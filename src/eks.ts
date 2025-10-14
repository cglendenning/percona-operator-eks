import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const EksArgs = z.object({
  action: z.enum(['create', 'delete']),
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
      logSuccess('EKS cluster created. Updating kubeconfig...');
      await run('aws', ['eks', 'update-kubeconfig', '--name', parsed.name, '--region', parsed.region]);
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


