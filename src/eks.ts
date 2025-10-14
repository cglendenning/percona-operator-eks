import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

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
  await run('eksctl', ['create', 'cluster', '--config-file=-'], { stdio: 'pipe' });
  // The above execa call with stdio pipe won't send stdin; use a separate call that writes stdin
}

async function createClusterWithStdin(yaml: string) {
  const { execa } = await import('execa');
  const subprocess = execa('eksctl', ['create', 'cluster', '--config-file=-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  subprocess.stdin?.write(yaml);
  subprocess.stdin?.end();
  await subprocess;
}

async function upgradeAddons(clusterName: string, region: string) {
  logInfo('Upgrading all EKS addons to latest versions...');
  try {
    // Get list of installed addons
    const { execa } = await import('execa');
    const result = await execa('aws', ['eks', 'list-addons', '--cluster-name', clusterName, '--region', region], { stdio: 'pipe' });
    const addons = JSON.parse(result.stdout).addons || [];
    
    // Upgrade each addon
    for (const addonName of addons) {
      logInfo(`Checking addon: ${addonName}`);
      
      // Get current addon info
      const currentResult = await execa('aws', ['eks', 'describe-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region], { stdio: 'pipe' });
      const currentInfo = JSON.parse(currentResult.stdout).addon;
      const currentVersion = currentInfo.addonVersion;
      
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
        continue;
      }
      
      logInfo(`Upgrading ${addonName} from ${currentVersion} to ${latestVersion}...`);
      await run('aws', ['eks', 'update-addon', '--cluster-name', clusterName, '--addon-name', addonName, '--addon-version', latestVersion, '--region', region, '--resolve-conflicts', 'OVERWRITE']);
      
      // Wait for addon to be active
      logInfo(`Waiting for ${addonName} to be active...`);
      await run('aws', ['eks', 'wait', 'addon-active', '--cluster-name', clusterName, '--addon-name', addonName, '--region', region]);
      logSuccess(`${addonName} upgraded to ${latestVersion}`);
    }
    logSuccess('All addons upgraded to latest versions');
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


