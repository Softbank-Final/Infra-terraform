provider "aws" {
  region = var.aws_region
}

# ==========================================
# 1. Network (VPC & Subnets)
# ==========================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "nanogrid-vpc" }
}

# Public Subnet (NAT GW, ALB용) - AZ a
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "nanogrid-public-subnet" }
}

# Public Subnet 2 (ALB용) - AZ c
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "nanogrid-public-subnet-2" }
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Private Subnet - App (Controller EC2용)
resource "aws_subnet" "private_app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "nanogrid-private-app-subnet" }
}

# Private Subnet - Worker/Data (EC2 Worker, Redis, AI Node용) - AZ-a
resource "aws_subnet" "private_data" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_data_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "nanogrid-private-data-subnet" }
}

# Private Subnet - Worker/Data 2 (Multi-AZ용) - AZ-c
resource "aws_subnet" "private_data_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "nanogrid-private-data-subnet-2" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "nanogrid-igw" }
}

# NAT Gateway (Elastic IP 필요)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "nanogrid-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "nanogrid-nat-gw" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "nanogrid-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "nanogrid-private-rt" }
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  subnet_id      = aws_subnet.private_data.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data_2" {
  subnet_id      = aws_subnet.private_data_2.id
  route_table_id = aws_route_table.private.id
}

# VPC Endpoints (S3, DynamoDB 비용 절감용)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "nanogrid-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "nanogrid-dynamodb-endpoint" }
}

# ==========================================
# 2. Security Groups
# ==========================================
# ALB용 SG
resource "aws_security_group" "alb_sg" {
  name   = "nanogrid-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nanogrid-alb-sg" }
}

# Controller EC2용 SG
resource "aws_security_group" "controller_sg" {
  name        = "nanogrid-controller-sg"
  description = "nanogrid-controller-sg"
  vpc_id      = aws_vpc.main.id

  # SSH 접근
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ALB에서 8080 포트 접근 허용 (Express.js) -> 수동
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = { Name = "nanogrid-controller-sg" }
}

# EC2 Worker용 SG
resource "aws_security_group" "worker_sg" {
  name   = "nanogrid-worker-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nanogrid-worker-sg" }
}

# AI Node용 SG (Worker에서만 11434 접근 허용)
resource "aws_security_group" "ai_sg" {
  name   = "nanogrid-ai-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 11434
    to_port         = 11434
    protocol        = "tcp"
    security_groups = [aws_security_group.worker_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nanogrid-ai-sg" }
}

# Redis용 SG (Controller와 Worker에서만 접근 가능)
resource "aws_security_group" "redis_sg" {
  name   = "nanogrid-redis-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.controller_sg.id, aws_security_group.worker_sg.id]
  }

  tags = { Name = "nanogrid-redis-sg" }
}

# ==========================================
# 3. ALB (Application Load Balancer)
# ==========================================
resource "aws_lb" "main" {
  name               = "nanogrid-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_2.id]

  tags = { Name = "nanogrid-alb" }
}

resource "aws_lb_target_group" "controller" {
  name     = "nanogrid-controller-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "8080"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  lifecycle {
    ignore_changes = all
  }

  tags = { Name = "nanogrid-controller-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.controller.arn
  }
}

# ==========================================
# 4. State Resources (SQS, Redis, S3, DynamoDB)
# ==========================================
data "aws_caller_identity" "current" {}

# SQS (기존 큐 사용)
data "aws_sqs_queue" "job_queue" {
  name = "nanogrid-task-queue"
}

# Redis (ElastiCache)
resource "aws_elasticache_subnet_group" "redis_subnet" {
  name       = "nanogrid-redis-subnet"
  subnet_ids = [aws_subnet.private_data.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "nanogrid-redis"
  engine               = "redis"
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet.name
  security_group_ids   = [aws_security_group.redis_sg.id]
  tags                 = { Name = "nanogrid-redis" }
}

# S3 Bucket (기존 버킷 사용)
data "aws_s3_bucket" "code_bucket" {
  bucket = "nanogrid-code-bucket"
}

# S3 Bucket (결과물 저장용 - 신규)
resource "aws_s3_bucket" "user_data_bucket" {
  bucket = "nanogrid-user-data-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "nanogrid-user-data" }
}

resource "aws_s3_bucket_versioning" "user_data_versioning" {
  bucket = aws_s3_bucket.user_data_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# DynamoDB
resource "aws_dynamodb_table" "meta_table" {
  name         = "NanoGridFunctions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "functionId"

  attribute {
    name = "functionId"
    type = "S"
  }

  tags = { Name = "nanogrid-functions-table" }
}

# ==========================================
# 5. IAM Roles
# ==========================================
# Controller EC2 IAM Role
resource "aws_iam_role" "controller_role" {
  name = "nanogrid_controller_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  lifecycle {
    ignore_changes = [managed_policy_arns, inline_policy]
  }
}

resource "aws_iam_role_policy" "controller_policy" {
  name = "nanogrid_controller_policy"
  role = aws_iam_role.controller_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${data.aws_s3_bucket.code_bucket.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.meta_table.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = data.aws_sqs_queue.job_queue.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "controller_profile" {
  name = "nanogrid_controller_profile"
  role = aws_iam_role.controller_role.name
}

# Worker EC2 IAM Role
resource "aws_iam_role" "worker_role" {
  name = "nanogrid_worker_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "nanogrid_worker_policy"
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.code_bucket.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.user_data_bucket.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = data.aws_sqs_queue.job_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.meta_table.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_cloudwatch" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "nanogrid_worker_profile"
  role = aws_iam_role.worker_role.name
}

# ==========================================
# 6. Controller EC2
# ==========================================
# Controller #1 (AZ-a, Public Subnet 1)
resource "aws_instance" "controller" {
  ami                    = "ami-04fcc2023d6e37430"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.controller_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.controller_profile.name
  key_name               = "key"

  lifecycle {
    ignore_changes = [ami, instance_type, subnet_id, user_data, key_name]
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
set -e
apt-get update
apt-get install -y nodejs npm
npm install -g pm2

# 환경 변수 설정
cat >> /etc/environment << 'ENVEOF'
S3_BUCKET=${data.aws_s3_bucket.code_bucket.bucket}
DYNAMODB_TABLE=${aws_dynamodb_table.meta_table.name}
SQS_QUEUE_URL=${data.aws_sqs_queue.job_queue.url}
REDIS_HOST=${aws_elasticache_cluster.redis.cache_nodes[0].address}
REDIS_PORT=6379
ENVEOF
EOF
  )

  tags = { Name = "nanogrid-controller-1" }
}

# Controller #2 (AZ-c, Public Subnet 2) - Multi-AZ HA
resource "aws_instance" "controller_2" {
  ami                    = "ami-04fcc2023d6e37430"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public_2.id
  vpc_security_group_ids = [aws_security_group.controller_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.controller_profile.name
  key_name               = "key"

  user_data = base64encode(<<-EOF
#!/bin/bash
set -e
apt-get update
apt-get install -y nodejs npm
npm install -g pm2

# 환경 변수 설정
cat >> /etc/environment << 'ENVEOF'
S3_BUCKET=${data.aws_s3_bucket.code_bucket.bucket}
DYNAMODB_TABLE=${aws_dynamodb_table.meta_table.name}
SQS_QUEUE_URL=${data.aws_sqs_queue.job_queue.url}
REDIS_HOST=${aws_elasticache_cluster.redis.cache_nodes[0].address}
REDIS_PORT=6379
ENVEOF
EOF
  )

  tags = { Name = "nanogrid-controller-2" }
}

# Controller #1을 ALB Target Group에 등록
resource "aws_lb_target_group_attachment" "controller" {
  target_group_arn = aws_lb_target_group.controller.arn
  target_id        = aws_instance.controller.id
  port             = 8080
}

# Controller #2를 ALB Target Group에 등록
resource "aws_lb_target_group_attachment" "controller_2" {
  target_group_arn = aws_lb_target_group.controller.arn
  target_id        = aws_instance.controller_2.id
  port             = 8080
}

# ==========================================
# 7. AI Node EC2 (현재 stopped 상태로 유지 - 비용 절감)
# ==========================================
# AI Node는 수동으로 관리 (필요시 AWS 콘솔에서 시작)
# Terraform에서 제외하여 stopped 상태 유지
# 기존 인스턴스 ID: i-01807910ee985894f (10.0.20.100)

# ==========================================
# 8. Worker EC2 (Auto Scaling Group)
# ==========================================
resource "aws_launch_template" "worker_template" {
  name_prefix   = "nanogrid-worker-"
  image_id      = "ami-04fcc2023d6e37430"  # Amazon Linux 2023
  instance_type = var.worker_instance_type
  key_name      = "key"

  iam_instance_profile {
    name = aws_iam_instance_profile.worker_profile.name
  }

  vpc_security_group_ids = [aws_security_group.worker_sg.id]

  user_data = base64encode(<<-EOF
#!/bin/bash
set -e

# Amazon Linux 2023용 패키지 설치
yum update -y
yum install -y docker python3-pip git
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

pip3 install boto3 redis docker requests

# 환경 변수 설정
cat >> /etc/environment << 'ENVEOF'
S3_CODE_BUCKET=${data.aws_s3_bucket.code_bucket.bucket}
S3_USER_DATA_BUCKET=${aws_s3_bucket.user_data_bucket.bucket}
SQS_QUEUE_URL=${data.aws_sqs_queue.job_queue.url}
REDIS_HOST=${aws_elasticache_cluster.redis.cache_nodes[0].address}
REDIS_PORT=6379
AI_ENDPOINT=http://10.0.20.100:11434
ENVEOF

# Worker Agent 배포
# git clone https://github.com/Softbank-Final/Infra-controller.git /app
# cd /app && python3 agent.py &
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "nanogrid-worker" }
  }
}

resource "aws_autoscaling_group" "worker_asg" {
  name                = "nanogrid-worker-asg"
  desired_capacity    = var.asg_desired_capacity
  max_size            = var.asg_max_size
  min_size            = var.asg_min_size
  vpc_zone_identifier = [aws_subnet.private_data.id, aws_subnet.private_data_2.id]  # Multi-AZ

  launch_template {
    id      = aws_launch_template.worker_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "nanogrid-worker"
    propagate_at_launch = true
  }
}

# ==========================================
# 9. Auto Scaling Policies
# ==========================================
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "nanogrid-scale-out"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.worker_asg.name
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "nanogrid-scale-in"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.worker_asg.name
}

resource "aws_cloudwatch_metric_alarm" "sqs_high" {
  alarm_name          = "nanogrid-sqs-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "Scale out when SQS queue has 10+ messages"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    QueueName = data.aws_sqs_queue.job_queue.name
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_low" {
  alarm_name          = "nanogrid-sqs-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Scale in when SQS queue is empty"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    QueueName = data.aws_sqs_queue.job_queue.name
  }
}
