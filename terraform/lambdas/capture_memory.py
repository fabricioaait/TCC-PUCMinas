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
    dump_path = f"/tmp/dump-{timestamp}.lime"

    print(f"[RAM] Iniciando captura de memoria da instancia {instance_id}")
    print(f"[RAM] Destino S3: s3://{BUCKET}/{s3_key}")

    # ---- Comando SSM: insmod LiME + upload S3 ----
    commands = [
        f"echo '[LiME] Iniciando captura de memoria RAM...'",
        f"LIME_MODULE=$(ls /opt/LiME/src/*.ko 2>/dev/null | head -1)",
        f"if [ -z \"$LIME_MODULE\" ]; then echo 'ERRO: modulo LiME nao encontrado'; exit 1; fi",
        f"insmod $LIME_MODULE 'path={dump_path} format=lime'",
        f"echo '[LiME] Captura concluida: {dump_path}'",
        f"ls -lh {dump_path}",
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
