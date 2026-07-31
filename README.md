# 🚀 ProxyFarm Neo - IPv6 Proxy Server

<div align="center">

![Version](https://img.shields.io/badge/version-8.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2020.04%2B-orange)

**Современная ферма IPv6 прокси с веб-интерфейсом**

[Установка](#-быстрая-установка) • [Возможности](#-возможности) • [Управление](#-управление) • [Удаление](#-удаление)

</div>

---

## 📋 Требования

| Требование | Описание |
|------------|----------|
| **ОС** | Ubuntu Server 20.04 / 22.04 / 24.04 |
| **IPv6** | Выделенная подсеть `/64` |
| **Доступ** | Права `root` |
| **Порты** | `2525` (веб) + `30000-31000` (прокси) |

---

## 🚀 Быстрая установка

```bash
cd /root
git clone https://github.com/LereyCorp/proxy-farm3.git
cd proxy-farm3
sed -i 's/\r$//' install.sh
bash install.sh
---
⚙️ Параметры установки
При запуске скрипт запросит следующие параметры:

Параметр	По умолчанию	Описание
Локальный IPv4	192.168.1.7	IP сервера в локальной сети
Внешний IPv4	❗ обязательно	Внешний IP для подключения клиентов
IPv6 подсеть	❗ обязательно	Выделенная /64 подсеть
Основной IPv6	❗ обязательно	Основной IPv6 адрес сервера
Интерфейс	ens33	Сетевой интерфейс (ens33, eth0, ens3)
Пароль админа	Maxim1809	Пароль для веб-интерфейса
Порты прокси	30000-31000	Диапазон портов
---
🌐 Доступ к веб-интерфейсу
Адрес
🏠 Локально	http://ЛОКАЛЬНЫЙ_IP:2525
🌍 Внешне	http://ВНЕШНИЙ_IP:2525
text
👤 Логин: admin
🔑 Пароль: указанный при установке
✨ Возможности
Функция	Описание
🎨	Современный черно-фиолетовый дизайн
📊	Дашборд с CPU, RAM, дисками, сетью
🌐	Массовое создание прокси
🔐	Индивидуальные логины и пароли
🔄	Ротация IPv6 адресов
🔍	Проверка работоспособности
🌍	Тест сайтов через прокси
🖥️	Системная информация
📱	Адаптивный дизайн (ПК + мобильные)
📥	Экспорт прокси в файл
🔌	Перезагрузка сервера из веб-интерфейса
---
📦 Формат прокси
text
http://ВНЕШНИЙ_IP:PORT:LOGIN:PASS
Пример:

text
http://your-server-ip:30000:user30000:pass30000
🛠 Управление сервисами
bash
# Статус сервисов
systemctl status proxy-farm      # Веб-интерфейс
systemctl status 3proxy          # Прокси-сервер

# Перезапуск
systemctl restart proxy-farm     # Веб-интерфейс
systemctl restart 3proxy         # Прокси-сервер

# Логи
journalctl -u proxy-farm -f      # Веб-интерфейс
journalctl -u 3proxy -f          # Прокси-сервер
---
🔧 Проверка прокси вручную
bash
# IPv6-only сайт
curl -x http://LOGIN:PASS@ЛОКАЛЬНЫЙ_IP:PORT -s http://ip6only.me/api/

# Google IPv6
curl -x http://LOGIN:PASS@ЛОКАЛЬНЫЙ_IP:PORT -s http://ipv6.google.com -I
---
📁 Структура проекта
text
/opt/proxy-farm/
├── app.py              # Flask приложение
├── templates/
│   ├── index.html      # Панель управления
│   └── login.html      # Страница входа
├── proxies.json        # База данных прокси
├── users.json          # Пользователи
└── venv/               # Python окружение

/etc/3proxy/
├── 3proxy.cfg          # Конфигурация прокси
└── .proxyauth          # Аутентификация
🗑 Полное удаление
bash
# Остановка сервисов
systemctl stop proxy-farm 3proxy

# Завершение процессов
pkill -9 3proxy python

# Удаление файлов
rm -rf /opt/proxy-farm /etc/3proxy /root/proxy-farm3
rm -f /etc/systemd/system/3proxy.service
rm -f /etc/systemd/system/proxy-farm.service
systemctl daemon-reload

# Очистка IPv6 адресов
for ip in $(ip -6 addr show dev ens33 | grep 'scope global' | grep -v dynamic | awk '{print $2}' | cut -d/ -f1); do
    if [ "$ip" != "ВАШ_ОСНОВНОЙ_IPv6" ]; then
        ip -6 addr del $ip/64 dev ens33 2>/dev/null
    fi
done
---
⚠️ Важная информация
🔒	Пароли генерируются без спецсимволов
🔄	После перезагрузки сервера всё восстанавливается автоматически
🌐	Прокси работают через IPv6
🔌	Для доступа извне нужен проброс портов на роутере
📱	Антидетект-браузеры могут требовать IPv4
🔗 Ссылки
GitHub репозиторий

Основано на Temporalitas/ipv6-proxy-server

3proxy

<div align="center">
📄 Лицензия MIT
Made with ❤️ for IPv6 community

</div> ```
