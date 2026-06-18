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
- MySQL/MariaDB dump and restore workflows

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
- MySQL / MariaDB
- GitHub Actions

## Repository Layout

```text
.
├── acme/                     # acme.sh container setup and env example
├── fail2ban/                # fail2ban Compose deployment
├── hestiash/                # HestiaCP certificate and backup helpers
├── nginx/                   # Nginx Compose deployment and site manager
├── acme_manage.sh           # acme.sh install / uninstall / CA switching
├── bbr_optimizer.sh         # BBR tuning helper
├── copy_user_key_to_root.sh # merge user SSH keys into root authorized_keys
├── fix_acme_serverauth.sh   # repair polluted acme.sh serverAuth config
├── rclone-backup.sh         # simple site + db backup sync example
├── sql_manage.sh            # MySQL/MariaDB backup and restore helper
└── xray-install.sh          # large Xray deployment installer
```

## Key Scripts

| Script | What it does | DevOps topics |
| --- | --- | --- |
| `nginx/site_manager.sh` | create sites, reverse proxies, SSL, reload/test Nginx | reverse proxy, web ops, validation |
| `acme_manage.sh` | install `acme.sh`, switch CA provider, inspect status | PKI, TLS automation, CA operations |
| `sql_manage.sh` | backup, restore, list, clean MySQL dumps | data safety, DB operations, recovery |
| `bbr_optimizer.sh` | apply BBR-related kernel tuning presets | Linux networking, sysctl tuning |
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

`make syntax` checks every shell script with `bash -n`, and `make lint` runs `shellcheck` on the currently maintained core helpers.

Inspect the main operational helpers:

```bash
bash nginx/site_manager.sh help
bash sql_manage.sh help
```

## Optional Direct Download

If you want to fetch a single script to a server:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/xray-install.sh \
  -o xray-install.sh && chmod +x xray-install.sh
```

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

## Suggested Starting Points

If you want a quick tour of the repository:

1. Start from this `README` and explain the project goal.
2. Show `nginx/site_manager.sh` and explain virtual host + TLS automation.
3. Show `acme/docker-compose.yml` and `acme/.env.example` to discuss certificate automation.
4. Show `sql_manage.sh help` to explain backup and restore workflow.
5. Show `.github/workflows/ShellCheck.yml` and `Makefile` to demonstrate basic CI quality checks.

## What this repo demonstrates well

- turning repetitive server work into scripts
- thinking about recoverability, not just deployment
- mixing containerized services with host-level operations
- documenting assumptions and operational boundaries
- adding lightweight CI to shell-heavy repos

## Current Limitations

This repo is strong as a single-host and homelab portfolio project, but it is not yet a full platform engineering stack.

Current gaps:

- no Terraform or cloud IaC yet
- no Ansible-based fleet management yet
- no Kubernetes deployment layer
- some scripts are tightly coupled to local filesystem conventions
- large scripts such as `xray-install.sh` would benefit from further modularization

## Roadmap

Practical next improvements:

1. convert repeated host setup into Ansible roles
2. add Terraform for DNS / VM / security group provisioning
3. add integration tests for critical Bash flows
4. split large scripts into reusable modules
5. add secrets management patterns beyond local env files

## License

Released under the [GPL-3.0 license](LICENSE).
