#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo -e "${RED}================================================${NC}"
echo -e "${RED}   DB Concierge Operator Uninstallation${NC}"
echo -e "${RED}================================================${NC}"
echo ""

# Warning
echo -e "${YELLOW}WARNING: This will remove the DB Concierge operator.${NC}"
echo -e "${YELLOW}AppDatabase resources and the CRD will be preserved by default.${NC}"
echo ""
read -p "Continue with uninstallation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found.${NC}"
    exit 1
fi

# Step 1: Delete operator deployment
echo ""
echo -e "${BLUE}[1/5] Removing operator deployment...${NC}"
if kubectl get deployment db-concierge-operator -n db-concierge &> /dev/null; then
    kubectl delete deployment db-concierge-operator -n db-concierge
    echo -e "${GREEN}✓ Operator deployment removed${NC}"
else
    echo -e "${YELLOW}Operator deployment not found, skipping${NC}"
fi

# Step 2: Delete RBAC
echo ""
echo -e "${BLUE}[2/5] Removing RBAC resources...${NC}"
if kubectl get clusterrolebinding db-concierge-operator &> /dev/null; then
    kubectl delete clusterrolebinding db-concierge-operator
fi
if kubectl get clusterrole db-concierge-operator &> /dev/null; then
    kubectl delete clusterrole db-concierge-operator
fi
if kubectl get clusterrole appdatabase-creator &> /dev/null; then
    kubectl delete clusterrole appdatabase-creator
fi
if kubectl get serviceaccount db-concierge-operator -n db-concierge &> /dev/null; then
    kubectl delete serviceaccount db-concierge-operator -n db-concierge
fi
echo -e "${GREEN}✓ RBAC resources removed${NC}"

# Step 3: Ask about secrets
echo ""
echo -e "${BLUE}[3/5] MySQL admin credentials secret...${NC}"
echo -e "${YELLOW}The secret 'db-concierge-mysql-admin' contains your MySQL admin credentials.${NC}"
read -p "Delete the secret? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if kubectl get secret db-concierge-mysql-admin -n db-concierge &> /dev/null; then
        kubectl delete secret db-concierge-mysql-admin -n db-concierge
        echo -e "${GREEN}✓ Secret removed${NC}"
    fi
else
    echo -e "${YELLOW}Secret preserved${NC}"
fi

# Step 4: Ask about namespace
echo ""
echo -e "${BLUE}[4/5] Namespace...${NC}"
read -p "Delete the 'db-concierge' namespace? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if kubectl get namespace db-concierge &> /dev/null; then
        kubectl delete namespace db-concierge
        echo -e "${GREEN}✓ Namespace removed${NC}"
    fi
else
    echo -e "${YELLOW}Namespace preserved${NC}"
fi

# Step 5: Ask about CRD
echo ""
echo -e "${BLUE}[5/5] Custom Resource Definition...${NC}"
echo -e "${RED}WARNING: Deleting the CRD will also delete ALL AppDatabase resources!${NC}"
echo -e "${YELLOW}This will NOT delete the actual MySQL databases, users, or secrets.${NC}"
echo -e "${YELLOW}But you will lose the Kubernetes representation of them.${NC}"
echo ""
read -p "Delete the AppDatabase CRD? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # List existing AppDatabase resources
    echo ""
    echo -e "${YELLOW}Existing AppDatabase resources:${NC}"
    kubectl get appdatabases --all-namespaces 2>/dev/null || echo "None found"
    echo ""
    echo -e "${RED}These will all be DELETED if you proceed!${NC}"
    read -p "Are you absolutely sure? Type 'DELETE' to confirm: " CONFIRM
    if [ "$CONFIRM" = "DELETE" ]; then
        if kubectl get crd appdatabases.db.stillwaters.io &> /dev/null; then
            kubectl delete crd appdatabases.db.stillwaters.io
            echo -e "${GREEN}✓ CRD removed${NC}"
        fi
    else
        echo -e "${YELLOW}CRD deletion cancelled${NC}"
    fi
else
    echo -e "${YELLOW}CRD preserved${NC}"
fi

# Cleanup complete
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Uninstallation Complete${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${YELLOW}Note:${NC}"
echo "- MySQL databases and users created by the operator are NOT deleted"
echo "- Kubernetes secrets in application namespaces are NOT deleted"
echo "- You must clean these up manually if needed"
echo ""
echo -e "${BLUE}To manually clean up application secrets:${NC}"
echo "  kubectl get secrets -A -l app.kubernetes.io/managed-by=db-concierge-operator"
echo "  kubectl delete secret <secret-name> -n <namespace>"
echo ""
echo -e "${BLUE}To manually clean up MySQL databases:${NC}"
echo "  mysql -h <host> -u root -p"
echo "  DROP DATABASE <database_name>;"
echo "  DROP USER '<username>'@'%';"
echo ""

