#!/usr/bin/env npx tsx
/**
 * Database Emergency Diagnostic CLI
 * Detects which disaster scenario is currently occurring
 * 
 * Usage: npx tsx dr-dashboard/cli/detect-scenario.ts --namespace percona
 */

import { execa, ExecaError } from 'execa';
import chalk from 'chalk';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

// Types
interface PodStatus {
  total: number;
  running: number;
  crashloop: number;
  pending: number;
  evicted: number;
  allDown: boolean;
  oomKilled: number;
  containerErrors: string[];
}

interface QuorumStatus {
  hasQuorum: boolean;
  clusterSize: number;
  status: string;
  reachable: boolean;
}

interface NodeStatus {
  total: number;
  ready: number;
  notReady: number;
  diskPressure: number;
  memoryPressure: number;
  unreachableNodes: string[];
}

interface OperatorStatus {
  running: boolean;
  count: number;
  errors: string[];
}

interface ServiceStatus {
  hasEndpoints: boolean;
  endpointCount: number;
  proxyType: 'proxysql' | 'haproxy' | 'unknown';
}

interface PvcStatus {
  total: number;
  bound: number;
  pending: number;
  issues: string[];
  diskUsage: { name: string; usedPercent: number }[];
}

interface ReplicationStatus {
  configured: boolean;
  ioRunning: boolean;
  sqlRunning: boolean;
  secondsBehind: number | null;
  lastError: string;
}

interface CertificateStatus {
  expiringSoon: boolean;
  expired: boolean;
  errors: string[];
}

interface BackupStatus {
  lastBackupTime: string | null;
  backupsFailing: boolean;
  s3Accessible: boolean;
  errors: string[];
}

interface ScenarioMatch {
  scenario: string;
  confidence: 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'LOW';
  file: string;
  indicators: string[];
}

interface DiagnosticState {
  pods: PodStatus;
  quorum: QuorumStatus;
  nodes: NodeStatus;
  operator: OperatorStatus;
  services: ServiceStatus;
  pvcs: PvcStatus;
  replication: ReplicationStatus;
  certificates: CertificateStatus;
  backups: BackupStatus;
  apiServerWorking: boolean;
  dnsWorking: boolean;
  environment: 'eks' | 'on-prem';
}

// CLI Arguments
const argv = yargs(hideBin(process.argv))
  .option('namespace', {
    alias: 'n',
    type: 'string',
    description: 'Kubernetes namespace to inspect',
    demandOption: true,
  })
  .option('cluster-name', {
    alias: 'c',
    type: 'string',
    description: 'PXC cluster name (optional, auto-detected if not provided)',
  })
  .option('json', {
    type: 'boolean',
    description: 'Output results as JSON',
    default: false,
  })
  .option('verbose', {
    alias: 'v',
    type: 'boolean',
    description: 'Show detailed command output',
    default: false,
  })
  .check(() => {
    if (!process.env.KUBECONFIG && !process.env.HOME) {
      throw new Error('KUBECONFIG environment variable must be set');
    }
    return true;
  })
  .example('$0 --namespace percona', 'Diagnose issues in the percona namespace')
  .example('$0 -n percona -c cluster1', 'Diagnose specific cluster')
  .strict()
  .parseSync();

const NAMESPACE = argv.namespace;
const VERBOSE = argv.verbose;
const JSON_OUTPUT = argv.json;

// Utility functions
function log(message: string): void {
  if (!JSON_OUTPUT) {
    console.log(message);
  }
}

function logStep(message: string): void {
  if (!JSON_OUTPUT) {
    console.log(chalk.cyan(`  -> ${message}`));
  }
}

function logWarn(message: string): void {
  if (!JSON_OUTPUT) {
    console.log(chalk.yellow(`  [!] ${message}`));
  }
}

function logError(message: string): void {
  if (!JSON_OUTPUT) {
    console.log(chalk.red(`  [ERROR] ${message}`));
  }
}

function logSuccess(message: string): void {
  if (!JSON_OUTPUT) {
    console.log(chalk.green(`  [OK] ${message}`));
  }
}

async function runKubectl(args: string[], timeout = 30000): Promise<{ stdout: string; exitCode: number }> {
  try {
    const result = await execa('kubectl', args, { timeout, reject: false });
    if (VERBOSE && !JSON_OUTPUT) {
      console.log(chalk.gray(`    $ kubectl ${args.join(' ')}`));
      if (result.stdout) console.log(chalk.gray(result.stdout.substring(0, 500)));
    }
    return { stdout: result.stdout + (result.stderr || ''), exitCode: result.exitCode ?? 0 };
  } catch (err) {
    if ((err as ExecaError).timedOut) {
      return { stdout: 'Command timed out', exitCode: 1 };
    }
    return { stdout: String(err), exitCode: 1 };
  }
}

// Diagnostic functions
async function checkApiServer(): Promise<boolean> {
  logStep('Checking Kubernetes API server connectivity...');
  const { exitCode } = await runKubectl(['cluster-info']);
  if (exitCode === 0) {
    logSuccess('API server is responsive');
    return true;
  }
  logError('API server is not responding');
  return false;
}

async function checkDns(): Promise<boolean> {
  logStep('Checking DNS resolution...');
  const { stdout, exitCode } = await runKubectl([
    'run', 'dns-test', '--rm', '-i', '--restart=Never',
    '--image=busybox:1.28', '-n', NAMESPACE,
    '--', 'nslookup', 'kubernetes.default'
  ], 15000);
  
  // Clean up if pod wasn't deleted
  await runKubectl(['delete', 'pod', 'dns-test', '-n', NAMESPACE, '--ignore-not-found'], 5000);
  
  if (exitCode === 0 && stdout.includes('Address')) {
    logSuccess('DNS resolution working');
    return true;
  }
  logWarn('DNS resolution may have issues');
  return false;
}

async function detectEnvironment(): Promise<'eks' | 'on-prem'> {
  logStep('Detecting environment...');
  const { stdout } = await runKubectl(['config', 'current-context']);
  const isEks = stdout.toLowerCase().includes('eks') || stdout.toLowerCase().includes('aws');
  log(chalk.gray(`    Environment: ${isEks ? 'EKS' : 'On-Prem'}`));
  return isEks ? 'eks' : 'on-prem';
}

async function checkPodStatus(): Promise<PodStatus> {
  logStep(`Checking PXC pod status in namespace ${NAMESPACE}...`);
  
  const { stdout } = await runKubectl([
    'get', 'pods', '-n', NAMESPACE,
    '-l', 'app.kubernetes.io/component=pxc',
    '-o', 'json'
  ]);
  
  const result: PodStatus = {
    total: 0,
    running: 0,
    crashloop: 0,
    pending: 0,
    evicted: 0,
    allDown: false,
    oomKilled: 0,
    containerErrors: [],
  };

  try {
    const data = JSON.parse(stdout);
    const pods = data.items || [];
    result.total = pods.length;
    
    for (const pod of pods) {
      const phase = pod.status?.phase;
      
      if (phase === 'Running') {
        result.running++;
      } else if (phase === 'Pending') {
        result.pending++;
      } else if (pod.status?.reason === 'Evicted') {
        result.evicted++;
      }
      
      const containerStatuses = pod.status?.containerStatuses || [];
      for (const cs of containerStatuses) {
        const waiting = cs.state?.waiting;
        const terminated = cs.state?.terminated;
        
        if (waiting?.reason === 'CrashLoopBackOff') {
          result.crashloop++;
          result.containerErrors.push(`${pod.metadata.name}: CrashLoopBackOff`);
        }
        
        if (terminated?.reason === 'OOMKilled') {
          result.oomKilled++;
          result.containerErrors.push(`${pod.metadata.name}: OOMKilled`);
        }
        
        if (waiting?.reason && !['ContainerCreating', 'PodInitializing'].includes(waiting.reason)) {
          result.containerErrors.push(`${pod.metadata.name}: ${waiting.reason}`);
        }
      }
    }
    
    result.allDown = result.running === 0 && result.total > 0;
  } catch {
    logWarn('Could not parse pod status');
  }
  
  log(chalk.gray(`    Pods: ${result.running}/${result.total} running, ${result.crashloop} crashloop, ${result.oomKilled} OOM`));
  return result;
}

async function checkClusterQuorum(): Promise<QuorumStatus> {
  logStep('Checking Galera cluster quorum...');
  
  const result: QuorumStatus = {
    hasQuorum: false,
    clusterSize: 0,
    status: 'unknown',
    reachable: false,
  };
  
  // Get first available PXC pod
  const { stdout: podName } = await runKubectl([
    'get', 'pods', '-n', NAMESPACE,
    '-l', 'app.kubernetes.io/component=pxc',
    '-o', 'jsonpath={.items[0].metadata.name}',
    '--field-selector=status.phase=Running'
  ]);
  
  if (!podName) {
    logWarn('No running PXC pods found to check quorum');
    return result;
  }
  
  result.reachable = true;
  
  // Check cluster status
  const { stdout: statusOutput } = await runKubectl([
    'exec', '-n', NAMESPACE, podName, '--',
    'mysql', '-uroot', `-p$MYSQL_ROOT_PASSWORD`, '-N', '-e',
    "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_cluster_size');"
  ]);
  
  if (statusOutput.includes('Primary')) {
    result.hasQuorum = true;
    result.status = 'Primary';
  } else if (statusOutput.includes('non-Primary')) {
    result.status = 'non-Primary';
  }
  
  const sizeMatch = statusOutput.match(/wsrep_cluster_size\s+(\d+)/);
  if (sizeMatch) {
    result.clusterSize = parseInt(sizeMatch[1], 10);
  }
  
  log(chalk.gray(`    Cluster: ${result.clusterSize} nodes, status=${result.status}`));
  return result;
}

async function checkNodes(): Promise<NodeStatus> {
  logStep('Checking Kubernetes node status...');
  
  const result: NodeStatus = {
    total: 0,
    ready: 0,
    notReady: 0,
    diskPressure: 0,
    memoryPressure: 0,
    unreachableNodes: [],
  };
  
  const { stdout } = await runKubectl(['get', 'nodes', '-o', 'json']);
  
  try {
    const data = JSON.parse(stdout);
    const nodes = data.items || [];
    result.total = nodes.length;
    
    for (const node of nodes) {
      const conditions = node.status?.conditions || [];
      const nodeName = node.metadata?.name;
      
      let isReady = false;
      for (const cond of conditions) {
        if (cond.type === 'Ready' && cond.status === 'True') {
          isReady = true;
        }
        if (cond.type === 'DiskPressure' && cond.status === 'True') {
          result.diskPressure++;
        }
        if (cond.type === 'MemoryPressure' && cond.status === 'True') {
          result.memoryPressure++;
        }
      }
      
      if (isReady) {
        result.ready++;
      } else {
        result.notReady++;
        result.unreachableNodes.push(nodeName);
      }
    }
  } catch {
    logWarn('Could not parse node status');
  }
  
  log(chalk.gray(`    Nodes: ${result.ready}/${result.total} ready, ${result.diskPressure} disk pressure, ${result.memoryPressure} memory pressure`));
  return result;
}

async function checkOperator(): Promise<OperatorStatus> {
  logStep('Checking Percona Operator status...');
  
  const result: OperatorStatus = {
    running: false,
    count: 0,
    errors: [],
  };
  
  // Try multiple possible namespaces/labels
  const namespaces = ['percona-operator', NAMESPACE, 'default'];
  const labels = [
    'app.kubernetes.io/name=percona-xtradb-cluster-operator',
    'name=percona-xtradb-cluster-operator'
  ];
  
  for (const ns of namespaces) {
    for (const label of labels) {
      const { stdout } = await runKubectl([
        'get', 'pods', '-n', ns, '-l', label, '-o', 'json'
      ]);
      
      try {
        const data = JSON.parse(stdout);
        const pods = data.items || [];
        
        if (pods.length > 0) {
          result.count = pods.length;
          result.running = pods.some((p: { status?: { phase?: string } }) => p.status?.phase === 'Running');
          
          // Check for errors in operator logs
          if (result.running) {
            const podName = pods[0].metadata.name;
            const { stdout: logs } = await runKubectl([
              'logs', '-n', ns, podName, '--tail=50'
            ]);
            
            if (logs.includes('error') || logs.includes('Error')) {
              result.errors.push('Recent errors in operator logs');
            }
          }
          break;
        }
      } catch {
        continue;
      }
    }
    if (result.count > 0) break;
  }
  
  if (result.running) {
    logSuccess('Operator is running');
  } else {
    logWarn('Operator is not running');
  }
  
  return result;
}

async function checkServices(): Promise<ServiceStatus> {
  logStep('Checking proxy service endpoints...');
  
  const result: ServiceStatus = {
    hasEndpoints: false,
    endpointCount: 0,
    proxyType: 'unknown',
  };
  
  // Check for ProxySQL first
  let { stdout } = await runKubectl([
    'get', 'endpoints', '-n', NAMESPACE, '-l', 'app.kubernetes.io/component=proxysql', '-o', 'json'
  ]);
  
  try {
    let data = JSON.parse(stdout);
    let endpoints = data.items || [];
    
    if (endpoints.length > 0) {
      result.proxyType = 'proxysql';
      for (const ep of endpoints) {
        const addresses = ep.subsets?.flatMap((s: { addresses?: { ip: string }[] }) => s.addresses || []) || [];
        result.endpointCount += addresses.length;
      }
    } else {
      // Check for HAProxy
      ({ stdout } = await runKubectl([
        'get', 'endpoints', '-n', NAMESPACE, '-l', 'app.kubernetes.io/component=haproxy', '-o', 'json'
      ]));
      
      data = JSON.parse(stdout);
      endpoints = data.items || [];
      
      if (endpoints.length > 0) {
        result.proxyType = 'haproxy';
        for (const ep of endpoints) {
          const addresses = ep.subsets?.flatMap((s: { addresses?: { ip: string }[] }) => s.addresses || []) || [];
          result.endpointCount += addresses.length;
        }
      }
    }
    
    result.hasEndpoints = result.endpointCount > 0;
  } catch {
    logWarn('Could not parse service endpoints');
  }
  
  log(chalk.gray(`    Proxy: ${result.proxyType}, ${result.endpointCount} endpoints`));
  return result;
}

async function checkPvcs(): Promise<PvcStatus> {
  logStep('Checking PVC status and disk usage...');
  
  const result: PvcStatus = {
    total: 0,
    bound: 0,
    pending: 0,
    issues: [],
    diskUsage: [],
  };
  
  const { stdout } = await runKubectl([
    'get', 'pvc', '-n', NAMESPACE, '-o', 'json'
  ]);
  
  try {
    const data = JSON.parse(stdout);
    const pvcs = data.items || [];
    result.total = pvcs.length;
    
    for (const pvc of pvcs) {
      const phase = pvc.status?.phase;
      if (phase === 'Bound') {
        result.bound++;
      } else if (phase === 'Pending') {
        result.pending++;
        result.issues.push(`PVC ${pvc.metadata.name} is pending`);
      }
    }
  } catch {
    logWarn('Could not parse PVC status');
  }
  
  // Check disk usage on running pods
  const { stdout: podName } = await runKubectl([
    'get', 'pods', '-n', NAMESPACE,
    '-l', 'app.kubernetes.io/component=pxc',
    '-o', 'jsonpath={.items[0].metadata.name}',
    '--field-selector=status.phase=Running'
  ]);
  
  if (podName) {
    const { stdout: dfOutput } = await runKubectl([
      'exec', '-n', NAMESPACE, podName, '--',
      'df', '-h', '/var/lib/mysql'
    ]);
    
    const lines = dfOutput.split('\n');
    for (const line of lines) {
      const match = line.match(/(\d+)%\s+\/var\/lib\/mysql/);
      if (match) {
        const usedPercent = parseInt(match[1], 10);
        result.diskUsage.push({ name: podName, usedPercent });
        
        if (usedPercent > 90) {
          result.issues.push(`${podName}: Disk ${usedPercent}% full`);
        }
      }
    }
  }
  
  log(chalk.gray(`    PVCs: ${result.bound}/${result.total} bound, ${result.pending} pending`));
  return result;
}

async function checkReplication(): Promise<ReplicationStatus> {
  logStep('Checking replication status...');
  
  const result: ReplicationStatus = {
    configured: false,
    ioRunning: false,
    sqlRunning: false,
    secondsBehind: null,
    lastError: '',
  };
  
  const { stdout: podName } = await runKubectl([
    'get', 'pods', '-n', NAMESPACE,
    '-l', 'app.kubernetes.io/component=pxc',
    '-o', 'jsonpath={.items[0].metadata.name}',
    '--field-selector=status.phase=Running'
  ]);
  
  if (!podName) return result;
  
  const { stdout } = await runKubectl([
    'exec', '-n', NAMESPACE, podName, '--',
    'mysql', '-uroot', `-p$MYSQL_ROOT_PASSWORD`, '-e',
    'SHOW REPLICA STATUS\\G'
  ]);
  
  if (stdout.includes('Replica_IO_Running') || stdout.includes('Slave_IO_Running')) {
    result.configured = true;
    result.ioRunning = stdout.includes('Replica_IO_Running: Yes') || stdout.includes('Slave_IO_Running: Yes');
    result.sqlRunning = stdout.includes('Replica_SQL_Running: Yes') || stdout.includes('Slave_SQL_Running: Yes');
    
    const lagMatch = stdout.match(/Seconds_Behind_(?:Source|Master):\s+(\d+)/);
    if (lagMatch) {
      result.secondsBehind = parseInt(lagMatch[1], 10);
    }
    
    const errorMatch = stdout.match(/Last_(?:IO_)?Error:\s+(.+)/);
    if (errorMatch && errorMatch[1].trim()) {
      result.lastError = errorMatch[1].trim();
    }
  }
  
  if (result.configured) {
    log(chalk.gray(`    Replication: IO=${result.ioRunning}, SQL=${result.sqlRunning}, Lag=${result.secondsBehind}s`));
  } else {
    log(chalk.gray('    Replication: Not configured'));
  }
  
  return result;
}

async function checkCertificates(): Promise<CertificateStatus> {
  logStep('Checking certificate status...');
  
  const result: CertificateStatus = {
    expiringSoon: false,
    expired: false,
    errors: [],
  };
  
  // Check TLS secrets
  const { stdout } = await runKubectl([
    'get', 'secrets', '-n', NAMESPACE,
    '-o', 'json'
  ]);
  
  try {
    const data = JSON.parse(stdout);
    const secrets = data.items || [];
    
    for (const secret of secrets) {
      if (secret.type === 'kubernetes.io/tls' || secret.metadata?.name?.includes('ssl')) {
        const tlsCrt = secret.data?.['tls.crt'];
        if (tlsCrt) {
          // Decode and check expiration via openssl in a pod
          const { stdout: certInfo } = await runKubectl([
            'get', 'secret', '-n', NAMESPACE, secret.metadata.name,
            '-o', 'jsonpath={.data.tls\\.crt}'
          ]);
          
          if (certInfo) {
            // Just note we found TLS secrets, actual expiration check would need openssl
            log(chalk.gray(`    Found TLS secret: ${secret.metadata.name}`));
          }
        }
      }
    }
  } catch {
    logWarn('Could not check certificates');
  }
  
  return result;
}

async function checkBackups(): Promise<BackupStatus> {
  logStep('Checking backup status...');
  
  const result: BackupStatus = {
    lastBackupTime: null,
    backupsFailing: false,
    s3Accessible: true,
    errors: [],
  };
  
  // Check for backup CRs
  const { stdout } = await runKubectl([
    'get', 'perconaxtradbclusterbackup', '-n', NAMESPACE, '-o', 'json'
  ]);
  
  try {
    const data = JSON.parse(stdout);
    const backups = data.items || [];
    
    if (backups.length > 0) {
      // Sort by creation timestamp
      backups.sort((a: { metadata?: { creationTimestamp?: string } }, b: { metadata?: { creationTimestamp?: string } }) => {
        const aTime = new Date(a.metadata?.creationTimestamp || 0).getTime();
        const bTime = new Date(b.metadata?.creationTimestamp || 0).getTime();
        return bTime - aTime;
      });
      
      const latest = backups[0];
      result.lastBackupTime = latest.metadata?.creationTimestamp;
      
      if (latest.status?.state === 'Failed') {
        result.backupsFailing = true;
        result.errors.push(`Latest backup failed: ${latest.status?.error || 'unknown error'}`);
      }
    }
    
    log(chalk.gray(`    Last backup: ${result.lastBackupTime || 'none found'}`));
  } catch {
    // No backup CRDs or not installed
    log(chalk.gray('    Backups: No backup resources found'));
  }
  
  return result;
}

// Scenario detection
function detectScenarios(state: DiagnosticState): ScenarioMatch[] {
  const matches: ScenarioMatch[] = [];
  
  // API server down - most critical
  if (!state.apiServerWorking) {
    matches.push({
      scenario: 'Kubernetes control plane outage (API server down)',
      confidence: 'CRITICAL',
      file: 'kubernetes-control-plane-outage-api-server-down.md',
      indicators: ['API server not responding to kubectl commands'],
    });
    return matches; // Can't check anything else
  }
  
  // All pods down - site outage
  if (state.pods.allDown) {
    matches.push({
      scenario: 'Primary DC power/cooling outage (site down)',
      confidence: 'CRITICAL',
      file: 'primary-dc-power-cooling-outage-site-down.md',
      indicators: [`All ${state.pods.total} PXC pods are down`],
    });
  }
  
  // Quorum loss
  if (!state.quorum.hasQuorum && state.quorum.reachable) {
    matches.push({
      scenario: 'Cluster loses quorum (multiple PXC pods down)',
      confidence: 'CRITICAL',
      file: 'cluster-loses-quorum.md',
      indicators: [
        `Cluster status: ${state.quorum.status}`,
        `Cluster size: ${state.quorum.clusterSize}`,
      ],
    });
  }
  
  // OOM kills
  if (state.pods.oomKilled > 0) {
    matches.push({
      scenario: 'Memory exhaustion causing OOM kills',
      confidence: 'HIGH',
      file: 'memory-exhaustion-causing-oom-kills-out-of-memory.md',
      indicators: state.pods.containerErrors.filter(e => e.includes('OOM')),
    });
  }
  
  // Single pod failure with CrashLoopBackOff
  if (state.pods.crashloop >= 1 && state.quorum.hasQuorum && state.pods.running >= 2) {
    matches.push({
      scenario: 'Single MySQL pod failure (container crash / OOM)',
      confidence: 'HIGH',
      file: 'single-mysql-pod-failure.md',
      indicators: [
        `${state.pods.crashloop} pod(s) in CrashLoopBackOff`,
        ...state.pods.containerErrors.filter(e => e.includes('CrashLoopBackOff')),
      ],
    });
  }
  
  // Node failure
  if (state.nodes.notReady >= 1) {
    matches.push({
      scenario: 'Kubernetes worker node failure (VM host crash)',
      confidence: 'HIGH',
      file: 'kubernetes-worker-node-failure.md',
      indicators: [
        `${state.nodes.notReady} node(s) not ready`,
        ...state.nodes.unreachableNodes.map(n => `Node ${n} unreachable`),
      ],
    });
  }
  
  // Disk pressure on nodes
  if (state.nodes.diskPressure > 0) {
    matches.push({
      scenario: 'Database disk space exhaustion (data directory)',
      confidence: 'HIGH',
      file: 'database-disk-space-exhaustion.md',
      indicators: [`${state.nodes.diskPressure} node(s) with disk pressure`],
    });
  }
  
  // Memory pressure on nodes
  if (state.nodes.memoryPressure > 0) {
    matches.push({
      scenario: 'Memory exhaustion causing OOM kills',
      confidence: 'MEDIUM',
      file: 'memory-exhaustion-causing-oom-kills-out-of-memory.md',
      indicators: [`${state.nodes.memoryPressure} node(s) with memory pressure`],
    });
  }
  
  // PVC disk usage issues
  const highDiskUsage = state.pvcs.diskUsage.filter(d => d.usedPercent > 85);
  if (highDiskUsage.length > 0) {
    matches.push({
      scenario: 'Database disk space exhaustion (data directory)',
      confidence: highDiskUsage.some(d => d.usedPercent > 95) ? 'CRITICAL' : 'HIGH',
      file: 'database-disk-space-exhaustion.md',
      indicators: highDiskUsage.map(d => `${d.name}: ${d.usedPercent}% disk used`),
    });
  }
  
  // PVC pending
  if (state.pvcs.pending > 0) {
    matches.push({
      scenario: 'Storage PVC corruption or provisioning failure',
      confidence: 'HIGH',
      file: 'storage-pvc-corruption.md',
      indicators: state.pvcs.issues,
    });
  }
  
  // Operator not running
  if (!state.operator.running && state.pods.total > 0) {
    matches.push({
      scenario: 'Percona Operator / CRD misconfiguration (bad rollout)',
      confidence: 'MEDIUM',
      file: 'percona-operator-crd-misconfiguration.md',
      indicators: ['Percona Operator is not running'],
    });
  }
  
  // Service/endpoint issues
  if (!state.services.hasEndpoints && state.pods.running > 0) {
    matches.push({
      scenario: 'Ingress/VIP failure (HAProxy/ProxySQL service unreachable)',
      confidence: 'HIGH',
      file: 'ingress-vip-failure.md',
      indicators: [
        `${state.services.proxyType} has no healthy endpoints`,
        `${state.pods.running} PXC pods running but not in endpoint list`,
      ],
    });
  }
  
  // DNS issues
  if (!state.dnsWorking) {
    matches.push({
      scenario: 'DNS resolution failure (internal or external)',
      confidence: 'MEDIUM',
      file: 'dns-resolution-failure-internal-or-external.md',
      indicators: ['DNS resolution test failed'],
    });
  }
  
  // Replication issues
  if (state.replication.configured) {
    if (!state.replication.ioRunning || !state.replication.sqlRunning) {
      matches.push({
        scenario: 'Both DCs up but replication stops (broken channel)',
        confidence: 'HIGH',
        file: 'both-dcs-up-but-replication-stops-broken-channel.md',
        indicators: [
          `IO thread: ${state.replication.ioRunning ? 'running' : 'stopped'}`,
          `SQL thread: ${state.replication.sqlRunning ? 'running' : 'stopped'}`,
          state.replication.lastError,
        ].filter(Boolean),
      });
    } else if (state.replication.secondsBehind !== null && state.replication.secondsBehind > 300) {
      matches.push({
        scenario: 'Primary DC network partition from Secondary (WAN cut)',
        confidence: 'MEDIUM',
        file: 'primary-dc-network-partition-from-secondary-wan-cut.md',
        indicators: [`Replication lag: ${state.replication.secondsBehind} seconds behind`],
      });
    }
  }
  
  // Backup failures
  if (state.backups.backupsFailing) {
    matches.push({
      scenario: 'Backups complete but are non-restorable (silent failure)',
      confidence: 'MEDIUM',
      file: 'backups-complete-but-are-non-restorable-silent-failure.md',
      indicators: state.backups.errors,
    });
  }
  
  // Certificate issues
  if (state.certificates.expired) {
    matches.push({
      scenario: 'Certificate expiration or revocation causing connection failures',
      confidence: 'HIGH',
      file: 'certificate-expiration-or-revocation-causing-connection-failures.md',
      indicators: state.certificates.errors,
    });
  } else if (state.certificates.expiringSoon) {
    matches.push({
      scenario: 'Certificate expiration or revocation causing connection failures',
      confidence: 'LOW',
      file: 'certificate-expiration-or-revocation-causing-connection-failures.md',
      indicators: ['Certificates expiring soon'],
    });
  }
  
  return matches;
}

// Main execution
async function main(): Promise<void> {
  if (!JSON_OUTPUT) {
    console.log();
    console.log(chalk.red.bold('DATABASE EMERGENCY DIAGNOSTIC'));
    console.log(chalk.red('═'.repeat(50)));
    console.log();
    console.log(chalk.cyan(`Namespace: ${NAMESPACE}`));
    console.log();
  }
  
  // Check KUBECONFIG
  const kubeconfigPath = process.env.KUBECONFIG || `${process.env.HOME}/.kube/config`;
  logStep(`Using KUBECONFIG: ${kubeconfigPath}`);
  
  // Run all diagnostics
  log(chalk.yellow.bold('\n[1/10] Infrastructure Checks'));
  const apiServerWorking = await checkApiServer();
  
  if (!apiServerWorking) {
    const results: ScenarioMatch[] = [{
      scenario: 'Kubernetes control plane outage (API server down)',
      confidence: 'CRITICAL',
      file: 'kubernetes-control-plane-outage-api-server-down.md',
      indicators: ['API server not responding'],
    }];
    
    if (JSON_OUTPUT) {
      console.log(JSON.stringify({ scenarios: results, state: { apiServerWorking: false } }, null, 2));
    } else {
      printResults(results, 'eks');
    }
    process.exit(1);
  }
  
  const environment = await detectEnvironment();
  const dnsWorking = await checkDns();
  
  log(chalk.yellow.bold('\n[2/10] Pod Status'));
  const pods = await checkPodStatus();
  
  log(chalk.yellow.bold('\n[3/10] Cluster Quorum'));
  const quorum = await checkClusterQuorum();
  
  log(chalk.yellow.bold('\n[4/10] Kubernetes Nodes'));
  const nodes = await checkNodes();
  
  log(chalk.yellow.bold('\n[5/10] Percona Operator'));
  const operator = await checkOperator();
  
  log(chalk.yellow.bold('\n[6/10] Service Endpoints'));
  const services = await checkServices();
  
  log(chalk.yellow.bold('\n[7/10] Storage (PVCs)'));
  const pvcs = await checkPvcs();
  
  log(chalk.yellow.bold('\n[8/10] Replication'));
  const replication = await checkReplication();
  
  log(chalk.yellow.bold('\n[9/10] Certificates'));
  const certificates = await checkCertificates();
  
  log(chalk.yellow.bold('\n[10/10] Backups'));
  const backups = await checkBackups();
  
  // Build state
  const state: DiagnosticState = {
    pods,
    quorum,
    nodes,
    operator,
    services,
    pvcs,
    replication,
    certificates,
    backups,
    apiServerWorking,
    dnsWorking,
    environment,
  };
  
  // Detect scenarios
  const scenarios = detectScenarios(state);
  
  if (JSON_OUTPUT) {
    console.log(JSON.stringify({ scenarios, state }, null, 2));
  } else {
    printResults(scenarios, environment);
  }
  
  process.exit(scenarios.length > 0 ? 1 : 0);
}

function printResults(scenarios: ScenarioMatch[], environment: 'eks' | 'on-prem'): void {
  console.log();
  console.log(chalk.yellow.bold('═'.repeat(50)));
  console.log(chalk.yellow.bold('DIAGNOSTIC RESULTS'));
  console.log(chalk.yellow.bold('═'.repeat(50)));
  console.log();
  
  if (scenarios.length === 0) {
    console.log(chalk.green.bold('No critical issues detected'));
    console.log();
    console.log('If you are experiencing issues, check:');
    console.log('  - Application logs');
    console.log('  - Network connectivity');
    console.log('  - Authentication/credentials');
    console.log('  - Recent changes or deployments');
    return;
  }
  
  console.log(chalk.red.bold(`DETECTED ${scenarios.length} POTENTIAL SCENARIO(S):\n`));
  
  // Sort by confidence
  const order = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3 };
  scenarios.sort((a, b) => order[a.confidence] - order[b.confidence]);
  
  for (let i = 0; i < scenarios.length; i++) {
    const s = scenarios[i];
    const color = s.confidence === 'CRITICAL' ? chalk.red :
                  s.confidence === 'HIGH' ? chalk.yellow :
                  chalk.cyan;
    
    console.log(color.bold(`${i + 1}. [${s.confidence}] ${s.scenario}`));
    console.log(chalk.gray(`   Recovery Doc: recovery_processes/${environment}/${s.file}`));
    
    if (s.indicators.length > 0) {
      console.log(chalk.gray('   Indicators:'));
      for (const ind of s.indicators) {
        console.log(chalk.gray(`     - ${ind}`));
      }
    }
    console.log();
  }
  
  console.log(chalk.cyan.bold('NEXT STEPS:'));
  console.log(`1. Review the recovery documentation in dr-dashboard/recovery_processes/${environment}/`);
  console.log('2. Open the Database Emergency Kit dashboard: http://localhost:8080');
  console.log(`3. Switch to '${environment.toUpperCase()}' environment in the dashboard`);
  console.log('4. Follow the recovery steps for the matching scenario(s)');
  console.log('5. Contact on-call DBA if needed');
  console.log();
}

main().catch((err) => {
  if (!JSON_OUTPUT) {
    console.error(chalk.red(`\nFatal error: ${err instanceof Error ? err.message : String(err)}`));
  }
  process.exit(1);
});

