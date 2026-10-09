# Personal Infra Toolkit

[![Repository Quality](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml/badge.svg)](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/quality.yml)
[![Infrastructure as Code](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/iac.yml/badge.svg)](https://github.com/z9wen/personal-infra-toolkit/actions/workflows/iac.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![AWS Certified DevOps Engineer – Professional](https://img.shields.io/badge/AWS_Certified-DevOps_Engineer_Professional-FF9900)](https://www.credly.com/badges/89341c78-f9f0-4887-856f-10f438dca8e8/public_url)
[![AWS Certified Solutions Architect – Associate](https://img.shields.io/badge/AWS_Certified-Solutions_Architect_Associate-FF9900)](https://www.credly.com/badges/585ee4ee-606e-4dec-81ad-55bfa3cba70f/public_url)

Infrastructure automation and operational tooling: AWS and Azure environments
defined in Terraform, plus Bash and Python tools for running Linux servers.

This repository is both an entry-level DevOps portfolio and a practical home
for scripts I use to solve real infrastructure tasks. It started as a loose
collection of personal utilities and is being progressively improved with
modular code, validation, rollback behaviour, documentation and CI checks.

## What This Repository Demonstrates

- AWS delivery pipeline: Terraform, GitHub OIDC, Lambda canary releases with
  CodeDeploy, automatic rollback on CloudWatch alarms, least-privilege IAM
- Azure private networking: VNet, NSGs, Private DNS and MySQL Flexible Server
  without a public endpoint
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

## Certifications

| Certification | Verification |
| --- | --- |
| AWS Certified DevOps Engineer – Professional (DOP-C02) | [Credly](https://www.credly.com/badges/89341c78-f9f0-4887-856f-10f438dca8e8/public_url) |
| AWS Certified Solutions Architect – Associate (SAA-C03) | [Credly](https://www.credly.com/badges/585ee4ee-606e-4dec-81ad-55bfa3cba70f/public_url) |

## Selected Projects

| Project | Operational problem | DevOps skills demonstrated |
| --- | --- | --- |
| [`aws/`](aws/) | Ship a serverless API safely and cheaply | Terraform, remote state, GitHub OIDC, CodeDeploy canary + rollback, CloudWatch, permissions boundaries |
| [`azure/`](azure/) | Connect an app VM to a database that is never exposed to the internet | Terraform, VNet/subnet delegation, NSGs, Private DNS, MySQL Flexible Server, cost controls |
| [`networking/`](networking/xray/) | Maintain a personal fork of [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent) for my own VPS hosts | Working in an inherited 7k-line codebase: modularisation, transactional config changes with rollback, XHTTP behind nginx/aaPanel, Docker end-to-end tests across Xray versions |
| `nginx/site_manager.sh` | Manage Nginx sites and reverse proxies from a menu, attaching certificates already on the host | Nginx config test with automatic rollback, certificate discovery (acme.sh, certbot) with renewal deploy hooks, docker and native modes |
| `acme_manage.sh` | Install and operate `acme.sh` across CA providers | PKI, certificate automation, failure diagnosis |
| `sql_manage.sh` | Back up and restore MySQL/MariaDB and PostgreSQL | per-database retention by age, transactional PostgreSQL restores, failure propagation |
| `hestiash/hestia_rclone_backup.sh` | Send panel backups to remote storage | backup automation, `rclone`, scheduled operations |
| `bbr_optimizer.sh` | Apply Linux network tuning profiles | sysctl, kernel networking, reversible system changes |
| `fail2ban/` | Deploy basic host protection | Docker Compose, log-driven security controls |
| `tools/codex_ghost_cleaner.py` | Repair stale local Codex/ChatGPT chat indexes | Python, SQLite, backups before writes, restore on failure, safe process handling |

## Engineering Practices

The repository intentionally applies lightweight engineering controls to
otherwise pragmatic shell tooling:

- maintained source modules are assembled into a single deployable installer,
  rebuilt and committed by CI whenever the sources change
- shell and Python syntax is validated across the repository
- every Terraform stack is format-checked and validated in CI, with provider
  versions pinned by lock files
- the AWS stack deploys only through a manually triggered, environment-gated
  workflow that uses short-lived OIDC credentials
- unit tests stub system commands (`systemctl`, `nginx`, `docker`, `rclone`,
  database clients, ...) so restart, rollback, retention and routing logic is
  verified without a real server; most tests were written alongside a bug fix
  and fail against the previous code
- configuration changes are validated before they take effect (`nginx -t`,
  `xray run -test`) and the previous version is restored automatically if the
  check fails
- ShellCheck (warning level) and shfmt enforce script quality and formatting
  on every script; Ruff and pytest do the same for Python
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
make python-lint
make test
make terraform-check
```

Python checks need the pinned dev tools: `pip install -r requirements-dev.txt`.

## Technology

- AWS: Lambda, API Gateway, DynamoDB, CodeDeploy, CloudWatch, SNS, IAM, S3, Budgets
- Azure: Virtual Network, NSG, Private DNS, Database for MySQL Flexible Server, Virtual Machines
- Terraform, Python and pytest
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
├── .github/workflows/       # CI quality, IaC validation, AWS deploy and installer workflows
├── aws/                    # Serverless API: Terraform, Lambda, CodeDeploy canary
├── azure/                  # VM + private MySQL + Private DNS in Terraform
├── acme/                   # acme.sh container setup and environment example
├── fail2ban/               # fail2ban Compose deployment
├── hestiash/               # HestiaCP certificate and backup helpers
├── networking/             # Linux networking and edge-service automation
├── nginx/                  # Nginx Compose deployment and site manager
├── tests/                  # Tests for the top-level scripts
├── tools/                  # Python utilities and their tests
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

## Credits

The Xray deployment manager under `networking/` is derived from
[mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent). It was split into
source modules, extended with relay/subscription management and given tests
and CI here. See [`networking/xray/README.md`](networking/xray/README.md).

## License

Released under the [GPL-3.0 license](LICENSE). Code derived from
mack-a/v2ray-agent (`networking/xray/` and `networking/xray-install.sh`)
remains under that project's
[AGPL-3.0 license](https://github.com/mack-a/v2ray-agent/blob/master/LICENSE).
