# Profile: Local PMM with Vault and External Secrets Operator
# Demonstrates PMM service account token management

[
  ../projects/pmm
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "pmm";
      apiPort = 6445;  # Use different port to avoid conflicts with multi-cluster setup (6443=cluster-a, 6444=cluster-b)
    };

    projects.pmm = {
      enable = true;
      namespace = "pmm";
      adminPassword = "admin";
      chartVersion = "3.0.0";
      chartHash = "sha256-PLACEHOLDER"; # required: nix-prefetch-url https://percona.github.io/percona-helm-charts/pmm-3.0.0.tgz

      # Enable after PMM is up and you have a service account token (glsa_…):
      # k8sMonitoring = {
      #   enable = true;
      #   namespace = "monitoring-system";
      #   k8sClusterId = "pmm";
      #   pmmApiKey = "glsa_...";
      # };
    };
  }
]
