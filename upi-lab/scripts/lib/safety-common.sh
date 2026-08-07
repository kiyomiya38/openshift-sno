#!/usr/bin/env bash

# Shared guardrails for scripts that plan, apply, or remove lab resources.
# This file intentionally does not enable set options; callers own their shell mode.

LAB_PROJECT_NAME="${LAB_PROJECT_NAME:-openshift-upi-lab}"
LAB_EXPECTED_WORKSPACE="${LAB_EXPECTED_WORKSPACE:-default}"
LAB_EXPECTED_ACCOUNT_FILE="${LAB_EXPECTED_ACCOUNT_FILE:-$HOME/.config/openshift-upi-lab/expected-account-id}"
LAB_STATE_DIR="${LAB_STATE_DIR:-$HOME/.config/openshift-upi-lab}"

lab_safety_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

lab_validate_account_id() {
  [[ "$1" =~ ^[0-9]{12}$ ]]
}

lab_assert_default_workspace() {
  local terraform_dir="$1"
  local workspace

  workspace="$(terraform -chdir="$terraform_dir" workspace show 2>/dev/null)" \
    || lab_safety_error 'Unable to read the Terraform workspace. Run terraform init first.'
  [[ "$workspace" == "$LAB_EXPECTED_WORKSPACE" ]] \
    || lab_safety_error "Terraform workspace must be $LAB_EXPECTED_WORKSPACE; found $workspace."
}

# Resolve an account ID supplied independently of the active AWS session. Strict mode
# accepts only an environment variable or the pre-registered file. Legacy mode also
# accepts an account recorded in existing state, its backup, or the ACM ARN file so
# an environment created by an earlier runbook can still be safely destroyed.
lab_resolve_expected_account_id() {
  local mode="${1:-strict}"
  local terraform_dir="${2:-}"
  local certificate_arn_file="${3:-}"
  local expected_id=''
  local source_name=''
  local candidate=''

  if [[ -n ${EXPECTED_AWS_ACCOUNT_ID:-} ]]; then
    expected_id="$EXPECTED_AWS_ACCOUNT_ID"
    source_name='EXPECTED_AWS_ACCOUNT_ID'
  elif [[ -n ${TF_VAR_expected_account_id:-} ]]; then
    expected_id="$TF_VAR_expected_account_id"
    source_name='TF_VAR_expected_account_id'
  elif [[ -s "$LAB_EXPECTED_ACCOUNT_FILE" ]]; then
    expected_id="$(tr -d '[:space:]' <"$LAB_EXPECTED_ACCOUNT_FILE")"
    source_name="$LAB_EXPECTED_ACCOUNT_FILE"
  fi

  if [[ -n "$expected_id" ]]; then
    lab_validate_account_id "$expected_id" \
      || lab_safety_error "Expected AWS account from $source_name must contain exactly 12 digits."
    printf '%s\n' "$expected_id"
    return 0
  fi

  if [[ "$mode" == legacy && -n "$terraform_dir" ]]; then
    candidate="$(terraform -chdir="$terraform_dir" output -raw account_id 2>/dev/null || true)"
    if lab_validate_account_id "$candidate"; then
      printf 'WARN: Using the AWS account recorded in existing Terraform state for legacy cleanup compatibility.\n' >&2
      printf '%s\n' "$candidate"
      return 0
    fi

    if [[ -s "$terraform_dir/terraform.tfstate.backup" ]]; then
      candidate="$(jq -r '.outputs.account_id.value // empty' \
        "$terraform_dir/terraform.tfstate.backup" 2>/dev/null || true)"
      if lab_validate_account_id "$candidate"; then
        printf 'WARN: Using the AWS account recorded in terraform.tfstate.backup for legacy cleanup compatibility.\n' >&2
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  if [[ "$mode" == legacy && -s "$certificate_arn_file" ]]; then
    candidate="$(sed -nE 's#^arn:aws:acm:[^:]+:([0-9]{12}):certificate/.+$#\1#p' \
      "$certificate_arn_file")"
    if lab_validate_account_id "$candidate"; then
      printf 'WARN: Using the AWS account encoded in the retained ACM certificate ARN for legacy cleanup compatibility.\n' >&2
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  lab_safety_error \
    "Expected AWS account is not registered. Set EXPECTED_AWS_ACCOUNT_ID or create $LAB_EXPECTED_ACCOUNT_FILE."
}

lab_assert_aws_identity() {
  local expected_account="$1"
  local profile="$2"
  local expected_region="$3"
  local actual_account actual_region

  actual_account="$(aws sts get-caller-identity \
    --profile "$profile" --query Account --output text)" \
    || lab_safety_error "AWS authentication failed for profile $profile."
  actual_region="$(aws configure get region --profile "$profile" 2>/dev/null || true)"

  [[ "$actual_account" == "$expected_account" ]] \
    || lab_safety_error "Active AWS account $actual_account does not match registered account $expected_account."
  [[ "$actual_region" == "$expected_region" ]] \
    || lab_safety_error "AWS profile $profile must use region $expected_region; found ${actual_region:-unset}."
}

lab_export_expected_account_id() {
  local mode="${1:-strict}"
  local terraform_dir="${2:-}"
  local certificate_arn_file="${3:-}"

  TF_VAR_expected_account_id="$(lab_resolve_expected_account_id \
    "$mode" "$terraform_dir" "$certificate_arn_file")" || return 1
  export TF_VAR_expected_account_id
}

lab_managed_plan_actions() {
  local terraform_dir="$1"
  local plan_file="$2"

  terraform -chdir="$terraform_dir" show -json "$plan_file" |
    jq -r '.resource_changes[]? |
      select(.mode == "managed" and .change.actions != ["no-op"]) |
      "\(.address):\(.change.actions | join(","))"' |
    LC_ALL=C sort
}

lab_assert_exact_plan_actions() {
  local terraform_dir="$1"
  local plan_file="$2"
  local expected_actions="$3"
  local actual_sorted expected_sorted

  actual_sorted="$(lab_managed_plan_actions "$terraform_dir" "$plan_file")" || return 1
  expected_sorted="$(LC_ALL=C sort <<<"$expected_actions")"

  if [[ "$actual_sorted" != "$expected_sorted" ]]; then
    printf 'ERROR: Terraform Plan actions do not exactly match the allowed action set.\n' >&2
    printf '%s\n' '--- Allowed actions ---' >&2
    printf '%s\n' "$expected_sorted" >&2
    printf '%s\n' '--- Actual actions ---' >&2
    printf '%s\n' "${actual_sorted:-<none>}" >&2
    return 1
  fi
}

lab_assert_no_recovery_or_active_test() {
  local recovery_file lock_file lock_fd

  for recovery_file in \
    "$LAB_STATE_DIR/haproxy-failover-recovery.json" \
    "$LAB_STATE_DIR/worker-reboot-recovery.json"
  do
    [[ ! -e "$recovery_file" ]] \
      || lab_safety_error "Unfinished recovery marker exists: $recovery_file"
  done

  command -v flock >/dev/null 2>&1 \
    || lab_safety_error 'flock is required to verify that no failure test is active.'

  for lock_file in \
    "$LAB_STATE_DIR/haproxy-failover.lock" \
    "$LAB_STATE_DIR/worker-reboot.lock"
  do
    [[ -e "$lock_file" ]] || continue
    exec {lock_fd}>>"$lock_file"
    if ! flock -n "$lock_fd"; then
      eval "exec ${lock_fd}>&-"
      lab_safety_error "A failure test or recovery still holds this lock: $lock_file"
      return 1
    fi
    flock -u "$lock_fd"
    eval "exec ${lock_fd}>&-"
  done
}
