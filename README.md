# Personal Infra Toolkit

A Bash-first infrastructure toolkit for single-host VPS and homelab operations.

This repository covers common small-scale infrastructure tasks:

- Linux server administration
- Bash automation
- Docker Compose operations
- Nginx virtual host and reverse proxy management
- TLS certificate lifecycle management with `acme.sh`
- Basic security hardening with `fail2ban`
- Backup workflows with `rclone`
- Operational support for HestiaCP
- MySQL/MariaDB and PostgreSQL backup and restore workflows

## Why this repo exists

The project started as a collection of daily ops scripts and was later reorganized into a cleaner reusable toolkit.

It focuses on common operational work such as:

- bring up a service on a VPS
- expose it through Nginx
- issue and renew TLS certificates
- back up site and database data
- harden a host
- document assumptions and operational risks

## Tech Stack

- Bash
- Docker Compose
- Nginx
- `acme.sh`
- `fail2ban`
- `rclone`
- MySQL / MariaDB / PostgreSQL
- GitHub Actions

## Repository Layout

```text
.
├── acme/                     # acme.sh container setup and env example
├── fail2ban/                # fail2ban Compose deployment
├── hestiash/                # HestiaCP certificate and backup helpers
├── networking/              # Linux networking and edge-service automation
├── nginx/                   # Nginx Compose deployment and site manager
├── acme_manage.sh           # acme.sh install / uninstall / CA switching
├── bbr_optimizer.sh         # BBR tuning helper
├── copy_user_key_to_root.sh # merge user SSH keys into root authorized_keys
├── fix_acme_serverauth.sh   # repair polluted acme.sh serverAuth config
├── rclone-backup.sh         # simple site + db backup sync example
└── sql_manage.sh            # MySQL/MariaDB/PostgreSQL menu-based backup helper
```

## Key Scripts

| Script | What it does | DevOps topics |
| --- | --- | --- |
| `nginx/site_manager.sh` | create sites, reverse proxies, SSL, reload/test Nginx | reverse proxy, web ops, validation |
| `acme_manage.sh` | install `acme.sh`, switch CA provider, inspect status | PKI, TLS automation, CA operations |
| `sql_manage.sh` | menu-based MySQL/MariaDB/PostgreSQL backup and restore | data safety, DB operations, recovery |
| `bbr_optimizer.sh` | apply BBR-related kernel tuning presets | Linux networking, sysctl tuning |
| `networking/` | advanced edge-service automation | TLS/QUIC, systemd, firewall, rollback |
| `hestiash/sync-cert-to-hestia.sh` | copy ACME certs into HestiaCP paths | platform ops, certificate distribution |
| `hestiash/hestia_rclone_backup.sh` | sync Hestia backups to remote storage | backup retention, remote sync |
| `copy_user_key_to_root.sh` | safely merge SSH keys | access management, Linux permissions |
| `fix_acme_serverauth.sh` | inspect and fix broken ACME account config | debugging, incident recovery |

## Quick Start

Clone the repository:

```bash
git clone git@github.com:z9wen/personal-infra-toolkit.git
cd personal-infra-toolkit
```

Run local checks:

```bash
make check
```

`make syntax` checks every shell script with `bash -n`, and `make lint` runs ShellCheck across all maintained source scripts while excluding generated bundles.

Inspect the main operational helpers:

```bash
bash nginx/site_manager.sh help
./sql_manage.sh
```

`sql_manage.sh` opens an interactive menu for MySQL/MariaDB and PostgreSQL
connection checks, backups, restores, and retention cleanup.

## Optional Direct Download

If you want to fetch a single script to a server:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/acme_manage.sh \
  -o acme_manage.sh && chmod +x acme_manage.sh
```

## Environment Assumptions

Most scripts assume:

- Debian or Ubuntu
- root or `sudo` access
- Docker installed when using Compose-based services
- standard Linux paths such as `/opt/nginx`, `/root/.acme.sh`, `/var/log`

This is intentionally a pragmatic ops toolkit, not a fully abstracted platform product.

## License

Released under the [GPL-3.0 license](LICENSE).
