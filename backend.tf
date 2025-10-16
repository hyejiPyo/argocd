terraform {
  backend "s3" {
    bucket = "phj-devops-cd"
    key    = "aws/devops/terraform.tfstate"
    region = "ap-northeast-2"
  }
} 