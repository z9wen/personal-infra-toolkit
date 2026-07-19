# Personal Infra Toolkit

[![Repository Quality](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml/badge.svg)](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

A Bash-first collection of infrastructure automation and operational tooling for
small VPS and homelab environments.

This repository is both an entry-level DevOps portfolio and a practical home
for scripts I use to solve real infrastructure tasks. It started as a loose
collection of personal utilities and is being progressively improved with
modular code, validation, rollback behaviour, documentation and CI checks.

## What This Repository Demonstrates

- Linux administration and repeatable Bash automation
- Service deployment with Docker Compose and systemd
- Nginx virtual hosts, reverse proxies and TLS lifecycle management
- Firewall rules, network tuning and edge-service operations
- Backup and recovery workflows with `rclone` and SQL databases
- Defensive scripting: input validation, configuration tests and safe rollback
- CI quality gates using ShellCheck, shfmt, yamllint and actionlint
- Maintaining generated artifacts separately from their source modules

The emphasis is on understandable operational automation rather than building a
large platform or hiding infrastructure behaviour behind abstractions.

## Selected Projects

| Project | Operational problem | DevOps skills demonstrated |
| --- | --- | --- |
| `networking/` | Automate Linux networking and edge-service operations | systemd, firewall management, TLS/QUIC, routing, scheduled maintenance, rollback |
| `nginx/site_manager.sh` | Manage sites, reverse proxies and certificates | Nginx validation, configuration automation, safe reloads |
| `acme_manage.sh` | Install and operate `acme.sh` across CA providers | PKI, certificate automation, failure diagnosis |
| `sql_manage.sh` | Back up and restore MySQL/MariaDB and PostgreSQL | database operations, retention, recovery workflows |
| `hestiash/hestia_rclone_backup.sh` | Send panel backups to remote storage | backup automation, `rclone`, scheduled operations |
| `bbr_optimizer.sh` | Apply Linux network tuning profiles | sysctl, kernel networking, reversible system changes |
| `fail2ban/` | Deploy basic host protection | Docker Compose, log-driven security controls |

## Engineering Practices

The repository intentionally applies lightweight engineering controls to
otherwise pragmatic shell tooling:

- maintained source modules are assembled into a single deployable installer
- generated artifacts are checked for consistency
- shell syntax is validated across the repository
- ShellCheck and shfmt enforce script quality and formatting
- yamllint and actionlint validate configuration and workflows
- risky service changes are tested before restart where supported
- several workflows preserve or restore the last working configuration on
  failure

Run the same checks locally with:

```bash
make check
```

Individual targets are also available:

```bash
make syntax
make lint
make format-check
make yaml-lint
make actionlint
```

## Technology

- Bash and common GNU/Linux utilities
- Debian and Ubuntu
- Docker Compose
- Nginx and systemd
- GitHub Actions
- `acme.sh`, `fail2ban` and `rclone`
- MySQL, MariaDB and PostgreSQL
- TLS, QUIC and Linux firewall tooling

## Repository Layout

```text
.
├── .github/workflows/       # CI quality and generated-installer workflows
├── acme/                   # acme.sh container setup and environment example
├── fail2ban/               # fail2ban Compose deployment
├── hestiash/               # HestiaCP certificate and backup helpers
├── networking/             # Linux networking and edge-service automation
├── nginx/                  # Nginx Compose deployment and site manager
├── acme_manage.sh          # acme.sh installation and CA management
├── bbr_optimizer.sh        # BBR-related kernel tuning profiles
├── copy_user_key_to_root.sh
├── fix_acme_serverauth.sh
├── rclone-backup.sh
└── sql_manage.sh           # SQL backup, restore and retention helper
```

## Getting Started

Clone the repository and run its checks:

```bash
git clone git@github.com:z9wen/personal-infra-toolkit.git
cd personal-infra-toolkit
make check
```

Inspect a script before executing it, then use its help or interactive menu
where available:

```bash
bash nginx/site_manager.sh help
./sql_manage.sh
```

To fetch a single utility directly:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/acme_manage.sh \
  -o acme_manage.sh
chmod +x acme_manage.sh
```

## Scope and Safety

Most scripts assume:

- a Debian or Ubuntu host
- root or `sudo` access
- Docker for Compose-based services
- conventional Linux paths under `/opt`, `/etc`, `/var/log` or the root user's
  home directory

These tools modify real services, firewall rules, certificates and data. Review
the relevant script and test it in a disposable environment before using it on
an important system.

This is a personal learning and operations repository, not a supported
production platform. Some scripts are reusable tools; others intentionally
document solutions to specific infrastructure problems. That mix reflects the
repository's evolution from ad-hoc automation toward more maintainable DevOps
practice.

## License

Released under the [GPL-3.0 license](LICENSE).
