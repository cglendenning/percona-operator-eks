# Helm values for vm/victoria-metrics-k8s-stack aligned with Percona Operator docs:
# https://docs.percona.com/percona-operator-for-mysql/pxc/monitor-kubernetes.html
# Chart pin matches Percona-Lab/k8s-monitoring tag v0.1.1 (HELM_CHART_VERSION=0.30.3).
{
  pmmWriteUrl,
  k8sClusterId,
  nodeExporterEnabled,
  tokenSecretName,
  tokenSecretKey,
  customResourceStateConfig,
}:

{
  externalVM = {
    read.url = "";
    write = {
      url = pmmWriteUrl;
      bearerTokenSecret = {
        name = tokenSecretName;
        key = tokenSecretKey;
      };
    };
  };

  vmsingle.enabled = false;
  vmcluster.enabled = false;

  prometheus-node-exporter.enabled = nodeExporterEnabled;

  vmagent = {
    enabled = true;
    spec = {
      externalLabels = {
        k8s_cluster_id = k8sClusterId;
      };
    };
  };

  # kube-state-metrics: Percona CR metrics (PXC backup/restore, cluster state, etc.)
  # customResourceState.enabled makes the subchart create its own ConfigMap — no separate
  # customresource-config-ksm manifest required.
  kube-state-metrics = {
    enabled = true;
    metricLabelsAllowlist = [
      "pods=[app.kubernetes.io/component,app.kubernetes.io/instance,app.kubernetes.io/managed-by,app.kubernetes.io/name,app.kubernetes.io/part-of],persistentvolumeclaims=[app.kubernetes.io/component,app.kubernetes.io/instance,app.kubernetes.io/managed-by,app.kubernetes.io/name,app.kubernetes.io/part-of],jobs=[app.kubernetes.io/component,app.kubernetes.io/instance,app.kubernetes.io/managed-by,app.kubernetes.io/name,app.kubernetes.io/part-of]"
    ];
    customResourceState = {
      enabled = true;
      config = customResourceStateConfig;
    };
    rbac.extraRules = [
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [ "list" "watch" ];
      }
      {
        apiGroups = [ "pxc.percona.com" ];
        resources = [
          "perconaxtradbclusters"
          "perconaxtradbclusters/status"
          "perconaxtradbclusterbackups"
          "perconaxtradbclusterbackups/status"
          "perconaxtradbclusterrestores"
          "perconaxtradbclusterrestores/status"
        ];
        verbs = [ "list" "watch" ];
      }
    ];
    vmScrape.enabled = true;
  };
}
