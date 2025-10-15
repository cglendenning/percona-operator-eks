import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, logWarn, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const Args = z.object({
  action: z.enum(['install', 'uninstall', 'expand']),
  namespace: z.string().default('percona'),
  name: z.string().default('pxc-cluster'),
  helmRepo: z.string().default('https://percona.github.io/percona-helm-charts/'),
  chart: z.string().default('percona/pxc-operator'),
  clusterChart: z.string().default('percona/pxc-db'),
  nodes: z.coerce.number().int().positive().default(3),
  size: z.string().optional(),
});

type Args = z.infer<typeof Args>;

async function ensurePrereqs() {
  await ensureBinaryExists('kubectl', ['version', '--client']);
  await ensureBinaryExists('helm', ['version']);
}

async function ensureNamespace(ns: string) {
  try {
    await run('kubectl', ['get', 'ns', ns], { stdio: 'pipe' });
  } catch {
    await run('kubectl', ['create', 'namespace', ns]);
  }
}

async function addRepos(repoUrl: string) {
  try {
    await run('helm', ['repo', 'add', 'percona', repoUrl]);
  } catch (err) {
    // Repo already exists, that's fine
    logInfo('Percona repo already exists, continuing...');
  }
  await run('helm', ['repo', 'update']);
}

async function installOperator(ns: string) {
  await run('helm', ['upgrade', '--install', 'percona-operator', 'percona/pxc-operator', '-n', ns]);
}

function clusterValues(nodes: number, accountId: string): string {
  return `pxc:
  size: ${nodes}
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1
  persistence:
    enabled: true
    size: 20Gi
    accessMode: ReadWriteOnce
    storageClass: gp3
haproxy:
  enabled: false
proxysql:
  enabled: true
  size: 3
  image: percona/proxysql:2.4.4
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  volumeSpec:
    persistentVolumeClaim:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 5Gi
      storageClassName: gp3
backup:
  enabled: true
  storages:
    s3-backup:
      type: s3
      s3:
        bucket: percona-backups-${accountId}
        region: us-east-1
        credentialsSecret: percona-backup-s3-credentials
  schedule:
    - name: "daily-backup"
      schedule: "0 2 * * *"
      retention:
        type: "count"
        count: 7
        deleteFromStorage: true
      storageName: s3-backup
    - name: "weekly-backup"
      schedule: "0 1 * * 0"
      retention:
        type: "count"
        count: 4
        deleteFromStorage: true
      storageName: s3-backup
`;}

async function createStorageClass() {
  logInfo('Creating gp3 storage class...');
  const storageClassYaml = `apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: xfs
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer`;

  const { execa } = await import('execa');
  const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  proc.stdin?.write(storageClassYaml);
  proc.stdin?.end();
  await proc;

  // Remove default from gp2
  try {
    await run('kubectl', ['patch', 'storageclass', 'gp2', '-p', '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}']);
  } catch (error) {
    logInfo('gp2 storage class not found or already not default');
  }

  logSuccess('Storage class created');
}

async function createS3BackupBucket(region: string) {
  logInfo('Creating S3 backup bucket...');
  const { execa } = await import('execa');
  
  try {
    // Get AWS account ID
    const accountResult = await execa('aws', ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'], { stdio: 'pipe' });
    const accountId = accountResult.stdout.trim();
    
    const bucketName = `percona-backups-${accountId}`;
    
    // Create S3 bucket
    await run('aws', ['s3', 'mb', `s3://${bucketName}`, '--region', region]);
    
    // Enable versioning
    await run('aws', ['s3api', 'put-bucket-versioning', '--bucket', bucketName, '--versioning-configuration', 'Status=Enabled', '--region', region]);
    
    // Enable server-side encryption
    await run('aws', ['s3api', 'put-bucket-encryption', '--bucket', bucketName, '--server-side-encryption-configuration', JSON.stringify({
      Rules: [{
        ApplyServerSideEncryptionByDefault: {
          SSEAlgorithm: 'AES256'
        }
      }]
    }), '--region', region]);
    
    // Enable MFA delete protection (optional but recommended for production)
    try {
      await run('aws', ['s3api', 'put-bucket-versioning', '--bucket', bucketName, '--versioning-configuration', 'Status=Enabled,MFADelete=Disabled', '--region', region]);
    } catch (error) {
      logInfo('MFA delete configuration skipped (requires MFA device)');
    }
    
    // Set basic lifecycle policy for cost optimization
    const lifecyclePolicy = {
      Rules: [{
        ID: 'BackupLifecycle',
        Status: 'Enabled',
        Filter: {
          Prefix: ''
        },
        Transitions: [
          {
            Days: 30,
            StorageClass: 'STANDARD_IA'
          }
        ],
        Expiration: {
          Days: 2555  // 7 years retention
        }
      }]
    };
    
    // Write lifecycle policy to temporary file
    const { writeFileSync, unlinkSync } = await import('fs');
    const lifecycleFile = '/tmp/lifecycle-policy.json';
    writeFileSync(lifecycleFile, JSON.stringify(lifecyclePolicy, null, 2));
    
    try {
      await run('aws', ['s3api', 'put-bucket-lifecycle-configuration', '--bucket', bucketName, '--lifecycle-configuration', `file://${lifecycleFile}`, '--region', region]);
    } catch (lifecycleError) {
      logWarn(`Failed to set lifecycle policy: ${lifecycleError}`);
      logInfo('Continuing without lifecycle policy...');
    } finally {
      // Clean up temporary file
      try {
        unlinkSync(lifecycleFile);
      } catch (cleanupError) {
        // Ignore cleanup errors
      }
    }
    
    // Enable public access blocking for security
    await run('aws', ['s3api', 'put-public-access-block', '--bucket', bucketName, '--public-access-block-configuration', JSON.stringify({
      BlockPublicAcls: true,
      IgnorePublicAcls: true,
      BlockPublicPolicy: true,
      RestrictPublicBuckets: true
    }), '--region', region]);
    
    logSuccess(`S3 backup bucket created: ${bucketName}`);
    return bucketName;
  } catch (error) {
    logWarn(`Failed to create S3 bucket: ${error}`);
    throw error;
  }
}

async function createS3CredentialsSecret(ns: string, region: string) {
  logInfo('Creating S3 credentials secret...');
  const { execa } = await import('execa');
  
  try {
    // Get AWS account ID
    const accountResult = await execa('aws', ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'], { stdio: 'pipe' });
    const accountId = accountResult.stdout.trim();
    
    const userName = 'percona-backup-user';
    const policyName = 'PerconaBackupPolicy';
    
    // Create IAM user for Percona backups
    try {
      const userResult = await execa('aws', ['iam', 'create-user', '--user-name', userName], { stdio: 'pipe' });
      logInfo(`Created IAM user: ${userName}`);
    } catch (error) {
      if (error.toString().includes('EntityAlreadyExists') || error.toString().includes('User with name percona-backup-user already exists')) {
        logInfo(`IAM user ${userName} already exists`);
      } else {
        logWarn(`Unexpected error creating IAM user: ${error}`);
        throw error;
      }
    }
    
    // Create IAM policy for S3 backup access
    const policyDocument = {
      Version: '2012-10-17',
      Statement: [{
        Effect: 'Allow',
        Action: [
          's3:GetObject',
          's3:PutObject',
          's3:DeleteObject',
          's3:ListBucket'
        ],
        Resource: [
          `arn:aws:s3:::percona-backups-${accountId}`,
          `arn:aws:s3:::percona-backups-${accountId}/*`
        ]
      }]
    };
    
    try {
      await execa('aws', ['iam', 'create-policy', '--policy-name', policyName, '--policy-document', JSON.stringify(policyDocument)], { stdio: 'pipe' });
      logInfo(`Created IAM policy: ${policyName}`);
    } catch (error) {
      if (error.toString().includes('EntityAlreadyExists')) {
        logInfo(`IAM policy ${policyName} already exists`);
      } else {
        throw error;
      }
    }
    
    // Attach policy to user
    try {
      await execa('aws', ['iam', 'attach-user-policy', '--user-name', userName, '--policy-arn', `arn:aws:iam::${accountId}:policy/${policyName}`], { stdio: 'pipe' });
    } catch (error) {
      if (error.toString().includes('EntityAlreadyExists')) {
        logInfo(`Policy already attached to user ${userName}`);
      } else {
        throw error;
      }
    }
    
    // Check if user already has access keys
    let accessKey, secretKey;
    try {
      const existingKeysResult = await execa('aws', ['iam', 'list-access-keys', '--user-name', userName], { stdio: 'pipe' });
      const existingKeys = JSON.parse(existingKeysResult.stdout);
      
      if (existingKeys.AccessKeyMetadata && existingKeys.AccessKeyMetadata.length > 0) {
        logInfo(`User ${userName} already has access keys, using existing ones`);
        // Get the existing access key ID
        const existingKeyId = existingKeys.AccessKeyMetadata[0].AccessKeyId;
        
        // We can't retrieve the secret key, so we need to create a new one
        // First delete the old one
        await run('aws', ['iam', 'delete-access-key', '--user-name', userName, '--access-key-id', existingKeyId]);
        logInfo('Deleted existing access key, creating new one');
      }
    } catch (error) {
      logInfo('No existing access keys found or error checking, creating new ones');
    }
    
    // Create access key for the user
    const keyResult = await execa('aws', ['iam', 'create-access-key', '--user-name', userName], { stdio: 'pipe' });
    const keyData = JSON.parse(keyResult.stdout);
    accessKey = keyData.AccessKey.AccessKeyId;
    secretKey = keyData.AccessKey.SecretAccessKey;
    
    // Create Kubernetes secret
    const secretYaml = `apiVersion: v1
kind: Secret
metadata:
  name: percona-backup-s3-credentials
  namespace: ${ns}
type: Opaque
data:
  AWS_ACCESS_KEY_ID: ${Buffer.from(accessKey).toString('base64')}
  AWS_SECRET_ACCESS_KEY: ${Buffer.from(secretKey).toString('base64')}`;

    const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
    proc.stdin?.write(secretYaml);
    proc.stdin?.end();
    await proc;

    logSuccess('S3 credentials secret created');
  } catch (error) {
    logWarn(`Failed to create S3 credentials secret: ${error}`);
    throw error;
  }
}

async function installCluster(ns: string, name: string, nodes: number, accountId: string) {
  const values = clusterValues(nodes, accountId);
  const { execa } = await import('execa');
  const proc = execa('helm', ['upgrade', '--install', name, 'percona/pxc-db', '-n', ns, '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  proc.stdin?.write(values);
  proc.stdin?.end();
  await proc;
}

async function waitForClusterReady(ns: string, name: string, nodes: number) {
  const pxcResourceName = `${name}-pxc-db`;
  logInfo(`Waiting for Percona cluster ${pxcResourceName} to be ready...`);
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 30 * 60 * 1000; // 30 minutes
  
  while (Date.now() - startTime < timeout) {
    try {
      // Check PXC custom resource status
      const pxcResult = await execa('kubectl', ['get', 'pxc', pxcResourceName, '-n', ns, '-o', 'json'], { stdio: 'pipe' });
      const pxc = JSON.parse(pxcResult.stdout);
      
      const pxcCount = pxc.status?.pxc || 0;
      const proxysqlCount = pxc.status?.proxysql || 0;
      const status = pxc.status?.status || 'unknown';
      
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logInfo(`Cluster status: ${status}, PXC: ${pxcCount}/${nodes}, ProxySQL: ${proxysqlCount} (${elapsed}s elapsed)`);
      
      // Check if all PXC pods are ready
      const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster', '--no-headers'], { stdio: 'pipe' });
      const podLines = podsResult.stdout.trim().split('\n').filter(line => line.includes(`${pxcResourceName}-pxc-`));
      
      if (podLines.length >= nodes) {
        const allReady = podLines.every(line => {
          const parts = line.split(/\s+/);
          const ready = parts[1];
          return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
        });
        
        if (allReady && pxcCount >= nodes && status === 'ready') {
          logSuccess(`Percona cluster ${pxcResourceName} is ready with ${nodes} nodes`);
          return;
        }
      }
      
      await new Promise(resolve => setTimeout(resolve, 30000)); // Wait 30 seconds
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking cluster status (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 30000));
    }
  }
  
  throw new Error(`Percona cluster ${pxcResourceName} did not become ready within 30 minutes`);
}

async function expandVolumes(ns: string, name: string, newSize: string) {
  logInfo(`Expanding Percona volumes to ${newSize}...`);
  
  try {
    // Get all PVCs for the cluster
    const { execa } = await import('execa');
    const pvcResult = await execa('kubectl', ['get', 'pvc', '-n', ns, '-l', `app.kubernetes.io/instance=${name}`, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
    const pvcs = pvcResult.stdout.trim().split('\n').filter(name => name.trim());
    
    if (pvcs.length === 0) {
      logWarn('No PVCs found for the cluster');
      return;
    }
    
    // Expand each PVC
    for (const pvcName of pvcs) {
      logInfo(`Expanding PVC: ${pvcName}`);
      await run('kubectl', ['patch', 'pvc', pvcName, '-n', ns, '-p', `{"spec":{"resources":{"requests":{"storage":"${newSize}"}}}}`]);
    }
    
    // Wait for expansion to complete
    logInfo('Waiting for volume expansion to complete...');
    await run('kubectl', ['wait', '--for=condition=FileSystemResizePending', 'pvc', '--all', '-n', ns, '--timeout=300s']);
    
    // Restart the cluster to pick up the new size
    logInfo('Restarting Percona cluster to apply volume expansion...');
    await run('kubectl', ['rollout', 'restart', 'statefulset', `${name}-pxc-db-pxc`, '-n', ns]);
    
    logSuccess(`Volumes expanded to ${newSize} successfully`);
  } catch (error) {
    logError(`Failed to expand volumes: ${error}`);
    throw error;
  }
}

async function uninstall(ns: string, name: string) {
  logInfo('Uninstalling Percona cluster and operator...');
  
  // First, try to delete the PXC custom resource gracefully
  try {
    logInfo('Deleting PXC custom resource...');
    await run('kubectl', ['delete', 'pxc', name, '-n', ns, '--timeout=60s']);
  } catch (error) {
    logWarn('PXC resource deletion timed out or failed, forcing cleanup...');
  }
  
  // Force delete PXC resource if it still exists (remove finalizers)
  try {
    const { execa } = await import('execa');
    const result = await execa('kubectl', ['get', 'pxc', name, '-n', ns], { stdio: 'pipe' });
    if (result.exitCode === 0) {
      logInfo('Removing finalizers from PXC resource...');
      await run('kubectl', ['patch', 'pxc', name, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge']);
      await run('kubectl', ['delete', 'pxc', name, '-n', ns]);
    }
  } catch (error) {
    logInfo('PXC resource already deleted or not found');
  }
  
  // Delete StatefulSets manually to ensure they're removed
  try {
    logInfo('Deleting StatefulSets...');
    await run('kubectl', ['delete', 'statefulset', '--all', '-n', ns]);
  } catch (error) {
    logInfo('No StatefulSets found or already deleted');
  }
  
  // Delete Services
  try {
    logInfo('Deleting Services...');
    await run('kubectl', ['delete', 'service', '--all', '-n', ns]);
  } catch (error) {
    logInfo('No Services found or already deleted');
  }
  
  // Delete PVCs to avoid orphaned volumes
  try {
    logInfo('Deleting PVCs...');
    await run('kubectl', ['delete', 'pvc', '--all', '-n', ns]);
  } catch (error) {
    logInfo('No PVCs found or already deleted');
  }
  
  // Uninstall Helm releases
  try {
    logInfo('Uninstalling Helm releases...');
    await run('helm', ['uninstall', name, '-n', ns]);
  } catch (error) {
    logInfo(`Helm release ${name} not found or already deleted`);
  }
  
  try {
    await run('helm', ['uninstall', 'percona-operator', '-n', ns]);
  } catch (error) {
    logInfo('Percona operator Helm release not found or already deleted');
  }
  
  // Clean up any remaining pods
  try {
    logInfo('Cleaning up remaining pods...');
    await run('kubectl', ['delete', 'pods', '--all', '-n', ns]);
  } catch (error) {
    logInfo('No remaining pods to clean up');
  }
  
  logSuccess('Percona cluster and operator uninstalled successfully');
}

async function main() {
  const argv = await yargs(hideBin(process.argv))
    .command('install', 'Install Percona operator and 3-node cluster')
    .command('uninstall', 'Uninstall Percona cluster and operator')
    .command('expand', 'Expand Percona cluster volumes')
    .option('namespace', { type: 'string' })
    .option('name', { type: 'string' })
    .option('helmRepo', { type: 'string' })
    .option('chart', { type: 'string' })
    .option('clusterChart', { type: 'string' })
    .option('nodes', { type: 'number' })
    .option('size', { type: 'string', description: 'New volume size (e.g., 50Gi, 100Gi)' })
    .demandCommand(1)
    .strict()
    .parse();

  const action = String(argv._[0]);
  const parsed = Args.parse({
    action,
    namespace: argv.namespace,
    name: argv.name,
    helmRepo: argv.helmRepo,
    chart: argv.chart,
    clusterChart: argv.clusterChart,
    nodes: argv.nodes,
    size: argv.size,
  });

  try {
    await ensurePrereqs();
    if (parsed.action === 'install') {
      await ensureNamespace(parsed.namespace);
      await addRepos(parsed.helmRepo);
      
      // Create storage class first
      await createStorageClass();
      
      // Get AWS account ID
      const { execa } = await import('execa');
      const accountResult = await execa('aws', ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'], { stdio: 'pipe' });
      const accountId = accountResult.stdout.trim();
      
      // Create S3 backup bucket and credentials
      await createS3BackupBucket('us-east-1');
      await createS3CredentialsSecret(parsed.namespace, 'us-east-1');
      
      logInfo('Installing Percona operator...');
      await installOperator(parsed.namespace);
      
      logInfo('Installing Percona cluster...');
      await installCluster(parsed.namespace, parsed.name, parsed.nodes, accountId);
      
      // Wait for cluster to be fully ready
      await waitForClusterReady(parsed.namespace, parsed.name, parsed.nodes);
      
      logSuccess('Percona operator and cluster installed and ready.');
    } else if (parsed.action === 'expand') {
      if (!parsed.size) {
        logError('Size parameter is required for expand command');
        process.exitCode = 1;
        return;
      }
      logInfo(`Expanding Percona cluster volumes to ${parsed.size}...`);
      await expandVolumes(parsed.namespace, parsed.name, parsed.size);
      logSuccess('Volume expansion completed.');
    } else {
      logInfo('Uninstalling Percona cluster and operator...');
      await uninstall(parsed.namespace, parsed.name);
      logSuccess('Uninstall completed.');
    }
  } catch (err) {
    logError('Percona script failed', err);
    process.exitCode = 1;
  }
}

main();


