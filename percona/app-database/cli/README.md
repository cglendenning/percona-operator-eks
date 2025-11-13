# bootstrap-mysql-schema CLI

A developer-friendly command-line tool for creating MySQL databases and users through the DB Concierge operator.

## Installation

### Option 1: Direct Usage (Requires Python 3.7+)

```bash
# Install dependencies
pip install -r requirements.txt

# Make executable
chmod +x bootstrap-mysql-schema

# Optionally, add to your PATH
sudo cp bootstrap-mysql-schema /usr/local/bin/
```

### Option 2: Create Standalone Executable (PyInstaller)

```bash
pip install pyinstaller pyyaml
pyinstaller --onefile bootstrap-mysql-schema
# Binary will be in dist/bootstrap-mysql-schema
```

## Usage

### Basic Usage

Create a database and user for your application:

```bash
bootstrap-mysql-schema --name myapp --namespace myapp-namespace
```

### Specify PXC Cluster

```bash
bootstrap-mysql-schema --name myapp --namespace myapp --cluster my-pxc-haproxy
```

### Output as Environment Variables

Perfect for local development:

```bash
bootstrap-mysql-schema --name myapp --namespace myapp --output-env > .env
source .env
```

### Custom Secret Name

```bash
bootstrap-mysql-schema --name myapp --namespace myapp --secret-name custom-db-creds
```

### Deletion Policy

By default, databases are retained when the AppDatabase resource is deleted (`Retain`). You can change this:

```bash
# WARNING: Database will be dropped when AppDatabase is deleted
bootstrap-mysql-schema --name myapp --namespace myapp --deletion-policy Delete
```

## Examples

### Example 1: Wookie Application

```bash
$ bootstrap-mysql-schema --name wookie --namespace wookie

DB Concierge - Bootstrap MySQL Schema
Creating database: wookie
Target namespace: wookie
PXC cluster:      cluster1-haproxy

appdatabase.db.stillwaters.io/wookie created

Waiting for database provisioning...
✓ Database provisioned successfully!

Database Created Successfully!

Database Information:
  Database Name: wookie
  Username:      wookie_app
  Host:          cluster1-haproxy.default.svc.cluster.local
  Port:          3306

Kubernetes Secret:
  Name:      wookie-mysql-creds
  Namespace: wookie

Connect to MySQL:
  mysql -h cluster1-haproxy.default.svc.cluster.local \
        -P 3306 \
        -u wookie_app \
        -p************ \
        wookie
```

### Example 2: Local Development with Environment Variables

```bash
$ bootstrap-mysql-schema --name devdb --namespace dev --output-env

DB Concierge - Bootstrap MySQL Schema
...

Environment Variables:
export MYSQL_HOST=cluster1-haproxy.default.svc.cluster.local
export MYSQL_PORT=3306
export MYSQL_USER=devdb_app
export MYSQL_PASSWORD=************
export MYSQL_DATABASE=devdb
export MYSQL_URL=mysql://devdb_app:************@cluster1-haproxy.default.svc.cluster.local:3306/devdb
```

### Example 3: Non-interactive Mode

```bash
# Just create the resource and exit (don't wait)
bootstrap-mysql-schema --name myapp --namespace myapp --no-wait

# Check status later
kubectl get appdatabase myapp -n db-concierge
```

## Troubleshooting

### "kubectl not found"

Make sure `kubectl` is installed and in your PATH:

```bash
which kubectl
kubectl version
```

### "appdatabase.db.stillwaters.io not found"

The DB Concierge operator isn't installed. Install it first:

```bash
cd ../
./install.sh
```

### "Failed to provision database"

Check operator logs:

```bash
kubectl logs -n db-concierge -l app.kubernetes.io/name=db-concierge-operator
```

### "Could not retrieve secret"

The database was created but the secret might be in a different namespace or have a different name. Check manually:

```bash
kubectl get secrets -n your-namespace
kubectl describe appdatabase your-db-name -n db-concierge
```

## Integration with CI/CD

### GitOps (ArgoCD/Flux)

Instead of using the CLI, you can commit AppDatabase resources directly to your Git repository:

```yaml
# apps/myapp/database.yaml
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: myapp
  namespace: db-concierge
spec:
  clusterRef: cluster1-haproxy
  dbName: myapp
  appNamespace: myapp
  deletionPolicy: Retain
```

### Helm Chart Integration

Add to your Helm chart:

```yaml
# templates/appdatabase.yaml
{{- if .Values.database.create }}
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: {{ .Values.database.name | default .Release.Name }}
  namespace: db-concierge
spec:
  clusterRef: {{ .Values.database.clusterRef }}
  dbName: {{ .Values.database.name | default .Release.Name }}
  appNamespace: {{ .Release.Namespace }}
  deletionPolicy: {{ .Values.database.deletionPolicy | default "Retain" }}
{{- end }}
```

Then in your app deployment, reference the secret created by the operator.

## Security Considerations

1. **Secret Access**: Developers only get access to secrets in their own namespaces
2. **No Root Access**: Developers never see or need MySQL root credentials
3. **Scoped Permissions**: Each app user only has access to their own database
4. **Audit Trail**: All database creations are Kubernetes resources with full audit logs

## Advanced Usage

### Using with Port Forwarding (Local Development)

```bash
# Port forward to your PXC cluster
kubectl port-forward svc/cluster1-haproxy 3306:3306 &

# Update the secret to point to localhost
kubectl get secret myapp-mysql-creds -n myapp -o yaml | \
  sed 's/cluster1-haproxy.*/localhost/' | \
  kubectl apply -f -

# Now connect locally
mysql -h localhost -P 3306 -u myapp_app -p myapp
```

### Cleanup

To remove a database (if deletion policy is Delete):

```bash
kubectl delete appdatabase myapp -n db-concierge
```

To just remove the secret but keep the database:

```bash
kubectl delete secret myapp-mysql-creds -n myapp
```

## Support

For issues or questions:
1. Check operator logs: `kubectl logs -n db-concierge -l app.kubernetes.io/name=db-concierge-operator`
2. Check AppDatabase status: `kubectl describe appdatabase <name> -n db-concierge`
3. Review the main README.md for architecture and setup details

