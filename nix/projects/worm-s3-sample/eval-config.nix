# Evaluates platform + project WORM sample modules. Used by flake.nix.

{ pkgs }:

let
  lib = pkgs.lib;
  raw =
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ./modules/platform-s3-worm.nix
        ./modules/project-worm-sample.nix
        {
          projects.wormS3Sample = {
            enable = true;
            bucketName = "worm-compliance-sample";
            defaultRetentionDays = 1;
          };
        }
      ];
    }).config;
in
if raw.platform.s3Worm.minRetentionDays < 1 then
  throw "platform.s3Worm.minRetentionDays must be >= 1"
else if !(raw.projects.wormS3Sample.defaultRetentionDays >= raw.platform.s3Worm.minRetentionDays) then
  throw "projects.wormS3Sample.defaultRetentionDays must be >= platform.s3Worm.minRetentionDays"
else if builtins.match "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" raw.projects.wormS3Sample.bucketName == null then
  throw "projects.wormS3Sample.bucketName must be a simple DNS-like S3 bucket name"
else
  raw
