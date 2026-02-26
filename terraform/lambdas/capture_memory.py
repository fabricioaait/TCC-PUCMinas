"""
Lambda 1 - Captura de Memoria RAM via LiME
Executa insmod do modulo LiME na instancia via SSM Run Command,
depois faz upload do dump .lime para o bucket S3 de evidencias.
"""

import json
import os
import time
import boto3

ssm = boto3.client("ssm")
BUCKET = os.environ["FORENSICS_BUCKET"]
TIMEOUT_SECONDS = int(os.environ.get("COMMAND_TIMEOUT", "600"))


def lambda_handler(event, context):
    instance_id = event["instance_id"]
    case_id = event.get("case_id", f"case-{int(time.time())}")
    timestamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    s3_key = f"{case_id}/{instance_id}/memory/dump-{timestamp}.lime"
    # /tmp eh tmpfs limitado a ~50% da RAM (apenas ~512 MB no t3.micro).
    # O dump do LiME tem o mesmo tamanho da RAM (~1 GB), causando
    # 'No space left on device'. Usar /var/tmp/ que fica no volume EBS (20 GB).
    dump_path = f"/var/tmp/dump-{timestamp}.lime"

    print(f"[RAM] Iniciando captura de memoria da instancia {instance_id}")
    print(f"[RAM] Destino S3: s3://{BUCKET}/{s3_key}")

    # ---- Comando SSM: insmod LiME + upload S3 ----
    commands = [
        f"echo '[LiME] Iniciando captura de memoria RAM...'",
        f"LIME_MODULE=$(ls /opt/LiME/src/*.ko 2>/dev/null | head -1)",
        f"if [ -z \"$LIME_MODULE\" ]; then echo 'ERRO: modulo LiME nao encontrado em /opt/LiME/src/'; exit 1; fi",
        f"echo \"[LiME] Modulo encontrado: $LIME_MODULE\"",
        # Descarregar modulo se ja estiver carregado de uma execucao anterior
        # (insmod falha com EEXIST se o modulo ja estiver no kernel)
        f"if lsmod | grep -q '^lime'; then echo '[LiME] Modulo ja carregado, descarregando...'; rmmod lime; fi",
        # Verificar espaco disponivel em /var/tmp (precisa de RAM + 10% de margem)
        f"AVAIL_KB=$(df /var/tmp --output=avail | tail -1)",
        f"RAM_KB=$(grep MemTotal /proc/meminfo | awk '{{print $2}}')",
        f"if [ \"$AVAIL_KB\" -lt \"$RAM_KB\" ]; then echo \"ERRO: espaco insuficiente em /var/tmp (${{AVAIL_KB}}KB disponivel, ${{RAM_KB}}KB necessario)\"; exit 1; fi",
        f"echo \"[DISK] Espaco disponivel: ${{AVAIL_KB}}KB | RAM total: ${{RAM_KB}}KB\"",
        f"insmod $LIME_MODULE 'path={dump_path} format=lime'",
        # Verificar que o dump foi gerado e tem tamanho plausivel (> 0 bytes)
        f"if [ ! -s {dump_path} ]; then echo 'ERRO: dump nao gerado ou esta vazio: {dump_path}'; exit 1; fi",
        f"echo '[LiME] Captura concluida: {dump_path}'",
        f"ls -lh {dump_path}",
        # Descarregar modulo apos o dump para liberar o kernel
        f"rmmod lime || true",
        f"echo '[S3] Iniciando upload para s3://{BUCKET}/{s3_key}'",
        f"aws s3 cp {dump_path} s3://{BUCKET}/{s3_key} --region {os.environ.get('AWS_REGION', 'us-east-1')}",
        f"echo '[S3] Upload concluido'",
        f"rm -f {dump_path}",
        f"echo '[CLEANUP] Dump local removido'",
    ]

    response = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={
            "commands": commands,
            "executionTimeout": [str(TIMEOUT_SECONDS)],
        },
        Comment=f"LiME RAM capture - {case_id}",
        TimeoutSeconds=TIMEOUT_SECONDS,
    )

    command_id = response["Command"]["CommandId"]
    print(f"[SSM] Command ID: {command_id}")

    # ---- Aguarda conclusao ----
    status = "InProgress"
    while status in ("InProgress", "Pending"):
        time.sleep(10)
        result = ssm.get_command_invocation(
            CommandId=command_id, InstanceId=instance_id
        )
        status = result["Status"]
        print(f"[SSM] Status: {status}")

    output = result.get("StandardOutputContent", "")
    error = result.get("StandardErrorContent", "")

    if status != "Success":
        print(f"[SSM] ERRO: {error}")
        raise RuntimeError(
            f"Captura de memoria falhou com status {status}: {error}"
        )

    print(f"[SSM] Output: {output}")

    return {
        "status": "success",
        "instance_id": instance_id,
        "case_id": case_id,
        "evidence_type": "memory_dump",
        "s3_uri": f"s3://{BUCKET}/{s3_key}",
        "command_id": command_id,
        "timestamp": timestamp,
    }
