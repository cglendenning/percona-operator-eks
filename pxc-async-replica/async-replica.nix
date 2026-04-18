# Nix: npm + esbuild bundle (host), plus rendered Kubernetes RBAC/Deployment YAML.
#
#   cd pxc-async-replica && nix-build async-replica.nix -A controllerApp   # bundled JS
#   nix-build async-replica.nix -A k8sManifest && kubectl apply -f result
#
# Container image: build with Docker in this directory (see Dockerfile).

let
  nixpkgsSrc = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
    sha256 = "1s2gr5rcyqvpr58vxdcb095mdhblij9bfzaximrva2243aal3dgx";
  };

  pkgs = import nixpkgsSrc { system = builtins.currentSystem; };
  lib = pkgs.lib;
  src = lib.cleanSource ./.;

  controllerApp = pkgs.buildNpmPackage rec {
    pname = "pxc-async-replica-controller";
    version = "1.0.0";
    inherit src;

    npmDepsHash = "sha256-E8Akqj3Z0bWG/Ro9cLnVxEPOgVr2TzmL6ToPC1TMWeo=";

    nativeBuildInputs = [ pkgs.esbuild ];

    npmBuildScript = "build";

    postInstall = ''
      ${pkgs.esbuild}/bin/esbuild \
        "$out/lib/node_modules/${pname}/dist/index.js" \
        --bundle --platform=node --target=node20 --format=cjs \
        --outfile=$out/bundle.cjs
    '';
  };

  destNs = "pxc-replica-local";
  saName = "pxc-async-replica-sa";
  deployName = "pxc-async-replica-controller";
  destRoleName = "pxc-async-replica-dest";

  # First host is used for SOURCE_MYSQL_URL (mysql client); full list is SOURCE_HOSTS for replication channel sources.
  sourceHosts = [
    "db-haproxy.percona.svc.cluster.local"
    "db-pxc-0.dev.wookie.com"
    "db-pxc-1.dev.wookie.com"
    "db-pxc-2.dev.wookie.com"
  ];
  sourcePort = "3306";
  sourceMysqlHost = builtins.elemAt sourceHosts 0;
  sourceMysqlUrl = "mysql://replication@${sourceMysqlHost}:${sourcePort}/mysql";
  sourceHostsCsv = lib.concatStringsSep "," sourceHosts;

  # ServiceAccount + namespaced Role/RoleBinding (not ClusterRole: secrets and apps workloads are namespace-scoped).
  rbacKubernetesObjects = [
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = saName;
        namespace = destNs;
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = destRoleName;
        namespace = destNs;
      };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          verbs = [ "get" ];
          resourceNames = [ "db-root-users" ];
        }
        {
          apiGroups = [ "apps" ];
          resources = [ "statefulsets" "deployments" ];
          verbs = [ "get" "list" "patch" ];
        }
        {
          apiGroups = [ "pxc.percona.com" ];
          resources = [ "perconaxtradbclusters" ];
          verbs = [ "get" "patch" ];
        }
        {
          apiGroups = [ "pxc.percona.com" ];
          resources = [ "perconaxtradbclusterrestores" ];
          verbs = [ "get" "list" "create" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = destRoleName;
        namespace = destNs;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = saName;
          namespace = destNs;
        }
      ];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = destRoleName;
      };
    }
  ];

  rbacYaml = lib.concatStringsSep "\n---\n" (map (obj: lib.generators.toYAML { } obj) rbacKubernetesObjects);

  deploymentYamlFragment = ''
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${deployName}
      namespace: ${destNs}
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: ${deployName}
      template:
        metadata:
          labels:
            app: ${deployName}
        spec:
          serviceAccountName: ${saName}
          containers:
            - name: controller
              image: pxc-async-replica-controller:latest
              imagePullPolicy: IfNotPresent
              env:
                - name: DEST_NS
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                - name: PXC_CLUSTER
                  value: "pxc-cluster"
                - name: REPLICATION_CHANNEL_NAME
                  value: "wookie_primary_to_replica"
                - name: SOURCE_HOSTS
                  value: "${sourceHostsCsv}"
                - name: SOURCE_PORT
                  value: "${sourcePort}"
                - name: S3_ENDPOINT_URL
                  value: "http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
                - name: S3_REGION
                  value: "us-east-1"
                - name: S3_FORCE_PATH_STYLE
                  value: "true"
                - name: S3_BACKUP_BUCKET
                  value: "pxc-backups"
                - name: S3_BACKUP_PREFIX
                  value: ""
                - name: S3_BACKUP_FOLDER_PREFIX
                  value: "db-"
                - name: DB_ROOT_USERS_SECRET
                  value: "db-root-users"
                - name: SOURCE_MYSQL_URL
                  value: "${sourceMysqlUrl}"
                - name: REPLICA_MYSQL_URL
                  valueFrom:
                    secretKeyRef:
                      name: db-root-users
                      key: REPLICA_MYSQL_URL
                - name: READY_TIMEOUT_SECONDS
                  value: "7200"
                - name: POLL_INTERVAL_MS
                  value: "10000"
                - name: RESTORE_TIMEOUT_SECONDS
                  value: "7200"
                - name: HEALTHCHECK_INTERVAL_SECONDS
                  value: "60"
                - name: MAX_REPLICATION_LAG_SECONDS
                  value: "5"
                - name: SELF_HEAL_FAILURE_THRESHOLD
                  value: "3"
  '';

  rbacAndDeployYaml = pkgs.writeText "pxc-async-replica-k8s.yaml" (rbacYaml + "\n---\n" + deploymentYamlFragment);

in
{
  inherit controllerApp rbacAndDeployYaml;
  k8sManifest = rbacAndDeployYaml;
  default = rbacAndDeployYaml;
}
