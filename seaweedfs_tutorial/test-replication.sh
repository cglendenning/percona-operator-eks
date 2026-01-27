#!/usr/bin/env bash
# Test script to verify SeaweedFS replication between namespaces

set -euo pipefail

CONTEXT="${CLUSTER_CONTEXT:-k3d-seaweedfs-tutorial}"
PRIMARY_NS="seaweedfs-primary"
SECONDARY_NS="seaweedfs-secondary"
BUCKET_NAME="test-replication-$(date +%s)"
TEST_FILE="test-file-$(date +%s).txt"
TEST_CONTENT="Hello from primary namespace! Timestamp: $(date)"

echo "=== SeaweedFS Replication Test ==="
echo ""
echo "Context: $CONTEXT"
echo "Primary namespace: $PRIMARY_NS"
echo "Secondary namespace: $SECONDARY_NS"
echo "Bucket: $BUCKET_NAME"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Check if aws CLI is available (or use curl)
USE_AWS=false
if command -v aws &> /dev/null; then
    USE_AWS=true
    echo "Using AWS CLI for S3 operations"
else
    echo "AWS CLI not found, using curl for S3 operations"
fi

# Set kubectl context
echo "Setting kubectl context..."
kubectl config use-context "$CONTEXT" || {
    echo "Error: Context '$CONTEXT' not found"
    exit 1
}

# Get filer service names
echo "Getting filer service names..."
PRIMARY_FILER=$(kubectl get svc -n "$PRIMARY_NS" -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
SECONDARY_FILER=$(kubectl get svc -n "$SECONDARY_NS" -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PRIMARY_FILER" ] || [ -z "$SECONDARY_FILER" ]; then
    echo "Error: Could not find filer services"
    echo "Primary filer: $PRIMARY_FILER"
    echo "Secondary filer: $SECONDARY_FILER"
    exit 1
fi

echo "Primary filer: $PRIMARY_FILER"
echo "Secondary filer: $SECONDARY_FILER"
echo ""

# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n "$PRIMARY_NS" -l app=seaweedfs --timeout=120s || true
kubectl wait --for=condition=ready pod -n "$SECONDARY_NS" -l app=seaweedfs --timeout=120s || true

# Start port forwards in background
echo "Starting port forwards..."
kubectl port-forward -n "$PRIMARY_NS" svc/$PRIMARY_FILER 8333:8333 > /dev/null 2>&1 &
PRIMARY_PF_PID=$!
sleep 2

kubectl port-forward -n "$SECONDARY_NS" svc/$SECONDARY_FILER 8334:8333 > /dev/null 2>&1 &
SECONDARY_PF_PID=$!
sleep 2

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up port forwards..."
    kill $PRIMARY_PF_PID 2>/dev/null || true
    kill $SECONDARY_PF_PID 2>/dev/null || true
    rm -f "$TEST_FILE" downloaded-file.txt 2>/dev/null || true
}
trap cleanup EXIT

# Create test file
echo "$TEST_CONTENT" > "$TEST_FILE"
echo "Created test file: $TEST_FILE"
echo "Content: $TEST_CONTENT"
echo ""

# Step 1: Create bucket in primary namespace
echo "Step 1: Creating bucket '$BUCKET_NAME' in primary namespace..."
if [ "$USE_AWS" = true ]; then
    aws --endpoint-url=http://localhost:8333 s3 mb "s3://$BUCKET_NAME" || {
        echo "Error: Failed to create bucket"
        exit 1
    }
else
    curl -X PUT "http://localhost:8333/$BUCKET_NAME" || {
        echo "Error: Failed to create bucket"
        exit 1
    }
fi
echo "Bucket created"
echo ""

# Step 2: Upload file to primary namespace
echo "Step 2: Uploading file to primary namespace..."
if [ "$USE_AWS" = true ]; then
    aws --endpoint-url=http://localhost:8333 s3 cp "$TEST_FILE" "s3://$BUCKET_NAME/$TEST_FILE" || {
        echo "Error: Failed to upload file"
        exit 1
    }
else
    curl -X PUT "http://localhost:8333/$BUCKET_NAME/$TEST_FILE" \
        -H "Content-Type: text/plain" \
        --data-binary "@$TEST_FILE" || {
        echo "Error: Failed to upload file"
        exit 1
    }
fi
echo "File uploaded"
echo ""

# Step 3: Verify file in primary namespace
echo "Step 3: Verifying file in primary namespace..."
if [ "$USE_AWS" = true ]; then
    aws --endpoint-url=http://localhost:8333 s3 ls "s3://$BUCKET_NAME/" | grep -q "$TEST_FILE" || {
        echo "Error: File not found in primary namespace"
        exit 1
    }
else
    curl -s "http://localhost:8333/$BUCKET_NAME/" | grep -q "$TEST_FILE" || {
        echo "Error: File not found in primary namespace"
        exit 1
    }
fi
echo "File verified in primary namespace"
echo ""

# Step 4: Wait a bit for replication (if configured)
echo "Step 4: Waiting 5 seconds for replication..."
sleep 5
echo ""

# Step 5: Check if file exists in secondary namespace
echo "Step 5: Checking for file in secondary namespace..."
FOUND_IN_SECONDARY=false

if [ "$USE_AWS" = true ]; then
    if aws --endpoint-url=http://localhost:8334 s3 ls "s3://$BUCKET_NAME/" 2>/dev/null | grep -q "$TEST_FILE"; then
        FOUND_IN_SECONDARY=true
    fi
else
    if curl -s "http://localhost:8334/$BUCKET_NAME/" 2>/dev/null | grep -q "$TEST_FILE"; then
        FOUND_IN_SECONDARY=true
    fi
fi

if [ "$FOUND_IN_SECONDARY" = true ]; then
    echo "SUCCESS: File found in secondary namespace!"
    echo ""
    
    # Download and verify content
    echo "Step 6: Downloading and verifying file content from secondary namespace..."
    if [ "$USE_AWS" = true ]; then
        aws --endpoint-url=http://localhost:8334 s3 cp "s3://$BUCKET_NAME/$TEST_FILE" downloaded-file.txt || {
            echo "Warning: Failed to download file"
        }
    else
        curl -s "http://localhost:8334/$BUCKET_NAME/$TEST_FILE" -o downloaded-file.txt || {
            echo "Warning: Failed to download file"
        }
    fi
    
    if [ -f downloaded-file.txt ]; then
        DOWNLOADED_CONTENT=$(cat downloaded-file.txt)
        if [ "$DOWNLOADED_CONTENT" = "$TEST_CONTENT" ]; then
            echo "SUCCESS: File content matches!"
            echo "Original: $TEST_CONTENT"
            echo "Downloaded: $DOWNLOADED_CONTENT"
        else
            echo "WARNING: File content does not match"
            echo "Original: $TEST_CONTENT"
            echo "Downloaded: $DOWNLOADED_CONTENT"
        fi
    fi
else
    echo "WARNING: File not found in secondary namespace"
    echo ""
    echo "This could mean:"
    echo "  1. Replication is not configured between namespaces"
    echo "  2. Replication is still in progress (wait longer)"
    echo "  3. Replication is configured but not working"
    echo ""
    echo "To configure replication, see the README.md in this directory"
fi

echo ""
echo "=== Test Complete ==="
