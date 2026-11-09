#!/usr/bin/env python3
"""Run the production Traefik config against a disposable local HTTP backend."""
import hashlib
import http.client
import http.server
import io
import os
import pathlib
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
# Match the version and checksum documented in README.md when upgrading.
TRAEFIK = '3.7.12'
SHA256 = 'c3b2634fc5421626641e2f4256108c08078a9b2662f649d770af78e5e5d729a2'
PLUGIN = '2c1b95bf1adca1cace71d9ce079c11936e26b86d'


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}):\n{result.stdout}')
    return result.stdout


def request(port, path='/', host='bwarchive.lib.lehigh.edu', source='127.0.0.1', headers=None):
    connection = http.client.HTTPSConnection(
        '::1' if ':' in source else '127.0.0.1', port, context=ssl._create_unverified_context(),
        source_address=(source, 0), timeout=20,
    ) if port == 18443 else http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        connection.request('GET', path, headers={'Host': host, **(headers or {})})
        response = connection.getresponse()
        return response.status, response.getheader('Location'), response.read()
    finally:
        connection.close()


class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ci-backend-ok')

    def log_message(self, *_):
        pass


def main():
    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 8080), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='veridian-ci-') as directory:
            work = pathlib.Path(directory)
            plugin = work / 'plugins-local/src/github.com/libops/captcha-protect'
            run('git', 'clone', '--quiet', 'https://github.com/libops/captcha-protect.git', str(plugin))
            run('git', '-C', str(plugin), 'checkout', '--quiet', PLUGIN)
            run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=bwarchive.lib.lehigh.edu', '-keyout', str(work / 'key.pem'),
                '-out', str(work / 'cert.pem'))
            archive = urllib.request.urlopen(
                f'https://github.com/traefik/traefik/releases/download/v{TRAEFIK}/traefik_v{TRAEFIK}_linux_amd64.tar.gz', timeout=60,
            ).read()
            assert hashlib.sha256(archive).hexdigest() == SHA256, 'Traefik checksum mismatch'
            with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
                (work / 'traefik').write_bytes(tar.extractfile('traefik').read())
            (work / 'traefik').chmod(0o755)
            # Relocate filesystem paths and ports, retaining all routing and middleware settings.
            config = work / 'config'
            config.mkdir()
            for source in (ROOT / 'etc/traefik/dynamic').glob('*.yml'):
                content = source.read_text().replace('/etc/ssl/certs/lib.lehigh.edu-fullchain.crt', str(work / 'cert.pem'))
                content = content.replace('/etc/ssl/private/lib.lehigh.edu.key', str(work / 'key.pem'))
                content = content.replace('/etc/traefik/challenge.tmpl.html', str(ROOT / 'etc/traefik/challenge.tmpl.html'))
                content = content.replace('/var/log/traefik/state.json', str(work / 'state.json'))
                (config / source.name).write_text(content)
            static = (ROOT / 'etc/traefik/traefik.yml').read_text()
            static = static.replace('":80"', '":18080"').replace('":443"', '":18443"')
            static = static.replace('/etc/traefik/dynamic', str(config))
            (work / 'traefik.yml').write_text(static)
            environment = {**os.environ, 'TURNSTILE_SITE_KEY': '1x00000000000000000000AA',
                           'TURNSTILE_SECRET_KEY': '1x0000000000000000000000000000000AA',
                           'APP': 'veridian', 'PUBLIC_HOST': 'bwarchive.lib.lehigh.edu',
                           'APACHE_PORT': '8080', 'TLS_CERT': str(work / 'cert.pem'), 'TLS_KEY': str(work / 'key.pem')}
            log = (work / 'traefik.log').open('w+')
            process = subprocess.Popen([str(work / 'traefik'), '--configFile=' + str(work / 'traefik.yml')],
                                       cwd=work, env=environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(60):
                    try:
                        if request(18443, '/oai/request')[0] == 200:
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    time.sleep(1)
                else:
                    raise AssertionError('Traefik did not serve the configured backend within 60 seconds')

                status, location, _ = request(18080, '/test?a=1')
                assert status in (301, 308) and location == 'https://bwarchive.lib.lehigh.edu/test?a=1', (status, location)
                for port in (18080, 18443):
                    status, location, _ = request(port, '/test?a=1', host='veridian3.lib.lehigh.edu')
                    assert status in (301, 308) and location == 'https://bwarchive.lib.lehigh.edu/test?a=1', (status, location)
                # IPv4 loopback and private ranges are always exempt in the plugin.
                status, _, body = request(18443, source='::1')
                assert status == 429 and b'captcha-form' in body, (status, body[:200])
                assert b'Verifying connection' in body and b'https://library.lehigh.edu/themes/' in body
                assert b'block-leh-storybook-gethelp' not in body
                assert b'cf-turnstile' in body and b'1x00000000000000000000AA' in body
                for path in ('/oai/request', '/node/123/manifest'):
                    status, _, body = request(18443, path)
                    assert status == 200 and body == b'ci-backend-ok', (path, status, body[:200])

                # Vary spoofed forwarded headers: they must not create new buckets.
                def hit(index):
                    return request(18443, '/oai/request', headers={'X-Forwarded-For': f'192.0.2.{index % 250 + 1}'})
                results = [hit(index) for index in range(400)]
                assert any(status == 200 for status, _, _ in results), 'No requests reached backend'
                assert any(status == 429 for status, _, _ in results), 'Rate limit never rejected a request'
                assert all(status in (200, 429) for status, _, _ in results), 'Unexpected proxy/backend failure'
                status, _, body = request(18443, '/oai/request', source='127.0.0.2')
                assert status == 200 and body == b'ci-backend-ok', 'Another IP shares the exhausted bucket'
                log.flush()
                logs = (work / 'traefik.log').read_text()
                assert ' ERR ' not in logs and 'level=error' not in logs, logs
                print('PASS: startup, TLS routing, redirects, CAPTCHA, exempt routes, per-IP rate limiting and spoof resistance')
            finally:
                process.terminate()
                process.wait(timeout=10)
                log.close()
                # Keep successful CI output short; retain proxy logs on failure.
                if sys.exc_info()[0] is not None:
                    print((work / 'traefik.log').read_text())
    finally:
        backend.shutdown()
        backend.server_close()


if __name__ == '__main__':
    main()
