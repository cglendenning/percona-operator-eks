# Profile: Local PMM with Vault and External Secrets Operator
# Demonstrates PMM service account token management

[
  ../projects/pmm
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "pmm";
    };

    projects.pmm = {
      enable = true;
      
      pmm = {
        enable = true;
        version = "3.0.0";
        namespace = "pmm";
        adminPassword = "admin";
      };
      
      vault = {
        enable = true;
        namespace = "vault";
        devMode = true;
        rootToken = "root";
      };
      
      externalSecrets = {
        enable = true;
        namespace = "external-secrets";
      };
    };
  }
]
