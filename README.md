# Xray VLESS + REALITY Installer

[English](README.md) | [Русский](README.ru.md)

One script to install and manage a VLESS + REALITY VPN server on any Linux VPS, with a choice of TCP + XTLS Vision or XHTTP transport. No domain, no certificates — works out of the box in under 2 minutes. A separate script is available for Docker containers without systemd.

## Quick Start

```bash
wget https://raw.githubusercontent.com/1517mb/xray-vless-reality-installer/main/xray-install.sh && sudo bash xray-install.sh
```

To manage clients later, just re-run `sudo bash xray-install.sh`.

### Running in Docker (no systemd)

Use `xray-install-docker.sh` inside a Docker container (Debian/Ubuntu, Fedora, Alpine, Arch images). Run it as root; bash is required:

```bash
wget https://raw.githubusercontent.com/1517mb/xray-vless-reality-installer/main/xray-install-docker.sh && bash xray-install-docker.sh
```

Differences from the host script:
- Interactive installs run Xray as a background process; log in `/var/log/xray.log`
- No systemd unit, no dedicated user, no BBR
- Publish port 443 of the container (e.g. `docker run -p 443:443 ...`)
- Autostart without systemd, detected automatically:
  - **cron** (if a cron daemon runs in the container): checks every minute, so Xray comes back after a container restart *and* after a crash
  - otherwise **OpenRC** (`/etc/local.d`) or **`/etc/rc.local`**: starts Xray at container boot
  - if none is available, set your provider's startup command or Docker `ENTRYPOINT` to `/usr/local/bin/xray-entrypoint`, or start Xray from the menu (**Start / restart Xray**)

`xray-entrypoint` runs Xray in the foreground using `exec`; its output appears in
Docker logs. `xray-autostart` is the background watchdog for cron/init hooks.
Both launchers are refreshed when this installer is run again.

Persist the entire `/etc/xray` directory as a volume. Atomic config replacement
requires a directory mount; mounting only `/etc/xray/config.json` prevents client
changes from being committed.

For Xray started with the foreground entrypoint (including PID 1), process
restart/removal and config changes that require a restart are refused by the
management menu. Use Docker or the provider's panel for its lifecycle. For
interactive client management inside a running container, use the background
mode with a separate container main process.

Background logs have a logrotate policy: daily or above 10 MB, seven rotations.
A running cron watchdog checks rotation every minute. With OpenRC/rc.local,
the container's logrotate scheduler must be active; the foreground entrypoint
uses Docker's logging configuration instead.

## What It Does

**First run** — interactive installation:
- Installs Xray-core (latest version, auto-detects architecture, verifies the release SHA-256 digest)
- Detects the server's public IP — you can keep it or enter a domain instead
- Generates REALITY keys, UUID, Short ID
- Lets you choose the transport: **TCP + XTLS Vision** (default, supported by all clients) or **XHTTP** (see below)
- Checks the SNI site against REALITY target requirements (TLS 1.3, HTTP/2, no redirect to another domain) and warns before continuing
- Lets you choose DNS (Google, Cloudflare, Quad9, AdGuard, OpenDNS)
- Configures systemd service on port 443 with autostart at boot
- Validates the config and checks that Xray actually started (shows logs if not)
- Disables client access logs; keeps warnings and errors for diagnostics
- Blocks clients from reaching the server's local and private addresses (see below)
- Enables TCP BBR for better speed (persistent across reboots)
- Prints connection URI + QR code
- Exports an optional INCY/Happ routing profile: Russian domains connect directly, other destinations use the VPN

New installations disable client access logs with `"access": "none"` in the
`log` section. DNS query logging and REALITY debug output are also disabled.
Warnings and errors may still contain client or destination addresses.
Existing installations keep their logging settings: add `"access": "none"` to
the `log` object in `/etc/xray/config.json` and restart Xray to apply this change
(restart the container when using the foreground entrypoint). Previously written
log entries are not removed.

**Every next run** — service status and management menu:

```
Xray VLESS+REALITY is already installed.

   Service  : active (since Thu 2026-09-25 21:00:00 MSK)
   Autostart: enabled
   Version  : 26.3.27
   Address  : 203.0.113.10
   SNI      : www.cloudflare.com
   Transport: TCP + XTLS Vision
   Clients  : 3
   Log      : journalctl -u xray

Select an option:
   1) Add a new client
   2) Remove an existing client
   3) Start / restart Xray
   4) Remove Xray
   5) Exit
   6) Client routing: Russian domains direct (INCY/Happ)
   7) Change server address (IP or domain)
```

If autostart at boot was turned off, the script re-enables it. A missing binary
or systemd unit is restored while preserving an existing config and credentials.
An existing config is never treated as a fresh installation.

One management operation runs at a time, using a shared `flock` lock. Config
changes are validated in a private temporary file beside the config, then saved
with a backup at `/etc/xray/config.json.bak`. If Xray cannot start with the new
config, the installer restores the previous config and attempts to restart it.
The backup contains private keys and should be protected like the active config.

New client links derive the REALITY public key from the active private key;
`public.key` is a cache and can be recovered if missing or stale. Removing a
client revokes its UUID and preserves the shared REALITY Short ID list, including
after manual client reordering. Short IDs are transport credentials, not a
per-user identity.

If the config was created by an older version without the private-address block,
the script offers to add it.

**Remove Xray** deletes the binary, configuration, service and BBR settings.

## Changing the Server Address

New client links use the address saved in `/etc/xray/server.addr`. The script
does not automatically update this value when the server's public IP changes.
Use menu option **7** to validate and save a new IPv4, IPv6 or domain for future
links. Saved domains, NAT endpoints and load-balancer addresses are preserved
until explicitly changed. Alternatively, run as root:

```bash
printf '%s\n' 'NEW_IP_OR_DOMAIN' > /etc/xray/server.addr
```

Existing links and QR images keep their previous address; update the server
address in each client manually. UUIDs, Short IDs and REALITY keys stay the same.
The address in this file is the connection endpoint, separate from the SNI
domain used for REALITY.

IPv6 addresses are bracketed correctly in client links. A fresh installation
with a literal IPv6 server address listens on `::`; other fresh installs listen
on `0.0.0.0`. Changing the advertised address alone does not change the listening
interfaces, so check the inbound `listen` setting when moving between IPv4 and
IPv6.

## Selecting an Xray Version

Fresh downloads verify the official `.zip.dgst` SHA-256 before extracting or
installing the binary. Downloads fail if the digest is missing or mismatched.
Set `XRAY_VERSION` to pin a release when downloading, for example:

```bash
sudo env XRAY_VERSION=v26.11.9 bash xray-install.sh
```

An existing Docker binary is reused; setting this variable does not upgrade it.

## Requirements

- Linux VPS (Debian, Ubuntu, CentOS, Fedora, Arch)
- Root access
- Port 443 open

The script installs all dependencies automatically.

## How It Works

REALITY is a next-gen security layer by the Xray team. It makes your VPN traffic indistinguishable from a regular HTTPS connection to a real website (the SNI site, e.g. `www.cloudflare.com`). Unlike traditional TLS proxies, REALITY requires no certificates and no domain — just a VPS with a public IP. On top of REALITY the traffic is carried either over TCP with XTLS Vision or over XHTTP (see below).

### Choosing the SNI site

The SNI site should be a foreign site that supports TLS 1.3 and HTTP/2 (required for XHTTP) and does not redirect to another domain — the script checks this during installation. Prefer a site hosted in the same network as your VPS over popular domains (Google, Microsoft, Apple): a VPS IP claiming to be one of them is easy to spot. Some sites pass the check but still fail with REALITY (e.g. `www.microsoft.com` with its very large certificate chain), so test a connection after installing.

## Transport: TCP + Vision or XHTTP

| | TCP + XTLS Vision | XHTTP |
|---|---|---|
| Client support | All apps | Apps with a recent Xray-core; see [Client Apps](#client-apps) |
| How it looks | One long TLS connection | HTTP requests (harder to fingerprint by connection pattern) |
| Flow | `xtls-rprx-vision` | none (Vision works only over TCP) |

XHTTP follows the [official Project X example](https://github.com/XTLS/Xray-examples/tree/main/VLESS-XHTTP-Reality):
only a random `path` is set, `mode` is `auto` (the client picks `stream-one` with REALITY),
everything else uses Xray defaults. Requires Xray-core v25.3.6 or newer. Do **not** enable
Mux (mux.cool) in the client app when using XHTTP.

The transport is chosen at install time; to switch, reinstall (clients get new links).

## Private Address Blocking

Clients can use the server only to reach the internet. Connections to the
server's own and internal addresses are dropped:

- `127.0.0.0/8`, `::1` — services on the server itself (databases, admin panels, APIs listening on localhost)
- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `fc00::/7` — provider/LAN networks, Docker host
- `169.254.0.0/16`, `fe80::/10` — link-local, including the cloud metadata service `169.254.169.254`

This also covers hostnames that resolve to these addresses (`localhost`, entries
from `/etc/hosts`, public domains pointing to `127.0.0.1`). Xray's own DNS queries
are routed directly, so a local system resolver keeps working. To allow access,
remove the `"outboundTag": "block"` rule from `routing.rules` in `/etc/xray/config.json`
and restart Xray.

## Client Apps

Import the generated URI or scan the QR code. All apps below support **TCP + XTLS Vision**.
**XHTTP** is an Xray-core feature: apps built on a recent Xray-core (v25.3.6+) support it,
apps built on sing-box usually do not.

| Platform | App | XHTTP |
|----------|-----|-------|
| iOS, Android, Windows, macOS, Linux | [Happ](https://happ.info/) | yes (recent Xray-core) |
| iOS, Android, Windows, macOS, Linux | [INCY](https://incy.cc/) | yes (recent Xray-core) |
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118), [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | check the app version |
| macOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118), [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | check the app version |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG) | yes (Xray-core) |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) | no (sing-box core) |
| Windows | [v2rayN](https://github.com/2dust/v2rayN) | yes (Xray-core) |
| Linux | [v2rayA](https://github.com/v2rayA/v2rayA) | yes, with Xray-core |
| Linux | [Nekoray](https://github.com/Mahdi-zarei/nekoray), [Hiddify](https://github.com/hiddify/hiddify-app) | usually no (sing-box core) |

Download the build for your platform from the official app sites linked above.
INCY's [desktop builds on GitHub](https://github.com/INCY-DEV/incy-platforms#desktop)
are currently pre-alpha.

Both apps support XHTTP; see the official [Happ](https://github.com/HappDev/happ_su/blob/main/dev-docs/app-management.md)
and [INCY](https://docs.incy.cc/share-links/) documentation for configuration details.
With XHTTP, keep **Mux** disabled in the app.

## Russian Domains Without VPN

Both scripts export a client routing profile after installation and when adding a
client. Existing users can generate it again with menu option **6**. The same
profile works with **INCY on Android/iPhone** and **Happ on Windows**; the script
prints a separate import link for each app and saves the links under `/etc/xray`.

1. Import the generated VLESS connection into your app.
2. Copy the `incy://routing/onadd/...` or `happ://routing/onadd/...` link and import
   it into that app, selecting the relevant connection/subscription if prompted.
3. Select the **Russian domains direct** profile, wait for its geo files to finish
   downloading, and reconnect the VPN.

The profile sends `.ru`, `.su`, `.рф` (`xn--p1ai`) and domains in
`geosite:category-ru` directly from your device. Local/private IP destinations also
connect directly. Other destinations use the VPN, including foreign domains
whose servers happen to have Russian IPs. The domain list is a classification,
so a Russian service missing from the list needs an additional direct rule;
foreign-operated sites using a listed suffix will also connect directly.

Routing takes effect on each client device after importing the profile. A
server-side `direct` rule would still carry traffic from your device to the VPN
server first. The exported profile contains no credentials and can be reused
across clients. For Happ on Windows, the app's active proxy/TUN mode determines
which traffic reaches its routing engine.

Import formats are documented by [INCY](https://docs.incy.cc/routing/) and
[Happ](https://docs.happ.info/main/dev-docs/routing). Geo files are downloaded by
the client from the [Loyalsoldier rule set](https://github.com/Loyalsoldier/v2ray-rules-dat).

## File Locations

| Path | Description |
|------|-------------|
| `/usr/local/bin/xray` | Xray-core binary |
| `/etc/xray/config.json` | Server configuration |
| `/etc/xray/config.json.bak` | Previous config saved before the latest change |
| `/etc/xray/public.key` | Recoverable REALITY public key cache |
| `/etc/xray/server.addr` | Server address (IP or domain) used in client links |
| `/etc/xray/vless-*.png` | QR code images |
| `/etc/xray/ru-direct.json` | Optional client routing profile for INCY/Happ |
| `/etc/xray/ru-direct-incy.txt`, `/etc/xray/ru-direct-happ.txt` | Client routing import links |
| `/etc/systemd/system/xray.service` | Systemd service unit |
| `/etc/sysctl.d/99-xray-bbr.conf` | TCP BBR settings |
| `/usr/local/bin/xray-autostart` | Docker background watchdog |
| `/usr/local/bin/xray-entrypoint` | Docker foreground startup command |
| `/etc/logrotate.d/xray-installer` | Docker background log rotation policy |

## Development Checks

Run syntax and regression checks with Bash, Python 3 and jq installed:

```bash
bash -n xray-install.sh
bash -n xray-install-docker.sh
python3 -m unittest discover -s tests -v
```

Tests use temporary configs and mocked service/process operations; they do not
install packages or write to `/etc`. `BASH_BIN` and `JQ_BIN` can select local
executables. Real lock contention is checked on Linux and skipped on Windows.
The Linux CI workflow also runs ShellCheck.

## License

MIT
