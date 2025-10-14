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
  enabled: true
`;}

async function installCluster(ns: string, name: string, nodes: number) {
  const values = clusterValues(nodes);
  const { execa } = await import('execa');
  const proc = execa('helm', ['upgrade', '--install', name, 'percona/pxc-db', '-n', ns, '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  proc.stdin?.write(values);
  proc.stdin?.end();
  await proc;
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
      logInfo('Installing Percona operator...');
      await installOperator(parsed.namespace);
      logInfo('Installing Percona cluster...');
      await installCluster(parsed.namespace, parsed.name, parsed.nodes);
      logSuccess('Percona operator and cluster installed.');
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


