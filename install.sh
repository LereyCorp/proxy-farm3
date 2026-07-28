#!/bin/bash
# ============================================
# ProxyFarm Neo - Complete Installation Script
# Автоматическая установка IPv6 прокси-фермы
# ============================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Конфигурация
IPV4_LOCAL="192.168.1.7"
IPV6_MAIN="2a01:540:44c4:df00:20c:29ff:fe84:71d1"
IPV6_SUBNET="2a01:540:44c4:df00::/64"
EXTERNAL_IPV4="62.148.226.89"
PROXY_PORT_START=30000
PROXY_PORT_END=31000
WEB_PORT=2525
ADMIN_PASSWORD="Maxim1809"

echo -e "${PURPLE}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - Installation Script            ║"
echo "║          IPv6 Proxy Farm with Web Interface             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен запускаться с правами root${NC}"
   exit 1
fi

# Функция для отображения прогресса
progress() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# ============================================
# Шаг 1: Обновление системы
# ============================================
progress "Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
success "Система обновлена"

# ============================================
# Шаг 2: Установка необходимых пакетов
# ============================================
progress "Установка зависимостей..."
apt-get install -y -qq \
    python3 python3-pip python3-venv python3-dev \
    gcc build-essential git wget tar gzip net-tools \
    nginx htop iotop iftop curl > /dev/null 2>&1
success "Зависимости установлены"

# ============================================
# Шаг 3: Установка 3proxy из исходников
# ============================================
progress "Установка 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /dev/null 2>&1
make -f Makefile.Linux install > /dev/null 2>&1
success "3proxy установлен"

# ============================================
# Шаг 4: Создание структуры директорий
# ============================================
progress "Создание структуры проекта..."
mkdir -p /opt/proxy-farm/templates
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy
cd /opt/proxy-farm
success "Структура создана"

# ============================================
# Шаг 5: Создание конфигурации 3proxy
# ============================================
progress "Настройка 3proxy..."
cat > /etc/3proxy/3proxy.cfg << 'EOF'
nserver 8.8.8.8
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $/etc/3proxy/.proxyauth
log /var/log/3proxy/3proxy.log D
logformat "L%d-%m-%Y %H:%M:%S %z %N %p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
allow * 127.0.0.1,192.168.1.7
allow * * * 80-65535
admin -p8080
EOF

touch /etc/3proxy/.proxyauth
chmod 600 /etc/3proxy/.proxyauth
success "3proxy настроен"

# ============================================
# Шаг 6: Создание systemd сервиса для 3proxy
# ============================================
progress "Создание сервиса 3proxy..."
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
success "Сервис 3proxy создан"

# ============================================
# Шаг 7: Создание Python приложения
# ============================================
progress "Создание веб-приложения..."

cat > /opt/proxy-farm/app.py << 'PYEOF'
#!/usr/bin/env python3
import os
import re
import subprocess
import json
import random
import string
import ipaddress
import threading
import time
from datetime import datetime
from functools import wraps
import psutil
import requests
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from flask_socketio import SocketIO, emit
from flask_cors import CORS
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.config['SECRET_KEY'] = 'proxy-farm-neo-secret-key-2024'
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*")

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

# Configuration
IPV4_LOCAL = "192.168.1.7"
IPV6_MAIN = "2a01:540:44c4:df00:20c:29ff:fe84:71d1"
IPV6_SUBNET = "2a01:540:44c4:df00::/64"
EXTERNAL_IPV4 = "62.148.226.89"
PROXY_PORT_START = 30000
PROXY_PORT_END = 31000
WEB_PORT = 2525
ADMIN_PASSWORD_HASH = generate_password_hash("Maxim1809")

PROXY_DB = '/opt/proxy-farm/proxies.json'
USERS_DB = '/opt/proxy-farm/users.json'
CONFIG_3PROXY = '/etc/3proxy/3proxy.cfg'
AUTH_3PROXY = '/etc/3proxy/.proxyauth'

for db_file in [PROXY_DB, USERS_DB]:
    if not os.path.exists(db_file):
        with open(db_file, 'w') as f:
            json.dump([], f)

class User(UserMixin):
    def __init__(self, id, username, password_hash):
        self.id = id
        self.username = username
        self.password_hash = password_hash

@login_manager.user_loader
def load_user(user_id):
    with open(USERS_DB, 'r') as f:
        users = json.load(f)
    for user in users:
        if user['id'] == user_id:
            return User(user['id'], user['username'], user['password'])
    return None

def load_proxies():
    with open(PROXY_DB, 'r') as f:
        return json.load(f)

def save_proxies(proxies):
    with open(PROXY_DB, 'w') as f:
        json.dump(proxies, f, indent=2)

def get_available_ips():
    used_ips = set()
    proxies = load_proxies()
    for proxy in proxies:
        if proxy.get('ipv6'):
            used_ips.add(proxy['ipv6'])
    network = ipaddress.ip_network(IPV6_SUBNET)
    available = []
    for ip in network.hosts():
        ip_str = str(ip)
        if ip_str not in used_ips and ip_str != IPV6_MAIN:
            available.append(ip_str)
    return available

def generate_proxy_config():
    proxies = load_proxies()
    config = """nserver 8.8.8.8
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $/etc/3proxy/.proxyauth
log /var/log/3proxy/3proxy.log D
logformat "L%d-%m-%Y %H:%M:%S %z %N %p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
allow * 127.0.0.1,192.168.1.7
allow * * * 80-65535
"""
    for proxy in proxies:
        if proxy['active']:
            config += f"proxy -6 -n -a -p{proxy['port']} -i{IPV4_LOCAL} -e{proxy['ipv6']}\n"
    
    config += "flush\n"
    
    with open(CONFIG_3PROXY, 'w') as f:
        f.write(config)
    
    auth_content = ""
    for proxy in proxies:
        if proxy['active']:
            auth_content += f"{proxy['username']}:CL:{proxy['password']}\n"
    
    with open(AUTH_3PROXY, 'w') as f:
        f.write(auth_content)

def restart_3proxy():
    generate_proxy_config()
    result = subprocess.run(['pgrep', '3proxy'], capture_output=True)
    if result.returncode == 0:
        subprocess.run(['killall', '-HUP', '3proxy'], capture_output=True)
    else:
        subprocess.run(['/usr/local/bin/3proxy', CONFIG_3PROXY], capture_output=True)

def get_system_info():
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    network = psutil.net_io_counters()
    interfaces = psutil.net_if_addrs()
    ipv6_interfaces = {}
    for iface, addrs in interfaces.items():
        for addr in addrs:
            if addr.family == 10:
                ipv6_interfaces[iface] = addr.address
    processes = []
    for proc in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_percent']):
        try:
            processes.append(proc.info)
        except:
            pass
    processes = sorted(processes, key=lambda x: x['cpu_percent'], reverse=True)[:10]
    uptime_seconds = time.time() - psutil.boot_time()
    uptime_str = str(datetime.timedelta(seconds=int(uptime_seconds)))
    
    return {
        'hostname': os.uname().nodename,
        'os': f"{os.uname().sysname} {os.uname().release}",
        'kernel': os.uname().version,
        'architecture': os.uname().machine,
        'cpu_count': psutil.cpu_count(),
        'cpu_percent': cpu_percent,
        'memory_total': f"{memory.total / (1024**3):.2f} GB",
        'memory_used': f"{memory.used / (1024**3):.2f} GB",
        'memory_percent': memory.percent,
        'disk_total': f"{disk.total / (1024**3):.2f} GB",
        'disk_used': f"{disk.used / (1024**3):.2f} GB",
        'disk_percent': disk.percent,
        'network_sent': f"{network.bytes_sent / (1024**2):.2f} MB",
        'network_recv': f"{network.bytes_recv / (1024**2):.2f} MB",
        'uptime': uptime_str,
        'ipv4_local': IPV4_LOCAL,
        'ipv6_main': IPV6_MAIN,
        'ipv6_subnet': IPV6_SUBNET,
        'external_ipv4': EXTERNAL_IPV4,
        'ipv6_interfaces': ipv6_interfaces,
        'processes': processes,
        'timestamp': datetime.now().isoformat()
    }

@app.route('/')
@login_required
def index():
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        if username == 'admin' and check_password_hash(ADMIN_PASSWORD_HASH, password):
            user = User('1', 'admin', ADMIN_PASSWORD_HASH)
            login_user(user)
            return redirect(url_for('index'))
        return render_template('login.html', error='Неверные учетные данные')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))

@app.route('/api/system-info')
@login_required
def api_system_info():
    return jsonify(get_system_info())

@app.route('/api/proxies')
@login_required
def api_get_proxies():
    proxies = load_proxies()
    available_ips = len(get_available_ips())
    active_count = sum(1 for p in proxies if p['active'])
    total_count = len(proxies)
    return jsonify({
        'proxies': proxies,
        'stats': {
            'active': active_count,
            'total': total_count,
            'available_ips': available_ips,
            'port_range': f"{PROXY_PORT_START}-{PROXY_PORT_END}",
            'ports_used': total_count,
            'ports_available': (PROXY_PORT_END - PROXY_PORT_START + 1) - total_count
        }
    })

@app.route('/api/proxy/create', methods=['POST'])
@login_required
def api_create_proxy():
    data = request.json
    count = data.get('count', 1)
    username = data.get('username', '')
    password = data.get('password', '')
    
    proxies = load_proxies()
    available_ips = get_available_ips()
    
    if count > len(available_ips):
        return jsonify({'error': f'Недостаточно IP. Доступно: {len(available_ips)}'}), 400
    
    used_ports = set(p['port'] for p in proxies)
    available_ports = [p for p in range(PROXY_PORT_START, PROXY_PORT_END + 1) if p not in used_ports]
    
    if count > len(available_ports):
        return jsonify({'error': f'Недостаточно портов. Доступно: {len(available_ports)}'}), 400
    
    created = []
    for i in range(count):
        new_proxy = {
            'id': datetime.now().strftime('%Y%m%d%H%M%S') + str(random.randint(1000, 9999)),
            'ipv6': available_ips[i],
            'port': available_ports[i],
            'username': username or f"user_{random.randint(10000, 99999)}",
            'password': password or ''.join(random.choices(string.ascii_letters + string.digits, k=12)),
            'created_at': datetime.now().isoformat(),
            'active': True,
            'last_checked': None,
            'status': 'active'
        }
        proxies.append(new_proxy)
        created.append(new_proxy)
    
    save_proxies(proxies)
    restart_3proxy()
    
    return jsonify({'message': f'Создано {count} прокси', 'proxies': created})

@app.route('/api/proxy/delete', methods=['POST'])
@login_required
def api_delete_proxy():
    data = request.json
    proxy_ids = data.get('ids', [])
    proxies = load_proxies()
    deleted = [p['id'] for p in proxies if p['id'] in proxy_ids]
    proxies = [p for p in proxies if p['id'] not in proxy_ids]
    save_proxies(proxies)
    restart_3proxy()
    return jsonify({'message': f'Удалено {len(deleted)} прокси', 'deleted': deleted})

@app.route('/api/proxy/rotate', methods=['POST'])
@login_required
def api_rotate_proxy():
    data = request.json
    proxy_ids = data.get('ids', [])
    proxies = load_proxies()
    rotated = []
    available = get_available_ips()
    
    for proxy in proxies:
        if proxy['id'] in proxy_ids and available:
            proxy['ipv6'] = available.pop(0)
            proxy['rotated_at'] = datetime.now().isoformat()
            rotated.append(proxy['id'])
    
    save_proxies(proxies)
    restart_3proxy()
    return jsonify({'message': f'Ротировано {len(rotated)} прокси', 'rotated': rotated})

@app.route('/api/proxy/check-duplicates', methods=['GET'])
@login_required
def api_check_duplicates():
    proxies = load_proxies()
    seen_ips = {}
    duplicates = []
    for proxy in proxies:
        if proxy['ipv6'] in seen_ips:
            duplicates.append(proxy)
        else:
            seen_ips[proxy['ipv6']] = proxy
    return jsonify({'duplicates': len(duplicates), 'details': duplicates})

@socketio.on('connect')
def handle_connect():
    if current_user.is_authenticated:
        emit('connected', {'data': 'Connected'})

def background_updates():
    while True:
        socketio.emit('system_update', get_system_info())
        time.sleep(5)

if __name__ == '__main__':
    with open(USERS_DB, 'r') as f:
        users = json.load(f)
    if not any(u['username'] == 'admin' for u in users):
        users.append({'id': '1', 'username': 'admin', 'password': ADMIN_PASSWORD_HASH})
        with open(USERS_DB, 'w') as f:
            json.dump(users, f, indent=2)
    
    threading.Thread(target=background_updates, daemon=True).start()
    socketio.run(app, host='0.0.0.0', port=WEB_PORT, debug=False)
PYEOF

success "Веб-приложение создано"

# ============================================
# Шаг 8: Создание HTML шаблонов
# ============================================
progress "Создание веб-интерфейса..."

cat > /opt/proxy-farm/templates/login.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ProxyFarm Neo - Login</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{
            font-family:'Inter',sans-serif;
            background:#0a0a0f;
            min-height:100vh;
            display:flex;
            align-items:center;
            justify-content:center;
            overflow:hidden;
        }
        .bg-glow{
            position:fixed;
            width:600px;
            height:600px;
            border-radius:50%;
            filter:blur(120px);
            opacity:0.15;
            animation:float 20s infinite;
            z-index:-1;
        }
        .bg-glow:nth-child(1){background:#6c5ce7;top:-20%;left:-20%}
        .bg-glow:nth-child(2){background:#d63384;bottom:-20%;right:-20%;animation-delay:-10s}
        @keyframes float{
            0%,100%{transform:translate(0,0) rotate(0deg)}
            33%{transform:translate(50px,-50px) rotate(120deg)}
            66%{transform:translate(-30px,30px) rotate(240deg)}
        }
        .login-container{
            background:rgba(30,30,46,0.8);
            backdrop-filter:blur(20px);
            border:1px solid #2a2a3a;
            border-radius:24px;
            padding:48px;
            width:400px;
            max-width:90%;
            box-shadow:0 20px 60px rgba(0,0,0,0.5);
        }
        .logo{
            font-size:36px;
            font-weight:700;
            background:linear-gradient(135deg,#6c5ce7,#a29bfe);
            -webkit-background-clip:text;
            -webkit-text-fill-color:transparent;
            text-align:center;
            margin-bottom:40px;
        }
        .form-group{margin-bottom:24px}
        .form-label{
            display:block;
            color:#9898b0;
            font-size:13px;
            font-weight:500;
            text-transform:uppercase;
            letter-spacing:1px;
            margin-bottom:8px;
        }
        .form-input{
            width:100%;
            background:#181825;
            border:1px solid #2a2a3a;
            border-radius:12px;
            padding:14px 18px;
            color:#e4e4f0;
            font-family:'Inter',sans-serif;
            font-size:16px;
            transition:all 0.3s ease;
        }
        .form-input:focus{
            outline:none;
            border-color:#6c5ce7;
            box-shadow:0 0 0 3px rgba(108,92,231,0.1);
        }
        .btn-login{
            width:100%;
            padding:14px;
            background:linear-gradient(135deg,#6c5ce7,#a29bfe);
            color:white;
            border:none;
            border-radius:12px;
            font-size:16px;
            font-weight:600;
            cursor:pointer;
            transition:all 0.3s ease;
            box-shadow:0 4px 20px rgba(108,92,231,0.3);
        }
        .btn-login:hover{
            transform:translateY(-2px);
            box-shadow:0 6px 30px rgba(108,92,231,0.5);
        }
        .error-message{
            background:rgba(255,23,68,0.1);
            border:1px solid #ff1744;
            color:#ff5252;
            padding:12px;
            border-radius:8px;
            margin-bottom:20px;
            text-align:center;
            font-size:14px;
        }
    </style>
</head>
<body>
    <div class="bg-glow"></div>
    <div class="bg-glow"></div>
    <div class="login-container">
        <div class="logo">⚡ ProxyFarm Neo</div>
        {% if error %}
        <div class="error-message">{{ error }}</div>
        {% endif %}
        <form method="POST">
            <div class="form-group">
                <label class="form-label">Логин</label>
                <input type="text" name="username" class="form-input" placeholder="Введите логин" required>
            </div>
            <div class="form-group">
                <label class="form-label">Пароль</label>
                <input type="password" name="password" class="form-input" placeholder="Введите пароль" required>
            </div>
            <button type="submit" class="btn-login">Войти</button>
        </form>
    </div>
</body>
</html>
HTMLEOF

# Создание основного index.html (сокращенная версия для скрипта)
cat > /opt/proxy-farm/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ProxyFarm Neo - Dashboard</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-primary: #0a0a0f;
            --bg-secondary: #13131a;
            --bg-tertiary: #1a1a24;
            --bg-card: #1e1e2e;
            --bg-card-hover: #252536;
            --bg-input: #181825;
            --border-color: #2a2a3a;
            --border-glow: #6c5ce7;
            --text-primary: #e4e4f0;
            --text-secondary: #9898b0;
            --text-muted: #666680;
            --accent-purple: #6c5ce7;
            --accent-purple-light: #a29bfe;
            --accent-purple-dark: #4834d4;
            --accent-violet: #8b5cf6;
            --accent-pink: #d63384;
            --success: #00c853;
            --success-glow: #69f0ae;
            --warning: #ffa726;
            --warning-glow: #ffcc80;
            --danger: #ff1744;
            --danger-glow: #ff5252;
            --info: #448aff;
            --info-glow: #82b1ff;
            --gradient-1: linear-gradient(135deg, #6c5ce7, #a29bfe);
            --gradient-2: linear-gradient(135deg, #8b5cf6, #d63384);
            --gradient-3: linear-gradient(135deg, #4834d4, #6c5ce7);
            --shadow-sm: 0 2px 8px rgba(0, 0, 0, 0.3);
            --shadow-md: 0 4px 16px rgba(0, 0, 0, 0.4);
            --shadow-lg: 0 8px 32px rgba(0, 0, 0, 0.5);
            --shadow-glow: 0 0 20px rgba(108, 92, 231, 0.2);
            --radius-sm: 8px;
            --radius-md: 12px;
            --radius-lg: 16px;
            --radius-xl: 20px;
            --transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Inter', sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            overflow-x: hidden;
        }

        .bg-animation {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: -1;
            overflow: hidden;
        }

        .bg-grid {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-image: 
                linear-gradient(var(--border-color) 1px, transparent 1px),
                linear-gradient(90deg, var(--border-color) 1px, transparent 1px);
            background-size: 50px 50px;
            opacity: 0.1;
        }

        .bg-glow {
            position: absolute;
            width: 500px;
            height: 500px;
            border-radius: 50%;
            filter: blur(100px);
            opacity: 0.1;
            animation: float 20s infinite;
        }

        .bg-glow:nth-child(1) { background: var(--accent-purple); top: -10%; left: -10%; }
        .bg-glow:nth-child(2) { background: var(--accent-violet); top: 60%; right: -10%; animation-delay: -7s; }
        .bg-glow:nth-child(3) { background: var(--accent-pink); bottom: -10%; left: 50%; animation-delay: -14s; }

        @keyframes float {
            0%, 100% { transform: translate(0, 0) rotate(0deg); }
            33% { transform: translate(30px, -30px) rotate(120deg); }
            66% { transform: translate(-20px, 20px) rotate(240deg); }
        }

        .app-container { display: flex; min-height: 100vh; }

        .sidebar {
            width: 280px;
            background: var(--bg-secondary);
            border-right: 1px solid var(--border-color);
            padding: 24px;
            display: flex;
            flex-direction: column;
            position: fixed;
            height: 100vh;
            z-index: 100;
            backdrop-filter: blur(10px);
        }

        .logo {
            font-size: 28px;
            font-weight: 700;
            background: var(--gradient-1);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 40px;
            display: flex;
            align-items: center;
            gap: 12px;
        }

        .logo-icon {
            width: 40px;
            height: 40px;
            background: var(--gradient-1);
            border-radius: var(--radius-md);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 20px;
            -webkit-text-fill-color: white;
            box-shadow: var(--shadow-glow);
        }

        .nav-menu { list-style: none; flex: 1; }

        .nav-item { margin-bottom: 8px; }

        .nav-link {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 16px;
            border-radius: var(--radius-md);
            color: var(--text-secondary);
            text-decoration: none;
            transition: var(--transition);
            cursor: pointer;
            border: none;
            background: none;
            width: 100%;
            font-size: 15px;
            font-family: 'Inter', sans-serif;
        }

        .nav-link:hover {
            background: var(--bg-tertiary);
            color: var(--text-primary);
        }

        .nav-link.active {
            background: var(--gradient-3);
            color: white;
            box-shadow: var(--shadow-glow);
        }

        .nav-icon { font-size: 20px; width: 24px; text-align: center; }

        .main-content {
            flex: 1;
            margin-left: 280px;
            padding: 32px;
            min-height: 100vh;
        }

        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 32px;
        }

        .page-title {
            font-size: 32px;
            font-weight: 700;
            background: var(--gradient-1);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .btn {
            padding: 10px 20px;
            border-radius: var(--radius-md);
            border: none;
            font-family: 'Inter', sans-serif;
            font-weight: 500;
            font-size: 14px;
            cursor: pointer;
            transition: var(--transition);
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .btn-primary {
            background: var(--gradient-1);
            color: white;
            box-shadow: var(--shadow-glow);
        }

        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 20px rgba(108, 92, 231, 0.4);
        }

        .btn-danger {
            background: linear-gradient(135deg, var(--danger), #ff5252);
            color: white;
        }

        .btn-success {
            background: linear-gradient(135deg, var(--success), var(--success-glow));
            color: white;
        }

        .btn-outline {
            background: transparent;
            border: 1px solid var(--border-color);
            color: var(--text-secondary);
        }

        .btn-outline:hover {
            border-color: var(--accent-purple);
            color: var(--accent-purple-light);
        }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 32px;
        }

        .stat-card {
            background: var(--bg-card);
            border-radius: var(--radius-lg);
            padding: 24px;
            border: 1px solid var(--border-color);
            transition: var(--transition);
            position: relative;
            overflow: hidden;
        }

        .stat-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 3px;
            background: var(--gradient-1);
        }

        .stat-card:hover {
            border-color: var(--accent-purple);
            transform: translateY(-2px);
            box-shadow: var(--shadow-lg);
        }

        .stat-card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 16px;
        }

        .stat-card-icon {
            width: 48px;
            height: 48px;
            border-radius: var(--radius-md);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
        }

        .stat-card-icon.purple { background: rgba(108, 92, 231, 0.1); color: var(--accent-purple-light); }
        .stat-card-icon.green { background: rgba(0, 200, 83, 0.1); color: var(--success-glow); }
        .stat-card-icon.blue { background: rgba(68, 138, 255, 0.1); color: var(--info-glow); }
        .stat-card-icon.orange { background: rgba(255, 167, 38, 0.1); color: var(--warning-glow); }

        .stat-value {
            font-size: 36px;
            font-weight: 700;
            font-family: 'JetBrains Mono', monospace;
        }

        .stat-label { color: var(--text-secondary); font-size: 14px; margin-top: 4px; }

        .content-section { display: none; }
        .content-section.active { display: block; animation: fadeIn 0.5s ease; }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .form-card {
            background: var(--bg-card);
            border-radius: var(--radius-lg);
            padding: 32px;
            border: 1px solid var(--border-color);
            margin-bottom: 24px;
        }

        .form-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }

        .form-group { display: flex; flex-direction: column; gap: 8px; }

        .form-label {
            color: var(--text-secondary);
            font-size: 13px;
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .form-input {
            background: var(--bg-input);
            border: 1px solid var(--border-color);
            border-radius: var(--radius-sm);
            padding: 12px 16px;
            color: var(--text-primary);
            font-family: 'Inter', sans-serif;
            font-size: 14px;
            transition: var(--transition);
        }

        .form-input:focus {
            outline: none;
            border-color: var(--accent-purple);
            box-shadow: 0 0 0 3px rgba(108, 92, 231, 0.1);
        }

        .proxy-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(380px, 1fr));
            gap: 16px;
            margin-top: 20px;
        }

        .proxy-card {
            background: var(--bg-card);
            border-radius: var(--radius-lg);
            padding: 20px;
            border: 1px solid var(--border-color);
            transition: var(--transition);
            cursor: pointer;
            position: relative;
        }

        .proxy-card:hover {
            border-color: var(--accent-purple);
            box-shadow: var(--shadow-md);
        }

        .proxy-card.selected {
            border-color: var(--accent-purple-light);
            background: var(--bg-card-hover);
            box-shadow: var(--shadow-glow);
        }

        .proxy-card-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            margin-bottom: 16px;
        }

        .proxy-status { display: flex; align-items: center; gap: 8px; }

        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }

        .status-dot.active { background: var(--success-glow); box-shadow: 0 0 10px var(--success); }
        .status-dot.inactive { background: var(--danger-glow); box-shadow: 0 0 10px var(--danger); }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        .proxy-ip {
            font-family: 'JetBrains Mono', monospace;
            font-size: 13px;
            color: var(--accent-purple-light);
            background: rgba(108, 92, 231, 0.1);
            padding: 4px 8px;
            border-radius: 4px;
            word-break: break-all;
        }

        .proxy-details {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 12px;
            margin-top: 16px;
        }

        .proxy-detail-item { display: flex; flex-direction: column; gap: 4px; }
        .proxy-detail-label { font-size: 11px; color: var(--text-muted); text-transform: uppercase; }
        .proxy-detail-value { font-family: 'JetBrains Mono', monospace; font-size: 14px; font-weight: 500; }

        .checkbox-custom {
            width: 20px;
            height: 20px;
            border: 2px solid var(--border-color);
            border-radius: 4px;
            cursor: pointer;
            transition: var(--transition);
            appearance: none;
            -webkit-appearance: none;
            position: relative;
        }

        .checkbox-custom:checked {
            background: var(--accent-purple);
            border-color: var(--accent-purple);
        }

        .checkbox-custom:checked::after {
            content: '✓';
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            color: white;
            font-size: 12px;
        }

        .system-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
        }

        .system-card {
            background: var(--bg-card);
            border-radius: var(--radius-lg);
            padding: 24px;
            border: 1px solid var(--border-color);
        }

        .system-card h3 { font-size: 18px; margin-bottom: 20px; color: var(--accent-purple-light); }

        .progress-bar {
            width: 100%;
            height: 8px;
            background: var(--bg-tertiary);
            border-radius: 4px;
            overflow: hidden;
            margin-top: 8px;
        }

        .progress-fill {
            height: 100%;
            border-radius: 4px;
            transition: width 0.3s ease;
            background: var(--gradient-1);
        }

        .modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0, 0, 0, 0.8);
            z-index: 1000;
            backdrop-filter: blur(5px);
        }

        .modal.active {
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .modal-content {
            background: var(--bg-secondary);
            border-radius: var(--radius-xl);
            padding: 32px;
            max-width: 500px;
            width: 90%;
            border: 1px solid var(--border-color);
            box-shadow: var(--shadow-lg);
        }

        .toast-container {
            position: fixed;
            top: 20px;
            right: 20px;
            z-index: 2000;
        }

        .toast {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: var(--radius-md);
            padding: 16px 20px;
            margin-bottom: 10px;
            animation: slideIn 0.3s ease;
            box-shadow: var(--shadow-md);
        }

        .toast.success { border-left: 4px solid var(--success); }
        .toast.error { border-left: 4px solid var(--danger); }

        @keyframes slideIn {
            from { transform: translateX(100%); opacity: 0; }
            to { transform: translateX(0); opacity: 1; }
        }

        @media (max-width: 768px) {
            .sidebar { width: 60px; padding: 16px 8px; }
            .logo span, .nav-link span { display: none; }
            .main-content { margin-left: 60px; padding: 16px; }
            .proxy-grid { grid-template-columns: 1fr; }
            .stats-grid { grid-template-columns: 1fr; }
            .form-grid { grid-template-columns: 1fr; }
        }

        ::-webkit-scrollbar { width: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-primary); }
        ::-webkit-scrollbar-thumb { background: var(--bg-tertiary); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--accent-purple); }
    </style>
</head>
<body>
    <div class="bg-animation">
        <div class="bg-grid"></div>
        <div class="bg-glow"></div>
        <div class="bg-glow"></div>
        <div class="bg-glow"></div>
    </div>

    <div class="app-container">
        <nav class="sidebar">
            <div class="logo">
                <div class="logo-icon">⚡</div>
                <span>ProxyFarm Neo</span>
            </div>
            <ul class="nav-menu">
                <li class="nav-item">
                    <button class="nav-link active" data-section="dashboard">
                        <span class="nav-icon">📊</span>
                        <span>Дашборд</span>
                    </button>
                </li>
                <li class="nav-item">
                    <button class="nav-link" data-section="proxies">
                        <span class="nav-icon">🌐</span>
                        <span>Прокси</span>
                    </button>
                </li>
                <li class="nav-item">
                    <button class="nav-link" data-section="create">
                        <span class="nav-icon">✨</span>
                        <span>Создать</span>
                    </button>
                </li>
                <li class="nav-item">
                    <button class="nav-link" data-section="system">
                        <span class="nav-icon">🖥️</span>
                        <span>Система</span>
                    </button>
                </li>
            </ul>
            <button class="btn btn-outline" onclick="window.location.href='/logout'" style="width: 100%; justify-content: center;">
                <span>🚪</span> Выйти
            </button>
        </nav>

        <main class="main-content">
            <div class="content-section active" id="dashboard">
                <div class="header">
                    <h1 class="page-title">Дашборд</h1>
                    <button class="btn btn-outline" onclick="refreshData()">🔄 Обновить</button>
                </div>
                <div class="stats-grid" id="statsGrid"></div>
            </div>

            <div class="content-section" id="proxies">
                <div class="header">
                    <h1 class="page-title">Прокси</h1>
                    <div style="display: flex; gap: 12px;">
                        <button class="btn btn-danger" onclick="deleteSelected()" id="deleteSelectedBtn" style="display: none;">🗑️ Удалить</button>
                        <button class="btn btn-outline" onclick="rotateSelected()" id="rotateSelectedBtn" style="display: none;">🔄 Ротировать</button>
                        <button class="btn btn-outline" onclick="checkDuplicates()">🔍 Дубликаты</button>
                    </div>
                </div>
                <div class="proxy-grid" id="proxyGrid"></div>
            </div>

            <div class="content-section" id="create">
                <div class="header">
                    <h1 class="page-title">Создать прокси</h1>
                </div>
                <div class="form-card">
                    <h3 style="margin-bottom: 24px; color: var(--accent-purple-light);">⚡ Создание прокси</h3>
                    <div class="form-grid">
                        <div class="form-group">
                            <label class="form-label">Количество</label>
                            <input type="number" class="form-input" id="proxyCount" value="1" min="1" max="100">
                        </div>
                        <div class="form-group">
                            <label class="form-label">Логин (опционально)</label>
                            <input type="text" class="form-input" id="proxyUsername" placeholder="Авто">
                        </div>
                        <div class="form-group">
                            <label class="form-label">Пароль (опционально)</label>
                            <input type="text" class="form-input" id="proxyPassword" placeholder="Авто">
                        </div>
                    </div>
                    <button class="btn btn-primary" onclick="createProxies()">✨ Создать</button>
                </div>
                <div class="form-card" id="creationResults" style="display: none;">
                    <h3 style="margin-bottom: 16px; color: var(--success-glow);">✅ Созданные прокси</h3>
                    <div id="createdProxiesList"></div>
                </div>
            </div>

            <div class="content-section" id="system">
                <div class="header">
                    <h1 class="page-title">Система</h1>
                    <button class="btn btn-outline" onclick="refreshSystemInfo()">🔄 Обновить</button>
                </div>
                <div id="systemInfo"></div>
            </div>
        </main>
    </div>

    <div class="toast-container" id="toastContainer"></div>

    <div class="modal" id="deleteModal">
        <div class="modal-content">
            <h3 style="margin-bottom: 16px; color: var(--danger-glow);">⚠️ Подтверждение удаления</h3>
            <p style="margin-bottom: 24px; color: var(--text-secondary);">Вы уверены, что хотите удалить выбранные прокси?</p>
            <div style="display: flex; gap: 12px; justify-content: flex-end;">
                <button class="btn btn-outline" onclick="closeModal('deleteModal')">Отмена</button>
                <button class="btn btn-danger" onclick="confirmDelete()">Удалить</button>
            </div>
        </div>
    </div>

    <script src="https://cdnjs.cloudflare.com/ajax/libs/socket.io/4.0.1/socket.io.js"></script>
    <script>
        let selectedProxies = new Set();
        let allProxies = [];
        let socket;

        document.addEventListener('DOMContentLoaded', () => {
            document.querySelectorAll('.nav-link').forEach(link => {
                link.addEventListener('click', (e) => {
                    document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));
                    e.target.closest('.nav-link').classList.add('active');
                    const section = e.target.closest('.nav-link').dataset.section;
                    document.querySelectorAll('.content-section').forEach(s => s.classList.remove('active'));
                    document.getElementById(section).classList.add('active');
                    if (section === 'proxies') loadProxies();
                    if (section === 'dashboard') loadDashboard();
                    if (section === 'system') loadSystemInfo();
                });
            });

            socket = io();
            socket.on('system_update', (data) => {
                const systemSection = document.getElementById('system');
                if (systemSection && systemSection.classList.contains('active')) {
                    renderSystemInfo(data);
                }
            });

            loadDashboard();
        });

        async function apiCall(endpoint, method = 'GET', body = null) {
            try {
                const options = { method, headers: { 'Content-Type': 'application/json' } };
                if (body) options.body = JSON.stringify(body);
                const response = await fetch(endpoint, options);
                const data = await response.json();
                if (!response.ok) throw new Error(data.error || 'Request failed');
                return data;
            } catch (error) {
                showToast(error.message, 'error');
                throw error;
            }
        }

        async function loadDashboard() {
            try {
                const data = await apiCall('/api/proxies');
                updateStats(data.stats);
            } catch (error) {
                console.error('Error loading dashboard:', error);
            }
        }

        function updateStats(stats) {
            document.getElementById('statsGrid').innerHTML = `
                <div class="stat-card">
                    <div class="stat-card-header">
                        <span class="stat-label">Активные прокси</span>
                        <div class="stat-card-icon green">🌐</div>
                    </div>
                    <div class="stat-value">${stats.active}</div>
                    <div class="stat-label">из ${stats.total} всего</div>
                </div>
                <div class="stat-card">
                    <div class="stat-card-header">
                        <span class="stat-label">Доступно IP</span>
                        <div class="stat-card-icon purple">📦</div>
                    </div>
                    <div class="stat-value">${stats.available_ips}</div>
                    <div class="stat-label">IPv6 адресов в пуле</div>
                </div>
                <div class="stat-card">
                    <div class="stat-card-header">
                        <span class="stat-label">Порты</span>
                        <div class="stat-card-icon blue">🔌</div>
                    </div>
                    <div class="stat-value">${stats.ports_available}</div>
                    <div class="stat-label">доступно из ${stats.port_range}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-card-header">
                        <span class="stat-label">Статус</span>
                        <div class="stat-card-icon orange">⚡</div>
                    </div>
                    <div class="stat-value" style="color: var(--success-glow);">Online</div>
                    <div class="stat-label">Сервер работает</div>
                </div>
            `;
        }

        async function loadProxies() {
            try {
                const data = await apiCall('/api/proxies');
                allProxies = data.proxies;
                renderProxies(allProxies);
            } catch (error) {
                console.error('Error loading proxies:', error);
            }
        }

        function renderProxies(proxies) {
            const grid = document.getElementById('proxyGrid');
            if (proxies.length === 0) {
                grid.innerHTML = '<div style="grid-column: 1/-1; text-align: center; padding: 48px; color: var(--text-muted);"><div style="font-size: 48px;">🌐</div><h3>Нет прокси</h3></div>';
                return;
            }
            grid.innerHTML = proxies.map(proxy => `
                <div class="proxy-card ${selectedProxies.has(proxy.id) ? 'selected' : ''}" onclick="toggleProxySelection('${proxy.id}', event)">
                    <div class="proxy-card-header">
                        <div class="proxy-status">
                            <span class="status-dot ${proxy.active ? 'active' : 'inactive'}"></span>
                            <span>${proxy.active ? 'Active' : 'Inactive'}</span>
                        </div>
                        <input type="checkbox" class="checkbox-custom" ${selectedProxies.has(proxy.id) ? 'checked' : ''} onclick="event.stopPropagation(); toggleProxySelection('${proxy.id}')">
                    </div>
                    <div class="proxy-ip">${proxy.ipv6}</div>
                    <div class="proxy-details">
                        <div class="proxy-detail-item">
                            <span class="proxy-detail-label">Порт</span>
                            <span class="proxy-detail-value">${proxy.port}</span>
                        </div>
                        <div class="proxy-detail-item">
                            <span class="proxy-detail-label">Логин</span>
                            <span class="proxy-detail-value">${proxy.username}</span>
                        </div>
                        <div class="proxy-detail-item">
                            <span class="proxy-detail-label">Пароль</span>
                            <span class="proxy-detail-value">${proxy.password}</span>
                        </div>
                        <div class="proxy-detail-item">
                            <span class="proxy-detail-label">Создан</span>
                            <span class="proxy-detail-value">${new Date(proxy.created_at).toLocaleDateString()}</span>
                        </div>
                    </div>
                </div>
            `).join('');
            updateSelectionButtons();
        }

        function toggleProxySelection(id, event) {
            if (event) event.stopPropagation();
            if (selectedProxies.has(id)) selectedProxies.delete(id);
            else selectedProxies.add(id);
            renderProxies(allProxies);
        }

        function updateSelectionButtons() {
            const hasSelection = selectedProxies.size > 0;
            document.getElementById('deleteSelectedBtn').style.display = hasSelection ? 'flex' : 'none';
            document.getElementById('rotateSelectedBtn').style.display = hasSelection ? 'flex' : 'none';
        }

        function deleteSelected() {
            if (selectedProxies.size === 0) return;
            document.getElementById('deleteModal').classList.add('active');
        }

        async function confirmDelete() {
            const ids = Array.from(selectedProxies);
            await apiCall('/api/proxy/delete', 'POST', { ids });
            selectedProxies.clear();
            closeModal('deleteModal');
            showToast('Прокси удалены', 'success');
            loadProxies();
            loadDashboard();
        }

        async function rotateSelected() {
            const ids = Array.from(selectedProxies);
            await apiCall('/api/proxy/rotate', 'POST', { ids });
            showToast('Прокси ротированы', 'success');
            loadProxies();
        }

        async function checkDuplicates() {
            const data = await apiCall('/api/proxy/check-duplicates');
            showToast(data.duplicates > 0 ? `Найдено дубликатов: ${data.duplicates}` : 'Дубликаты не найдены', data.duplicates > 0 ? 'error' : 'success');
        }

        async function createProxies() {
            const count = parseInt(document.getElementById('proxyCount').value) || 1;
            const username = document.getElementById('proxyUsername').value;
            const password = document.getElementById('proxyPassword').value;
            const data = await apiCall('/api/proxy/create', 'POST', { count, username, password });
            const resultsDiv = document.getElementById('creationResults');
            const listDiv = document.getElementById('createdProxiesList');
            resultsDiv.style.display = 'block';
            listDiv.innerHTML = data.proxies.map(p => `
                <div style="background: var(--bg-tertiary); padding: 12px; border-radius: var(--radius-sm); margin-bottom: 8px;">
                    <div style="display: flex; justify-content: space-between; align-items: center;">
                        <span style="font-family: 'JetBrains Mono', monospace;">${p.ipv6}:${p.port}</span>
                        <span style="color: var(--text-muted);">${p.username}:${p.password}</span>
                    </div>
                </div>
            `).join('');
            showToast(`Создано ${data.proxies.length} прокси`, 'success');
            loadProxies();
            loadDashboard();
        }

        async function loadSystemInfo() {
            const data = await apiCall('/api/system-info');
            renderSystemInfo(data);
        }

        function renderSystemInfo(data) {
            const div = document.getElementById('systemInfo');
            const cpuColor = data.cpu_percent > 80 ? 'danger' : data.cpu_percent > 60 ? 'warning' : '';
            const memColor = data.memory_percent > 80 ? 'danger' : data.memory_percent > 60 ? 'warning' : '';
            const diskColor = data.disk_percent > 80 ? 'danger' : data.disk_percent > 60 ? 'warning' : '';
            
            div.innerHTML = `
                <div class="system-grid">
                    <div class="system-card">
                        <h3>🖥️ Процессор</h3>
                        <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
                            <span>Загрузка CPU</span>
                            <span>${data.cpu_percent}%</span>
                        </div>
                        <div class="progress-bar"><div class="progress-fill ${cpuColor}" style="width: ${data.cpu_percent}%"></div></div>
                        <div style="margin-top: 16px; color: var(--text-muted);">Ядер: ${data.cpu_count}</div>
                    </div>
                    <div class="system-card">
                        <h3>💾 Память</h3>
                        <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
                            <span>RAM</span>
                            <span>${data.memory_percent}%</span>
                        </div>
                        <div class="progress-bar"><div class="progress-fill ${memColor}" style="width: ${data.memory_percent}%"></div></div>
                        <div style="margin-top: 16px; color: var(--text-muted);">${data.memory_used} / ${data.memory_total}</div>
                    </div>
                    <div class="system-card">
                        <h3>💿 Диск</h3>
                        <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
                            <span>Занято</span>
                            <span>${data.disk_percent}%</span>
                        </div>
                        <div class="progress-bar"><div class="progress-fill ${diskColor}" style="width: ${data.disk_percent}%"></div></div>
                        <div style="margin-top: 16px; color: var(--text-muted);">${data.disk_used} / ${data.disk_total}</div>
                    </div>
                    <div class="system-card">
                        <h3>🌐 Сеть</h3>
                        <div style="color: var(--text-muted);">
                            <div>IPv4: ${data.ipv4_local}</div>
                            <div>IPv6: ${data.ipv6_main}</div>
                            <div>Внешний: ${data.external_ipv4}</div>
                            <div>TX: ${data.network_sent}</div>
                            <div>RX: ${data.network_recv}</div>
                        </div>
                    </div>
                    <div class="system-card">
                        <h3>📊 Система</h3>
                        <div style="color: var(--text-muted);">
                            <div>Хост: ${data.hostname}</div>
                            <div>ОС: ${data.os}</div>
                            <div>Аптайм: ${data.uptime}</div>
                        </div>
                    </div>
                </div>
            `;
        }

        function showToast(message, type = 'info') {
            const container = document.getElementById('toastContainer');
            const toast = document.createElement('div');
            toast.className = `toast ${type}`;
            toast.textContent = message;
            container.appendChild(toast);
            setTimeout(() => toast.remove(), 3000);
        }

        function closeModal(modalId) {
            document.getElementById(modalId).classList.remove('active');
        }

        function refreshData() {
            loadDashboard();
            loadProxies();
            showToast('Данные обновлены', 'success');
        }

        function refreshSystemInfo() {
            loadSystemInfo();
            showToast('Информация обновлена', 'success');
        }
    </script>
</body>
</html>
HTMLEOF

success "Веб-интерфейс создан"

# ============================================
# Шаг 9: Установка Python зависимостей
# ============================================
progress "Установка Python пакетов..."
cd /opt/proxy-farm
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip setuptools wheel > /dev/null 2>&1
pip install flask flask-login flask-socketio flask-cors psutil requests python-dotenv eventlet > /dev/null 2>&1
success "Python пакеты установлены"

# ============================================
# Шаг 10: Создание systemd сервиса
# ============================================
progress "Создание сервиса ProxyFarm..."
cat > /etc/systemd/system/proxy-farm.service << EOF
[Unit]
Description=ProxyFarm Neo Web Interface
After=network.target 3proxy.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxy-farm
Environment="PATH=/opt/proxy-farm/venv/bin"
ExecStart=/opt/proxy-farm/venv/bin/python /opt/proxy-farm/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
success "Сервис ProxyFarm создан"

# ============================================
# Шаг 11: Настройка прав и запуск
# ============================================
progress "Настройка прав..."
chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py
success "Права настроены"

progress "Запуск сервисов..."
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy
sleep 2
systemctl restart proxy-farm
sleep 2

# Проверка статуса
if systemctl is-active --quiet proxy-farm; then
    success "ProxyFarm успешно запущен"
else
    error "Ошибка запуска ProxyFarm. Проверьте логи: journalctl -u proxy-farm -f"
fi

if systemctl is-active --quiet 3proxy; then
    success "3proxy успешно запущен"
else
    error "Ошибка запуска 3proxy. Проверьте логи: journalctl -u 3proxy -f"
fi

# ============================================
# Готово
# ============================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
echo "║          Установка завершена успешно!                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Веб-интерфейс:                                         ║"
echo "║  Локально:  http://192.168.1.7:2525                     ║"
echo "║  Внешне:    http://62.148.226.89:2525                   ║"
echo "║                                                          ║"
echo "║  Данные для входа:                                       ║"
echo "║  Логин:     admin                                        ║"
echo "║  Пароль:    Maxim1809                                    ║"
echo "║                                                          ║"
echo "║  Прокси порты: 30000-31000                              ║"
echo "║  IPv6 подсеть: 2a01:540:44c4:df00::/64                 ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Команды управления:                                     ║"
echo "║  systemctl status proxy-farm    - статус веб-интерфейса ║"
echo "║  systemctl status 3proxy        - статус прокси-сервера ║"
echo "║  systemctl restart proxy-farm   - перезапуск веб        ║"
echo "║  journalctl -u proxy-farm -f    - логи веб-интерфейса   ║"
echo "╚══════════════════════════════════════════════════════════╝${NC}"
echo ""