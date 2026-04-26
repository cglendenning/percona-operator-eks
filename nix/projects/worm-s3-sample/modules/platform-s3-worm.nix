# Platform-side contract: WORM / Object Lock defaults and reference IAM for writers.
# Apps (project modules) supply the bucket name; platform supplies security invariants.

{ config, lib, pkgs, ... }:

let
  cfg = config.platform.s3Worm;
  inherit (lib) mkEnableOption mkOption types mkIf;

  # Reference IAM policy document for app credentials (attach in your IdP / K8s SA / etc.).
  # SeaweedFS S3 IAM may differ from AWS; treat as baseline deny-list for audits.
  writerPolicyForBucket = bucketName: {
    Version = "2012-10-17";
    Statement = [
      {
        Sid = "AllowListBucket";
        Effect = "Allow";
        Action = [ "s3:ListBucket" "s3:ListBucketVersions" ];
        Resource = "arn:aws:s3:::${bucketName}";
      }
      {
        Sid = "AllowReadWriteObjects";
        Effect = "Allow";
        Action = [
          "s3:GetObject"
          "s3:GetObjectVersion"
          "s3:PutObject"
          "s3:AbortMultipartUpload"
          "s3:ListMultipartUploadParts"
        ];
        Resource = "arn:aws:s3:::${bucketName}/*";
      }
      {
        Sid = "DenyDeletes";
        Effect = "Deny";
        Action = [
          "s3:DeleteObject"
          "s3:DeleteObjectVersion"
          "s3:DeleteBucket"
        ];
        Resource = [
          "arn:aws:s3:::${bucketName}"
          "arn:aws:s3:::${bucketName}/*"
        ];
      }
      {
        Sid = "DenyLockTampering";
        Effect = "Deny";
        Action = [
          "s3:PutBucketObjectLockConfiguration"
          "s3:PutBucketVersioning"
          "s3:PutObjectRetention"
          "s3:PutObjectLegalHold"
          "s3:BypassGovernanceRetention"
        ];
        Resource = [
          "arn:aws:s3:::${bucketName}"
          "arn:aws:s3:::${bucketName}/*"
        ];
      }
    ];
  };

  seaweedFilerS3Fragment = bucketName: {
    enabled = true;
    enableAuth = false;
    createBuckets = [
      {
        name = bucketName;
        objectLock = true;
        versioning = "Enabled";
        anonymousRead = false;
      }
    ];
  };

in
{
  options.platform.s3Worm = {
    enable = mkEnableOption "platform WORM / Object Lock baseline for S3 buckets";

    minRetentionDays = mkOption {
      type = types.int;
      default = 1;
      description = "Minimum default retention (days) enforced at evaluation time for project buckets.";
    };

    requireObjectLockOnCreate = mkOption {
      type = types.bool;
      default = true;
      description = "If true, project bucket specs must set objectLock = true.";
    };

    requireVersioningEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "If true, project bucket specs must enable versioning.";
    };

    writerIamPolicyJsonFor = mkOption {
      type = types.functionTo types.str;
      default = _: "{}";
      visible = false;
      description = "Internal: bucket name -> IAM policy JSON string for writer role.";
    };

    seaweedHelmFilerS3For = mkOption {
      type = types.functionTo types.anything;
      default = _: { };
      visible = false;
      description = "Internal: bucket name -> filer.s3 Helm fragment.";
    };
  };

  config = mkIf cfg.enable {

    platform.s3Worm.writerIamPolicyJsonFor =
      bucketName: builtins.toJSON (writerPolicyForBucket bucketName);

    platform.s3Worm.seaweedHelmFilerS3For = seaweedFilerS3Fragment;
  };
}
