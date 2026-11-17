#!/usr/bin/env python3
"""XHTTP Manager per-instance local subscription HTTP endpoint."""
import http.server
import socketserver
import os
import sys
from urllib.parse import unquote

port = int(sys.argv[1])
token = sys.argv[2]
root = sys.argv[3]
files = {
    "clmi.yaml": "application/yaml; charset=utf-8",
    "sbox.json": "application/json; charset=utf-8",
    "jhsub.txt": "text/plain; charset=utf-8",
}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = [unquote(p) for p in self.path.split("?", 1)[0].split("/") if p]
        if len(parts) != 2 or parts[0] != token or parts[1] not in files:
            self.send_error(404)
            return
        path = os.path.join(root, parts[1])
        try:
            with open(path, "rb") as stream:
                payload = stream.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", files[parts[1]])
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
