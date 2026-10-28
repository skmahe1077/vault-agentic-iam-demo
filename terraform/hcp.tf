# HCP Vault Dedicated cluster + HVN peering to this VPC.
#
# HCP Vault Dedicated publishes no static egress IP list, so the only
# supported way for it to reach a private resource in this VPC (the
# orders-db RDS instance, terraform/rds.tf) is HVN peering -- not a CIDR
# allowlist, which is what the EKS side has to fall back to instead (see
# the comment on var.eks_public_access_cidrs).
#
# Uses the existing HVN (var.hvn_id) rather than creating one -- this repo
# doesn't own that network's lifecycle.
data "hcp_hvn" "main" {
  hvn_id = var.hvn_id
}

resource "hcp_vault_cluster" "main" {
  cluster_id        = var.vault_cluster_id
  hvn_id            = data.hcp_hvn.main.hvn_id
  tier              = var.vault_tier
  min_vault_version = var.min_vault_version

  # Public endpoint so the presenter's local `vault` CLI can reach it
  # without also needing to be inside the peered network. Locked to the
  # presenter's own IP -- unlike the EKS side, HCP clusters really do
  # support a usable IP allowlist for this (ip_allowlist below), since it's
  # Vault's own inbound listener, not a dependency on Vault's egress IPs.
  public_endpoint = true

  ip_allowlist {
    address     = var.presenter_ip_cidr
    description = "presenter laptop"
  }
}

resource "hcp_aws_network_peering" "main" {
  hvn_id          = data.hcp_hvn.main.hvn_id
  peering_id      = "${var.cluster_name}-peering"
  peer_vpc_id     = module.vpc.vpc_id
  peer_account_id = data.aws_caller_identity.current.account_id
  peer_vpc_region = var.aws_region
}

resource "aws_vpc_peering_connection_accepter" "main" {
  vpc_peering_connection_id = hcp_aws_network_peering.main.provider_peering_id
  auto_accept               = true
}

# HVN-side route: traffic from the Vault cluster to this VPC's CIDR goes
# over the peering connection.
resource "hcp_hvn_route" "to_vpc" {
  hvn_link         = data.hcp_hvn.main.self_link
  hvn_route_id     = "${var.cluster_name}-to-vpc"
  destination_cidr = module.vpc.vpc_cidr_block
  target_link      = hcp_aws_network_peering.main.self_link
}

# VPC-side return routes: traffic from the private subnets (where RDS
# lives) back to the HVN's CIDR goes over the same peering connection.
# Public subnets don't need this -- nothing in them talks to Vault over
# the peered path; EKS is reached over the public internet instead.
resource "aws_route" "private_to_hvn" {
  count                     = length(module.vpc.private_route_table_ids)
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = data.hcp_hvn.main.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.main.id
}

data "aws_caller_identity" "current" {}

# Admin token for the one-time setup scripts (vault-config/*.sh) and the
# presenter's `vault login`. Not the agent/human identities' own
# credentials -- those come from Agent Registry/OIDC, set up afterward.
resource "hcp_vault_cluster_admin_token" "main" {
  cluster_id = hcp_vault_cluster.main.cluster_id
}
