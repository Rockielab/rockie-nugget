#!/usr/bin/env python3
# nothink-proxy.py — minimal OpenAI-compatible passthrough that disables the
# upstream model's thinking mode so multi-turn tool-calling harnesses (goose,
# older codex) can drive it without the reasoning_content round-trip 400.
# Generic: upstream base + key come from env. No provider identity baked in.
import json, os, urllib.request, http.server, socketserver
UPSTREAM = os.environ["UPSTREAM_BASE_URL"].rstrip("/")
KEY = os.environ["UPSTREAM_API_KEY"]
PORT = int(os.environ.get("PROXY_PORT", "8088"))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _proxy(self, method):
        body = b""
        if "Content-Length" in self.headers:
            body = self.rfile.read(int(self.headers["Content-Length"]))
        # inject thinking-disabled on chat/completions
        if body and self.path.endswith("/chat/completions"):
            try:
                d = json.loads(body)
                d["thinking"] = {"type": "disabled"}
                body = json.dumps(d).encode()
            except Exception:
                pass
        url = UPSTREAM + self.path
        req = urllib.request.Request(url, data=body if method=="POST" else None, method=method)
        req.add_header("Authorization", f"Bearer {KEY}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                data = r.read(); code = r.status
        except urllib.error.HTTPError as e:
            data = e.read(); code = e.code
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self): self._proxy("POST")
    def do_GET(self): self._proxy("GET")

socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H) as s:
    print(f"nothink-proxy on 127.0.0.1:{PORT} -> {UPSTREAM}", flush=True)
    s.serve_forever()
