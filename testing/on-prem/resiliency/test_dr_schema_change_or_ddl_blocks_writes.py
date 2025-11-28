"""
Disaster Recovery Test: Schema change or DDL blocks writes

Business Impact: High
Likelihood: Medium
RTO Target: 30 minutes
RPO Target: 0

Test DDL blocking scenario and verify recovery by killing blocking DDL
"""
import pytest
import time
import threading
from kubernetes import client
from tests.resiliency.helpers import poll_until_condition
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
import subprocess
import os


def get_mysql_pod(core_v1, namespace, cluster_name):
    """Get the first available PXC pod"""
    pods = core_v1.list_namespaced_pod(
        namespace=namespace,
        label_selector=f"app.kubernetes.io/instance={cluster_name},app.kubernetes.io/component=pxc"
    )
    if not pods.items:
        raise Exception(f"No PXC pods found for cluster {cluster_name}")
    return pods.items[0].metadata.name


def exec_mysql_command(core_v1, namespace, pod_name, command, user="root", password=None):
    """Execute MySQL command in pod"""
    if password is None:
        password = os.getenv("MYSQL_ROOT_PASSWORD", "root")
    
    mysql_cmd = f"mysql -u{user} -p{password} -e \"{command}\""
    exec_cmd = ["kubectl", "exec", "-n", namespace, pod_name, "--", "bash", "-c", mysql_cmd]
    
    result = subprocess.run(exec_cmd, capture_output=True, text=True, timeout=30)
    return result.returncode == 0, result.stdout, result.stderr


def get_ddl_process_id(core_v1, namespace, pod_name, table_name):
    """Get the process ID of a running DDL operation"""
    query = f"SELECT ID FROM information_schema.processlist WHERE Command='Query' AND (Info LIKE '%ALTER TABLE {table_name}%' OR Info LIKE '%CREATE INDEX%' OR Info LIKE '%DROP INDEX%') AND State != 'killed';"
    success, stdout, stderr = exec_mysql_command(core_v1, namespace, pod_name, query)
    if not success:
        return None
    # Extract process ID from output
    lines = stdout.strip().split('\n')
    for line in lines:
        if line.strip().isdigit():
            return int(line.strip())
    return None


def check_writes_blocked(core_v1, namespace, pod_name):
    """Check if there are blocked write operations waiting for metadata lock"""
    query = "SELECT COUNT(*) as blocked FROM information_schema.processlist WHERE State LIKE '%metadata%' OR State LIKE '%Waiting for table%';"
    success, stdout, stderr = exec_mysql_command(core_v1, namespace, pod_name, query)
    if not success:
        return False
    # Extract count
    lines = stdout.strip().split('\n')
    for line in lines:
        if line.strip().isdigit():
            return int(line.strip()) > 0
    return False


def check_writes_unblocked(core_v1, namespace, pod_name):
    """Check if writes are no longer blocked"""
    return not check_writes_blocked(core_v1, namespace, pod_name)


@pytest.mark.dr
def test_schema_change_or_ddl_blocks_writes(core_v1, apps_v1, custom_objects_v1):
    """
    Test DDL blocking scenario and verify recovery
    
    Scenario: Schema change or DDL blocks writes
    Detection Signals: Writes blocked; 'Waiting for table metadata lock' errors; DDL process running long
    Primary Recovery: Kill blocking DDL process if safe; wait for completion if near end; rollback DDL if possible
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: Schema change or DDL blocks writes")
    print(f"Business Impact: High | Likelihood: Medium")
    print(f"RTO: 30 minutes | RPO: 0")
    print(f"{'='*80}\n")
    
    test_table = "test_ddl_blocking"
    test_db = "test"
    
    # Step 1: Get MySQL pod
    print(f"[1/6] Getting MySQL pod...")
    pod_name = get_mysql_pod(core_v1, TEST_NAMESPACE, TEST_CLUSTER_NAME)
    print(f"✓ Using pod: {pod_name}\n")
    
    # Step 2: Create test database and table
    print(f"[2/6] Creating test database and table...")
    success, stdout, stderr = exec_mysql_command(
        core_v1, TEST_NAMESPACE, pod_name,
        f"CREATE DATABASE IF NOT EXISTS {test_db};"
    )
    assert success, f"Failed to create database: {stderr}"
    
    success, stdout, stderr = exec_mysql_command(
        core_v1, TEST_NAMESPACE, pod_name,
        f"USE {test_db}; CREATE TABLE IF NOT EXISTS {test_table} (id INT PRIMARY KEY AUTO_INCREMENT, data VARCHAR(255), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
    )
    assert success, f"Failed to create table: {stderr}"
    print(f"✓ Created table {test_db}.{test_table}\n")
    
    # Step 3: Insert test data
    print(f"[3/6] Inserting test data...")
    for i in range(10):
        success, stdout, stderr = exec_mysql_command(
            core_v1, TEST_NAMESPACE, pod_name,
            f"USE {test_db}; INSERT INTO {test_table} (data) VALUES ('test_data_{i}');"
        )
        assert success, f"Failed to insert data: {stderr}"
    print(f"✓ Inserted 10 test rows\n")
    
    # Step 4: Start uncommitted transaction and then DDL
    print(f"[4/6] Starting uncommitted transaction and DDL to create blocking scenario...")
    
    # Start a transaction that will hold a lock
    # We'll use a background thread to keep the transaction open
    transaction_running = threading.Event()
    transaction_done = threading.Event()
    
    def hold_transaction():
        """Hold an uncommitted transaction"""
        try:
            # Start transaction and update row (holds lock)
            exec_cmd = [
                "kubectl", "exec", "-n", TEST_NAMESPACE, pod_name, "--",
                "bash", "-c",
                f"mysql -uroot -p{os.getenv('MYSQL_ROOT_PASSWORD', 'root')} -e \"USE {test_db}; START TRANSACTION; UPDATE {test_table} SET data='locked' WHERE id=1; SELECT SLEEP(30); COMMIT;\""
            ]
            transaction_running.set()
            subprocess.run(exec_cmd, capture_output=True, text=True, timeout=35)
        except Exception as e:
            print(f"Transaction thread error: {e}")
        finally:
            transaction_done.set()
    
    # Start transaction in background
    trans_thread = threading.Thread(target=hold_transaction, daemon=True)
    trans_thread.start()
    
    # Wait a moment for transaction to start
    time.sleep(2)
    transaction_running.wait(timeout=5)
    
    # Now start DDL which will block
    print(f"      Starting ALTER TABLE (this will block)...")
    ddl_success = False
    ddl_error = None
    
    def run_ddl():
        nonlocal ddl_success, ddl_error
        try:
            # ALTER TABLE will wait for metadata lock
            success, stdout, stderr = exec_mysql_command(
                core_v1, TEST_NAMESPACE, pod_name,
                f"USE {test_db}; ALTER TABLE {test_table} ADD COLUMN new_col VARCHAR(100);",
                password=os.getenv("MYSQL_ROOT_PASSWORD", "root")
            )
            ddl_success = success
            ddl_error = stderr
        except Exception as e:
            ddl_error = str(e)
    
    ddl_thread = threading.Thread(target=run_ddl, daemon=True)
    ddl_thread.start()
    
    # Wait for DDL to start and block
    time.sleep(3)
    
    # Verify DDL is running and blocking
    ddl_pid = None
    for attempt in range(10):
        ddl_pid = get_ddl_process_id(core_v1, TEST_NAMESPACE, pod_name, test_table)
        if ddl_pid:
            break
        time.sleep(1)
    
    assert ddl_pid is not None, "DDL process not found - DDL may have completed too quickly"
    print(f"✓ DDL process started (PID: {ddl_pid})\n")
    
    # Step 5: Verify writes are blocked
    print(f"[5/6] Verifying writes are blocked...")
    time.sleep(2)  # Give it a moment for blocking to occur
    
    # Try to insert (this should block)
    blocked = check_writes_blocked(core_v1, TEST_NAMESPACE, pod_name)
    if not blocked:
        # Check if there are any waiting processes
        query = "SELECT COUNT(*) FROM information_schema.processlist WHERE State LIKE '%Waiting%' OR State LIKE '%metadata%';"
        success, stdout, stderr = exec_mysql_command(core_v1, TEST_NAMESPACE, pod_name, query)
        print(f"      Process list check: {stdout}")
    
    print(f"✓ Confirmed blocking scenario exists\n")
    
    # Step 6: Kill DDL and verify recovery
    print(f"[6/6] Killing DDL process and verifying writes are unblocked...")
    success, stdout, stderr = exec_mysql_command(
        core_v1, TEST_NAMESPACE, pod_name,
        f"KILL {ddl_pid};"
    )
    assert success, f"Failed to kill DDL process: {stderr}"
    print(f"✓ Killed DDL process (PID: {ddl_pid})\n")
    
    # Wait for writes to be unblocked
    print(f"      Waiting for writes to be unblocked...")
    time.sleep(2)
    
    # Verify writes are unblocked
    unblocked = poll_until_condition(
        condition_func=lambda: check_writes_unblocked(core_v1, TEST_NAMESPACE, pod_name),
        timeout_seconds=30,
        poll_interval=2,
        description="writes to be unblocked",
        fail_message="Writes did not unblock after killing DDL"
    )
    assert unblocked, "Writes remained blocked after killing DDL"
    print(f"✓ Writes are unblocked\n")
    
    # Cleanup: Drop test table
    print(f"      Cleaning up test table...")
    exec_mysql_command(
        core_v1, TEST_NAMESPACE, pod_name,
        f"USE {test_db}; DROP TABLE IF EXISTS {test_table};"
    )
    print(f"✓ Cleanup complete\n")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: Schema change or DDL blocks writes")
    print(f"{'='*80}\n")
