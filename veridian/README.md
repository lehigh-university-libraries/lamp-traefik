# Veridian

Use the [shared deployment procedure](../DEPLOY.md) with `APP=veridian`. Set the actual Apache port, certificate and key, and the existing Turnstile widget keys in `/etc/traefik/traefik.env`. The checked-in [Apache configuration](etc/apache2/sites-available/veridian.conf) is the existing 8080 example; change both its VirtualHost address and Apache Listen port to 8888 if 8080 is occupied.

Veridian retains the `veridian3.lib.lehigh.edu` redirect to `bwarchive.lib.lehigh.edu`, the shared Lehigh Libraries challenge page, the existing good-bot domains, and CAPTCHA exemptions for `/oai/request` and `/node/<number>/manifest`. The shared per-IP rate limit applies before CAPTCHA exemptions. Review the fixed redirect hostnames in [veridian-redirect.yml](../etc/traefik/dynamic/veridian-redirect.yml) if they change.

For an existing deployment, back up Apache, `/etc/traefik`, the systemd unit, certificates, plugin checkout and persistent state first. Preserve the real Turnstile keys and local adjustments. Replace the old dynamic directory as a unit so obsolete routers and middlewares do not conflict with the shared files. Compare the shared settings with the running deployment, then validate CAPTCHA, exempt routes, redirects, logs and real traffic in a maintenance window. The shared state file remains `/var/log/traefik/state.json`.
