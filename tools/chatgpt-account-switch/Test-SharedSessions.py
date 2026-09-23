"""Offline compatibility check against installed codex app-server.

Synthetic sessions and fake credentials only. Requests go to a local HTTP
fixture that returns a preset error; no real model is called.
"""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import stat
import argparse
import base64
import gzip
import signal
import zstandard
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(description="Check shared sessions using a selected Codex backend.")
parser.add_argument("--codex", default=shutil.which("codex"), help="Path to the app's actual codex.exe or a CLI binary")
parser.add_argument("--active", choices=["Lab", "Personal", "AccountTwo"], help="Run one route for diagnosis")
args = parser.parse_args()
if not args.codex or not Path(args.codex).is_file():
    parser.error("A readable codex executable is required")

requests = queue.Queue()


class Endpoint(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": "gpt-5.5", "object": "model", "created": 0, "owned_by": "fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        elif self.headers.get("Content-Encoding") == "zstd":
            body = zstandard.ZstdDecompressor().decompress(body, max_output_size=16 * 1024 * 1024)
        requests.put((self.path, json.loads(body)))
        # Deliberately end the turn at the transport boundary. No model or tools run.
        response = b'{"error":{"message":"Offline fixture received request","type":"invalid_request_error","code":"fixture_complete"}}'
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_):
        pass


class AppServer:
    def __init__(self, home, cwd, endpoint):
        env = os.environ.copy()
        env.update(CODEX_HOME=str(home))
        env.pop("OPENAI_BASE_URL", None)
        env.pop("CODEX_SQLITE_HOME", None)
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_APP_SERVER_OPENAI_BASE_URL"] = endpoint
        env["CODEX_APP_SERVER_CHATGPT_BASE_URL"] = endpoint
        self.process = subprocess.Popen(
            [args.codex, "app-server", "--stdio"],
            cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            start_new_session=os.name != "nt",
        )
        self.messages = queue.Queue()
        self.errors = []
        self.counter = 0
        threading.Thread(target=self._read, daemon=True).start()
        self.call("initialize", {"clientInfo": {"name": "provider_fixture", "version": "1"}})
        self.process.stdin.write('{"method":"initialized","params":{}}\n')
        self.process.stdin.flush()

    def _read(self):
        for line in self.process.stdout:
            try:
                message = json.loads(line)
                if message.get("method") == "error":
                    self.errors.append(message.get("params", {}).get("error", {}).get("message", "Backend error"))
                self.messages.put(message)
            except json.JSONDecodeError:
                pass

    def call(self, method, params):
        self.counter += 1
        request_id = self.counter
        self.process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.1, deadline - time.monotonic()))
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise AssertionError(f"{method}: {message['error']}")
            return message["result"]
        raise AssertionError(f"Timed out: {method}")

    def close(self):
        # Also stop helper processes created by this isolated server.
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           creationflags=subprocess.CREATE_NO_WINDOW)
        else:
            # This process group is created solely by this isolated test.
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.process.wait(timeout=10)


parent = Path(tempfile.gettempdir()).resolve()
root = Path(tempfile.mkdtemp(prefix="provider-sessions-test-", dir=parent)).resolve()
assert root.parent == parent and root.name.startswith("provider-sessions-test-")
http = ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
threading.Thread(target=http.serve_forever, daemon=True).start()
try:
    home = root / "shared"
    project = root / "project"
    project.mkdir()
    sessions = home / "sessions" / "2026" / "09" / "05"
    sessions.mkdir(parents=True)
    (home / "auth.json").write_text(json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "FAKE_LOCAL_TEST_ONLY"}))
    ids = {}
    for provider in ("Personal", "Lab", "AccountTwo"):
        thread_id = str(uuid.uuid4())
        ids[provider] = thread_id
        timestamp = "2026-09-05T00:00:00Z"
        records = [
            {"timestamp": timestamp, "type": "session_meta", "payload": {
                "id": thread_id, "timestamp": timestamp, "cwd": str(project),
                "originator": "codex_cli_rs", "cli_version": "0.0.0",
                "source": "cli", "model_provider": "openai",
            }},
            {"timestamp": timestamp, "type": "response_item", "payload": {
                "type": "message", "role": "user", "content": [{"type": "input_text", "text": "Shared fixture history"}],
            }},
            {"timestamp": timestamp, "type": "event_msg", "payload": {
                "type": "user_message", "message": "Shared fixture history", "images": [], "local_images": [],
            }},
        ]
        (sessions / f"rollout-2026-09-05T00-00-00-{thread_id}.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8"
        )

    for active in ([args.active] if args.active else ["Lab", "Personal", "AccountTwo"]):
        endpoint = f"http://127.0.0.1:{http.server_port}/{active.lower()}"
        if active == "AccountTwo":
            claims = {"sub": "FAKE_USER_LOCAL_TEST_ONLY", "email": "fixture@example.invalid", "exp": int(time.time()) + 3600,
                      "https://api.openai.com/auth": {"chatgpt_account_id": "FAKE_ACCOUNT_LOCAL_TEST_ONLY", "chatgpt_plan_type": "plus"}}
            payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
            auth = {"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": {
                "id_token": "eyJhbGciOiJub25lIn0." + payload + ".FAKE_LOCAL_TEST_ONLY",
                "access_token": "FAKE_ACCESS_LOCAL_TEST_ONLY", "refresh_token": "FAKE_REFRESH_LOCAL_TEST_ONLY",
                "account_id": "FAKE_ACCOUNT_LOCAL_TEST_ONLY"}, "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        else:
            auth = {"auth_mode": "apikey", "OPENAI_API_KEY": "FAKE_LOCAL_TEST_ONLY"}
        (home / "auth.json").write_text(json.dumps(auth), encoding="utf-8")
        config = '\n'.join([
            'model = "gpt-5.5"', 'model_provider = "openai"',
            f'openai_base_url = "{endpoint}"',
            'cli_auth_credentials_store = "file"',
            '[features]', 'plugins = false', 'remote_plugin = false',
            '[analytics]', 'enabled = false',
        ]) + '\n'
        (home / "config.toml").write_text(config, encoding="utf-8")
        server = AppServer(home, project, endpoint)
        try:
            for thread_id in ids.values():
                server.call("thread/read", {"threadId": thread_id, "includeTurns": True})
            listed = server.call("thread/list", {"limit": 100, "sourceKinds": ["cli"], "modelProviders": None})
            visible = {item["id"] for item in listed["data"]}
            assert set(ids.values()).issubset(visible), (active, "sessions missing", visible)
            print(f"PASS: {active} lists sessions created by all three profiles.", flush=True)
            for origin, thread_id in ids.items():
                read = server.call("thread/read", {"threadId": thread_id, "includeTurns": True})
                assert read["thread"]["id"] == thread_id
                assert "Shared fixture history" in json.dumps(read)
                resumed = server.call("thread/resume", {"threadId": thread_id, "sandbox": "read-only", "approvalPolicy": "never"})
                selected = resumed.get("modelProvider", resumed["thread"].get("modelProvider"))
                print(f"RESUME: origin={origin}, active={active}, selected={selected}", flush=True)
                assert selected == "openai", "Resume did not keep the shared provider identity"
                assert resumed["thread"]["id"] == thread_id
                assert resumed["thread"]["cwd"] == str(project)
                server.call("turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": "Offline transport fixture"}]})
                try:
                    path, sent = requests.get(timeout=60)
                except queue.Empty:
                    raise AssertionError(f"No request reached local fixture: {server.errors[-3:]}") from None
                assert path.startswith(f"/{active.lower()}/") and path.endswith("/responses"), path
                assert "Shared fixture history" in json.dumps(sent), "Previous conversation was not sent to the selected endpoint"
                print(f"PASS: actual HTTP request with prior history reached {active} endpoint.", flush=True)
                print(f"PASS: same session ID, history, project and active provider survive resume ({origin}).", flush=True)
        finally:
            server.close()
finally:
    http.shutdown()
    http.server_close()
    if root.parent != parent or not root.name.startswith("provider-sessions-test-"):
        raise RuntimeError("Refusing cleanup outside the test directory")
    def remove_readonly(func, name, error):
        target = Path(name).resolve()
        if not target.is_relative_to(root):
            raise RuntimeError("Refusing cleanup outside the test directory")
        if not isinstance(error, PermissionError):
            raise error
        os.chmod(target, stat.S_IWRITE | stat.S_IREAD)
        func(target)
    shutil.rmtree(root, onexc=remove_readonly)
print("Shared session app-server tests passed.")
