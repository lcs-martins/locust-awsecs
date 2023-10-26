variable "region" {}
variable "profile" {}
variable "vpc_id" {}
variable "workers" {}


# Values for autoscalling metrics
variable "ecs_cpu_low_threshold" {
  default = "20"
}

variable "ecs_cpu_high_threshold" {
  default = "80"
}