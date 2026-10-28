variable "aws_region" {
  description = "AWS region to create the EKS cluster and RDS instance in. Must match the region of the existing HCP HVN (var.hvn_id) -- HVN peering is region-locked."
  type        = string
  default     = "us-west-2"
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

# HCP Vault Dedicated publishes no static egress IP list -- there is
# nothing to allowlist on the EKS side. HVN peering doesn't help here
# either: the EKS API server's public hostname resolves to public IPs even
# from inside a peered network, so Vault's connection takes the internet
# path regardless of peering. The endpoint has to be open to the internet;
# what actually protects it is IAM+RBAC auth on every request, same as any
# other public EKS cluster. Default reflects that (0.0.0.0/0 is the
# AWS/eksctl default for a public endpoint) -- override if you'd rather
# scope it to your own IP for kubectl access during setup, knowing Vault's
# calls still need the wider range.
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Defaults to open (0.0.0.0/0) because HCP Vault Dedicated has no static egress IPs to scope this to -- see comment above."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0
    error_message = "Set at least one CIDR -- an empty list would leave the default wide open in the opposite, unintended direction (no access at all)."
  }
}

variable "presenter_ip_cidr" {
  description = "Your own public IP in CIDR form (e.g. \"$(curl -s https://checkip.amazonaws.com)/32\"), used for the HCP Vault cluster's ip_allowlist and the RDS security group alongside the HVN's CIDR."
  type        = string
}

variable "orders_db_admin_password" {
  description = "Admin password for the orders-db RDS instance. Export as TF_VAR_orders_db_admin_password (reuse ORDERS_DB_ADMIN_PASSWORD from .env: `export TF_VAR_orders_db_admin_password=\"$ORDERS_DB_ADMIN_PASSWORD\"`)."
  type        = string
  sensitive   = true
}

variable "hvn_id" {
  description = "ID of the existing HCP HVN to peer with and run the Vault cluster in. Must already exist -- this repo doesn't create one."
  type        = string
  default     = "hvn"
}

variable "hcp_project_id" {
  description = "HCP project ID that owns the HVN and will own the Vault cluster. Find with `hcp profile display`."
  type        = string
}

variable "vault_cluster_id" {
  description = "ID for the new HCP Vault Dedicated cluster."
  type        = string
  default     = "vault-agentic-iam"
}

variable "vault_tier" {
  description = "HCP Vault Dedicated tier. Agentic IAM (Agent Registry) requires Standard or Essential on Vault 2.1.2+ -- but hcp_vault_cluster's Terraform schema only accepts dev/standard_*/plus_*, no literal \"essential\" value, so standard_small is the smallest tier that's both valid here and meets that requirement."
  type        = string
  default     = "standard_small"
}

variable "min_vault_version" {
  description = "Minimum Vault version for the HCP cluster. Agent Registry needs 2.1.2+; leave unset to let HCP pick its current recommended version (expected to already satisfy this)."
  type        = string
  default     = null
}
