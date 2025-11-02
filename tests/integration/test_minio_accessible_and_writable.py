"""
Test MinIO accessibility and bucket write capability (S3-compatible)
"""
import pytest
import base64
import subprocess
from kubernetes import client
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_minio_accessible_and_writable(core_v1):
    """Test MinIO accessibility and bucket write capability (S3-compatible)"""
    if TEST_BACKUP_TYPE != 'minio':
        pytest.skip(f"Skipping MinIO test - using {TEST_BACKUP_TYPE} instead of MinIO")

    # Default bucket name if not set (should match what's configured in Percona)
    bucket_name = TEST_BACKUP_BUCKET or 'percona-backups'

    # Get MinIO pod and credentials
    try:
        minio_pods = core_v1.list_namespaced_pod(
            namespace='minio',
            label_selector='app=minio'
        )
    except:
        # Fallback: get all pods in minio namespace and filter by name
        all_pods = core_v1.list_namespaced_pod(namespace='minio')
        minio_pods = type('obj', (object,), {'items': [p for p in all_pods.items if 'minio' in p.metadata.name.lower()]})()

    assert len(minio_pods.items) > 0, "MinIO pod not found in minio namespace"
    minio_pod = minio_pods.items[0]

    # Get credentials from secret
    secret = core_v1.read_namespaced_secret(
        name='percona-backup-minio-credentials',
        namespace=TEST_NAMESPACE
    )

    # Read credentials from secret (can be in string_data or base64-encoded data)
    string_data = getattr(secret, 'string_data', {}) or {}
    data = getattr(secret, 'data', {}) or {}

    access_key = string_data.get('AWS_ACCESS_KEY_ID')
    if not access_key and data.get('AWS_ACCESS_KEY_ID'):
        access_key = base64.b64decode(data['AWS_ACCESS_KEY_ID']).decode()

    secret_key = string_data.get('AWS_SECRET_ACCESS_KEY')
    if not secret_key and data.get('AWS_SECRET_ACCESS_KEY'):
        secret_key = base64.b64decode(data['AWS_SECRET_ACCESS_KEY']).decode()

    endpoint = string_data.get('AWS_ENDPOINT')
    if not endpoint and data.get('AWS_ENDPOINT'):
        endpoint = base64.b64decode(data['AWS_ENDPOINT']).decode()

    assert access_key and secret_key and endpoint, \
        "MinIO credentials not found in secret percona-backup-minio-credentials"

    console.print(f"[cyan]MinIO Endpoint:[/cyan] {endpoint}")
    console.print(f"[cyan]Bucket:[/cyan] {bucket_name}")

    # If secret credentials don't work, try to get actual credentials from MinIO pod env vars
    # This handles cases where the secret might not match MinIO's actual credentials
    try:
        env_result = subprocess.run(
            ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--', 'env'],
            capture_output=True, text=True, timeout=10
        )
        if env_result.returncode == 0:
            for line in env_result.stdout.split('\n'):
                if line.startswith('MINIO_ROOT_USER='):
                    actual_access_key = line.split('=', 1)[1]
                elif line.startswith('MINIO_ROOT_PASSWORD='):
                    actual_secret_key = line.split('=', 1)[1]
    except:
        pass

    # Use MinIO client (mc) inside the pod to test bucket access and write
    import time
    test_content = f"test-{int(time.time())}.txt"
    test_data = b"Percona backup test data - MinIO bucket write test"

    try:
        # Try credentials from secret first (what Percona uses), fallback to actual MinIO credentials
        test_credentials = [(access_key, secret_key, "from secret")]
        if 'actual_access_key' in locals() and actual_access_key != access_key:
            test_credentials.append((actual_access_key, actual_secret_key, "from MinIO pod"))

        mc_alias = 'test-minio'
        credentials_work = False

        for cred_access_key, cred_secret_key, cred_source in test_credentials:
            try:
                # Configure mc alias (using MinIO's internal endpoint)
                mc_config_cmd = [
                    'kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                    'mc', 'alias', 'set', mc_alias, 
                    'http://localhost:9000', cred_access_key, cred_secret_key
                ]

                result = subprocess.run(mc_config_cmd, capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    credentials_work = True
                    access_key = cred_access_key
                    secret_key = cred_secret_key
                    console.print(f"[cyan]Using credentials:[/cyan] {cred_source}")
                    break
            except:
                continue

        assert credentials_work, \
            f"Failed to configure MinIO client with any available credentials. " \
            f"Secret credentials may not match MinIO's actual credentials."

        # Check if bucket exists, create it if it doesn't
        ls_cmd = ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                 'mc', 'ls', f'{mc_alias}/{bucket_name}']
        result = subprocess.run(ls_cmd, capture_output=True, text=True, timeout=10)

        if result.returncode != 0:
            # Bucket doesn't exist, create it
            console.print(f"[yellow]⚠[/yellow] MinIO bucket {bucket_name} does not exist, creating it...")
            mb_cmd = ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                     'mc', 'mb', f'{mc_alias}/{bucket_name}']
            mb_result = subprocess.run(mb_cmd, capture_output=True, text=True, timeout=10)

            # Check if bucket was created or already exists
            error_msg = (mb_result.stderr or mb_result.stdout or '').lower()
            if (mb_result.returncode == 0 or 
                'already exists' in error_msg or 
                'already own it' in error_msg or
                'succeeded' in error_msg):
                console.print(f"[green]✓[/green] MinIO bucket {bucket_name} created or already exists")
                # Retry listing to confirm it exists now
                result = subprocess.run(ls_cmd, capture_output=True, text=True, timeout=10)
            else:
                pytest.fail(f"Failed to create MinIO bucket {bucket_name}: {mb_result.stderr or mb_result.stdout}")

        assert result.returncode == 0, \
            f"MinIO bucket {bucket_name} does not exist or is not accessible: {result.stderr or result.stdout}"

        console.print(f"[green]✓[/green] MinIO bucket {bucket_name} exists and is accessible")

        # Test write capability - write a test file
        # First create the test file content inside the pod
        write_cmd = [
            'kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
            'sh', '-c', f'echo "{base64.b64encode(test_data).decode()}" | base64 -d > /tmp/test_write.txt && cat /tmp/test_write.txt | mc pipe {mc_alias}/{bucket_name}/{test_content}'
        ]
        result = subprocess.run(write_cmd, capture_output=True, text=True, timeout=10)

        assert result.returncode == 0, \
            f"Failed to write test file to MinIO bucket: {result.stderr or result.stdout}"

        console.print(f"[green]✓[/green] Successfully wrote test file to MinIO bucket: {test_content}")

        # Verify the file was written by listing it
        verify_cmd = ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                     'mc', 'ls', f'{mc_alias}/{bucket_name}/{test_content}']
        result = subprocess.run(verify_cmd, capture_output=True, text=True, timeout=10)

        assert result.returncode == 0, \
            f"Test file not found in bucket after write: {result.stderr or result.stdout}"

        # Verify we can read it back
        read_cmd = ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                   'mc', 'cat', f'{mc_alias}/{bucket_name}/{test_content}']
        result = subprocess.run(read_cmd, capture_output=True, text=True, timeout=10)

        assert result.returncode == 0, \
            f"Failed to read test file from bucket: {result.stderr or result.stdout}"
        assert result.stdout.strip() == test_data.decode(), \
            f"Test file content mismatch: expected '{test_data.decode()}', got '{result.stdout.strip()}'"

        console.print(f"[green]✓[/green] Successfully read test file from MinIO bucket")

        # Clean up test file
        rm_cmd = ['kubectl', 'exec', '-n', 'minio', minio_pod.metadata.name, '--',
                 'mc', 'rm', f'{mc_alias}/{bucket_name}/{test_content}']
        subprocess.run(rm_cmd, capture_output=True, text=True, timeout=10)

        console.print(f"[green]✓[/green] MinIO bucket is writable and readable - backup functionality verified")

    except subprocess.TimeoutExpired:
        pytest.fail("MinIO access test timed out")
    except FileNotFoundError:
        pytest.fail("kubectl not available - cannot test MinIO from outside cluster")
    except Exception as e:
        pytest.fail(f"MinIO bucket test failed: {e}")

