resource "aws_cloudwatch_log_group" "client_vpn" {
  count = var.enable_client_vpn ? 1 : 0

  name              = "/aws/client-vpn/${var.project_name}"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-client-vpn-logs"
  }
}

resource "aws_cloudwatch_log_stream" "client_vpn" {
  count = var.enable_client_vpn ? 1 : 0

  name           = "connections"
  log_group_name = aws_cloudwatch_log_group.client_vpn[0].name
}

resource "aws_security_group" "client_vpn" {
  count = var.enable_client_vpn ? 1 : 0

  name        = "${var.project_name}-client-vpn"
  description = "Controls traffic sent from AWS Client VPN clients"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Allow VPN clients to reach the lab VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-client-vpn-sg"
  }
}

resource "aws_ec2_client_vpn_endpoint" "lab" {
  count = var.enable_client_vpn ? 1 : 0

  description            = "OpenShift UPI lab administration"
  server_certificate_arn = var.client_vpn_server_certificate_arn
  client_cidr_block      = var.client_vpn_cidr
  vpc_id                 = aws_vpc.lab.id
  security_group_ids     = [aws_security_group.client_vpn[0].id]
  dns_servers            = var.client_vpn_dns_servers
  split_tunnel           = true
  transport_protocol     = "udp"
  vpn_port               = 443
  session_timeout_hours  = 8
  self_service_portal    = "disabled"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_vpn_server_certificate_arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.client_vpn[0].name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.client_vpn[0].name
  }

  tags = {
    Name = "${var.project_name}-client-vpn"
  }

  lifecycle {
    precondition {
      condition     = var.client_vpn_server_certificate_arn != null
      error_message = "client_vpn_server_certificate_arn is required when enable_client_vpn is true."
    }

    precondition {
      condition = (
        var.client_vpn_server_certificate_arn != null &&
        startswith(
          var.client_vpn_server_certificate_arn,
          "arn:aws:acm:${var.aws_region}:${var.expected_account_id}:certificate/"
        )
      )
      error_message = "The Client VPN certificate must belong to the expected AWS account and configured region."
    }
  }
}

resource "aws_ec2_client_vpn_network_association" "infra_a" {
  count = var.enable_client_vpn ? 1 : 0

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.lab[0].id
  subnet_id              = aws_subnet.infra["infra-a"].id
}

# Associate a second Availability Zone so management access does not depend on
# a single Client VPN target-network association.
resource "aws_ec2_client_vpn_network_association" "infra_b" {
  count = var.enable_client_vpn ? 1 : 0

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.lab[0].id
  subnet_id              = aws_subnet.infra["infra-b"].id
}

resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  count = var.enable_client_vpn ? 1 : 0

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.lab[0].id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Allow certificate-authenticated clients to reach the lab VPC"
}
