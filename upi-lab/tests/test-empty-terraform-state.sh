#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/safety-common.sh
source "$LAB_ROOT/scripts/lib/safety-common.sh"

test_mode=empty

terraform() {
  local command_tail="${*: -2}"
  case "$test_mode" in
    empty)
      return 0
      ;;
    populated)
      if [[ "$command_tail" == 'state pull' ]]; then
        printf '%s\n' '{"version":4,"terraform_version":"1.15.8","serial":1,"lineage":"test-lineage","outputs":{},"resources":[{"mode":"managed","type":"test_resource","name":"one","provider":"test","instances":[{"index_key":0},{"index_key":1}]},{"mode":"data","type":"test_data","name":"one","provider":"test","instances":[{}]}]}'
      elif [[ "$command_tail" == 'state list' ]]; then
        printf '%s\n' 'data.test_data.one' 'test_resource.one[0]' 'test_resource.one[1]'
      else
        return 2
      fi
      ;;
    malformed)
      printf '%s\n' '{"resources":[]}'
      ;;
    command-error)
      return 1
      ;;
    list-error)
      if [[ "$command_tail" == 'state pull' ]]; then
        printf '%s\n' '{"version":4,"terraform_version":"1.15.8","serial":1,"lineage":"test-lineage","outputs":{},"resources":[]}'
      else
        return 1
      fi
      ;;
    *)
      return 2
      ;;
  esac
}

empty_count="$(lab_managed_state_count_allow_absent /not-used)"
[[ "$empty_count" == 0 ]] || {
  printf 'FAIL: An absent initialized state must contain zero managed resources.\n' >&2
  exit 1
}

test_mode=populated
populated_count="$(lab_managed_state_count_allow_absent /not-used)"
[[ "$populated_count" == 2 ]] || {
  printf 'FAIL: The managed-resource counter returned %s instead of 2.\n' "$populated_count" >&2
  exit 1
}

populated_list="$(lab_state_list_required /not-used)"
[[ "$populated_list" == $'data.test_data.one\ntest_resource.one[0]\ntest_resource.one[1]' ]] || {
  printf 'FAIL: Required state addresses were not returned exactly.\n' >&2
  exit 1
}

test_mode=empty
empty_list="$(lab_state_list_allow_absent /not-used)"
[[ -z "$empty_list" ]] || {
  printf 'FAIL: An absent state returned unexpected state addresses.\n' >&2
  exit 1
}
if lab_state_list_required /not-used >/dev/null 2>&1; then
  printf 'FAIL: Required state lookup accepted an absent state.\n' >&2
  exit 1
fi

test_mode=malformed
if lab_managed_state_count_allow_absent /not-used >/dev/null 2>&1; then
  printf 'FAIL: Malformed state JSON was accepted as an empty state.\n' >&2
  exit 1
fi

test_mode=command-error
if lab_managed_state_count_allow_absent /not-used >/dev/null 2>&1; then
  printf 'FAIL: A Terraform command failure was accepted as an empty state.\n' >&2
  exit 1
fi

test_mode=list-error
if lab_state_list_allow_absent /not-used >/dev/null 2>&1; then
  printf 'FAIL: A Terraform state-list failure was accepted as an empty list.\n' >&2
  exit 1
fi

printf 'Empty Terraform state safety regression PASSED.\n'
