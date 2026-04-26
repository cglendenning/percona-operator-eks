{
  description = "WORM S3 sample: platform rules + project Helm values + static and k3d tests";

  inputs = {
    # Newer Helm (3.16+) provides `fromToml` required by upstream SeaweedFS Helm chart templates.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          wormCfg = import ./eval-config.nix { inherit pkgs; };
          wormHelmValuesDir = pkgs.runCommand "worm-seaweed-helm-values" { } ''
            mkdir -p "$out"
            ln -s "${wormCfg.projects.wormS3Sample.rendered.seaweedHelmValuesYaml}" "$out/values.yaml"
          '';
          wormWriterIam = pkgs.writeText "writer-iam.json" wormCfg.projects.wormS3Sample.rendered.writerIamPolicyJson;
          wormStaticVerify = pkgs.writeShellApplication {
            name = "worm-static-verify";
            runtimeInputs = [
              pkgs.bash
              pkgs.jq
              pkgs.yq-go
            ];
            text = ''
              export WORM_SEAWEED_VALUES="${wormHelmValuesDir}/values.yaml"
              export WORM_WRITER_IAM_JSON="${wormWriterIam}"
              exec bash ${./scripts/static-verify.sh}
            '';
          };
          wormK3dE2e = pkgs.writeShellApplication {
            name = "worm-k3d-e2e";
            runtimeInputs = [
              pkgs.bash
              pkgs.curl
              pkgs.k3d
              pkgs.kubectl
              pkgs.kubernetes-helm
              pkgs.awscli2
              pkgs.jq
              pkgs.yq-go
              pkgs.python3
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gawk
            ];
            text = ''
              export WORM_SEAWEED_VALUES="${wormHelmValuesDir}/values.yaml"
              # Pin Helm from this flake so a Homebrew/system `helm` (<3.16) cannot win on PATH (missing `fromToml`).
              export WORM_HELM="${pkgs.kubernetes-helm}/bin/helm"
              export WORM_AUDIT_FLUENT_MANIFEST="${./scripts/worm-s3-audit-fluent.k8s.yaml}"
              bash ${./scripts/k3d-e2e.sh}
            '';
          };
        in
        {
          default = wormHelmValuesDir;
          worm-seaweed-helm-values = wormHelmValuesDir;
          worm-writer-iam-policy = wormWriterIam;
          worm-static-verify = wormStaticVerify;
          worm-k3d-e2e = wormK3dE2e;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          p = self.packages.${system};
        in
        {
          worm-static-verify = {
            type = "app";
            program = "${p.worm-static-verify}/bin/worm-static-verify";
            meta = {
              description = "Static checks: WORM YAML + reference IAM (no cluster)";
              mainProgram = "worm-static-verify";
            };
          };
          worm-k3d-e2e = {
            type = "app";
            program = "${p.worm-k3d-e2e}/bin/worm-k3d-e2e";
            meta = {
              description = "k3d + SeaweedFS helm + S3 object-lock API e2e (needs Docker)";
              mainProgram = "worm-k3d-e2e";
            };
          };
          worm-show-helm-values = {
            type = "app";
            program = (pkgs.writeShellScript "worm-show-helm-values" "cat \"${p.worm-seaweed-helm-values}/values.yaml\"").outPath;
            meta = {
              description = "Print generated SeaweedFS Helm values.yaml to stdout";
              mainProgram = "worm-show-helm-values";
            };
          };
          worm-show-writer-iam = {
            type = "app";
            program = (pkgs.writeShellScript "worm-show-writer-iam" "cat \"${p.worm-writer-iam-policy}\"").outPath;
            meta = {
              description = "Print reference writer IAM policy JSON to stdout";
              mainProgram = "worm-show-writer-iam";
            };
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          worm-static = pkgs.runCommand "worm-static-check-${system}" {
            nativeBuildInputs = [ self.packages.${system}.worm-static-verify ];
          } ''
            ${self.packages.${system}.worm-static-verify}/bin/worm-static-verify
            mkdir "$out"
            echo ok > "$out/result"
          '';
        }
      );
    };
}
