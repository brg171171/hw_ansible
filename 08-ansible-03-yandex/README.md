# Использование Ansible: ClickHouse, Vector и LightHouse в Yandex Cloud

[Playbook](site.yml) настраивает три отдельные ВМ Debian 12 x86_64. Vector читает тестовую строку из файла и отправляет её в ClickHouse. Браузер открывает LightHouse через SSH-туннель и обращается к базе через Nginx. Открывать в интернет HTTP-порты или нативный порт ClickHouse не нужно.

## Фактически выполненные проверки

### Yandex Cloud: итоговый прогон

26 ноября 2026 года в 00:30:22 UTC запущена проверка [коммита 96015f1](https://github.com/brg171171/hw_ansible/commit/96015f1d02cb678c465ccaa1944562fe33bf3266) на трёх ВМ в зоне `ru-central1-a`. [Полная сводка трёх этапов](verification-yc.txt) содержит SHA проверенного кода и результаты по каждому узлу.

| Этап | ClickHouse: changed | Vector: changed | LightHouse: changed |
|---|---:|---:|---:|
| Прогноз `--check --diff` | 0 | 0 | 2 |
| Первое применение `--diff` в итоговом запуске | 0 | 0 | 6 |
| Повторное применение `--diff` | 0 | 0 | 0 |

Все этапы завершились с `failed=0` и `unreachable=0` на всех трёх ВМ. ClickHouse и Vector уже были настроены предыдущим применением, поэтому в секции `first` изменился только LightHouse. Секция `second` подтверждает идемпотентность всех трёх play.

Условия воспроизведения на этом стенде: из-за тайм-аутов при скачивании пакет Vector и архив LightHouse были заранее помещены в кэш целевых ВМ с проверкой SHA-256. Для установки зависимостей на ClickHouse и LightHouse использовалось доступное зеркало Debian Security.

### Локальная проверка в QEMU

До облачного запуска исходный вариант проверялся на трёх отдельных Debian 12 amd64 в QEMU с SSH и systemd. Использовался тот же `prod.yml`: переменные адресов указывали на локальные SSH-алиасы, а порт назначения ClickHouse был переопределён на `18123` для проброса QEMU.

| Проверка | ClickHouse | Vector | LightHouse |
|---|---:|---:|---:|
| Прогноз `--check --diff`, changed | 1 | 1 | 2 |
| Первый `--diff`, changed | 6 | 6 | 7 |
| Повторный `--diff`, changed | 0 | 0 | 0 |

Во всех трёх прогонах на каждом узле `failed=0`, `unreachable=0`; [вывод PLAY RECAP](verification.txt) сохранён без округления или пересчёта. Линтер `ansible-lint 25.9.2` для `site.yml` выдал 0 ошибок и 0 предупреждений; `--syntax-check` прошёл. Nginx вернул страницу с `<title>LightHouse</title>`, а запрос через `/clickhouse/` вернул строку `ansible-lab-ready`, доставленную Vector.

## Что делает каждый play

| Группа / тег | Результат |
|---|---|
| `clickhouse` | Устанавливает сервер и клиент из репозитория Debian; включает службу, настраивает IPv4 и создаёт базу `logs` с таблицей `events(message String)`, только если их ещё нет. |
| `vector` | Скачивает закреплённый DEB с проверкой SHA-256, валидирует YAML перед заменой конфига и включает службу. Источник: `/var/log/vector-lab.log`; назначение: `logs.events`. |
| `lighthouse` | Устанавливает Nginx, скачивает и проверяет архив [VKCOM/LightHouse](https://github.com/VKCOM/lighthouse), распаковывает статику в каталог с SHA коммита, отключает стандартный сайт и применяет [шаблон Nginx](templates/lighthouse.conf.j2). Проверяет `nginx -t`, заголовок страницы и ответ на `SELECT 1` через прокси. |

Порядок первого запуска: ClickHouse, затем Vector, затем LightHouse. Для повторной настройки одного компонента используйте, например, `--tags lighthouse`; база к этому моменту должна быть доступна. Для учебной изолированной сети используется штатная учётная запись ClickHouse без пароля. Для общего или промышленного контура нужны отдельные пользователи, пароли, TLS и более узкие права.

## Подготовка трёх ВМ

Нужны настроенный профиль `yc` с выбранным каталогом, существующие VPC и подсеть в одной зоне, публичный SSH-ключ, Bash и `jq`. Команды ниже создают **платные ресурсы**. Сначала проверьте каталог, подставьте свои значения и убедитесь, что имена `a08-*` свободны. Код рассчитан на однократное создание, а не на повторное применение; если оно прервалось, проверьте список ресурсов перед продолжением.

```bash
yc config get folder-id
yc vpc subnet list
yc compute instance list
yc vpc security-group list
```

```bash
# Выполнять в Bash после замены значений в угловых скобках.
(
  set -euo pipefail
  SUBNET_ID='<id-подсети>'
  ADMIN_CIDR='<публичный-IPv4-управляющей-машины>/32'
  SSH_PUB="$HOME/.ssh/id_ed25519.pub"
  test -s "$SSH_PUB"
  subnet=$(yc vpc subnet get "$SUBNET_ID" --format json)
  zone=$(jq -er '.zone_id' <<< "$subnet")
  network=$(jq -er '.network_id' <<< "$subnet")

  sg=$(yc vpc security-group create --name a08-sg --network-id "$network" \
    --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[$ADMIN_CIDR]" \
    --rule "direction=ingress,port=8123,protocol=tcp,predefined=self_security_group" \
    --rule 'direction=egress,protocol=any,from-port=0,to-port=65535,v4-cidrs=[0.0.0.0/0]' \
    --format json | jq -er '.id')

  for role in clickhouse vector lighthouse; do
    yc compute instance create --name "a08-$role" --hostname "a08-$role" \
      --zone "$zone" --cores 2 --memory 2GB --core-fraction 20 \
      --create-boot-disk 'image-folder-id=standard-images,image-family=debian-12,size=15GB,type=network-hdd,auto-delete=true' \
      --network-interface "subnet-id=$SUBNET_ID,nat-ip-version=ipv4,security-group-ids=$sg" \
      --ssh-key "$SSH_PUB"
  done
)
```

Основа команд: [создание Linux-ВМ](https://yandex.cloud/en/docs/compute/operations/vm-create/create-linux-vm) и [правила групп безопасности](https://yandex.cloud/en/docs/vpc/operations/security-group-create). Используйте группу только для этих трёх узлов. SQL через прокси не требует пароля, поэтому Nginx намеренно слушает только loopback.

## Inventory и параметры

Запускайте команды из каталога `08-ansible-03-yandex`. В [prod.yml](prod.yml) три группы, три узла и пользователь `yc-user`. Адреса не хранятся в Git. Если ВМ созданы командами выше, прочитайте их адреса из активного каталога YC:

```bash
# Сначала выполнить скрипт успешно, только потом импортировать результат.
yc_env=$(bash yc-inventory.sh) && eval "$yc_env"
```

Для существующего стенда вместо скрипта задайте четыре переменные окружения вручную: `CH_HOST`, `VECTOR_HOST`, `LH_HOST` (адреса или SSH-алиасы с машины управления) и `CH_PRIVATE_IP` (адрес ClickHouse внутри VPC, видимый двум другим ВМ). После пересоздания ВМ обновите значения. Ключ передаётся через SSH-agent или флаг `--private-key`; проверку ключей хостов не отключайте. Перед первым соединением сверьте их отпечатки по доверенному каналу.

| Параметр из [group_vars/all.yml](group_vars/all.yml) | Значение и назначение |
|---|---|
| `clickhouse_endpoint_host` | По умолчанию `CH_PRIVATE_IP`; адрес назначения для Vector и прокси Nginx. |
| `clickhouse_endpoint_port` | `8123`; порт назначения для клиентов. Если менять его, нужен соответствующий listener или перенаправление. |
| `vector_version`, `vector_sha256` | Версия пакета `0.50.0-1` и ожидаемая контрольная сумма. Меняются парой. |
| `lighthouse_revision`, `lighthouse_sha256` | Полный SHA коммита статики и SHA-256 архива. Меняются парой. |
| `lighthouse_port` | `8080`; локальный порт Nginx на ВМ LightHouse. При переопределении обновите SSH-туннель. |

Для разового переопределения параметров используйте `-e`, например `-e lighthouse_port=8081`. Для другого SSH-пользователя переопределите `ansible_user` в inventory либо через `-e ansible_user=...`.

## Проверка задания

### Запуск проверки в Yandex Cloud

На управляющей машине с настроенным `yc` можно воспроизвести именно облачную проверку: выберите коммит из протокола, как показано ниже. Скрипт запишет SHA фактически проверенной версии в отчёт.

```bash
git clone https://github.com/brg171171/hw_ansible.git
cd hw_ansible
git switch --detach 96015f1d02cb678c465ccaa1944562fe33bf3266
cd 08-ansible-03-yandex
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Создайте три ВМ по разделу выше, подключите свой ключ к SSH-agent, проверьте отпечатки SSH и завершение cloud-init. Если APT ещё не получил индексы пакетов, выполните на каждой новой ВМ `sudo apt-get update` перед первым dry-run. Укажите ID выделенного каталога из консоли YC, не токен:

```bash
FOLDER_ID='замените-на-id-каталога-стенда'
bash test-yc.sh check "$FOLDER_ID"    # Не применяет playbook
bash test-yc.sh apply "$FOLDER_ID"    # Повторяет check, затем два реальных --diff
```

[Скрипт](test-yc.sh) не создаёт и не удаляет облачные ресурсы. Он сверяет каталог, получает адреса трёх работающих ВМ по именам, проверяет SSH, линтер и синтаксис. В режиме `apply` ненулевой `changed` хотя бы на одном хосте при повторном запуске считается ошибкой. На уже настроенном стенде даже первый реальный запуск может дать ноль изменений.

Для сдачи используйте этот README и [облачный протокол](verification-yc.txt). При самостоятельном запуске файл `recap.txt` сохраняется в каталоге, который напечатает скрипт. Полные логи могут содержать IP и пути; каталог `.local/` игнорируется Git.

### Ручной запуск

На управляющей машине используйте Python 3.11 или новее из поддерживаемых Ansible версий (проверочный интерпретатор: Python 3.12). Новым ВМ дайте завершить cloud-init и убедитесь, что индексы APT доступны; на совсем пустом кэше перед первым dry-run выполните `sudo apt-get update` на ВМ.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt

ansible-inventory -i prod.yml --graph
ansible all -i prod.yml -m ping
ansible-lint site.yml
ansible-playbook -i prod.yml site.yml --syntax-check
ansible-playbook -i prod.yml site.yml --list-tags

# Логи хранятся локально: diff может включать адреса инфраструктуры.
set -o pipefail
ansible-playbook -i prod.yml site.yml --check --diff | tee check.log
ansible-playbook -i prod.yml site.yml --diff | tee first.log
ansible-playbook -i prod.yml site.yml --diff | tee second.log
```

На чистой машине check mode не устанавливает пакеты и не оставляет скачанные файлы. Поэтому зависящие от этих файлов задачи пропускаются, а SQL и HTTP не выполняются. Это прогноз, не подтверждение развёртывания. Первый обычный запуск должен показать изменения; критерий повторного запуска без дрейфа: `changed=0 failed=0 unreachable=0` у каждого узла.

## Как проверить результат

```bash
# Дождитесь появления строки от Vector (обычно несколько секунд).
ssh "yc-user@$CH_HOST" \
  "clickhouse-client --query \"SELECT message FROM logs.events WHERE message='ansible-lab-ready' LIMIT 1\""

# Туннель держите открытым в отдельном терминале.
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:8080:127.0.0.1:8080 "yc-user@$LH_HOST"
```

Откройте [LightHouse через туннель](http://127.0.0.1:8080/). В поле **Host** укажите `http://127.0.0.1:8080/clickhouse` без завершающего слеша, выберите базу `logs` и выполните `SELECT message FROM logs.events LIMIT 10`. Так запросы идут через тот же origin, что и статика, а внутренний адрес базы браузеру не требуется.

После сдачи проверьте, нужны ли ещё ВМ. Если стенд больше не нужен, удалите **только созданные для этой работы** три экземпляра, затем их группу `a08-sg`; существующую сеть и подсеть не удаляйте. Проверьте в каталоге, что не осталось платных дисков и зарезервированных адресов стенда.
