# EKS cluster hosting the demo's checkout-service/billing-service
# workloads, replacing the local `kind` cluster used previously. Public
# subnets only (no NAT gateway) to keep this cheap and short-lived for a
# demo -- nodes get a public IP directly. The EKS API server is public too,
# restricted to var.eks_public_access_cidrs, since HCP Vault Dedicated's
# kubernetes secrets engine needs to reach it without HVN peering.

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = "10.90.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.90.0.0/20", "10.90.16.0/20"]

  map_public_ip_on_launch = true
  enable_dns_hostnames    = true
  enable_dns_support      = true

  # EKS needs these tags to auto-discover subnets for load balancers --
  # unused by this demo (no Services of type LoadBalancer) but harmless to
  # leave on in case that's added later.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs
  cluster_endpoint_private_access      = false

  # Grants the Terraform-applying IAM principal cluster-admin via an EKS
  # access entry -- no hand-rolled aws-auth configmap needed.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # Nodes sit in the public subnets above and need a public IP to pull
      # images / reach the EKS API without a NAT gateway. The subnets set
      # map_public_ip_on_launch above; verify after apply with `aws ec2
      # describe-instances` that nodes actually got a public IP -- if the
      # node group's launch template ends up overriding that (module
      # version-dependent), the fallback is a NAT gateway on module.vpc
      # (`enable_nat_gateway = true`) instead of relying on public IPs.
      subnet_ids = module.vpc.public_subnets
    }
  }
}
