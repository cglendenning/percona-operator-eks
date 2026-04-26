# Project-side sample: chooses bucket name and merges platform WORM rules into SeaweedFS Helm values.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf mkMerge;
  cfg = config.projects.wormS3Sample;
  yaml = pkgs.formats.yaml { };
in
{
  imports = [ ./platform-s3-worm.nix ];

  options.projects.wormS3Sample = {
    enable = mkEnableOption "sample project that declares a WORM S3 bucket via platform rules";

    bucketName = mkOption {
      type = types.str;
      example = "worm-compliance-sample";
      description = "S3 bucket name (must be DNS-compliant).";
    };

    defaultRetentionDays = mkOption {
      type = types.int;
      default = 1;
      description = "Declared default COMPLIANCE retention window in days (audit/config; must be >= platform.s3Worm.minRetentionDays).";
    };

    rendered = mkOption {
      type = types.nullOr (types.attrsOf types.anything);
      default = null;
      visible = false;
      description = "Internal: writer policy JSON string, Helm attrset, and generated values.yaml path.";
    };
  };

  config = mkIf cfg.enable {
    platform.s3Worm.enable = true;

    projects.wormS3Sample.rendered =
      let
        s3w = config.platform.s3Worm;
        seaweedHelmValues = {
          master = {
            enabled = true;
            replicas = 1;
          };
          volume = {
            enabled = true;
            replicas = 1;
            persistence = {
              enabled = true;
              storageClass = "local-path";
              size = "10Gi";
            };
          };
          filer = {
            enabled = true;
            replicas = 1;
            s3 = s3w.seaweedHelmFilerS3For cfg.bucketName;
            extraEnvironmentVars = {
              WEED_REPLICATION = "001";
            };
          };
        };
      in
      {
        writerIamPolicyJson = s3w.writerIamPolicyJsonFor cfg.bucketName;
        inherit seaweedHelmValues;
        seaweedHelmValuesYaml = yaml.generate "worm-seaweedfs-values.yaml" seaweedHelmValues;
      };
  };
}
