#!/usr/bin/env python3
"""Serves a Flutter web build with single page app fallback (unknown paths return index.html).

    python3 tool/serve_spa.py <build_dir> <port>
"""
import http.server
import os
import sys

root = os.path.abspath(sys.argv[1])
port = int(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)

    def do_GET(self):
        path = self.translate_path(self.path.split('?')[0])
        if not os.path.exists(path) or os.path.isdir(path) and not os.path.exists(os.path.join(path, 'index.html')):
            self.path = '/index.html'
        super().do_GET()

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
