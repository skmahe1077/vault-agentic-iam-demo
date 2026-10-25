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
