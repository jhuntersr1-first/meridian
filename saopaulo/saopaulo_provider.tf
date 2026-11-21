terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "saopaulo/terraform.tfstate"
    region = "us-east-1"
  }

}

# São Paulo is a separate Terraform state.
# This provider file is standalone — it does NOT reference the Tokyo provider.
# Tokyo outputs are consumed via variables (see variables.tf).
provider "aws" {
  alias  = "saopaulo"
  region = "sa-east-1"
}

# Default provider required by Terraform even when all resources use alias.
provider "aws" {
  region = "sa-east-1"
}

# Tokyo provider alias — used only to read the Secrets Manager secret
# that was created in ap-northeast-1 by the Tokyo state.
provider "aws" {
  alias  = "tokyo"
  region = "ap-northeast-1"
}

