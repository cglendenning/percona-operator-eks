# ServiceEntry module for Istio cross-cluster service discovery
#
# Allows services in one cluster to discover services in another cluster by DNS name
# Exports: mkServiceEntry, mkPXCServiceEntry
{ pkgs }:

let
  yaml = pkgs.formats.yaml { };
in
{
  # Generic ServiceEntry creator
  mkServiceEntry = {
    name,
    namespace ? "default",
    hosts,
    addresses ? [],
    ports,
    location ? "MESH_EXTERNAL",
    resolution ? "STATIC",
    endpoints ? [],
  }:
    let
      serviceEntry = {
        apiVersion = "networking.istio.io/v1beta1";
        kind = "ServiceEntry";
        metadata = {
          inherit name namespace;
        };
        spec = {
          inherit hosts addresses ports location resolution endpoints;
        };
      };
    in
    pkgs.runCommand "service-entry-${name}" { } ''
      mkdir -p $out
      cat ${yaml.generate "serviceentry.yaml" serviceEntry} > $out/manifest.yaml
    '';

  # PXC-specific ServiceEntry helper
  mkPXCServiceEntry = {
    name,
    namespace ? "default",
    remoteClusterName,
    remoteEndpoints,  # List of { address, port }
    mysqlPort ? 3306,
  }:
    let
      serviceEntry = {
        apiVersion = "networking.istio.io/v1beta1";
        kind = "ServiceEntry";
        metadata = {
          inherit name namespace;
          labels = {
            "app.kubernetes.io/name" = "percona-xtradb-cluster";
            "app.kubernetes.io/component" = "remote-cluster";
          };
        };
        spec = {
          hosts = [
            "${name}.${remoteClusterName}.global"
          ];
          addresses = [
            "240.0.0.${toString (builtins.hashString "md5" name)}"  # Generate virtual IP
          ];
          ports = [{
            number = mysqlPort;
            name = "mysql";
            protocol = "TCP";
          }];
          location = "MESH_EXTERNAL";
          resolution = "STATIC";
          endpoints = map (ep: {
            address = ep.address;
            ports = {
              mysql = ep.port or mysqlPort;
            };
          }) remoteEndpoints;
        };
      };
      
      # Also create DestinationRule for TLS
      destinationRule = {
        apiVersion = "networking.istio.io/v1beta1";
        kind = "DestinationRule";
        metadata = {
          name = "${name}-tls";
          inherit namespace;
        };
        spec = {
          host = "${name}.${remoteClusterName}.global";
          trafficPolicy = {
            tls = {
              mode = "DISABLE";  # MySQL handles TLS itself
            };
          };
        };
      };
    in
    pkgs.runCommand "pxc-service-entry-${name}" { } ''
      mkdir -p $out
      cat ${yaml.generate "serviceentry.yaml" serviceEntry} > $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "destinationrule.yaml" destinationRule} >> $out/manifest.yaml
    '';

  # Generate multicluster configuration
  mkMulticlusterConfig = {
    clusterName,
    network ? "network1",
    meshId ? "mesh1",
  }:
    let
      configMap = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "istio";
          namespace = "istio-system";
        };
        data = {
          mesh = ''
            defaultConfig:
              discoveryAddress: istiod.istio-system.svc:15012
              tracing:
                zipkin:
                  address: zipkin.istio-system:9411
            enablePrometheusMerge: true
            rootNamespace: istio-system
            trustDomain: cluster.local
          '';
          meshNetworks = ''
            networks:
              ${network}:
                endpoints:
                - fromRegistry: ${clusterName}
                gateways: []
          '';
        };
      };
    in
    pkgs.runCommand "istio-multicluster-config" { } ''
      mkdir -p $out
      cat ${yaml.generate "configmap.yaml" configMap} > $out/manifest.yaml
    '';
}
