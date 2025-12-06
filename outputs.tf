# ==========================================
# Network Outputs
# ==========================================
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

output "private_app_subnet_id" {
  description = "Private App Subnet ID (Controller Layer)"
  value       = aws_subnet.private_app.id
}

output "private_data_subnet_id" {
  description = "Private Data Subnet ID (Worker Layer)"
  value       = aws_subnet.private_data.id
}

# ==========================================
# ALB Outputs
# ==========================================
output "alb_dns_name" {
  description = "ALB DNS Name (Entry Point)"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

# ==========================================
# Controller Outputs (Multi-AZ)
# ==========================================
output "controller_1_private_ip" {
  description = "Controller #1 EC2 Private IP (AZ-a)"
  value       = aws_instance.controller.private_ip
}

output "controller_1_instance_id" {
  description = "Controller #1 EC2 Instance ID"
  value       = aws_instance.controller.id
}

output "controller_2_private_ip" {
  description = "Controller #2 EC2 Private IP (AZ-c)"
  value       = aws_instance.controller_2.private_ip
}

output "controller_2_instance_id" {
  description = "Controller #2 EC2 Instance ID"
  value       = aws_instance.controller_2.id
}

# ==========================================
# AI Node Outputs (현재 stopped - 수동 관리)
# ==========================================
# AI Node는 Terraform에서 제외됨 (stopped 상태 유지)
# output "ai_node_private_ip" {
#   description = "AI Node Private IP"
#   value       = "10.0.20.100"
# }

output "ai_node_endpoint" {
  description = "AI Node Endpoint URL (수동 관리)"
  value       = "http://10.0.20.100:11434"
}

# ==========================================
# Storage Outputs
# ==========================================
output "s3_code_bucket" {
  description = "S3 Code Bucket Name"
  value       = data.aws_s3_bucket.code_bucket.bucket
}

output "s3_user_data_bucket" {
  description = "S3 User Data Bucket Name (Output Binding)"
  value       = aws_s3_bucket.user_data_bucket.bucket
}

output "sqs_queue_url" {
  description = "SQS Queue URL"
  value       = data.aws_sqs_queue.job_queue.url
}

output "dynamodb_table_name" {
  description = "DynamoDB Table Name"
  value       = aws_dynamodb_table.meta_table.name
}

output "redis_endpoint" {
  description = "Redis Endpoint"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

# ==========================================
# Security Group Outputs
# ==========================================
output "alb_security_group_id" {
  description = "ALB Security Group ID"
  value       = aws_security_group.alb_sg.id
}

output "controller_security_group_id" {
  description = "Controller Security Group ID"
  value       = aws_security_group.controller_sg.id
}

output "worker_security_group_id" {
  description = "Worker Security Group ID"
  value       = aws_security_group.worker_sg.id
}

output "ai_security_group_id" {
  description = "AI Node Security Group ID"
  value       = aws_security_group.ai_sg.id
}

output "redis_security_group_id" {
  description = "Redis Security Group ID"
  value       = aws_security_group.redis_sg.id
}
