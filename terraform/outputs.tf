output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint -- this is K8S_HOST for vault-config/01-enable-secrets-engines.sh."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA cert. Decode and save to a file for K8S_CA_CERT: `terraform output -raw cluster_certificate_authority_data | base64 -d > ca.pem`."
  value       = module.eks.cluster_certificate_authority_data
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "orders_db_endpoint" {
  description = "orders-db host:port -- this is ORDERS_DB_HOST (minus the port) for vault-config/01-enable-secrets-engines.sh, and what orders-db-proxy.yaml forwards to."
  value       = aws_db_instance.orders_db.endpoint
}

output "orders_db_address" {
  description = "orders-db hostname only (no port)."
  value       = aws_db_instance.orders_db.address
}

output "vault_public_endpoint_url" {
  description = "HCP Vault Dedicated cluster's public URL -- this is VAULT_ADDR."
  value       = hcp_vault_cluster.main.vault_public_endpoint_url
}

output "vault_cluster_version" {
  description = "Vault version on the provisioned cluster. Agent Registry requires 2.1.2+ -- verify this before configuring anything."
  value       = hcp_vault_cluster.main.vault_version
}

output "vault_admin_token" {
  description = "Admin token for the one-time setup scripts and presenter login: `vault login $(terraform -chdir=terraform output -raw vault_admin_token)`. Not committed anywhere -- this only ever lives in Terraform state and your shell."
  value       = hcp_vault_cluster_admin_token.main.token
  sensitive   = true
}
