# Example: ServiceEntry for Percona XtraDB Cluster cross-cluster replication
#
# This shows how to define remote PXC clusters for async replication
# without needing pxc.expose = true or external IPs

{
  description = "PXC ServiceEntry example";

  outputs = { self, ... }:
    {
      # This would be used in your main flake
      examplePackages = { pkgs, serviceEntryLib }:
        {
          # Simple ServiceEntry - point to remote cluster's PXC
          pxc-remote-simple = serviceEntryLib.mkServiceEntry {
            name = "pxc-remote";
            namespace = "pxc";
            hosts = [ "pxc-source.remote.global" ];
            addresses = [ "240.0.0.10" ];
            ports = [{
              number = 3306;
              name = "mysql";
              protocol = "TCP";
            }];
            location = "MESH_EXTERNAL";
            resolution = "STATIC";
            endpoints = [{
              address = "172.19.0.2";  # k3d node IP from remote cluster
              ports = { mysql = 3306; };
            }];
          };

          # PXC-specific helper - handles multiple endpoints
          pxc-production = serviceEntryLib.mkPXCServiceEntry {
            name = "pxc-prod";
            namespace = "pxc";
            remoteClusterName = "production";
            remoteEndpoints = [
              { address = "10.0.1.10"; port = 3306; }
              { address = "10.0.1.11"; port = 3306; }
              { address = "10.0.1.12"; port = 3306; }
            ];
            mysqlPort = 3306;
          };

          # DR site
          pxc-dr = serviceEntryLib.mkPXCServiceEntry {
            name = "pxc-dr";
            namespace = "pxc";
            remoteClusterName = "dr-site";
            remoteEndpoints = [
              { address = "192.168.1.10"; }
              { address = "192.168.1.11"; }
              { address = "192.168.1.12"; }
            ];
          };

          # Combine multiple ServiceEntries
          pxc-all-remotes = pkgs.runCommand "pxc-all-remotes" { } ''
            mkdir -p $out
            cat ${self.packages.${pkgs.system}.pxc-production}/manifest.yaml > $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${pkgs.system}.pxc-dr}/manifest.yaml >> $out/manifest.yaml
          '';
        };
    };
}

# Usage in main flake.nix:
#
# outputs = { self, nixpkgs, service-entry, ... }:
#   packages = forAllSystems (system:
#     let
#       serviceEntryLib = service-entry.lib { inherit pkgs; };
#     in
#     {
#       pxc-production = serviceEntryLib.mkPXCServiceEntry {
#         name = "pxc-prod";
#         namespace = "pxc";
#         remoteClusterName = "production";
#         remoteEndpoints = [
#           { address = "10.0.1.10"; }
#         ];
#       };
#     }
#   );
#
# Build and deploy:
#   nix build .#pxc-production
#   kubectl apply -f result/manifest.yaml
#
# Then in your PXC pod:
#   mysql> CHANGE REPLICATION SOURCE TO
#          SOURCE_HOST='pxc-prod.production.global',
#          SOURCE_PORT=3306,
#          SOURCE_USER='repl_user',
#          SOURCE_PASSWORD='password',
#          SOURCE_AUTO_POSITION=1;
#   mysql> START REPLICA;
