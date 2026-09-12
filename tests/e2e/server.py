#!/usr/bin/env python3
import os
import sys
import json
import shutil
import subprocess
import http.server
import socketserver
import time

PORT = 9990
SANDBOX = "/tmp/ssh_ksu_e2e_sandbox"
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
WEBROOT = os.path.join(REPO_ROOT, "webroot")

dummy_proc = None

def setup_sandbox():
    global dummy_proc
    if os.path.exists(SANDBOX):
        shutil.rmtree(SANDBOX)
    
    ssh_dir = os.path.join(SANDBOX, "ssh")
    mod_dir = os.path.join(SANDBOX, "modules/ssh-ksu")
    home_ssh = os.path.join(ssh_dir, "home/.ssh")
    os.makedirs(home_ssh, exist_ok=True)
    os.makedirs(mod_dir, exist_ok=True)

    # Configs
    shutil.copy(os.path.join(REPO_ROOT, "sshd_config"), os.path.join(ssh_dir, "sshd_config"))
    shutil.copy(os.path.join(REPO_ROOT, "module.prop"), os.path.join(mod_dir, "module.prop"))
    
    with open(os.path.join(mod_dir, "module.prop"), "r") as f:
        mprop = f.read().replace("Status: Stopped", "Status: Running")
    with open(os.path.join(mod_dir, "module.prop"), "w") as f:
        f.write(mprop)

    with open(os.path.join(home_ssh, "authorized_keys"), "w") as f:
        f.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5a8Wd4mE6Q1y2e3r4t5y6u7i8o9p0a1b2c3d4e5f6g test@e2e\n")

    with open(os.path.join(ssh_dir, "sshd.log"), "w") as f:
        f.write("[2026-09-12 13:00:00] [ssh-ksu] sshd launched successfully (pid=12345).\n")
        f.write("[2026-09-12 13:01:23] Server listening on 0.0.0.0 port 22.\n")
        f.write("[2026-09-12 13:02:15] Accepted publickey for root from 192.168.1.100 port 54321 ssh2: ED25519\n")

    # Host keys
    subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", os.path.join(ssh_dir, "ssh_host_ed25519_key"), "-N", ""],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["ssh-keygen", "-t", "rsa", "-b", "2048", "-f", os.path.join(ssh_dir, "ssh_host_rsa_key"), "-N", ""],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Start dummy daemon process
    start_dummy_daemon()

    # Create mock action.sh
    action_sh_content = f"""#!/bin/bash
ACTION="$1"
SSH_DIR="{ssh_dir}"
MOD_DIR="{mod_dir}"

case "$ACTION" in
    stop)
        if [ -f "$SSH_DIR/sshd.pid" ]; then
            PID=$(cat "$SSH_DIR/sshd.pid")
            kill "$PID" 2>/dev/null || true
            rm -f "$SSH_DIR/sshd.pid"
        fi
        sed -i 's/Status: Running/Status: Stopped/g' "$MOD_DIR/module.prop"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ssh-ksu] stopped via action.sh" >> "$SSH_DIR/sshd.log"
        ;;
    start)
        nohup bash -c 'exec -a sshd sleep 3600' >/dev/null 2>&1 &
        echo $! > "$SSH_DIR/sshd.pid"
        sed -i 's/Status: Stopped/Status: Running/g' "$MOD_DIR/module.prop"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ssh-ksu] started via action.sh (pid=$(cat $SSH_DIR/sshd.pid))" >> "$SSH_DIR/sshd.log"
        ;;
    restart)
        "$0" stop
        sleep 0.5
        "$0" start
        ;;
esac
"""
    with open(os.path.join(mod_dir, "action.sh"), "w") as f:
        f.write(action_sh_content)
    os.chmod(os.path.join(mod_dir, "action.sh"), 0o755)

def start_dummy_daemon():
    global dummy_proc
    dummy_proc = subprocess.Popen(["bash", "-c", "exec -a sshd sleep 3600"])
    ssh_dir = os.path.join(SANDBOX, "ssh")
    with open(os.path.join(ssh_dir, "sshd.pid"), "w") as f:
        f.write(str(dummy_proc.pid))

BRIDGE_SNIPPET = """
<script>
window.ksu = {
  exec: function(command, optionsStr, callbackName) {
    fetch('/api/ksu_exec', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: command })
    })
    .then(r => r.json())
    .then(data => {
      if (typeof window[callbackName] === 'function') {
        window[callbackName](data.errno, data.stdout, data.stderr);
      }
    })
    .catch(err => {
      if (typeof window[callbackName] === 'function') {
        window[callbackName](1, '', String(err));
      }
    });
  },
  toast: function(msg) {
    console.log('[KSU_TOAST]', msg);
    const t = document.createElement('div');
    t.className = 'ksu-e2e-toast';
    t.style.display = 'none';
    t.innerText = msg;
    document.body.appendChild(t);
  },
  fullScreen: function() {},
  enableEdgeToEdge: function() {}
};
</script>
"""

class E2EHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEBROOT, **kwargs)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index.html"):
            index_path = os.path.join(WEBROOT, "index.html")
            with open(index_path, "r", encoding="utf-8") as f:
                content = f.read()
            # Inject bridge before </head>
            injected = content.replace("</head>", f"{BRIDGE_SNIPPET}</head>")
            data = injected.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        return super().do_GET()

    def do_POST(self):
        if self.path == "/api/ksu_exec":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8")
            payload = json.loads(body)
            raw_cmd = payload.get("command", "")

            # Path mappings to sandbox
            cmd = raw_cmd.replace("/data/adb/ssh", f"{SANDBOX}/ssh")
            cmd = cmd.replace("/data/adb/modules/ssh-ksu", f"{SANDBOX}/modules/ssh-ksu")

            # Execute command in bash
            res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)

            out_data = json.dumps({
                "errno": res.returncode,
                "stdout": res.stdout,
                "stderr": res.stderr
            }).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out_data)))
            self.end_headers()
            self.wfile.write(out_data)
            return

        self.send_error(404, "Not Found")

def main():
    setup_sandbox()
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), E2EHandler) as httpd:
        print(f"E2E Test Server ready at http://127.0.0.1:{PORT}", flush=True)
        try:
            httpd.serve_forever()
        finally:
            if dummy_proc:
                dummy_proc.terminate()

if __name__ == "__main__":
    main()
