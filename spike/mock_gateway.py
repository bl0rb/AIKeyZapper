#!/usr/bin/env python3
"""Minimal Anthropic-compatible mock gateway for the apiKeyHelper spike.

Logs per request: path, which auth headers are present, and whether the value
matches a known *test* key. Real values are never logged. Keys listed in
REVOKED get HTTP 401 (simulates a server-side revoked key)."""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("MOCK_LOG", "mock.log")
REVOKED = set(filter(None, os.environ.get("MOCK_REVOKED", "").split(",")))

def label(v):
    if v is None: return "-"
    v = v.removeprefix("Bearer ").strip()
    if v.startswith("sk-test-"): return v
    if not v: return "EMPTY"
    if v.startswith("sk-ant-oat"): return "OAUTH-TOKEN"
    if v.startswith("sk-ant-"): return "ANTHROPIC-KEY"
    return f"OTHER(len={len(v)})"

SSE = [
 ("message_start", {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"mock","content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":1,"output_tokens":1}}}),
 ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
 ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}),
 ("content_block_stop", {"type":"content_block_stop","index":0}),
 ("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":1}}),
 ("message_stop", {"type":"message_stop"}),
]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        xk, au = label(self.headers.get("x-api-key")), label(self.headers.get("authorization"))
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.path.split('?')[0]} x-api-key={xk} authorization={au}\n")
        if xk in REVOKED or au in REVOKED:
            self.send_response(401); self.send_header("content-type","application/json"); self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"revoked"}}'); return
        try: stream = json.loads(body or b"{}").get("stream", False)
        except Exception: stream = False
        if "count_tokens" in self.path:
            out = b'{"input_tokens":1}'; self.send_response(200); self.send_header("content-type","application/json"); self.end_headers(); self.wfile.write(out); return
        if stream:
            self.send_response(200); self.send_header("content-type","text/event-stream"); self.end_headers()
            for ev, d in SSE: self.wfile.write(f"event: {ev}\ndata: {json.dumps(d)}\n\n".encode())
        else:
            msg = dict(SSE[0][1]["message"], content=[{"type":"text","text":"OK"}], stop_reason="end_turn")
            out = json.dumps(msg).encode(); self.send_response(200); self.send_header("content-type","application/json"); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1] if len(sys.argv) > 1 else 18471)), H).serve_forever()
