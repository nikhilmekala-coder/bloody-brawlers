#!/usr/bin/env python3
"""Simple HTTP server with COOP/COEP headers for Godot web export."""
import http.server
import sys

class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
print(f"Serving on http://0.0.0.0:{port} with COOP/COEP headers...")
http.server.HTTPServer(("0.0.0.0", port), CORSHandler).serve_forever()
