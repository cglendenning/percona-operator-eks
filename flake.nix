{
  description = "Percona operator repo checks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          valuesYaml = ./percona/templates/percona-values.yaml;
          expected = "kubernetes.io/hostname";

          getTopologyExpr = component:
            # Prefer CR-style `antiAffinityTopologyKey`, fall back to values-style podAntiAffinity.
            ''
              .${component}.affinity.antiAffinityTopologyKey
              // .${component}.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey
              // ""
            '';
        in
        {
          percona-onprem-anti-affinity-hostname =
            pkgs.runCommand "percona-onprem-anti-affinity-hostname" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
              set -euo pipefail

              pxc_topology="$(yq -r '${getTopologyExpr "pxc"}' ${valuesYaml})"
              haproxy_topology="$(yq -r '${getTopologyExpr "haproxy"}' ${valuesYaml})"

              if [ "$pxc_topology" != "${expected}" ]; then
                echo "pxc anti-affinity topology key must be '${expected}', got '${pxc_topology:-<unset>}'" >&2
                exit 1
              fi

              if [ "$haproxy_topology" != "${expected}" ]; then
                echo "haproxy anti-affinity topology key must be '${expected}', got '${haproxy_topology:-<unset>}'" >&2
                exit 1
              fi

              mkdir -p "$out"
              printf "ok\n" > "$out/result"
            '';
        }
      );
    };
}

