"""
Test that Percona data volumes use XFS filesystem with correct mount options

This test verifies that:
1. All PXC and ProxySQL data volumes are formatted with XFS
2. XFS volumes are mounted with recommended options for database workloads
3. Critical performance-impacting options are set correctly

Background:
- XFS is recommended by Percona for production MySQL/Percona deployments
- Proper mount options significantly impact database performance and durability
- This test ensures infrastructure meets Percona best practices
"""
import pytest
import re
from kubernetes import client
from kubernetes.stream import stream
from tests.conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

# Recommended XFS mount options for Percona/MySQL workloads
REQUIRED_XFS_OPTIONS = {
    # At least one of these should be present (relatime is often the default)
    'atime_options': ['noatime', 'relatime'],
    # Performance-critical options (at least largeio is recommended)
    'recommended_options': ['largeio', 'inode64'],
}

# Options that should NOT be present (performance killers for databases)
FORBIDDEN_OPTIONS = [
    'atime',  # Full atime tracking (only if relatime/noatime are absent)
    'sync',   # Synchronous writes (catastrophic for performance)
]


def get_filesystem_info_from_pod(core_v1, namespace, pod_name, container_name, mount_path='/var/lib/mysql'):
    """
    Execute commands in a pod to get filesystem type and mount options
    
    Args:
        core_v1: Kubernetes Core V1 API client
        namespace: Kubernetes namespace
        pod_name: Name of the pod to exec into
        container_name: Name of the container within the pod
        mount_path: Path to check (default: /var/lib/mysql for Percona)
    
    Returns:
        dict: {'fs_type': str, 'mount_options': list, 'device': str}
    """
    # Get filesystem type using df -T
    df_command = ['/bin/sh', '-c', f'df -T {mount_path} | tail -n 1']
    
    try:
        df_output = stream(
            core_v1.connect_get_namespaced_pod_exec,
            pod_name,
            namespace,
            container=container_name,
            command=df_command,
            stderr=True,
            stdin=False,
            stdout=True,
            tty=False
        )
        
        console.print(f"[dim]df -T output for {pod_name}:{mount_path}:[/dim]")
        console.print(f"[dim]{df_output}[/dim]")
        
        # Parse df output: Filesystem Type 1K-blocks Used Available Use% Mounted on
        df_parts = df_output.strip().split()
        if len(df_parts) < 2:
            raise ValueError(f"Unexpected df output format: {df_output}")
        
        device = df_parts[0]
        fs_type = df_parts[1]
        
    except Exception as e:
        console.print(f"[yellow]⚠ Could not determine filesystem type for {pod_name}: {e}[/yellow]")
        raise
    
    # Get mount options from /proc/mounts
    mount_command = ['/bin/sh', '-c', f'cat /proc/mounts | grep "{mount_path}"']
    
    try:
        mount_output = stream(
            core_v1.connect_get_namespaced_pod_exec,
            pod_name,
            namespace,
            container=container_name,
            command=mount_command,
            stderr=True,
            stdin=False,
            stdout=True,
            tty=False
        )
        
        console.print(f"[dim]/proc/mounts output for {pod_name}:{mount_path}:[/dim]")
        console.print(f"[dim]{mount_output}[/dim]")
        
        # Parse mount output: device mountpoint fstype options 0 0
        mount_parts = mount_output.strip().split()
        if len(mount_parts) < 4:
            raise ValueError(f"Unexpected mount output format: {mount_output}")
        
        mount_options = mount_parts[3].split(',')
        
    except Exception as e:
        console.print(f"[yellow]⚠ Could not determine mount options for {pod_name}: {e}[/yellow]")
        raise
    
    return {
        'fs_type': fs_type,
        'mount_options': mount_options,
        'device': device,
        'mount_path': mount_path
    }


def validate_xfs_mount_options(mount_options, pod_name):
    """
    Validate that mount options follow Percona best practices
    
    Args:
        mount_options: List of mount option strings
        pod_name: Name of pod (for error messages)
    
    Returns:
        list: List of validation errors (empty if all validations pass)
    """
    errors = []
    warnings = []
    
    # Check for forbidden options
    for forbidden_opt in FORBIDDEN_OPTIONS:
        if forbidden_opt in mount_options:
            # Special case: 'atime' is only a problem if neither noatime nor relatime are set
            if forbidden_opt == 'atime':
                has_good_atime = any(opt in mount_options for opt in REQUIRED_XFS_OPTIONS['atime_options'])
                if not has_good_atime:
                    errors.append(
                        f"Pod {pod_name}: Full atime tracking is enabled (performance killer). "
                        f"Should use 'noatime' or 'relatime'"
                    )
            else:
                errors.append(
                    f"Pod {pod_name}: Forbidden mount option '{forbidden_opt}' detected. "
                    f"This will severely impact database performance."
                )
    
    # Check for required atime option (noatime or relatime)
    has_atime_option = any(opt in mount_options for opt in REQUIRED_XFS_OPTIONS['atime_options'])
    if not has_atime_option:
        warnings.append(
            f"Pod {pod_name}: Neither 'noatime' nor 'relatime' found in mount options. "
            f"This may impact write performance. Current options: {', '.join(mount_options)}"
        )
    
    # Check for recommended performance options
    has_largeio = 'largeio' in mount_options
    has_inode64 = 'inode64' in mount_options
    
    if not has_largeio:
        warnings.append(
            f"Pod {pod_name}: 'largeio' mount option not found. "
            f"This option improves performance for large sequential I/O (databases)."
        )
    
    if not has_inode64:
        warnings.append(
            f"Pod {pod_name}: 'inode64' mount option not found. "
            f"This option enables better inode allocation for large filesystems."
        )
    
    return errors, warnings


@pytest.mark.integration
def test_xfs_filesystem_on_data_volumes(core_v1):
    """
    Test that all Percona data volumes use XFS filesystem
    
    This test checks PXC and ProxySQL pods to ensure their data volumes
    are formatted with XFS, which is the recommended filesystem for
    production MySQL/Percona deployments.
    """
    # Get all pods in the namespace
    pods = core_v1.list_namespaced_pod(namespace=TEST_NAMESPACE)
    
    # Filter for Percona pods (PXC and ProxySQL)
    percona_pods = [
        pod for pod in pods.items
        if (pod.metadata.labels.get('app.kubernetes.io/component') in ['pxc', 'proxysql'] or
            'pxc' in pod.metadata.name.lower() or 
            'proxysql' in pod.metadata.name.lower())
    ]
    
    if not percona_pods:
        pytest.skip("No Percona pods found in namespace")
    
    console.print(f"[cyan]Found {len(percona_pods)} Percona pods to check[/cyan]")
    
    all_errors = []
    results = []
    
    for pod in percona_pods:
        pod_name = pod.metadata.name
        
        # Skip if pod is not running
        if pod.status.phase != 'Running':
            console.print(f"[yellow]⚠ Skipping {pod_name} (status: {pod.status.phase})[/yellow]")
            continue
        
        # Determine container name and data path
        if 'pxc' in pod_name.lower() and 'proxysql' not in pod_name.lower():
            container_name = 'pxc'
            mount_path = '/var/lib/mysql'
        elif 'proxysql' in pod_name.lower():
            container_name = 'proxysql'
            mount_path = '/var/lib/proxysql'
        else:
            console.print(f"[yellow]⚠ Skipping {pod_name} (unknown pod type)[/yellow]")
            continue
        
        console.print(f"[cyan]Checking filesystem for pod: {pod_name}[/cyan]")
        
        try:
            fs_info = get_filesystem_info_from_pod(
                core_v1, 
                TEST_NAMESPACE, 
                pod_name, 
                container_name,
                mount_path
            )
            
            results.append({
                'pod': pod_name,
                'container': container_name,
                'mount_path': mount_path,
                'fs_info': fs_info
            })
            
            # Check filesystem type
            if fs_info['fs_type'].lower() != 'xfs':
                error_msg = (
                    f"Pod {pod_name}: Data volume is {fs_info['fs_type']}, not XFS. "
                    f"Percona recommends XFS for production MySQL deployments. "
                    f"Device: {fs_info['device']}, Mount: {fs_info['mount_path']}"
                )
                all_errors.append(error_msg)
                console.print(f"[red]✗ {error_msg}[/red]")
            else:
                console.print(
                    f"[green]✓ {pod_name}: XFS filesystem detected on {fs_info['device']}[/green]"
                )
            
        except Exception as e:
            error_msg = f"Pod {pod_name}: Failed to check filesystem: {str(e)}"
            all_errors.append(error_msg)
            console.print(f"[red]✗ {error_msg}[/red]")
    
    # Summary
    console.print("\n[bold cyan]Filesystem Check Summary:[/bold cyan]")
    for result in results:
        console.print(
            f"  • {result['pod']}: {result['fs_info']['fs_type']} "
            f"on {result['fs_info']['device']}"
        )
    
    if all_errors:
        console.print(f"\n[bold red]✗ Found {len(all_errors)} filesystem errors[/bold red]")
        for error in all_errors:
            console.print(f"  [red]• {error}[/red]")
        pytest.fail(f"Filesystem validation failed with {len(all_errors)} errors")
    else:
        console.print(f"\n[bold green]✓ All {len(results)} Percona pods are using XFS filesystem[/bold green]")


@pytest.mark.integration
def test_xfs_mount_options(core_v1):
    """
    Test that XFS volumes have correct mount options for database workloads
    
    This test verifies that XFS volumes are mounted with options that follow
    Percona best practices for MySQL/Percona deployments. It checks for:
    - Appropriate atime settings (noatime or relatime)
    - Performance options (largeio, inode64)
    - Absence of forbidden options (sync, full atime)
    """
    # Get all pods in the namespace
    pods = core_v1.list_namespaced_pod(namespace=TEST_NAMESPACE)
    
    # Filter for Percona pods (PXC and ProxySQL)
    percona_pods = [
        pod for pod in pods.items
        if (pod.metadata.labels.get('app.kubernetes.io/component') in ['pxc', 'proxysql'] or
            'pxc' in pod.metadata.name.lower() or 
            'proxysql' in pod.metadata.name.lower())
    ]
    
    if not percona_pods:
        pytest.skip("No Percona pods found in namespace")
    
    console.print(f"[cyan]Found {len(percona_pods)} Percona pods to check mount options[/cyan]")
    
    all_errors = []
    all_warnings = []
    results = []
    
    for pod in percona_pods:
        pod_name = pod.metadata.name
        
        # Skip if pod is not running
        if pod.status.phase != 'Running':
            console.print(f"[yellow]⚠ Skipping {pod_name} (status: {pod.status.phase})[/yellow]")
            continue
        
        # Determine container name and data path
        if 'pxc' in pod_name.lower() and 'proxysql' not in pod_name.lower():
            container_name = 'pxc'
            mount_path = '/var/lib/mysql'
        elif 'proxysql' in pod_name.lower():
            container_name = 'proxysql'
            mount_path = '/var/lib/proxysql'
        else:
            console.print(f"[yellow]⚠ Skipping {pod_name} (unknown pod type)[/yellow]")
            continue
        
        console.print(f"[cyan]Checking mount options for pod: {pod_name}[/cyan]")
        
        try:
            fs_info = get_filesystem_info_from_pod(
                core_v1, 
                TEST_NAMESPACE, 
                pod_name, 
                container_name,
                mount_path
            )
            
            # Only check mount options if filesystem is XFS
            if fs_info['fs_type'].lower() != 'xfs':
                console.print(
                    f"[yellow]⚠ Skipping mount option check for {pod_name} "
                    f"(filesystem is {fs_info['fs_type']}, not XFS)[/yellow]"
                )
                continue
            
            results.append({
                'pod': pod_name,
                'mount_options': fs_info['mount_options'],
                'device': fs_info['device']
            })
            
            # Validate mount options
            errors, warnings = validate_xfs_mount_options(fs_info['mount_options'], pod_name)
            
            all_errors.extend(errors)
            all_warnings.extend(warnings)
            
            if not errors and not warnings:
                console.print(
                    f"[green]✓ {pod_name}: Mount options are optimal[/green]"
                )
                console.print(f"[dim]  Options: {', '.join(fs_info['mount_options'])}[/dim]")
            elif not errors:
                console.print(
                    f"[yellow]⚠ {pod_name}: Mount options could be improved[/yellow]"
                )
                console.print(f"[dim]  Options: {', '.join(fs_info['mount_options'])}[/dim]")
            
        except Exception as e:
            error_msg = f"Pod {pod_name}: Failed to check mount options: {str(e)}"
            all_errors.append(error_msg)
            console.print(f"[red]✗ {error_msg}[/red]")
    
    # Summary
    console.print("\n[bold cyan]Mount Options Summary:[/bold cyan]")
    for result in results:
        console.print(f"  • {result['pod']}:")
        console.print(f"    {', '.join(result['mount_options'])}")
    
    # Print warnings (non-fatal)
    if all_warnings:
        console.print(f"\n[bold yellow]⚠ Mount option recommendations ({len(all_warnings)}):[/bold yellow]")
        for warning in all_warnings:
            console.print(f"  [yellow]• {warning}[/yellow]")
    
    # Fail on errors
    if all_errors:
        console.print(f"\n[bold red]✗ Found {len(all_errors)} critical mount option errors[/bold red]")
        for error in all_errors:
            console.print(f"  [red]• {error}[/red]")
        pytest.fail(f"Mount option validation failed with {len(all_errors)} errors")
    else:
        console.print(
            f"\n[bold green]✓ All {len(results)} XFS volumes passed mount option validation[/bold green]"
        )
        if all_warnings:
            console.print(
                "[yellow]Note: Some recommendations above could improve performance further[/yellow]"
            )

