// ─────────────────────────────────────────────────────────────
// KernelSU API import
// ─────────────────────────────────────────────────────────────
let ksuExec, ksuSpawn, ksuToast;
try {
  const ksu = await import('./kernelsu.js');
  ksuExec  = ksu.exec;
  ksuSpawn = ksu.spawn;
  ksuToast = ksu.toast;
} catch {
  // Fallback for desktop dev/preview
  ksuExec  = async (cmd) => ({ errno: 1, stdout: `[mock] ${cmd}`, stderr: '' });
  ksuSpawn = () => ({ stdout: { on: () => {} }, stderr: { on: () => {} }, on: () => {} });
  ksuToast = (msg) => console.log('[toast]', msg);
}

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────
const SSH_DIR  = '/data/adb/ssh';
const MOD_DIR  = '/data/adb/modules/ssh-ksu';
const PID_FILE = `${SSH_DIR}/sshd.pid`;
const CONFIG   = `${SSH_DIR}/sshd_config`;
const AUTH_KEYS= `${SSH_DIR}/home/.ssh/authorized_keys`;
const LOG_FILE = `${SSH_DIR}/sshd.log`;
const ACTION   = `${MOD_DIR}/action.sh`;

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────
const sh  = async (cmd) => {
  const r = await ksuExec(cmd);
  return { ok: r.errno === 0, out: (r.stdout||'').trim(), err: (r.stderr||'').trim() };
};

function toBase64(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i]);
  }
  return btoa(bin);
}

function toast(msg, dur = 2000) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  setTimeout(() => el.classList.remove('show'), dur);
}

function confirm(title, body) {
  return new Promise((resolve) => {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').textContent  = body;
    document.getElementById('modal').classList.add('open');
    const ok  = document.getElementById('modal-ok');
    const cancel = document.getElementById('modal-cancel');
    const cleanup = (val) => {
      document.getElementById('modal').classList.remove('open');
      ok.removeEventListener('click', onOk);
      cancel.removeEventListener('click', onCancel);
      resolve(val);
    };
    const onOk = () => cleanup(true);
    const onCancel = () => cleanup(false);
    ok.addEventListener('click', onOk);
    cancel.addEventListener('click', onCancel);
  });
}

function setButtonLoading(btn, loading) {
  if (loading) {
    btn._label = btn.innerHTML;
    btn.innerHTML = '<span class="spin"></span>';
    btn.disabled = true;
  } else {
    btn.innerHTML = btn._label || btn.innerHTML;
    btn.disabled = false;
  }
}

// ─────────────────────────────────────────────────────────────
// SSH status & info
// ─────────────────────────────────────────────────────────────
let lastDescription = '';
let activeProcessUptime = null;
let uptimeInterval = null;
let selectedIp = null;

async function getStatus() {
  const pidR = await sh(`cat ${PID_FILE} 2>/dev/null`);
  if (!pidR.ok || !pidR.out) return { running: false, pid: null };
  const cleanPid = parseInt(pidR.out.trim(), 10);
  if (isNaN(cleanPid)) return { running: false, pid: null };
  const procR = await sh(`[ -d /proc/${cleanPid} ] && echo yes`);
  return { running: procR.out === 'yes', pid: cleanPid };
}

async function getPort() {
  const r = await sh(`grep -m1 -E '^Port ' ${CONFIG} 2>/dev/null | awk '{print $2}'`);
  return r.out || '22';
}

async function getProcessAge(pid) {
  if (!pid) return null;
  const cleanPid = parseInt(String(pid).trim(), 10);
  if (isNaN(cleanPid)) return null;
  const r = await sh(
    `awk '{print $1}' /proc/uptime 2>/dev/null && ` +
    `awk '{print $22}' /proc/${cleanPid}/stat 2>/dev/null && ` +
    `getconf CLK_TCK 2>/dev/null || echo 100`
  );
  if (!r.ok || !r.out) return null;
  const lines = r.out.split('\n').map(l => l.trim()).filter(Boolean);
  if (lines.length < 3) return null;
  const uptimeSec  = parseFloat(lines[0]);
  const startTicks = parseInt(lines[1]);
  const clkTck     = parseInt(lines[2]) || 100;
  const startSec   = startTicks / clkTck;
  const age = Math.floor(uptimeSec - startSec);
  return age >= 0 ? age : null;
}

function formatDuration(secs) {
  if (secs === null || secs < 0) return '—';
  const h = Math.floor(secs / 3600);
  const rem = secs % 3600;
  const m = Math.floor(rem / 60);
  const s = rem % 60;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

function startUptimeTicker() {
  if (uptimeInterval) clearInterval(uptimeInterval);
  updateUptimeUI();
  uptimeInterval = setInterval(() => {
    if (activeProcessUptime !== null) {
      activeProcessUptime++;
      updateUptimeUI();
    }
  }, 1000);
}

function stopUptimeTicker() {
  if (uptimeInterval) {
    clearInterval(uptimeInterval);
    uptimeInterval = null;
  }
}

function updateUptimeUI() {
  document.getElementById('info-uptime').textContent = formatDuration(activeProcessUptime);
}

async function getIPs() {
  // ip addr show → extract inet lines
  const r = await sh(`ip addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1'`);
  if (!r.ok || !r.out) return [];
  return r.out.split('\n').map(line => {
    const m = line.match(/inet\s+([\d.]+)\/\d+/);
    if (!m) return null;
    const ip = m[1];
    const parts = line.trim().split(/\s+/);
    const iface = parts[parts.length - 1] || 'unknown';
    let type = 'other';
    if (/wlan|wlp/.test(iface)) type = 'wifi';
    else if (/rmnet|ccmni|usb/.test(iface)) type = 'mobile';
    return { ip, iface, type };
  }).filter(Boolean);
}

async function getClients() {
  const portR = await getPort();
  let r = await sh(`ss -tnp 2>/dev/null | grep ':${portR} ' | grep ESTAB`);
  if (!r.ok || !r.out) {
    r = await sh(`netstat -tn 2>/dev/null | grep ':${portR} ' | grep ESTABLISHED`);
  }
  if (!r.ok || !r.out) return [];
  return r.out.split('\n').filter(Boolean).map(line => {
    const parts = line.trim().split(/\s+/);
    const peer  = parts[4] || parts[3] || '';
    const ip    = peer.replace(/:\d+$/, '');
    const since = '(active)';
    return { ip, since };
  }).filter(x => x.ip && x.ip !== '—');
}

// ─────────────────────────────────────────────────────────────
// Update module.prop description with self-healing redirection
// ─────────────────────────────────────────────────────────────
async function updateModuleProp(status, port) {
  const label = status.running ? 'Running' : 'Stopped';
  const desc  = `OpenSSH server + bash shell. Port: ${port} | Status: ${label} | Home: /data/adb/ssh/home`;
  if (desc === lastDescription) return;

  const checkR = await sh(`cat ${MOD_DIR}/module.prop 2>/dev/null`);
  let content = checkR.out || '';

  // If empty or missing, rebuild module.prop with standard structure
  if (!content.trim() || !content.includes('id=')) {
    content = `id=ssh-ksu
name=SSH-KSU
version=1.1.0
versionCode=2
author=Jtnqr
description=${desc}`;
  } else {
    // Replace the description line safely in JS
    content = content.replace(/^description=.*/m, `description=${desc}`);
  }

  // Write content safely using base64 stream to prevent shell metacharacter expansion
  const b64 = toBase64(content);
  const r = await sh(`printf '%s' '${b64}' | base64 -d > ${MOD_DIR}/module.prop`);
  if (r.ok || r.errno === 0) {
    lastDescription = desc;
  }
}

let controlInProgress = false;

// ─────────────────────────────────────────────────────────────
// Dashboard refresh
// ─────────────────────────────────────────────────────────────
async function refreshDashboard() {
  const [status, port] = await Promise.all([getStatus(), getPort()]);

  // Pill
  const pill = document.getElementById('status-pill');
  pill.className = 'loading';
  void pill.offsetWidth;
  pill.className = status.running ? 'running' : 'stopped';
  pill.innerHTML = `<div class="dot${status.running ? ' pulse' : ''}"></div><span>${status.running ? 'Running' : 'Stopped'}</span>`;

  // Info
  document.getElementById('info-port').textContent = port;
  document.getElementById('info-pid').textContent  = status.pid ?? '—';

  // Dynamic process Uptime ticker
  if (status.running && status.pid) {
    const ageSecs = await getProcessAge(status.pid);
    activeProcessUptime = ageSecs;
    startUptimeTicker();
  } else {
    activeProcessUptime = null;
    stopUptimeTicker();
    updateUptimeUI();
  }

  // Buttons
  document.getElementById('btn-start').disabled   =  status.running || controlInProgress;
  document.getElementById('btn-stop').disabled    = !status.running || controlInProgress;
  document.getElementById('btn-restart').disabled = !status.running || controlInProgress;

  // IPs
  const ips = await getIPs();
  const ipList = document.getElementById('ip-list');
  if (ips.length === 0) {
    ipList.innerHTML = `<div class="empty-state">No network interfaces found</div>`;
  } else {
    if (!selectedIp || !ips.some(x => x.ip === selectedIp)) {
      selectedIp = ips[0].ip;
    }
    ipList.innerHTML = ips.map(x => {
      const isSelected = x.ip === selectedIp;
      return `
        <div class="interface-row clickable ${isSelected ? 'selected' : ''}" data-ip="${x.ip}" role="button" tabindex="0" title="Tap to copy SSH command">
          <div class="if-left">
            <span class="selection-dot ${isSelected ? 'active' : ''}"></span>
            <span class="if-name">${x.iface}</span>
          </div>
          <div class="if-right">
            <span class="if-ip">${x.ip}</span>
            <span class="if-action">Copy</span>
          </div>
        </div>
      `;
    }).join('');
  }

  // Quick connect command
  const cmdEl = document.getElementById('quick-connect-cmd');
  if (cmdEl) {
    const activeIp = selectedIp || ((ips && ips.length > 0) ? ips[0].ip : '127.0.0.1');
    cmdEl.textContent = `ssh root@${activeIp} -p ${port}`;
  }

  // Clients
  await refreshClients(status);

  // module.prop
  await updateModuleProp(status, port);
}

async function refreshClients(status) {
  const clients = await getClients();
  const el = document.getElementById('client-list');
  document.getElementById('info-clients').textContent = clients.length.toString();
  if (clients.length === 0) {
    el.innerHTML = `<div class="empty-state">No active sessions</div>`;
  } else {
    el.innerHTML = clients.map(c => `
      <div class="row">
        <span class="row-label">${c.ip}</span>
        <span class="row-value">${c.since}</span>
      </div>
    `).join('');
  }
}

// ─────────────────────────────────────────────────────────────
// Control actions
// ─────────────────────────────────────────────────────────────
async function runControl(action) {
  if (controlInProgress) return;
  controlInProgress = true;

  const btn = document.getElementById(`btn-${action}`);
  setButtonLoading(btn, true);

  // Disable all buttons immediately to block concurrent clicks
  document.getElementById('btn-start').disabled   = true;
  document.getElementById('btn-stop').disabled    = true;
  document.getElementById('btn-restart').disabled = true;

  try {
    await sh(`sh ${ACTION} ${action}`);
    // wait for settle
    await new Promise(r => setTimeout(r, 1500));
  } catch (e) {
    console.error(e);
  } finally {
    controlInProgress = false;
    setButtonLoading(btn, false);
    await refreshDashboard();
  }
  toast(`sshd ${action}ed`);
}

// ─────────────────────────────────────────────────────────────
// Live log via spawn
// ─────────────────────────────────────────────────────────────
let logInterval = null;
let livePaused = false;
let logLines   = [];   // array of raw line strings
let lineCount  = 0;
const LOG_CAP  = 500;

function classifyLine(text) {
  if (/error|failed|fatal/i.test(text)) return 'err';
  if (/warn/i.test(text)) return 'warn';
  return '';
}

function renderLogRow(lineNum, text) {
  const row  = document.createElement('div');
  row.className = 'log-line' + (classifyLine(text) ? ' ' + classifyLine(text) : '');
  const num  = document.createElement('span');
  num.className = 'log-num';
  num.textContent = lineNum;
  const txt  = document.createElement('span');
  txt.className = 'log-text';
  txt.textContent = text;
  row.appendChild(num);
  row.appendChild(txt);
  return row;
}

function flushLog() {
  const el = document.getElementById('log-output');
  el.innerHTML = '';
  for (const line of logLines) {
    if (!line.trim()) continue;
    const idx = line.indexOf(':');
    if (idx !== -1) {
      const fileLineNum = parseInt(line.substring(0, idx), 10);
      const text = line.substring(idx + 1);
      el.appendChild(renderLogRow(fileLineNum, text));
    } else {
      el.appendChild(renderLogRow('', line));
    }
  }
  const scrollEl = document.getElementById('log-scroll');
  if (scrollEl) {
    scrollEl.scrollTop = scrollEl.scrollHeight;
  }
}

async function updateLogView() {
  if (livePaused) return;
  const r = await sh(`awk '{print NR ":" $0}' ${LOG_FILE} 2>/dev/null | tail -n 100`);
  if (r.ok) {
    logLines = r.out ? r.out.split('\n') : [];
    flushLog();
  }
}

function startLiveLog() {
  if (logInterval) return;
  
  logLines = [];
  document.getElementById('log-output').innerHTML = 'Loading log…';
  
  updateLogView();
  logInterval = setInterval(updateLogView, 2000);
  
  setLiveUI(true);
}

function stopLiveLog() {
  if (logInterval) {
    clearInterval(logInterval);
    logInterval = null;
  }
  setLiveUI(false);
}

function setLiveUI(on) {
  const ind   = document.getElementById('live-indicator');
  const label = document.getElementById('live-label');
  const btn   = document.getElementById('btn-toggle-live');
  ind.className = on && !livePaused ? 'on' : '';
  label.textContent = on ? (livePaused ? 'PAUSED' : 'LIVE') : 'OFF';
  btn.textContent   = on ? (livePaused ? 'Resume' : 'Pause') : 'Start';
}

// ─────────────────────────────────────────────────────────────
// Config editor — gutter sync
// ─────────────────────────────────────────────────────────────
const editorArea   = document.getElementById('editor-area');
const editorGutter = document.getElementById('editor-gutter');

function updateGutter() {
  const lines = editorArea.value.split('\n').length;
  let nums = '';
  for (let i = 1; i <= lines; i++) nums += i + '\n';
  editorGutter.textContent = nums;
  // sync scroll position
  editorGutter.scrollTop = editorArea.scrollTop;
}

editorArea.addEventListener('input',  updateGutter);
editorArea.addEventListener('scroll', () => { editorGutter.scrollTop = editorArea.scrollTop; });
// keep gutter height in sync with textarea height (resize observer)
new ResizeObserver(() => {
  requestAnimationFrame(() => {
    editorGutter.style.height = editorArea.clientHeight + 'px';
  });
}).observe(editorArea);

let activeFile = 'sshd_config';
const filePaths = {
  sshd_config:     CONFIG,
  authorized_keys: AUTH_KEYS,
};

async function loadFile(name) {
  activeFile = name;
  document.querySelectorAll('.file-tab').forEach(t => t.classList.toggle('active', t.dataset.file === name));
  document.getElementById('save-status').textContent = '';
  editorArea.value = 'Loading…';
  updateGutter();
  const r = await sh(`cat ${filePaths[name]} 2>/dev/null`);
  editorArea.value = r.out || '';
  updateGutter();
}

async function saveFile() {
  if (activeFile !== 'sshd_config' && activeFile !== 'authorized_keys') {
    toast('Save failed: Invalid file selection');
    return;
  }
  const btn = document.getElementById('btn-save');
  const status = document.getElementById('save-status');
  setButtonLoading(btn, true);
  const content = editorArea.value;
  // Write safely via base64 stream to prevent quote escaping and ARG_MAX shell limits
  const b64 = toBase64(content);
  const r = await sh(`printf '%s' '${b64}' | base64 -d > ${filePaths[activeFile]}`);
  setButtonLoading(btn, false);
  if (r.ok || r.errno === 0) {
    status.className = 'save-status ok';
    status.textContent = '✓ Saved';
    toast('File saved');
  } else {
    status.className = 'save-status err';
    status.textContent = '✗ Failed';
    toast('Save failed: ' + r.err);
  }
  setTimeout(() => status.textContent = '', 3000);
}

// ─────────────────────────────────────────────────────────────
// Host key management
// ─────────────────────────────────────────────────────────────
async function loadKeys() {
  const el = document.getElementById('key-list');
  const keys = ['ssh_host_ed25519_key', 'ssh_host_rsa_key'];
  const items = await Promise.all(keys.map(async (k) => {
    const exists = await sh(`[ -f ${SSH_DIR}/${k} ] && echo yes`);
    if (exists.out !== 'yes') return null;
    const fp = await sh(`ssh-keygen -l -f ${SSH_DIR}/${k} 2>/dev/null`);
    const type = k.includes('ed25519') ? 'ED25519' : 'RSA';
    return { type, fp: fp.out || '(fingerprint unavailable)' };
  }));
  const valid = items.filter(Boolean);
  if (valid.length === 0) {
    el.innerHTML = `<div class="empty-state"><div class="icon">🔑</div>No host keys found.<br>Generate keys below.</div>`;
    return;
  }
  el.innerHTML = valid.map(k => `
    <div class="key-item">
      <div class="key-header">
        <span class="key-type">${k.type}</span>
      </div>
      <div class="key-fp" title="Tap to copy fingerprint" role="button" tabindex="0">${k.fp}</div>
    </div>
  `).join('');

  el.querySelectorAll('.key-fp').forEach(fpEl => {
    fpEl.addEventListener('click', async () => {
      const text = fpEl.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        toast('Fingerprint copied');
      } catch {
        toast(text);
      }
    });
  });
}

async function regenKey(type, bits) {
  const label = type === 'ed25519' ? 'ED25519' : `RSA-${bits}`;
  const ok = await confirm(
    `Regenerate ${label} Key`,
    `This will delete the existing ${label} host key and generate a new one. Connected clients will see a host key warning. Continue?`
  );
  if (!ok) return;
  const btn = document.getElementById(`btn-regen-${type}`);
  setButtonLoading(btn, true);
  await sh(`rm -f ${SSH_DIR}/ssh_host_${type}_key ${SSH_DIR}/ssh_host_${type}_key.pub`);
  const flags = type === 'rsa' ? `-t rsa -b ${bits}` : `-t ed25519`;
  await sh(`ssh-keygen ${flags} -N "" -f ${SSH_DIR}/ssh_host_${type}_key 2>/dev/null`);
  await loadKeys();
  setButtonLoading(btn, false);
  toast(`${label} key regenerated`);
}

async function regenAll() {
  const ok = await confirm(
    '⚠ Regenerate ALL Keys',
    'This will delete ALL host keys, generate new ones, and restart sshd. All clients will need to re-accept the host key. Continue?'
  );
  if (!ok) return;
  const btn = document.getElementById('btn-regen-all');
  setButtonLoading(btn, true);
  await sh(`rm -f ${SSH_DIR}/ssh_host_*`);
  await sh(`ssh-keygen -t ed25519 -N "" -f ${SSH_DIR}/ssh_host_ed25519_key 2>/dev/null`);
  await sh(`ssh-keygen -t rsa -b 4096 -N "" -f ${SSH_DIR}/ssh_host_rsa_key 2>/dev/null`);
  await sh(`sh ${ACTION} restart`);
  await Promise.all([loadKeys(), refreshDashboard()]);
  setButtonLoading(btn, false);
  toast('All keys regenerated, sshd restarted');
}

// ─────────────────────────────────────────────────────────────
// Tab routing
// ─────────────────────────────────────────────────────────────
const panels = { dashboard: false, log: false, editor: false, keys: false };

async function switchTab(name) {
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.panel === name));
  document.querySelectorAll('.panel').forEach(p => p.classList.toggle('active', p.id === name));

  if (name === 'log') {
    startLiveLog();
  } else {
    stopLiveLog();
  }
  if (name === 'editor' && !panels.editor) {
    panels.editor = true;
    await loadFile('sshd_config');
  }
  if (name === 'keys' && !panels.keys) {
    panels.keys = true;
    await loadKeys();
  }
}

// ─────────────────────────────────────────────────────────────
// Wire up events
// ─────────────────────────────────────────────────────────────
document.querySelectorAll('.tab').forEach(t =>
  t.addEventListener('click', () => switchTab(t.dataset.panel))
);

document.getElementById('btn-start').addEventListener('click', () => runControl('start'));
document.getElementById('btn-stop').addEventListener('click',  () => runControl('stop'));
document.getElementById('btn-restart').addEventListener('click', () => runControl('restart'));

const copyBtn = document.getElementById('btn-copy-ssh');
if (copyBtn) {
  copyBtn.addEventListener('click', async () => {
    const cmd = document.getElementById('quick-connect-cmd').textContent.trim();
    try {
      await navigator.clipboard.writeText(cmd);
      toast('Copied to clipboard');
    } catch {
      // Fallback
      toast(cmd);
    }
  });
}

const ipListEl = document.getElementById('ip-list');
if (ipListEl) {
  const handleIpSelect = async (row) => {
    const ip = row.dataset.ip;
    if (!ip) return;
    selectedIp = ip;

    // Update active row visual states
    ipListEl.querySelectorAll('.interface-row').forEach(r => {
      const active = r.dataset.ip === selectedIp;
      r.classList.toggle('selected', active);
      r.querySelector('.selection-dot')?.classList.toggle('active', active);
    });

    // Update connect command box
    const portEl = document.getElementById('info-port');
    const port = (portEl && portEl.textContent.trim() !== '—') ? portEl.textContent.trim() : '22';
    const cmd = `ssh root@${selectedIp} -p ${port}`;
    const cmdEl = document.getElementById('quick-connect-cmd');
    if (cmdEl) cmdEl.textContent = cmd;

    // Copy to clipboard
    try {
      await navigator.clipboard.writeText(cmd);
      toast(`Copied: ${cmd}`);
    } catch {
      toast(cmd);
    }
  };

  ipListEl.addEventListener('click', (e) => {
    const row = e.target.closest('.interface-row');
    if (row) handleIpSelect(row);
  });

  ipListEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      const row = e.target.closest('.interface-row');
      if (row) {
        e.preventDefault();
        handleIpSelect(row);
      }
    }
  });
}

document.getElementById('btn-toggle-live').addEventListener('click', () => {
  if (!logInterval) {
    startLiveLog();
  } else {
    livePaused = !livePaused;
    if (!livePaused) flushLog();
    setLiveUI(true);
  }
});
document.getElementById('btn-clear-log').addEventListener('click', async () => {
  if (await confirm('Clear log file?', 'Are you sure you want to truncate the physical sshd.log file on your device?')) {
    logLines = [];
    lineCount = 0;
    document.getElementById('log-output').innerHTML = '';
    const r = await sh(`> ${LOG_FILE}`);
    if (r.ok) {
      toast('Physical log truncated');
    } else {
      toast('Log cleared locally, failed to truncate file');
    }
  }
});

document.querySelectorAll('.file-tab').forEach(t =>
  t.addEventListener('click', () => loadFile(t.dataset.file))
);
document.getElementById('btn-save').addEventListener('click', saveFile);
document.getElementById('btn-reload-file').addEventListener('click', () => loadFile(activeFile));

document.getElementById('btn-regen-ed25519').addEventListener('click', () => regenKey('ed25519'));
document.getElementById('btn-regen-rsa').addEventListener('click',     () => regenKey('rsa', 4096));
document.getElementById('btn-regen-all').addEventListener('click',      regenAll);

document.getElementById('modal-cancel').addEventListener('click', () =>
  document.getElementById('modal').classList.remove('open')
);

// ─────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────
await refreshDashboard();

// Clients auto-refresh every 10s when dashboard is active
setInterval(async () => {
  const active = document.querySelector('.tab.active');
  if (active?.dataset.panel === 'dashboard') {
    const s = await getStatus();
    await refreshClients(s);
  }
}, 10_000);

// Full dashboard refresh every 30s (uptime, IPs, status pill, module.prop)
setInterval(async () => {
  const active = document.querySelector('.tab.active');
  if (active?.dataset.panel === 'dashboard') await refreshDashboard();
}, 30_000);
