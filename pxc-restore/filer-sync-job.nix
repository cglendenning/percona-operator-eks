[200~{ lib, ... }:

let
  # =========================
  # EDIT THESE
  # =========================

  NAMESPACE = "seaweedfs";

  # Source filer (in the OTHER cluster) - must be reachable from this cluster.
  # Use your LB/Ingress/DNS name here.
  SOURCE_FILER_URL = "http://seaweed-filer.your-source-dns-name:8888";

  # Dest filer (in THIS cluster) - normally the in-cluster service DNS.
  # Adjust service name/port to match your helm release.
  DEST_FILER_URL = "http://seaweedfs-filer.${NAMESPACE}.svc.cluster.local:8888";

  # Optional: if you want to scope sync to the S3 buckets path.
  # Leave "" to sync everything.
  SYNC_DIR = "/buckets";
in
{
  resources.jobs."seaweedfs-filer-sync" = {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata = {
      name = "seaweedfs-filer-sync";
      namespace = NAMESPACE;
      labels = {
        app = "seaweedfs-filer-sync";
      };
    };

    spec = {
      # Re-run if it ever exits/crashes
      backoffLimit = 6;
      template = {
        metadata = {
          labels = { app = "seaweedfs-filer-sync"; };
        };
        spec = {
          restartPolicy = "OnFailure";

          containers = [
            {
              name = "filer-sync";
              image = "chrislusf/seaweedfs:latest";
              imagePullPolicy = "IfNotPresent";

              command = [ "sh" "-lc" ];
              args = [
                ''
                  set -euo pipefail

                  echo "SOURCE_FILER_URL=${SOURCE_FILER_URL}"
                  echo "DEST_FILER_URL=${DEST_FILER_URL}"
                  echo "SYNC_DIR=${SYNC_DIR}"

                  # Wait for dest filer to be up (in-cluster)
                  until wget -qO- "${DEST_FILER_URL}/status" >/dev/null 2>&1; do
                    echo "Waiting for DEST filer..."
                    sleep 2
                  done

                  # Wait for source filer to be reachable (cross-cluster)
                  until wget -qO- "${SOURCE_FILER_URL}/status" >/dev/null 2>&1; do
                    echo "Waiting for SOURCE filer..."
                    sleep 2
                  done

                  # Run continuous sync (active -> passive)
                  # Notes:
                  # -isActivePassive=true means SOURCE wins; DEST mirrors.
                  # -dir is optional; use it to sync only buckets.
                  if [ -n "${SYNC_DIR}" ]; then
                    exec weed filer.sync \
                      -a "${SOURCE_FILER_URL}" \
                      -b "${DEST_FILER_URL}" \
                      -isActivePassive=true \
                      -dir "${SYNC_DIR}"
                  else
                    exec weed filer.sync \
                      -a "${SOURCE_FILER_URL}" \
                      -b "${DEST_FILER_URL}" \
                      -isActivePassive=true
                  fi
                ''
              ];
            }
          ];
        };
      };
    };
  };
}

