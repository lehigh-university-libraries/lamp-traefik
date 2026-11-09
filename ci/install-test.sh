#!/usr/bin/env bash
# Run only on an expendable systemd VM with ports 80, 443 and 8080 free.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
backend_pid=
cleanup() {
  sudo systemctl stop traefik 2>/dev/null || true
  if [[ -n $backend_pid ]]; then kill "$backend_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
cp -a "$repo/." "$work/repo"
cd "$work/repo"
mkdir "$work/mock"
printf '#!/bin/sh\nprintf "scalar\\n"\n' > "$work/mock/hostname"
chmod +x "$work/mock/hostname"
sudo env "PATH=$work/mock:$PATH" ./install.sh
sudo grep -qx 'APP=scalar' /etc/traefik/traefik.env
/usr/local/bin/traefik version | grep -q '3.7.12'
[[ $(sudo git -C /var/lib/traefik/plugins-local/src/github.com/libops/captcha-protect rev-parse HEAD) == 2c1b95bf1adca1cace71d9ce079c11936e26b86d ]]
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=scalar.lehigh.edu' \
  -keyout /etc/traefik/ci.key -out /etc/traefik/ci.crt >/dev/null 2>&1
sudo chmod 0644 /etc/traefik/ci.crt
sudo chown root:traefik /etc/traefik/ci.key
sudo chmod 0640 /etc/traefik/ci.key
sudo tee /etc/traefik/traefik.env >/dev/null <<'ENV'
APP=scalar
APACHE_PORT=8080
TLS_CERT=/etc/traefik/ci.crt
TLS_KEY=/etc/traefik/ci.key
TURNSTILE_SITE_KEY=1x00000000000000000000AA
TURNSTILE_SECRET_KEY=1x0000000000000000000000000000000AA
ENV
env_hash=$(sudo sha256sum /etc/traefik/traefik.env)
echo backend-ok > "$work/index.html"
python3 -m http.server --bind 127.0.0.1 --directory "$work" 8080 >"$work/backend.log" 2>&1 &
backend_pid=$!
sudo systemctl start traefik
check_proxy() {
  local code
  for _ in {1..60}; do
    code=$(curl -ksS --noproxy '*' --resolve scalar.lehigh.edu:443:127.0.0.1 -o "$work/response" -w '%{http_code}' https://scalar.lehigh.edu/ 2>/dev/null || true)
    if [[ $code == 200 ]] && grep -q backend-ok "$work/response"; then break; fi
    sleep 1
  done
  [[ $code == 200 ]] && grep -q backend-ok "$work/response"
  code=$(curl -ksS --noproxy '*' --resolve 'scalar.lehigh.edu:443:[::1]' -o "$work/response" -w '%{http_code}' https://scalar.lehigh.edu/)
  [[ $code == 429 ]] && grep -q captcha-form "$work/response"
}
check_proxy
pid=$(systemctl show -p MainPID --value traefik)
sudo touch /var/lib/traefik/install-test-state
sudo ./install.sh
[[ $(systemctl show -p MainPID --value traefik) == "$pid" ]]
[[ $(sudo sha256sum /etc/traefik/traefik.env) == "$env_hash" ]]
sudo test -f /var/lib/traefik/install-test-state
check_proxy
printf '\n# integration test change\n' >> etc/traefik/traefik.yml
sudo ./install.sh
[[ $(systemctl show -p MainPID --value traefik) != "$pid" ]]
[[ $(sudo sha256sum /etc/traefik/traefik.env) == "$env_hash" ]]
sudo test -f /var/lib/traefik/install-test-state
check_proxy
echo 'PASS: install, active proxy, idempotent reapply, update restart and state preservation'
