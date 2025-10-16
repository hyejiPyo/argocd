variable "vpc_id" {
  description = "배포할 VPC의 ID"
  type        = string
  default     = "vpc-08289defd1ea10e6f"
}
variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_key_name" {
  description = "AWS EC2 Key Name"
  type        = string
  default = "cppm-test"
}

variable "instance_type" {
  description = "AWS EC2 인스턴스 타입"
  type = string
  default = "t3.medium"
}


variable "subnet_id" {
  description = "AWS Subnet"
  type = string
  default = "subnet-075de9772da50ef19"
}