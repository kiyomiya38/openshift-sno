#!/usr/bin/env python3
"""Validate the numbered UPI lab content and its guarded execution order."""

from __future__ import annotations

import sys
from pathlib import Path


LAB_ROOT = Path(__file__).resolve().parents[1]
DOCS = LAB_ROOT / "docs"
SCRIPTS = LAB_ROOT / "scripts"


def relative(path: Path) -> str:
    return path.relative_to(LAB_ROOT).as_posix()


def read(path: Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"{relative(path)}: unable to read: {error}")
        return ""


def check_order(label: str, text: str, tokens: list[str], errors: list[str]) -> None:
    if not text:
        return
    position = -1
    for token in tokens:
        found = text.find(token, position + 1)
        if found < 0:
            errors.append(f"{label}: missing or out-of-order marker: {token}")
            return
        position = found


def check_absent(label: str, text: str, tokens: list[str], errors: list[str]) -> None:
    for token in tokens:
        if token in text:
            errors.append(f"{label}: obsolete or misplaced marker: {token}")


def main() -> int:
    errors: list[str] = []

    readme = read(LAB_ROOT / "README.md", errors)
    prerequisite_doc = read(DOCS / "02-prerequisites.md", errors)
    network_doc = read(DOCS / "03-terraform-network.md", errors)
    vpn_doc = read(DOCS / "04-client-vpn.md", errors)
    infra_doc = read(DOCS / "05-infrastructure-services.md", errors)
    install_doc = read(DOCS / "06-openshift-install.md", errors)
    validation_doc = read(DOCS / "07-storage-and-failure-tests.md", errors)
    destroy_doc = read(DOCS / "08-destroy.md", errors)
    release_doc = read(DOCS / "release-process.md", errors)

    check_order(
        "README.md numbered content",
        readme,
        [
            "docs/00-design-decisions.md",
            "docs/01-architecture-and-parameters.md",
            "docs/02-prerequisites.md",
            "docs/03-terraform-network.md",
            "docs/04-client-vpn.md",
            "docs/05-infrastructure-services.md",
            "docs/06-openshift-install.md",
            "docs/07-storage-and-failure-tests.md",
            "docs/08-destroy.md",
            "docs/09-troubleshooting.md",
            "docs/99-references.md",
        ],
        errors,
    )
    check_absent(
        "README.md numbered content",
        readme,
        ["docs/03-build-runbook.md", "docs/08-validation-and-destroy.md"],
        errors,
    )

    check_order(
        "docs/02-prerequisites.md execution order",
        prerequisite_doc,
        [
            'LAB_ROOT_FILE="$HOME/.config/openshift-upi-lab/lab-root"',
            'printf \'%s\\n\' "$LAB_ROOT" > "$LAB_ROOT_FILE"',
            "bash scripts/02-01-register-expected-account.sh",
            "bash scripts/02-02-install-openshift-tools.sh",
            "bash scripts/02-03-preflight.sh",
        ],
        errors,
    )

    for label, text, first_action in [
        ("docs/03-terraform-network.md session entry", network_doc, "terraform -chdir=\"$LAB_ROOT/terraform\" init"),
        ("docs/04-client-vpn.md session entry", vpn_doc, "bash scripts/03-03-validate-network.sh"),
        ("docs/05-infrastructure-services.md session entry", infra_doc, "bash scripts/04-05-validate-client-vpn.sh"),
        ("docs/06-openshift-install.md session entry", install_doc, "bash scripts/05-06-validate-infrastructure-services.sh"),
        ("docs/07-storage-and-failure-tests.md session entry", validation_doc, "bash scripts/06-15-validate-openshift-cluster.sh"),
        ("docs/08-destroy.md session entry", destroy_doc, "bash scripts/02-03-preflight.sh"),
    ]:
        check_order(
            label,
            text,
            [
                'LAB_ROOT_FILE="$HOME/.config/openshift-upi-lab/lab-root"',
                "PASS: WSL work context is ready.",
                first_action,
            ],
            errors,
        )

    check_order(
        "docs/03-terraform-network.md execution gates",
        network_doc,
        [
            "03-01-plan-network.sh",
            "show -no-color network.tfplan",
            "03-02-apply-network.sh",
            "03-03-validate-network.sh",
        ],
        errors,
    )

    check_order(
        "docs/04-client-vpn.md execution gates",
        vpn_doc,
        [
            "03-03-validate-network.sh",
            "04-01-generate-client-vpn-pki.sh",
            "04-02-import-client-vpn-certificate.sh",
            "04-03-plan-client-vpn.sh",
            "show -no-color client-vpn.tfplan",
            "04-04-apply-client-vpn.sh",
            "04-05-validate-client-vpn.sh",
            "04-06-export-client-vpn-config.sh",
            "Windowsで接続を確認する",
        ],
        errors,
    )
    check_absent(
        "docs/04-client-vpn.md",
        vpn_doc,
        ["05-07-plan-client-vpn-dns.sh"],
        errors,
    )

    check_order(
        "docs/05-infrastructure-services.md execution gates",
        infra_doc,
        [
            "05-01-plan-infrastructure.sh",
            "show -no-color infrastructure.tfplan",
            "05-02-apply-infrastructure.sh",
            "05-03-validate-infrastructure.sh",
            "VPN経由でInstallerへSSHする",
            "05-04-ansible-preflight.sh",
            "05-05-apply-infrastructure-services.sh",
            "05-06-validate-infrastructure-services.sh",
            "05-07-plan-client-vpn-dns.sh",
            "show -no-color client-vpn-dns.tfplan",
            "05-08-apply-client-vpn-dns.sh",
            "いったん切断し、再接続",
            "05-09-validate-client-vpn-dns.sh",
            "Windowsで名前解決を検証する",
        ],
        errors,
    )

    check_order(
        "docs/06-openshift-install.md execution gates",
        install_doc,
        [
            "05-06-validate-infrastructure-services.sh",
            "05-09-validate-client-vpn-dns.sh",
            "06-01-prepare-openshift-install.sh",
            "06-02-plan-cluster-prerequisites.sh",
            "show -no-color cluster-prerequisites.tfplan",
            "06-03-apply-cluster-prerequisites.sh",
            "06-04-generate-stage-ignition.sh",
            "06-05-validate-cluster-prerequisites.sh",
            "06-06-plan-cluster-nodes.sh",
            "show -no-color cluster-nodes.tfplan",
            "06-07-apply-cluster-nodes.sh",
            "06-08-validate-cluster-nodes.sh",
            "06-09-wait-for-bootstrap.sh",
            "06-10-cutover-from-bootstrap.sh",
            "06-11-plan-bootstrap-removal.sh",
            "show -no-color bootstrap-removal.tfplan",
            "06-12-apply-bootstrap-removal.sh",
            "06-13-review-csrs.sh",
            "CSR and node readiness gate PASSED.",
            "06-14-wait-for-install-complete.sh",
            "06-15-validate-openshift-cluster.sh",
        ],
        errors,
    )

    csr_review_script = read(SCRIPTS / "06-13-review-csrs.sh", errors)
    check_order(
        "scripts/06-13-review-csrs.sh safety gates",
        csr_review_script,
        [
            "phase7_assert_target_cluster",
            "phase6_assert_expected_node_subset",
            "phase6_csr_is_expected_node_request",
            "NOT ELIGIBLE - do not approve",
            "CSR and node readiness gate PASSED.",
        ],
        errors,
    )
    if csr_review_script.count("exit 2") != 2:
        errors.append(
            "scripts/06-13-review-csrs.sh: both WAIT paths must exit with status 2"
        )

    install_complete_script = read(
        SCRIPTS / "06-14-wait-for-install-complete.sh", errors
    )
    check_order(
        "scripts/06-14-wait-for-install-complete.sh completion gates",
        install_complete_script,
        [
            "phase7_assert_target_cluster",
            "phase6_assert_expected_node_inventory",
            "unresolved_csrs",
            "openshift-install wait-for install-complete",
            "stop-ignition.yml",
            'mv -- "$marker_temp" "$INSTALL_DIR/install-complete.ok"',
        ],
        errors,
    )

    check_order(
        "docs/07-storage-and-failure-tests.md execution order",
        validation_doc,
        [
            "06-15-validate-openshift-cluster.sh",
            "07-01-apply-nfs-storage.sh",
            "07-02-validate-nfs-storage.sh",
            "07-03-cleanup-nfs-storage-test.sh",
            "07-04-test-haproxy-failover.sh",
            "07-05-test-worker-reboot.sh",
            "06-15-validate-openshift-cluster.sh",
        ],
        errors,
    )

    check_order(
        "docs/08-destroy.md destroy gates",
        destroy_doc,
        [
            "02-03-preflight.sh",
            "08-01-plan-destroy.sh",
            "show -no-color destroy.tfplan",
            "WindowsのClient VPNを切断する",
            "08-02-apply-destroy.sh",
            "08-03-delete-client-vpn-certificate.sh",
            "08-04-validate-cleanup.sh",
            "08-05-clean-local-artifacts.sh",
        ],
        errors,
    )
    check_absent(
        "docs/08-destroy.md",
        destroy_doc,
        ["93-build-release.sh"],
        errors,
    )

    check_order(
        "docs/release-process.md release gates",
        release_doc,
        [
            "91-static-validation.sh",
            "92-test-release-builder.sh",
            "93-build-release.sh --audit-only",
            "93-build-release.sh \"$HOME/openshift-upi-lab-release\"",
        ],
        errors,
    )

    planner_names = [
        "03-01-plan-network.sh",
        "04-03-plan-client-vpn.sh",
        "05-01-plan-infrastructure.sh",
        "05-07-plan-client-vpn-dns.sh",
        "06-02-plan-cluster-prerequisites.sh",
        "06-06-plan-cluster-nodes.sh",
        "06-11-plan-bootstrap-removal.sh",
    ]
    for name in planner_names:
        planner = read(SCRIPTS / name, errors)
        if not planner:
            continue
        review = planner.find("Next: review the saved Plan before Apply:")
        apply = planner.find("After the review passes:", review + 1)
        if review < 0 or apply < 0:
            errors.append(
                f"scripts/{name}: review guidance must precede Apply guidance"
            )

    destroy_planner = read(SCRIPTS / "08-01-plan-destroy.sh", errors)
    check_order(
        "scripts/08-01-plan-destroy.sh guidance",
        destroy_planner,
        [
            "Next: review the saved destroy Plan",
            "disconnect the Windows Client VPN",
            "After the review and VPN disconnect: bash scripts/08-02-apply-destroy.sh",
        ],
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(
            f"Numbered content order validation FAILED: {len(errors)} error(s).",
            file=sys.stderr,
        )
        return 1

    print("Numbered content order validation PASSED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
