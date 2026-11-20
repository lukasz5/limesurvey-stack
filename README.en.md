# Docker stack for LimeSurvey — quick, secure deployment

> 🇵🇱 [Wersja polska (README.md)](./README.md)

A ready-made, hardened kit for running LimeSurvey on an Ubuntu server with Docker:

| Service | Image | Role |
| --- | --- | --- |
| `traefik` | `traefik:v3.7` | HTTPS, Let's Encrypt certificates, security headers, rate limits |
| `socket-proxy` | `tecnativa/docker-socket-proxy:v0.5.0` | read-only Docker API access for Traefik |
| `limesurvey` | built locally (PHP 8.3.37 + Apache) | LimeSurvey 7.10.0, read-only code |
| `db` | `mariadb:11.4` (LTS) | database, reachable only on the internal network |
| `backup` | `mariadb:11.4` | daily backup of the database, files and encryption keys |

## Requirements

- Ubuntu 22.04/24.04 (or Debian 12). Docker Engine with the `docker compose` plugin (the installer can install it from Docker's official repository).
- Ports 80 and 443 free on the host (Traefik is the only container with published ports).
- A DNS A/AAAA record for your domain pointing at the server, needed to issue the certificate.

## Installation

```bash
sudo ./install.sh
```

A terminal wizard (whiptail) opens. It asks for:

- the domain (and checks right away that DNS points at this server),
- the e-mail for Let's Encrypt, plus the e-mail and login of the first administrator,
- the time zone,
- admin panel access: from anywhere, only from your SSH address, or from selected networks,
- backup time and retention,
- production or test certificates (Let's Encrypt staging, no rate limits),
- whether to enable the `ufw` firewall (opens only the SSH port detected from the `sshd` config, 80 and 443).

Nothing is changed before the summary screen, and "Cancel" quits without side effects. The script then generates random passwords in `secrets/`, builds the image, starts the stack and waits until every service is healthy. At the end it can show the initial administrator password.

Without dialogs (e.g. over a basic terminal): `sudo ./install.sh --plain`.

Non-interactive mode (automation, Ansible, cloud-init):

```bash
sudo LS_DOMAIN=surveys.example.com ACME_EMAIL=it@example.com ADMIN_EMAIL=it@example.com ./install.sh --yes --firewall --lang en
```

First administrator password: `sudo cat secrets/admin_password`. Change it after your first login.

### Installer language

The installer speaks English and Polish. On the first run it asks which one to use (with a Polish system locale it picks Polish straight away) and remembers the choice in `.env` (`INSTALLER_LANG`). You can choose it explicitly with `--lang en` / `--lang pl` or the `LS_LANG` variable.

## Management menu

Running `sudo ./install.sh` again opens a menu:

| Item | What it does |
| --- | --- |
| Service status | container state, version, number of backups, free disk space |
| Back up now | on-demand backup to `backups/` |
| Restore a backup | list of backups with dates; offers a backup of the current state before restoring |
| Logs | last 300 lines of the chosen service in `less` (`q` to go back, `/` to search) |
| Change configuration | the same wizard with current values; applies changes without rebuilding |
| Update | new Traefik/MariaDB images or a new LimeSurvey version (suggests the latest, backs up first, refuses downgrades) |
| Restart services | restarts the whole stack |
| Show initial password | the password from `secrets/admin_password` |

When you switch between test and production certificates, the menu deletes the stored certificates so Traefik fetches new ones.

## Security

**Network and TLS**
- Only ports 80 (redirect to HTTPS) and 443 are exposed.
- TLS 1.2+ with modern ciphers only, HSTS, `sniStrict` (no response for unknown domains).
- The database and backup run on an `internal` network with no internet access and no host ports.
- Traefik never sees `docker.sock` directly, only a filtered, read-only API through `socket-proxy`.
- The Traefik dashboard is disabled.

**Admin panel**
- Rate limit on `/admin` (20/s) and a stricter one on login (10/min per IP), on top of LimeSurvey's built-in lockout.
- `ADMIN_ALLOW_CIDRS` in `.env` restricts the panel to selected IP addresses (open by default). The rule covers both URL styles, `/index.php/admin/...` and `?r=admin/...`, plus the REST API, and blocks logins from outside the list. Other LimeSurvey 7 panel screens (e.g. `/index.php/dashboard`) require a logged-in session anyway.

**Containers**
- All: `no-new-privileges`, memory limits, log rotation.
- LimeSurvey: runs as `www-data`, read-only file system, all kernel capabilities dropped (`cap_drop: ALL`). Only `upload/`, `tmp/` (tmpfs) and the generated-config directory are writable.
- PHP is disabled in `upload/` and `tmp/`, so an uploaded file cannot be executed.
- PHP: `exec`/`shell_exec`/`proc_open` etc. disabled, `Secure`/`HttpOnly`/`SameSite=Lax` session cookies, version hidden.
- The LimeSurvey image is built from the official GitHub release and verified against a SHA-256 checksum. Developer files and documentation are removed.

**Secrets**
- Passwords live only in `secrets/` (Docker secrets), never in the image, labels or environment variables.
- `config.php` is generated on every start from `.env` and the secrets.
- `security.php` (response encryption keys) is created once and kept on the `state` volume. **Never change it**: without it, encrypted data cannot be read.

## Day-to-day operations

```bash
docker compose ps                       # service status
docker compose logs -f limesurvey       # application logs
docker compose logs -f traefik          # access logs (JSON) and certificates
docker compose exec backup /bin/bash /opt/backup/backup.sh now   # on-demand backup
```

### Updating LimeSurvey

The easy way: menu → Update → LimeSurvey to a new version. Manually:

1. Make an on-demand backup.
2. In `.env`, set the new `LIMESURVEY_VERSION` (a tag from https://github.com/LimeSurvey/LimeSurvey/tags) and `LIMESURVEY_SHA256`:
   ```bash
   curl -fsSL "https://github.com/LimeSurvey/LimeSurvey/archive/refs/tags/<TAG>.tar.gz" | sha256sum
   ```
3. Rebuild and restart. Database migrations run automatically on start (`updatedb`).
   ```bash
   docker compose build --pull limesurvey && docker compose up -d --wait
   ```

Traefik and MariaDB updates: `docker compose pull && docker compose up -d --wait`. MariaDB has `MARIADB_AUTO_UPGRADE` enabled.

### Backup

Every day at `BACKUP_TIME` the `backup` service writes to `backups/YYYYMMDD-HHMMSS/`:

- `database.sql.gz`: a consistent dump (`--single-transaction`),
- `upload.tar.gz`: user-uploaded files and themes,
- `keys.tar.gz`: `security.php` with the encryption keys,
- `SHA256SUMS`.

Backups older than `BACKUP_KEEP_DAYS` are deleted. **Copy the `backups/` directory off the server** (rsync, restic, S3): a backup on the same disk does not protect you from a server failure.

### Restoring

```bash
sudo ./scripts/restore.sh backups/20261117-031500
```

The script verifies checksums, asks for confirmation and replaces the database, files and keys. If the backup comes from an older LimeSurvey version, the schema is migrated on start. Rehearse your first restore on a separate machine.

## Customisation

- **Embedding surveys in an iframe on another domain:** remove `customFrameOptionsValue` in `traefik/dynamic/security.yml`.
- **Letting search engines index surveys:** remove `X-Robots-Tag` from the same file.
- **Server behind Cloudflare or another proxy:** add `--entrypoints.websecure.forwardedHeaders.trustedIPs=...` to Traefik in `compose.yaml`. Otherwise rate limits and the IP allow-list see the proxy's address instead of the client's.
- **E-mail:** SMTP is configured in the LimeSurvey panel (Configuration → Global settings → Email settings).
- **Custom themes:** upload them through the panel. They are stored on the `upload` volume and included in backups.

## Recommendations for the Ubuntu host

- `apt install unattended-upgrades` for automatic security patches.
- SSH login with keys only (`PasswordAuthentication no`), optionally `fail2ban` for SSH.
- `ufw` does not filter ports published by Docker. Here only Traefik publishes them (80/443), so this is intended.
