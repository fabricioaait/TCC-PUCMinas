output "instance_id" {
  description = "ID da instancia EC2"
  value       = aws_instance.lime.id
}

output "instance_public_ip" {
  description = "IP publico da instancia EC2"
  value       = aws_instance.lime.public_ip
}

output "ami_used" {
  description = "ID da AMI Amazon Linux 2023 utilizada"
  value       = data.aws_ami.amazon_linux_2023.id
}

output "private_key_path" {
  description = "Caminho local da chave SSH privada gerada pelo Terraform"
  value       = local_sensitive_file.private_key.filename
  sensitive   = true
}

output "ssh_command" {
  description = "Comando para conectar na instancia via SSH"
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.lime.public_ip}"
}

output "ssm_command" {
  description = "Comando para conectar na instancia via SSM Session Manager (sem abrir porta 22)"
  value       = "aws ssm start-session --target ${aws_instance.lime.id} --region ${var.aws_region}"
}

output "lime_capture_command" {
  description = "Comando para iniciar captura de memoria via LiME (executar na instancia)"
  value       = "sudo lime-capture /var/tmp/dump-$(date +%Y%m%d-%H%M%S).lime"
}

# =============================================================================
# Outputs - Incident Response (Lambdas + S3)
# =============================================================================

output "forensics_bucket" {
  description = "Nome do bucket S3 de evidencias forenses"
  value       = aws_s3_bucket.forensics.id
}

output "lambda_capture_memory_arn" {
  description = "ARN da Lambda de captura de memoria RAM"
  value       = aws_lambda_function.capture_memory.arn
}

output "lambda_snapshot_ebs_arn" {
  description = "ARN da Lambda de snapshot EBS"
  value       = aws_lambda_function.snapshot_ebs.arn
}

output "lambda_collect_metadata_arn" {
  description = "ARN da Lambda de coleta de metadados"
  value       = aws_lambda_function.collect_metadata.arn
}

output "lambda_stop_instance_arn" {
  description = "ARN da Lambda de parada da instancia"
  value       = aws_lambda_function.stop_instance.arn
}

output "invoke_full_ir_flow" {
  description = "Comandos para invocar o fluxo completo de IR na instancia"
  value       = <<-EOT
    # 1. Captura de memoria RAM
    aws lambda invoke --function-name ${aws_lambda_function.capture_memory.function_name} --payload '{"instance_id": "${aws_instance.lime.id}", "case_id": "case-001"}' --cli-binary-format raw-in-base64-out /tmp/result-memory.json

    # 2. Snapshot dos volumes EBS
    aws lambda invoke --function-name ${aws_lambda_function.snapshot_ebs.function_name} --payload '{"instance_id": "${aws_instance.lime.id}", "case_id": "case-001"}' --cli-binary-format raw-in-base64-out /tmp/result-ebs.json

    # 3. Coleta de metadados
    aws lambda invoke --function-name ${aws_lambda_function.collect_metadata.function_name} --payload '{"instance_id": "${aws_instance.lime.id}", "case_id": "case-001"}' --cli-binary-format raw-in-base64-out /tmp/result-metadata.json

    # 4. Parar instancia (containment)
    aws lambda invoke --function-name ${aws_lambda_function.stop_instance.function_name} --payload '{"instance_id": "${aws_instance.lime.id}", "case_id": "case-001"}' --cli-binary-format raw-in-base64-out /tmp/result-stop.json
  EOT
}
