#!/usr/bin/env python3

import argparse
import codecs
import json
import os
import queue
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


REQUEST_EXCLUDED_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}
RESPONSE_EXCLUDED_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}
SPECIAL_RESPONSE_MARKERS = (
    "<|channel|>analysis<|message|>",
    "<|channel|>final<|message|>",
    "<|return|>",
)


def get_min_output_tokens():
    try:
        return max(64, int(os.environ.get("LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS", "1024")))
    except (TypeError, ValueError):
        return 1024


def build_models_payload(model_ids):
    return {
        "object": "list",
        "data": [
            {
                "id": model_id,
                "object": "model",
                "created": 0,
                "owned_by": "local-codex-kit",
            }
            for model_id in model_ids
        ],
    }


def flatten_content(value):
    if value is None:
        return ""

    if isinstance(value, str):
        return value

    if isinstance(value, list):
        parts = [flatten_content(item) for item in value]
        return "\n".join(part for part in parts if part)

    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return value["text"]
        if "content" in value:
            return flatten_content(value["content"])

        item_type = value.get("type")
        if item_type in {"function_call_output", "computer_call_output"}:
            return flatten_content(value.get("output"))
        if item_type in {"function_call", "computer_call", "tool_call"}:
            tool_name = value.get("name") or value.get("call_id") or item_type
            tool_args = flatten_content(value.get("arguments") or value.get("input"))
            return f"[{tool_name}: {tool_args}]"
        if item_type in {"input_image", "image", "image_url", "reasoning"}:
            return ""

        return json.dumps(value, ensure_ascii=False)

    if isinstance(value, (int, float, bool)):
        return str(value)

    return ""


def normalize_input_item(item):
    if isinstance(item, dict):
        normalized = dict(item)
        normalized["content"] = flatten_content(normalized.get("content"))
        if "role" not in normalized and normalized.get("type") == "message":
            normalized["role"] = "user"
        normalized.pop("type", None)
        return normalized

    return item


def normalize_responses_payload(payload):
    if not isinstance(payload, dict):
        return payload

    normalized = dict(payload)
    if "instructions" in normalized:
        normalized["instructions"] = flatten_content(normalized.get("instructions"))

    input_value = normalized.get("input")
    if isinstance(input_value, list):
        normalized["input"] = [normalize_input_item(item) for item in input_value]
    elif isinstance(input_value, dict):
        normalized["input"] = normalize_input_item(input_value)
    elif isinstance(input_value, str):
        normalized["input"] = input_value
    elif input_value is not None:
        normalized["input"] = flatten_content(input_value)

    min_output_tokens = get_min_output_tokens()
    current_max_output_tokens = normalized.get("max_output_tokens")
    if current_max_output_tokens is None:
        normalized["max_output_tokens"] = min_output_tokens
    else:
        try:
            normalized["max_output_tokens"] = max(int(current_max_output_tokens), min_output_tokens)
        except (TypeError, ValueError):
            normalized["max_output_tokens"] = min_output_tokens

    return normalized


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self._handle_request()

    def do_POST(self):
        self._handle_request()

    def do_PUT(self):
        self._handle_request()

    def do_PATCH(self):
        self._handle_request()

    def do_DELETE(self):
        self._handle_request()

    def do_OPTIONS(self):
        self._handle_request()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _handle_request(self):
        request_path = self.path.split("?", 1)[0]
        if self.command == "GET" and request_path == "/healthz":
            self._write_json(200, {"status": "ok"})
            return

        if self.command == "GET" and request_path == "/v1/models":
            self._write_json(200, self.server.models_payload)
            return

        self._proxy_request()

    def _proxy_request(self):
        content_length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(content_length) if content_length > 0 else None
        request_path = self.path.split("?", 1)[0]
        content_type = self.headers.get("Content-Type", "")
        if (
            body
            and request_path == "/v1/responses"
            and "application/json" in content_type.lower()
        ):
            try:
                payload = json.loads(body.decode("utf-8"))
                payload = normalize_responses_payload(payload)
                body = json.dumps(payload).encode("utf-8")
            except Exception:
                pass
        upstream_url = self.server.upstream_base.rstrip("/") + self.path
        upstream_request = urllib.request.Request(
            upstream_url,
            data=body,
            method=self.command,
        )

        for header_name, header_value in self.headers.items():
            if header_name.lower() in REQUEST_EXCLUDED_HEADERS:
                continue
            upstream_request.add_header(header_name, header_value)

        try:
            with urllib.request.urlopen(upstream_request, timeout=self.server.request_timeout_sec) as upstream_response:
                self._relay_response(
                    status_code=getattr(upstream_response, "status", 200),
                    headers=upstream_response.headers,
                    response=upstream_response,
                    request_path=request_path,
                )
        except urllib.error.HTTPError as exc:
            self._relay_response(
                status_code=exc.code,
                headers=exc.headers,
                response=exc,
                request_path=request_path,
            )
        except Exception as exc:
            self._write_json(502, {"error": {"message": str(exc), "type": "proxy_error"}})

    def _relay_response(self, status_code, headers, response, request_path=""):
        content_type = headers.get("Content-Type", "")
        self.send_response(status_code)
        for header_name, header_value in headers.items():
            if header_name.lower() in RESPONSE_EXCLUDED_HEADERS:
                continue
            self.send_header(header_name, header_value)
        self.end_headers()

        if "text/event-stream" in content_type.lower():
            self._relay_sse_response(response, request_path=request_path)
            return

        while True:
            chunk = self._read_response_chunk(response, 65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def _read_response_chunk(self, response, chunk_size):
        read1 = getattr(response, "read1", None)
        if callable(read1):
            return read1(chunk_size)
        return response.read(chunk_size)

    def _relay_sse_response(self, response, request_path=""):
        sentinel = object()
        chunks = queue.Queue()

        def _reader():
            try:
                while True:
                    chunk = self._read_response_chunk(response, 1024)
                    if not chunk:
                        break
                    chunks.put(chunk)
            except Exception as exc:
                chunks.put(exc)
            finally:
                chunks.put(sentinel)

        threading.Thread(target=_reader, daemon=True).start()

        self.wfile.write(b": keep-alive\n\n")
        self.wfile.flush()
        decoder = codecs.getincrementaldecoder("utf-8")()
        buffer = ""

        while True:
            try:
                item = chunks.get(timeout=self.server.sse_keepalive_interval_sec)
            except queue.Empty:
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
                continue

            if item is sentinel:
                break

            if isinstance(item, Exception):
                break

            buffer += decoder.decode(item)
            buffer = self._flush_sse_buffer(buffer, request_path=request_path)

        buffer += decoder.decode(b"", final=True)
        self._flush_sse_buffer(buffer, request_path=request_path, flush_all=True)

    def _flush_sse_buffer(self, buffer, request_path="", flush_all=False):
        while True:
            separator_index = buffer.find("\n\n")
            if separator_index < 0:
                if flush_all and buffer:
                    self._write_sse_event(buffer, request_path=request_path)
                    return ""
                return buffer

            event_block = buffer[:separator_index]
            buffer = buffer[separator_index + 2 :]
            self._write_sse_event(event_block, request_path=request_path)

    def _write_sse_event(self, event_block, request_path="", force=False):
        processed_event = event_block if force else self._process_sse_event(event_block, request_path=request_path)
        if processed_event is None:
            return

        payload = processed_event.encode("utf-8", errors="replace") + b"\n\n"
        self.wfile.write(payload)
        self.wfile.flush()

    def _process_sse_event(self, event_block, request_path=""):
        stripped = event_block.strip()
        if not stripped:
            return None

        if request_path != "/v1/responses":
            return event_block

        for line in stripped.splitlines():
            if not line.startswith("data:"):
                continue

            payload_text = line[5:].strip()
            if not payload_text:
                continue

            try:
                payload = json.loads(payload_text)
            except json.JSONDecodeError:
                return event_block

            self._sanitize_response_event(payload)
            return "data: " + json.dumps(payload, ensure_ascii=False)

        return event_block

    def _sanitize_response_event(self, payload):
        event_type = payload.get("type")
        if event_type == "response.output_text.delta":
            payload["delta"] = self._sanitize_text(payload.get("delta", ""))
            return

        if event_type == "response.output_text.done":
            payload["text"] = self._sanitize_text(payload.get("text", ""))
            return

        if event_type == "response.content_part.done":
            part = payload.get("part")
            if isinstance(part, dict):
                part["text"] = self._sanitize_text(part.get("text", ""))
            return

        if event_type == "response.output_item.done":
            self._sanitize_output_item(payload.get("item"))
            return

        if event_type in {"response.created", "response.in_progress", "response.completed"}:
            response = payload.get("response")
            if isinstance(response, dict):
                response["model"] = self.server.primary_model_id
                for output_item in response.get("output") or []:
                    self._sanitize_output_item(output_item)

    def _sanitize_output_item(self, item):
        if not isinstance(item, dict):
            return
        for content_item in item.get("content") or []:
            if isinstance(content_item, dict) and isinstance(content_item.get("text"), str):
                content_item["text"] = self._sanitize_text(content_item["text"])

    def _sanitize_text(self, value):
        if not isinstance(value, str):
            return value
        sanitized = value
        for marker in SPECIAL_RESPONSE_MARKERS:
            sanitized = sanitized.replace(marker, "")
        return sanitized

    def _write_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()


def parse_args():
    parser = argparse.ArgumentParser(description="Small OpenAI-compatible proxy for local-codex-kit.")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-base", required=True)
    parser.add_argument("--model-id", action="append", dest="model_ids", required=True)
    parser.add_argument("--request-timeout-sec", type=int, default=600)
    parser.add_argument("--sse-keepalive-interval-sec", type=int, default=15)
    return parser.parse_args()


def main():
    args = parse_args()
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), ProxyHandler)
    server.daemon_threads = True
    server.upstream_base = args.upstream_base.rstrip("/")
    server.models_payload = build_models_payload(args.model_ids)
    server.primary_model_id = args.model_ids[0]
    server.request_timeout_sec = args.request_timeout_sec
    server.sse_keepalive_interval_sec = args.sse_keepalive_interval_sec
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
