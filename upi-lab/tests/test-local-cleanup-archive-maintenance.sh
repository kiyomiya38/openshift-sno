#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP_SCRIPT="$LAB_ROOT/scripts/08-05-clean-local-artifacts.sh"
TEST_HOME="$TEST_DIR/home"
ARCHIVE_ID='20260102-030405'
SIBLING_ID='20260102-030406'
ARCHIVE_PARENT="$TEST_HOME/.local/share/openshift-upi-lab-cleanup-archive"
ARCHIVE_DIR="$ARCHIVE_PARENT/$ARCHIVE_ID"
SIBLING_DIR="$ARCHIVE_PARENT/$SIBLING_ID"
CONFIG_ROOT="$TEST_HOME/.config/openshift-upi-lab"
PKI_DIR="$CONFIG_ROOT/pki"

mkdir -p "$ARCHIVE_DIR/home/config" "$SIBLING_DIR" "$PKI_DIR"
chmod 700 "$ARCHIVE_DIR" "$SIBLING_DIR" "$PKI_DIR"
mkdir -p "$CONFIG_ROOT"
printf '%s\n' '123456789012' >"$CONFIG_ROOT/expected-account-id"
printf '%s\n' 'test-private-key' >"$PKI_DIR/client-test.key"
printf '%s\n' 'sibling-must-remain' >"$SIBLING_DIR/sentinel"
jq -n \
  --arg account_id '123456789012' \
  --arg region 'ap-northeast-3' \
  --arg workspace 'default' \
  --arg validated_at '2026-01-02T03:04:05+09:00' \
  '{account_id:$account_id,region:$region,workspace:$workspace,
    state_lineage:"test-lineage",state_serial:1,managed_resource_count:0,
    validated_at:$validated_at}' \
  >"$ARCHIVE_DIR/home/config/cleanup-validated.json"
chmod 600 "$ARCHIVE_DIR/home/config/cleanup-validated.json"

if HOME="$TEST_HOME" bash "$CLEANUP_SCRIPT" --delete-archive '../unsafe' >/dev/null 2>&1; then
  printf 'ERROR: An unsafe archive ID was accepted.\n' >&2
  exit 1
fi

printf 'CANCEL\n' |
  HOME="$TEST_HOME" bash "$CLEANUP_SCRIPT" --archive-pki "$ARCHIVE_ID" >/dev/null
[[ -d "$PKI_DIR" && ! -e "$ARCHIVE_DIR/home/config/pki" ]]

printf 'ARCHIVE-PKI-INTO-%s\n' "$ARCHIVE_ID" |
  HOME="$TEST_HOME" bash "$CLEANUP_SCRIPT" --archive-pki "$ARCHIVE_ID" >/dev/null
[[ ! -e "$PKI_DIR" && -f "$ARCHIVE_DIR/home/config/pki/client-test.key" ]]

printf 'CANCEL\n' |
  HOME="$TEST_HOME" bash "$CLEANUP_SCRIPT" --delete-archive "$ARCHIVE_ID" >/dev/null
[[ -d "$ARCHIVE_DIR" && -f "$SIBLING_DIR/sentinel" ]]

printf 'DELETE-LOCAL-LAB-ARCHIVE-%s\n' "$ARCHIVE_ID" |
  HOME="$TEST_HOME" bash "$CLEANUP_SCRIPT" --delete-archive "$ARCHIVE_ID" >/dev/null
[[ ! -e "$ARCHIVE_DIR" ]]
[[ -f "$SIBLING_DIR/sentinel" ]]
[[ -f "$CONFIG_ROOT/expected-account-id" ]]

printf 'Local cleanup archive-maintenance safety regression PASSED.\n'
