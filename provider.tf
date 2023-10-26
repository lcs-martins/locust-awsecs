provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      stack = "locust"
      # add you own if needed...
    }
  }
}