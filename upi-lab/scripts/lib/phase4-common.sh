#!/usr/bin/env bash

PHASE4_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=safety-common.sh
source "$PHASE4_LIB_DIR/safety-common.sh"

phase4_expected_actions() {
  cat <<'EOF'
aws_iam_instance_profile.infrastructure[0]:create
aws_iam_role.infrastructure[0]:create
aws_iam_role_policy_attachment.ssm[0]:create
aws_instance.infrastructure["dns-ntp-0"]:create
aws_instance.infrastructure["dns-ntp-1"]:create
aws_instance.infrastructure["haproxy-0"]:create
aws_instance.infrastructure["haproxy-1"]:create
aws_instance.infrastructure["installer"]:create
aws_instance.infrastructure["nfs-0"]:create
aws_instance.infrastructure["proxy-registry"]:create
aws_key_pair.infrastructure[0]:create
aws_lb.openshift_internal[0]:create
aws_lb_listener.openshift["api"]:create
aws_lb_listener.openshift["ingress_http"]:create
aws_lb_listener.openshift["ingress_https"]:create
aws_lb_listener.openshift["machine_config"]:create
aws_lb_target_group.openshift["api"]:create
aws_lb_target_group.openshift["ingress_http"]:create
aws_lb_target_group.openshift["ingress_https"]:create
aws_lb_target_group.openshift["machine_config"]:create
aws_lb_target_group_attachment.haproxy["api:haproxy-0"]:create
aws_lb_target_group_attachment.haproxy["api:haproxy-1"]:create
aws_lb_target_group_attachment.haproxy["ingress_http:haproxy-0"]:create
aws_lb_target_group_attachment.haproxy["ingress_http:haproxy-1"]:create
aws_lb_target_group_attachment.haproxy["ingress_https:haproxy-0"]:create
aws_lb_target_group_attachment.haproxy["ingress_https:haproxy-1"]:create
aws_lb_target_group_attachment.haproxy["machine_config:haproxy-0"]:create
aws_lb_target_group_attachment.haproxy["machine_config:haproxy-1"]:create
aws_security_group.dns_ntp[0]:create
aws_security_group.haproxy[0]:create
aws_security_group.ignition_server[0]:create
aws_security_group.infrastructure_admin[0]:create
aws_security_group.internal_nlb[0]:create
aws_security_group.nfs[0]:create
aws_security_group.proxy_registry[0]:create
aws_vpc_security_group_ingress_rule.admin_ssh_from_vpn[0]:create
aws_vpc_security_group_ingress_rule.dns_tcp_from_vpc[0]:create
aws_vpc_security_group_ingress_rule.dns_tcp_from_vpn[0]:create
aws_vpc_security_group_ingress_rule.dns_udp_from_vpc[0]:create
aws_vpc_security_group_ingress_rule.dns_udp_from_vpn[0]:create
aws_vpc_security_group_ingress_rule.haproxy_vpc["api"]:create
aws_vpc_security_group_ingress_rule.haproxy_vpc["health"]:create
aws_vpc_security_group_ingress_rule.haproxy_vpc["ingress_http"]:create
aws_vpc_security_group_ingress_rule.haproxy_vpc["ingress_https"]:create
aws_vpc_security_group_ingress_rule.haproxy_vpc["machine_config"]:create
aws_vpc_security_group_ingress_rule.nfs_from_vpc[0]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpc["api"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpc["ingress_http"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpc["ingress_https"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpc["machine_config"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpn["api"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpn["ingress_http"]:create
aws_vpc_security_group_ingress_rule.nlb_from_vpn["ingress_https"]:create
aws_vpc_security_group_ingress_rule.ntp_udp_from_vpc[0]:create
aws_vpc_security_group_ingress_rule.proxy_from_vpc[0]:create
aws_vpc_security_group_ingress_rule.registry_from_vpc[0]:create
EOF
}

phase4_assert_exact_plan() {
  local terraform_dir="$1"
  local plan_file="$2"
  lab_assert_exact_plan_actions "$terraform_dir" "$plan_file" "$(phase4_expected_actions)"
}
