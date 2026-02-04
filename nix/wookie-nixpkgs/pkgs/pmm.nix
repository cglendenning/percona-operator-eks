{ lib, ... }:

{
  mkPMMServiceAccountSidecar = {
    saName ? "wookie-pmm-sa",
    saRole ? "Admin",
    tokenName ? "wookie-pmm-token",
    adminUser ? "admin",
    adminPassword,
    tokenSecretName ? null,
    tokenSecretKey ? "pmmservertoken",
    sharedTokenMountPath ? "/var/run/pmm-sa",
    sharedTokenFilename ? "token",
    grafanaURL ? "http://127.0.0.1:3000",
    image ? "alpine:3.19",
  }:
  let
    tokenFile = "${sharedTokenMountPath}/${sharedTokenFilename}";
    
    sidecarScript = ''
      apk add --no-cache curl >/dev/null

      auth="-u ${"$"}PMM_ADMIN_USER:${"$"}PMM_ADMIN_PASS"

      echo "[pmm-sa] waiting for Grafana ${"$"}GRAFANA_URL ..."
      until curl -sS ${"$"}auth "${"$"}GRAFANA_URL/api/health" >/dev/null; do
        sleep 2
      done

      echo "[pmm-sa] looking for service account ${"$"}SA_NAME ..."
      sa_json="$(curl -sS ${"$"}auth "${"$"}GRAFANA_URL/api/serviceaccounts/search?query=${"$"}SA_NAME&perpage=10&page=1")"
      sa_id="$(echo "${"$"}sa_json" | sed -n 's/.*"id":\([0-9][0-9]*\).*"name":"'"${"$"}SA_NAME"'".*/\1/p' | head -n1)"

      if [ -z "${"$"}sa_id" ]; then
        echo "[pmm-sa] creating service account ${"$"}SA_NAME role=${"$"}SA_ROLE ..."
        create_resp="$(curl -sS ${"$"}auth \
          -H 'Content-Type: application/json' \
          -X POST "${"$"}GRAFANA_URL/api/serviceaccounts" \
          -d "{\"name\":\"${"$"}SA_NAME\",\"role\":\"${"$"}SA_ROLE\"}")"
        sa_id="$(echo "${"$"}create_resp" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' | head -n1)"
      fi

      if [ -z "${"$"}sa_id" ]; then
        echo "[pmm-sa] ERROR: could not determine service account id"
        echo "${"$"}sa_json"
        exit 1
      fi

      curl -sS ${"$"}auth "${"$"}GRAFANA_URL/api/serviceaccounts/${"$"}sa_id" >/dev/null
      echo "[pmm-sa] service account id=${"$"}sa_id verified"

      echo "[pmm-sa] checking existing tokens for token name ${"$"}TOKEN_NAME ..."
      tokens_json="$(curl -sS ${"$"}auth "${"$"}GRAFANA_URL/api/serviceaccounts/${"$"}sa_id/tokens")"

      if echo "${"$"}tokens_json" | grep -q "\"name\":\"${"$"}TOKEN_NAME\""; then
        echo "[pmm-sa] token name already exists; not creating a new token"
      else
        echo "[pmm-sa] creating token ${"$"}TOKEN_NAME ..."
        token_resp="$(curl -sS ${"$"}auth \
          -H 'Content-Type: application/json' \
          -X POST "${"$"}GRAFANA_URL/api/serviceaccounts/${"$"}sa_id/tokens" \
          -d "{\"name\":\"${"$"}TOKEN_NAME\",\"secondsToLive\":0}")"

        token_val="$(echo "${"$"}token_resp" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p' | head -n1)"

        if [ -z "${"$"}token_val" ]; then
          echo "[pmm-sa] ERROR: token create did not return a key"
          echo "${"$"}token_resp"
          exit 1
        fi

        umask 077
        echo -n "${"$"}token_val" > "${"$"}TOKEN_FILE"
        echo
        echo "[pmm-sa] Token: ${"$"}token_val"
        echo "[pmm-sa] wrote token to ${"$"}TOKEN_FILE"
        echo ""
        echo "=== IMPORTANT ==="
        echo "Add this token to your Vault secret at:"
        echo "  - secret/pmm/wookie (key: token)"
        echo "  - All Percona locations that send metrics to PMM (key: pmmservertoken)"
        echo ""
        echo "To retrieve token later from pod:"
        echo "  kubectl exec <pod-name> -c pmm-serviceaccount-provisioner -- cat ${"$"}TOKEN_FILE"

        if [ -n "${"$"}{DESIRED_TOKEN_VALUE-}" ] && [ "${"$"}DESIRED_TOKEN_VALUE" != "${"$"}token_val" ]; then
          echo ""
          echo "[pmm-sa] WARNING: DESIRED_TOKEN_VALUE was provided but Grafana does not allow seeding token values."
          echo "[pmm-sa] WARNING: Created token != desired token."
        fi
      fi

      echo "[pmm-sa] done. sleeping."
      sleep 365d
    '';
  in
  {
    container = {
      name = "pmm-serviceaccount-provisioner";
      image = image;
      imagePullPolicy = "IfNotPresent";
      volumeMounts = [
        {
          name = "pmm-sa-token";
          mountPath = sharedTokenMountPath;
        }
      ];
      env = [
        { name = "GRAFANA_URL"; value = grafanaURL; }
        { name = "SA_NAME"; value = saName; }
        { name = "SA_ROLE"; value = saRole; }
        { name = "TOKEN_NAME"; value = tokenName; }
        { name = "TOKEN_FILE"; value = tokenFile; }
        { name = "PMM_ADMIN_USER"; value = adminUser; }
        { name = "PMM_ADMIN_PASS"; value = adminPassword; }
      ] ++ (if tokenSecretName != null then [
        {
          name = "DESIRED_TOKEN_VALUE";
          valueFrom.secretKeyRef = {
            name = tokenSecretName;
            key = tokenSecretKey;
          };
        }
      ] else []);
      command = [ "/bin/sh" "-ceu" ];
      args = [ sidecarScript ];
    };
    
    volume = {
      name = "pmm-sa-token";
      emptyDir = {};
    };
  };
}
