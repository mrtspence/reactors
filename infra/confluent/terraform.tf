terraform {
  required_version = "~> 1.15"
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.94"
    }
  }
  backend "s3" {
    bucket       = "reactor-337903911763-us-east-2-an"
    key          = "confluent/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
