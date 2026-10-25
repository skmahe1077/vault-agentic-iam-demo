variable "aws_region" {
  description = "AWS region to create the EKS cluster in."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name -- also used as the kubectl context alias. Keep in sync with CLUSTER_NAME used by the demo scripts."
  type        = string
  default     = "vault-agentic-iam"
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Instance type for the single managed node group. The demo workload is two nginx-based Deployments -- tiny, so a small instance is enough."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

# The EKS API server is given a public endpoint (no HVN peering/tunnel) so
# HCP Vault Dedicated's kubernetes secrets engine can reach it directly.
# Lock this down to HCP's published egress CIDR ranges (see HashiCorp's HCP
# network documentation -- these change over time, so look them up fresh
# rather than trusting a stale list) plus your own IP for kubectl/bootstrap
# access. There is deliberately no default -- an empty/wide-open CIDR list
# would expose the cluster's API server to the entire internet.
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint: HCP Vault Dedicated's published egress ranges + your own IP (e.g. \"$(curl -s https://checkip.amazonaws.com)/32\")."
  type        = list(string)

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0
    error_message = "Set at least one CIDR (your own IP, plus HCP Vault Dedicated's published egress ranges) -- an empty list would leave the default wide open."
  }
}
