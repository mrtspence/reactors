terraform {
  backend "s3" {
    bucket       = "reactor-337903911763-us-east-2-an"
    key          = "confluent/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
