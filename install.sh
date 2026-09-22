#!/bin/bash
# Local OpenBao install. Everything it needs is in this directory.
# Run on the target machine: sudo ./install.sh
# Optional: sudo OPENBAO_API_ADDR=https://10.0.0.5:8200 ./install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="2.6.2"
INIT_FILE="/root/openbao-init.txt"
TLS_DIR="/etc/openbao/tls"
DATA_DIR="/opt/openbao/data"
CONFIG="/etc/openbao/openbao.hcl"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root: sudo ./install.sh" >&2
  exit 1
fi

arch="$(uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  echo "В этом каталоге пакеты только для x86_64. На машине: ${arch}." >&2
  exit 1
fi

if [[ -f /etc/debian_version ]]; then
  package="${ROOT}/files/openbao_${VERSION}_linux_amd64.deb"
  family="deb"
elif [[ -f /etc/redhat-release || -f /etc/fedora-release ]]; then
  package="${ROOT}/files/openbao_${VERSION}_linux_amd64.rpm"
  family="rpm"
else
  echo "Нужна Debian, Ubuntu или RHEL-подобная система." >&2
  exit 1
fi

if [[ ! -f "$package" ]]; then
  echo "Нет пакета ${package}." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "На машине нет openssl. Поставьте его с установочного носителя ОС и запустите скрипт снова." >&2
  exit 1
fi

echo "Проверяю контрольную сумму..."
name="$(basename "$package")"
line="$(awk -v name="$name" '$NF == name || $NF == "*" name { print; exit }' "${ROOT}/files/checksums.txt")"
if [[ -z "$line" ]]; then
  echo "В checksums.txt нет строки для ${name}." >&2
  exit 1
fi
printf '%s\n' "$line" | (cd "${ROOT}/files" && sha256sum -c -)

if [[ -n "${OPENBAO_API_ADDR:-}" ]]; then
  api_addr="$OPENBAO_API_ADDR"
  bind_host="${api_addr#*://}"
  bind_host="${bind_host%%:*}"
  bind_host="${bind_host%%/*}"
else
  bind_host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$bind_host" ]]; then
    echo "Не удалось определить IP. Запустите так: sudo OPENBAO_API_ADDR=https://<ip>:8200 ./install.sh" >&2
    exit 1
  fi
  api_addr="https://${bind_host}:8200"
fi
cluster_addr="${OPENBAO_CLUSTER_ADDR:-https://${bind_host}:8201}"

echo "Ставлю пакет..."
if [[ "$family" == "deb" ]]; then
  installed="$(dpkg-query -W -f '${Version}' openbao 2>/dev/null || true)"
  if [[ "$installed" != "$VERSION" ]]; then
    dpkg -i "$package"
  fi
else
  installed="$(rpm -q --qf '%{VERSION}' openbao 2>/dev/null || true)"
  if [[ "$installed" != "$VERSION" ]]; then
    rpm -Uvh --nosignature "$package"
  fi
fi

install -d -o openbao -g openbao -m 0700 "$DATA_DIR"
install -d -o root -g openbao -m 0750 "$TLS_DIR"

if [[ -f "${ROOT}/files/tls.crt" && -f "${ROOT}/files/tls.key" ]]; then
  echo "Беру сертификат из files/tls.crt..."
  install -o root -g openbao -m 0644 "${ROOT}/files/tls.crt" "${TLS_DIR}/tls.crt"
  install -o root -g openbao -m 0640 "${ROOT}/files/tls.key" "${TLS_DIR}/tls.key"
elif [[ ! -s "${TLS_DIR}/tls.crt" || ! -s "${TLS_DIR}/tls.key" ]]; then
  echo "Выпускаю сертификат на ${bind_host}..."
  if [[ "$bind_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san="IP:${bind_host}"
  else
    san="DNS:${bind_host}"
  fi
  cnf="$(mktemp)"
  cat > "$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${bind_host}
[v3_req]
subjectAltName = ${san}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TLS_DIR}/tls.key" \
    -out "${TLS_DIR}/tls.crt" \
    -days 825 \
    -config "$cnf"
  rm -f "$cnf"
  chown root:openbao "${TLS_DIR}/tls.crt" "${TLS_DIR}/tls.key"
  chmod 0644 "${TLS_DIR}/tls.crt"
  chmod 0640 "${TLS_DIR}/tls.key"
fi

tmp_config="$(mktemp)"
cat > "$tmp_config" <<EOF
ui = true
api_addr = "${api_addr}"
cluster_addr = "${cluster_addr}"

storage "raft" {
  path    = "${DATA_DIR}"
  node_id = "node1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "${TLS_DIR}/tls.crt"
  tls_key_file  = "${TLS_DIR}/tls.key"
}
EOF

changed=0
if [[ ! -f "$CONFIG" ]] || ! cmp -s "$tmp_config" "$CONFIG"; then
  install -o root -g openbao -m 0640 "$tmp_config" "$CONFIG"
  changed=1
fi
rm -f "$tmp_config"

cat > /etc/profile.d/openbao.sh <<EOF
export BAO_ADDR='${api_addr}'
export BAO_CACERT='${TLS_DIR}/tls.crt'
EOF
chmod 0644 /etc/profile.d/openbao.sh

systemctl daemon-reload
systemctl enable openbao
if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet openbao; then
  systemctl restart openbao
fi

export BAO_ADDR="$api_addr"
export BAO_CACERT="${TLS_DIR}/tls.crt"

echo "Жду, пока OpenBao начнёт отвечать..."
ready=0
for _ in $(seq 1 30); do
  if bao status 2>&1 | grep -q 'Initialized'; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  echo "Сервис запущен, но API ещё не отвечает. Смотрите: journalctl -u openbao -n 50" >&2
  exit 1
fi

status="$(bao status 2>&1 || true)"
if ! grep -q 'Initialized[[:space:]]*true' <<<"$status"; then
  echo "Инициализирую хранилище..."
  umask 077
  bao operator init -key-shares=1 -key-threshold=1 > "$INIT_FILE"
  chmod 0600 "$INIT_FILE"
  status="$(bao status 2>&1 || true)"
fi

if grep -q 'Sealed[[:space:]]*true' <<<"$status"; then
  if [[ ! -f "$INIT_FILE" ]]; then
    echo "OpenBao запечатан, а ${INIT_FILE} нет. Выполните bao operator unseal вручную." >&2
    exit 1
  fi
  key="$(awk -F': ' '/^Unseal Key 1:/ {print $2; exit}' "$INIT_FILE")"
  if [[ -z "$key" ]]; then
    echo "В ${INIT_FILE} нет Unseal Key 1." >&2
    exit 1
  fi
  bao operator unseal "$key" >/dev/null
fi

echo
echo "OpenBao работает: ${api_addr}"
echo "Интерфейс:       ${api_addr}/ui"
echo "Ключ и root token записаны в ${INIT_FILE}"
echo "Уберите этот файл с сервера, если ключ должен храниться отдельно."
echo "После перезагрузки сервер снова sealed. Распечатать:"
echo "  export BAO_ADDR='${api_addr}'"
echo "  export BAO_CACERT='${TLS_DIR}/tls.crt'"
echo "  bao operator unseal \"\$(awk -F': ' '/^Unseal Key 1:/ {print \$2; exit}' ${INIT_FILE})\""
