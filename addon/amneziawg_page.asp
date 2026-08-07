<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta HTTP-EQUIV="Pragma" CONTENT="no-cache">
<meta HTTP-EQUIV="Expires" CONTENT="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>AmneziaWG</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/validator.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<style>
.awg-status {
    padding: 8px 16px;
    border-radius: 4px;
    font-weight: bold;
    display: inline-block;
    font-size: 13px;
    letter-spacing: 0.5px;
    text-transform: uppercase;
}
.awg-status.running {
    background: #1a6e2e;
    color: #fff;
    border: 1px solid #2a8b42;
}
.awg-status.stopped {
    background: #8b0000;
    color: #fff;
    border: 1px solid #a00;
}
.awg-status.connecting {
    background: #b8860b;
    color: #fff;
    border: 1px solid #daa520;
}

.awg-section {
    margin: 14px 0 6px 0;
    font-size: 14px;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.awg-log {
    font-family: "Courier New", "Lucida Console", monospace;
    font-size: 11px;
    padding: 10px;
    height: 180px;
    overflow-y: auto;
    border: 1px solid #444;
    border-radius: 3px;
    white-space: pre-wrap;
    word-wrap: break-word;
}

.awg-btn { margin: 0 4px; }

#awg_peers_table { width: 100%; }
#awg_peers_table thead td {
    font-weight: bold;
    text-transform: uppercase;
    font-size: 11px;
    letter-spacing: 0.5px;
}
#awg_peers_table tbody td {
    padding: 6px 8px;
    font-size: 12px;
}

#awg_client_table { width: 100%; margin-top: 6px; }
#awg_client_table td { padding: 5px 8px; }
.awg-remove-btn {
    background: transparent; border: 1px solid #a00; color: #c00;
    padding: 3px 10px; border-radius: 3px; cursor: pointer; font-size: 14px;
}
.awg-remove-btn:hover { background: #a00; color: #fff; }
.awg-add-btn, .awg-import-btn {
    cursor: pointer;
    font-size: 12px;
}
.awg-ac-wrap { position:relative; display:inline-block; width:95%; }
.awg-ac-list { position:absolute; top:100%; left:0; right:0; max-height:200px; overflow-y:auto; border:1px solid #444; border-top:none; z-index:999; display:none; border-radius:0 0 4px 4px; background:#2f3a3e; }
.awg-ac-list div { padding:4px 8px; cursor:pointer; font-size:12px; }
.awg-ac-list div:hover, .awg-ac-list div.selected { background:#666; color:#fff; }
.awg-ac-list::-webkit-scrollbar { width:5px; }
.awg-ac-list::-webkit-scrollbar-thumb { background:#888; border-radius:3px; }

.awg-taglist { position:relative; width:95%; }
.awg-taglist-row { display:flex; gap:6px; }
.awg-taglist-row input[type=text] { flex:1; }
.awg-chips { margin-top:6px; min-height:20px; }
.awg-chips-empty { color:#666; font-size:11px; }
.awg-chip { display:inline-flex; align-items:center; gap:6px; background:#3a464b; border:1px solid #55666b; border-radius:12px; padding:3px 10px; margin:2px 4px 2px 0; font-size:12px; }
.awg-chip-remove { cursor:pointer; color:#e77; font-weight:bold; line-height:1; }
.awg-chip-remove:hover { color:#f00; }
.awg-taglist-error { color:#f66; font-size:11px; margin-top:4px; }
</style>
<script>
var custom_settings = <% get_custom_settings(); %>;
var statusTimer = null;
var geoSiteList = [];
var geoIpList = ['cloudflare','cloudfront','digitalocean','discord','google_meet','hetzner','meta','ovh','roblox','telegram','twitter'];
function escHtml(s){
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function loadGeoSiteCategories(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/domain_categories.htm?_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200 && xhr.responseText.length > 0){
            geoSiteList = xhr.responseText.trim().split('\n').filter(function(s){ return s; });
        }
    };
    xhr.send();
}

function initial(){
    show_menu();
    loadSettings();
    refreshStatus();
    statusTimer = setInterval(refreshStatus, 5000);
    loadGeoSiteCategories();
    initTagList('awg_geoip_services', {placeholder: 'Например: telegram', suggestions: function(){ return geoIpList; }});
    initTagList('awg_geosite_services', {placeholder: 'Например: youtube', suggestions: function(){ return geoSiteList; }});
    initTagList('geo_custom_domains', {placeholder: 'example.com'});
    initTagList('geo_custom_ips', {placeholder: '8.8.8.8 или 1.1.1.0/24'});
    checkForUpdate();
}

function checkForUpdate(){
    // Проверка GitHub напрямую из браузера (без бэкенда)
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'https://api.github.com/repos/stxlvn/asuswrt-merlin-amneziawg/releases/latest', true);
    xhr.timeout = 10000;
    xhr.onload = function(){
        if(xhr.status !== 200) return;
        try {
            var data = JSON.parse(xhr.responseText);
            var latest = (data.tag_name || '').replace(/^v/, '');
            showVersionInfo('', latest, false);
        } catch(e){}
    };
    xhr.send();
}

function showVersionInfo(currentIgnored, latest, hasUpdateIgnored){
    // Текущая версия из файла статуса
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
    xhr.timeout = 3000;
    xhr.onload = function(){
        try {
            var s = JSON.parse(xhr.responseText);
            var current = s.version || '';
            var vi = document.getElementById('awg_version_info');
            var ub = document.getElementById('awg_update_btn');
            if(!vi) return;
            if(current) vi.textContent = 'v' + current;
            if(latest && current && latest !== current){
                ub.style.display = 'inline';
                ub.innerHTML = '<input type="button" class="button_gen" value="Обновить до v' + escHtml(latest) + '" onclick="doUpdate();" style="font-size:11px; padding:2px 10px;">';
            }
        } catch(e){}
    };
    xhr.send();
}

function doUpdate(){
    if(!confirm('Обновить AmneziaWG?\nVPN будет остановлен. После обновления нажмите Запустить.')) return;
    var badge = document.getElementById('awg_badge');
    badge.className = 'awg-status connecting';
    badge.innerHTML = '&#9679; Обновление...';
    if(statusTimer){ clearInterval(statusTimer); statusTimer = null; }

    document.form.action_script.value = "start_awgdoupdate";
    document.form.submit();

    // Ждём завершения обновления (VPN остановлен, установлена новая версия), затем перезагружаем страницу
    var attempts = 0;
    setTimeout(function(){
        var poll = setInterval(function(){
            attempts++;
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
            xhr.timeout = 3000;
            xhr.onload = function(){
                try {
                    var s = JSON.parse(xhr.responseText);
                    // Обновление завершено, когда VPN остановлен (do_update его останавливает)
                    if(!s.running || attempts >= 120){
                        clearInterval(poll);
                        location.reload();
                    }
                } catch(e){
                    if(attempts >= 120){ clearInterval(poll); location.reload(); }
                }
            };
            xhr.onerror = function(){ if(attempts >= 120){ clearInterval(poll); location.reload(); } };
            xhr.send();
        }, 2000);
    }, 5000);
}

function loadSettings(){
    var fields = [
        'awg_privatekey', 'awg_address', 'awg_listenport', 'awg_dns',
        'awg_peer_pubkey', 'awg_peer_psk', 'awg_peer_endpoint',
        'awg_peer_allowedips', 'awg_peer_keepalive',
        'awg_jc', 'awg_jmin', 'awg_jmax',
        'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
        'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4',
        'awg_header_protection_key', 'awg_content_padding',
        'awg_rekey_after', 'awg_rekey_timeout', 'awg_reject_after',
        'awg_keepalive_timeout', 'awg_max_handshake_attempts'
    ];
    for(var i = 0; i < fields.length; i++){
        var el = document.getElementById(fields[i]);
        if(el && custom_settings[fields[i]] != undefined){
            el.value = custom_settings[fields[i]];
        }
    }
    // Загрузка I1-I5 из base64
    if(custom_settings.awg_initdata){
        try {
            var initLines = atob(custom_settings.awg_initdata).split('\n');
            for(var il = 0; il < initLines.length; il++){
                var ip = initLines[il].split('=');
                if(ip.length >= 2){
                    var ik = ip[0].trim().toLowerCase();
                    var ival = ip.slice(1).join('=').trim();
                    if(ik === 'i1') setVal('awg_i1', ival);
                    else if(ik === 'i2') setVal('awg_i2', ival);
                    else if(ik === 'i3') setVal('awg_i3', ival);
                    else if(ik === 'i4') setVal('awg_i4', ival);
                    else if(ik === 'i5') setVal('awg_i5', ival);
                }
            }
        } catch(e){}
    }
    // Загрузка политики по умолчанию
    var defPolicy = document.getElementById('default_policy');
    defPolicy.value = custom_settings.awg_default_policy || 'direct';
    // Загрузка списка устройств
    loadClients();
    // Загрузка гео-настроек
    loadGeoSettings();
    updateGeoVisibility();
}

function saveSettings(){
    var fields = [
        'awg_privatekey', 'awg_address', 'awg_listenport', 'awg_dns',
        'awg_peer_pubkey', 'awg_peer_psk', 'awg_peer_endpoint',
        'awg_peer_allowedips', 'awg_peer_keepalive',
        'awg_jc', 'awg_jmin', 'awg_jmax',
        'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
        'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4',
        'awg_header_protection_key', 'awg_content_padding',
        'awg_rekey_after', 'awg_rekey_timeout', 'awg_reject_after',
        'awg_keepalive_timeout', 'awg_max_handshake_attempts'
    ];
    for(var i = 0; i < fields.length; i++){
        var el = document.getElementById(fields[i]);
        if(el){
            var v = el.value;
            // Удаляем пробелы из значений через запятую (Merlin обрезает по пробелу)
            if(fields[i] === 'awg_peer_allowedips' || fields[i] === 'awg_address' || fields[i] === 'awg_dns'){
                v = v.replace(/\s+/g, '');
            }
            custom_settings[fields[i]] = v;
        }
    }
    // Сохранение политики по умолчанию и списка устройств
    custom_settings.awg_default_policy = document.getElementById('default_policy').value;
    custom_settings.awg_clients = serializeClients();

    // Сохранение I1-I5 в base64 (содержат небезопасные для HTML символы)
    var initData = '';
    for(var ix = 1; ix <= 5; ix++){
        var iv = document.getElementById('awg_i' + ix);
        if(iv && iv.value) initData += 'I' + ix + ' = ' + iv.value + '\n';
    }
    custom_settings.awg_initdata = initData ? btoa(initData) : '';

    // Сохранение гео-настроек
    custom_settings.awg_geosite_services = document.getElementById('awg_geosite_services').value;
    custom_settings.awg_geoip_services = document.getElementById('awg_geoip_services').value;
    custom_settings.awg_geo_custom_domains = document.getElementById('geo_custom_domains').value;
    custom_settings.awg_geo_custom_ips = document.getElementById('geo_custom_ips').value;
    custom_settings.awg_geo_autoupdate = document.getElementById('geo_autoupdate').checked ? '1' : '0';

    // Базовая валидация
    var pk = document.getElementById('awg_privatekey').value;
    var pubk = document.getElementById('awg_peer_pubkey').value;
    var ep = document.getElementById('awg_peer_endpoint').value;
    if(!pk || !pubk || !ep){
        alert('Обязательно: Приватный ключ, Публичный ключ пира и Адрес сервера.');
        return;
    }
    if(pk.length !== 44 || pubk.length !== 44){
        alert('Неверный формат ключа. Ключи должны быть длиной 44 символа (base64).');
        return;
    }
    var hpk = document.getElementById('awg_header_protection_key').value;
    if(hpk && hpk.length !== 44){
        alert('Неверный формат ключа защиты заголовков. Ключи должны быть длиной 44 символа (base64).');
        return;
    }
    if(ep.indexOf(':') === -1){
        alert('Адрес сервера должен включать порт (например server:51820).');
        return;
    }

    if(!confirm('Сохранить конфигурацию и перезапустить туннель?')) return;

    document.getElementById('amng_custom').value = JSON.stringify(custom_settings);
    document.form.action_script.value = "start_awgsaveconf";
    document.form.submit();
    setTimeout(function(){ location.reload(); }, 15000);
}

// === Маршрутизация: по устройствам с индивидуальными политиками ===

function loadClients(){
    var data = custom_settings.awg_clients || '';
    var tbody = document.getElementById('awg_client_rows');
    tbody.innerHTML = '';
    if(!data) return;
    var entries = data.split(';');
    for(var i = 0; i < entries.length; i++){
        if(!entries[i]) continue;
        var parts = entries[i].split(',');
        addClientRow(parts[0] || '', parts[1] || '', parts[2] || 'vpn_all');
    }
    updateGeoVisibility();
}

function addClientRow(ip, name, policy){
    var tbody = document.getElementById('awg_client_rows');
    var tr = document.createElement('tr');
    policy = policy || 'vpn_all';
    tr.innerHTML =
        '<td><input type="text" class="client_ip input_25_table" value="' + escHtml(ip) + '" placeholder="192.168.1.100"></td>' +
        '<td><input type="text" class="client_name input_25_table" value="' + escHtml(name) + '" placeholder="iPhone, PS5, TV..."></td>' +
        '<td><select class="client_policy input_option" onchange="updateGeoVisibility();" style="width:100%;">' +
            '<option value="vpn_all"' + (policy==='vpn_all'?' selected':'') + '>VPN (всё)</option>' +
            '<option value="vpn_geo"' + (policy==='vpn_geo'?' selected':'') + '>VPN (гео)</option>' +
            '<option value="direct"' + (policy==='direct'?' selected':'') + '>Напрямую</option>' +
        '</select></td>' +
        '<td style="text-align:center;"><button type="button" class="awg-remove-btn" onclick="this.closest(\'tr\').remove(); updateGeoVisibility();">&times;</button></td>';
    tbody.appendChild(tr);
    updateGeoVisibility();
}

function serializeClients(){
    var rows = document.querySelectorAll('#awg_client_rows tr');
    var parts = [];
    for(var i = 0; i < rows.length; i++){
        var ip = rows[i].querySelector('.client_ip').value.trim();
        var name = rows[i].querySelector('.client_name').value.trim();
        var policy = rows[i].querySelector('.client_policy').value;
        if(ip) parts.push(ip + ',' + name.replace(/[,;]/g, ' ') + ',' + policy);
    }
    return parts.join(';');
}

function updateGeoVisibility(){
    // Показываем гео-настройки, если хотя бы одно устройство или политика по умолчанию использует vpn_geo
    var defPolicy = document.getElementById('default_policy').value;
    var hasGeo = (defPolicy === 'vpn_geo');
    if(!hasGeo){
        var selects = document.querySelectorAll('.client_policy');
        for(var i = 0; i < selects.length; i++){
            if(selects[i].value === 'vpn_geo'){ hasGeo = true; break; }
        }
    }
    document.getElementById('geo_section').style.display = hasGeo ? '' : 'none';
}

// === GeoIP / GeoSite ===

function loadGeoSettings(){
    var geosite = document.getElementById('awg_geosite_services');
    if(geosite) geosite.value = custom_settings.awg_geosite_services || '';
    var geoip = document.getElementById('awg_geoip_services');
    if(geoip) geoip.value = custom_settings.awg_geoip_services || '';
    // Свои
    var cd = document.getElementById('geo_custom_domains');
    if(cd) cd.value = custom_settings.awg_geo_custom_domains || '';
    var ci = document.getElementById('geo_custom_ips');
    if(ci) ci.value = custom_settings.awg_geo_custom_ips || '';
    // Автообновление
    var au = document.getElementById('geo_autoupdate');
    if(au) au.checked = (custom_settings.awg_geo_autoupdate === '1');
}

function getCheckedValues(prefix){
    var checks = document.querySelectorAll('input[data-group="' + prefix + '"]:checked');
    var vals = [];
    for(var i = 0; i < checks.length; i++) vals.push(checks[i].value);
    return vals.join(',');
}

function setCheckedValues(prefix, csv){
    var vals = csv.split(',');
    var checks = document.querySelectorAll('input[data-group="' + prefix + '"]');
    for(var i = 0; i < checks.length; i++){
        checks[i].checked = (vals.indexOf(checks[i].value) !== -1);
    }
}

function updateGeoLists(){
    var btn = document.getElementById('btn_geo_update');
    var isDownload = btn && btn.value === 'Скачать списки';
    var msg = isDownload
        ? 'Скачать все списки GeoIP и доменов?\nЭто может занять 1-2 минуты.'
        : 'Принудительно перекачать все списки GeoIP и доменов?\nЭто может занять 1-2 минуты.';
    if(!confirm(msg)) return;
    var log = document.getElementById('awg_log');
    if(log) log.textContent = 'Загрузка гео-списков... Подождите.';
    document.form.action_script.value = "start_awgupdategeo";
    document.form.submit();
    if(btn) btn.disabled = true;

    // Poll for actual completion instead of a fixed timer: with retries for
    // flaky CDN edges, a full download pass can now take well past a
    // minute, and reloading the page mid-download looked like AmneziaWG
    // had "reset" even though the backend was still running fine.
    var attempts = 0;
    var poll = setInterval(function(){
        attempts++;
        var xhr = new XMLHttpRequest();
        xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
        xhr.timeout = 3000;
        xhr.onload = function(){
            try {
                var s = JSON.parse(xhr.responseText);
                if(s.log && log) log.textContent = s.log;
                var done = /Geo databases updated/.test(s.log || '');
                if(done || attempts >= 90){
                    clearInterval(poll);
                    if(btn) btn.disabled = false;
                    location.reload();
                }
            } catch(e){
                if(attempts >= 90){ clearInterval(poll); if(btn) btn.disabled = false; location.reload(); }
            }
        };
        xhr.onerror = function(){ if(attempts >= 90){ clearInterval(poll); if(btn) btn.disabled = false; location.reload(); } };
        xhr.send();
    }, 2000);
}

function fetchDhcpClients(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/appGet.cgi?hook=get_clientlist()&_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200){
            try {
                var data = JSON.parse(xhr.responseText);
                var cl = data.get_clientlist || data;
                var lines = [];
                for(var key in cl){
                    if(!cl.hasOwnProperty(key)) continue;
                    var c = cl[key];
                    if(c && typeof c === 'object' && c.ip){
                        lines.push({ip: c.ip, name: c.name || c.nickName || key});
                    }
                }
                if(lines.length > 0){
                    showClientPicker(lines);
                } else {
                    fetchDhcpLeases();
                }
            } catch(e){
                fetchDhcpLeases();
            }
        } else {
            fetchDhcpLeases();
        }
    };
    xhr.onerror = function(){ fetchDhcpLeases(); };
    xhr.send();
}

function fetchDhcpLeases(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/update_clients.asp?_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200){
            var lines = [];
            var text = xhr.responseText;
            // формат dnsmasq.leases: expiry mac ip hostname clientid
            var rows = text.match(/\d+\.\d+\.\d+\.\d+/g);
            if(rows){
                // Разбираем построчно IP + имя хоста
                var rawLines = text.split('\n');
                for(var i = 0; i < rawLines.length; i++){
                    var parts = rawLines[i].trim().split(/\s+/);
                    if(parts.length >= 4 && parts[2].match(/^\d+\.\d+\.\d+\.\d+$/)){
                        lines.push({ip: parts[2], name: parts[3] === '*' ? parts[1] : parts[3]});
                    }
                }
            }
            if(lines.length > 0){
                showClientPicker(lines);
            } else {
                var input = prompt('Введите IP устройств для добавления (через запятую):');
                if(input) addManualIPs(input);
            }
        }
    };
    xhr.onerror = function(){
        var input = prompt('Введите IP устройств для добавления (через запятую):');
        if(input) addManualIPs(input);
    };
    xhr.send();
}

function showClientPicker(clients){
    var msg = 'Устройства DHCP:\n\n';
    for(var i = 0; i < clients.length; i++){
        msg += (i+1) + ') ' + clients[i].ip + ' — ' + clients[i].name + '\n';
    }
    msg += '\nВведите номера (например 1,3,5) или IP напрямую:';
    var input = prompt(msg);
    if(!input) return;

    var items = input.split(',');
    for(var i = 0; i < items.length; i++){
        var v = items[i].trim();
        var num = parseInt(v);
        if(!isNaN(num) && num >= 1 && num <= clients.length){
            var c = clients[num - 1];
            addClientRow(c.ip, c.name, 'vpn_all');
        } else if(v.match(/^\d+\.\d+\.\d+\.\d+$/)){
            addClientRow(v, '', 'vpn_all');
        }
    }
}

function addManualIPs(input){
    var ips = input.split(',');
    for(var i = 0; i < ips.length; i++){
        var ip = ips[i].trim();
        if(ip) addClientRow(ip, '', 'vpn_all');
    }
}

function awgAction(action){
    if(action === 'start_awgstart' && !confirm('Запустить туннель AmneziaWG?')) return;

    document.form.action_script.value = action;
    document.form.submit();
    var badge = document.getElementById('awg_badge');
    var isStop = action.indexOf('stop') !== -1;
    var expect = !isStop;

    // Останавливаем периодическое обновление статуса на время выполнения действия
    if(statusTimer){ clearInterval(statusTimer); statusTimer = null; }
    document.getElementById('btn_start').disabled = true;
    document.getElementById('btn_stop').disabled = true;
    document.getElementById('btn_restart').disabled = true;

    // Промежуточный статус
    badge.className = 'awg-status connecting';
    badge.innerHTML = isStop ? '&#9679; Остановка...' : '&#9679; Подключение...';

    // Опрашиваем, пока статус не станет окончательным
    var attempts = 0;
    var poll = setInterval(function(){
        attempts++;
        var xhr = new XMLHttpRequest();
        xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
        xhr.timeout = 3000;
        xhr.onload = function(){
            try {
                var s = JSON.parse(xhr.responseText);
                // Для запуска: ждём running === true и наличия публичного ключа (полная готовность)
                // Для остановки: ждём running === false
                var ready = (s.running === expect);
                if(ready || attempts >= 90){
                    clearInterval(poll);
                    updateStatusUI(s);
                    statusTimer = setInterval(refreshStatus, 5000);
                    document.getElementById('btn_start').disabled = false;
                    document.getElementById('btn_stop').disabled = false;
                    document.getElementById('btn_restart').disabled = false;
                }
            } catch(e){
                if(attempts >= 90){ clearInterval(poll); refreshStatus(); document.getElementById('btn_start').disabled = false; document.getElementById('btn_stop').disabled = false; document.getElementById('btn_restart').disabled = false; }
            }
        };
        xhr.onerror = function(){ if(attempts >= 90){ clearInterval(poll); refreshStatus(); document.getElementById('btn_start').disabled = false; document.getElementById('btn_stop').disabled = false; document.getElementById('btn_restart').disabled = false; } };
        xhr.send();
    }, 2000);
}

function showLoading(){}
function hideLoading(){}

function refreshStatus(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
    xhr.timeout = 3000;
    xhr.onload = function(){
        if(xhr.status === 200){
            try {
                var status = JSON.parse(xhr.responseText);
                updateStatusUI(status);
            } catch(e) {
                setOfflineUI();
            }
        } else {
            setOfflineUI();
        }
    };
    xhr.onerror = function(){ setOfflineUI(); };
    xhr.ontimeout = function(){ setOfflineUI(); };
    xhr.send();
}

function updateStatusUI(s){
    var badge = document.getElementById('awg_badge');
    var info = document.getElementById('awg_info');
    var peers = document.getElementById('awg_peers');
    var logbox = document.getElementById('awg_log');

    if(s.running){
        badge.className = 'awg-status running';
        badge.innerHTML = '&#9679; Подключено';
        document.getElementById('btn_start').style.display = 'none';
        document.getElementById('btn_stop').style.display = '';
        document.getElementById('btn_restart').style.display = '';
    } else {
        badge.className = 'awg-status stopped';
        badge.innerHTML = '&#9679; Остановлен';
        document.getElementById('btn_start').style.display = '';
        document.getElementById('btn_stop').style.display = 'none';
        document.getElementById('btn_restart').style.display = 'none';
    }

    info.innerHTML = '';
    if(s.interface_addr) info.innerHTML += 'Адрес: ' + escHtml(s.interface_addr) + '<br>';
    if(s.public_key) info.innerHTML += 'Публичный ключ: ' + escHtml(s.public_key.substring(0,12)) + '...<br>';
    if(s.listen_port) info.innerHTML += 'Порт прослушивания: ' + escHtml(s.listen_port) + '<br>';

    var html = '';
    if(s.peers && s.peers.length > 0){
        for(var i = 0; i < s.peers.length; i++){
            var p = s.peers[i];
            html += '<tr>';
            html += '<td>' + escHtml(p.endpoint || '-') + '</td>';
            html += '<td>' + escHtml(p.allowed_ips || '-') + '</td>';
            html += '<td>' + escHtml(p.transfer_rx || '0 B') + ' / ' + escHtml(p.transfer_tx || '0 B') + '</td>';
            html += '<td>' + escHtml(p.latest_handshake || 'никогда') + '</td>';
            html += '</tr>';
        }
    }
    peers.innerHTML = html;

    if(s.log) logbox.textContent = s.log;

    // Информация о маршрутах
    var rulesEl = document.getElementById('awg_active_rules');
    if(s.running){
        var infoParts = [];
        if(s.active_rules > 0) infoParts.push(s.active_rules + ' правил(о) маршрутизации');
        if(s.ipset_count > 0) infoParts.push(s.ipset_count + ' IP-диапазонов');
        if(s.geo_domains > 0) infoParts.push(s.geo_domains + ' правил доменов');
        rulesEl.innerHTML = infoParts.join(' &middot; ') || 'нет активных правил';
        rulesEl.style.color = '#93E7FF';
    } else {
        rulesEl.innerHTML = '';
    }

    // Обновление текста кнопки гео-списков в зависимости от наличия базы
    var geoBtn = document.getElementById('btn_geo_update');
    if(geoBtn){
        if(s.geo_downloaded){
            geoBtn.value = 'Обновить сейчас';
        } else {
            geoBtn.value = 'Скачать списки';
            geoBtn.style.fontWeight = 'bold';
        }
    }
}

function setOfflineUI(){
    var badge = document.getElementById('awg_badge');
    badge.className = 'awg-status stopped';
    badge.innerHTML = '&#9679; Остановлен';
    document.getElementById('btn_start').style.display = '';
    document.getElementById('btn_stop').style.display = 'none';
    document.getElementById('btn_restart').style.display = 'none';
}

function copyLog(){
    var logEl = document.getElementById('awg_log');
    var text = logEl ? logEl.textContent : '';
    var btn = document.getElementById('btn_copy_log');
    function report(ok){
        if(!btn) return;
        var old = btn.value;
        btn.value = ok ? 'Скопировано!' : 'Не удалось скопировать';
        setTimeout(function(){ btn.value = old; }, 2000);
    }
    function fallbackCopy(){
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.top = '0';
        ta.style.left = '0';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        var ok = false;
        try { ok = document.execCommand('copy'); } catch(e){ ok = false; }
        document.body.removeChild(ta);
        report(ok);
    }
    // Merlin's web UI usually runs on plain http:// on the LAN, where the
    // Clipboard API is unavailable (secure-context only) -- try it as a
    // progressive enhancement, but the execCommand fallback is what
    // actually works in the common case.
    if(navigator.clipboard && navigator.clipboard.writeText){
        navigator.clipboard.writeText(text).then(function(){ report(true); }, fallbackCopy);
    } else {
        fallbackCopy();
    }
}

var _initParams = {};

function importConfig(){
    var fileInput = document.getElementById('awg_config_file');
    if(!fileInput){
        fileInput = document.createElement('input');
        fileInput.type = 'file';
        fileInput.id = 'awg_config_file';
        fileInput.accept = '.conf,.txt';
        fileInput.style.display = 'none';
        document.body.appendChild(fileInput);
    }
    fileInput.value = '';
    fileInput.onchange = function(){
        if(!fileInput.files || !fileInput.files[0]) return;
        var reader = new FileReader();
        reader.onload = function(e){ parseConfig(e.target.result); };
        reader.readAsText(fileInput.files[0]);
    };
    fileInput.click();
}

function parseConfig(text){
    if(!text) return;

    // Clear every field this function can set before parsing, otherwise a
    // fresh import that omits a key (e.g. a plain AmneziaWG 2.0 config with
    // no HeaderProtectionKey/3.0 timing fields) silently inherits stale
    // values left over from a previous import instead of leaving them
    // unset -- the client then sends a mismatched mix of old 3.0 fields and
    // new 2.0 fields to the server, breaking the handshake.
    var allFields = ['awg_privatekey', 'awg_address', 'awg_listenport', 'awg_dns',
        'awg_jc', 'awg_jmin', 'awg_jmax', 'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
        'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4', 'awg_i1', 'awg_i2', 'awg_i3', 'awg_i4', 'awg_i5',
        'awg_header_protection_key', 'awg_content_padding', 'awg_rekey_after',
        'awg_rekey_timeout', 'awg_reject_after', 'awg_keepalive_timeout', 'awg_max_handshake_attempts',
        'awg_peer_pubkey', 'awg_peer_psk', 'awg_peer_endpoint', 'awg_peer_allowedips', 'awg_peer_keepalive'];
    for(var f = 0; f < allFields.length; f++) setVal(allFields[f], '');

    var lines = text.split('\n');
    var section = '';
    for(var i = 0; i < lines.length; i++){
        var line = lines[i].trim();
        if(line === '[Interface]'){ section = 'iface'; continue; }
        if(line === '[Peer]'){ section = 'peer'; continue; }
        if(!line || line.charAt(0) === '#') continue;

        var parts = line.split('=');
        if(parts.length < 2) continue;
        // Ported from advocdiaboly/asuswrt-merlin-amneziawg@fbf595e (Dmitry Fomin):
        // lowercase the key so exports with different casing still parse.
        var key = parts[0].trim().toLowerCase();
        var val = parts.slice(1).join('=').trim();

        if(section === 'iface'){
            switch(key){
                case 'privatekey': setVal('awg_privatekey', val); break;
                case 'address':    setVal('awg_address', val); break;
                case 'listenport': setVal('awg_listenport', val); break;
                case 'dns':        setVal('awg_dns', val); break;
                case 'jc':         setVal('awg_jc', val); break;
                case 'jmin':       setVal('awg_jmin', val); break;
                case 'jmax':       setVal('awg_jmax', val); break;
                case 's1':         setVal('awg_s1', val); break;
                case 's2':         setVal('awg_s2', val); break;
                case 's3':         setVal('awg_s3', val); break;
                case 's4':         setVal('awg_s4', val); break;
                case 'h1':         setVal('awg_h1', val); break;
                case 'h2':         setVal('awg_h2', val); break;
                case 'h3':         setVal('awg_h3', val); break;
                case 'h4':         setVal('awg_h4', val); break;
                case 'i1': setVal('awg_i1', val); break;
                case 'i2': setVal('awg_i2', val); break;
                case 'i3': setVal('awg_i3', val); break;
                case 'i4': setVal('awg_i4', val); break;
                case 'i5': setVal('awg_i5', val); break;
                case 'headerprotectionkey':    setVal('awg_header_protection_key', val); break;
                case 'contentpaddingaddition': setVal('awg_content_padding', val); break;
                case 'rekeyaftertime':         setVal('awg_rekey_after', val); break;
                case 'rekeytimeout':           setVal('awg_rekey_timeout', val); break;
                case 'rejectaftertime':        setVal('awg_reject_after', val); break;
                case 'keepalivetimeout':       setVal('awg_keepalive_timeout', val); break;
                case 'maxhandshakeattempts':   setVal('awg_max_handshake_attempts', val); break;
            }
        } else if(section === 'peer'){
            switch(key){
                case 'publickey':          setVal('awg_peer_pubkey', val); break;
                case 'presharedkey':       setVal('awg_peer_psk', val); break;
                case 'endpoint':           setVal('awg_peer_endpoint', val); break;
                case 'allowedips':         setVal('awg_peer_allowedips', val); break;
                case 'persistentkeepalive': setVal('awg_peer_keepalive', val); break;
            }
        }
    }
    alert('Конфиг импортирован. Проверьте поля и нажмите Применить.');
}

function setVal(id, val){
    var el = document.getElementById(id);
    if(el) el.value = val;
}

// === Списки с добавлением/удалением пунктов (GeoIP, GeoSite, свои домены/IP) ===

function initTagList(fieldId, opts){
    opts = opts || {};
    var hidden = document.getElementById(fieldId);
    if(!hidden) return;

    var wrap = document.createElement('div');
    wrap.className = 'awg-taglist';
    hidden.parentNode.insertBefore(wrap, hidden);
    hidden.style.display = 'none';
    wrap.appendChild(hidden);

    var row = document.createElement('div');
    row.className = 'awg-taglist-row';
    wrap.appendChild(row);

    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'input_25_table';
    input.placeholder = opts.placeholder || 'Введите значение...';
    row.appendChild(input);

    var addBtn = document.createElement('input');
    addBtn.type = 'button';
    addBtn.className = 'button_gen';
    addBtn.value = '+ Добавить';
    row.appendChild(addBtn);

    var sugBox = document.createElement('div');
    sugBox.className = 'awg-ac-list';
    wrap.appendChild(sugBox);

    var chipsBox = document.createElement('div');
    chipsBox.className = 'awg-chips';
    wrap.appendChild(chipsBox);

    var errBox = document.createElement('div');
    errBox.className = 'awg-taglist-error';
    errBox.style.display = 'none';
    wrap.appendChild(errBox);
    var errTimer = null;
    function showError(msg){
        errBox.textContent = msg;
        errBox.style.display = 'block';
        clearTimeout(errTimer);
        errTimer = setTimeout(function(){ errBox.style.display = 'none'; }, 4000);
    }

    function getItems(){
        return hidden.value ? hidden.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s; }) : [];
    }
    function setItems(items){
        hidden.value = items.join(',');
        renderChips();
    }
    function renderChips(){
        var items = getItems();
        chipsBox.innerHTML = '';
        if(items.length === 0){
            var empty = document.createElement('span');
            empty.className = 'awg-chips-empty';
            empty.textContent = 'Список пуст';
            chipsBox.appendChild(empty);
            return;
        }
        items.forEach(function(item){
            var chip = document.createElement('span');
            chip.className = 'awg-chip';
            chip.appendChild(document.createTextNode(item));
            var x = document.createElement('span');
            x.className = 'awg-chip-remove';
            x.innerHTML = '&times;';
            x.title = 'Удалить';
            x.onclick = function(){ setItems(getItems().filter(function(v){ return v !== item; })); };
            chip.appendChild(x);
            chipsBox.appendChild(chip);
        });
    }
    function hideSug(){ sugBox.style.display = 'none'; }
    function showSug(){
        if(!opts.suggestions) return;
        var q = input.value.trim().toLowerCase();
        var existing = getItems();
        var list = typeof opts.suggestions === 'function' ? opts.suggestions() : opts.suggestions;
        var matches = (list || []).filter(function(s){
            return existing.indexOf(s) === -1 && (q.length === 0 || s.indexOf(q) !== -1);
        }).slice(0, 20);
        sugBox.innerHTML = '';
        if(matches.length === 0){ hideSug(); return; }
        matches.forEach(function(m){
            var d = document.createElement('div');
            d.textContent = m;
            d.onmousedown = function(e){ e.preventDefault(); input.value = m; addFromInput(); };
            sugBox.appendChild(d);
        });
        sugBox.style.display = 'block';
    }
    function addFromInput(){
        var v = input.value.trim().toLowerCase().replace(/\s+/g, '');
        if(!v) return;
        // Reject unknown names against the known catalog instead of silently
        // saving a typo (e.g. "cloldflare") that only surfaces later as a
        // buried "not cached" warning in the log.
        if(opts.suggestions){
            var list = typeof opts.suggestions === 'function' ? opts.suggestions() : opts.suggestions;
            if(list && list.length > 0 && list.indexOf(v) === -1){
                showError('Неизвестное имя "' + v + '". Выберите вариант из списка ниже.');
                return;
            }
        }
        var items = getItems();
        if(items.indexOf(v) === -1){ items.push(v); setItems(items); }
        input.value = '';
        hideSug();
        input.focus();
    }
    addBtn.onclick = addFromInput;
    input.addEventListener('keydown', function(e){
        if(e.key === 'Enter'){ e.preventDefault(); addFromInput(); }
    });
    if(opts.suggestions){
        input.addEventListener('focus', showSug);
        input.addEventListener('input', showSug);
        input.addEventListener('blur', function(){ setTimeout(hideSug, 200); });
    }

    renderChips();
}
</script>
</head>
<body onload="initial();" onunload="clearInterval(statusTimer);">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="about:blank" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="productid" value="<% nvram_get("productid"); %>">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="action_wait" value="15">
<input type="hidden" name="amng_custom" id="amng_custom" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
    <td width="17">&nbsp;</td>
    <td valign="top" width="202">
        <div id="mainMenu"></div>
        <div id="subMenu"></div>
    </td>
    <td valign="top">
        <div id="tabMenu" class="submenuBlock"></div>
        <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
        <tr>
            <td valign="top">

            <!-- ==================== STATUS ==================== -->
            <table width="760px" border="0" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
            <tr><td bgcolor="#4D595D" valign="top">
                <div>&nbsp;</div>
                <div class="formfonttitle" style="display:flex; align-items:center; gap:10px;">
                    <span style="font-size:20px; font-weight:bold; letter-spacing:1px;">AmneziaWG</span>
                    <span style="font-size:13px; font-weight:normal;">VPN-клиент</span>
                    <span id="awg_version_info" style="margin-left:auto; font-size:11px; opacity:0.6;"></span>
                    <span id="awg_update_btn" style="display:none;"></span>
                </div>
                <div style="margin:10px 0 10px 5px;" class="splitLine"></div>

                <!-- Status & Actions -->
                <table width="100%" border="0" cellpadding="4" cellspacing="0">
                <tr>
                    <th width="20%">Статус</th>
                    <td>
                        <span id="awg_badge" class="awg-status stopped">Остановлен</span>
                        &nbsp;&nbsp;
                        <input type="button" id="btn_start" class="button_gen awg-btn" value="Запустить" onclick="awgAction('start_awgstart');">
                        <input type="button" id="btn_stop" class="button_gen awg-btn" value="Остановить" style="display:none;" onclick="awgAction('start_awgstop');">
                        <input type="button" id="btn_restart" class="button_gen awg-btn" value="Перезапустить" style="display:none;" onclick="awgAction('start_awgrestart');">
                    </td>
                </tr>
                <tr>
                    <th width="20%">Интерфейс</th>
                    <td><span id="awg_info">-</span></td>
                </tr>
                </table>

                <!-- Peers Table -->
                <div class="awg-section">Подключенные пиры</div>
                <table width="100%" border="0" cellpadding="4" cellspacing="0" class="FormTable_table" id="awg_peers_table">
                <thead><tr>
                    <td width="25%">Адрес сервера</td>
                    <td width="25%">Разрешённые IP</td>
                    <td width="25%">Трафик (RX/TX)</td>
                    <td width="25%">Последнее рукопожатие</td>
                </tr></thead>
                <tbody id="awg_peers">
                    <tr><td colspan="4" style="text-align:center; color:#666;">Нет пиров</td></tr>
                </tbody>
                </table>

                <div style="margin:15px 0 10px 0;" class="splitLine"></div>

                <!-- ==================== CONFIG ==================== -->
                <div class="awg-section">Конфигурация</div>
                <div style="margin-bottom:8px;">
                    <input type="button" class="button_gen" value="Импорт конфига" onclick="importConfig();">
                    <span style="color:#AAA; margin-left:10px; font-size:12px;">Загрузите .conf файл из клиента Amnezia VPN</span>
                </div>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable">
                <thead><tr><td colspan="2">Интерфейс</td></tr></thead>
                <tr>
                    <th width="35%">Приватный ключ</th>
                    <td><input type="password" class="input_32_table" id="awg_privatekey" maxlength="64" autocomplete="off"></td>
                </tr>
                <tr>
                    <th>Адрес</th>
                    <td><input type="text" class="input_20_table" id="awg_address" maxlength="32" placeholder="10.7.0.2/24"></td>
                </tr>
                <tr>
                    <th>Порт прослушивания</th>
                    <td><input type="text" class="input_6_table" id="awg_listenport" maxlength="5" placeholder="51820"></td>
                </tr>
                <tr>
                    <th>DNS</th>
                    <td><input type="text" class="input_20_table" id="awg_dns" maxlength="64" placeholder="1.1.1.1"></td>
                </tr>
                </table>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">Пир</td></tr></thead>
                <tr>
                    <th width="35%">Публичный ключ</th>
                    <td><input type="text" class="input_32_table" id="awg_peer_pubkey" maxlength="64"></td>
                </tr>
                <tr>
                    <th>Общий ключ (PSK)</th>
                    <td><input type="password" class="input_32_table" id="awg_peer_psk" maxlength="64" autocomplete="off" placeholder="(опционально)"></td>
                </tr>
                <tr>
                    <th>Адрес сервера</th>
                    <td><input type="text" class="input_25_table" id="awg_peer_endpoint" maxlength="64" placeholder="server.example.com:51820"></td>
                </tr>
                <tr>
                    <th>Разрешённые IP</th>
                    <td><input type="text" class="input_25_table" id="awg_peer_allowedips" maxlength="128" placeholder="0.0.0.0/0"></td>
                </tr>
                <tr>
                    <th>Persistent Keepalive</th>
                    <td><input type="text" class="input_6_table" id="awg_peer_keepalive" maxlength="4" placeholder="25"> сек</td>
                </tr>
                </table>

                <!-- ==================== OBFUSCATION ==================== -->
                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">Обфускация AmneziaWG</td></tr></thead>
                <tr>
                    <th width="35%">Jc (кол-во мусорных пакетов)</th>
                    <td><input type="text" class="input_6_table" id="awg_jc" maxlength="3" placeholder="4"> (0-128)</td>
                </tr>
                <tr>
                    <th>Jmin (мин. размер мусора)</th>
                    <td><input type="text" class="input_6_table" id="awg_jmin" maxlength="5" placeholder="40"> байт</td>
                </tr>
                <tr>
                    <th>Jmax (макс. размер мусора)</th>
                    <td><input type="text" class="input_6_table" id="awg_jmax" maxlength="5" placeholder="70"> байт</td>
                </tr>
                <tr>
                    <th>S1 (паддинг инициализации)</th>
                    <td><input type="text" class="input_6_table" id="awg_s1" maxlength="3" placeholder="20"> байт</td>
                </tr>
                <tr>
                    <th>S2 (паддинг ответа)</th>
                    <td><input type="text" class="input_6_table" id="awg_s2" maxlength="3" placeholder="30"> байт</td>
                </tr>
                <tr>
                    <th>S3</th>
                    <td><input type="text" class="input_6_table" id="awg_s3" maxlength="3" placeholder="0"> байт</td>
                </tr>
                <tr>
                    <th>S4</th>
                    <td><input type="text" class="input_6_table" id="awg_s4" maxlength="3" placeholder="0"> байт</td>
                </tr>
                <tr>
                    <th>H1 (заголовок инициализации)</th>
                    <td><input type="text" class="input_25_table" id="awg_h1" maxlength="32" placeholder="1234567891"></td>
                </tr>
                <tr>
                    <th>H2 (заголовок ответа)</th>
                    <td><input type="text" class="input_25_table" id="awg_h2" maxlength="32" placeholder="1987654321"></td>
                </tr>
                <tr>
                    <th>H3 (заголовок cookie)</th>
                    <td><input type="text" class="input_25_table" id="awg_h3" maxlength="32" placeholder="1112223334"></td>
                </tr>
                <tr>
                    <th>H4 (заголовок данных)</th>
                    <td><input type="text" class="input_25_table" id="awg_h4" maxlength="32" placeholder="4445556667"></td>
                </tr>
                <tr>
                    <th>I1 (мусор инициализации)</th>
                    <td><input type="text" class="input_32_table" id="awg_i1" style="width:95%; font-size:11px;" maxlength="2048" placeholder="Заполняется автоматически при импорте конфига"></td>
                </tr>
                <tr>
                    <th>I2</th>
                    <td><input type="text" class="input_32_table" id="awg_i2" style="width:95%; font-size:11px;" maxlength="2048" placeholder="(опционально)"></td>
                </tr>
                <tr>
                    <th>I3</th>
                    <td><input type="text" class="input_32_table" id="awg_i3" style="width:95%; font-size:11px;" maxlength="2048" placeholder="(опционально)"></td>
                </tr>
                <tr>
                    <th>I4</th>
                    <td><input type="text" class="input_32_table" id="awg_i4" style="width:95%; font-size:11px;" maxlength="2048" placeholder="(опционально)"></td>
                </tr>
                <tr>
                    <th>I5</th>
                    <td><input type="text" class="input_32_table" id="awg_i5" style="width:95%; font-size:11px;" maxlength="2048" placeholder="(опционально)"></td>
                </tr>
                </table>

                <!-- ==================== AMNEZIAWG 3.0 ==================== -->
                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">AmneziaWG 3.0 (защита заголовков) <span style="font-weight:normal; font-size:11px; color:#888;">опционально, оставьте пустым для серверов только с 2.0</span></td></tr></thead>
                <tr>
                    <th width="35%">Ключ защиты заголовков</th>
                    <td><input type="password" class="input_32_table" id="awg_header_protection_key" maxlength="64" autocomplete="off" placeholder="Заполняется автоматически при импорте конфига"></td>
                </tr>
                <tr>
                    <th>Доп. паддинг содержимого</th>
                    <td><input type="text" class="input_25_table" id="awg_content_padding" maxlength="16" placeholder="44-61"> байт</td>
                </tr>
                <tr>
                    <th>Пересоздание ключа через</th>
                    <td><input type="text" class="input_25_table" id="awg_rekey_after" maxlength="16" placeholder="104-121"> сек</td>
                </tr>
                <tr>
                    <th>Таймаут пересоздания ключа</th>
                    <td><input type="text" class="input_25_table" id="awg_rekey_timeout" maxlength="16" placeholder="5-8"> сек</td>
                </tr>
                <tr>
                    <th>Отклонение соединения через</th>
                    <td><input type="text" class="input_25_table" id="awg_reject_after" maxlength="16" placeholder="151-185"> сек</td>
                </tr>
                <tr>
                    <th>Таймаут keepalive</th>
                    <td><input type="text" class="input_25_table" id="awg_keepalive_timeout" maxlength="16" placeholder="9-16"> сек</td>
                </tr>
                <tr>
                    <th>Макс. попыток рукопожатия</th>
                    <td><input type="text" class="input_25_table" id="awg_max_handshake_attempts" maxlength="16" placeholder="16-21"></td>
                </tr>
                </table>

                <!-- ==================== ROUTING ==================== -->
                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">Политика маршрутизации</td></tr></thead>
                <tr>
                    <th width="35%">Политика по умолчанию</th>
                    <td>
                        <select id="default_policy" class="input_option" onchange="updateGeoVisibility();"
                                style="font-size:13px; font-weight:bold;">
                            <option value="direct">Напрямую (без VPN)</option>
                            <option value="vpn_all">VPN — весь трафик</option>
                            <option value="vpn_geo">VPN — только гео</option>
                        </select>
                        <span style="color:#666; font-size:11px; margin-left:8px;">Для устройств, не указанных ниже</span>
                        <span id="awg_active_rules" style="margin-left:12px; color:#666; font-size:11px;"></span>
                    </td>
                </tr>
                </table>

                <div class="awg-section">Правила устройств</div>
                <table width="100%" border="0" cellpadding="4" cellspacing="0" class="FormTable_table" id="awg_client_table">
                <thead><tr>
                    <td width="25%">IP-адрес</td>
                    <td width="25%">Название устройства</td>
                    <td width="30%">Политика</td>
                    <td width="20%">Действие</td>
                </tr></thead>
                <tbody id="awg_client_rows">
                </tbody>
                </table>
                <div style="margin-top:6px;">
                    <input type="button" class="button_gen" value="+ Добавить устройство" onclick="addClientRow('','','vpn_all');">
                    <input type="button" class="button_gen" value="+ Из списка DHCP" onclick="fetchDhcpClients();" style="margin-left:6px;">
                </div>

                <!-- ==================== GEO ROUTING ==================== -->
                <div id="geo_section" style="display:none;">

                <div style="border:1px solid #fc0; border-radius:4px; padding:10px 14px; margin-top:10px; font-size:12px; color:#fc0;">
                    <b>Важно:</b> Для работы VPN Geo устройства должны использовать роутер как DNS-сервер.<br>
                    iPhone: Настройки &gt; Wi-Fi &gt; (i) &gt; DNS &gt; Вручную &gt; только <% nvram_get("lan_ipaddr"); %><br>
                    macOS/Windows: укажите <% nvram_get("lan_ipaddr"); %> как DNS в настройках сети. Отключите DNS-over-HTTPS в браузере.
                </div>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">GeoIP — маршрутизация по IP сервиса</td></tr></thead>
                <tr>
                    <th width="35%">Списки сервисов GeoIP<br><span style="font-weight:normal; font-size:11px; color:#888;">github.com/itdoginfo/allow-domains</span></th>
                    <td>
                        <input type="text" class="input_32_table" id="awg_geoip_services" style="width:95%;" maxlength="512">
                        <div style="color:#666; font-size:11px; margin-top:3px;">Работает без DNS — прямое сопоставление по IP. Идеально для Telegram и других мессенджеров.</div>
                    </td>
                </tr>
                </table>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">GeoSite — маршрутизация по сервису / домену</td></tr></thead>
                <tr>
                    <th width="35%">Списки сервисов GeoSite<br><span style="font-weight:normal; font-size:11px; color:#888;">github.com/itdoginfo/allow-domains</span></th>
                    <td>
                        <input type="text" class="input_32_table" id="awg_geosite_services" style="width:95%;" maxlength="512">
                    </td>
                </tr>
                <tr>
                    <th>Свои домены</th>
                    <td>
                        <input type="text" class="input_32_table" id="geo_custom_domains" style="width:95%;" maxlength="2000">
                        <div style="color:#666; font-size:11px; margin-top:3px;">Резолвится через DNS → маршрутизируется через VPN</div>
                    </td>
                </tr>
                <tr>
                    <th>Свои IP / подсети</th>
                    <td>
                        <input type="text" class="input_32_table" id="geo_custom_ips" style="width:95%;" maxlength="2000">
                    </td>
                </tr>
                <tr>
                    <th>Автообновление списков</th>
                    <td>
                        <label><input type="checkbox" id="geo_autoupdate"> Ежедневно в 4:00</label>
                        &nbsp;&nbsp;
                        <input type="button" class="button_gen" id="btn_geo_update" value="Обновить сейчас" onclick="updateGeoLists();">
                    </td>
                </tr>
                </table>

                </div>

                <!-- Apply -->
                <div style="margin-top:12px; text-align:center;">
                    <input type="button" class="button_gen" value="Применить" onclick="saveSettings();">
                </div>

                <!-- ==================== LOG ==================== -->
                <div class="awg-section" style="margin-top:15px; display:flex; align-items:center; justify-content:space-between;">
                    <span>Журнал</span>
                    <input type="button" class="button_gen" id="btn_copy_log" value="Копировать" onclick="copyLog();" style="font-size:11px; padding:2px 10px; text-transform:none; font-weight:normal;">
                </div>
                <div id="awg_log" class="awg-log">Ожидание данных...</div>
                <div style="text-align:right; font-size:11px; opacity:0.5; margin-top:4px;">
                    <a href="https://github.com/stxlvn/asuswrt-merlin-amneziawg" target="_blank" style="text-decoration:none;">&copy; stxlvn</a>
                </div>

            </td></tr>
            </table>

            </td>
        </tr>
        </table>
    </td>
</tr>
</table>
</form>

<div id="footer"></div>
</body>
</html>
