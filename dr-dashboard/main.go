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

// DisasterScenario represents a single disaster recovery scenario
// Data source: ../testing/{eks,on-prem}/disaster_scenarios/disaster_scenarios.json
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

type ScenarioResponse struct {
	Environment string             `json:"environment"`
	Scenarios   []DisasterScenario `json:"scenarios"`
}

var scenarios map[string][]DisasterScenario

func init() {
	scenarios = make(map[string][]DisasterScenario)
}

func main() {
	// Load scenarios from JSON files
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

	log.Printf("Disaster Recovery Dashboard starting on port %s", port)
	log.Printf("Open http://localhost:%s in your browser", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// loadScenarios reads disaster scenarios from the testing framework's JSON files
// Single source of truth: ../testing/{eks,on-prem}/disaster_scenarios/disaster_scenarios.json
func loadScenarios() error {
	environments := []string{"eks", "on-prem"}

	for _, env := range environments {
		jsonPath := filepath.Join("..", "testing", env, "disaster_scenarios", "disaster_scenarios.json")

		data, err := os.ReadFile(jsonPath)
		if err != nil {
			return fmt.Errorf("failed to read %s scenarios: %w", env, err)
		}

		var envScenarios []DisasterScenario
		if err := json.Unmarshal(data, &envScenarios); err != nil {
			return fmt.Errorf("failed to parse %s scenarios: %w", env, err)
		}

		// Map each scenario to its recovery process file
		for i := range envScenarios {
			filename := scenarioToFilename(envScenarios[i].Scenario)
			envScenarios[i].RecoveryProcessFile = filename
		}

		scenarios[env] = envScenarios
		log.Printf("✅ Loaded %d scenarios for %s", len(envScenarios), env)
	}

	return nil
}

func scenarioToFilename(scenario string) string {
	// Manual mapping for known scenarios to ensure exact filename matches
	mappings := map[string]string{
		"Single MySQL pod failure (container crash / OOM)":                 "single-mysql-pod-failure.md",
		"Kubernetes worker node failure (VM host crash)":                   "kubernetes-worker-node-failure.md",
		"Storage PVC corruption for a single PXC node":                     "storage-pvc-corruption.md",
		"Percona Operator / CRD misconfiguration (bad rollout)":            "percona-operator-crd-misconfiguration.md",
		"Cluster loses quorum (multiple PXC pods down)":                    "cluster-loses-quorum.md",
		"Primary DC network partition from Secondary (WAN cut)":            "primary-dc-network-partition-from-secondary-wan-cut.md",
		"Primary DC power/cooling outage (site down)":                      "primary-dc-power-cooling-outage-site-down.md",
		"Both DCs up but replication stops (broken channel)":               "both-dcs-up-but-replication-stops-broken-channel.md",
		"Accidental DROP/DELETE/TRUNCATE (logical data loss)":              "accidental-drop-delete-truncate-logical-data-loss.md",
		"Widespread data corruption (bad migration/script)":                "widespread-data-corruption-bad-migration-script.md",
		"S3 backup target unavailable (regional outage or ACL/cred issue)": "s3-backup-target-unavailable-regional-outage-or-acl-cred-issue.md",
		"Backups complete but are non\u2011restorable (silent failure)":    "backups-complete-but-are-non-restorable-silent-failure.md",
		"Kubernetes control plane outage (API server down)":                "kubernetes-control-plane-outage-api-server-down.md",
		"Ransomware on VMware hosts (storage encrypted)":                   "ransomware-on-vmware-hosts-storage-encrypted.md",
		"Credential compromise (DB or S3 keys)":                            "credential-compromise-db-or-s3-keys.md",
		"Ingress/VIP failure (HAProxy/ProxySQL service unreachable)":       "ingress-vip-failure.md",
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
	env := r.URL.Query().Get("env")
	if env == "" {
		env = "eks"
	}

	envScenarios, ok := scenarios[env]
	if !ok {
		http.Error(w, "Environment not found", http.StatusNotFound)
		return
	}

	response := ScenarioResponse{
		Environment: env,
		Scenarios:   envScenarios,
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
	env := r.URL.Query().Get("env")
	filename := r.URL.Query().Get("file")

	if env == "" || filename == "" {
		http.Error(w, "Missing env or file parameter", http.StatusBadRequest)
		return
	}

	// Security: prevent directory traversal attacks
	if strings.Contains(filename, "..") || strings.Contains(filename, "/") {
		http.Error(w, "Invalid filename", http.StatusBadRequest)
		return
	}

	mdPath := filepath.Join("recovery_processes", env, filename)
	content, err := os.ReadFile(mdPath)
	if err != nil {
		http.Error(w, "Recovery process not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "text/markdown")
	if _, err := w.Write(content); err != nil {
		log.Printf("Error writing response: %v", err)
	}
}
