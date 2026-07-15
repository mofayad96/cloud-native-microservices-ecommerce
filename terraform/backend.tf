terraform {
   backend "s3" {
     bucket         = "google-microservices-terraform-state"
     key            = "microservices/terraform.tfstate"
     region         = "eu-central-1"
     encrypt        = true
     dynamodb_table = "terraform-state-lock"
   }
 }

