#!/usr/bin/env python3
"""Loopback-only preview with the prepared response headers and GitHub-style custom 404s.

These headers are local preview behavior. GitHub Pages does not read the JSON file.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json

repo = Path(__file__).resolve().parents[1]
headers = json.loads((repo/'deployment/security-headers.json').read_text())

class Website(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        resolved = Path(super().translate_path(path))
        # GitHub Pages also serves extensionless HTML routes such as NFC /tap.
        if not resolved.exists() and resolved.with_suffix('.html').is_file():
            return str(resolved.with_suffix('.html'))
        return str(resolved)
    def guess_type(self, path):
        if Path(path).name == 'apple-app-site-association': return 'application/json'
        return super().guess_type(path)
    def end_headers(self):
        for name,value in headers.items():
            # HSTS belongs on the eventual HTTPS host, not this HTTP loopback preview.
            if name != 'Strict-Transport-Security': self.send_header(name,value)
        super().end_headers()
    def list_directory(self,path):
        self.send_error(404)
        return None
    def send_error(self,code,message=None,explain=None):
        if code != 404: return super().send_error(code,message,explain)
        content=(repo/'docs/404.html').read_bytes()
        self.send_response(404)
        self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Content-Length',str(len(content)))
        self.end_headers()
        if self.command!='HEAD': self.wfile.write(content)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=8765)
    args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),partial(Website,directory=str(repo/'docs')))
    print(f'Preview: http://localhost:{args.port}/ (local only; not a production server)',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: server.server_close()
