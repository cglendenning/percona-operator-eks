#!/usr/bin/env bash
# Static checks (no cluster): IAM policy shape + Helm values WORM flags.
set -euo pipefail

VALUES="${WORM_SEAWEED_VALUES:?}"
POL="${WORM_WRITER_IAM_JSON:?}"

echo "==> Values: objectLock + versioning on first createBuckets entry"
yq -e '.filer.s3.createBuckets[0].objectLock == true' "$VALUES"
yq -e '(.filer.s3.createBuckets[0].versioning == "Enabled") or (.filer.s3.createBuckets[0].versioning == true)' "$VALUES"

echo "==> IAM: Deny includes delete and lock tampering"
jq -e '
  [.Statement[]
   | select(.Effect == "Deny")
   | (.Action | if type == "array" then . else [.] end)
   | .[]
  ] as $a
  | ($a | index("s3:DeleteObject")) != null
' "$POL" >/dev/null

jq -e '
  [.Statement[]
   | select(.Effect == "Deny")
   | (.Action | if type == "array" then . else [.] end)
   | .[]
  ] as $a
  | ($a | index("s3:PutBucketObjectLockConfiguration")) != null
' "$POL" >/dev/null

echo "==> Negative simulation: writer policy must not grant unconditional DeleteObject Allow"
# If any Allow statement included s3:DeleteObject without tight deny layering, fail (simple guard).
if jq -e '
  [.Statement[] | select(.Effect == "Allow") | (.Action | if type == "array" then . else [.] end) | .[]]
    | index("s3:DeleteObject") != null
' "$POL" >/dev/null 2>&1; then
  echo "FAIL: writer policy must not Allow s3:DeleteObject" >&2
  exit 1
fi

echo "Static verification OK."
