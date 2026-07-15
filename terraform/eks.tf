//this file defines the EKS cluster and its managed node groups using the terraform-aws-modules/eks/aws module.
// It configures the cluster with public and private endpoint access, security group rules for worker nodes, and enables logging. The node groups are set up with specified instance types and scaling parameters, and additional IAM policies for pulling images from ECR.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                               = module.vpc.vpc_id
  subnet_ids                           = module.vpc.private_subnets
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Enable EKS Access Entry API for direct IAM administration (replaces aws-auth)
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  create_cloudwatch_log_group = true

  # Cluster secret encryption
  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  # Managed node group defaults
  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = [var.node_instance_type]
    capacity_type  = "ON_DEMAND"
    
    # Configure GP3 root volume via block device mappings
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 50
          volume_type           = "gp3"
          delete_on_termination = true
        }
      }
    }
  }

  # EKS managed node groups
  eks_managed_node_groups = {
    default = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = module.vpc.private_subnets

      labels = {
        workload = "microservices"
      }

      iam_role_additional_policies = {
        ecr_pull = aws_iam_policy.ecr_pull_policy.arn
      }

      tags = merge(
        local.common_tags,
        {
          Name = "${var.cluster_name}-managed-ng"
        }
      )
    }
  }
  cluster_addons = {} # Addons managed separately in eks-addons.tf

  cluster_enabled_log_types = local.eks_log_types

  tags = merge(
    local.common_tags,
    {
      Name = var.cluster_name
    }
  )
}
