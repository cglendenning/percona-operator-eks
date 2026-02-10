[200~# Sidecar that:
# - polls the SOURCE namespace for the most recent *Succeeded* pxc-backup
# - checks whether we’ve already restored from that backup (stored in a ConfigMap)
# - if not, creates a PerconaXtraDBClusterRestore in the DEST namespace
# - waits for restore to Succeed, then records the backup it used
#
# Notes:
# - Restore-to-new-cluster typically uses spec.backupSource.destination + storageName. :contentReference[oaicite:0]{index=0}
# - pxc-backup exposes .status.state and .status.completed (CRD printcolumns use these jsonPaths). :contentReference[oaicite:1]{index=1}

{ lib, ... }:
{
  pxc = {
    sidecars = [
      {
        name = "pxc-auto-restore";
        # Includes kubectl + jq + bash (handy for this kind of controller-y scripting). :contentReference[oaicite:2]{index=2}
        image = "bskim45/helm-kubectl-jq:latest";

        env = [
          # Where to *read* backups from
          { name = "SOURCE_NS"; value = "source-namespace"; }

          # Where to *create* restore resources + tracking ConfigMap
          { name = "DEST_NS"; value = "restore-namespace"; }

          # The name of the PXC cluster in DEST_NS you want to restore *into*
          { name = "DEST_PXC_CLUSTER"; value = "cluster1"; }

          # The storageName that exists in the DEST cluster CR (spec.backup.storages[...])
          # used by restore spec.backupSource.storageName. :contentReference[oaicite:3]{index=3}
          { name = "DEST_STORAGE_NAME"; value = "s3-us-west"; }

          # Tracking ConfigMap name in DEST_NS
          { name = "TRACKING_CM"; value = "pxc-restore-tracker"; }

          # How often to poll
          { name = "SLEEP_SECONDS"; value = "60"; }
        ];

        command = [ "/bin/bash" "-lc" ];
        args = [
          ''
            set -euo pipefail

            log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

            require_env() {
              local v="$1"
              if [[ -z "''${!v:-}" ]]; then
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

            # Reads last restored "completed timestamp" + destination string from a ConfigMap
            get_last_restore_record() {
              # returns: "<completed> <destination>" or empty strings if not set
              local completed destination
              completed="$(kubectl -n "$DEST_NS" get cm "$TRACKING_CM" -o jsonpath='{.data.last_completed}' 2>/dev/null || true)"
              destination="$(kubectl -n "$DEST_NS" get cm "$TRACKING_CM" -o jsonpath='{.data.last_destination}' 2>/dev/null || true)"
              echo "$completed|$destination"
            }

            set_last_restore_record() {
              local completed="$1"
              local destination="$2"

              kubectl -n "$DEST_NS" create cm "$TRACKING_CM" \
                --from-literal=last_completed="$completed" \
                --from-literal=last_destination="$destination" \
                --dry-run=client -o yaml | kubectl apply -f - >/dev/null
            }

            # Return JSON for the newest completed backup (Succeeded)
            newest_backup_json() {
              kubectl -n "$SOURCE_NS" get pxc-backup -o json \
                | jq -c '
                    .items
                    | map(select(.status.state=="Succeeded"))
                    | sort_by(.status.completed // .metadata.creationTimestamp)
                    | last // empty
                  '
            }

            # Safety: don’t start a new restore if one is already in progress in DEST_NS
            restore_in_progress() {
              local n
              n="$(kubectl -n "$DEST_NS" get pxc-restore -o json 2>/dev/null \
                    | jq '[.items[] | select((.status.state // "") | test("^(Starting|Running)$"))] | length' \
                    || echo "0")"
              [[ "$n" != "0" ]]
            }

            create_restore_cr() {
              local restore_name="$1"
              local destination="$2"

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
              local restore_name="$1"
              local timeout_seconds="$2"

              local start now state
              start="$(date +%s)"

              while true; do
                state="$(kubectl -n "$DEST_NS" get pxc-restore "$restore_name" -o json \
                          | jq -r '.status.state // ""' || true)"

                if [[ "$state" == "Succeeded" ]]; then
                  return 0
                fi
                if [[ "$state" == "Failed" || "$state" == "Error" ]]; then
                  log "Restore $restore_name ended in state=$state"
                  return 1
                fi

                now="$(date +%s)"
                if (( now - start > timeout_seconds )); then
                  log "Timed out waiting for restore $restore_name to succeed (last state=$state)"
                  return 2
                fi

                sleep 10
              done
            }

            log "pxc-auto-restore sidecar starting. source=$SOURCE_NS dest=$DEST_NS destCluster=$DEST_PXC_CLUSTER"

            while true; do
              if restore_in_progress; then
                log "Restore already in progress in $DEST_NS; sleeping $SLEEP_SECONDS"
                sleep "$SLEEP_SECONDS"
                continue
              fi

              backup="$(newest_backup_json || true)"
              if [[ -z "$backup" ]]; then
                log "No Succeeded pxc-backup found in $SOURCE_NS; sleeping $SLEEP_SECONDS"
                sleep "$SLEEP_SECONDS"
                continue
              fi

              newest_completed="$(echo "$backup" | jq -r '.status.completed // ""')"
              newest_destination="$(echo "$backup" | jq -r '.status.destination // ""')"

              # If destination is not present for your storage type, this will be empty.
              # For “restore to a new cluster”, Percona docs show destination is used in backupSource. :contentReference[oaicite:4]{index=4}
              if [[ -z "$newest_destination" ]]; then
                log "Newest backup has empty .status.destination; cannot restore-to-new-cluster; sleeping $SLEEP_SECONDS"
                sleep "$SLEEP_SECONDS"
                continue
              fi

              record="$(get_last_restore_record)"
              last_completed="''${record%%|*}"
              last_destination="''${record#*|}"

              if [[ -n "$last_completed" && "$last_completed" == "$newest_completed" && "$last_destination" == "$newest_destination" ]]; then
                log "Already restored latest backup (completed=$newest_completed); sleeping $SLEEP_SECONDS"
                sleep "$SLEEP_SECONDS"
                continue
              fi

              # Condition met:
              # - there is a completed backup in SOURCE_NS
              # - and we either never restored, or restored an older backup
              restore_name="auto-restore-$(date -u '+%Y%m%d%H%M%S')"
              log "Triggering restore $restore_name from destination=$newest_destination (completed=$newest_completed)"

              create_restore_cr "$restore_name" "$newest_destination"

              # Wait up to 2 hours (adjust if your restores are longer)
              if wait_restore_succeeded "$restore_name" 7200; then
                log "Restore succeeded: $restore_name; recording completed=$newest_completed destination=$newest_destination"
                set_last_restore_record "$newest_completed" "$newest_destination"
              else
                log "Restore did not succeed (name=$restore_name). Will retry on next loop."
              fi

              sleep "$SLEEP_SECONDS"
            done
          ''
        ];
      }
    ];
  };
}

