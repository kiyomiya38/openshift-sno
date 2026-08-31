# Security policy

## Support boundary

This repository is an educational OpenShift UPI lab and reference
implementation. It does not provide a production SLA, managed operations, or
official Red Hat or AWS support. Report a suspected vulnerability privately to
the repository owner, using the hosting service's private security-reporting
channel when available. Do not include credentials or secret values in a
public issue.

## Sensitive local artifacts

Never distribute or commit Terraform state or plans, `.terraform/`, logs,
`.ovpn` profiles, PKI private keys, Pull Secrets, kubeconfig, Ignition files,
`install-config.yaml`, `metadata.json`, or generated cluster authentication
files. Before creating a release, run:

```bash
bash scripts/91-static-validation.sh
bash scripts/92-test-release-builder.sh
bash scripts/93-build-release.sh --audit-only
```

The release builder stops when these artifacts or concrete personal paths are
present. It stages only an allowlisted set of source files and never deletes
or overwrites the source tree.

Distribute only the archive produced by `scripts/93-build-release.sh`. Do not
ZIP, copy, or publish the working tree, because ignored local files still exist
on disk and can be included by tools that do not honor `.gitignore`.

## Accidental disclosure response

If a sensitive artifact is published:

1. Stop or unpublish the release and restrict repository access immediately.
2. Revoke or rotate credentials before attempting history cleanup. Depending
   on the exposed file, this can include AWS access keys, Red Hat Pull Secret
   credentials, VPN client/server certificates and their CA, registry
   credentials, or OpenShift administrator credentials.
3. Treat state, plans, logs, kubeconfig, Ignition, and `.ovpn` files as
   confidential even when no plaintext password is apparent. Review the
   exposed resource metadata and rotate every credential that might be
   embedded or referenced.
4. Remove the file from current and historical Git objects and from release,
   CI, cache, and mirror storage. A deletion commit alone does not remove it
   from history.
5. Re-run cleanup validation, secret scanning, and
   `scripts/93-build-release.sh --audit-only` before republishing.
6. Record the exposure window, affected identities, rotations, and validation
   evidence without recording the secret values themselves.

When the scope of an exposed cluster administrator credential or installation
asset cannot be proven, rebuild the disposable lab from clean credentials.
