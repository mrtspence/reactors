provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      project    = "reactor"
      managed_by = "terraform"
      layer      = "bootstrap"
    }
  }
}
