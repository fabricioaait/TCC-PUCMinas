# READMEXEC — Guia de Execução do Fluxo de Incident Response

TCC PUC Minas — Forense de Memória com LiME + AWS Lambdas

---

## Pré-requisitos

- AWS CLI instalado e configurado (`aws configure`)
- Terraform >= 1.5 instalado
- Permissões na conta AWS: EC2, SSM, Lambda, S3, IAM, CloudWatch

---

## 1. Provisionamento da Infraestrutura

```bash
cd terraform/

# Inicializar providers
terraform init

# Verificar o plano
terraform plan

# Criar todos os recursos (EC2 + Lambdas + S3 + IAM)
terraform apply --auto-approve
```

Ao final, anote os outputs:

```bash
terraform output instance_id
terraform output instance_public_ip
terraform output forensics_bucket
```

---

## 2. Conexão na Instância EC2

### Via SSM (recomendado — sem expor porta 22)

```bash
aws ssm start-session \
  --target $(terraform output -raw instance_id) \
  --region us-east-1
```

### Via SSH (requer porta 22 aberta no SG)

```bash
ssh -i $(terraform output -raw private_key_path) \
  ec2-user@$(terraform output -raw instance_public_ip)
```

---

## 3. Captura Manual de Memória (dentro da instância)

```bash
# Captura com helper script instalado pelo userdata
sudo lime-capture /tmp/dump-$(date +%Y%m%d-%H%M%S).lime

# Verificar o arquivo gerado
ls -lh /tmp/*.lime

# Upload manual para S3 (opcional)
aws s3 cp /tmp/dump-*.lime s3://<BUCKET>/manual/<INSTANCE_ID>/memory/
```

---

## 4. Fluxo Automatizado de Incident Response (Lambdas)

> Substitua `INSTANCE_ID` e `CASE_ID` nos comandos abaixo.

### Variáveis de ambiente (facilita os próximos comandos)

```bash
export INSTANCE_ID=$(cd terraform && terraform output -raw instance_id)
export CASE_ID="case-$(date +%Y%m%d-%H%M%S)"
export REGION="us-east-1"

echo "Instance: $INSTANCE_ID"
echo "Case:     $CASE_ID"
```

---

### Lambda 1 — Captura de Memória RAM

Executa `insmod` do módulo LiME via SSM e envia o dump `.lime` para o S3.

```bash
aws lambda invoke \
  --function-name tcc-pucminas-lime-capture-memory \
  --payload "{\"instance_id\": \"$INSTANCE_ID\", \"case_id\": \"$CASE_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  --region $REGION \
  /tmp/result-memory.json

cat /tmp/result-memory.json | python3 -m json.tool
```

> ⏱️ Timeout: 15 minutos (a captura pode levar vários minutos dependendo da RAM)

---

### Lambda 2 — Snapshot dos Volumes EBS

Cria snapshots de todos os volumes EBS da instância comprometida.

```bash
aws lambda invoke \
  --function-name tcc-pucminas-lime-snapshot-ebs \
  --payload "{\"instance_id\": \"$INSTANCE_ID\", \"case_id\": \"$CASE_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  --region $REGION \
  /tmp/result-ebs.json

cat /tmp/result-ebs.json | python3 -m json.tool
```

---

### Lambda 3 — Coleta de Metadados da Instância

Coleta tags, Security Groups, interfaces de rede, IAM role, estado da instância e salva JSON no S3.

```bash
aws lambda invoke \
  --function-name tcc-pucminas-lime-collect-metadata \
  --payload "{\"instance_id\": \"$INSTANCE_ID\", \"case_id\": \"$CASE_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  --region $REGION \
  /tmp/result-metadata.json

cat /tmp/result-metadata.json | python3 -m json.tool
```

---

### Lambda 4 — Parar a Instância (Containment)

Para a instância comprometida. **Execute apenas após as etapas 1, 2 e 3.**

```bash
aws lambda invoke \
  --function-name tcc-pucminas-lime-stop-instance \
  --payload "{\"instance_id\": \"$INSTANCE_ID\", \"case_id\": \"$CASE_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  --region $REGION \
  /tmp/result-stop.json

cat /tmp/result-stop.json | python3 -m json.tool
```

---

## 5. Verificação das Evidências no S3

```bash
export BUCKET=$(cd terraform && terraform output -raw forensics_bucket)

# Listar todas as evidências do caso
aws s3 ls s3://$BUCKET/$CASE_ID/ --recursive --human-readable

# Baixar o dump de memória
aws s3 cp s3://$BUCKET/$CASE_ID/$INSTANCE_ID/memory/ . --recursive

# Baixar o JSON de metadados
aws s3 cp s3://$BUCKET/$CASE_ID/$INSTANCE_ID/metadata/ . --recursive

# Listar snapshots EBS criados
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:CaseId,Values=$CASE_ID" \
  --query 'Snapshots[*].{ID:SnapshotId,Size:VolumeSize,State:State,Desc:Description}' \
  --output table \
  --region $REGION
```

---

## 6. Verificar Logs das Lambdas (CloudWatch)

```bash
# Lambda 1 - capture_memory
aws logs tail /aws/lambda/tcc-pucminas-lime-capture-memory \
  --follow --region $REGION

# Lambda 2 - snapshot_ebs
aws logs tail /aws/lambda/tcc-pucminas-lime-snapshot-ebs \
  --follow --region $REGION

# Lambda 3 - collect_metadata
aws logs tail /aws/lambda/tcc-pucminas-lime-collect-metadata \
  --follow --region $REGION

# Lambda 4 - stop_instance
aws logs tail /aws/lambda/tcc-pucminas-lime-stop-instance \
  --follow --region $REGION
```

---

## 7. Análise Básica do Dump de Memória

```bash
# Verificar assinatura LiME no dump (magic bytes "EMiL")
xxd dump-*.lime | head -5

# Extrair strings legíveis (processos, paths, conexões)
strings dump-*.lime | grep -E "^/.{3,}" | sort -u | head -50

# Buscar IPs no dump
strings dump-*.lime | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u

# Buscar nomes de processos comuns
strings dump-*.lime | grep -E "bash|python|ssh|curl|wget|nc |ncat" | sort -u

# Tamanho do dump
ls -lh dump-*.lime
```

---

## 8. Destruir a Infraestrutura

```bash
cd terraform/

# Destruir tudo (EC2, Lambdas, S3, IAM)
# ATENÇÃO: o bucket S3 tem force_destroy=true, os dados serão apagados
terraform destroy --auto-approve
```

---

## Resumo do Fluxo IR

```
Incidente detectado
       │
       ▼
[Lambda 1] capture_memory   →  dump .lime → S3
       │
       ▼
[Lambda 2] snapshot_ebs     →  snapshot EBS criado
       │
       ▼
[Lambda 3] collect_metadata →  JSON com metadados → S3
       │
       ▼
[Lambda 4] stop_instance    →  instância parada (containment)
       │
       ▼
Evidências em s3://<BUCKET>/<CASE_ID>/<INSTANCE_ID>/
```

---

## Referências

- [LiME - Linux Memory Extractor](https://github.com/504ensicsLabs/LiME)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Artigo base: AWS Automated EC2 Security Incident Response](https://systemweakness.com/aws-automated-ec2-security-incident-response)
