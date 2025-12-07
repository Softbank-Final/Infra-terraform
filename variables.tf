variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_app_subnet_cidr" {
  description = "Private App subnet CIDR block (Controller Layer)"
  type        = string
  default     = "10.0.10.0/24"
}

variable "private_data_subnet_cidr" {
  description = "Private Data subnet CIDR block (Worker Layer)"
  type        = string
  default     = "10.0.20.0/24"
}

variable "availability_zone" {
  description = "Availability Zone"
  type        = string
  default     = "ap-northeast-2a"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (Ubuntu 22.04 LTS)"
  type        = string
  default     = "ami-0c9c942bd7bf113a2"
}

# Controller EC2
variable "controller_instance_type" {
  description = "EC2 instance type for Controller (Node.js)"
  type        = string
  default     = "t3.micro"
}

# AI Node EC2
variable "ai_instance_type" {
  description = "EC2 instance type for AI Node (min 4GB RAM)"
  type        = string
  default     = "t3.large"
}

# Worker EC2
variable "worker_instance_type" {
  description = "EC2 instance type for Workers (On-Demand)"
  type        = string
  default     = "t3.small"
}

# Auto Scaling
variable "asg_desired_capacity" {
  description = "Desired number of Worker EC2 instances"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of Worker EC2 instances"
  type        = number
  default     = 5
}

variable "asg_min_size" {
  description = "Minimum number of Worker EC2 instances"
  type        = number
  default     = 2
}

# Redis
variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}
