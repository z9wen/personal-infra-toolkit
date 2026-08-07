# Xray Deployment Manager

Operational automation for an Xray-based TLS/QUIC edge service. It covers
installation, certificates, Nginx fallback, firewall rules, control-panel
integration, users, Hysteria2 tuning and chained routing.

## Layout

```text
xray/
├── src/                  # Maintained source modules
└── build.sh              # Builds and verifies ../xray-install.sh
```

The source modules follow runtime dependency order:

| Module | Responsibility |
| --- | --- |
| `01_common.sh` | System detection, global state and shared helpers |
| `02_state_readers.sh` | Read existing TLS, ports and installed protocols |
| `03_panels.sh` | aaPanel, 1Panel and HestiaCP adapters |
| `04_firewall.sh` | UFW, firewalld and iptables operations |
| `05_preflight.sh` | Existing-install discovery and native ACME checks |
| `06_host_provisioning.sh` | Packages, directories, Nginx discovery and host tools |
| `07_nginx.sh` | Domain checks, fallback sites and generated Nginx config |
| `08_tls_hysteria.sh` | ACME/TLS lifecycle and Hysteria2 transport settings |
| `09_core_runtime.sh` | Downloads, Xray versions, services and scheduled jobs |
| `10_xray_config.sh` | Users, inbounds, outbounds and Xray JSON generation |
| `11_client_output.sh` | Share links, QR links and client-facing output |
| `12_operations.sh` | Site, port, account, uninstall and log operations |
| `13_network_routing.sh` | IPv6, WARP and WireGuard routing helpers |
| `14_relay.sh` | Chained-proxy outbound, sing-box JSON subscription updates and routing management |
| `15_routing_tools.sh` | SNI, DNS and routing-tool menus |
| `16_install_management.sh` | Install/reinstall workflows and core management |
| `17_subscriptions.sh` | Local and remote subscription generation |
| `18_reality.sh` | REALITY keys, destination checks and management |
| `19_hysteria_management.sh` | Runtime QUIC BBR profile management |
| `20_menu.sh` | Interactive entry point |

## Development

Edit files in `src/`, then rebuild the deployable script:

```bash
./networking/xray/build.sh
./networking/xray/build.sh --check
```

Each build stamps the generated installer with
`vYYYY.MM.DD.<Unix timestamp>` using the UTC+8 calendar date.

Do not edit `networking/xray-install.sh` directly. A push to `main` that changes
the source modules or build script automatically rebuilds and commits the
single-file artifact.

## Direct installation

```bash
curl -fsSL \
  https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/networking/xray-install.sh \
  -o xray-install.sh
chmod +x xray-install.sh
sudo ./xray-install.sh
```

With `wget`:

```bash
wget -O xray-install.sh \
  https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/networking/xray-install.sh
chmod +x xray-install.sh
```

The script is intended for Debian/Ubuntu VPS environments and performs
privileged system, firewall, Nginx and systemd changes. Review it before use.

The relay manager separates reusable upstream profiles from their inbound
selectors. One manual upstream or Shadowsocks node imported from a sing-box
JSON subscription can serve multiple independent inbound/account selectors,
without entering its credentials again. Every installed inbound is presented
as both a whole-inbound target and individual UUID/auth targets. Multiple exact
targets can be selected together, for example one Vision UUID plus one
Hysteria2 auth, while unselected accounts keep the fallback route. Xray matches
their configured email values.
Subscription profiles share a daily refresh job;
changed credentials are validated before Xray is restarted, while failed
refreshes keep the last working outbound. Existing relay state is migrated
automatically. Account-scoped relay rules take priority over a whole-inbound
rule, so a Vision UUID can use another existing upstream while the whole Vision
inbound rule remains as a fallback for every other UUID.

Account creation accepts a stable, human-readable tag such as `jp_vision` or
`vision_jp_us`. Protocol-specific suffixes are added internally so Xray routing
can identify the authenticated user. A new UUID can be added to selected
installed protocols instead of being copied to every inbound. The account menu
discovers these choices from the active inbound JSON files rather than from a
fixed list of installation type numbers.

Account management only lists, adds and removes server-side identities.
Subscription generation and remote-subscription aggregation live under a
separate top-level subscription menu.
