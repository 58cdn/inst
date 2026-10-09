"""Real curl + isolated TLS server; no external downloads or system trust changes."""
import hashlib
import http.server
import os
from pathlib import Path
import signal
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BODY = b'#!/bin/sh\n' + b'#' * 8192

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        mode = self.path[1:].split('.')[0]
        try:
            if mode == 'headers':
                time.sleep(4)
            if mode.startswith('redirect'):
                n = int(mode[8:])
                time.sleep(.65)
                self.send_response(302)
                self.send_header('Location', '/redirect%d.sh' % (n + 1))
                self.end_headers()
                return
            if mode == 'downgrade':
                self.send_response(302)
                self.send_header('Location', 'http://localhost/ok.sh')
                self.end_headers()
                return
            self.send_response(500 if mode == 'error' else 200)
            self.send_header('Content-Type', 'application/octet-stream')
            length = {'empty': 0, 'html': 1030, 'small': 10, 'slow': 9*len(BODY)}.get(mode, len(BODY) + (1 if mode == 'stall' else 0))
            self.send_header('Content-Length', str(length))
            self.end_headers()
            if mode == 'empty':
                return
            if mode == 'no-data':
                time.sleep(4)
                return
            if mode == 'html':
                self.wfile.write(b'<html>' + b'x' * 1024)
                return
            if mode == 'tiny':
                self.wfile.write(b'#'); self.wfile.flush(); time.sleep(4)
                return
            if mode == 'small':
                self.wfile.write(b'#!/bin/sh\n'); return
            self.wfile.write(BODY); self.wfile.flush()
            if mode == 'stall':
                time.sleep(5)
            if mode == 'slow':
                for _ in range(8):
                    time.sleep(.5); self.wfile.write(BODY); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

with tempfile.TemporaryDirectory() as temp:
    d = Path(temp)
    (d / 'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n')
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(d/'cert.cnf'),'-keyout',str(d/'key'),'-out',str(d/'cert')], check=True, capture_output=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(d/'cert', d/'key')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, CURL_CA_BUNDLE=str(d/'cert'), NO_PROXY='localhost')
    def command(mode, digest=''):
        return ['bash','-c','. "$1"; inst_download_attempt "$2" "$3" "$4" 2 2', 'test', str(ROOT/'scripts/lib/download.sh'),f'https://localhost:{server.server_port}/{mode}.sh',str(d/'out'),digest]
    for mode, success, digest in [('ok',True,''),('small',True,''),('slow',True,''),('headers',False,''),('no-data',False,''),('tiny',False,''),('stall',False,''),('empty',False,''),('html',False,''),('error',False,''),('redirect0',False,''),('downgrade',False,''),('ok',False,'0'*64),('ok',True,hashlib.sha256(BODY).hexdigest())]:
        (d/'out').write_bytes(b'original')
        begin = time.monotonic()
        result = subprocess.run(command(mode,digest), env=env, capture_output=True, timeout=12)
        elapsed = time.monotonic() - begin
        assert (result.returncode == 0) == success, (mode,result.stderr)
        if not success:
            assert (d/'out').read_bytes() == b'original', mode
        assert not list(d.glob('out.part.*')), mode
        if mode in ('headers','no-data','tiny','redirect0'):
            assert elapsed < 3.5, (mode,elapsed)
        if mode == 'slow':
            assert elapsed > 4, elapsed
        print('PASS:',mode,round(elapsed,2),flush=True)
    p = subprocess.Popen(command('no-data'),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    time.sleep(.3); os.killpg(p.pid,signal.SIGTERM); p.communicate(timeout=3)
    assert p.returncode != 0 and not list(d.glob('out.part.*'))
    print('PASS: cancellation cleanup',flush=True)
    server.shutdown()

# Candidate policy and retry state, independent of external mirror availability.
subprocess.run(['bash','-c',r'''
set -eu
. "$1/scripts/lib/download.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for url in 'https://example.org/a.zip' 'https://inst.linux.yun/scripts/install-unix.sh?token=secret' 'https://u:p@inst.linux.yun/scripts/install-unix.sh'; do
  [ "$(inst_download_candidates "$url" | wc -l | tr -d ' ')" = 1 ]
done
[ "$(inst_download_candidates https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh | wc -l | tr -d ' ')" = 1 ]
[ "$(inst_download_candidates https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh abc | wc -l | tr -d ' ')" = 2 ]
inst_download_attempt() { echo attempt >> "$tmp/log"; case "$1" in https://inst.linux.yun/*) return 28;; *) echo valid > "$2";; esac; }
inst_download https://inst.linux.yun/scripts/install-unix.sh "$tmp/out"
[ "$(cat "$tmp/out")" = valid ]; [ "$(wc -l < "$tmp/log" | tr -d ' ')" = 2 ]
inst_download_attempt() { echo attempt >> "$tmp/log"; return 65; }
: > "$tmp/log"
if inst_download https://inst.linux.yun/scripts/install-unix.sh "$tmp/out"; then exit 1; fi
[ "$(wc -l < "$tmp/log" | tr -d ' ')" = 2 ]
inst_download_attempt() { echo attempt >> "$tmp/log"; return 130; }
: > "$tmp/log"
if inst_download https://inst.linux.yun/scripts/install-unix.sh "$tmp/out"; then exit 1; fi
[ "$(wc -l < "$tmp/log" | tr -d ' ')" = 1 ]
echo 'PASS: bounded mirror success/exhaustion/cancel and URL policy'
''','test',str(ROOT)],check=True)
