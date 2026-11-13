# ProxyFarm Neo — IPv6 Proxy Server

Ферма IPv6-прокси с веб-панелью: массовое создание, ротация адресов, проверка
работоспособности, тест сайтов через прокси, дашборд нагрузки и экспорт списка.

- Версия: **15.0**
- ОС: **Ubuntu Server 20.04 / 22.04 / 24.04**
- Панель: `http://IP:2525`
- Прокси: порты `30000–31000` (по умолчанию)

---

## 1. Что нужно до установки

| Требование | Описание |
|---|---|
| ОС | Ubuntu Server 20.04 / 22.04 / 24.04, чистая |
| Доступ | `root` или `sudo` |
| IPv6 | Выделенная **маршрутизируемая** подсеть `/64` |
| IPv4 | Внешний IPv4 (для подключения клиентов) |
| Порты | `2525/tcp` для панели, `30000–31000/tcp` для прокси |
| Сеть VM | **Bridged** (мост), не NAT |

Проверить, что IPv6 реально работает:

```bash
ip -6 addr show scope global
ping -6 -c 2 2001:4860:4860::8888
```

Если ping не проходит — `/64` не маршрутизируется до сервера. Установщик
создаст адреса, но наружу они работать не будут. Это вопрос настройки
провайдера/роутера, а не скрипта.

---

## 2. Установка

Скопируй папку проекта на сервер (например, в `/root/proxy-farm3`) и запусти:

```bash
cd /root/proxy-farm3
sed -i 's/\r$//' install.sh      # если файл приехал с Windows
sudo bash install.sh
```

Если проект лежит в git-репозитории:

```bash
cd /root
git clone <URL_РЕПОЗИТОРИЯ> proxy-farm3
cd proxy-farm3
sed -i 's/\r$//' install.sh
sudo bash install.sh
```

Установщик:

1. Ставит пакеты и собирает 3proxy 0.9.4 из исходников.
2. Создаёт Python-окружение и Flask-панель.
3. Создаёт до 5 тестовых прокси (по числу свободных портов).
4. Настраивает systemd-сервисы `3proxy` и `proxy-farm`.
5. Проверяет, что сервисы и панель запустились.
6. Печатает адрес панели, логин и пароль.

### Параметры установки

Скрипт сам определяет значения и предлагает их как defaults — просто жми
**Enter**, если всё верно.

| Параметр | По умолчанию | Обязателен | Комментарий |
|---|---|---|---|
| Локальный IPv4 | определяется | да | IP сервера в локальной сети |
| Внешний IPv4 | определяется через ifconfig.me | да | IP, по которому подключаются клиенты |
| IPv6 подсеть | из основного IPv6 | да | строго вида `2001:db8:1:2::/64` |
| Основной IPv6 | определяется | да | адрес самого сервера |
| Интерфейс | из default route | да | `ens33`, `eth0`, `ens3`, `enp0s3` |
| Пароль админа | генерируется | нет | пусто = случайный, 14 символов |
| Порты прокси | `30000–31000` | нет | начало и конец диапазона |

Пароль админа — только латиница и цифры, минимум 6 символов. Это сделано
специально: спецсимволы ломают конфиги и неудобны для копирования.

В конце установки скрипт покажет:

```text
Веб-интерфейс:  http://192.168.1.16:2525
Логин:          admin
Пароль:         xxxxxxxxxxxxxx
```

**Сохрани пароль.** В базе хранится только его hash.

---

## 3. Доступ к панели

| Откуда | Адрес |
|---|---|
| Локальная сеть | `http://ЛОКАЛЬНЫЙ_IP:2525` |
| Извне | `http://ВНЕШНИЙ_IP:2525` |

Для доступа извне нужен проброс порта `2525` на роутере на локальный IP
сервера. Для прокси — проброс всего диапазона `30000–31000` (или того,
который указал при установке).

Логин: `admin`, пароль — заданный при установке.

### Что есть в панели

- **Дашборд** — CPU, RAM, прокси, кнопки перезапуска 3proxy и ребута.
- **Прокси** — список, копирование строки подключения, экспорт, ротация,
  удаление, проверка дубликатов.
- **Создать** — массовое создание прокси (до 100 за раз).
- **Проверка** — открыт ли порт и выходит ли прокси в IPv6-интернет.
- **Тест сайтов** — HTTP-запрос к сайту через выбранный прокси.
- **Система** — диски, сеть, uptime, конфигурация.
- **Настройки** — смена пароля админа (сохраняется в `users.json`).

---

## 4. Формат прокси

```text
http://ВНЕШНИЙ_IP:ПОРТ:ЛОГИН:ПАРОЛЬ
```

Пример:

```text
http://203.0.113.10:30000:user30000:pass30000
```

Проверка вручную:

```bash
# IPv6-only сайт (вернёт IPv6-адрес прокси)
curl -x http://user30000:pass30000@ЛОКАЛЬНЫЙ_IP:30000 -s http://ip6only.me/api/

# Google по IPv6
curl -x http://user30000:pass30000@ЛОКАЛЬНЫЙ_IP:30000 -sI http://ipv6.google.com
```

Локальный IPv4 используется для подключения изнутри сети, внешний — снаружи
(при условии проброса портов).

---

## 5. Перезагрузка сервера

Почему раньше прокси «отваливались» после ребута:

- IPv6-адреса добавлялись командой `ip -6 addr add` и **не сохранялись** —
  после перезагрузки их просто не было;
- 3proxy запускался вручную/через `Popen`, а не через systemd, и мог не
  подняться вместе с системой;
- в конфиге стоял `daemon`, что конфликтовало с systemd;
- `SECRET_KEY` и пароль админа не сохранялись между запусками.

Что сделано сейчас:

- `/opt/proxy-farm/restore_ipv6.py` при каждом старте `3proxy.service`
  (через `ExecStartPre`) заново добавляет все IPv6-адреса из `proxies.json`
  и пересобирает `/etc/3proxy/3proxy.cfg`;
- 3proxy работает как `Type=simple` без `daemon`, с `Restart=always`;
- `proxy-farm.service` ждёт `network-online.target` и тоже перезапускается
  автоматически;
- `SECRET_KEY` лежит в `/opt/proxy-farm/secret.key`, пароль — в `users.json`.

Проверка после ребута:

```bash
systemctl status 3proxy proxy-farm --no-pager
journalctl -u 3proxy -n 30 --no-pager
ip -6 addr show scope global | head
```

---

## 6. Управление сервисами

```bash
# Статус
systemctl status 3proxy
systemctl status proxy-farm

# Перезапуск
systemctl restart 3proxy
systemctl restart proxy-farm

# Логи в реальном времени
journalctl -u 3proxy -f
journalctl -u proxy-farm -f

# Автозапуск (включён установщиком)
systemctl enable 3proxy proxy-farm
```

Перезапускать 3proxy вручную после изменения конфига не обязательно:
панель делает это сама при создании/удалении/ротации прокси.

---

## 7. Диагностика

Одна команда, чтобы увидеть всё сразу:

```bash
echo "=== services ==="; systemctl is-active 3proxy proxy-farm
echo "=== ports ==="; ss -ltn | grep -E ':2525|:30000'
echo "=== ipv6 ==="; ip -6 addr show scope global | head -20
echo "=== 3proxy log ==="; journalctl -u 3proxy -n 20 --no-pager
echo "=== panel log ==="; journalctl -u proxy-farm -n 20 --no-pager
```

| Симптом | Причина | Что делать |
|---|---|---|
| Панель не открывается | `proxy-farm` не запущен | `journalctl -u proxy-farm -n 50` |
| Порт 2525 закрыт | firewall / другой процесс | `ss -ltnp \| grep 2525`, `ufw allow 2525` |
| Прокси-порт закрыт | 3proxy не запущен или порт занят | `systemctl status 3proxy`, `ss -ltnp \| grep 30000` |
| Прокси не выходит в интернет | IPv6 не маршрутизируется | `ping -6 2000::1`, проверить `/64` у провайдера |
| `407 Proxy Authentication Required` | неверный логин/пароль | взять строку из панели заново |
| После ребута нет IPv6 | адреса не добавились | `journalctl -u 3proxy -b`, запустить `restore_ipv6.py` вручную |
| `3proxy: command not found` | сборка не установила бинарник | `sudo bash install.sh` заново, смотреть `/tmp/3proxy-build.log` |
| Забыл пароль админа | — | сбросить (см. ниже) |

Ручной запуск восстановления IPv6:

```bash
sudo /opt/proxy-farm/venv/bin/python /opt/proxy-farm/restore_ipv6.py
```

### Сброс пароля админа

```bash
sudo /opt/proxy-farm/venv/bin/python - <<'PY'
import json
from werkzeug.security import generate_password_hash

path = '/opt/proxy-farm/users.json'
try:
    users = json.load(open(path))
except Exception:
    users = []

new_hash = generate_password_hash('НОВЫЙ_ПАРОЛЬ')
for u in users:
    if u.get('username') == 'admin':
        u['password'] = new_hash
        break
else:
    users.append({'id': '1', 'username': 'admin', 'password': new_hash})

json.dump(users, open(path, 'w'))
print('Пароль обновлён')
PY
sudo systemctl restart proxy-farm
```

---

## 8. Чек-лист для новой VM (чтобы не было «танцев с бубном»)

1. **Сетевой адаптер — Bridged.** При NAT IPv6-подсеть до VM не дойдёт.
2. **Статический IP** — резерв на роутере по MAC или netplan. Иначе после
   ребута адрес изменится и панель «пропадёт».
3. **IPv6 `/64` маршрутизируется на сервер.** Проверка:
   `ping -6 -c 2 2001:4860:4860::8888`.
4. **Проброс портов на роутере:** `2525` и диапазон прокси
   (`30000–31000`) → локальный IP сервера.
5. **Firewall:** `ufw allow 2525/tcp`, `ufw allow 30000:31000/tcp`
   (если ufw включён).
6. **SSH и sudo без пароля** — по желанию, для удобства деплоя.
7. Запустить `sudo bash install.sh` и сохранить пароль из вывода.

Если менял диапазон портов при установке — проброс и firewall должны
совпадать с ним.

---

## 9. Структура проекта

```text
/opt/proxy-farm/
├── app.py               # Flask-панель
├── restore_ipv6.py      # восстановление IPv6 и конфига при старте
├── config.json          # параметры установки
├── proxies.json         # база прокси
├── users.json           # админ (hash пароля)
├── secret.key           # ключ сессий
├── templates/
│   ├── login.html
│   └── index.html
└── venv/                # Python-окружение

/etc/3proxy/
├── 3proxy.cfg           # генерируется автоматически
└── .proxyauth           # список логинов/паролей

/etc/systemd/system/
├── 3proxy.service
└── proxy-farm.service
```

`proxies.json` — источник истины. `3proxy.cfg` пересобирается из него при
каждом изменении и при каждом старте сервиса, поэтому руками его править
не нужно.

---

## 10. Удаление

```bash
sudo systemctl stop proxy-farm 3proxy
sudo systemctl disable proxy-farm 3proxy
sudo rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/proxy-farm.service
sudo systemctl daemon-reload

sudo rm -rf /opt/proxy-farm /etc/3proxy
sudo rm -f /usr/bin/3proxy /usr/local/bin/3proxy

# Удалить добавленные IPv6-адреса (кроме основного)
INTERFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
MAIN_IPV6=$(ip -6 -o addr show dev "$INTERFACE" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
for ip in $(ip -6 -o addr show dev "$INTERFACE" scope global | awk '{split($4,a,"/"); print a[1]}'); do
    [ "$ip" != "$MAIN_IPV6" ] && sudo ip -6 addr del "$ip/64" dev "$INTERFACE" 2>/dev/null
done
```

Удаление не трогает сетевые настройки, SSH и другие сервисы.

---

## 11. Безопасность

- Панель слушает `0.0.0.0:2525`. Если внешний доступ не нужен — закрой порт
  в firewall и пользуйся через SSH-туннель:
  `ssh -L 2525:127.0.0.1:2525 user@server`.
- Пароль админа хранится как hash, но панель работает по HTTP. Для доступа
  из интернета поставь перед ней reverse-proxy с HTTPS (Caddy/Nginx).
- Прокси-логины и пароли лежат в `proxies.json` и `3proxy.cfg` в открытом
  виде — это неизбежно для basic-auth 3proxy. Ограничь доступ к серверу.

---

## 12. Лицензия

MIT. Проект основан на идее `Temporalitas/ipv6-proxy-server`, 3proxy
используется по своей лицензии.
