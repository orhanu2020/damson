"""Tiny local HTTP server Damson talks to: POST /run {name, role, command} -> {reply}."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import graph

PORT = 8765


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, {"ok": True, "engine": "langgraph"})

    def do_POST(self):
        if self.path != "/run":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n))
            self._send(200, {"reply": graph.run(req["name"], req.get("role", ""), req["command"])})
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"error": str(exc)})

    def log_message(self, fmt, *args):
        sys.stderr.write("[agents] " + fmt % args + "\n")


if __name__ == "__main__":
    print(f"Damson agents (LangGraph) listening on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
