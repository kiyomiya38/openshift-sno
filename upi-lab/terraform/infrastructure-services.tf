resource "aws_key_pair" "infrastructure" {
  count = var.enable_infrastructure_services ? 1 : 0

  key_name   = "${var.project_name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = "${var.project_name}-key"
  }
}

resource "aws_iam_role" "infrastructure" {
  count = var.enable_infrastructure_services ? 1 : 0

  name = "${var.project_name}-infrastructure"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-infrastructure-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.enable_infrastructure_services ? 1 : 0

  role       = aws_iam_role.infrastructure[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "infrastructure" {
  count = var.enable_infrastructure_services ? 1 : 0

  name = "${var.project_name}-infrastructure"
  role = aws_iam_role.infrastructure[0].name
}

resource "aws_security_group" "infrastructure_admin" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-infrastructure-admin"
  description = "Administration and common egress for infrastructure hosts"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Allow infrastructure hosts outbound access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-infrastructure-admin-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "admin_ssh_from_vpn" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id            = aws_security_group.infrastructure_admin[0].id
  referenced_security_group_id = aws_security_group.client_vpn[0].id
  description                  = "SSH from AWS Client VPN"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_security_group" "dns_ntp" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-dns-ntp"
  description = "DNS and NTP services for the lab VPC"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-dns-ntp-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "dns_udp_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.dns_ntp[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "DNS UDP from VPC"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_ingress_rule" "dns_tcp_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.dns_ntp[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "DNS TCP from VPC"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_ingress_rule" "dns_udp_from_vpn" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id            = aws_security_group.dns_ntp[0].id
  referenced_security_group_id = aws_security_group.client_vpn[0].id
  description                  = "DNS UDP from AWS Client VPN"
  ip_protocol                  = "udp"
  from_port                    = 53
  to_port                      = 53
}

resource "aws_vpc_security_group_ingress_rule" "dns_tcp_from_vpn" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id            = aws_security_group.dns_ntp[0].id
  referenced_security_group_id = aws_security_group.client_vpn[0].id
  description                  = "DNS TCP from AWS Client VPN"
  ip_protocol                  = "tcp"
  from_port                    = 53
  to_port                      = 53
}

resource "aws_vpc_security_group_ingress_rule" "ntp_udp_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.dns_ntp[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "NTP from VPC"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
}

resource "aws_security_group" "haproxy" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-haproxy"
  description = "OpenShift API, machine config, ingress, and health endpoints"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-haproxy-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "haproxy_vpc" {
  for_each = var.enable_infrastructure_services ? {
    api            = 6443
    machine_config = 22623
    ingress_http   = 80
    ingress_https  = 443
    health         = 1936
  } : {}

  security_group_id = aws_security_group.haproxy[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "${each.key} from VPC"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_security_group" "proxy_registry" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-proxy-registry"
  description = "Squid proxy and mirror registry from the lab VPC"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-proxy-registry-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.proxy_registry[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "Squid from VPC"
  ip_protocol       = "tcp"
  from_port         = 3128
  to_port           = 3128
}

resource "aws_vpc_security_group_ingress_rule" "registry_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.proxy_registry[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "Mirror registry from VPC"
  ip_protocol       = "tcp"
  from_port         = 5000
  to_port           = 5000
}

resource "aws_security_group" "nfs" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-nfs"
  description = "NFSv4 from the lab VPC"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-nfs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nfs_from_vpc" {
  count = var.enable_infrastructure_services ? 1 : 0

  security_group_id = aws_security_group.nfs[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "NFSv4 from VPC"
  ip_protocol       = "tcp"
  from_port         = 2049
  to_port           = 2049
}

resource "aws_instance" "infrastructure" {
  for_each = var.enable_infrastructure_services ? local.infrastructure_hosts : {}

  ami                         = data.aws_ami.rhel_infrastructure[0].id
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.infra[each.value.subnet].id
  private_ip                  = each.value.private_ip
  associate_public_ip_address = false
  key_name                    = aws_key_pair.infrastructure[0].key_name
  iam_instance_profile        = aws_iam_instance_profile.infrastructure[0].name
  vpc_security_group_ids = compact([
    aws_security_group.infrastructure_admin[0].id,
    contains(each.value.roles, "dns_ntp") ? aws_security_group.dns_ntp[0].id : null,
    contains(each.value.roles, "haproxy") ? aws_security_group.haproxy[0].id : null,
    contains(each.value.roles, "proxy_registry") ? aws_security_group.proxy_registry[0].id : null,
    contains(each.value.roles, "nfs") ? aws_security_group.nfs[0].id : null,
    each.key == "installer" ? aws_security_group.ignition_server[0].id : null,
  ])

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.root_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.project_name}-${each.key}-root"
    }
  }

  tags = {
    Name = "${var.project_name}-${each.key}"
    Role = each.key
  }

  lifecycle {
    precondition {
      condition     = var.enable_client_vpn
      error_message = "enable_client_vpn must remain true when creating infrastructure services."
    }
  }
}

resource "aws_security_group" "internal_nlb" {
  count = var.enable_infrastructure_services ? 1 : 0

  name        = "${var.project_name}-internal-nlb"
  description = "Internal OpenShift NLB entry points"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Forward traffic to HAProxy hosts"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-internal-nlb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_vpc" {
  for_each = var.enable_infrastructure_services ? local.nlb_services : {}

  security_group_id = aws_security_group.internal_nlb[0].id
  cidr_ipv4         = var.vpc_cidr
  description       = "${each.key} from VPC"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_vpn" {
  for_each = var.enable_infrastructure_services ? {
    api           = 6443
    ingress_http  = 80
    ingress_https = 443
  } : {}

  security_group_id            = aws_security_group.internal_nlb[0].id
  referenced_security_group_id = aws_security_group.client_vpn[0].id
  description                  = "${each.key} from AWS Client VPN"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_lb" "openshift_internal" {
  count = var.enable_infrastructure_services ? 1 : 0

  name               = "openshift-upi-internal"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.internal_nlb[0].id]

  dynamic "subnet_mapping" {
    for_each = local.nlb_mappings
    content {
      subnet_id            = aws_subnet.cluster[subnet_mapping.key].id
      private_ipv4_address = subnet_mapping.value
    }
  }

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = {
    Name = "${var.project_name}-internal-nlb"
  }
}

resource "aws_lb_target_group" "openshift" {
  for_each = var.enable_infrastructure_services ? local.nlb_services : {}

  name        = "upi-${replace(each.key, "_", "-")}"
  port        = each.value.port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.lab.id

  health_check {
    enabled             = true
    protocol            = each.value.health_protocol
    port                = each.value.health_port
    path                = each.value.health_path
    healthy_threshold   = each.value.healthy_threshold
    unhealthy_threshold = each.value.unhealthy_threshold
    interval            = 30
    timeout             = 6
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.project_name}-${each.key}-tg"
  }
}

resource "aws_lb_target_group_attachment" "haproxy" {
  for_each = var.enable_infrastructure_services ? {
    for pair in setproduct(keys(local.nlb_services), ["haproxy-0", "haproxy-1"]) : "${pair[0]}:${pair[1]}" => {
      service = pair[0]
      host    = pair[1]
    }
  } : {}

  target_group_arn = aws_lb_target_group.openshift[each.value.service].arn
  target_id        = aws_instance.infrastructure[each.value.host].id
  port             = local.nlb_services[each.value.service].port
}

resource "aws_lb_listener" "openshift" {
  for_each = var.enable_infrastructure_services ? local.nlb_services : {}

  load_balancer_arn = aws_lb.openshift_internal[0].arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openshift[each.key].arn
  }
}
