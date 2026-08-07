# Third-party notices

This distribution contains material adapted from the following project.

## NFS Subdir External Provisioner

- Project: Kubernetes SIG Storage - NFS Subdir External Provisioner
- Copyright: The Kubernetes Authors
- License: Apache License 2.0
- Upstream release used as the design baseline: `nfs-subdir-external-provisioner-4.0.18`
- Upstream deployment: <https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/nfs-subdir-external-provisioner-4.0.18/deploy/deployment.yaml>
- Upstream RBAC: <https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/nfs-subdir-external-provisioner-4.0.18/deploy/rbac.yaml>
- Local derivative: `manifests/nfs-storage/provisioner.yaml`

The local manifest combines and modifies upstream deployment and RBAC ideas
for this lab. Changes include OpenShift labels and `restricted-v2` settings, a
dedicated retained root PV/PVC, resource limits, an image digest, an NFSv4.1
StorageClass, and lab-specific names and addresses.

The complete Apache License 2.0 text is included at
`licenses/Apache-2.0.txt`. The upstream project and its authors do not endorse
this lab or its modifications.

## Trademarks and affiliation

OpenShift and Red Hat are trademarks or registered trademarks of Red Hat,
Inc. AWS and related marks are trademarks of Amazon.com, Inc. or its
affiliates. All marks remain the property of their respective owners. This
independent educational project is not endorsed by Red Hat or Amazon Web
Services.
