import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const Args = z.object({
  action: z.enum(['install', 'uninstall']),
  namespace: z.string().default('percona'),
  name: z.string().default('pxc-cluster'),
  helmRepo: z.string().default('https://percona.github.io/percona-helm-charts/'),
  chart: z.string().default('percona/pxc-operator'),
  clusterChart: z.string().default('percona/pxc-db'),
  nodes: z.coerce.number().int().positive().default(3),
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

function clusterValues(nodes: number): string {
  return `pxc:
  size: ${nodes}
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1
proxyHaproxy:
  enabled: false
proxyProxysql:
  enabled: true
  size: 3
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
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

async function installCluster(ns: string, name: string, nodes: number) {
  const values = clusterValues(nodes);
  const { execa } = await import('execa');
  const proc = execa('helm', ['upgrade', '--install', name, 'percona/pxc-db', '-n', ns, '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  proc.stdin?.write(values);
  proc.stdin?.end();
  await proc;
}

async function waitForClusterReady(ns: string, name: string, nodes: number) {
  logInfo(`Waiting for Percona cluster ${name} to be ready...`);
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 30 * 60 * 1000; // 30 minutes
  
  while (Date.now() - startTime < timeout) {
    try {
      // Check PXC custom resource status
      const pxcResult = await execa('kubectl', ['get', 'pxc', name, '-n', ns, '-o', 'json'], { stdio: 'pipe' });
      const pxc = JSON.parse(pxcResult.stdout);
      
      const pxcCount = pxc.status?.pxc || 0;
      const proxysqlCount = pxc.status?.proxysql || 0;
      const status = pxc.status?.status || 'unknown';
      
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logInfo(`Cluster status: ${status}, PXC: ${pxcCount}/${nodes}, ProxySQL: ${proxysqlCount} (${elapsed}s elapsed)`);
      
      // Check if all PXC pods are ready
      const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster', '--no-headers'], { stdio: 'pipe' });
      const podLines = podsResult.stdout.trim().split('\n').filter(line => line.includes('pxc-cluster-pxc-db-pxc-'));
      
      if (podLines.length >= nodes) {
        const allReady = podLines.every(line => {
          const parts = line.split(/\s+/);
          const ready = parts[1];
          return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
        });
        
        if (allReady && pxcCount >= nodes && status === 'ready') {
          logSuccess(`Percona cluster ${name} is ready with ${nodes} nodes`);
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
  
  throw new Error(`Percona cluster ${name} did not become ready within 30 minutes`);
}

async function uninstall(ns: string, name: string) {
  await run('helm', ['uninstall', name, '-n', ns]);
  await run('helm', ['uninstall', 'percona-operator', '-n', ns]);
  // Delete PVCs to avoid orphaned volumes
  try { await run('kubectl', ['delete', 'pvc', '--all', '-n', ns]); } catch {}
}

async function main() {
  const argv = await yargs(hideBin(process.argv))
    .command('install', 'Install Percona operator and 3-node cluster')
    .command('uninstall', 'Uninstall Percona cluster and operator')
    .option('namespace', { type: 'string' })
    .option('name', { type: 'string' })
    .option('helmRepo', { type: 'string' })
    .option('chart', { type: 'string' })
    .option('clusterChart', { type: 'string' })
    .option('nodes', { type: 'number' })
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
  });

  try {
    await ensurePrereqs();
    if (parsed.action === 'install') {
      await ensureNamespace(parsed.namespace);
      await addRepos(parsed.helmRepo);
      
      // Create storage class first
      await createStorageClass();
      
      logInfo('Installing Percona operator...');
      await installOperator(parsed.namespace);
      
      logInfo('Installing Percona cluster...');
      await installCluster(parsed.namespace, parsed.name, parsed.nodes);
      
      // Wait for cluster to be fully ready
      await waitForClusterReady(parsed.namespace, parsed.name, parsed.nodes);
      
      logSuccess('Percona operator and cluster installed and ready.');
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


