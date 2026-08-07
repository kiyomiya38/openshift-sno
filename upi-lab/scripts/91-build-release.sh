#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RELEASE_ROOT_NAME='openshift-upi-lab'
AUDIT_ONLY=false

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/91-build-release.sh --audit-only
  bash scripts/91-build-release.sh OUTPUT_DIRECTORY

The command never deletes or changes the source tree and never overwrites an
existing archive. It stops before staging if generated state, plans, logs,
credentials, private keys, kubeconfig, install assets, or personal paths are
present. OUTPUT_DIRECTORY must be outside upi-lab.
USAGE
}

if [[ "${1:-}" == '--audit-only' ]]; then
  AUDIT_ONLY=true
  shift
fi

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

if [[ "$AUDIT_ONLY" == false && $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

is_forbidden_file() {
  local relative_path=$1
  case "$relative_path" in
    logs/.gitkeep | .env.example | */.env.example)
      return 1
      ;;
    logs/* | artifacts/* | dist/* | */.terraform/* | \
      *.tfstate | *.tfstate.* | *.tfplan | *.tfplan.* | \
      *.key | *.pem | *.p12 | *.pfx | *.ovpn | *.crt | *.csr | \
      */auth/* | auth/* | *kubeconfig* | *.ign | \
      install-config.yaml | */install-config.yaml | \
      metadata.json | */metadata.json | pull-secret*.json | */pull-secret*.json | \
      .env | */.env | .env.* | */.env.* | *.retry | *.log)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_release_file() {
  local relative_path=$1
  case "$relative_path" in
    .gitignore | .shellcheckrc | LICENSE | README.md | SECURITY.md | THIRD_PARTY_NOTICES.md | \
      .github/workflows/upi-lab-quality.yml | \
      ansible/* | configs/* | diagrams/* | docs/* | licenses/* | manifests/* | scripts/* | \
      terraform/* | tests/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

forbidden_paths=()
while IFS= read -r -d '' directory; do
  forbidden_paths+=("${directory#"$LAB_ROOT/"}/")
done < <(find "$LAB_ROOT" -type d -name .terraform -print0)

while IFS= read -r -d '' file; do
  relative_path="${file#"$LAB_ROOT/"}"
  [[ "$relative_path" == */.terraform/* ]] && continue
  if is_forbidden_file "$relative_path"; then
    forbidden_paths+=("$relative_path")
  fi
done < <(find "$LAB_ROOT" -type f -print0)

if ((${#forbidden_paths[@]} > 0)); then
  printf 'ERROR: Release audit found generated or sensitive artifacts:\n' >&2
  printf '  - %s\n' "${forbidden_paths[@]}" >&2
  printf 'Clean the local environment using the documented cleanup procedure, then rerun the audit.\n' >&2
  exit 1
fi

secret_pattern='-----BEGIN ([A-Z0-9 ]+ )?PRIV'
secret_pattern+='ATE KEY-----|(A'
secret_pattern+='KIA|A'
secret_pattern+='SIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]+'
personal_path_pattern='/mnt/c/Us'
personal_path_pattern+='ers/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|[A-Za-z]:[/\\]Us'
personal_path_pattern+='ers[/\\][A-Za-z0-9._-]+[/\\]'
content_failures=()

while IFS= read -r -d '' file; do
  relative_path="${file#"$LAB_ROOT/"}"
  is_release_file "$relative_path" || continue
  is_forbidden_file "$relative_path" && continue
  grep -Iq . "$file" || continue
  if grep -Eq -- "$secret_pattern" "$file"; then
    content_failures+=("possible credential or private key: $relative_path")
  fi
  if grep -Eq "$personal_path_pattern" "$file"; then
    content_failures+=("personal path: $relative_path")
  fi

  account_candidates="$(
    grep -Eo '(^|[^0-9])[0-9]{12}([^0-9]|$)' "$file" \
      | grep -Eo '[0-9]{12}' \
      | sort -u || true
  )"
  while IFS= read -r account_id; do
    [[ -n "$account_id" ]] || continue
    case "$account_id" in
      123456789012 | 309956199498 | 531415883065)
        # Documentation placeholder, Red Hat RHCOS owner, and Red Hat RHEL owner.
        ;;
      *)
        content_failures+=("concrete AWS account ID: $relative_path")
        break
        ;;
    esac
  done <<<"$account_candidates"
done < <(find "$LAB_ROOT" -type f -print0)

if ((${#content_failures[@]} > 0)); then
  printf 'ERROR: Release audit found non-portable or potentially sensitive content:\n' >&2
  printf '  - %s\n' "${content_failures[@]}" >&2
  printf 'Only filenames are shown; secret values are never printed.\n' >&2
  exit 1
fi

printf 'Release source audit PASSED.\n'

if [[ "$AUDIT_ONLY" == true ]]; then
  printf 'Audit-only mode made no files.\n'
  exit 0
fi

OUTPUT_DIRECTORY="$(realpath -m -- "$1")"
case "$OUTPUT_DIRECTORY/" in
  "$LAB_ROOT/"*)
    printf 'ERROR: OUTPUT_DIRECTORY must be outside %s.\n' "$LAB_ROOT" >&2
    exit 1
    ;;
esac
mkdir -p -- "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd -- "$OUTPUT_DIRECTORY" && pwd)"

archive="$OUTPUT_DIRECTORY/$RELEASE_ROOT_NAME-source.tar.gz"
checksum="$archive.sha256"
if [[ -e "$archive" || -e "$checksum" ]]; then
  printf 'ERROR: Refusing to overwrite an existing release file:\n  %s\n' "$archive" >&2
  exit 1
fi

stage_parent="$(mktemp -d "${TMPDIR:-/tmp}/openshift-upi-lab-release.XXXXXXXX")"
stage="$stage_parent/$RELEASE_ROOT_NAME"
mkdir -p -- "$stage"

cleanup_stage() {
  if [[ -n "${stage_parent:-}" && -d "$stage_parent" \
    && "$stage_parent" == "${TMPDIR:-/tmp}/openshift-upi-lab-release."* ]]; then
    rm -rf -- "$stage_parent"
  fi
}
trap cleanup_stage EXIT

while IFS= read -r -d '' file; do
  relative_path="${file#"$LAB_ROOT/"}"
  is_release_file "$relative_path" || continue
  is_forbidden_file "$relative_path" && continue
  mkdir -p -- "$stage/$(dirname -- "$relative_path")"
  cp -p -- "$file" "$stage/$relative_path"
done < <(find "$LAB_ROOT" -type f -print0)

if find "$stage" -type d -name .terraform -print -quit | grep -q . \
  || find "$stage" -type f \( \
    -name '*.tfstate' -o -name '*.tfstate.*' -o -name '*.tfplan' -o -name '*.tfplan.*' \
    -o -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' \
    -o -name '*.ovpn' -o -name '*.ign' -o -name '*kubeconfig*' \
  \) -print -quit | grep -q .; then
  printf 'ERROR: Internal release staging verification failed. No archive was created.\n' >&2
  exit 1
fi

temporary_archive="$stage_parent/$RELEASE_ROOT_NAME-source.tar.gz"
tar -C "$stage_parent" \
  --sort=name \
  --mtime='@0' \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -cf - "$RELEASE_ROOT_NAME" | gzip -n >"$temporary_archive"
mv -- "$temporary_archive" "$archive"
(cd "$OUTPUT_DIRECTORY" && sha256sum "$(basename -- "$archive")" >"$(basename -- "$checksum")")
printf 'Release archive created without changing the source tree:\n'
printf '  %s\n  %s\n' "$archive" "$checksum"
