// State management
const state = {
    sourceNamespace: '',
    backups: [],
    selectedBackup: null,
    earliestTime: '',
    latestTime: '',
    restoreTime: '',
    targetNamespace: '',
    targetNamespaceValid: false,
    clusterName: '',
    restoreName: ''
};

// API base URL
const API_BASE = '';

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    setupEventListeners();
});

function setupEventListeners() {
    // Step 1: Load backups
    document.getElementById('load-backups-btn').addEventListener('click', loadBackups);
    document.getElementById('source-namespace').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') loadBackups();
    });

    // Step 3: Restore time input
    document.getElementById('restore-time').addEventListener('input', validateRestoreTime);

    // Step 4: Check namespace
    document.getElementById('check-namespace-btn').addEventListener('click', checkNamespace);
    document.getElementById('target-namespace').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') checkNamespace();
    });
    document.getElementById('create-namespace-btn').addEventListener('click', createNamespace);

    // Step 5: Start restore
    document.getElementById('start-restore-btn').addEventListener('click', startRestore);
}

// Step 1: Load backups from source namespace
async function loadBackups() {
    const namespace = document.getElementById('source-namespace').value.trim();
    if (!namespace) {
        showError('source-error', 'Please enter a namespace');
        return;
    }

    state.sourceNamespace = namespace;
    hideError('source-error');
    
    const btn = document.getElementById('load-backups-btn');
    btn.disabled = true;
    btn.textContent = 'Loading...';

    try {
        const response = await fetch(`${API_BASE}/api/backups?namespace=${encodeURIComponent(namespace)}`);
        const data = await response.json();

        if (!data.backups || data.backups.length === 0) {
            showError('source-error', data.message || 'No backups found in this namespace');
            btn.disabled = false;
            btn.textContent = 'Load Backups';
            return;
        }

        state.backups = data.backups;
        state.clusterName = data.clusterName;
        state.earliestTime = data.earliestRestorableTime;
        state.latestTime = data.latestRestorableTime;

        showStep(2);
        renderBackups(data);

    } catch (error) {
        showError('source-error', `Failed to load backups: ${error.message}`);
    } finally {
        btn.disabled = false;
        btn.textContent = 'Load Backups';
    }
}

function renderBackups(data) {
    // Show cluster info
    document.getElementById('cluster-info').innerHTML = `
        <div class="info-row">
            <span class="info-label">Cluster:</span>
            <span class="info-value">${data.clusterName}</span>
        </div>
        <div class="info-row">
            <span class="info-label">Namespace:</span>
            <span class="info-value">${data.namespace}</span>
        </div>
    `;

    // Render backup list
    const backupsList = document.getElementById('backups-list');
    backupsList.innerHTML = data.backups.map((backup, index) => `
        <div class="backup-card ${index === 0 ? 'recommended' : ''}" data-backup="${backup.name}">
            <div class="backup-header">
                <span class="backup-name">${backup.name}</span>
                ${index === 0 ? '<span class="badge badge-recommended">Latest</span>' : ''}
                ${backup.pitrReady ? '<span class="badge badge-pitr">PITR Ready</span>' : ''}
            </div>
            <div class="backup-details">
                <div class="backup-detail">
                    <span class="detail-label">State:</span>
                    <span class="detail-value state-${backup.state.toLowerCase()}">${backup.state}</span>
                </div>
                <div class="backup-detail">
                    <span class="detail-label">Completed:</span>
                    <span class="detail-value">${formatTime(backup.completed)}</span>
                </div>
                <div class="backup-detail">
                    <span class="detail-label">Latest Restorable:</span>
                    <span class="detail-value">${formatTime(backup.latestRestorableTime)}</span>
                </div>
                <div class="backup-detail">
                    <span class="detail-label">Storage:</span>
                    <span class="detail-value">${backup.storage}</span>
                </div>
            </div>
            <button class="btn btn-select-backup" onclick="selectBackup('${backup.name}')">Select This Backup</button>
        </div>
    `).join('');
}

function selectBackup(backupName) {
    state.selectedBackup = state.backups.find(b => b.name === backupName);
    
    // Highlight selected
    document.querySelectorAll('.backup-card').forEach(card => {
        card.classList.remove('selected');
        if (card.dataset.backup === backupName) {
            card.classList.add('selected');
        }
    });

    // Show step 3 with time range
    showStep(3);
    
    const timeRangeInfo = document.getElementById('time-range-info');
    const earliest = formatTime(state.selectedBackup.completed);
    const latest = formatTime(state.selectedBackup.latestRestorableTime || state.latestTime);
    
    timeRangeInfo.innerHTML = `
        <div class="time-range-box">
            <div class="time-point">
                <span class="time-label">Earliest (Backup Completed)</span>
                <span class="time-value">${earliest}</span>
            </div>
            <div class="time-arrow">to</div>
            <div class="time-point">
                <span class="time-label">Latest Restorable</span>
                <span class="time-value">${latest}</span>
            </div>
        </div>
        <p class="time-hint">Choose any time within this range. The restore will replay binary logs up to your chosen time.</p>
    `;

    // Pre-fill with latest time
    if (state.selectedBackup.latestRestorableTime) {
        document.getElementById('restore-time').value = formatTimeForInput(state.selectedBackup.latestRestorableTime);
    }
}

function validateRestoreTime() {
    const input = document.getElementById('restore-time').value.trim();
    const timeRegex = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;
    
    if (!input) {
        hideError('time-error');
        hideStep(4);
        return;
    }

    if (!timeRegex.test(input)) {
        showError('time-error', 'Invalid format. Use: YYYY-MM-DD HH:MM:SS');
        hideStep(4);
        return;
    }

    // Basic date validation
    const parts = input.split(' ');
    const dateParts = parts[0].split('-');
    const timeParts = parts[1].split(':');
    
    const year = parseInt(dateParts[0]);
    const month = parseInt(dateParts[1]);
    const day = parseInt(dateParts[2]);
    const hour = parseInt(timeParts[0]);
    const minute = parseInt(timeParts[1]);
    const second = parseInt(timeParts[2]);

    if (month < 1 || month > 12 || day < 1 || day > 31 || 
        hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
        showError('time-error', 'Invalid date/time values');
        hideStep(4);
        return;
    }

    hideError('time-error');
    state.restoreTime = input;
    showStep(4);
}

async function checkNamespace() {
    const namespace = document.getElementById('target-namespace').value.trim();
    if (!namespace) {
        document.getElementById('namespace-status').classList.add('hidden');
        document.getElementById('create-namespace-prompt').classList.add('hidden');
        return;
    }

    if (namespace === state.sourceNamespace) {
        const statusDiv = document.getElementById('namespace-status');
        statusDiv.innerHTML = '<span class="status-error">Cannot restore to source namespace</span>';
        statusDiv.classList.remove('hidden');
        document.getElementById('create-namespace-prompt').classList.add('hidden');
        state.targetNamespaceValid = false;
        hideStep(5);
        return;
    }

    state.targetNamespace = namespace;

    try {
        const response = await fetch(`${API_BASE}/api/namespace/check?namespace=${encodeURIComponent(namespace)}`);
        const data = await response.json();

        const statusDiv = document.getElementById('namespace-status');
        const createPrompt = document.getElementById('create-namespace-prompt');

        if (data.exists) {
            if (data.hasPxc) {
                statusDiv.innerHTML = `<span class="status-warning">${data.message}</span>`;
                state.targetNamespaceValid = true; // Allow but warn
            } else {
                statusDiv.innerHTML = '<span class="status-success">Namespace exists and is ready</span>';
                state.targetNamespaceValid = true;
            }
            statusDiv.classList.remove('hidden');
            createPrompt.classList.add('hidden');
            showStep(5);
            updateRestoreSummary();
        } else {
            statusDiv.innerHTML = '<span class="status-info">Namespace does not exist</span>';
            statusDiv.classList.remove('hidden');
            createPrompt.classList.remove('hidden');
            state.targetNamespaceValid = false;
            hideStep(5);
        }

    } catch (error) {
        const statusDiv = document.getElementById('namespace-status');
        statusDiv.innerHTML = `<span class="status-error">Error checking namespace: ${error.message}</span>`;
        statusDiv.classList.remove('hidden');
        state.targetNamespaceValid = false;
    }
}

async function createNamespace() {
    const namespace = state.targetNamespace;
    const btn = document.getElementById('create-namespace-btn');
    
    btn.disabled = true;
    btn.textContent = 'Creating...';

    try {
        const response = await fetch(`${API_BASE}/api/namespace/create`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ namespace })
        });

        const data = await response.json();

        if (data.success) {
            const statusDiv = document.getElementById('namespace-status');
            statusDiv.innerHTML = '<span class="status-success">Namespace created successfully</span>';
            document.getElementById('create-namespace-prompt').classList.add('hidden');
            state.targetNamespaceValid = true;
            showStep(5);
            updateRestoreSummary();
        } else {
            throw new Error(data.message || 'Failed to create namespace');
        }

    } catch (error) {
        const statusDiv = document.getElementById('namespace-status');
        statusDiv.innerHTML = `<span class="status-error">Failed to create namespace: ${error.message}</span>`;
    } finally {
        btn.disabled = false;
        btn.textContent = 'Create Namespace';
    }
}

function updateRestoreSummary() {
    const summaryDiv = document.getElementById('restore-summary');
    summaryDiv.innerHTML = `
        <h3>Restore Configuration</h3>
        <table class="summary-table">
            <tr>
                <td>Source Namespace:</td>
                <td><strong>${state.sourceNamespace}</strong></td>
            </tr>
            <tr>
                <td>Source Cluster:</td>
                <td><strong>${state.clusterName}</strong></td>
            </tr>
            <tr>
                <td>Backup:</td>
                <td><strong>${state.selectedBackup.name}</strong></td>
            </tr>
            <tr>
                <td>Restore To (UTC):</td>
                <td><strong>${state.restoreTime}</strong></td>
            </tr>
            <tr>
                <td>Target Namespace:</td>
                <td><strong>${state.targetNamespace}</strong></td>
            </tr>
            <tr>
                <td>New Cluster Name:</td>
                <td><strong>${state.clusterName}-restored</strong></td>
            </tr>
        </table>
    `;
}

async function startRestore() {
    const btn = document.getElementById('start-restore-btn');
    btn.disabled = true;
    btn.textContent = 'Starting Restore...';

    showStep(6);
    updateProgress('Initiating restore...', 10);

    try {
        const response = await fetch(`${API_BASE}/api/restore`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                sourceNamespace: state.sourceNamespace,
                targetNamespace: state.targetNamespace,
                backupName: state.selectedBackup.name,
                restoreTime: state.restoreTime,
                createNamespace: false
            })
        });

        const data = await response.json();

        if (!data.success) {
            throw new Error(data.message);
        }

        state.restoreName = data.restoreName;
        state.clusterName = data.clusterName;

        updateProgress('Restore initiated. Creating cluster...', 20);
        
        // Poll for restore status
        pollRestoreStatus();

    } catch (error) {
        updateProgress(`Error: ${error.message}`, 0, true);
        btn.disabled = false;
        btn.textContent = 'Start Restore';
    }
}

async function pollRestoreStatus() {
    const maxAttempts = 120; // 10 minutes with 5 second intervals
    let attempts = 0;

    const poll = async () => {
        attempts++;
        
        try {
            // Check restore status
            const restoreResponse = await fetch(
                `${API_BASE}/api/restore/status?namespace=${state.targetNamespace}&name=${state.restoreName}`
            );
            const restoreData = await restoreResponse.json();

            // Check cluster status
            const clusterResponse = await fetch(
                `${API_BASE}/api/cluster/status?namespace=${state.targetNamespace}&cluster=${state.clusterName}`
            );
            const clusterData = await clusterResponse.json();

            // Update progress based on status
            const progress = Math.min(20 + (attempts * 0.5), 90);
            let statusMessage = '';

            if (restoreData.state === 'Restoring' || restoreData.state === 'Starting') {
                statusMessage = `Restoring data... (${restoreData.state})`;
            } else if (restoreData.state === 'Succeeded' || restoreData.state === 'Ready') {
                if (clusterData.state === 'ready') {
                    updateProgress('Restore complete!', 100);
                    showRestoreComplete();
                    return;
                } else {
                    statusMessage = `Restore complete. Waiting for cluster... (${clusterData.state})`;
                }
            } else if (restoreData.state === 'Failed' || restoreData.state === 'Error') {
                throw new Error(`Restore failed: ${restoreData.message || restoreData.state}`);
            } else {
                statusMessage = `Status: ${restoreData.state || 'Waiting'}... Cluster: ${clusterData.state || 'Pending'}`;
            }

            updateProgress(statusMessage, progress);
            document.getElementById('progress-details').innerHTML = `
                <div>Restore: ${restoreData.state || 'Pending'}</div>
                <div>Cluster: ${clusterData.state || 'Pending'} (${clusterData.pxcReady || '0'}/${clusterData.pxcSize || '?'} nodes)</div>
            `;

            if (attempts < maxAttempts) {
                setTimeout(poll, 5000);
            } else {
                throw new Error('Restore timed out after 10 minutes');
            }

        } catch (error) {
            if (error.message.includes('timed out') || error.message.includes('failed')) {
                updateProgress(`Error: ${error.message}`, 0, true);
            } else {
                // Network error, retry
                if (attempts < maxAttempts) {
                    setTimeout(poll, 5000);
                }
            }
        }
    };

    poll();
}

async function showRestoreComplete() {
    showStep(7);
    
    document.getElementById('success-banner').innerHTML = `
        <div class="success-icon">OK</div>
        <h3>Restore Successful</h3>
        <p>Cluster <strong>${state.clusterName}</strong> has been restored to <strong>${state.restoreTime} UTC</strong></p>
        <p>in namespace <strong>${state.targetNamespace}</strong></p>
    `;

    // Load database summary
    try {
        const response = await fetch(
            `${API_BASE}/api/restore/summary?namespace=${state.targetNamespace}&cluster=${state.clusterName}`
        );
        const data = await response.json();

        const summaryDiv = document.getElementById('database-summary');
        
        if (data.databases && data.databases.length > 0) {
            summaryDiv.innerHTML = `
                <h3>Database Summary</h3>
                <p class="summary-time">Restored to: <strong>${data.restoredTo || state.restoreTime}</strong></p>
                <table class="database-table">
                    <thead>
                        <tr>
                            <th>Database</th>
                            <th>Tables</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.databases.map(db => `
                            <tr>
                                <td>${db.name}</td>
                                <td>${db.tableCount >= 0 ? db.tableCount : 'N/A'}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                    <tfoot>
                        <tr>
                            <td><strong>Total</strong></td>
                            <td><strong>${data.totalTables}</strong></td>
                        </tr>
                    </tfoot>
                </table>
                <div class="connection-info">
                    <h4>Connect to Restored Cluster</h4>
                    <pre><code>kubectl exec -it ${state.clusterName}-pxc-0 -n ${state.targetNamespace} -c pxc -- mysql -uroot -p</code></pre>
                </div>
            `;
        } else {
            summaryDiv.innerHTML = `
                <h3>Database Summary</h3>
                <p>No user databases found (only system databases exist).</p>
                <div class="connection-info">
                    <h4>Connect to Restored Cluster</h4>
                    <pre><code>kubectl exec -it ${state.clusterName}-pxc-0 -n ${state.targetNamespace} -c pxc -- mysql -uroot -p</code></pre>
                </div>
            `;
        }

    } catch (error) {
        document.getElementById('database-summary').innerHTML = `
            <h3>Database Summary</h3>
            <p class="error">Could not load database summary: ${error.message}</p>
            <div class="connection-info">
                <h4>Connect to Restored Cluster</h4>
                <pre><code>kubectl exec -it ${state.clusterName}-pxc-0 -n ${state.targetNamespace} -c pxc -- mysql -uroot -p</code></pre>
            </div>
        `;
    }
}

function updateProgress(message, percent, isError = false) {
    document.getElementById('progress-status').textContent = message;
    document.getElementById('progress-status').className = `progress-status ${isError ? 'error' : ''}`;
    document.getElementById('progress-fill').style.width = `${percent}%`;
    document.getElementById('progress-fill').className = `progress-fill ${isError ? 'error' : ''}`;
}

// Utility functions
function showStep(stepNum) {
    const section = document.getElementById(`step-${stepNum}`);
    if (section) {
        section.classList.remove('hidden');
        section.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
}

function hideStep(stepNum) {
    const section = document.getElementById(`step-${stepNum}`);
    if (section) {
        section.classList.add('hidden');
    }
    // Also hide subsequent steps
    for (let i = stepNum + 1; i <= 7; i++) {
        const s = document.getElementById(`step-${i}`);
        if (s) s.classList.add('hidden');
    }
}

function showError(elementId, message) {
    const el = document.getElementById(elementId);
    if (el) {
        el.textContent = message;
        el.classList.remove('hidden');
    }
}

function hideError(elementId) {
    const el = document.getElementById(elementId);
    if (el) {
        el.classList.add('hidden');
    }
}

function formatTime(isoString) {
    if (!isoString) return 'N/A';
    try {
        const date = new Date(isoString);
        return date.toISOString().replace('T', ' ').replace('Z', ' UTC').substring(0, 23) + ' UTC';
    } catch {
        return isoString;
    }
}

function formatTimeForInput(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const year = date.getUTCFullYear();
        const month = String(date.getUTCMonth() + 1).padStart(2, '0');
        const day = String(date.getUTCDate()).padStart(2, '0');
        const hour = String(date.getUTCHours()).padStart(2, '0');
        const minute = String(date.getUTCMinutes()).padStart(2, '0');
        const second = String(date.getUTCSeconds()).padStart(2, '0');
        return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
    } catch {
        return '';
    }
}
