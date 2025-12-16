package main

import (
	"context"
	"database/sql"
	"encoding/csv"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/fatih/color"
	_ "github.com/go-sql-driver/mysql"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

// Config holds all configuration for the monitor
type Config struct {
	// Proxy connection (HAProxy or ProxySQL)
	ProxyHost     string
	ProxyPort     int
	ProxyUser     string
	ProxyPassword string
	Database      string

	// HAProxy stats
	HAProxyStatsURL      string
	HAProxyStatsUser     string
	HAProxyStatsPassword string

	// ProxySQL admin
	ProxySQLAdminHost     string
	ProxySQLAdminPort     int
	ProxySQLAdminUser     string
	ProxySQLAdminPassword string

	// PXC nodes (for direct monitoring)
	PXCNodes    []string
	PXCUser     string
	PXCPassword string

	// Pool settings (HikariCP-like)
	PoolSize           int
	MinIdle            int
	MaxLifetime        time.Duration
	IdleTimeout        time.Duration
	ConnectionTimeout  time.Duration
	ValidationInterval time.Duration

	// Workload settings
	ReadQPS       int
	WriteQPS      int
	QueryInterval time.Duration

	// Mode
	UseProxySQL bool
	Verbose     bool
}

// ConnectionStats tracks connection-level statistics
type ConnectionStats struct {
	mu sync.RWMutex

	TotalConnections  int64
	ActiveConnections int64
	IdleConnections   int64
	FailedConnections int64
	ReconnectAttempts int64

	TotalReads   int64
	TotalWrites  int64
	FailedReads  int64
	FailedWrites int64

	LastReadLatency  time.Duration
	LastWriteLatency time.Duration
	AvgReadLatency   time.Duration
	AvgWriteLatency  time.Duration

	ConnectionErrors []ConnectionError
	LastBackendNode  string
}

type ConnectionError struct {
	Timestamp time.Time
	Operation string
	Error     string
	Node      string
}

// HAProxyBackend represents a backend server in HAProxy
type HAProxyBackend struct {
	Name        string
	Status      string
	Addr        string
	CurrentConn int
	MaxConn     int
	Sessions    int
	CheckStatus string
	LastChange  string
	Downtime    string
}

// ProxySQLServer represents a MySQL server in ProxySQL
type ProxySQLServer struct {
	HostgroupID  int
	Hostname     string
	Port         int
	Status       string
	Weight       int
	Compression  int
	MaxConns     int
	UsedConns    int
	FreeConns    int
	MaxLatencyMs int
	Comment      string
}

// ProxySQLConnPool represents connection pool stats from ProxySQL
type ProxySQLConnPool struct {
	HostgroupID   int
	SrvHost       string
	SrvPort       int
	Status        string
	ConnUsed      int
	ConnFree      int
	ConnOK        int
	ConnErr       int
	Queries       int64
	BytesDataSent int64
	BytesDataRecv int64
	LatencyUs     int64
}

// PXCNodeStatus represents wsrep status of a PXC node
type PXCNodeStatus struct {
	NodeName       string
	Address        string
	ClusterStatus  string
	ClusterSize    int
	LocalState     string
	LocalStateUUID string
	ReadyStatus    string
	Connected      string
	DesyncCount    int
	RecvQueue      int
	SendQueue      int
	FlowControl    string
	Connections    int
}

var (
	cfg   Config
	stats ConnectionStats
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "connpool-monitor",
		Short: "Monitor HikariCP-like connection pool behavior through HAProxy/ProxySQL to PXC",
		Long: `A diagnostic tool to observe connection pool behavior when connecting
to Percona XtraDB Cluster through HAProxy or ProxySQL.

This tool helps identify connection issues during pod rolling updates,
network partitions, or proxy failovers by showing the full connection path.`,
		Run: runMonitor,
	}

	// Proxy connection flags
	rootCmd.Flags().StringVar(&cfg.ProxyHost, "proxy-host", "localhost", "Proxy host (HAProxy or ProxySQL)")
	rootCmd.Flags().IntVar(&cfg.ProxyPort, "proxy-port", 3306, "Proxy port")
	rootCmd.Flags().StringVar(&cfg.ProxyUser, "proxy-user", "root", "MySQL user")
	rootCmd.Flags().StringVar(&cfg.ProxyPassword, "proxy-password", "", "MySQL password")
	rootCmd.Flags().StringVar(&cfg.Database, "database", "test", "Database name")

	// HAProxy stats flags
	rootCmd.Flags().StringVar(&cfg.HAProxyStatsURL, "haproxy-stats-url", "http://localhost:8404/stats", "HAProxy stats URL")
	rootCmd.Flags().StringVar(&cfg.HAProxyStatsUser, "haproxy-stats-user", "", "HAProxy stats user")
	rootCmd.Flags().StringVar(&cfg.HAProxyStatsPassword, "haproxy-stats-password", "", "HAProxy stats password")

	// ProxySQL admin flags
	rootCmd.Flags().StringVar(&cfg.ProxySQLAdminHost, "proxysql-admin-host", "localhost", "ProxySQL admin host")
	rootCmd.Flags().IntVar(&cfg.ProxySQLAdminPort, "proxysql-admin-port", 6032, "ProxySQL admin port")
	rootCmd.Flags().StringVar(&cfg.ProxySQLAdminUser, "proxysql-admin-user", "admin", "ProxySQL admin user")
	rootCmd.Flags().StringVar(&cfg.ProxySQLAdminPassword, "proxysql-admin-password", "admin", "ProxySQL admin password")

	// PXC node flags
	rootCmd.Flags().StringSliceVar(&cfg.PXCNodes, "pxc-nodes", []string{}, "PXC node addresses (comma-separated, e.g., node1:3306,node2:3306)")
	rootCmd.Flags().StringVar(&cfg.PXCUser, "pxc-user", "", "PXC direct user (defaults to proxy-user)")
	rootCmd.Flags().StringVar(&cfg.PXCPassword, "pxc-password", "", "PXC direct password (defaults to proxy-password)")

	// Pool settings
	rootCmd.Flags().IntVar(&cfg.PoolSize, "pool-size", 10, "Connection pool size (like HikariCP maximumPoolSize)")
	rootCmd.Flags().IntVar(&cfg.MinIdle, "min-idle", 2, "Minimum idle connections (like HikariCP minimumIdle)")
	rootCmd.Flags().DurationVar(&cfg.MaxLifetime, "max-lifetime", 30*time.Minute, "Maximum connection lifetime (like HikariCP maxLifetime)")
	rootCmd.Flags().DurationVar(&cfg.IdleTimeout, "idle-timeout", 10*time.Minute, "Idle connection timeout (like HikariCP idleTimeout)")
	rootCmd.Flags().DurationVar(&cfg.ConnectionTimeout, "connection-timeout", 30*time.Second, "Connection timeout (like HikariCP connectionTimeout)")
	rootCmd.Flags().DurationVar(&cfg.ValidationInterval, "validation-interval", 5*time.Second, "Connection validation interval")

	// Workload settings
	rootCmd.Flags().IntVar(&cfg.ReadQPS, "read-qps", 10, "Read queries per second")
	rootCmd.Flags().IntVar(&cfg.WriteQPS, "write-qps", 2, "Write queries per second")

	// Mode
	rootCmd.Flags().BoolVar(&cfg.UseProxySQL, "proxysql", false, "Use ProxySQL mode instead of HAProxy")
	rootCmd.Flags().BoolVar(&cfg.Verbose, "verbose", false, "Verbose output")

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func runMonitor(cmd *cobra.Command, args []string) {
	// Set defaults for PXC credentials
	if cfg.PXCUser == "" {
		cfg.PXCUser = cfg.ProxyUser
	}
	if cfg.PXCPassword == "" {
		cfg.PXCPassword = cfg.ProxyPassword
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nShutting down...")
		cancel()
	}()

	// Create connection pool
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%d)/%s?timeout=%s&readTimeout=10s&writeTimeout=10s",
		cfg.ProxyUser, cfg.ProxyPassword, cfg.ProxyHost, cfg.ProxyPort, cfg.Database,
		cfg.ConnectionTimeout.String())

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		color.Red("Failed to create connection pool: %v", err)
		os.Exit(1)
	}
	defer db.Close()

	// Configure pool (HikariCP-like settings)
	db.SetMaxOpenConns(cfg.PoolSize)
	db.SetMaxIdleConns(cfg.MinIdle)
	db.SetConnMaxLifetime(cfg.MaxLifetime)
	db.SetConnMaxIdleTime(cfg.IdleTimeout)

	// Ensure test table exists
	if err := ensureTestTable(ctx, db); err != nil {
		color.Red("Failed to create test table: %v", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup

	// Start workload generator
	wg.Add(1)
	go func() {
		defer wg.Done()
		runWorkload(ctx, db)
	}()

	// Start monitoring display
	wg.Add(1)
	go func() {
		defer wg.Done()
		runMonitorDisplay(ctx, db)
	}()

	wg.Wait()
}

func ensureTestTable(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS connpool_test (
			id INT AUTO_INCREMENT PRIMARY KEY,
			data VARCHAR(255),
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		)
	`)
	return err
}

func runWorkload(ctx context.Context, db *sql.DB) {
	readTicker := time.NewTicker(time.Second / time.Duration(cfg.ReadQPS))
	writeTicker := time.NewTicker(time.Second / time.Duration(cfg.WriteQPS))
	defer readTicker.Stop()
	defer writeTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-readTicker.C:
			go executeRead(ctx, db)
		case <-writeTicker.C:
			go executeWrite(ctx, db)
		}
	}
}

func executeRead(ctx context.Context, db *sql.DB) {
	start := time.Now()

	// Get connection info first
	var connID int
	var backendHost string

	conn, err := db.Conn(ctx)
	if err != nil {
		recordError("read_conn", err, "")
		return
	}
	defer conn.Close()

	// Get connection ID and backend info
	err = conn.QueryRowContext(ctx, "SELECT CONNECTION_ID()").Scan(&connID)
	if err != nil {
		recordError("read_connid", err, "")
		return
	}

	// Try to get the backend host
	err = conn.QueryRowContext(ctx, "SELECT @@hostname").Scan(&backendHost)
	if err != nil {
		backendHost = "unknown"
	}

	// Execute read query
	rows, err := conn.QueryContext(ctx, "SELECT id, data FROM connpool_test ORDER BY id DESC LIMIT 10")
	if err != nil {
		recordError("read", err, backendHost)
		return
	}
	defer rows.Close()

	// Consume results
	for rows.Next() {
		var id int
		var data string
		rows.Scan(&id, &data)
	}

	latency := time.Since(start)

	stats.mu.Lock()
	stats.TotalReads++
	stats.LastReadLatency = latency
	stats.LastBackendNode = backendHost
	if stats.TotalReads > 0 {
		stats.AvgReadLatency = time.Duration((int64(stats.AvgReadLatency)*(stats.TotalReads-1) + int64(latency)) / stats.TotalReads)
	}
	stats.mu.Unlock()
}

func executeWrite(ctx context.Context, db *sql.DB) {
	start := time.Now()

	conn, err := db.Conn(ctx)
	if err != nil {
		recordError("write_conn", err, "")
		return
	}
	defer conn.Close()

	// Get backend host
	var backendHost string
	err = conn.QueryRowContext(ctx, "SELECT @@hostname").Scan(&backendHost)
	if err != nil {
		backendHost = "unknown"
	}

	// Execute write
	data := fmt.Sprintf("test-%d", time.Now().UnixNano())
	_, err = conn.ExecContext(ctx, "INSERT INTO connpool_test (data) VALUES (?)", data)
	if err != nil {
		recordError("write", err, backendHost)
		return
	}

	latency := time.Since(start)

	stats.mu.Lock()
	stats.TotalWrites++
	stats.LastWriteLatency = latency
	stats.LastBackendNode = backendHost
	if stats.TotalWrites > 0 {
		stats.AvgWriteLatency = time.Duration((int64(stats.AvgWriteLatency)*(stats.TotalWrites-1) + int64(latency)) / stats.TotalWrites)
	}
	stats.mu.Unlock()
}

func recordError(operation string, err error, node string) {
	stats.mu.Lock()
	defer stats.mu.Unlock()

	switch {
	case strings.HasPrefix(operation, "read"):
		stats.FailedReads++
	case strings.HasPrefix(operation, "write"):
		stats.FailedWrites++
	}
	stats.FailedConnections++

	connErr := ConnectionError{
		Timestamp: time.Now(),
		Operation: operation,
		Error:     err.Error(),
		Node:      node,
	}
	stats.ConnectionErrors = append(stats.ConnectionErrors, connErr)

	// Keep only last 100 errors
	if len(stats.ConnectionErrors) > 100 {
		stats.ConnectionErrors = stats.ConnectionErrors[len(stats.ConnectionErrors)-100:]
	}
}

func runMonitorDisplay(ctx context.Context, db *sql.DB) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	clearScreen()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			clearScreen()
			printHeader()
			printPoolStats(db)

			if cfg.UseProxySQL {
				printProxySQLStats(ctx)
			} else {
				printHAProxyStats()
			}

			printPXCStatus(ctx)
			printConnectionErrors()
			printFooter()
		}
	}
}

func clearScreen() {
	fmt.Print("\033[H\033[2J")
}

func printHeader() {
	bold := color.New(color.Bold)
	bold.Println("===============================================================================")
	bold.Println("  CONNECTION POOL MONITOR - HAProxy/ProxySQL to PXC Cluster")
	bold.Println("===============================================================================")
	fmt.Printf("  Mode: %s | Time: %s\n", getModeString(), time.Now().Format("15:04:05"))
	fmt.Println()
}

func getModeString() string {
	if cfg.UseProxySQL {
		return color.CyanString("ProxySQL")
	}
	return color.YellowString("HAProxy")
}

func printPoolStats(db *sql.DB) {
	bold := color.New(color.Bold)
	bold.Println("[CONNECTION POOL STATUS] (HikariCP-like)")
	fmt.Println(strings.Repeat("-", 79))

	dbStats := db.Stats()

	stats.mu.RLock()
	defer stats.mu.RUnlock()

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Metric", "Value", "Metric", "Value"})
	table.SetBorder(false)
	table.SetColumnSeparator("|")

	table.Append([]string{
		"Pool Size", fmt.Sprintf("%d/%d", dbStats.OpenConnections, cfg.PoolSize),
		"In Use", fmt.Sprintf("%d", dbStats.InUse),
	})
	table.Append([]string{
		"Idle", fmt.Sprintf("%d", dbStats.Idle),
		"Wait Count", fmt.Sprintf("%d", dbStats.WaitCount),
	})
	table.Append([]string{
		"Max Idle Closed", fmt.Sprintf("%d", dbStats.MaxIdleClosed),
		"Max Lifetime Closed", fmt.Sprintf("%d", dbStats.MaxLifetimeClosed),
	})
	table.Append([]string{
		"Total Reads", fmt.Sprintf("%d", stats.TotalReads),
		"Failed Reads", formatErrorCount(stats.FailedReads),
	})
	table.Append([]string{
		"Total Writes", fmt.Sprintf("%d", stats.TotalWrites),
		"Failed Writes", formatErrorCount(stats.FailedWrites),
	})
	table.Append([]string{
		"Avg Read Latency", stats.AvgReadLatency.String(),
		"Avg Write Latency", stats.AvgWriteLatency.String(),
	})
	table.Append([]string{
		"Last Backend", stats.LastBackendNode,
		"Wait Duration", dbStats.WaitDuration.String(),
	})

	table.Render()
	fmt.Println()
}

func formatErrorCount(count int64) string {
	if count > 0 {
		return color.RedString("%d", count)
	}
	return color.GreenString("%d", count)
}

func printHAProxyStats() {
	bold := color.New(color.Bold)
	bold.Println("[HAPROXY BACKEND STATUS]")
	fmt.Println(strings.Repeat("-", 79))

	backends, err := fetchHAProxyStats()
	if err != nil {
		color.Red("  Error fetching HAProxy stats: %v", err)
		fmt.Println()
		return
	}

	if len(backends) == 0 {
		color.Yellow("  No backends found. Check HAProxy stats URL: %s", cfg.HAProxyStatsURL)
		fmt.Println()
		return
	}

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Backend", "Status", "Address", "Curr Conn", "Sessions", "Check", "Last Change"})
	table.SetBorder(false)
	table.SetColumnSeparator("|")

	for _, b := range backends {
		status := b.Status
		if b.Status == "UP" {
			status = color.GreenString("UP")
		} else if b.Status == "DOWN" {
			status = color.RedString("DOWN")
		} else if b.Status == "MAINT" {
			status = color.YellowString("MAINT")
		}

		table.Append([]string{
			b.Name,
			status,
			b.Addr,
			fmt.Sprintf("%d/%d", b.CurrentConn, b.MaxConn),
			fmt.Sprintf("%d", b.Sessions),
			b.CheckStatus,
			b.LastChange,
		})
	}
	table.Render()
	fmt.Println()
}

func fetchHAProxyStats() ([]HAProxyBackend, error) {
	url := cfg.HAProxyStatsURL
	if !strings.Contains(url, ";csv") {
		if strings.Contains(url, "?") {
			url += "&csv"
		} else {
			url += ";csv"
		}
	}

	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	if cfg.HAProxyStatsUser != "" {
		req.SetBasicAuth(cfg.HAProxyStatsUser, cfg.HAProxyStatsPassword)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	reader := csv.NewReader(resp.Body)
	records, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}

	var backends []HAProxyBackend
	for i, record := range records {
		if i == 0 || len(record) < 80 {
			continue // Skip header
		}

		// Only include backend servers, not frontend or aggregates
		if record[1] != "FRONTEND" && record[1] != "BACKEND" && record[0] != "" {
			currConn, _ := strconv.Atoi(record[4])
			maxConn, _ := strconv.Atoi(record[6])
			sessions, _ := strconv.Atoi(record[7])

			backends = append(backends, HAProxyBackend{
				Name:        record[1],
				Status:      record[17],
				Addr:        record[73],
				CurrentConn: currConn,
				MaxConn:     maxConn,
				Sessions:    sessions,
				CheckStatus: record[36],
				LastChange:  formatDuration(record[23]),
			})
		}
	}

	return backends, nil
}

func formatDuration(seconds string) string {
	secs, err := strconv.Atoi(seconds)
	if err != nil {
		return seconds
	}

	d := time.Duration(secs) * time.Second
	if d > 24*time.Hour {
		return fmt.Sprintf("%dd%dh", int(d.Hours())/24, int(d.Hours())%24)
	} else if d > time.Hour {
		return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
	} else if d > time.Minute {
		return fmt.Sprintf("%dm%ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%ds", secs)
}

func printProxySQLStats(ctx context.Context) {
	bold := color.New(color.Bold)
	bold.Println("[PROXYSQL STATUS]")
	fmt.Println(strings.Repeat("-", 79))

	adminDSN := fmt.Sprintf("%s:%s@tcp(%s:%d)/",
		cfg.ProxySQLAdminUser, cfg.ProxySQLAdminPassword,
		cfg.ProxySQLAdminHost, cfg.ProxySQLAdminPort)

	adminDB, err := sql.Open("mysql", adminDSN)
	if err != nil {
		color.Red("  Error connecting to ProxySQL admin: %v", err)
		fmt.Println()
		return
	}
	defer adminDB.Close()

	// Get server status
	servers, err := fetchProxySQLServers(ctx, adminDB)
	if err != nil {
		color.Red("  Error fetching server status: %v", err)
	} else {
		fmt.Println("  MySQL Servers:")
		table := tablewriter.NewWriter(os.Stdout)
		table.SetHeader([]string{"HG", "Host", "Port", "Status", "Weight", "Max Conn", "Latency"})
		table.SetBorder(false)
		table.SetColumnSeparator("|")

		for _, s := range servers {
			status := s.Status
			if s.Status == "ONLINE" {
				status = color.GreenString("ONLINE")
			} else if s.Status == "OFFLINE_SOFT" {
				status = color.YellowString("OFFLINE_SOFT")
			} else if s.Status == "OFFLINE_HARD" || s.Status == "SHUNNED" {
				status = color.RedString(s.Status)
			}

			table.Append([]string{
				fmt.Sprintf("%d", s.HostgroupID),
				s.Hostname,
				fmt.Sprintf("%d", s.Port),
				status,
				fmt.Sprintf("%d", s.Weight),
				fmt.Sprintf("%d", s.MaxConns),
				fmt.Sprintf("%dms", s.MaxLatencyMs),
			})
		}
		table.Render()
	}
	fmt.Println()

	// Get connection pool stats
	poolStats, err := fetchProxySQLConnPool(ctx, adminDB)
	if err != nil {
		color.Red("  Error fetching connection pool stats: %v", err)
	} else {
		fmt.Println("  Connection Pool Stats:")
		table := tablewriter.NewWriter(os.Stdout)
		table.SetHeader([]string{"HG", "Server", "Status", "Used", "Free", "OK", "Err", "Queries", "Latency"})
		table.SetBorder(false)
		table.SetColumnSeparator("|")

		for _, p := range poolStats {
			status := p.Status
			if strings.Contains(p.Status, "ONLINE") {
				status = color.GreenString(p.Status)
			} else {
				status = color.RedString(p.Status)
			}

			errCount := fmt.Sprintf("%d", p.ConnErr)
			if p.ConnErr > 0 {
				errCount = color.RedString("%d", p.ConnErr)
			}

			table.Append([]string{
				fmt.Sprintf("%d", p.HostgroupID),
				fmt.Sprintf("%s:%d", p.SrvHost, p.SrvPort),
				status,
				fmt.Sprintf("%d", p.ConnUsed),
				fmt.Sprintf("%d", p.ConnFree),
				fmt.Sprintf("%d", p.ConnOK),
				errCount,
				fmt.Sprintf("%d", p.Queries),
				fmt.Sprintf("%dus", p.LatencyUs),
			})
		}
		table.Render()
	}
	fmt.Println()
}

func fetchProxySQLServers(ctx context.Context, db *sql.DB) ([]ProxySQLServer, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT hostgroup_id, hostname, port, status, weight, compression, max_connections, 
		       max_latency_ms, comment 
		FROM mysql_servers
		ORDER BY hostgroup_id, hostname
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var servers []ProxySQLServer
	for rows.Next() {
		var s ProxySQLServer
		if err := rows.Scan(&s.HostgroupID, &s.Hostname, &s.Port, &s.Status, &s.Weight,
			&s.Compression, &s.MaxConns, &s.MaxLatencyMs, &s.Comment); err != nil {
			continue
		}
		servers = append(servers, s)
	}
	return servers, nil
}

func fetchProxySQLConnPool(ctx context.Context, db *sql.DB) ([]ProxySQLConnPool, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT hostgroup, srv_host, srv_port, status, ConnUsed, ConnFree, ConnOK, ConnERR,
		       Queries, Bytes_data_sent, Bytes_data_recv, Latency_us
		FROM stats_mysql_connection_pool
		ORDER BY hostgroup, srv_host
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var pools []ProxySQLConnPool
	for rows.Next() {
		var p ProxySQLConnPool
		if err := rows.Scan(&p.HostgroupID, &p.SrvHost, &p.SrvPort, &p.Status,
			&p.ConnUsed, &p.ConnFree, &p.ConnOK, &p.ConnErr, &p.Queries,
			&p.BytesDataSent, &p.BytesDataRecv, &p.LatencyUs); err != nil {
			continue
		}
		pools = append(pools, p)
	}
	return pools, nil
}

func printPXCStatus(ctx context.Context) {
	bold := color.New(color.Bold)
	bold.Println("[PXC CLUSTER STATUS]")
	fmt.Println(strings.Repeat("-", 79))

	if len(cfg.PXCNodes) == 0 {
		color.Yellow("  No PXC nodes configured. Use --pxc-nodes to specify nodes.")
		fmt.Println()
		return
	}

	var wg sync.WaitGroup
	statusCh := make(chan PXCNodeStatus, len(cfg.PXCNodes))

	for _, node := range cfg.PXCNodes {
		wg.Add(1)
		go func(nodeAddr string) {
			defer wg.Done()
			status, err := fetchPXCNodeStatus(ctx, nodeAddr)
			if err != nil {
				statusCh <- PXCNodeStatus{
					Address:       nodeAddr,
					ClusterStatus: color.RedString("ERROR: %v", err),
				}
				return
			}
			statusCh <- status
		}(node)
	}

	go func() {
		wg.Wait()
		close(statusCh)
	}()

	var statuses []PXCNodeStatus
	for s := range statusCh {
		statuses = append(statuses, s)
	}

	// Sort by address for consistent display
	sort.Slice(statuses, func(i, j int) bool {
		return statuses[i].Address < statuses[j].Address
	})

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Node", "State", "Cluster", "Size", "Ready", "Flow Ctrl", "Recv Q", "Send Q", "Conns"})
	table.SetBorder(false)
	table.SetColumnSeparator("|")

	for _, s := range statuses {
		state := s.LocalState
		if s.LocalState == "Synced" {
			state = color.GreenString("Synced")
		} else if s.LocalState == "Donor" || s.LocalState == "Joiner" {
			state = color.YellowString(s.LocalState)
		} else if s.LocalState != "" {
			state = color.RedString(s.LocalState)
		}

		ready := s.ReadyStatus
		if s.ReadyStatus == "ON" {
			ready = color.GreenString("ON")
		} else if s.ReadyStatus != "" {
			ready = color.RedString(s.ReadyStatus)
		}

		fc := s.FlowControl
		if s.FlowControl == "OFF" || s.FlowControl == "0" {
			fc = color.GreenString(s.FlowControl)
		} else if s.FlowControl != "" {
			fc = color.YellowString(s.FlowControl)
		}

		table.Append([]string{
			s.NodeName,
			state,
			s.ClusterStatus,
			fmt.Sprintf("%d", s.ClusterSize),
			ready,
			fc,
			fmt.Sprintf("%d", s.RecvQueue),
			fmt.Sprintf("%d", s.SendQueue),
			fmt.Sprintf("%d", s.Connections),
		})
	}
	table.Render()
	fmt.Println()
}

func fetchPXCNodeStatus(ctx context.Context, nodeAddr string) (PXCNodeStatus, error) {
	dsn := fmt.Sprintf("%s:%s@tcp(%s)/?timeout=5s", cfg.PXCUser, cfg.PXCPassword, nodeAddr)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return PXCNodeStatus{}, err
	}
	defer db.Close()

	status := PXCNodeStatus{Address: nodeAddr}

	// Get hostname
	db.QueryRowContext(ctx, "SELECT @@hostname").Scan(&status.NodeName)

	// Get wsrep status
	rows, err := db.QueryContext(ctx, "SHOW GLOBAL STATUS LIKE 'wsrep_%'")
	if err != nil {
		return status, err
	}
	defer rows.Close()

	wsrepStatus := make(map[string]string)
	for rows.Next() {
		var name, value string
		rows.Scan(&name, &value)
		wsrepStatus[name] = value
	}

	status.ClusterStatus = wsrepStatus["wsrep_cluster_status"]
	status.ClusterSize, _ = strconv.Atoi(wsrepStatus["wsrep_cluster_size"])
	status.LocalState = wsrepStatus["wsrep_local_state_comment"]
	status.LocalStateUUID = wsrepStatus["wsrep_local_state_uuid"]
	status.ReadyStatus = wsrepStatus["wsrep_ready"]
	status.Connected = wsrepStatus["wsrep_connected"]
	status.DesyncCount, _ = strconv.Atoi(wsrepStatus["wsrep_desync_count"])
	status.RecvQueue, _ = strconv.Atoi(wsrepStatus["wsrep_local_recv_queue"])
	status.SendQueue, _ = strconv.Atoi(wsrepStatus["wsrep_local_send_queue"])
	status.FlowControl = wsrepStatus["wsrep_flow_control_paused_ns"]

	// Get connection count
	db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.processlist").Scan(&status.Connections)

	return status, nil
}

func printConnectionErrors() {
	stats.mu.RLock()
	defer stats.mu.RUnlock()

	if len(stats.ConnectionErrors) == 0 {
		return
	}

	bold := color.New(color.Bold)
	bold.Println("[RECENT CONNECTION ERRORS]")
	fmt.Println(strings.Repeat("-", 79))

	// Show last 10 errors
	start := 0
	if len(stats.ConnectionErrors) > 10 {
		start = len(stats.ConnectionErrors) - 10
	}

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Time", "Operation", "Node", "Error"})
	table.SetBorder(false)
	table.SetColumnSeparator("|")
	table.SetColWidth(40)

	for _, e := range stats.ConnectionErrors[start:] {
		errStr := e.Error
		if len(errStr) > 50 {
			errStr = errStr[:47] + "..."
		}
		table.Append([]string{
			e.Timestamp.Format("15:04:05"),
			color.RedString(e.Operation),
			e.Node,
			errStr,
		})
	}
	table.Render()
	fmt.Println()
}

func printFooter() {
	fmt.Println(strings.Repeat("=", 79))
	color.Cyan("  Press Ctrl+C to exit | Refresh: 2s | Target: %s:%d", cfg.ProxyHost, cfg.ProxyPort)

	stats.mu.RLock()
	errorRate := float64(0)
	total := stats.TotalReads + stats.TotalWrites
	if total > 0 {
		errorRate = float64(stats.FailedReads+stats.FailedWrites) / float64(total) * 100
	}
	stats.mu.RUnlock()

	if errorRate > 0 {
		color.Red("  ERROR RATE: %.2f%% - Connection issues detected!", errorRate)
	} else {
		color.Green("  ERROR RATE: 0%% - All connections healthy")
	}
}

// Atomic counters for high-frequency updates
var (
	readOps  int64
	writeOps int64
)

func incrementReadOps() {
	atomic.AddInt64(&readOps, 1)
}

func incrementWriteOps() {
	atomic.AddInt64(&writeOps, 1)
}
