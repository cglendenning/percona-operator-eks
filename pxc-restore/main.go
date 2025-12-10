package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Backup represents a PXC backup resource
type Backup struct {
	Name                  string    `json:"name"`
	State                 string    `json:"state"`
	Completed             string    `json:"completed"`
	CompletedTime         time.Time `json:"completedTime,omitempty"`
	Storage               string    `json:"storage"`
	Destination           string    `json:"destination"`
	PITRReady             bool      `json:"pitrReady"`
	LatestRestorableTime  string    `json:"latestRestorableTime"`
	LatestRestorableTimeT time.Time `json:"latestRestorableTimeT,omitempty"`
	ClusterName           string    `json:"clusterName"`
}

// BackupListResponse contains all backups and restorable time range
type BackupListResponse struct {
	Namespace              string   `json:"namespace"`
	ClusterName            string   `json:"clusterName"`
	Backups                []Backup `json:"backups"`
	EarliestRestorableTime string   `json:"earliestRestorableTime"`
	LatestRestorableTime   string   `json:"latestRestorableTime"`
	TimeFormat             string   `json:"timeFormat"`
	Message                string   `json:"message,omitempty"`
}

// NamespaceCheckResponse contains namespace validation info
type NamespaceCheckResponse struct {
	Namespace string `json:"namespace"`
	Exists    bool   `json:"exists"`
	HasPXC    bool   `json:"hasPxc"`
	Message   string `json:"message"`
}

// RestoreRequest contains the restore parameters
type RestoreRequest struct {
	SourceNamespace string `json:"sourceNamespace"`
	TargetNamespace string `json:"targetNamespace"`
	BackupName      string `json:"backupName"`
	RestoreTime     string `json:"restoreTime"`
	CreateNamespace bool   `json:"createNamespace"`
}

// RestoreResponse contains restore operation result
type RestoreResponse struct {
	Success     bool            `json:"success"`
	Message     string          `json:"message"`
	RestoreName string          `json:"restoreName,omitempty"`
	ClusterName string          `json:"clusterName,omitempty"`
	RestoreTime string          `json:"restoreTime,omitempty"`
	Summary     *RestoreSummary `json:"summary,omitempty"`
}

// RestoreSummary contains database/table summary after restore
type RestoreSummary struct {
	RestoredTo  string         `json:"restoredTo"`
	ClusterName string         `json:"clusterName"`
	Namespace   string         `json:"namespace"`
	Databases   []DatabaseInfo `json:"databases"`
	TotalTables int            `json:"totalTables"`
}

// DatabaseInfo contains database name and table count
type DatabaseInfo struct {
	Name       string `json:"name"`
	TableCount int    `json:"tableCount"`
}

// RestoreStatusResponse contains status of a restore operation
type RestoreStatusResponse struct {
	Name      string `json:"name"`
	State     string `json:"state"`
	Completed bool   `json:"completed"`
	Message   string `json:"message"`
}

// PXCClusterSpec simplified for cloning
type PXCClusterSpec struct {
	Name      string          `json:"name"`
	Namespace string          `json:"namespace"`
	Spec      json.RawMessage `json:"spec"`
}

var kubeconfig string

func init() {
	kubeconfig = os.Getenv("KUBECONFIG")
}

// kubectl runs a kubectl command and returns output
func kubectl(args ...string) (string, error) {
	var cmdArgs []string
	if kubeconfig != "" {
		cmdArgs = append(cmdArgs, "--kubeconfig", kubeconfig)
	}
	cmdArgs = append(cmdArgs, args...)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", cmdArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("%v: %s", err, stderr.String())
	}
	return strings.TrimSpace(stdout.String()), nil
}

// mysqlExec runs a mysql command inside the cluster
func mysqlExec(namespace, clusterName, query string) (string, error) {
	// Get the MySQL root password from secret
	secretName := fmt.Sprintf("%s-secrets", clusterName)
	password, err := kubectl("get", "secret", secretName, "-n", namespace,
		"-o", "jsonpath={.data.root}", "--ignore-not-found")
	if err != nil {
		return "", fmt.Errorf("failed to get root password: %v", err)
	}
	if password == "" {
		return "", fmt.Errorf("root password not found in secret %s", secretName)
	}

	// Decode base64 password
	decoded, err := kubectl("run", "decode-tmp", "--rm", "-i", "--restart=Never",
		"--image=busybox", "-n", namespace, "--",
		"sh", "-c", fmt.Sprintf("echo %s | base64 -d", password))
	if err != nil {
		// Alternative: use bash
		cmd := exec.Command("bash", "-c", fmt.Sprintf("echo %s | base64 -d", password))
		out, err := cmd.Output()
		if err != nil {
			return "", fmt.Errorf("failed to decode password: %v", err)
		}
		decoded = strings.TrimSpace(string(out))
	}

	// Find a running PXC pod
	podName := fmt.Sprintf("%s-pxc-0", clusterName)

	// Execute mysql query
	mysqlCmd := fmt.Sprintf("mysql -uroot -p'%s' -N -e \"%s\"", decoded, query)
	output, err := kubectl("exec", "-n", namespace, podName, "-c", "pxc", "--",
		"sh", "-c", mysqlCmd)
	if err != nil {
		return "", fmt.Errorf("mysql query failed: %v", err)
	}
	return output, nil
}

func main() {
	// Setup HTTP handlers
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/api/backups", handleListBackups)
	http.HandleFunc("/api/namespace/check", handleCheckNamespace)
	http.HandleFunc("/api/namespace/create", handleCreateNamespace)
	http.HandleFunc("/api/restore", handleRestore)
	http.HandleFunc("/api/restore/status", handleRestoreStatus)
	http.HandleFunc("/api/restore/summary", handleRestoreSummary)
	http.HandleFunc("/api/cluster/status", handleClusterStatus)
	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("./static"))))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}

	log.Printf("PXC Restore Service starting on port %s", port)
	log.Printf("Open http://localhost:%s in your browser", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, "./static/index.html")
}

// handleListBackups returns all backups in a namespace with restorable time window
func handleListBackups(w http.ResponseWriter, r *http.Request) {
	namespace := r.URL.Query().Get("namespace")
	if namespace == "" {
		http.Error(w, "namespace parameter required", http.StatusBadRequest)
		return
	}

	// Get PXC cluster name
	clusterName, err := kubectl("get", "perconaxtradbcluster", "-n", namespace,
		"-o", "jsonpath={.items[0].metadata.name}")
	if err != nil || clusterName == "" {
		sendJSON(w, BackupListResponse{
			Namespace: namespace,
			Message:   "No PXC cluster found in namespace",
		})
		return
	}

	// Get all backups
	backupsJSON, err := kubectl("get", "perconaxtradbclusterbackup", "-n", namespace, "-o", "json")
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to get backups: %v", err), http.StatusInternalServerError)
		return
	}

	var backupList struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				PxcCluster  string `json:"pxcCluster"`
				StorageName string `json:"storageName"`
			} `json:"spec"`
			Status struct {
				State                string `json:"state"`
				Completed            string `json:"completed"`
				Destination          string `json:"destination"`
				LatestRestorableTime string `json:"latestRestorableTime"`
				Conditions           []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}

	if err := json.Unmarshal([]byte(backupsJSON), &backupList); err != nil {
		http.Error(w, fmt.Sprintf("Failed to parse backups: %v", err), http.StatusInternalServerError)
		return
	}

	var backups []Backup
	var earliestTime, latestTime time.Time

	for _, item := range backupList.Items {
		if item.Status.State != "Succeeded" && item.Status.State != "Ready" {
			continue
		}

		pitrReady := false
		for _, cond := range item.Status.Conditions {
			if cond.Type == "PITRReady" && cond.Status == "True" {
				pitrReady = true
				break
			}
		}

		backup := Backup{
			Name:                 item.Metadata.Name,
			State:                item.Status.State,
			Completed:            item.Status.Completed,
			Storage:              item.Spec.StorageName,
			Destination:          item.Status.Destination,
			PITRReady:            pitrReady,
			LatestRestorableTime: item.Status.LatestRestorableTime,
			ClusterName:          item.Spec.PxcCluster,
		}

		// Parse completed time (earliest restorable)
		if item.Status.Completed != "" {
			if t, err := time.Parse(time.RFC3339, item.Status.Completed); err == nil {
				backup.CompletedTime = t
				if earliestTime.IsZero() || t.Before(earliestTime) {
					earliestTime = t
				}
			}
		}

		// Parse latest restorable time
		if item.Status.LatestRestorableTime != "" {
			if t, err := time.Parse(time.RFC3339, item.Status.LatestRestorableTime); err == nil {
				backup.LatestRestorableTimeT = t
				if latestTime.IsZero() || t.After(latestTime) {
					latestTime = t
				}
			}
		}

		backups = append(backups, backup)
	}

	// Sort by completed time descending
	sort.Slice(backups, func(i, j int) bool {
		return backups[i].CompletedTime.After(backups[j].CompletedTime)
	})

	response := BackupListResponse{
		Namespace:   namespace,
		ClusterName: clusterName,
		Backups:     backups,
		TimeFormat:  "YYYY-MM-DD HH:MM:SS (UTC)",
	}

	if !earliestTime.IsZero() {
		response.EarliestRestorableTime = earliestTime.UTC().Format("2006-01-02 15:04:05")
	}
	if !latestTime.IsZero() {
		response.LatestRestorableTime = latestTime.UTC().Format("2006-01-02 15:04:05")
	}

	sendJSON(w, response)
}

// handleCheckNamespace validates a target namespace
func handleCheckNamespace(w http.ResponseWriter, r *http.Request) {
	namespace := r.URL.Query().Get("namespace")
	if namespace == "" {
		http.Error(w, "namespace parameter required", http.StatusBadRequest)
		return
	}

	response := NamespaceCheckResponse{
		Namespace: namespace,
	}

	// Check if namespace exists
	_, err := kubectl("get", "namespace", namespace)
	if err != nil {
		response.Exists = false
		response.Message = "Namespace does not exist"
		sendJSON(w, response)
		return
	}
	response.Exists = true

	// Check if there's already a PXC cluster
	clusters, err := kubectl("get", "perconaxtradbcluster", "-n", namespace, "-o", "jsonpath={.items[*].metadata.name}")
	if err == nil && clusters != "" {
		response.HasPXC = true
		response.Message = fmt.Sprintf("Warning: Namespace already contains PXC cluster(s): %s", clusters)
	} else {
		response.HasPXC = false
		response.Message = "Namespace exists and has no PXC cluster"
	}

	sendJSON(w, response)
}

// handleCreateNamespace creates a new namespace
func handleCreateNamespace(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Namespace string `json:"namespace"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if req.Namespace == "" {
		http.Error(w, "namespace required", http.StatusBadRequest)
		return
	}

	// Validate namespace name
	validName := regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	if !validName.MatchString(req.Namespace) {
		http.Error(w, "Invalid namespace name (must be lowercase alphanumeric with hyphens)", http.StatusBadRequest)
		return
	}

	_, err := kubectl("create", "namespace", req.Namespace)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to create namespace: %v", err), http.StatusInternalServerError)
		return
	}

	sendJSON(w, map[string]interface{}{
		"success":   true,
		"namespace": req.Namespace,
		"message":   "Namespace created successfully",
	})
}

// handleRestore initiates a PXC cluster restore
func handleRestore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	var req RestoreRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate required fields
	if req.SourceNamespace == "" || req.TargetNamespace == "" || req.BackupName == "" || req.RestoreTime == "" {
		http.Error(w, "sourceNamespace, targetNamespace, backupName, and restoreTime are required", http.StatusBadRequest)
		return
	}

	// Check target namespace
	_, err := kubectl("get", "namespace", req.TargetNamespace)
	if err != nil {
		if req.CreateNamespace {
			_, err = kubectl("create", "namespace", req.TargetNamespace)
			if err != nil {
				sendJSON(w, RestoreResponse{
					Success: false,
					Message: fmt.Sprintf("Failed to create namespace: %v", err),
				})
				return
			}
		} else {
			sendJSON(w, RestoreResponse{
				Success: false,
				Message: "Target namespace does not exist. Set createNamespace=true to create it.",
			})
			return
		}
	}

	// Get source cluster spec
	sourceClusterName, err := kubectl("get", "perconaxtradbcluster", "-n", req.SourceNamespace,
		"-o", "jsonpath={.items[0].metadata.name}")
	if err != nil || sourceClusterName == "" {
		sendJSON(w, RestoreResponse{
			Success: false,
			Message: "No PXC cluster found in source namespace",
		})
		return
	}

	// Get source cluster full spec
	sourceClusterJSON, err := kubectl("get", "perconaxtradbcluster", sourceClusterName,
		"-n", req.SourceNamespace, "-o", "json")
	if err != nil {
		sendJSON(w, RestoreResponse{
			Success: false,
			Message: fmt.Sprintf("Failed to get source cluster spec: %v", err),
		})
		return
	}

	// Create new cluster in target namespace
	targetClusterName := fmt.Sprintf("%s-restored", sourceClusterName)
	err = createTargetCluster(req.TargetNamespace, targetClusterName, sourceClusterJSON, req.SourceNamespace)
	if err != nil {
		sendJSON(w, RestoreResponse{
			Success: false,
			Message: fmt.Sprintf("Failed to create target cluster: %v", err),
		})
		return
	}

	// Wait for operator to create initial cluster (give it a moment)
	log.Printf("Waiting for target cluster %s to be created in namespace %s", targetClusterName, req.TargetNamespace)
	time.Sleep(5 * time.Second)

	// Parse restore time
	restoreTimeFormatted, err := parseRestoreTime(req.RestoreTime)
	if err != nil {
		sendJSON(w, RestoreResponse{
			Success: false,
			Message: fmt.Sprintf("Invalid restore time format: %v. Expected format: YYYY-MM-DD HH:MM:SS", err),
		})
		return
	}

	// Create restore resource
	restoreName := fmt.Sprintf("restore-%s-%d", targetClusterName, time.Now().Unix())
	err = createRestoreResource(req.TargetNamespace, restoreName, targetClusterName, req.BackupName, restoreTimeFormatted, req.SourceNamespace)
	if err != nil {
		sendJSON(w, RestoreResponse{
			Success: false,
			Message: fmt.Sprintf("Failed to create restore resource: %v", err),
		})
		return
	}

	sendJSON(w, RestoreResponse{
		Success:     true,
		Message:     "Restore initiated successfully. Monitor status via /api/restore/status",
		RestoreName: restoreName,
		ClusterName: targetClusterName,
		RestoreTime: restoreTimeFormatted,
	})
}

// createTargetCluster creates a new PXC cluster based on source spec
func createTargetCluster(targetNamespace, targetClusterName, sourceClusterJSON, sourceNamespace string) error {
	var sourceCluster map[string]interface{}
	if err := json.Unmarshal([]byte(sourceClusterJSON), &sourceCluster); err != nil {
		return fmt.Errorf("failed to parse source cluster: %v", err)
	}

	// Modify for target
	metadata := sourceCluster["metadata"].(map[string]interface{})
	metadata["name"] = targetClusterName
	metadata["namespace"] = targetNamespace
	delete(metadata, "resourceVersion")
	delete(metadata, "uid")
	delete(metadata, "creationTimestamp")
	delete(metadata, "generation")
	delete(metadata, "managedFields")

	// Remove status
	delete(sourceCluster, "status")

	// Update spec if needed - ensure secrets reference is handled
	spec := sourceCluster["spec"].(map[string]interface{})

	// Copy secrets from source namespace to target namespace
	if secretsRef, ok := spec["secretsName"].(string); ok {
		err := copySecret(sourceNamespace, targetNamespace, secretsRef)
		if err != nil {
			log.Printf("Warning: could not copy secrets %s: %v", secretsRef, err)
		}
	} else {
		// Try default secret name
		defaultSecretName := fmt.Sprintf("%s-secrets", strings.TrimSuffix(targetClusterName, "-restored"))
		err := copySecret(sourceNamespace, targetNamespace, defaultSecretName)
		if err != nil {
			log.Printf("Warning: could not copy default secrets %s: %v", defaultSecretName, err)
		}
	}

	// Copy backup credentials secret if present
	if backup, ok := spec["backup"].(map[string]interface{}); ok {
		if storages, ok := backup["storages"].(map[string]interface{}); ok {
			for _, storage := range storages {
				if s, ok := storage.(map[string]interface{}); ok {
					if s3, ok := s["s3"].(map[string]interface{}); ok {
						if credSecret, ok := s3["credentialsSecret"].(string); ok {
							err := copySecret(sourceNamespace, targetNamespace, credSecret)
							if err != nil {
								log.Printf("Warning: could not copy backup credentials %s: %v", credSecret, err)
							}
						}
					}
				}
			}
		}
	}

	// Create target cluster
	clusterYAML, err := json.Marshal(sourceCluster)
	if err != nil {
		return fmt.Errorf("failed to marshal cluster spec: %v", err)
	}

	// Write to temp file and apply
	tmpFile := filepath.Join(os.TempDir(), fmt.Sprintf("pxc-cluster-%s.json", targetClusterName))
	if err := os.WriteFile(tmpFile, clusterYAML, 0644); err != nil {
		return fmt.Errorf("failed to write temp file: %v", err)
	}
	defer os.Remove(tmpFile)

	_, err = kubectl("apply", "-f", tmpFile)
	if err != nil {
		return fmt.Errorf("failed to create cluster: %v", err)
	}

	return nil
}

// copySecret copies a secret from source to target namespace
func copySecret(sourceNS, targetNS, secretName string) error {
	// Get secret from source
	secretJSON, err := kubectl("get", "secret", secretName, "-n", sourceNS, "-o", "json")
	if err != nil {
		return err
	}

	var secret map[string]interface{}
	if err := json.Unmarshal([]byte(secretJSON), &secret); err != nil {
		return err
	}

	// Modify for target namespace
	metadata := secret["metadata"].(map[string]interface{})
	metadata["namespace"] = targetNS
	delete(metadata, "resourceVersion")
	delete(metadata, "uid")
	delete(metadata, "creationTimestamp")
	delete(metadata, "managedFields")

	// Write and apply
	secretYAML, err := json.Marshal(secret)
	if err != nil {
		return err
	}

	tmpFile := filepath.Join(os.TempDir(), fmt.Sprintf("secret-%s.json", secretName))
	if err := os.WriteFile(tmpFile, secretYAML, 0644); err != nil {
		return err
	}
	defer os.Remove(tmpFile)

	_, err = kubectl("apply", "-f", tmpFile)
	return err
}

// parseRestoreTime converts various time formats to RFC3339
func parseRestoreTime(input string) (string, error) {
	// Try various formats
	formats := []string{
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05",
		time.RFC3339,
	}

	var t time.Time
	var err error
	for _, format := range formats {
		t, err = time.Parse(format, input)
		if err == nil {
			break
		}
	}

	if err != nil {
		return "", err
	}

	return t.UTC().Format("2006-01-02 15:04:05"), nil
}

// createRestoreResource creates a PerconaXtraDBClusterRestore resource
func createRestoreResource(namespace, restoreName, clusterName, backupName, restoreTime, sourceNamespace string) error {
	// Get backup storage info
	backupJSON, err := kubectl("get", "perconaxtradbclusterbackup", backupName, "-n", sourceNamespace, "-o", "json")
	if err != nil {
		return fmt.Errorf("failed to get backup info: %v", err)
	}

	var backup struct {
		Spec struct {
			StorageName string `json:"storageName"`
		} `json:"spec"`
	}
	if err := json.Unmarshal([]byte(backupJSON), &backup); err != nil {
		return fmt.Errorf("failed to parse backup: %v", err)
	}

	restoreYAML := fmt.Sprintf(`apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterRestore
metadata:
  name: %s
  namespace: %s
spec:
  pxcCluster: %s
  backupName: %s
  pitr:
    type: date
    date: "%s"
    backupSource:
      storageName: %s
`, restoreName, namespace, clusterName, backupName, restoreTime, backup.Spec.StorageName)

	tmpFile := filepath.Join(os.TempDir(), fmt.Sprintf("restore-%s.yaml", restoreName))
	if err := os.WriteFile(tmpFile, []byte(restoreYAML), 0644); err != nil {
		return fmt.Errorf("failed to write restore yaml: %v", err)
	}
	defer os.Remove(tmpFile)

	_, err = kubectl("apply", "-f", tmpFile)
	return err
}

// handleRestoreStatus returns status of a restore operation
func handleRestoreStatus(w http.ResponseWriter, r *http.Request) {
	namespace := r.URL.Query().Get("namespace")
	name := r.URL.Query().Get("name")

	if namespace == "" || name == "" {
		http.Error(w, "namespace and name parameters required", http.StatusBadRequest)
		return
	}

	statusJSON, err := kubectl("get", "perconaxtradbclusterrestore", name, "-n", namespace, "-o", "json")
	if err != nil {
		sendJSON(w, RestoreStatusResponse{
			Name:    name,
			State:   "Unknown",
			Message: fmt.Sprintf("Failed to get restore status: %v", err),
		})
		return
	}

	var restore struct {
		Status struct {
			State     string `json:"state"`
			Completed bool   `json:"completed"`
			Comments  string `json:"comments"`
		} `json:"status"`
	}
	if err := json.Unmarshal([]byte(statusJSON), &restore); err != nil {
		http.Error(w, fmt.Sprintf("Failed to parse restore status: %v", err), http.StatusInternalServerError)
		return
	}

	sendJSON(w, RestoreStatusResponse{
		Name:      name,
		State:     restore.Status.State,
		Completed: restore.Status.State == "Succeeded" || restore.Status.State == "Ready",
		Message:   restore.Status.Comments,
	})
}

// handleRestoreSummary returns a summary of the restored database
func handleRestoreSummary(w http.ResponseWriter, r *http.Request) {
	namespace := r.URL.Query().Get("namespace")
	clusterName := r.URL.Query().Get("cluster")

	if namespace == "" || clusterName == "" {
		http.Error(w, "namespace and cluster parameters required", http.StatusBadRequest)
		return
	}

	// Check cluster is ready
	status, err := kubectl("get", "perconaxtradbcluster", clusterName, "-n", namespace,
		"-o", "jsonpath={.status.state}")
	if err != nil {
		sendJSON(w, RestoreSummary{
			ClusterName: clusterName,
			Namespace:   namespace,
			RestoredTo:  "Cluster not ready",
		})
		return
	}

	if status != "ready" {
		sendJSON(w, RestoreSummary{
			ClusterName: clusterName,
			Namespace:   namespace,
			RestoredTo:  fmt.Sprintf("Cluster status: %s (waiting for ready)", status),
		})
		return
	}

	// Get database list
	databases, err := getDatabaseSummary(namespace, clusterName)
	if err != nil {
		sendJSON(w, RestoreSummary{
			ClusterName: clusterName,
			Namespace:   namespace,
			RestoredTo:  fmt.Sprintf("Error getting database info: %v", err),
		})
		return
	}

	totalTables := 0
	for _, db := range databases {
		totalTables += db.TableCount
	}

	sendJSON(w, RestoreSummary{
		ClusterName: clusterName,
		Namespace:   namespace,
		RestoredTo:  time.Now().UTC().Format("2006-01-02 15:04:05 UTC"),
		Databases:   databases,
		TotalTables: totalTables,
	})
}

// getDatabaseSummary gets database and table counts from MySQL
func getDatabaseSummary(namespace, clusterName string) ([]DatabaseInfo, error) {
	// Get the MySQL root password from secret
	secretName := fmt.Sprintf("%s-secrets", clusterName)
	password, err := kubectl("get", "secret", secretName, "-n", namespace,
		"-o", "jsonpath={.data.root}")
	if err != nil {
		return nil, fmt.Errorf("failed to get root password: %v", err)
	}

	// Decode base64 password
	cmd := exec.Command("bash", "-c", fmt.Sprintf("echo %s | base64 -d", password))
	decoded, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to decode password: %v", err)
	}
	decodedPwd := strings.TrimSpace(string(decoded))

	// Find a running PXC pod
	podName := fmt.Sprintf("%s-pxc-0", clusterName)

	// Get database list
	dbQuery := "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')"
	mysqlCmd := fmt.Sprintf("mysql -uroot -p'%s' -N -e \"%s\"", decodedPwd, dbQuery)
	dbOutput, err := kubectl("exec", "-n", namespace, podName, "-c", "pxc", "--",
		"sh", "-c", mysqlCmd)
	if err != nil {
		return nil, fmt.Errorf("failed to get databases: %v", err)
	}

	var databases []DatabaseInfo
	dbNames := strings.Split(strings.TrimSpace(dbOutput), "\n")

	for _, dbName := range dbNames {
		dbName = strings.TrimSpace(dbName)
		if dbName == "" {
			continue
		}

		// Get table count for each database
		tableQuery := fmt.Sprintf("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '%s'", dbName)
		mysqlCmd := fmt.Sprintf("mysql -uroot -p'%s' -N -e \"%s\"", decodedPwd, tableQuery)
		tableOutput, err := kubectl("exec", "-n", namespace, podName, "-c", "pxc", "--",
			"sh", "-c", mysqlCmd)
		if err != nil {
			log.Printf("Warning: could not get table count for %s: %v", dbName, err)
			databases = append(databases, DatabaseInfo{Name: dbName, TableCount: -1})
			continue
		}

		var tableCount int
		fmt.Sscanf(strings.TrimSpace(tableOutput), "%d", &tableCount)
		databases = append(databases, DatabaseInfo{Name: dbName, TableCount: tableCount})
	}

	return databases, nil
}

// handleClusterStatus returns status of a PXC cluster
func handleClusterStatus(w http.ResponseWriter, r *http.Request) {
	namespace := r.URL.Query().Get("namespace")
	clusterName := r.URL.Query().Get("cluster")

	if namespace == "" || clusterName == "" {
		http.Error(w, "namespace and cluster parameters required", http.StatusBadRequest)
		return
	}

	status, err := kubectl("get", "perconaxtradbcluster", clusterName, "-n", namespace,
		"-o", "jsonpath={.status.state}")
	if err != nil {
		sendJSON(w, map[string]interface{}{
			"cluster":   clusterName,
			"namespace": namespace,
			"state":     "error",
			"message":   err.Error(),
		})
		return
	}

	pxcReady, _ := kubectl("get", "perconaxtradbcluster", clusterName, "-n", namespace,
		"-o", "jsonpath={.status.pxc.ready}")
	pxcSize, _ := kubectl("get", "perconaxtradbcluster", clusterName, "-n", namespace,
		"-o", "jsonpath={.status.pxc.size}")

	sendJSON(w, map[string]interface{}{
		"cluster":   clusterName,
		"namespace": namespace,
		"state":     status,
		"pxcReady":  pxcReady,
		"pxcSize":   pxcSize,
	})
}

func sendJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON response: %v", err)
	}
}
