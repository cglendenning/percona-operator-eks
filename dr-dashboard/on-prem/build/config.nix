# Configuration file for DR Dashboard deployment
# Edit these values to match your environment
{
  # Container registry (leave empty for local images)
  # Examples:
  #   "ghcr.io/myorg"
  #   "docker.io/myuser"
  #   "registry.example.com:5000"
  registry = "";

  # Image tag
  imageTag = "latest";

  # Kubernetes namespace
  namespace = "default";

  # Service type: "ClusterIP", "NodePort", or "LoadBalancer"
  serviceType = "ClusterIP";

  # NodePort (only used when serviceType = "NodePort")
  # Set to null for auto-assignment, or specify a port like 30080
  nodePort = null;

  # Ingress configuration
  ingressEnabled = true;
  ingressHost = "wookie.eko.dev.cookie.com";
  ingressClassName = null;  # e.g., "nginx" or "traefik"
  ingressTlsEnabled = false;
  ingressTlsSecretName = "dr-dashboard-tls";

  # Additional labels to apply to all resources
  extraLabels = { };

  # Image pull secrets (list of secret names)
  imagePullSecrets = [ ];
}

