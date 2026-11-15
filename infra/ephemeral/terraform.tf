terraform {
  required_version = "~> 1.15"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.23"
    }
    time = {
      source  = "hashicorp/time"
      version = "~>0.14"
    }
  }
}
