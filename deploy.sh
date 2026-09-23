#!/bin/bash
# Copy the installer to a machine inside the closed network and run it there.
#   ./deploy.sh root@10.0.0.5
#   ./deploy.sh admin@10.0.0.5                     not root: install.sh runs through sudo
#   OPENBAO_API_ADDR=https://10.0.0.5:8200 ./deploy.sh admin@10.0.0.5
# OPENBAO_API_ADDR, OPENBAO_CLUSTER_ADDR, OPENBAO_FIREWALL and OPENBAO_AUTO_UNSEAL
# are passed on to install.sh. Only the files install.sh needs are sent, to
# ~/openbao-install on the target; no tar is needed there. Works with the stock
# macOS /bin/bash 3.2.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR="openbao-install"   # relative to the remote user's home directory
# One place for the version: install.sh.
VERSION="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "${ROOT}/install.sh")"
if [[ -z "$VERSION" ]]; then
  echo "Не нашёл VERSION в ${ROOT}/install.sh." >&2
  exit 1
fi

if [[ $# -ne 1 || "$1" == -* ]]; then
  echo "Использование: ./deploy.sh root@10.0.0.5   (на самой машине: sudo ./install.sh)" >&2
  exit 1
fi
target="$1"

# One SSH connection for every step: one password prompt instead of one per file.
# /tmp, not $TMPDIR: the macOS $TMPDIR is too long for a socket path.
ctl_dir="$(mktemp -d /tmp/openbao-deploy.XXXXXX)"
ssh_opts=(-o ControlMaster=auto -o "ControlPath=${ctl_dir}/%C" -o ControlPersist=120)
cleanup() {
  ssh "${ssh_opts[@]}" -O exit "$target" >/dev/null 2>&1 || true
  rm -rf "$ctl_dir"
}
trap cleanup EXIT
# rsh -n|-t|-T COMMAND
rsh() {
  local flag="$1"
  shift
  ssh "${ssh_opts[@]}" "$flag" "$target" "$@"
}

echo "Подключаюсь к ${target}..."
info="$(rsh -n 'if [ -f /etc/debian_version ]; then f=deb; elif [ -f /etc/redhat-release ] || [ -f /etc/fedora-release ]; then f=rpm; else f=none; fi
  if [ "$(id -u)" -eq 0 ]; then s=root; elif ! command -v sudo >/dev/null 2>&1; then s=none; elif sudo -n true 2>/dev/null; then s=nopass; else s=pass; fi
  echo "$f $(uname -m) $s"')"
read -r family remote_arch sudo_mode <<<"$info"
if [[ "$family" != "deb" && "$family" != "rpm" ]]; then
  echo "На ${target} не Debian/Ubuntu и не RHEL-подобная система." >&2
  exit 1
fi
if [[ "$remote_arch" != "x86_64" ]]; then
  echo "На ${target} архитектура ${remote_arch}, а пакеты только для x86_64." >&2
  exit 1
fi
if [[ "$sudo_mode" == "none" ]]; then
  echo "На ${target} нет sudo. Зайдите под root: ./deploy.sh root@<адрес>" >&2
  exit 1
fi
if [[ "$sudo_mode" == "pass" && ! -t 0 ]]; then
  echo "sudo на ${target} спрашивает пароль, а терминала нет. Запустите из терминала или зайдите под root." >&2
  exit 1
fi

send=(install.sh files/checksums.txt files/openbao-unseal "files/openbao_${VERSION}_linux_amd64.${family}")
if [[ -f "${ROOT}/files/tls.crt" || -f "${ROOT}/files/tls.key" ]]; then
  send+=(files/tls.crt files/tls.key)
fi
for f in "${send[@]}"; do
  if [[ ! -f "${ROOT}/${f}" ]]; then
    echo "Нет файла ${ROOT}/${f}." >&2
    exit 1
  fi
done

# A fresh private directory each time, so nothing is left over from an earlier deploy.
rsh -n "umask 077 && rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}/files"
for f in "${send[@]}"; do
  echo "Копирую ${f}..."
  # -T, not -t: a terminal would mangle the binary stream.
  rsh -T "umask 077 && cat > ${REMOTE_DIR}/${f}" < "${ROOT}/${f}"
done

cmd="bash ${REMOTE_DIR}/install.sh"   # bash, not ./install.sh: works on a noexec home
for v in OPENBAO_API_ADDR OPENBAO_CLUSTER_ADDR OPENBAO_FIREWALL OPENBAO_AUTO_UNSEAL; do
  if [[ -n "${!v:-}" ]]; then
    cmd="${v}=$(printf '%q' "${!v}") ${cmd}"
  fi
done
cmd="env ${cmd}"
if [[ "$sudo_mode" != "root" ]]; then
  cmd="sudo ${cmd}"
fi

# -t for sudo's password prompt. -n without a terminal, so a loop like
# 'while read h; do ./deploy.sh "$h"; done < hosts' keeps its stdin.
tty_flag=-n
if [[ -t 0 ]]; then
  tty_flag=-t
fi
echo "Запускаю install.sh на ${target}..."
rc=0
rsh "$tty_flag" "$cmd" || rc=$?
# The certificate is in /etc/openbao/tls now; keep no second copy of the key in a home directory.
rsh -n "chmod 700 ${REMOTE_DIR}/install.sh; rm -f ${REMOTE_DIR}/files/tls.crt ${REMOTE_DIR}/files/tls.key" || true
if [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi
echo "Установщик остался на сервере. Повторить там: sudo bash ~/${REMOTE_DIR}/install.sh"
