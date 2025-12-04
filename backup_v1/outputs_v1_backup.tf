output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

output "private_app_subnet_id" {
  description = "Private App Subnet ID"
  value       = aws_subnet.private_app.id
}

output "private_data_subnet_id" {
  description = "Private Data Subnet ID"
  value       = aws_subnet.private_data.id
}

output "s3_bucket_name" {
  description = "S3 Bucket Name"
  value       = data.aws_s3_bucket.code_bucket.bucket
}

output "sqs_queue_url" {
  description = "SQS Queue URL"
  value       = data.aws_sqs_queue.job_queue.url
}

output "sqs_queue_arn" {
  description = "SQS Queue ARN"
  value       = data.aws_sqs_queue.job_queue.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB Table Name"
  value       = aws_dynamodb_table.meta_table.name
}

output "redis_endpoint" {
  description = "Redis Endpoint"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "worker_security_group_id" {
  description = "Worker Security Group ID"
  value       = aws_security_group.worker_sg.id
}

output "lambda_security_group_id" {
  description = "Lambda Security Group ID"
  value       = aws_security_group.lambda_sg.id
}


# ==========================================
# API Gateway Outputs
# ==========================================
output "api_gateway_url" {
  description = "API Gateway URL"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "api_gateway_id" {
  description = "API Gateway ID"
  value       = aws_apigatewayv2_api.main.id
}

# ==========================================
# Lambda Outputs
# ==========================================
output "resource_manager_lambda_arn" {
  description = "Resource Manager Lambda ARN"
  value       = aws_lambda_function.resource_manager.arn
}

output "resource_manager_lambda_name" {
  description = "Resource Manager Lambda Name"
  value       = aws_lambda_function.resource_manager.function_name
}

output "dispatcher_lambda_arn" {
  description = "Dispatcher Lambda ARN"
  value       = aws_lambda_function.dispatcher.arn
}

output "dispatcher_lambda_name" {
  description = "Dispatcher Lambda Name"
  value       = aws_lambda_function.dispatcher.function_name
}

output "lambda_role_arn" {
  description = "Lambda IAM Role ARN"
  value       = aws_iam_role.lambda_role.arn
}
