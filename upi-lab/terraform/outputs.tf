output "account_id" {
  description = "AWS account used by this configuration."
  value       = data.aws_caller_identity.current.account_id
}

output "public_hosted_zone" {
  description = "Existing public hosted zone read through a data source."
  value = {
    id   = data.aws_route53_zone.lab.zone_id
    name = data.aws_route53_zone.lab.name
  }
}

output "vpc_id" {
  description = "Lab VPC ID."
  value       = aws_vpc.lab.id
}

output "cluster_subnet_ids" {
  description = "Cluster subnet IDs keyed by logical name."
  value       = { for name, subnet in aws_subnet.cluster : name => subnet.id }
}

output "infra_subnet_ids" {
  description = "Infrastructure subnet IDs keyed by logical name."
  value       = { for name, subnet in aws_subnet.infra : name => subnet.id }
}

output "public_subnet_ids" {
  description = "Public egress subnet IDs keyed by logical name."
  value       = { for name, subnet in aws_subnet.public : name => subnet.id }
}

output "nat_gateway_id" {
  description = "Initial single-AZ NAT Gateway ID."
  value       = aws_nat_gateway.a.id
}

output "client_vpn_endpoint_id" {
  description = "AWS Client VPN endpoint ID, or null when disabled."
  value       = var.enable_client_vpn ? aws_ec2_client_vpn_endpoint.lab[0].id : null
}

output "client_vpn_security_group_id" {
  description = "Security group used as the source for future infrastructure ingress rules."
  value       = var.enable_client_vpn ? aws_security_group.client_vpn[0].id : null
}

output "infrastructure_ami" {
  description = "Official RHEL AMI selected for Phase 4 infrastructure hosts."
  value = var.enable_infrastructure_services ? {
    id   = data.aws_ami.rhel_infrastructure[0].id
    name = data.aws_ami.rhel_infrastructure[0].name
  } : null
}

output "infrastructure_instances" {
  description = "Infrastructure host IDs and fixed private addresses."
  value = {
    for name, instance in aws_instance.infrastructure : name => {
      id         = instance.id
      private_ip = instance.private_ip
      subnet_id  = instance.subnet_id
    }
  }
}

output "internal_nlb" {
  description = "Internal OpenShift NLB details."
  value = var.enable_infrastructure_services ? {
    arn         = aws_lb.openshift_internal[0].arn
    dns_name    = aws_lb.openshift_internal[0].dns_name
    private_ips = local.nlb_mappings
  } : null
}

output "internal_nlb_target_groups" {
  description = "Internal NLB target group ARNs keyed by OpenShift service."
  value       = { for name, target_group in aws_lb_target_group.openshift : name => target_group.arn }
}

output "cluster_dhcp_options_id" {
  description = "DHCP options that give RHCOS nodes the BIND and NTP servers."
  value       = var.enable_cluster_prerequisites ? aws_vpc_dhcp_options.cluster[0].id : null
}

output "ignition_server_security_group_id" {
  description = "Security group attached only to Installer for private Ignition delivery."
  value       = var.enable_infrastructure_services ? aws_security_group.ignition_server[0].id : null
}

output "rhcos_ami" {
  description = "RHCOS AMI validated for the current OpenShift installer."
  value = length(local.enabled_openshift_hosts) > 0 ? {
    id   = data.aws_ami.rhcos[0].id
    name = data.aws_ami.rhcos[0].name
  } : null
}

output "openshift_instances" {
  description = "OpenShift node IDs, roles, fixed private addresses, and subnets."
  value = {
    for name, instance in aws_instance.openshift : name => {
      id         = instance.id
      role       = local.openshift_hosts[name].node_role
      private_ip = instance.private_ip
      subnet_id  = instance.subnet_id
    }
  }
}
