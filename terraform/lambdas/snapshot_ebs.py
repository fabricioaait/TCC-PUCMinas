"""
Lambda 2 - Snapshot do EBS
Cria snapshots de todos os volumes EBS anexados a instancia comprometida
e salva os metadados no bucket S3 de evidencias.
"""

import json
import os
import time
import boto3

ec2 = boto3.client("ec2")
s3 = boto3.client("s3")
BUCKET = os.environ["FORENSICS_BUCKET"]


def lambda_handler(event, context):
    instance_id = event["instance_id"]
    case_id = event.get("case_id", f"case-{int(time.time())}")
    timestamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())

    print(f"[EBS] Iniciando snapshot dos volumes de {instance_id}")

    # ---- Listar volumes da instancia ----
    reservations = ec2.describe_instances(InstanceIds=[instance_id])
    instance = reservations["Reservations"][0]["Instances"][0]
    block_devices = instance.get("BlockDeviceMappings", [])

    if not block_devices:
        raise RuntimeError(f"Nenhum volume EBS encontrado em {instance_id}")

    snapshots = []

    for device in block_devices:
        volume_id = device["Ebs"]["VolumeId"]
        device_name = device["DeviceName"]

        print(f"[EBS] Criando snapshot de {volume_id} ({device_name})")

        snapshot = ec2.create_snapshot(
            VolumeId=volume_id,
            Description=f"Forensics snapshot - {case_id} - {instance_id} - {device_name}",
            TagSpecifications=[
                {
                    "ResourceType": "snapshot",
                    "Tags": [
                        {"Key": "CaseId", "Value": case_id},
                        {"Key": "InstanceId", "Value": instance_id},
                        {"Key": "DeviceName", "Value": device_name},
                        {"Key": "Purpose", "Value": "forensics-evidence"},
                        {"Key": "Project", "Value": "tcc-pucminas-lime"},
                    ],
                }
            ],
        )

        snapshot_info = {
            "snapshot_id": snapshot["SnapshotId"],
            "volume_id": volume_id,
            "device_name": device_name,
            "state": snapshot["State"],
            "start_time": snapshot["StartTime"].isoformat(),
        }

        snapshots.append(snapshot_info)
        print(f"[EBS] Snapshot criado: {snapshot['SnapshotId']}")

    # ---- Salvar metadados dos snapshots no S3 ----
    s3_key = f"{case_id}/{instance_id}/ebs/snapshots-{timestamp}.json"

    report = {
        "case_id": case_id,
        "instance_id": instance_id,
        "timestamp": timestamp,
        "snapshots": snapshots,
        "total_volumes": len(block_devices),
    }

    s3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=json.dumps(report, indent=2, default=str),
        ContentType="application/json",
        Tagging=f"CaseId={case_id}&Purpose=forensics-evidence",
    )

    print(f"[S3] Relatorio salvo em s3://{BUCKET}/{s3_key}")

    return {
        "status": "success",
        "instance_id": instance_id,
        "case_id": case_id,
        "evidence_type": "ebs_snapshot",
        "s3_uri": f"s3://{BUCKET}/{s3_key}",
        "snapshots": snapshots,
        "timestamp": timestamp,
    }
