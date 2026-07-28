cat > /opt/fix_proxy_final.sh << 'EOF'
#!/bin/bash

echo "Финальная настройка прокси-фермы..."

# Останавливаем сервисы
systemctl stop proxy-farm 3proxy 2>/dev/null
pkill -9 3proxy 2>/dev/null
pkill -9 python 2>/dev/null

# Исправляем генерацию IPv6 адресов и отображение
cat > /opt/proxy-farm/app.py << 'PYEOF'
#!/usr/bin/env python3
from flask import Flask, render_template, request, jsonify, redirect, url_for
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user
from werkzeug.security import generate_password_hash, check_password_hash
import json, os, random, string, ipaddress, subprocess, psutil, time
from datetime import datetime
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24).hex()

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

# Конфигурация
EXTERNAL_IPV4 = "62.148.226.89"
IPV6_SUBNET = "2a01:540:44c4:df00::/64"
IPV6_MAIN = "2a01:540:44c4:df00:20c:29ff:fe84:71d1"
ADMIN_PASSWORD_HASH = generate_password_hash("Maxim1809")
PROXY_DB = '/opt/proxy-farm/proxies.json'
USERS_DB = '/opt/proxy-farm/users.json'
THREEPROXY_BIN = '/usr/bin/3proxy'
THREEPROXY_CONFIG = '/etc/3proxy/3proxy.cfg'
THREEPROXY_AUTH = '/etc/3proxy/.proxyauth'

for f in [PROXY_DB, USERS_DB]:
    if not os.path.exists(f):
        with open(f, 'w') as fh: 
            json.dump([], fh)

class User(UserMixin):
    def __init__(self, id, username, password_hash):
        self.id = id
        self.username = username
        self.password_hash = password_hash

@login_manager.user_loader
def load_user(user_id):
    try:
        with open(USERS_DB) as f: 
            users = json.load(f)
        for u in users:
            if u['id'] == user_id: 
                return User(u['id'], u['username'], u['password'])
    except:
        pass
    return None

def load_proxies():
    try:
        with open(PROXY_DB) as f: 
            return json.load(f)
    except:
        return []

def save_proxies(proxies):
    with open(PROXY_DB, 'w') as f: 
        json.dump(proxies, f, indent=2)

def generate_random_ipv6():
    """Генерация случайного IPv6 адреса в подсети"""
    network = ipaddress.ip_network(IPV6_SUBNET)
    # Получаем случайный host part
    random_host = random.randint(1, 2**64 - 2)
    ip = network.network_address + random_host
    return str(ip)

def get_available_ips(count=1):
    """Получение уникальных случайных IPv6 адресов"""
    used = set(p.get('ipv6', '') for p in load_proxies())
    available = []
    attempts = 0
    max_attempts = count * 100  # Максимальное количество попыток
    
    while len(available) < count and attempts < max_attempts:
        ip = generate_random_ipv6()
        if ip not in used and ip != IPV6_MAIN:
            available.append(ip)
            used.add(ip)
        attempts += 1
    
    return available

def generate_proxy_config():
    """Генерация конфигурации 3proxy"""
    try:
        proxies = load_proxies()
        
        config = f"""nserver 8.8.8.8
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $/etc/3proxy/.proxyauth
log /var/log/3proxy/3proxy.log D
auth strong
allow * * * 80-65535
"""
        
        for p in proxies:
            if p.get('active', True):
                # Клиенты подключаются к внешнему IPv4, выходят через IPv6
                config += f"proxy -6 -n -a -p{p['port']} -i{EXTERNAL_IPV4} -e{p['ipv6']}\n"
        
        config += "flush\n"
        
        with open(THREEPROXY_CONFIG, 'w') as f:
            f.write(config)
        
        # Файл аутентификации
        auth = ""
        for p in proxies:
            if p.get('active', True):
                auth += f"{p['username']}:CL:{p['password']}\n"
        
        with open(THREEPROXY_AUTH, 'w') as f:
            f.write(auth)
        
        return True
    except Exception as e:
        logger.error(f"Error generating config: {e}")
        return False

def restart_3proxy():
    try:
        os.system('pkill 3proxy')
        time.sleep(1)
        os.system(f'{THREEPROXY_BIN} {THREEPROXY_CONFIG} &')
        time.sleep(1)
        return True
    except Exception as e:
        logger.error(f"Error restarting 3proxy: {e}")
        return False

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
            login_user(User('1', 'admin', ADMIN_PASSWORD_HASH))
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
    try:
        proxies = load_proxies()
        active = sum(1 for p in proxies if p.get('active', True))
        
        # Добавляем информацию для отображения
        for p in proxies:
            p['display_ip'] = EXTERNAL_IPV4  # Показываем внешний IPv4
            p['display_port'] = p['port']
            p['outgoing_ipv6'] = p['ipv6']  # Исходящий IPv6
            p['connection_format'] = f"{EXTERNAL_IPV4}:{p['port']}:{p['username']}:{p['password']}"
        
        return jsonify({
            'proxies': proxies,
            'external_ip': EXTERNAL_IPV4,
            'stats': {
                'active': active,
                'total': len(proxies),
                'ports_used': len(proxies),
                'ports_available': 1001 - len(proxies),
                'available_ips': '~18 квинтиллионов'  # /64 подсеть
            }
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/create', methods=['POST'])
@login_required
def api_create():
    try:
        data = request.json
        count = int(data.get('count', 1))
        
        proxies = load_proxies()
        used_ports = set(p['port'] for p in proxies)
        available_ports = [p for p in range(30000, 31001) if p not in used_ports]
        
        if count > len(available_ports):
            return jsonify({'error': f'Недостаточно портов. Доступно: {len(available_ports)}'}), 400
        
        # Генерируем случайные IPv6
        ipv6_addresses = get_available_ips(count)
        
        if len(ipv6_addresses) < count:
            return jsonify({'error': 'Не удалось сгенерировать достаточно уникальных IPv6'}), 400
        
        created = []
        for i in range(count):
            username = data.get('username') or f"user_{random.randint(10000,99999)}"
            password = data.get('password') or ''.join(random.choices(string.ascii_letters+string.digits, k=12))
            
            proxy = {
                'id': datetime.now().strftime('%Y%m%d%H%M%S') + str(random.randint(1000,9999)),
                'ipv6': ipv6_addresses[i],  # Исходящий IPv6
                'port': available_ports[i],
                'username': username,
                'password': password,
                'created_at': datetime.now().isoformat(),
                'active': True,
                'display_ip': EXTERNAL_IPV4,
                'connection_format': f"{EXTERNAL_IPV4}:{available_ports[i]}:{username}:{password}"
            }
            proxies.append(proxy)
            created.append(proxy)
        
        save_proxies(proxies)
        generate_proxy_config()
        restart_3proxy()
        
        return jsonify({
            'message': f'Создано {count} прокси', 
            'proxies': created,
            'format': 'IP:PORT:LOGIN:PASS'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/delete', methods=['POST'])
@login_required
def api_delete():
    try:
        ids = request.json.get('ids', [])
        proxies = [p for p in load_proxies() if p['id'] not in ids]
        save_proxies(proxies)
        generate_proxy_config()
        restart_3proxy()
        return jsonify({'message': f'Удалено {len(ids)} прокси'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/rotate', methods=['POST'])
@login_required
def api_rotate():
    try:
        ids = request.json.get('ids', [])
        proxies = load_proxies()
        rotated = []
        
        for proxy in proxies:
            if proxy['id'] in ids:
                new_ipv6 = get_available_ips(1)
                if new_ipv6:
                    proxy['ipv6'] = new_ipv6[0]
                    proxy['rotated_at'] = datetime.now().isoformat()
                    rotated.append(proxy['id'])
        
        save_proxies(proxies)
        generate_proxy_config()
        restart_3proxy()
        return jsonify({'message': f'Ротировано {len(rotated)} прокси'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/proxy/check-duplicates', methods=['GET'])
@login_required
def check_duplicates():
    try:
        proxies = load_proxies()
        seen = {}
        dups = []
        for p in proxies:
            if p['ipv6'] in seen:
                dups.append(p)
            else:
                seen[p['ipv6']] = p
        return jsonify({'duplicates': len(dups), 'details': dups})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system-info')
@login_required
def system_info():
    try:
        cpu = psutil.cpu_percent(interval=0.5)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        net = psutil.net_io_counters()
        uptime = int(time.time() - psutil.boot_time())
        
        proxies = load_proxies()
        active_proxies = sum(1 for p in proxies if p.get('active', True))
        
        return jsonify({
            'cpu_percent': cpu,
            'cpu_count': psutil.cpu_count(),
            'memory_percent': mem.percent,
            'memory_used': f"{mem.used/(1024**3):.1f} GB",
            'memory_total': f"{mem.total/(1024**3):.1f} GB",
            'disk_percent': disk.percent,
            'disk_used': f"{disk.used/(1024**3):.1f} GB",
            'disk_total': f"{disk.total/(1024**3):.1f} GB",
            'network_sent': f"{net.bytes_sent/(1024**2):.1f} MB",
            'network_recv': f"{net.bytes_recv/(1024**2):.1f} MB",
            'hostname': os.uname().nodename,
            'os': f"{os.uname().sysname} {os.uname().release}",
            'uptime': str(datetime.timedelta(seconds=uptime)),
            'external_ipv4': EXTERNAL_IPV4,
            'ipv6_subnet': IPV6_SUBNET,
            'active_proxies': active_proxies,
            'total_proxies': len(proxies),
            'timestamp': datetime.now().isoformat()
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Создаем админа
    try:
        with open(USERS_DB) as f:
            users = json.load(f)
    except:
        users = []
    
    if not any(u.get('username') == 'admin' for u in users):
        users.append({
            'id': '1',
            'username': 'admin',
            'password': ADMIN_PASSWORD_HASH
        })
        with open(USERS_DB, 'w') as f:
            json.dump(users, f, indent=2)
    
    # Запускаем 3proxy
    generate_proxy_config()
    restart_3proxy()
    
    print(f"""
    ╔═══════════════════════════════════════════╗
    ║     Proxy Farm Neo запущен!              ║
    ║     Внешний IP: {EXTERNAL_IPV4}                ║
    ║     Веб: http://{EXTERNAL_IPV4}:2525         ║
    ║     Логин: admin                         ║
    ║     Пароль: Maxim1809                    ║
    ╚═══════════════════════════════════════════╝
    """)
    
    app.run(host='0.0.0.0', port=2525, debug=False, threaded=True)
PYEOF

# Исправляем HTML для отображения IPv4:port:user:pass
cat > /opt/proxy-farm/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ProxyFarm Neo - Панель управления</title>
    <style>
        :root {
            --bg: #0a0a0f;
            --card: #1e1e2e;
            --purple: #6c5ce7;
            --text: #e4e4f0;
            --text2: #9898b0;
        }
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:Arial,sans-serif;background:var(--bg);color:var(--text);display:flex;min-height:100vh}
        
        .sidebar{width:250px;background:#13131a;padding:20px;position:fixed;height:100vh;border-right:1px solid #2a2a3a}
        .sidebar h2{background:linear-gradient(135deg,#6c5ce7,#a29bfe);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:30px;font-size:24px}
        .nav-btn{display:block;width:100%;padding:12px;margin:5px 0;background:none;border:none;color:var(--text2);text-align:left;cursor:pointer;border-radius:8px;font-size:14px}
        .nav-btn:hover,.nav-btn.active{background:#1a1a24;color:#fff}
        
        .main{margin-left:250px;padding:30px;flex:1}
        .header{display:flex;justify-content:space-between;margin-bottom:30px}
        .header h1{background:linear-gradient(135deg,#6c5ce7,#a29bfe);-webkit-background-clip:text;-webkit-text-fill-color:transparent;font-size:28px}
        
        .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px;margin-bottom:30px}
        .stat-card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a}
        .stat-card .value{font-size:32px;font-weight:bold;color:#a29bfe}
        .stat-card .label{color:var(--text2);font-size:13px;margin-top:5px}
        
        .btn{padding:10px 20px;border:none;border-radius:8px;cursor:pointer;font-size:14px;margin:5px;background:linear-gradient(135deg,#6c5ce7,#a29bfe);color:#fff}
        .btn-danger{background:linear-gradient(135deg,#ff1744,#ff5252)}
        .btn-success{background:linear-gradient(135deg,#00c853,#69f0ae)}
        
        .proxy-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(400px,1fr));gap:15px}
        .proxy-card{
            background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a;
            cursor:pointer;transition:all 0.3s
        }
        .proxy-card:hover{border-color:var(--purple)}
        .proxy-card.selected{border-color:#a29bfe;box-shadow:0 0 20px rgba(108,92,231,0.2)}
        .proxy-main{font-family:monospace;font-size:16px;color:#fff;margin-bottom:10px}
        .proxy-format{background:#1a1a24;padding:10px;border-radius:8px;font-family:monospace;font-size:14px;color:#00ff88;margin:10px 0;word-break:break-all}
        .proxy-out{color:var(--text2);font-size:12px}
        .proxy-details{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;font-size:13px}
        .detail-label{color:var(--text2);font-size:11px}
        .detail-value{font-family:monospace;color:#fff}
        
        .form-card{background:var(--card);padding:25px;border-radius:12px;margin-bottom:20px;border:1px solid #2a2a3a}
        .form-input{width:100%;padding:12px;margin:8px 0;background:#181825;border:1px solid #2a2a3a;border-radius:8px;color:#fff;font-size:14px}
        .form-input:focus{outline:none;border-color:#6c5ce7}
        
        .section{display:none}
        .section.active{display:block}
        
        .toast{position:fixed;top:20px;right:20px;background:var(--card);padding:15px 20px;border-radius:8px;animation:slideIn 0.3s;z-index:1000}
        .toast.success{border-left:4px solid #00c853}
        .toast.error{border-left:4px solid #ff1744}
        
        .copy-btn{background:#6c5ce7;color:#fff;border:none;padding:5px 10px;border-radius:5px;cursor:pointer;font-size:12px;margin-left:10px}
        .copy-btn:hover{background:#4834d4}
        
        @keyframes slideIn{from{transform:translateX(100%)}to{transform:translateX(0)}}
        
        @media(max-width:768px){
            .sidebar{width:60px;padding:10px}
            .sidebar h2,.sidebar span{display:none}
            .main{margin-left:60px;padding:15px}
            .proxy-grid{grid-template-columns:1fr}
            .stats{grid-template-columns:1fr}
        }
    </style>
</head>
<body>
    <nav class="sidebar">
        <h2>⚡ ProxyFarm Neo</h2>
        <button class="nav-btn active" onclick="showSection('dashboard',this)"><span>📊 Дашборд</span></button>
        <button class="nav-btn" onclick="showSection('proxies',this)"><span>🌐 Прокси</span></button>
        <button class="nav-btn" onclick="showSection('create',this)"><span>✨ Создать</span></button>
        <button class="nav-btn" onclick="showSection('system',this)"><span>🖥️ Система</span></button>
        <button class="nav-btn" onclick="location.href='/logout'"><span>🚪 Выход</span></button>
    </nav>
    
    <main class="main">
        <div class="section active" id="dashboard">
            <div class="header"><h1>Дашборд</h1><button class="btn" onclick="loadAll()">🔄 Обновить</button></div>
            <div class="stats" id="stats"></div>
            <div class="form-card">
                <h3 style="color:#a29bfe;margin-bottom:15px">📋 Формат подключения</h3>
                <div style="background:#1a1a24;padding:15px;border-radius:8px;font-family:monospace;color:#00ff88;font-size:18px;text-align:center">
                    62.148.226.89:PORT:LOGIN:PASS
                </div>
            </div>
        </div>
        
        <div class="section" id="proxies">
            <div class="header">
                <h1>Прокси</h1>
                <div>
                    <button class="btn btn-success" onclick="exportProxies()">📥 Экспорт</button>
                    <button class="btn" onclick="checkDuplicates()">🔍 Проверить дубликаты</button>
                    <button class="btn" onclick="rotateSelected()" id="rotateBtn" style="display:none">🔄 Ротировать</button>
                    <button class="btn btn-danger" onclick="deleteSelected()" id="delBtn" style="display:none">🗑️ Удалить</button>
                </div>
            </div>
            <div class="proxy-grid" id="proxyList"></div>
        </div>
        
        <div class="section" id="create">
            <div class="header"><h1>Создать прокси</h1></div>
            <div class="form-card">
                <h3 style="color:#a29bfe;margin-bottom:15px">⚡ Параметры прокси</h3>
                <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px">
                    <div>
                        <label style="color:#9898b0;font-size:12px;display:block;margin-bottom:5px">Количество</label>
                        <input type="number" class="form-input" id="count" value="1" min="1" max="100">
                    </div>
                    <div>
                        <label style="color:#9898b0;font-size:12px;display:block;margin-bottom:5px">Логин (опционально)</label>
                        <input type="text" class="form-input" id="username" placeholder="Автоматически">
                    </div>
                    <div>
                        <label style="color:#9898b0;font-size:12px;display:block;margin-bottom:5px">Пароль (опционально)</label>
                        <input type="text" class="form-input" id="password" placeholder="Автоматически">
                    </div>
                </div>
                <button class="btn" onclick="createProxies()" style="margin-top:15px;width:100%">✨ Создать прокси</button>
            </div>
            <div id="results" style="display:none"></div>
        </div>
        
        <div class="section" id="system">
            <div class="header"><h1>Система</h1><button class="btn" onclick="loadSystem()">🔄 Обновить</button></div>
            <div id="sysInfo"></div>
        </div>
    </main>
    
    <div id="toasts" style="position:fixed;top:20px;right:20px;z-index:1000"></div>
    
    <script>
        let selectedProxies = new Set();
        
        function showSection(name, btn) {
            document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
            document.getElementById(name).classList.add('active');
            document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
            if(btn) btn.classList.add('active');
            if(name === 'proxies') loadProxies();
            if(name === 'dashboard') loadDashboard();
            if(name === 'system') loadSystem();
        }
        
        async function api(url, method='GET', body=null) {
            const opts = {method, headers:{'Content-Type':'application/json'}};
            if(body) opts.body = JSON.stringify(body);
            const res = await fetch(url, opts);
            return res.json();
        }
        
        function toast(msg, type='success') {
            const div = document.createElement('div');
            div.className = `toast ${type}`;
            div.textContent = msg;
            document.getElementById('toasts').appendChild(div);
            setTimeout(() => div.remove(), 3000);
        }
        
        function copyToClipboard(text) {
            navigator.clipboard.writeText(text).then(() => {
                toast('Скопировано!', 'success');
            });
        }
        
        async function loadDashboard() {
            const data = await api('/api/proxies');
            document.getElementById('stats').innerHTML = `
                <div class="stat-card">
                    <div class="value">${data.stats.active}</div>
                    <div class="label">Активных прокси</div>
                </div>
                <div class="stat-card">
                    <div class="value">${data.stats.ports_available}</div>
                    <div class="label">Свободных портов</div>
                </div>
                <div class="stat-card">
                    <div class="value">${data.stats.total}</div>
                    <div class="label">Всего прокси</div>
                </div>
                <div class="stat-card">
                    <div class="value" style="color:#00c853">Online</div>
                    <div class="label">Статус сервера</div>
                </div>
            `;
        }
        
        async function loadProxies() {
            const data = await api('/api/proxies');
            const list = document.getElementById('proxyList');
            if(data.proxies.length === 0) {
                list.innerHTML = '<div style="text-align:center;padding:50px;color:#666"><h3>Нет прокси</h3><p>Создайте прокси во вкладке "Создать"</p></div>';
                return;
            }
            list.innerHTML = data.proxies.map(p => `
                <div class="proxy-card ${selectedProxies.has(p.id)?'selected':''}" onclick="toggleSelect('${p.id}')">
                    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                        <span class="proxy-main">🌐 ${p.connection_format}</span>
                        <span style="color:${p.active?'#00c853':'#ff1744'};font-size:12px">● ${p.active?'Active':'Inactive'}</span>
                    </div>
                    <div class="proxy-format" onclick="event.stopPropagation();copyToClipboard('${p.connection_format}')">
                        📋 ${p.connection_format} <button class="copy-btn">Копировать</button>
                    </div>
                    <div class="proxy-out">
                        Входящий: <b>${p.display_ip}:${p.port}</b> → Исходящий IPv6: <b style="color:#a29bfe">${p.ipv6}</b>
                    </div>
                    <div class="proxy-details">
                        <div><div class="detail-label">Логин</div><div class="detail-value">${p.username}</div></div>
                        <div><div class="detail-label">Пароль</div><div class="detail-value">${p.password}</div></div>
                        <div><div class="detail-label">Порт</div><div class="detail-value">${p.port}</div></div>
                        <div><div class="detail-label">Создан</div><div class="detail-value">${new Date(p.created_at).toLocaleDateString()}</div></div>
                    </div>
                </div>
            `).join('');
            
            document.getElementById('delBtn').style.display = selectedProxies.size > 0 ? 'inline-block' : 'none';
            document.getElementById('rotateBtn').style.display = selectedProxies.size > 0 ? 'inline-block' : 'none';
        }
        
        function toggleSelect(id) {
            if(selectedProxies.has(id)) selectedProxies.delete(id);
            else selectedProxies.add(id);
            loadProxies();
        }
        
        async function deleteSelected() {
            if(!confirm(`Удалить ${selectedProxies.size} прокси?`)) return;
            await api('/api/proxy/delete', 'POST', {ids: Array.from(selectedProxies)});
            selectedProxies.clear();
            toast('Прокси удалены', 'success');
            loadAll();
        }
        
        async function rotateSelected() {
            await api('/api/proxy/rotate', 'POST', {ids: Array.from(selectedProxies)});
            toast('Прокси ротированы', 'success');
            loadProxies();
        }
        
        async function checkDuplicates() {
            const data = await api('/api/proxy/check-duplicates');
            if(data.duplicates > 0) {
                toast(`Найдено дубликатов: ${data.duplicates}`, 'error');
            } else {
                toast('Дубликаты не найдены', 'success');
            }
        }
        
        async function createProxies() {
            const count = parseInt(document.getElementById('count').value) || 1;
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            
            const data = await api('/api/proxy/create', 'POST', {count, username, password});
            
            if(data.error) { 
                toast(data.error, 'error'); 
                return; 
            }
            
            const results = document.getElementById('results');
            results.style.display = 'block';
            results.innerHTML = `
                <div class="form-card">
                    <h3 style="color:#00c853;margin-bottom:15px">✅ Создано ${count} прокси</h3>
                    ${data.proxies.map(p => `
                        <div style="background:#1a1a24;padding:15px;margin:10px 0;border-radius:8px">
                            <div style="font-family:monospace;color:#00ff88;font-size:16px;margin-bottom:5px">${p.connection_format}</div>
                            <div style="color:#9898b0;font-size:12px">Исходящий IPv6: ${p.ipv6}</div>
                            <button class="copy-btn" onclick="copyToClipboard('${p.connection_format}')" style="margin-top:5px">📋 Копировать</button>
                        </div>
                    `).join('')}
                </div>
            `;
            
            toast(`Создано ${count} прокси`, 'success');
            loadAll();
        }
        
        async function exportProxies() {
            const data = await api('/api/proxies');
            const text = data.proxies.map(p => p.connection_format).join('\n');
            const blob = new Blob([text], {type: 'text/plain'});
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'proxies.txt';
            a.click();
            toast('Прокси экспортированы', 'success');
        }
        
        async function loadSystem() {
            const data = await api('/api/system-info');
            document.getElementById('sysInfo').innerHTML = `
                <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px">
                    <div class="form-card">
                        <h3 style="color:#a29bfe">🖥️ Процессор</h3>
                        <div style="font-size:36px;color:#fff;margin:10px 0">${data.cpu_percent}%</div>
                        <div style="color:#9898b0">Ядер: ${data.cpu_count}</div>
                        <div style="background:#1a1a24;height:8px;border-radius:4px;margin-top:10px">
                            <div style="background:linear-gradient(135deg,#6c5ce7,#a29bfe);height:100%;width:${data.cpu_percent}%;border-radius:4px"></div>
                        </div>
                    </div>
                    <div class="form-card">
                        <h3 style="color:#a29bfe">💾 Память</h3>
                        <div style="font-size:24px;color:#fff;margin:10px 0">${data.memory_used} / ${data.memory_total}</div>
                        <div style="color:#9898b0">${data.memory_percent}%</div>
                        <div style="background:#1a1a24;height:8px;border-radius:4px;margin-top:10px">
                            <div style="background:linear-gradient(135deg,#6c5ce7,#a29bfe);height:100%;width:${data.memory_percent}%;border-radius:4px"></div>
                        </div>
                    </div>
                    <div class="form-card">
                        <h3 style="color:#a29bfe">💿 Диск</h3>
                        <div style="font-size:24px;color:#fff;margin:10px 0">${data.disk_used} / ${data.disk_total}</div>
                        <div style="color:#9898b0">${data.disk_percent}%</div>
                    </div>
                    <div class="form-card">
                        <h3 style="color:#a29bfe">🌐 Сеть</h3>
                        <div style="color:#9898b0">
                            <div>Внешний IPv4: <b style="color:#fff">${data.external_ipv4}</b></div>
                            <div>IPv6 подсеть: <b style="color:#fff">${data.ipv6_subnet}</b></div>
                            <div>Отправлено: ${data.network_sent}</div>
                            <div>Получено: ${data.network_recv}</div>
                        </div>
                    </div>
                    <div class="form-card">
                        <h3 style="color:#a29bfe">📊 Статистика</h3>
                        <div style="color:#9898b0">
                            <div>Сервер: <b style="color:#fff">${data.hostname}</b></div>
                            <div>ОС: <b style="color:#fff">${data.os}</b></div>
                            <div>Аптайм: <b style="color:#fff">${data.uptime}</b></div>
                            <div>Активных прокси: <b style="color:#00c853">${data.active_proxies}</b></div>
                            <div>Всего прокси: <b style="color:#fff">${data.total_proxies}</b></div>
                        </div>
                    </div>
                </div>
            `;
        }
        
        function loadAll() { 
            loadDashboard(); 
            loadProxies(); 
        }
        
        loadDashboard();
        // Автообновление каждые 30 секунд
        setInterval(loadAll, 30000);
    </script>
</body>
</html>
HTMLEOF

# Перезапускаем сервисы
systemctl daemon-reload
systemctl restart proxy-farm

echo ""
echo "========================================="
echo "  ГОТОВО!"
echo "  Веб-интерфейс: http://62.148.226.89:2525"
echo "  Логин: admin"
echo "  Пароль: Maxim1809"
echo ""
echo "  Формат прокси: 62.148.226.89:PORT:LOGIN:PASS"
echo "========================================="
EOF

chmod +x /opt/fix_proxy_final.sh
bash /opt/fix_proxy_final.sh
