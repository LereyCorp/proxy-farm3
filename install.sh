cat > /root/proxy-farm3/install.sh << 'INSTALLEOF'
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server v5.0         ║"
echo "║          Фикс паролей + проверка сайтов                 ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Конфигурация
IPV4_LOCAL="192.168.1.7"
IPV4_EXTERNAL="62.148.226.89"
IPV6_SUBNET="2a01:540:44c4:df00::/64"
IPV6_MAIN="2a01:540:44c4:df00:20c:29ff:fe84:71d1"
INTERFACE="ens33"
ADMIN_PASS="Maxim1809"

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

def generate_safe_password(length=10):
    """Генерация пароля БЕЗ спецсимволов"""
    chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789'
    return ''.join(random.choice(chars) for _ in range(length))

def generate_safe_username():
    """Генерация логина БЕЗ спецсимволов"""
    return f"user{random.randint(10000, 99999)}"

def generate_random_ipv6():
    network = ipaddress.ip_network(IPV6_SUBNET)
    random_bits = random.getrandbits(64)
    return str(network.network_address + random_bits)

def add_ipv6(ipv6):
    try:
        result = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'show', 'dev', INTERFACE],
                              capture_output=True, text=True)
        if ipv6 in result.stdout:
            return True
        for attempt in range(3):
            r = subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE],
                             capture_output=True, text=True)
            if r.returncode == 0:
                return True
            time.sleep(0.5)
        return False
    except:
        return False

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

def check_website_via_proxy(proxy, url):
    """Проверка сайта через прокси"""
    try:
        result = subprocess.run([
            '/usr/bin/curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}",
            '-s', '-o', '/dev/null', '-w', '%{http_code}', url,
            '--connect-timeout', '10', '--max-time', '15'
        ], capture_output=True, text=True, timeout=20)
        http_code = result.stdout.strip()
        return {'url': url, 'http_code': http_code, 'accessible': http_code in ['200', '301', '302', '403']}
    except Exception as e:
        return {'url': url, 'http_code': '0', 'accessible': False, 'error': str(e)}

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
        username = data.get('username') or ''
        password = data.get('password') or ''
        
        proxies = load_proxies()
        used_ports = set(p['port'] for p in proxies)
        available_ports = [p for p in range(30000, 31001) if p not in used_ports]
        
        if count > len(available_ports):
            return jsonify({'error': 'Недостаточно портов'}), 400
        
        created = []
        for i in range(count):
            ipv6 = generate_random_ipv6()
            if not add_ipv6(ipv6):
                continue
            
            port = available_ports[i]
            # БЕЗОПАСНЫЕ логин/пароль без спецсимволов
            login = username or generate_safe_username()
            passwd = password or generate_safe_password()
            
            proxy = {
                'id': f"p{port}",
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
        
        return jsonify({'message': f'Создано {len(created)} прокси', 'proxies': created})
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

@app.route('/api/proxy/check-website', methods=['POST'])
@login_required
def check_website():
    """Проверка сайта через выбранный прокси"""
    try:
        data = request.json
        proxy_id = data.get('proxy_id')
        url = data.get('url', 'http://ipv6.google.com')
        
        proxies = load_proxies()
        proxy = next((p for p in proxies if p['id'] == proxy_id), None)
        if not proxy:
            # Если прокси не выбран, берем первый
            proxy = proxies[0] if proxies else None
        if not proxy:
            return jsonify({'error': 'Нет доступных прокси'}), 400
        
        # Добавляем http:// если нет
        if not url.startswith('http'):
            url = 'http://' + url
        
        result = check_website_via_proxy(proxy, url)
        result['proxy'] = f"{proxy['port']}:{proxy['username']}"
        result['ipv6'] = proxy['ipv6']
        
        return jsonify(result)
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
    update_3proxy_config()
    restart_3proxy()
    return jsonify({'message': '3proxy перезапущен'})

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
    <div class="login-box"><h1>⚡ ProxyFarm Neo</h1>
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

cat > /opt/proxy-farm/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ProxyFarm Neo</title>
    <style>
        :root{--bg:#0a0a0f;--card:#1e1e2e;--purple:#6c5ce7;--text:#e4e4f0;--text2:#9898b0;--green:#00c853;--red:#ff1744;--yellow:#ffa726}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:Arial,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
        .tabs{display:flex;background:#13131a;padding:10px 20px;gap:5px;flex-wrap:wrap;border-bottom:1px solid #2a2a3a;position:sticky;top:0;z-index:100}
        .tab-btn{padding:12px 20px;background:none;border:none;color:var(--text2);cursor:pointer;border-radius:8px;font-size:14px;transition:.2s;white-space:nowrap}
        .tab-btn:hover{background:#1a1a24;color:#fff}
        .tab-btn.active{background:linear-gradient(135deg,#6c5ce7,#4834d4);color:#fff}
        .logo-tab{background:linear-gradient(135deg,#6c5ce7,#a29bfe);-webkit-background-clip:text;-webkit-text-fill-color:transparent;font-weight:bold;font-size:16px;margin-right:15px}
        .main{padding:20px;max-width:1400px;margin:0 auto}
        .dashboard-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:15px;margin-bottom:20px}
        .stat-card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a;transition:.3s}
        .stat-card:hover{border-color:var(--purple);transform:translateY(-2px)}
        .stat-icon{font-size:32px;margin-bottom:10px}
        .stat-value{font-size:32px;font-weight:bold;color:#a29bfe}
        .stat-label{color:var(--text2);font-size:13px;margin-top:5px}
        .stat-sub{color:var(--text2);font-size:11px;margin-top:3px}
        .row{display:grid;grid-template-columns:repeat(auto-fit,minmax(400px,1fr));gap:20px;margin-bottom:20px}
        .card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a}
        .card h3{color:#a29bfe;margin-bottom:15px;font-size:18px}
        .btn{padding:8px 16px;border:none;border-radius:8px;font-size:13px;margin:3px;cursor:pointer;color:#fff;background:linear-gradient(135deg,#6c5ce7,#a29bfe);transition:.2s}
        .btn:hover{opacity:0.9;transform:translateY(-1px)}
        .btn-danger{background:linear-gradient(135deg,#ff1744,#ff5252)}
        .btn-success{background:linear-gradient(135deg,#00c853,#69f0ae)}
        .btn-warning{background:linear-gradient(135deg,#ffa726,#ffcc80)}
        .proxy-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(380px,1fr));gap:15px}
        .proxy-card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a;position:relative;transition:.2s;cursor:pointer}
        .proxy-card:hover{border-color:var(--purple)}
        .proxy-card.selected{border-color:#a29bfe;box-shadow:0 0 15px rgba(108,92,231,0.3)}
        .proxy-format{background:#1a1a24;padding:12px;border-radius:8px;font-family:monospace;font-size:12px;color:#00ff88;text-align:center;word-break:break-all;margin:10px 0}
        .copy-btn{display:block;width:100%;padding:10px;background:#6c5ce7;color:#fff;border:none;border-radius:6px;font-size:13px;cursor:pointer;text-align:center}
        .copy-btn:hover{background:#4834d4}
        .section{display:none}
        .section.active{display:block}
        .form-input{width:100%;padding:12px;margin:8px 0;background:#181825;border:1px solid #2a2a3a;border-radius:8px;color:#fff;font-size:14px}
        .form-input:focus{outline:none;border-color:#6c5ce7}
        .form-label{color:var(--text2);font-size:11px;display:block;margin-bottom:5px;text-transform:uppercase}
        select.form-input{appearance:auto}
        .sys-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(350px,1fr));gap:15px}
        .sys-card{background:var(--card);padding:18px;border-radius:12px;border:1px solid #2a2a3a}
        .sys-card h3{color:#a29bfe;margin-bottom:10px}
        .sys-value{font-size:28px;color:#fff;margin:5px 0}
        .sys-detail{color:var(--text2);font-size:12px;margin:3px 0}
        .progress{background:#1a1a24;height:8px;border-radius:4px;margin-top:8px}
        .progress-fill{background:linear-gradient(135deg,#6c5ce7,#a29bfe);height:100%;border-radius:4px;transition:width 0.5s}
        .check-table{width:100%;border-collapse:collapse;font-size:13px;margin-top:10px}
        .check-table th,.check-table td{padding:10px;text-align:left;border-bottom:1px solid #2a2a3a}
        .check-table th{color:var(--text2)}
        .toast{position:fixed;top:20px;right:20px;background:var(--card);padding:15px 20px;border-radius:8px;z-index:9999;animation:slideIn .3s}
        .toast.success{border-left:4px solid var(--green)}
        .toast.error{border-left:4px solid var(--red)}
        @keyframes slideIn{from{transform:translateX(100%)}to{transform:translateX(0)}}
        @media(max-width:768px){.tabs{padding:10px;gap:3px}.tab-btn{padding:8px 12px;font-size:11px}.main{padding:10px}.dashboard-grid{grid-template-columns:repeat(2,1fr);gap:8px}.stat-value{font-size:24px}.proxy-grid,.sys-grid{grid-template-columns:1fr}.row{grid-template-columns:1fr}}
    </style>
</head>
<body>
    <div class="tabs">
        <span class="logo-tab">⚡ ProxyFarm Neo</span>
        <button class="tab-btn active" onclick="showTab('dashboard',this)">📊 Дашборд</button>
        <button class="tab-btn" onclick="showTab('proxies',this)">🌐 Прокси</button>
        <button class="tab-btn" onclick="showTab('create',this)">✨ Создать</button>
        <button class="tab-btn" onclick="showTab('checker',this)">🔍 Проверка</button>
        <button class="tab-btn" onclick="showTab('sitetest',this)">🌍 Тест сайтов</button>
        <button class="tab-btn" onclick="showTab('system',this)">🖥️ Система</button>
        <button class="tab-btn" onclick="showTab('tools',this)">🔧 Инструменты</button>
        <button class="tab-btn" onclick="window.location.href='/logout'" style="margin-left:auto">🚪 Выйти</button>
    </div>
    <main class="main">
        <div class="section active" id="dashboard">
            <div class="dashboard-grid" id="dashStats"></div>
            <div class="row">
                <div class="card"><h3>📈 CPU</h3><div class="progress" style="height:20px"><div class="progress-fill" id="cpuBar" style="width:0%"></div></div><div style="text-align:center;margin-top:5px;font-size:24px;color:#a29bfe" id="cpuValue">0%</div></div>
                <div class="card"><h3>💾 RAM</h3><div class="progress" style="height:20px"><div class="progress-fill" id="ramBar" style="width:0%;background:linear-gradient(135deg,#00c853,#69f0ae)"></div></div><div style="text-align:center;margin-top:5px;font-size:24px;color:#69f0ae" id="ramValue">0%</div></div>
            </div>
            <div class="row">
                <div class="card"><h3>🌐 Прокси</h3><div id="proxyStatsDash"></div></div>
                <div class="card"><h3>⚡ Действия</h3>
                    <button class="btn btn-warning" onclick="restart3proxy()">🔄 3proxy</button>
                    <button class="btn btn-danger" onclick="rebootServer()">🔌 Reboot</button>
                </div>
            </div>
        </div>
        <div class="section" id="proxies">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:15px;flex-wrap:wrap;gap:10px">
                <h2 style="color:#a29bfe">Список прокси</h2>
                <div>
                    <button class="btn btn-success" onclick="exportProxies()">📥 Экспорт</button>
                    <button class="btn" onclick="checkDuplicates()">🔍 Дубликаты</button>
                    <button class="btn" onclick="rotateSelected()" id="rotateBtn" style="display:none">🔄 Ротировать</button>
                    <button class="btn btn-danger" onclick="deleteSelected()" id="delBtn" style="display:none">🗑️ Удалить</button>
                </div>
            </div>
            <div class="proxy-grid" id="proxyList"></div>
        </div>
        <div class="section" id="create">
            <h2 style="color:#a29bfe;margin-bottom:15px">Создание прокси</h2>
            <div class="card">
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:15px">
                    <div><label class="form-label">Количество</label><input type="number" class="form-input" id="count" value="1" min="1" max="100"></div>
                    <div><label class="form-label">Логин (пусто=авто)</label><input type="text" class="form-input" id="username" placeholder="Авто"></div>
                    <div><label class="form-label">Пароль (пусто=авто)</label><input type="text" class="form-input" id="password" placeholder="Авто"></div>
                </div>
                <button class="btn" onclick="createProxies()" style="width:100%;margin-top:15px;padding:14px;font-size:16px">✨ Создать прокси</button>
            </div>
            <div id="results"></div>
        </div>
        <div class="section" id="checker">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:15px">
                <h2 style="color:#a29bfe">Проверка прокси</h2>
                <button class="btn" onclick="checkAll()">🔍 Проверить всё</button>
            </div>
            <div class="card"><div id="checkResults">Нажмите "Проверить всё"</div></div>
        </div>
        <div class="section" id="sitetest">
            <h2 style="color:#a29bfe;margin-bottom:15px">🌍 Тест сайтов через прокси</h2>
            <div class="card">
                <div style="display:grid;grid-template-columns:1fr 2fr 1fr;gap:10px;align-items:end">
                    <div>
                        <label class="form-label">Прокси (порт)</label>
                        <select class="form-input" id="testProxy"></select>
                    </div>
                    <div>
                        <label class="form-label">URL сайта</label>
                        <input type="text" class="form-input" id="testUrl" value="ipv6.google.com" placeholder="google.com">
                    </div>
                    <div>
                        <button class="btn btn-success" onclick="testWebsite()" style="width:100%">🔍 Проверить</button>
                    </div>
                </div>
                <div id="siteTestResult" style="margin-top:15px"></div>
                <div style="margin-top:10px;color:var(--text2);font-size:11px">
                    Популярные IPv6 сайты: ipv6.google.com, ip6only.me, whatismyv6.com
                </div>
            </div>
        </div>
        <div class="section" id="system">
            <h2 style="color:#a29bfe;margin-bottom:15px">Системная информация</h2>
            <div class="sys-grid" id="sysInfo"></div>
        </div>
        <div class="section" id="tools">
            <h2 style="color:#a29bfe;margin-bottom:15px">Инструменты</h2>
            <div class="row">
                <div class="card"><h3>🔧 Управление</h3>
                    <button class="btn btn-warning" onclick="restart3proxy()">🔄 Перезапустить 3proxy</button>
                    <button class="btn btn-danger" onclick="rebootServer()">🔌 Перезагрузить сервер</button>
                </div>
            </div>
        </div>
    </main>
    <div id="toasts"></div>
    <script>
        var selectedProxies=[];
        function showTab(n,b){document.querySelectorAll('.section').forEach(function(s){s.classList.remove('active')});document.getElementById(n).classList.add('active');document.querySelectorAll('.tab-btn').forEach(function(x){x.classList.remove('active')});if(b)b.classList.add('active');if(n==='proxies')loadProxies();if(n==='dashboard')loadDashboard();if(n==='system')loadSystem();if(n==='sitetest')loadProxySelect()}
        function api(u,m,b,c){m=m||'GET';var x=new XMLHttpRequest();x.open(m,u,true);x.setRequestHeader('Content-Type','application/json');x.onload=function(){c(x.status===200?JSON.parse(x.responseText):{})};x.onerror=function(){c({})};x.send(b?JSON.stringify(b):null)}
        function toast(m,t){t=t||'success';var d=document.createElement('div');d.className='toast '+t;d.textContent=m;document.getElementById('toasts').appendChild(d);setTimeout(function(){d.remove()},3000)}
        function copyText(t){var i=document.createElement('textarea');i.value=t;i.style.position='fixed';i.style.opacity='0';document.body.appendChild(i);i.select();document.execCommand('copy');document.body.removeChild(i);toast('Скопировано!')}
        function loadDashboard(){api('/api/system-info','GET',null,function(d){document.getElementById('dashStats').innerHTML='<div class="stat-card"><div class="stat-icon">🌐</div><div class="stat-value">'+(d.proxy_stats?d.proxy_stats.active:0)+'</div><div class="stat-label">Активных</div></div><div class="stat-card"><div class="stat-icon">🔌</div><div class="stat-value">'+(d.proxy_stats?d.proxy_stats.ports_available:0)+'</div><div class="stat-label">Портов</div></div><div class="stat-card"><div class="stat-icon">🖥️</div><div class="stat-value">'+(d.cpu?d.cpu.percent:0)+'%</div><div class="stat-label">CPU</div></div><div class="stat-card"><div class="stat-icon">💾</div><div class="stat-value">'+(d.memory?d.memory.percent:0)+'%</div><div class="stat-label">RAM</div></div>';document.getElementById('cpuBar').style.width=(d.cpu?d.cpu.percent:0)+'%';document.getElementById('cpuValue').textContent=(d.cpu?d.cpu.percent:0)+'%';document.getElementById('ramBar').style.width=(d.memory?d.memory.percent:0)+'%';document.getElementById('ramValue').textContent=(d.memory?d.memory.percent:0)+'%';document.getElementById('proxyStatsDash').innerHTML='<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px;text-align:center"><div><div style="font-size:24px;color:#00c853">'+(d.proxy_stats?d.proxy_stats.active:0)+'</div><div style="font-size:11px;color:var(--text2)">Активные</div></div><div><div style="font-size:24px;color:#ffa726">'+(d.proxy_stats?d.proxy_stats.total:0)+'</div><div style="font-size:11px;color:var(--text2)">Всего</div></div><div><div style="font-size:24px;color:#448aff">'+(d.proxy_stats?d.proxy_stats.ports_available:0)+'</div><div style="font-size:11px;color:var(--text2)">Свободно</div></div></div>'})}
        function loadProxies(){api('/api/proxies','GET',null,function(d){var l=document.getElementById('proxyList');if(!d.proxies||d.proxies.length===0){l.innerHTML='<div style="text-align:center;padding:40px;color:#666"><h3>Нет прокси</h3></div>';return}var h='';for(var i=0;i<d.proxies.length;i++){var p=d.proxies[i];var s=selectedProxies.indexOf(p.id)>=0?' selected':'';var sc=p.port_open?'var(--green)':'var(--red)';var st=p.port_open?'Открыт':'Закрыт';h+='<div class="proxy-card'+s+'" onclick="selectProxy(\''+p.id+'\')"><div style="position:absolute;top:12px;right:12px"><span style="color:'+sc+';font-weight:bold">● '+st+'</span></div><div style="font-weight:bold;margin-bottom:8px">Порт '+p.port+' | '+p.username+':'+p.password+'</div><div class="proxy-format">'+(p.connection_format||'')+'</div><button class="copy-btn" onclick="event.stopPropagation();copyText(\''+(p.connection_format||'')+'\')">📋 Копировать</button></div>'}l.innerHTML=h;document.getElementById('delBtn').style.display=selectedProxies.length>0?'inline-block':'none';document.getElementById('rotateBtn').style.display=selectedProxies.length>0?'inline-block':'none'})}
        function selectProxy(id){var i=selectedProxies.indexOf(id);if(i>=0)selectedProxies.splice(i,1);else selectedProxies.push(id);loadProxies()}
        function deleteSelected(){if(selectedProxies.length===0)return;if(!confirm('Удалить?'))return;api('/api/proxy/delete','POST',{ids:selectedProxies},function(){selectedProxies=[];toast('Удалено');loadProxies();loadDashboard()})}
        function rotateSelected(){if(selectedProxies.length===0)return;api('/api/proxy/rotate','POST',{ids:selectedProxies},function(){toast('Ротировано');loadProxies()})}
        function createProxies(){var c=parseInt(document.getElementById('count').value)||1;api('/api/proxy/create','POST',{count:c,username:document.getElementById('username').value,password:document.getElementById('password').value},function(d){if(d.error){toast(d.error,'error');return}var h='<div class="card" style="margin-top:15px"><h3 style="color:#00c853">✅ Создано '+c+'</h3>';for(var i=0;i<d.proxies.length;i++){var f=d.proxies[i].connection_format;h+='<div style="background:#1a1a24;padding:12px;margin:8px 0;border-radius:8px"><div style="font-family:monospace;color:#00ff88;text-align:center;margin-bottom:8px">'+f+'</div><button class="copy-btn" onclick="copyText(\''+f+'\')">📋 Копировать</button></div>'}h+='</div>';document.getElementById('results').innerHTML=h;toast('Создано '+c+' прокси');loadProxies();loadDashboard()})}
        function exportProxies(){api('/api/proxies','GET',null,function(d){if(!d.proxies||d.proxies.length===0){toast('Нет прокси','error');return}var t='';for(var i=0;i<d.proxies.length;i++)t+=d.proxies[i].connection_format+'\n';var b=new Blob([t],{type:'text/plain'});var a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='proxies.txt';a.click();toast('Экспортировано')})}
        function checkAll(){document.getElementById('checkResults').innerHTML='<div style="text-align:center;padding:20px">⏳ Проверка...</div>';api('/api/proxy/check-all','GET',null,function(d){var h='<h3 style="color:#a29bfe;margin-bottom:10px">Результаты</h3>';h+='<div style="margin-bottom:10px">Всего: <b>'+d.total+'</b> | Открыто: <b style="color:#00c853">'+d.open+'</b> | Работает: <b style="color:#00c853">'+d.working+'</b></div>';h+='<table class="check-table"><tr><th>Порт</th><th>Порт</th><th>Интернет</th><th>IP</th></tr>';for(var i=0;i<d.results.length;i++){var r=d.results[i];var ps=r.open?'<span style="color:#00c853">✅ Открыт</span>':'<span style="color:#ff1744">❌ Закрыт</span>';var ins=!r.open?'<span style="color:#666">-</span>':(r.internet&&r.internet.status==='working'?'<span style="color:#00c853">✅ IPv6</span>':'<span style="color:#ff1744">❌ Нет</span>');var ip=(r.internet&&r.internet.ip)?'<span style="font-size:10px">'+r.internet.ip+'</span>':'-';h+='<tr><td><b>'+r.port+'</b></td><td>'+ps+'</td><td>'+ins+'</td><td>'+ip+'</td></tr>'}h+='</table>';document.getElementById('checkResults').innerHTML=h;toast('Проверено '+d.total+' прокси')})}
        function checkDuplicates(){api('/api/proxy/check-duplicates','GET',null,function(d){toast(d.duplicates>0?'Дубликатов: '+d.duplicates:'Дубликатов нет',d.duplicates>0?'error':'success')})}
        function loadProxySelect(){api('/api/proxies','GET',null,function(d){var s=document.getElementById('testProxy');s.innerHTML='';if(d.proxies)for(var i=0;i<d.proxies.length;i++){var p=d.proxies[i];s.innerHTML+='<option value="'+p.id+'">Порт '+p.port+' ('+p.username+':'+p.password+')</option>'}})}
        function testWebsite(){var pid=document.getElementById('testProxy').value;var url=document.getElementById('testUrl').value;document.getElementById('siteTestResult').innerHTML='<div style="text-align:center;padding:20px">⏳ Проверка '+url+'...</div>';api('/api/proxy/check-website','POST',{proxy_id:pid,url:url},function(d){if(d.error){document.getElementById('siteTestResult').innerHTML='<div style="color:#ff1744">❌ '+d.error+'</div>';return}var color=d.accessible?'#00c853':'#ff1744';var icon=d.accessible?'✅':'❌';document.getElementById('siteTestResult').innerHTML='<div style="background:#1a1a24;padding:15px;border-radius:8px"><div style="font-size:18px;color:'+color+';margin-bottom:10px">'+icon+' HTTP '+d.http_code+' - '+d.url+'</div><div style="color:var(--text2);font-size:12px">Прокси: '+d.proxy+' | IPv6: '+d.ipv6+'</div>'+(d.error?'<div style="color:#ff1744;font-size:12px">'+d.error+'</div>':'')+'</div>'})}
        function loadSystem(){api('/api/system-info','GET',null,function(d){var h='';h+='<div class="sys-card"><h3>🖥️ CPU</h3><div class="sys-value">'+(d.cpu?d.cpu.percent:0)+'%</div><div class="sys-detail">Ядер: '+(d.cpu?d.cpu.count:0)+' | Load: '+((d.system?d.system.load_avg:[0,0,0])[0])+'</div><div class="progress"><div class="progress-fill" style="width:'+(d.cpu?d.cpu.percent:0)+'%"></div></div></div>';h+='<div class="sys-card"><h3>💾 RAM</h3><div class="sys-value">'+(d.memory?d.memory.used:'0')+'/'+(d.memory?d.memory.total:'0')+' GB</div><div class="sys-detail">'+(d.memory?d.memory.percent:0)+'% | Swap: '+(d.swap?d.swap.used:'0')+' GB</div><div class="progress"><div class="progress-fill" style="width:'+(d.memory?d.memory.percent:0)+'%;background:linear-gradient(135deg,#00c853,#69f0ae)"></div></div></div>';h+='<div class="sys-card"><h3>💿 Диски</h3>';for(var i=0;i<(d.disks||[]).length;i++)h+='<div class="sys-detail"><b>'+d.disks[i].mountpoint+'</b>: '+d.disks[i].used+'/'+d.disks[i].total+' GB ('+d.disks[i].percent+'%)</div>';h+='</div>';h+='<div class="sys-card"><h3>🌐 Сеть</h3><div class="sys-detail">Внешний: '+d.network_config.external_ipv4+'</div><div class="sys-detail">Локальный: '+d.network_config.local_ipv4+'</div><div class="sys-detail">IPv6 подсеть: '+d.network_config.ipv6_subnet+'</div><div class="sys-detail">TX: '+(d.network?d.network.sent:'0')+' MB | RX: '+(d.network?d.network.recv:'0')+' MB</div></div>';h+='<div class="sys-card"><h3>📊 Система</h3><div class="sys-detail">Хост: '+d.system.hostname+'</div><div class="sys-detail">ОС: '+d.system.os+'</div><div class="sys-detail">Ядро: '+d.system.kernel+'</div><div class="sys-detail">Аптайм: '+d.system.uptime+'</div></div>';document.getElementById('sysInfo').innerHTML=h})}
        function restart3proxy(){if(!confirm('Перезапустить 3proxy?'))return;api('/api/server/restart-3proxy','POST',null,function(d){toast(d.message||'3proxy перезапущен')})}
        function rebootServer(){if(!confirm('⚠️ Перезагрузить сервер?'))return;api('/api/server/reboot','POST',null,function(d){toast(d.message||'Перезагрузка...','warning')})}
        setInterval(function(){if(document.getElementById('dashboard').classList.contains('active'))loadDashboard()},10000);
        loadDashboard();
    </script>
</body>
</html>
HTMLEOF

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

# Тестовые прокси
echo "[8/10] Создание тестовых прокси..."
cd /opt/proxy-farm && source venv/bin/activate
python3 << 'PYEOF'
import json, subprocess, ipaddress, random

INTERFACE = "ens33"
IPV6_SUBNET = "2a01:540:44c4:df00::/64"
network = ipaddress.ip_network(IPV6_SUBNET)
proxies = []

for i in range(5):
    ipv6 = str(network.network_address + random.getrandbits(64))
    port = 30000 + i
    login = f"user{port}"
    passwd = f"pass{port}"
    subprocess.run(['/usr/sbin/ip', '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True)
    proxies.append({
        'id': f"p{port}", 'ipv6': ipv6, 'port': port,
        'username': login, 'password': passwd,
        'created_at': '2026-07-28T00:00:00', 'active': True,
        'connection_format': f"62.148.226.89:{port}:{login}:{passwd}"
    })

with open('/opt/proxy-farm/proxies.json', 'w') as f: json.dump(proxies, f, indent=2)

config = "daemon\nnserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
users_added = set()
for p in proxies:
    u = f"{p['username']}:{p['password']}"
    if u not in users_added:
        config += f"users {p['username']}:CL:{p['password']}\n"
        users_added.add(u)
config += "\nallow *\n"
for p in proxies:
    config += f"proxy -6 -n -a -p{p['port']} -i192.168.1.7 -e{p['ipv6']}\n"
config += "flush\n"

with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
auth = ""
for p in proxies:
    auth += f"{p['username']}:CL:{p['password']}\n"
with open('/etc/3proxy/.proxyauth', 'w') as f: f.write(auth)
print(f"Создано {len(proxies)} прокси")
PYEOF

# Права
echo "[9/10] Настройка прав..."
chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py

# Запуск
echo "[10/10] Запуск сервисов..."
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          УСТАНОВКА ЗАВЕРШЕНА! v5.0                      ║"
echo "║          http://192.168.1.7:2525                        ║"
echo "║          Логин: admin / Пароль: Maxim1809               ║"
echo "║          Пароли без спецсимволов                        ║"
echo "║          + Вкладка Тест сайтов                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
INSTALLEOF

chmod +x /root/proxy-farm3/install.sh
echo "Готово! install.sh v5.0 - пароли без спецсимволов + тест сайтов"
