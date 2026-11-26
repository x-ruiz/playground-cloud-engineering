#!/usr/bin/env bash
set -euo pipefail

# Offline unit tests for scripts/detect_affected_envs.sh (Spec 02 REQ-03 routing matrix).
# Builds throwaway project trees in a temp dir; zero network, Git, or GCP calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/detect_affected_envs.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PD="platform_unified_data_gcp"
failures=0

setup_tree() {
  local uat="$1" prod="$2"
  rm -rf "${TMP_ROOT:?}/${PD}"
  mkdir -p "${TMP_ROOT}/${PD}/infra/envs/uat" "${TMP_ROOT}/${PD}/infra/envs/prod"
  printf '# Managed by promote\nplatform_version: "%s"\n' "$uat" > "${TMP_ROOT}/${PD}/infra/envs/uat/release.yaml"
  printf '# Managed by promote\nplatform_version: "%s"\n' "$prod" > "${TMP_ROOT}/${PD}/infra/envs/prod/release.yaml"
}

expect() {
  local name="$1" expected="$2" input="$3"
  shift 3
  local actual
  actual="$(cd "$TMP_ROOT" && printf '%b' "$input" | bash "$DETECT" "$@" "$PD" 2>/dev/null)"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} (expected ${expected}, got ${actual})" >&2
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local name="$1"
  if (cd "$TMP_ROOT" && printf '' | bash "$DETECT" "$PD" >/dev/null 2>&1); then
    echo "FAIL: ${name} (expected non-zero exit)" >&2
    failures=$((failures + 1))
  else
    echo "PASS: ${name}"
  fi
}

# --- Day 0: uat & prod unreleased ---
setup_tree "unreleased" "unreleased"
expect "platform change -> dev only" '["dev"]' "${PD}/infra/platform/main.tf\n"
expect "module-versions bump -> dev only" '["dev"]' "${PD}/infra/platform/module-versions.yaml\n"
expect "root.hcl on day 0 -> dev only" '["dev"]' "${PD}/infra/envs/root.hcl\n"
expect "unreleased uat edit -> skipped" '[]' "${PD}/infra/envs/uat/terragrunt.hcl\n"
expect "scripts/specs/docs only -> none" '[]' "${PD}/scripts/detect_affected_envs.sh\n${PD}/specs/02_github_actions_cicd.md\n${PD}/README.md\n"
expect "apply workflow change -> dev" '["dev"]' ".github/workflows/udp-gcp-apply.yml\n"
expect "pr-check workflow change -> dev" '["dev"]' ".github/workflows/udp-gcp-pr-check.yml\n"
expect "promote workflow change -> none" '[]' ".github/workflows/udp-gcp-promote.yml\n"
expect "unrelated repo path -> none" '[]' "other_project/main.tf\n"
expect "--all on day 0 -> dev only" '["dev"]' "" --all

# --- uat released, prod unreleased ---
setup_tree "udp-gcp-v0.1.0" "unreleased"
expect "uat promotion PR -> uat only" '["uat"]' "${PD}/infra/envs/uat/release.yaml\n"
expect "platform change never touches uat" '["dev"]' "${PD}/infra/platform/main.tf\n"
expect "root.hcl -> dev + released uat" '["dev","uat"]' "${PD}/infra/envs/root.hcl\n"

# --- both released ---
setup_tree "udp-gcp-v0.2.0" "udp-gcp-v0.1.0"
expect "prod promotion PR -> prod only" '["prod"]' "${PD}/infra/envs/prod/release.yaml\n"
expect "prod config edit -> prod only (TC-007)" '["prod"]' "${PD}/infra/envs/prod/terragrunt.hcl\n"
expect "root.hcl -> dev, uat, prod ordered" '["dev","uat","prod"]' "${PD}/infra/envs/root.hcl\n"
expect "mixed prod+platform -> ordered dev,prod" '["dev","prod"]' "${PD}/infra/envs/prod/terragrunt.hcl\n${PD}/infra/platform/main.tf\n"
expect "--all -> dev, uat, prod" '["dev","uat","prod"]' "" --all

# --- graduation layout (PROJECT_DIR=".") ---
mkdir -p "${TMP_ROOT}/grad/infra/envs/uat" "${TMP_ROOT}/grad/infra/envs/prod"
printf 'platform_version: "udp-gcp-v1.0.0"\n' > "${TMP_ROOT}/grad/infra/envs/uat/release.yaml"
printf 'platform_version: "unreleased"\n' > "${TMP_ROOT}/grad/infra/envs/prod/release.yaml"
actual="$(cd "${TMP_ROOT}/grad" && printf 'infra/envs/uat/terragrunt.hcl\ninfra/platform/main.tf\n' | bash "$DETECT" . 2>/dev/null)"
if [[ "$actual" == '["dev","uat"]' ]]; then echo "PASS: graduated layout (PROJECT_DIR=.)"; else
  echo "FAIL: graduated layout (got ${actual})" >&2
  failures=$((failures + 1))
fi

# --- fail-closed schema guards ---
setup_tree "main" "unreleased"
expect_failure "floating ref in release.yaml fails closed"
setup_tree "v0.1.0" "unreleased"
expect_failure "missing udp-gcp- prefix fails closed"
setup_tree "unreleased" "unreleased"
rm "${TMP_ROOT}/${PD}/infra/envs/prod/release.yaml"
expect_failure "missing release.yaml fails closed"

if [[ $failures -gt 0 ]]; then
  echo "${failures} detect_affected_envs test(s) failed." >&2
  exit 1
fi
echo "All detect_affected_envs tests passed."
