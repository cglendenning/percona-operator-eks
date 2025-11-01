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

async function validateEksCluster(ns: string, nodes: number) {
  logInfo('=== Validating EKS cluster state for Percona installation ===');
  const { execa } = await import('execa');
  
  let validationErrors: string[] = [];
  let validationWarnings: string[] = [];
  
  try {
    // 1. Check kubectl connectivity
    logInfo('Checking kubectl connectivity...');
    await run('kubectl', ['cluster-info'], { stdio: 'pipe' });
    logSuccess('✓ kubectl connectivity verified');
  } catch (error) {
    validationErrors.push('Cannot connect to Kubernetes cluster via kubectl');
  }
  
  try {
    // 2. Check cluster version and compatibility
    logInfo('Checking Kubernetes version...');
    
    // Try different kubectl version command formats
    let versionResult;
    let versionOutput = '';
    
    try {
      // Try newer kubectl format first
      versionResult = await execa('kubectl', ['version', '--output=yaml'], { stdio: 'pipe' });
      versionOutput = versionResult.stdout;
      logInfo(`Kubectl version output (yaml): ${versionOutput}`);
    } catch (yamlError) {
      try {
        // Try older format
        versionResult = await execa('kubectl', ['version', '--short'], { stdio: 'pipe' });
        versionOutput = versionResult.stdout;
        logInfo(`Kubectl version output (short): ${versionOutput}`);
      } catch (shortError) {
        // Try without any flags
        versionResult = await execa('kubectl', ['version'], { stdio: 'pipe' });
        versionOutput = versionResult.stdout;
        logInfo(`Kubectl version output (default): ${versionOutput}`);
      }
    }
    
    // Try multiple patterns to match version
    let versionMatch = versionOutput.match(/Server Version: v(\d+\.\d+)/);
    if (!versionMatch) {
      versionMatch = versionOutput.match(/serverVersion:\s+gitVersion:\s+v(\d+\.\d+)/);
    }
    if (!versionMatch) {
      versionMatch = versionOutput.match(/v(\d+\.\d+)/);
    }
    if (!versionMatch) {
      // Try parsing the full version string
      const fullVersionMatch = versionOutput.match(/Server Version: v(\d+\.\d+\.\d+)/);
      if (fullVersionMatch) {
        versionMatch = [fullVersionMatch[0], fullVersionMatch[1].split('.').slice(0, 2).join('.')];
      }
    }
    if (!versionMatch) {
      // Try YAML format
      const yamlVersionMatch = versionOutput.match(/serverVersion:\s+gitVersion:\s+v(\d+\.\d+\.\d+)/);
      if (yamlVersionMatch) {
        versionMatch = [yamlVersionMatch[0], yamlVersionMatch[1].split('.').slice(0, 2).join('.')];
      }
    }
    
    if (versionMatch) {
      const majorMinor = versionMatch[1];
      const [major, minor] = majorMinor.split('.').map(Number);
      
      logInfo(`Detected Kubernetes version: ${majorMinor} (major: ${major}, minor: ${minor})`);
      
      // Percona Operator requires Kubernetes 1.24+ (based on compatibility matrix)
      if (major < 1 || (major === 1 && minor < 24)) {
        validationErrors.push(`Kubernetes version ${majorMinor} is too old. Percona Operator requires 1.24+`);
      } else {
        logSuccess(`✓ Kubernetes version ${majorMinor} is compatible`);
      }
    } else {
      logWarn(`Could not parse Kubernetes version from: ${versionResult.stdout}`);
      
      // Fallback: try to get version from cluster info
      try {
        logInfo('Trying fallback method to get Kubernetes version...');
        const clusterInfoResult = await execa('kubectl', ['cluster-info'], { stdio: 'pipe' });
        logInfo(`Cluster info output: ${clusterInfoResult.stdout}`);
        
        // Look for version in cluster info
        const clusterVersionMatch = clusterInfoResult.stdout.match(/v(\d+\.\d+)/);
        if (clusterVersionMatch) {
          const majorMinor = clusterVersionMatch[1];
          const [major, minor] = majorMinor.split('.').map(Number);
          
          logInfo(`Detected Kubernetes version (fallback): ${majorMinor} (major: ${major}, minor: ${minor})`);
          
          if (major < 1 || (major === 1 && minor < 24)) {
            validationErrors.push(`Kubernetes version ${majorMinor} is too old. Percona Operator requires 1.24+`);
          } else {
            logSuccess(`✓ Kubernetes version ${majorMinor} is compatible (detected via fallback)`);
          }
        } else {
          validationWarnings.push('Could not determine Kubernetes version from kubectl output or cluster info');
        }
      } catch (fallbackError) {
        logWarn(`Fallback version check also failed: ${fallbackError}`);
        validationWarnings.push('Could not determine Kubernetes version from any method');
      }
    }
  } catch (error) {
    logWarn(`Error running kubectl version: ${error}`);
    validationWarnings.push(`Could not check Kubernetes version: ${error.message || error}`);
  }
  
  try {
    // 3. Check available nodes and resources
    logInfo('Checking cluster nodes and resources...');
    const nodesResult = await execa('kubectl', ['get', 'nodes', '-o', 'json'], { stdio: 'pipe' });
    const nodesData = JSON.parse(nodesResult.stdout);
    
    if (!nodesData.items || nodesData.items.length === 0) {
      validationErrors.push('No nodes found in the cluster');
    } else {
      const readyNodes = nodesData.items.filter((node: any) => 
        node.status.conditions?.some((c: any) => c.type === 'Ready' && c.status === 'True')
      );
      
      logInfo(`Found ${readyNodes.length}/${nodesData.items.length} ready nodes`);
      
      if (readyNodes.length < nodes) {
        validationWarnings.push(`Only ${readyNodes.length} ready nodes found. Expected ${nodes} nodes for the Percona cluster`);
      }
      
      // Check node resources
      let totalCpu = 0;
      let totalMemory = 0;
      
      readyNodes.forEach((node: any) => {
        const cpu = node.status.allocatable?.['cpu'] || '0';
        const memory = node.status.allocatable?.['memory'] || '0';
        
        // Debug: log the actual values
        logInfo(`Node ${node.metadata.name}: CPU=${cpu}, Memory=${memory}`);
        
        // Convert CPU (e.g., "2" or "2000m" to millicores)
        const cpuMillicores = cpu.endsWith('m') ? parseInt(cpu) : parseInt(cpu) * 1000;
        totalCpu += cpuMillicores;
        
        // Convert memory (e.g., "8Gi" to bytes) - handle more formats
        let memoryBytes = 0;
        if (memory.endsWith('Gi')) {
          memoryBytes = parseInt(memory) * 1024 * 1024 * 1024;
        } else if (memory.endsWith('Mi')) {
          memoryBytes = parseInt(memory) * 1024 * 1024;
        } else if (memory.endsWith('Ki')) {
          memoryBytes = parseInt(memory) * 1024;
        } else if (memory.endsWith('G')) {
          memoryBytes = parseInt(memory) * 1000 * 1000 * 1000;
        } else if (memory.endsWith('M')) {
          memoryBytes = parseInt(memory) * 1000 * 1000;
        } else if (memory.endsWith('K')) {
          memoryBytes = parseInt(memory) * 1000;
        } else {
          // Try to parse as raw bytes
          memoryBytes = parseInt(memory) || 0;
        }
        
        totalMemory += memoryBytes;
        logInfo(`  Converted: CPU=${cpuMillicores}mc, Memory=${memoryBytes} bytes (${Math.round(memoryBytes/1024/1024/1024)}GB)`);
      });
      
      // Percona needs ~1 CPU core and ~2GB RAM per node (conservative estimate)
      // Each node runs: PXC pod (~500m CPU, 1GB RAM) + ProxySQL pod (~200m CPU, 512MB RAM) + system overhead
      const minCpuPerNode = 1000; // 1 core per node in millicores
      const minMemoryPerNode = 2 * 1024 * 1024 * 1024; // 2GB per node in bytes
      const minCpu = minCpuPerNode * nodes;
      const minMemory = minMemoryPerNode * nodes;
      
      if (totalCpu < minCpu) {
        validationWarnings.push(`Total CPU capacity (${Math.round(totalCpu/1000)} cores) may be insufficient for ${nodes}-node Percona cluster (minimum ${nodes} cores recommended)`);
      }
      
      if (totalMemory < minMemory) {
        validationWarnings.push(`Total memory capacity (${Math.round(totalMemory/1024/1024/1024)}GB) may be insufficient for ${nodes}-node Percona cluster (minimum ${nodes * 2}GB recommended)`);
      }
      
              logSuccess(`✓ Cluster has ${readyNodes.length} nodes with ${Math.round(totalCpu/1000)} CPU cores and ${Math.round(totalMemory/1024/1024/1024)}GB memory`);
              
              // Check for multi-AZ deployment
              const nodeZones = new Set();
              logInfo('=== AZ Detection Debug ===');
              logInfo(`Checking ${readyNodes.length} ready nodes for availability zone distribution...`);
              
              readyNodes.forEach((node: any, index: number) => {
                const zone = node.metadata.labels?.['topology.kubernetes.io/zone'] || 
                            node.metadata.labels?.['failure-domain.beta.kubernetes.io/zone'];
                logInfo(`Node ${index + 1}: ${node.metadata.name}`);
                logInfo(`  - topology.kubernetes.io/zone: ${node.metadata.labels?.['topology.kubernetes.io/zone'] || 'not found'}`);
                logInfo(`  - failure-domain.beta.kubernetes.io/zone: ${node.metadata.labels?.['failure-domain.beta.kubernetes.io/zone'] || 'not found'}`);
                logInfo(`  - Detected zone: ${zone || 'none'}`);
                
                if (zone) {
                  nodeZones.add(zone);
                  logInfo(`  ✓ Added to zones set: ${zone}`);
                } else {
                  logInfo(`  ⚠️  No zone label found for this node`);
                }
              });
              
              logInfo(`=== AZ Detection Results ===`);
              logInfo(`Total unique zones detected: ${nodeZones.size}`);
              logInfo(`Zones found: [${Array.from(nodeZones).join(', ')}]`);
              
              if (nodeZones.size >= 2) {
                logSuccess(`✓ Multi-AZ deployment detected: ${nodeZones.size} availability zones (${Array.from(nodeZones).join(', ')})`);
              } else if (nodeZones.size === 1) {
                validationErrors.push(`❌ FATAL: Single AZ deployment detected (${Array.from(nodeZones)[0]}). Percona requires multi-AZ deployment for high availability. Please recreate your EKS cluster with nodes across multiple availability zones.`);
              } else {
                validationErrors.push('❌ FATAL: Could not determine availability zones for nodes. Multi-AZ deployment is required for high availability.');
              }
            }
          } catch (error) {
            validationErrors.push(`Failed to check cluster nodes: ${error}`);
          }
  
  try {
    // 4. Check storage classes
    logInfo('Checking storage classes...');
    const scResult = await execa('kubectl', ['get', 'storageclass', '-o', 'json'], { stdio: 'pipe' });
    const scData = JSON.parse(scResult.stdout);
    
    // Check for EBS storage classes (gp2 is EKS default, gp3 is preferred)
    const ebsStorageClass = scData.items?.find((sc: any) => 
      sc.provisioner === 'kubernetes.io/aws-ebs' || sc.provisioner === 'ebs.csi.aws.com'
    );
    
    if (!ebsStorageClass) {
      validationWarnings.push('No EBS storage class found. Storage provisioning may fail.');
    } else {
      logSuccess(`✓ EBS storage class found: ${ebsStorageClass.metadata.name} (provisioner: ${ebsStorageClass.provisioner})`);
      
      // Prefer gp3 but accept gp2
      if (ebsStorageClass.metadata.name !== 'gp3' && ebsStorageClass.metadata.name !== 'gp2') {
        logInfo(`  Note: Using ${ebsStorageClass.metadata.name} storage class. Consider using gp3 for better performance/cost.`);
      }
    }
    
    // Check if EBS CSI driver is running
    try {
      const ebsCsiResult = await execa('kubectl', ['get', 'pods', '-n', 'kube-system', '-l', 'app=ebs-csi-controller', '--no-headers'], { stdio: 'pipe' });
      const ebsCsiPods = ebsCsiResult.stdout.trim().split('\n').filter(line => line.trim());
      
      if (ebsCsiPods.length === 0) {
        validationWarnings.push('EBS CSI driver pods not found. Storage provisioning may fail.');
      } else {
        const readyPods = ebsCsiPods.filter(line => line.includes('Running'));
        if (readyPods.length === 0) {
          validationWarnings.push('EBS CSI driver pods are not running. Storage provisioning may fail.');
        } else {
          logSuccess('✓ EBS CSI driver is running');
        }
      }
    } catch (error) {
      validationWarnings.push('Could not check EBS CSI driver status');
    }
  } catch (error) {
    validationWarnings.push(`Failed to check storage classes: ${error}`);
  }
  
  // DNS resolution test moved to after namespace creation
  
  try {
    // 6. Check IAM roles and permissions
    logInfo('Checking IAM roles and permissions...');
    
    // First create the namespace if it doesn't exist
    try {
      await run('kubectl', ['create', 'namespace', ns], { stdio: 'pipe' });
      logInfo(`Created namespace ${ns} for validation`);
    } catch (error) {
      if (error.toString().includes('already exists')) {
        logInfo(`Namespace ${ns} already exists`);
      } else {
        validationWarnings.push(`Could not create namespace ${ns}: ${error}`);
      }
    }
    
    // Check DNS resolution now that namespace exists
    try {
      logInfo('Checking DNS resolution...');
      const dnsTestPod = `apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: ${ns}
spec:
  containers:
  - name: dns-test
    image: busybox:1.35
    command: ['nslookup', 'kubernetes.default.svc.cluster.local']
  restartPolicy: Never`;
      
      const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'pipe', 'pipe'] });
      proc.stdin?.write(dnsTestPod);
      proc.stdin?.end();
      await proc;
      
      // Wait for pod to complete
      await new Promise(resolve => setTimeout(resolve, 10000));
      
      try {
        const dnsResult = await execa('kubectl', ['logs', 'dns-test', '-n', ns], { stdio: 'pipe' });
        if (dnsResult.stdout.includes('kubernetes.default.svc.cluster.local')) {
          logSuccess('✓ DNS resolution working');
        } else {
          validationWarnings.push('DNS resolution may have issues');
        }
      } catch (error) {
        validationWarnings.push('Could not verify DNS resolution');
      } finally {
        // Clean up test pod
        try {
          await run('kubectl', ['delete', 'pod', 'dns-test', '-n', ns], { stdio: 'pipe' });
        } catch (error) {
          // Ignore cleanup errors
        }
      }
    } catch (error) {
      validationWarnings.push(`Failed to test DNS resolution: ${error}`);
    }
    
    // Check if we can create secrets (needed for S3 credentials)
    try {
      const testSecret = `apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: ${ns}
type: Opaque
data:
  test: dGVzdA==`;
      
      const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'pipe', 'pipe'] });
      proc.stdin?.write(testSecret);
      proc.stdin?.end();
      await proc;
      
      await run('kubectl', ['delete', 'secret', 'test-secret', '-n', ns], { stdio: 'pipe' });
      logSuccess('✓ Can create secrets in namespace');
    } catch (error) {
      validationErrors.push('Cannot create secrets in namespace - check IAM permissions');
    }
    
    // Check if we can create StatefulSets (needed for Percona)
    try {
      const testSts = `apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: test-sts
  namespace: ${ns}
spec:
  serviceName: test-service
  replicas: 0
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: test
        image: busybox:1.35
        command: ['sleep', '3600']`;
        
      const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'pipe', 'pipe'] });
      proc.stdin?.write(testSts);
      proc.stdin?.end();
      await proc;
      
      await run('kubectl', ['delete', 'statefulset', 'test-sts', '-n', ns], { stdio: 'pipe' });
      logSuccess('✓ Can create StatefulSets in namespace');
    } catch (error) {
      validationErrors.push('Cannot create StatefulSets in namespace - check IAM permissions');
    }
  } catch (error) {
    validationWarnings.push(`Failed to check IAM permissions: ${error}`);
  }
  
  try {
    // 7. Check for existing Percona resources
    logInfo('Checking for existing Percona resources...');
    
    const existingPxc = await execa('kubectl', ['get', 'pxc', '-n', ns, '--no-headers'], { stdio: 'pipe' });
    if (existingPxc.stdout.trim()) {
      validationWarnings.push('Existing PXC resources found in namespace. Installation may conflict.');
    }
    
    const existingSts = await execa('kubectl', ['get', 'statefulset', '-n', ns, '--no-headers'], { stdio: 'pipe' });
    if (existingSts.stdout.trim()) {
      validationWarnings.push('Existing StatefulSets found in namespace. Installation may conflict.');
    }
    
    logSuccess('✓ No conflicting Percona resources found');
  } catch (error) {
    // This is expected if no resources exist
    logSuccess('✓ No existing Percona resources found');
  }
  
  // 8. Summary
  logInfo('=== Validation Summary ===');
  
  if (validationErrors.length > 0) {
    logError('❌ Validation failed with errors:');
    validationErrors.forEach(error => logError(`  - ${error}`));
    throw new Error(`EKS cluster validation failed: ${validationErrors.join(', ')}`);
  }
  
  if (validationWarnings.length > 0) {
    logWarn('⚠️  Validation completed with warnings:');
    validationWarnings.forEach(warning => logWarn(`  - ${warning}`));
  }
  
  if (validationErrors.length === 0 && validationWarnings.length === 0) {
    logSuccess('✅ EKS cluster validation passed - ready for Percona installation');
  } else if (validationErrors.length === 0) {
    logSuccess('✅ EKS cluster validation passed with warnings - proceeding with installation');
  }
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
    await run('helm', ['repo', 'add', 'percona', repoUrl], { stdio: 'pipe' });
  } catch (err) {
    // Repo already exists, that's fine
    logInfo('Percona repo already exists, continuing...');
  }
  await run('helm', ['repo', 'update']);
}

async function installOperator(ns: string) {
  logInfo('Installing Percona operator via Helm...');
  try {
    await run('helm', ['upgrade', '--install', 'percona-operator', 'percona/pxc-operator', '-n', ns]);
    logSuccess('Percona operator Helm chart installed successfully');
  } catch (error) {
    logError(`Failed to install Percona operator: ${error}`);
    throw error;
  }
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
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - pxc
        topologyKey: topology.kubernetes.io/zone
  podDisruptionBudget:
    maxUnavailable: 1
haproxy:
  enabled: false
proxysql:
  enabled: true
  size: ${nodes}
  image: percona/proxysql2:2.7.3
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - proxysql
        topologyKey: topology.kubernetes.io/zone
  podDisruptionBudget:
    maxUnavailable: 1
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
    minio-backup:
      type: s3
      s3:
        bucket: percona-backups
        region: us-east-1
        endpoint: http://minio.minio.svc.cluster.local:9000
        credentialsSecret: percona-backup-minio-credentials
  schedule:
    - name: "daily-backup"
      schedule: "0 2 * * *"
      retention:
        type: "count"
        count: 7
        deleteFromStorage: true
      storageName: minio-backup
    - name: "weekly-backup"
      schedule: "0 1 * * 0"
      retention:
        type: "count"
        count: 4
        deleteFromStorage: true
      storageName: minio-backup
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

async function installMinIO(ns: string) {
  logInfo('Installing MinIO for on-premises backup storage...');
  const { execa } = await import('execa');
  
  try {
    // Check if MinIO Helm repo exists, add if not
    try {
      await run('helm', ['repo', 'list'], { stdio: 'pipe' });
      const repoListResult = await execa('helm', ['repo', 'list'], { stdio: 'pipe' });
      if (!repoListResult.stdout.includes('minio')) {
        await run('helm', ['repo', 'add', 'minio', 'https://charts.min.io/']);
        await run('helm', ['repo', 'update']);
        logInfo('Added MinIO Helm repository');
      }
    } catch (error) {
      // Add repo if it doesn't exist
      await run('helm', ['repo', 'add', 'minio', 'https://charts.min.io/']);
      await run('helm', ['repo', 'update']);
      logInfo('Added MinIO Helm repository');
    }
    
    // Create MinIO namespace if it doesn't exist
    try {
      await run('kubectl', ['create', 'namespace', 'minio'], { stdio: 'pipe' });
      logInfo('Created MinIO namespace');
    } catch (error) {
      if (error.toString().includes('already exists')) {
        logInfo('MinIO namespace already exists');
      } else {
        throw error;
      }
    }
    
    // Check if MinIO is already installed
    try {
      const existingRelease = await execa('helm', ['list', '-n', 'minio', '--filter', '^minio$'], { stdio: 'pipe' });
      const releases = existingRelease.stdout.split('\n').filter(line => line.trim() && !line.includes('NAME'));
      if (releases.some(line => line.includes('minio'))) {
        logInfo('MinIO is already installed, fetching credentials...');
        // Try to get credentials from existing secret if available
        try {
          const secretResult = await execa('kubectl', ['get', 'secret', 'minio', '-n', 'minio', '-o', 'jsonpath={.data.rootUser}', '--ignore-not-found'], { stdio: 'pipe' });
          if (secretResult.stdout) {
            const accessKey = Buffer.from(secretResult.stdout, 'base64').toString();
            const secretKeyResult = await execa('kubectl', ['get', 'secret', 'minio', '-n', 'minio', '-o', 'jsonpath={.data.rootPassword}', '--ignore-not-found'], { stdio: 'pipe' });
            const secretKey = secretKeyResult.stdout ? Buffer.from(secretKeyResult.stdout, 'base64').toString() : 'minioadmin';
            return { accessKey, secretKey };
          }
        } catch (secretError) {
          // Use defaults if secret not found
        }
        return { accessKey: 'minioadmin', secretKey: 'minioadmin' };
      }
    } catch (error) {
      // MinIO not installed, continue with installation
    }
    
    // Generate secure credentials (you should change these in production)
    const minioAccessKey = 'minioadmin';
    const minioSecretKey = 'minioadmin';
    
    // Install MinIO using Helm
    await run('helm', [
      'upgrade', '--install', 'minio', 'minio/minio',
      '--namespace', 'minio',
      '--set', 'persistence.size=100Gi',
      '--set', 'persistence.storageClass=gp3',
      '--set', `accessKey=${minioAccessKey}`,
      '--set', `secretKey=${minioSecretKey}`,
      '--set', 'defaultBuckets=percona-backups',
      '--set', 'resources.requests.memory=1Gi',
      '--set', 'resources.requests.cpu=500m',
      '--set', 'resources.limits.memory=2Gi',
      '--set', 'resources.limits.cpu=1000m',
      '--wait'
    ]);
    
    logSuccess('MinIO installed successfully');
    
    // Wait for MinIO service to be ready
    logInfo('Waiting for MinIO service to be ready...');
    await run('kubectl', ['wait', '--for=condition=ready', 'pod', '-l', 'app=minio', '-n', 'minio', '--timeout=300s']);
    
    return { accessKey: minioAccessKey, secretKey: minioSecretKey };
  } catch (error) {
    logError(`Failed to install MinIO: ${error}`);
    throw error;
  }
}

async function createMinIOCredentialsSecret(ns: string, accessKey: string, secretKey: string) {
  logInfo('Creating MinIO credentials secret...');
  const { execa } = await import('execa');
  
  try {
    // MinIO endpoint (using cluster-internal DNS)
    const minioEndpoint = 'http://minio.minio.svc.cluster.local:9000';
    
    // Create Kubernetes secret with MinIO credentials
    const secretYaml = `apiVersion: v1
kind: Secret
metadata:
  name: percona-backup-minio-credentials
  namespace: ${ns}
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ${accessKey}
  AWS_SECRET_ACCESS_KEY: ${secretKey}
  AWS_ENDPOINT: ${minioEndpoint}`;

    const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
    proc.stdin?.write(secretYaml);
    proc.stdin?.end();
    await proc;

    logSuccess('MinIO credentials secret created');
  } catch (error) {
    logWarn(`Failed to create MinIO credentials secret: ${error}`);
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

async function checkProxySQLIssues(ns: string, name: string) {
  const { execa } = await import('execa');
  
  try {
    // Check ProxySQL StatefulSet
    const stsResult = await execa('kubectl', ['get', 'statefulset', '-n', ns, '-l', 'app.kubernetes.io/name=proxysql', '-o', 'json'], { stdio: 'pipe' });
    const stsData = JSON.parse(stsResult.stdout);
    
    if (stsData.items && stsData.items.length > 0) {
      const sts = stsData.items[0];
      const readyReplicas = sts.status.readyReplicas || 0;
      const desiredReplicas = sts.spec.replicas || 0;
      
      logInfo(`ProxySQL StatefulSet: ${readyReplicas}/${desiredReplicas} ready`);
      
      if (readyReplicas < desiredReplicas) {
        logWarn(`ProxySQL StatefulSet not ready: ${readyReplicas}/${desiredReplicas}`);
        
        // Check for specific issues
        if (sts.status.conditions) {
          sts.status.conditions.forEach((condition: any) => {
            if (condition.type === 'Ready' && condition.status !== 'True') {
              logWarn(`ProxySQL StatefulSet condition: ${condition.type}=${condition.status} - ${condition.message}`);
            }
          });
        }
      }
    }
    
    // Check ProxySQL pods for specific issues
    const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=proxysql', '-o', 'json'], { stdio: 'pipe' });
    const podsData = JSON.parse(podsResult.stdout);
    
    if (podsData.items) {
      podsData.items.forEach((pod: any) => {
        const podName = pod.metadata.name;
        const phase = pod.status.phase;
        const ready = pod.status.containerStatuses?.[0]?.ready || false;
        
        logInfo(`ProxySQL pod ${podName}: ${phase}, ready: ${ready}`);
        
        if (phase === 'Pending' || phase === 'Failed' || !ready) {
          logWarn(`ProxySQL pod ${podName} has issues: ${phase}`);
          
          // Check container status
          if (pod.status.containerStatuses) {
            pod.status.containerStatuses.forEach((container: any) => {
              if (container.state.waiting) {
                logWarn(`  Container waiting: ${container.state.waiting.reason} - ${container.state.waiting.message}`);
              }
              if (container.state.terminated) {
                logWarn(`  Container terminated: ${container.state.terminated.reason} - ${container.state.terminated.message}`);
              }
            });
          }
        }
      });
    }
    
  } catch (error) {
    logWarn(`Error checking ProxySQL issues: ${error}`);
  }
}

async function waitForOperatorReady(ns: string) {
  logInfo('Waiting for Percona operator to be ready...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 5 * 60 * 1000; // 5 minutes
  
  while (Date.now() - startTime < timeout) {
    try {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      
      // Check for any pods in the namespace first
      const allPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const allPods = allPodsResult.stdout.trim().split('\n').filter(line => line.trim());
      logInfo(`Found ${allPods.length} total pods in namespace ${ns}`);
      
      if (allPods.length > 0) {
        logInfo('All pods in namespace:');
        allPods.forEach((pod, index) => {
          logInfo(`  ${index + 1}. ${pod}`);
        });
      }
      
      // Check for operator pods specifically
      const operatorPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster-operator', '--no-headers'], { stdio: 'pipe' });
      const operatorPods = operatorPodsResult.stdout.trim().split('\n').filter(line => line.trim());
      
      logInfo(`Found ${operatorPods.length} operator pods with label 'app.kubernetes.io/name=percona-xtradb-cluster-operator'`);
      
      if (operatorPods.length === 0) {
        // Try alternative labels
        logInfo('Trying alternative operator pod labels...');
        const altLabels = [
          'app.kubernetes.io/name=percona-xtradb-cluster-operator',
          'app=percona-xtradb-cluster-operator',
          'name=percona-xtradb-cluster-operator',
          'app.kubernetes.io/component=operator'
        ];
        
        let foundOperatorPods: string[] = [];
        let workingLabel = '';
        
        for (const label of altLabels) {
          try {
            const altResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', label, '--no-headers'], { stdio: 'pipe' });
            const altPods = altResult.stdout.trim().split('\n').filter(line => line.trim());
            if (altPods.length > 0) {
              logInfo(`Found ${altPods.length} pods with label '${label}':`);
              altPods.forEach((pod, index) => {
                logInfo(`  ${index + 1}. ${pod}`);
              });
              foundOperatorPods = altPods;
              workingLabel = label;
              break; // Use the first working label
            }
          } catch (altError) {
            // Ignore label errors
          }
        }
        
        if (foundOperatorPods.length > 0) {
          logInfo(`Using operator pods found with label '${workingLabel}'`);
          const readyPods = foundOperatorPods.filter(line => {
            const parts = line.split(/\s+/);
            const ready = parts[1];
            return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
          });
          
          if (readyPods.length > 0) {
            logSuccess('Percona operator is ready');
            return;
          } else {
            logInfo(`Percona operator pods starting: ${foundOperatorPods.length} found, ${readyPods.length} ready (${elapsed}s elapsed)`);
          }
        } else {
          logInfo(`Percona operator pods not found yet... (${elapsed}s elapsed)`);
        }
      } else {
        logInfo(`Operator pods found: ${operatorPods.length}`);
        operatorPods.forEach((pod, index) => {
          logInfo(`  ${index + 1}. ${pod}`);
        });
        
        const readyPods = operatorPods.filter(line => {
          const parts = line.split(/\s+/);
          const ready = parts[1];
          return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
        });
        
        if (readyPods.length > 0) {
          logSuccess('Percona operator is ready');
          return;
        } else {
          logInfo(`Percona operator pods starting: ${operatorPods.length} found, ${readyPods.length} ready (${elapsed}s elapsed)`);
        }
      }
      
      await new Promise(resolve => setTimeout(resolve, 10000)); // Wait 10 seconds
    } catch (error) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      logWarn(`Error checking operator status (${elapsed}s): ${error}`);
      await new Promise(resolve => setTimeout(resolve, 10000));
    }
  }
  
  throw new Error('Percona operator did not become ready within 5 minutes');
}

async function validatePodDistribution(ns: string, nodes: number) {
  logInfo('=== Validating Pod Distribution Across Availability Zones ===');
  const { execa } = await import('execa');
  
  try {
    // Get all pods with their zones
    const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-o', 'json'], { stdio: 'pipe' });
    const podsData = JSON.parse(podsResult.stdout);
    
    // Track PXC pods by zone
    const pxcPodsByZone = new Map<string, string[]>();
    // Track ProxySQL pods by zone
    const proxysqlPodsByZone = new Map<string, string[]>();
    
    for (const pod of podsData.items) {
      const podName = pod.metadata.name;
      const labels = pod.metadata.labels || {};
      const component = labels['app.kubernetes.io/component'];
      
      // Get the node this pod is running on
      const nodeName = pod.spec.nodeName;
      if (!nodeName) {
        logWarn(`Pod ${podName} is not yet scheduled to a node`);
        continue;
      }
      
      // Get the node's zone
      const nodeResult = await execa('kubectl', ['get', 'node', nodeName, '-o', 'json'], { stdio: 'pipe' });
      const nodeData = JSON.parse(nodeResult.stdout);
      const zone = nodeData.metadata.labels?.['topology.kubernetes.io/zone'] || 
                   nodeData.metadata.labels?.['failure-domain.beta.kubernetes.io/zone'] ||
                   'unknown';
      
      // Categorize pods (be specific to avoid catching operator or other pods)
      // PXC pods have names like: pxc-cluster-pxc-db-pxc-0, pxc-cluster-pxc-db-pxc-1, etc.
      // ProxySQL pods have names like: pxc-cluster-pxc-db-proxysql-0, pxc-cluster-pxc-db-proxysql-1, etc.
      if (component === 'proxysql' || (podName.includes('proxysql') && !podName.includes('operator'))) {
        // Check ProxySQL first since it also contains 'pxc' in the name
        if (!proxysqlPodsByZone.has(zone)) {
          proxysqlPodsByZone.set(zone, []);
        }
        proxysqlPodsByZone.get(zone)!.push(podName);
      } else if (component === 'pxc' || (podName.includes('-pxc-') && !podName.includes('operator') && !podName.includes('proxysql'))) {
        if (!pxcPodsByZone.has(zone)) {
          pxcPodsByZone.set(zone, []);
        }
        pxcPodsByZone.get(zone)!.push(podName);
      }
    }
    
    let validationPassed = true;
    const issues: string[] = [];
    
    // Validate PXC pods
    logInfo('=== PXC Pod Distribution ===');
    if (pxcPodsByZone.size === 0) {
      issues.push('No PXC pods found');
      validationPassed = false;
    } else {
      for (const [zone, pods] of pxcPodsByZone.entries()) {
        logInfo(`Zone ${zone}: ${pods.length} PXC pod(s)`);
        pods.forEach(pod => logInfo(`  - ${pod}`));
        
        if (pods.length > 1) {
          issues.push(`VIOLATION: Multiple PXC pods (${pods.length}) in same zone ${zone}: ${pods.join(', ')}`);
          validationPassed = false;
        }
      }
      
      if (pxcPodsByZone.size < nodes) {
        issues.push(`PXC pods only in ${pxcPodsByZone.size} zone(s), expected ${nodes} zones`);
        validationPassed = false;
      }
    }
    
    // Validate ProxySQL pods
    logInfo('=== ProxySQL Pod Distribution ===');
    if (proxysqlPodsByZone.size === 0) {
      issues.push('No ProxySQL pods found');
      validationPassed = false;
    } else {
      for (const [zone, pods] of proxysqlPodsByZone.entries()) {
        logInfo(`Zone ${zone}: ${pods.length} ProxySQL pod(s)`);
        pods.forEach(pod => logInfo(`  - ${pod}`));
        
        if (pods.length > 1) {
          issues.push(`VIOLATION: Multiple ProxySQL pods (${pods.length}) in same zone ${zone}: ${pods.join(', ')}`);
          validationPassed = false;
        }
      }
      
      if (proxysqlPodsByZone.size < nodes) {
        issues.push(`ProxySQL pods only in ${proxysqlPodsByZone.size} zone(s), expected ${nodes} zones`);
        validationPassed = false;
      }
    }
    
    // Report results
    logInfo('=== Pod Distribution Validation Results ===');
    if (validationPassed) {
      logSuccess('✅ All pods are properly distributed across availability zones');
      logSuccess(`✅ PXC pods: ${pxcPodsByZone.size} zones (expected ${nodes})`);
      logSuccess(`✅ ProxySQL pods: ${proxysqlPodsByZone.size} zones (expected ${nodes})`);
    } else {
      logError('❌ Pod distribution validation FAILED:');
      issues.forEach(issue => logError(`  - ${issue}`));
      throw new Error('Pod anti-affinity validation failed: Pods are not properly distributed across availability zones');
    }
    
  } catch (error) {
    logError('Failed to validate pod distribution:', error);
    throw error;
  }
}

async function waitForClusterReady(ns: string, name: string, nodes: number) {
  const pxcResourceName = `${name}-pxc-db`;
  logInfo(`Waiting for Percona cluster ${pxcResourceName} to be ready...`);
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 15 * 60 * 1000; // 15 minutes (reduced from 30)
  
  while (Date.now() - startTime < timeout) {
    try {
      // First check if PXC custom resource exists
      let pxcExists = false;
      try {
        await execa('kubectl', ['get', 'pxc', pxcResourceName, '-n', ns], { stdio: 'pipe' });
        pxcExists = true;
      } catch (error) {
        if (error.toString().includes('NotFound')) {
          logInfo(`PXC resource ${pxcResourceName} not found yet, waiting for operator to create it...`);
        } else {
          logWarn(`Error checking PXC resource existence: ${error}`);
        }
      }
      
      if (!pxcExists) {
        // Check if the operator is running
        try {
          const operatorPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster-operator', '--no-headers'], { stdio: 'pipe' });
          const operatorPods = operatorPodsResult.stdout.trim().split('\n').filter(line => line.trim());
          
          if (operatorPods.length === 0) {
            logWarn('Percona operator not found, waiting for installation...');
          } else {
            const readyOperators = operatorPods.filter(line => line.includes('Running'));
            if (readyOperators.length === 0) {
              logWarn('Percona operator pods not ready yet...');
            } else {
              logInfo('Percona operator is running, waiting for PXC resource creation...');
            }
          }
        } catch (error) {
          logWarn(`Error checking operator status: ${error}`);
        }
        
        // Wait and continue
        await new Promise(resolve => setTimeout(resolve, 30000));
        continue;
      }
      
      // Check PXC custom resource status
      const pxcResult = await execa('kubectl', ['get', 'pxc', pxcResourceName, '-n', ns, '-o', 'json'], { stdio: 'pipe' });
      const pxc = JSON.parse(pxcResult.stdout);
      
      // Debug: log the actual status structure
      if (pxc.status) {
        logInfo(`Debug - PXC status: state=${pxc.status.state}, pxc.status=${pxc.status.pxc?.status}, proxysql.status=${pxc.status.proxysql?.status}`);
      }
      
      const pxcCount = typeof pxc.status?.pxc === 'number' ? pxc.status.pxc : (pxc.status?.pxc?.ready || 0);
      const proxysqlCount = typeof pxc.status?.proxysql === 'number' ? pxc.status.proxysql : (pxc.status?.proxysql?.ready || 0);
      const status = pxc.status?.status || 'unknown';
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      
      // Explain what the numbers mean
      if (elapsed === 0 || elapsed % 60 === 0) { // Show explanation every minute
        logInfo(`💡 Status Guide: PXC = Percona XtraDB Cluster nodes, ProxySQL = Database proxy pods, Status 'unknown' = Still initializing`);
      }
      logInfo(`📊 Cluster Progress: PXC nodes ${pxcCount}/${nodes}, ProxySQL pods ${proxysqlCount}/3, Status: ${status} (${elapsed}s elapsed)`);
      
      // Check PXC pods
      const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster', '--no-headers'], { stdio: 'pipe' });
      const podLines = podsResult.stdout.trim().split('\n').filter(line => line.includes(`${pxcResourceName}-pxc-`));
      logInfo(`🔍 PXC pods found: ${podLines.length}/${nodes}`);
      
      // Check ProxySQL pods with multiple label selectors
      try {
        let proxysqlPodsFound = 0;
        const proxysqlLabels = [
          'app.kubernetes.io/component=proxysql',
          'app.kubernetes.io/name=proxysql',
          'app=proxysql'
        ];
        
        for (const label of proxysqlLabels) {
          try {
            const proxysqlPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', label, '--no-headers'], { stdio: 'pipe' });
            const proxysqlPodLines = proxysqlPodsResult.stdout.trim().split('\n').filter(line => line.trim());
            if (proxysqlPodLines.length > 0) {
              logInfo(`🔍 ProxySQL pods found with label '${label}': ${proxysqlPodLines.length}`);
              proxysqlPodLines.forEach((line, index) => {
                const parts = line.split(/\s+/);
                const name = parts[0];
                const ready = parts[1];
                const status = parts[2];
                logInfo(`  ProxySQL pod ${index + 1}: ${name} (${ready}, ${status})`);
              });
              proxysqlPodsFound = Math.max(proxysqlPodsFound, proxysqlPodLines.length);
            }
          } catch (labelError) {
            // Try next label
          }
        }
        
        if (proxysqlPodsFound === 0) {
          logInfo(`🔍 No ProxySQL pods found with any label selector`);
        } else if (proxysqlPodsFound === 3) {
          // Check if ProxySQL pods are distributed across AZs
          try {
            const proxysqlPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/component=proxysql', '-o', 'json'], { stdio: 'pipe' });
            const proxysqlPods = JSON.parse(proxysqlPodsResult.stdout);
            const zones = new Set();
            
            for (const pod of proxysqlPods.items) {
              if (pod.spec.nodeName) {
                try {
                  const nodeResult = await execa('kubectl', ['get', 'node', pod.spec.nodeName, '-o', 'json'], { stdio: 'pipe' });
                  const node = JSON.parse(nodeResult.stdout);
                  const zone = node.metadata.labels?.['topology.kubernetes.io/zone'] || 
                              node.metadata.labels?.['failure-domain.beta.kubernetes.io/zone'] || 
                              'Unknown';
                  zones.add(zone);
                } catch (nodeError) {
                  zones.add('Unknown');
                }
              } else {
                zones.add('Pending');
              }
            }
            
            if (zones.size >= 2) {
              logSuccess(`✓ ProxySQL pods distributed across ${zones.size} availability zones: ${Array.from(zones).join(', ')}`);
            } else if (zones.size === 1) {
              logWarn(`⚠️  All ProxySQL pods in same zone (${Array.from(zones)[0]}). Consider multi-AZ deployment for high availability.`);
            }
          } catch (error) {
            // Ignore zone checking errors
          }
        }
      } catch (error) {
        logWarn(`Error checking ProxySQL pods: ${error}`);
      }
      
      // Check for any failed pods
      try {
        const failedPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '--field-selector=status.phase=Failed', '--no-headers'], { stdio: 'pipe' });
        const failedPods = failedPodsResult.stdout.trim().split('\n').filter(line => line.trim());
        if (failedPods.length > 0) {
          logWarn(`Found ${failedPods.length} failed pods:`);
          failedPods.forEach(pod => logWarn(`  Failed: ${pod}`));
        }
      } catch (error) {
        // Ignore errors here as this is just for debugging
      }
      
      // Check Kubernetes events for errors (every 2 minutes)
      if (elapsed % 120 === 0 && elapsed > 0) {
        try {
          const eventsResult = await execa('kubectl', ['get', 'events', '-n', ns, '--sort-by=.lastTimestamp', '--field-selector=type=Warning', '--no-headers'], { stdio: 'pipe' });
          const warningEvents = eventsResult.stdout.trim().split('\n').filter(line => line.trim()).slice(-5); // Last 5 warnings
          if (warningEvents.length > 0) {
            logWarn(`Recent warning events:`);
            warningEvents.forEach(event => logWarn(`  ${event}`));
          }
        } catch (error) {
          // Ignore errors here as this is just for debugging
        }
      }
      
      // Check ProxySQL issues (every 2 minutes)
      if (elapsed % 120 === 0 && elapsed > 0) {
        logInfo('=== Checking ProxySQL status ===');
        await checkProxySQLIssues(ns, name);
      }
      
      // Check ProxySQL pod logs if there are issues (every 3 minutes)
      if (elapsed % 180 === 0 && elapsed > 0) {
        try {
          const proxysqlPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=proxysql', '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
          const proxysqlPodNames = proxysqlPodsResult.stdout.trim().split('\n').filter(name => name.trim());
          
          for (const podName of proxysqlPodNames.slice(0, 2)) { // Check first 2 ProxySQL pods
            try {
              const logsResult = await execa('kubectl', ['logs', podName, '-n', ns, '--tail=10', '--since=2m'], { stdio: 'pipe' });
              const logs = logsResult.stdout.trim();
              if (logs) {
                logInfo(`ProxySQL pod ${podName} recent logs:`);
                logs.split('\n').forEach(line => {
                  if (line.trim()) {
                    logInfo(`  ${line}`);
                  }
                });
              }
            } catch (logError) {
              logWarn(`Could not get logs from ProxySQL pod ${podName}: ${logError}`);
            }
          }
        } catch (error) {
          logWarn(`Error checking ProxySQL pod logs: ${error}`);
        }
      }
      
              if (podLines.length >= nodes) {
                const allReady = podLines.every(line => {
                  const parts = line.split(/\s+/);
                  const ready = parts[1];
                  return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
                });
                
                // Check if cluster is ready based on PXC status
                const clusterReady = pxc.status?.state === 'ready' || 
                                   (pxcCount >= nodes && pxc.status?.proxysql?.status === 'ready');
                
                if (allReady && clusterReady) {
                  logSuccess(`🎉 Percona cluster ${pxcResourceName} is ready with ${nodes} PXC nodes and 3 ProxySQL pods!`);
                  logSuccess(`📊 Final Status: PXC ${pxcCount}/${nodes}, ProxySQL ${proxysqlCount}/3, State: ${pxc.status?.state || status}`);
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
  
  throw new Error(`Percona cluster ${pxcResourceName} did not become ready within 15 minutes. Check the logs above for ProxySQL and PXC pod issues.`);
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
  
  const { execa } = await import('execa');
  let pxcDeleted = false;
  const maxAttempts = 3;
  
  // First check if PXC resource exists at all
  let pxcExists = false;
  try {
    const initialCheck = await execa('kubectl', ['get', 'pxc', name, '-n', ns], { stdio: 'pipe' });
    pxcExists = (initialCheck.exitCode === 0);
  } catch (error) {
    pxcExists = false;
  }
  
  if (!pxcExists) {
    logSuccess('✓ PXC custom resource not found - already deleted');
    pxcDeleted = true;
  } else {
    logInfo(`PXC resource exists, attempting deletion with ${maxAttempts} attempts...`);
    
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      logInfo(`Attempt ${attempt}/${maxAttempts}: Deleting PXC resource...`);
      
      try {
        if (attempt === 1) {
          // Normal deletion
          await run('kubectl', ['delete', 'pxc', name, '-n', ns, '--timeout=30s'], { stdio: 'pipe' });
          logInfo('Normal deletion command completed');
        } else if (attempt === 2) {
          // Force deletion with finalizer removal
          await run('kubectl', ['patch', 'pxc', name, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
          await run('kubectl', ['delete', 'pxc', name, '-n', ns, '--force', '--grace-period=0'], { stdio: 'pipe' });
          logInfo('Force deletion command completed');
        } else {
          // Final attempt: aggressive cleanup
          logError(`Final attempt ${attempt}: Aggressive PXC cleanup...`);
          try {
            // Remove all finalizers multiple times
            await run('kubectl', ['patch', 'pxc', name, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
            await run('kubectl', ['patch', 'pxc', name, '-n', ns, '-p', '{"metadata":{"finalizers":null}}', '--type=merge'], { stdio: 'pipe' });
            
            // Try multiple deletion approaches
            try {
              await run('kubectl', ['delete', 'pxc', name, '-n', ns, '--force', '--grace-period=0'], { stdio: 'pipe' });
            } catch (deleteError) {
              // Try with different flags
              await run('kubectl', ['delete', 'pxc', name, '-n', ns, '--cascade=orphan'], { stdio: 'pipe' });
            }
            
            logError('Aggressive cleanup completed');
          } catch (aggressiveError) {
            logError(`Aggressive cleanup failed: ${aggressiveError}`);
          }
        }
      } catch (error) {
        logWarn(`Deletion attempt ${attempt} failed: ${error}`);
      }
      
      // Wait for Kubernetes to process the deletion
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      // Verify if deletion was successful
      try {
        const verifyResult = await execa('kubectl', ['get', 'pxc', name, '-n', ns], { stdio: 'pipe' });
        if (verifyResult.exitCode !== 0) {
          logSuccess(`✓ PXC resource successfully deleted on attempt ${attempt}`);
          pxcDeleted = true;
          break;
        } else {
          logWarn(`PXC resource still exists after attempt ${attempt}`);
        }
      } catch (error) {
        logSuccess(`✓ PXC resource successfully deleted on attempt ${attempt}`);
        pxcDeleted = true;
        break;
      }
    }
  }
  
  // CRITICAL: If PXC still exists, abort the entire uninstall
  if (!pxcDeleted) {
    logError('❌ FATAL: PXC resource could not be deleted after all attempts!');
    logError('This will prevent namespace deletion. The uninstall cannot continue.');
    logError('Manual intervention required: kubectl patch pxc <name> -n <ns> -p \'{"metadata":{"finalizers":[]}}\' --type=merge');
    throw new Error('CRITICAL: PXC resource deletion failed - uninstall aborted');
  }
  
  // Delete resources in correct order (controllers before pods to prevent recreation)
  
  // 1. Delete StatefulSets first (stops pod recreation)
  try {
    logInfo('Deleting StatefulSets...');
    await run('kubectl', ['delete', 'statefulset', '--all', '-n', ns, '--timeout=60s'], { stdio: 'pipe' });
    logSuccess('StatefulSets deleted successfully');
  } catch (error) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No StatefulSets found or already deleted');
    } else {
      logWarn(`Error deleting StatefulSets: ${error}`);
    }
  }
  
  // 2. Delete any remaining Pods (should be cleaned up by StatefulSet deletion)
  try {
    logInfo('Deleting remaining Pods...');
    await run('kubectl', ['delete', 'pods', '--all', '-n', ns, '--timeout=30s', '--force', '--grace-period=0'], { stdio: 'pipe' });
    logSuccess('Pods deleted successfully');
  } catch (error) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No Pods found or already deleted');
    } else {
      logWarn(`Error deleting Pods: ${error}`);
    }
  }
  
  // 3. Delete Services
  try {
    logInfo('Deleting Services...');
    await run('kubectl', ['delete', 'service', '--all', '-n', ns], { stdio: 'pipe' });
    logSuccess('Services deleted successfully');
  } catch (error) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No Services found or already deleted');
    } else {
      logWarn(`Error deleting Services: ${error}`);
    }
  }
  
  // 4. Delete PVCs (they can have finalizers)
  try {
    logInfo('Deleting PVCs...');
    await run('kubectl', ['delete', 'pvc', '--all', '-n', ns, '--timeout=60s'], { stdio: 'pipe' });
    logSuccess('PVCs deleted successfully');
  } catch (error) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No PVCs found or already deleted');
    } else if (error.toString().includes('timeout')) {
      logWarn('PVC deletion timed out, forcing cleanup...');
      try {
        // Force delete PVCs that are stuck
        const pvcResult = await execa('kubectl', ['get', 'pvc', '-n', ns, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
        const pvcNames = pvcResult.stdout.trim().split('\n').filter(name => name.trim());
        
        for (const pvcName of pvcNames) {
          try {
            logInfo(`Force deleting PVC: ${pvcName}`);
            // Remove finalizers first
            await run('kubectl', ['patch', 'pvc', pvcName, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
            // Force delete with immediate termination
            await run('kubectl', ['delete', 'pvc', pvcName, '-n', ns, '--force', '--grace-period=0'], { stdio: 'pipe' });
          } catch (pvcError) {
            logWarn(`Failed to force delete PVC ${pvcName}: ${pvcError}`);
          }
        }
        logSuccess('PVCs force deleted successfully');
      } catch (forceError) {
        logWarn(`Error force deleting PVCs: ${forceError}`);
      }
    } else {
      logWarn(`Error deleting PVCs: ${error}`);
    }
  }
  
  // Delete Percona-related Secrets
  try {
    logInfo('Deleting Percona-related Secrets...');
    
    // Get all secrets and filter for Percona-related ones
    const { execa } = await import('execa');
    const secretsResult = await execa('kubectl', ['get', 'secrets', '-n', ns, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
    const allSecrets = secretsResult.stdout.trim().split('\n').filter(line => line.trim());
    const perconaSecrets = allSecrets.filter(secret => 
      secret.includes('percona') || 
      secret.includes('pxc') || 
      secret.includes('proxysql') ||
      secret.includes('backup') ||
      secret.includes('ssl') ||
      secret.includes('internal')
    );
    
    if (perconaSecrets.length > 0) {
      logInfo(`Found ${perconaSecrets.length} Percona-related Secrets to delete: ${perconaSecrets.join(', ')}`);
      for (const secretName of perconaSecrets) {
        try {
          await run('kubectl', ['delete', 'secret', secretName, '-n', ns]);
          logInfo(`Deleted secret: ${secretName}`);
        } catch (secretError) {
          logWarn(`Failed to delete secret ${secretName}: ${secretError}`);
        }
      }
      logSuccess('Percona-related Secrets deleted successfully');
    } else {
      logInfo('No Percona-related Secrets found to delete');
    }
  } catch (error) {
    logWarn(`Error deleting Percona-related Secrets: ${error}`);
  }
  
  // Delete Percona-related ConfigMaps
  try {
    logInfo('Deleting Percona-related ConfigMaps...');
    
    const { execa } = await import('execa');
    const cmResult = await execa('kubectl', ['get', 'configmap', '-n', ns, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
    const allConfigMaps = cmResult.stdout.trim().split('\n').filter(line => line.trim());
    const perconaConfigMaps = allConfigMaps.filter(cm => 
      cm.includes('percona') || 
      cm.includes('pxc') || 
      cm.includes('proxysql')
    );
    
    if (perconaConfigMaps.length > 0) {
      logInfo(`Found ${perconaConfigMaps.length} Percona-related ConfigMaps to delete: ${perconaConfigMaps.join(', ')}`);
      for (const cmName of perconaConfigMaps) {
        try {
          await run('kubectl', ['delete', 'configmap', cmName, '-n', ns]);
          logInfo(`Deleted configmap: ${cmName}`);
        } catch (cmError) {
          logWarn(`Failed to delete configmap ${cmName}: ${cmError}`);
        }
      }
      logSuccess('Percona-related ConfigMaps deleted successfully');
    } else {
      logInfo('No Percona-related ConfigMaps found to delete');
    }
  } catch (error) {
    logWarn(`Error deleting Percona-related ConfigMaps: ${error}`);
  }
  
  // Uninstall Helm releases
  logInfo('Uninstalling Helm releases...');
  
  // Check if Helm releases exist before trying to uninstall
  try {
    const { execa } = await import('execa');
    const listResult = await execa('helm', ['list', '-n', ns, '--output', 'json'], { stdio: 'pipe' });
    const releases = JSON.parse(listResult.stdout);
    
    const clusterRelease = releases.find((r: any) => r.name === name);
    const operatorRelease = releases.find((r: any) => r.name === 'percona-operator');
    
    if (clusterRelease) {
      await run('helm', ['uninstall', name, '-n', ns]);
      logSuccess(`Helm release ${name} uninstalled successfully`);
    } else {
      logInfo(`Helm release ${name} not found or already deleted`);
    }
    
    if (operatorRelease) {
      await run('helm', ['uninstall', 'percona-operator', '-n', ns]);
      logSuccess('Percona operator Helm release uninstalled successfully');
    } else {
      logInfo('Percona operator Helm release not found or already deleted');
    }
  } catch (error) {
    logWarn(`Error checking Helm releases: ${error}`);
    // Fallback to trying to uninstall anyway
    try {
      await run('helm', ['uninstall', name, '-n', ns]);
      logSuccess(`Helm release ${name} uninstalled successfully`);
    } catch (uninstallError) {
      logInfo(`Helm release ${name} not found or already deleted`);
    }
    
    try {
      await run('helm', ['uninstall', 'percona-operator', '-n', ns]);
      logSuccess('Percona operator Helm release uninstalled successfully');
    } catch (uninstallError) {
      logInfo('Percona operator Helm release not found or already deleted');
    }
  }
  
  // Delete the namespace itself
  logInfo('Deleting Percona namespace...');
  let namespaceDeleted = false;
  
  try {
    await run('kubectl', ['delete', 'namespace', ns, '--timeout=60s'], { stdio: 'pipe' });
    logInfo('Namespace deletion command completed, verifying...');
  } catch (error) {
    if (error.toString().includes('NotFound')) {
      logInfo(`Namespace ${ns} not found or already deleted`);
      namespaceDeleted = true;
    } else if (error.toString().includes('timeout')) {
      logWarn(`Namespace deletion timed out, forcing cleanup...`);
    } else {
      logWarn(`Namespace deletion failed: ${error}`);
    }
  }
  
  // If namespace deletion failed or timed out, try aggressive cleanup
  if (!namespaceDeleted) {
    try {
      // Check if namespace still exists
      const nsCheck = await execa('kubectl', ['get', 'namespace', ns], { stdio: 'pipe' });
      if (nsCheck.exitCode === 0) {
        logWarn('Namespace still exists, performing aggressive cleanup...');
        
        // 1. Remove finalizers from all resources in the namespace
        logInfo('Removing finalizers from all resources...');
        const resourceTypes = ['pxc', 'perconaxtradbclusters', 'persistentvolumeclaims', 'pods', 'statefulsets', 'deployments', 'replicasets', 'services'];
        
        for (const resourceType of resourceTypes) {
          try {
            const resources = await execa('kubectl', ['get', resourceType, '-n', ns, '-o', 'json'], { stdio: 'pipe' });
            const resourceData = JSON.parse(resources.stdout);
            
            if (resourceData.items && resourceData.items.length > 0) {
              logInfo(`Found ${resourceData.items.length} ${resourceType} to clean up`);
              for (const resource of resourceData.items) {
                const resourceName = resource.metadata.name;
                try {
                  await run('kubectl', ['patch', resourceType, resourceName, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
                  logInfo(`  Removed finalizers from ${resourceType}/${resourceName}`);
                } catch (patchError) {
                  // Ignore errors - resource might not exist anymore
                }
              }
            }
          } catch (getError) {
            // Ignore errors - resource type might not exist
          }
        }
        
        // 2. Remove finalizer from namespace itself
        logInfo('Removing namespace finalizers...');
        await run('kubectl', ['patch', 'namespace', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
        
        // 3. Force delete the namespace
        logInfo('Force deleting namespace...');
        await run('kubectl', ['delete', 'namespace', ns, '--force', '--grace-period=0'], { stdio: 'pipe' });
        logInfo('Force deletion command completed, verifying...');
        
        // Wait a moment for deletion to propagate
        await new Promise(resolve => setTimeout(resolve, 2000));
      } else {
        logInfo('Namespace not found - deletion successful');
        namespaceDeleted = true;
      }
    } catch (forceError) {
      logWarn(`Error during aggressive cleanup: ${forceError}`);
    }
  }
  
  // Final verification: check if namespace is actually deleted
  logInfo('=== Final verification ===');
  try {
    const finalCheck = await execa('kubectl', ['get', 'namespace', ns], { stdio: 'pipe' });
    if (finalCheck.exitCode === 0) {
      logError(`❌ CRITICAL: Namespace ${ns} still exists after all deletion attempts!`);
      logError('This indicates the uninstall was not completely successful.');
      throw new Error(`CRITICAL: Namespace ${ns} could not be deleted - uninstall incomplete`);
    } else {
      logSuccess(`✓ Namespace ${ns} successfully deleted - uninstall complete`);
    }
  } catch (error) {
    if (error.message.includes('Namespace') && error.message.includes('could not be deleted')) {
      throw error; // Re-throw critical errors
    }
    logSuccess(`✓ Namespace ${ns} successfully deleted - uninstall complete`);
  }
  
  logSuccess('Percona cluster and operator uninstalled successfully');
}

async function verifyCleanup(ns: string, name: string) {
  const { execa } = await import('execa');
  let cleanupIssues: string[] = [];
  
  try {
    // 1. Check for remaining PXC custom resources
    logInfo('Checking for remaining PXC custom resources...');
    try {
      const pxcResult = await execa('kubectl', ['get', 'pxc', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const pxcResources = pxcResult.stdout.trim().split('\n').filter(line => line.trim());
      if (pxcResources.length > 0) {
        cleanupIssues.push(`Found ${pxcResources.length} remaining PXC resources: ${pxcResources.join(', ')}`);
      } else {
        logSuccess('✓ No PXC custom resources found');
      }
    } catch (error) {
      logSuccess('✓ No PXC custom resources found');
    }
    
    // 2. Check for remaining StatefulSets
    logInfo('Checking for remaining StatefulSets...');
    try {
      const stsResult = await execa('kubectl', ['get', 'statefulset', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const stsResources = stsResult.stdout.trim().split('\n').filter(line => line.trim());
      if (stsResources.length > 0) {
        cleanupIssues.push(`Found ${stsResources.length} remaining StatefulSets: ${stsResources.join(', ')}`);
      } else {
        logSuccess('✓ No StatefulSets found');
      }
    } catch (error) {
      logSuccess('✓ No StatefulSets found');
    }
    
    // 3. Check for remaining Services
    logInfo('Checking for remaining Services...');
    try {
      const svcResult = await execa('kubectl', ['get', 'service', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const svcResources = svcResult.stdout.trim().split('\n').filter(line => line.trim());
      if (svcResources.length > 0) {
        cleanupIssues.push(`Found ${svcResources.length} remaining Services: ${svcResources.join(', ')}`);
      } else {
        logSuccess('✓ No Services found');
      }
    } catch (error) {
      logSuccess('✓ No Services found');
    }
    
    // 4. Check for remaining PVCs
    logInfo('Checking for remaining PVCs...');
    try {
      const pvcResult = await execa('kubectl', ['get', 'pvc', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const pvcResources = pvcResult.stdout.trim().split('\n').filter(line => line.trim());
      if (pvcResources.length > 0) {
        cleanupIssues.push(`Found ${pvcResources.length} remaining PVCs: ${pvcResources.join(', ')}`);
      } else {
        logSuccess('✓ No PVCs found');
      }
    } catch (error) {
      logSuccess('✓ No PVCs found');
    }
    
    // 5. Check for remaining Pods
    logInfo('Checking for remaining Pods...');
    try {
      const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const podResources = podsResult.stdout.trim().split('\n').filter(line => line.trim());
      if (podResources.length > 0) {
        cleanupIssues.push(`Found ${podResources.length} remaining Pods: ${podResources.join(', ')}`);
      } else {
        logSuccess('✓ No Pods found');
      }
    } catch (error) {
      logSuccess('✓ No Pods found');
    }
    
    // 6. Check for remaining Secrets
    logInfo('Checking for Percona-related Secrets...');
    try {
      const secretsResult = await execa('kubectl', ['get', 'secrets', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const allSecrets = secretsResult.stdout.trim().split('\n').filter(line => line.trim());
      const perconaSecrets = allSecrets.filter(secret => 
        secret.includes('percona') || 
        secret.includes('pxc') || 
        secret.includes('proxysql') ||
        secret.includes('backup')
      );
      if (perconaSecrets.length > 0) {
        cleanupIssues.push(`Found ${perconaSecrets.length} Percona-related Secrets: ${perconaSecrets.join(', ')}`);
      } else {
        logSuccess('✓ No Percona-related Secrets found');
      }
    } catch (error) {
      logSuccess('✓ No Percona-related Secrets found');
    }
    
    // 7. Check for remaining ConfigMaps
    logInfo('Checking for Percona-related ConfigMaps...');
    try {
      const cmResult = await execa('kubectl', ['get', 'configmap', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const allConfigMaps = cmResult.stdout.trim().split('\n').filter(line => line.trim());
      const perconaConfigMaps = allConfigMaps.filter(cm => 
        cm.includes('percona') || 
        cm.includes('pxc') || 
        cm.includes('proxysql')
      );
      if (perconaConfigMaps.length > 0) {
        cleanupIssues.push(`Found ${perconaConfigMaps.length} Percona-related ConfigMaps: ${perconaConfigMaps.join(', ')}`);
      } else {
        logSuccess('✓ No Percona-related ConfigMaps found');
      }
    } catch (error) {
      logSuccess('✓ No Percona-related ConfigMaps found');
    }
    
    // 8. Check for remaining Helm releases
    logInfo('Checking for remaining Helm releases...');
    try {
      const helmResult = await execa('helm', ['list', '-n', ns, '--output', 'json'], { stdio: 'pipe' });
      const releases = JSON.parse(helmResult.stdout);
      const perconaReleases = releases.filter((r: any) => 
        r.name.includes('percona') || 
        r.name.includes('pxc') || 
        r.name === name
      );
      if (perconaReleases.length > 0) {
        cleanupIssues.push(`Found ${perconaReleases.length} remaining Helm releases: ${perconaReleases.map((r: any) => r.name).join(', ')}`);
      } else {
        logSuccess('✓ No Helm releases found');
      }
    } catch (error) {
      logSuccess('✓ No Helm releases found');
    }
    
    
    // 9. Check if namespace still exists
    logInfo('Checking if Percona namespace still exists...');
    try {
      await execa('kubectl', ['get', 'namespace', ns], { stdio: 'pipe' });
      cleanupIssues.push(`Namespace ${ns} still exists`);
    } catch (error) {
      logSuccess('✓ Percona namespace has been deleted');
    }
    
    // 10. Summary
    logInfo('=== Cleanup Verification Summary ===');
    if (cleanupIssues.length > 0) {
      logWarn('⚠️  Cleanup issues found:');
      cleanupIssues.forEach(issue => logWarn(`  - ${issue}`));
      logWarn('Some resources may still exist. You may need to delete them manually.');
    } else {
      logSuccess('✅ All Percona resources have been successfully removed');
    }
    
  } catch (error) {
    logWarn(`Error during cleanup verification: ${error}`);
  }
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
      // Validate EKS cluster state before installation
      await validateEksCluster(parsed.namespace, parsed.nodes);
      
      await ensureNamespace(parsed.namespace);
      await addRepos(parsed.helmRepo);
      
      // Create storage class first
      await createStorageClass();
      
      // Get AWS account ID (still needed for some operations)
      const { execa } = await import('execa');
      const accountResult = await execa('aws', ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'], { stdio: 'pipe' });
      const accountId = accountResult.stdout.trim();
      
      // Install MinIO for on-premises backup storage (replicates on-prem environment)
      const minioCredentials = await installMinIO(parsed.namespace);
      
      // Create MinIO credentials secret for Percona backups
      await createMinIOCredentialsSecret(parsed.namespace, minioCredentials.accessKey, minioCredentials.secretKey);
      
      logInfo('Installing Percona operator...');
      await installOperator(parsed.namespace);
      
      // Wait for operator to be ready before installing cluster
      logInfo('Waiting for Percona operator to be ready...');
      await waitForOperatorReady(parsed.namespace);
      
      logInfo('Installing Percona cluster...');
      await installCluster(parsed.namespace, parsed.name, parsed.nodes, accountId);
      
      // Wait for cluster to be fully ready
      await waitForClusterReady(parsed.namespace, parsed.name, parsed.nodes);
      
      // Validate pod distribution across availability zones
      await validatePodDistribution(parsed.namespace, parsed.nodes);
      
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
      await uninstall(parsed.namespace, parsed.name);
      logSuccess('Uninstall completed.');
    }
  } catch (err) {
    logError('Percona script failed', err);
    process.exitCode = 1;
  }
}

main();


