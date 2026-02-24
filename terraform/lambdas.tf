# =============================================================================
# Lambdas de Incident Response - Resposta automatizada a incidentes EC2
# =============================================================================
#
# Fluxo de resposta:
#   1. capture_memory  -> insmod LiME, captura RAM e envia para S3
#   2. snapshot_ebs    -> cria snapshot de todos os volumes EBS
#   3. collect_metadata -> coleta metadados da instancia (tags, SGs, rede, SO)
#   4. stop_instance   -> para a instancia comprometida (containment)
#
# Referencia: https://systemweakness.com/aws-automated-ec2-security-incident-response
# =============================================================================

data "aws_region" "current" {}

# -- Empacotamento dos arquivos Python como ZIP (inline via archive_file) ------

data "archive_file" "capture_memory" {
  type        = "zip"
  source_file = "${path.module}/lambdas/capture_memory.py"
  output_path = "${path.module}/lambdas/.zip/capture_memory.zip"
}

data "archive_file" "snapshot_ebs" {
  type        = "zip"
  source_file = "${path.module}/lambdas/snapshot_ebs.py"
  output_path = "${path.module}/lambdas/.zip/snapshot_ebs.zip"
}

data "archive_file" "collect_metadata" {
  type        = "zip"
  source_file = "${path.module}/lambdas/collect_metadata.py"
  output_path = "${path.module}/lambdas/.zip/collect_metadata.zip"
}

data "archive_file" "stop_instance" {
  type        = "zip"
  source_file = "${path.module}/lambdas/stop_instance.py"
  output_path = "${path.module}/lambdas/.zip/stop_instance.zip"
}

# =============================================================================
# Lambda 1: Captura de Memoria RAM via LiME
# =============================================================================
resource "aws_lambda_function" "capture_memory" {
  function_name    = "${var.project_name}-capture-memory"
  description      = "Captura de memoria RAM via LiME (insmod) e upload para S3"
  role             = aws_iam_role.lambda_ir.arn
  handler          = "capture_memory.lambda_handler"
  runtime          = "python3.13"
  timeout          = 900
  memory_size      = 256
  filename         = data.archive_file.capture_memory.output_path
  source_code_hash = data.archive_file.capture_memory.output_base64sha256

  environment {
    variables = {
      FORENSICS_BUCKET = aws_s3_bucket.forensics.id
      COMMAND_TIMEOUT  = "600"
      AWS_REGION_NAME  = data.aws_region.current.name
    }
  }

  tags = merge(local.common_tags, { Function = "capture-memory" })
}

# =============================================================================
# Lambda 2: Snapshot dos volumes EBS
# =============================================================================
resource "aws_lambda_function" "snapshot_ebs" {
  function_name    = "${var.project_name}-snapshot-ebs"
  description      = "Cria snapshots de todos os volumes EBS da instancia comprometida"
  role             = aws_iam_role.lambda_ir.arn
  handler          = "snapshot_ebs.lambda_handler"
  runtime          = "python3.13"
  timeout          = 300
  memory_size      = 128
  filename         = data.archive_file.snapshot_ebs.output_path
  source_code_hash = data.archive_file.snapshot_ebs.output_base64sha256

  environment {
    variables = {
      FORENSICS_BUCKET = aws_s3_bucket.forensics.id
    }
  }

  tags = merge(local.common_tags, { Function = "snapshot-ebs" })
}

# =============================================================================
# Lambda 3: Coleta de Metadados da Instancia
# =============================================================================
resource "aws_lambda_function" "collect_metadata" {
  function_name    = "${var.project_name}-collect-metadata"
  description      = "Coleta metadados completos da instancia EC2 (tags, SGs, rede, SO)"
  role             = aws_iam_role.lambda_ir.arn
  handler          = "collect_metadata.lambda_handler"
  runtime          = "python3.13"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.collect_metadata.output_path
  source_code_hash = data.archive_file.collect_metadata.output_base64sha256

  environment {
    variables = {
      FORENSICS_BUCKET = aws_s3_bucket.forensics.id
    }
  }

  tags = merge(local.common_tags, { Function = "collect-metadata" })
}

# =============================================================================
# Lambda 4: Parar Instancia (Containment)
# =============================================================================
resource "aws_lambda_function" "stop_instance" {
  function_name    = "${var.project_name}-stop-instance"
  description      = "Para a instancia EC2 comprometida apos coleta de evidencias"
  role             = aws_iam_role.lambda_ir.arn
  handler          = "stop_instance.lambda_handler"
  runtime          = "python3.13"
  timeout          = 300
  memory_size      = 128
  filename         = data.archive_file.stop_instance.output_path
  source_code_hash = data.archive_file.stop_instance.output_base64sha256

  environment {
    variables = {
      FORENSICS_BUCKET = aws_s3_bucket.forensics.id
    }
  }

  tags = merge(local.common_tags, { Function = "stop-instance" })
}

# =============================================================================
# CloudWatch Log Groups (retencao de 30 dias)
# =============================================================================
resource "aws_cloudwatch_log_group" "capture_memory" {
  name              = "/aws/lambda/${aws_lambda_function.capture_memory.function_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "snapshot_ebs" {
  name              = "/aws/lambda/${aws_lambda_function.snapshot_ebs.function_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "collect_metadata" {
  name              = "/aws/lambda/${aws_lambda_function.collect_metadata.function_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "stop_instance" {
  name              = "/aws/lambda/${aws_lambda_function.stop_instance.function_name}"
  retention_in_days = 30
  tags              = local.common_tags
}
