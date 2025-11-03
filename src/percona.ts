import { z } from 'zod';
import { ensureBinaryExists, logError, logInfo, logSuccess, logWarn, run } from './utils.js';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const Args = z.object({
  action: z.enum(['install', 'uninstall', 'expand']),
  namespace: z.string().default('percona'),
  name: z.string().default('pxc-cluster'),
  helmRepo: z.string().default('http://chartmuseum.chartmuseum.svc.cluster.local'),
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
      const { readFile } = await import('fs/promises');
      const { resolve } = await import('path');
      const templatePath = resolve(process.cwd(), 'templates', 'test', 'dns-test-pod.yaml');
      let dnsTestPod = await readFile(templatePath, 'utf8');
      dnsTestPod = dnsTestPod.replace(/\{\{NAMESPACE\}\}/g, ns);
      
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
      const { readFile } = await import('fs/promises');
      const { resolve } = await import('path');
      const templatePath = resolve(process.cwd(), 'templates', 'test', 'test-secret.yaml');
      let testSecret = await readFile(templatePath, 'utf8');
      testSecret = testSecret.replace(/\{\{NAMESPACE\}\}/g, ns);
      
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
      const { readFile } = await import('fs/promises');
      const { resolve } = await import('path');
      const templatePath = resolve(process.cwd(), 'templates', 'test', 'test-sts.yaml');
      let testSts = await readFile(templatePath, 'utf8');
      testSts = testSts.replace(/\{\{NAMESPACE\}\}/g, ns);
        
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
  const { execa } = await import('execa');
  
  try {
    // Always use the internal ChartMuseum repo
    await execa('helm', ['repo', 'add', 'internal', repoUrl], { stdio: 'pipe' });
    logInfo('Added internal Helm repo');
  } catch (err) {
    // Repo already exists, that's fine
    logInfo('Internal Helm repo already exists, continuing...');
  }
  
  // Update repos and verify internal repo is accessible
  try {
    await execa('helm', ['repo', 'update'], { stdio: 'pipe' });
    
    // Verify internal repo is working by searching for at least one chart
    try {
      const searchResult = await execa('helm', ['search', 'repo', 'internal', '--max-col-width', '0'], { stdio: 'pipe', timeout: 30000 });
      if (searchResult.stdout.includes('No results found')) {
        logWarn('⚠️  Internal repo is empty - charts may not be mirrored yet');
      } else {
        logInfo('✓ Internal Helm repo is accessible and has charts');
      }
    } catch (searchError) {
      logWarn('⚠️  Could not verify internal repo has charts - proceeding anyway');
    }
  } catch (error) {
    logWarn(`Helm repo update had issues: ${error}`);
    // Continue anyway - might be a transient issue
  }
}

async function installOperator(ns: string) {
  logInfo('Installing Percona operator via Helm...');
  try {
    await run('helm', ['upgrade', '--install', 'percona-operator', 'internal/pxc-operator', '-n', ns]);
    logSuccess('Percona operator Helm chart installed successfully');
  } catch (error) {
    logError(`Failed to install Percona operator: ${error}`);
    throw error;
  }
}

async function clusterValues(nodes: number, accountId: string): Promise<string> {
  const { readFile } = await import('fs/promises');
  const { resolve } = await import('path');
  const templatePath = resolve(process.cwd(), 'templates', 'percona-values.yaml');
  let content = await readFile(templatePath, 'utf8');
  content = content.replace(/\{\{NODES\}\}/g, nodes.toString());
  return content;
}

async function createStorageClass() {
  logInfo('Creating gp3 storage class...');
  const { execa } = await import('execa');
  const { readFile } = await import('fs/promises');
  const { resolve } = await import('path');
  const templatePath = resolve(process.cwd(), 'templates', 'storageclass-gp3.yaml');
  const storageClassYaml = await readFile(templatePath, 'utf8');
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

// Helper function to diagnose resource allocation issues for Pending pods
async function diagnoseResourceIssues(podName: string, namespace: string) {
  const { execa } = await import('execa');
  const issues: string[] = [];
  
  try {
    // Get pod details
    const describeResult = await execa('kubectl', ['describe', 'pod', podName, '-n', namespace], { stdio: 'pipe' });
    const describeOutput = describeResult.stdout;
    
    // Check for resource-related issues
    if (describeOutput.includes('Insufficient cpu') || describeOutput.match(/Insufficient\s+cpu/i)) {
      const cpuMatch = describeOutput.match(/Insufficient\s+cpu\s*\((\d+)\s*requested/i);
      if (cpuMatch) {
        issues.push(`Insufficient CPU: ${cpuMatch[1]} requested but not available`);
      } else {
        issues.push('Insufficient CPU resources available on any node');
      }
    }
    
    if (describeOutput.includes('Insufficient memory') || describeOutput.match(/Insufficient\s+memory/i)) {
      const memMatch = describeOutput.match(/Insufficient\s+memory\s*\(([^)]+)\s*requested/i);
      if (memMatch) {
        issues.push(`Insufficient Memory: ${memMatch[1]} requested but not available`);
      } else {
        issues.push('Insufficient memory resources available on any node');
      }
    }
    
    // Check node resources if pod is assigned
    const nodeMatch = describeOutput.match(/Node:\s+([^\s]+)/);
    if (nodeMatch && !describeOutput.includes('Pending')) {
      const nodeName = nodeMatch[1];
      try {
        // Get node resource allocation
        const nodeResult = await execa('kubectl', ['describe', 'node', nodeName], { stdio: 'pipe' });
        const nodeOutput = nodeResult.stdout;
        
        // Check for resource pressure
        if (nodeOutput.includes('MemoryPressure')) {
          issues.push(`Node ${nodeName} is under MemoryPressure`);
        }
        if (nodeOutput.includes('DiskPressure')) {
          issues.push(`Node ${nodeName} is under DiskPressure`);
        }
        if (nodeOutput.includes('PIDPressure')) {
          issues.push(`Node ${nodeName} is under PIDPressure`);
        }
        
        // Extract allocatable vs requested resources
        const allocatableMatch = nodeOutput.match(/Allocatable:\s*\n\s*cpu:\s*([^\n]+)\n\s*memory:\s*([^\n]+)/);
        const requestsMatch = nodeOutput.match(/cpu\s+request:\s*([^\s]+)/);
        const memoryRequestsMatch = nodeOutput.match(/memory\s+request:\s*([^\s]+)/);
        
        if (allocatableMatch && requestsMatch && memoryRequestsMatch) {
          logInfo(`  Node ${nodeName} resources: Allocatable CPU=${allocatableMatch[1]}, Memory=${allocatableMatch[2]}`);
          logInfo(`  Requested: CPU=${requestsMatch[1]}, Memory=${memoryRequestsMatch[1]}`);
        }
      } catch (nodeError) {
        // Ignore node check errors
      }
    } else if (describeOutput.includes('Pending')) {
      // Pod not assigned - check all nodes for available resources
      try {
        const nodesResult = await execa('kubectl', ['get', 'nodes', '-o', 'json'], { stdio: 'pipe' });
        const nodesData = JSON.parse(nodesResult.stdout);
        
        // Get pod resource requests
        const podResult = await execa('kubectl', ['get', 'pod', podName, '-n', namespace, '-o', 'json'], { stdio: 'pipe' });
        const podData = JSON.parse(podResult.stdout);
        
        let podCpuRequest = 0;
        let podMemoryRequest = 0;
        
        // Calculate pod resource requests
        if (podData.spec?.containers) {
          for (const container of podData.spec.containers) {
            const cpu = container.resources?.requests?.cpu || '0';
            const memory = container.resources?.requests?.memory || '0';
            
            // Convert CPU (e.g., "500m" = 500 millicores, "1" = 1000 millicores)
            const cpuMillicores = cpu.endsWith('m') ? parseInt(cpu) : parseFloat(cpu) * 1000;
            podCpuRequest += cpuMillicores;
            
            // Convert memory to bytes
            let memBytes = 0;
            if (memory.endsWith('Gi')) {
              memBytes = parseFloat(memory) * 1024 * 1024 * 1024;
            } else if (memory.endsWith('Mi')) {
              memBytes = parseFloat(memory) * 1024 * 1024;
            }
            podMemoryRequest += memBytes;
          }
        }
        
        // Check each node for available resources
        let foundSuitableNode = false;
        for (const node of nodesData.items || []) {
          const allocatable = node.status?.allocatable || {};
          const nodeCpu = allocatable.cpu || '0';
          const nodeMemory = allocatable.memory || '0';
          
          // Check if node has enough resources
          const nodeCpuMillicores = nodeCpu.endsWith('m') ? parseInt(nodeCpu) : parseFloat(nodeCpu) * 1000;
          let nodeMemBytes = 0;
          if (nodeMemory.endsWith('Gi')) {
            nodeMemBytes = parseFloat(nodeMemory) * 1024 * 1024 * 1024;
          } else if (nodeMemory.endsWith('Mi')) {
            nodeMemBytes = parseFloat(nodeMemory) * 1024 * 1024;
          }
          
          if (nodeCpuMillicores >= podCpuRequest && nodeMemBytes >= podMemoryRequest) {
            foundSuitableNode = true;
            break;
          }
        }
        
        if (!foundSuitableNode) {
          issues.push(`No node has sufficient resources (CPU: ${podCpuRequest}m, Memory: ${Math.round(podMemoryRequest/1024/1024)}Mi)`);
        }
      } catch (resourceError) {
        // Ignore resource check errors
      }
    }
    
    // Check for other scheduling issues
    const eventsMatch = describeOutput.match(/Events:\s*\n((?:.*\n)*)/);
    if (eventsMatch) {
      const events = eventsMatch[1];
      if (events.includes('0/') && events.includes('nodes are available')) {
        const nodeMatch = events.match(/(\d+)\/\d+\s+nodes?\s+are\s+available/i);
        if (nodeMatch && nodeMatch[1] === '0') {
          issues.push('No nodes are available to schedule this pod (check node taints, affinity, or resource constraints)');
        }
      }
    }
    
    return issues;
  } catch (error) {
    logWarn(`Could not diagnose resource issues for pod ${podName}: ${error}`);
    return [];
  }
}

async function installMinIO(ns: string) {
  logInfo('Installing MinIO for on-premises backup storage...');
  const { execa } = await import('execa');
  
  try {
    // Use internal ChartMuseum repository; external repos are not allowed
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
        logInfo('MinIO is already installed, checking installation...');
        
        // Check how many pods exist - warn if distributed mode
        try {
          const podsResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '-l', 'app.kubernetes.io/name=minio', '--no-headers'], { stdio: 'pipe' });
          const podCount = podsResult.stdout.trim().split('\n').filter(line => line.trim() && !line.includes('post-job')).length;
          if (podCount > 3) {
            logWarn(`⚠️  WARNING: Found ${podCount} MinIO pods - MinIO appears to be in distributed mode!`);
            logWarn(`    This will consume excessive resources (${podCount} pods × 1Gi memory = ${podCount}Gi minimum).`);
            logWarn(`    To fix: helm uninstall minio -n minio && kubectl delete namespace minio`);
            logWarn(`    Then re-run this installation to use standalone mode (1 pod).`);
          }
        } catch (podCheckError) {
          // Ignore pod check errors
        }
        
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
    
    // Install MinIO using Helm from external repo (bootstrap before ChartMuseum)
    // We use the external minio repo here because ChartMuseum doesn't exist yet
    logInfo('Adding MinIO Helm repository (for bootstrap)...');
    try {
      await execa('helm', ['repo', 'add', 'minio', 'https://charts.min.io/'], { stdio: 'pipe' });
    } catch (repoError) {
      // Repo might already exist
      logInfo('MinIO repo already added');
    }
    await execa('helm', ['repo', 'update'], { stdio: 'pipe' });
    
    // Install MinIO using Helm
    // Use --wait=false to prevent Helm from waiting for pods (we'll wait separately)
    // This avoids timeout issues with Helm's post-install hooks
    logInfo('Installing MinIO Helm chart from external repo (this may take a few minutes)...');
    try {
      await run('helm', [
        'upgrade', '--install', 'minio', 'minio/minio',  // Use external repo for bootstrap
        '--namespace', 'minio',
        '--set', 'mode=standalone',  // Use standalone mode (single pod) instead of distributed
        '--set', 'replicas=1',  // Explicitly set to 1 replica
        '--set', 'persistence.size=100Gi',
        '--set', 'persistence.storageClass=gp3',
        '--set', `rootUser=${minioAccessKey}`,  // Updated parameter name for newer MinIO charts
        '--set', `rootPassword=${minioSecretKey}`,  // Updated parameter name for newer MinIO charts
        '--set', 'resources.requests.memory=1Gi',
        '--set', 'resources.requests.cpu=500m',
        '--set', 'resources.limits.memory=2Gi',
        '--set', 'resources.limits.cpu=1000m',
        '--timeout', '10m',
        '--wait=false'  // Don't wait for resources - we'll wait manually
      ]);
    } catch (helmError) {
      // If Helm install failed, check what resources were created
      logWarn('Helm install had issues, checking what was created...');
      try {
        const podsResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '-o', 'json'], { stdio: 'pipe' });
        const podsData = JSON.parse(podsResult.stdout);
        if (podsData.items && podsData.items.length > 0) {
          logInfo(`Found ${podsData.items.length} MinIO pod(s) created`);
          podsData.items.forEach((pod: any) => {
            logInfo(`  Pod: ${pod.metadata.name}, Status: ${pod.status.phase}`);
          });
        }
        
        const pvcResult = await execa('kubectl', ['get', 'pvc', '-n', 'minio', '-o', 'json'], { stdio: 'pipe' });
        const pvcData = JSON.parse(pvcResult.stdout);
        if (pvcData.items && pvcData.items.length > 0) {
          logInfo(`Found ${pvcData.items.length} MinIO PVC(s) created`);
          pvcData.items.forEach((pvc: any) => {
            logInfo(`  PVC: ${pvc.metadata.name}, Status: ${pvc.status.phase}`);
          });
        }
      } catch (checkError) {
        // Ignore check errors
      }
      
      // Re-throw the error if it's not just a timeout issue
      if (!helmError.toString().includes('timeout') && !helmError.toString().includes('timed out')) {
        throw helmError;
      }
      // If it's a timeout, continue - we'll check pod status manually
      logWarn('Helm install timed out, but resources may have been created. Continuing with manual pod wait...');
    }
    
    logSuccess('MinIO Helm chart installation initiated');
    
    // Wait a moment for resources to be created
    await new Promise(resolve => setTimeout(resolve, 5000));
    
    // Fix sessionAffinity warning on headless services
    // This must be done early, right after Helm install, to prevent the warning
    logInfo('Fixing sessionAffinity warning on headless services...');
    try {
      // Get all services in the minio namespace
      const servicesResult = await execa('kubectl', ['get', 'services', '-n', 'minio', '-o', 'json'], { stdio: 'pipe' });
      const servicesData = JSON.parse(servicesResult.stdout);
      
      if (servicesData.items && servicesData.items.length > 0) {
        // Find all headless services (those with clusterIP: None)
        const headlessServices = servicesData.items.filter((svc: any) => 
          svc.spec.clusterIP === 'None' && svc.spec.sessionAffinity
        );
        
        if (headlessServices.length > 0) {
          logInfo(`Found ${headlessServices.length} headless service(s) with sessionAffinity that need patching`);
          
          for (const svc of headlessServices) {
            const svcName = svc.metadata.name;
            logInfo(`Removing sessionAffinity from service: ${svcName}`);
            try {
              await run('kubectl', ['patch', 'service', svcName, '-n', 'minio', '-p', '{"spec":{"sessionAffinity":null}}', '--type=merge'], { stdio: 'pipe' });
              logSuccess(`Fixed sessionAffinity on service: ${svcName}`);
            } catch (patchError) {
              logWarn(`Could not patch service ${svcName}: ${patchError}`);
            }
          }
        } else {
          logInfo('No headless services with sessionAffinity found (or already fixed)');
        }
      }
    } catch (patchError) {
      // Service might not exist yet or already fixed, log but don't fail
      logInfo('Note: Could not check/patch services (may not exist yet or already configured)');
    }
    
    // Check pod status before waiting
    logInfo('Checking MinIO pod status...');
    try {
      const statusResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '--no-headers'], { stdio: 'pipe' });
      if (statusResult.stdout.trim()) {
        logInfo('Current MinIO pods:');
        statusResult.stdout.trim().split('\n').forEach((line: string) => {
          logInfo(`  ${line}`);
        });
      } else {
        logWarn('No MinIO pods found yet');
      }
    } catch (error) {
      logWarn('Could not check pod status');
    }
    
    // Wait for MinIO pods to be ready (with periodic status updates)
    logInfo('Waiting for MinIO pods to be ready (this may take a few minutes)...');
    logInfo('Status updates will be provided every 30 seconds...');
    let podsReady = false;
    
    const waitStartTime = Date.now();
    const maxWaitTime = 10 * 60 * 1000; // 10 minutes
    const statusUpdateInterval = 30 * 1000; // 30 seconds
    let lastStatusUpdate = 0;
    let warnedAboutTooManyPods = false;
    
    // Try different label selectors
    const labelSelectors = [
      'app.kubernetes.io/name=minio',
      'app=minio',
      'release=minio',
      'app.kubernetes.io/instance=minio'
    ];
    
    // Poll for pod readiness with status updates
    while (Date.now() - waitStartTime < maxWaitTime && !podsReady) {
      const elapsed = Math.floor((Date.now() - waitStartTime) / 1000);
      const shouldUpdate = Date.now() - lastStatusUpdate >= statusUpdateInterval;
      
      if (shouldUpdate || elapsed === 0) {
        logInfo(`[${Math.floor(elapsed/60)}m ${elapsed%60}s] Checking MinIO pod status...`);
        lastStatusUpdate = Date.now();
      }
      
      // Try each label selector
      for (const selector of labelSelectors) {
        try {
          // Check if pods with this selector exist and are ready
          const checkResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '-l', selector, '-o', 'json'], { stdio: 'pipe' });
          const podsData = JSON.parse(checkResult.stdout);
          
          if (podsData.items && podsData.items.length > 0) {
            const readyPods = podsData.items.filter((pod: any) => {
              const ready = pod.status.containerStatuses?.[0]?.ready || false;
              return pod.status.phase === 'Running' && ready;
            });
            
            if (shouldUpdate) {
              logInfo(`  Found ${podsData.items.length} pod(s) with selector "${selector}"`);
              logInfo(`  Ready: ${readyPods.length}/${podsData.items.length}`);
              
              // Warn if too many pods (indicates distributed mode instead of standalone)
              if (podsData.items.length > 3 && !warnedAboutTooManyPods) {
                logWarn(`⚠️  WARNING: Found ${podsData.items.length} MinIO pods - this suggests distributed mode is active!`);
                logWarn(`    Expected only 1 pod in standalone mode. This will consume excessive resources.`);
                logWarn(`    If this is a fresh install, you may need to uninstall and reinstall with correct mode.`);
                warnedAboutTooManyPods = true;
              }
              
              // Show pod statuses and diagnose Pending pods
              for (const pod of podsData.items) {
                const phase = pod.status.phase || 'Unknown';
                const ready = pod.status.containerStatuses?.[0]?.ready ? 'Ready' : 'NotReady';
                const reason = pod.status.containerStatuses?.[0]?.state?.waiting?.reason || 
                              pod.status.containerStatuses?.[0]?.state?.waiting?.message || '';
                logInfo(`    - ${pod.metadata.name}: ${phase}/${ready}${reason ? ` (${reason})` : ''}`);
                
                // Diagnose resource issues for Pending pods
                if (phase === 'Pending' && elapsed >= 30) {  // Only diagnose after 30 seconds to avoid spam
                  const resourceIssues = await diagnoseResourceIssues(pod.metadata.name, 'minio');
                  if (resourceIssues.length > 0) {
                    logWarn(`    ⚠️  Resource issues detected for ${pod.metadata.name}:`);
                    resourceIssues.forEach(issue => logWarn(`      - ${issue}`));
                    logInfo(`    → Consider: Reducing MinIO resource requests or adding more nodes`);
                    logInfo(`    → Check node capacity: kubectl top nodes`);
                  }
                }
              }
            }
            
            // Check if all pods are ready
            if (readyPods.length === podsData.items.length && podsData.items.length > 0) {
              podsReady = true;
              logSuccess(`MinIO pods are ready! (matched selector: ${selector})`);
              logSuccess(`  ${readyPods.length} pod(s) ready in ${Math.floor(elapsed/60)}m ${elapsed%60}s`);
              break;
            }
          }
        } catch (error) {
          // Selector might not match or error - continue
        }
      }
      
      if (podsReady) break;
      
      // Wait 15 seconds before next check
      await new Promise(resolve => setTimeout(resolve, 15000));
    }
    
    if (!podsReady) {
      // Final attempt: wait for any pod in the namespace to be ready
      logWarn('Standard label selectors did not work, checking for any ready pods in minio namespace...');
      try {
        const anyPodsResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '--no-headers'], { stdio: 'pipe' });
        if (anyPodsResult.stdout.trim()) {
          const podLines = anyPodsResult.stdout.trim().split('\n');
          const readyPods = podLines.filter((line: string) => {
            const parts = line.split(/\s+/);
            const ready = parts[1];
            return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
          });
          
          if (readyPods.length > 0) {
            logSuccess(`Found ${readyPods.length} ready pod(s) in minio namespace`);
            podsReady = true;
          } else {
            logWarn('No ready pods found yet. Pod status:');
            podLines.forEach((line: string) => logWarn(`  ${line}`));
          }
        } else {
          logError('No pods found in minio namespace');
        }
      } catch (finalError) {
        logError(`Could not verify pod status: ${finalError}`);
      }
    }
    
    if (podsReady) {
      logSuccess('MinIO pods are ready');
    } else {
      logWarn('MinIO pods may not be fully ready, but installation will continue');
      logWarn('MinIO may become ready shortly. You can check with: kubectl get pods -n minio');
      
      // Check if there are any pods at all (even if not ready)
      try {
        const checkPodsResult = await execa('kubectl', ['get', 'pods', '-n', 'minio', '--no-headers'], { stdio: 'pipe' });
        if (checkPodsResult.stdout.trim()) {
          logInfo('MinIO pods exist (may still be starting):');
          checkPodsResult.stdout.trim().split('\n').forEach((line: string) => {
            logInfo(`  ${line}`);
          });
        } else {
          logError('No MinIO pods found - installation may have failed');
          throw new Error('MinIO installation failed: No pods created');
        }
      } catch (checkError) {
        logError('Could not verify MinIO pod status');
        throw new Error('MinIO installation failed: Could not verify pod status');
      }
    }
    
    // Fetch actual credentials from MinIO secret (MinIO may generate its own credentials)
    logInfo('Fetching MinIO credentials from secret...');
    let finalAccessKey = minioAccessKey;
    let finalSecretKey = minioSecretKey;
    
    // Wait a bit for MinIO to generate credentials if needed
    await new Promise(resolve => setTimeout(resolve, 5000));
    
    // Try multiple times to get credentials (MinIO might take a moment to create the secret)
    for (let attempt = 1; attempt <= 10; attempt++) {
      try {
        const secretResult = await execa('kubectl', ['get', 'secret', 'minio', '-n', 'minio', '-o', 'jsonpath={.data.rootUser}', '--ignore-not-found'], { stdio: 'pipe' });
        if (secretResult.stdout && secretResult.stdout.trim()) {
          const fetchedAccessKey = Buffer.from(secretResult.stdout.trim(), 'base64').toString();
          const secretKeyResult = await execa('kubectl', ['get', 'secret', 'minio', '-n', 'minio', '-o', 'jsonpath={.data.rootPassword}', '--ignore-not-found'], { stdio: 'pipe' });
          if (secretKeyResult.stdout && secretKeyResult.stdout.trim()) {
            const fetchedSecretKey = Buffer.from(secretKeyResult.stdout.trim(), 'base64').toString();
            if (fetchedAccessKey && fetchedSecretKey) {
              finalAccessKey = fetchedAccessKey;
              finalSecretKey = fetchedSecretKey;
              logSuccess(`✓ Using MinIO credentials from secret (attempt ${attempt})`);
              break;
            }
          }
        }
      } catch (secretError) {
        // Continue trying
      }
      
      if (attempt < 10) {
        logInfo(`Waiting for MinIO secret to be ready (attempt ${attempt}/10)...`);
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    }
    
    if (finalAccessKey === minioAccessKey && finalSecretKey === minioSecretKey) {
      logInfo('Using provided/default MinIO credentials');
    }
    
    return { accessKey: finalAccessKey, secretKey: finalSecretKey };
    } catch (error) {
    logError(`Failed to install MinIO: ${error}`);
        throw error;
      }
    }
    
async function createMinIOCredentialsSecret(ns: string, accessKey: string, secretKey: string) {
  logInfo('Creating MinIO credentials secret...');
  const { execa } = await import('execa');
  const { readFile } = await import('fs/promises');
  const { resolve } = await import('path');
  
  try {
    const templatePath = resolve(process.cwd(), 'templates', 'minio-credentials-secret.yaml');
    let content = await readFile(templatePath, 'utf8');
    content = content
      .replace(/\{\{NAMESPACE\}\}/g, ns)
      .replace(/\{\{AWS_ACCESS_KEY_ID\}\}/g, accessKey)
      .replace(/\{\{AWS_SECRET_ACCESS_KEY\}\}/g, secretKey);

    const proc = execa('kubectl', ['apply', '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
    proc.stdin?.write(content);
    proc.stdin?.end();
    await proc;

    logSuccess('MinIO credentials secret created');
  } catch (error) {
    logWarn(`Failed to create MinIO credentials secret: ${error}`);
    throw error;
  }
}

async function installCluster(ns: string, name: string, nodes: number, accountId: string) {
  logInfo(`Installing Percona cluster "${name}" with ${nodes} nodes via Helm...`);
  logInfo('This may take a few minutes...');
  const values = await clusterValues(nodes, accountId);
  const { execa } = await import('execa');
  const proc = execa('helm', ['upgrade', '--install', name, 'internal/pxc-db', '-n', ns, '-f', '-'], { stdio: ['pipe', 'inherit', 'inherit'] });
  proc.stdin?.write(values);
  proc.stdin?.end();
  await proc;
  logSuccess('Percona cluster Helm chart installed successfully');
  logInfo('Waiting for cluster pods to start...');
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
  logInfo('Status updates will be provided every 30 seconds...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 5 * 60 * 1000; // 5 minutes
  const statusUpdateInterval = 30 * 1000; // 30 seconds
  let lastStatusUpdate = 0;
  
  while (Date.now() - startTime < timeout) {
    try {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      const shouldUpdate = Date.now() - lastStatusUpdate >= statusUpdateInterval || elapsed === 0;
      
      if (shouldUpdate) {
        logInfo(`[${Math.floor(elapsed/60)}m ${elapsed%60}s] Checking Percona operator status...`);
        lastStatusUpdate = Date.now();
      }
      
      // Check for any pods in the namespace first
      const allPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '--no-headers'], { stdio: 'pipe' });
      const allPods = allPodsResult.stdout.trim().split('\n').filter(line => line.trim());
      
      if (shouldUpdate) {
        logInfo(`  Found ${allPods.length} total pod(s) in namespace ${ns}`);
      }
      
      if (allPods.length > 0 && shouldUpdate) {
        logInfo('  All pods in namespace:');
        allPods.forEach((pod, index) => {
          logInfo(`    ${index + 1}. ${pod}`);
        });
      }
      
      // Check for operator pods specifically
      const operatorPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster-operator', '--no-headers'], { stdio: 'pipe' });
      const operatorPods = operatorPodsResult.stdout.trim().split('\n').filter(line => line.trim());
      
      if (shouldUpdate) {
        logInfo(`  Found ${operatorPods.length} operator pod(s) with label 'app.kubernetes.io/name=percona-xtradb-cluster-operator'`);
      }
      
      if (operatorPods.length === 0) {
        // Try alternative labels (only log when updating)
        if (shouldUpdate) {
          logInfo('  Trying alternative operator pod labels...');
        }
        const altLabels = [
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
              if (shouldUpdate) {
                logInfo(`  Found ${altPods.length} pod(s) with label '${label}':`);
                altPods.forEach((pod, index) => {
                  logInfo(`    ${index + 1}. ${pod}`);
                });
              }
              foundOperatorPods = altPods;
              workingLabel = label;
              break; // Use the first working label
            }
          } catch (altError) {
            // Ignore label errors
          }
        }
        
        if (foundOperatorPods.length > 0) {
          if (shouldUpdate) {
            logInfo(`  Using operator pods found with label '${workingLabel}'`);
          }
          const readyPods = foundOperatorPods.filter(line => {
            const parts = line.split(/\s+/);
            const ready = parts[1];
            return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
          });
          
          if (readyPods.length > 0) {
            logSuccess(`Percona operator is ready! (${readyPods.length} pod(s) ready in ${Math.floor(elapsed/60)}m ${elapsed%60}s)`);
            return;
          } else if (shouldUpdate) {
            logInfo(`  Operator pods starting: ${foundOperatorPods.length} found, ${readyPods.length} ready`);
          }
        } else if (shouldUpdate) {
          logInfo(`  Operator pods not found yet`);
        }
      } else {
        if (shouldUpdate) {
          logInfo(`  Operator pods found: ${operatorPods.length}`);
          operatorPods.forEach((pod, index) => {
            logInfo(`    ${index + 1}. ${pod}`);
          });
        }
        
        const readyPods = operatorPods.filter(line => {
          const parts = line.split(/\s+/);
          const ready = parts[1];
          return ready.includes('/') && ready.split('/')[0] === ready.split('/')[1];
        });
        
        if (readyPods.length > 0) {
          logSuccess(`Percona operator is ready! (${readyPods.length} pod(s) ready in ${Math.floor(elapsed/60)}m ${elapsed%60}s)`);
          return;
        } else if (shouldUpdate) {
          logInfo(`  Operator pods starting: ${operatorPods.length} found, ${readyPods.length} ready`);
        }
      }
      
      // Wait 15 seconds before next check
      await new Promise(resolve => setTimeout(resolve, 15000));
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
      // PITR pods have names like: pxc-cluster-pxc-db-pitr-... (should be excluded)
      if (component === 'proxysql' || (podName.includes('proxysql') && !podName.includes('operator'))) {
        // Check ProxySQL first since it also contains 'pxc' in the name
        if (!proxysqlPodsByZone.has(zone)) {
          proxysqlPodsByZone.set(zone, []);
        }
        proxysqlPodsByZone.get(zone)!.push(podName);
      } else if (component === 'pxc' || (podName.includes('-pxc-') && !podName.includes('operator') && !podName.includes('proxysql') && !podName.includes('pitr'))) {
        // Only include actual PXC database pods, not PITR or other auxiliary pods
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
  logInfo('Status updates will be provided every 30 seconds...');
  const { execa } = await import('execa');
  const startTime = Date.now();
  const timeout = 15 * 60 * 1000; // 15 minutes
  const statusUpdateInterval = 30 * 1000; // 30 seconds
  let lastStatusUpdate = 0;
  
  // Track previous state to detect when stuck
  let lastPxcCount = -1;
  let lastProxysqlCount = -1;
  let lastStatus = '';
  let lastPxcPodStates: Map<string, string> = new Map();
  let stuckSince: Map<string, number> = new Map();
  
  async function diagnoseStuckPod(podName: string, namespace: string) {
    logInfo(`\n🔍 Diagnosing stuck pod: ${podName}`);
    try {
      // Get pod describe output
      const describeResult = await execa('kubectl', ['describe', 'pod', podName, '-n', namespace], { stdio: 'pipe' });
      const describeOutput = describeResult.stdout;
      
      // Extract events section
      const eventsMatch = describeOutput.match(/Events:\s*\n((?:.*\n)*)/);
      if (eventsMatch) {
        logInfo('📋 Recent events:');
        const events = eventsMatch[1].trim().split('\n').slice(-8); // Last 8 events
        events.forEach(event => {
          if (event.trim()) {
            // Format events better
            const parts = event.trim().split(/\s{2,}/);
            if (parts.length >= 3) {
              logInfo(`  ${parts[0]} ${parts[1]}: ${parts.slice(2).join(' ')}`);
            } else {
              logInfo(`  ${event.trim()}`);
            }
          }
        });
      }
      
      // Check for common issues and provide actionable info
      if (describeOutput.includes('Insufficient cpu') || describeOutput.includes('Insufficient memory')) {
        logWarn('⚠️  Insufficient node resources - pod cannot be scheduled');
        logInfo('   → Check node capacity: kubectl top nodes');
        logInfo('   → Consider reducing resource requests or adding more nodes');
      }
      
      if (describeOutput.includes('persistentvolumeclaim')) {
        logWarn('⚠️  Pod may be waiting for PersistentVolumeClaim');
        // Extract PVC name
        const pvcMatch = describeOutput.match(/persistentvolumeclaim[^\s]*\s+([^\s]+)/i);
        if (pvcMatch) {
          const pvcName = pvcMatch[1];
          logInfo(`   → Checking PVC: ${pvcName}`);
          try {
            const pvcResult = await execa('kubectl', ['get', 'pvc', pvcName, '-n', namespace, '-o', 'json'], { stdio: 'pipe' });
            const pvc = JSON.parse(pvcResult.stdout);
            if (pvc.status.phase === 'Pending') {
              logWarn(`   → PVC ${pvcName} is still Pending - may be waiting for storage provisioner`);
              logInfo(`   → Check storage class: kubectl get storageclass ${pvc.spec.storageClassName || 'default'}`);
            }
          } catch (pvcError) {
            logWarn(`   → Could not check PVC status: ${pvcError}`);
          }
        }
      }
      
      if (describeOutput.includes('nodeSelector') || describeOutput.includes('node affinity')) {
        logWarn('⚠️  Pod has scheduling constraints - may not match any nodes');
      }
      
      if (describeOutput.includes('taint')) {
        logWarn('⚠️  Pod may not tolerate node taints');
        logInfo('   → Check node taints: kubectl describe nodes');
      }
      
      // Check node resources if pod has been assigned to a node
      const nodeMatch = describeOutput.match(/Node:\s+([^\s]+)/);
      if (nodeMatch && !describeOutput.includes('Pending')) {
        const nodeName = nodeMatch[1];
        logInfo(`   → Pod assigned to node: ${nodeName}`);
        try {
          const nodeResult = await execa('kubectl', ['describe', 'node', nodeName], { stdio: 'pipe' });
          const nodeOutput = nodeResult.stdout;
          // Check for resource pressure
          if (nodeOutput.includes('MemoryPressure') || nodeOutput.includes('DiskPressure') || nodeOutput.includes('PIDPressure')) {
            logWarn(`   → Node ${nodeName} is under pressure`);
          }
        } catch (nodeError) {
          // Ignore node check errors
        }
      } else if (describeOutput.includes('Pending')) {
        logWarn('⚠️  Pod is Pending - not assigned to any node yet');
        logInfo('   → This usually indicates scheduling constraints or resource limitations');
      }
      
    } catch (error) {
      logWarn(`Could not diagnose pod ${podName}: ${error}`);
    }
  }
  
  while (Date.now() - startTime < timeout) {
    try {
      // First check if PXC custom resource exists
      let pxcExists = false;
      try {
        await execa('kubectl', ['get', 'pxc', pxcResourceName, '-n', ns], { stdio: 'pipe' });
        pxcExists = true;
      } catch (error) {
        if (error.toString().includes('NotFound')) {
          // Log status updates every 30 seconds
          const elapsed = Math.round((Date.now() - startTime) / 1000);
          const shouldUpdate = Date.now() - lastStatusUpdate >= statusUpdateInterval || elapsed === 0;
          if (shouldUpdate) {
            logInfo(`[${Math.floor(elapsed/60)}m ${elapsed%60}s] Waiting for operator to create PXC resource...`);
            lastStatusUpdate = Date.now();
          }
        } else {
          logWarn(`Error checking PXC resource existence: ${error}`);
        }
      }
      
      if (!pxcExists) {
        await new Promise(resolve => setTimeout(resolve, 15000));
        continue;
      }
      
      // Check PXC custom resource status
      const pxcResult = await execa('kubectl', ['get', 'pxc', pxcResourceName, '-n', ns, '-o', 'json'], { stdio: 'pipe' });
      const pxc = JSON.parse(pxcResult.stdout);
      
      const pxcCount = typeof pxc.status?.pxc === 'number' ? pxc.status.pxc : (pxc.status?.pxc?.ready || 0);
      const proxysqlCount = typeof pxc.status?.proxysql === 'number' ? pxc.status.proxysql : (pxc.status?.proxysql?.ready || 0);
      const status = pxc.status?.state || pxc.status?.status || 'unknown';
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      
      // Get PXC pod statuses
      let currentPxcPodStates: Map<string, string> = new Map();
      try {
        const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster', '-o', 'json'], { stdio: 'pipe' });
        const podsData = JSON.parse(podsResult.stdout);
        for (const pod of podsData.items || []) {
          if (pod.metadata.name.includes(`${pxcResourceName}-pxc-`)) {
            const podStatus = pod.status.phase || 'Unknown';
            const ready = pod.status.containerStatuses?.[0]?.ready ? 'Ready' : 'NotReady';
            currentPxcPodStates.set(pod.metadata.name, `${podStatus}/${ready}`);
            
            // Track stuck pods (Pending for > 2 minutes or same status for > 5 minutes)
            const stateKey = `${pod.metadata.name}:${podStatus}`;
            const now = Date.now();
            if (lastPxcPodStates.get(pod.metadata.name) === `${podStatus}/${ready}`) {
              if (!stuckSince.has(stateKey)) {
                stuckSince.set(stateKey, now);
              }
              const stuckDuration = now - (stuckSince.get(stateKey) || now);
              
              // If pod is Pending for > 2 minutes or same status for > 5 minutes, diagnose it
              if (podStatus === 'Pending' && stuckDuration > 2 * 60 * 1000) {
                if (elapsed % 120 === 0) { // Only diagnose every 2 minutes to avoid spam
                  await diagnoseStuckPod(pod.metadata.name, ns);
                }
              } else if (stuckDuration > 5 * 60 * 1000 && elapsed % 180 === 0) {
                await diagnoseStuckPod(pod.metadata.name, ns);
              }
            } else {
              // Status changed, reset stuck timer
              stuckSince.delete(stateKey);
            }
          }
        }
      } catch (error) {
        // Ignore pod check errors
      }
      
      // Log status updates every 30 seconds or when status changes
      const statusChanged = pxcCount !== lastPxcCount || proxysqlCount !== lastProxysqlCount || status !== lastStatus;
      const shouldLogSummary = elapsed === 0 || Date.now() - lastStatusUpdate >= statusUpdateInterval || statusChanged;
      
      if (shouldLogSummary) {
        lastStatusUpdate = Date.now();
        logInfo(`[${Math.floor(elapsed/60)}m ${elapsed%60}s] 📊 Cluster Status: PXC ${pxcCount}/${nodes} ready, ProxySQL ${proxysqlCount}/${nodes} ready, State: ${status}`);
        
        // Show pod states if there are issues
        if (pxcCount < nodes || currentPxcPodStates.size < nodes) {
          logInfo(`   PXC Pods: ${Array.from(currentPxcPodStates.entries()).map(([name, state]) => `${name.split('-').pop()}:${state}`).join(', ') || 'None yet'}`);
        }
        
        // Track changes
        lastPxcCount = pxcCount;
        lastProxysqlCount = proxysqlCount;
        lastStatus = status;
        lastPxcPodStates = new Map(currentPxcPodStates);
      }
      
      // Only check ProxySQL pods periodically or when status changes (to reduce spam)
      if (shouldLogSummary && proxysqlCount < nodes) {
          try {
            const proxysqlPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/component=proxysql', '-o', 'json'], { stdio: 'pipe' });
            const proxysqlPods = JSON.parse(proxysqlPodsResult.stdout);
            
          if (proxysqlPods.items && proxysqlPods.items.length > 0) {
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
              }
            }
            if (zones.size >= 2) {
              logSuccess(`✓ ProxySQL pods distributed across ${zones.size} availability zones: ${Array.from(zones).join(', ')}`);
          }
        }
      } catch (error) {
          // Ignore errors
        }
      }
      
      // Check for failed pods (only when status changes or periodically)
      if (shouldLogSummary) {
      try {
        const failedPodsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '--field-selector=status.phase=Failed', '--no-headers'], { stdio: 'pipe' });
        const failedPods = failedPodsResult.stdout.trim().split('\n').filter(line => line.trim());
        if (failedPods.length > 0) {
            logWarn(`⚠️  Found ${failedPods.length} failed pods:`);
          failedPods.forEach(pod => logWarn(`  Failed: ${pod}`));
        }
      } catch (error) {
          // Ignore errors
      }
      
        // Check Kubernetes events for warnings (only periodically)
        if (elapsed % 180 === 0 && elapsed > 0) {
        try {
          const eventsResult = await execa('kubectl', ['get', 'events', '-n', ns, '--sort-by=.lastTimestamp', '--field-selector=type=Warning', '--no-headers'], { stdio: 'pipe' });
            const warningEvents = eventsResult.stdout.trim().split('\n').filter(line => line.trim()).slice(-3); // Last 3 warnings
          if (warningEvents.length > 0) {
              logWarn(`⚠️  Recent warning events:`);
            warningEvents.forEach(event => logWarn(`  ${event}`));
          }
        } catch (error) {
            // Ignore errors
          }
        }
      }
      
      // Check if cluster is ready
      try {
        const podsResult = await execa('kubectl', ['get', 'pods', '-n', ns, '-l', 'app.kubernetes.io/name=percona-xtradb-cluster', '--no-headers'], { stdio: 'pipe' });
        const podLines = podsResult.stdout.trim().split('\n').filter(line => line.includes(`${pxcResourceName}-pxc-`));
      
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
            logSuccess(`🎉 Percona cluster ${pxcResourceName} is ready with ${nodes} PXC nodes and ${proxysqlCount} ProxySQL pods!`);
                  logSuccess(`📊 Final Status: PXC ${pxcCount}/${nodes}, ProxySQL ${proxysqlCount}/3, State: ${pxc.status?.state || status}`);
                  return;
                }
        }
      } catch (error) {
        // Ignore errors, will check again next iteration
              }
      
      await new Promise(resolve => setTimeout(resolve, 15000)); // Wait 15 seconds before next check
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

async function verifyChartMuseumReady(): Promise<boolean> {
  const { execa } = await import('execa');
  
  try {
    // Check if ChartMuseum pod is running
    const podsResult = await execa('kubectl', ['get', 'pods', '-n', 'chartmuseum', '-l', 'app.kubernetes.io/name=chartmuseum', '-o', 'json'], { stdio: 'pipe' });
    const podsData = JSON.parse(podsResult.stdout);
    const readyPods = podsData.items?.filter((pod: any) => {
      const status = pod.status?.containerStatuses?.[0];
      return status?.ready === true && pod.status?.phase === 'Running';
    }) || [];
    
    if (readyPods.length === 0) {
      logInfo('ChartMuseum pod is not ready yet');
      return false;
    }
    
    // Check if ChartMuseum service is accessible via port-forward test
    // We'll verify by checking if we can list charts (which requires the service to be ready)
    // For now, just having a ready pod is sufficient - the service will be ready too
    return true;
  } catch (error) {
    return false;
  }
}

async function installChartMuseum() {
  logInfo('Installing ChartMuseum for internal Helm chart repository...');
  const { execa } = await import('execa');
  const { resolve } = await import('path');
  
  // Check if ChartMuseum is already installed
  let chartmuseumInstalled = false;
  try {
    await execa('kubectl', ['get', 'namespace', 'chartmuseum'], { stdio: 'pipe' });
    const helmListResult = await execa('helm', ['list', '-n', 'chartmuseum', '--output', 'json'], { stdio: 'pipe' });
    const releases = JSON.parse(helmListResult.stdout);
    if (releases.some((r: any) => r.name === 'chartmuseum')) {
      chartmuseumInstalled = true;
      logInfo('ChartMuseum appears to be installed, verifying it is ready...');
      
      // Wait up to 2 minutes for ChartMuseum to be ready
      const maxWaitTime = 120000; // 2 minutes
      const checkInterval = 5000; // 5 seconds
      const startTime = Date.now();
      
      while (Date.now() - startTime < maxWaitTime) {
        if (await verifyChartMuseumReady()) {
          logSuccess('✓ ChartMuseum is ready');
          return;
        }
        logInfo('Waiting for ChartMuseum to be ready...');
        await new Promise(resolve => setTimeout(resolve, checkInterval));
      }
      
      logWarn('ChartMuseum is installed but not ready after waiting. Will attempt to continue...');
      return;
    }
  } catch (error) {
    // ChartMuseum not installed, continue with installation
  }
  
  // Run the setup script
  try {
    const scriptPath = resolve(process.cwd(), 'scripts', 'setup-chartmuseum.sh');
    logInfo('Running ChartMuseum setup script...');
    await run('bash', [scriptPath], { stdio: 'inherit' });
    
    // Wait for ChartMuseum to be ready after installation
    logInfo('Waiting for ChartMuseum to be ready...');
    const maxWaitTime = 300000; // 5 minutes
    const checkInterval = 5000; // 5 seconds
    const startTime = Date.now();
    
    while (Date.now() - startTime < maxWaitTime) {
      if (await verifyChartMuseumReady()) {
        logSuccess('✓ ChartMuseum installed and ready');
        return;
      }
      logInfo('Waiting for ChartMuseum to be ready...');
      await new Promise(resolve => setTimeout(resolve, checkInterval));
    }
    
    logWarn('ChartMuseum installation completed but not fully ready. Proceeding anyway...');
  } catch (error) {
    logError(`Failed to install ChartMuseum: ${error}`);
    logError('ChartMuseum is required for the internal Helm chart repository');
    logError('You can install it manually with: ./scripts/setup-chartmuseum.sh');
    throw error;
  }
}

async function verifyChartsInChartMuseum(): Promise<boolean> {
  const { execa } = await import('execa');
  
  try {
    // Check if internal repo exists and has charts
    const searchResult = await execa('helm', ['search', 'repo', 'internal', '--output', 'json'], { stdio: 'pipe' });
    const charts = JSON.parse(searchResult.stdout);
    
    // Check for required charts: minio, pxc-operator, pxc-db
    const requiredCharts = ['minio', 'pxc-operator', 'pxc-db'];
    const foundCharts = charts.map((c: any) => c.name.replace('internal/', ''));
    const missingCharts = requiredCharts.filter(chart => !foundCharts.includes(chart));
    
    if (missingCharts.length > 0) {
      logInfo(`Missing charts in ChartMuseum: ${missingCharts.join(', ')}`);
      return false;
    }
    
    return true;
  } catch (error) {
    // If search fails, charts might not be available
    return false;
  }
}

async function mirrorChartsToChartMuseum() {
  logInfo('Mirroring charts to ChartMuseum...');
  const { resolve } = await import('path');
  const { execa } = await import('execa');
  
  // First check if charts are already available
  try {
    // Make sure internal repo is added
    try {
      await execa('helm', ['repo', 'add', 'internal', 'http://chartmuseum.chartmuseum.svc.cluster.local'], { stdio: 'pipe' });
    } catch (error) {
      // Repo might already exist, that's fine
    }
    await execa('helm', ['repo', 'update'], { stdio: 'pipe' });
    
    if (await verifyChartsInChartMuseum()) {
      logInfo('Required charts are already available in ChartMuseum, skipping mirroring');
      return;
    }
  } catch (error) {
    // If verification fails, proceed with mirroring
    logInfo('Could not verify charts, proceeding with mirroring...');
  }
  
  try {
    // Run the mirror script
    const scriptPath = resolve(process.cwd(), 'scripts', 'mirror-charts.sh');
    logInfo('Running chart mirroring script...');
    await run('bash', [scriptPath], { stdio: 'inherit' });
    
    // Verify charts are now available
    await execa('helm', ['repo', 'update'], { stdio: 'pipe' });
    if (await verifyChartsInChartMuseum()) {
      logSuccess('✓ Charts mirrored to ChartMuseum successfully');
    } else {
      logWarn('Charts were mirrored but verification failed. Proceeding anyway...');
    }
  } catch (error) {
    logError(`Failed to mirror charts: ${error}`);
    logError('Chart mirroring is required for the internal Helm chart repository');
    logError('You can run it manually with: ./scripts/mirror-charts.sh');
    throw error;
  }
}

async function uninstallChartMuseum() {
  logInfo('Uninstalling ChartMuseum...');
  const { execa } = await import('execa');
  
  try {
    // Check if ChartMuseum is installed
    try {
      await execa('kubectl', ['get', 'namespace', 'chartmuseum'], { stdio: 'pipe' });
    } catch (error) {
      logInfo('ChartMuseum namespace not found - already uninstalled');
      return;
    }
    
    // Uninstall Helm release (non-fatal if not installed)
    try {
      await run('helm', ['uninstall', 'chartmuseum', '-n', 'chartmuseum'], { stdio: 'pipe' });
      logSuccess('✓ ChartMuseum Helm release uninstalled');
    } catch (error: any) {
      const msg = error?.toString?.() || '';
      if (msg.includes('release: not found') || msg.includes('Release not loaded') || msg.includes('not found')) {
        logInfo('ChartMuseum Helm release not found; continuing uninstall.');
      } else {
        logWarn(`Failed to uninstall ChartMuseum Helm release: ${msg}`);
      }
    }
    
    // Delete namespace (will also delete all resources)
    try {
      await run('kubectl', ['delete', 'namespace', 'chartmuseum', '--timeout=60s'], { stdio: 'pipe' });
      logSuccess('✓ ChartMuseum namespace deleted');
    } catch (error) {
      logWarn(`Failed to delete ChartMuseum namespace: ${error}`);
      
      // Try to force-clean the namespace
      try {
        logInfo('Attempting to force-clean chartmuseum namespace...');
        
        // Remove namespace finalizers
        await run('kubectl', ['patch', 'namespace', 'chartmuseum', '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
        logInfo('✓ ChartMuseum namespace finalizers removed');
        
        // Wait for cleanup
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        // Try delete again
        try {
          await execa('kubectl', ['get', 'namespace', 'chartmuseum'], { stdio: 'pipe' });
          // Still exists, force delete
          await run('kubectl', ['delete', 'namespace', 'chartmuseum', '--force', '--grace-period=0'], { stdio: 'pipe' });
          logSuccess('✓ ChartMuseum namespace force deleted');
        } catch (checkError) {
          // Namespace is gone
          logSuccess('✓ ChartMuseum namespace deleted');
        }
      } catch (forceError) {
        logWarn(`Could not force-clean chartmuseum namespace: ${forceError}`);
        logWarn('You may need to delete it manually: kubectl delete namespace chartmuseum --force');
      }
    }
  } catch (error) {
    logWarn(`Error during ChartMuseum uninstall: ${error}`);
  }
}

async function installLitmusChaos() {
  logInfo('Installing LitmusChaos...');
  const { execa } = await import('execa');
  
  try {
    // Ensure namespace exists
    await run('kubectl', ['create', 'namespace', 'litmus'], { stdio: 'pipe' }).catch(() => {});
    
    // Install LitmusChaos exclusively from internal ChartMuseum
    logInfo('Installing LitmusChaos from internal Helm repository...');
    try {
      await run('helm', [
        'upgrade', '--install', 'litmus', 'internal/litmus',
        '--namespace', 'litmus',
        '--set', 'portal.frontend.service.type=NodePort',
        '--wait',
        '--timeout', '10m'
      ]);
    } catch (helmError) {
      logError('Helm installation failed or timed out!');
      logError('Checking pod status...');
      try {
        const podStatus = await execa('kubectl', ['get', 'pods', '-n', 'litmus'], { stdio: 'pipe' });
        logError(podStatus.stdout);
      } catch {
        // Ignore kubectl errors
      }
      throw helmError;
    }
    
    logInfo('Helm installation completed. Waiting for all pods to be ready...');
    
    // Wait and monitor pods with explicit ImagePullBackOff detection
    const maxWait = 600; // 10 minutes
    const interval = 10; // 10 seconds
    let elapsed = 0;
    
    while (elapsed < maxWait) {
      try {
        const pods = await execa('kubectl', ['get', 'pods', '-n', 'litmus', '-o', 'json'], { stdio: 'pipe' });
        const podList = JSON.parse(pods.stdout);
        
        // Check for ImagePullBackOff or ErrImagePull
        const errorPods = podList.items.filter((pod: any) => {
          const phase = pod.status.phase;
          const waitingReason = pod.status.containerStatuses?.[0]?.state?.waiting?.reason || '';
          return phase === 'ImagePullBackOff' || 
                 phase === 'ErrImagePull' || 
                 waitingReason === 'ImagePullBackOff' || 
                 waitingReason === 'ErrImagePull';
        });
        
        if (errorPods.length > 0) {
          logError('❌ CRITICAL: ImagePullBackOff detected!');
          logError('Failing pods:');
          for (const pod of errorPods) {
            const image = pod.spec.containers?.[0]?.image || 'unknown';
            const reason = pod.status.containerStatuses?.[0]?.state?.waiting?.reason || pod.status.phase;
            logError(`  - ${pod.metadata.name}: ${reason}`);
            logError(`    Image: ${image}`);
          }
          logError('');
          logError('Installation FAILED due to image pull errors!');
          throw new Error('ImagePullBackOff detected - installation failed');
        }
        
        // Check if all pods are running
        const totalPods = podList.items.length;
        const runningPods = podList.items.filter((p: any) => p.status.phase === 'Running');
        
        if (totalPods > 0 && runningPods.length === totalPods) {
          logSuccess(`✓ All ${runningPods.length} pods are running!`);
          break;
        }
        
        // Show progress every 30 seconds
        if (elapsed % 30 === 0 || runningPods.length > 0) {
          logInfo(`[${elapsed}s] Pod status: ${runningPods.length}/${totalPods} running`);
          for (const pod of podList.items) {
            if (pod.status.phase !== 'Running') {
              const reason = pod.status.containerStatuses?.[0]?.state?.waiting?.reason || '';
              logInfo(`  - ${pod.metadata.name}: ${pod.status.phase} ${reason ? `(${reason})` : ''}`);
            }
          }
        }
      } catch (checkError: any) {
        if (checkError.message && checkError.message.includes('ImagePullBackOff')) {
          throw checkError; // Re-throw ImagePullBackOff errors
        }
        logInfo(`[${elapsed}s] Waiting for pods to appear...`);
      }
      
      await new Promise(resolve => setTimeout(resolve, interval * 1000));
      elapsed += interval;
    }
    
    // Final verification
    logInfo('');
    logInfo('=== FINAL POD STATUS ===');
    try {
      const finalPods = await execa('kubectl', ['get', 'pods', '-n', 'litmus'], { stdio: 'pipe' });
      logInfo(finalPods.stdout);
      
      if (finalPods.stdout.includes('ImagePullBackOff') || finalPods.stdout.includes('ErrImagePull')) {
        logError('❌ Installation FAILED: Pods still in ImagePullBackOff state!');
        throw new Error('ImagePullBackOff detected in final check');
      }
      
      // Verify all pods are ready
      const readyCheck = await execa('kubectl', ['get', 'pods', '-n', 'litmus', '--field-selector=status.phase=Running', '--no-headers'], { stdio: 'pipe' });
      const readyCount = readyCheck.stdout.split('\n').filter(l => l.trim()).length;
      const totalCheck = await execa('kubectl', ['get', 'pods', '-n', 'litmus', '--no-headers'], { stdio: 'pipe' });
      const totalCount = totalCheck.stdout.split('\n').filter(l => l.trim()).length;
      
      if (readyCount < totalCount) {
        logWarn(`⚠ Not all pods are running yet (${readyCount}/${totalCount})`);
      } else {
        logSuccess(`✓ All ${totalCount} pods are ready!`);
      }
    } catch (finalCheckError) {
      logWarn(`Could not verify final pod status: ${finalCheckError}`);
    }
    
    // Optionally verify CRDs were installed by the Helm chart
    logInfo('Verifying LitmusChaos CRDs...');
    await execa('kubectl', ['get', 'crd', 'chaosengines.litmuschaos.io'], { stdio: 'pipe' });
    
    logSuccess('✓ LitmusChaos installed successfully');
  } catch (error) {
    logWarn(`Failed to install LitmusChaos: ${error}`);
    logWarn('You can install it manually later with: ./scripts/install-litmus.sh');
  }
}

async function uninstallLitmusChaos() {
  logInfo('Uninstalling LitmusChaos...');
  const { execa } = await import('execa');
  
  try {
    // Check if LitmusChaos is installed
    try {
      await execa('kubectl', ['get', 'namespace', 'litmus'], { stdio: 'pipe' });
    } catch (error) {
      logInfo('LitmusChaos namespace not found - already uninstalled');
      return;
    }
    
    // Uninstall Helm release (non-fatal if not installed)
    try {
      await run('helm', ['uninstall', 'litmus', '-n', 'litmus'], { stdio: 'pipe' });
      logSuccess('✓ LitmusChaos Helm release uninstalled');
    } catch (error: any) {
      const msg = error?.toString?.() || '';
      if (msg.includes('release: not found') || msg.includes('Release not loaded') || msg.includes('not found')) {
        logInfo('LitmusChaos Helm release not found; continuing uninstall.');
      } else {
        logWarn(`Failed to uninstall LitmusChaos Helm release: ${msg}`);
      }
    }
    
    // Delete namespace (will also delete all resources)
    try {
      await run('kubectl', ['delete', 'namespace', 'litmus', '--timeout=60s'], { stdio: 'pipe' });
      logSuccess('✓ LitmusChaos namespace deleted');
    } catch (error) {
      logWarn(`Failed to delete LitmusChaos namespace: ${error}`);
      
      // Try to force-clean the namespace
      try {
        logInfo('Attempting to force-clean litmus namespace...');
        
        // Check namespace status
        const nsStatusResult = await execa('kubectl', ['get', 'namespace', 'litmus', '-o', 'yaml'], { stdio: 'pipe' });
        const nsStatus = nsStatusResult.stdout;
        
        if (nsStatus.includes('NamespaceContentRemaining') || nsStatus.includes('NamespaceFinalizersRemaining')) {
          logWarn('Litmus namespace has content or finalizers remaining');
          
          // Remove finalizers from common LitmusChaos resources
          const resourceTypes = ['chaosengines', 'chaosexperiments', 'chaosresults', 'workflows', 'cronworkflows', 'pods', 'statefulsets', 'deployments', 'services'];
          
          for (const resourceType of resourceTypes) {
            try {
              const resources = await execa('kubectl', ['get', resourceType, '-n', 'litmus', '-o', 'json'], { stdio: 'pipe' });
              const resourceData = JSON.parse(resources.stdout);
              
              if (resourceData.items && resourceData.items.length > 0) {
                logInfo(`Removing finalizers from ${resourceData.items.length} ${resourceType}...`);
                for (const resource of resourceData.items) {
                  try {
                    await run('kubectl', ['patch', resourceType, resource.metadata.name, '-n', 'litmus', '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
                  } catch (patchError) {
                    // Ignore - resource might be gone
                  }
                }
              }
            } catch (getError) {
              // Ignore - resource type might not exist
            }
          }
          
          // Remove namespace finalizers
          await run('kubectl', ['patch', 'namespace', 'litmus', '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
          logInfo('✓ LitmusChaos namespace finalizers removed');
          
          // Wait for cleanup
          await new Promise(resolve => setTimeout(resolve, 3000));
        }
        
        // Try delete again
        try {
          await execa('kubectl', ['get', 'namespace', 'litmus'], { stdio: 'pipe' });
          // Still exists, force delete
          await run('kubectl', ['delete', 'namespace', 'litmus', '--force', '--grace-period=0'], { stdio: 'pipe' });
          logSuccess('✓ LitmusChaos namespace force deleted');
        } catch (checkError) {
          // Namespace is gone
          logSuccess('✓ LitmusChaos namespace deleted');
        }
      } catch (forceError) {
        logWarn(`Could not force-clean litmus namespace: ${forceError}`);
        logWarn('You may need to delete it manually: kubectl delete namespace litmus --force');
      }
    }
  } catch (error) {
    logWarn(`Error during LitmusChaos uninstall: ${error}`);
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
  
  // 1. Delete StatefulSets first (stops pod recreation) - AGGRESSIVE MODE
  try {
    logInfo('Deleting StatefulSets...');
    await run('kubectl', ['delete', 'statefulset', '--all', '-n', ns, '--timeout=10s', '--force', '--grace-period=0'], { stdio: 'pipe' });
    logSuccess('StatefulSets deleted successfully');
  } catch (error: any) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No StatefulSets found or already deleted');
    } else {
      logWarn(`StatefulSet deletion timed out or failed, continuing...`);
    }
  }
  
  // 2. Delete any remaining Pods immediately - AGGRESSIVE MODE
  try {
    logInfo('Deleting remaining Pods...');
    await run('kubectl', ['delete', 'pods', '--all', '-n', ns, '--timeout=5s', '--force', '--grace-period=0'], { stdio: 'pipe' });
    logSuccess('Pods deleted successfully');
  } catch (error: any) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No Pods found or already deleted');
    } else {
      logWarn('Pod deletion timed out, continuing...');
    }
  }
  
  // 3. Delete Services - AGGRESSIVE MODE
  try {
    logInfo('Deleting Services...');
    await run('kubectl', ['delete', 'service', '--all', '-n', ns, '--timeout=5s'], { stdio: 'pipe' });
    logSuccess('Services deleted successfully');
  } catch (error: any) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No Services found or already deleted');
    } else {
      logWarn(`Service deletion timed out or failed, continuing...`);
    }
  }
  
  // 4. Delete PVCs (they can have finalizers) - AGGRESSIVE MODE
  try {
    logInfo('Deleting PVCs...');
    await run('kubectl', ['delete', 'pvc', '--all', '-n', ns, '--timeout=10s'], { stdio: 'pipe' });
    logSuccess('PVCs deleted successfully');
  } catch (error: any) {
    if (error.toString().includes('NotFound') || error.toString().includes('no resources found')) {
      logInfo('No PVCs found or already deleted');
    } else if (error.toString().includes('timeout')) {
      logWarn('PVC deletion timed out, forcing aggressive cleanup...');
      try {
        // Get all PVCs immediately
        const pvcResult = await execa('kubectl', ['get', 'pvc', '-n', ns, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name'], { stdio: 'pipe' });
        const pvcNames = pvcResult.stdout.trim().split('\n').filter(name => name.trim());
        
        if (pvcNames.length === 0) {
          logInfo('✓ No PVCs found');
        } else {
          logInfo(`Aggressively deleting ${pvcNames.length} PVC(s)...`);
          
          // Remove all finalizers in parallel
          const { execa } = await import('execa');

          // Small helper to bound async wait times
          const withTimeout = async <T>(p: Promise<T>, ms: number): Promise<void> => {
            return Promise.race([
              p.then(() => {}),
              new Promise<void>(resolve => setTimeout(resolve, ms))
            ]);
          };

          const finalizerPromises = pvcNames.map(async pvcName => {
            try {
              await execa('kubectl', ['patch', 'pvc', pvcName, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe', timeout: 5000 });
              logInfo(`✓ Finalizers removed: ${pvcName}`);
            } catch {
              // Ignore - PVC might already be gone or API slow
            }
          });
          // Do not block longer than 5s on finalizer removal overall
          await withTimeout(Promise.allSettled(finalizerPromises), 5000);
          
          // Force delete all PVCs in parallel (no waiting)
          const deletePromises = pvcNames.map(async pvcName => {
            try {
              await execa('kubectl', ['delete', 'pvc', pvcName, '-n', ns, '--force', '--grace-period=0'], { stdio: 'pipe', timeout: 5000 });
              logInfo(`✓ Delete requested: ${pvcName}`);
            } catch {
              // Ignore - best effort
            }
          });
          // Fire-and-forget; don't block uninstall on PVC deletions
          void Promise.allSettled(deletePromises);
          
          logSuccess('PVCs aggressively deleted');
        }
      } catch (forceError: any) {
        logWarn(`Error during aggressive PVC deletion: ${forceError}`);
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
      secret.includes('minio') ||
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
  
  // Delete storage class (if we created it)
  // Note: We only created it if it didn't exist, but we'll try to clean it up
  // This will fail if other resources are using it, which is fine
  logInfo('Cleaning up storage class...');
  try {
    // Check if storage class exists and if we can safely delete it
    const { execa } = await import('execa');
    try {
      await execa('kubectl', ['get', 'storageclass', 'gp3'], { stdio: 'pipe' });
      // Storage class exists - try to delete it
      logInfo('Attempting to delete gp3 storage class...');
      try {
        await run('kubectl', ['delete', 'storageclass', 'gp3'], { stdio: 'pipe' });
        logSuccess('Storage class gp3 deleted successfully');
      } catch (deleteError) {
        // This is expected if storage class is in use by other resources
        if (deleteError.toString().includes('cannot be deleted') || deleteError.toString().includes('in use')) {
          logInfo('Storage class gp3 is in use by other resources - leaving it in place');
        } else {
          logWarn(`Could not delete storage class gp3: ${deleteError}`);
        }
      }
      
      // Try to restore gp2 as default if it exists (we may have removed it during install)
      try {
        await run('kubectl', ['patch', 'storageclass', 'gp2', '-p', '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}']);
        logInfo('Restored gp2 as default storage class');
      } catch (gp2Error) {
        // gp2 might not exist or already be default - that's fine
        logInfo('Note: Could not restore gp2 as default storage class (may not exist or already default)');
      }
    } catch (getError) {
      logInfo('Storage class gp3 not found - may not have been created by this installation');
    }
  } catch (error) {
    logWarn(`Error during storage class cleanup: ${error}`);
  }
  
  // Uninstall MinIO (if installed)
  logInfo('Uninstalling MinIO...');
  try {
    const { execa } = await import('execa');
    // Check if MinIO Helm release exists
    try {
      const minioListResult = await execa('helm', ['list', '-n', 'minio', '--output', 'json'], { stdio: 'pipe' });
      const minioReleases = JSON.parse(minioListResult.stdout);
      const minioRelease = minioReleases.find((r: any) => r.name === 'minio');
      
      if (minioRelease) {
        logInfo('Uninstalling MinIO Helm release...');
        await run('helm', ['uninstall', 'minio', '-n', 'minio']);
        logSuccess('MinIO Helm release uninstalled successfully');
        
        // Wait a bit for resources to be cleaned up
        await new Promise(resolve => setTimeout(resolve, 5000));
        
        // Delete MinIO PVCs (they won't be automatically deleted)
        try {
          logInfo('Deleting MinIO PVCs...');
          await run('kubectl', ['delete', 'pvc', '--all', '-n', 'minio', '--timeout=60s'], { stdio: 'pipe' });
          logSuccess('MinIO PVCs deleted successfully');
        } catch (pvcError) {
          if (!pvcError.toString().includes('NotFound') && !pvcError.toString().includes('no resources found')) {
            logWarn(`Error deleting MinIO PVCs: ${pvcError}`);
          }
        }
        
        // Delete MinIO namespace
        try {
          logInfo('Deleting MinIO namespace...');
          await run('kubectl', ['delete', 'namespace', 'minio', '--timeout=60s'], { stdio: 'pipe' });
          logSuccess('MinIO namespace deleted successfully');
        } catch (nsError) {
          if (!nsError.toString().includes('NotFound')) {
            logWarn(`Error deleting MinIO namespace: ${nsError}`);
            // Try force delete if regular delete fails
            try {
              await run('kubectl', ['patch', 'namespace', 'minio', '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
              await run('kubectl', ['delete', 'namespace', 'minio', '--force', '--grace-period=0'], { stdio: 'pipe' });
              logSuccess('MinIO namespace force deleted successfully');
            } catch (forceError) {
              logWarn(`Error force deleting MinIO namespace: ${forceError}`);
            }
          } else {
            logInfo('MinIO namespace not found or already deleted');
          }
        }
      } else {
        logInfo('MinIO Helm release not found - skipping MinIO cleanup');
      }
    } catch (error) {
      // MinIO namespace might not exist
      if (error.toString().includes('NotFound') || error.toString().includes('does not exist')) {
        logInfo('MinIO namespace not found - MinIO may not be installed');
      } else {
        logWarn(`Error checking MinIO installation: ${error}`);
        // Try to uninstall anyway
        try {
          await run('helm', ['uninstall', 'minio', '-n', 'minio'], { stdio: 'pipe' });
          logSuccess('MinIO Helm release uninstalled successfully');
        } catch (uninstallError) {
          logInfo('MinIO Helm release not found or already deleted');
        }
      }
    }
  } catch (error) {
    logWarn(`Error during MinIO cleanup: ${error}`);
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
  
  // Delete the namespace itself - AGGRESSIVE MODE
  logInfo('Deleting Percona namespace...');
  let namespaceDeleted = false;
  
  try {
    await run('kubectl', ['delete', 'namespace', ns, '--timeout=10s'], { stdio: 'pipe' });
    logInfo('Namespace deletion command completed, verifying...');
  } catch (error: any) {
    if (error.toString().includes('NotFound')) {
      logInfo(`Namespace ${ns} not found or already deleted`);
      namespaceDeleted = true;
    } else if (error.toString().includes('timeout')) {
      logWarn(`Namespace deletion timed out, forcing aggressive cleanup...`);
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
        logWarn('Namespace still exists, checking status...');
        
        // Check namespace status to diagnose what's blocking deletion
        try {
          const nsStatusResult = await execa('kubectl', ['get', 'namespace', ns, '-o', 'yaml'], { stdio: 'pipe' });
          const nsStatus = nsStatusResult.stdout;
          
          // Parse status to check for finalizers and stuck resources
          if (nsStatus.includes('NamespaceContentRemaining') || nsStatus.includes('NamespaceFinalizersRemaining')) {
            logWarn('Namespace has content or finalizers remaining');
            
            // Extract specific issues if possible
            if (nsStatus.match(/Some resources are remaining: ([^\n]+)/)) {
              const match = nsStatus.match(/Some resources are remaining: ([^\n]+)/);
              if (match) {
                logWarn(`  Remaining resources: ${match[1]}`);
              }
            }
            if (nsStatus.match(/Some content in the namespace has finalizers remaining: ([^\n]+)/)) {
              const match = nsStatus.match(/Some content in the namespace has finalizers remaining: ([^\n]+)/);
              if (match) {
                logWarn(`  Finalizers remaining: ${match[1]}`);
              }
            }
          }
        } catch (statusError) {
          logWarn(`Could not check namespace status: ${statusError}`);
        }
        
        logWarn('Performing aggressive cleanup...');
        
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
                  logInfo(`  ✓ Removed finalizers from ${resourceType}/${resourceName}`);
                } catch (patchError: any) {
                  // Ignore errors - resource might not exist anymore
                  if (!patchError.toString().includes('NotFound')) {
                    logWarn(`  Could not patch ${resourceType}/${resourceName}: ${patchError}`);
                  }
                }
              }
            }
          } catch (getError: any) {
            // Ignore errors - resource type might not exist
            if (!getError.toString().includes('NotFound') && !getError.toString().includes('the server doesn\'t have a resource type')) {
              logWarn(`  Could not list ${resourceType}: ${getError}`);
            }
          }
        }
        
        // 2. Remove finalizer from namespace itself
        logInfo('Removing namespace finalizers...');
        try {
          await run('kubectl', ['patch', 'namespace', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
          logInfo('  ✓ Namespace finalizers removed');
        } catch (patchError: any) {
          logWarn(`  Could not remove namespace finalizers: ${patchError}`);
        }
        
        // 3. Wait briefly for Kubernetes to process the changes
        await new Promise(resolve => setTimeout(resolve, 500));
        
        // 4. Try deleting namespace again (might not need force now)
        try {
          const nsCheckAfterPatch = await execa('kubectl', ['get', 'namespace', ns], { stdio: 'pipe' });
          if (nsCheckAfterPatch.exitCode !== 0) {
            logSuccess('✓ Namespace deleted after finalizer removal');
            namespaceDeleted = true;
          } else {
            // Still exists, try force delete
            logInfo('Namespace still exists, attempting force delete...');
            try {
              await run('kubectl', ['delete', 'namespace', ns, '--force', '--grace-period=0'], { stdio: 'pipe' });
              logInfo('Force deletion command completed');
            } catch (forceDeleteError: any) {
              if (!forceDeleteError.toString().includes('NotFound')) {
                logWarn(`Force delete command error: ${forceDeleteError}`);
              }
            }
            
            // Poll for namespace deletion with diagnostics
            logInfo('Polling namespace deletion status (checking every 3 seconds)...');
            const maxPollAttempts = 60; // 3 minutes total
            for (let attempt = 1; attempt <= maxPollAttempts; attempt++) {
              await new Promise(resolve => setTimeout(resolve, 3000));
              
              try {
                const pollCheck = await execa('kubectl', ['get', 'namespace', ns, '-o', 'json'], { stdio: 'pipe' });
                const nsData = JSON.parse(pollCheck.stdout);
                
                // Check status conditions
                const status = nsData.status || {};
                const conditions = status.conditions || [];
                
                logInfo(`  Check ${attempt}/${maxPollAttempts}: Namespace still in '${nsData.status?.phase || 'Unknown'}' state`);
                
                // Parse and display blocking resources
                for (const condition of conditions) {
                  if (condition.type === 'NamespaceContentRemaining') {
                    logWarn(`    → Blocking: Content remaining - ${condition.message || 'Unknown resources'}`);
                    
                    // Try to extract resource details from message
                    if (condition.message) {
                      const resourceMatch = condition.message.match(/has (\d+) resource\(s\): (.+)/);
                      if (resourceMatch) {
                        logWarn(`      Resources blocking deletion: ${resourceMatch[2]}`);
                      }
                      
                      // Try to extract specific resource types
                      const resourceTypesMatch = condition.message.match(/([a-z.]+)\/[a-z0-9-]+/gi);
                      if (resourceTypesMatch) {
                        const uniqueTypes = [...new Set(resourceTypesMatch)] as string[];
                        logInfo(`      Attempting to remove finalizers from: ${uniqueTypes.join(', ')}`);
                        
                        // Try to clean up each resource type mentioned
                        for (const resourceRef of uniqueTypes) {
                          const [apiVersion, kind] = (resourceRef as string).split('/');
                          if (kind) {
                            try {
                              // List resources of this kind in the namespace
                              const resList = await execa('kubectl', ['get', kind.toLowerCase(), '-n', ns, '-o', 'json'], { stdio: 'pipe' }).catch(() => null);
                              if (resList) {
                                const resData = JSON.parse(resList.stdout);
                                if (resData.items && resData.items.length > 0) {
                                  for (const item of resData.items) {
                                    try {
                                      await run('kubectl', ['patch', kind.toLowerCase(), item.metadata.name, '-n', ns, '-p', '{"metadata":{"finalizers":[]}}', '--type=merge'], { stdio: 'pipe' });
                                      logInfo(`        ✓ Removed finalizers from ${kind}/${item.metadata.name}`);
                                    } catch (e) {
                                      // Ignore individual resource errors
                                    }
                                  }
                                }
                              }
                            } catch (e) {
                              // Ignore errors for resource types we can't access
                            }
                          }
                        }
                      }
                    }
                  } else if (condition.type === 'NamespaceFinalizersRemaining') {
                    logWarn(`    → Blocking: Finalizers remaining - ${condition.message || 'Unknown finalizers'}`);
                    
                    // Extract finalizer names from message if possible
                    if (condition.message) {
                      const finalizerMatch = condition.message.match(/finalizers: (.+)/);
                      if (finalizerMatch) {
                        logWarn(`      Finalizers: ${finalizerMatch[1]}`);
                      }
                    }
                  }
                }
                
                // Also check what resources actually exist
                if (attempt % 5 === 0) { // Every 5 checks (15 seconds)
                  logInfo('    Enumerating remaining resources in namespace...');
                  const allResources = await execa('kubectl', ['api-resources', '--verbs=list', '--namespaced=true', '-o', 'name'], { stdio: 'pipe' }).catch(() => null);
                  if (allResources) {
                    const resourceTypes = allResources.stdout.trim().split('\n');
                    for (const resourceType of resourceTypes.slice(0, 20)) { // Limit to first 20 types
                      try {
                        const res = await execa('kubectl', ['get', resourceType.trim(), '-n', ns, '--no-headers'], { stdio: 'pipe', timeout: 5000 }).catch(() => null);
                        if (res && res.stdout.trim()) {
                          const count = res.stdout.trim().split('\n').filter(l => l.trim()).length;
                          if (count > 0) {
                            logWarn(`      Found ${count} ${resourceType.trim()} resource(s) remaining`);
                          }
                        }
                      } catch (e) {
                        // Ignore errors
                      }
                    }
                  }
                }
                
              } catch (pollError: any) {
                // Namespace might be deleted (NotFound) or error occurred
                const errorStr = pollError.toString();
                if (errorStr.includes('NotFound') || errorStr.includes('not found') || (pollError.exitCode !== undefined && pollError.exitCode === 1)) {
                  logSuccess('✓ Namespace deleted successfully!');
                  namespaceDeleted = true;
                  break;
                } else {
                  // Some other error - log it but continue polling
                  if (attempt % 10 === 0) { // Only log every 10th attempt to avoid spam
                    logWarn(`    Polling error (attempt ${attempt}): ${errorStr}`);
                  }
                }
              }
            }
            
            if (!namespaceDeleted) {
              logWarn('⚠️  Namespace deletion is taking longer than expected.');
              logWarn('    The namespace may still be deleting in the background.');
              logWarn('    You can check status manually with: kubectl get namespace ' + ns);
            }
          }
        } catch (deleteAfterError: any) {
          if (deleteAfterError.toString().includes('NotFound')) {
            logSuccess('✓ Namespace deleted');
            namespaceDeleted = true;
          } else {
            logWarn(`Force delete failed: ${deleteAfterError}`);
          }
        }
      } else {
        logInfo('Namespace not found - deletion successful');
        namespaceDeleted = true;
      }
    } catch (forceError: any) {
      // Check if the error is just that the namespace doesn't exist (which is what we want)
      const errorStr = forceError?.toString?.() || '';
      if (errorStr.includes('NotFound') || errorStr.includes('not found')) {
        logInfo('Namespace not found during cleanup - already deleted');
        namespaceDeleted = true;
      } else {
        logWarn(`Error during aggressive cleanup: ${errorStr}`);
      }
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
    
    // 8. Check for remaining Helm releases (Percona namespace)
    logInfo('Checking for remaining Helm releases in Percona namespace...');
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
        logSuccess('✓ No Helm releases found in Percona namespace');
      }
    } catch (error) {
      logSuccess('✓ No Helm releases found in Percona namespace');
    }
    
    // 8b. Check for remaining MinIO Helm releases
    logInfo('Checking for remaining MinIO Helm releases...');
    try {
      const minioHelmResult = await execa('helm', ['list', '-n', 'minio', '--output', 'json'], { stdio: 'pipe' });
      const minioReleases = JSON.parse(minioHelmResult.stdout);
      const minioReleasesFound = minioReleases.filter((r: any) => r.name === 'minio');
      if (minioReleasesFound.length > 0) {
        cleanupIssues.push(`Found MinIO Helm release still installed: ${minioReleasesFound.map((r: any) => r.name).join(', ')}`);
      } else {
        logSuccess('✓ No MinIO Helm releases found');
      }
    } catch (error) {
      // MinIO namespace might not exist, which is fine
      logSuccess('✓ No MinIO Helm releases found (or MinIO namespace does not exist)');
    }
    
    // 8c. Check for storage class cleanup
    logInfo('Checking storage class...');
    try {
      await execa('kubectl', ['get', 'storageclass', 'gp3'], { stdio: 'pipe' });
      cleanupIssues.push('Storage class gp3 still exists (may be in use by other resources)');
    } catch (error) {
      logSuccess('✓ Storage class gp3 has been deleted or does not exist');
    }
    
    // 9. Check if MinIO namespace still exists
    logInfo('Checking if MinIO namespace still exists...');
    try {
      await execa('kubectl', ['get', 'namespace', 'minio'], { stdio: 'pipe' });
      cleanupIssues.push('MinIO namespace still exists');
    } catch (error) {
      logSuccess('✓ MinIO namespace has been deleted');
    }
    
    // 9b. Check if ChartMuseum namespace still exists
    logInfo('Checking if ChartMuseum namespace still exists...');
    try {
      await execa('kubectl', ['get', 'namespace', 'chartmuseum'], { stdio: 'pipe' });
      cleanupIssues.push('ChartMuseum namespace still exists');
    } catch (error) {
      logSuccess('✓ ChartMuseum namespace has been deleted');
    }
    
    // 10. Check if Percona namespace still exists
    logInfo('Checking if Percona namespace still exists...');
    try {
      await execa('kubectl', ['get', 'namespace', ns], { stdio: 'pipe' });
      cleanupIssues.push(`Namespace ${ns} still exists`);
    } catch (error) {
      logSuccess('✓ Percona namespace has been deleted');
    }
    
    // 11. Summary
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
      
      // Create storage class first (needed by both MinIO and ChartMuseum)
      await createStorageClass();
      
      // Get AWS account ID (still needed for some operations)
      const { execa } = await import('execa');
      const accountResult = await execa('aws', ['sts', 'get-caller-identity', '--query', 'Account', '--output', 'text'], { stdio: 'pipe' });
      const accountId = accountResult.stdout.trim();
      
      // Bootstrap sequence:
      // 1. Install MinIO from external repo (minio/minio) - needed to bootstrap
      //    since ChartMuseum doesn't exist yet to host charts internally
      const minioCredentials = await installMinIO(parsed.namespace);
      
      // 2. Install ChartMuseum with local persistent storage
      //    Now MinIO is available if ChartMuseum needed it (though we use local storage)
      await installChartMuseum();
      
      // 3. Mirror all charts to ChartMuseum (Percona, MinIO, LitmusChaos)
      //    From this point forward, all installations use internal ChartMuseum repo
      await mirrorChartsToChartMuseum();
      
      // 4. Add internal repo (ChartMuseum) for Percona operator and cluster
      await addRepos(parsed.helmRepo);
      
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
      
      // Install LitmusChaos for chaos engineering
      await installLitmusChaos();
      
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
      // Uninstall LitmusChaos as well
      await uninstallLitmusChaos();
      // Uninstall ChartMuseum as well
      await uninstallChartMuseum();
      logSuccess('Uninstall completed.');
    }
  } catch (err) {
    logError('Percona script failed', err);
    process.exitCode = 1;
  }
}

main();


