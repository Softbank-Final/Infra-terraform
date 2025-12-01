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
  tags = { Name = "nanogrid-vpc" }
}

# Public Subnet (NAT GW, ALB용)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags = { Name = "nanogrid-public-subnet" }
}

# Private Subnet - App (Lambda, API용)
resource "aws_subnet" "private_app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidr
  availability_zone = var.availability_zone
  tags = { Name = "nanogrid-private-app-subnet" }
}

# Private Subnet - Worker/Data (EC2 Worker, Redis, DB용)
resource "aws_subnet" "private_data" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_data_subnet_cidr
  availability_zone = var.availability_zone
  tags = { Name = "nanogrid-private-data-subnet" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# NAT Gateway (Elastic IP 필요)
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = { Name = "nanogrid-nat-gw" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
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
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  subnet_id      = aws_subnet.private_data.id
  route_table_id = aws_route_table.private.id
}


# VPC Endpoints (S3, DynamoDB 비용 절감용) - 모든 Private 서브넷에 적용
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# ==========================================
# 2. Security Groups
# ==========================================
# Lambda용 SG
resource "aws_security_group" "lambda_sg" {
  name   = "nanogrid-lambda-sg"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
}

# Redis용 SG (Lambda와 Worker에서만 접근 가능)
resource "aws_security_group" "redis_sg" {
  name   = "nanogrid-redis-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id, aws_security_group.worker_sg.id]
  }
}

# ==========================================
# 3. State Resources (SQS, Redis, S3, Dynamo)
# ==========================================
# 현재 AWS 계정 ID 가져오기
data "aws_caller_identity" "current" {}

# SQS (기존 큐 사용)
# visibility_timeout_seconds = 30 -> 추후 조정 예정 11/30 회의 중 
data "aws_sqs_queue" "job_queue" {
  name = "nanogrid-task-queue"
  
}

# Redis (ElastiCache) - Data 서브넷에 배치
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
}

# S3 Bucket (기존 버킷 사용)
data "aws_s3_bucket" "code_bucket" {
  bucket = "nanogrid-code-bucket"
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
}


# ==========================================
# 4. Compute (IAM & Launch Template)
# ==========================================
# EC2가 S3, SQS에 접근할 권한 (IAM Role)
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

# 권한 붙이기 (S3 Read, SQS Full, DynamoDB Read, CloudWatch)
resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "sqs_full" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_iam_role_policy_attachment" "dynamodb_read" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "nanogrid_worker_profile"
  role = aws_iam_role.worker_role.name
}

# Launch Template (User Data로 Docker 설치 자동화)
resource "aws_launch_template" "worker_template" {
  name_prefix   = "nanogrid-worker-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.worker_profile.name
  }

  vpc_security_group_ids = [aws_security_group.worker_sg.id]

  user_data = base64encode(<<-EOF
#!/bin/bash
apt-get update
apt-get install -y docker.io python3-pip
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu
pip3 install boto3 redis docker requests
# 여기서 Git Clone 후 Agent 실행
# git clone https://github.com/your-repo/nanogrid.git
# python3 nanogrid/agent.py &
EOF
  )
}

# Auto Scaling Group - Data 서브넷에 배치
resource "aws_autoscaling_group" "worker_asg" {
  name                = "nanogrid-worker-asg"
  desired_capacity    = var.asg_desired_capacity
  max_size            = var.asg_max_size
  min_size            = var.asg_min_size
  vpc_zone_identifier = [aws_subnet.private_data.id]

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
# 5. SQS 기반 Auto Scaling 정책
# ==========================================
# Scale Out 정책 (SQS 메시지 많으면 EC2 추가)
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "nanogrid-scale-out"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.worker_asg.name
}

# Scale In 정책 (SQS 메시지 없으면 EC2 감소)
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "nanogrid-scale-in"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.worker_asg.name
}

# CloudWatch Alarm - SQS 메시지 10개 이상이면 Scale Out
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

# CloudWatch Alarm - SQS 메시지 0개면 Scale In
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



# ==========================================
# 6. Lambda IAM Role & Policies
# ==========================================
# Lambda 실행 역할
resource "aws_iam_role" "lambda_role" {
  name = "nanogrid_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Lambda 기본 실행 권한 (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda VPC 접근 권한
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda용 커스텀 정책 (S3, DynamoDB, SQS 접근)
resource "aws_iam_role_policy" "lambda_custom" {
  name = "nanogrid_lambda_policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${data.aws_s3_bucket.code_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.meta_table.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = data.aws_sqs_queue.job_queue.arn
      }
    ]
  })
}

# ==========================================
# 7. Lambda Functions (Placeholder)
# ==========================================
# Lambda 코드 placeholder (실제 코드는 별도 배포)
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_placeholder.zip"
  source {
    content  = "def handler(event, context): return {'statusCode': 200, 'body': 'placeholder'}"
    filename = "index.py"
  }
}

# Resource Manager Lambda (코드 저장 담당)
resource "aws_lambda_function" "resource_manager" {
  function_name = "nanogrid-resource-manager"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_app.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      S3_BUCKET      = data.aws_s3_bucket.code_bucket.bucket
      DYNAMODB_TABLE = aws_dynamodb_table.meta_table.name
    }
  }
}

# Dispatcher Lambda (실행 요청 처리)
resource "aws_lambda_function" "dispatcher" {
  function_name = "nanogrid-dispatcher"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_app.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      S3_BUCKET      = data.aws_s3_bucket.code_bucket.bucket
      DYNAMODB_TABLE = aws_dynamodb_table.meta_table.name
      SQS_QUEUE_URL  = data.aws_sqs_queue.job_queue.url
      REDIS_HOST     = aws_elasticache_cluster.redis.cache_nodes[0].address
      REDIS_PORT     = "6379"
    }
  }
}


# ==========================================
# 8. API Gateway (HTTP API)
# ==========================================
resource "aws_apigatewayv2_api" "main" {
  name          = "nanogrid-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["*"]
  }
}

# API Gateway Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/nanogrid-api"
  retention_in_days = 7
}

# ==========================================
# 9. API Gateway -> Lambda Integrations
# ==========================================
# Resource Manager Integration
resource "aws_apigatewayv2_integration" "resource_manager" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.resource_manager.invoke_arn
  payload_format_version = "2.0"
}

# Dispatcher Integration
resource "aws_apigatewayv2_integration" "dispatcher" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dispatcher.invoke_arn
  payload_format_version = "2.0"
}

# ==========================================
# 10. API Routes
# ==========================================
# POST /functions - 함수 등록 (코드 업로드)
resource "aws_apigatewayv2_route" "create_function" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /functions"
  target    = "integrations/${aws_apigatewayv2_integration.resource_manager.id}"
}

# GET /functions/{functionId} - 함수 정보 조회
resource "aws_apigatewayv2_route" "get_function" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /functions/{functionId}"
  target    = "integrations/${aws_apigatewayv2_integration.resource_manager.id}"
}

# DELETE /functions/{functionId} - 함수 삭제
resource "aws_apigatewayv2_route" "delete_function" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "DELETE /functions/{functionId}"
  target    = "integrations/${aws_apigatewayv2_integration.resource_manager.id}"
}

# POST /run - 함수 실행
resource "aws_apigatewayv2_route" "run_function" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /run"
  target    = "integrations/${aws_apigatewayv2_integration.dispatcher.id}"
}

# ==========================================
# 11. Lambda Permissions for API Gateway
# ==========================================
resource "aws_lambda_permission" "resource_manager_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.resource_manager.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "dispatcher_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
