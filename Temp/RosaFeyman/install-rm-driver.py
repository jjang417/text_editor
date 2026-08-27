root@dl325g11-2067:~/scratch-4gpu-scripts# cat install-rm-38823641.py
#!/usr/bin/env python3
"""
Install RM driver 38823641 + tests into the running ARM64 L1 guest via UART console.

Based on install-driver-and-tests.py, with these changes:
  * ASSETS_DIR  -> 38823641
  * GUEST_DIR   -> /home/nvidia/RM  (created if missing)
  * also extracts tests-Linux-aarch64/resman/rmtest_apps.tar.xz

Transfer is over HTTP (host 10.0.2.2:18080 via QEMU slirp), driven from the
serial console -- the guest's static 172.17.0.100 can't use hostfwd/scp, so a
secondary 10.0.2.15/24 address must already be present on enp0s1.
"""

import http.server
import os
import re
import socket
import sys
import threading
import time

SCRIPT_DIR = "/root/scratch-4gpu-scripts"
SOCK       = os.path.join(SCRIPT_DIR, "guest_console.sock")
LOG        = os.path.join(SCRIPT_DIR, "install_38823641.log")
ASSETS_DIR = os.path.join(SCRIPT_DIR, "38823641")

DRIVER_RUN = os.path.join(ASSETS_DIR, "NVIDIA-Linux-aarch64-DVS-internal.run")
TESTS_TAR  = os.path.join(ASSETS_DIR, "tests-Linux-aarch64.tar")

HOST_IP    = "10.0.2.2"
HTTP_PORT  = 18080
GUEST_DIR  = "/home/nvidia/RM"

logf = open(LOG, "ab", buffering=0)
buf  = b""
sock = None


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    logf.write((line + "\n").encode())


def wait_for(pattern, timeout, poke=None, poke_every=60):
    global buf
    deadline  = time.time() + timeout
    last_poke = time.time()
    compiled  = re.compile(pattern)
    while time.time() < deadline:
        if poke is not None and time.time() - last_poke > poke_every:
            sock.send(poke)
            last_poke = time.time()
        try:
            d = sock.recv(65536)
            if d:
                buf += d
                logf.write(d)
        except socket.timeout:
            pass
        if compiled.search(buf[-4000:].decode("utf-8", "replace")):
            return True
    log(f"  TIMEOUT waiting for: {pattern!r}")
    log("  tail:\n" + buf[-1200:].decode("utf-8", "replace"))
    return False


def send_cmd(line, timeout=60):
    """Send command + RC probe. Returns (rc, output)."""
    global buf
    buf = b""
    log(f"  >> {line[:140]}")
    sock.send((line + '; echo "RC:$?"').encode() + b"\n")
    time.sleep(0.3)
    if not wait_for(r"RC:\d+", timeout, poke=b"", poke_every=120):
        log(f"TIMEOUT after: {line[:80]}")
        sys.exit(1)
    out = buf.decode("utf-8", "replace")
    m   = re.search(r"RC:(\d+)", out)
    return (int(m.group(1)) if m else -1), out


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        fpath = os.path.join(ASSETS_DIR, self.path.lstrip("/"))
        if not os.path.isfile(fpath):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(os.path.getsize(fpath)))
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, fmt, *args):
        log(f"  HTTP {fmt % args}")


def main():
    global buf, sock

    for path, label in [(SOCK, "console sock"), (DRIVER_RUN, "driver .run"), (TESTS_TAR, "tests tar")]:
        if not os.path.exists(path):
            log(f"ERROR missing {label}: {path}")
            sys.exit(1)

    httpd = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), _Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"HTTP server :{HTTP_PORT} -> {ASSETS_DIR}")

    sock = socket.socket(socket.AF_UNIX)
    sock.connect(SOCK)
    sock.settimeout(5)

    log("Waiting for shell prompt...")
    buf = b""
    if not wait_for(r"\$ $|\$$", 60, poke=b"\n", poke_every=10):
        log("ERROR: no shell prompt (is the guest logged in?)")
        sys.exit(1)

    rc, _ = send_cmd(f"ping -c2 -W3 {HOST_IP}", timeout=40)
    if rc != 0:
        log("ERROR: guest cannot reach host 10.0.2.2 -- add 10.0.2.15/24 to enp0s1 first")
        sys.exit(1)
    log("Network OK")

    send_cmd(f"mkdir -p {GUEST_DIR}", timeout=30)

    # ---- driver ----
    dname = os.path.basename(DRIVER_RUN)
    mb    = os.path.getsize(DRIVER_RUN) // (1024 * 1024)
    log(f"Downloading driver ({mb} MB)...")
    rc, tail = send_cmd(
        f"wget -q -O {GUEST_DIR}/{dname} 'http://{HOST_IP}:{HTTP_PORT}/{dname}'",
        timeout=1800)
    if rc != 0:
        log(f"ERROR driver download rc={rc}\n" + tail[-1200:])
        sys.exit(1)
    log("Driver downloaded")

    log("Installing driver (several minutes)...")
    rc, tail = send_cmd(
        f"cd {GUEST_DIR} && echo nvidia | sudo -S sh {dname} "
        "-m=kernel --install-libglvnd -sq --no-drm",
        timeout=2400)
    if rc != 0:
        log(f"ERROR driver install rc={rc}\n" + tail[-2500:])
        sys.exit(1)
    log("Driver installed")

    # ---- tests ----
    tname = os.path.basename(TESTS_TAR)
    mb    = os.path.getsize(TESTS_TAR) // (1024 * 1024)
    log(f"Downloading tests tar ({mb} MB)...")
    rc, tail = send_cmd(
        f"wget -q -O {GUEST_DIR}/{tname} 'http://{HOST_IP}:{HTTP_PORT}/{tname}'",
        timeout=1800)
    if rc != 0:
        log(f"ERROR tests download rc={rc}\n" + tail[-1200:])
        sys.exit(1)
    log("Tests tar downloaded")

    log("Extracting tests-Linux-aarch64.tar ...")
    rc, tail = send_cmd(f"cd {GUEST_DIR} && tar xf {tname}", timeout=900)
    if rc != 0:
        log(f"ERROR extract rc={rc}\n" + tail[-1200:])
        sys.exit(1)
    log("tests tar extracted")

    log("Extracting resman/rmtest_apps.tar.xz ...")
    rc, tail = send_cmd(
        f"cd {GUEST_DIR}/tests-Linux-aarch64/resman && "
        f"ls rmtest_apps.tar.xz && tar xf rmtest_apps.tar.xz",
        timeout=1800)
    if rc != 0:
        log(f"WARNING rmtest_apps.tar.xz extract rc={rc} (see tail)\n" + tail[-1500:])
    else:
        log("rmtest_apps.tar.xz extracted")

    # ---- verify ----
    rc, tail = send_cmd("modinfo nvidia 2>&1 | grep -E 'filename|^version' | head -4", timeout=60)
    log("modinfo:\n" + tail[-900:])
    rc, tail = send_cmd(f"ls {GUEST_DIR} && ls {GUEST_DIR}/tests-Linux-aarch64 | head", timeout=60)
    log("listing:\n" + tail[-1200:])

    httpd.shutdown()
    log("=" * 55)
    log("ALL DONE -- " + GUEST_DIR)
    log("=" * 55)


if __name__ == "__main__":
    main()
