//this file defines the EKS cluster and its managed node groups using the terraform-aws-modules/eks/aws module.
// It configures the cluster with public and private endpoint access, security group rules for worker nodes, and enables logging. The node groups are set up with specified instance types and scaling parameters, and additional IAM policies for pulling images from ECR.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                               = module.vpc.vpc_id
  subnet_ids                           = module.vpc.private_subnets
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"] # Restrict this in production


  manage_aws_auth_configmap = false


  create_cloudwatch_log_group = true

  # Cluster secret encryption
  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  # Managed node group defaults
  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    instance_types = [var.node_instance_type]
    disk_size      = 50
    capacity_type  = "ON_DEMAND"
  }

  # Node security group rules
  node_security_group_additional_rules = {
    ingress_cluster_all = {
      description                   = "Allow all control plane traffic to worker nodes"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_all = {
      description = "Allow all outbound traffic from node"
      protocol    = "-1"
      from_port   = 0
      to_port     = 65535
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ingress_self_all = {
      description = "Allow nodes to talk to each other"
      protocol    = "-1"
      from_port   = 0
      to_port     = 65535
      type        = "ingress"
      self        = true
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
