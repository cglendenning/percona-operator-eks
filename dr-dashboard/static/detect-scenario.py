#!/usr/bin/env python3
"""
Database Emergency Diagnostic Script
Detects which disaster scenario is currently occurring
"""

import subprocess
import sys
import json
import re
from typing import Dict, List, Optional

# ANSI colors
RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

def run_command(cmd: str) -> tuple[str, int]:
    """Run shell command and return output and exit code"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout + result.stderr, result.returncode
    except subprocess.TimeoutExpired:
        return "Command timed out", 1
    except Exception as e:
        return str(e), 1

def check_pods_status() -> Dict:
    """Check PXC and ProxySQL pod status"""
    output, _ = run_command("kubectl get pods -n percona -l app.kubernetes.io/component=pxc -o json 2>/dev/null")
    
    try:
        pods_data = json.loads(output)
        pods = pods_data.get('items', [])
        
        total = len(pods)
        running = sum(1 for p in pods if p.get('status', {}).get('phase') == 'Running')
        crashloop = sum(1 for p in pods if any(
            c.get('state', {}).get('waiting', {}).get('reason') == 'CrashLoopBackOff'
            for c in p.get('status', {}).get('containerStatuses', [])
        ))
        
        return {
            'total': total,
            'running': running,
            'crashloop': crashloop,
            'all_down': running == 0 and total > 0
        }
    except:
        return {'total': 0, 'running': 0, 'crashloop': 0, 'all_down': False}

def check_cluster_quorum() -> Dict:
    """Check if Galera cluster has quorum"""
    output, code = run_command(
        "kubectl exec -n percona $(kubectl get pods -n percona -l app.kubernetes.io/component=pxc -o name | head -1) "
        "-- mysql -uroot -p$MYSQL_ROOT_PASSWORD -e \"SHOW STATUS LIKE 'wsrep_cluster_status';\" 2>/dev/null"
    )
    
    has_quorum = 'Primary' in output
    cluster_size_output, _ = run_command(
        "kubectl exec -n percona $(kubectl get pods -n percona -l app.kubernetes.io/component=pxc -o name | head -1) "
        "-- mysql -uroot -p$MYSQL_ROOT_PASSWORD -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" 2>/dev/null"
    )
    
    cluster_size = 0
    if cluster_size_output:
        match = re.search(r'wsrep_cluster_size\s+(\d+)', cluster_size_output)
        if match:
            cluster_size = int(match.group(1))
    
    return {
        'has_quorum': has_quorum,
        'cluster_size': cluster_size,
        'status': 'Primary' if has_quorum else 'non-Primary'
    }

def check_nodes() -> Dict:
    """Check Kubernetes node status"""
    output, _ = run_command("kubectl get nodes -o json 2>/dev/null")
    
    try:
        nodes_data = json.loads(output)
        nodes = nodes_data.get('items', [])
        
        total = len(nodes)
        ready = sum(1 for n in nodes if any(
            c.get('type') == 'Ready' and c.get('status') == 'True'
            for c in n.get('status', {}).get('conditions', [])
        ))
        
        return {
            'total': total,
            'ready': ready,
            'notready': total - ready
        }
    except:
        return {'total': 0, 'ready': 0, 'notready': 0}

def check_operator() -> Dict:
    """Check Percona Operator status"""
    output, _ = run_command(
        "kubectl get pods -n percona-operator -l app.kubernetes.io/name=percona-xtradb-cluster-operator -o json 2>/dev/null"
    )
    
    try:
        pods_data = json.loads(output)
        pods = pods_data.get('items', [])
        
        running = sum(1 for p in pods if p.get('status', {}).get('phase') == 'Running')
        
        return {
            'running': running > 0,
            'count': len(pods)
        }
    except:
        return {'running': False, 'count': 0}

def check_services() -> Dict:
    """Check ProxySQL/HAProxy service endpoints"""
    output, _ = run_command("kubectl get endpoints -n percona proxysql -o json 2>/dev/null")
    
    try:
        ep_data = json.loads(output)
        subsets = ep_data.get('subsets', [])
        addresses = sum(len(s.get('addresses', [])) for s in subsets)
        
        return {
            'has_endpoints': addresses > 0,
            'endpoint_count': addresses
        }
    except:
        return {'has_endpoints': False, 'endpoint_count': 0}

def check_api_server() -> bool:
    """Check if Kubernetes API server is responsive"""
    _, code = run_command("kubectl cluster-info 2>/dev/null")
    return code == 0

def check_replication() -> Dict:
    """Check replication status (if multi-DC)"""
    output, _ = run_command(
        "kubectl exec -n percona $(kubectl get pods -n percona -l app.kubernetes.io/component=pxc -o name | head -1) "
        "-- mysql -uroot -p$MYSQL_ROOT_PASSWORD -e \"SHOW SLAVE STATUS\\G\" 2>/dev/null"
    )
    
    io_running = 'Slave_IO_Running: Yes' in output
    sql_running = 'Slave_SQL_Running: Yes' in output
    seconds_behind = 0
    
    match = re.search(r'Seconds_Behind_Master:\s+(\d+)', output)
    if match:
        seconds_behind = int(match.group(1))
    
    return {
        'io_running': io_running,
        'sql_running': sql_running,
        'seconds_behind': seconds_behind,
        'replication_configured': 'Slave_IO_Running' in output
    }

def detect_scenario() -> List[Dict]:
    """Detect which disaster scenario(s) match current state"""
    print(f"{BLUE}Running diagnostics...{RESET}\n")
    
    # Gather data
    pods = check_pods_status()
    quorum = check_cluster_quorum()
    nodes = check_nodes()
    operator = check_operator()
    services = check_services()
    api_working = check_api_server()
    replication = check_replication()
    
    # Display findings
    print(f"{YELLOW}Current State:{RESET}")
    print(f"  Pods: {pods['running']}/{pods['total']} running, {pods['crashloop']} in CrashLoopBackOff")
    print(f"  Cluster: {quorum['cluster_size']} nodes, status={quorum['status']}")
    print(f"  Kubernetes Nodes: {nodes['ready']}/{nodes['total']} ready")
    print(f"  Operator: {'Running' if operator['running'] else 'Not Running'}")
    print(f"  Service Endpoints: {services['endpoint_count']}")
    print(f"  API Server: {'Responsive' if api_working else 'Unresponsive'}")
    if replication['replication_configured']:
        print(f"  Replication: IO={replication['io_running']}, SQL={replication['sql_running']}, Lag={replication['seconds_behind']}s")
    print()
    
    # Detect scenarios
    matches = []
    
    # Single pod failure
    if pods['crashloop'] >= 1 and quorum['has_quorum'] and pods['running'] >= 2:
        matches.append({
            'scenario': 'Single MySQL pod failure (container crash / OOM)',
            'confidence': 'HIGH',
            'file': 'single-mysql-pod-failure.md'
        })
    
    # Node failure
    if nodes['notready'] >= 1 and pods['running'] < pods['total'] and quorum['has_quorum']:
        matches.append({
            'scenario': 'Kubernetes worker node failure (VM host crash)',
            'confidence': 'HIGH',
            'file': 'kubernetes-worker-node-failure.md'
        })
    
    # Quorum loss
    if not quorum['has_quorum'] or quorum['cluster_size'] < 2:
        matches.append({
            'scenario': 'Cluster loses quorum (multiple PXC pods down)',
            'confidence': 'CRITICAL',
            'file': 'cluster-loses-quorum.md'
        })
    
    # Operator failure
    if not operator['running'] and pods['total'] > 0:
        matches.append({
            'scenario': 'Percona Operator / CRD misconfiguration (bad rollout)',
            'confidence': 'MEDIUM',
            'file': 'percona-operator-crd-misconfiguration.md'
        })
    
    # Service/Ingress failure
    if not services['has_endpoints'] and pods['running'] > 0:
        matches.append({
            'scenario': 'Ingress/VIP failure (HAProxy/ProxySQL service unreachable)',
            'confidence': 'HIGH',
            'file': 'ingress-vip-failure.md'
        })
    
    # API server down
    if not api_working:
        matches.append({
            'scenario': 'Kubernetes control plane outage (API server down)',
            'confidence': 'CRITICAL',
            'file': 'kubernetes-control-plane-outage-api-server-down.md'
        })
    
    # Replication issues
    if replication['replication_configured']:
        if not replication['io_running'] or not replication['sql_running']:
            matches.append({
                'scenario': 'Both DCs up but replication stops (broken channel)',
                'confidence': 'HIGH',
                'file': 'both-dcs-up-but-replication-stops-broken-channel.md'
            })
        elif replication['seconds_behind'] > 300:
            matches.append({
                'scenario': 'Primary DC network partition from Secondary (WAN cut)',
                'confidence': 'MEDIUM',
                'file': 'primary-dc-network-partition-from-secondary-wan-cut.md'
            })
    
    # All pods down
    if pods['all_down']:
        matches.append({
            'scenario': 'Primary DC power/cooling outage (site down)',
            'confidence': 'CRITICAL',
            'file': 'primary-dc-power-cooling-outage-site-down.md'
        })
    
    return matches

def main():
    print(f"\n{RED}DATABASE EMERGENCY DIAGNOSTIC{RESET}")
    print(f"{RED}═══════════════════════════════{RESET}\n")
    
    matches = detect_scenario()
    
    if not matches:
        print(f"{GREEN}No critical issues detected{RESET}")
        print(f"\nIf you're experiencing issues, check:")
        print(f"  - Application logs")
        print(f"  - Network connectivity")
        print(f"  - Authentication/credentials")
        return 0
    
    print(f"{RED}DETECTED SCENARIOS:{RESET}\n")
    
    # Get environment (EKS or on-prem)
    # Try to detect from cluster context
    context_output, _ = run_command("kubectl config current-context 2>/dev/null")
    env = "eks" if "eks" in context_output.lower() or "aws" in context_output.lower() else "on-prem"
    
    # Determine base URL for dashboard
    dashboard_url = f"http://localhost:8080"
    
    for i, match in enumerate(matches, 1):
        confidence_color = RED if match['confidence'] == 'CRITICAL' else YELLOW
        print(f"{confidence_color}{i}. [{match['confidence']}] {match['scenario']}{RESET}")
        print(f"   Recovery Process: {dashboard_url}/#scenario-{match['file'].replace('.md', '')}")
        print(f"   File: recovery_processes/{env}/{match['file']}\n")
    
    print(f"\n{BLUE}Next Steps:{RESET}")
    print(f"1. Open the Database Emergency Kit: {dashboard_url}")
    print(f"2. Switch to '{env.upper()}' environment")
    print(f"3. Expand the matching scenario and follow recovery steps")
    print(f"4. Contact on-call DBA if needed\n")
    
    return len(matches)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(f"\n{YELLOW}Interrupted{RESET}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{RED}Error: {e}{RESET}")
        sys.exit(1)
