resource "aws_vpc_dhcp_options" "cluster" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  domain_name         = local.cluster_domain
  domain_name_servers = ["10.80.40.11", "10.80.50.11"]
  ntp_servers         = ["10.80.40.11", "10.80.50.11"]

  tags = {
    Name = "${var.project_name}-cluster-dhcp-options"
  }

  lifecycle {
    precondition {
      condition     = var.enable_infrastructure_services
      error_message = "enable_infrastructure_services must remain true when cluster prerequisites are enabled."
    }

    precondition {
      condition     = var.client_vpn_dns_servers == tolist(["10.80.40.11", "10.80.50.11"])
      error_message = "Client VPN DNS must remain on the two BIND servers before cluster prerequisites are enabled."
    }
  }
}

resource "aws_vpc_dhcp_options_association" "cluster" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  vpc_id          = aws_vpc.lab.id
  dhcp_options_id = aws_vpc_dhcp_options.cluster[0].id
}

resource "aws_security_group" "openshift_nodes" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  name        = "${var.project_name}-openshift-nodes"
  description = "OpenShift control-plane, worker, and bootstrap nodes"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Allow cluster nodes outbound access through the configured proxy or VPC services"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-openshift-nodes-sg"
  }
}

resource "aws_security_group" "ignition_server" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-ignition-server"
  description = "Private Ignition HTTP endpoint on the Installer host"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-ignition-server-sg"
  }
}

resource "aws_security_group" "openshift_control_plane" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  name        = "${var.project_name}-openshift-control-plane"
  description = "HAProxy entry points for Bootstrap and control-plane nodes"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-openshift-control-plane-sg"
  }
}

resource "aws_security_group" "openshift_worker" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  name        = "${var.project_name}-openshift-worker"
  description = "HAProxy ingress entry points for worker nodes"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-openshift-worker-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "openshift_nodes_from_self" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  security_group_id            = aws_security_group.openshift_nodes[0].id
  referenced_security_group_id = aws_security_group.openshift_nodes[0].id
  description                  = "All node-to-node traffic required by OpenShift"
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "openshift_ssh_from_vpn" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  security_group_id            = aws_security_group.openshift_nodes[0].id
  referenced_security_group_id = aws_security_group.client_vpn[0].id
  description                  = "Core user SSH from AWS Client VPN for troubleshooting"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_ingress_rule" "openshift_ssh_from_infrastructure" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  security_group_id            = aws_security_group.openshift_nodes[0].id
  referenced_security_group_id = aws_security_group.infrastructure_admin[0].id
  description                  = "Core user SSH from the Installer host for troubleshooting"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_ingress_rule" "openshift_from_haproxy" {
  for_each = var.enable_cluster_prerequisites ? {
    api            = 6443
    machine_config = 22623
    ingress_http   = 80
    ingress_https  = 443
  } : {}

  security_group_id = contains(["api", "machine_config"], each.key) ? (
    aws_security_group.openshift_control_plane[0].id
  ) : aws_security_group.openshift_worker[0].id
  referenced_security_group_id = aws_security_group.haproxy[0].id
  description                  = "${each.key} from HAProxy"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_ingress_rule" "ignition_http_from_nodes" {
  count = var.enable_cluster_prerequisites ? 1 : 0

  security_group_id            = aws_security_group.ignition_server[0].id
  referenced_security_group_id = aws_security_group.openshift_nodes[0].id
  description                  = "Ignition delivery from the Installer host"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_instance" "openshift" {
  for_each = local.enabled_openshift_hosts

  ami                         = data.aws_ami.rhcos[0].id
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.cluster[each.value.subnet].id
  private_ip                  = each.value.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids = [
    aws_security_group.openshift_nodes[0].id,
    each.value.node_role == "worker" ? aws_security_group.openshift_worker[0].id : aws_security_group.openshift_control_plane[0].id,
  ]
  user_data_replace_on_change = true

  user_data = jsonencode({
    ignition = {
      version = var.ignition_spec_version
      config = {
        merge = [{
          source = "${var.ignition_base_url}/${each.value.ignition_role}.ign"
          verification = {
            hash = "sha512-${var.ignition_sha512[each.value.ignition_role]}"
          }
        }]
      }
    }
    storage = {
      files = [{
        path      = "/etc/hostname"
        mode      = 420
        overwrite = true
        contents = {
          source = "data:text/plain;charset=utf-8;base64,${base64encode("${each.key}.${local.cluster_domain}\n")}"
        }
      }]
    }
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.root_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.project_name}-${each.key}-root"
    }
  }

  tags = {
    Name = "${var.project_name}-${each.key}"
    Role = each.value.node_role
  }

  lifecycle {
    precondition {
      condition     = var.enable_cluster_prerequisites
      error_message = "enable_cluster_prerequisites must remain true while OpenShift nodes exist."
    }

    precondition {
      condition     = var.enable_cluster_nodes
      error_message = "enable_cluster_nodes must be true when creating the bootstrap or permanent nodes."
    }

    precondition {
      condition     = var.rhcos_ami_id != null && var.ignition_base_url != null
      error_message = "Set rhcos_ami_id and ignition_base_url before creating OpenShift nodes."
    }

    precondition {
      condition     = can(regex("^[0-9a-f]{128}$", var.ignition_sha512[each.value.ignition_role]))
      error_message = "Set the SHA-512 digest for every enabled Ignition role."
    }
  }

  depends_on = [
    aws_vpc_dhcp_options_association.cluster,
    aws_lb_listener.openshift,
  ]
}
