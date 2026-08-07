#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/upi-release-builder-test.XXXXXXXX")"
FIXTURE="$TEST_ROOT/openshift-upi-lab"
OUTPUT="$TEST_ROOT/output"
SECOND_OUTPUT="$TEST_ROOT/output-second"

cleanup() {
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" \
    && "$TEST_ROOT" == "${TMPDIR:-/tmp}/upi-release-builder-test."* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p -- "$FIXTURE"
tar -C "$LAB_ROOT" \
  --exclude='./terraform/.terraform' \
  --exclude='./terraform/*.tfstate' \
  --exclude='./terraform/*.tfstate.*' \
  --exclude='./terraform/*.tfplan' \
  --exclude='./terraform/*.tfplan.*' \
  --exclude='./logs/*' \
  --exclude='./artifacts' \
  --exclude='./dist' \
  -cf - . | tar -C "$FIXTURE" -xf -

bash "$FIXTURE/scripts/91-build-release.sh" --audit-only

inside_output="$FIXTURE/forbidden-output"
if bash "$FIXTURE/scripts/91-build-release.sh" "$inside_output" >/dev/null 2>&1; then
  printf 'ERROR: The release builder accepted an output directory inside the source tree.\n' >&2
  exit 1
fi
if [[ -e "$inside_output" ]]; then
  printf 'ERROR: Rejecting an in-tree output directory changed the source tree.\n' >&2
  exit 1
fi

bash "$FIXTURE/scripts/91-build-release.sh" "$OUTPUT"
bash "$FIXTURE/scripts/91-build-release.sh" "$SECOND_OUTPUT"

archive="$OUTPUT/openshift-upi-lab-source.tar.gz"
checksum="$archive.sha256"
listing="$(tar -tzf "$archive")"
if grep -Eq '(^|/)(\.terraform|logs|artifacts|dist)(/|$)|\.tf(state|plan)($|\.)' <<<"$listing"; then
  printf 'ERROR: The release archive contains a forbidden entry.\n' >&2
  exit 1
fi
if ! grep -qx 'openshift-upi-lab/.github/workflows/upi-lab-quality.yml' <<<"$listing"; then
  printf 'ERROR: The standalone release workflow is missing from the archive.\n' >&2
  exit 1
fi
for expected_diagram in \
  01-architecture-overview \
  02-network-az-layout \
  03-communication-flows; do
  for extension in mmd svg png; do
    expected_path="openshift-upi-lab/diagrams/$expected_diagram.$extension"
    if ! grep -qx "$expected_path" <<<"$listing"; then
      printf 'ERROR: The release archive is missing %s.\n' "$expected_path" >&2
      exit 1
    fi
  done
done
if grep -q 'upi-lab/scripts/' "$FIXTURE/.github/workflows/upi-lab-quality.yml"; then
  printf 'ERROR: The standalone workflow contains a monorepo-relative command.\n' >&2
  exit 1
fi

(cd "$OUTPUT" && sha256sum --check "$(basename -- "$checksum")")
if ! cmp -s -- \
  "$archive" \
  "$SECOND_OUTPUT/openshift-upi-lab-source.tar.gz"; then
  printf 'ERROR: Two builds from identical source were not byte-for-byte reproducible.\n' >&2
  exit 1
fi

mkdir -p -- "$FIXTURE/terraform"
printf '{"sensitive":"fixture"}\n' >"$FIXTURE/terraform/leak.tfstate"
if bash "$FIXTURE/scripts/91-build-release.sh" --audit-only >/dev/null 2>&1; then
  printf 'ERROR: The release audit accepted a Terraform state fixture.\n' >&2
  exit 1
fi

rm -f -- "$FIXTURE/terraform/leak.tfstate"
mkdir -p -- "$FIXTURE/configs"
printf '%s%s\n' '-----BEGIN PRIV' 'ATE KEY-----' >"$FIXTURE/configs/leaked-secret.txt"
if bash "$FIXTURE/scripts/91-build-release.sh" --audit-only >/dev/null 2>&1; then
  printf 'ERROR: The release audit accepted a private-key fixture.\n' >&2
  exit 1
fi

printf 'Release builder self-test PASSED. The archive is reproducible and rejection rules work.\n'
