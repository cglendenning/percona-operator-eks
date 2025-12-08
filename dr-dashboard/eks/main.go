package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const environment = "eks"

// DisasterScenario represents a single disaster recovery scenario
// Data source: ../../testing/eks/disaster_scenarios/disaster_scenarios.json
// This maintains single source of truth with the testing framework
type DisasterScenario struct {
	Scenario              string  `json:"scenario"`
	PrimaryRecoveryMethod string  `json:"primary_recovery_method"`
	AlternateFallback     string  `json:"alternate_fallback"`
	DetectionSignals      string  `json:"detection_signals"`
	RTOTarget             string  `json:"rto_target"`
	RPOTarget             string  `json:"rpo_target"`
	MTTRExpected          string  `json:"mttr_expected"`
	ExpectedDataLoss      string  `json:"expected_data_loss"`
	Likelihood            string  `json:"likelihood"`
	BusinessImpact        string  `json:"business_impact"`
	AffectedComponents    string  `json:"affected_components"`
	NotesAssumptions      string  `json:"notes_assumptions"`
	TestEnabled           bool    `json:"test_enabled"`
	TestDescription       string  `json:"test_description"`
	TestFile              *string `json:"test_file"`
	RecoveryProcessFile   string  `json:"recovery_process_file,omitempty"`
}

// DiscardedScenario represents a scenario that has no recovery process documentation
type DiscardedScenario struct {
	Scenario string `json:"scenario"`
	Reason   string `json:"reason"`
}

// DisasterScenariosFile represents the structure of the disaster scenarios JSON file
type DisasterScenariosFile struct {
	Scenarios          []DisasterScenario  `json:"scenarios"`
	DiscardedScenarios []DiscardedScenario `json:"discarded_scenarios"`
}

type ScenarioResponse struct {
	Environment        string              `json:"environment"`
	Scenarios          []DisasterScenario  `json:"scenarios"`
	DiscardedScenarios []DiscardedScenario `json:"discarded_scenarios"`
}

var scenarios []DisasterScenario
var discardedScenarios []DiscardedScenario
var baseDir string

func main() {
	// Determine base directory (dr-dashboard/)
	// Get current working directory
	cwd, err := os.Getwd()
	if err != nil {
		log.Fatalf("Failed to get working directory: %v", err)
	}

	// If we're in on-prem/ or eks/ subdirectory, go up one level
	baseDir = cwd
	if filepath.Base(cwd) == "on-prem" || filepath.Base(cwd) == "eks" {
		baseDir = filepath.Dir(cwd)
	}

	log.Printf("Base directory: %s", baseDir)
	log.Printf("Current working directory: %s", cwd)

	// Load scenarios from JSON file
	if err := loadScenarios(); err != nil {
		log.Fatalf("Failed to load scenarios: %v", err)
	}

	// Setup HTTP handlers
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/api/scenarios", handleScenarios)
	http.HandleFunc("/api/recovery-process", handleRecoveryProcess)
	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("./static"))))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Database Emergency Kit (EKS) starting on port %s", port)
	log.Printf("Open http://localhost:%s in your browser", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// loadScenarios reads disaster scenarios from the testing framework's JSON file
// Single source of truth: ../../testing/eks/disaster_scenarios/disaster_scenarios.json
func loadScenarios() error {
	jsonPath := filepath.Join(baseDir, "..", "testing", environment, "disaster_scenarios", "disaster_scenarios.json")

	data, err := os.ReadFile(jsonPath)
	if err != nil {
		return fmt.Errorf("failed to read %s scenarios: %w", environment, err)
	}

	var scenariosFile DisasterScenariosFile
	if err := json.Unmarshal(data, &scenariosFile); err != nil {
		return fmt.Errorf("failed to parse %s scenarios: %w", environment, err)
	}

	scenarios = scenariosFile.Scenarios
	discardedScenarios = scenariosFile.DiscardedScenarios

	// Map each scenario to its recovery process file
	for i := range scenarios {
		filename := scenarioToFilename(scenarios[i].Scenario)
		scenarios[i].RecoveryProcessFile = filename
	}

	log.Printf("✅ Loaded %d scenarios for %s", len(scenarios), environment)
	return nil
}

func scenarioToFilename(scenario string) string {
	// Manual mapping for known scenarios to ensure exact filename matches
	mappings := map[string]string{
		"Single MySQL pod failure (container crash / OOM)":                 "single-mysql-pod-failure.md",
		"Kubernetes worker node failure (VM host crash)":                   "kubernetes-worker-node-failure.md",
		"Storage PVC corruption for a single PXC node":                     "storage-pvc-corruption.md",
		"Percona Operator / CRD misconfiguration (bad rollout)":            "percona-operator-crd-misconfiguration.md",
		"Schema change or DDL blocks writes":                               "schema-change-or-ddl-blocks-writes.md",
		"Cluster loses quorum (multiple PXC pods down)":                    "cluster-loses-quorum.md",
		"Primary DC network partition from Secondary (WAN cut)":            "primary-dc-network-partition-from-secondary-wan-cut.md",
		"Primary DC power/cooling outage (site down)":                      "primary-dc-power-cooling-outage-site-down.md",
		"Primary Data Center Is Down":                                      "primary-dc-power-cooling-outage-site-down.md",
		"Both DCs up but replication stops (broken channel)":               "both-dcs-up-but-replication-stops-broken-channel.md",
		"Accidental DROP/DELETE/TRUNCATE (logical data loss)":              "accidental-drop-delete-truncate-logical-data-loss.md",
		"Widespread data corruption (bad migration/script)":                "widespread-data-corruption-bad-migration-script.md",
		"S3 backup target unavailable (regional outage or ACL/cred issue)": "s3-backup-target-unavailable-regional-outage-or-acl-cred-issue.md",
		"Backups complete but are non\u2011restorable (silent failure)":    "backups-complete-but-are-non-restorable-silent-failure.md",
		"Kubernetes control plane outage (API server down)":                "kubernetes-control-plane-outage-api-server-down.md",
		"Ransomware attack":                                                      "ransomware-on-vmware-hosts-storage-encrypted.md",
		"Credential compromise (DB or S3 keys)":                                  "credential-compromise-db-or-s3-keys.md",
		"HAProxy endpoints inaccessible":                                         "ingress-vip-failure.md",
		"Database disk space exhaustion (data directory)":                        "database-disk-space-exhaustion.md",
		"Temporary tablespace exhaustion":                                        "temporary-tablespace-exhaustion.md",
		"Connection pool exhaustion (max_connections reached)":                   "connection-pool-exhaustion-max-connections-reached.md",
		"Increased API call volume causes performance degradation":               "sustained-high-load-causing-performance-degradation.md",
		"S3 service failure (backup target unavailable)":                         "s3-service-failure-backup-target-unavailable.md",
		"Audit log corruption or loss (compliance violation)":                    "audit-log-corruption-or-loss-compliance-violation.md",
		"Backup retention policy failure (backups deleted prematurely)":          "backup-retention-policy-failure-backups-deleted-prematurely.md",
		"DNS resolution failure (internal or external)":                          "dns-resolution-failure-internal-or-external.md",
		"Certificate expiration or revocation causing connection failures":       "certificate-expiration-or-revocation-causing-connection-failures.md",
		"Memory exhaustion causing OOM kills (out of memory)":                    "memory-exhaustion-causing-oom-kills-out-of-memory.md",
		"Clock skew between cluster nodes causing replication issues":            "clock-skew-between-cluster-nodes-causing-replication-issues.md",
		"Accidental production restore from wrong backup or wrong point in time": "accidental-production-restore-from-wrong-backup-or-wrong-point-in-time.md",
		"Network policy misconfiguration blocking database access":               "network-policy-misconfiguration-blocking-database-access.md",
		"Application causing excessive replication lag":                          "application-causing-excessive-replication-lag.md",
		"Monitoring and alerting system failure during incident":                 "monitoring-and-alerting-system-failure-during-incident.md",
		"Encryption key rotation failure (database or backup encryption)":        "encryption-key-rotation-failure-database-or-backup-encryption.md",
		"Application change causes performance degradation":                      "application-change-causes-performance-degradation.md",
	}

	// Check if we have a direct mapping
	if filename, ok := mappings[scenario]; ok {
		return filename
	}

	// Fallback: generate filename from scenario name
	filename := strings.ToLower(scenario)
	filename = strings.ReplaceAll(filename, "(", "")
	filename = strings.ReplaceAll(filename, ")", "")
	filename = strings.ReplaceAll(filename, "/", "-")
	filename = strings.ReplaceAll(filename, ":", "")
	filename = strings.ReplaceAll(filename, ",", "")
	filename = strings.ReplaceAll(filename, " ", "-")

	// Clean up multiple consecutive dashes
	re := regexp.MustCompile(`-+`)
	filename = re.ReplaceAllString(filename, "-")
	filename = strings.Trim(filename, "-")

	return filename + ".md"
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, "./static/index.html")
}

func handleScenarios(w http.ResponseWriter, r *http.Request) {
	response := ScenarioResponse{
		Environment:        environment,
		Scenarios:          scenarios,
		DiscardedScenarios: discardedScenarios,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding response: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}
}

// handleRecoveryProcess serves markdown recovery process documentation
func handleRecoveryProcess(w http.ResponseWriter, r *http.Request) {
	filename := r.URL.Query().Get("file")

	if filename == "" {
		http.Error(w, "Missing file parameter", http.StatusBadRequest)
		return
	}

	// Security: prevent directory traversal attacks
	if strings.Contains(filename, "..") || strings.Contains(filename, "/") {
		http.Error(w, "Invalid filename", http.StatusBadRequest)
		return
	}

	// Use base directory to construct path
	mdPath := filepath.Join(baseDir, "recovery_processes", environment, filename)
	absPath, _ := filepath.Abs(mdPath)
	log.Printf("Loading recovery process: %s (absolute: %s)", filename, absPath)

	content, err := os.ReadFile(mdPath)
	if err != nil {
		log.Printf("Error reading recovery process file '%s' from %s: %v", filename, absPath, err)
		http.Error(w, fmt.Sprintf("Recovery process not found: %s", filename), http.StatusNotFound)
		return
	}

	log.Printf("Successfully loaded recovery process: %s", filename)

	w.Header().Set("Content-Type", "text/markdown")
	if _, err := w.Write(content); err != nil {
		log.Printf("Error writing response: %v", err)
	}
}
