#!/usr/bin/env bash
set -euo pipefail

# Automated Phase 0 + Phase 1 bootstrap for platform_unified_data_gcp:
#   1. Verifies gcloud/tofu prerequisites and active gcloud identity
#   2. Auto-discovers (or reuses existing terraform.tfvars) Org, Billing, and GitHub repo values
#   3. Validates all inputs against infra/bootstrap/variables.tf regex contracts
#   4. Idempotently binds required base Org IAM roles and verifies Billing Account admin access
#   5. Ensures Application Default Credentials (ADC) match the active Org Admin
#   6. Atomically writes infra/bootstrap/terraform.tfvars
#   7. Automatically runs `tofu init`, `tofu plan`, and `tofu apply` in infra/bootstrap

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_DIR="${PROJECT_DIR}/infra/bootstrap"
TFVARS_FILE="${BOOTSTRAP_TFVARS_PATH:-${BOOTSTRAP_DIR}/terraform.tfvars}"

CLI_ORG_ID=""
CLI_BILLING_ACCOUNT_ID=""
CLI_GITHUB_REPO=""
CLI_SEED_PROJECT_ID=""
CLI_DEV_PROJECT_ID=""
CLI_BUDGET_ALERT_EMAIL=""
CLI_PLATFORM_NAME=""
CLI_REGION=""
CLI_COST_CENTER=""
CLI_ADMIN_USER=""
SKIP_ADC_CHECK="false"
AUTO_APPROVE="false"
SKIP_APPLY="false"
NON_INTERACTIVE="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: bootstrap_init.sh [OPTIONS]

Automates base GCP Org IAM setup, ADC verification, population of
platform_unified_data_gcp/infra/bootstrap/terraform.tfvars, and OpenTofu
init / plan / apply for bootstrap.

Options:
  --org-id <id>                Numeric GCP Organization ID (auto-discovered if omitted)
  --billing-account <id>       GCP Billing Account ID XXXXXX-XXXXXX-XXXXXX (auto-discovered if omitted)
  --github-repo <owner/repo>   GitHub repository for WIF trust (parsed from git origin if omitted)
  --seed-project-id <id>       Base Seed GCP Project ID prefix (4-25 chars; OpenTofu appends -xxxx)
  --dev-project-id <id>        Base Dev GCP Project ID prefix (4-25 chars; synced to UDP_GCP_DEV_PROJECT_ID)
  --budget-alert-email <email> Email for dev budget alerts (synced to UDP_GCP_BUDGET_ALERT_EMAIL)
  --platform-name <slug>       Platform slug (default: unified-data-platform)
  --region <region>            Primary GCP region (default: us-central1)
  --cost-center <label>        Cost center label (default: engineering-playground)
  --admin-user <email>         Org Admin identity email (default: active gcloud account)
  --skip-adc-check             Skip Application Default Credentials check/refresh
  --auto-approve               Apply the generated tfplan without an interactive confirmation prompt
  --skip-apply                 Run `tofu init` and `tofu plan` only (do not run `tofu apply`)
  --non-interactive            Never prompt on stdin (requires --auto-approve or --skip-apply unless --dry-run)
  --dry-run                    Validate inputs and print planned actions without mutating GCP, files, or OpenTofu state
  -h, --help                   Show this help message and exit
EOF
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_err() {
  printf '[ERROR] %s\n' "$*" >&2
}

die_prereq() {
  log_err "$*"
  exit 1
}

die_usage() {
  log_err "$*"
  exit 2
}

require_arg_value() {
  local flag="$1"
  local remaining="$2"
  if [[ "$remaining" -lt 2 ]]; then
    die_usage "Missing value for ${flag}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org-id)
        require_arg_value "$1" "$#"
        CLI_ORG_ID="$2"
        shift 2
        ;;
      --billing-account)
        require_arg_value "$1" "$#"
        CLI_BILLING_ACCOUNT_ID="$2"
        shift 2
        ;;
      --github-repo)
        require_arg_value "$1" "$#"
        CLI_GITHUB_REPO="$2"
        shift 2
        ;;
      --seed-project-id)
        require_arg_value "$1" "$#"
        CLI_SEED_PROJECT_ID="$2"
        shift 2
        ;;
      --dev-project-id)
        require_arg_value "$1" "$#"
        CLI_DEV_PROJECT_ID="$2"
        shift 2
        ;;
      --budget-alert-email)
        require_arg_value "$1" "$#"
        CLI_BUDGET_ALERT_EMAIL="$2"
        shift 2
        ;;
      --platform-name)
        require_arg_value "$1" "$#"
        CLI_PLATFORM_NAME="$2"
        shift 2
        ;;
      --region)
        require_arg_value "$1" "$#"
        CLI_REGION="$2"
        shift 2
        ;;
      --cost-center)
        require_arg_value "$1" "$#"
        CLI_COST_CENTER="$2"
        shift 2
        ;;
      --admin-user)
        require_arg_value "$1" "$#"
        CLI_ADMIN_USER="$2"
        shift 2
        ;;
      --skip-adc-check)
        SKIP_ADC_CHECK="true"
        shift
        ;;
      --auto-approve)
        AUTO_APPROVE="true"
        shift
        ;;
      --skip-apply)
        SKIP_APPLY="true"
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die_usage "Unknown argument: $1 (use --help for usage)"
        ;;
    esac
  done
}

# Read an existing string assignment from terraform.tfvars if present.
read_tfvar() {
  local key="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*\"", "", $0)
      sub("\"[[:space:]]*(#.*)?$", "", $0)
      print $0
      exit
    }
  ' "$file"
}

detect_github_repo() {
  local remote_url=""
  remote_url="$(git -C "${PROJECT_DIR}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    return 0
  fi
  if [[ "$remote_url" =~ github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(\.git)?$ ]]; then
    local repo="${BASH_REMATCH[1]}"
    printf '%s' "${repo%.git}"
  fi
}

prompt_if_interactive() {
  local label="$1"
  local current="$2"
  local result="$current"

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    printf '%s' "$result"
    return 0
  fi

  if [[ -n "$current" ]]; then
    printf '%s [%s]: ' "$label" "$current" >&2
  else
    printf '%s: ' "$label" >&2
  fi

  local input=""
  if IFS= read -r input; then
    if [[ -n "$input" ]]; then
      result="$input"
    fi
  fi
  printf '%s' "$result"
}

validate_inputs() {
  local valid="true"

  if [[ "$AUTO_APPROVE" == "true" && "$SKIP_APPLY" == "true" ]]; then
    log_err "--auto-approve and --skip-apply are mutually exclusive."
    valid="false"
  fi

  if [[ "$NON_INTERACTIVE" == "true" && "$DRY_RUN" != "true" && "$AUTO_APPROVE" != "true" && "$SKIP_APPLY" != "true" ]]; then
    log_err "--non-interactive requires either --auto-approve or --skip-apply (unless --dry-run is set)."
    valid="false"
  fi

  if [[ -z "$ADMIN_USER" || ! "$ADMIN_USER" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    log_err "Invalid admin_user '${ADMIN_USER}'. Authenticate with 'gcloud auth login' or pass --admin-user <email>."
    valid="false"
  fi

  if [[ ! "$ORG_ID" =~ ^[0-9]+$ ]]; then
    log_err "Invalid org_id '${ORG_ID}'. Must be a numeric GCP Organization ID (digits only)."
    valid="false"
  fi

  if [[ ! "$BILLING_ACCOUNT_ID" =~ ^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$ ]]; then
    log_err "Invalid billing_account_id '${BILLING_ACCOUNT_ID}'. Must match XXXXXX-XXXXXX-XXXXXX."
    valid="false"
  fi

  if [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    log_err "Invalid github_repository '${GITHUB_REPO}'. Must match owner/repo format."
    valid="false"
  fi

  if [[ ! "$PLATFORM_NAME" =~ ^[a-z][a-z0-9-]{2,28}[a-z0-9]$ ]]; then
    log_err "Invalid platform_name '${PLATFORM_NAME}'. Must be 4-30 lowercase alphanumeric characters or hyphens."
    valid="false"
  fi

  if [[ ! "$SEED_PROJECT_ID" =~ ^[a-z][a-z0-9-]{2,23}[a-z0-9]$ ]]; then
    log_err "Invalid seed_project_id '${SEED_PROJECT_ID}'. Must be 4-25 lowercase letters, digits, or hyphens (OpenTofu appends a random -xxxx suffix)."
    valid="false"
  fi

  if [[ ! "$DEV_PROJECT_ID" =~ ^[a-z][a-z0-9-]{2,23}[a-z0-9]$ ]]; then
    log_err "Invalid dev_project_id '${DEV_PROJECT_ID}'. Must be 4-25 lowercase letters, digits, or hyphens (OpenTofu appends a random -xxxx suffix)."
    valid="false"
  fi

  if [[ -z "$BUDGET_ALERT_EMAIL" || ! "$BUDGET_ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    log_err "Invalid budget_alert_email '${BUDGET_ALERT_EMAIL}'. Must be a valid email address."
    valid="false"
  fi

  if [[ ! "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
    log_err "Invalid region '${REGION}'. Must be a valid GCP region (e.g., us-central1)."
    valid="false"
  fi

  if [[ ! "$COST_CENTER" =~ ^[a-z][a-z0-9_-]{1,61}[a-z0-9]$ ]]; then
    log_err "Invalid cost_center '${COST_CENTER}'. Must be a valid lowercase GCP label value."
    valid="false"
  fi

  if [[ "$valid" != "true" ]]; then
    exit 2
  fi
}

check_prerequisites() {
  if ! command -v gcloud >/dev/null 2>&1; then
    die_prereq "gcloud CLI not found on PATH. Install Google Cloud SDK before running bootstrap_init.sh."
  fi
  if ! command -v tofu >/dev/null 2>&1; then
    die_prereq "tofu (OpenTofu) not found on PATH. Install via: brew install opentofu"
  fi
}

render_tfvars() {
  cat <<EOF
org_id             = "${ORG_ID}"
billing_account_id = "${BILLING_ACCOUNT_ID}"
github_repository  = "${GITHUB_REPO}"
platform_name      = "${PLATFORM_NAME}"
seed_project_id    = "${SEED_PROJECT_ID}"
dev_project_id     = "${DEV_PROJECT_ID}"
budget_alert_email = "${BUDGET_ALERT_EMAIL}"
region             = "${REGION}"
cost_center        = "${COST_CENTER}"
EOF
}

ensure_github_token() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would ensure GITHUB_TOKEN is available for integrations/github provider"
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log_info "Using GITHUB_TOKEN from environment for integrations/github provider."
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    local gh_token=""
    if gh_token="$(gh auth token 2>/dev/null)" && [[ -n "$gh_token" ]]; then
      export GITHUB_TOKEN="$gh_token"
      log_info "Exported GITHUB_TOKEN from authenticated GitHub CLI (gh auth token)."
      return 0
    fi
  fi

  die_prereq "GITHUB_TOKEN is not set and 'gh auth token' is unavailable. Authenticate with 'gh auth login' (with repo scope) or export GITHUB_TOKEN with Actions variables write access so OpenTofu can manage GitHub Actions repository variables."
}

grant_base_org_iam() {
  local roles=(
    "roles/resourcemanager.folderAdmin"
    "roles/resourcemanager.projectCreator"
    "roles/billing.admin"
  )

  for role in "${roles[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] Would bind ${role} on organizations/${ORG_ID} for user:${ADMIN_USER}"
    else
      log_info "Binding ${role} on organizations/${ORG_ID} for user:${ADMIN_USER}..."
      gcloud organizations add-iam-policy-binding "${ORG_ID}" \
        --member="user:${ADMIN_USER}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null \
        || die_prereq "Failed to grant ${role} on organizations/${ORG_ID}. Verify ${ADMIN_USER} holds Organization Administrator (roles/resourcemanager.organizationAdmin)."
    fi
  done
}

verify_billing_iam() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would verify roles/billing.admin access on billingAccounts/${BILLING_ACCOUNT_ID} for user:${ADMIN_USER}"
    return 0
  fi

  local max_attempts="${BOOTSTRAP_BILLING_RETRIES:-3}"
  local retry_delay="${BOOTSTRAP_BILLING_DELAY_SECONDS:-5}"
  local attempt=1
  local policy_output=""
  local last_err=""

  log_info "Verifying Billing Account IAM visibility on ${BILLING_ACCOUNT_ID} for user:${ADMIN_USER}..."
  while [[ "$attempt" -le "$max_attempts" ]]; do
    local err_file
    err_file="$(mktemp)"
    if policy_output="$(gcloud billing accounts get-iam-policy "${BILLING_ACCOUNT_ID}" --format=json 2>"$err_file")"; then
      rm -f "$err_file"
      # Succeeds when user holds roles/billing.admin directly OR inherited from organizations/${ORG_ID}.
      log_info "Verified Billing Account IAM access on ${BILLING_ACCOUNT_ID}."
      return 0
    fi
    last_err="$(cat "$err_file")"
    rm -f "$err_file"

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log_warn "Billing IAM check attempt ${attempt}/${max_attempts} failed (waiting ${retry_delay}s for IAM propagation)..."
      sleep "$retry_delay"
    fi
    attempt=$((attempt + 1))
  done

  if [[ -n "$last_err" ]]; then
    log_err "gcloud output: ${last_err}"
  fi
  die_prereq "Cannot read IAM policy for Billing Account ${BILLING_ACCOUNT_ID} as ${ADMIN_USER}. If this Billing Account lives outside organizations/${ORG_ID} (e.g., under a personal @gmail.com account), sign into Console -> Billing -> Account Management as the billing owner and grant 'Billing Account Administrator' (roles/billing.admin) to ${ADMIN_USER}, then re-run this script."
}

ensure_adc_matches_admin() {
  if [[ "$SKIP_ADC_CHECK" == "true" ]]; then
    log_info "Skipping ADC check (--skip-adc-check)."
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would verify Application Default Credentials (ADC) match ${ADMIN_USER}"
    return 0
  fi

  local adc_file="${HOME}/.config/gcloud/application_default_credentials.json"
  local needs_refresh="false"
  local adc_email=""

  if [[ ! -f "$adc_file" ]]; then
    log_warn "No Application Default Credentials file found at ${adc_file}."
    needs_refresh="true"
  else
    local token=""
    if token="$(gcloud auth application-default print-access-token 2>/dev/null)" && command -v curl >/dev/null 2>&1; then
      local token_info=""
      token_info="$(curl -fsS "https://oauth2.googleapis.com/tokeninfo?access_token=${token}" 2>/dev/null || true)"
      adc_email="$(printf '%s' "$token_info" | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
      if [[ -n "$adc_email" && "$adc_email" != "$ADMIN_USER" ]]; then
        log_warn "ADC is currently authenticated as '${adc_email}', but Org Admin is '${ADMIN_USER}'."
        needs_refresh="true"
      fi
    else
      log_warn "Existing ADC token is expired or unreadable."
      needs_refresh="true"
    fi
  fi

  if [[ "$needs_refresh" == "true" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die_prereq "ADC is missing, expired, or bound to '${adc_email:-unknown}' instead of '${ADMIN_USER}'. Run 'gcloud auth application-default login' as ${ADMIN_USER} and retry."
    fi
    log_info "Launching 'gcloud auth application-default login' — sign in as ${ADMIN_USER}..."
    gcloud auth application-default login
  else
    log_info "Verified ADC matches active Org Admin (${adc_email:-${ADMIN_USER}})."
  fi

  if [[ -f "$adc_file" ]] && grep -q '"quota_project_id"' "$adc_file"; then
    log_warn "ADC contains a quota_project_id in ${adc_file}. If tofu apply fails with USER_PROJECT_DENIED on a fresh org, remove quota_project_id or re-run 'gcloud auth application-default login'."
  fi
}

write_tfvars_atomically() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would write ${TFVARS_FILE} with:"
    printf '\n'
    render_tfvars
    printf '\n'
    return 0
  fi

  mkdir -p "$(dirname "${TFVARS_FILE}")"
  local tmp_file
  tmp_file="$(mktemp "${TFVARS_FILE}.tmp.XXXXXX")"
  render_tfvars > "$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "${TFVARS_FILE}"
  log_info "Wrote ${TFVARS_FILE} (mode 600, gitignored)."
}

run_bootstrap_tofu() {
  local plan_file="${BOOTSTRAP_DIR}/tfplan"
  local var_file_args=("-var-file=${TFVARS_FILE}")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would run: tofu -chdir=${BOOTSTRAP_DIR} init -input=false"
    log_info "[dry-run] Would run: tofu -chdir=${BOOTSTRAP_DIR} plan -input=false -var-file=${TFVARS_FILE} -out=${plan_file}"
    if [[ "$SKIP_APPLY" == "true" ]]; then
      log_info "[dry-run] Would skip tofu apply (--skip-apply)."
    else
      log_info "[dry-run] Would run: tofu -chdir=${BOOTSTRAP_DIR} apply -input=false ${plan_file}"
    fi
    return 0
  fi

  local iam_wait="${BOOTSTRAP_IAM_WAIT_SECONDS:-10}"
  if [[ "$iam_wait" -gt 0 ]]; then
    log_info "Waiting ${iam_wait}s for newly applied Org IAM bindings to propagate before OpenTofu..."
    sleep "$iam_wait"
  fi

  trap 'rm -f "${plan_file}"' EXIT

  log_info "Running tofu init in ${BOOTSTRAP_DIR}..."
  tofu -chdir="${BOOTSTRAP_DIR}" init -input=false

  log_info "Running tofu plan in ${BOOTSTRAP_DIR}..."
  tofu -chdir="${BOOTSTRAP_DIR}" plan -input=false "${var_file_args[@]}" -out="${plan_file}"

  if [[ "$SKIP_APPLY" == "true" ]]; then
    log_info "Skipping tofu apply (--skip-apply)."
    rm -f "${plan_file}"
    trap - EXIT
    return 0
  fi

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    local confirm=""
    printf '\nApply this bootstrap plan now? Type "yes" to proceed: ' >&2
    IFS= read -r confirm || true
    if [[ "$confirm" != "yes" ]]; then
      log_warn "Apply cancelled by user. Re-run this script (or run 'cd ${BOOTSTRAP_DIR} && tofu apply') when ready."
      rm -f "${plan_file}"
      trap - EXIT
      exit 0
    fi
  fi

  log_info "Running tofu apply in ${BOOTSTRAP_DIR}..."
  tofu -chdir="${BOOTSTRAP_DIR}" apply -input=false "${plan_file}"

  rm -f "${plan_file}"
  trap - EXIT
}

main() {
  parse_args "$@"
  check_prerequisites

  # 1. Load existing terraform.tfvars values (if present) for idempotency
  local existing_org_id existing_billing existing_repo existing_platform existing_seed existing_dev existing_alert_email existing_region existing_cost_center
  existing_org_id="$(read_tfvar "org_id" "$TFVARS_FILE")"
  existing_billing="$(read_tfvar "billing_account_id" "$TFVARS_FILE")"
  existing_repo="$(read_tfvar "github_repository" "$TFVARS_FILE")"
  existing_platform="$(read_tfvar "platform_name" "$TFVARS_FILE")"
  existing_seed="$(read_tfvar "seed_project_id" "$TFVARS_FILE")"
  existing_dev="$(read_tfvar "dev_project_id" "$TFVARS_FILE")"
  existing_alert_email="$(read_tfvar "budget_alert_email" "$TFVARS_FILE")"
  existing_region="$(read_tfvar "region" "$TFVARS_FILE")"
  existing_cost_center="$(read_tfvar "cost_center" "$TFVARS_FILE")"

  # 2. Auto-discover missing metadata from gcloud and git
  local detected_admin="" detected_org="" detected_billing="" detected_repo=""
  detected_admin="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ "$detected_admin" == "(unset)" ]]; then
    detected_admin=""
  fi

  ADMIN_USER="${CLI_ADMIN_USER:-${detected_admin}}"

  if [[ -z "$CLI_ORG_ID" && -z "$existing_org_id" ]]; then
    detected_org="$(gcloud organizations list --format="value(ID)" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$CLI_BILLING_ACCOUNT_ID" && -z "$existing_billing" ]]; then
    detected_billing="$(gcloud billing accounts list --filter="open=true" --format="value(ACCOUNT_ID)" 2>/dev/null | head -n 1 || true)"
    detected_billing="${detected_billing#billingAccounts/}"
  fi
  if [[ -z "$CLI_GITHUB_REPO" && -z "$existing_repo" ]]; then
    detected_repo="$(detect_github_repo || true)"
  fi

  ORG_ID="${CLI_ORG_ID:-${existing_org_id:-${detected_org}}}"
  BILLING_ACCOUNT_ID="${CLI_BILLING_ACCOUNT_ID:-${existing_billing:-${detected_billing}}}"
  GITHUB_REPO="${CLI_GITHUB_REPO:-${existing_repo:-${detected_repo}}}"
  PLATFORM_NAME="${CLI_PLATFORM_NAME:-${existing_platform:-unified-data-platform}}"
  REGION="${CLI_REGION:-${existing_region:-us-central1}}"
  COST_CENTER="${CLI_COST_CENTER:-${existing_cost_center:-engineering-playground}}"

  local owner_slug=""
  owner_slug="$(printf '%s' "${GITHUB_REPO%%/*}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-12)"

  local suggested_seed="${existing_seed}"
  if [[ -z "$suggested_seed" && "$NON_INTERACTIVE" != "true" ]]; then
    if [[ -n "$owner_slug" ]]; then
      suggested_seed="udp-seed-${owner_slug}"
    else
      suggested_seed="udp-seed-001"
    fi
  fi
  SEED_PROJECT_ID="${CLI_SEED_PROJECT_ID:-${suggested_seed}}"

  local suggested_dev="${existing_dev}"
  if [[ -z "$suggested_dev" ]]; then
    if [[ -n "$owner_slug" ]]; then
      suggested_dev="udp-dev-${owner_slug}"
    else
      suggested_dev="udp-dev-001"
    fi
  fi
  DEV_PROJECT_ID="${CLI_DEV_PROJECT_ID:-${suggested_dev}}"
  BUDGET_ALERT_EMAIL="${CLI_BUDGET_ALERT_EMAIL:-${existing_alert_email:-${ADMIN_USER}}}"

  # 3. Interactive confirmation/override for any missing or default values
  if [[ "$NON_INTERACTIVE" != "true" ]]; then
    log_info "Confirm bootstrap parameters (press Enter to accept defaults):"
    ADMIN_USER="$(prompt_if_interactive "Org Admin email" "$ADMIN_USER")"
    ORG_ID="$(prompt_if_interactive "GCP Organization ID" "$ORG_ID")"
    BILLING_ACCOUNT_ID="$(prompt_if_interactive "GCP Billing Account ID" "$BILLING_ACCOUNT_ID")"
    GITHUB_REPO="$(prompt_if_interactive "GitHub repository (owner/repo)" "$GITHUB_REPO")"
    SEED_PROJECT_ID="$(prompt_if_interactive "Seed GCP Project ID prefix (OpenTofu appends -xxxx)" "$SEED_PROJECT_ID")"
    DEV_PROJECT_ID="$(prompt_if_interactive "Dev GCP Project ID prefix (synced to GitHub Actions)" "$DEV_PROJECT_ID")"
    BUDGET_ALERT_EMAIL="$(prompt_if_interactive "Dev budget alert email (synced to GitHub Actions)" "$BUDGET_ALERT_EMAIL")"
    PLATFORM_NAME="$(prompt_if_interactive "Platform name" "$PLATFORM_NAME")"
    REGION="$(prompt_if_interactive "Primary GCP region" "$REGION")"
    COST_CENTER="$(prompt_if_interactive "Cost center label" "$COST_CENTER")"
  fi

  # 4. Validate all inputs before any GCP mutation, file write, or OpenTofu run
  validate_inputs

  # 5. Grant base Org IAM roles, verify Billing Account admin access, ADC, and GitHub token
  grant_base_org_iam
  verify_billing_iam
  ensure_adc_matches_admin
  ensure_github_token

  # 6. Populate infra/bootstrap/terraform.tfvars
  write_tfvars_atomically

  # 7. Run OpenTofu init, plan, and apply
  run_bootstrap_tofu

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Complete. No GCP IAM changes, files, or OpenTofu state were modified."
  elif [[ "$SKIP_APPLY" == "true" ]]; then
    log_info "Bootstrap preflight and plan complete (apply skipped). Run without --skip-apply to provision."
  else
    log_info "Bootstrap apply complete! Proceed to Phase 2 in platform_unified_data_gcp/README.md to migrate state to Cloud KMS-encrypted GCS."
  fi
}

main "$@"
