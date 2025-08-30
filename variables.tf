# variables.tf - Terraform Variables Definition

#===========================================
# AWS Configuration
#===========================================

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-northeast-2"
  
  validation {
    condition = can(regex("^[a-z0-9-]+$", var.aws_region))
    error_message = "AWS region must be a valid region name."
  }
}

#===========================================
# Cluster Configuration
#===========================================

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "test-cluster"
  
  validation {
    condition     = length(var.cluster_name) > 0 && length(var.cluster_name) <= 20
    error_message = "Cluster name must be between 1 and 20 characters."
  }
}

#===========================================
# Network Configuration
#===========================================

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.250.0.0/16"
  
  validation {
    condition = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.250.1.0/24", "10.250.2.0/24"]
  
  validation {
    condition = length(var.public_subnet_cidrs) >= 1 && length(var.public_subnet_cidrs) <= 3
    error_message = "Must provide between 1 and 3 public subnet CIDRs."
  }
}

#===========================================
# EC2 Instance Configuration
#===========================================

variable "master_instance_type" {
  description = "EC2 instance type for Kubernetes master node"
  type        = string
  default     = "t3.medium"
  
  validation {
    condition = can(regex("^(t3|t2|m5|m4|c5|c4)\\.[a-z]+$", var.master_instance_type))
    error_message = "Master instance type must be a valid EC2 instance type (e.g., t3.medium, m5.large)."
  }
}

variable "worker_instance_type" {
  description = "EC2 instance type for Kubernetes worker nodes"
  type        = string
  default     = "t3.small"
  
  validation {
    condition = can(regex("^(t3|t2|m5|m4|c5|c4)\\.[a-z]+$", var.worker_instance_type))
    error_message = "Worker instance type must be a valid EC2 instance type (e.g., t3.small, t3.medium)."
  }
}

variable "worker_count" {
  description = "Number of Kubernetes worker nodes"
  type        = number
  default     = 3
  
  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "Worker count must be between 1 and 10."
  }
}

variable "disk_size" {
  description = "EBS root volume size in GB"
  type        = number
  default     = 50
  
  validation {
    condition     = var.disk_size >= 20 && var.disk_size <= 500
    error_message = "Disk size must be between 20 and 500 GB."
  }
}

#===========================================
# Optional Tags
#===========================================

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

#===========================================
# Script Configuration
#===========================================

variable "timezone" {
  description = "Timezone for EC2 instances"
  type        = string
  default     = "Asia/Seoul"
  
  validation {
    condition = can(regex("^[A-Za-z_]+/[A-Za-z_]+$", var.timezone))
    error_message = "Timezone must be in format 'Region/City' (e.g., Asia/Seoul, America/New_York)."
  }
}