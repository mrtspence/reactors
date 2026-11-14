# The teardown check lists resources by these tags, so anything created outside
# this provider (for my k8s controller later, for exmpl) must be given them too.
# TODO: Remove this comment once that's sorted
provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = {
      project    = "reactor"
      managed_by = "terraform"
      layer      = "ephemeral"
    }
  }
}
