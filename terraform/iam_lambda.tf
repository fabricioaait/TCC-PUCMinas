# =============================================================================
# IAM: Roles e Policies para as Lambdas de Incident Response
# =============================================================================

# -- Role generica assumida por todas as Lambdas --------------------------
resource "aws_iam_role" "lambda_ir" {
  name = "${var.project_name}-lambda-ir-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

# -- CloudWatch Logs (todas as lambdas precisam) ---------------------------
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_ir.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# -- Policy customizada: SSM + EC2 + S3 + EBS -----------------------------
resource "aws_iam_role_policy" "lambda_ir_policy" {
  name = "${var.project_name}-lambda-ir-policy"
  role = aws_iam_role.lambda_ir.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2StopAndSnapshot"
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:CreateSnapshot",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3PutEvidence"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.forensics.arn,
          "${aws_s3_bucket.forensics.arn}/*"
        ]
      }
    ]
  })
}

# -- Adicionar permissao de S3 PutObject na role da EC2 (para upload do dump) --
resource "aws_iam_role_policy" "ec2_s3_upload" {
  name = "${var.project_name}-ec2-s3-upload"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3UploadForensics"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging"
        ]
        Resource = "${aws_s3_bucket.forensics.arn}/*"
      }
    ]
  })
}
