#!/usr/bin/env bash
set -euo pipefail

# Offline mocked test suite for scripts/bootstrap_init.sh (TC-015 & TC-016).
# Uses temporary stub `gcloud` and `tofu` binaries on PATH with zero network or GCP calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap_init.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_BIN="${TMP_ROOT}/bin"
mkdir -p "${STUB_BIN}"
GCLOUD_LOG="${TMP_ROOT}/gcloud_calls.log"
TOFU_LOG="${TMP_ROOT}/tofu_calls.log"
export GCLOUD_LOG TOFU_LOG

cat > "${STUB_BIN}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TOFU_LOG}"
for arg in "$@"; do
  if [[ "$arg" == -out=* ]]; then
    touch "${arg#-out=}"
  fi
done
exit 0
EOF
chmod +x "${STUB_BIN}/tofu"

cat > "${STUB_BIN}/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GCLOUD_LOG}"
case "$*" in
  "config get-value account")
    echo "admin@example.com"
    ;;
  "organizations list --format=value(ID)")
    echo "846182627456"
    ;;
  "billing accounts list --filter=open=true --format=value(ACCOUNT_ID)")
    echo "billingAccounts/01ABCD-23EFGH-45IJKL"
    ;;
  "organizations add-iam-policy-binding "*)
    exit 0
    ;;
  "billing accounts get-iam-policy "*)
    if [[ "${STUB_BILLING_FAIL:-false}" == "true" ]]; then
      echo "ERROR: PERMISSION_DENIED" >&2
      exit 1
    fi
    cat <<'JSON'
{"bindings":[{"members":["user:admin@example.com"],"role":"roles/billing.admin"}]}
JSON
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${STUB_BIN}/gcloud"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "auth token" ]]; then
  echo "gho_stub_test_token"
  exit 0
fi
exit 0
EOF
chmod +x "${STUB_BIN}/gh"

export PATH="${STUB_BIN}:${PATH}"
unset GITHUB_TOKEN || true
export BOOTSTRAP_BILLING_RETRIES=1
export BOOTSTRAP_BILLING_DELAY_SECONDS=0
export BOOTSTRAP_IAM_WAIT_SECONDS=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${msg} (expected to contain: ${needle})"
  fi
}

# --- TC-015a: Happy path auto-discovery, IAM bindings, tfvars, and tofu init/plan/apply ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_1="${TMP_ROOT}/tc015_happy.tfvars"
BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --github-repo "x-ruiz/playground-cloud-engineering" \
  --seed-project-id "udp-seed-test-001" >/dev/null

[[ -f "${TFVARS_1}" ]] || fail "TC-015a: terraform.tfvars was not created"
tfvars_content="$(cat "${TFVARS_1}")"
assert_contains "$tfvars_content" 'org_id             = "846182627456"' "TC-015a: org_id auto-discovered"
assert_contains "$tfvars_content" 'billing_account_id = "01ABCD-23EFGH-45IJKL"' "TC-015a: billing_account_id auto-discovered and stripped"
assert_contains "$tfvars_content" 'github_repository  = "x-ruiz/playground-cloud-engineering"' "TC-015a: github_repository written"
assert_contains "$tfvars_content" 'seed_project_id    = "udp-seed-test-001"' "TC-015a: seed_project_id written"
assert_contains "$tfvars_content" 'dev_project_id     = "udp-dev-x-ruiz"' "TC-015a: dev_project_id defaulted cleanly"
assert_contains "$tfvars_content" 'budget_alert_email = "admin@example.com"' "TC-015a: budget_alert_email defaulted cleanly"

gcloud_calls="$(cat "${GCLOUD_LOG}")"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/resourcemanager.folderAdmin" "TC-015a: folderAdmin bound"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/resourcemanager.projectCreator" "TC-015a: projectCreator bound"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/billing.admin" "TC-015a: billing.admin bound on org"
assert_contains "$gcloud_calls" "billing accounts get-iam-policy 01ABCD-23EFGH-45IJKL" "TC-015a: billing IAM verified"

tofu_calls="$(cat "${TOFU_LOG}")"
assert_contains "$tofu_calls" "init -input=false" "TC-015a: tofu init executed"
assert_contains "$tofu_calls" "plan -input=false -var-file=${TFVARS_1}" "TC-015a: tofu plan executed with tfvars"
assert_contains "$tofu_calls" "apply -input=false" "TC-015a: tofu apply executed"
pass "TC-015a: Auto-discovery, base Org IAM, Billing check, tfvars, and tofu init/plan/apply"

# --- TC-015b: --skip-apply runs init + plan only ---
: > "${TOFU_LOG}"
BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-apply \
  --skip-adc-check >/dev/null
tofu_calls="$(cat "${TOFU_LOG}")"
assert_contains "$tofu_calls" "init -input=false" "TC-015b: tofu init executed"
assert_contains "$tofu_calls" "plan -input=false" "TC-015b: tofu plan executed"
if grep -q "apply -input=false" "${TOFU_LOG}"; then
  fail "TC-015b: --skip-apply must not invoke tofu apply"
fi
pass "TC-015b: --skip-apply runs tofu init + plan and skips apply"

# --- TC-015c: Invalid org_id or missing non-interactive approval flag fails fast (exit 2) ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_BAD="${TMP_ROOT}/tc015_bad.tfvars"
set +e
BOOTSTRAP_TFVARS_PATH="${TFVARS_BAD}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --org-id "not-numeric" \
  --github-repo "x-ruiz/playground-cloud-engineering" \
  --seed-project-id "udp-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "TC-015c: expected exit code 2 for invalid org_id, got ${rc}"
[[ ! -f "${TFVARS_BAD}" ]] || fail "TC-015c: terraform.tfvars should not be written on validation failure"
if grep -q "add-iam-policy-binding" "${GCLOUD_LOG}" || [[ -s "${TOFU_LOG}" ]]; then
  fail "TC-015c: should not mutate GCP or call tofu when validation fails"
fi

set +e
BOOTSTRAP_TFVARS_PATH="${TFVARS_BAD}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-adc-check \
  --github-repo "x-ruiz/playground-cloud-engineering" \
  --seed-project-id "udp-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "TC-015c: expected exit code 2 when --non-interactive lacks --auto-approve/--skip-apply, got ${rc}"
pass "TC-015c: Invalid org_id and unsafe --non-interactive exit 2 with zero mutations"

# --- TC-015d: Missing billing admin permission exits 1 without writing tfvars or calling tofu ---
: > "${TOFU_LOG}"
TFVARS_NOBILL="${TMP_ROOT}/tc015_nobill.tfvars"
set +e
STUB_BILLING_FAIL="true" BOOTSTRAP_TFVARS_PATH="${TFVARS_NOBILL}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --github-repo "x-ruiz/playground-cloud-engineering" \
  --seed-project-id "udp-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "TC-015d: expected exit code 1 when billing IAM check fails, got ${rc}"
[[ ! -f "${TFVARS_NOBILL}" ]] || fail "TC-015d: terraform.tfvars should not be written when billing IAM fails"
[[ ! -s "${TOFU_LOG}" ]] || fail "TC-015d: tofu must not run when billing IAM fails"
pass "TC-015d: Missing billing.admin fails clearly with exit 1 before tfvars or tofu"

# --- TC-016a: Dry-run performs zero GCP IAM mutations, zero tofu calls, and writes no file ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_DRY="${TMP_ROOT}/tc016_dry.tfvars"
dry_out="$(BOOTSTRAP_TFVARS_PATH="${TFVARS_DRY}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-adc-check \
  --dry-run \
  --github-repo "x-ruiz/playground-cloud-engineering" \
  --seed-project-id "udp-seed-dry-001")"
[[ ! -f "${TFVARS_DRY}" ]] || fail "TC-016a: --dry-run must not write terraform.tfvars"
if grep -q "add-iam-policy-binding" "${GCLOUD_LOG}" || [[ -s "${TOFU_LOG}" ]]; then
  fail "TC-016a: --dry-run must not call add-iam-policy-binding or tofu"
fi
assert_contains "$dry_out" 'seed_project_id    = "udp-seed-dry-001"' "TC-016a: --dry-run prints rendered tfvars"
assert_contains "$dry_out" "Would run: tofu -chdir=" "TC-016a: --dry-run prints planned tofu commands"
pass "TC-016a: Dry-run performs zero GCP mutations, zero tofu calls, and writes no files"

# --- TC-016b: Re-running against existing terraform.tfvars preserves prior values idempotently ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
cat > "${TFVARS_1}" <<'EOF'
org_id             = "111222333444"
billing_account_id = "99AAAA-88BBBB-77CCCC"
github_repository  = "custom-org/custom-repo"
platform_name      = "custom-data-platform"
seed_project_id    = "udp-seed-custom-009"
region             = "us-east1"
cost_center        = "platform-core"
EOF

BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-apply \
  --skip-adc-check >/dev/null

tfvars_rerun="$(cat "${TFVARS_1}")"
assert_contains "$tfvars_rerun" 'org_id             = "111222333444"' "TC-016b: existing org_id preserved"
assert_contains "$tfvars_rerun" 'billing_account_id = "99AAAA-88BBBB-77CCCC"' "TC-016b: existing billing_account_id preserved"
assert_contains "$tfvars_rerun" 'github_repository  = "custom-org/custom-repo"' "TC-016b: existing github_repository preserved"
assert_contains "$tfvars_rerun" 'seed_project_id    = "udp-seed-custom-009"' "TC-016b: existing seed_project_id preserved"
assert_contains "$tfvars_rerun" 'region             = "us-east1"' "TC-016b: existing region preserved"
pass "TC-016b: Re-run preserves existing terraform.tfvars values idempotently"

printf '\nAll bootstrap_init.sh tests passed!\n'
