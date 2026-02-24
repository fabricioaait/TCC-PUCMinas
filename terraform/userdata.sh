#!/bin/bash
# =============================================================================
# User Data – Amazon Linux 2023
# TCC PUC Minas – Forense de Memória com LiME
# https://github.com/504ensicsLabs/LiME
# =============================================================================
set -euxo pipefail

# Redireciona toda a saída para syslog e console (visível no EC2 System Log)
exec > >(tee /var/log/userdata-lime.log | logger -t userdata-lime -s 2>/dev/console) 2>&1

echo "======================================================================"
echo " [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Iniciando provisionamento"
echo "======================================================================"

# ==============================================================================
# 1. SSM Agent
#    O SSM Agent vem pré-instalado no AL2023; apenas garantimos que está ativo.
# ==============================================================================
systemctl enable amazon-ssm-agent
systemctl start  amazon-ssm-agent || true
echo "[SSM] Status: $(systemctl is-active amazon-ssm-agent)"

# ==============================================================================
# 2. Instalar headers do kernel em execução ANTES de atualizar pacotes
#    (evita divergência de versão caso o dnf update atualize o kernel)
# ==============================================================================
KERNEL_VERSION=$(uname -r)
echo "[KERNEL] Versão em execução: ${KERNEL_VERSION}"

dnf install -y gcc make git elfutils-libelf-devel

# Tenta instalar a versão exata; se não disponível, cai para a genérica
if ! dnf install -y "kernel-devel-${KERNEL_VERSION}" 2>/dev/null; then
    echo "[KERNEL] kernel-devel-${KERNEL_VERSION} não encontrado; instalando versão disponível"
    dnf install -y kernel-devel
fi

# ==============================================================================
# 3. Atualiza demais pacotes (kernel excluído para evitar divergência de versão)
# ==============================================================================
dnf update -y --exclude='kernel*'

# ==============================================================================
# 4. Verifica / cria symlink de build do kernel (exigido pelo Makefile do LiME)
#    O LiME usa: KDIR ?= /lib/modules/$(uname -r)/build
# ==============================================================================
BUILD_LINK="/lib/modules/${KERNEL_VERSION}/build"

if [ ! -d "${BUILD_LINK}" ]; then
    echo "[KERNEL] Symlink ${BUILD_LINK} ausente; tentando criar..."
    KERNEL_SRC=$(find /usr/src/kernels -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)

    if [ -n "${KERNEL_SRC}" ]; then
        ln -sfn "${KERNEL_SRC}" "${BUILD_LINK}"
        echo "[KERNEL] Symlink criado: ${BUILD_LINK} -> ${KERNEL_SRC}"
    else
        echo "[KERNEL] ERRO: diretório de headers não encontrado em /usr/src/kernels/" >&2
        exit 1
    fi
else
    echo "[KERNEL] Build dir OK: ${BUILD_LINK}"
fi

# ==============================================================================
# 5. Clonar e compilar o LiME
# ==============================================================================
LIME_DIR="/opt/LiME"

echo "[LiME] Clonando repositório..."
git clone --depth=1 https://github.com/504ensicsLabs/LiME.git "${LIME_DIR}"

echo "[LiME] Compilando módulo de kernel..."
cd "${LIME_DIR}/src"
make

LIME_MODULE=$(ls "${LIME_DIR}/src/"*.ko 2>/dev/null | head -1)

if [ -z "${LIME_MODULE}" ]; then
    echo "[LiME] ERRO: módulo .ko não foi gerado após o make" >&2
    exit 1
fi

echo "[LiME] Módulo compilado com sucesso: ${LIME_MODULE}"
modinfo "${LIME_MODULE}"

# ==============================================================================
# 6. Script helper: sudo lime-capture [arquivo.lime]
#    Facilita a captura de memória sem precisar lembrar a sintaxe do insmod
# ==============================================================================
cat > /usr/local/bin/lime-capture << 'HELPER'
#!/bin/bash
# Uso: sudo lime-capture [arquivo_de_saida.lime]
set -e

OUTPUT="${1:-/tmp/memory-$(date +%Y%m%d-%H%M%S).lime}"
MODULE=$(ls /opt/LiME/src/*.ko 2>/dev/null | head -1)

if [ -z "${MODULE}" ]; then
    echo "Erro: módulo LiME não encontrado em /opt/LiME/src/" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Erro: execute com sudo" >&2
    exit 1
fi

echo "[LiME] Módulo : ${MODULE}"
echo "[LiME] Destino: ${OUTPUT}"
echo "[LiME] Iniciando captura de memória RAM..."

insmod "${MODULE}" "path=${OUTPUT} format=lime"

echo "[LiME] Captura concluída!"
echo "[LiME] Arquivo : ${OUTPUT}"
echo "[LiME] Tamanho : $(du -sh "${OUTPUT}" | cut -f1)"
HELPER

chmod +x /usr/local/bin/lime-capture

# ==============================================================================
# 7. Resumo final
# ==============================================================================
echo "======================================================================"
echo " [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Provisionamento concluído"
echo "----------------------------------------------------------------------"
echo " SSM Agent : $(systemctl is-active amazon-ssm-agent)"
echo " LiME      : ${LIME_MODULE}"
echo " Helper    : /usr/local/bin/lime-capture"
echo ""
echo " Para capturar memória (dentro da instância):"
echo "   sudo lime-capture /tmp/dump.lime"
echo "======================================================================"
