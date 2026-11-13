#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите установщик от root: sudo bash install.sh"
    exit 1
fi

export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

clear
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server v15.0        ║"
echo "║          Полный fix + Тест сайтов работает              ║"
echo "╚══════════════════════════════════════════════════════════╝"

# === АВТООПРЕДЕЛЕНИЕ ===
INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -z "$INTERFACE" ] && INTERFACE=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -z "$INTERFACE" ] && INTERFACE=$(ip -br l 2>/dev/null | awk '$1 !~ "lo|vir|wl|@NONE" {print $1; exit}')

IPV4_LOCAL=$(ip -4 -o addr show dev "$INTERFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -z "$IPV4_LOCAL" ] && IPV4_LOCAL=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)

IPV6_MAIN=$(ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); if(a[2]=="64"){print a[1]; exit}}')
[ -z "$IPV6_MAIN" ] && IPV6_MAIN=$(ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -z "$IPV6_MAIN" ] && IPV6_MAIN=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+(?=/64)' | grep -v ^fe80 | head -1)

IPV6_SUBNET=""
if [ -n "$INTERFACE" ]; then
    IPV6_SUBNET=$(ip -6 route show dev "$INTERFACE" 2>/dev/null | awk '$1 ~ /^[0-9a-fA-F:]+\/64$/ && $1 !~ /^fe80/ {print $1; exit}')
fi
if [ -z "$IPV6_SUBNET" ] && [ -n "$IPV6_MAIN" ]; then
    IPV6_SUBNET=$(echo "$IPV6_MAIN" | awk -F: '{print $1":"$2":"$3":"$4"::/64"}')
fi

IPV4_EXTERNAL=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 3 ipinfo.io/ip 2>/dev/null || echo "")

echo ""
echo "=== АВТООПРЕДЕЛЕНИЕ ==="
echo "Локальный IPv4:  $IPV4_LOCAL"
echo "Основной IPv6:   $IPV6_MAIN"
echo "IPv6 подсеть:    $IPV6_SUBNET"
echo "Интерфейс:       $INTERFACE"
echo "Внешний IPv4:    ${IPV4_EXTERNAL:-не определен}"
echo ""

echo "Нажмите ENTER для автоопределения или введите свои данные:"
echo ""

read -p "Локальный IPv4 [$IPV4_LOCAL]: " input
IPV4_LOCAL=${input:-$IPV4_LOCAL}
while ! echo "$IPV4_LOCAL" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; do
    read -p "❌ Некорректный IPv4. Введите локальный IPv4: " IPV4_LOCAL
done

read -p "Внешний IPv4 [${IPV4_EXTERNAL:-введите}]: " input
IPV4_EXTERNAL=${input:-$IPV4_EXTERNAL}
while ! echo "$IPV4_EXTERNAL" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; do
    read -p "❌ Внешний IPv4 обязателен! Введите: " IPV4_EXTERNAL
done

read -p "IPv6 подсеть [$IPV6_SUBNET]: " input
IPV6_SUBNET=${input:-$IPV6_SUBNET}
while ! echo "$IPV6_SUBNET" | grep -qE '^[0-9a-fA-F:]+::/64$'; do
    read -p "❌ Нужна подсеть вида 2001:db8:1:2::/64. Введите: " IPV6_SUBNET
done

read -p "Основной IPv6 [$IPV6_MAIN]: " input
IPV6_MAIN=${input:-$IPV6_MAIN}
while ! echo "$IPV6_MAIN" | grep -qE '^[0-9a-fA-F:]+$'; do
    read -p "❌ Введите основной IPv6-адрес сервера: " IPV6_MAIN
done

read -p "Интерфейс [$INTERFACE]: " input
INTERFACE=${input:-$INTERFACE}
while [ ! -e "/sys/class/net/$INTERFACE" ]; do
    read -p "❌ Интерфейс не найден. Введите имя (ens33/eth0/ens3): " INTERFACE
done

read -p "Пароль админа [сгенерировать автоматически]: " input
ADMIN_PASS="$input"
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14)
    echo "Сгенерирован пароль админа: $ADMIN_PASS"
fi
while ! echo "$ADMIN_PASS" | grep -qE '^[A-Za-z0-9]{6,}$'; do
    read -p "❌ Только латиница и цифры, минимум 6 символов. Введите пароль админа: " ADMIN_PASS
done

read -p "Начальный порт [30000]: " input
PROXY_START=${input:-30000}
while ! [[ "$PROXY_START" =~ ^[0-9]+$ ]] || [ "$PROXY_START" -lt 1024 ] || [ "$PROXY_START" -gt 65535 ]; do
    read -p "❌ Порт должен быть 1024-65535. Введите начальный порт: " PROXY_START
done

read -p "Конечный порт [31000]: " input
PROXY_END=${input:-31000}
while ! [[ "$PROXY_END" =~ ^[0-9]+$ ]] || [ "$PROXY_END" -lt "$PROXY_START" ] || [ "$PROXY_END" -gt 65535 ]; do
    read -p "❌ Конечный порт должен быть >= $PROXY_START. Введите: " PROXY_END
done

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

read -p "Всё верно? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Установка отменена."
    exit 0
fi

echo ""
echo "[1/6] Установка пакетов..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential wget tar gzip net-tools curl iproute2 ca-certificates

echo "[2/6] Компиляция 3proxy..."
cd /tmp
rm -rf 3proxy-0.9.4 0.9.4.tar.gz
wget -q --tries=3 --timeout=20 https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz || { echo "❌ Не удалось скачать 3proxy. Проверь интернет на сервере."; exit 1; }
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /tmp/3proxy-build.log 2>&1 || { echo "❌ Ошибка сборки 3proxy, лог: /tmp/3proxy-build.log"; tail -20 /tmp/3proxy-build.log; exit 1; }
make -f Makefile.Linux install > /tmp/3proxy-install.log 2>&1 || { echo "❌ Ошибка установки 3proxy, лог: /tmp/3proxy-install.log"; tail -20 /tmp/3proxy-install.log; exit 1; }
THREEPROXY_BIN=$(command -v 3proxy || true)
[ -z "$THREEPROXY_BIN" ] && [ -x /usr/local/bin/3proxy ] && THREEPROXY_BIN=/usr/local/bin/3proxy
if [ -z "$THREEPROXY_BIN" ]; then
    echo "❌ Бинарник 3proxy не найден после сборки."
    exit 1
fi
ln -sf "$THREEPROXY_BIN" /usr/bin/3proxy

echo "[3/6] Настройка Python..."
mkdir -p /opt/proxy-farm/templates /etc/3proxy /var/log/3proxy
cd /opt/proxy-farm
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask flask-login werkzeug psutil

cat > /opt/proxy-farm/config.json << CFGEOF
{
  "interface": "$INTERFACE",
  "local_ipv4": "$IPV4_LOCAL",
  "external_ipv4": "$IPV4_EXTERNAL",
  "ipv6_main": "$IPV6_MAIN",
  "ipv6_subnet": "$IPV6_SUBNET",
  "proxy_start": $PROXY_START,
  "proxy_end": $PROXY_END
}
CFGEOF

echo "[4/6] Создание приложения..."
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
SECRET_FILE = '/opt/proxy-farm/secret.key'
try:
    with open(SECRET_FILE) as f:
        SECRET_KEY = f.read().strip()
except Exception:
    SECRET_KEY = os.urandom(24).hex()
    with open(SECRET_FILE, 'w') as f:
        f.write(SECRET_KEY)
    os.chmod(SECRET_FILE, 0o600)
app.config['SECRET_KEY'] = SECRET_KEY

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
IP_BIN = '/usr/sbin/ip' if os.path.exists('/usr/sbin/ip') else '/sbin/ip'

def detect_interface():
    for family in ('-4', '-6'):
        try:
            out = subprocess.check_output(
                [IP_BIN, family, 'route', 'show', 'default'],
                text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                parts = line.split()
                if 'dev' in parts:
                    return parts[parts.index('dev') + 1]
        except Exception:
            pass
    return INTERFACE

def detect_local_ipv4():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('1.1.1.1', 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith('127.'):
            return ip
    except Exception:
        pass
    return LOCAL_IPV4

INTERFACE = detect_interface() or INTERFACE
LOCAL_IPV4 = detect_local_ipv4() or LOCAL_IPV4

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

def get_admin_hash():
    try:
        with open(USERS_DB) as f: users = json.load(f)
        for u in users:
            if u.get('username') == 'admin':
                return u.get('password')
    except Exception:
        pass
    return ADMIN_HASH

def generate_safe_password(length=10):
    chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789'
    return ''.join(random.choice(chars) for _ in range(length))

def generate_safe_username():
    return f"user{random.randint(10000, 99999)}"

def generate_random_ipv6():
    network = ipaddress.ip_network(IPV6_SUBNET)
    used = {p.get('ipv6') for p in load_proxies()}
    for _ in range(100):
        ip = str(network.network_address + random.randint(1, (1 << 64) - 2))
        if ip not in used:
            return ip
    return str(network.network_address + random.randint(1, (1 << 64) - 2))

def add_ipv6(ipv6):
    try:
        result = subprocess.run([IP_BIN, '-6', '-o', 'addr', 'show', 'dev', INTERFACE], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            parts = line.split()
            if 'inet6' in parts and parts[parts.index('inet6') + 1].split('/')[0] == ipv6:
                return True
        for attempt in range(3):
            r = subprocess.run([IP_BIN, '-6', 'addr', 'add', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True, text=True)
            if r.returncode == 0: return True
            time.sleep(0.5)
        return False
    except: return False

def remove_ipv6(ipv6):
    try:
        subprocess.run([IP_BIN, '-6', 'addr', 'del', f'{ipv6}/64', 'dev', INTERFACE], capture_output=True)
    except: pass

def update_3proxy_config():
    try:
        proxies = load_proxies()
        config = "nserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
        users_added = set()
        for p in proxies:
            if p.get('active', True):
                u = f"{p['username']}:{p['password']}"
                if u not in users_added:
                    config += f"users {p['username']}:CL:{p['password']}\n"
                    users_added.add(u)
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
        r = subprocess.run(['/bin/systemctl', 'restart', '3proxy'],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0
    except Exception:
        return False

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
            result = subprocess.run(['/usr/bin/curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}", '-s', 'http://ip6only.me/api/', '--connect-timeout', '10', '--max-time', '15'], capture_output=True, text=True, timeout=20)
            match = re.search(r'IPv6,([0-9a-f:]+)', result.stdout)
            if match: return {'status': 'working', 'ip': match.group(1), 'type': 'IPv6'}
            if '407' in result.stdout: return {'status': 'error', 'error': 'Auth failed'}
            if attempt < 2: time.sleep(2)
        except:
            if attempt < 2: time.sleep(2)
    return {'status': 'error', 'error': 'No response'}

def check_website_via_proxy(proxy, url):
    try:
        result = subprocess.run(['/usr/bin/curl', '-x', f"http://{proxy['username']}:{proxy['password']}@{LOCAL_IPV4}:{proxy['port']}", '-s', '-o', '/dev/null', '-w', '%{http_code}', url, '--connect-timeout', '10', '--max-time', '15'], capture_output=True, text=True, timeout=20)
        http_code = result.stdout.strip()
        return {'url': url, 'http_code': http_code, 'accessible': http_code in ['200', '301', '302', '403']}
    except Exception as e:
        return {'url': url, 'http_code': '0', 'accessible': False, 'error': str(e)}

def get_system_info():
    info = {'cpu': {'percent': 0, 'count': 0}, 'memory': {'percent': 0, 'used': '0', 'total': '0'}, 'swap': {'percent': 0, 'used': '0', 'total': '0'}, 'disks': [], 'network': {'sent': '0', 'recv': '0'}, 'system': {'hostname': socket.gethostname(), 'os': f"{platform.system()} {platform.release()}", 'kernel': platform.release(), 'uptime': 'N/A', 'load_avg': [0,0,0]}, 'network_config': {'external_ipv4': EXTERNAL_IPV4, 'local_ipv4': LOCAL_IPV4, 'ipv6_main': IPV6_MAIN, 'ipv6_subnet': IPV6_SUBNET}, 'proxy_stats': {'active': 0, 'total': 0, 'ports_available': 0}, 'processes': []}
    if PSUTIL:
        try:
            info['cpu'] = {'percent': round(psutil.cpu_percent(interval=0.3), 1), 'count': psutil.cpu_count()}
            info['system']['load_avg'] = [round(l,2) for l in (os.getloadavg() if hasattr(os,'getloadavg') else [0,0,0])]
            mem = psutil.virtual_memory(); swap = psutil.swap_memory()
            info['memory'] = {'percent': mem.percent, 'used': f"{mem.used/(1024**3):.1f}", 'total': f"{mem.total/(1024**3):.1f}"}
            info['swap'] = {'percent': swap.percent, 'used': f"{swap.used/(1024**3):.1f}", 'total': f"{swap.total/(1024**3):.1f}"}
            for part in psutil.disk_partitions():
                try:
                    usage = psutil.disk_usage(part.mountpoint)
                    info['disks'].append({'mountpoint': part.mountpoint, 'used': f"{usage.used/(1024**3):.1f}", 'total': f"{usage.total/(1024**3):.1f}", 'percent': usage.percent})
                except: pass
            net = psutil.net_io_counters()
            info['network'] = {'sent': f"{net.bytes_sent/(1024**2):.1f}", 'recv': f"{net.bytes_recv/(1024**2):.1f}"}
            uptime = int(time.time() - psutil.boot_time())
            info['system']['uptime'] = f"{uptime//3600}ч {(uptime%3600)//60}м"
        except: pass
    proxies = load_proxies()
    info['proxy_stats'] = {'active': sum(1 for p in proxies if p.get('active',True)), 'total': len(proxies), 'ports_available': (PROXY_END - PROXY_START + 1) - len(proxies)}
    return info

@app.route('/')
@login_required
def index():
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        admin_hash = get_admin_hash()
        if request.form.get('username') == 'admin' and admin_hash and check_password_hash(admin_hash, request.form.get('password')):
            login_user(User('1', 'admin', admin_hash))
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
        p['connection_format'] = f"http://{EXTERNAL_IPV4}:{p['port']}:{p['username']}:{p['password']}"
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
        if count > len(available_ports): return jsonify({'error': 'Недостаточно портов'}), 400
        created = []
        for i in range(count):
            ipv6 = generate_random_ipv6()
            if not add_ipv6(ipv6): continue
            port = available_ports[i]
            login = data.get('username') or generate_safe_username()
            passwd = data.get('password') or generate_safe_password()
            proxy = {'id': f"p{port}", 'ipv6': ipv6, 'port': port, 'username': login, 'password': passwd, 'created_at': datetime.now().isoformat(), 'active': True, 'connection_format': f"http://{EXTERNAL_IPV4}:{port}:{login}:{passwd}"}
            proxies.append(proxy); created.append(proxy)
        save_proxies(proxies); update_3proxy_config(); restart_3proxy()
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
    save_proxies(proxies); update_3proxy_config(); restart_3proxy()
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
    save_proxies(proxies); update_3proxy_config(); restart_3proxy()
    return jsonify({'message': 'Ротировано'})

@app.route('/api/proxy/check-all')
@login_required
def check_all():
    proxies = load_proxies()
    results = []
    for p in proxies:
        port_open = check_port(p['port'])
        internet = check_proxy_internet(p) if port_open else None
        results.append({'port': p['port'], 'open': port_open, 'ipv6': p['ipv6'], 'internet': internet})
    return jsonify({'total': len(results), 'open': sum(1 for r in results if r['open']), 'working': sum(1 for r in results if r.get('internet') and r['internet'].get('status')=='working'), 'results': results})

@app.route('/api/proxy/check-duplicates')
@login_required
def check_duplicates():
    proxies = load_proxies()
    seen = {}
    for p in proxies:
        if p['ipv6'] in seen: seen[p['ipv6']].append(p)
        else: seen[p['ipv6']] = [p]
    return jsonify({'duplicates': sum(1 for v in seen.values() if len(v)>1)})

@app.route('/api/proxy/check-website', methods=['POST'])
@login_required
def check_website():
    data = request.json
    proxy_id = data.get('proxy_id')
    url = data.get('url', 'http://ipv6.google.com')
    proxies = load_proxies()
    proxy = next((p for p in proxies if p['id'] == proxy_id), None)
    if not proxy: proxy = proxies[0] if proxies else None
    if not proxy: return jsonify({'error': 'Нет прокси'}), 400
    if not url.startswith('http'): url = 'http://' + url
    result = check_website_via_proxy(proxy, url)
    result['proxy'] = f"{proxy['port']}:{proxy['username']}"
    result['ipv6'] = proxy['ipv6']
    return jsonify(result)

@app.route('/api/settings/change-password', methods=['POST'])
@login_required
def change_password():
    global ADMIN_HASH
    try:
        data = request.json or {}
        new_password = data.get('new_password', '')
        if len(new_password) < 6:
            return jsonify({'error': 'Минимум 6 символов'}), 400
        current_hash = get_admin_hash() or ADMIN_HASH
        if not check_password_hash(current_hash, data.get('old_password', '')):
            return jsonify({'error': 'Неверный пароль'}), 403
        new_hash = generate_password_hash(new_password)
        try:
            with open(USERS_DB) as f: users = json.load(f)
        except: users = []
        found = False
        for u in users:
            if u.get('username') == 'admin':
                u['password'] = new_hash
                found = True
        if not found:
            users.append({'id': '1', 'username': 'admin', 'password': new_hash})
        with open(USERS_DB, 'w') as f: json.dump(users, f)
        ADMIN_HASH = new_hash
        return jsonify({'message': 'Пароль изменен!'})
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
    update_3proxy_config(); restart_3proxy()
    return jsonify({'message': '3proxy перезапущен'})

if __name__ == '__main__':
    try:
        with open(USERS_DB) as f: users = json.load(f)
    except: users = []
    if not any(u.get('username')=='admin' for u in users):
        users.append({'id':'1','username':'admin','password':ADMIN_HASH})
        with open(USERS_DB,'w') as f: json.dump(users, f)
    update_3proxy_config(); restart_3proxy()
    app.run(host='0.0.0.0', port=2525, debug=False, threaded=True)
PYEOF

cat > /opt/proxy-farm/restore_ipv6.py << 'PYEOF'
#!/usr/bin/env python3
"""Восстанавливает IPv6-адреса прокси и пересобирает 3proxy.cfg после ребута."""
import json
import os
import subprocess
import sys

BASE = '/opt/proxy-farm'
CONFIG = os.path.join(BASE, 'config.json')
PROXIES = os.path.join(BASE, 'proxies.json')
IP_BIN = '/usr/sbin/ip' if os.path.exists('/usr/sbin/ip') else '/sbin/ip'


def run(args):
    return subprocess.run(args, capture_output=True, text=True)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def find_interface(cfg):
    for family in ('-4', '-6'):
        r = run([IP_BIN, family, 'route', 'show', 'default'])
        for line in r.stdout.splitlines():
            parts = line.split()
            if 'dev' in parts:
                iface = parts[parts.index('dev') + 1]
                if os.path.exists('/sys/class/net/' + iface):
                    return iface
    iface = cfg.get('interface')
    if iface and os.path.exists('/sys/class/net/' + iface):
        return iface
    try:
        for name in os.listdir('/sys/class/net'):
            if name != 'lo' and os.path.isdir('/sys/class/net/' + name):
                return name
    except Exception:
        pass
    return None


def main():
    cfg = read_json(CONFIG, {})
    proxies = read_json(PROXIES, [])
    iface = find_interface(cfg)
    if not iface:
        print('restore-ipv6: сетевой интерфейс не найден')
        return 0

    active = [p for p in proxies if p.get('active', True) and p.get('ipv6')]
    current = set()
    for line in run([IP_BIN, '-6', '-o', 'addr', 'show', 'dev', iface]).stdout.splitlines():
        parts = line.split()
        if 'inet6' in parts:
            current.add(parts[parts.index('inet6') + 1].split('/')[0])
    restored = 0
    for p in active:
        ip = p['ipv6']
        if ip in current:
            restored += 1
            continue
        r = run([IP_BIN, '-6', 'addr', 'add', f'{ip}/64', 'dev', iface])
        err = (r.stderr or '') + (r.stdout or '')
        if r.returncode == 0 or 'File exists' in err:
            restored += 1
        else:
            print(f'restore-ipv6: не удалось добавить {ip}: {err.strip()}')

    print(f'restore-ipv6: {restored}/{len(active)} адресов на {iface}')

    if cfg.get('interface') != iface:
        cfg['interface'] = iface
        try:
            with open(CONFIG, 'w') as f:
                json.dump(cfg, f, indent=2)
        except Exception as e:
            print(f'restore-ipv6: не удалось обновить config.json: {e}')

    try:
        sys.path.insert(0, BASE)
        import app as farm
        if farm.update_3proxy_config():
            print('restore-ipv6: 3proxy.cfg обновлён')
        else:
            print('restore-ipv6: 3proxy.cfg НЕ обновлён')
    except Exception as e:
        print(f'restore-ipv6: конфиг 3proxy не обновлён: {e}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
PYEOF

echo "[5/6] Создание веб-интерфейса..."

cat > /opt/proxy-farm/templates/login.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>ProxyFarm Neo — Вход</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Roboto,sans-serif;background:radial-gradient(ellipse at 30% 20%,rgba(139,92,246,0.15),transparent 50%),radial-gradient(ellipse at 70% 80%,rgba(34,211,238,0.1),transparent 50%),#07070d;min-height:100vh;display:flex;align-items:center;justify-content:center;color:#ededf2;padding:20px}
.box{width:400px;max-width:100%;background:rgba(22,22,34,0.7);backdrop-filter:blur(16px);padding:40px;border-radius:20px;border:1px solid rgba(139,92,246,0.15);box-shadow:0 24px 64px rgba(0,0,0,0.5);animation:fadeInUp .5s cubic-bezier(.22,1,.36,1)}
@keyframes fadeInUp{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:translateY(0)}}
.logo{width:60px;height:60px;border-radius:16px;background:linear-gradient(135deg,#8b5cf6,#22d3ee);display:flex;align-items:center;justify-content:center;font-size:32px;margin:0 auto 20px;box-shadow:0 12px 32px rgba(139,92,246,0.4);color:#fff}
h1{font-size:24px;font-weight:700;text-align:center;letter-spacing:-0.01em;margin-bottom:6px}
h1 span{background:linear-gradient(135deg,#a78bfa,#22d3ee);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.sub{text-align:center;color:#5a5a72;font-size:12px;margin-bottom:28px;letter-spacing:0.03em}
label{display:block;font-size:11px;font-weight:600;color:#8b8ba0;text-transform:uppercase;letter-spacing:0.06em;margin-bottom:7px}
input{width:100%;padding:13px 16px;margin-bottom:16px;background:rgba(12,12,20,0.8);border:1px solid rgba(255,255,255,0.08);border-radius:11px;color:#fff;font-size:15px;font-family:inherit;transition:all .2s}
input:focus{outline:none;border-color:#8b5cf6;box-shadow:0 0 0 3px rgba(139,92,246,0.15)}
button{width:100%;padding:13px;background:linear-gradient(135deg,#8b5cf6,#7c3aed);border:none;border-radius:11px;color:#fff;font-size:15px;font-weight:600;font-family:inherit;cursor:pointer;transition:all .15s;box-shadow:0 6px 20px rgba(139,92,246,0.35);margin-top:6px}
button:hover{transform:translateY(-1px);box-shadow:0 8px 28px rgba(139,92,246,0.5)}
button:active{transform:translateY(0) scale(0.98)}
.error{background:rgba(239,68,68,0.1);color:#fca5a5;padding:11px 14px;border-radius:10px;margin-bottom:16px;font-size:13px;border:1px solid rgba(239,68,68,0.25);text-align:center}
</style>
</head>
<body>
<div class="box">
<div class="logo">&#9889;</div>
<h1>ProxyFarm <span>Neo</span></h1>
<div class="sub">IPv6 PROXY SERVER &middot; v15</div>
{% if error %}<div class="error">{{ error }}</div>{% endif %}
<form method="POST">
<label for="username">Логин</label>
<input id="username" type="text" name="username" placeholder="admin" autocomplete="username" required autofocus>
<label for="password">Пароль</label>
<input id="password" type="password" name="password" placeholder="&bull;&bull;&bull;&bull;&bull;&bull;&bull;&bull;" autocomplete="current-password" required>
<button type="submit">Войти &rarr;</button>
</form>
</div>
</body>
</html>
HTMLEOF

cat > /opt/proxy-farm/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ProxyFarm Neo</title>
<style>
:root{--bg:#07070d;--bg-2:#0e0e18;--card:rgba(22,22,34,0.7);--border:rgba(139,92,246,0.12);--border-h:rgba(139,92,246,0.45);--accent:#8b5cf6;--accent-2:#a78bfa;--accent-3:#22d3ee;--text:#ededf2;--text-dim:#8b8ba0;--text-mute:#5a5a72;--success:#10b981;--success-g:rgba(16,185,129,0.4);--danger:#ef4444;--danger-g:rgba(239,68,68,0.4);--warning:#f59e0b;--radius:14px}
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Roboto,sans-serif;background:radial-gradient(ellipse at 15% 10%,rgba(139,92,246,0.10),transparent 45%),radial-gradient(ellipse at 85% 85%,rgba(34,211,238,0.08),transparent 45%),var(--bg);color:var(--text);min-height:100vh;line-height:1.5;-webkit-font-smoothing:antialiased}
::-webkit-scrollbar{width:9px;height:9px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:rgba(139,92,246,0.3);border-radius:5px}
::-webkit-scrollbar-thumb:hover{background:rgba(139,92,246,0.5)}
.topbar{position:sticky;top:0;z-index:100;display:flex;justify-content:space-between;align-items:center;padding:14px 28px;background:rgba(7,7,13,0.85);backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,0.05)}
.brand{display:flex;align-items:center;gap:12px}
.brand-icon{width:40px;height:40px;border-radius:12px;background:linear-gradient(135deg,#8b5cf6,#22d3ee);display:flex;align-items:center;justify-content:center;font-size:22px;box-shadow:0 8px 24px rgba(139,92,246,0.35);color:#fff}
.brand-title{font-size:17px;font-weight:700;letter-spacing:-0.01em}
.brand-title span{background:linear-gradient(135deg,#a78bfa,#22d3ee);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.brand-sub{font-size:11px;color:var(--text-mute);margin-top:1px;letter-spacing:0.02em}
.topbar-right{display:flex;align-items:center;gap:12px}
.status-pill{display:flex;align-items:center;gap:8px;padding:7px 14px;border-radius:20px;background:rgba(16,185,129,0.08);border:1px solid rgba(16,185,129,0.25);font-size:12px;color:#a7f3d0}
.status-pill.offline{background:rgba(239,68,68,0.08);border-color:rgba(239,68,68,0.25);color:#fca5a5}
.status-dot{width:7px;height:7px;border-radius:50%;background:var(--success);box-shadow:0 0 10px var(--success-g);animation:pulse 2s ease-in-out infinite}
.status-pill.offline .status-dot{background:var(--danger);box-shadow:0 0 10px var(--danger-g)}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:0.5;transform:scale(0.85)}}
.icon-btn{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;background:rgba(255,255,255,0.04);color:var(--text-dim);border:1px solid rgba(255,255,255,0.06);text-decoration:none;font-size:16px;transition:all .2s}
.icon-btn:hover{background:rgba(239,68,68,0.15);color:#fca5a5;border-color:rgba(239,68,68,0.35)}
.tabs{position:sticky;top:69px;z-index:99;display:flex;flex-wrap:wrap;gap:4px;padding:10px 28px;background:rgba(7,7,13,0.75);backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,0.05)}
.tabs::-webkit-scrollbar{display:none}
.tab-btn{display:flex;align-items:center;gap:7px;padding:9px 16px;border-radius:10px;background:transparent;border:1px solid transparent;color:var(--text-dim);font-size:13px;font-weight:500;cursor:pointer;white-space:nowrap;transition:all .2s;font-family:inherit}
.tab-btn:hover{color:var(--text);background:rgba(255,255,255,0.04)}
.tab-btn.active{background:linear-gradient(135deg,rgba(139,92,246,0.2),rgba(34,211,238,0.1));color:#fff;border-color:rgba(139,92,246,0.4);box-shadow:0 4px 16px rgba(139,92,246,0.15)}
.tab-icon{font-size:14px}
main{max-width:1400px;margin:0 auto;padding:28px 28px 60px}
.section{display:none}
.section.active{display:block;animation:fadeInUp .35s cubic-bezier(.22,1,.36,1)}
@keyframes fadeInUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
h2{font-size:20px;font-weight:700;letter-spacing:-0.01em;margin-bottom:18px;display:flex;align-items:center;gap:9px}
h2 .icon-circle{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,rgba(139,92,246,0.25),rgba(34,211,238,0.15));display:inline-flex;align-items:center;justify-content:center;font-size:15px}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:22px;backdrop-filter:blur(10px);transition:all .25s}
.card:hover{border-color:rgba(139,92,246,0.3)}
.card h3{font-size:14px;font-weight:600;color:var(--text-dim);margin-bottom:14px;text-transform:uppercase;letter-spacing:0.06em}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin-bottom:18px}
.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:18px;margin-bottom:18px}
.stat{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:20px;position:relative;overflow:hidden;transition:all .25s}
.stat::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,var(--accent),var(--accent-3));opacity:0;transition:opacity .25s}
.stat:hover{transform:translateY(-2px);border-color:var(--border-h);box-shadow:0 12px 32px rgba(0,0,0,0.3)}
.stat:hover::before{opacity:1}
.stat-icon{width:42px;height:42px;border-radius:11px;background:linear-gradient(135deg,rgba(139,92,246,0.2),rgba(34,211,238,0.1));display:flex;align-items:center;justify-content:center;font-size:20px;margin-bottom:12px}
.stat-value{font-size:30px;font-weight:700;letter-spacing:-0.02em;color:#fff}
.stat-label{font-size:12px;color:var(--text-dim);margin-top:3px}
.ring-wrap{display:flex;align-items:center;gap:18px}
.ring{width:88px;height:88px;border-radius:50%;background:conic-gradient(var(--accent) calc(var(--p)*1%),rgba(255,255,255,0.05) 0);display:flex;align-items:center;justify-content:center;position:relative;transition:background .6s}
.ring::before{content:'';position:absolute;inset:8px;border-radius:50%;background:var(--bg-2)}
.ring-label{position:relative;font-size:19px;font-weight:700;color:#fff;z-index:1}
.ring.ram{background:conic-gradient(var(--success) calc(var(--p)*1%),rgba(255,255,255,0.05) 0)}
.ring-info{flex:1}
.ring-info .big{font-size:20px;font-weight:600;color:#fff}
.ring-info .small{font-size:12px;color:var(--text-dim);margin-top:3px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;padding:9px 16px;border-radius:10px;border:none;font-size:13px;font-weight:600;font-family:inherit;cursor:pointer;color:#fff;transition:all .15s;background:linear-gradient(135deg,#8b5cf6,#7c3aed);box-shadow:0 4px 14px rgba(139,92,246,0.25)}
.btn:hover{transform:translateY(-1px);box-shadow:0 6px 20px rgba(139,92,246,0.4)}
.btn:active{transform:translateY(0) scale(0.98)}
.btn:disabled{opacity:0.5;cursor:not-allowed;transform:none;box-shadow:none}
.btn-danger{background:linear-gradient(135deg,#ef4444,#dc2626);box-shadow:0 4px 14px rgba(239,68,68,0.25)}
.btn-danger:hover{box-shadow:0 6px 20px rgba(239,68,68,0.4)}
.btn-success{background:linear-gradient(135deg,#10b981,#059669);box-shadow:0 4px 14px rgba(16,185,129,0.25)}
.btn-success:hover{box-shadow:0 6px 20px rgba(16,185,129,0.4)}
.btn-warning{background:linear-gradient(135deg,#f59e0b,#d97706);box-shadow:0 4px 14px rgba(245,158,11,0.25)}
.btn-ghost{background:rgba(255,255,255,0.04);color:var(--text-dim);border:1px solid rgba(255,255,255,0.08);box-shadow:none}
.btn-ghost:hover{background:rgba(255,255,255,0.08);color:var(--text);transform:translateY(-1px);box-shadow:none}
.btn-sm{padding:7px 12px;font-size:12px}
.form-label{display:block;font-size:11px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.06em;margin-bottom:7px}
.form-input{width:100%;padding:11px 14px;background:rgba(12,12,20,0.8);border:1px solid rgba(255,255,255,0.08);border-radius:10px;color:#fff;font-size:14px;font-family:inherit;transition:all .2s}
.form-input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px rgba(139,92,246,0.15)}
select.form-input{cursor:pointer}
.create-fields{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.site-fields{display:grid;grid-template-columns:1fr 2fr 1fr;gap:12px;align-items:end}
.proxy-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:14px}
.proxy-card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:18px;position:relative;cursor:pointer;transition:all .2s}
.proxy-card:hover{border-color:var(--border-h);transform:translateY(-2px);box-shadow:0 12px 32px rgba(0,0,0,0.3)}
.proxy-card.selected{border-color:var(--accent);box-shadow:0 0 0 2px rgba(139,92,246,0.3),0 12px 32px rgba(139,92,246,0.15)}
.proxy-status{position:absolute;top:16px;right:16px;display:flex;align-items:center;gap:6px;font-size:11px;font-weight:600;padding:4px 9px;border-radius:20px}
.proxy-status.open{color:#6ee7b7;background:rgba(16,185,129,0.12);border:1px solid rgba(16,185,129,0.25)}
.proxy-status.closed{color:#fca5a5;background:rgba(239,68,68,0.1);border:1px solid rgba(239,68,68,0.25)}
.proxy-status .dot{width:6px;height:6px;border-radius:50%;background:currentColor;box-shadow:0 0 6px currentColor;animation:pulse 2s ease-in-out infinite}
.proxy-meta{font-size:13px;color:var(--text);margin-bottom:10px;padding-right:74px}
.proxy-meta b{color:#fff}
.proxy-fmt{background:rgba(6,6,12,0.7);border:1px solid rgba(255,255,255,0.05);padding:11px;border-radius:9px;font-family:'JetBrains Mono','Consolas',monospace;font-size:11.5px;color:#22d3ee;text-align:center;word-break:break-all;margin-bottom:10px}
.copy-btn{width:100%;padding:9px;background:rgba(139,92,246,0.12);color:#a78bfa;border:1px solid rgba(139,92,246,0.25);border-radius:9px;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;transition:all .15s}
.copy-btn:hover{background:rgba(139,92,246,0.22);border-color:var(--accent);color:#fff}
.tbl{width:100%;border-collapse:collapse;font-size:13px;margin-top:14px}
.tbl th,.tbl td{padding:11px 14px;text-align:left;border-bottom:1px solid rgba(255,255,255,0.05)}
.tbl th{color:var(--text-dim);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:0.06em}
.tbl tr:hover td{background:rgba(139,92,246,0.03)}
.badge{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:20px;font-size:11px;font-weight:600}
.badge-ok{color:#6ee7b7;background:rgba(16,185,129,0.12)}
.badge-err{color:#fca5a5;background:rgba(239,68,68,0.1)}
.badge-wait{color:#fcd34d;background:rgba(245,158,11,0.1)}
.empty{text-align:center;padding:60px 20px;color:var(--text-mute)}
.empty-icon{font-size:48px;opacity:0.4;margin-bottom:14px}
.empty-title{font-size:16px;color:var(--text-dim);margin-bottom:6px}
.empty-sub{font-size:13px}
.toasts{position:fixed;top:84px;right:24px;z-index:9999;display:flex;flex-direction:column;gap:10px;pointer-events:none}
.toast{display:flex;align-items:center;gap:11px;padding:13px 18px;border-radius:12px;background:rgba(22,22,34,0.95);backdrop-filter:blur(14px);border:1px solid rgba(255,255,255,0.08);font-size:13px;color:var(--text);min-width:220px;max-width:380px;box-shadow:0 8px 32px rgba(0,0,0,0.5);animation:slideIn .35s cubic-bezier(.22,1,.36,1);pointer-events:auto}
.toast.success{border-left:3px solid var(--success)}
.toast.error{border-left:3px solid var(--danger)}
.toast.info{border-left:3px solid var(--accent-3)}
.toast.warning{border-left:3px solid var(--warning)}
.toast-icon{font-size:17px}
@keyframes slideIn{from{transform:translateX(120%);opacity:0}to{transform:translateX(0);opacity:1}}
.toast.leaving{animation:slideOut .3s forwards}
@keyframes slideOut{to{transform:translateX(120%);opacity:0}}
.spinner{display:inline-block;width:16px;height:16px;border:2px solid rgba(255,255,255,0.2);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;vertical-align:middle}
@keyframes spin{to{transform:rotate(360deg)}}
.loading-block{display:flex;align-items:center;justify-content:center;gap:10px;padding:40px 20px;color:var(--text-dim);font-size:14px}
.sys-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px}
@media(max-width:900px){.topbar{padding:12px 16px}.brand-sub{display:none}.tabs{padding:8px 16px;top:65px}.tab-btn{padding:8px 12px;font-size:12px}main{padding:18px 16px 40px}.grid{grid-template-columns:repeat(2,1fr);gap:10px}.row{grid-template-columns:1fr}.proxy-grid{grid-template-columns:1fr}.stat-value{font-size:24px}.stat{padding:15px}.stat-icon{width:36px;height:36px;font-size:17px;margin-bottom:9px}}
@media(max-width:700px){.create-fields,.site-fields{grid-template-columns:1fr}}
@media(max-width:520px){.grid{grid-template-columns:1fr}.ring{width:72px;height:72px}.ring::before{inset:6px}.ring-label{font-size:16px}}
</style>
</head>
<body>
<header class="topbar">
<div class="brand">
<div class="brand-icon">&#9889;</div>
<div><div class="brand-title">ProxyFarm <span>Neo</span></div><div class="brand-sub">IPv6 Proxy Server &middot; v15</div></div>
</div>
<div class="topbar-right">
<div class="status-pill" id="statusPill"><span class="status-dot"></span><span id="statusLabel">Онлайн</span></div>
<a href="/logout" class="icon-btn" title="Выйти">&#9166;</a>
</div>
</header>
<nav class="tabs">
<button class="tab-btn active" data-tab="dashboard" onclick="showTab('dashboard',this)"><span class="tab-icon">&#128202;</span>Дашборд</button>
<button class="tab-btn" data-tab="proxies" onclick="showTab('proxies',this)"><span class="tab-icon">&#127760;</span>Прокси</button>
<button class="tab-btn" data-tab="create" onclick="showTab('create',this)"><span class="tab-icon">&#10024;</span>Создать</button>
<button class="tab-btn" data-tab="checker" onclick="showTab('checker',this)"><span class="tab-icon">&#128269;</span>Проверка</button>
<button class="tab-btn" data-tab="sitetest" onclick="showTab('sitetest',this)"><span class="tab-icon">&#127757;</span>Тест сайтов</button>
<button class="tab-btn" data-tab="system" onclick="showTab('system',this)"><span class="tab-icon">&#128421;</span>Система</button>
<button class="tab-btn" data-tab="settings" onclick="showTab('settings',this)"><span class="tab-icon">&#9881;</span>Настройки</button>
<button class="tab-btn" data-tab="tools" onclick="showTab('tools',this)"><span class="tab-icon">&#128295;</span>Инструменты</button>
</nav>
<main>
<section id="dashboard" class="section active">
<div class="grid" id="dashStats">
<div class="stat"><div class="stat-icon">&#9889;</div><div class="stat-value">&mdash;</div><div class="stat-label">Активных прокси</div></div>
<div class="stat"><div class="stat-icon">&#128268;</div><div class="stat-value">&mdash;</div><div class="stat-label">Свободных портов</div></div>
<div class="stat"><div class="stat-icon">&#128421;</div><div class="stat-value">&mdash;</div><div class="stat-label">CPU</div></div>
<div class="stat"><div class="stat-icon">&#128190;</div><div class="stat-value">&mdash;</div><div class="stat-label">RAM</div></div>
</div>
<div class="row">
<div class="card"><h3>CPU</h3><div class="ring-wrap"><div class="ring" id="cpuRing" style="--p:0"><div class="ring-label" id="cpuRingLabel">0%</div></div><div class="ring-info"><div class="big" id="cpuBig">0%</div><div class="small" id="cpuSmall">Ядра: &mdash;</div></div></div></div>
<div class="card"><h3>Память</h3><div class="ring-wrap"><div class="ring ram" id="ramRing" style="--p:0"><div class="ring-label" id="ramRingLabel">0%</div></div><div class="ring-info"><div class="big" id="ramBig">0 GB</div><div class="small" id="ramSmall">из &mdash; GB</div></div></div></div>
<div class="card"><h3>Прокси</h3><div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;text-align:center"><div><div style="font-size:26px;font-weight:700;color:#10b981" id="pActive">0</div><div style="font-size:11px;color:var(--text-dim);margin-top:3px">Активные</div></div><div><div style="font-size:26px;font-weight:700;color:#f59e0b" id="pTotal">0</div><div style="font-size:11px;color:var(--text-dim);margin-top:3px">Всего</div></div><div><div style="font-size:26px;font-weight:700;color:#22d3ee" id="pFree">0</div><div style="font-size:11px;color:var(--text-dim);margin-top:3px">Свободно</div></div></div></div>
<div class="card"><h3>Быстрые действия</h3><div style="display:flex;flex-wrap:wrap;gap:8px"><button class="btn btn-warning btn-sm" onclick="restart3proxy()">&#128260; Перезапустить</button><button class="btn btn-ghost btn-sm" onclick="showTab('create',document.querySelector('[data-tab=create]'))">&#10024; Создать</button><button class="btn btn-ghost btn-sm" onclick="showTab('checker',document.querySelector('[data-tab=checker]'))">&#128269; Проверить</button><button class="btn btn-ghost btn-sm" onclick="showTab('tools',document.querySelector('[data-tab=tools]'))">&#128295; Инструменты</button></div></div>
</div>
</section>
<section id="proxies" class="section">
<h2><span class="icon-circle">&#127760;</span> Список прокси</h2>
<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;flex-wrap:wrap;gap:10px">
<div id="selectedInfo" style="font-size:13px;color:var(--text-dim)"></div>
<div style="display:flex;gap:6px;flex-wrap:wrap">
<button class="btn btn-ghost btn-sm" id="selectAllBtn" onclick="toggleSelectAll()">Выбрать все</button>
<button class="btn btn-ghost btn-sm" onclick="checkDuplicates()">&#128270; Дубликаты</button>
<button class="btn btn-success btn-sm" onclick="exportProxies()">&#128229; Экспорт</button>
<button class="btn btn-warning btn-sm" id="rotateBtn" style="display:none" onclick="rotateSelected()">&#128260; Ротировать</button>
<button class="btn btn-danger btn-sm" id="delBtn" style="display:none" onclick="deleteSelected()">&#128465; Удалить</button>
</div></div>
<div class="proxy-grid" id="proxyList"></div>
</section>
<section id="create" class="section">
<h2><span class="icon-circle">&#10024;</span> Создание прокси</h2>
<div class="card">
<div class="create-fields">
<div><label class="form-label">Количество</label><input type="number" class="form-input" id="count" value="1" min="1" max="100"></div>
<div><label class="form-label">Логин (пусто = авто)</label><input type="text" class="form-input" id="username" placeholder="Авто"></div>
<div><label class="form-label">Пароль (пусто = авто)</label><input type="text" class="form-input" id="password" placeholder="Авто"></div>
</div>
<button class="btn" style="width:100%;margin-top:16px;padding:13px" onclick="createProxies(this)">&#10024; Создать прокси</button>
</div>
<div id="results" style="margin-top:16px"></div>
</section>
<section id="checker" class="section">
<h2><span class="icon-circle">&#128269;</span> Проверка прокси</h2>
<div style="margin-bottom:14px"><button class="btn btn-success" onclick="checkAll(this)">&#128269; Проверить всё</button></div>
<div class="card"><div id="checkResults"><div class="empty"><div class="empty-icon">&#128269;</div><div class="empty-title">Пока нет результатов</div><div class="empty-sub">Нажмите «Проверить всё», чтобы протестировать каждый прокси</div></div></div></div>
</section>
<section id="sitetest" class="section">
<h2><span class="icon-circle">&#127757;</span> Тест сайтов через прокси</h2>
<div class="card">
<div class="site-fields">
<div><label class="form-label">Прокси</label><select class="form-input" id="testProxy"></select></div>
<div><label class="form-label">URL</label><input type="text" class="form-input" id="testUrl" value="ipv6.google.com"></div>
<div><button class="btn btn-success" style="width:100%" onclick="testWebsite(this)">Проверить</button></div>
</div>
<div id="siteTestResult" style="margin-top:16px"></div>
</div>
</section>
<section id="system" class="section">
<h2><span class="icon-circle">&#128421;</span> Системная информация</h2>
<div id="sysInfo" class="sys-grid"></div>
</section>
<section id="settings" class="section">
<h2><span class="icon-circle">&#9881;</span> Настройки</h2>
<div class="row">
<div class="card"><h3>&#128273; Смена пароля</h3><div style="margin:14px 0"><label class="form-label">Текущий пароль</label><input type="password" class="form-input" id="oldPassword" placeholder="Текущий пароль"></div><div style="margin:14px 0"><label class="form-label">Новый пароль (мин. 6)</label><input type="password" class="form-input" id="newPassword" placeholder="Новый пароль"></div><button class="btn btn-warning" style="width:100%" onclick="changePassword()">Сменить пароль</button></div>
<div class="card"><h3>&#128203; Информация</h3><div id="settingsInfo" style="color:var(--text-dim);font-size:13px;line-height:1.9">Загрузка...</div></div>
</div>
</section>
<section id="tools" class="section">
<h2><span class="icon-circle">&#128295;</span> Инструменты</h2>
<div class="row">
<div class="card"><h3>&#9881; Управление</h3><div style="display:flex;flex-direction:column;gap:10px"><button class="btn btn-warning" style="width:100%" onclick="restart3proxy()">&#128260; Перезапустить 3proxy</button><button class="btn btn-danger" style="width:100%" onclick="rebootServer()">&#128268; Перезагрузить сервер</button></div></div>
<div class="card"><h3>&#128161; Подсказки</h3><div style="color:var(--text-dim);font-size:13px;line-height:1.8">&bull; <b style="color:#a78bfa">Перезапустить 3proxy</b> — пересобрать конфиг и перезапустить прокси.<br>&bull; <b style="color:#a78bfa">Перезагрузить сервер</b> — перезагрузка ОС примерно через 3 секунды.<br>&bull; IPv6-адреса и конфиг восстанавливаются автоматически при старте сервиса.</div></div>
</div>
</section>
</main>
<div class="toasts" id="toasts"></div>
<script>
var selectedProxies=[],proxyCache={},allProxyIds=[];
function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function safeId(v){return String(v==null?'':v).replace(/[^A-Za-z0-9_-]/g,'')}
function showTab(name,btn){document.querySelectorAll('.section').forEach(function(s){s.classList.remove('active')});var sec=document.getElementById(name);if(sec)sec.classList.add('active');document.querySelectorAll('.tab-btn').forEach(function(t){t.classList.remove('active')});if(!btn)btn=document.querySelector('[data-tab="'+name+'"]');if(btn)btn.classList.add('active');if(name==='proxies')loadProxies();else if(name==='dashboard')loadDashboard();else if(name==='system')loadSystem();else if(name==='sitetest')loadProxySelect();else if(name==='settings')loadSettings()}
async function api(url,method,body){method=method||'GET';var opts={method:method,headers:{'Content-Type':'application/json'},credentials:'same-origin'};if(body!==undefined&&body!==null)opts.body=JSON.stringify(body);try{var r=await fetch(url,opts);if(r.status===401||(r.redirected&&r.url.indexOf('/login')>=0)){window.location='/login';return{}}var text=await r.text();try{return JSON.parse(text)}catch(e){return{}}}catch(e){return{error:String(e)}}}
function toast(msg,type){type=type||'success';var icons={success:'\u2713',error:'\u2715',info:'\u2139',warning:'\u26A0'};var el=document.createElement('div');el.className='toast '+type;var ic=document.createElement('span');ic.className='toast-icon';ic.textContent=icons[type]||'';var tx=document.createElement('span');tx.textContent=msg;el.appendChild(ic);el.appendChild(tx);document.getElementById('toasts').appendChild(el);setTimeout(function(){el.classList.add('leaving');setTimeout(function(){el.remove()},300)},3000)}
function fallbackCopy(t,cb){var i=document.createElement('textarea');i.value=t;i.style.position='fixed';i.style.opacity='0';document.body.appendChild(i);i.select();try{document.execCommand('copy');cb()}catch(e){toast('Не удалось скопировать','error')}document.body.removeChild(i)}
function copyText(t){var done=function(){toast('Скопировано','success')};if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t).then(done).catch(function(){fallbackCopy(t,done)})}else{fallbackCopy(t,done)}}
function copyProxy(id){var t=proxyCache[id];if(!t){toast('Нет данных для копирования','error');return}copyText(t)}
function setBtnLoading(btn,loading,label){if(!btn)return;if(loading){btn.dataset.orig=btn.innerHTML;btn.innerHTML='<span class="spinner"></span> '+(label||'Работаю...');btn.disabled=true}else{if(btn.dataset.orig)btn.innerHTML=btn.dataset.orig;btn.disabled=false}}
function setRing(ringId,labelId,val){var r=document.getElementById(ringId);if(r)r.style.setProperty('--p',val);var l=document.getElementById(labelId);if(l)l.textContent=val+'%'}
async function loadDashboard(){var d=await api('/api/system-info');if(d.error)return;var ps=d.proxy_stats||{};var cpu=(d.cpu&&d.cpu.percent)||0;var ram=(d.memory&&d.memory.percent)||0;document.getElementById('dashStats').innerHTML='<div class="stat"><div class="stat-icon">&#9889;</div><div class="stat-value">'+(ps.active||0)+'</div><div class="stat-label">Активных прокси</div></div><div class="stat"><div class="stat-icon">&#128268;</div><div class="stat-value">'+(ps.ports_available||0)+'</div><div class="stat-label">Свободных портов</div></div><div class="stat"><div class="stat-icon">&#128421;</div><div class="stat-value">'+cpu+'%</div><div class="stat-label">CPU</div></div><div class="stat"><div class="stat-icon">&#128190;</div><div class="stat-value">'+ram+'%</div><div class="stat-label">RAM</div></div>';setRing('cpuRing','cpuRingLabel',cpu);setRing('ramRing','ramRingLabel',ram);document.getElementById('cpuBig').textContent=cpu+'%';document.getElementById('cpuSmall').textContent='Ядра: '+((d.cpu&&d.cpu.count)||'\u2014');document.getElementById('ramBig').textContent=((d.memory&&d.memory.used)||'0')+' GB';document.getElementById('ramSmall').textContent='из '+((d.memory&&d.memory.total)||'\u2014')+' GB';document.getElementById('pActive').textContent=ps.active||0;document.getElementById('pTotal').textContent=ps.total||0;document.getElementById('pFree').textContent=ps.ports_available||0}
async function loadProxies(){var list=document.getElementById('proxyList');list.innerHTML='<div class="loading-block"><span class="spinner"></span> Загружаю прокси...</div>';var d=await api('/api/proxies');var items=d.proxies||[];proxyCache={};allProxyIds=items.map(function(p){return safeId(p.id)});var sa=document.getElementById('selectAllBtn');if(!items.length){list.innerHTML='<div class="empty" style="grid-column:1/-1"><div class="empty-icon">&#128237;</div><div class="empty-title">Прокси пока нет</div><div class="empty-sub">Создайте их на вкладке «Создать»</div></div>';document.getElementById('delBtn').style.display='none';document.getElementById('rotateBtn').style.display='none';document.getElementById('selectedInfo').textContent='';if(sa){sa.style.display='none';sa.textContent='Выбрать все'}return}selectedProxies=selectedProxies.filter(function(id){return allProxyIds.indexOf(id)>=0});var h='';items.forEach(function(p){var id=safeId(p.id);proxyCache[id]=p.connection_format||'';var sel=selectedProxies.indexOf(id)>=0;var open=p.port_open;h+='<div class="proxy-card'+(sel?' selected':'')+'" onclick="selectProxy(\''+id+'\')"><div class="proxy-status '+(open?'open':'closed')+'"><span class="dot"></span>'+(open?'Открыт':'Закрыт')+'</div><div class="proxy-meta"><b>Порт '+esc(p.port)+'</b> &middot; '+esc(p.username)+':'+esc(p.password)+'</div><div class="proxy-fmt">'+esc(p.connection_format||'')+'</div><button class="copy-btn" onclick="event.stopPropagation();copyProxy(\''+id+'\')">&#128203; Копировать</button></div>'});list.innerHTML=h;var has=selectedProxies.length>0;document.getElementById('delBtn').style.display=has?'inline-flex':'none';document.getElementById('rotateBtn').style.display=has?'inline-flex':'none';if(sa){sa.style.display='inline-flex';sa.textContent=(selectedProxies.length===allProxyIds.length?'Снять выбор':'Выбрать все')}document.getElementById('selectedInfo').textContent=has?'Выбрано: '+selectedProxies.length:''}
function toggleSelectAll(){if(!allProxyIds.length)return;selectedProxies=(selectedProxies.length===allProxyIds.length)?[]:allProxyIds.slice();loadProxies()}
function selectProxy(id){var i=selectedProxies.indexOf(id);if(i>=0)selectedProxies.splice(i,1);else selectedProxies.push(id);loadProxies()}
async function deleteSelected(){if(!selectedProxies.length)return;if(!confirm('Удалить выбранные прокси: '+selectedProxies.length+'?'))return;var d=await api('/api/proxy/delete','POST',{ids:selectedProxies});if(d.error){toast(d.error,'error');return}selectedProxies=[];toast('Удалено','success');loadProxies();loadDashboard()}
async function rotateSelected(){if(!selectedProxies.length)return;var n=selectedProxies.length;var d=await api('/api/proxy/rotate','POST',{ids:selectedProxies});if(d.error){toast(d.error,'error');return}toast('Ротировано: '+n,'success');loadProxies()}
async function createProxies(btn){setBtnLoading(btn,true,'Создаю...');var c=parseInt(document.getElementById('count').value)||1;var d=await api('/api/proxy/create','POST',{count:c,username:document.getElementById('username').value,password:document.getElementById('password').value});setBtnLoading(btn,false);if(d.error){toast(d.error,'error');return}var items=d.proxies||[];items.forEach(function(p){proxyCache[safeId(p.id)]=p.connection_format||''});var h='<div class="card"><h3>&#10003; Создано: '+items.length+'</h3>';items.forEach(function(p){var id=safeId(p.id);h+='<div style="background:rgba(6,6,12,0.7);padding:12px;margin:10px 0;border-radius:9px;border:1px solid rgba(255,255,255,0.05)"><div style="font-family:monospace;color:#22d3ee;font-size:12px;text-align:center;word-break:break-all;margin-bottom:8px">'+esc(p.connection_format||'')+'</div><button class="copy-btn" onclick="copyProxy(\''+id+'\')">&#128203; Копировать</button></div>'});h+='</div>';document.getElementById('results').innerHTML=h;toast('Создано: '+items.length,'success');loadProxies();loadDashboard()}
async function exportProxies(){var d=await api('/api/proxies');var items=d.proxies||[];if(!items.length){toast('Нет прокси для экспорта','error');return}var t=items.map(function(p){return p.connection_format}).join('\n');var b=new Blob([t],{type:'text/plain'});var a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='proxies.txt';a.click();toast('Экспортировано: '+items.length,'success')}
async function checkAll(btn){setBtnLoading(btn,true,'Проверяю...');var box=document.getElementById('checkResults');box.innerHTML='<div class="loading-block"><span class="spinner"></span> Проверяю все прокси...</div>';var d=await api('/api/proxy/check-all');setBtnLoading(btn,false);var items=d.results||[];if(!items.length){box.innerHTML='<div class="empty"><div class="empty-icon">&#128237;</div><div class="empty-title">Нет прокси для проверки</div><div class="empty-sub">Сначала создайте прокси</div></div>';return}var h='<div style="display:flex;gap:16px;margin-bottom:14px;font-size:13px;flex-wrap:wrap"><span>Всего: <b>'+d.total+'</b></span><span style="color:#10b981">Открыто: <b>'+d.open+'</b></span><span style="color:#10b981">Работает: <b>'+d.working+'</b></span></div>';h+='<table class="tbl"><thead><tr><th>Порт</th><th>Статус</th><th>Интернет</th><th>IPv6</th></tr></thead><tbody>';items.forEach(function(r){var portBadge=r.open?'<span class="badge badge-ok">Открыт</span>':'<span class="badge badge-err">Закрыт</span>';var inetBadge=!r.open?'<span class="badge badge-wait">&mdash;</span>':(r.internet&&r.internet.status==='working'?'<span class="badge badge-ok">&#10003; IPv6</span>':'<span class="badge badge-err">Нет</span>');var ip=(r.internet&&r.internet.ip)?'<span style="font-family:monospace;font-size:11px;color:#22d3ee">'+esc(r.internet.ip)+'</span>':'&mdash;';h+='<tr><td><b>'+esc(r.port)+'</b></td><td>'+portBadge+'</td><td>'+inetBadge+'</td><td>'+ip+'</td></tr>'});h+='</tbody></table>';box.innerHTML=h;toast('Проверено: '+d.total,'success')}
async function checkDuplicates(){var d=await api('/api/proxy/check-duplicates');if(d.duplicates>0)toast('Дубликатов найдено: '+d.duplicates,'warning');else toast('Дубликатов нет','success')}
async function loadProxySelect(){var s=document.getElementById('testProxy');s.innerHTML='<option value="">Загрузка...</option>';var d=await api('/api/proxies');var items=d.proxies||[];s.innerHTML='';if(!items.length){s.innerHTML='<option value="">Нет прокси</option>';return}items.forEach(function(p){var o=document.createElement('option');o.value=p.id;o.textContent='Порт '+p.port+' ('+p.username+')';s.appendChild(o)})}
async function testWebsite(btn){var pid=document.getElementById('testProxy').value;var url=document.getElementById('testUrl').value;var box=document.getElementById('siteTestResult');setBtnLoading(btn,true,'Проверяю...');box.innerHTML='<div class="loading-block"><span class="spinner"></span> Проверяю '+esc(url)+'...</div>';var d=await api('/api/proxy/check-website','POST',{proxy_id:pid,url:url});setBtnLoading(btn,false);if(d.error){box.innerHTML='<div class="card" style="border-color:rgba(239,68,68,0.3)"><span style="color:#fca5a5">&#10005; '+esc(d.error)+'</span></div>';return}var ok=d.accessible;var color=ok?'#10b981':'#ef4444';box.innerHTML='<div class="card" style="border-color:'+color+'33"><div style="font-size:16px;color:'+color+';margin-bottom:10px;font-weight:600">'+(ok?'&#10003;':'&#10005;')+' HTTP '+esc(d.http_code)+' &middot; '+esc(d.url)+'</div><div style="font-size:12px;color:var(--text-dim);line-height:1.7">Прокси: <b>'+esc(d.proxy)+'</b><br>IPv6: <span style="font-family:monospace;color:#22d3ee">'+esc(d.ipv6)+'</span></div>'+(d.error?'<div style="color:#fca5a5;font-size:12px;margin-top:8px">'+esc(d.error)+'</div>':'')+'</div>'}
async function loadSystem(){var box=document.getElementById('sysInfo');box.innerHTML='<div class="loading-block" style="grid-column:1/-1"><span class="spinner"></span> Загружаю системную информацию...</div>';var d=await api('/api/system-info');if(d.error){box.innerHTML='<div class="card">Ошибка: '+esc(d.error)+'</div>';return}var nc=d.network_config||{};var sys=d.system||{};var cpu=d.cpu||{};var mem=d.memory||{};var sw=d.swap||{};var net=d.network||{};var h='';h+='<div class="card"><h3>&#128421; CPU</h3><div style="font-size:26px;font-weight:700;color:#fff;margin:6px 0">'+(cpu.percent||0)+'%</div><div style="font-size:12px;color:var(--text-dim)">Ядер: '+(cpu.count||0)+' &middot; Load: '+((sys.load_avg&&sys.load_avg[0])||0)+'</div></div>';h+='<div class="card"><h3>&#128190; RAM</h3><div style="font-size:26px;font-weight:700;color:#fff;margin:6px 0">'+(mem.used||'0')+' / '+(mem.total||'0')+' GB</div><div style="font-size:12px;color:var(--text-dim)">'+(mem.percent||0)+'% использовано &middot; Swap: '+(sw.used||'0')+' GB</div></div>';h+='<div class="card"><h3>&#128189; Диски</h3>';(d.disks||[]).forEach(function(k){h+='<div style="font-size:12px;color:var(--text-dim);margin:5px 0"><b style="color:#fff">'+esc(k.mountpoint)+'</b> &mdash; '+esc(k.used)+' / '+esc(k.total)+' GB ('+esc(k.percent)+'%)</div>'});h+='</div>';h+='<div class="card"><h3>&#127760; Сеть</h3><div style="font-size:12px;color:var(--text-dim);line-height:1.9">Внешний IPv4: <b style="color:#fff">'+esc(nc.external_ipv4)+'</b><br>Локальный IPv4: <b style="color:#fff">'+esc(nc.local_ipv4)+'</b><br>IPv6 подсеть: <span style="font-family:monospace;color:#22d3ee">'+esc(nc.ipv6_subnet)+'</span><br>TX: <b style="color:#fff">'+(net.sent||'0')+' MB</b> &middot; RX: <b style="color:#fff">'+(net.recv||'0')+' MB</b></div></div>';h+='<div class="card"><h3>&#9881; Система</h3><div style="font-size:12px;color:var(--text-dim);line-height:1.9">Хост: <b style="color:#fff">'+esc(sys.hostname)+'</b><br>ОС: '+esc(sys.os)+'<br>Ядро: '+esc(sys.kernel)+'<br>Аптайм: '+esc(sys.uptime)+'</div></div>';box.innerHTML=h}
async function restart3proxy(){if(!confirm('Перезапустить 3proxy?'))return;toast('Перезапускаю...','info');var d=await api('/api/server/restart-3proxy','POST');if(d.error)toast(d.error,'error');else toast(d.message||'3proxy перезапущен','success')}
async function rebootServer(){if(!confirm('Перезагрузить сервер?\n\nВсе соединения будут разорваны.'))return;toast('Перезагрузка...','warning');var d=await api('/api/server/reboot','POST');if(d.error)toast(d.error,'error')}
async function loadSettings(){var d=await api('/api/system-info');if(d.error)return;var nc=d.network_config||{};var ps=d.proxy_stats||{};document.getElementById('settingsInfo').innerHTML='Внешний IP: <b style="color:#fff">'+esc(nc.external_ipv4)+'</b><br>Локальный IP: <b style="color:#fff">'+esc(nc.local_ipv4)+'</b><br>IPv6 подсеть: <span style="font-family:monospace;color:#22d3ee">'+esc(nc.ipv6_subnet)+'</span><br>Всего прокси: <b style="color:#fff">'+(ps.total||0)+'</b>'}
async function changePassword(){var o=document.getElementById('oldPassword').value;var n=document.getElementById('newPassword').value;if(!o||!n){toast('Заполните оба поля','error');return}if(n.length<6){toast('Минимум 6 символов','error');return}var d=await api('/api/settings/change-password','POST',{old_password:o,new_password:n});if(d.error)toast(d.error,'error');else{toast('Пароль изменён','success');document.getElementById('oldPassword').value='';document.getElementById('newPassword').value=''}}
async function checkStatus(){var pill=document.getElementById('statusPill');var label=document.getElementById('statusLabel');try{var r=await fetch('/api/system-info',{credentials:'same-origin'});var ct=r.headers.get('content-type')||'';if(r.ok&&ct.indexOf('application/json')>=0){pill.classList.remove('offline');label.textContent='Онлайн'}else{pill.classList.add('offline');label.textContent='Офлайн'}}catch(e){pill.classList.add('offline');label.textContent='Офлайн'}}
setInterval(function(){if(document.getElementById('dashboard').classList.contains('active'))loadDashboard()},10000);
setInterval(checkStatus,30000);
loadDashboard();checkStatus();
</script>
</body>
</html>
HTMLEOF

echo "[6/6] Сервисы и запуск..."

cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy IPv6 Proxy Farm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/opt/proxy-farm/venv/bin/python /opt/proxy-farm/restore_ipv6.py
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxy-farm.service << 'EOF'
[Unit]
Description=ProxyFarm Web
After=network-online.target 3proxy.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxy-farm
Environment="PATH=/opt/proxy-farm/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"
ExecStart=/opt/proxy-farm/venv/bin/python /opt/proxy-farm/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cd /opt/proxy-farm && source venv/bin/activate
python3 << PYEOF
import json, subprocess, ipaddress, random, os
from datetime import datetime
from werkzeug.security import generate_password_hash
INTERFACE = "$INTERFACE"
IPV6_SUBNET = "$IPV6_SUBNET"
IPV4_EXTERNAL = "$IPV4_EXTERNAL"
IPV4_LOCAL = "$IPV4_LOCAL"
PROXY_START = $PROXY_START
PROXY_END = $PROXY_END
ADMIN_PASS = "$ADMIN_PASS"
PROXY_DB = '/opt/proxy-farm/proxies.json'
USERS_DB = '/opt/proxy-farm/users.json'
IP_BIN = '/usr/sbin/ip' if os.path.exists('/usr/sbin/ip') else '/sbin/ip'

try:
    with open(USERS_DB) as f: users = json.load(f)
except Exception:
    users = []
admin_hash = generate_password_hash(ADMIN_PASS)
for u in users:
    if u.get('username') == 'admin':
        u['password'] = admin_hash
        break
else:
    users.append({'id': '1', 'username': 'admin', 'password': admin_hash})
with open(USERS_DB, 'w') as f: json.dump(users, f)
print("Пароль админа сохранён в users.json")

proxies = []
try:
    if os.path.getsize(PROXY_DB) > 2:
        with open(PROXY_DB) as f: proxies = json.load(f)
except Exception:
    proxies = []

if proxies:
    print(f"Существующие прокси сохранены: {len(proxies)}")
else:
    network = ipaddress.ip_network(IPV6_SUBNET)
    used = set()
    count = min(5, PROXY_END - PROXY_START + 1)
    for i in range(count):
        while True:
            ipv6 = str(network.network_address + random.randint(1, (1 << 64) - 2))
            if ipv6 not in used:
                used.add(ipv6)
                break
        port = PROXY_START + i
        login = f"user{port}"
        passwd = f"pass{port}"
        proxies.append({'id': f"p{port}", 'ipv6': ipv6, 'port': port, 'username': login, 'password': passwd, 'created_at': datetime.now().isoformat(), 'active': True, 'connection_format': f"http://{IPV4_EXTERNAL}:{port}:{login}:{passwd}"})
    with open(PROXY_DB, 'w') as f: json.dump(proxies, f, indent=2)
    print(f"Создано {len(proxies)} тестовых прокси")

for p in proxies:
    if p.get('active', True) and p.get('ipv6'):
        r = subprocess.run([IP_BIN, '-6', 'addr', 'add', f"{p['ipv6']}/64", 'dev', INTERFACE], capture_output=True, text=True)
        err = (r.stderr or '') + (r.stdout or '')
        if r.returncode != 0 and 'File exists' not in err:
            print(f"⚠ IPv6 {p['ipv6']} не добавлен: {err.strip()}")

config = "nserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
users_added = set()
for p in proxies:
    if not p.get('active', True):
        continue
    u = f"{p['username']}:{p['password']}"
    if u not in users_added:
        config += f"users {p['username']}:CL:{p['password']}\n"
        users_added.add(u)
config += "\nallow *\n"
for p in proxies:
    if p.get('active', True):
        config += f"proxy -6 -n -a -p{p['port']} -i{IPV4_LOCAL} -e{p['ipv6']}\n"
config += "flush\n"
with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
auth = ""
for p in proxies:
    if p.get('active', True):
        auth += f"{p['username']}:CL:{p['password']}\n"
with open('/etc/3proxy/.proxyauth', 'w') as f: f.write(auth)
print(f"3proxy.cfg обновлён, активных прокси: {sum(1 for p in proxies if p.get('active', True))}")
PYEOF

chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm || true
sleep 3

echo ""
echo "Проверка сервисов..."
FAIL=0
for svc in 3proxy proxy-farm; do
    if systemctl is-active --quiet "$svc"; then
        echo "  [OK]   $svc"
    else
        echo "  [FAIL] $svc"
        journalctl -u "$svc" -n 15 --no-pager || true
        FAIL=1
    fi
done
if ss -ltn 2>/dev/null | grep -q ':2525 '; then
    echo "  [OK]   веб-порт 2525"
else
    echo "  [FAIL] веб-порт 2525 не слушается"
    FAIL=1
fi
if curl -s --max-time 5 "http://127.0.0.1:2525/login" -o /dev/null; then
    echo "  [OK]   веб-интерфейс отвечает"
else
    echo "  [FAIL] веб-интерфейс не отвечает"
    FAIL=1
fi

echo ""
echo "=============================================================="
echo "  УСТАНОВКА ЗАВЕРШЕНА"
echo "  Веб-интерфейс:  http://$IPV4_LOCAL:2525"
if [ -n "$IPV4_EXTERNAL" ] && [ "$IPV4_EXTERNAL" != "$IPV4_LOCAL" ]; then
echo "  Извне:          http://$IPV4_EXTERNAL:2525 (нужен проброс порта 2525)"
fi
echo "  Логин:          admin"
echo "  Пароль:         $ADMIN_PASS"
echo "  Прокси:         порты $PROXY_START-$PROXY_END, IPv6 $IPV6_SUBNET"
echo ""
echo "  IPv6 адреса восстанавливаются при каждой загрузке"
echo "  (restore_ipv6.py через ExecStartPre у 3proxy)."
echo "  Перезагрузка:   sudo reboot"
echo "=============================================================="
if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "⚠ Один или несколько сервисов не запустились."
    echo "  Логи: journalctl -u 3proxy -n 50 --no-pager"
    echo "        journalctl -u proxy-farm -n 50 --no-pager"
    exit 1
fi
