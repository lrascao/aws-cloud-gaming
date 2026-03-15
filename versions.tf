terraform {
  required_version = ">= 1.3"

  backend "s3" {
    # Configured via -backend-config at init time:
    #   terraform init \
    #     -backend-config="bucket=cloudrig-terraform-state" \
    #     -backend-config="region=us-east-1" \
    #     -backend-config="dynamodb_table=cloudrig-terraform-locks"
    key     = "cloudrig/terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
