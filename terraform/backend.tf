# S3 backend for Terraform state
# Migration steps:
#   1. terraform init                    (starts with local state)
#   2. terraform apply                   (creates S3 bucket + DynamoDB table)
#   3. Uncomment the backend block below
#   4. terraform init -migrate-state     (migrates to S3)
#
# terraform {
#   backend "s3" {
#     bucket         = "google-microservices-terraform-state"
#     key            = "microservices/terraform.tfstate"
#     region         = "eu-central-1"
#     encrypt        = true
#     dynamodb_table = "terraform-state-lock"
#   }
# }
