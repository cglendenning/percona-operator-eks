# Customization Guide

## On-Call Contact Information

Update the emergency on-call contact in `static/index.html`:

```html
<div class="on-call-info">
    <div class="on-call-label">Emergency On-call Contact</div>
    <div class="on-call-name">Your Name Here</div>
    <div class="on-call-phone">+1 (XXX) XXX-XXXX</div>
</div>
```

### Dynamic On-Call Rotation

To pull from a rotation schedule:

1. Create an API endpoint in `main.go`:

```go
func handleOnCall(w http.ResponseWriter, r *http.Request) {
    // Read from PagerDuty, OpsGenie, or your rotation system
    oncall := OnCallInfo{
        Name: "Sarah Mitchell",
        Phone: "+1 (555) 123-4567",
    }
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(oncall)
}
```

2. Update `static/app.js` to fetch on load:

```javascript
async function loadOnCall() {
    const response = await fetch('/api/oncall');
    const oncall = await response.json();
    document.querySelector('.on-call-name').textContent = oncall.name;
    document.querySelector('.on-call-phone').textContent = oncall.phone;
}
```

## Scenario Sorting

Current order: Impact (Critical → High → Medium → Low), then Likelihood (High → Medium → Low)

To change sorting in `static/app.js`:

```javascript
function sortScenarios(scenarios) {
    // Example: Sort by RTO instead
    return scenarios.sort((a, b) => {
        // Your custom sorting logic
    });
}
```

## Colors and Styling

Edit `static/styles.css`:

```css
:root {
    --accent-danger: #ef4444;  /* On-call box border/text */
    --accent-primary: #6366f1; /* Environment buttons */
    --text-primary: #ffffff;   /* Main text */
}
```

### On-Call Box Styling

The on-call contact is now styled without a background box. To add colored styling:

```css
.on-call-info {
    background: rgba(99, 102, 241, 0.15);  /* Blue tint */
    border: 2px solid var(--accent-primary);
    border-radius: 12px;
}
```

## Environment Names

Update `static/index.html`:

```html
<button class="env-btn active" data-env="eks">
    Production  <!-- Changed from EKS -->
</button>
<button class="env-btn" data-env="on-prem">
    DR Site     <!-- Changed from On-Prem -->
</button>
```

## Page Title

Update `static/index.html`:

```html
<title>Your Company - Database Emergency Kit</title>
```

And in the header:

```html
<h1 class="title">
    <span>Your Company Emergency Kit</span>
</h1>
```

## Multiple On-Call Contacts

Add additional contacts in `static/index.html`:

```html
<div class="on-call-info">
    <div class="on-call-label">Emergency On-call Contact</div>
    <div class="on-call-name">Craig Glendenning</div>
    <div class="on-call-phone">+1 (555) 123-4567</div>
    
    <div style="margin-top: 1rem; padding-top: 1rem; border-top: 1px solid rgba(255,255,255,0.2);">
        <div style="font-size: 0.75rem; color: var(--text-secondary);">BACKUP</div>
        <div style="font-weight: 600;">John Smith</div>
        <div>+1 (555) 987-6543</div>
    </div>
</div>
```

## Port Configuration

Set via environment variable:

```bash
PORT=3000 ./start-dev.sh
```

Or update `main.go`:

```go
port := os.Getenv("PORT")
if port == "" {
    port = "3000"  // Changed from 8080
}
```

## Removing Environment Switcher

If you only have one environment, hide it in `static/styles.css`:

```css
.environment-switcher {
    display: none;
}
```

## Custom Logo

Replace the emoji icon in `static/index.html`:

```html
<h1 class="title">
    <img src="/static/logo.png" alt="Logo" style="height: 3rem;" />
    <span>Database Emergency Kit</span>
</h1>
```

Add `logo.png` to the `static/` directory.

## Emergency Banner

Add an emergency banner in `static/index.html` after the header:

```html
<div style="background: var(--accent-danger); padding: 1rem; text-align: center; margin-bottom: 2rem; border-radius: 12px; font-weight: 700;">
    PRODUCTION INCIDENT IN PROGRESS - All hands on deck!
</div>
```

---

**Remember:** Keep it simple and focused for users in crisis!
