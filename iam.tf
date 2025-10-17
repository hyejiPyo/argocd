data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "master_role" {
  name               = "ec2-master-upload-kubeconfig-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy" "master_upload_kubeconfig" {
  name = "master-upload-kubeconfig"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["s3:PutObject"],
      Resource = "arn:aws:s3:::${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "master_attach" {
  role       = aws_iam_role.master_role.name
  policy_arn = aws_iam_policy.master_upload_kubeconfig.arn
}

resource "aws_iam_instance_profile" "master_profile" {
  name = "ec2-master-upload-kubeconfig-profile"
  role = aws_iam_role.master_role.name
}

# Argo 서버용 role (S3에서 kubeconfig 읽기 권한)
resource "aws_iam_role" "argo_role" {
  name               = "ec2-argo-read-kubeconfig-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy" "argo_read_kubeconfig" {
  name = "argo-read-kubeconfig"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["s3:GetObject"],
      Resource = "arn:aws:s3:::${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "argo_attach" {
  role       = aws_iam_role.argo_role.name
  policy_arn = aws_iam_policy.argo_read_kubeconfig.arn
}

resource "aws_iam_instance_profile" "argo_profile" {
  name = "ec2-argo-read-kubeconfig-profile"
  role = aws_iam_role.argo_role.name
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_read_role" {
  name               = "ec2-s3-read-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy" "s3_read_policy" {
  name = "ec2-s3-read-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject","s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${var.kubeconfig_s3_bucket}",
          "arn:aws:s3:::${var.kubeconfig_s3_bucket}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_read" {
  role       = aws_iam_role.s3_read_role.name
  policy_arn = aws_iam_policy.s3_read_policy.arn
}

resource "aws_iam_instance_profile" "s3_read_profile" {
  name = "ec2-s3-read-profile"
  role = aws_iam_role.s3_read_role.name
}