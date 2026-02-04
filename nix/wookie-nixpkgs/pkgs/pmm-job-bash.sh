kubectl -n "${NS}" exec "${POD}" -- env \
  PMM_ADMIN_USER="${PMM_ADMIN_USER}" \
  PMM_ADMIN_PASS="${PMM_ADMIN_PASS}" \
  SA_NAME="${SA_NAME}" \
  SA_ROLE="${SA_ROLE}" \
  TOKEN_NAME="${TOKEN_NAME}" \
  /bin/bash -ceu '
    set -o pipefail

    auth="-u ${PMM_ADMIN_USER}:${PMM_ADMIN_PASS}"
    base="http://127.0.0.1:3000"

    ensure_jq() {
      if command -v jq >/dev/null 2>&1; then
        return 0
      fi

      echo "jq not found; attempting to install..." >&2

      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq >/dev/null
      elif command -v microdnf >/dev/null 2>&1; then
        microdnf install -y jq >/dev/null
      elif command -v yum >/dev/null 2>&1; then
        yum install -y jq >/dev/null
      else
        echo "ERROR: No supported package manager found to install jq (apt-get/apk/microdnf/yum)." >&2
        return 1
      fi

      command -v jq >/dev/null 2>&1 || { echo "ERROR: jq install attempted but still not present." >&2; return 1; }
    }

    ensure_jq

    # Helper: curl JSON and return "status body"
    curl_json() {
      local method="$1"; shift
      local url="$1"; shift
      local data="${1-}"

      local body
      body="$(mktemp)"
      local code

      if [ -n "${data}" ]; then
        code="$(curl -sS ${auth} -H "Accept: application/json" -H "Content-Type: application/json" \
          -X "${method}" "${url}" -d "${data}" -o "${body}" -w "%{http_code}")"
      else
        code="$(curl -sS ${auth} -H "Accept: application/json" \
          -X "${method}" "${url}" -o "${body}" -w "%{http_code}")"
      fi

      echo "${code} ${body}"
    }

    # 1) Try to create the service account
    create_payload="$(jq -n --arg name "${SA_NAME}" --arg role "${SA_ROLE}" "{name:\$name, role:\$role}")"
    read -r create_code create_body < <(curl_json POST "${base}/api/serviceaccounts" "${create_payload}")

    # If create succeeded, it should include an id
    sa_id=""
    if [ "${create_code}" = "200" ] || [ "${create_code}" = "201" ]; then
      sa_id="$(jq -r ".id // empty" < "${create_body}")"
    fi

    # 2) If we didn’t get an id (already exists or other), search by name
    if [ -z "${sa_id}" ]; then
      read -r search_code search_body < <(curl_json GET "${base}/api/serviceaccounts/search?query=$(printf "%s" "${SA_NAME}" | jq -sRr @uri)&perpage=10&page=1")
      if [ "${search_code}" != "200" ]; then
        echo "ERROR: service account search failed (HTTP ${search_code})" >&2
        cat "${search_body}" >&2
        exit 1
      fi

      # Grafana search returns items; find exact name match and take id
      sa_id="$(jq -r --arg name "${SA_NAME}" ".serviceAccounts[]? | select(.name==\$name) | .id" < "${search_body}" | head -n1)"
    fi

    if [ -z "${sa_id}" ] || [ "${sa_id}" = "null" ]; then
      echo "ERROR: could not resolve service account id for name=${SA_NAME}" >&2
      echo "Create HTTP=${create_code}" >&2
      cat "${create_body}" >&2
      exit 1
    fi

    echo "Service account id: ${sa_id}"

    # 3) Create a token for that service account
    token_payload="$(jq -n --arg name "${TOKEN_NAME}" --argjson ttl 0 "{name:\$name, secondsToLive:\$ttl}")"
    read -r tok_code tok_body < <(curl_json POST "${base}/api/serviceaccounts/${sa_id}/tokens" "${token_payload}")

    if [ "${tok_code}" != "200" ] && [ "${tok_code}" != "201" ]; then
      echo "ERROR: token create failed (HTTP ${tok_code})" >&2
      cat "${tok_body}" >&2
      exit 1
    fi

    # Token value is returned once as "key"
    token_value="$(jq -r ".key // empty" < "${tok_body}")"
    if [ -z "${token_value}" ] || [ "${token_value}" = "null" ]; then
      echo "ERROR: token created but response did not include .key" >&2
      cat "${tok_body}" >&2
      exit 1
    fi

    echo "Service account token (save this; shown once):"
    echo "${token_value}"
  '

