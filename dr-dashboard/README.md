# 🚨 Database Emergency Kit

**Your first stop during a database crisis.** Emergency-focused interface for Percona XtraDB Cluster recovery procedures.

## Quick Start

```bash
cd dr-dashboard
./start-dev.sh
# Open http://localhost:8080
```

## Features

- **Crisis-Optimized UI** - Immediate on-call contact info, no distractions
- **Prioritized Scenarios** - Sorted by impact, then likelihood
- **Multi-Environment** - EKS and On-Prem
- **Step-by-Step Runbooks** - Copy-pasteable commands for recovery
- **Single Source of Truth** - Reads from testing framework JSON
- **Fast & Reliable** - <100ms startup, works when you need it most  

## Prerequisites

- Go 1.21+
- Modern browser

## Running

```bash
# Development (fastest)
./start-dev.sh

# Production build
./start.sh

# Custom port
PORT=3000 ./start-dev.sh

# Using Make
make dev
make run
```

## Using During a Disaster

1. Open `http://localhost:8080`
2. Search for your scenario
3. Click ▶️ arrow to expand
4. Follow recovery process step-by-step
5. Use verification steps to confirm recovery

## Architecture

**Single Source of Truth:**
- Disaster scenarios: `../testing/{eks,on-prem}/disaster_scenarios/disaster_scenarios.json`
- Recovery processes: `./recovery_processes/{eks,on-prem}/*.md`
- No duplication with testing framework

**Stack:**
- Backend: Go (standard library only)
- Frontend: Vanilla JS, CSS3, marked.js
- Data: File-based (no database)

## Adding New Scenarios

1. Add to `../testing/{env}/disaster_scenarios/disaster_scenarios.json`
2. Create `recovery_processes/{env}/scenario-name.md`
3. Restart server
4. Verify in browser

## API

- `GET /api/scenarios?env={eks|on-prem}` - List scenarios
- `GET /api/recovery-process?env={env}&file={name}.md` - Get recovery doc
- `GET /static/*` - Static assets


## Customization

**Colors:** Edit `:root` CSS variables in `static/styles.css`  
**Port:** Set `PORT` environment variable  
**Environments:** Add to `environments` array in `main.go`

## Building

```bash
# Quick build
make build

# Cross-platform
GOOS=linux GOARCH=amd64 go build -o dr-dashboard-linux
GOOS=darwin GOARCH=amd64 go build -o dr-dashboard-macos
GOOS=windows GOARCH=amd64 go build -o dr-dashboard.exe
```

## WSL

Build for Linux, run in WSL, access from Windows browser at `http://localhost:8080`

## Security

- ✅ Read-only (cannot modify infrastructure)
- ✅ Path traversal protection
- ⚠️ No authentication (internal use only)
- ⚠️ Do NOT expose to internet without auth

## Troubleshooting

**Port in use:** `PORT=8081 ./start-dev.sh`  
**Scenarios not loading:** Check JSON files exist in `../testing/*/disaster_scenarios/`  
**Recovery process 404:** Verify markdown file exists, check naming (spaces → hyphens)

## Documentation

- `README.md` - This file
- `QUICKSTART.md` - 2-minute guide
- `ARCHITECTURE.md` - Technical details
- `PROJECT_SUMMARY.md` - Complete overview

---

**Bookmark `http://localhost:8080` - your lifeline during a disaster!** 🚨
