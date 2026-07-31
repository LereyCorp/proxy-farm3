# ProxyFarm Neo - IPv6 Proxy Server v8.0

Современная ферма IPv6 прокси с веб-интерфейсом для управления.

## 🚀 Быстрая установка

```bash
cd /root
git clone https://github.com/LereyCorp/proxy-farm3.git
cd proxy-farm3
sed -i 's/\r$//' install.sh
bash install.sh

## 📋 Требования

Ubuntu Server 20.04 / 22.04 / 24.04

Выделенная IPv6 подсеть /64

Права root

Открытые порты на роутере: 2525 (веб), 30000-31000 (прокси)

## ⚙️ Параметры установки

Параметр	По умолчанию	Описание
Локальный IPv4	192.168.1.7	IP сервера в локальной сети
Внешний IPv4	обязательно	Внешний IP для клиентов
IPv6 подсеть	обязательно	/64 подсеть
Основной IPv6	обязательно	Основной IPv6 сервера
Интерфейс	ens33	Имя сетевого интерфейса
Пароль админа	Maxim1809	Для веб-интерфейса
Порты	30000-31000	Диапазон портов прокси

## 🌐 Доступ

Локально: http://ЛОКАЛЬНЫЙ_IP:2525

Внешне: http://ВНЕШНИЙ_IP:2525

Логин: admin

Пароль: указанный при установке

✨ Возможности
🎨 Современный дизайн

📊 Дашборд (CPU, RAM, диски, сеть)

🌐 Создание прокси (по 1 и массово)

🔐 Индивидуальные логины/пароли

🔄 Ротация IPv6 адресов

🔍 Проверка работоспособности

🌍 Тест сайтов через прокси

🖥️ Системная информация

📱 Адаптивный дизайн

📥 Экспорт прокси

🔌 Перезагрузка сервера

## 📦 Формат прокси
text
http://ВНЕШНИЙ_IP:PORT:LOGIN:PASS
🛠 Управление
bash
systemctl status proxy-farm   # Статус веб-интерфейса
systemctl status 3proxy       # Статус прокси
systemctl restart proxy-farm  # Перезапуск веб
systemctl restart 3proxy      # Перезапуск прокси
journalctl -u proxy-farm -f   # Логи
🗑 Удаление
bash
systemctl stop proxy-farm 3proxy
pkill -9 3proxy python
rm -rf /opt/proxy-farm /etc/3proxy /root/proxy-farm3
rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/proxy-farm.service
systemctl daemon-reload
## ⚠️ Важно
Прокси работают через IPv6

Нужен проброс портов на роутере

Пароли без спецсимволов

После перезагрузки всё восстанавливается

## 📄 Лицензия
MIT License
EOF
