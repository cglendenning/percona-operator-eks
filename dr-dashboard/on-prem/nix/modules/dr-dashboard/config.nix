{
  # Image
  registry = "";
  imageName = "dr-dashboard-on-prem";

  # Resource name
  name = "dr-dashboard-on-prem";

  # Ports
  containerPort = 8080;
  servicePort = 80;

  # Resource limits
  resources = {
    requests = { memory = "32Mi"; cpu = "10m"; };
    limits = { memory = "128Mi"; cpu = "100m"; };
  };

  # Security
  runAsUser = 1000;
  fsGroup = 1000;

  # Default labels
  labels = {
    app = "dr-dashboard";
    environment = "on-prem";
  };
}
