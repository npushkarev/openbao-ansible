#!/bin/bash
# Offline OpenBao install on one x86_64 machine. Everything it needs is in this directory.
#   sudo ./install.sh            (or: sudo bash install.sh)
#
# Optional environment:
#   OPENBAO_API_ADDR=https://10.0.0.5:8200   address clients use; a new one rewrites the config
#   OPENBAO_CLUSTER_ADDR=https://10.0.0.5:8201
#   OPENBAO_FIREWALL=0                       leave firewalld/ufw alone
#   OPENBAO_AUTO_UNSEAL=1                    unseal after every start of the service (0 turns it off)
#
# Safe to re-run: it changes only what differs, and unseals a sealed server.

set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="2.6.2"
PORT=8200
INIT_FILE="/root/openbao-init.txt"
CONFIG="/etc/openbao/openbao.hcl"
TLS_DIR="/etc/openbao/tls"
DATA_DIR="/opt/openbao/data"
AUDIT_DIR="/var/log/openbao"
UNSEAL_BIN="/usr/local/sbin/openbao-unseal"
UNIT_DIR="/etc/systemd/system/openbao.service.d"
DROPIN="${UNIT_DIR}/auto-unseal.conf"
SECUREBITS_DROPIN="${UNIT_DIR}/securebits.conf"

die() {
  echo "$*" >&2
  exit 1
}

# put_file SRC DEST OWNER MODE: replace DEST when the contents differ.
# Returns 1 only when DEST already had these contents.
put_file() {
  local src="$1" dest="$2" owner="$3" mode="$4"
  if [[ -f "$dest" ]] && [[ "$(sha256sum < "$src")" == "$(sha256sum < "$dest")" ]]; then
    chown "$owner" "$dest" || die "Не удалось сменить владельца ${dest}."
    chmod "$mode" "$dest" || die "Не удалось сменить права ${dest}."
    return 1
  fi
  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$src" "$dest" || die "Не удалось записать ${dest}."
  return 0
}

# conf_value KEY: the first quoted value of KEY in openbao.hcl. A trailing comment is fine.
conf_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$CONFIG" 2>/dev/null | head -n 1 || true
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
}

# cert_covers CERT HOST: the certificate is valid for this IP or DNS name.
cert_covers() {
  local check="-checkhost"
  if is_ipv4 "$2"; then
    check="-checkip"
  fi
  openssl x509 -in "$1" -noout "$check" "$2" 2>/dev/null | grep -q 'does match'
}

# Only self-signed certificates are ours to reissue. A CA-issued one is left alone.
cert_self_signed() {
  [[ "$(openssl x509 -in "$1" -noout -subject | sed 's/^subject=//')" == \
     "$(openssl x509 -in "$1" -noout -issuer | sed 's/^issuer=//')" ]]
}

# First IPv4 of the interface that carries the default route, else any global one.
detect_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
    if [[ -z "$ip" ]]; then
      ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}' || true)"
    fi
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true)"
  fi
  printf '%s' "$ip"
}

# Sets $status to `bao status -format=json`. Returns 1 while the API does not answer.
read_status() {
  local rc=0
  status="$(BAO_CLIENT_TIMEOUT=5s bao status -format=json 2>&1)" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 2 ]]
}

open_firewall() {
  local zone="" dev="" addr="$bind_host"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    # The zone of the interface that carries the address clients use.
    if ! is_ipv4 "$addr"; then
      addr="$(getent ahostsv4 "$addr" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
      if [[ -z "$addr" ]]; then
        addr="$(detect_ip)"
      fi
    fi
    if [[ -n "$addr" ]] && command -v ip >/dev/null 2>&1; then
      dev="$(ip -o -4 addr show to "$addr" 2>/dev/null | awk '{print $2; exit}' || true)"
    fi
    if [[ -n "$dev" ]]; then
      zone="$(firewall-cmd --get-zone-of-interface="$dev" 2>/dev/null || true)"
    fi
    if [[ -z "$zone" ]]; then
      zone="$(firewall-cmd --get-default-zone)"
    fi
    # Runtime and permanent separately: --reload would drop the admin's runtime-only rules.
    local opened=0
    if ! firewall-cmd --zone="$zone" --query-port="${PORT}/tcp" >/dev/null 2>&1; then
      firewall-cmd --zone="$zone" --add-port="${PORT}/tcp" >/dev/null
      opened=1
    fi
    if ! firewall-cmd --permanent --zone="$zone" --query-port="${PORT}/tcp" >/dev/null 2>&1; then
      firewall-cmd --permanent --zone="$zone" --add-port="${PORT}/tcp" >/dev/null
      opened=1
    fi
    if [[ "$opened" -eq 1 ]]; then
      echo "Открыл ${PORT}/tcp в firewalld, зона ${zone}."
      changes+=("firewall")
    fi
  elif command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    # Any existing rule for the port is the admin's decision, a deny included.
    if ! LC_ALL=C ufw status | grep -qE "^${PORT}/tcp[[:space:]]"; then
      ufw allow "${PORT}/tcp" >/dev/null
      echo "Открыл ${PORT}/tcp в ufw."
      changes+=("firewall")
    fi
  fi
}

changes=()

if [[ "$(id -u)" -ne 0 ]]; then
  die "Запустите от root: sudo ./install.sh"
fi

for var in OPENBAO_FIREWALL OPENBAO_AUTO_UNSEAL; do
  case "${!var:-}" in
    "" | 0 | 1) ;;
    *) die "${var} принимает 1 или 0, а не '${!var}'." ;;
  esac
done

arch="$(uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  die "В этом каталоге пакеты только для x86_64. На машине: ${arch}."
fi

if [[ -f /etc/debian_version ]]; then
  package="${ROOT}/files/openbao_${VERSION}_linux_amd64.deb"
  family="deb"
elif [[ -f /etc/redhat-release || -f /etc/fedora-release ]]; then
  package="${ROOT}/files/openbao_${VERSION}_linux_amd64.rpm"
  family="rpm"
else
  die "Нужна Debian, Ubuntu или RHEL-подобная система."
fi

for f in "$package" "${ROOT}/files/checksums.txt" "${ROOT}/files/openbao-unseal"; do
  if [[ ! -f "$f" ]]; then
    die "Нет файла ${f}."
  fi
done

for cmd in openssl systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "На машине нет ${cmd}. Поставьте его с установочного носителя ОС и запустите скрипт снова."
  fi
done

# Settings from the caller's shell (BAO_FORMAT=json, BAO_NAMESPACE, a short client
# timeout...) would change what the bao calls below return. Drop them all.
for var in $(compgen -e); do
  case "$var" in
    BAO_* | VAULT_*) unset "$var" ;;
  esac
done

echo "Проверяю контрольную сумму..."
name="$(basename "$package")"
line="$(awk -v name="$name" '{ sub(/\r$/, "") } $NF == name || $NF == "*" name { print; exit }' "${ROOT}/files/checksums.txt")"
if [[ -z "$line" ]]; then
  die "В checksums.txt нет строки для ${name}."
fi
printf '%s\n' "$line" | (cd "${ROOT}/files" && sha256sum -c -)

# Address: OPENBAO_API_ADDR wins, then the existing config, then autodetect.
# The config is written on the first install, or when a variable sets an address
# that differs from the one in it. Otherwise a re-run keeps manual edits.
raft_config=0
existing_api_addr=""
existing_cluster_addr=""
if [[ -s "$CONFIG" ]] && grep -q '^[[:space:]]*storage[[:space:]]*"raft"' "$CONFIG"; then
  raft_config=1
  existing_api_addr="$(conf_value api_addr)"
  existing_cluster_addr="$(conf_value cluster_addr)"
fi

if [[ -n "${OPENBAO_API_ADDR:-}" ]]; then
  api_addr="$OPENBAO_API_ADDR"
elif [[ -n "$existing_api_addr" ]]; then
  api_addr="$existing_api_addr"
elif [[ "$raft_config" -eq 1 ]]; then
  die "В ${CONFIG} нет api_addr. Запустите с OPENBAO_API_ADDR=https://<адрес>:${PORT}"
else
  ip="$(detect_ip)"
  if [[ -z "$ip" ]]; then
    die "Не удалось определить IP. Запустите так: sudo OPENBAO_API_ADDR=https://<ip>:${PORT} ./install.sh"
  fi
  api_addr="https://${ip}:${PORT}"
  if command -v ip >/dev/null 2>&1; then
    all_ips="$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | tr '\n' ' ' || true)"
    if [[ "$(wc -w <<<"$all_ips")" -gt 1 ]]; then
      echo "У машины несколько адресов (${all_ips% }), беру ${ip}. Другой: sudo OPENBAO_API_ADDR=https://<ip>:${PORT} ./install.sh"
    fi
  fi
fi
api_addr="${api_addr%/}"
if [[ "$api_addr" =~ ^https://[^:/]+$ ]]; then
  api_addr="${api_addr}:${PORT}"
fi
if [[ ! "$api_addr" =~ ^https://([A-Za-z0-9.-]+):([0-9]{1,5})$ ]] || [[ "${BASH_REMATCH[2]}" -gt 65535 ]]; then
  die "Адрес ${api_addr} не подходит. Нужен вид https://<IPv4 или DNS-имя>:${PORT}"
fi
bind_host="${BASH_REMATCH[1]}"

if [[ -n "${OPENBAO_CLUSTER_ADDR:-}" ]]; then
  cluster_addr="${OPENBAO_CLUSTER_ADDR%/}"
elif [[ -n "$existing_cluster_addr" && "$api_addr" == "$existing_api_addr" ]]; then
  cluster_addr="$existing_cluster_addr"
else
  cluster_addr="https://${bind_host}:8201"
fi

write_config=0
if [[ "$raft_config" -eq 0 ]]; then
  write_config=1
elif [[ -n "${OPENBAO_API_ADDR:-}" && "$api_addr" != "$existing_api_addr" ]]; then
  write_config=1
elif [[ -n "${OPENBAO_CLUSTER_ADDR:-}" && "$cluster_addr" != "$existing_cluster_addr" ]]; then
  write_config=1
fi
if [[ "$write_config" -eq 1 ]]; then
  if [[ ! "$cluster_addr" =~ ^https://[A-Za-z0-9.-]+:([0-9]{1,5})$ ]] || [[ "${BASH_REMATCH[1]}" -gt 65535 ]]; then
    die "Адрес кластера ${cluster_addr} не подходит. Нужен вид https://<IPv4 или DNS-имя>:8201"
  fi
fi

if is_ipv4 "$bind_host" && command -v ip >/dev/null 2>&1 &&
   [[ -z "$(ip -o -4 addr show to "$bind_host" 2>/dev/null || true)" ]]; then
  echo "Внимание: адреса ${bind_host} нет на этой машине. Если он сменился: sudo OPENBAO_API_ADDR=https://<новый>:${PORT} ./install.sh" >&2
fi

# node_id must never change once raft holds data: keep the configured one.
node_id="$(conf_value node_id)"
if [[ -z "$node_id" && -s "${DATA_DIR}/node-id" ]]; then
  node_id="$(head -n 1 "${DATA_DIR}/node-id")"
fi
if [[ -z "$node_id" && "$write_config" -eq 1 && -e "${DATA_DIR}/raft/raft.db" ]]; then
  die "В ${DATA_DIR} уже есть данные raft, а node_id не найден. Впишите прежний node_id в ${CONFIG}."
fi
node_id="${node_id:-node1}"

# Check a supplied certificate before anything on the machine changes.
user_crt="${ROOT}/files/tls.crt"
user_key="${ROOT}/files/tls.key"
own_cert=0
if [[ -f "$user_crt" || -f "$user_key" ]]; then
  if [[ ! -f "$user_crt" || ! -f "$user_key" ]]; then
    die "Для своего сертификата нужны оба файла: files/tls.crt и files/tls.key."
  fi
  crt_pub="$(openssl x509 -in "$user_crt" -noout -pubkey 2>/dev/null)" ||
    die "files/tls.crt не читается: нужен сертификат в PEM."
  key_pub="$(openssl pkey -in "$user_key" -pubout -passin pass: 2>/dev/null)" ||
    die "files/tls.key не читается: нужен ключ в PEM без пароля."
  if [[ "$crt_pub" != "$key_pub" ]]; then
    die "files/tls.key не подходит к files/tls.crt."
  fi
  if ! cert_covers "$user_crt" "$bind_host"; then
    die "files/tls.crt выпущен не на ${bind_host}. Запустите с OPENBAO_API_ADDR=https://<имя из сертификата>:${PORT}"
  fi
  own_cert=1
elif [[ -s "${TLS_DIR}/tls.crt" ]] && ! cert_self_signed "${TLS_DIR}/tls.crt" &&
     ! cert_covers "${TLS_DIR}/tls.crt" "$bind_host"; then
  die "${TLS_DIR}/tls.crt выпущен не на ${bind_host}. Положите новый сертификат в files/ или задайте OPENBAO_API_ADDR с именем из сертификата."
fi

pkg_changed=0
if [[ "$family" == "deb" ]]; then
  state="$(dpkg-query -W -f '${db:Status-Abbrev}|${Version}' openbao 2>/dev/null || true)"
  current="${state#*|}"
  # The second and third letters 'i ' mean fully installed, held ('hi ') included.
  # 'rc' (removed, config left) also reports a version but has no binary.
  installed=0
  if [[ "${state:1:2}" == "i " ]]; then
    installed=1
  fi
  if [[ "$installed" -eq 1 && "$current" != "$VERSION" ]]; then
    if dpkg --compare-versions "$current" gt "$VERSION"; then
      die "Уже стоит openbao ${current}, он новее ${VERSION}. Откатывать не буду."
    fi
    if [[ "${state:0:1}" == "h" ]]; then
      die "Пакет openbao ${current} закреплён (hold). Чтобы обновить до ${VERSION}: apt-mark unhold openbao"
    fi
  fi
  if [[ "$installed" -eq 0 || "$current" != "$VERSION" ]]; then
    echo "Ставлю пакет..."
    log="$(mktemp)"
    if ! DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i "$package" >"$log" 2>&1; then
      cat "$log" >&2
      rm -f "$log"
      die "dpkg не смог поставить ${name}."
    fi
    rm -f "$log"
    pkg_changed=1
  fi
else
  current="$(rpm -q --qf '%{VERSION}' openbao 2>/dev/null || true)"
  if [[ "$current" != "$VERSION" ]]; then
    echo "Ставлю пакет..."
    log="$(mktemp)"
    if ! rpm -Uvh --nosignature "$package" >"$log" 2>&1; then
      cat "$log" >&2
      rm -f "$log"
      die "rpm не смог поставить ${name}."
    fi
    rm -f "$log"
    pkg_changed=1
  fi
fi
if [[ "$pkg_changed" -eq 1 ]]; then
  changes+=("пакет")
fi

if ! command -v bao >/dev/null 2>&1; then
  die "После установки пакета нет команды bao."
fi

# The package's postinst hands /etc/openbao to the service user. Config belongs to root.
chown root:openbao /etc/openbao
chmod 0755 /etc/openbao
if [[ -f /etc/openbao/openbao.env ]]; then
  chown root:openbao /etc/openbao/openbao.env
  chmod 0640 /etc/openbao/openbao.env
fi
install -d -o openbao -g openbao -m 0700 "$DATA_DIR"
install -d -o openbao -g openbao -m 0750 "$AUDIT_DIR"
# 0755: tls.crt is public and every user's BAO_CACERT points at it. tls.key stays 0640.
install -d -o root -g openbao -m 0755 "$TLS_DIR"

tls_changed=0
if [[ "$own_cert" -eq 1 ]]; then
  crt_new=0
  key_new=0
  put_file "$user_crt" "${TLS_DIR}/tls.crt" root:openbao 0644 && crt_new=1
  put_file "$user_key" "${TLS_DIR}/tls.key" root:openbao 0640 && key_new=1
  if [[ "$crt_new" -eq 1 || "$key_new" -eq 1 ]]; then
    echo "Беру сертификат из files/tls.crt..."
    tls_changed=1
  fi
else
  reason=""
  if [[ ! -s "${TLS_DIR}/tls.crt" || ! -s "${TLS_DIR}/tls.key" ]]; then
    reason="Выпускаю сертификат на ${bind_host}..."
  elif cert_self_signed "${TLS_DIR}/tls.crt"; then
    if ! cert_covers "${TLS_DIR}/tls.crt" "$bind_host"; then
      reason="Сертификат выпущен не на ${bind_host}, перевыпускаю..."
    elif ! openssl x509 -in "${TLS_DIR}/tls.crt" -noout -checkend 2592000 >/dev/null; then
      reason="Сертификат истекает в ближайшие 30 дней, перевыпускаю..."
    fi
  fi
  if [[ -n "$reason" ]]; then
    echo "$reason"
    if is_ipv4 "$bind_host"; then
      san="IP:${bind_host}"
    else
      san="DNS:${bind_host}"
    fi
    work="$(mktemp -d)"
    cat > "${work}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${bind_host}
[v3_req]
subjectAltName = ${san}, IP:127.0.0.1, DNS:localhost
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${work}/tls.key" -out "${work}/tls.crt" \
        -config "${work}/openssl.cnf" 2>"${work}/openssl.log"; then
      cat "${work}/openssl.log" >&2
      rm -rf "$work"
      die "openssl не смог выпустить сертификат."
    fi
    install -o root -g openbao -m 0640 "${work}/tls.key" "${TLS_DIR}/tls.key"
    install -o root -g openbao -m 0644 "${work}/tls.crt" "${TLS_DIR}/tls.crt"
    rm -rf "$work"
    tls_changed=1
  fi
  chown root:openbao "${TLS_DIR}/tls.crt" "${TLS_DIR}/tls.key"
  chmod 0644 "${TLS_DIR}/tls.crt"
  chmod 0640 "${TLS_DIR}/tls.key"
fi
if [[ "$tls_changed" -eq 1 ]]; then
  changes+=("сертификат")
fi

config_changed=0
if [[ "$write_config" -eq 1 ]]; then
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Written by install.sh on the first install or when OPENBAO_API_ADDR /
# OPENBAO_CLUSTER_ADDR sets a new address. Otherwise re-runs keep this file as it is.
ui = true
api_addr = "${api_addr}"
cluster_addr = "${cluster_addr}"

storage "raft" {
  path    = "${DATA_DIR}"
  # Never change node_id after 'bao operator init'.
  node_id = "${node_id}"
}

listener "tcp" {
  address       = "0.0.0.0:${PORT}"
  tls_cert_file = "${TLS_DIR}/tls.crt"
  tls_key_file  = "${TLS_DIR}/tls.key"
}

audit "file" "file" {
  options {
    file_path = "${AUDIT_DIR}/audit.log"
  }
}
EOF
  if put_file "$tmp" "$CONFIG" root:openbao 0640; then
    config_changed=1
    changes+=("конфиг")
  fi
  rm -f "$tmp"
else
  chown root:openbao "$CONFIG"
  chmod 0640 "$CONFIG"
  if ! grep -q '^[[:space:]]*audit[[:space:]]' "$CONFIG"; then
    echo "Внимание: в ${CONFIG} нет блока audit, журнал аудита не ведётся. Как добавить: README, раздел «Обслуживание»." >&2
  fi
fi

tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Written by install.sh: points the bao CLI at this server.
export BAO_ADDR='${api_addr}'
export BAO_CACERT='${TLS_DIR}/tls.crt'
export NO_PROXY="\${NO_PROXY:+\$NO_PROXY,}${bind_host}" no_proxy="\${no_proxy:+\$no_proxy,}${bind_host}"
EOF
put_file "$tmp" /etc/profile.d/openbao.sh root:root 0644 && changes+=("профиль bao")
if [[ -d /etc/logrotate.d ]]; then
  cat > "$tmp" <<EOF
${AUDIT_DIR}/audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0600 openbao openbao
    postrotate
        systemctl reload openbao >/dev/null 2>&1 || true
    endscript
}
EOF
  put_file "$tmp" /etc/logrotate.d/openbao root:root 0644 && changes+=("logrotate")
fi
put_file "${ROOT}/files/openbao-unseal" "$UNSEAL_BIN" root:root 0755 && changes+=("openbao-unseal")

case "${OPENBAO_AUTO_UNSEAL:-}" in
  1)
    cat > "$tmp" <<EOF
# Written by install.sh (OPENBAO_AUTO_UNSEAL=1): unseal with the key from
# ${INIT_FILE} after every start. Turn off: OPENBAO_AUTO_UNSEAL=0 ./install.sh
[Service]
ExecStartPost=-+${UNSEAL_BIN} --boot
EOF
    install -d -m 0755 "$UNIT_DIR"
    put_file "$tmp" "$DROPIN" root:root 0644 && changes+=("автоматический unseal включён")
    ;;
  0)
    if [[ -f "$DROPIN" ]]; then
      rm -f "$DROPIN"
      changes+=("автоматический unseal выключен")
    fi
    ;;
esac

# The packaged unit sets SecureBits=keep-caps. systemd 239 (EL8) applies it after
# switching to User=openbao, gets EPERM and never starts the service
# (status=213/SECUREBITS). The service holds no capabilities, so the bit is moot.
systemd_version="$(systemctl --version | awk 'NR == 1 {print $2}')"
if [[ "$systemd_version" =~ ^[0-9]+$ ]] && [[ "$systemd_version" -lt 249 ]]; then
  cat > "$tmp" <<EOF
# Written by install.sh: systemd ${systemd_version} fails SecureBits=keep-caps for User=openbao.
[Service]
SecureBits=
EOF
  install -d -m 0755 "$UNIT_DIR"
  put_file "$tmp" "$SECUREBITS_DROPIN" root:root 0644 && changes+=("юнит systemd")
fi
rm -f "$tmp"

if [[ "${OPENBAO_FIREWALL:-1}" != "0" ]]; then
  open_firewall
fi

systemctl daemon-reload
systemctl enable --quiet openbao
if ! systemctl is-active --quiet openbao; then
  echo "Запускаю OpenBao..."
  systemctl reset-failed openbao 2>/dev/null || true
  systemctl start openbao
elif [[ "$config_changed" -eq 1 || "$pkg_changed" -eq 1 ]]; then
  # A restart seals the server; the unseal step below opens it again.
  echo "Перезапускаю OpenBao..."
  systemctl reset-failed openbao 2>/dev/null || true
  systemctl restart openbao
elif [[ "$tls_changed" -eq 1 ]]; then
  # SIGHUP reloads the certificate without sealing the server.
  echo "Перечитываю сертификат..."
  systemctl reload openbao
fi

# Talk to the local listener: api_addr may be a name that does not resolve here
# or sit behind a proxy from the environment. Verify the certificate for bind_host.
listen="$(conf_value address)"
listen_host="${listen%:*}"
listen_port="${listen##*:}"
case "$listen_host" in
  "" | 0.0.0.0 | "[::]" | "::") listen_host="127.0.0.1" ;;
esac
if [[ ! "$listen_port" =~ ^[0-9]+$ ]]; then
  listen_port="$PORT"
fi
export BAO_ADDR="https://${listen_host}:${listen_port}"
export BAO_CACERT="${TLS_DIR}/tls.crt"
export BAO_TLS_SERVER_NAME="$bind_host"

echo "Жду, пока OpenBao начнёт отвечать..."
status=""
ready=0
for _ in $(seq 1 60); do
  if read_status; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  echo "$status" >&2
  die "OpenBao не отвечает на ${BAO_ADDR}. Смотрите: journalctl -u openbao -n 50"
fi

if grep -q '"initialized":[[:space:]]*false' <<<"$status"; then
  echo "Инициализирую хранилище..."
  if [[ -s "$INIT_FILE" ]]; then
    backup="${INIT_FILE}.$(date +%Y%m%d-%H%M%S)"
    mv "$INIT_FILE" "$backup"
    echo "Прежний ${INIT_FILE} сохранён как ${backup}."
  fi
  # Never redirect straight into INIT_FILE: a failed init would leave it empty.
  tmp_init="$(umask 077 && mktemp /root/.openbao-init.XXXXXX)"
  if ! BAO_CLIENT_TIMEOUT=300s bao operator init -format=table -key-shares=1 -key-threshold=1 >"$tmp_init" ||
     ! grep -q '^Unseal Key 1: ' "$tmp_init"; then
    die "bao operator init не удался. Вывод: ${tmp_init}; журнал: journalctl -u openbao -n 50"
  fi
  mv "$tmp_init" "$INIT_FILE"
  chmod 0600 "$INIT_FILE"
  changes+=("инициализация")
  read_status || true
fi

if grep -q '"sealed":[[:space:]]*true' <<<"$status"; then
  if ! "$UNSEAL_BIN"; then
    die "Сервер запечатан. Снимите печать: sudo openbao-unseal"
  fi
  changes+=("unseal")
fi

echo
echo "OpenBao работает: ${api_addr}"
echo "Интерфейс:        ${api_addr}/ui"
echo "Сертификат для клиентов: ${TLS_DIR}/tls.crt, до $(openssl x509 -in "${TLS_DIR}/tls.crt" -noout -enddate | cut -d= -f2)"
if [[ -s "$INIT_FILE" ]]; then
  echo "Ключ unseal и root token: ${INIT_FILE}"
  echo "Заберите этот файл с сервера, если ключ должен храниться отдельно."
fi
if [[ -f "$DROPIN" ]]; then
  echo "После перезагрузки печать снимается автоматически, пока есть ${INIT_FILE}."
else
  echo "После перезагрузки сервер снова sealed. Снять печать: sudo openbao-unseal"
fi
if [[ "${#changes[@]}" -gt 0 ]]; then
  printf -v joined '%s, ' "${changes[@]}"
  echo "Изменено: ${joined%, }."
else
  echo "Изменений нет."
fi
