# Minimal SeaweedFS deployment without using the Helm chart
# Creates raw Kubernetes manifests for master, volume, and filer

{ pkgs, lib }:

{ name, namespace, image ? "chrislusf/seaweedfs:latest", replicas ? 1 }:

let
  yaml = pkgs.formats.yaml {};
  
  masterManifest = {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    metadata = {
      name = "${name}-master";
      inherit namespace;
    };
    spec = {
      serviceName = "${name}-master";
      replicas = replicas;
      selector.matchLabels = {
        app = "${name}-master";
      };
      template = {
        metadata.labels = {
          app = "${name}-master";
        };
        spec = {
          containers = [{
            name = "master";
            image = image;
            command = [ "weed" "master" ];
            ports = [
              { containerPort = 9333; name = "http"; }
              { containerPort = 19333; name = "grpc"; }
            ];
          }];
        };
      };
    };
  };
  
  masterService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "${name}-master";
      inherit namespace;
    };
    spec = {
      selector = {
        app = "${name}-master";
      };
      ports = [
        { port = 9333; name = "http"; }
        { port = 19333; name = "grpc"; }
      ];
    };
  };
  
  volumeManifest = {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    metadata = {
      name = "${name}-volume";
      inherit namespace;
    };
    spec = {
      serviceName = "${name}-volume";
      replicas = replicas;
      selector.matchLabels = {
        app = "${name}-volume";
      };
      template = {
        metadata.labels = {
          app = "${name}-volume";
        };
        spec = {
          containers = [{
            name = "volume";
            image = image;
            command = [ "weed" "volume" "-mserver=${name}-master:9333" "-port=8080" ];
            ports = [
              { containerPort = 8080; name = "http"; }
              { containerPort = 18080; name = "grpc"; }
            ];
            volumeMounts = [{
              name = "data";
              mountPath = "/data";
            }];
          }];
        };
      };
      volumeClaimTemplates = [{
        metadata.name = "data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          storageClassName = "local-path";
          resources.requests.storage = "10Gi";
        };
      }];
    };
  };
  
  volumeService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "${name}-volume";
      inherit namespace;
    };
    spec = {
      selector = {
        app = "${name}-volume";
      };
      ports = [
        { port = 8080; name = "http"; }
        { port = 18080; name = "grpc"; }
      ];
    };
  };
  
  filerManifest = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "${name}-filer";
      inherit namespace;
    };
    spec = {
      replicas = replicas;
      selector.matchLabels = {
        app = "${name}-filer";
      };
      template = {
        metadata.labels = {
          app = "${name}-filer";
        };
        spec = {
          containers = [{
            name = "filer";
            image = image;
            command = [ "weed" "filer" "-master=${name}-master:9333" ];
            ports = [
              { containerPort = 8888; name = "http"; }
              { containerPort = 18888; name = "grpc"; }
            ];
          }];
        };
      };
    };
  };
  
  filerService = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "${name}-filer";
      inherit namespace;
    };
    spec = {
      selector = {
        app = "${name}-filer";
      };
      ports = [
        { port = 8888; name = "http"; }
        { port = 18888; name = "grpc"; }
      ];
    };
  };
  
  allManifests = [
    masterManifest
    masterService
    volumeManifest
    volumeService
    filerManifest
    filerService
  ];
  
in
pkgs.runCommand "seaweedfs-minimal-${name}" {} ''
  mkdir -p $out
  ${lib.concatMapStringsSep "\n" (m: ''
    cat >> $out/manifest.yaml << 'EOF'
${builtins.readFile (yaml.generate "manifest.yaml" m)}
---
EOF
  '') allManifests}
''
