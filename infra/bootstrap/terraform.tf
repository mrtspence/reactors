terraform {
  required_version = "~> 1.17.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.23"
    }
  }
  backend "s3" {
    bucket       = "reactor-337903911763-us-east-2-an"
    key          = "global/s3/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
