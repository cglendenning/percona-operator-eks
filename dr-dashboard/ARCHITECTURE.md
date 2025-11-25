# 🏗️ DR Dashboard Architecture

## Overview

The Disaster Recovery Dashboard is a **read-only web interface** built with Go that provides instant access to disaster recovery procedures during critical incidents. It follows a **single source of truth** design pattern to eliminate duplication between the testing framework and the operational dashboard.

## Design Principles

### 1. Single Source of Truth
- **Disaster scenarios** are defined once in JSON files
- **Recovery processes** are written once in Markdown files
- Both the **testing framework** and the **web dashboard** consume the same data
- No duplication = no sync issues

### 2. Environment-Aware
- Supports multiple deployment environments (EKS, On-Prem)
- Each environment has its own scenarios and recovery processes
- Easy to switch between environments in the UI

### 3. Fast & Lightweight
- Static file server (no database required)
- Loads JSON at startup for instant access
- Markdown rendered client-side for speed
- Works offline once loaded

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Browser (Client)                        │
│  ┌────────────┐  ┌─────────────┐  ┌──────────────────────┐    │
│  │  HTML/CSS  │  │ JavaScript  │  │  marked.js           │    │
│  │  (Web 3.0) │  │  (app.js)   │  │  (MD Renderer)       │    │
│  └────────────┘  └─────────────┘  └──────────────────────┘    │
└───────────────────────────┬─────────────────────────────────────┘
                            │ HTTP
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                    Go HTTP Server (main.go)                     │
│                                                                  │
│  API Endpoints:                                                 │
│  • GET /                    → index.html                       │
│  • GET /api/scenarios       → JSON scenarios                   │
│  • GET /api/recovery-process → Markdown files                  │
│  • GET /static/*            → CSS, JS, etc.                    │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            │ Reads from
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                    File System (Data Layer)                     │
│                                                                  │
│  Source of Truth:                                               │
│  ┌──────────────────────────────────────────────────────┐      │
│  │ ../testing/eks/disaster_scenarios/                   │      │
│  │   └── disaster_scenarios.json                        │      │
│  │                                                       │      │
│  │ ../testing/on-prem/disaster_scenarios/               │      │
│  │   └── disaster_scenarios.json                        │      │
│  └──────────────────────────────────────────────────────┘      │
│                                                                  │
│  Recovery Docs:                                                 │
│  ┌──────────────────────────────────────────────────────┐      │
│  │ ./recovery_processes/eks/                            │      │
│  │   ├── single-mysql-pod-failure.md                    │      │
│  │   ├── kubernetes-worker-node-failure.md              │      │
│  │   └── ...                                            │      │
│  │                                                       │      │
│  │ ./recovery_processes/on-prem/                        │      │
│  │   └── (same files)                                   │      │
│  └──────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────┘
```

## Data Flow

### Startup
1. Go server starts
2. Reads JSON files from `../testing/{eks,on-prem}/disaster_scenarios/`
3. Loads scenarios into memory
4. Maps each scenario to its recovery process markdown file
5. Starts HTTP server on port 8080 (default)

### User Interaction
1. User opens browser to `http://localhost:8080`
2. Server serves `static/index.html`
3. Browser loads CSS (`styles.css`) and JavaScript (`app.js`)
4. JavaScript calls `/api/scenarios?env=eks`
5. Server returns JSON with all scenarios
6. Browser renders scenario cards
7. User clicks arrow to expand a scenario
8. JavaScript calls `/api/recovery-process?env=eks&file=<filename>`
9. Server reads markdown file and returns content
10. Browser uses `marked.js` to render markdown as HTML

## Component Responsibilities

### Go Server (`main.go`)
**Responsibilities:**
- Serve static files (HTML, CSS, JS)
- Load and cache scenario JSON files
- Provide API endpoints for scenarios and recovery processes
- Map scenario names to markdown filenames
- Security: Prevent directory traversal attacks

**Does NOT:**
- Modify any files
- Store state (stateless)
- Connect to databases
- Require authentication (designed for internal use)

### Frontend (`static/index.html`, `styles.css`, `app.js`)
**Responsibilities:**
- Display beautiful Web 3.0 interface
- Fetch scenarios from API
- Render markdown using marked.js
- Handle expand/collapse interactions
- Search and filter scenarios
- Switch between environments
- Calculate and display statistics

**Does NOT:**
- Access file system directly
- Store data locally (could be enhanced with localStorage)
- Modify server state

### Data Files

#### JSON Scenarios (`../testing/*/disaster_scenarios/disaster_scenarios.json`)
**Purpose:**
- Single source of truth for disaster scenarios
- Used by BOTH testing framework AND web dashboard
- Contains all metadata (RTO, RPO, MTTR, likelihood, impact, etc.)

**Structure:**
```json
[
  {
    "scenario": "Single MySQL pod failure",
    "primary_recovery_method": "...",
    "alternate_fallback": "...",
    "detection_signals": "...",
    "rto_target": "5-10 minutes",
    "rpo_target": "0 (no data loss)",
    "mttr_expected": "10-20 minutes",
    "expected_data_loss": "None",
    "likelihood": "Medium",
    "business_impact": "Low",
    "affected_components": "...",
    "notes_assumptions": "...",
    "test_enabled": true,
    "test_file": "test_dr_single_mysql_pod_failure.py"
  }
]
```

#### Markdown Recovery Processes (`./recovery_processes/*/`)
**Purpose:**
- Detailed step-by-step recovery procedures
- Human-readable during incidents
- Version-controlled documentation
- Can be referenced by testing framework for validation

**Structure:**
```markdown
# Scenario Name Recovery Process

## Scenario
Description

## Detection Signals
- Signal 1
- Signal 2

## Primary Recovery Method
Description

### Steps
1. Step one with commands
2. Step two with verification

## Alternate/Fallback Method
...

## Related Scenarios
- Link to other relevant scenarios
```

## Extending the System

### Adding a New Disaster Scenario

1. **Update JSON file** (`../testing/{env}/disaster_scenarios/disaster_scenarios.json`)
   ```json
   {
     "scenario": "New disaster scenario",
     "primary_recovery_method": "...",
     "test_enabled": false,
     ...
   }
   ```

2. **Create recovery process markdown** (`./recovery_processes/{env}/new-disaster-scenario.md`)
   - Use existing files as templates
   - Follow the standard structure
   - Include verification steps

3. **Restart the server**
   ```bash
   ./start-dev.sh
   ```

4. **Verify in browser**
   - Search for the new scenario
   - Expand and check recovery process loads

### Adding a New Environment

1. **Create directory structure**
   ```bash
   mkdir -p ../testing/staging/disaster_scenarios
   mkdir -p recovery_processes/staging
   ```

2. **Add JSON file**
   ```bash
   cp ../testing/eks/disaster_scenarios/disaster_scenarios.json \
      ../testing/staging/disaster_scenarios/
   ```

3. **Update `main.go`**
   ```go
   environments := []string{"eks", "on-prem", "staging"}
   ```

4. **Update UI** (`static/index.html`)
   ```html
   <button class="env-btn" data-env="staging">
     <span class="env-icon">🧪</span>
     Staging
   </button>
   ```

### Customizing the UI

**Colors** - Edit `:root` in `static/styles.css`:
```css
:root {
    --accent-primary: #6366f1;  /* Change to your brand color */
    --accent-secondary: #8b5cf6;
}
```

**Layout** - Modify grid in `static/styles.css`:
```css
.stats-grid {
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
}
```

**Features** - Add functionality in `static/app.js`:
```javascript
// Example: Add export functionality
function exportScenarios() {
    const json = JSON.stringify(allScenarios, null, 2);
    // ... download logic
}
```

## Integration with Testing Framework

### Current Integration
- Testing framework reads `disaster_scenarios.json`
- Executes tests based on `test_enabled` flag
- References `test_file` for test implementation
- Uses scenario metadata (MTTR, chaos_type, etc.)

### Future Integration Possibilities
1. **Test Results in Dashboard**
   - Display last test run date
   - Show pass/fail status
   - Link to test reports

2. **Recovery Process Validation**
   - Tests verify recovery processes work
   - Automated runbook verification
   - Link test results to specific recovery steps

3. **Real-time Monitoring**
   - Connect to Prometheus/Grafana
   - Show live cluster health
   - Trigger alerts when scenarios detected

## Security Considerations

### Current Security Posture
✅ Read-only (cannot modify infrastructure)  
✅ Path traversal protection (validated filenames)  
✅ No SQL injection (no database)  
✅ Stateless (no session management)  
⚠️ No authentication (designed for internal use)  
⚠️ Contains sensitive infrastructure info  

### Recommendations for Production
1. **Add authentication** if exposing beyond localhost
2. **Use HTTPS** with TLS certificates
3. **Implement rate limiting** to prevent DoS
4. **Add audit logging** for access tracking
5. **Run as non-root user** in production
6. **Use environment variables** for sensitive config

## Performance Characteristics

### Startup Time
- < 100ms (loads JSON files into memory)

### Response Time
- Scenarios API: < 1ms (returns from memory)
- Recovery process: < 5ms (reads markdown file)
- Static files: < 1ms (direct file serve)

### Memory Usage
- ~10-20 MB (Go runtime + cached JSON)
- Scales with number of scenarios (negligible)

### Scalability
- Single instance handles thousands of requests/sec
- Stateless design allows horizontal scaling
- Can add CDN for static files
- No database bottleneck

## Browser Compatibility

### Supported Browsers
✅ Chrome 90+  
✅ Firefox 88+  
✅ Safari 14+  
✅ Edge 90+  

### Required Features
- ES6 JavaScript
- CSS Grid
- Fetch API
- CSS Custom Properties
- Backdrop Filter (for glassmorphism)

## Deployment Options

### Local Development
```bash
./start-dev.sh
```

### Docker Container
```dockerfile
FROM golang:1.21-alpine
WORKDIR /app
COPY . .
RUN go build -o dr-dashboard main.go
CMD ["./dr-dashboard"]
EXPOSE 8080
```

### Kubernetes Deployment
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
        image: dr-dashboard:latest
        ports:
        - containerPort: 8080
```

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

## Monitoring & Observability

### Metrics to Track
- Request count by endpoint
- Response time percentiles
- Error rate
- Concurrent users
- Scenario view count (popular scenarios)

### Log Format
```
2024-01-15 14:30:00 INFO Server starting on port 8080
2024-01-15 14:30:01 INFO Loaded 16 scenarios for eks
2024-01-15 14:30:01 INFO Loaded 16 scenarios for on-prem
2024-01-15 14:32:15 INFO GET /api/scenarios?env=eks 200 1ms
2024-01-15 14:32:20 INFO GET /api/recovery-process?env=eks&file=... 200 3ms
```

## Future Enhancements

### Planned Features
- [ ] Dark/Light mode toggle
- [ ] Export scenarios to PDF
- [ ] Offline mode (Service Worker)
- [ ] Test result integration
- [ ] Real-time cluster status
- [ ] Incident timeline tracking
- [ ] Collaboration features (comments, notes)
- [ ] Mobile app (React Native)

### Nice to Have
- [ ] AI-powered scenario suggestions
- [ ] Automated runbook execution
- [ ] Integration with PagerDuty/OpsGenie
- [ ] Historical incident tracking
- [ ] Recovery time analytics
- [ ] Scenario dependency graph

---

**Remember**: This dashboard is a critical operational tool. Keep it simple, fast, and reliable. During a disaster, every second counts! 🚨
