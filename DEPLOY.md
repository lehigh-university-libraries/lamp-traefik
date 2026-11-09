# Deploy on a LAMP VM

On the VM, check out the repository and run the same installer for every site:

```sh
git clone https://github.com/lehigh-university-libraries/lamp-traefik.git
cd lamp-traefik
sudo ./install.sh
```

The installer requires Linux amd64, systemd, curl, Git, tar and sha256sum. It verifies the pinned Traefik archive checksum, installs the pinned CAPTCHA plugin commit, and updates the shared configuration and systemd unit. It creates `/etc/traefik/traefik.env` from the example only if absent; it preserves that file, certificates and CAPTCHA state. An active Traefik service restarts when managed files change; an unchanged run leaves it running. An inactive service is not started or enabled. Review any reported unmanaged dynamic files or modified plugin checkout before proceeding.

On first installation, the installer selects `APP` from a matching short hostname (`scalar`, `omeka-s`, `exhibits`, or `veridian`). For other hostnames, set `APP` manually. Existing environment files are never overwritten. Edit `/etc/traefik/traefik.env` and set `APACHE_PORT`, the certificate and key paths, and the Cloudflare Turnstile site and secret keys. Verify that the Traefik user can read the existing full-chain certificate and private key. Arrange for certificate renewal and a Traefik restart after renewal. Keep the environment file private.

During a maintenance window, back up `/etc/apache2` and inspect enabled sites (`sudo apache2ctl -S`) and listeners (`sudo ss -ltnp`). Select Apache port 8080 when free, otherwise 8888; resolve any conflict if neither is available. Configure Apache to listen on `127.0.0.1` at that port and retain the application's existing virtual-host directives. Disable public 80/443 Apache listeners after accounting for all hosted sites. Enable `remoteip` and configure the loopback virtual host with `RemoteIPHeader X-Forwarded-For`, `RemoteIPTrustedProxy 127.0.0.1`, and `SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on`. Check application proxy settings. The [Scalar notes](scalar/README.md) include its adapted virtual host; see [Veridian](veridian/README.md) for its migration.

Run `sudo apache2ctl configtest`, restart Apache, and check the backend on loopback with the site's Host header. Then start Traefik with `sudo systemctl start traefik`. Test the public HTTPS certificate, redirects, CAPTCHA from outside the campus network, successful login and application behavior, client IP logging, and any automated clients. Check `sudo journalctl -u traefik`; once satisfied, enable it with `sudo systemctl enable traefik`. The CAPTCHA plugin exempts the configured Lehigh networks and may bypass challenges when Turnstile is unavailable; the rate limit remains active.

For subsequent releases, update the checkout and rerun `sudo ./install.sh`. The installer does not modify Apache or change configuration and secrets in `traefik.env`. If a deployment fails, restore the backed-up Apache configuration, stop Traefik, test Apache configuration and restart Apache; preserve the old Traefik binary and configuration before updating if you need to roll back an existing Traefik deployment.
