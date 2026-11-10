# Personal Infra Toolkit

[![Repository Quality](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml/badge.svg)](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml)
[![Infrastructure as Code](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/iac.yml/badge.svg)](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/iac.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

Bash tools for running Linux servers, plus AWS and Azure environments defined
in Terraform.

These are the scripts I use on my own hosts. The repository started as a loose
collection of utilities and has been tightened up over time with input
validation, rollback behaviour, tests and CI checks. The emphasis is on
understandable operational automation rather than a large platform.

## What is here

| Path | Purpose | Notes |
| --- | --- | --- |
| [`aws/`](aws/) | Serverless API on Lambda, released by a CodeDeploy canary with rollback on CloudWatch alarms | Terraform, remote state, GitHub OIDC, name-scoped deploy role with a permissions boundary |
| [`azure/`](azure/) | App VM and a MySQL Flexible Server that is never exposed to the internet | Terraform, VNet and subnet delegation, NSGs, Private DNS |
| `nginx/site_manager.sh` | Manage Nginx sites and reverse proxies from a menu, attaching certificates already on the host | Config test with automatic rollback, certificate discovery (acme.sh, certbot) with renewal deploy hooks, Docker and native modes |
| `acme_manage.sh` | Install and operate `acme.sh` across CA providers | Issue, inspect, renew and install certificates |
| `sql_manage.sh` | Back up and restore MySQL/MariaDB and PostgreSQL | Keeps the newest N backups per database, transactional PostgreSQL restores |
| `server-backup/` | Per-site and per-database archives with daily, weekly and monthly rotation, copied off-site with `rclone` | |
| `hestiash/` | HestiaCP helpers: certificate sync and panel-backup upload | |
| `bbr_optimizer.sh` | Apply Linux network tuning profiles | sysctl changes with a timed automatic revert |
| `acme/`, `fail2ban/`, `nginx/docker-compose.yml` | Compose definitions for the supporting services | |

### Status of the cloud stacks

Both stacks are format-checked and validated in CI, and the Lambda handler and
deploy script have unit tests. The deploy workflow (`aws-deploy.yml`) is
manually triggered and has not been run from this repository; it expects an
`aws-demo` environment and repository variables that are not configured here.

## Engineering practices

- Shell and Python syntax is validated across the repository.
- ShellCheck (warning level) and shfmt run on every script; Ruff and pytest
  cover the Python code.
- yamllint and actionlint validate configuration and workflows.
- Every Terraform stack is format-checked and validated in CI, with provider
  versions pinned by lock files.
- Unit tests stub system commands (`systemctl`, `nginx`, `docker`, `rclone`,
  database clients) so restart, rollback and retention logic is verified
  without a real server.
- Configuration changes are validated before they take effect (`nginx -t`) and
  the previous version is restored automatically if the check fails.
- The AWS deploy role is name-scoped and limited by a permissions boundary;
  the Lambda runtime role is least-privilege.

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
make python-lint
make test
make terraform-check
```

Python checks need the pinned dev tools: `pip install -r requirements-dev.txt`.

## Technology

- AWS: Lambda, API Gateway, DynamoDB, CodeDeploy, CloudWatch, SNS, IAM, S3, Budgets
- Azure: Virtual Network, NSG, Private DNS, Database for MySQL Flexible Server, Virtual Machines
- Terraform, Python and pytest
- Bash and common GNU/Linux utilities on Debian and Ubuntu
- Docker Compose, Nginx and systemd
- GitHub Actions
- `acme.sh`, `fail2ban` and `rclone`
- MySQL, MariaDB and PostgreSQL

## Repository layout

```text
.
├── .github/workflows/       # CI quality, IaC validation and the manual AWS deploy workflow
├── aws/                    # Serverless API: Terraform, Lambda, CodeDeploy canary
├── azure/                  # VM + private MySQL + Private DNS in Terraform
├── acme/                   # acme.sh container setup
├── fail2ban/               # fail2ban Compose definition
├── hestiash/               # HestiaCP certificate and backup helpers
├── nginx/                  # Nginx Compose definition and site manager
├── server-backup/          # Rotating site and database backups with rclone
├── tests/                  # Tests for the top-level scripts
├── tools/                  # A local Python utility and its tests
├── acme_manage.sh          # acme.sh installation and CA management
├── bbr_optimizer.sh        # Kernel network tuning profiles
├── copy_user_key_to_root.sh
├── fix_acme_serverauth.sh
├── rclone-backup.sh
└── sql_manage.sh           # SQL backup, restore and retention helper
```

## Getting started

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

## Scope and safety

Most scripts assume:

- a Debian or Ubuntu host
- root or `sudo` access
- Docker for Compose-based services
- conventional Linux paths under `/opt`, `/etc`, `/var/log` or the root user's
  home directory

These tools modify real services, firewall rules, certificates and data. Review
the relevant script and test it in a disposable environment before using it on
an important system.

This is a personal operations repository, not a supported production platform.
Some scripts are reusable tools; others document solutions to specific
infrastructure problems.

## Licence

Released under the [AGPL-3.0 licence](LICENSE).
