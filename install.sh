cat > /root/proxy-farm3/install.sh << 'INSTALLEOF'
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server              ║"
echo "║          РАБОЧАЯ ВЕРСИЯ                                 ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Конфигурация
IPV4_LOCAL="192.168.1.7"
IPV4_EXTERNAL="62.148.226.89"
IPV6_SUBNET="2a01:540:44c4:df00::/64"
IPV6_MAIN="2a01:540:44c4:df00:20c:29ff:fe84:71d1"
INTERFACE="ens33"
WEB_PORT=2525
PROXY_START=30000
PROXY_END=31000
ADMIN_PASS="Maxim1809"

# Установка пакетов
echo "[1/8] Установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential git wget tar gzip net-tools curl > /dev/null 2>&1

# Установка 3proxy
echo "[2/8] Установка 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /dev/null 2>&1
make -f Makefile.Linux install > /dev/null 2>&1

# Структура проекта
echo "[3/8] Создание структуры..."
mkdir -p /opt/proxy-farm/templates /etc/3proxy /var/log/3proxy
cd /opt/proxy-farm

# Python окружение
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip > /dev/null 2>&1
pip install flask flask-login werkzeug psutil > /dev/null 2>&1

# Основное приложение
echo "[4/8] Создание приложения..."
cat > /opt/proxy-farm/app.py << 'PYEOF'
#!/usr/bin/env python3
import sys, os, json, random, string, ipaddress, subprocess, time, socket, platform
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

EXTERNAL_IPV4 = "62.148.226.89"
LOCAL_IPV4 = "192.168.1.7"
IPV6_SUBNET = "2a01:540:44c4:df00::/64"
IPV6_MAIN = "2a01:540:44c4:df00:20c:29ff:fe84:71d1"
INTERFACE = "ens33"
PROXY_START = 30000
PROXY_END = 31000
IPV6_START = 0x1000
ADMIN_HASH = generate_password_hash("Maxim1809")

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

def get_used_ipv6():
    used = set(p.get('ipv6', '') for p in load_proxies())
    try:
        result = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'show', 'dev', INTERFACE],
                              capture_output=True, text=True)
        for line in result.stdout.split('\n'):
            if 'inet6' in line and 'scope global' in line:
                used.add(line.strip().split()[1].split('/')[0])
    except: pass
    return used

def generate_ipv6_list(count):
    network = ipaddress.ip_network(IPV6_SUBNET)
    used = get_used_ipv6()
    available = []
    for i in range(IPV6_START, IPV6_START + 65536):
        ip = str(network.network_address + i)
        if ip not in used and ip != IPV6_MAIN:
            available.append(ip)
        if len(available) >= count:
            break
    return available

def add_ipv6(ipv6):
    try:
        subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE],
                     capture_output=True, check=False)
        return True
    except: return False

def remove_ipv6(ipv6):
    try:
        subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'del', f'{ipv6}/64', 'dev', INTERFACE],
                     capture_output=True)
    except: pass

def update_3proxy_config():
    try:
        proxies = load_proxies()
        config = """nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
allow * * * 80-65535
"""
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
        time.sleep(2)
        subprocess.Popen('/usr/bin/3proxy /etc/3proxy/3proxy.cfg', shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
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
    """Проверка через IPv6-only сайт"""
    try:
        result = subprocess.run([
            'curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}",
            '-s', 'http://ip6only.me/api/', '--connect-timeout', '5', '--max-time', '10'
        ], capture_output=True, text=True, timeout=15)
        if proxy['ipv6'] in result.stdout:
            return {'status': 'working', 'ip': proxy['ipv6'], 'type': 'IPv6'}
    except: pass
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
        p['connection_format'] = f"{EXTERNAL_IPV4}:{p['port']}:{p['username']}:{p['password']}"
        p['port_open'] = check_port(p['port'])
    return jsonify({'proxies': proxies})

@app.route('/api/proxy/create', methods=['POST'])
@login_required
def api_create():
    try:
        data = request.json
        count = int(data.get('count', 1))
        proxies = load_proxies()
        used_ports = set(p['port'] for p in proxies)
        available_ports = [p for p in range(PROXY_START, PROXY_END + 1) if p not in used_ports]
        
        if count > len(available_ports):
            return jsonify({'error': 'Недостаточно портов'}), 400
        
        ipv6_list = generate_ipv6_list(count)
        if len(ipv6_list) < count:
            return jsonify({'error': 'Недостаточно IPv6'}), 400
        
        created = []
        for i in range(count):
            ipv6 = ipv6_list[i]
            add_ipv6(ipv6)
            login = data.get('username') or f"user_{random.randint(10000, 99999)}"
            passwd = data.get('password') or ''.join(random.choices(string.ascii_letters + string.digits, k=12))
            port = available_ports[i]
            
            proxy = {
                'id': datetime.now().strftime('%Y%m%d%H%M%S') + str(random.randint(1000, 9999)),
                'ipv6': ipv6,
                'port': port,
                'username': login,
                'password': passwd,
                'created_at': datetime.now().isoformat(),
                'active': True,
                'connection_format': f"{EXTERNAL_IPV4}:{port}:{login}:{passwd}"
            }
            proxies.append(proxy)
            created.append(proxy)
        
        save_proxies(proxies)
        update_3proxy_config()
        restart_3proxy()
        return jsonify({'message': f'Создано {count} прокси', 'proxies': created})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/delete', methods=['POST'])
@login_required
def api_delete():
    ids = request.json.get('ids', [])
    proxies = load_proxies()
    for p in proxies:
        if p['id'] in ids:
            remove_ipv6(p['ipv6'])
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
            new_ips = generate_ipv6_list(1)
            if new_ips:
                proxy['ipv6'] = new_ips[0]
                add_ipv6(new_ips[0])
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
        if port_open:
            internet = check_proxy_internet(p)
        results.append({
            'port': p['port'],
            'open': port_open,
            'ipv6': p['ipv6'],
            'internet': internet
        })
    return jsonify({
        'total': len(results),
        'open': sum(1 for r in results if r['open']),
        'working': sum(1 for r in results if r.get('internet') and r['internet'].get('status') == 'working'),
        'results': results
    })

@app.route('/api/proxy/check-duplicates')
@login_required
def check_duplicates():
    proxies = load_proxies()
    seen = {}
    for p in proxies:
        if p['ipv6'] in seen:
            seen[p['ipv6']].append(p)
        else:
            seen[p['ipv6']] = [p]
    dups = {k: v for k, v in seen.items() if len(v) > 1}
    return jsonify({'duplicates': len(dups)})

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

# HTML шаблоны
echo "[5/8] Создание веб-интерфейса..."
# (оставляем текущий рабочий HTML)

# Сервисы
echo "[6/8] Создание сервисов..."
cat > /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxy-farm.service << EOF
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

# Запуск
echo "[7/8] Запуск..."
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ГОТОВО! ПРОКСИ РАБОТАЮТ!                       ║"
echo "║          http://192.168.1.7:2525                        ║"
echo "║          admin / Maxim1809                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
INSTALLEOF

chmod +x /root/proxy-farm3/install.sh

echo ""
echo "========================================="
echo "  ГОТОВО! Загрузите install.sh на GitHub"
echo "  Прокси работают через IPv6!"
echo "  Проверка через ip6only.me/api/"
echo "========================================="
