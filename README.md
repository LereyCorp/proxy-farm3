# ProxyFarm Neo - IPv6 Proxy Server v8.0

Современная ферма IPv6 прокси с веб-интерфейсом для управления.

## 🚀 Быстрая установка

```bash
cd /root
git clone https://github.com/LereyCorp/proxy-farm3.git
cd proxy-farm3
sed -i 's/\r$//' install.sh
bash install.sh


📋 Требования
Ubuntu Server 20.04 / 22.04 / 24.04

Выделенная IPv6 подсеть /64

Права root

Открытые порты на роутере:

2525 (веб-интерфейс)

30000-31000 (прокси)

⚙️ Что будет запрошено при установке
Параметр	По умолчанию	Описание
Локальный IPv4	192.168.1.7	IP сервера в локальной сети
Внешний IPv4	обязательно	Внешний IP для подключения клиентов
IPv6 подсеть	обязательно	Выделенная /64 подсеть
Основной IPv6	обязательно	Основной IPv6 адрес сервера
Сетевой интерфейс	ens33	Имя интерфейса (ens33, eth0, ens3)
Пароль админа	Maxim1809	Пароль для входа в веб-интерфейс
Начальный порт	30000	Первый порт для прокси
Конечный порт	31000	Последний порт для прокси
🌐 Доступ к веб-интерфейсу
После установки:

Локально: http://ЛОКАЛЬНЫЙ_IP:2525

Внешне: http://ВНЕШНИЙ_IP:2525

Данные для входа:

Логин: admin

Пароль: указанный при установке

✨ Возможности
🎨 Современный черно-фиолетовый дизайн

📊 Дашборд с CPU, RAM, дисками, сетью

🌐 Создание прокси по 1 шт и массово

🔐 Индивидуальные логины и пароли для каждого прокси

🔄 Ротация IPv6 адресов

🔍 Проверка прокси на работоспособность

🌍 Тест сайтов через выбранный прокси

🖥️ Системная информация (процессы, диски, сеть)

📱 Адаптивный дизайн (ПК и мобильные)

📥 Экспорт прокси в файл

🔌 Перезагрузка сервера из веб-интерфейса

🔄 Перезапуск 3proxy одной кнопкой

📦 Формат прокси
text
http://ВНЕШНИЙ_IP:PORT:LOGIN:PASS
Пример:

text
http://your-server-ip:30000:user30000:pass30000
🛠 Управление сервисами
bash
# Статус веб-интерфейса
systemctl status proxy-farm

# Статус прокси-сервера
systemctl status 3proxy

# Перезапуск веб-интерфейса
systemctl restart proxy-farm

# Перезапуск прокси-сервера
systemctl restart 3proxy

# Просмотр логов
journalctl -u proxy-farm -f
journalctl -u 3proxy -f
🔧 Проверка прокси вручную
bash
# Через IPv6-only сайт
curl -x http://LOGIN:PASS@ЛОКАЛЬНЫЙ_IP:PORT -s http://ip6only.me/api/

# Через Google IPv6
curl -x http://LOGIN:PASS@ЛОКАЛЬНЫЙ_IP:PORT -s http://ipv6.google.com -I
📁 Структура проекта
text
/opt/proxy-farm/
├── app.py              # Flask приложение
├── templates/
│   ├── index.html      # Панель управления
│   └── login.html      # Страница входа
├── proxies.json        # База прокси
├── users.json          # Пользователи
└── venv/               # Python окружение

/etc/3proxy/
├── 3proxy.cfg          # Конфигурация 3proxy
└── .proxyauth          # Аутентификация
🗑 Полное удаление
bash
systemctl stop proxy-farm 3proxy 2>/dev/null
pkill -9 3proxy 2>/dev/null
pkill -9 python 2>/dev/null
rm -rf /opt/proxy-farm /root/proxyserver /tmp/ipv6-proxy-server /root/proxy-farm3 /etc/3proxy
rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/proxy-farm.service
systemctl daemon-reload

# Очистка IPv6 адресов (кроме основного)
for ip in $(ip -6 addr show dev ens33 | grep 'scope global' | grep -v dynamic | awk '{print $2}' | cut -d/ -f1); do
    if [ "$ip" != "ВАШ_ОСНОВНОЙ_IPv6" ]; then
        ip -6 addr del $ip/64 dev ens33 2>/dev/null
    fi
done
⚠️ Важно
Прокси работают через IPv6. Для доступа к IPv4 сайтам может потребоваться NAT64/DNS64

Проброс портов на роутере обязателен для доступа извне

После перезагрузки сервера всё восстанавливается автоматически

Пароли генерируются без спецсимволов для совместимости

📝 Примечания по проверке
Проверка прокси в веб-интерфейсе использует ip6only.me/api/ (IPv6-only)

HTTP 000 при тесте сайтов = сайт не поддерживает IPv6 или недоступен

Adspower и подобные антидетект-браузеры могут не работать с IPv6 прокси (требуют IPv4)

🔗 Ссылки
GitHub: LereyCorp/proxy-farm3

Основано на: Temporalitas/ipv6-proxy-server

3proxy: 3proxy/3proxy
