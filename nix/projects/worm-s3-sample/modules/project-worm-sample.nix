# Project-side sample: chooses bucket name and merges platform WORM rules into SeaweedFS Helm values.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf mkMerge recursiveUpdate;
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
            # S3 API audit: forward JSON to worm-s3-audit-fluent:24224 (k3d e2e deploys Fluent Bit before Helm).
            # filer.s3.enableAuth must be true or the SeaweedFS Helm chart does not mount /etc/sw, so
            # -s3.auditLogConfig=/etc/sw/filer_s3_auditLogConfig.json is missing and no audit is emitted.
            s3 = recursiveUpdate (s3w.seaweedHelmFilerS3For cfg.bucketName) {
              enableAuth = true;
              auditLogConfig = {
                fluent_host = "worm-s3-audit-fluent";
                fluent_port = 24224;
                fluent_network = "tcp";
                timeout = 3000;
                write_timeout = 0;
                buffer_limit = 8192;
                retry_wait = 500;
                max_retry = 13;
                max_retry_wait = 60000;
                tag_prefix = "";
              };
            };
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
