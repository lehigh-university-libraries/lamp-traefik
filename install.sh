#!/usr/bin/env bash
# Install the repository's native Traefik frontend without changing Apache.
set -euo pipefail

TRAEFIK_VERSION=3.7.12
TRAEFIK_SHA256=c3b2634fc5421626641e2f4256108c08078a9b2662f649d770af78e5e5d729a2
CAPTCHA_COMMIT=2c1b95bf1adca1cace71d9ce079c11936e26b86d
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin=/var/lib/traefik/plugins-local/src/github.com/libops/captcha-protect
changed=0
unit_changed=0

if (( EUID != 0 )); then echo 'Run as root: sudo ./install.sh' >&2; exit 1; fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then echo 'This installer supports Linux amd64 only.' >&2; exit 1; fi
for cmd in curl git sha256sum tar systemctl cmp install hostname; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

# Unknown files can define conflicting routers or middleware. Leave them intact.
if [[ -d /etc/traefik/dynamic ]]; then
  for file in /etc/traefik/dynamic/*.yml /etc/traefik/dynamic/*.yaml /etc/traefik/dynamic/*.toml; do
    [[ -e $file ]] || continue
    if [[ ! -f "$repo/etc/traefik/dynamic/${file##*/}" ]]; then
      echo "Unmanaged dynamic configuration: $file. Review and move it out of /etc/traefik/dynamic before installing." >&2
      exit 1
    fi
  done
fi
if [[ -e $plugin ]]; then
  if [[ ! -d $plugin/.git ]] || [[ -n $(git -C "$plugin" status --porcelain --untracked-files=all) ]]; then
    echo "Plugin checkout has local changes or is not a Git checkout: $plugin" >&2
    exit 1
  fi
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
archive="traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
curl -fsSL "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/${archive}" -o "$work/$archive"
printf '%s  %s\n' "$TRAEFIK_SHA256" "$work/$archive" | sha256sum --check --status || { echo 'Traefik archive checksum mismatch.' >&2; exit 1; }
tar -xzf "$work/$archive" -C "$work" traefik

if [[ ! -d $plugin/.git ]] || [[ $(git -C "$plugin" rev-parse HEAD) != "$CAPTCHA_COMMIT" ]]; then
  git clone --quiet https://github.com/libops/captcha-protect.git "$work/captcha-protect"
  git -C "$work/captcha-protect" checkout --quiet --detach "$CAPTCHA_COMMIT"
  plugin_update=1
else
  plugin_update=0
fi

id traefik >/dev/null 2>&1 || useradd --system --home /var/lib/traefik --shell /usr/sbin/nologin traefik
getent group traefik >/dev/null || { echo 'The traefik group is missing.' >&2; exit 1; }
install -d -o traefik -g traefik -m 0750 /var/lib/traefik /var/log/traefik
install -d -o root -g traefik -m 0750 /etc/traefik /etc/traefik/dynamic

copy_if_changed() {
  local source=$1 target=$2 mode=$3 group=$4
  if [[ ! -f $target ]] || ! cmp -s "$source" "$target"; then
    install -o root -g "$group" -m "$mode" "$source" "$target"
    changed=1
    return 0
  fi
  chown "root:$group" "$target"
  chmod "$mode" "$target"
  return 0
}

copy_if_changed "$work/traefik" /usr/local/bin/traefik 0755 root
if [[ ! -f /etc/systemd/system/traefik.service ]] || ! cmp -s "$repo/etc/systemd/system/traefik.service" /etc/systemd/system/traefik.service; then unit_changed=1; fi
copy_if_changed "$repo/etc/systemd/system/traefik.service" /etc/systemd/system/traefik.service 0644 root
copy_if_changed "$repo/etc/traefik/traefik.yml" /etc/traefik/traefik.yml 0640 traefik
copy_if_changed "$repo/etc/traefik/challenge.tmpl.html" /etc/traefik/challenge.tmpl.html 0640 traefik
for file in "$repo"/etc/traefik/dynamic/*.yml; do
  copy_if_changed "$file" "/etc/traefik/dynamic/${file##*/}" 0640 traefik
done
if [[ ! -e /etc/traefik/traefik.env ]]; then
  case $(hostname -s) in
    scalar|omeka-s|exhibits|veridian) app=$(hostname -s) ;;
    *) app= ;;
  esac
  sed "s/^APP=.*/APP=$app/" "$repo/etc/traefik/traefik.env.example" > "$work/traefik.env"
  install -o root -g traefik -m 0640 "$work/traefik.env" /etc/traefik/traefik.env
  if [[ -n $app ]]; then
    echo "Selected APP=$app from the hostname. Set the remaining values in /etc/traefik/traefik.env."
  else
    echo 'Hostname is not mapped; set APP and the remaining values in /etc/traefik/traefik.env.'
  fi
fi
if (( plugin_update )); then
  install -d -o root -g root -m 0755 "${plugin%/*}"
  if [[ -e $plugin ]]; then mv "$plugin" "$work/previous-plugin"; fi
  mv "$work/captcha-protect" "$plugin"
  changed=1
fi
if (( unit_changed )); then systemctl daemon-reload; fi
if (( changed )) && systemctl is-active --quiet traefik; then
  systemctl restart traefik
  echo 'Updated Traefik and restarted the active service.'
elif (( changed )); then
  echo 'Installed Traefik files; the service was not started.'
else
  echo 'Traefik files and plugin are already up to date.'
fi
