# Configuration scope

This repository is distributed as a tested reference profile, not as a fully
parameterized OpenShift installer.

The following values are part of the tested design and are intentionally kept
consistent across Terraform, Ansible, manifests, validation scripts, and the
runbook:

- AWS Region: `ap-northeast-3`
- Base domain: `lab.k8study.com`
- Cluster name: `ocp`
- VPC and node/service CIDRs shown in `docs/01-architecture-and-parameters.md`

Do not change only one occurrence of a design value. Supporting another region,
domain, or CIDR requires a reviewed profile change and a complete clean-room
installation and destruction test.

Per-user values are configured outside this directory:

- expected AWS account ID: local account guard created during prerequisites;
- AWS CLI profile: `AWS_PROFILE_NAME` or the documented default;
- resource owner tag: `owner_tag` in a private `terraform.tfvars`;
- SSH key, Pull Secret, PKI, and install assets: paths under the user's home
  directory as documented by the runbook.

`terraform/terraform.tfvars.example` lists the supported Terraform inputs. Do
not commit a populated `terraform.tfvars`.
