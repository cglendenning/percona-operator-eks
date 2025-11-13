# WSL Setup Guide for Percona On-Premise Scripts

This guide will help you set up and run the Percona XtraDB Cluster installation scripts on Windows Subsystem for Linux (WSL).

## Prerequisites

### 1. Install WSL2

If you haven't already installed WSL2, follow these steps:

```powershell
# In PowerShell (as Administrator)
wsl --install
```

Or to install a specific distribution (recommended: Ubuntu):

```powershell
wsl --install -d Ubuntu-22.04
```

Restart your computer after installation.

### 2. Update WSL Distribution

Once inside your WSL terminal:

```bash
sudo apt update && sudo apt upgrade -y
```

## Required Tools Installation

### 1. Install kubectl

```bash
# Download latest kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Make it executable
chmod +x kubectl

# Move to PATH
sudo mv kubectl /usr/local/bin/

# Verify installation
kubectl version --client
```

### 2. Install Helm

```bash
# Download and install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version
```

### 3. Install jq

```bash
sudo apt install -y jq

# Verify installation
jq --version
```

### 4. Install bc (Calculator)

```bash
sudo apt install -y bc

# Verify installation
bc --version
```

### 5. Install openssl (Usually Pre-installed)

```bash
# Check if installed
openssl version

# If not installed
sudo apt install -y openssl
```

## Kubernetes Cluster Configuration

### Option 1: Remote On-Premise Cluster

If you're connecting to a remote vSphere/vCenter Kubernetes cluster:

1. Copy your kubeconfig file from the cluster or administrator
2. Place it in WSL:

```bash
# Create .kube directory
mkdir -p ~/.kube

# Copy kubeconfig (adjust path as needed)
# If the file is in Windows: C:\Users\YourName\Downloads\kubeconfig
cp /mnt/c/Users/YourName/Downloads/kubeconfig ~/.kube/config

# Set proper permissions
chmod 600 ~/.kube/config
```

3. Test connectivity:

```bash
kubectl cluster-info
kubectl get nodes
```

### Option 2: Local Kubernetes (Docker Desktop with WSL2)

If using Docker Desktop with WSL2 integration:

1. Enable Kubernetes in Docker Desktop settings
2. Enable WSL2 integration
3. The kubeconfig should be automatically configured

## Running the Percona Installation Scripts

### 1. Navigate to the Script Directory

```bash
cd /path/to/percona_operator/percona/on-prem
```

If your repository is in Windows (e.g., `C:\Users\YourName\percona_operator`):

```bash
cd /mnt/c/Users/YourName/percona_operator/percona/on-prem
```

### 2. Verify Script Permissions

```bash
# Scripts should already be executable, but verify:
ls -la *.sh

# If not executable, fix:
chmod +x install.sh uninstall.sh
```

### 3. Run Installation

```bash
./install.sh
```

The script will:
- Check prerequisites
- Prompt for configuration (namespace, storage class, resources)
- Install Percona Operator
- Deploy XtraDB Cluster
- Configure backups and PITR

### 4. Run Uninstallation (When Needed)

```bash
./uninstall.sh
```

## WSL-Specific Considerations

### Line Endings

✅ **Already Handled**: The repository includes a `.gitattributes` file that ensures shell scripts always use LF line endings, even when cloned on Windows.

If you manually create or edit scripts on Windows, ensure they use LF (Unix) line endings:
- In VS Code: Set "End of Line" to LF in the status bar
- In Notepad++: Edit → EOL Conversion → Unix (LF)

### File Permissions

WSL automatically handles Unix file permissions. The scripts are marked as executable (`-rwxr-xr-x`).

### Path Differences

- Windows paths in WSL: `/mnt/c/Users/...`
- WSL native paths: `/home/username/...`
- Use WSL native paths when possible for better performance

### Performance Tips

1. **Store files in WSL filesystem**: Clone the repository directly in WSL (e.g., `~/percona_operator`) rather than accessing Windows filesystem (`/mnt/c/...`) for better I/O performance.

```bash
# Recommended: Clone in WSL
cd ~
git clone <repository-url>
cd percona_operator/percona/on-prem
```

2. **Use WSL2 over WSL1**: WSL2 provides much better performance and full system call compatibility.

### Troubleshooting

#### Issue: "command not found: kubectl"

```bash
# Ensure kubectl is in PATH
echo $PATH | grep -q "/usr/local/bin" || echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
source ~/.bashrc
```

#### Issue: "Cannot connect to Kubernetes cluster"

```bash
# Check kubeconfig
kubectl config view

# Check current context
kubectl config current-context

# List available contexts
kubectl config get-contexts

# Switch context if needed
kubectl config use-context <context-name>
```

#### Issue: "Permission denied" when running script

```bash
# Make script executable
chmod +x install.sh uninstall.sh
```

#### Issue: Script shows "^M" characters or syntax errors

This indicates CRLF line endings. Fix with:

```bash
# Install dos2unix
sudo apt install dos2unix

# Convert line endings
dos2unix install.sh uninstall.sh
```

Or use sed:

```bash
sed -i 's/\r$//' install.sh uninstall.sh
```

## Verifying WSL Compatibility

Run this quick verification:

```bash
# Check shell
echo $SHELL  # Should show /bin/bash or similar

# Check prerequisite tools
kubectl version --client
helm version
jq --version
bc --version
openssl version

# Check cluster connectivity
kubectl cluster-info
kubectl get nodes
```

## Additional Resources

- [WSL Documentation](https://docs.microsoft.com/en-us/windows/wsl/)
- [kubectl Installation](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [Helm Installation](https://helm.sh/docs/intro/install/)
- [Percona Operator Documentation](https://docs.percona.com/percona-operator-for-mysql/pxc/)

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Verify all prerequisites are installed
3. Ensure proper Kubernetes cluster connectivity
4. Check script output for detailed error messages

