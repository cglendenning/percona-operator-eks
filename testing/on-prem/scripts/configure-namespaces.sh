#!/bin/bash
# Interactive namespace configuration helper for Percona test suite
# This script prompts for all namespace values and creates an env file

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Percona Test Suite - Namespace Configuration${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "This script will help you configure namespace values for environments"
echo "where Percona, MinIO, and Litmus are in different namespaces."
echo ""
echo -e "${YELLOW}Press Enter to use the default value shown in [brackets]${NC}"
echo ""

# Function to prompt for input with default
prompt_with_default() {
    local var_name="$1"
    local default_value="$2"
    local description="$3"
    local value=""
    
    echo -e "${CYAN}${description}${NC}"
    read -p "  Enter value [${default_value}]: " value
    value=${value:-$default_value}
    echo ""
    
    # Store in array for later use
    eval "${var_name}='${value}'"
}

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: kubectl not found. Cannot auto-detect namespaces.${NC}"
    echo ""
    AUTO_DETECT=false
else
    AUTO_DETECT=true
fi

# Auto-detect existing namespaces if kubectl is available
if [ "$AUTO_DETECT" = true ]; then
    echo -e "${BLUE}Scanning for existing namespaces...${NC}"
    EXISTING_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_NAMESPACES" ]; then
        echo -e "${GREEN}Found namespaces:${NC}"
        for ns in $EXISTING_NAMESPACES; do
            echo "  - $ns"
        done
        echo ""
    fi
fi

# Prompt for each namespace
prompt_with_default "PERCONA_NS" "percona" "Percona XtraDB Cluster Namespace (where PXC pods run)"
prompt_with_default "OPERATOR_NS" "$PERCONA_NS" "Percona Operator Namespace (usually same as Percona namespace)"
prompt_with_default "MINIO_NS" "minio" "MinIO Namespace (for S3-compatible backup storage)"
prompt_with_default "CHAOS_NS" "litmus" "Litmus Chaos Namespace (for resiliency/DR testing)"

# Prompt for other common settings
echo -e "${CYAN}Other Configuration${NC}"
echo ""
prompt_with_default "CLUSTER_NAME" "pxc-cluster" "Percona Cluster Name"
prompt_with_default "BACKUP_TYPE" "minio" "Backup Type (minio or s3)"
prompt_with_default "BACKUP_BUCKET" "percona-backups" "Backup Bucket Name"

# Verify namespaces exist (if kubectl available)
if [ "$AUTO_DETECT" = true ]; then
    echo -e "${BLUE}Verifying namespaces...${NC}"
    ALL_OK=true
    
    for ns_var in PERCONA_NS OPERATOR_NS MINIO_NS CHAOS_NS; do
        ns_value="${!ns_var}"
        ns_label=$(echo "$ns_var" | sed 's/_NS//; s/_/ /g')
        
        if kubectl get namespace "$ns_value" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} ${ns_label}: ${ns_value} exists"
        else
            echo -e "  ${YELLOW}⚠${NC} ${ns_label}: ${ns_value} ${YELLOW}does not exist${NC}"
            ALL_OK=false
        fi
    done
    echo ""
    
    if [ "$ALL_OK" = false ]; then
        echo -e "${YELLOW}⚠ Warning: Some namespaces don't exist yet.${NC}"
        echo "Tests may fail if resources are not deployed in these namespaces."
        echo ""
    fi
fi

# Generate export statements
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Configuration Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "You can use these namespaces by:"
echo ""
echo -e "${BLUE}Option 1: Export in your current shell${NC}"
echo ""
echo "export TEST_NAMESPACE='${PERCONA_NS}'"
echo "export TEST_OPERATOR_NAMESPACE='${OPERATOR_NS}'"
echo "export MINIO_NAMESPACE='${MINIO_NS}'"
echo "export CHAOS_NAMESPACE='${CHAOS_NS}'"
echo "export TEST_CLUSTER_NAME='${CLUSTER_NAME}'"
echo "export TEST_BACKUP_TYPE='${BACKUP_TYPE}'"
echo "export TEST_BACKUP_BUCKET='${BACKUP_BUCKET}'"
echo ""

# Ask if user wants to create an env file
read -p "Create a .env file with these settings? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ENV_FILE=".env.test"
    
    cat > "$ENV_FILE" <<EOF
# Percona Test Suite Configuration
# Generated: $(date)
# Source this file before running tests: source $ENV_FILE

# Namespace Configuration
export TEST_NAMESPACE='${PERCONA_NS}'
export TEST_OPERATOR_NAMESPACE='${OPERATOR_NS}'
export MINIO_NAMESPACE='${MINIO_NS}'
export CHAOS_NAMESPACE='${CHAOS_NS}'

# Cluster Configuration
export TEST_CLUSTER_NAME='${CLUSTER_NAME}'
export TEST_BACKUP_TYPE='${BACKUP_TYPE}'
export TEST_BACKUP_BUCKET='${BACKUP_BUCKET}'

# Optional: Uncomment to override auto-detected node count
# export TEST_EXPECTED_NODES=6

# Optional: Uncomment to enable resiliency test features
# export RESILIENCY_MTTR_TIMEOUT_SECONDS=120

# Optional: Uncomment to generate test reports
# export GENERATE_HTML_REPORT=true
# export GENERATE_COVERAGE=true
EOF
    
    echo ""
    echo -e "${GREEN}✓ Created ${ENV_FILE}${NC}"
    echo ""
    echo "To use these settings, run:"
    echo -e "  ${BLUE}source ${ENV_FILE}${NC}"
    echo "  ${BLUE}./tests/run_tests.sh${NC}"
    echo ""
fi

echo -e "${BLUE}Option 2: Pass as environment variables directly${NC}"
echo ""
echo "TEST_NAMESPACE='${PERCONA_NS}' \\"
echo "TEST_OPERATOR_NAMESPACE='${OPERATOR_NS}' \\"
echo "MINIO_NAMESPACE='${MINIO_NS}' \\"
echo "CHAOS_NAMESPACE='${CHAOS_NS}' \\"
echo "TEST_CLUSTER_NAME='${CLUSTER_NAME}' \\"
echo "TEST_BACKUP_TYPE='${BACKUP_TYPE}' \\"
echo "TEST_BACKUP_BUCKET='${BACKUP_BUCKET}' \\"
echo "./tests/run_tests.sh"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Ready to run tests!${NC}"
echo -e "${BLUE}========================================${NC}"

