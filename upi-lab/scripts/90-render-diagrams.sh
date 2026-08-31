#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIAGRAM_DIR="$LAB_ROOT/diagrams"
MERMAID_CLI_VERSION='11.16.0'
CONFIG_FILE="$DIAGRAM_DIR/mermaid-config.json"

command -v mmdc >/dev/null 2>&1 || {
  printf 'ERROR: Mermaid CLI is not installed.\n' >&2
  printf 'Install the pinned renderer, then retry:\n' >&2
  printf '  npm install --global @mermaid-js/mermaid-cli@%s\n' "$MERMAID_CLI_VERSION" >&2
  exit 1
}

actual_version="$(mmdc --version | tr -d '[:space:]')"
[[ "$actual_version" == "$MERMAID_CLI_VERSION" ]] || {
  printf 'ERROR: Mermaid CLI version must be %s; found %s.\n' \
    "$MERMAID_CLI_VERSION" "$actual_version" >&2
  exit 1
}

diagram_names=(
  01-architecture-overview
  02-network-az-layout
  03-communication-flows
)

for diagram_name in "${diagram_names[@]}"; do
  source_file="$DIAGRAM_DIR/$diagram_name.mmd"
  [[ -s "$source_file" ]] || {
    printf 'ERROR: Missing Mermaid source: %s\n' "$source_file" >&2
    exit 1
  }

  mmdc \
    --input "$source_file" \
    --output "$DIAGRAM_DIR/$diagram_name.svg" \
    --configFile "$CONFIG_FILE" \
    --backgroundColor white \
    --width 2400

  mmdc \
    --input "$source_file" \
    --output "$DIAGRAM_DIR/$diagram_name.png" \
    --configFile "$CONFIG_FILE" \
    --backgroundColor white \
    --width 2400 \
    --scale 1.5
done

python3 "$SCRIPT_DIR/90-validate-diagrams.py"
printf 'Diagram rendering PASSED with Mermaid CLI %s.\n' "$MERMAID_CLI_VERSION"
