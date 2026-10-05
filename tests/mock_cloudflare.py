#!/usr/bin/env python3
"""Tiny stand-in for the Cloudflare v4 API (zones, tunnels, DNS) used by tests/cloudflare.bats."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
STATE = {"tunnels": [], "dns": [], "calls": []}

def ok(result): return {"success": True, "errors": [], "result": result}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body):
        data = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n) or b"{}")
    def _route(self, method):
        if self.headers.get("Authorization") != "Bearer goodtoken":
            return self._send(403, {"success": False, "errors": [{"message": "bad token"}]})
        p, _, q = self.path.partition("?"); STATE["calls"].append(f"{method} {p}")
        if p == "/__state": return self._send(200, STATE)
        if p == "/zones": return self._send(200, ok([{"id": "ZONE1", "account": {"id": "ACCT1"}}] if "name=example.org" in q else []))
        if p == "/accounts/ACCT1/cfd_tunnel" and method == "GET": return self._send(200, ok(STATE["tunnels"]))
        if p == "/accounts/ACCT1/cfd_tunnel" and method == "POST":
            t = {"id": "TUN1", "name": self._body()["name"]}; STATE["tunnels"].append(t); return self._send(200, ok(t))
        if p == "/accounts/ACCT1/cfd_tunnel/TUN1/configurations" and method == "PUT":
            STATE["config"] = self._body(); return self._send(200, ok({}))
        if p == "/accounts/ACCT1/cfd_tunnel/TUN1/token": return self._send(200, ok("TUNNEL-TOKEN-XYZ"))
        if p == "/zones/ZONE1/dns_records" and method == "GET":
            name = q.split("name=")[1].split("&")[0]; return self._send(200, ok([r for r in STATE["dns"] if r["name"] == name]))
        if p == "/zones/ZONE1/dns_records" and method == "POST":
            r = self._body(); r["id"] = f"R{len(STATE['dns'])+1}"; STATE["dns"].append(r); return self._send(200, ok(r))
        if p.startswith("/zones/ZONE1/dns_records/") and method == "PUT":
            rid = p.rsplit("/", 1)[1]; r = self._body(); r["id"] = rid
            STATE["dns"] = [r if x["id"] == rid else x for x in STATE["dns"]]; return self._send(200, ok(r))
        self._send(404, {"success": False, "errors": [{"message": "no route " + p}]})
    def do_GET(self): self._route("GET")
    def do_POST(self): self._route("POST")
    def do_PUT(self): self._route("PUT")

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
