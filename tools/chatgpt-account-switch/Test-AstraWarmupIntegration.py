"""Verify the real Codex hook boundary with native code and fake loopback requests.

Only this disposable test home receives explicit trust for the vetted fixture
handler. Neither the installer nor the shipped hook writes trust records.
"""
import argparse
import gzip
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import zstandard


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', default=shutil.which('codex'))
    parser.add_argument('--mac-driver', help='Test-only Swift WarmupFixture executable')
    args = parser.parse_args()
    if not args.codex or not Path(args.codex).is_file():
        parser.error('Official Codex executable required')
    if os.name != 'nt' and not args.mac_driver:
        parser.error('--mac-driver is required on macOS')
    if os.name == 'nt':
        # Malformed input must be rejected before any real auth/home is read.
        entry = Path(__file__).resolve().with_name('Invoke-AstraWarmup.ps1')
        smoke = subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
                                '-ExecutionPolicy', 'Bypass', '-File', str(entry)], input=b'{broken',
                               capture_output=True, timeout=10, check=True,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        assert not smoke.stderr and json.loads(smoke.stdout)['decision'] == 'block'
    requests = []
    response_mode = {'fail': False}

    class Endpoint(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def do_GET(self):
            # The official runtime may try WebSocket before HTTP fallback.
            self.send_error(426, 'Loopback fixture uses HTTP streaming only')

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if self.headers.get('Content-Encoding') == 'gzip':
                raw = gzip.decompress(raw)
            elif self.headers.get('Content-Encoding') == 'zstd':
                raw = zstandard.ZstdDecompressor().decompress(raw, max_output_size=16 * 1024 * 1024)
            body = json.loads(raw)
            requests.append((self.path, body))
            if body.get('model') == 'gpt-5.6-sol':
                response = {'id': 'resp_fixture', 'object': 'response', 'created_at': 0,
                            'model': 'gpt-5.6-sol', 'status': 'failed' if response_mode['fail'] else 'completed',
                            'output': [], 'error': {'message': 'FAKE_PRIVATE_ERROR', 'code': 'fixture'} if response_mode['fail'] else None,
                            'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
                kind = 'response.failed' if response_mode['fail'] else 'response.completed'
                payload = ('event: ' + kind + '\ndata: ' + json.dumps({'type': kind, 'response': response}) + '\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
            else:
                # Stop at transport; no real model or tools run.
                payload = b'{"error":{"message":"Offline fixture received Astra","type":"invalid_request_error"}}'
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Connection', 'close')
            self.close_connection = True
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    parent = Path(tempfile.gettempdir()).resolve()
    root = Path(tempfile.mkdtemp(prefix='astra-warmup-integration-', dir=parent)).resolve()
    process = None
    try:
        home, vault, project = root / 'home', root / 'vault', root / 'project'
        for folder in [home, vault, project]:
            folder.mkdir(mode=0o700)
        endpoint = f'http://127.0.0.1:{server.server_port}/v1'
        fake_key = 'FAKE_WARMUP_INTEGRATION_ONLY'
        (home / 'auth.json').write_text(json.dumps({'auth_mode': 'apikey', 'OPENAI_API_KEY': fake_key}), encoding='utf-8')
        (home / 'config.toml').write_text(
            f'model = "gpt-6-astra"\nmodel_provider = "openai"\nopenai_base_url = "{endpoint}"\n'
            'cli_auth_credentials_store = "file"\n[features]\nplugins = false\nremote_plugin = false\n'
            'skip_host_skill_discovery = true\n[analytics]\nenabled = false\n', encoding='utf-8')
        sentinel = project / 'untouched.txt'
        sentinel.write_bytes(b'WORKSPACE_MUST_NOT_CHANGE')
        env = os.environ.copy()
        for name in list(env):
            if name.startswith(('CODEX_', 'OPENAI_')):
                env.pop(name, None)
        env.update(CODEX_HOME=str(home), CODEX_APP_SERVER_OPENAI_BASE_URL=endpoint,
                   CODEX_APP_SERVER_CHATGPT_BASE_URL=endpoint, NO_PROXY='127.0.0.1,localhost',
                   HTTP_PROXY='', HTTPS_PROXY='', ALL_PROXY='')
        creation = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
        if os.name == 'nt':
            def ps_quote(path):
                return "'" + str(path).replace("'", "''") + "'"
            module = Path(__file__).resolve().with_name('AstraWarmup.ps1')
            wrapper = root / 'Invoke-AstraWarmup.ps1'
            wrapper.write_text(
                "$ErrorActionPreference='Stop'\n. " + ps_quote(module) + '\n'
                '$event=[Console]::In.ReadToEnd() | ConvertFrom-Json\n'
                '$result=Invoke-AstraWarmup -HomePath ' + ps_quote(home) + ' -VaultPath ' + ps_quote(vault) + ' -Event $event\n'
                'if ($null -ne $result) { $result | ConvertTo-Json -Compress -Depth 10 }\n', encoding='utf-8-sig')
            setup = '. ' + ps_quote(module) + '; Set-AstraWarmupEnabled -HomePath ' + ps_quote(home) + ' -VaultPath ' + ps_quote(vault) + ' -HookScriptPath ' + ps_quote(wrapper) + ' -Enabled $true -ConfirmCost $true'
            subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', setup],
                           env=env, cwd=project, check=True, capture_output=True, creationflags=creation, timeout=15)
        else:
            env.update(WARMUP_FIXTURE_HOME=str(home), WARMUP_FIXTURE_ROOT=str(vault))
            subprocess.run([str(Path(args.mac_driver).resolve()), '--configure'], env=env, cwd=project,
                           check=True, capture_output=True, timeout=15)
        process = subprocess.Popen([args.codex, 'app-server', '--stdio'], cwd=project, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, encoding='utf-8', creationflags=creation, start_new_session=os.name != 'nt')
        messages = queue.Queue()

        def read():
            for line in process.stdout:
                try:
                    messages.put(json.loads(line))
                except ValueError:
                    pass
        threading.Thread(target=read, daemon=True).start()
        counter = 0

        def call(method, params):
            nonlocal counter
            counter += 1
            process.stdin.write(json.dumps({'id': counter, 'method': method, 'params': params}) + '\n')
            process.stdin.flush()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                message = messages.get(timeout=max(0.1, deadline - time.monotonic()))
                if message.get('id') == counter:
                    if 'error' in message:
                        raise AssertionError(f'{method}: {message["error"]}')
                    return message['result']
            raise AssertionError(f'Timed out: {method}')

        call('initialize', {'clientInfo': {'name': 'astra_warmup_fixture', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        process.stdin.write('{"method":"initialized"}\n'); process.stdin.flush()
        entries = call('hooks/list', {'cwds': [str(project)]})['data']
        handlers = [hook for entry in entries for hook in entry['hooks']]
        assert len(handlers) == 1, 'Expected only the native test handler'
        assert all(not entry.get('errors') for entry in entries), 'Invalid installed hook definition'
        assert handlers[0]['trustStatus'] == 'untrusted', 'Installer must not silently trust hooks'
        # Vetted fixture ONLY: equivalent to reviewing/trusting this exact hash.
        call('config/batchWrite', {'edits': [{'keyPath': 'hooks.state', 'mergeStrategy': 'upsert',
              'value': {handlers[0]['key']: {'trusted_hash': handlers[0]['currentHash']}}}], 'reloadUserConfig': True})

        def start():
            return call('thread/start', {'cwd': str(project), 'model': 'gpt-6-astra', 'sandbox': 'read-only', 'approvalPolicy': 'never'})['thread']['id']

        def turn(thread_id, prompt):
            result = call('turn/start', {'threadId': thread_id, 'input': [{'type': 'text', 'text': prompt}]})
            turn_id = result['turn']['id']
            deadline = time.monotonic() + 45
            hook_status = None
            while time.monotonic() < deadline:
                message = messages.get(timeout=max(0.1, deadline - time.monotonic()))
                params = message.get('params', {})
                if params.get('threadId') != thread_id:
                    continue
                if message.get('method') == 'hook/completed':
                    hook_status = params['run']['status']
                if message.get('method') == 'turn/completed' and params.get('turn', {}).get('id') == turn_id:
                    return hook_status
            raise AssertionError('Native hook/turn did not finish within bounded time')

        thread = start()
        assert turn(thread, 'PRIVATE_ORIGINAL_SENTINEL_FIRST') == 'completed'
        assert [body['model'] for _, body in requests] == ['gpt-5.6-sol', 'gpt-6-astra'], 'Warmup must finish before Astra is submitted'
        warmup = requests[0][1]
        assert warmup['reasoning']['effort'] == 'low'
        assert warmup['input'] == 'Reply only OK.'
        assert warmup['tools'] == [] and warmup['store'] is False
        assert 'PRIVATE_ORIGINAL_SENTINEL' not in json.dumps(warmup)
        assert json.dumps(requests[1][1]).count('PRIVATE_ORIGINAL_SENTINEL_FIRST') == 1
        print('PASS: Native Sol/low warmup precedes the unchanged original Astra request.', flush=True)
        assert turn(thread, 'PRIVATE_ORIGINAL_SENTINEL_SECOND') == 'completed'
        assert [body['model'] for _, body in requests] == ['gpt-5.6-sol', 'gpt-6-astra', 'gpt-6-astra']
        print('PASS: The second message in the same conversation does not repeat warmup.', flush=True)
        response_mode['fail'] = True
        before = len(requests)
        assert turn(start(), 'PRIVATE_ORIGINAL_SENTINEL_BLOCKED') == 'blocked'
        assert len(requests) == before + 1 and requests[-1][1]['model'] == 'gpt-5.6-sol'
        assert all('PRIVATE_ORIGINAL_SENTINEL_BLOCKED' not in json.dumps(body) for _, body in requests)
        print('PASS: Failed warmup blocks the original Astra request in the official runtime.', flush=True)
        assert sentinel.read_bytes() == b'WORKSPACE_MUST_NOT_CHANGE'
        assert set(project.iterdir()) == {sentinel}, 'No files may be added to the workspace'
        for path in vault.rglob('*'):
            if path.is_file():
                text = path.read_bytes()
                assert fake_key.encode() not in text and b'PRIVATE_ORIGINAL_SENTINEL' not in text
        print('PASS: No workspace mutation, prompt persistence or copied plaintext API key.', flush=True)
    finally:
        if process is not None:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            else:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            process.wait(timeout=10)
        server.shutdown(); server.server_close()
        if root.parent != parent or not root.name.startswith('astra-warmup-integration-'):
            raise RuntimeError('Refusing cleanup outside the isolated fixture')
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
