let currentEnv = 'eks';
let allScenarios = [];

// Initialize the app
document.addEventListener('DOMContentLoaded', () => {
    loadScenarios(currentEnv);
    setupEventListeners();
});

// Copy to clipboard function
function copyToClipboard(elementId) {
    const element = document.getElementById(elementId);
    const text = element.textContent;
    
    navigator.clipboard.writeText(text).then(() => {
        // Find the copy button
        const btn = event.target.closest('.copy-btn');
        const originalText = btn.textContent;
        
        // Show feedback
        btn.textContent = 'Copied!';
        btn.classList.add('copied');
        
        // Reset after 2 seconds
        setTimeout(() => {
            btn.textContent = originalText;
            btn.classList.remove('copied');
        }, 2000);
    }).catch(err => {
        console.error('Failed to copy:', err);
        alert('Failed to copy to clipboard. Please copy manually.');
    });
}

function setupEventListeners() {
    // Environment switcher
    document.querySelectorAll('.env-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const env = e.currentTarget.dataset.env;
            switchEnvironment(env);
        });
    });
}

function switchEnvironment(env) {
    currentEnv = env;
    
    // Update button states
    document.querySelectorAll('.env-btn').forEach(btn => {
        btn.classList.remove('active');
        if (btn.dataset.env === env) {
            btn.classList.add('active');
        }
    });
    
    // Load scenarios for the new environment
    loadScenarios(env);
}

async function loadScenarios(env) {
    const container = document.getElementById('scenarios-container');
    container.innerHTML = '<div class="loading"><div class="spinner"></div><p>Loading emergency procedures...</p></div>';
    
    try {
        const response = await fetch(`/api/scenarios?env=${env}`);
        if (!response.ok) throw new Error('Failed to load scenarios');
        
        const data = await response.json();
        allScenarios = sortScenarios(data.scenarios);
        
        renderScenarios(allScenarios);
    } catch (error) {
        container.innerHTML = `
            <div class="loading">
                <p style="color: var(--accent-danger);">❌ Error loading scenarios: ${error.message}</p>
            </div>
        `;
    }
}

function sortScenarios(scenarios) {
    const impactOrder = { 'critical': 0, 'high': 1, 'medium': 2, 'low': 3 };
    const likelihoodOrder = { 'high': 0, 'medium': 1, 'low': 2 };
    
    return scenarios.sort((a, b) => {
        const impactA = impactOrder[a.business_impact.toLowerCase()] ?? 99;
        const impactB = impactOrder[b.business_impact.toLowerCase()] ?? 99;
        
        if (impactA !== impactB) {
            return impactA - impactB;
        }
        
        const likelihoodA = likelihoodOrder[a.likelihood.toLowerCase()] ?? 99;
        const likelihoodB = likelihoodOrder[b.likelihood.toLowerCase()] ?? 99;
        
        return likelihoodA - likelihoodB;
    });
}

function renderScenarios(scenarios) {
    const container = document.getElementById('scenarios-container');
    
    if (scenarios.length === 0) {
        container.innerHTML = '<div class="loading"><p>No scenarios found</p></div>';
        return;
    }
    
    container.innerHTML = scenarios.map((scenario, index) => {
        const impactClass = getImpactClass(scenario.business_impact);
        const likelihoodClass = getLikelihoodClass(scenario.likelihood);
        
        return `
            <div class="scenario-card" style="animation-delay: ${index * 0.05}s">
                <div class="scenario-header" onclick="toggleScenario(${index})">
                    <div class="expand-arrow" id="arrow-${index}">
                        ▶
                    </div>
                    <div class="scenario-summary">
                        <h3 class="scenario-title">${scenario.scenario}</h3>
                        
                        <div class="scenario-meta">
                            <span class="badge ${impactClass}">${scenario.business_impact} Impact</span>
                            <span class="badge ${likelihoodClass}">${scenario.likelihood} Likelihood</span>
                            <span class="badge ${scenario.test_enabled ? 'badge-tested' : 'badge-untested'}">
                                ${scenario.test_enabled ? 'Tested' : 'Untested'}
                            </span>
                        </div>
                        
                        <div class="scenario-info">
                            <div class="info-item">
                                <span>RTO: ${scenario.rto_target}</span>
                            </div>
                            <div class="info-item">
                                <span>RPO: ${scenario.rpo_target}</span>
                            </div>
                            <div class="info-item">
                                <span>MTTR: ${scenario.mttr_expected}</span>
                            </div>
                            <div class="info-item">
                                <span>Data Loss: ${scenario.expected_data_loss}</span>
                            </div>
                        </div>
                    </div>
                </div>
                
                <div class="recovery-content" id="content-${index}">
                    <div class="recovery-inner">
                        <div class="recovery-tabs">
                            <button class="tab-btn active" onclick="switchTab(${index}, 'overview')">
                                Overview
                            </button>
                            <button class="tab-btn" onclick="switchTab(${index}, 'process')">
                                Recovery Process
                            </button>
                        </div>
                        
                        <div class="tab-content active" id="tab-overview-${index}">
                            <div class="quick-info">
                                <div class="info-card">
                                    <div class="info-card-title">Detection Signals</div>
                                    <div class="info-card-value">${scenario.detection_signals}</div>
                                </div>
                                <div class="info-card">
                                    <div class="info-card-title">Affected Components</div>
                                    <div class="info-card-value">${scenario.affected_components}</div>
                                </div>
                            </div>
                            
                            <div class="recovery-process">
                                <h2>Primary Recovery Method</h2>
                                <p>${scenario.primary_recovery_method}</p>
                                
                                <h2>Alternate/Fallback Method</h2>
                                <p>${scenario.alternate_fallback}</p>
                                
                                <h2>Notes & Assumptions</h2>
                                <p>${scenario.notes_assumptions}</p>
                            </div>
                        </div>
                        
                        <div class="tab-content" id="tab-process-${index}">
                            <div class="recovery-process" id="process-content-${index}">
                                <div class="loading">
                                    <div class="spinner"></div>
                                    <p>Loading detailed recovery process...</p>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function toggleScenario(index) {
    const arrow = document.getElementById(`arrow-${index}`);
    const content = document.getElementById(`content-${index}`);
    
    // Handle 'unknown' scenario (no process content to load)
    if (index === 'unknown') {
        const isExpanded = content.classList.contains('expanded');
        if (isExpanded) {
            arrow.classList.remove('expanded');
            content.classList.remove('expanded');
        } else {
            arrow.classList.add('expanded');
            content.classList.add('expanded');
        }
        return;
    }
    
    const processContent = document.getElementById(`process-content-${index}`);
    const isExpanded = content.classList.contains('expanded');
    
    if (isExpanded) {
        // Collapse
        arrow.classList.remove('expanded');
        content.classList.remove('expanded');
    } else {
        // Expand
        arrow.classList.add('expanded');
        content.classList.add('expanded');
        
        // Load recovery process if not already loaded
        if (processContent.innerHTML.includes('Loading')) {
            loadRecoveryProcess(index);
        }
    }
}

async function loadRecoveryProcess(index) {
    const scenario = allScenarios[index];
    const processContent = document.getElementById(`process-content-${index}`);
    
    try {
        const response = await fetch(`/api/recovery-process?env=${currentEnv}&file=${scenario.recovery_process_file}`);
        
        if (response.ok) {
            const markdown = await response.text();
            processContent.innerHTML = marked.parse(markdown);
        } else {
            processContent.innerHTML = `
                <div style="padding: 2rem; text-align: center;">
                    <p style="color: var(--accent-warning);">⚠️ Detailed recovery process documentation not yet available.</p>
                    <p style="color: var(--text-secondary); margin-top: 1rem;">Please refer to the overview tab for basic recovery information.</p>
                </div>
            `;
        }
    } catch (error) {
        processContent.innerHTML = `
            <div style="padding: 2rem; text-align: center;">
                <p style="color: var(--accent-danger);">❌ Error loading recovery process: ${error.message}</p>
            </div>
        `;
    }
}

function switchTab(index, tab) {
    // Update tab buttons
    const tabBtns = document.querySelectorAll(`#content-${index} .tab-btn`);
    tabBtns.forEach(btn => btn.classList.remove('active'));
    event.currentTarget.classList.add('active');
    
    // Update tab content
    const tabContents = document.querySelectorAll(`#content-${index} .tab-content`);
    tabContents.forEach(content => content.classList.remove('active'));
    document.getElementById(`tab-${tab}-${index}`).classList.add('active');
    
    // Load recovery process if switching to process tab
    if (tab === 'process') {
        const processContent = document.getElementById(`process-content-${index}`);
        if (processContent.innerHTML.includes('Loading')) {
            loadRecoveryProcess(index);
        }
    }
}


function getImpactClass(impact) {
    const lower = impact.toLowerCase();
    if (lower.includes('critical')) return 'badge-critical';
    if (lower.includes('high')) return 'badge-high';
    if (lower.includes('medium')) return 'badge-medium';
    return 'badge-low';
}

function getLikelihoodClass(likelihood) {
    const lower = likelihood.toLowerCase();
    if (lower.includes('high')) return 'badge-critical';
    if (lower.includes('medium')) return 'badge-medium';
    return 'badge-low';
}

// Configure marked.js options
if (typeof marked !== 'undefined') {
    marked.setOptions({
        breaks: true,
        gfm: true,
        headerIds: true,
        mangle: false
    });
}
