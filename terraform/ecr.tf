// this file defines data sources to retrieve information about existing ECR repositories and outputs their URIs for use in other parts of the Terraform configuration.
data "aws_ecr_repository" "adservice" {
  name = "adservice"
}

data "aws_ecr_repository" "cartservice" {
  name = "cartservice"
}
data "aws_ecr_repository" "checkoutservice" {
  name = "checkoutservice"
}
data "aws_ecr_repository" "currencyservice" {
  name = "currencyservice"
}
data "aws_ecr_repository" "emailservice" {
  name = "emailservice"
}
data "aws_ecr_repository" "frontend" {
  name = "frontend"
}
data "aws_ecr_repository" "loadgenerator" {
  name = "loadgenerator"
}
data "aws_ecr_repository" "paymentservice" {
  name = "paymentservice"
}
data "aws_ecr_repository" "productcatalogservice" {
  name = "productcatalogservice"
}
data "aws_ecr_repository" "recommendationservice" {
  name = "recommendationservice"
}
data "aws_ecr_repository" "shippingservice" {
  name = "shippingservice"
}


# output the repository URIs 
output "ecr_repo_uris" {
  value = {
    adservice             = data.aws_ecr_repository.adservice.repository_url
    cartservice           = data.aws_ecr_repository.cartservice.repository_url
    checkoutservice       = data.aws_ecr_repository.checkoutservice.repository_url
    currencyservice       = data.aws_ecr_repository.currencyservice.repository_url
    emailservice          = data.aws_ecr_repository.emailservice.repository_url
    frontend              = data.aws_ecr_repository.frontend.repository_url
    loadgenerator         = data.aws_ecr_repository.loadgenerator.repository_url
    paymentservice        = data.aws_ecr_repository.paymentservice.repository_url
    productcatalogservice = data.aws_ecr_repository.productcatalogservice.repository_url
    recommendationservice = data.aws_ecr_repository.recommendationservice.repository_url
    shippingservice       = data.aws_ecr_repository.shippingservice.repository_url
  }
}