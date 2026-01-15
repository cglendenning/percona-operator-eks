[
  ../modules/projects/wookie
  ../modules/targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "wookie-local";
    };

    projects.wookie = {
      enable = true;
      clusterRole = "standalone";
      
      # Istio configuration (component of wookie)
      istio = {
        enable = true;
        version = "1_28_2";
        profile = "default";
      };
    };
  }
]
