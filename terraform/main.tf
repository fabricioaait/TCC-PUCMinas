terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Project     = var.project_name
    ManagedBy   = "Terraform"
    Description = "TCC PUC Minas – Forense de Memória com LiME"
  }
}

# =============================================================================
# AMI: Amazon Linux 2023 (x86_64 mais recente)
# =============================================================================
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# =============================================================================
# Chave SSH: gerada pelo Terraform (privada salva localmente, coberta pelo .gitignore)
# =============================================================================
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = local.common_tags
}

# Salva a chave privada no diretório terraform/ com permissão 0400
# O arquivo *.pem está coberto pelo .gitignore da raiz do repo
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/${var.project_name}.pem"
  file_permission = "0400"
}

# =============================================================================
# IAM: Role + Instance Profile para SSM Session Manager
# =============================================================================
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ssm-profile"
  role = aws_iam_role.ec2_ssm.name

  tags = local.common_tags
}

# =============================================================================
# Rede: VPC e subnets padrão da conta
# =============================================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# =============================================================================
# Security Group
# =============================================================================
resource "aws_security_group" "lime_instance" {
  name        = "${var.project_name}-sg"
  description = "SG da instância de forense de memória – TCC PUC Minas"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "Saída livre (necessário para dnf e git durante provisionamento)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-sg" })
}

# =============================================================================
# EC2: Instância Amazon Linux 2023 com SSM + LiME
# =============================================================================
resource "aws_instance" "lime" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.ssh.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.lime_instance.id]
  associate_public_ip_address = true

  # Script de provisionamento: instala dependências, compila e configura o LiME
  user_data = file("${path.module}/userdata.sh")

  # Força nova instância se o userdata mudar
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 obrigatório (boa prática de segurança)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-instance" })
}
