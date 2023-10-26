output "web_ui" {
  value = "${aws_lb.alb.dns_name}:8089"
}
