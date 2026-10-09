# Xray Deployment Manager

Operational automation for an Xray-based TLS/QUIC edge service. It covers
installation, certificates, Nginx fallback, firewall rules, control-panel
integration, users, Hysteria2 tuning and chained routing.

## Origin

This is a personal fork of
[mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent) (AGPL-3.0) that I
maintain for my own VPS hosts. It remains under AGPL-3.0. Work done in this
fork includes:

- splitting the single upstream script into ordered source modules plus a
  build step that reassembles and versions the deployable installer
- relay upstream profiles, per-account selectors and sing-box JSON
  subscription refresh with validation before restart
- restart/rollback hardening and unit tests with stubbed system commands
- CI that rebuilds the installer on every source change
- a cleanup pass over the inherited code: 14 unreachable functions and the
  commented-out code removed, duplicated logic consolidated, ShellCheck clean
  at warning level, comments translated to English

## Compatibility notes

- **REALITY public key on Xray 26.x.** `xray x25519` prints
  `Password (PublicKey): <key>` since 26.x (previously `Password: <key>`).
  Parsing it as "second field" stored the literal `(PublicKey):`, so share
  links from fresh installs could not connect. Keys are now parsed by label,
  and existing installs are repaired from the private key when read.
- **Hysteria2 `users` vs `clients`.** v26.5.9+ also accepts `users`, but
  stable v26.3.27 passes `run -test` with it and then ignores it at runtime
  (no accounts), breaking rollbacks from pre-releases. The installer always
  writes `clients` and converts old configs before switching cores.
- **REALITY clients on v26.9.8+.** Pre-release servers reject Client Hellos
  without X25519MLKEM768 (XTLS/REALITY 8cdf7bf, not configurable). Xray clients
  are unaffected; some sing-box/Clash Meta clients cannot connect. Version
  management prints a notice when crossing that version.

## Design

**Relay state is the source of truth.** `/opt/xray-agent/relay_config.json`
lists upstream profiles and the selectors (inbound + optional accounts) routed
through each. `09_routing.json` is regenerated from it, so other menus that
rewrite or delete the routing file (reinstall, global IPv6/WARP modes) just
call `syncRelayRouting` to put the relay rules back.

**Every config change is a transaction.** `applyXrayConfigChange` snapshots the
config directory and relay state, runs the change, validates the result with
`xray run -test` and restores the snapshot exactly if anything fails. Relay
operations go through `commitRelayChange`, which adds routing regeneration and
removal of outbound files no profile uses. Extra ports use the same helper.

**Relay changes are serialized.** `withRelayLock` holds a `flock` only for the
duration of one change, so an open menu does not block the daily subscription
refresh and the refresh cannot overwrite an edit in progress.

**Restarts must be stable.** `restartXray` only reports success after several
consecutive checks with an unchanged systemd `NRestarts` counter, so a
crash-looping service is not mistaken for a healthy one.

**Untrusted input is constrained.** Ports are validated before use in file
names, subscriptions and self-updates are fetched over HTTPS only (redirects
included), and JSON is built with `jq --arg` rather than string interpolation.

## Protocols

| Menu | Protocol | Needs a domain | Typical use |
| --- | --- | --- | --- |
| 1 | VLESS + TCP + TLS Vision | yes | direct connections; TLS front for the others |
| 2 | VLESS + XHTTP + TLS | yes | port 443 / CDN; on aaPanel it rides the panel site's 443 |
| 3 | Hysteria2 (QUIC) | yes | games and lossy links: UDP without head-of-line blocking |
| 4 | VLESS + REALITY + Vision | no | direct connections without a domain |
| 5 | VLESS + XHTTP + REALITY | no | XHTTP without a domain |
| 6 | VLESS + WebSocket + TLS | yes | deprecated by Xray; kept for existing clients |

"Install recommended" installs Vision, XHTTP + TLS, REALITY + Vision and
Hysteria2.

### How XHTTP + TLS is served

XHTTP is hidden behind nginx, as upstream recommends, and nginx hands the path
to a local XHTTP inbound with `grpc_pass` (which also serves HTTP/1.1 clients,
e.g. CDNs talking HTTP/1.1 to the origin):

```text
without a panel:   client ──TLS:443──> Xray Vision ──fallback──> nginx 127.0.0.1:31302/31300 ──grpc_pass──> XHTTP 127.0.0.1:31305
with aaPanel:      client ──TLS:443──> panel nginx site ─location ^~ /<path>xhttp/──grpc_pass──> XHTTP 127.0.0.1:31305
```

On aaPanel the location goes into a file the site config already includes (the
per-site `extension` directory, or a marked block in the site's rewrite file),
so the panel regenerating the site config does not remove it. Every change is
checked with `nginx -t` and rolled back if the test fails. When no such include
exists (e.g. 1Panel), the installer prints the location to add by hand instead
of editing panel-owned files. nginx sets a header that Xray trusts
(`sockopt.trustedXForwardedFor`), so the client IP from `X-Forwarded-For` is
only accepted from nginx.

The XTLS Vision flow is not used with XHTTP: XTLS's splice only works on raw
TCP with TLS/REALITY, and over XHTTP the flow is only accepted together with
VLESS Encryption.

### Hysteria2 port hopping

Some ISPs throttle or block a single UDP port; port hopping lets clients
switch between ports of a range (it does not help when UDP as a whole is
restricted). It is offered while installing Hysteria2 and can be changed later
under Protocol settings → Hysteria2.

Xray's Hysteria2 inbound listens on one port, so an nftables table
(`xray_agent_port_hopping`) redirects the UDP range to it; on systemd hosts a
oneshot unit restores it at boot. Ranges that would swallow the UDP forwarders
of extra ports are refused, and a failed rule load rolls back. The cloud
security group must allow the whole UDP range.

Clients learn the range from the subscription, each in its own format:
`mport=` in the share link (v2rayN/v2rayNG cannot parse the official
`host:20000-50000` form), `ports`/`hop-interval` for Clash Meta, and
`server_ports`/`hop_interval` for sing-box. Xray clients configure the hop
themselves: `quicParams.udpHop` up to v26.3.27, a Finalmask `udphop` UDP mask
from v26.9.8.

Hysteria2's BBR profile (`bbrProfile`) only exists from Xray v26.4.13;
stable v26.3.27 ignores it. Installation always uses `standard` (a reinstall
keeps the previous choice); change it under Hysteria2 management.

## Menu

```text
1. Install recommended       2. Custom install
3. Accounts   4. Subscriptions   5. Relays   6. Protocol settings (REALITY, Hysteria2, extra ports)
7. Routing tools   8. Decoy site & certificate
9. Xray core versions   10. Update script   11. Uninstall
```

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
| `03_panels.sh` | aaPanel and 1Panel adapters |
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

Edit files in `src/` only: CI rebuilds and commits `networking/xray-install.sh`
on every push to `main`, so the generated file is never edited or committed by
hand. `make check` lints a temporary build of the installer at ShellCheck
warning level. To build a local copy without touching the committed file:

```bash
XRAY_BUILD_OUTPUT=/tmp/xray-install.sh ./networking/xray/build.sh
```

Run the checks and tests:

```bash
make lint test      # ShellCheck (temporary build) and unit tests
make xray-e2e       # Docker end-to-end tests across Xray versions
```

`make xray-e2e` runs the end-to-end tests in Docker. One generates a full config with the installer's functions and connects through every protocol; a privileged one enables port hopping with real nftables and checks a hopping client from a separate network namespace. In detail: the installer's own
functions generate a full config with the latest stable and pre-release cores,
real nginx serves it (including a simulated aaPanel site), and real Xray
clients connect through every protocol, with every core. This is what caught
the two compatibility bugs below.

Tests in `tests/` source individual modules and replace commands such as
`systemctl` and `pgrep` with shell functions, so they run on any machine
without root or a real Xray install.

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
