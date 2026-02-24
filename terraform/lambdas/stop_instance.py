"""
Lambda 4 - Parar Instancia (Containment)
Para a instancia EC2 comprometida apos a coleta de todas as evidencias.
Registra o estado final no S3.
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

    print(f"[STOP] Parando instancia {instance_id}")

    # ---- Estado atual antes de parar ----
    reservations = ec2.describe_instances(InstanceIds=[instance_id])
    instance = reservations["Reservations"][0]["Instances"][0]
    state_before = instance["State"]["Name"]

    print(f"[STOP] Estado atual: {state_before}")

    if state_before == "stopped":
        print(f"[STOP] Instancia ja esta parada")
        stop_result = {"already_stopped": True}
    else:
        # ---- Parar a instancia ----
        stop_response = ec2.stop_instances(InstanceIds=[instance_id])
        stop_result = {
            "previous_state": stop_response["StoppingInstances"][0][
                "PreviousState"
            ]["Name"],
            "current_state": stop_response["StoppingInstances"][0][
                "CurrentState"
            ]["Name"],
        }

        print(f"[STOP] Estado transicionou: {stop_result['previous_state']} -> {stop_result['current_state']}")

        # ---- Aguardar ate ficar stopped (max 120s) ----
        waiter = ec2.get_waiter("instance_stopped")
        try:
            waiter.wait(
                InstanceIds=[instance_id],
                WaiterConfig={"Delay": 10, "MaxAttempts": 12},
            )
            stop_result["final_state"] = "stopped"
            print("[STOP] Instancia parada com sucesso")
        except Exception as e:
            stop_result["final_state"] = "timeout"
            stop_result["error"] = str(e)
            print(f"[STOP] Timeout aguardando parada: {e}")

    # ---- Adicionar tag de evidencia ----
    ec2.create_tags(
        Resources=[instance_id],
        Tags=[
            {"Key": "ForensicsCaseId", "Value": case_id},
            {"Key": "ForensicsStatus", "Value": "contained"},
            {
                "Key": "ForensicsTimestamp",
                "Value": timestamp,
            },
        ],
    )

    print(f"[TAG] Tags de forensics adicionadas a {instance_id}")

    # ---- Registrar no S3 ----
    report = {
        "case_id": case_id,
        "instance_id": instance_id,
        "action": "stop_instance",
        "timestamp": timestamp,
        "state_before": state_before,
        "stop_result": stop_result,
    }

    s3_key = f"{case_id}/{instance_id}/containment/stop-instance-{timestamp}.json"

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
        "evidence_type": "containment",
        "s3_uri": f"s3://{BUCKET}/{s3_key}",
        "state_before": state_before,
        "timestamp": timestamp,
    }
