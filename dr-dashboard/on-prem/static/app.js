let allScenarios = [];

// Initialize the app
document.addEventListener('DOMContentLoaded', () => {
    loadScenarios();
    enhanceCodeBlocks();
});

function copyCodeText(codeElement, triggerEl) {
    if (!codeElement) return;
    const text = codeElement.innerText;
    if (!text) return;

    const handleSuccess = () => {
        if (triggerEl) {
            triggerEl.classList.add('copied');
            clearTimeout(triggerEl._copyTimeout);
            triggerEl._copyTimeout = setTimeout(() => {
                triggerEl.classList.remove('copied');
            }, 1500);
        }
    };

    const clipboardCopy = navigator.clipboard?.writeText(text);
    if (clipboardCopy) {
        clipboardCopy.then(handleSuccess).catch((err) => {
            console.error('Clipboard copy failed, falling back to execCommand:', err);
            fallbackCopy();
        });
    } else {
        fallbackCopy();
    }

    function fallbackCopy() {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(codeElement);
        selection.removeAllRanges();
        selection.addRange(range);

        try {
            const successful = document.execCommand('copy');
            if (successful) {
                handleSuccess();
            } else {
                alert('Failed to copy. Please copy manually.');
            }
        } catch (err) {
            console.error('Fallback copy failed:', err);
            alert('Failed to copy. Please copy manually.');
        } finally {
            selection.removeAllRanges();
        }
    }
}

function enhanceCodeBlocks(context = document) {
    const codeBlocks = context.querySelectorAll('pre code');
    codeBlocks.forEach((codeBlock) => {
        if (codeBlock.dataset.copyEnhanced === 'true') return;
        codeBlock.dataset.copyEnhanced = 'true';

        const pre = codeBlock.parentElement;
        if (!pre) return;

        pre.classList.add('code-copy-container');
        if (!pre.getAttribute('tabindex')) {
            pre.setAttribute('tabindex', '0');
        }

        let copyIcon = pre.querySelector('.copy-icon');
        if (!copyIcon) {
            copyIcon = document.createElement('button');
            copyIcon.type = 'button';
            copyIcon.className = 'copy-icon';
            copyIcon.setAttribute('aria-label', 'Copy code');
            copyIcon.innerHTML = `
                <svg viewBox="0 0 16 16" role="img" aria-hidden="true">
                    <path d="M4 1.75A1.75 1.75 0 0 1 5.75 0h7.5A1.75 1.75 0 0 1 15 1.75v7.5A1.75 1.75 0 0 1 13.25 11h-7.5A1.75 1.75 0 0 1 4 9.25ZM5.75 1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"></path>
                    <path d="M1.75 5A1.75 1.75 0 0 0 0 6.75v7.5C0 15.216.784 16 1.75 16h7.5A1.75 1.75 0 0 0 11 14.25V13H9.5v1.25a.25.25 0 0 1-.25.25h-7.5a.25.25 0 0 1-.25-.25v-7.5a.25.25 0 0 1 .25-.25H3V5Z"></path>
                </svg>
            `;
            pre.appendChild(copyIcon);
        }

        copyIcon.addEventListener('click', (event) => {
            event.preventDefault();
            event.stopPropagation();
            copyCodeText(codeBlock, copyIcon);
        });

        pre.addEventListener('click', () => copyCodeText(codeBlock, copyIcon));
        pre.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' || event.key === ' ') {
                event.preventDefault();
                copyCodeText(codeBlock, copyIcon);
            }
        });
    });
}

async function loadScenarios() {
    const container = document.getElementById('scenarios-container');
    container.innerHTML = '<div class="loading"><div class="spinner"></div><p>Loading emergency procedures...</p></div>';
    
    try {
        const response = await fetch('/api/scenarios');
        if (!response.ok) throw new Error('Failed to load scenarios');
        
        const data = await response.json();
        allScenarios = sortScenarios(data.scenarios);
        
        renderScenarios(allScenarios);
        renderDiscardedScenarios(data.discarded_scenarios || []);
    } catch (error) {
        container.innerHTML = `
            <div class="loading">
                <p style="color: var(--accent-danger);">Error loading scenarios: ${error.message}</p>
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

function formatDescription(text) {
    if (!text) return '';
    // Split by semicolon and format each item on a new line
    return text.split(';').map(item => item.trim()).filter(item => item).join('<br>');
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
                                <span>Service Restored Time Objective: ${scenario.rto_target}</span>
                            </div>
                            <div class="info-item">
                                <span>Recovery Point Objective: ${scenario.rpo_target}</span>
                            </div>
                            <div class="info-item">
                                <span>Full Repair Time Objective: ${scenario.mttr_expected}</span>
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
                                    <div class="info-card-value">${formatDescription(scenario.detection_signals)}</div>
                                </div>
                                <div class="info-card">
                                    <div class="info-card-title">Affected Components</div>
                                    <div class="info-card-value">${formatDescription(scenario.affected_components)}</div>
                                </div>
                            </div>
                            
                            <div class="recovery-process">
                                <h2>Primary Recovery Method</h2>
                                <p>${formatDescription(scenario.primary_recovery_method)}</p>
                                
                                <h2>Alternate/Fallback Method</h2>
                                <p>${formatDescription(scenario.alternate_fallback)}</p>
                                
                                <h2>Notes & Assumptions</h2>
                                <p>${formatDescription(scenario.notes_assumptions)}</p>
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
    
    if (!scenario || !scenario.recovery_process_file) {
        console.error('Scenario or recovery_process_file missing:', scenario);
        processContent.innerHTML = `
            <div style="padding: 2rem; text-align: center;">
                <p style="color: var(--accent-danger);">Error: Recovery process file not specified for this scenario.</p>
            </div>
        `;
        return;
    }
    
    const url = `/api/recovery-process?file=${encodeURIComponent(scenario.recovery_process_file)}`;
    console.log('Loading recovery process:', url, 'for scenario:', scenario.scenario);
    
    try {
        const response = await fetch(url);
        
        if (response.ok) {
            const markdown = await response.text();
            if (markdown && markdown.trim().length > 0) {
                processContent.innerHTML = marked.parse(markdown);
                enhanceCodeBlocks(processContent);
            } else {
                console.warn('Recovery process file is empty:', scenario.recovery_process_file);
                processContent.innerHTML = `
                    <div style="padding: 2rem; text-align: center;">
                        <p style="color: var(--accent-warning);">Recovery process file is empty.</p>
                    </div>
                `;
            }
        } else {
            const errorText = await response.text();
            console.error('Failed to load recovery process:', response.status, errorText);
            processContent.innerHTML = `
                <div style="padding: 2rem; text-align: center;">
                    <p style="color: var(--accent-warning);">Detailed recovery process documentation not yet available.</p>
                    <p style="color: var(--text-secondary); margin-top: 1rem;">File: ${scenario.recovery_process_file}</p>
                    <p style="color: var(--text-secondary); margin-top: 0.5rem;">Status: ${response.status} ${response.statusText}</p>
                    <p style="color: var(--text-secondary); margin-top: 1rem;">Please refer to the overview tab for basic recovery information.</p>
                </div>
            `;
        }
    } catch (error) {
        console.error('Error loading recovery process:', error);
        processContent.innerHTML = `
            <div style="padding: 2rem; text-align: center;">
                <p style="color: var(--accent-danger);">Error loading recovery process: ${error.message}</p>
                <p style="color: var(--text-secondary); margin-top: 0.5rem;">File: ${scenario.recovery_process_file}</p>
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

function renderDiscardedScenarios(discardedScenarios) {
    const container = document.getElementById('discarded-scenarios-container');
    
    if (!discardedScenarios || discardedScenarios.length === 0) {
        container.innerHTML = '';
        return;
    }
    
    container.innerHTML = `
        <div class="discarded-scenarios-section">
            <h2 class="discarded-scenarios-title">Undocumented Scenarios</h2>
            <p class="discarded-scenarios-description">These scenarios were evaluated but de-prioritized due to either extremely low likelihood of occurrence or insufficient business impact to justify dedicated recovery documentation. Recovery procedures for these scenarios are not provided, as resources were allocated to the higher-priority scenarios documented above. These undocumented scenarios are included here to demonstrate completeness of the disaster scenario evaluation process.</p>
            <div class="discarded-scenarios-list">
                ${discardedScenarios.map(discarded => `
                    <div class="discarded-scenario-item">
                        <div class="discarded-scenario-name">${discarded.scenario}</div>
                        <div class="discarded-scenario-reason">${discarded.reason}</div>
                    </div>
                `).join('')}
            </div>
        </div>
    `;
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
