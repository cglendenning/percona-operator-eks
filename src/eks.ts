import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, logWarn, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';
// process is a global Node.js object

const EksArgs = z.object({
  action: z.enum(['create', 'delete', 'upgrade-addons']),
  name: z.string().default('percona-eks'),
  region: z.string().default('us-east-1'),
  version: z.string().default('1.34'),
  nodeType: z.string().default('m6i.large'),
  nodes: z.coerce.number().int().positive().default(3),
  spot: z.coerce.boolean().default(true),
});

type EksArgs = z.infer<typeof EksArgs>;

async function ensurePrereqs() {
  await ensureBinaryExists('aws', ['--version']);
  await ensureBinaryExists('kubectl', ['version', '--client']);
  await ensureBinaryExists('eksctl', ['version']);
}

function buildClusterYaml(args: EksArgs): string {
  const spotLine = args.spot ? '    spot: true\n' : '';
  return `apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${args.name}
  region: ${args.region}
  version: "${args.version}"
iam:
  withOIDC: true
managedNodeGroups:
  - name: ng-spot
    amiFamily: AmazonLinux2023
    instanceTypes: [${JSON.stringify(args.nodeType)}]
    desiredCapacity: ${args.nodes}
    minSize: ${args.nodes}
    maxSize: ${Math.max(args.nodes, args.nodes + 1)}
${spotLine}    volumeSize: 50
    labels: { workload: percona }
addons:
  - name: aws-ebs-csi-driver
    version: latest
    resolveConflicts: overwrite
`; 
}

async function createCluster(args: EksArgs) {
  await ensurePrereqs();
  const yaml = buildClusterYaml(args);
  logInfo('Creating EKS cluster via eksctl...');
  await createClusterWithStdin(yaml);
  
  logSuccess(`EKS cluster ${args.name} created successfully`);
  
  // Wait for cluster to be ready
  await waitForClusterReady(args.name, args.region);
  
  // Fix IAM permissions for VPC CNI
  await fixVpcCniPermissions(args.name, args.region);
  
  // Setup EBS CSI driver with proper IAM role
  await setupEbsCsiDriver(args.name, args.region);
  
  // Wait for all addons to be active
  await waitForAddonsActive(args.name, args.region);
  
  logSuccess(`EKS cluster ${args.name} is fully ready with all addons`);
}

async function createClusterWithStdin(yaml: string) {
  const { execa } = await import('execa');
  const subprocess = execa('eksctl', ['create', 'cluster', '--config-file=-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  subprocess.stdin?.write(yaml);
  subprocess.stdin?.end();
  await subprocess;
}

async function waitForClusterReady(clusterName: string, region: string) {
  logInfo('Waiting for EKS cluster to be ready...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 20 * 60 * 1000; // 20 minutes
  
  while (Date.now() - startTime < timeout) {
    try {
      const result = await execa('aws', ['eks', 'describe-cluster', '--name', clusterName, '--region', region], { stdio: 'pipe' });
      const cluster = JSON.parse(result.stdout).cluster;
      
      if (cluster.status === 'ACTIVE') {
        logSuccess(`EKS cluster ${clusterName} is ready`);
        return;
      }
      
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logInfo(`Cluster status: ${cluster.status} (${elapsed}s elapsed)`);
      
      await new Promise(resolve => setTimeout(resolve, 30000)); // Wait 30 seconds
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking cluster status (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 30000));
    }
  }
  
  throw new Error(`EKS cluster ${clusterName} did not become ready within 20 minutes`);
}

async function fixVpcCniPermissions(clusterName: string, region: string) {
  logInfo('Fixing VPC CNI IAM permissions...');
  const { execa } = await import('execa');
  
  try {
    // Get the node group role name
    const nodeGroupResult = await execa('aws', ['eks', 'describe-nodegroup', '--cluster-name', clusterName, '--nodegroup-name', 'ng-spot', '--region', region], { stdio: 'pipe' });
    const nodeGroup = JSON.parse(nodeGroupResult.stdout).nodegroup;
    const nodeGroupRoleArn = nodeGroup.nodeRole;
    const nodeGroupRoleName = nodeGroupRoleArn.split('/').pop();
    
    if (!nodeGroupRoleName) {
      throw new Error('Could not extract node group role name');
    }
    
    // Attach VPC CNI policy to node group role
    logInfo(`Attaching VPC CNI policy to node group role: ${nodeGroupRoleName}`);
    await run('aws', ['iam', 'attach-role-policy', '--role-name', nodeGroupRoleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy']);
    
    logSuccess('VPC CNI IAM permissions fixed');
  } catch (error) {
    logWarn(`Failed to fix VPC CNI permissions: ${error}`);
    // Continue anyway as this might already be fixed
  }
}

async function setupEbsCsiDriver(clusterName: string, region: string) {
  logInfo('Setting up EBS CSI driver with proper IAM role...');
  const { execa } = await import('execa');
  
  try {
    // Get cluster OIDC issuer URL
    const clusterResult = await execa('aws', ['eks', 'describe-cluster', '--name', clusterName, '--region', region], { stdio: 'pipe' });
    const cluster = JSON.parse(clusterResult.stdout).cluster;
    const oidcIssuer = cluster.identity.oidc.issuer;
    const oidcId = oidcIssuer.split('/').pop();
    
    if (!oidcId) {
      throw new Error('Could not extract OIDC ID');
    }
    
    const accountId = await getAccountId();
    const roleName = 'AmazonEKS_EBS_CSI_DriverRole';
    const roleArn = `arn:aws:iam::${accountId}:role/${roleName}`;
    
    // Create IAM role for EBS CSI driver
    logInfo('Creating IAM role for EBS CSI driver...');
    try {
      await run('aws', ['iam', 'create-role', '--role-name', roleName, '--assume-role-policy-document', JSON.stringify({
        Version: '2012-10-17',
        Statement: [{
          Effect: 'Allow',
          Principal: {
            Federated: `arn:aws:iam::${accountId}:oidc-provider/oidc.eks.${region}.amazonaws.com/id/${oidcId}`
          },
          Action: 'sts:AssumeRoleWithWebIdentity',
          Condition: {
            StringEquals: {
              [`oidc.eks.${region}.amazonaws.com/id/${oidcId}:sub`]: 'system:serviceaccount:kube-system:ebs-csi-controller-sa',
              [`oidc.eks.${region}.amazonaws.com/id/${oidcId}:aud`]: 'sts.amazonaws.com'
            }
          }
        }]
      })]);
    } catch (error) {
      if (error instanceof Error && error.toString().includes('EntityAlreadyExists')) {
        logInfo('EBS CSI driver IAM role already exists');
      } else {
        throw error;
      }
    }
    
    // Attach EBS CSI driver policy
    await run('aws', ['iam', 'attach-role-policy', '--role-name', roleName, '--policy-arn', 'arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy']);
    
    // Update service account annotation
    logInfo('Updating EBS CSI driver service account...');
    await run('kubectl', ['annotate', 'serviceaccount', 'ebs-csi-controller-sa', '-n', 'kube-system', `eks.amazonaws.com/role-arn=${roleArn}`, '--overwrite']);
    
    // Restart EBS CSI controller
    logInfo('Restarting EBS CSI controller...');
    await run('kubectl', ['rollout', 'restart', 'deployment/ebs-csi-controller', '-n', 'kube-system']);
    
    // Wait for EBS CSI controller to be ready
    await waitForEbsCsiController();
    
    logSuccess('EBS CSI driver setup complete');
  } catch (error) {
    logWarn(`Failed to setup EBS CSI driver: ${error}`);
    // Continue anyway as this might already be working
  }
}

async function getAccountId(): Promise<string> {
  const { execa } = await import('execa');
  const result = await execa('aws', ['sts', 'get-caller-identity'], { stdio: 'pipe' });
  const identity = JSON.parse(result.stdout);
  return identity.Account;
}

async function waitForEbsCsiController() {
  logInfo('Waiting for EBS CSI controller to be ready...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 10 * 60 * 1000; // 10 minutes
  
  while (Date.now() - startTime < timeout) {
    try {
      const result = await execa('kubectl', ['get', 'pods', '-n', 'kube-system', '-l', 'app=ebs-csi-controller'], { stdio: 'pipe' });
      const lines = result.stdout.trim().split('\n').slice(1); // Skip header
      
      if (lines.length > 0) {
        const allReady = lines.every((line: string) => {
          const parts = line.split(/\s+/);
          const ready = parts[1];
          return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
        });
        
        if (allReady) {
          logSuccess('EBS CSI controller is ready');
          return;
        }
      }
      
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logInfo(`EBS CSI controller not ready yet (${elapsed}s elapsed)`);
      
      await new Promise(resolve => setTimeout(resolve, 30000)); // Wait 30 seconds
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking EBS CSI controller (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 30000));
    }
  }
  
  throw new Error('EBS CSI controller did not become ready within 10 minutes');
}

async function waitForAddonsActive(clusterName: string, region: string) {
  logInfo('Waiting for all EKS addons to be active...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 30 * 60 * 1000; // 30 minutes
  
  const expectedAddons = ['vpc-cni', 'aws-ebs-csi-driver', 'coredns', 'kube-proxy', 'metrics-server'];
  
  while (Date.now() - startTime < timeout) {
    try {
      const result = await execa('aws', ['eks', 'list-addons', '--cluster-name', clusterName, '--region', region], { stdio: 'pipe' });
      const addons = JSON.parse(result.stdout).addons || [];
      
      let allActive = true;
      for (const addonName of expectedAddons) {
        if (addons.includes(addonName)) {
          const addonResult = await execa('aws', ['eks', 'describe-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region], { stdio: 'pipe' });
          const addon = JSON.parse(addonResult.stdout).addon;
          
          if (addon.status !== 'ACTIVE') {
            allActive = false;
            const elapsed = Math.round((Date.now() - startTime) / 1000);
            logInfo(`${addonName} status: ${addon.status} (${elapsed}s elapsed)`);
          }
        }
      }
      
      if (allActive) {
        logSuccess('All EKS addons are active');
        return;
      }
      
      await new Promise(resolve => setTimeout(resolve, 60000)); // Wait 1 minute
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking addon status (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 60000));
    }
  }
  
  throw new Error('Not all EKS addons became active within 30 minutes');
}

async function getAddonLogs(clusterName: string, addonName: string, region: string, startTime?: Date) {
  const { execa } = await import('execa');
  
  try {
    // Get CloudWatch logs for the addon
    const logGroupName = `/aws/eks/${clusterName}/cluster`;
    const logStreamPrefix = addonName === 'vpc-cni' ? 'vpc-cni' : addonName;
    
    // Get recent log streams
    const streamsResult = await execa('aws', [
      'logs', 'describe-log-streams',
      '--log-group-name', logGroupName,
      '--log-stream-name-prefix', logStreamPrefix,
      '--order-by', 'LastEventTime',
      '--descending',
      '--max-items', '5',
      '--region', region
    ], { stdio: 'pipe' });
    
    const streams = JSON.parse(streamsResult.stdout).logStreams || [];
    
    if (streams.length === 0) {
      logInfo(`  No CloudWatch logs found for ${addonName}`);
      return;
    }
    
    // Get logs from the most recent stream
    const latestStream = streams[0];
    const logStreamName = latestStream.logStreamName;
    
    // Build time filter if startTime provided
    const timeFilter = startTime ? [
      '--start-time', Math.floor(startTime.getTime() / 1000).toString()
    ] : [
      '--start-time', Math.floor((Date.now() - 300000) / 1000).toString() // Last 5 minutes
    ];
    
    // Get recent log events
    const logsResult = await execa('aws', [
      'logs', 'get-log-events',
      '--log-group-name', logGroupName,
      '--log-stream-name', logStreamName,
      '--region', region,
      '--limit', '20',
      ...timeFilter
    ], { stdio: 'pipe' });
    
    const logEvents = JSON.parse(logsResult.stdout).events || [];
    
    if (logEvents.length > 0) {
      logInfo(`  Recent ${addonName} logs:`);
      logEvents.slice(-5).forEach((event: { timestamp: number; message: string }) => {
        const timestamp = new Date(event.timestamp).toISOString();
        const message = event.message.trim();
        if (message) {
          logInfo(`    [${timestamp}] ${message}`);
        }
      });
    } else {
      logInfo(`  No recent log events found for ${addonName}`);
    }
    
  } catch (error) {
    logWarn(`  Could not retrieve logs for ${addonName}: ${error}`);
  }
}

async function getKubernetesLogs(clusterName: string, addonName: string) {
  try {
    // Get kubectl context
    await run('kubectl', ['config', 'current-context']);
    
    // Get logs from addon pods
    const namespace = addonName === 'vpc-cni' ? 'kube-system' : 'kube-system';
    const podSelector = addonName === 'vpc-cni' ? 'app=vpc-cni' : `app=${addonName}`;
    
    // Get pod names
    const { execa } = await import('execa');
    const podsResult = await execa('kubectl', [
      'get', 'pods',
      '-n', namespace,
      '-l', podSelector,
      '--no-headers',
      '-o', 'custom-columns=NAME:.metadata.name'
    ], { stdio: 'pipe' });
    
    const podNames = podsResult.stdout.trim().split('\n').filter((name: string) => name.trim());
    
    if (podNames.length > 0) {
      logInfo(`  Recent ${addonName} pod logs:`);
      for (const podName of podNames.slice(0, 2)) { // Limit to 2 pods
        try {
          const logsResult = await execa('kubectl', [
            'logs', podName,
            '-n', namespace,
            '--tail', '10',
            '--since', '2m'
          ], { stdio: 'pipe' });
          
          const logs = logsResult.stdout.trim();
          if (logs) {
            logInfo(`    Pod ${podName}:`);
            logs.split('\n').slice(-5).forEach((line: string) => {
              if (line.trim()) {
                logInfo(`      ${line}`);
              }
            });
          }
        } catch (podError) {
          logWarn(`    Could not get logs from pod ${podName}: ${podError}`);
        }
      }
    } else {
      logInfo(`  No ${addonName} pods found`);
    }
    
  } catch (error) {
    logWarn(`  Could not retrieve Kubernetes logs for ${addonName}: ${error}`);
  }
}

async function waitForAddonWithProgress(clusterName: string, addonName: string, region: string, timeoutSeconds: number) {
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = timeoutSeconds * 1000;
  let lastLogCheck = 0;
  
  logInfo(`Monitoring ${addonName} progress (timeout: ${timeoutSeconds}s)...`);
  
  while (Date.now() - startTime < timeout) {
    try {
      // Get current addon status
      const result = await execa('aws', ['eks', 'describe-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region], { stdio: 'pipe' });
      const addonInfo = JSON.parse(result.stdout).addon;
      const status = addonInfo.status;
      const health = addonInfo.health;
      
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      
      if (status === 'ACTIVE') {
        logSuccess(`${addonName} is now ACTIVE (took ${elapsed}s)`);
        return;
      }
      
      // Log current status with progress info
      let statusMessage = `${addonName} status: ${status}`;
      if (health && health.issues && health.issues.length > 0) {
        statusMessage += ` (${health.issues.length} issue(s))`;
      }
      if (addonInfo.addonVersion) {
        statusMessage += ` - version: ${addonInfo.addonVersion}`;
      }
      statusMessage += ` - elapsed: ${elapsed}s`;
      
      logInfo(statusMessage);
      
      // Show logs every 30 seconds for VPC CNI, every 60 seconds for others
      const logInterval = addonName === 'vpc-cni' ? 30000 : 60000;
      if (Date.now() - lastLogCheck > logInterval) {
        lastLogCheck = Date.now();
        
        // Get CloudWatch logs
        await getAddonLogs(clusterName, addonName, region, new Date(startTime));
        
        // Get Kubernetes logs
        await getKubernetesLogs(clusterName, addonName);
      }
      
      // Wait before next check
      await new Promise(resolve => setTimeout(resolve, 10000)); // Check every 10 seconds
      
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking ${addonName} status (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 10000));
    }
  }
  
  throw new Error(`${addonName} did not become ACTIVE within ${timeoutSeconds} seconds`);
}

async function upgradeAddons(clusterName: string, region: string) {
  logInfo('Ensuring all expected addons are installed and upgraded to latest versions...');
  try {
    // Expected addons that should be present
    const expectedAddons = [
      'aws-ebs-csi-driver',
      'vpc-cni', 
      'coredns',
      'kube-proxy',
      'metrics-server'
    ];
    
    // Get list of currently installed addons
    const { execa } = await import('execa');
    const result = await execa('aws', ['eks', 'list-addons', '--cluster-name', clusterName, '--region', region], { stdio: 'pipe' });
    const installedAddons = JSON.parse(result.stdout).addons || [];
    
    // Install missing addons
    const missingAddons = expectedAddons.filter(addon => !installedAddons.includes(addon));
    if (missingAddons.length > 0) {
      logInfo(`Installing missing addons: ${missingAddons.join(', ')}`);
      for (const addonName of missingAddons) {
        logInfo(`Installing ${addonName}...`);
        await run('aws', ['eks', 'create-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region, '--resolve-conflicts', 'OVERWRITE']);
        // Wait for addon to be active with progress monitoring
        logInfo(`Waiting for ${addonName} to be active...`);
        await waitForAddonWithProgress(clusterName, addonName, region, 300);
        logSuccess(`${addonName} installed successfully`);
      }
    }
    
    // Now upgrade all addons (including newly installed ones)
    const allAddons = [...new Set([...installedAddons, ...missingAddons])];
    
    let upgradedCount = 0;
    let skippedCount = 0;
    let alreadyLatestCount = 0;
    
    // Upgrade each addon
    for (const addonName of allAddons) {
      logInfo(`Checking addon: ${addonName}`);
      
      // Get current addon info
      const currentResult = await execa('aws', ['eks', 'describe-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region], { stdio: 'pipe' });
      const currentInfo = JSON.parse(currentResult.stdout).addon;
      const currentVersion = currentInfo.addonVersion;
      const currentStatus = currentInfo.status;
      
      // Skip if addon is already updating
      if (currentStatus === 'UPDATING' || currentStatus === 'CREATING') {
        logInfo(`${addonName} is currently ${currentStatus.toLowerCase()}, skipping upgrade`);
        skippedCount++;
        continue;
      }
      
      // Get available versions
      const versionsResult = await execa('aws', ['eks', 'describe-addon-versions', '--addon-name', addonName, '--region', region], { stdio: 'pipe' });
      const versionsInfo = JSON.parse(versionsResult.stdout);
      const availableVersions = versionsInfo.addons[0]?.addonVersions || [];
      
      if (availableVersions.length === 0) {
        logWarn(`No available versions found for ${addonName}, skipping`);
        continue;
      }
      
      // Find the latest version (sort by version and take the last one)
      const latestVersion = availableVersions
        .sort((a: any, b: any) => a.addonVersion.localeCompare(b.addonVersion, undefined, { numeric: true }))
        .pop()?.addonVersion;
      
      if (!latestVersion) {
        logWarn(`Could not determine latest version for ${addonName}, skipping`);
        continue;
      }
      
      if (currentVersion === latestVersion) {
        logInfo(`${addonName} is already at latest version ${latestVersion}`);
        alreadyLatestCount++;
        continue;
      }
      
      logInfo(`Upgrading ${addonName} from ${currentVersion} to ${latestVersion}...`);
      await run('aws', ['eks', 'update-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--addon-version', latestVersion, '--region', region, '--resolve-conflicts', 'OVERWRITE']);
      
          // Wait for addon to be active with progress monitoring
          logInfo(`Waiting for ${addonName} to be active (this may take several minutes for VPC CNI)...`);
          try {
            if (addonName === 'vpc-cni') {
              // VPC CNI can take 15+ minutes, monitor progress
              await waitForAddonWithProgress(clusterName, addonName, region, 1200);
            } else {
              await waitForAddonWithProgress(clusterName, addonName, region, 300);
            }
            logSuccess(`${addonName} upgraded to ${latestVersion}`);
            upgradedCount++;
          } catch (waitError) {
            logWarn(`${addonName} upgrade may still be in progress. Check status manually with: aws eks describe-addon --cluster-name ${clusterName} --addon-name ${addonName} --region ${region}`);
            upgradedCount++; // Count as upgraded even if we can't confirm completion
          }
    }
    
    // Provide accurate summary
    if (upgradedCount > 0) {
      logSuccess(`Upgraded ${upgradedCount} addon(s) to latest versions`);
    }
    if (alreadyLatestCount > 0) {
      logInfo(`${alreadyLatestCount} addon(s) were already at latest versions`);
    }
    if (skippedCount > 0) {
      logInfo(`${skippedCount} addon(s) were skipped (currently updating/creating)`);
    }
  } catch (err) {
    logWarn('Failed to upgrade some addons, but cluster is still functional');
  }
}

async function deleteCluster(args: EksArgs) {
  await ensurePrereqs();
  logWarnAboutResiduals();
  logInfo(`Deleting EKS cluster ${args.name} in ${args.region}...`);
  await run('eksctl', ['delete', 'cluster', '--name', args.name, '--region', args.region, '--disable-nodegroup-eviction']);
}

function logWarnAboutResiduals() {
  logInfo('Note: Ensure no leftover LoadBalancers or EBS volumes after deletion.');
}

async function main() {
  const argv = await yargs(hideBin(process.argv))
    .command('create', 'Create EKS cluster')
    .command('delete', 'Delete EKS cluster')
    .command('upgrade-addons', 'Upgrade all addons on existing EKS cluster')
    .version(false)
    .option('name', { type: 'string' })
    .option('region', { type: 'string' })
    .option('version', { type: 'string' })
    .option('nodeType', { type: 'string' })
    .option('nodes', { type: 'number' })
    .option('spot', { type: 'boolean' })
    .demandCommand(1)
    .strict()
    .parse();

  const action = String(argv._[0]);
  const parsed = EksArgs.parse({
    action,
    name: argv.name,
    region: argv.region,
    version: argv.version,
    nodeType: argv.nodeType,
    nodes: argv.nodes,
    spot: argv.spot,
  });

  try {
    if (parsed.action === 'create') {
      const yaml = buildClusterYaml(parsed);
      await createClusterWithStdin(yaml);
      logSuccess('EKS cluster created. Upgrading addons...');
      await upgradeAddons(parsed.name, parsed.region);
      logSuccess('Updating kubeconfig...');
      await run('aws', ['eks', 'update-kubeconfig', '--name', parsed.name, '--region', parsed.region]);
    } else if (parsed.action === 'upgrade-addons') {
      await ensurePrereqs();
      await upgradeAddons(parsed.name, parsed.region);
    } else {
      await deleteCluster(parsed);
      logSuccess('EKS cluster deletion initiated.');
    }
  } catch (err) {
    logError('Failed to execute EKS action', err);
    process.exitCode = 1;
  }
}

main();


