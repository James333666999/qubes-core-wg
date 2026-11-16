#!/usr/bin/env python3
"""Test qvif against a fake xenstore speaking the real wire protocol over a unix socket."""
import os, socket, struct, subprocess, sys, tempfile, threading, time

XS_DIRECTORY, XS_READ, XS_WATCH, XS_WRITE, XS_EVENT, XS_ERROR = 1, 2, 4, 11, 15, 16
HDR = struct.Struct("<IIII")


class FakeXenstore:
    def __init__(self, path):
        self.kv = {}
        self.watches = []
        self.lock = threading.Lock()
        self.conn = None
        self.nreq = 0
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(1)
        threading.Thread(target=self.serve, daemon=True).start()

    def send(self, typ, rid, payload):
        with self.lock:
            self.conn.sendall(HDR.pack(typ, rid, 0, len(payload)) + payload)

    def fire(self, key):
        for p, tok in list(self.watches):
            if key == p or key.startswith(p + "/"):
                self.send(XS_EVENT, 0, key.encode() + b"\0" + tok.encode() + b"\0")

    def recvn(self, n):
        buf = b""
        while len(buf) < n:
            c = self.conn.recv(n - len(buf))
            if not c:
                raise EOFError
            buf += c
        return buf

    def serve(self):
        self.conn, _ = self.srv.accept()
        try:
            while True:
                typ, rid, _tx, ln = HDR.unpack(self.recvn(16))
                body = self.recvn(ln)
                self.nreq += 1
                if self.nreq % 3 == 0:  # interleave an event before the reply
                    self.send(XS_EVENT, 0, b"backend/vif\0qvif\0")
                self.handle(typ, rid, body)
        except (EOFError, OSError):
            pass

    def err(self, rid, name):
        self.send(XS_ERROR, rid, name.encode() + b"\0")

    def handle(self, typ, rid, body):
        if typ == XS_WATCH:
            path, tok = body.split(b"\0")[:2]
            self.watches.append((path.decode(), tok.decode()))
            self.send(typ, rid, b"OK\0")
            self.fire(path.decode())
        elif typ == XS_READ:
            k = body.rstrip(b"\0").decode()
            if k in self.kv:
                self.send(typ, rid, self.kv[k].encode())
            else:
                self.err(rid, "ENOENT")
        elif typ == XS_DIRECTORY:
            k = body.rstrip(b"\0").decode()
            kids = []
            for key in sorted(self.kv):
                if key.startswith(k + "/"):
                    c = key[len(k) + 1:].split("/")[0]
                    if c not in kids:
                        kids.append(c)
            if kids:
                self.send(typ, rid, b"".join(c.encode() + b"\0" for c in kids))
            else:
                self.err(rid, "ENOENT")
        elif typ == XS_WRITE:
            path, _, val = body.partition(b"\0")
            self.kv[path.decode()] = val.decode()
            self.send(typ, rid, b"OK\0")
            self.fire(path.decode())
        else:
            self.err(rid, "EINVAL")

    # --- test-side admin ---
    def add_dev(self, dom, h, ip, state=1):
        base = f"backend/vif/{dom}/{h}"
        self.kv[base + "/handle"] = str(h)
        self.kv[base + "/ip"] = ip
        self.kv[base + "/state"] = str(state)  # state last, like libxl's transaction
        self.fire(base + "/state")

    def set(self, k, v):
        self.kv[k] = v
        self.fire(k)

    def remove_dev(self, dom, h):
        base = f"backend/vif/{dom}/{h}"
        for k in [k for k in self.kv if k.startswith(base + "/")]:
            del self.kv[k]
        self.fire(base)


def wait_for(cond, what, timeout=5.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            return
        time.sleep(0.05)
    print("FAIL: timeout waiting for", what)
    sys.exit(1)


def main():
    d = tempfile.mkdtemp()
    sock, log = os.path.join(d, "xs.sock"), os.path.join(d, "calls.log")
    for name, body in (("up.sh", '[ "$1" = vif9.0 ] && exit 1\necho "up $*" >> %s\n' % log),
                       ("down.sh", 'echo "down $*" >> %s\n' % log)):
        p = os.path.join(d, name)
        open(p, "w").write("#!/bin/sh\n" + body)
        os.chmod(p, 0o755)

    xs = FakeXenstore(sock)
    xs.add_dev(5, 0, "10.137.0.99")  # present before qvif starts
    q = subprocess.Popen(["./qvif", "-v", "-s", sock, "-u", os.path.join(d, "up.sh"),
                          "-D", os.path.join(d, "down.sh")], stderr=subprocess.PIPE, text=True)

    def calls():
        return open(log).read().splitlines() if os.path.exists(log) else []

    wait_for(lambda: "up vif5.0 10.137.0.99" in calls(), "initial up")
    wait_for(lambda: xs.kv.get("backend/vif/5/0/hotplug-status") == "connected", "hotplug-status 5/0")
    print("ok: existing device brought up, hotplug-status=connected")

    xs.add_dev(7, 1, "10.137.0.100 10.137.0.101")
    wait_for(lambda: "up vif7.1 10.137.0.100 10.137.0.101" in calls(), "dynamic up with 2 ips")
    wait_for(lambda: xs.kv.get("backend/vif/7/1/hotplug-status") == "connected", "hotplug-status 7/1")
    print("ok: hot-added device with two IPs")

    xs.add_dev(9, 0, "10.137.0.50")  # up.sh fails for vif9.0
    wait_for(lambda: xs.kv.get("backend/vif/9/0/hotplug-status") == "error", "error status")
    assert xs.kv.get("backend/vif/9/0/hotplug-error"), "hotplug-error not written"
    print("ok: failing up script -> hotplug-status=error")

    xs.add_dev(11, 0, "10.137.0.60; rm -rf /")  # hostile ip value must be sanitised
    wait_for(lambda: any(c.startswith("up vif11.0") for c in calls()), "sanitised up")
    assert "up vif11.0 10.137.0.60 " in calls() or "up vif11.0 10.137.0.60" in calls(), calls()
    assert not any("rm" in c for c in calls())
    print("ok: hostile ip value sanitised")

    xs.set("backend/vif/5/0/state", "5")  # Closing
    wait_for(lambda: "down vif5.0 10.137.0.99" in calls(), "down on Closing")
    print("ok: Closing -> down script")

    xs.remove_dev(7, 1)
    wait_for(lambda: "down vif7.1 10.137.0.100 10.137.0.101" in calls(), "down on removal")
    print("ok: removed node -> down script")

    time.sleep(0.5)
    n = len(calls())
    xs.set("backend/vif/5/0/state", "6")  # Closed: must not run down twice
    time.sleep(0.5)
    assert len(calls()) == n, "duplicate calls: %s" % calls()
    assert q.poll() is None, "qvif exited unexpectedly"
    print("ok: no duplicate down calls, helper still running")

    q.terminate()
    q.wait()
    print("calls:", *calls(), sep="\n  ")
    print("ALL PASSED")


main()
