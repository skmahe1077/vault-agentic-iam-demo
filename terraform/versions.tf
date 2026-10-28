terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.100"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Reads credentials from the `hcp auth login` cache by default. If that
# doesn't satisfy the provider, fall back to an HCP service principal via
# HCP_CLIENT_ID/HCP_CLIENT_SECRET env vars -- no provider block change
# needed either way.
provider "hcp" {
  project_id = var.hcp_project_id
}
