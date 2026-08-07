data "aws_caller_identity" "current" {}

data "aws_route53_zone" "lab" {
  name         = "${var.base_domain}."
  private_zone = false
}

data "aws_ami" "rhel_infrastructure" {
  count = var.enable_infrastructure_services ? 1 : 0

  most_recent = false
  owners      = ["309956199498"]

  filter {
    name   = "image-id"
    values = [var.rhel_ami_id]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}


data "aws_ami" "rhcos" {
  count = length(local.enabled_openshift_hosts) > 0 ? 1 : 0

  most_recent = false
  owners      = ["531415883065"]

  filter {
    name   = "image-id"
    values = [coalesce(var.rhcos_ami_id, "ami-00000000")]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
