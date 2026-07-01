variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]{1}$", var.aws_region))
    error_message = "AWS region must be a valid region format (e.g., eu-central-1)."
  }
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "microservices-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.cluster_name)) && length(var.cluster_name) >= 3 && length(var.cluster_name) <= 100
    error_message = "Cluster name must be 3-100 characters, start and end with alphanumeric, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the EKS cluster API endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to access the public EKS API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.31"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "Cluster version must be a valid Kubernetes version (e.g., 1.31)."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Environment must be one of: development, staging, production."
  }
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes. Use m7i-flex.large or larger for production."
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.[a-z0-9-]+$", var.node_instance_type))
    error_message = "Node instance type must be a valid EC2 instance type (e.g., t3.medium, m7i-flex.large)."
  }
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size <= 100
    error_message = "Desired node size must be between 1 and 100."
  }
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1 && var.node_min_size <= 100
    error_message = "Minimum node size must be between 1 and 100."
  }
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.node_max_size >= 1 && var.node_max_size <= 100
    error_message = "Maximum node size must be between 1 and 100."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "Log retention days must be a valid CloudWatch value (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653)."
  }
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project      = "Microservices"
    ManagedBy    = "Terraform"
    Owner        = "Mohamed Fayad"
    CostCenter   = "Engineering"
    BillingAlarm = "true"
  }
}
