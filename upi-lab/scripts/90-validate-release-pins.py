#!/usr/bin/env python3
"""Validate that OpenShift release pins agree across metadata and scripts."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


LAB_ROOT = Path(__file__).resolve().parents[1]


def shell_literal(path: Path, name: str, errors: list[str]) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(rf"^{re.escape(name)}='([^']+)'$", text, re.MULTILINE)
    if match is None:
        errors.append(f"{path.relative_to(LAB_ROOT)}: missing {name}")
        return ""
    return match.group(1)


def main() -> int:
    errors: list[str] = []
    metadata_path = LAB_ROOT / "configs" / "tested-versions.yaml"
    metadata = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))

    openshift = metadata.get("openshift", {})
    tools = metadata.get("tools", {})
    client_tools = openshift.get("client_tools", {})
    client_archive = client_tools.get("client_archive", {})
    installer_archive = client_tools.get("installer_archive", {})

    version = str(openshift.get("version", ""))
    expected_values = {
        "tools.oc": str(tools.get("oc", "")),
        "tools.openshift_install": str(tools.get("openshift_install", "")),
        "scripts/02-03-preflight.sh": shell_literal(
            LAB_ROOT / "scripts" / "02-03-preflight.sh",
            "VERIFIED_OPENSHIFT_VERSION",
            errors,
        ),
        "scripts/lib/phase6-common.sh": shell_literal(
            LAB_ROOT / "scripts" / "lib" / "phase6-common.sh",
            "PHASE6_VERIFIED_OPENSHIFT_VERSION",
            errors,
        ),
        "scripts/02-02-install-openshift-tools.sh": shell_literal(
            LAB_ROOT / "scripts" / "02-02-install-openshift-tools.sh",
            "VERIFIED_OPENSHIFT_VERSION",
            errors,
        ),
    }
    for label, value in expected_values.items():
        if value != version:
            errors.append(
                f"{label}: OpenShift version {value or '<missing>'} != {version or '<missing>'}"
            )

    expected_base_url = (
        f"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/{version}"
    )
    if client_tools.get("mirror_base_url") != expected_base_url:
        errors.append("tested-versions.yaml: OpenShift client mirror URL is inconsistent")

    expected_client_name = f"openshift-client-linux-{version}.tar.gz"
    expected_installer_name = f"openshift-install-linux-{version}.tar.gz"
    if client_archive.get("filename") != expected_client_name:
        errors.append("tested-versions.yaml: OpenShift client archive name is inconsistent")
    if installer_archive.get("filename") != expected_installer_name:
        errors.append("tested-versions.yaml: OpenShift installer archive name is inconsistent")

    installer_script = LAB_ROOT / "scripts" / "02-02-install-openshift-tools.sh"
    checksum_pairs = {
        "CLIENT_SHA256": str(client_archive.get("sha256", "")),
        "INSTALLER_SHA256": str(installer_archive.get("sha256", "")),
    }
    for constant, metadata_checksum in checksum_pairs.items():
        script_checksum = shell_literal(installer_script, constant, errors)
        if not re.fullmatch(r"[0-9a-f]{64}", metadata_checksum):
            errors.append(f"tested-versions.yaml: invalid {constant} value")
        if script_checksum != metadata_checksum:
            errors.append(
                "scripts/02-02-install-openshift-tools.sh: "
                f"{constant} differs from release metadata"
            )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Release pin validation FAILED: {len(errors)} error(s).", file=sys.stderr)
        return 1

    print(f"Release pin validation PASSED: OpenShift {version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
