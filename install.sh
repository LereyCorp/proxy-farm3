cat > /root/proxy-farm3/install.sh << 'INSTALLEOF'
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server v3.0         ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Конфигурация
IPV4_LOCAL="192.168.1.7"
IPV4_EXTERNAL="62.148.226.89"
IPV6_SUBNET="2a01:540:44c4:df00::/64"
IPV6_MAIN="2a01:540:44c4:df00:20c:29ff:fe84:71d1"
INTERFACE="ens33"
ADMIN_PASS="Maxim1809"
PROXY_USER="1111"
PROXY_PASS="1111"

# Установка пакетов
echo "[1/10] Установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential git wget tar gzip net-tools curl > /dev/null 2>&1

# Установка 3proxy
echo "[2/10] Установка 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /dev/null 2>&1
make -f Makefile.Linux install > /dev/null 2>&1

# Структура проекта
echo "[3/10] Создание структуры..."
mkdir -p /opt/proxy-farm/templates /etc/3proxy /var/log/3proxy
cd /opt/proxy-farm

# Python окружение
echo "[4/10] Настройка Python..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip > /dev/null 2>&1
pip install flask flask-login werkzeug psutil > /dev/null 2>&1

# Основное приложение
echo "[5/10] Создание приложения..."
cat > /opt/proxy-farm/app.py << 'PYEOF'
#!/usr/bin/env python3
import sys, os, json, subprocess, time, socket, ipaddress, random, platform, re
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
PROXY_USER = "1111"
PROXY_PASS = "1111"
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

def generate_random_ipv6():
    network = ipaddress.ip_network(IPV6_SUBNET)
    random_bits = random.getrandbits(64)
    return str(network.network_address + random_bits)

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

def get_interface_ipv6():
    result = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'show', 'dev', INTERFACE],
                          capture_output=True, text=True)
    ips = []
    for line in result.stdout.split('\n'):
        if 'inet6' in line and 'scope global' in line:
            ips.append(line.strip().split()[1].split('/')[0])
    return ips

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
users 1111:CL:1111

allow *
"""
        for p in proxies:
            if p.get('active', True):
                config += f"proxy -6 -n -a -p{p['port']} -i{LOCAL_IPV4} -e{p['ipv6']}\n"
        config += "flush\n"
        with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
        with open('/etc/3proxy/.proxyauth', 'w') as f: f.write("1111:CL:1111\n")
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
    try:
        result = subprocess.run([
            '/usr/bin/curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}",
            '-s', 'http://ip6only.me/api/', '--connect-timeout', '5', '--max-time', '10'
        ], capture_output=True, text=True, timeout=15)
        match = re.search(r'IPv6,([0-9a-f:]+)', result.stdout)
        if match:
            return {'status': 'working', 'ip': match.group(1), 'type': 'IPv6'}
        return {'status': 'error', 'error': 'No IPv6'}
    except Exception as e:
        return {'status': 'error', 'error': str(e)}

def get_system_info():
    info = {
        'cpu': {'percent': 0, 'count': 0, 'freq_current': 0, 'freq_max': 0},
        'memory': {'percent': 0, 'used': '0', 'total': '0', 'available': '0'},
        'swap': {'percent': 0, 'used': '0', 'total': '0'},
        'disks': [],
        'network': {'sent': '0', 'recv': '0'},
        'system': {
            'hostname': socket.gethostname(),
            'os': f"{platform.system()} {platform.release()}",
            'kernel': platform.release(),
            'architecture': platform.machine(),
            'uptime': 'N/A',
            'load_avg': [0, 0, 0]
        },
        'network_config': {
            'external_ipv4': EXTERNAL_IPV4,
            'local_ipv4': LOCAL_IPV4,
            'ipv6_main': IPV6_MAIN,
            'ipv6_subnet': IPV6_SUBNET
        },
        'proxy_stats': {'active': 0, 'total': 0, 'ports_available': 0},
        'processes': []
    }
    
    if PSUTIL:
        try:
            cpu_percent = psutil.cpu_percent(interval=0.3)
            cpu_count = psutil.cpu_count()
            cpu_freq = psutil.cpu_freq()
            load_avg = os.getloadavg() if hasattr(os, 'getloadavg') else [0, 0, 0]
            
            info['cpu'] = {
                'percent': round(cpu_percent, 1),
                'count': cpu_count,
                'freq_current': round(cpu_freq.current, 1) if cpu_freq else 0,
                'freq_max': round(cpu_freq.max, 1) if cpu_freq and cpu_freq.max else 0
            }
            info['system']['load_avg'] = [round(l, 2) for l in load_avg]
            
            mem = psutil.virtual_memory()
            swap = psutil.swap_memory()
            info['memory'] = {
                'percent': mem.percent,
                'used': f"{mem.used/(1024**3):.1f}",
                'total': f"{mem.total/(1024**3):.1f}",
                'available': f"{mem.available/(1024**3):.1f}"
            }
            info['swap'] = {
                'percent': swap.percent,
                'used': f"{swap.used/(1024**3):.1f}",
                'total': f"{swap.total/(1024**3):.1f}"
            }
            
            for part in psutil.disk_partitions():
                try:
                    usage = psutil.disk_usage(part.mountpoint)
                    info['disks'].append({
                        'mountpoint': part.mountpoint,
                        'total': f"{usage.total/(1024**3):.1f}",
                        'used': f"{usage.used/(1024**3):.1f}",
                        'free': f"{usage.free/(1024**3):.1f}",
                        'percent': usage.percent
                    })
                except: pass
            
            net = psutil.net_io_counters()
            info['network'] = {
                'sent': f"{net.bytes_sent/(1024**2):.1f}",
                'recv': f"{net.bytes_recv/(1024**2):.1f}"
            }
            
            uptime_seconds = int(time.time() - psutil.boot_time())
            hours, minutes, seconds = uptime_seconds // 3600, (uptime_seconds % 3600) // 60, uptime_seconds % 60
            info['system']['uptime'] = f"{hours}ч {minutes}м {seconds}с"
            info['system']['boot_time'] = datetime.fromtimestamp(psutil.boot_time()).strftime('%Y-%m-%d %H:%M:%S')
            
            for proc in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_percent']):
                try:
                    pinfo = proc.info
                    if pinfo['cpu_percent'] and pinfo['cpu_percent'] > 0.1:
                        info['processes'].append({
                            'pid': pinfo['pid'],
                            'name': pinfo['name'][:25],
                            'cpu': round(pinfo['cpu_percent'], 1),
                            'memory': round(pinfo['memory_percent'] or 0, 1)
                        })
                except: pass
            info['processes'] = sorted(info['processes'], key=lambda x: x['cpu'], reverse=True)[:10]
        except Exception as e:
            print(f"System info error: {e}")
    
    proxies = load_proxies()
    info['proxy_stats'] = {
        'active': sum(1 for p in proxies if p.get('active', True)),
        'total': len(proxies),
        'ports_used': len(proxies),
        'ports_available': 1001 - len(proxies)
    }
    
    return info

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

@app.route('/api/system-info')
@login_required
def system_info():
    return jsonify(get_system_info())

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
        username = data.get('username') or PROXY_USER
        password = data.get('password') or PROXY_PASS
        
        proxies = load_proxies()
        used_ports = set(p['port'] for p in proxies)
        available_ports = [p for p in range(30000, 31001) if p not in used_ports]
        
        if count > len(available_ports):
            return jsonify({'error': 'Недостаточно портов'}), 400
        
        created = []
        for i in range(count):
            ipv6 = generate_random_ipv6()
            
            # ГАРАНТИРОВАННО добавляем IPv6 на интерфейс
            for attempt in range(3):
                if add_ipv6(ipv6):
                    break
                time.sleep(0.5)
            
            port = available_ports[i]
            proxy = {
                'id': f"p{port}",
                'ipv6': ipv6,
                'port': port,
                'username': username,
                'password': password,
                'created_at': datetime.now().isoformat(),
                'active': True,
                'connection_format': f"{EXTERNAL_IPV4}:{port}:{username}:{password}"
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
    
    # Проверяем и добавляем недостающие IPv6
    interface_ips = get_interface_ipv6()
    for p in proxies:
        if p['ipv6'] not in interface_ips:
            add_ipv6(p['ipv6'])
    
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
    return jsonify({'duplicates': sum(1 for v in seen.values() if len(v) > 1)})

@app.route('/api/server/reboot', methods=['POST'])
@login_required
def reboot_server():
    subprocess.Popen('sleep 3 && reboot', shell=True)
    return jsonify({'message': 'Перезагрузка...'})

@app.route('/api/server/restart-3proxy', methods=['POST'])
@login_required
def restart_3proxy_api():
    update_3proxy_config()
    restart_3proxy()
    return jsonify({'message': '3proxy перезапущен'})

@app.route('/api/server/speedtest', methods=['GET'])
@login_required
def speedtest():
    try:
        start = time.time()
        subprocess.run(['/usr/bin/curl', '-s', 'http://ipinfo.io/ip', '--connect-timeout', '5'],
                     capture_output=True, timeout=10)
        latency = round((time.time() - start) * 1000, 2)
        return jsonify({'latency_ms': latency, 'status': 'ok'})
    except:
        return jsonify({'latency_ms': 0, 'status': 'error'})

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
echo "[6/10] Создание веб-интерфейса..."
cat > /opt/proxy-farm/templates/login.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ProxyFarm Neo - Вход</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:Arial,sans-serif;background:linear-gradient(135deg,#0a0a0f,#1a1a2e);min-height:100vh;display:flex;align-items:center;justify-content:center}
        .login-box{background:rgba(30,30,46,0.95);padding:40px;border-radius:20px;box-shadow:0 10px 40px rgba(0,0,0,0.5);width:380px;max-width:90%;border:1px solid #333}
        h1{color:#a29bfe;text-align:center;margin-bottom:30px;font-size:28px}
        input{width:100%;padding:12px;margin:10px 0;background:#1a1a2e;border:1px solid #333;border-radius:8px;color:#fff;font-size:16px}
        input:focus{outline:none;border-color:#6c5ce7}
        button{width:100%;padding:12px;background:linear-gradient(135deg,#6c5ce7,#a29bfe);border:none;border-radius:8px;color:#fff;font-size:16px;cursor:pointer;margin-top:10px}
        button:hover{opacity:0.9}
        .error{background:rgba(255,0,0,0.1);color:#ff4444;padding:10px;border-radius:8px;margin-bottom:15px;text-align:center}
    </style>
</head>
<body>
    <div class="login-box">
        <h1>⚡ ProxyFarm Neo</h1>
        {% if error %}<div class="error">{{ error }}</div>{% endif %}
        <form method="POST">
            <input type="text" name="username" placeholder="Логин" required>
            <input type="password" name="password" placeholder="Пароль" required>
            <button type="submit">Войти</button>
        </form>
    </div>
</body>
</html>
HTMLEOF

# Сохраняем текущий index.html если есть
if [ -f /opt/proxy-farm/templates/index.html ]; then
    cp /opt/proxy-farm/templates/index.html /opt/proxy-farm/templates/index.html.bak
fi

# Сервисы
echo "[7/10] Создание сервисов..."
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

# Права
echo "[8/10] Настройка прав..."
chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py

# Создание тестовых прокси
echo "[9/10] Создание тестовых прокси..."
cd /opt/proxy-farm && source venv/bin/activate
python3 << 'PYEOF'
import json, subprocess, ipaddress, random

INTERFACE = "ens33"
IPV6_SUBNET = "2a01:540:44c4:df00::/64"
IPV6_MAIN = "2a01:540:44c4:df00:20c:29ff:fe84:71d1"

proxies = []
network = ipaddress.ip_network(IPV6_SUBNET)

for i in range(5):
    ipv6 = str(network.network_address + random.getrandbits(64))
    port = 30000 + i
    
    # Добавляем на интерфейс
    subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True)
    
    proxies.append({
        'id': f"p{port}",
        'ipv6': ipv6,
        'port': port,
        'username': '1111',
        'password': '1111',
        'created_at': '2026-07-28T00:00:00',
        'active': True,
        'connection_format': f"62.148.226.89:{port}:1111:1111"
    })

with open('/opt/proxy-farm/proxies.json', 'w') as f:
    json.dump(proxies, f, indent=2)

# Конфиг 3proxy
config = """daemon
nserver 1.1.1.1
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535

auth strong
users 1111:CL:1111

allow *
"""
for p in proxies:
    config += f"proxy -6 -n -a -p{p['port']} -i192.168.1.7 -e{p['ipv6']}\n"
config += "flush\n"

with open('/etc/3proxy/3proxy.cfg', 'w') as f:
    f.write(config)
with open('/etc/3proxy/.proxyauth', 'w') as f:
    f.write("1111:CL:1111\n")

print(f"Создано {len(proxies)} тестовых прокси")
PYEOF

# Запуск
echo "[10/10] Запуск сервисов..."
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          УСТАНОВКА ЗАВЕРШЕНА!                           ║"
echo "║          http://192.168.1.7:2525                        ║"
echo "║          http://62.148.226.89:2525                      ║"
echo "║          Логин: admin                                   ║"
echo "║          Пароль: Maxim1809                              ║"
echo "║          Прокси: 1111:1111                              ║"
echo "║          Порты: 30000-31000                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
INSTALLEOF

chmod +x /root/proxy-farm3/install.sh
echo "Готово! Файл install.sh обновлен."
