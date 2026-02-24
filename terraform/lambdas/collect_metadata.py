"""
Lambda 3 - Coleta de Metadados da Instancia
Captura informacoes detalhadas da instancia EC2 comprometida:
tags, security groups, interfaces de rede, volumes, IAM role, etc.
Salva tudo como JSON no bucket S3 de evidencias.
"""

import json
import os
import time
import boto3

ec2 = boto3.client("ec2")
s3 = boto3.client("s3")
ssm = boto3.client("ssm")
BUCKET = os.environ["FORENSICS_BUCKET"]


def lambda_handler(event, context):
    instance_id = event["instance_id"]
    case_id = event.get("case_id", f"case-{int(time.time())}")
    timestamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())

    print(f"[META] Coletando metadados de {instance_id}")

    # ---- Dados da instancia via EC2 API ----
    reservations = ec2.describe_instances(InstanceIds=[instance_id])
    instance = reservations["Reservations"][0]["Instances"][0]

    # ---- Security Groups detalhados ----
    sg_ids = [sg["GroupId"] for sg in instance.get("SecurityGroups", [])]
    sg_details = []
    if sg_ids:
        sgs = ec2.describe_security_groups(GroupIds=sg_ids)
        sg_details = sgs["SecurityGroups"]

    # ---- Network interfaces ----
    eni_ids = [
        eni["NetworkInterfaceId"]
        for eni in instance.get("NetworkInterfaces", [])
    ]
    eni_details = []
    if eni_ids:
        enis = ec2.describe_network_interfaces(NetworkInterfaceIds=eni_ids)
        eni_details = enis["NetworkInterfaces"]

    # ---- Volumes ----
    volume_ids = [
        dev["Ebs"]["VolumeId"]
        for dev in instance.get("BlockDeviceMappings", [])
    ]
    volume_details = []
    if volume_ids:
        vols = ec2.describe_volumes(VolumeIds=volume_ids)
        volume_details = vols["Volumes"]

    # ---- Informacoes do SO via SSM (uname, hostname, processos, conexoes) ----
    os_info = {}
    try:
        commands = [
            "echo '=== HOSTNAME ===' && hostname -f",
            "echo '=== UNAME ===' && uname -a",
            "echo '=== UPTIME ===' && uptime",
            "echo '=== WHO ===' && who",
            "echo '=== PS AUX (top 50) ===' && ps aux --sort=-%mem | head -50",
            "echo '=== NETSTAT ===' && ss -tunapl 2>/dev/null || netstat -tunapl 2>/dev/null",
            "echo '=== ROUTES ===' && ip route show",
            "echo '=== IPTABLES ===' && iptables -L -n 2>/dev/null || echo 'sem permissao'",
            "echo '=== CRONTAB ROOT ===' && crontab -l 2>/dev/null || echo 'vazio'",
            "echo '=== LAST LOGINS ===' && last -20",
            "echo '=== /etc/passwd (ultimas 10 linhas) ===' && tail -10 /etc/passwd",
            "echo '=== MODULOS KERNEL ===' && lsmod",
        ]

        response = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands, "executionTimeout": ["120"]},
            Comment=f"Metadata collection - {case_id}",
            TimeoutSeconds=120,
        )

        command_id = response["Command"]["CommandId"]
        time.sleep(15)

        result = ssm.get_command_invocation(
            CommandId=command_id, InstanceId=instance_id
        )

        os_info = {
            "status": result["Status"],
            "stdout": result.get("StandardOutputContent", ""),
            "stderr": result.get("StandardErrorContent", ""),
        }

        print(f"[SSM] Coleta de metadados do SO: {result['Status']}")

    except Exception as e:
        os_info = {"status": "error", "message": str(e)}
        print(f"[SSM] Falha ao coletar dados do SO: {e}")

    # ---- Montar relatorio completo ----
    metadata = {
        "case_id": case_id,
        "instance_id": instance_id,
        "collection_timestamp": timestamp,
        "instance": {
            "instance_type": instance.get("InstanceType"),
            "ami_id": instance.get("ImageId"),
            "launch_time": instance.get("LaunchTime", "").isoformat()
            if hasattr(instance.get("LaunchTime", ""), "isoformat")
            else str(instance.get("LaunchTime", "")),
            "state": instance.get("State", {}).get("Name"),
            "private_ip": instance.get("PrivateIpAddress"),
            "public_ip": instance.get("PublicIpAddress"),
            "subnet_id": instance.get("SubnetId"),
            "vpc_id": instance.get("VpcId"),
            "availability_zone": instance.get("Placement", {}).get(
                "AvailabilityZone"
            ),
            "iam_instance_profile": instance.get("IamInstanceProfile", {}),
            "tags": instance.get("Tags", []),
            "platform": instance.get("PlatformDetails"),
            "architecture": instance.get("Architecture"),
            "key_name": instance.get("KeyName"),
        },
        "security_groups": sg_details,
        "network_interfaces": eni_details,
        "volumes": volume_details,
        "os_info": os_info,
    }

    # ---- Upload para S3 ----
    s3_key = f"{case_id}/{instance_id}/metadata/instance-metadata-{timestamp}.json"

    s3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=json.dumps(metadata, indent=2, default=str),
        ContentType="application/json",
        Tagging=f"CaseId={case_id}&Purpose=forensics-evidence",
    )

    print(f"[S3] Metadados salvos em s3://{BUCKET}/{s3_key}")

    return {
        "status": "success",
        "instance_id": instance_id,
        "case_id": case_id,
        "evidence_type": "instance_metadata",
        "s3_uri": f"s3://{BUCKET}/{s3_key}",
        "timestamp": timestamp,
    }
