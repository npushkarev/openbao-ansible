#!/bin/bash
# Run install.sh in throwaway systemd containers and check what it leaves behind.
# Needs Docker. On an arm64 host (Apple Silicon) the amd64 images run under qemu,
# which is slow and cannot run systemd 257 sandboxing (Debian 13). With the arm64
# packages of the same release in files/ the tests run natively instead.
#   tests/run.sh                          every system below
#   tests/run.sh debian:12 rockylinux:9   only these

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  systems=("$@")
else
  systems=(debian:12 debian:13 ubuntu:22.04 ubuntu:24.04 rockylinux:8 rockylinux:9)
fi

arch=amd64
case "$(uname -m)" in
  arm64 | aarch64)
    if ls "${ROOT}"/files/openbao_*_linux_arm64.deb "${ROOT}"/files/openbao_*_linux_arm64.rpm >/dev/null 2>&1; then
      arch=arm64
    fi
    ;;
esac
echo "Архитектура: ${arch}"

failures=0
c=""

# ct COMMAND: run in the container as root in a login shell (profile.d applies).
ct() { docker exec "$c" bash -lc "$1"; }
check() {
  local name="$1" log
  log="$(mktemp)"
  if ct "$2" >"$log" 2>&1; then
    echo "  ok    ${name}"
  else
    echo "  FAIL  ${name}"
    sed 's/^/        /' "$log" | tail -n 20
    failures=$((failures + 1))
  fi
  rm -f "$log"
}

unsealed='bao status -format=json | grep -q "\"sealed\": false"'
wait_unsealed='for i in $(seq 1 60); do bao status -format=json 2>/dev/null | grep -q "\"sealed\": false" && exit 0; sleep 2; done; exit 1'
# reset-failed: the unit allows 3 starts a minute, and the checks restart it often.
restart='systemctl reset-failed openbao; systemctl restart openbao'
token='export BAO_TOKEN="$(awk -F": " "/^Initial Root Token:/ {print \$2; exit}" /root/openbao-init.txt)"'

for system in "${systems[@]}"; do
  image="openbao-test:${system//[:\/]/-}-${arch}"
  echo "== ${system}"
  if ! docker build -q --platform "linux/${arch}" --build-arg "BASE=${system}" -t "$image" "${ROOT}/tests" >/dev/null; then
    echo "  FAIL  образ не собрался"
    failures=$((failures + 1))
    continue
  fi
  c="openbao-test-${system//[:\/.]/-}-${arch}"
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker run -d --name "$c" --platform "linux/${arch}" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "${ROOT}:/src:ro" "$image" >/dev/null
  ct 'for i in $(seq 1 60); do s=$(systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ] && break; sleep 1; done
      mkdir /opt/ob && cd /src && cp -a install.sh /opt/ob/ && mkdir /opt/ob/files &&
      cp -a files/checksums.txt files/openbao-unseal files/openbao_*_linux_'"${arch}"'.* /opt/ob/files/'
  if [[ "$arch" == "arm64" ]]; then
    ct 'sed -i -e "s/!= \"x86_64\"/!= \"aarch64\"/" -e "s/linux_amd64/linux_arm64/g" /opt/ob/install.sh'
  fi

  check "первая установка" 'cd /opt/ob && ./install.sh'
  check "сервер распечатан" "$unsealed"
  check "повторный запуск ничего не меняет" 'cd /opt/ob && ./install.sh | grep -qxF "Изменений нет."'
  check "секрет записан" "$token"' && bao secrets enable -path=kv kv-v2 && bao kv put kv/t v=42'
  check "аудит пишется" 'test -s /var/log/openbao/audit.log'
  check "после рестарта install.sh снимает печать" "$restart && cd /opt/ob && ./install.sh && $unsealed"
  check "после рестарта openbao-unseal снимает печать" "$restart && openbao-unseal && $unsealed"
  check "обычному пользователю виден сервер" 'useradd -m tester && su - tester -c "bao status"'
  # A bao wrapper earlier in PATH records every command line; the key must not be in it.
  check "ключ не попадает в командную строку" 'printf "#!/bin/sh\necho \"\$*\" >> /tmp/bao-argv\nexec /usr/bin/bao \"\$@\"\n" > /usr/local/bin/bao &&
    chmod +x /usr/local/bin/bao && systemctl reset-failed openbao; systemctl restart openbao && openbao-unseal &&
    key="$(awk -F": " "/^Unseal Key 1:/ {print \$2; exit}" /root/openbao-init.txt)" && test -s /tmp/bao-argv &&
    ! grep -qF "$key" /tmp/bao-argv; rc=$?; rm -f /usr/local/bin/bao /tmp/bao-argv; exit $rc'
  check "автоматический unseal после падения" "cd /opt/ob && OPENBAO_AUTO_UNSEAL=1 ./install.sh &&
    kill -9 \$(systemctl show -p MainPID --value openbao) && sleep 3 && $wait_unsealed"
  check "смена адреса перевыпускает сертификат" "ip addr add 10.99.0.5/32 dev eth0 && cd /opt/ob &&
    OPENBAO_API_ADDR=https://10.99.0.5:8200 ./install.sh &&
    openssl x509 -in /etc/openbao/tls/tls.crt -noout -checkip 10.99.0.5 | grep -q 'does match' &&
    grep -q 'node_id = \"node1\"' /etc/openbao/openbao.hcl && . /etc/profile.d/openbao.sh && $unsealed && $token && bao kv get -field=v kv/t | grep -qx 42"
  check "адрес переживает повторный запуск" "cd /opt/ob && ./install.sh | grep -qxF 'Изменений нет.' && grep -q 10.99.0.5 /etc/openbao/openbao.hcl"
  check "тот же адрес в переменной не трогает конфиг" "cd /opt/ob && OPENBAO_API_ADDR=https://10.99.0.5:8200 ./install.sh | grep -qxF 'Изменений нет.'"
  check "комментарии в конфиге не сбивают адрес и node_id" "sed -i -e 's/^\\(api_addr = .*\\)$/\\1   # согласовано/' \
      -e 's/^\\( *node_id = .*\\)$/\\1   # не менять/' /etc/openbao/openbao.hcl && grep -q 'не менять' /etc/openbao/openbao.hcl &&
    cd /opt/ob && ./install.sh | grep -qxF 'Изменений нет.' && grep -q 'node_id = \"node1\"   # не менять' /etc/openbao/openbao.hcl"
  check "неверное значение флага отклоняется" "cd /opt/ob && ! OPENBAO_FIREWALL=no ./install.sh"
  check "свой сертификат подхватывается без рестарта" 'cd /opt/ob/files && d=$(mktemp -d) &&
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=test-ca -keyout $d/ca.key -out $d/ca.crt 2>/dev/null &&
    printf "subjectAltName=IP:10.99.0.5\n" > $d/ext &&
    openssl req -newkey rsa:2048 -nodes -subj /CN=10.99.0.5 -keyout tls.key -out $d/tls.csr 2>/dev/null &&
    openssl x509 -req -in $d/tls.csr -CA $d/ca.crt -CAkey $d/ca.key -CAcreateserial -days 30 -extfile $d/ext -out tls.crt 2>/dev/null &&
    pid=$(systemctl show -p MainPID --value openbao) &&
    cd /opt/ob && ./install.sh | grep -qxF "Изменено: сертификат." &&
    [ "$pid" = "$(systemctl show -p MainPID --value openbao)" ] &&
    served=$(openssl s_client -connect 127.0.0.1:8200 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint) &&
    [ "$served" = "$(openssl x509 -in files/tls.crt -noout -fingerprint)" ] && '"$unsealed"
  if [[ "$system" == debian* || "$system" == ubuntu* ]]; then
    check "пакет на hold не переустанавливается" "apt-mark hold openbao >/dev/null && cd /opt/ob &&
      ./install.sh | grep -qxF 'Изменений нет.'; rc=\$?; apt-mark unhold openbao >/dev/null; exit \$rc"
    check "пакет в состоянии rc ставится заново" "systemctl stop openbao && dpkg -r openbao >/dev/null &&
      cd /opt/ob && ./install.sh && $unsealed"
  fi

  docker rm -f "$c" >/dev/null
done

if [[ "$failures" -gt 0 ]]; then
  echo "Не прошло проверок: ${failures}"
  exit 1
fi
echo "Все проверки прошли."
