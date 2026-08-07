locals {
  cluster_subnets = {
    cluster-a = { az = "ap-northeast-3a", cidr = "10.80.10.0/24" }
    cluster-b = { az = "ap-northeast-3b", cidr = "10.80.20.0/24" }
    cluster-c = { az = "ap-northeast-3c", cidr = "10.80.30.0/24" }
  }

  infra_subnets = {
    infra-a = { az = "ap-northeast-3a", cidr = "10.80.40.0/24" }
    infra-b = { az = "ap-northeast-3b", cidr = "10.80.50.0/24" }
    infra-c = { az = "ap-northeast-3c", cidr = "10.80.60.0/24" }
  }

  public_subnets = {
    public-a = { az = "ap-northeast-3a", cidr = "10.80.110.0/24" }
    public-b = { az = "ap-northeast-3b", cidr = "10.80.120.0/24" }
    public-c = { az = "ap-northeast-3c", cidr = "10.80.130.0/24" }
  }

  infrastructure_hosts = {
    installer = {
      subnet        = "infra-a"
      private_ip    = "10.80.40.10"
      instance_type = "t3.medium"
      root_gib      = 50
      roles         = ["admin"]
    }
    dns-ntp-0 = {
      subnet        = "infra-a"
      private_ip    = "10.80.40.11"
      instance_type = "t3.small"
      root_gib      = 20
      roles         = ["admin", "dns_ntp"]
    }
    dns-ntp-1 = {
      subnet        = "infra-b"
      private_ip    = "10.80.50.11"
      instance_type = "t3.small"
      root_gib      = 20
      roles         = ["admin", "dns_ntp"]
    }
    haproxy-0 = {
      subnet        = "infra-a"
      private_ip    = "10.80.40.21"
      instance_type = "t3.small"
      root_gib      = 20
      roles         = ["admin", "haproxy"]
    }
    haproxy-1 = {
      subnet        = "infra-b"
      private_ip    = "10.80.50.21"
      instance_type = "t3.small"
      root_gib      = 20
      roles         = ["admin", "haproxy"]
    }
    proxy-registry = {
      subnet        = "infra-a"
      private_ip    = "10.80.40.31"
      instance_type = "m6i.large"
      root_gib      = 200
      roles         = ["admin", "proxy_registry"]
    }
    nfs-0 = {
      subnet        = "infra-a"
      private_ip    = "10.80.40.41"
      instance_type = "m6i.large"
      root_gib      = 200
      roles         = ["admin", "nfs"]
    }
  }

  nlb_mappings = {
    cluster-a = "10.80.10.5"
    cluster-b = "10.80.20.5"
    cluster-c = "10.80.30.5"
  }

  nlb_services = {
    api = {
      port                = 6443
      health_protocol     = "HTTPS"
      health_port         = "traffic-port"
      health_path         = "/readyz"
      healthy_threshold   = 2
      unhealthy_threshold = 2
    }
    machine_config = {
      port                = 22623
      health_protocol     = "HTTPS"
      health_port         = "traffic-port"
      health_path         = "/healthz"
      healthy_threshold   = 2
      unhealthy_threshold = 2
    }
    ingress_http = {
      port                = 80
      health_protocol     = "HTTP"
      health_port         = "1936"
      health_path         = "/healthz/ready"
      healthy_threshold   = 2
      unhealthy_threshold = 2
    }
    ingress_https = {
      port                = 443
      health_protocol     = "HTTP"
      health_port         = "1936"
      health_path         = "/healthz/ready"
      healthy_threshold   = 2
      unhealthy_threshold = 2
    }
  }

  cluster_domain = "${var.cluster_name}.${var.base_domain}"

  openshift_hosts = {
    bootstrap = {
      subnet        = "cluster-a"
      private_ip    = "10.80.10.30"
      instance_type = "m6i.xlarge"
      root_gib      = 120
      ignition_role = "bootstrap"
      node_role     = "bootstrap"
    }
    control-plane-0 = {
      subnet        = "cluster-a"
      private_ip    = "10.80.10.10"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "master"
      node_role     = "control-plane"
    }
    control-plane-1 = {
      subnet        = "cluster-b"
      private_ip    = "10.80.20.10"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "master"
      node_role     = "control-plane"
    }
    control-plane-2 = {
      subnet        = "cluster-c"
      private_ip    = "10.80.30.10"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "master"
      node_role     = "control-plane"
    }
    worker-0 = {
      subnet        = "cluster-a"
      private_ip    = "10.80.10.20"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "worker"
      node_role     = "worker"
    }
    worker-1 = {
      subnet        = "cluster-b"
      private_ip    = "10.80.20.20"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "worker"
      node_role     = "worker"
    }
    worker-2 = {
      subnet        = "cluster-c"
      private_ip    = "10.80.30.20"
      instance_type = "m6i.xlarge"
      root_gib      = 150
      ignition_role = "worker"
      node_role     = "worker"
    }
  }

  enabled_openshift_hosts = merge(
    var.enable_cluster_nodes ? {
      for name, host in local.openshift_hosts : name => host if name != "bootstrap"
    } : {},
    var.enable_bootstrap ? {
      bootstrap = local.openshift_hosts.bootstrap
    } : {},
  )

  common_tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
    Purpose   = "OpenShift-UPI-Learning"
    Owner     = var.owner_tag
  }
}
