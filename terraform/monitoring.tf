# CloudWatch Log Group for Application Logs
resource "aws_cloudwatch_log_group" "application_logs" {
  name              = "/aws/eks/${var.cluster_name}/applications"
  retention_in_days = var.log_retention_days

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name_prefix}-app-logs"
    }
  )
}
