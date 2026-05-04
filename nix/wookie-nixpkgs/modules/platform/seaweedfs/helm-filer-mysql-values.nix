# Helm values fragment for SeaweedFS chart 4.17.x: MySQL/MariaDB-backed filer metadata.
#
# Upstream chart review (seaweedfs-4.17.0.tgz):
# - There is no `mariadb:` (or other DB) subchart in Chart.yaml; the chart does not deploy MariaDB.
# - Filer pods merge `filer.extraEnvironmentVars` into the container env (templates/filer/filer-statefulset.yaml).
# - `WEED_MYSQL_USERNAME` / `WEED_MYSQL_PASSWORD` are injected from Secret `<release>-seaweedfs-db-secret`
#   (keys `user`, `password`), from templates/shared/secret-seaweedfs-db.yaml (helm pre-install hook).
# - Chart defaults keep `WEED_MYSQL_ENABLED: "false"` and `WEED_LEVELDB2_ENABLED: "true"`; for SQL metadata,
#   enable MySQL env vars and set `WEED_LEVELDB2_ENABLED` to "false" as below.
# - Run MariaDB/MySQL separately, create the `filemeta` table (SQL in chart README), and align credentials
#   with `<release>-seaweedfs-db-secret` or manage credentials via your own Secret + overrides.

{ lib }:

let
  inherit (lib) optionalAttrs;

in
{
  /*
    Attrset to merge into Helm `values` for chart package `charts.seaweedfs."4_17_0"`.

    `hostname`: DNS name reachable from filer pods (e.g. `mariadb.namespace.svc.cluster.local`).

    Merge with your base values, e.g. `lib.recursiveUpdate baseValues (seaweedfsHelm417FilerMysqlValues { ... })`.
  */
  seaweedfsHelm417FilerMysqlValues =
    {
      hostname,
      database ? "sw_database",
      port ? "3306",
      maxIdle ? "5",
      maxOpen ? "75",
      maxLifetimeSeconds ? "600",
      interpolateParams ? true,
      filerReplicas ? null,
      extraFilerEnv ? { },
    }:
    {
      filer =
        {
          extraEnvironmentVars =
            {
              WEED_MYSQL_ENABLED = "true";
              WEED_MYSQL_HOSTNAME = hostname;
              WEED_MYSQL_PORT = port;
              WEED_MYSQL_DATABASE = database;
              WEED_MYSQL_CONNECTION_MAX_IDLE = maxIdle;
              WEED_MYSQL_CONNECTION_MAX_OPEN = maxOpen;
              WEED_MYSQL_CONNECTION_MAX_LIFETIME_SECONDS = maxLifetimeSeconds;
              WEED_MYSQL_INTERPOLATEPARAMS = if interpolateParams then "true" else "false";
              WEED_LEVELDB2_ENABLED = "false";
            }
            // extraFilerEnv;
        }
        // optionalAttrs (filerReplicas != null) { replicas = filerReplicas; };
    };
}
