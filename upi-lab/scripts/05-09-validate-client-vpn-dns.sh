#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export EXPECTED_CLIENT_VPN_DNS_SERVERS='10.80.40.11,10.80.50.11'

bash "$SCRIPT_DIR/04-05-validate-client-vpn.sh"
