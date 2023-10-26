## Cloudwatch log group
resource "aws_cloudwatch_log_group" "log_group" {
  name              = "locust-stack"
  retention_in_days = 7
}

## IAM
resource "aws_iam_role" "ecs_role" {
  name = "locust-stack-ecs-role"

  assume_role_policy = jsoncode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:Assumerole"
      Effect = "Allow"
      Sid    = "assumeRole"
      Principal = {
        Service = ["ecs.amazonaws.com", "ecs-tasks.amazonaws.com"]
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attachrole" {
  role       = aws_iam_role.ecs_role.name
  policy_arn = data.aws_iam_policy.max.arn
}

## alb

### SG
resource "aws_security_group" "sg_alb" {
  name        = "locust-alb-ecs"
  description = "ALB Locust"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow access in locust web ui port to alb"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

### alb
resource "aws_lb" "alb" {
  name                       = "locust-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.sg_alb.id]
  subnets                    = toset(data.aws_subnets.public.ids)
  enable_deletion_protection = false
}

### alb tg
resource "aws_alb_target_group" "alb_tg_ecs" {
  name        = "locust-alb-tg"
  port        = 8089
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  stickiness {
    enabled = true
    type    = "lb_coockie"
  }

  health_check {
    healthy_threshold   = "2"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200-300"
    timeout             = "20"
    path                = "/"
    unhealthy_threshold = "2"
  }

  lifecycle {
    create_before_destroy = false
    ignore_changes        = [name]
  }
}

### alb listner
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 8089
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.alb_tg_ecs.arn
  }
}

## ECR and dockerfile

### ECR
resource "aws_ecr_repository" "locust-custom" {
  name                 = "locust-custom"
  image_tag_mutability = "MUTABLE"
}

resource "null_resource" "docker_packaging" {
  provisioner "local-exec" {
    command = <<EOF
        echo 'LOGIN REGISTRY'
        aws ecr get-login-password --region ${var.region} --profile ${var.profile} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com
        echo 'IMAGE BUILD'
        docker build -t "${aws_ecr_repository.locust-custom.repository_url}:latest" -f Dockerfile .
        echo 'IMAGE PUSH'
        docker push "${aws_ecr_repository.locust-custom.repository_url}:latest"
        EOF
  }

  triggers = {
    "run_at" = timestamp()
  }

  depends_on = [aws_ecr_repository.locust-custom]
}

## ECS (Cluster, Service, Task and Service discovery)

### Service Discovery
resource "aws_service_discovery_private_dns_namespace" "namespace" {
  name        = "locust.namespace"
  description = "Gateway para comunicação entre os serviços de master e worker"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "service-discovery-master" {
  name = "master"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.namespace.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "service-discovery-worker" {
  name = "worker"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.namespace.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster" {
  cluster_name       = "locust-cluster"
  capacity_providers = ["FARGATE_SPOT", "FARGATE"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 1
    weight            = 100
  }
}

### Clsuter ECS
resource "aws_ecs_cluster" "cluster" {
  name = "locust-cluster"
  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.log_group.name
      }
    }
  }
}

# Task-defination
resource "aws_ecs_task_definition" "master-task-definition" {
  #var_tasks_id = aws_ecs_task_definition.master-task-definition.task.arn
  depends_on               = [null_resource.docker_packaging]
  family                   = "locust-task-master-definition"
  execution_role_arn       = aws_iam_role.ecs_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.ecs_role.arn
  cpu                      = 512
  memory                   = 1024
  container_definitions = jsonencode([
    {
      name  = "master"
      image = "${aws_ecr_repository.locust-custom.repository_url}"
      command = [
        "-f", "/mnt/locust/locustfile.py", "--master", "-H", "http://master:8089"
      ]
      cpu    = 512
      memory = 1024
      portMappings = [
        {
          name          = "locust_web_port"
          containerPort = 8089
          hostPort      = 8089
        },
        {
          name          = "locust_master_port"
          containerPort = 5557
          hostPort      = 5557
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          #todo: Alterar Nome do log
          awslogs-group         = aws_cloudwatch_log_group.log_group.name
          awslogs-region        = "us-west-2"
          awslogs-stream-prefix = "master"
        }
      }
    }

  ])
}

resource "aws_ecs_task_definition" "worker-task-definition" {
  depends_on               = [null_resource.docker_packaging]
  family                   = "locust-task-worker-definition"
  execution_role_arn       = aws_iam_role.ecs_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.ecs_role.arn
  cpu                      = 512
  memory                   = 1024
  container_definitions = jsonencode([
    {
      name  = "worker"
      image = "${aws_ecr_repository.locust-custom.repository_url}"
      command = [
        "-f", "/mnt/locust/locustfile.py", "--worker", "--master-host", "master.locust.namespace"
      ]
      cpu    = 512
      memory = 256
      portMappings = [
        {
          name          = "locust_worker_port"
          containerPort = 5557
          hostPort      = 5557
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          #todo: Alterar Nome do log
          awslogs-group         = aws_cloudwatch_log_group.log_group.name
          awslogs-region        = "us-west-2"
          awslogs-stream-prefix = "worker"
        }
      }
    }
  ])
}

### SG services
resource "aws_security_group" "sg_ecs" {
  name        = "locust-sg-ecs"
  description = "SG cluster locust"
  vpc_id      = var.vpc_id

  ingress {
    description = "Permite acesso entre os servicos"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Permite acesso entre os servicos"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    self        = true
  }

  ingress {
    description     = "Permite acesso SG do lb"
    from_port       = 8089
    to_port         = 8089
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_alb.id]
  }

  ingress {
    description = "Permite acesso SG do lb"
    from_port   = 5557
    to_port     = 5557
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}


resource "aws_ecs_service" "master" {
  name            = "master"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.master-task-definition.arn
  desired_count   = 1
  depends_on      = [aws_iam_role_policy_attachment.attachrole, null_resource.docker_packaging]
  #launch_type = "FARGATE"
  load_balancer {
    target_group_arn = aws_alb_target_group.alb_tg_ecs.arn
    container_name   = "master"
    container_port   = 8089
  }

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.sg_ecs.id]
    subnets          = toset(data.aws_subnets.public.ids)
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.service-discovery-master.arn
    container_name = "master"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}


resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.worker-task-definition.arn
  desired_count   = var.workers
  depends_on      = [aws_iam_role_policy_attachment.attachrole, null_resource.docker_packaging]

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.sg_ecs.id]
    subnets          = toset(data.aws_subnets.public.ids)
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.service-discovery-worker.arn
    container_name = "worker"
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}



resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 100
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.cluster.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy_task_up" {
  name               = "locust-autoscaling-policy-up"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 30
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_task_down" {
  name               = "locust-autoscaling-policy-down"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_high" {
  alarm_name          = "locust-CPU-Utilization-High"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "30"
  statistic           = "Average"
  threshold           = var.ecs_cpu_high_threshold

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.worker.name
  }

  alarm_actions = [aws_appautoscaling_policy.ecs_policy_task_up.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_low" {
  alarm_name          = "locust-CPU-Utilization-Low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = var.ecs_cpu_low_threshold

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.worker.name
  }

  alarm_actions = [aws_appautoscaling_policy.ecs_policy_task_down.arn]
}