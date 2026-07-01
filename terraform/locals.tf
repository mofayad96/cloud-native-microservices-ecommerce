locals {
  name_prefix = "${var.cluster_name}-${var.environment}"

  iam_name_prefix = var.cluster_name

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Cluster     = var.cluster_name
      ManagedBy   = "Terraform"
    }
  )

  eks_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
}
