#!/usr/bin/env python3
"""Local HTTP responses for model-download regression tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"lmgg" + b"\0" * 128
        status = 200
        if self.path == "/empty":
            body = b""
        elif self.path == "/html":
            body = b"<html>upstream error page</html>"
        elif self.path == "/partial":
            status = 206
        elif self.path == "/slow":
            body = b"lmgg" + b"\0" * (1024 * 1024)
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            if self.path == "/slow":
                for start in range(0, len(body), 4096):
                    self.wfile.write(body[start:start + 4096])
                    self.wfile.flush()
                    time.sleep(0.02)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
