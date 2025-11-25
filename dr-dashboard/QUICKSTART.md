# 🚀 Quick Start Guide

Get the Database Emergency Kit running in under 2 minutes!

## Prerequisites

- Go 1.21+ installed
- macOS, Linux, or WSL

## 1️⃣ Navigate to the Dashboard

```bash
cd dr-dashboard
```

## 2️⃣ Start the Server

### Option A: Development Mode (Recommended for first run)
```bash
./start-dev.sh
```

### Option B: Production Build
```bash
./start.sh
```

### Option C: Custom Port
```bash
PORT=3000 ./start-dev.sh
```

## 3️⃣ Open Your Browser

Navigate to:
```
http://localhost:8080
```

## 🎯 What You'll See

1. **🚨 Header** - Database Emergency Kit title with ON-CALL DBA contact info
2. **🌐 Environment Switcher** - Toggle between EKS and On-Prem
3. **📋 Emergency Scenarios** - Sorted by impact/likelihood, expand for recovery steps

## 💡 How to Use During an Emergency

### 1. Contact On-Call DBA
Call the number shown prominently at the top if you need immediate help

### 2. Find Your Scenario
Scenarios are sorted by severity (impact first, likelihood second)
Most critical scenarios appear at the top

### 3. Expand for Recovery Steps
1. Click the **▶️ arrow** on the left of the matching scenario
2. Review the **Overview** tab for quick info
3. Switch to **Recovery Process** tab for detailed commands
4. Follow steps in order

### 4. Switch Environments
- Click **☁️ EKS** for AWS/EKS scenarios
- Click **🏢 On-Prem** for on-premises scenarios

## 🔧 Troubleshooting

### "Port already in use"
```bash
# Use a different port
PORT=8081 ./start-dev.sh
```

### "Go not found"
Install Go from: https://go.dev/dl/

### "Scenarios not loading"
Verify the JSON files exist:
```bash
ls ../testing/eks/disaster_scenarios/disaster_scenarios.json
ls ../testing/on-prem/disaster_scenarios/disaster_scenarios.json
```

## 📱 Bookmark It!

Save this URL for quick access during emergencies:
```
http://localhost:8080
```

## 🆘 During a Disaster

1. Open the dashboard
2. Search for your scenario
3. Expand the scenario
4. Follow the recovery process step-by-step
5. Use verification steps to confirm recovery

## 📚 Full Documentation

See [README.md](README.md) for complete documentation including:
- API endpoints
- Customization options
- Security considerations
- Adding new scenarios
- Cross-platform builds

---

**Ready to go? Run `./start-dev.sh` and open http://localhost:8080!** 🚀
