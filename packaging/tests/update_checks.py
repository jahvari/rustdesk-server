"""Exercise update opt-out/config precedence without contacting an external API."""
import argparse
import os
import pathlib
import socket
import subprocess
import tempfile
import time


def config_snapshot(roots):
    return {str(path): (path.stat().st_size, path.stat().st_mtime_ns)
            for root in roots if root.exists() for path in root.rglob('RustDesk.toml')}


def reserve_server_ports():
    for _ in range(100):
        sockets = []
        try:
            main = socket.socket()
            sockets.append(main)
            main.bind(('127.0.0.1', 0))
            port = main.getsockname()[1]
            if not 3 <= port <= 65533:
                raise OSError('Companion port out of range')
            for kind, number in [(socket.SOCK_STREAM, port - 1), (socket.SOCK_STREAM, port + 2), (socket.SOCK_DGRAM, port)]:
                companion = socket.socket(socket.AF_INET, kind)
                sockets.append(companion)
                companion.bind(('127.0.0.1', number))
            return port, sockets
        except OSError:
            for item in sockets:
                item.close()
    raise RuntimeError('Could not reserve the server listener ports')


def check(binary, root, name, environment, config, arguments, expected):
    directory = root / name
    directory.mkdir()
    env = os.environ.copy()
    for key in list(env):
        if key.upper().replace('-', '_') in {'DISABLE_UPDATE_CHECK', 'DB_URL', 'TEST_HBBS', 'KEY', 'PORT'}:
            del env[key]
    profile_roots = [directory / 'home', directory / 'config', directory / 'roaming']
    if os.name == 'nt' and os.environ.get('APPDATA'):
        profile_roots.append(pathlib.Path(os.environ['APPDATA']) / 'RustDesk')
    before = config_snapshot(profile_roots)
    env.update(HOME=str(profile_roots[0]), XDG_CONFIG_HOME=str(profile_roots[1]),
               APPDATA=str(profile_roots[2]), LOCALAPPDATA=str(directory / 'local'),
               TEST_HBBS='no', KEY='-', NO_PROXY='', no_proxy='')
    env.update(environment)
    if config is not None:
        (directory / 'options.ini').write_text('DISABLE_UPDATE_CHECK=' + config + '\n')
        arguments = ['--config', str(directory / 'options.ini'), *arguments]
    port, reserved = reserve_server_ports()
    with socket.socket() as proxy:
        proxy.bind(('127.0.0.1', 0))
        proxy.listen()
        proxy_url = 'http://127.0.0.1:' + str(proxy.getsockname()[1])
        for variable in ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']:
            env[variable] = proxy_url
        for item in reserved:
            item.close()
        with (directory / 'stdout.log').open('wb') as stdout, (directory / 'stderr.log').open('wb') as stderr:
            process = subprocess.Popen([str(binary), '--bind', '127.0.0.1', '--port', str(port), *arguments],
                                       cwd=directory, env=env, stdout=stdout, stderr=stderr)
            try:
                # Confirm that a disabled-check case did not merely fail to start.
                deadline = time.monotonic() + 10
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(name + ': server exited during startup')
                    try:
                        with socket.create_connection(('127.0.0.1', port - 1), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise RuntimeError(name + ': server did not open its listener')
                        time.sleep(.05)
                proxy.settimeout(5 if expected else 1)
                connected = False
                try:
                    connection, _ = proxy.accept()
                    with connection:
                        connection.settimeout(2)
                        header = b''
                        while b'\r\n\r\n' not in header and len(header) < 4096:
                            chunk = connection.recv(4096 - len(header))
                            if not chunk:
                                break
                            header += chunk
                        assert b'CONNECT api.rustdesk.com:443' in header, repr(header[:200])
                    connected = True
                except socket.timeout:
                    pass
                assert connected == expected, f'{name}: expected outbound check={expected}, observed={connected}'
                assert config_snapshot(profile_roots) == before, name + ': client configuration changed'
                print(name + ': passed (outbound check=' + str(connected) + ', client config unchanged)', flush=True)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=pathlib.Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='rustdesk-update-check-') as temporary:
    root = pathlib.Path(temporary)
    for case in [
        ('default-enabled', {}, None, [], True),
        ('environment-disabled', {'DISABLE_UPDATE_CHECK': 'y'}, None, [], False),
        ('config-overrides-environment', {'DISABLE_UPDATE_CHECK': 'N'}, 'Y', [], False),
        ('cli-enables-over-config', {}, 'Y', ['--disable-update-check', 'N'], True),
        ('cli-disables-over-environment', {'DISABLE_UPDATE_CHECK': 'N'}, None, ['--disable-update-check', 'Y'], False),
    ]:
        check(args.binary.resolve(), root, *case)
