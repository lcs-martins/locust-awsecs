data "aws_caller_identity" "current" {}

data "aws_iam_policy" "max" { arn = "arn:aws:iam::aws:policy/AdministratorAccess" }

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    Network = "Public"
  }
}