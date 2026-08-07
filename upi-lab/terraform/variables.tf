variable "aws_profile" {
  description = "AWS CLI profile used by Terraform."
  type        = string
  default     = "openshift-lab"
}

variable "aws_region" {
  description = "AWS region for the lab."
  type        = string
  default     = "ap-northeast-3"

  validation {
    condition     = var.aws_region == "ap-northeast-3"
    error_message = "This runbook is designed for ap-northeast-3."
  }
}

variable "expected_account_id" {
  description = "Twelve-digit AWS account ID. Prevents planning against the wrong account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must contain exactly 12 digits."
  }
}

variable "project_name" {
  description = "Name used for tags and resource names."
  type        = string
  default     = "openshift-upi-lab"
}

variable "owner_tag" {
  description = "Non-secret owner or training-group label applied to lab resources."
  type        = string
  default     = "openshift-lab-user"

  validation {
    condition     = length(trimspace(var.owner_tag)) > 0
    error_message = "owner_tag must not be empty."
  }
}

variable "base_domain" {
  description = "Existing Route 53 public hosted zone name."
  type        = string
  default     = "lab.k8study.com"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR assigned to the lab VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "enable_client_vpn" {
  description = "Creates the AWS Client VPN resources after PKI and ACM preparation."
  type        = bool
  default     = false
}

variable "client_vpn_server_certificate_arn" {
  description = "ARN of the ACM server certificate. The same CA signs server and client certificates."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.client_vpn_server_certificate_arn == null || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]+$", var.client_vpn_server_certificate_arn))
    error_message = "The certificate ARN must be a valid ACM certificate ARN."
  }
}

variable "client_vpn_cidr" {
  description = "IPv4 pool assigned to AWS Client VPN users."
  type        = string
  default     = "10.81.0.0/22"

  validation {
    condition     = var.client_vpn_cidr == "10.81.0.0/22"
    error_message = "This runbook is designed for Client VPN CIDR 10.81.0.0/22."
  }
}

variable "client_vpn_dns_servers" {
  description = "DNS servers pushed to VPN clients. Initially uses the VPC resolver; changed to BIND after infrastructure services are ready."
  type        = list(string)
  default     = ["10.80.0.2"]

  validation {
    condition     = length(var.client_vpn_dns_servers) >= 1 && length(var.client_vpn_dns_servers) <= 2
    error_message = "AWS Client VPN accepts one or two DNS server addresses."
  }
}

variable "enable_infrastructure_services" {
  description = "Creates the Phase 4 infrastructure EC2 instances, security groups, IAM profile, and internal NLB."
  type        = bool
  default     = false
}

variable "ssh_public_key_path" {
  description = "Path to the dedicated OpenShift UPI lab SSH public key."
  type        = string
  default     = "~/.ssh/openshift_upi_lab.pub"
}

variable "rhel_ami_id" {
  description = "Reviewed RHEL 9.6 x86_64 AMI for infrastructure service hosts in ap-northeast-3."
  type        = string
  default     = "ami-00398bf75d34bf700"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.rhel_ami_id))
    error_message = "rhel_ami_id must be a valid AMI ID."
  }
}

variable "cluster_name" {
  description = "OpenShift cluster name used by DNS and Ignition delivery."
  type        = string
  default     = "ocp"

  validation {
    condition     = var.cluster_name == "ocp"
    error_message = "This runbook is designed for cluster name ocp."
  }
}

variable "enable_cluster_prerequisites" {
  description = "Creates the DHCP options and security-group rules required before RHCOS nodes start."
  type        = bool
  default     = false
}

variable "enable_cluster_nodes" {
  description = "Creates the three control-plane and three worker RHCOS instances."
  type        = bool
  default     = false
}

variable "enable_bootstrap" {
  description = "Creates the temporary bootstrap RHCOS instance. Set false only after bootstrap-complete and HAProxy cutover."
  type        = bool
  default     = false
}

variable "rhcos_ami_id" {
  description = "RHCOS AMI selected from openshift-install coreos print-stream-json."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.rhcos_ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.rhcos_ami_id))
    error_message = "rhcos_ami_id must be a valid AMI ID or null."
  }
}

variable "ignition_base_url" {
  description = "Private Installer HTTP URL containing bootstrap.ign, master.ign, and worker.ign."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ignition_base_url == null || can(regex("^http://10\\.80\\.40\\.10:8080/[a-z0-9-]+$", var.ignition_base_url))
    error_message = "ignition_base_url must use http://10.80.40.10:8080/<infra-id>."
  }
}

variable "ignition_spec_version" {
  description = "Ignition specification version read from the generated role configs."
  type        = string
  default     = "3.4.0"

  validation {
    condition     = can(regex("^3\\.[0-9]+\\.[0-9]+$", var.ignition_spec_version))
    error_message = "ignition_spec_version must be a version from the Ignition 3.x specification."
  }
}

variable "ignition_sha512" {
  description = "SHA-512 digests for role Ignition files. Full Ignition content is never stored in Terraform state."
  type = object({
    bootstrap = string
    master    = string
    worker    = string
  })
  default = {
    bootstrap = ""
    master    = ""
    worker    = ""
  }

  validation {
    condition = alltrue([
      for digest in values(var.ignition_sha512) : digest == "" || can(regex("^[0-9a-f]{128}$", digest))
    ])
    error_message = "Each Ignition digest must be empty or exactly 128 lowercase hexadecimal characters."
  }
}
