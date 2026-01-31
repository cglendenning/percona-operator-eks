{ lib, ... }:

{ namespace ? "observability"
, pmmBaseUrl ? null
, pmmServiceAccountName ? "svc-observability"
, k8sSecretName ? "pmm-service-account-token"
, adminCredsSecretName ? "pmm-admin-creds"
}:

let
  ns = namespace;
  baseUrl = if pmmBaseUrl != null then pmmBaseUrl else "http://pmm.${ns}.svc.cluster.local";
in
{
  resources = [
    # --- RBAC so the job can create/update the output Secret ---
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = { name = "pmm-token-bootstrap"; namespace = ns; };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = { name = "pmm-token-bootstrap"; namespace = ns; };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          verbs = [ "get" "create" "patch" "update" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = { name = "pmm-token-bootstrap"; namespace = ns; };
      subjects = [
        { kind = "ServiceAccount"; name = "pmm-token-bootstrap"; namespace = ns; }
      ];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "pmm-token-bootstrap";
      };
    }

    # --- The bootstrap Job ---
    {
      apiVersion = "batch/v1";
      kind = "Job";
      metadata = {
        name = "pmm-create-serviceaccount-token";
        namespace = ns;
        labels = { app = "pmm-token-bootstrap"; };
      };
      spec = {
        backoffLimit = 2;
        ttlSecondsAfterFinished = 300;
        template = {
          metadata = {
            name = "pmm-create-serviceaccount-token";
            labels = { app = "pmm-token-bootstrap"; };
          };
          spec = {
            serviceAccountName = "pmm-token-bootstrap";
            restartPolicy = "Never";

            containers = [
              {
                name = "bootstrap";
                image = "bitnami/kubectl:latest";
                imagePullPolicy = "IfNotPresent";

                env = [
                  { name = "PMM_BASE_URL"; value = baseUrl; }
                  { name = "PMM_SA_NAME"; value = pmmServiceAccountName; }
                  { name = "OUT_SECRET"; value = k8sSecretName; }
                  { name = "NAMESPACE"; value = ns; }

                  {
                    name = "PMM_ADMIN_USER";
                    valueFrom = { secretKeyRef = { name = adminCredsSecretName; key = "username"; }; };
                  }
                  {
                    name = "PMM_ADMIN_PASS";
                    valueFrom = { secretKeyRef = { name = adminCredsSecretName; key = "password"; }; };
                  }
                ];

                command = [ "bash" "-lc" ];
                args = [ ''
                  set -euo pipefail

                  echo "Waiting for Grafana API at ${PMM_BASE_URL}..."
                  for i in $(seq 1 120); do
                    if curl -fsS "${PMM_BASE_URL}/api/health" >/dev/null 2>&1; then
                      echo "Grafana API ready."
                      break
                    fi
                    if [ "$i" -eq 120 ]; then
                      echo "ERROR: Grafana API did not become ready in time." >&2
                      exit 1
                    fi
                    sleep 2
                  done

                  # 1) Find existing service account id (Grafana API)
                  query="$(jq -nr --arg n "${PMM_SA_NAME}" '$n | @uri')"
                  sa_id="$(
                    curl -fsS -u "${PMM_ADMIN_USER}:${PMM_ADMIN_PASS}" \
                      "${PMM_BASE_URL}/api/serviceaccounts/search?perpage=1000&page=1&query=${query}" \
                    | jq -r --arg n "${PMM_SA_NAME}" '
                      .serviceAccounts[]? | select(.name==$n) | .id
                    ' | head -n1
                  )"

                  if [ -z "${sa_id}" ] || [ "${sa_id}" = "null" ]; then
                    echo "Creating service account ${PMM_SA_NAME}..."
                    sa_id="$(
                      curl -fsS -u "${PMM_ADMIN_USER}:${PMM_ADMIN_PASS}" \
                        -H 'Content-Type: application/json' \
                        -d "$(jq -n --arg name "${PMM_SA_NAME}" '{name:$name, role:"Admin", isDisabled:false}')" \
                        "${PMM_BASE_URL}/api/serviceaccounts" | jq -r '.id'
                    )"
                  fi

                  echo "Service account id: ${sa_id}"

                  # 2) Create a token for that service account (POST /api/serviceaccounts/:id/tokens)
                  # secondsToLive=0 => never expires
                  token_name="bootstrap-$(date +%Y%m%d%H%M%S)"
                  token="$(
                    curl -fsS -u "${PMM_ADMIN_USER}:${PMM_ADMIN_PASS}" \
                      -H 'Content-Type: application/json' \
                      -d "$(jq -n --arg name "${token_name}" '{name:$name, secondsToLive:0}')" \
                      "${PMM_BASE_URL}/api/serviceaccounts/${sa_id}/tokens" | jq -r '.key'
                  )"

                  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
                    echo "ERROR: token creation returned empty key" >&2
                    exit 1
                  fi

                  echo "Upserting Kubernetes secret ${OUT_SECRET} in namespace ${NAMESPACE}..."

                  # Write token into a Secret as stringData (kubectl will handle base64)
                  cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
                  apiVersion: v1
                  kind: Secret
                  metadata:
                    name: ${OUT_SECRET}
                  type: Opaque
                  stringData:
                    token: "${token}"
                  EOF

                  echo "Done."
                '' ];
              }
            ];
          };
        };
      };
    }
  ];
}

