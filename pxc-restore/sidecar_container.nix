# Only the script changes: bash -> POSIX sh. Everything else stays the same.
# Key differences:
# - no [[ ... ]], no local, no ${var,,}, no pipefail
# - jq filters unchanged
# - use tr/grep and POSIX test [ ... ]
#
# If your image doesn’t have /bin/sh or doesn’t have jq/kubectl, adjust IMAGE.

{ lib, pkgs, ... }:

let
  SOURCE_NS = "source-namespace";
  DEST_NS   = "restore-namespace";

  DEST_PXC_CLUSTER  = "cluster1";
  DEST_STORAGE_NAME = "s3-us-west";

  SA_NAME           = "pxc-auto-restore-sa";
  CLUSTER_ROLE_NAME = "pxc-auto-restore";
  DEPLOYMENT_NAME   = "pxc-auto-restore-controller";

  TRACKING_CM       = "pxc-restore-tracker";
  SLEEP_SECONDS     = "60";

  IMAGE             = "bskim45/helm-kubectl-jq:latest";

  controllerScript = ''
    set -eu

    log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

    # Exit cleanly on teardown so this pod never blocks anything
    trap 'log "SIGTERM received, exiting controller"; exit 0' TERM INT

    require_env() {
      v="$1"
      eval "val=\${$v-}"
      if [ -z "$val" ]; then
        log "FATAL: env var $v is required"
        exit 1
      fi
    }

    require_env SOURCE_NS
    require_env DEST_NS
    require_env DEST_PXC_CLUSTER
    require_env DEST_STORAGE_NAME
    require_env TRACKING_CM
    require_env SLEEP_SECONDS

    get_last_restore_record() {
      completed="$(kubectl -n "$DEST_NS" get cm "$TRACKING_CM" -o jsonpath='{.data.last_completed}' 2>/dev/null || true)"
      destination="$(kubectl -n "$DEST_NS" get cm "$TRACKING_CM" -o jsonpath='{.data.last_destination}' 2>/dev/null || true)"
      printf "%s|%s\n" "$completed" "$destination"
    }

    set_last_restore_record() {
      completed="$1"
      destination="$2"

      kubectl -n "$DEST_NS" create cm "$TRACKING_CM" \
        --from-literal=last_completed="$completed" \
        --from-literal=last_destination="$destination" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    }

    newest_backup_json() {
      kubectl -n "$SOURCE_NS" get perconaxtradbclusterbackups.pxc.percona.com -o json --request-timeout=10s \
        | jq -c '
            .items
            | map(select(.status.state=="Succeeded"))
            | sort_by(.status.completed // .metadata.creationTimestamp)
            | last // empty
          '
    }

    restore_in_progress() {
      n="$(
        kubectl -n "$DEST_NS" get perconaxtradbclusterrestores.pxc.percona.com -o json --request-timeout=10s 2>/dev/null \
          | jq -r '([.items[]? | select((.status.state // "") | test("^(Starting|Running)$"))] | length) // 0' 2>/dev/null \
          | tr -d ' \n\r\t'
      )"

      if [ -z "${n-}" ]; then n="0"; fi
      # numeric compare in POSIX sh: use -gt
      if [ "$n" -gt 0 ]; then
        return 0
      fi
      return 1
    }

    create_restore_cr() {
      restore_name="$1"
      destination="$2"

      cat <<YAML | kubectl -n "$DEST_NS" apply -f -
    apiVersion: pxc.percona.com/v1
    kind: PerconaXtraDBClusterRestore
    metadata:
      name: ${restore_name}
    spec:
      pxcCluster: ${DEST_PXC_CLUSTER}
      backupSource:
        destination: ${destination}
        storageName: ${DEST_STORAGE_NAME}
    YAML
    }

    wait_restore_succeeded() {
      restore_name="$1"
      timeout_seconds="$2"

      start="$(date +%s)"

      while :; do
        state="$(
          kubectl -n "$DEST_NS" get perconaxtradbclusterrestores.pxc.percona.com "$restore_name" -o json --request-timeout=10s 2>/dev/null \
            | jq -r '.status.state // ""' 2>/dev/null || true
        )"

        if [ "$state" = "Succeeded" ]; then
          return 0
        fi
        if [ "$state" = "Failed" ] || [ "$state" = "Error" ]; then
          log "Restore $restore_name ended in state=$state"
          return 1
        fi

        now="$(date +%s)"
        elapsed=$(( now - start ))
        if [ "$elapsed" -gt "$timeout_seconds" ]; then
          log "Timed out waiting for restore $restore_name to succeed (last state=$state)"
          return 2
        fi

        sleep 10
      done
    }

    log "pxc-auto-restore controller starting. source=$SOURCE_NS dest=$DEST_NS destCluster=$DEST_PXC_CLUSTER"

    while :; do
      if restore_in_progress; then
        log "Restore already in progress in $DEST_NS; sleeping $SLEEP_SECONDS"
        sleep "$SLEEP_SECONDS"
        continue
      fi

      backup="$(newest_backup_json 2>/dev/null || true)"
      if [ -z "$backup" ]; then
        log "No Succeeded backup found in $SOURCE_NS; sleeping $SLEEP_SECONDS"
        sleep "$SLEEP_SECONDS"
        continue
      fi

      newest_completed="$(printf "%s" "$backup" | jq -r '.status.completed // ""')"
      newest_destination="$(printf "%s" "$backup" | jq -r '.status.destination // ""')"

      if [ -z "$newest_destination" ]; then
        log "Newest backup has empty .status.destination; cannot restore-to-new-cluster; sleeping $SLEEP_SECONDS"
        sleep "$SLEEP_SECONDS"
        continue
      fi

      record="$(get_last_restore_record)"
      last_completed="$(printf "%s" "$record" | cut -d'|' -f1)"
      last_destination="$(printf "%s" "$record" | cut -d'|' -f2- )"

      if [ -n "$last_completed" ] && [ "$last_completed" = "$newest_completed" ] && [ "$last_destination" = "$newest_destination" ]; then
        log "Already restored latest backup (completed=$newest_completed); sleeping $SLEEP_SECONDS"
        sleep "$SLEEP_SECONDS"
        continue
      fi

      restore_name="auto-restore-$(date -u '+%Y%m%d%H%M%S')"
      log "Triggering restore $restore_name from destination=$newest_destination (completed=$newest_completed)"

      create_restore_cr "$restore_name" "$newest_destination"

      if wait_restore_succeeded "$restore_name" 7200; then
        log "Restore succeeded: $restore_name; recording completed=$newest_completed destination=$newest_destination"
        set_last_restore_record "$newest_completed" "$newest_destination"
      else
        log "Restore did not succeed (name=$restore_name). Will retry on next loop."
      fi

      sleep "$SLEEP_SECONDS"
    done
  '';

  resources = [
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = { name = SA_NAME; namespace = DEST_NS; };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      metadata = { name = CLUSTER_ROLE_NAME; };
      rules = [
        { apiGroups = [ "pxc.percona.com" ]; resources = [ "perconaxtradbclusterbackups" ]; verbs = [ "get" "list" "watch" ]; }
        { apiGroups = [ "pxc.percona.com" ]; resources = [ "perconaxtradbclusterrestores" ]; verbs = [ "get" "list" "watch" "create" "patch" "update" ]; }
        { apiGroups = [ "" ]; resources = [ "configmaps" ]; verbs = [ "get" "create" "patch" "update" ]; }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      metadata = { name = CLUSTER_ROLE_NAME; };
      subjects = [ { kind = "ServiceAccount"; name = SA_NAME; namespace = DEST_NS; } ];
      roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "ClusterRole"; name = CLUSTER_ROLE_NAME; };
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = { name = DEPLOYMENT_NAME; namespace = DEST_NS; };
      spec = {
        replicas = 1;
        selector = { matchLabels = { app = DEPLOYMENT_NAME; }; };
        template = {
          metadata = { labels = { app = DEPLOYMENT_NAME; }; };
          spec = {
            serviceAccountName = SA_NAME;
            containers = [
              {
                name = "controller";
                image = IMAGE;
                imagePullPolicy = "IfNotPresent";
                command = [ "/bin/sh" "-c" ];
                args = [ controllerScript ];
                env = [
                  { name = "SOURCE_NS"; value = SOURCE_NS; }
                  { name = "DEST_NS"; value = DEST_NS; }
                  { name = "DEST_PXC_CLUSTER"; value = DEST_PXC_CLUSTER; }
                  { name = "DEST_STORAGE_NAME"; value = DEST_STORAGE_NAME; }
                  { name = "TRACKING_CM"; value = TRACKING_CM; }
                  { name = "SLEEP_SECONDS"; value = SLEEP_SECONDS; }
                ];
              }
            ];
          };
        };
      };
    }
  ];

  yaml = lib.concatStringsSep "\n---\n" (map (r: lib.generators.toYAML { } r) resources);

in
{
  pxcAutoRestoreControllerManifest = pkgs.writeText "pxc-auto-restore-controller.yaml" yaml;
}

