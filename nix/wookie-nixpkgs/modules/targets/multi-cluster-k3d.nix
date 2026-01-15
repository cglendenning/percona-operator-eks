{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

{
  options.targets.multi-cluster-k3d = {
    enable = mkEnableOption "Multi-cluster k3d setup for cross-datacenter simulation";

    clusterA = {
      clusterName = mkOption {
        type = types.str;
        default = "cluster-a";
        description = "Name of the first k3d cluster.";
      };

      apiPort = mkOption {
        type = types.int;
        default = 6443;
        description = "Port to expose the Kubernetes API server.";
      };

      httpPort = mkOption {
        type = types.int;
        default = 8080;
        description = "HTTP port for loadbalancer.";
      };

      httpsPort = mkOption {
        type = types.int;
        default = 8443;
        description = "HTTPS port for loadbalancer.";
      };

      servers = mkOption {
        type = types.int;
        default = 1;
        description = "Number of server nodes.";
      };

      agents = mkOption {
        type = types.int;
        default = 2;
        description = "Number of agent nodes.";
      };

      context = mkOption {
        type = types.str;
        default = "k3d-${config.targets.multi-cluster-k3d.clusterA.clusterName}";
        description = "Kubectl context name for cluster A.";
      };
    };

    clusterB = {
      clusterName = mkOption {
        type = types.str;
        default = "cluster-b";
        description = "Name of the second k3d cluster.";
      };

      apiPort = mkOption {
        type = types.int;
        default = 6444;
        description = "Port to expose the Kubernetes API server.";
      };

      httpPort = mkOption {
        type = types.int;
        default = 9080;
        description = "HTTP port for loadbalancer.";
      };

      httpsPort = mkOption {
        type = types.int;
        default = 9443;
        description = "HTTPS port for loadbalancer.";
      };

      servers = mkOption {
        type = types.int;
        default = 1;
        description = "Number of server nodes.";
      };

      agents = mkOption {
        type = types.int;
        default = 2;
        description = "Number of agent nodes.";
      };

      context = mkOption {
        type = types.str;
        default = "k3d-${config.targets.multi-cluster-k3d.clusterB.clusterName}";
        description = "Kubectl context name for cluster B.";
      };
    };

    network = {
      name = mkOption {
        type = types.str;
        default = "k3d-multicluster";
        description = "Name of the shared Docker network.";
      };

      subnet = mkOption {
        type = types.str;
        default = "172.24.0.0/16";
        description = "Subnet for the shared network.";
      };
    };
  };

  config = mkIf config.targets.multi-cluster-k3d.enable {
    # k3d-specific Istio overrides for Docker compatibility
    projects.wookie.istio.eastWestGateway.values = mkIf (config.projects.wookie.istio.eastWestGateway.enabled or false) {
      # Disable sysctl requirements - Docker/k3d doesn't allow pod-level sysctls
      securityContext = {
        sysctls = [];
      };
    };

    # Generate k3d cluster creation script for both clusters
    build.scripts.create-clusters = pkgs.writeShellScript "create-k3d-multicluster" ''
      set -euo pipefail
      
      NETWORK_NAME="${config.targets.multi-cluster-k3d.network.name}"
      NETWORK_SUBNET="${config.targets.multi-cluster-k3d.network.subnet}"
      
      CLUSTER_A_NAME="${config.targets.multi-cluster-k3d.clusterA.clusterName}"
      CLUSTER_A_API_PORT="${toString config.targets.multi-cluster-k3d.clusterA.apiPort}"
      CLUSTER_A_HTTP_PORT="${toString config.targets.multi-cluster-k3d.clusterA.httpPort}"
      CLUSTER_A_HTTPS_PORT="${toString config.targets.multi-cluster-k3d.clusterA.httpsPort}"
      CLUSTER_A_SERVERS="${toString config.targets.multi-cluster-k3d.clusterA.servers}"
      CLUSTER_A_AGENTS="${toString config.targets.multi-cluster-k3d.clusterA.agents}"
      
      CLUSTER_B_NAME="${config.targets.multi-cluster-k3d.clusterB.clusterName}"
      CLUSTER_B_API_PORT="${toString config.targets.multi-cluster-k3d.clusterB.apiPort}"
      CLUSTER_B_HTTP_PORT="${toString config.targets.multi-cluster-k3d.clusterB.httpPort}"
      CLUSTER_B_HTTPS_PORT="${toString config.targets.multi-cluster-k3d.clusterB.httpsPort}"
      CLUSTER_B_SERVERS="${toString config.targets.multi-cluster-k3d.clusterB.servers}"
      CLUSTER_B_AGENTS="${toString config.targets.multi-cluster-k3d.clusterB.agents}"
      
      echo "=== Setting up two k3d clusters for cross-cluster demo ==="
      echo ""
      
      # Check if clusters already exist
      if ${pkgs.k3d}/bin/k3d cluster list | grep -q "^$CLUSTER_A_NAME" && \
         ${pkgs.k3d}/bin/k3d cluster list | grep -q "^$CLUSTER_B_NAME"; then
        echo "Clusters already exist and are ready"
        ${pkgs.k3d}/bin/k3d cluster list
        echo ""
        echo "Kubeconfig contexts:"
        ${pkgs.kubectl}/bin/kubectl config get-contexts | grep k3d || true
        exit 0
      fi
      
      # Create or reuse Docker network
      echo "Setting up Docker network..."
      if ${pkgs.docker}/bin/docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        echo "Network $NETWORK_NAME already exists, reusing it"
      else
        ${pkgs.docker}/bin/docker network create "$NETWORK_NAME" --subnet="$NETWORK_SUBNET"
        echo "Network created: $NETWORK_SUBNET"
      fi
      echo ""
      
      # Create Cluster A (if it doesn't exist)
      if ${pkgs.k3d}/bin/k3d cluster list | grep -q "^$CLUSTER_A_NAME"; then
        echo "Cluster A already exists, skipping creation"
      else
        echo "Creating Cluster A on shared network..."
        ${pkgs.k3d}/bin/k3d cluster create "$CLUSTER_A_NAME" \
          --servers "$CLUSTER_A_SERVERS" \
          --agents "$CLUSTER_A_AGENTS" \
          --api-port "$CLUSTER_A_API_PORT" \
          --port "$CLUSTER_A_HTTP_PORT:80@loadbalancer" \
          --port "$CLUSTER_A_HTTPS_PORT:443@loadbalancer" \
          --network "$NETWORK_NAME" \
          --k3s-arg "--disable=traefik@server:*" \
          --k3s-arg "--tls-san=172.24.0.2@server:0" \
          --k3s-arg "--tls-san=172.24.0.3@server:0" \
          --k3s-arg "--tls-san=172.24.0.4@server:0" \
          --k3s-arg "--tls-san=172.24.0.5@server:0" \
          --k3s-arg "--tls-san=172.24.0.6@server:0" \
          --k3s-arg "--tls-san=172.24.0.7@server:0" \
          --k3s-arg "--tls-san=172.24.0.8@server:0"
      fi
      
      echo ""
      # Create Cluster B (if it doesn't exist)
      if ${pkgs.k3d}/bin/k3d cluster list | grep -q "^$CLUSTER_B_NAME"; then
        echo "Cluster B already exists, skipping creation"
      else
        echo "Creating Cluster B on shared network..."
        ${pkgs.k3d}/bin/k3d cluster create "$CLUSTER_B_NAME" \
          --servers "$CLUSTER_B_SERVERS" \
          --agents "$CLUSTER_B_AGENTS" \
          --api-port "$CLUSTER_B_API_PORT" \
          --port "$CLUSTER_B_HTTP_PORT:80@loadbalancer" \
          --port "$CLUSTER_B_HTTPS_PORT:443@loadbalancer" \
          --network "$NETWORK_NAME" \
          --k3s-arg "--disable=traefik@server:*" \
          --k3s-arg "--tls-san=172.24.0.2@server:0" \
          --k3s-arg "--tls-san=172.24.0.3@server:0" \
          --k3s-arg "--tls-san=172.24.0.4@server:0" \
          --k3s-arg "--tls-san=172.24.0.5@server:0" \
          --k3s-arg "--tls-san=172.24.0.6@server:0" \
          --k3s-arg "--tls-san=172.24.0.7@server:0" \
          --k3s-arg "--tls-san=172.24.0.8@server:0" \
          --k3s-arg "--tls-san=172.24.0.9@server:0" \
          --k3s-arg "--tls-san=172.24.0.10@server:0" \
          --k3s-arg "--tls-san=172.24.0.11@server:0" \
          --k3s-arg "--tls-san=172.24.0.12@server:0" \
          --k3s-arg "--tls-san=172.24.0.13@server:0" \
          --k3s-arg "--tls-san=172.24.0.14@server:0" \
          --k3s-arg "--tls-san=172.24.0.15@server:0"
      fi
      
      echo ""
      echo "Clusters created on shared network:"
      ${pkgs.k3d}/bin/k3d cluster list
      
      echo ""
      echo "Verifying API server IPs on $NETWORK_NAME network..."
      CLUSTER_A_IP=$(${pkgs.docker}/bin/docker inspect k3d-$CLUSTER_A_NAME-server-0 -f '{{range .NetworkSettings.Networks}}{{if .NetworkID}}{{.IPAddress}} {{end}}{{end}}' | awk '{print $1}')
      CLUSTER_B_IP=$(${pkgs.docker}/bin/docker inspect k3d-$CLUSTER_B_NAME-server-0 -f '{{range .NetworkSettings.Networks}}{{if .NetworkID}}{{.IPAddress}} {{end}}{{end}}' | awk '{print $1}')
      
      echo "Cluster A server IP: $CLUSTER_A_IP"
      echo "Cluster B server IP: $CLUSTER_B_IP"
      
      echo ""
      echo "All nodes on $NETWORK_NAME network:"
      ${pkgs.docker}/bin/docker network inspect "$NETWORK_NAME" -f '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{println}}{{end}}' | grep k3d-cluster
      
      echo ""
      echo "Kubeconfig contexts:"
      ${pkgs.kubectl}/bin/kubectl config get-contexts | grep k3d
      
      echo ""
      echo "=== Cluster creation complete ==="
      echo "Contexts: ${config.targets.multi-cluster-k3d.clusterA.context}, ${config.targets.multi-cluster-k3d.clusterB.context}"
    '';

    # Generate k3d cluster deletion script
    build.scripts.delete-clusters = pkgs.writeShellScript "delete-k3d-multicluster" ''
      set -euo pipefail
      
      CLUSTER_A_NAME="${config.targets.multi-cluster-k3d.clusterA.clusterName}"
      CLUSTER_B_NAME="${config.targets.multi-cluster-k3d.clusterB.clusterName}"
      NETWORK_NAME="${config.targets.multi-cluster-k3d.network.name}"
      
      echo "=== Cleaning up multi-cluster setup ==="
      echo ""
      
      echo "Deleting cluster A..."
      ${pkgs.k3d}/bin/k3d cluster delete "$CLUSTER_A_NAME" || echo "Cluster A not found or already deleted"
      
      echo "Deleting cluster B..."
      ${pkgs.k3d}/bin/k3d cluster delete "$CLUSTER_B_NAME" || echo "Cluster B not found or already deleted"
      
      echo "Deleting Docker network..."
      ${pkgs.docker}/bin/docker network rm "$NETWORK_NAME" 2>/dev/null || echo "Network not found or already deleted"
      
      echo ""
      echo "=== Cleanup complete ==="
    '';

    # Cluster status script
    build.scripts.status-clusters = pkgs.writeShellScript "status-k3d-multicluster" ''
      set -euo pipefail
      
      CLUSTER_A_NAME="${config.targets.multi-cluster-k3d.clusterA.clusterName}"
      CLUSTER_B_NAME="${config.targets.multi-cluster-k3d.clusterB.clusterName}"
      NETWORK_NAME="${config.targets.multi-cluster-k3d.network.name}"
      
      echo "=== Multi-cluster k3d status ==="
      echo ""
      
      echo "Clusters:"
      ${pkgs.k3d}/bin/k3d cluster list | grep -E "(NAME|$CLUSTER_A_NAME|$CLUSTER_B_NAME)" || echo "No clusters found"
      
      echo ""
      echo "Network:"
      ${pkgs.docker}/bin/docker network inspect "$NETWORK_NAME" --format '{{.Name}}: {{.IPAM.Config}}' 2>/dev/null || echo "Network not found"
      
      echo ""
      echo "Contexts:"
      ${pkgs.kubectl}/bin/kubectl config get-contexts | grep -E "(CURRENT|k3d)" || echo "No contexts found"
    '';
    
    # Helper script to get k3d API server IPs (returns as shell variables)
    build.scripts.get-api-ips = pkgs.writeShellScript "get-k3d-api-ips" ''
      CLUSTER_A_NAME="${config.targets.multi-cluster-k3d.clusterA.clusterName}"
      CLUSTER_B_NAME="${config.targets.multi-cluster-k3d.clusterB.clusterName}"
      
      API_A=$(${pkgs.docker}/bin/docker inspect k3d-$CLUSTER_A_NAME-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
      API_B=$(${pkgs.docker}/bin/docker inspect k3d-$CLUSTER_B_NAME-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
      
      echo "API_A=$API_A"
      echo "API_B=$API_B"
    '';
    
    # Helper values for use in flake
    build.helpers.k3d = {
      clusterA = {
        name = config.targets.multi-cluster-k3d.clusterA.clusterName;
        context = config.targets.multi-cluster-k3d.clusterA.context;
        serverContainer = "k3d-${config.targets.multi-cluster-k3d.clusterA.clusterName}-server-0";
      };
      clusterB = {
        name = config.targets.multi-cluster-k3d.clusterB.clusterName;
        context = config.targets.multi-cluster-k3d.clusterB.context;
        serverContainer = "k3d-${config.targets.multi-cluster-k3d.clusterB.clusterName}-server-0";
      };
      
      # Script snippets that can be sourced
      getApiIps = ''
        API_A=$(${pkgs.docker}/bin/docker inspect k3d-${config.targets.multi-cluster-k3d.clusterA.clusterName}-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
        API_B=$(${pkgs.docker}/bin/docker inspect k3d-${config.targets.multi-cluster-k3d.clusterB.clusterName}-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
      '';
    };
  };
}
