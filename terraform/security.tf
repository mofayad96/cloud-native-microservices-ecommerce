# KMS key for EKS cluster secret encryption
resource "aws_kms_key" "eks" {
  description             = "EKS cluster secret encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-encryption"
  target_key_id = aws_kms_key.eks.key_id
}


