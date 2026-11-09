# Scalar Apache cutover

Follow the [shared deployment instructions](../DEPLOY.md). Scalar's supplied `default-ssl.conf` uses `scalar.lehigh.edu`, `/opt/scalar`, `/etc/ssl/certs/le/lehigh.edu.pem`, and `/etc/ssl/private/le/lehigh.edu.key`. The adapted [scalar.conf](etc/apache2/sites-available/scalar.conf) retains its document root, directory access, user-agent blocks, and logging; it adds trusted loopback proxy headers and listens on `127.0.0.1:8080`.

Set these values in `/etc/traefik/traefik.env`, along with the Turnstile keys:

```ini
APP=scalar
APACHE_PORT=8080
TLS_CERT=/etc/ssl/certs/le/lehigh.edu.pem
TLS_KEY=/etc/ssl/private/le/lehigh.edu.key
```

Verify that the `.pem` contains the full certificate chain, that Traefik can read both files, and that certificate renewal updates them. If 8080 is occupied, use 8888 in `scalar.conf`, Apache's `ports.conf`, and `APACHE_PORT`.

During the maintenance window, back up Apache first. Inspect all enabled sites with `sudo apache2ctl -S`; the supplied SSL virtual host does not reveal the existing port 80 site or other services. Compare the example with the live file for changes, then copy it into `/etc/apache2/sites-available/scalar.conf`, disable the old public Scalar sites, and enable `scalar.conf`:

```sh
sudo cp ~/lamp-traefik/scalar/etc/apache2/sites-available/scalar.conf /etc/apache2/sites-available/scalar.conf
sudo a2enmod remoteip rewrite
sudo a2dissite default-ssl.conf
sudo a2ensite scalar.conf
```

Update `/etc/apache2/ports.conf` for the chosen loopback port and account for other enabled sites before restarting Apache. Run `sudo apache2ctl configtest`, then follow the shared switch, verification, and rollback steps. The existing configuration mentions Salt pillar: coordinate with the VM's Salt administrator so a later highstate does not restore the old listener or virtual host.
