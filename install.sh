cat > /root/proxy-farm3/install.sh << 'INSTALLEOF'
#!/bin/bash
set -e

clear
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server v11.0        ║"
echo "║          Автоопределение + фикс IPv4/IPv6              ║"
echo "╚══════════════════════════════════════════════════════════╝"

# === АВТООПРЕДЕЛЕНИЕ ===
echo ""
echo "🔍 Анализ системы..."

IPV4_LOCAL=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
[ -z "$IPV4_LOCAL" ] && IPV4_LOCAL=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)

IPV6_MAIN=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+(?=/64)' | grep -v ^fe80 | head -1)
[ -z "$IPV6_MAIN" ] && IPV6_MAIN=$(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+(?=/64)' | grep -v ^fe80 | head -1)

# Правильная подсеть: первые 4 блока + ::/64
IPV6_SUBNET=$(echo "$IPV6_MAIN" | awk -F: '{print $1":"$2":"$3":"$4"::/64"}')

INTERFACE=$(ip -br l | awk '$1 !~ "lo|vir|wl|@NONE" {print $1}' | head -1)
[ -z "$INTERFACE" ] && INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)

# Внешний IPv4 - ТОЛЬКО IPv4 через curl -4
IPV4_EXTERNAL=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 3 ipinfo.io/ip 2>/dev/null || curl -4 -s --connect-timeout 3 icanhazip.com 2>/dev/null || echo "")

echo ""
echo "=== АВТООПРЕДЕЛЕНИЕ ==="
echo "Локальный IPv4:  $IPV4_LOCAL"
echo "Основной IPv6:   $IPV6_MAIN"
echo "IPv6 подсеть:    $IPV6_SUBNET"
echo "Интерфейс:       $INTERFACE"
echo "Внешний IPv4:    ${IPV4_EXTERNAL:-не определен}"
echo ""

# === ВВОД ДАННЫХ ===
echo "Нажмите ENTER чтобы использовать автоопределение, или введите свои данные:"
echo ""

read -p "Локальный IPv4 [$IPV4_LOCAL]: " input
IPV4_LOCAL=${input:-$IPV4_LOCAL}

read -p "Внешний IPv4 (для клиентов) [${IPV4_EXTERNAL:-введите обязательно}]: " input
IPV4_EXTERNAL=${input:-$IPV4_EXTERNAL}
while [ -z "$IPV4_EXTERNAL" ]; do
    read -p "❌ Внешний IPv4 обязателен! Введите: " IPV4_EXTERNAL
done

read -p "IPv6 подсеть [$IPV6_SUBNET]: " input
IPV6_SUBNET=${input:-$IPV6_SUBNET}

read -p "Основной IPv6 [$IPV6_MAIN]: " input
IPV6_MAIN=${input:-$IPV6_MAIN}

read -p "Сетевой интерфейс [$INTERFACE]: " input
INTERFACE=${input:-$INTERFACE}

read -p "Пароль админа веб-интерфейса [Maxim1809]: " input
ADMIN_PASS=${input:-Maxim1809}

read -p "Начальный порт прокси [30000]: " input
PROXY_START=${input:-30000}

read -p "Конечный порт прокси [31000]: " input
PROXY_END=${input:-31000}

# === ПРОВЕРКА ===
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ПРОВЕРЬТЕ ДАННЫЕ                               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Локальный IPv4:  $IPV4_LOCAL"
echo "║ Внешний IPv4:    $IPV4_EXTERNAL"
echo "║ IPv6 подсеть:    $IPV6_SUBNET"
echo "║ Основной IPv6:   $IPV6_MAIN"
echo "║ Интерфейс:       $INTERFACE"
echo "║ Пароль админа:   $ADMIN_PASS"
echo "║ Порты прокси:    $PROXY_START-$PROXY_END"
echo "╚══════════════════════════════════════════════════════════╝"

read -p "Всё верно? Начать установку? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Установка отменена. Запустите заново: bash install.sh"
    exit 0
fi

# === УСТАНОВКА ===
echo ""
echo "[1/8] Установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential wget tar gzip net-tools curl > /dev/null 2>&1

echo "[2/8] Компиляция 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /dev/null 2>&1
make -f Makefile.Linux install > /dev/null 2>&1

echo "[3/8] Создание структуры..."
mkdir -p /opt/proxy-farm/templates /etc/3proxy /var/log/3proxy
cd /opt/proxy-farm

echo "[4/8] Настройка Python..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip > /dev/null 2>&1
pip install flask flask-login werkzeug psutil > /dev/null 2>&1

echo "[5/8] Создание приложения..."
cat > /opt/proxy-farm/app.py << PYEOF
#!/usr/bin/env python3
import sys, os, json, subprocess, time, socket, ipaddress, random, platform, re, string
from datetime import datetime

sys.path.insert(0, '/opt/proxy-farm/venv/lib/python3/dist-packages')

from flask import Flask, render_template, request, jsonify, redirect, url_for
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user
from werkzeug.security import generate_password_hash, check_password_hash

try:
    import psutil
    PSUTIL = True
except:
    PSUTIL = False

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24).hex()

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

EXTERNAL_IPV4 = "$IPV4_EXTERNAL"
LOCAL_IPV4 = "$IPV4_LOCAL"
IPV6_SUBNET = "$IPV6_SUBNET"
IPV6_MAIN = "$IPV6_MAIN"
INTERFACE = "$INTERFACE"
PROXY_START = $PROXY_START
PROXY_END = $PROXY_END
ADMIN_HASH = generate_password_hash("$ADMIN_PASS")

PROXY_DB = '/opt/proxy-farm/proxies.json'
USERS_DB = '/opt/proxy-farm/users.json'

for f in [PROXY_DB, USERS_DB]:
    if not os.path.exists(f):
        with open(f, 'w') as fh: json.dump([], fh)

class User(UserMixin):
    def __init__(self, id, username, password_hash):
        self.id = id
        self.username = username
        self.password_hash = password_hash

@login_manager.user_loader
def load_user(user_id):
    try:
        with open(USERS_DB) as f: users = json.load(f)
        for u in users:
            if u['id'] == user_id: return User(u['id'], u['username'], u['password'])
    except: pass
    return None

def load_proxies():
    try:
        with open(PROXY_DB) as f: return json.load(f)
    except: return []

def save_proxies(proxies):
    with open(PROXY_DB, 'w') as f: json.dump(proxies, f, indent=2)

def generate_safe_password(length=10):
    chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789'
    return ''.join(random.choice(chars) for _ in range(length))

def generate_safe_username():
    return f"user{random.randint(10000, 99999)}"

def generate_random_ipv6():
    network = ipaddress.ip_network(IPV6_SUBNET)
    return str(network.network_address + random.getrandbits(64))

def add_ipv6(ipv6):
    try:
        result = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'show', 'dev', INTERFACE],
                              capture_output=True, text=True)
        if ipv6 in result.stdout: return True
        for attempt in range(3):
            r = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE],
                             capture_output=True, text=True)
            if r.returncode == 0: return True
            time.sleep(0.5)
        return False
    except: return False

def remove_ipv6(ipv6):
    try:
        subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'del', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True)
    except: pass

def update_3proxy_config():
    try:
        proxies = load_proxies()
        config = """daemon
nserver 1.1.1.1
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

auth strong
"""
        users_added = set()
        for p in proxies:
            if p.get('active', True):
                user_pass = f"{p['username']}:{p['password']}"
                if user_pass not in users_added:
                    config += f"users {p['username']}:CL:{p['password']}\n"
                    users_added.add(user_pass)
        config += "\nallow *\n"
        for p in proxies:
            if p.get('active', True):
                config += f"proxy -6 -n -a -p{p['port']} -i{LOCAL_IPV4} -e{p['ipv6']}\n"
        config += "flush\n"
        with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
        auth = ""
        for p in proxies:
            if p.get('active', True):
                auth += f"{p['username']}:CL:{p['password']}\n"
        with open('/etc/3proxy/.proxyauth', 'w') as f: f.write(auth)
        return True
    except: return False

def restart_3proxy():
    try:
        os.system('pkill -9 3proxy 2>/dev/null')
        time.sleep(3)
        subprocess.Popen('/usr/bin/3proxy /etc/3proxy/3proxy.cfg', shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(5)
        return True
    except: return False

def check_port(port):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1)
        result = sock.connect_ex((LOCAL_IPV4, port))
        sock.close()
        return result == 0
    except: return False

def check_proxy_internet(proxy):
    for attempt in range(3):
        try:
            result = subprocess.run([
                '/usr/bin/curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}",
                '-s', 'http://ip6only.me/api/', '--connect-timeout', '10', '--max-time', '15'
            ], capture_output=True, text=True, timeout=20)
            match = re.search(r'IPv6,([0-9a-f:]+)', result.stdout)
            if match: return {'status': 'working', 'ip': match.group(1), 'type': 'IPv6'}
            if '407' in result.stdout: return {'status': 'error', 'error': 'Auth failed'}
            if attempt < 2: time.sleep(2)
        except:
            if attempt < 2: time.sleep(2)
    return {'status': 'error', 'error': 'No response'}

@app.route('/')
@login_required
def index():
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('username') == 'admin' and check_password_hash(ADMIN_HASH, request.form.get('password')):
            login_user(User('1', 'admin', ADMIN_HASH))
            return redirect(url_for('index'))
        return render_template('login.html', error='Неверные данные')
    return render_template('login.html')

@app.route('/logout')
def logout():
    logout_user()
    return redirect(url_for('login'))

@app.route('/api/proxies')
@login_required
def api_proxies():
    proxies = load_proxies()
    for p in proxies:
        p['connection_format'] = f"http://{EXTERNAL_IPV4}:{p['port']}:{p['username']}:{p['password']}"
        p['port_open'] = check_port(p['port'])
    return jsonify({'proxies': proxies})

@app.route('/api/proxy/create', methods=['POST'])
@login_required
def api_create():
    try:
        data = request.json
        count = int(data.get('count', 1))
        username = data.get('username') or ''
        password = data.get('password') or ''
        proxies = load_proxies()
        used_ports = set(p['port'] for p in proxies)
        available_ports = [p for p in range(PROXY_START, PROXY_END + 1) if p not in used_ports]
        if count > len(available_ports):
            return jsonify({'error': 'Недостаточно портов'}), 400
        created = []
        for i in range(count):
            ipv6 = generate_random_ipv6()
            if not add_ipv6(ipv6): continue
            port = available_ports[i]
            login = username or generate_safe_username()
            passwd = password or generate_safe_password()
            proxy = {
                'id': f"p{port}", 'ipv6': ipv6, 'port': port,
                'username': login, 'password': passwd,
                'created_at': datetime.now().isoformat(), 'active': True,
                'connection_format': f"http://{EXTERNAL_IPV4}:{port}:{login}:{passwd}"
            }
            proxies.append(proxy)
            created.append(proxy)
        save_proxies(proxies)
        update_3proxy_config()
        restart_3proxy()
        return jsonify({'message': f'Создано {len(created)} прокси', 'proxies': created})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/delete', methods=['POST'])
@login_required
def api_delete():
    ids = request.json.get('ids', [])
    proxies = load_proxies()
    for p in proxies:
        if p['id'] in ids: remove_ipv6(p['ipv6'])
    proxies = [p for p in proxies if p['id'] not in ids]
    save_proxies(proxies)
    update_3proxy_config()
    restart_3proxy()
    return jsonify({'message': 'Удалено'})

@app.route('/api/proxy/rotate', methods=['POST'])
@login_required
def api_rotate():
    ids = request.json.get('ids', [])
    proxies = load_proxies()
    for proxy in proxies:
        if proxy['id'] in ids:
            remove_ipv6(proxy['ipv6'])
            proxy['ipv6'] = generate_random_ipv6()
            add_ipv6(proxy['ipv6'])
    save_proxies(proxies)
    update_3proxy_config()
    restart_3proxy()
    return jsonify({'message': 'Ротировано'})

@app.route('/api/proxy/check-all')
@login_required
def check_all():
    proxies = load_proxies()
    results = []
    for p in proxies:
        port_open = check_port(p['port'])
        internet = None
        if port_open: internet = check_proxy_internet(p)
        results.append({'port': p['port'], 'open': port_open, 'ipv6': p['ipv6'], 'internet': internet})
    return jsonify({'total': len(results), 'open': sum(1 for r in results if r['open']), 'working': sum(1 for r in results if r.get('internet') and r['internet'].get('status') == 'working'), 'results': results})

@app.route('/api/proxy/check-duplicates')
@login_required
def check_duplicates():
    proxies = load_proxies()
    seen = {}
    for p in proxies:
        if p['ipv6'] in seen: seen[p['ipv6']].append(p)
        else: seen[p['ipv6']] = [p]
    return jsonify({'duplicates': sum(1 for v in seen.values() if len(v) > 1)})

@app.route('/api/settings/change-password', methods=['POST'])
@login_required
def change_password():
    try:
        data = request.json
        old_password = data.get('old_password', '')
        new_password = data.get('new_password', '')
        if not old_password or not new_password:
            return jsonify({'error': 'Введите старый и новый пароль'}), 400
        if len(new_password) < 6:
            return jsonify({'error': 'Пароль должен быть не менее 6 символов'}), 400
        if not check_password_hash(ADMIN_HASH, old_password):
            return jsonify({'error': 'Неверный текущий пароль'}), 403
        new_hash = generate_password_hash(new_password)
        try:
            with open(USERS_DB) as f: users = json.load(f)
        except: users = []
        for u in users:
            if u.get('username') == 'admin':
                u['password'] = new_hash
        with open(USERS_DB, 'w') as f: json.dump(users, f, indent=2)
        import app as app_module
        app_module.ADMIN_HASH = new_hash
        return jsonify({'message': 'Пароль успешно изменен!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/server/reboot', methods=['POST'])
@login_required
def reboot_server():
    subprocess.Popen('sleep 3 && reboot', shell=True)
    return jsonify({'message': 'Перезагрузка...'})

@app.route('/api/server/restart-3proxy', methods=['POST'])
@login_required
def restart_3proxy_api():
    try:
        update_3proxy_config()
        restart_3proxy()
        return jsonify({'message': '3proxy перезапущен'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    try:
        with open(USERS_DB) as f: users = json.load(f)
    except: users = []
    if not any(u.get('username') == 'admin' for u in users):
        users.append({'id': '1', 'username': 'admin', 'password': ADMIN_HASH})
        with open(USERS_DB, 'w') as f: json.dump(users, f, indent=2)
    update_3proxy_config()
    restart_3proxy()
    app.run(host='0.0.0.0', port=2525, debug=False, threaded=True)
PYEOF

# HTML
echo "[6/8] Создание веб-интерфейса..."
cat > /opt/proxy-farm/templates/login.html << 'HTMLEOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ProxyFarm Neo - Вход</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:Arial,sans-serif;background:linear-gradient(135deg,#0a0a0f,#1a1a2e);min-height:100vh;display:flex;align-items:center;justify-content:center}.login-box{background:rgba(30,30,46,0.95);padding:40px;border-radius:20px;box-shadow:0 10px 40px rgba(0,0,0,0.5);width:380px;max-width:90%;border:1px solid #333}h1{color:#a29bfe;text-align:center;margin-bottom:30px;font-size:28px}input{width:100%;padding:12px;margin:10px 0;background:#1a1a2e;border:1px solid #333;border-radius:8px;color:#fff;font-size:16px}input:focus{outline:none;border-color:#6c5ce7}button{width:100%;padding:12px;background:linear-gradient(135deg,#6c5ce7,#a29bfe);border:none;border-radius:8px;color:#fff;font-size:16px;cursor:pointer;margin-top:10px}button:hover{opacity:0.9}.error{background:rgba(255,0,0,0.1);color:#ff4444;padding:10px;border-radius:8px;margin-bottom:15px;text-align:center}</style></head>
<body><div class="login-box"><h1>⚡ ProxyFarm Neo</h1>{% if error %}<div class="error">{{ error }}</div>{% endif %}<form method="POST"><input type="text" name="username" placeholder="Логин" required><input type="password" name="password" placeholder="Пароль" required><button type="submit">Войти</button></form></div></body></html>
HTMLEOF

# Сервисы
echo "[7/8] Создание сервисов..."
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy
After=network.target
[Service]
Type=forking
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxy-farm.service << 'EOF'
[Unit]
Description=ProxyFarm Web
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxy-farm
Environment="PATH=/opt/proxy-farm/venv/bin"
ExecStart=/opt/proxy-farm/venv/bin/python /opt/proxy-farm/app.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# Тестовые прокси
echo "[8/8] Создание прокси и запуск..."
cd /opt/proxy-farm && source venv/bin/activate
python3 << PYEOF
import json, subprocess, ipaddress, random

INTERFACE = "$INTERFACE"
IPV6_SUBNET = "$IPV6_SUBNET"
IPV4_EXTERNAL = "$IPV4_EXTERNAL"
IPV4_LOCAL = "$IPV4_LOCAL"
PROXY_START = $PROXY_START
network = ipaddress.ip_network(IPV6_SUBNET)
proxies = []

for i in range(5):
    ipv6 = str(network.network_address + random.getrandbits(64))
    port = PROXY_START + i
    login = f"user{port}"
    passwd = f"pass{port}"
    subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True)
    proxies.append({'id': f"p{port}", 'ipv6': ipv6, 'port': port, 'username': login, 'password': passwd, 'created_at': '2026-08-07T00:00:00', 'active': True, 'connection_format': f"http://{IPV4_EXTERNAL}:{port}:{login}:{passwd}"})

with open('/opt/proxy-farm/proxies.json', 'w') as f: json.dump(proxies, f, indent=2)

config = "daemon\nnserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
users_added = set()
for p in proxies:
    u = f"{p['username']}:{p['password']}"
    if u not in users_added:
        config += f"users {p['username']}:CL:{p['password']}\n"
        users_added.add(u)
config += "\nallow *\n"
for p in proxies: config += f"proxy -6 -n -a -p{p['port']} -i{IPV4_LOCAL} -e{p['ipv6']}\n"
config += "flush\n"
with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
auth = ""
for p in proxies: auth += f"{p['username']}:CL:{p['password']}\n"
with open('/etc/3proxy/.proxyauth', 'w') as f: f.write(auth)
print(f"Создано {len(proxies)} тестовых прокси")
PYEOF

chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py

systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          УСТАНОВКА ЗАВЕРШЕНА! v11.0                     ║"
echo "║          http://$IPV4_LOCAL:2525                     ║"
echo "║          Логин: admin / Пароль: $ADMIN_PASS             ║"
echo "║          Прокси: $IPV4_EXTERNAL:$PROXY_START...         ║"
echo "╚══════════════════════════════════════════════════════════╝"
INSTALLEOF

chmod +x /root/proxy-farm3/install.sh
echo ""
echo "========================================="
echo "  ГОТОВО! v11.0 - Фикс автоопределения"
echo "  IPv4 внешний определяется через curl -4"
echo "  IPv6 подсеть правильно вычисляется"
echo "========================================="
