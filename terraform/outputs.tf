output "instance_id" {
  description = "ID da instância EC2"
  value       = aws_instance.lime.id
}

output "instance_public_ip" {
  description = "IP público da instância EC2"
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
  description = "Comando para conectar na instância via SSH"
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.lime.public_ip}"
}

output "ssm_command" {
  description = "Comando para conectar na instância via SSM Session Manager (sem abrir porta 22)"
  value       = "aws ssm start-session --target ${aws_instance.lime.id} --region ${var.aws_region}"
}

output "lime_capture_command" {
  description = "Comando para iniciar captura de memória via LiME (executar na instância)"
  value       = "sudo lime-capture /tmp/dump-$(date +%Y%m%d-%H%M%S).lime"
}
