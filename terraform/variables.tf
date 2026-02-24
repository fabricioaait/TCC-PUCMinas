variable "aws_region" {
  description = "Região AWS onde os recursos serão criados"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome do projeto; usado como prefixo nos recursos AWS"
  type        = string
  default     = "tcc-pucminas-lime"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 (t3.micro=Free Tier 750h/mes, t3.medium=compilacao rapida)"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidrs" {
  description = "Lista de blocos CIDR permitidos para acesso SSH (porta 22)"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrinja ao seu IP em produção: ["SEU_IP/32"]
}

variable "volume_size_gb" {
  description = "Tamanho do volume raiz em GiB"
  type        = number
  default     = 20
}
