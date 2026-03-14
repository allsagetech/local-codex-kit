import http.client
import importlib.util
import json
import os
import pathlib
import threading
import time
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PROXY_PATH = REPO_ROOT / "codex-openai-proxy.py"


def load_proxy_module():
    spec = importlib.util.spec_from_file_location("codex_openai_proxy", PROXY_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def environment(overrides):
    previous = {key: os.environ.get(key) for key in overrides}
    try:
        for key, value in overrides.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextmanager
def running_server(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class ProxyTests(unittest.TestCase):
    def test_proxy_normalizes_responses_payload_before_forwarding(self):
        proxy_module = load_proxy_module()
        observed = {}

        class UpstreamHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                content_length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(content_length)
                observed["path"] = self.path
                observed["payload"] = json.loads(body.decode("utf-8"))

                response_body = json.dumps({"ok": True}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        proxy = proxy_module.ThreadingHTTPServer(("127.0.0.1", 0), proxy_module.ProxyHandler)
        proxy.daemon_threads = True
        proxy.upstream_base = f"http://127.0.0.1:{upstream.server_address[1]}"
        proxy.models_payload = proxy_module.build_models_payload(["openai/gpt-oss-20b"])
        proxy.primary_model_id = "openai/gpt-oss-20b"
        proxy.request_timeout_sec = 5
        proxy.sse_keepalive_interval_sec = 1

        payload = {
            "instructions": [{"text": "system rules"}],
            "input": [
                {"type": "message", "content": [{"text": "hello"}]},
                {"role": "user", "content": [{"type": "input_text", "text": "world"}]},
            ],
        }

        with environment({"LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS": "256"}):
            with running_server(upstream), running_server(proxy):
                connection = http.client.HTTPConnection("127.0.0.1", proxy.server_address[1], timeout=5)
                try:
                    connection.request(
                        "POST",
                        "/v1/responses",
                        body=json.dumps(payload),
                        headers={"Content-Type": "application/json"},
                    )
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    response.read()
                finally:
                    connection.close()

        self.assertEqual(observed["path"], "/v1/responses")
        self.assertEqual(observed["payload"]["instructions"], "system rules")
        self.assertEqual(observed["payload"]["input"][0]["content"], "hello")
        self.assertEqual(observed["payload"]["input"][0]["role"], "user")
        self.assertEqual(observed["payload"]["input"][1]["content"], "world")
        self.assertEqual(observed["payload"]["max_output_tokens"], 256)

    def test_proxy_streams_sse_events_without_waiting_for_response_end(self):
        proxy_module = load_proxy_module()

        class UpstreamHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                for index in range(3):
                    payload = {"type": "response.output_text.delta", "delta": f"t{index}"}
                    self.wfile.write((f"data: {json.dumps(payload)}\n\n").encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.2)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        proxy = proxy_module.ThreadingHTTPServer(("127.0.0.1", 0), proxy_module.ProxyHandler)
        proxy.daemon_threads = True
        proxy.upstream_base = f"http://127.0.0.1:{upstream.server_address[1]}"
        proxy.models_payload = proxy_module.build_models_payload(["openai/gpt-oss-20b"])
        proxy.primary_model_id = "openai/gpt-oss-20b"
        proxy.request_timeout_sec = 5
        proxy.sse_keepalive_interval_sec = 1

        with running_server(upstream), running_server(proxy):
            connection = http.client.HTTPConnection("127.0.0.1", proxy.server_address[1], timeout=5)
            try:
                start = time.perf_counter()
                connection.request(
                    "POST",
                    "/v1/responses",
                    body=json.dumps({"input": "hi"}),
                    headers={"Content-Type": "application/json"},
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 200)

                first_data_at = None
                while True:
                    line = response.fp.readline()
                    if not line:
                        break
                    if line.startswith(b"data:"):
                        first_data_at = time.perf_counter() - start
                        break
            finally:
                connection.close()

        self.assertIsNotNone(first_data_at)
        self.assertLess(first_data_at, 0.35, f"first data event arrived too late: {first_data_at:.3f}s")


if __name__ == "__main__":
    unittest.main()
