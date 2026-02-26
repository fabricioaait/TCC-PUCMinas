# Forense de Memória em Nuvem com LiME e AWS

**Trabalho de Conclusão de Curso — Ciência da Computação | PUC Minas**

Implementação de um pipeline automatizado de resposta a incidentes em instâncias EC2, com captura de memória RAM via [LiME](https://github.com/504ensicsLabs/LiME) e preservação de evidências no Amazon S3.

---

## Visão Geral

O projeto provisiona, via Terraform, toda a infraestrutura necessária para executar um fluxo de *incident response* em uma instância EC2 comprometida:

1. **Captura de RAM** — módulo LiME carregado via SSM Run Command; dump `.lime` enviado ao S3.
2. **Snapshot EBS** — snapshot dos volumes de disco da instância comprometida.
3. **Coleta de Metadados** — tags, Security Groups, interfaces de rede e estado da instância em JSON no S3.
4. **Contenção** — parada da instância após a coleta de todas as evidências.

Cada etapa é executada por uma AWS Lambda independente, permitindo que o fluxo seja acionado manualmente ou por automação (EventBridge, GuardDuty, etc.).

---

## Estrutura

```
terraform/
├── main.tf            # EC2, VPC, Security Group, chave SSH
├── lambdas.tf         # Funções Lambda + CloudWatch Logs
├── iam_lambda.tf      # Roles e policies IAM
├── s3.tf              # Bucket de evidências forenses
├── variables.tf       # Variáveis configuráveis
├── outputs.tf         # Outputs do Terraform
├── userdata.sh        # Provisionamento da EC2: instala dependências e compila o LiME
└── lambdas/
    ├── capture_memory.py   # Lambda 1: captura de RAM via LiME
    ├── snapshot_ebs.py     # Lambda 2: snapshot dos volumes EBS
    ├── collect_metadata.py # Lambda 3: metadados da instância
    └── stop_instance.py    # Lambda 4: parada da instância (contenção)
```

---

## Pré-requisitos

- AWS CLI configurado (`aws configure`)
- Terraform ≥ 1.5
- Permissões AWS: EC2, SSM, Lambda, S3, IAM, CloudWatch

---

## Execução Rápida

```bash
cd terraform/
terraform init
terraform apply --auto-approve

export INSTANCE_ID=$(terraform output -raw instance_id)
export CASE_ID="case-$(date +%Y%m%d-%H%M%S)"
export REGION="us-east-1"

# Captura de memória RAM
aws lambda invoke \
  --function-name tcc-pucminas-lime-capture-memory \
  --payload "{\"instance_id\": \"$INSTANCE_ID\", \"case_id\": \"$CASE_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  --region $REGION /tmp/result-memory.json
```

Consulte o [READMEXEC.md](TCC-PUCMinas/READMEXEC.md) para o fluxo completo.

---

## Evidências Geradas

Todas as evidências são armazenadas em:

```
s3://<bucket>/<case_id>/<instance_id>/
├── memory/      # dump .lime (RAM completa)
├── ebs/         # JSON com IDs dos snapshots EBS
├── metadata/    # JSON com metadados da instância
└── containment/ # JSON com estado da parada
```

---

## Referências

- [LiME — Linux Memory Extractor](https://github.com/504ensicsLabs/LiME)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [AWS Automated EC2 Security Incident Response](https://systemweakness.com/aws-automated-ec2-security-incident-response)
