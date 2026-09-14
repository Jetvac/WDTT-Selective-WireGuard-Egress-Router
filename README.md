# WDTT Selective WireGuard Egress Router

`wdtt-egress-router.sh` — скрипт для выборочной маршрутизации интернет-трафика клиентов WDTT через отдельный WireGuard egress-сервер без изменения основного маршрута VPS.

Это позволяет оставить SSH, 3x-ui/VLESS, веб-панели и другие сервисы на штатном интернет-канале сервера, а только сеть клиентов WDTT направить через другой VPS.

Скрипт управляет policy routing, scoped `iptables`-правилами и SNAT, восстанавливает маршрутизацию после рестарта WDTT, а также умеет проверять и обновлять нативную systemd-установку WDTT до последнего стабильного релиза server core из [`XXcipherX/proxy-turn-vk-android`](https://github.com/XXcipherX/proxy-turn-vk-android).

**Репозиторий:** https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router  
**Готовый скрипт:** https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router/releases/download/release/wdtt-egress-router.sh

> Проект не связан с VK, XXcipherX, 3x-ui или WireGuard и не является их официальным компонентом.

## Возможности

- выборочная маршрутизация только сети клиентов WDTT;
- отдельная policy-routing table без изменения системной таблицы `main`;
- SNAT трафика WDTT в адрес WireGuard-клиента;
- kill switch: трафик WDTT не уходит напрямую через основной интерфейс при нарушении заданного маршрута;
- совместная работа с 3x-ui/VLESS и другими сервисами на том же VPS;
- автоматическое восстановление правил после рестарта `wdtt.service`;
- проверка WireGuard egress до применения маршрутов;
- включение и отключение маршрутизации без удаления WDTT и WireGuard;
- полное удаление только тех правил, которые создал этот скрипт;
- просмотр установленной версии WDTT и последнего стабильного релиза;
- обновление WDTT до последнего стабильного релиза с резервным копированием и попыткой автоматического отката при ошибке.

## Архитектура

Типовая схема:

```text
                         ┌────────────────────────────────────┐
                         │          основной VPS              │
                         │                                    │
Internet / VK TURN ─────►│ WDTT server                        │
                         │      │                             │
                         │      ▼                             │
                         │    wdtt0                           │
                         │  10.66.66.0/24                     │
                         │      │                             │
                         │      │ policy routing              │
                         │      ▼                             │
                         │    wg-de ──────────────────────────┼────► WireGuard egress VPS ───► Internet
                         │                                    │
                         │ SSH / 3x-ui / VLESS / system       │
                         │      │                             │
                         │      ▼                             │
                         │    eth0 ───────────────────────────┼────► обычный Internet uplink
                         └────────────────────────────────────┘
```

Главный принцип: policy rule применяется только к пакетам с source-адресами из сети WDTT.

По умолчанию:

```text
WDTT interface:       wdtt0
WDTT client network:  10.66.66.0/24
WireGuard interface:  wg-de
WireGuard IPv4:       10.8.1.3
Routing table:        51888
Rule priority:        10666
```

В результате обычный трафик самого VPS продолжает использовать штатный default route, а трафик клиентов WDTT получает отдельный egress через WireGuard.

## Как работает маршрутизация

При включении скрипт создаёт отдельное policy rule:

```text
from 10.66.66.0/24 lookup 51888
```

В таблице `51888` создаётся маршрут:

```text
default dev wg-de
```

Поэтому пакет клиента WDTT:

```text
10.66.66.x -> wdtt0 -> table 51888 -> wg-de
```

уходит через WireGuard.

При этом обычный пакет самого VPS не соответствует правилу `from 10.66.66.0/24` и продолжает обрабатываться через системную таблицу `main`.

Пример:

```text
VPS / 3x-ui / SSH:
1.1.1.1 via <MAIN_GATEWAY> dev eth0

WDTT client:
1.1.1.1 from 10.66.66.2 dev wg-de table 51888
```

## SNAT

Перед отправкой пакетов в WireGuard выполняется SNAT:

```text
10.66.66.x -> 10.8.1.3
```

Полный путь выглядит так:

```text
WDTT client
10.66.66.2
    │
    │ SNAT
    ▼
10.8.1.3
    │
    │ WireGuard
    ▼
egress VPS
    │
    │ NAT egress-сервера
    ▼
Internet
```

Это позволяет использовать уже существующий WireGuard peer, у которого на egress-сервере разрешён только адрес клиента, например:

```text
AllowedIPs = 10.8.1.3/32
```

Добавлять всю сеть `10.66.66.0/24` в `AllowedIPs` удалённого peer в таком варианте не требуется.

## Kill switch

Скрипт создаёт отдельную цепочку `WDTT_EGRESS_DE`.

Она разрешает:

```text
wdtt0 -> wg-de
wg-de -> wdtt0  RELATED,ESTABLISHED
```

и завершает обработку исходящего трафика WDTT правилом `DROP`.

Это не позволяет клиентскому трафику WDTT незаметно переключиться на основной uplink VPS, если требуемый путь через WireGuard перестал использоваться.

Проверить счётчики:

```bash
sudo iptables -vnL WDTT_EGRESS_DE
```

## Что скрипт не изменяет

Скрипт специально ограничен собственными объектами маршрутизации и firewall.

Он не должен:

- заменять основной `default route` VPS;
- менять routing table `main`;
- менять `INPUT`;
- менять `OUTPUT`;
- очищать системные или сторонние `iptables`-цепочки;
- менять конфигурацию 3x-ui;
- менять конфигурацию VLESS/Xray;
- удалять или останавливать WireGuard при `disable` или `uninstall`;
- удалять WDTT при `disable` или `uninstall`.

Перед применением правил скрипт проверяет текущий маршрут самого VPS. Если обычный host traffic уже использует выбранный WireGuard-интерфейс, применение прекращается.

После применения дополнительно проверяется, что системный default route не изменился.

## Требования

Поддерживается нативная systemd-установка WDTT.

На VPS должны быть доступны:

- Linux с systemd;
- `iproute2`;
- `iptables`;
- `wireguard-tools`;
- `curl`;
- `awk`, `grep`, `sed`;
- работающий `wdtt.service`;
- существующий интерфейс `wdtt0` или другой указанный WDTT-интерфейс;
- заранее настроенный WireGuard-клиент до egress-сервера.

Для функции обновления WDTT дополнительно требуются:

- `git`;
- `bash`;
- `sha256sum`;
- доступ к GitHub и `raw.githubusercontent.com`.

## Подготовка WireGuard

WireGuard должен быть настроен заранее.

Пример клиентского профиля на сервере с WDTT:

```ini
[Interface]
Address = 10.8.1.3/32
PrivateKey = <PRIVATE_KEY>
Table = off

[Peer]
PublicKey = <EGRESS_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
AllowedIPs = 0.0.0.0/0
Endpoint = <EGRESS_IP>:44950
PersistentKeepalive = 25
```

### `Table = off`

Для этой схемы рекомендуется использовать:

```ini
Table = off
```

Это запрещает `wg-quick` автоматически создавать default route на основании:

```ini
AllowedIPs = 0.0.0.0/0
```

Маршруты WDTT вместо этого создаёт `wdtt-egress-router.sh` в отдельной policy table.

Запуск WireGuard:

```bash
sudo systemctl enable --now wg-quick@wg-de
```

Проверка:

```bash
ip -br addr show wg-de
wg show wg-de
```

Перед дальнейшей настройкой должен быть виден успешный WireGuard handshake.

## Установка

Рекомендуемый способ — скачать готовый `wdtt-egress-router.sh` из GitHub Releases и установить его в `/usr/local/sbin`.

```bash
curl -fL   https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router/releases/download/release/wdtt-egress-router.sh   -o /tmp/wdtt-egress-router.sh

bash -n /tmp/wdtt-egress-router.sh
sudo install -m 0755 /tmp/wdtt-egress-router.sh /usr/local/sbin/wdtt-egress-router.sh
rm -f /tmp/wdtt-egress-router.sh
```

Проверьте установку:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh --help
```

Альтернативно можно клонировать репозиторий:

```bash
git clone https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router.git
cd WDTT-Selective-WireGuard-Egress-Router
sudo install -m 0755 wdtt-egress-router.sh /usr/local/sbin/wdtt-egress-router.sh
```

### Установка со стандартными параметрами

Если используются значения по умолчанию:

```text
WireGuard interface:  wg-de
WireGuard IPv4:       10.8.1.3
WDTT interface:       wdtt0
WDTT network:         10.66.66.0/24
```

выполните:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh install
```

Перед применением скрипт:

1. проверит наличие WireGuard и WDTT-интерфейсов;
2. проверит WireGuard handshake;
3. проверит, что обычный трафик VPS не использует выбранный WireGuard-интерфейс;
4. проверит конфликты policy-routing table и `ip rule`;
5. проверит доступ в интернет через WireGuard;
6. сохранит конфигурацию;
7. установит systemd persistence;
8. применит policy route, FORWARD и SNAT;
9. повторно проверит основной маршрут VPS.

### Установка с собственными параметрами

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh install     --wg-if wg-de     --wg-ip 10.8.1.3     --wdtt-if wdtt0     --wdtt-net 10.66.66.0/24     --probe-ip 10.66.66.2     --table 51888     --rule-pref 10666
```

Доступные параметры:

| Параметр | Назначение | По умолчанию |
| --- | --- | --- |
| `--wg-if NAME` | WireGuard egress-интерфейс | `wg-de` |
| `--wg-ip IPv4` | локальный IPv4 WireGuard | `10.8.1.3` |
| `--wdtt-if NAME` | интерфейс WDTT | `wdtt0` |
| `--wdtt-net CIDR` | сеть клиентов WDTT | `10.66.66.0/24` |
| `--probe-ip IPv4` | адрес из WDTT-сети для диагностики | `10.66.66.2` |
| `--table NUMBER` | отдельная policy-routing table | `51888` |
| `--rule-pref NUMBER` | priority policy rule | `10666` |
| `--skip-egress-test` | не выполнять предварительный интернет-тест WireGuard | выключено |

`--skip-egress-test` рекомендуется использовать только для диагностики или если `api.ipify.org` недоступен намеренно.

### Обновление самого скрипта

Чтобы заменить локальную копию на версию из опубликованного релиза:

```bash
curl -fL   https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router/releases/download/release/wdtt-egress-router.sh   -o /tmp/wdtt-egress-router.sh

bash -n /tmp/wdtt-egress-router.sh
sudo install -m 0755 /tmp/wdtt-egress-router.sh /usr/local/sbin/wdtt-egress-router.sh
rm -f /tmp/wdtt-egress-router.sh
```

Сохранённая конфигурация в `/etc/wdtt-egress-router.conf` при этом не изменяется.

После обновления рекомендуется проверить состояние:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh status
```

## Команды

### `install`

Сохраняет конфигурацию, включает автоматическое применение и настраивает маршрутизацию:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh install [options]
```

Команда идемпотентна и может использоваться повторно.

### `reconfigure`

Изменяет сохранённые параметры и заново применяет конфигурацию:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh reconfigure \
    --wg-if wg-de \
    --wg-ip 10.8.1.3 \
    --wdtt-if wdtt0 \
    --wdtt-net 10.66.66.0/24
```

При отсутствии новых параметров используются значения из `/etc/wdtt-egress-router.conf`.

### `status`

Показывает текущее состояние:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh status
```

Вывод содержит:

- сохранённые параметры;
- состояние persistence;
- основной маршрут VPS;
- policy rule;
- содержимое отдельной routing table;
- `wg show`;
- счётчики `WDTT_EGRESS_DE`;
- FORWARD jumps;
- scoped SNAT;
- состояние `wdtt.service`.

### `probe`

Проверяет интернет через WireGuard без замены системного default route:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh probe
```

При успешной проверке выводится публичный IPv4 egress-сервера.

### `apply`

Повторно применяет сохранённую конфигурацию:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh apply
```

Обычно вручную запускать эту команду не требуется. Она используется systemd после старта WDTT.

### `disable`

Отключает созданную скриптом выборочную маршрутизацию:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh disable
```

Удаляются:

- policy rule;
- default route из отдельной policy table;
- собственные FORWARD jumps;
- цепочка `WDTT_EGRESS_DE`;
- scoped SNAT;
- systemd drop-in автоприменения.

Сохраняются:

- `/etc/wdtt-egress-router.conf`;
- WireGuard;
- WDTT;
- 3x-ui и другие сервисы;
- все сторонние routing/firewall rules.

После `disable` собственная маршрутизация WDTT снова определяется самим WDTT server core.

### `enable`

Возвращает ранее отключённую маршрутизацию из сохранённого конфига:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh enable
```

### `uninstall`

Полностью удаляет слой selective routing, созданный этим проектом:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh uninstall
```

Дополнительно удаляется:

```text
/etc/wdtt-egress-router.conf
```

Команда не удаляет WireGuard, WDTT, 3x-ui или другие сетевые сервисы.

## Persistence

WDTT server core самостоятельно создаёт и обновляет правила `WDTT_MANAGED`. Из-за этого selective routing должен применяться после запуска WDTT.

При `install` или `enable` создаётся systemd drop-in:

```text
/etc/systemd/system/wdtt.service.d/90-german-egress.conf
```

Он добавляет зависимость от WireGuard и выполняет после старта WDTT:

```bash
/usr/local/sbin/wdtt-egress-router.sh apply
```

Благодаря этому собственные правила маршрутизации восстанавливаются после:

- перезагрузки VPS;
- рестарта `wdtt.service`;
- обновления WDTT.

Проверка:

```bash
systemctl cat wdtt.service
```

## Проверка после установки

### Основной маршрут VPS

```bash
ip route get 1.1.1.1
```

Он не должен использовать WireGuard-интерфейс.

Пример:

```text
1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.10
```

### Policy rule

```bash
ip rule show
```

Пример:

```text
0:      from all lookup local
10666:  from 10.66.66.0/24 lookup 51888
32766:  from all lookup main
32767:  from all lookup default
```

### Policy table

```bash
ip route show table 51888
```

Ожидается:

```text
default dev wg-de scope link
```

### Маршрут клиента WDTT

```bash
ip route get 1.1.1.1 from 10.66.66.2 iif wdtt0
```

Ожидается маршрут через WireGuard:

```text
... dev wg-de table 51888
```

### Внешний IP VPS

```bash
curl -4 https://api.ipify.org
```

Должен оставаться публичный адрес основного VPS.

### Внешний IP клиента WDTT

На устройстве, подключённом через WDTT, сервис определения внешнего IP должен показывать адрес egress-сервера.

### Счётчики firewall

```bash
sudo iptables -vnL WDTT_EGRESS_DE
sudo iptables -t nat -vnL POSTROUTING | grep WDTT_EGRESS_DE_SNAT
```

При активном клиентском трафике счётчики `ACCEPT` и SNAT должны увеличиваться.

## Совместная работа с 3x-ui/VLESS

Скрипт не маршрутизирует трафик по имени процесса или порту. Изоляция достигается за счёт source network.

3x-ui, Xray/VLESS, SSH и другие сервисы самого VPS обычно используют адреса основного сетевого интерфейса и поэтому не соответствуют правилу:

```text
from 10.66.66.0/24 lookup 51888
```

Они продолжают использовать таблицу `main`.

Для контроля рекомендуется после изменения конфигурации проверить:

```bash
ip route get 1.1.1.1
curl -4 https://api.ipify.org
```

Если обычный host route указывает на `wg-de`, необходимо сначала исправить конфигурацию WireGuard. Чаще всего причина — отсутствие `Table = off` при `AllowedIPs = 0.0.0.0/0`.

## Обновление WDTT

### Источник server core

Репозиторий [`XXcipherX/vkturn-vps-setup`](https://github.com/XXcipherX/vkturn-vps-setup) содержит установщики и описание развёртывания.

Фактическая серверная часть WDTT находится в:

[`XXcipherX/proxy-turn-vk-android`](https://github.com/XXcipherX/proxy-turn-vk-android)

Для нативной установки собирается модуль:

```text
app/src/main/assets/linux-server
```

Команда обновления использует **последний стабильный GitHub Release** `proxy-turn-vk-android`, а не HEAD ветки `main-new`.

### Проверка версии

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh wdtt-version
```

Пример вывода:

```text
WDTT server core:
  repository:     https://github.com/XXcipherX/proxy-turn-vk-android
  configured ref: vX.Y.Z
  source commit:  abcdef123456
  latest release: vX.Y.Z
  status:         up to date
```

### Только проверить наличие обновления

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh update-wdtt --check
```

Команда ничего не изменяет.

### Обновить WDTT

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh update-wdtt
```

Процесс обновления:

1. через GitHub API определяется `releases/latest` репозитория `proxy-turn-vk-android`;
2. определяется актуальный commit `vkturn-vps-setup/main`;
3. `wdtt-systemd-setup.sh` скачивается по конкретному immutable commit SHA;
4. загруженный установщик проверяется через `bash -n`;
5. создаётся резервная копия текущего WDTT runtime;
6. upstream installer запускается с последним release tag server core;
7. существующий `/etc/wdtt/wdtt.env` используется для сохранения текущих настроек WDTT;
8. проверяется состояние `wdtt.service`;
9. если selective routing был включён до обновления, он применяется снова;
10. если selective routing был отключён, обновление не включает его автоматически.

Upstream installer вызывается эквивалентно:

```text
--source-repo https://github.com/XXcipherX/proxy-turn-vk-android.git
--source-ref <LATEST_RELEASE_TAG>
```

### Резервные копии

Перед обновлением создаётся дополнительный каталог:

```text
/etc/wdtt/backups/router-update-YYYYMMDDTHHMMSSZ/
```

В него сохраняются доступные runtime-файлы:

```text
wdtt-server
wdtt.env
wdtt.service
wdtt-firewall.service
apply-firewall.sh
run-wdtt.sh
```

Сам upstream installer также использует собственный backup-механизм для базы WDTT.

Если обновление или последующий запуск сервиса завершается ошибкой, скрипт пытается восстановить предыдущие runtime-файлы и перезапустить WDTT.

После обновления рекомендуется проверить:

```bash
sudo systemctl status wdtt --no-pager
sudo journalctl -u wdtt -n 100 --no-pager
sudo /usr/local/sbin/wdtt-egress-router.sh wdtt-version
sudo /usr/local/sbin/wdtt-egress-router.sh status
```

## Конфигурационные файлы

```text
/usr/local/sbin/wdtt-egress-router.sh
    основной управляющий скрипт

/etc/wdtt-egress-router.conf
    сохранённые параметры selective routing

/etc/systemd/system/wdtt.service.d/90-german-egress.conf
    systemd persistence

/etc/wireguard/<interface>.conf
    WireGuard-конфигурация; проект её не создаёт и не удаляет

/etc/wdtt/wdtt.env
    штатная конфигурация WDTT

/etc/wdtt/passwords.json
    база WDTT

/etc/wdtt/backups/
    backup-файлы WDTT
```

## Диагностика

### Нет WireGuard handshake

```bash
wg show wg-de
```

Проверьте:

- endpoint;
- UDP-порт;
- firewall;
- private/public keys;
- preshared key;
- доступность удалённого VPS.

### WireGuard подключён, но через него нет интернета

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh probe
```

Если проверка завершается ошибкой, проблема находится между WireGuard-клиентом и egress-сервером. Обычно необходимо проверить forwarding и NAT на egress VPS.

### Сам VPS начал выходить через WireGuard

```bash
ip route get 1.1.1.1
ip route show table main
```

`wg-de` не должен являться default route в `main`.

Проверьте `/etc/wireguard/wg-de.conf`:

```ini
Table = off
```

После исправления перезапустите WireGuard и снова проверьте маршрут.

### WDTT продолжает выходить через основной uplink

```bash
ip rule show
ip route show table 51888
ip route get 1.1.1.1 from 10.66.66.2 iif wdtt0
sudo iptables -vnL WDTT_EGRESS_DE
sudo iptables -t nat -vnL POSTROUTING | grep WDTT_EGRESS_DE_SNAT
```

Также можно выполнить:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh status
```

### Маршрутизация исчезает после рестарта WDTT

Проверьте drop-in:

```bash
systemctl cat wdtt.service
ls -l /etc/systemd/system/wdtt.service.d/90-german-egress.conf
```

Логи:

```bash
journalctl -u wdtt -n 100 --no-pager
```

Принудительно применить сохранённую конфигурацию:

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh apply
```

### Быстро отключить selective routing

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh disable
```

Проверить результат:

```bash
ip rule show
ip route show table 51888
sudo iptables -S | grep WDTT_EGRESS_DE || true
sudo iptables -t nat -S | grep WDTT_EGRESS_DE || true
```

### Повторно включить

```bash
sudo /usr/local/sbin/wdtt-egress-router.sh enable
```

## Ограничения

- Автоматическое обновление WDTT рассчитано на нативную systemd-установку из `wdtt-systemd-setup.sh`.
- Docker-варианты WDTT этим updater не обслуживаются.
- Скрипт работает с IPv4-трафиком WDTT. Полноценная selective IPv6-маршрутизация не настраивается.
- WireGuard egress и NAT на удалённом сервере должны быть настроены заранее.
- Проект не управляет cloud firewall VPS-провайдера.
- Скрипт не создаёт WireGuard peer автоматически.

## Быстрый справочник

```bash
# Установить и включить selective egress
sudo /usr/local/sbin/wdtt-egress-router.sh install

# Состояние
sudo /usr/local/sbin/wdtt-egress-router.sh status

# Проверить WireGuard egress
sudo /usr/local/sbin/wdtt-egress-router.sh probe

# Изменить параметры
sudo /usr/local/sbin/wdtt-egress-router.sh reconfigure [options]

# Временно отключить маршрутизацию
sudo /usr/local/sbin/wdtt-egress-router.sh disable

# Включить обратно
sudo /usr/local/sbin/wdtt-egress-router.sh enable

# Повторно применить правила
sudo /usr/local/sbin/wdtt-egress-router.sh apply

# Проверить версию WDTT
sudo /usr/local/sbin/wdtt-egress-router.sh wdtt-version

# Проверить наличие обновления WDTT
sudo /usr/local/sbin/wdtt-egress-router.sh update-wdtt --check

# Обновить WDTT
sudo /usr/local/sbin/wdtt-egress-router.sh update-wdtt

# Полностью удалить только selective routing этого проекта
sudo /usr/local/sbin/wdtt-egress-router.sh uninstall
```

## Ссылки

- [`Jetvac/WDTT-Selective-WireGuard-Egress-Router`](https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router) — репозиторий этого проекта.
- [Releases](https://github.com/Jetvac/WDTT-Selective-WireGuard-Egress-Router/releases) — опубликованные версии и готовый `wdtt-egress-router.sh`.
- [`XXcipherX/vkturn-vps-setup`](https://github.com/XXcipherX/vkturn-vps-setup) — установщики и документация по развёртыванию WDTT/VK TURN proxy.
- [`XXcipherX/proxy-turn-vk-android`](https://github.com/XXcipherX/proxy-turn-vk-android) — исходный проект WDTT; Linux server core находится в `app/src/main/assets/linux-server`.
- [WireGuard](https://www.wireguard.com/) — VPN-туннель, используемый как отдельный egress.
