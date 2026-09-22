# OpenBao в закрытом контуре

Ansible ставит OpenBao 2.6.2 на Debian, Ubuntu или RHEL-подобную систему с локального пакета. Во время прогона целевой хост и управляющая машина в интернет не ходят.

Пакет — это бинарник `bao`, пользователь `openbao` и systemd-unit. Единственная зависимость пакета — уже установленный в ОС `openssl`. Служба хранит данные в Raft на `/opt/openbao/data`, слушает `0.0.0.0:8200` по TLS и поднимается в состоянии sealed.

## Что пронести в контур

На машине с интернетом, до переноса:

```bash
curl -fL -O https://github.com/openbao/openbao/releases/download/v2.6.2/openbao_2.6.2_linux_amd64.deb
curl -fL -O https://github.com/openbao/openbao/releases/download/v2.6.2/checksums.txt
sha256sum --ignore-missing -c checksums.txt
```

Для rpm-систем скачивается `openbao_2.6.2_linux_amd64.rpm`. Для ARM в имени `arm64` вместо `amd64`. Строка проверки должна закончиться на `OK`. Тот же хеш сверяется ещё раз внутри контура: playbook читает `files/checksums.txt`.

Рядом кладётся сертификат внутреннего удостоверяющего центра. Имя в сертификате совпадает с именем в `openbao_api_addr`.

```text
files/openbao_2.6.2_linux_amd64.deb
files/checksums.txt
files/tls.crt
files/tls.key
```

`openssl` на сервере берётся с установочного носителя ОС. Роль его из сети не ставит. Подпись rpm в базу ключей не импортируется: перед установкой playbook сверяет sha256, затем ставит пакет с `--nosignature`.

## Запуск

```bash
cp inventory/hosts.ini.example inventory/hosts.ini
ansible-playbook openbao.yml
```

В `inventory/hosts.ini` указываются адрес SSH, `openbao_api_addr` и `openbao_cluster_addr`. Пример лежит в `inventory/hosts.ini.example`.

## После установки

Инициализация выполняется один раз вручную. Вывод содержит unseal-ключи и root token, поэтому в playbook её нет.

```bash
export BAO_ADDR='https://bao.example.com:8200'
bao operator init
bao operator unseal
bao status
```

По умолчанию OpenBao делит ключ на 5 долей с порогом 3. После перезапуска сервис снова sealed, и unseal повторяется. Повторный прогон playbook при смене конфига или сертификата тоже перезапускает сервис и запечатывает его.

Пакет при первой установке сам создаёт самоподписанный сертификат в `/opt/openbao/tls`. Рабочий слушатель его не использует: сертификат контура лежит в `/etc/openbao/tls`.
