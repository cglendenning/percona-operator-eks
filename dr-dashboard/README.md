# Database Emergency Kit

Emergency-focused web interface for Percona XtraDB Cluster disaster recovery procedures. Your first stop during a database crisis.

## Quick Start

```bash
cd dr-dashboard
./start-dev.sh
# Open http://localhost:8080
```

## Features

- Crisis-optimized UI with immediate on-call contact information
- Scenarios prioritized by business impact and likelihood
- Multi-environment support (EKS and On-Prem)
- Step-by-step recovery runbooks with copy-pasteable commands
- Single source of truth architecture (reads from testing framework JSON)
- Fast startup (<100ms) and reliable operation

## Prerequisites

- Go 1.21+ (for local development)
- Docker (for containerized deployment)
- Modern browser (Chrome 90+, Firefox 88+, Safari 14+, Edge 90+)

## Running

### Development Mode
```bash
./start-dev.sh
```

### Production Build
```bash
./start.sh
```

### Custom Port
```bash
PORT=3000 ./start-dev.sh
```

### Using Make
```bash
make dev
make run
```

## Architecture

### Single Source of Truth

The dashboard reads from existing JSON files - no duplication:

- Disaster scenarios: `../testing/{eks,on-prem}/disaster_scenarios/disaster_scenarios.json`
- Recovery processes: `./recovery_processes/{eks,on-prem}/*.md`

Both the testing framework and web dashboard consume the same data sources.

### Stack

- Backend: Go (standard library only, no external dependencies)
- Frontend: Vanilla JavaScript, CSS3, marked.js for markdown rendering
- Data: File-based (no database required)

### Data Flow

1. Server starts and loads JSON scenario files into memory
2. User opens browser to `http://localhost:8080`
3. Browser fetches scenarios via `/api/scenarios?env={eks|on-prem}`
4. User expands scenario to view recovery process
5. Browser fetches markdown via `/api/recovery-process?env={env}&file={name}.md`
6. Markdown rendered client-side using marked.js

## Using During a Disaster

1. Open `http://localhost:8080`
2. Select environment (EKS or On-Prem)
3. Find your scenario (sorted by impact, then likelihood)
4. Click arrow to expand scenario
5. Review Overview tab for quick information
6. Switch to Recovery Process tab for detailed steps
7. Follow recovery steps in order
8. Use verification steps to confirm recovery

## Adding New Scenarios

1. Add scenario to `../testing/{env}/disaster_scenarios/disaster_scenarios.json`
2. Create recovery process markdown: `recovery_processes/{env}/scenario-name.md`
3. Follow existing markdown template structure
4. Restart server
5. Verify in browser

### Markdown Template Structure

```markdown
# Scenario Name Recovery Process

## Scenario
Brief description

## Detection Signals
- Signal 1
- Signal 2

## Primary Recovery Method
Description

### Steps
1. Step one with commands
2. Step two with verification

## Alternate/Fallback Method
Description

## Related Scenarios
- Link to other relevant scenarios
```

## API Endpoints

- `GET /` - Serves index.html
- `GET /api/scenarios?env={eks|on-prem}` - Returns JSON array of scenarios
- `GET /api/recovery-process?env={env}&file={name}.md` - Returns markdown content
- `GET /static/*` - Serves static assets (CSS, JS, images)

## Customization

### On-Call Contact Information

Update in `static/index.html`:
```html
<div class="on-call-info">
    <div class="on-call-label">Emergency On-call Contact</div>
    <div class="on-call-name">Your Name Here</div>
    <div class="on-call-phone">+1 (XXX) XXX-XXXX</div>
</div>
```

### Colors and Styling

Edit CSS variables in `static/styles.css`:
```css
:root {
    --accent-primary: #6366f1;
    --accent-secondary: #8b5cf6;
    --accent-danger: #ef4444;
    --text-primary: #ffffff;
}
```

### Environment Names

Update button labels in `static/index.html`:
```html
<button class="env-btn active" data-env="eks">Production</button>
<button class="env-btn" data-env="on-prem">DR Site</button>
```

### Port Configuration

Set via environment variable:
```bash
PORT=3000 ./start-dev.sh
```

Or update default in `main.go`:
```go
port := os.Getenv("PORT")
if port == "" {
    port = "8080"  // Default port
}
```

## Building

### Quick Build
```bash
make build
```

### Cross-Platform
```bash
GOOS=linux GOARCH=amd64 go build -o dr-dashboard-linux
GOOS=darwin GOARCH=amd64 go build -o dr-dashboard-macos
GOOS=windows GOARCH=amd64 go build -o dr-dashboard.exe
```

## Security

### Current Security Posture

- Read-only operations (cannot modify infrastructure)
- Path traversal protection (validated filenames only)
- No SQL injection risk (no database)
- Stateless design (no session management)
- No authentication (designed for internal use only)

### Recommendations for Production

- Add authentication if exposing beyond localhost
- Use HTTPS with TLS certificates
- Implement rate limiting to prevent DoS
- Add audit logging for access tracking
- Run as non-root user
- Use environment variables for sensitive configuration

## Performance

- Startup time: < 100ms
- Scenario API response: < 1ms (served from memory)
- Recovery process response: < 5ms (file read)
- Memory usage: ~10-20 MB
- Concurrent users: Thousands (stateless design)

## Troubleshooting

### Port Already in Use
```bash
PORT=8081 ./start-dev.sh
```

### Scenarios Not Loading
Verify JSON files exist:
```bash
ls ../testing/eks/disaster_scenarios/disaster_scenarios.json
ls ../testing/on-prem/disaster_scenarios/disaster_scenarios.json
```

### Recovery Process 404
- Verify markdown file exists in `recovery_processes/{env}/`
- Check filename matches scenario name (spaces converted to hyphens)
- Ensure file has `.md` extension

### Go Not Found
Install Go from: https://go.dev/dl/

## WSL Support

Build for Linux, run in WSL, access from Windows browser at `http://localhost:8080`

## Project Structure

```
dr-dashboard/
├── k8s/                       # Kubernetes manifests
│   ├── deployment-on-prem.yaml
│   └── deployment-eks.yaml
├── on-prem/                   # On-premises environment
│   ├── Dockerfile
│   ├── main.go
│   ├── go.mod
│   ├── build.sh
│   ├── start.sh
│   ├── static/
│   ├── build/                 # Nix flake for manifest generation
│   │   ├── flake.nix
│   │   ├── render.sh
│   │   └── Makefile
│   └── nix/                   # Nix modules
│       └── modules/
│           └── dr-dashboard/
├── eks/                       # EKS environment
│   ├── Dockerfile
│   ├── main.go
│   ├── go.mod
│   ├── build.sh
│   ├── start.sh
│   └── static/
├── recovery_processes/        # Recovery documentation
│   ├── on-prem/
│   └── eks/
├── start-dev.sh              # Development startup
├── start.sh                  # Production startup
└── Makefile                  # Build tasks
```

## Integration with Testing Framework

The dashboard integrates with the testing framework through shared data sources:

- Testing framework reads `disaster_scenarios.json` for test execution
- Dashboard reads same JSON files for display
- Both reference recovery process markdown files
- No duplication ensures consistency

## Deployment Options

### Local Development
```bash
./start-dev.sh
```

### Docker Container

Build images:
```bash
# Build on-prem image
cd on-prem && ./build.sh

# Build eks image
cd eks && ./build.sh

# Build with specific tag
./build.sh v1.0.0

# Build with custom registry
REGISTRY=myregistry.example.com ./build.sh v1.0.0
```

Run locally:
```bash
# On-prem environment
docker run -p 8080:8080 dr-dashboard-on-prem:latest

# EKS environment
docker run -p 8080:8080 dr-dashboard-eks:latest
```

The build scripts work on both macOS and WSL/Linux. They require Docker to be installed and running.

### Kubernetes Deployment

Pre-built manifests are available in `k8s/`:

```bash
# Deploy on-prem dashboard
kubectl apply -f k8s/deployment-on-prem.yaml

# Deploy EKS dashboard
kubectl apply -f k8s/deployment-eks.yaml
```

### Nix-Based Deployment (On-Prem)

For declarative, reproducible manifest generation using Nix:

```bash
cd on-prem/build

# Generate manifests with default settings
nix build

# Or use the render script with options
./render.sh --registry ghcr.io/myorg --tag v1.0.0 --namespace dr-dashboard

# Deploy
kubectl apply -f manifests.yaml
```

The Nix module supports:
- Custom registry and image tag
- Namespace configuration
- Service type (ClusterIP, NodePort, LoadBalancer)
- Resource limits
- Image pull secrets

See `on-prem/build/` for the flake and `on-prem/nix/modules/dr-dashboard/` for the module source.

Custom deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dr-dashboard
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: dr-dashboard
        image: dr-dashboard:on-prem-latest
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        - name: DATA_DIR
          value: "/app/data"
        - name: STATIC_DIR
          value: "/app/static"
```

### Environment Variables

| Variable    | Description                           | Default      |
|-------------|---------------------------------------|--------------|
| PORT        | HTTP server port                      | 8080         |
| DATA_DIR    | Path to scenarios and recovery docs   | (local mode) |
| STATIC_DIR  | Path to static assets                 | ./static     |

When `DATA_DIR` is set, the app runs in container mode and expects:
- `$DATA_DIR/scenarios/disaster_scenarios.json`
- `$DATA_DIR/recovery_processes/*.md`

### Systemd Service (Linux)
```ini
[Unit]
Description=DR Dashboard
After=network.target

[Service]
Type=simple
User=dr-dashboard
WorkingDirectory=/opt/dr-dashboard
ExecStart=/opt/dr-dashboard/dr-dashboard
Restart=always

[Install]
WantedBy=multi-user.target
```

## Browser Compatibility

- Chrome 90+
- Firefox 88+
- Safari 14+
- Edge 90+

Required features: ES6 JavaScript, CSS Grid, Fetch API, CSS Custom Properties, Backdrop Filter

---

**Bookmark `http://localhost:8080` - your lifeline during a disaster!**
