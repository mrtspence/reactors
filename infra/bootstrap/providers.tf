variable "aws_profile" {
  type        = string
  description = "The AWS CLI profile to use"
}

provider "aws" {
  region = "us-east-2"
  profile = var.aws_profile # can pass in with export TF_VAR_aws_profile for now?
  default_tags {
    tags = {
      project    = "reactor"
      managed_by = "terraform"
      layer      = "bootstrap"
    }
  }
}
