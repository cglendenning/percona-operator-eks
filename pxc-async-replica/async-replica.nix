# Single-file Nix: npm+esbuild bundle on the host (Darwin/Linux), Linux OCI image via pulled Node base.
#
#   cd pxc-async-replica && nix-build async-replica.nix -A ociImage
#   docker load < result
#
# Also: nix-build async-replica.nix -A k8sManifest && kubectl apply -f result

let
  nixpkgsSrc = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
    sha256 = "1s2gr5rcyqvpr58vxdcb095mdhblij9bfzaximrva2243aal3dgx";
  };

  pkgs = import nixpkgsSrc { system = builtins.currentSystem; };
  lib = pkgs.lib;
  src = lib.cleanSource ./.;

  # linux/arm64 vs linux/amd64 single-arch Node 20 Alpine (official index digest)
  nodeBaseDigest =
    if builtins.elem builtins.currentSystem [ "aarch64-darwin" "aarch64-linux" ] then
      "sha256:545117153efee1468bed699fa8f2b4525582454d876c6a0fdc764893a2b51a08"
    else
      "sha256:42d1d5b07c84257b55d409f4e6e3be3b55d42867afce975a5648a3f231bf7e81";

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

  appRoot = pkgs.runCommand "pxc-async-replica-app-root" { } ''
    mkdir -p $out/app
    cp ${controllerApp}/bundle.cjs $out/app/bundle.cjs
  '';

  imageArch =
    if builtins.elem builtins.currentSystem [ "aarch64-darwin" "aarch64-linux" ] then "arm64" else "amd64";

  nodeBase = pkgs.dockerTools.pullImage {
    imageName = "docker.io/library/node";
    imageDigest = nodeBaseDigest;
    sha256 = "sha256-wtlgnFWfaf8yM9ug7HgKxBldbI4iGSTV84T5/ItdNs0=";
    arch = imageArch;
    os = "linux";
    finalImageTag = "20-alpine";
  };

  ociImage = pkgs.dockerTools.buildImage {
    name = "pxc-async-replica-controller";
    tag = "local";
    fromImage = nodeBase;
    copyToRoot = pkgs.buildEnv {
      name = "image-root";
      paths = [ appRoot ];
      pathsToLink = [ "/" ];
    };
    config = {
      Cmd = [ "node" "/app/bundle.cjs" ];
      Env = [
        "NODE_ENV=production"
        "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt"
      ];
      WorkingDir = "/";
    };
  };

  ns = "pxc-replica-local";
  saName = "pxc-async-replica-sa";
  deployName = "pxc-async-replica-controller";
  roleName = "pxc-async-replica";

  rbacAndDeployYaml = pkgs.writeText "pxc-async-replica-k8s.yaml" ''
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: ${saName}
      namespace: ${ns}
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: ${roleName}
      namespace: ${ns}
    rules:
      - apiGroups: [""]
        resources: ["secrets"]
        verbs: ["get"]
        resourceNames: ["seaweedfs-s3-credentials", "pxc-async-replica-mysql", "root-db-users"]
      - apiGroups: ["apps"]
        resources: ["statefulsets", "deployments"]
        verbs: ["get", "list", "patch"]
      - apiGroups: ["pxc.percona.com"]
        resources: ["perconaxtradbclusters"]
        verbs: ["get", "patch"]
      - apiGroups: ["pxc.percona.com"]
        resources: ["perconaxtradbclusterrestores"]
        verbs: ["get", "list", "create"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: ${roleName}
      namespace: ${ns}
    subjects:
      - kind: ServiceAccount
        name: ${saName}
        namespace: ${ns}
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: ${roleName}
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${deployName}
      namespace: ${ns}
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
              image: pxc-async-replica-controller:local
              imagePullPolicy: IfNotPresent
              env:
                - name: PXC_NAMESPACE
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                - name: PXC_CLUSTER_NAME
                  value: "pxc-cluster"
                - name: REPLICATION_CHANNEL_NAME
                  value: "wookie_primary_to_replica"
                - name: SOURCE_HOSTS
                  value: "db-pxc-0.dev.wookie.com,db-pxc-1.dev.wookie.com,db-pxc-2.dev.wookie.com"
                - name: SOURCE_PORT
                  value: "3306"
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
                - name: S3_CREDENTIALS_SECRET
                  value: "seaweedfs-s3-credentials"
                - name: SOURCE_MYSQL_URL
                  value: "mysql://root@db-haproxy.percona.svc.cluster.local:3306/mysql"
                - name: REPLICA_MYSQL_URL
                  valueFrom:
                    secretKeyRef:
                      name: pxc-async-replica-mysql
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

in
{
  inherit controllerApp ociImage rbacAndDeployYaml;
  default = ociImage;
  k8sManifest = rbacAndDeployYaml;
}
