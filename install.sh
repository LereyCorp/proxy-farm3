cat > /root/proxy-farm3/install.sh << 'INSTALLEOF'
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ProxyFarm Neo - IPv6 Proxy Server v8.0         ║"
echo "║          Установка для Lirakva                          ║"
echo "╚══════════════════════════════════════════════════════════╝"

IPV4_LOCAL="192.168.1.7"
IPV4_EXTERNAL="62.148.226.89"
IPV6_SUBNET="2a01:540:44e1:c00::/64"
IPV6_MAIN="2a01:540:44e1:c00:20c:29ff:fe84:71d1"
INTERFACE="ens33"
ADMIN_PASS="Maxim1809"
PROXY_START=30000
PROXY_END=31000

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ПАРАМЕТРЫ УСТАНОВКИ                            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Локальный IPv4:    $IPV4_LOCAL"
echo "║ Внешний IPv4:      $IPV4_EXTERNAL"
echo "║ IPv6 подсеть:      $IPV6_SUBNET"
echo "║ Основной IPv6:     $IPV6_MAIN"
echo "║ Интерфейс:         $INTERFACE"
echo "║ Пароль админа:     $ADMIN_PASS"
echo "║ Порты прокси:      $PROXY_START-$PROXY_END"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

echo "[1/10] Установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential git wget tar gzip net-tools curl > /dev/null 2>&1

echo "[2/10] Установка 3proxy..."
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux > /dev/null 2>&1
make -f Makefile.Linux install > /dev/null 2>&1

echo "[3/10] Создание структуры..."
mkdir -p /opt/proxy-farm/templates /etc/3proxy /var/log/3proxy
cd /opt/proxy-farm

echo "[4/10] Настройка Python..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip > /dev/null 2>&1
pip install flask flask-login werkzeug psutil > /dev/null 2>&1

echo "[5/10] Создание приложения..."
wget -q -O /opt/proxy-farm/app.py https://raw.githubusercontent.com/Temporalitas/ipv6-proxy-server/main/app.py 2>/dev/null || cat > /opt/proxy-farm/app.py << 'PYEOF'
import sys, os, json, subprocess, time, socket, ipaddress, random, platform, re
from datetime import datetime
from flask import Flask, render_template, request, jsonify, redirect, url_for
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user
from werkzeug.security import generate_password_hash, check_password_hash
try: import psutil; PSUTIL = True
except: PSUTIL = False

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24).hex()
login_manager = LoginManager(); login_manager.init_app(app); login_manager.login_view = 'login'

EXTERNAL_IPV4 = "$IPV4_EXTERNAL"; LOCAL_IPV4 = "$IPV4_LOCAL"
IPV6_SUBNET = "$IPV6_SUBNET"; IPV6_MAIN = "$IPV6_MAIN"; INTERFACE = "$INTERFACE"
PROXY_START = $PROXY_START; PROXY_END = $PROXY_END
ADMIN_HASH = generate_password_hash("$ADMIN_PASS")
PROXY_DB = '/opt/proxy-farm/proxies.json'; USERS_DB = '/opt/proxy-farm/users.json'

for f in [PROXY_DB, USERS_DB]:
    if not os.path.exists(f):
        with open(f, 'w') as fh: json.dump([], fh)

class User(UserMixin):
    def __init__(self, id, username, password_hash): self.id = id; self.username = username; self.password_hash = password_hash

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

def random_ipv6():
    network = ipaddress.ip_network(IPV6_SUBNET)
    return str(network.network_address + random.getrandbits(64))

def update_3proxy_config():
    proxies = load_proxies()
    config = "daemon\nnserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
    for p in proxies:
        if p.get('active', True): config += f"users {p['username']}:CL:{p['password']}\n"
    config += "\nallow *\n"
    for p in proxies:
        if p.get('active', True): config += f"proxy -6 -n -a -p{p['port']} -i{LOCAL_IPV4} -e{p['ipv6']}\n"
    config += "flush\n"
    with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
    return True

def restart_3proxy():
    os.system('pkill -9 3proxy 2>/dev/null')
    time.sleep(3)
    subprocess.Popen('/usr/bin/3proxy /etc/3proxy/3proxy.cfg', shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(5)
    return True

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('username') == 'admin' and check_password_hash(ADMIN_HASH, request.form.get('password')):
            login_user(User('1', 'admin', ADMIN_HASH)); return redirect(url_for('index'))
        return render_template('login.html', error='Неверные данные')
    return render_template('login.html')

@app.route('/logout')
def logout(): logout_user(); return redirect(url_for('login'))

@app.route('/')
@login_required
def index(): return render_template('index.html')

@app.route('/api/proxies')
@login_required
def api_proxies():
    proxies = load_proxies()
    for p in proxies: p['connection_format'] = f"http://{EXTERNAL_IPV4}:{p['port']}:{p['username']}:{p['password']}"
    return jsonify({'proxies': proxies})

@app.route('/api/system-info')
@login_required
def system_info():
    info = {'cpu': {'percent': 0, 'count': 0}, 'memory': {'percent': 0, 'used': '0', 'total': '0'}, 'disks': [], 'network': {'sent': '0', 'recv': '0'}, 'system': {'hostname': socket.gethostname(), 'os': f"{platform.system()} {platform.release()}", 'uptime': 'N/A'}, 'network_config': {'external_ipv4': EXTERNAL_IPV4, 'local_ipv4': LOCAL_IPV4, 'ipv6_subnet': IPV6_SUBNET}, 'proxy_stats': {'active': 0, 'total': 0, 'ports_available': 0}}
    if PSUTIL:
        try:
            cpu = psutil.cpu_percent(interval=0.3); mem = psutil.virtual_memory()
            info['cpu'] = {'percent': round(cpu, 1), 'count': psutil.cpu_count()}
            info['memory'] = {'percent': mem.percent, 'used': f"{mem.used/(1024**3):.1f}", 'total': f"{mem.total/(1024**3):.1f}"}
            for part in psutil.disk_partitions():
                try:
                    usage = psutil.disk_usage(part.mountpoint)
                    info['disks'].append({'mountpoint': part.mountpoint, 'total': f"{usage.total/(1024**3):.1f}", 'used': f"{usage.used/(1024**3):.1f}", 'percent': usage.percent})
                except: pass
            net = psutil.net_io_counters(); info['network'] = {'sent': f"{net.bytes_sent/(1024**2):.1f}", 'recv': f"{net.bytes_recv/(1024**2):.1f}"}
            uptime = int(time.time() - psutil.boot_time()); h, m, s = uptime // 3600, (uptime % 3600) // 60, uptime % 60; info['system']['uptime'] = f"{h}ч {m}м {s}с"
        except: pass
    proxies = load_proxies(); info['proxy_stats'] = {'active': sum(1 for p in proxies if p.get('active', True)), 'total': len(proxies), 'ports_available': (PROXY_END - PROXY_START + 1) - len(proxies)}
    return jsonify(info)

@app.route('/api/proxy/create', methods=['POST'])
@login_required
def api_create():
    data = request.json; count = int(data.get('count', 1))
    username = data.get('username') or ''; password = data.get('password') or ''
    proxies = load_proxies(); used_ports = set(p['port'] for p in proxies)
    available = [p for p in range(PROXY_START, PROXY_END + 1) if p not in used_ports]
    if count > len(available): return jsonify({'error': 'Недостаточно портов'}), 400
    created = []
    for i in range(count):
        ipv6 = random_ipv6(); port = available[i]
        login = username or f"user{random.randint(10000,99999)}"; passwd = password or f"pass{random.randint(10000,99999)}"
        proxy = {'id': f"p{port}", 'ipv6': ipv6, 'port': port, 'username': login, 'password': passwd, 'created_at': datetime.now().isoformat(), 'active': True, 'connection_format': f"http://{EXTERNAL_IPV4}:{port}:{login}:{passwd}"}
        proxies.append(proxy); created.append(proxy)
    save_proxies(proxies); update_3proxy_config(); restart_3proxy()
    return jsonify({'message': f'Создано {len(created)} прокси', 'proxies': created})

@app.route('/api/proxy/delete', methods=['POST'])
@login_required
def api_delete():
    ids = request.json.get('ids', []); proxies = [p for p in load_proxies() if p['id'] not in ids]
    save_proxies(proxies); update_3proxy_config(); restart_3proxy()
    return jsonify({'message': 'Удалено'})

@app.route('/api/proxy/rotate', methods=['POST'])
@login_required
def api_rotate():
    ids = request.json.get('ids', []); proxies = load_proxies()
    for proxy in proxies:
        if proxy['id'] in ids: proxy['ipv6'] = random_ipv6()
    save_proxies(proxies); update_3proxy_config(); restart_3proxy()
    return jsonify({'message': 'Ротировано'})

@app.route('/api/proxy/check-all')
@login_required
def check_all():
    proxies = load_proxies(); results = []
    for p in proxies:
        try:
            r = subprocess.run(['curl', '-x', f"http://{p['username']}:{p['password']}@{LOCAL_IPV4}:{p['port']}", '-s', 'http://ip6only.me/api/', '--connect-timeout', '5', '--max-time', '10'], capture_output=True, text=True, timeout=15)
            match = re.search(r'IPv6,([0-9a-f:]+)', r.stdout)
            results.append({'port': p['port'], 'open': True, 'working': bool(match), 'ip': match.group(1) if match else None})
        except: results.append({'port': p['port'], 'open': False, 'working': False, 'ip': None})
    return jsonify({'total': len(results), 'working': sum(1 for r in results if r.get('working')), 'results': results})

@app.route('/api/proxy/check-duplicates')
@login_required
def check_duplicates():
    proxies = load_proxies(); seen = {}
    for p in proxies: seen.setdefault(p['ipv6'], []).append(p)
    return jsonify({'duplicates': sum(1 for v in seen.values() if len(v) > 1)})

@app.route('/api/server/restart-3proxy', methods=['POST'])
@login_required
def restart_3proxy_api(): update_3proxy_config(); restart_3proxy(); return jsonify({'message': '3proxy перезапущен'})

@app.route('/api/server/reboot', methods=['POST'])
@login_required
def reboot_server(): subprocess.Popen('sleep 3 && reboot', shell=True); return jsonify({'message': 'Перезагрузка...'})

if __name__ == '__main__':
    with open(USERS_DB) as f: users = json.load(f)
    if not any(u.get('username') == 'admin' for u in users):
        users.append({'id': '1', 'username': 'admin', 'password': ADMIN_HASH})
        with open(USERS_DB, 'w') as f: json.dump(users, f, indent=2)
    update_3proxy_config(); restart_3proxy()
    app.run(host='0.0.0.0', port=2525, debug=False, threaded=True)
PYEOF

echo "[6/10] Создание шаблонов..."
cat > /opt/proxy-farm/templates/login.html << 'HTMLEOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ProxyFarm Neo - Вход</title>
<style>*{margin:0;padding:0}body{font-family:Arial;background:linear-gradient(135deg,#0a0a0f,#1a1a2e);min-height:100vh;display:flex;align-items:center;justify-content:center}.box{background:rgba(30,30,46,0.95);padding:40px;border-radius:20px;width:380px;max-width:90%;border:1px solid #333}h1{color:#a29bfe;text-align:center;margin-bottom:30px}input{width:100%;padding:12px;margin:10px 0;background:#1a1a2e;border:1px solid #333;border-radius:8px;color:#fff;font-size:16px}input:focus{outline:none;border-color:#6c5ce7}button{width:100%;padding:12px;background:linear-gradient(135deg,#6c5ce7,#a29bfe);border:none;border-radius:8px;color:#fff;font-size:16px;cursor:pointer}button:hover{opacity:0.9}.error{background:rgba(255,0,0,0.1);color:#f44;padding:10px;border-radius:8px;margin-bottom:15px;text-align:center}</style></head>
<body><div class="box"><h1>⚡ ProxyFarm Neo</h1>{% if error %}<div class="error">{{ error }}</div>{% endif %}<form method="POST"><input type="text" name="username" placeholder="Логин" required><input type="password" name="password" placeholder="Пароль" required><button type="submit">Войти</button></form></div></body></html>
HTMLEOF

cat > /opt/proxy-farm/templates/index.html << 'HTMLEOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ProxyFarm Neo v8.0</title>
<style>:root{--bg:#0a0a0f;--card:#1e1e2e;--p:#6c5ce7;--t:#e4e4f0;--m:#9898b0;--g:#00c853;--r:#ff1744;--y:#ffa726}*{margin:0;padding:0;box-sizing:border-box}body{font-family:Arial;background:var(--bg);color:var(--t);min-height:100vh}.tabs{display:flex;background:#13131a;padding:10px 20px;gap:5px;flex-wrap:wrap;border-bottom:1px solid #2a2a3a;position:sticky;top:0;z-index:100}.tab-btn{padding:12px 20px;background:none;border:none;color:var(--m);cursor:pointer;border-radius:8px;font-size:14px;white-space:nowrap}.tab-btn:hover{background:#1a1a24;color:#fff}.tab-btn.active{background:linear-gradient(135deg,#6c5ce7,#4834d4);color:#fff}.main{padding:20px;max-width:1400px;margin:0 auto}.dashboard-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px;margin-bottom:20px}.stat-card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a}.stat-value{font-size:32px;font-weight:bold;color:#a29bfe}.stat-label{color:var(--m);font-size:13px;margin-top:5px}.card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a;margin-bottom:15px}.card h3{color:#a29bfe;margin-bottom:15px}.btn{padding:8px 16px;border:none;border-radius:8px;font-size:13px;margin:3px;cursor:pointer;color:#fff;background:linear-gradient(135deg,#6c5ce7,#a29bfe)}.btn-danger{background:linear-gradient(135deg,#ff1744,#ff5252)}.btn-success{background:linear-gradient(135deg,#00c853,#69f0ae)}.proxy-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(350px,1fr));gap:15px}.proxy-card{background:var(--card);padding:20px;border-radius:12px;border:1px solid #2a2a3a;cursor:pointer}.proxy-card.selected{border-color:#a29bfe}.proxy-format{background:#1a1a24;padding:12px;border-radius:8px;font-family:monospace;font-size:12px;color:#0f0;text-align:center;margin:10px 0;word-break:break-all}.copy-btn{display:block;width:100%;padding:10px;background:#6c5ce7;color:#fff;border:none;border-radius:6px;cursor:pointer}.form-input{width:100%;padding:12px;margin:8px 0;background:#181825;border:1px solid #2a2a3a;border-radius:8px;color:#fff;font-size:14px}.section{display:none}.section.active{display:block}.toast{position:fixed;top:20px;right:20px;background:var(--card);padding:15px 20px;border-radius:8px;z-index:9999;animation:slide .3s}.toast.success{border-left:4px solid var(--g)}@keyframes slide{from{transform:translateX(100%)}}.check-table{width:100%;border-collapse:collapse;margin-top:10px}.check-table th,.check-table td{padding:10px;border-bottom:1px solid #2a2a3a}.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(350px,1fr));gap:20px}@media(max-width:768px){.proxy-grid{grid-template-columns:1fr}.row{grid-template-columns:1fr}}</style></head>
<body><div class="tabs"><button class="tab-btn active" onclick="showTab('dashboard',this)">📊 Дашборд</button><button class="tab-btn" onclick="showTab('proxies',this)">🌐 Прокси</button><button class="tab-btn" onclick="showTab('create',this)">✨ Создать</button><button class="tab-btn" onclick="showTab('checker',this)">🔍 Проверка</button><button class="tab-btn" onclick="showTab('system',this)">🖥️ Система</button><button class="tab-btn" onclick="window.location.href='/logout'" style="margin-left:auto">🚪 Выйти</button></div>
<main class="main">
<div class="section active" id="dashboard"><div class="dashboard-grid" id="dashStats"></div></div>
<div class="section" id="proxies"><div style="display:flex;justify-content:space-between;margin-bottom:15px;flex-wrap:wrap;gap:10px"><h2 style="color:#a29bfe">Прокси</h2><div><button class="btn btn-success" onclick="exportProxies()">📥 Экспорт</button><button class="btn" onclick="checkDuplicates()">🔍 Дубликаты</button><button class="btn btn-danger" onclick="deleteSelected()" id="delBtn" style="display:none">🗑️ Удалить</button></div></div><div class="proxy-grid" id="proxyList"></div></div>
<div class="section" id="create"><h2 style="color:#a29bfe;margin-bottom:15px">Создание</h2><div class="card"><div style="display:grid;grid-template-columns:repeat(3,1fr);gap:15px"><div><label class="form-label">Количество</label><input type="number" class="form-input" id="count" value="1" min="1" max="100"></div><div><label class="form-label">Логин</label><input type="text" class="form-input" id="username" placeholder="Авто"></div><div><label class="form-label">Пароль</label><input type="text" class="form-input" id="password" placeholder="Авто"></div></div><button class="btn" onclick="createProxies()" style="width:100%;margin-top:15px;padding:14px;font-size:16px">✨ Создать</button></div><div id="results"></div></div>
<div class="section" id="checker"><h2 style="color:#a29bfe;margin-bottom:15px">Проверка</h2><button class="btn" onclick="checkAll()">🔍 Проверить всё</button><div class="card" style="margin-top:15px"><div id="checkResults">Нажмите "Проверить всё"</div></div></div>
<div class="section" id="system"><h2 style="color:#a29bfe;margin-bottom:15px">Система</h2><div class="row" id="sysInfo"></div></div>
</main><div id="toasts"></div>
<script>
var selectedProxies=[];
function showTab(n,b){document.querySelectorAll('.section').forEach(function(s){s.classList.remove('active')});document.getElementById(n).classList.add('active');document.querySelectorAll('.tab-btn').forEach(function(x){x.classList.remove('active')});if(b)b.classList.add('active');if(n==='proxies')loadProxies();if(n==='dashboard')loadDashboard();if(n==='system')loadSystem()}
function api(u,m,b,c){m=m||'GET';var x=new XMLHttpRequest();x.open(m,u,true);x.setRequestHeader('Content-Type','application/json');x.onload=function(){c(x.status===200?JSON.parse(x.responseText):{})};x.onerror=function(){c({})};x.send(b?JSON.stringify(b):null)}
function toast(m,t){t=t||'success';var d=document.createElement('div');d.className='toast '+t;d.textContent=m;document.getElementById('toasts').appendChild(d);setTimeout(function(){d.remove()},3000)}
function copyText(t){var i=document.createElement('textarea');i.value=t;i.style.position='fixed';i.style.opacity='0';document.body.appendChild(i);i.select();document.execCommand('copy');document.body.removeChild(i);toast('Скопировано!')}
function loadDashboard(){api('/api/system-info','GET',null,function(d){document.getElementById('dashStats').innerHTML='<div class="stat-card"><div class="stat-value">'+(d.proxy_stats?d.proxy_stats.active:0)+'</div><div class="stat-label">Активных</div></div><div class="stat-card"><div class="stat-value">'+(d.proxy_stats?d.proxy_stats.ports_available:0)+'</div><div class="stat-label">Портов</div></div><div class="stat-card"><div class="stat-value">'+(d.cpu?d.cpu.percent:0)+'%</div><div class="stat-label">CPU</div></div><div class="stat-card"><div class="stat-value">'+(d.memory?d.memory.percent:0)+'%</div><div class="stat-label">RAM</div></div>'})}
function loadProxies(){api('/api/proxies','GET',null,function(d){var l=document.getElementById('proxyList');if(!d.proxies||d.proxies.length===0){l.innerHTML='<div style="text-align:center;padding:40px;color:#666">Нет прокси</div>';return}var h='';for(var i=0;i<d.proxies.length;i++){var p=d.proxies[i];var s=selectedProxies.indexOf(p.id)>=0?' selected':'';h+='<div class="proxy-card'+s+'" onclick="selectProxy(\''+p.id+'\')"><div style="font-weight:bold;margin-bottom:8px">Порт '+p.port+' | '+p.username+':'+p.password+'</div><div class="proxy-format">'+(p.connection_format||'')+'</div><button class="copy-btn" onclick="event.stopPropagation();copyText(\''+(p.connection_format||'')+'\')">📋 Копировать</button></div>'}l.innerHTML=h;document.getElementById('delBtn').style.display=selectedProxies.length>0?'inline-block':'none'})}
function selectProxy(id){var i=selectedProxies.indexOf(id);if(i>=0)selectedProxies.splice(i,1);else selectedProxies.push(id);loadProxies()}
function deleteSelected(){if(selectedProxies.length===0)return;if(!confirm('Удалить?'))return;api('/api/proxy/delete','POST',{ids:selectedProxies},function(){selectedProxies=[];toast('Удалено');loadProxies();loadDashboard()})}
function createProxies(){var c=parseInt(document.getElementById('count').value)||1;api('/api/proxy/create','POST',{count:c,username:document.getElementById('username').value,password:document.getElementById('password').value},function(d){if(d.error){toast(d.error,'error');return}var h='<div class="card" style="margin-top:15px"><h3 style="color:#00c853">✅ Создано '+c+'</h3>';for(var i=0;i<d.proxies.length;i++){var f=d.proxies[i].connection_format;h+='<div style="background:#1a1a24;padding:12px;margin:8px 0;border-radius:8px"><div style="font-family:monospace;color:#0f0;text-align:center;margin-bottom:8px">'+f+'</div><button class="copy-btn" onclick="copyText(\''+f+'\')">📋 Копировать</button></div>'}h+='</div>';document.getElementById('results').innerHTML=h;toast('Создано '+c);loadProxies();loadDashboard()})}
function exportProxies(){api('/api/proxies','GET',null,function(d){if(!d.proxies||d.proxies.length===0){toast('Нет прокси','error');return}var t='';for(var i=0;i<d.proxies.length;i++)t+=d.proxies[i].connection_format+'\n';var b=new Blob([t]);var a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='proxies.txt';a.click();toast('Экспортировано')})}
function checkAll(){document.getElementById('checkResults').innerHTML='<div style="text-align:center;padding:20px">⏳ Проверка...</div>';api('/api/proxy/check-all','GET',null,function(d){var h='<h3 style="color:#a29bfe">Результаты</h3>';h+='<div style="margin-bottom:10px">Всего: <b>'+d.total+'</b> | Работает: <b style="color:#00c853">'+d.working+'</b></div>';h+='<table class="check-table"><tr><th>Порт</th><th>Работает</th><th>IP</th></tr>';for(var i=0;i<d.results.length;i++){var r=d.results[i];h+='<tr><td><b>'+r.port+'</b></td><td>'+(r.working?'<span style="color:#00c853">✅</span>':'<span style="color:#f44">❌</span>')+'</td><td><span style="font-size:10px">'+(r.ip||'-')+'</span></td></tr>'}h+='</table>';document.getElementById('checkResults').innerHTML=h;toast('Проверено '+d.total)})}
function checkDuplicates(){api('/api/proxy/check-duplicates','GET',null,function(d){toast(d.duplicates>0?'Дубликатов: '+d.duplicates:'Дубликатов нет',d.duplicates>0?'error':'success')})}
function loadSystem(){api('/api/system-info','GET',null,function(d){document.getElementById('sysInfo').innerHTML='<div class="card"><h3>🖥️ CPU</h3><div style="font-size:28px;color:#a29bfe">'+(d.cpu?d.cpu.percent:0)+'%</div><div>Ядер: '+(d.cpu?d.cpu.count:0)+'</div></div><div class="card"><h3>💾 RAM</h3><div style="font-size:28px;color:#a29bfe">'+(d.memory?d.memory.used:'0')+'/'+(d.memory?d.memory.total:'0')+' GB</div></div><div class="card"><h3>🌐 Сеть</h3><div>Внешний: '+d.network_config.external_ipv4+'</div><div>Локальный: '+d.network_config.local_ipv4+'</div><div>IPv6: '+d.network_config.ipv6_subnet+'</div></div><div class="card"><h3>📊 Система</h3><div>Хост: '+d.system.hostname+'</div><div>Аптайм: '+d.system.uptime+'</div></div>'})}
setInterval(function(){if(document.getElementById('dashboard').classList.contains('active'))loadDashboard()},10000);
loadDashboard();
</script></body></html>
HTMLEOF

echo "[7/10] Сервисы..."
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
WorkingDirectory=/opt/proxy-farm
ExecStart=/opt/proxy-farm/venv/bin/python /opt/proxy-farm/app.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

echo "[8/10] Тестовые прокси..."
cd /opt/proxy-farm && source venv/bin/activate
python3 << PYEOF
import json, subprocess, ipaddress, random
INTERFACE = "$INTERFACE"; IPV6_SUBNET = "$IPV6_SUBNET"
IPV4_EXTERNAL = "$IPV4_EXTERNAL"; IPV4_LOCAL = "$IPV4_LOCAL"
PROXY_START = $PROXY_START; network = ipaddress.ip_network(IPV6_SUBNET)
proxies = []
for i in range(5):
    ipv6 = str(network.network_address + random.getrandbits(64))
    port = PROXY_START + i; login = f"user{port}"; passwd = f"pass{port}"
    proxies.append({'id': f"p{port}", 'ipv6': ipv6, 'port': port, 'username': login, 'password': passwd, 'created_at': '2026-07-28T00:00:00', 'active': True, 'connection_format': f"http://{IPV4_EXTERNAL}:{port}:{login}:{passwd}"})
with open('/opt/proxy-farm/proxies.json', 'w') as f: json.dump(proxies, f, indent=2)
config = "daemon\nnserver 1.1.1.1\nmaxconn 200\nnscache 65536\ntimeouts 1 5 30 60 180 1800 15 60\nsetgid 65535\nsetuid 65535\n\nauth strong\n"
for p in proxies: config += f"users {p['username']}:CL:{p['password']}\n"
config += "\nallow *\n"
for p in proxies: config += f"proxy -6 -n -a -p{p['port']} -i{IPV4_LOCAL} -e{p['ipv6']}\n"
config += "flush\n"
with open('/etc/3proxy/3proxy.cfg', 'w') as f: f.write(config)
print(f"OK")
PYEOF

echo "[9/10] Права..."
chown -R root:root /opt/proxy-farm
chmod +x /opt/proxy-farm/app.py

echo "[10/10] Запуск..."
systemctl daemon-reload
systemctl enable 3proxy proxy-farm
systemctl restart 3proxy proxy-farm
sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ГОТОВО! v8.0                                   ║"
echo "║          http://$IPV4_LOCAL:2525                     ║"
echo "║          Логин: admin / Пароль: $ADMIN_PASS            ║"
echo "╚══════════════════════════════════════════════════════════╝"
INSTALLEOF

chmod +x /root/proxy-farm3/install.sh
echo "Готово! Запусти: /root/proxy-farm3/install.sh"
