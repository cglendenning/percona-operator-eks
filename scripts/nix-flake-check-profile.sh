#!/usr/bin/env bash
# Profile why `nix flake check` is slow on a local flake (Linux/WSL friendly).
# Usage: scripts/nix-flake-check-profile.sh /path/to/flake-dir
#
# Requires: nix, jq, coreutils (GNU date, timeout). bash 4+.
set -euo pipefail

usage() {
  echo "usage: $0 <path-to-flake-directory>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
FLAKE_DIR="${1}"
if [[ ! -f "${FLAKE_DIR}/flake.nix" && ! -f "${FLAKE_DIR}/flake.flake" ]]; then
  echo "error: no flake.nix (or flake.flake) in ${FLAKE_DIR}" >&2
  exit 1
fi

for bin in nix jq awk; do
  command -v "${bin}" >/dev/null 2>&1 || {
    echo "error: missing required command: ${bin}" >&2
    exit 1
  }
done

HAVE_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=1
fi

flake_dir_abs="$(cd "${FLAKE_DIR}" && pwd)"
# Explicit path: form avoids ambiguous cwd when nix resolves the flake.
FLAKE_REF="path:${flake_dir_abs}"

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
NIX_VERSION="$(nix --version 2>/dev/null | awk '{print $3}')"

now_ns() {
  date +%s%N 2>/dev/null || date +%s
}

elapsed_ms() {
  local start="$1"
  local end
  end="$(now_ns)"
  if [[ "${#start}" -ge 18 && "${#end}" -ge 18 ]]; then
    echo $(( (end - start) / 1000000 ))
  else
    echo $(( (end - start) * 1000 ))
  fi
}

run_timed_ms() {
  local start rc=0
  start="$(now_ns)"
  "$@" >/dev/null 2>&1 || rc=$?
  elapsed_ms "${start}"
  return "${rc}"
}

json_has_top() {
  local json="$1"
  local key="$2"
  echo "${json}" | jq -e --arg k "${key}" 'has($k)' >/dev/null 2>&1
}

attr_names_json() {
  local expr="$1"
  nix eval "${FLAKE_REF}#${expr}" --apply 'builtins.attrNames' --json 2>/dev/null || echo '[]'
}

echo "== nix flake check profiler =="
echo "flake: ${FLAKE_REF}"
echo "currentSystem: ${SYSTEM}"
echo "nix: ${NIX_VERSION}"
echo

FLAKE_SHOW_JSON=""
if FLAKE_SHOW_JSON="$(nix flake show "${FLAKE_REF}" --json 2>/dev/null)"; then
  :
else
  echo "warning: nix flake show --json failed (network or eval). Continuing with nix eval probes." >&2
  FLAKE_SHOW_JSON="{}"
fi

checks_systems_json='[]'
if json_has_top "${FLAKE_SHOW_JSON}" checks; then
  checks_systems_json="$(echo "${FLAKE_SHOW_JSON}" | jq -c '[.checks // {} | keys[]]')"
elif checks_systems_json="$(nix eval "${FLAKE_REF}#checks" --apply 'builtins.attrNames' --json 2>/dev/null)"; then
  :
else
  checks_systems_json='[]'
fi
checks_system_count="$(echo "${checks_systems_json}" | jq 'length')"

echo "== cross-system breadth (checks.*) =="
echo "systems under checks: ${checks_system_count} $(echo "${checks_systems_json}" | jq -c '.')"
echo "note: plain nix flake check builds checks only for currentSystem unless you pass --all-systems."
echo

has_legacy=0
has_hydra=0
if json_has_top "${FLAKE_SHOW_JSON}" legacyPackages; then
  has_legacy=1
fi
if json_has_top "${FLAKE_SHOW_JSON}" hydraJobs; then
  has_hydra=1
fi
if [[ "${FLAKE_SHOW_JSON}" == "{}" ]]; then
  echo "warning: legacyPackages/hydraJobs detection skipped (flake show unavailable)." >&2
fi

echo "== flake outputs that inflate flake-check evaluation =="
echo "legacyPackages present: $([[ ${has_legacy} -eq 1 ]] && echo yes || echo no)"
echo "hydraJobs present: $([[ ${has_hydra} -eq 1 ]] && echo yes || echo no)"
echo "nix manual: legacyPackages.<system> is evaluated like nix-env --query --available; hydraJobs like hydra-eval-jobs."
echo

NO_BUILD_MS=-1
if [[ ${HAVE_TIMEOUT} -eq 1 ]]; then
  echo "== timing: nix flake check --no-build (timeout 120s; measures eval + non-build checks) =="
  start_nb="$(now_ns)"
  set +e
  out_nb="$(timeout 120s nix flake check "${FLAKE_REF}" --no-build 2>&1)"
  rc_nb=$?
  set -e
  NO_BUILD_MS="$(elapsed_ms "${start_nb}")"
  if [[ ${rc_nb} -eq 124 ]]; then
    echo "result: TIMEOUT after 120s (evaluation is the bottleneck)."
    echo "last lines:"
    echo "${out_nb}" | tail -n 20
  elif [[ ${rc_nb} -ne 0 ]]; then
    echo "result: failed (rc=${rc_nb}) after ${NO_BUILD_MS}ms"
    echo "${out_nb}" | tail -n 30
  else
    echo "result: ok in ${NO_BUILD_MS}ms"
  fi
else
  echo "== timing: nix flake check --no-build (skipped: no GNU timeout in PATH) =="
fi
echo

declare -a ROW_CAT=()
declare -a ROW_ATTR=()
declare -a ROW_MS=()

record_row() {
  ROW_CAT+=("$1")
  ROW_ATTR+=("$2")
  ROW_MS+=("$3")
}

time_nix_build_fragment() {
  local fragment="$1"
  local ms rc=0
  set +e
  ms="$(run_timed_ms nix build "${FLAKE_REF}#${fragment}" --no-link --accept-flake-config)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "-1"
  else
    echo "${ms}"
  fi
}

echo "== timing: per-derivation builds (serial; warm store benefits later rows) =="
echo "category\tattribute\tms"

checks_attrs_json="$(attr_names_json "checks.${SYSTEM}")"
for name in $(echo "${checks_attrs_json}" | jq -r '.[]'); do
  frag="checks.${SYSTEM}.${name}"
  ms="$(time_nix_build_fragment "${frag}")"
  echo -e "checks\t${frag}\t${ms}"
  record_row "checks" "${frag}" "${ms}"
done

pkgs_attrs_json="$(attr_names_json "packages.${SYSTEM}")"
for name in $(echo "${pkgs_attrs_json}" | jq -r '.[]'); do
  frag="packages.${SYSTEM}.${name}"
  ms="$(time_nix_build_fragment "${frag}")"
  echo -e "packages\t${frag}\t${ms}"
  record_row "packages" "${frag}" "${ms}"
done

devshell_attrs_json="$(attr_names_json "devShells.${SYSTEM}")"
for name in $(echo "${devshell_attrs_json}" | jq -r '.[]'); do
  frag="devShells.${SYSTEM}.${name}"
  ms="$(time_nix_build_fragment "${frag}")"
  echo -e "devShells\t${frag}\t${ms}"
  record_row "devShells" "${frag}" "${ms}"
done

nixos_names_json="$(attr_names_json "nixosConfigurations")"
for name in $(echo "${nixos_names_json}" | jq -r '.[]'); do
  frag="nixosConfigurations.${name}.config.system.build.toplevel"
  ms="$(time_nix_build_fragment "${frag}")"
  echo -e "nixosConfigurations\t${frag}\t${ms}"
  record_row "nixosConfigurations" "${frag}" "${ms}"
done

echo

echo "== timing: full nix flake check (may reuse store paths from prior builds) =="
start_full="$(now_ns)"
set +e
out_full="$(nix flake check "${FLAKE_REF}" --accept-flake-config 2>&1)"
rc_full=$?
set -e
FULL_MS="$(elapsed_ms "${start_full}")"
if [[ ${rc_full} -ne 0 ]]; then
  echo "result: failed (rc=${rc_full}) after ${FULL_MS}ms"
  echo "${out_full}" | tail -n 40
else
  echo "result: ok in ${FULL_MS}ms"
fi
echo

echo "== summary table (ms) =="
printf "%-20s %-9s %s\n" "category" "ms" "attribute"
max_ms=-1
max_attr=""
max_cat=""
sum_valid_ms=0
for i in "${!ROW_MS[@]}"; do
  ms="${ROW_MS[$i]}"
  if [[ "${ms}" =~ ^[0-9]+$ && "${ms}" -ge 0 ]]; then
    printf "%-20s %-9s %s\n" "${ROW_CAT[$i]}" "${ms}" "${ROW_ATTR[$i]}"
    sum_valid_ms=$((sum_valid_ms + ms))
    if [[ "${ms}" -gt ${max_ms} ]]; then
      max_ms="${ms}"
      max_attr="${ROW_ATTR[$i]}"
      max_cat="${ROW_CAT[$i]}"
    fi
  fi
done
echo "serial build sum (approx): ${sum_valid_ms}ms"
echo "full flake check wall: ${FULL_MS}ms"
echo

echo "== highest-impact single change (heuristic) =="
rec=""
if [[ ${NO_BUILD_MS} -ge 120000 ]]; then
  rec="Your flake-check evaluation phase hit the 120s probe cap (or timed out). The largest wins usually come from removing or isolating eval-heavy outputs: drop legacyPackages from outputs if present, split hydraJobs into another flake, or reduce deep/IFD-heavy module graphs so nix flake check --no-build is cheap."
elif [[ ${has_legacy} -eq 1 && ${NO_BUILD_MS} -ge 30000 ]]; then
  rec="legacyPackages is present and nix flake check --no-build took ${NO_BUILD_MS}ms. Remove legacyPackages from this flake's outputs (re-export nixpkgs elsewhere) or stop using flake check on this mega-flake; legacyPackages forces a nix-env-style package set evaluation during flake check."
elif [[ ${has_hydra} -eq 1 && ${NO_BUILD_MS} -ge 30000 ]]; then
  rec="hydraJobs is present and nix flake check --no-build took ${NO_BUILD_MS}ms. Move hydraJobs to a dedicated flake/CI job so developer flake checks do not pay hydra-eval-jobs-style evaluation."
elif [[ ${max_ms} -ge 0 && ${max_ms} -ge 1000 && ${sum_valid_ms} -ge $((FULL_MS * 3 / 2)) ]]; then
  rec="Build time is mostly serial heavy derivations; the slowest build measured was ${max_attr} (${max_ms}ms) under ${max_cat}. Slim that derivation (smaller nativeBuildInputs, avoid rebuilding large deps) or stop exposing it via packages/checks/devShells for routine flake check."
elif [[ ${max_ms} -lt 0 && ${rc_full:-0} -ne 0 ]]; then
  rec="nix flake check failed (eval error, missing store paths, or a check script exiting non-zero). Fix that first (see errors above or nix log on the reported .drv); until builds succeed, this script cannot rank per-derivation wall times."
elif [[ ${checks_system_count} -gt 2 ]]; then
  rec="checks defines ${checks_system_count} systems. If CI uses nix flake check --all-systems, you multiply work across systems; narrow the systems list to what you actually ship, or gate all-system checks to scheduled CI only."
else
  if [[ "${max_ms}" -lt 0 ]]; then
    rec="No per-output builds were successfully timed; re-run with network access and a healthy nix daemon. If evaluation is still slow, suspect legacyPackages/hydraJobs or IFD."
  else
    rec="No single smoking gun from coarse probes; next step is nix profiling (nix build --profile) on the slow attribute you care about, or split outputs so flake check does less."
  fi
fi
echo "${rec}"
if [[ ${rc_full:-0} -ne 0 ]]; then
  exit "${rc_full}"
fi
