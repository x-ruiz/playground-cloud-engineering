#!/usr/bin/env bash
set -euo pipefail

# Deterministic change detection for udp-gcp-pr-check.yml and udp-gcp-apply.yml (Spec 02 REQ-03).
#
# Reads repository-relative changed file paths (one per line) on stdin and prints the affected
# environments as a compact JSON array, ordered dev -> uat -> prod (e.g. ["dev","uat"]).
#
# Routing (paths relative to <project_dir>):
#   infra/platform/**                -> dev
#   infra/envs/dev/**                -> dev
#   infra/envs/uat/**                -> uat  (only if uat/release.yaml != "unreleased")
#   infra/envs/prod/**               -> prod (only if prod/release.yaml != "unreleased")
#   infra/envs/root.hcl              -> dev + every released uat/prod
#   .github/workflows/udp-gcp-{pr-check,apply}.yml -> dev (exercises CI/CD changes against dev only)
#   anything else                    -> nothing (static checks only)
#
# Usage:
#   git diff --name-only A B | detect_affected_envs.sh [--all] <project_dir>
#     --all   ignore stdin and select dev + every released env (manual dispatch)
#
# Fails closed (exit 1) if a release.yaml is missing or holds a malformed platform_version.

usage() {
  echo "Usage: detect_affected_envs.sh [--all] <project_dir>" >&2
  exit 2
}

select_all=false
if [[ "${1:-}" == "--all" ]]; then
  select_all=true
  shift
fi
[[ $# -eq 1 ]] || usage

project_dir="${1%/}"
if [[ "$project_dir" == "." || -z "$project_dir" ]]; then
  prefix=""
else
  prefix="${project_dir}/"
fi
envs_dir="${project_dir}/infra/envs"

read_release() {
  local file="${envs_dir}/$1/release.yaml" version
  if [[ ! -f "$file" ]]; then
    echo "ERROR: ${file} not found." >&2
    exit 1
  fi
  version="$(sed -nE 's/^platform_version:[[:space:]]*"?([^"#[:space:]]*)"?.*$/\1/p' "$file" | head -n 1)"
  if [[ ! "$version" =~ ^(unreleased|udp-gcp-v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "ERROR: ${file} platform_version '${version}' must be \"unreleased\" or \"udp-gcp-vX.Y.Z\"." >&2
    exit 1
  fi
  printf '%s' "$version"
}

uat_version="$(read_release uat)" || exit 1
prod_version="$(read_release prod)" || exit 1
uat_released=false
prod_released=false
[[ "$uat_version" != "unreleased" ]] && uat_released=true
[[ "$prod_version" != "unreleased" ]] && prod_released=true

hit_dev=false
hit_uat=false
hit_prod=false

if [[ "$select_all" == true ]]; then
  hit_dev=true hit_uat=true hit_prod=true
else
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" ]] && continue
    case "$path" in
      "${prefix}infra/platform/"*) hit_dev=true ;;
      "${prefix}infra/envs/dev/"*) hit_dev=true ;;
      "${prefix}infra/envs/uat/"*) hit_uat=true ;;
      "${prefix}infra/envs/prod/"*) hit_prod=true ;;
      "${prefix}infra/envs/root.hcl") hit_dev=true hit_uat=true hit_prod=true ;;
      .github/workflows/udp-gcp-pr-check.yml|.github/workflows/udp-gcp-apply.yml) hit_dev=true ;;
    esac
  done
fi

result=()
[[ "$hit_dev" == true ]] && result+=("dev")
add_released() {
  local env="$1" hit="$2" released="$3"
  [[ "$hit" == true ]] || return 0
  if [[ "$released" == true ]]; then
    result+=("$env")
  else
    echo "NOTE: skipping ${env}: ${envs_dir}/${env}/release.yaml is \"unreleased\" (promote with udp-gcp-promote.yml first)." >&2
  fi
}
add_released uat "$hit_uat" "$uat_released"
add_released prod "$hit_prod" "$prod_released"

json="["
sep=""
for env in ${result[@]+"${result[@]}"}; do
  json+="${sep}\"${env}\""
  sep=","
done
json+="]"
printf '%s\n' "$json"
