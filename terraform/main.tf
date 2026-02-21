terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Use default VPC (simplest for getting started)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "wanderlog" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = false
  }

  tags = {
    Name        = "wanderlog"
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "wanderlog" {
  repository = aws_ecr_repository.wanderlog.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ── EFS Filesystem (for persistent DB and uploads) ───────────────────────────

resource "aws_efs_file_system" "wanderlog" {
  creation_token = "wanderlog-efs"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name        = "wanderlog-efs"
    Environment = var.environment
  }
}

resource "aws_efs_mount_target" "wanderlog" {
  count = length(data.aws_subnets.default.ids)

  file_system_id  = aws_efs_file_system.wanderlog.id
  subnet_id       = data.aws_subnets.default.ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# ── Security Groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "wanderlog-alb-sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from anywhere"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "wanderlog-alb-sg"
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "wanderlog-ecs-tasks-sg"
  description = "Allow traffic from ALB to ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow traffic from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (for Anthropic API, pip installs, etc.)"
  }

  tags = {
    Name = "wanderlog-ecs-tasks-sg"
  }
}

resource "aws_security_group" "efs" {
  name        = "wanderlog-efs-sg"
  description = "Allow NFS from ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
    description     = "Allow NFS from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wanderlog-efs-sg"
  }
}

# ── IAM Roles ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name = "wanderlog-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "wanderlog-ecs-task-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow reading secrets from Secrets Manager
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name = "wanderlog-secrets-access"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [
        aws_secretsmanager_secret.secret_key.arn,
        aws_secretsmanager_secret.anthropic_api_key.arn
      ]
    }]
  })
}

# ── Secrets Manager ───────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "secret_key" {
  name                    = "wanderlog/SECRET_KEY"
  description             = "Flask secret key"
  recovery_window_in_days = 0

  tags = {
    Name = "wanderlog-secret-key"
  }
}

resource "aws_secretsmanager_secret_version" "secret_key" {
  secret_id     = aws_secretsmanager_secret.secret_key.id
  secret_string = var.secret_key
}

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "wanderlog/ANTHROPIC_API_KEY"
  description             = "Anthropic API key"
  recovery_window_in_days = 0

  tags = {
    Name = "wanderlog-anthropic-key"
  }
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key" {
  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = var.anthropic_api_key
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "wanderlog" {
  name               = "wanderlog-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "wanderlog-alb"
  }
}

resource "aws_lb_target_group" "wanderlog" {
  name        = "wanderlog-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "wanderlog-tg"
  }
}

resource "aws_lb_listener" "wanderlog" {
  load_balancer_arn = aws_lb.wanderlog.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wanderlog.arn
  }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "wanderlog" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "wanderlog-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "wanderlog" {
  cluster_name = aws_ecs_cluster.wanderlog.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── ECS Task Definition ───────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "wanderlog" {
  family                   = "wanderlog"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "wanderlog"
    image     = "${aws_ecr_repository.wanderlog.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]

    environment = [
      { name = "GUNICORN_BIND", value = "0.0.0.0:8000" },
      { name = "FLASK_ENV", value = "production" },
      { name = "DATABASE_PATH", value = "/app/data-db/travel_blog.db" }
    ]

    secrets = [
      {
        name      = "SECRET_KEY"
        valueFrom = aws_secretsmanager_secret.secret_key.arn
      },
      {
        name      = "ANTHROPIC_API_KEY"
        valueFrom = aws_secretsmanager_secret.anthropic_api_key.arn
      }
    ]

    mountPoints = [
      {
        sourceVolume  = "wanderlog-db"
        containerPath = "/app/data-db"
        readOnly      = false
      },
      {
        sourceVolume  = "wanderlog-uploads"
        containerPath = "/app/static/uploads"
        readOnly      = false
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/wanderlog"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
        "awslogs-create-group"  = "true"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/ || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 60
    }
  }])

  volume {
    name = "wanderlog-db"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.wanderlog.id
      root_directory     = "/db"
      transit_encryption = "ENABLED"
    }
  }

  volume {
    name = "wanderlog-uploads"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.wanderlog.id
      root_directory     = "/uploads"
      transit_encryption = "ENABLED"
    }
  }

  tags = {
    Name = "wanderlog-task"
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "wanderlog" {
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.wanderlog.id
  task_definition = aws_ecs_task_definition.wanderlog.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.wanderlog.arn
    container_name   = "wanderlog"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.wanderlog,
    aws_iam_role_policy_attachment.ecs_task_execution
  ]

  tags = {
    Name = "wanderlog-service"
  }
}
