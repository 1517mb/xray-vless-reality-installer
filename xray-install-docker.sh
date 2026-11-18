#!/usr/bin/env bash

# ==============================================================================
# Xray VLESS + REALITY — Docker Management Script (no systemd)
# ------------------------------------------------------------------------------
# Same lifecycle as xray-install.sh, adapted for Docker containers without systemd:
#   - First run  : installs Xray-core with VLESS+REALITY (interactive prompts)
#   - Re-run     : management menu (status, add/remove clients, restart, uninstall)
#
# Differences from xray-install.sh:
#   - Xray runs as a background process (nohup), log in /var/log/xray.log
#   - No systemd unit, no dedicated user, no BBR (sysctl)
#   - Autostart without systemd: a cron check every minute (also restarts
#     Xray after a crash), else OpenRC local.d or /etc/rc.local at boot.
#     If none is available, start Xray from the menu after a container restart
#     or set your provider's startup command to /usr/local/bin/xray-entrypoint
#
# Publish port 443 of the container (e.g. docker run -p 443:443 ...).
#
# Usage on a host with Docker:
#   bash xray-install-docker.sh --deploy
#
# Usage (as root inside an existing container):
#   bash xray-install-docker.sh
#   bash xray-install-docker.sh --prepare    # install tools and launchers into an image
#   bash xray-install-docker.sh --configure  # initialize a prepared image's config volume
# ==============================================================================

set -euo pipefail
umask 077

CONFIG="/etc/xray/config.json"
SERVER_ADDR_FILE="/etc/xray/server.addr"
LOCK_FILE="/run/lock/xray-installer.lock"
# Private/local destinations clients must not reach through the proxy
# (server's localhost, LAN/provider networks, cloud metadata 169.254.169.254)
PRIVATE_IPS_JSON='["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"]'
XRAY_BIN="/usr/local/bin/xray"
XRAY_LOG="/var/log/xray.log"
LOGROTATE_CONF="/etc/logrotate.d/xray-installer"

# ==============================================================================
# Utility functions
# ==============================================================================

# Check whether a previous installation exists
is_xray_installed() {
    [[ -e "$CONFIG" || -L "$CONFIG" ]]
}

# Keep one installer operation active; the watchdog uses the same lock.
ensure_lock_tool() {
    command -v flock &>/dev/null && return 0
    echo ">>> Installing the configuration lock tool..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux
    elif command -v dnf &>/dev/null; then
        dnf install -y util-linux
    elif command -v yum &>/dev/null; then
        yum install -y util-linux
    elif command -v apk &>/dev/null; then
        apk add --no-cache util-linux
    elif command -v pacman &>/dev/null; then
        pacman -S --needed --noconfirm util-linux
    else
        echo "Install 'flock' (util-linux) before running this script." >&2
        return 1
    fi
    command -v flock &>/dev/null
}

acquire_install_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {INSTALL_LOCK_FD}>>"$LOCK_FILE"
    if ! flock -n "$INSTALL_LOCK_FD"; then
        echo "Another Xray management operation is running. Try again after it finishes." >&2
        return 1
    fi
}

# The runtime lock is local to a container. A second lock protects config data
# when separate installer and runtime containers share the same volume.
acquire_config_lock() {
    local dir="${CONFIG%/*}" lock_path
    lock_path="$dir/.xray-installer.lock"
    mkdir -p -- "$dir" || return 1
    if [[ -L "$lock_path" || ( -e "$lock_path" && ! -f "$lock_path" ) ]]; then
        echo "Cannot lock the configuration directory: $lock_path is not a regular file." >&2
        return 1
    fi
    exec {CONFIG_LOCK_FD}>>"$lock_path" || return 1
    flock -n "$CONFIG_LOCK_FD" && return 0
    [[ "${1:-}" == quiet ]] || echo "Could not lock the configuration directory. Try again after other Xray operations finish." >&2
    return 75
}

prepare_existing_install() {
    [[ -f "$CONFIG" ]] || { echo "Existing config path is not a regular file: $CONFIG" >&2; return 1; }
    if [[ ! -x "$XRAY_BIN" ]]; then
        echo ">>> Restoring the missing Xray binary; existing credentials will be preserved."
        install_deps || return 1
        install_xray_binary || return 1
    fi
    set_config_permissions || return 1
    setup_log_rotation || return 1
    setup_autostart
}

# Background-process logs need copytruncate because Xray keeps stdout open.
setup_log_rotation() {
    local rotation_tmp
    install -d -m 755 "$(dirname "$LOGROTATE_CONF")" || return 1
    rotation_tmp="$(mktemp "${LOGROTATE_CONF}.XXXXXX")" || return 1
    cat > "$rotation_tmp" <<ROTATE || { rm -f -- "$rotation_tmp"; return 1; }
"$XRAY_LOG" {
    daily
    maxsize 10M
    rotate 7
    compress
    delaycompress
    nodateext
    missingok
    notifempty
    copytruncate
    su root root
}
ROTATE
    chmod 644 "$rotation_tmp" || { rm -f -- "$rotation_tmp"; return 1; }
    mv -fT -- "$rotation_tmp" "$LOGROTATE_CONF" || { rm -f -- "$rotation_tmp"; return 1; }
}

# Resolve the server's public IPv4 address using external services.
# Leave stdout empty on failure so callers can request the address manually.
detect_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me; do
        ip="$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        # Accept only something that looks like an IPv4 address (not an error page)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"; return 0
        fi
    done
    return 0
}

# Return the server address clients connect to.
# Uses the address saved at install time; if it is missing,
# auto-detects (or asks) and saves it for next time.
validate_ipv4_address() {
    local address="$1" octet
    local octets=()
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

validate_server_address() {
    local address="$1" part left right suffix
    local groups=() labels=()
    [[ -n "$address" && ! "$address" =~ [[:space:]/@?#%] ]] || return 1
    if [[ "$address" == *:* ]]; then
        # IPv4-mapped IPv6 has the same width as two hexadecimal groups.
        if [[ "$address" == *.* ]]; then
            suffix="${address##*:}"
            validate_ipv4_address "$suffix" || return 1
            address="${address%:*}:0:0"
        fi
        [[ "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" != *:::* ]] || return 1
        if [[ "$address" == *::* ]]; then
            left="${address%%::*}"; right="${address#*::}"
            [[ "$right" != *::* && "$left" != :* && "$right" != *: ]] || return 1
            IFS=: read -r -a groups <<< "${left}${left:+:}${right}"
            (( ${#groups[@]} < 8 )) || return 1
        else
            [[ "$address" != :* && "$address" != *: ]] || return 1
            IFS=: read -r -a groups <<< "$address"
            (( ${#groups[@]} == 8 )) || return 1
        fi
        for part in "${groups[@]}"; do
            [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
        return 0
    fi
    if [[ "$address" =~ ^[0-9.]+$ ]]; then
        validate_ipv4_address "$address"
        return
    fi
    (( ${#address} <= 253 )) || return 1
    [[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$address"
    for part in "${labels[@]}"; do
        (( ${#part} <= 63 )) || return 1
        [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_sni_domain() {
    local domain="$1"
    [[ "$domain" != *:* && ! "$domain" =~ ^[0-9.]+$ ]] && validate_server_address "$domain"
}

validate_configuration_environment() {
    local server="${XRAY_SERVER_ADDRESS:-}" sni="${XRAY_SNI:-}"
    [[ -n "$server" || -n "$sni" ]] || return 0
    if [[ -z "$server" || -z "$sni" ]]; then
        echo "Set both XRAY_SERVER_ADDRESS and XRAY_SNI for unattended configuration." >&2
        return 1
    fi
    if [[ "$server" == \[*\] ]]; then server="${server:1:-1}"; fi
    if ! validate_server_address "$server" || ! validate_sni_domain "$sni"; then
        echo "Set XRAY_SERVER_ADDRESS to an IP or domain and XRAY_SNI to a domain, without a scheme or port." >&2
        return 1
    fi
}

format_uri_host() {
    local address="$1"
    validate_server_address "$address" || return 1
    if [[ "$address" == *:* ]]; then printf '[%s]\n' "$address"; else printf '%s\n' "$address"; fi
}

# Metadata is committed atomically in the same directory with private permissions.
write_private_file() {
    local path="$1" value="$2" tmp
    tmp=$(mktemp "$(dirname "$path")/.xray-write.XXXXXX") || return 1
    if ! chmod 600 "$tmp" || ! printf '%s\n' "$value" > "$tmp" || ! mv -fT -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
}

get_server_address() {
    local server=""
    [[ -f "$SERVER_ADDR_FILE" ]] && server="$(head -n1 "$SERVER_ADDR_FILE")"
    if [[ -z "$server" ]]; then
        server="$(detect_public_ip)" || return 1
        if ! validate_server_address "$server"; then
            echo "Unable to auto-detect public IP." >&2
            read -rp "Enter the server's public IP or domain: " server || return 1
            if [[ "$server" == \[*\] ]]; then server="${server:1:-1}"; fi
        fi
        validate_server_address "$server" || { echo "Invalid server address. Enter an IP or domain without a scheme or port." >&2; return 1; }
        write_private_file "$SERVER_ADDR_FILE" "$server" || return 1
    fi
    validate_server_address "$server" || { echo "Saved server address is invalid. Use 'Change server address' to update it." >&2; return 1; }
    printf '%s\n' "$server"
}

change_server_address() {
    local current="" server answer
    [[ -f "$SERVER_ADDR_FILE" ]] && current="$(head -n1 "$SERVER_ADDR_FILE")"
    read -rp "New server IP or domain [${current:-not saved}] (Enter to cancel): " server || return 1
    [[ -n "$server" ]] || { echo "Aborted."; return 0; }
    if [[ "$server" == \[*\] ]]; then server="${server:1:-1}"; fi
    validate_server_address "$server" || { echo "Invalid server address. Enter an IP or domain without a scheme or port." >&2; return 1; }
    read -rp "Use $server in new client links? [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
    write_private_file "$SERVER_ADDR_FILE" "$server" || return 1
    echo "Server address updated. Update the address in existing client apps; old links and QR codes are unchanged."
}

validate_server_port() {
    local port="$1"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 ))
}

# --deploy publishes container port 443. Bind links to the corresponding host
# port, including when a named volume survives recreating the container.
save_deployment_port() {
    local port="${XRAY_DOCKER_PORT:-}" config="$1"
    [[ -n "$port" ]] || return 0
    if ! validate_server_port "$port"; then
        echo "XRAY_DOCKER_PORT must be a port from 1 to 65535." >&2
        return 1
    fi
    if ! jq -e '.inbounds[0].port | tostring == "443"' "$config" >/dev/null; then
        echo "The existing configuration must listen on container port 443 for --deploy." >&2
        return 1
    fi
    write_private_file "${SERVER_ADDR_FILE%/*}/server.port" "$port"
}

get_server_port() {
    local port_file="${SERVER_ADDR_FILE%/*}/server.port" port
    if [[ -e "$port_file" || -L "$port_file" ]]; then
        port="$(head -n1 "$port_file")" || return 1
    else
        port="$(jq -er '.inbounds[0].port // 443' "$CONFIG")" || return 1
    fi
    if ! validate_server_port "$port"; then
        echo "Invalid client port. Set a port from 1 to 65535 using 'Change external port'." >&2
        return 1
    fi
    printf '%s\n' "$port"
}

change_server_port() {
    local port_file="${SERVER_ADDR_FILE%/*}/server.port" port current
    current="$(get_server_port 2>/dev/null || true)"
    read -rp "External port [${current:-unknown}] ('auto' for configured inbound port, Enter to cancel): " port || return 1
    [[ -n "$port" ]] || { echo "Aborted."; return 0; }
    if [[ "$port" == auto ]]; then
        rm -f -- "$port_file" || return 1
        echo "New links will use the port from the server configuration."
        return 0
    fi
    validate_server_port "$port" || { echo "Enter a port from 1 to 65535." >&2; return 1; }
    write_private_file "$port_file" "$port" || return 1
    echo "External port saved for new client links."
}

# Derive the public key from the active config; the separate file is only a cache.
get_public_key() {
    local private_key public_key
    private_key=$(jq -er '.inbounds[0].streamSettings.realitySettings.privateKey | select(type == "string" and length > 0)' "$CONFIG") || {
        echo "Cannot read the REALITY private key from the active configuration." >&2; return 1;
    }
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || {
        echo "The active configuration has an invalid REALITY private key." >&2; return 1;
    }
    command -v openssl &>/dev/null || { echo "Install OpenSSL to derive the REALITY public key." >&2; return 1; }
    # RFC 8410 PKCS#8 prefix followed by the raw X25519 key. Keep the secret
    # on stdin: xray's -i argument would expose it in process listings.
    if ! public_key=$(
        {
            printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
            printf '%s=' "$private_key" | tr '_-' '/+' | base64 -d
        } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null \
          | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\r\n'
    ); then
        echo "Cannot derive the REALITY public key from the active configuration." >&2
        return 1
    fi
    [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo "OpenSSL returned an invalid REALITY public key." >&2; return 1; }
    write_private_file "$(dirname "$CONFIG")/public.key" "$public_key" || return 1
    printf '%s\n' "$public_key"
}

# Generate a random UUID using the best available method
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        "$XRAY_BIN" uuid
    fi
}

# Generate an 8-char hex Short ID that does not collide with existing ones
# $1 — space-separated list of existing Short IDs (optional)
generate_short_id() {
    local existing="${1:-}"
    local sid=""
    for _ in {1..10}; do
        if command -v openssl &>/dev/null; then
            sid="$(openssl rand -hex 4)" || return 1
        else
            sid="$(od -An -N4 -tx1 /dev/urandom | tr -d '[:space:]')" || return 1
        fi
        [[ "$sid" =~ ^[0-9a-f]{8}$ ]] || { echo "Failed to generate a Short ID." >&2; return 1; }
        # Return immediately if unique
        if [[ " $existing " != *" $sid "* ]]; then
            echo "$sid"; return 0
        fi
    done
    echo "Unable to generate a unique Short ID after 10 attempts." >&2
    return 1
}

# Restrict permissions on config.json and /etc/xray/ (Xray runs as root here)
set_config_permissions() {
    local path="${1:-$CONFIG}"
    chmod 750 "$(dirname "$path")" || return 1
    chmod 640 "$path" || return 1
}

# Callers hold the installer lock throughout reading, editing and committing.
# Keep a private backup and restore it if the new configuration cannot run.
apply_config_change() {
    local tmp="$1" dir backup_tmp restore_tmp
    dir="$(dirname "$CONFIG")"
    if [[ "$tmp" == "$CONFIG" || "$(dirname "$tmp")" != "$dir" ]]; then
        echo "Configuration changes must use a temporary file next to $CONFIG." >&2
        return 1
    fi
    if ! set_config_permissions "$tmp" || ! validate_config "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if declare -F can_restart_xray >/dev/null && ! can_restart_xray; then
        rm -f -- "$tmp"
        return 1
    fi
    backup_tmp=$(mktemp "$dir/.config-backup.XXXXXX") || { rm -f -- "$tmp"; return 1; }
    if ! cp -- "$CONFIG" "$backup_tmp" || ! chmod 600 "$backup_tmp" || ! mv -fT -- "$backup_tmp" "${CONFIG}.bak"; then
        rm -f -- "$tmp" "$backup_tmp"
        echo "Could not back up the configuration; no changes were applied." >&2
        return 1
    fi
    if ! mv -fT -- "$tmp" "$CONFIG"; then
        rm -f -- "$tmp"
        echo "Could not replace $CONFIG. Mount the configuration directory, rather than an individual file." >&2
        return 1
    fi
    if restart_xray; then
        return 0
    fi

    echo "New configuration failed to start; restoring ${CONFIG}.bak..." >&2
    restore_tmp=$(mktemp "$dir/.config-restore.XXXXXX") || {
        echo "Could not prepare rollback. The previous configuration is saved in ${CONFIG}.bak." >&2; return 1;
    }
    if ! cp -- "${CONFIG}.bak" "$restore_tmp" || ! set_config_permissions "$restore_tmp" || ! mv -fT -- "$restore_tmp" "$CONFIG"; then
        rm -f -- "$restore_tmp"
        echo "Could not restore the configuration. Recover it from ${CONFIG}.bak." >&2
        return 1
    fi
    if restart_xray; then
        echo "Previous configuration restored and Xray restarted. The requested change was not applied." >&2
    else
        echo "Previous configuration restored, but Xray could not restart. Check its logs." >&2
    fi
    return 1
}

# Validate an Xray config file; print Xray's output and fail if it is invalid
# $1 — path to config (optional, defaults to $CONFIG)
validate_config() {
    local path="${1:-$CONFIG}" output
    # Xray also checks the extension of local files with an explicit format.
    if ! output=$("$XRAY_BIN" run -test -format json -config stdin: 2>&1 < "$path"); then
        echo "Xray config validation failed ($path):" >&2
        echo "$output" >&2
        return 1
    fi
}

# Check whether the config already blocks private destinations
has_private_block() {
    jq -e '[.routing.rules[]? | select(.outboundTag == "block")] | length > 0' "$CONFIG" &>/dev/null
}

# Add the private-address block to an existing config (older installs):
# tag DNS and outbounds, route Xray's own DNS queries directly (the system
# resolver may be 127.0.0.53 / 127.0.0.11), send private IPs to blackhole.
# freedom uses ForceIP: with UseIP, names Xray's DNS can't resolve (localhost,
# entries from /etc/hosts) fall back to the system resolver and bypass the block.
add_private_block() {
    local tmp
    tmp=$(mktemp "$(dirname "$CONFIG")/.config.XXXXXX") || return 1
    jq --argjson ips "$PRIVATE_IPS_JSON" '
        .dns.tag = "dns-internal" |
        .outbounds = ((.outbounds // []) | map(if .protocol == "freedom" then (.tag //= "direct") | .settings.domainStrategy = "ForceIP" else . end)) |
        (if any(.outbounds[]; .tag == "block") then . else .outbounds += [{"tag": "block", "protocol": "blackhole"}] end) |
        .routing.domainStrategy = "IPIfNonMatch" |
        .routing.rules = [
            {"type": "field", "inboundTag": ["dns-internal"], "outboundTag": "direct"},
            {"type": "field", "ip": $ips, "outboundTag": "block"}
        ] + ((.routing.rules // []) | map(select(.outboundTag != "block" and .inboundTag != ["dns-internal"])))
    ' "$CONFIG" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    apply_config_change "$tmp" || return 1
    echo ">>> Access to private/local addresses is now blocked."
}

# Offer the private-address block if the config does not have it yet
offer_private_block() {
    command -v jq &>/dev/null || return 0
    # Only touch a config Xray accepts; a broken one is reported by start/restart
    validate_config &>/dev/null || return 0
    has_private_block && return 0
    echo ""
    echo "Your config lets clients reach the server's local and private addresses"
    echo "(localhost services, internal networks, cloud metadata)."
    local answer
    read -rp "Block them now? [Y/n]: " answer || return 1
    [[ "$answer" =~ ^[Nn]$ ]] || add_private_block
}

# ==============================================================================
# Process management (no systemd)
# ==============================================================================

XRAY_PROC_ROOT="/proc"

# Match the complete argument vector, including the exact configuration path.
# Validation commands and instances using another config must never be signalled.
is_xray_pid() {
    local pid="$1" arg
    local -a args=()
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r "$XRAY_PROC_ROOT/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < "$XRAY_PROC_ROOT/$pid/cmdline" 2>/dev/null || return 1
    [[ ${#args[@]} -eq 4 ]] &&
        [[ "${args[0]}" == "$XRAY_BIN" ]] &&
        [[ "${args[1]}" == "run" ]] &&
        [[ "${args[2]}" == "-config" ]] &&
        [[ "${args[3]}" == "$CONFIG" ]]
}

xray_pids() {
    local path pid
    for path in "$XRAY_PROC_ROOT"/[0-9]*/cmdline; do
        pid="${path%/cmdline}"; pid="${pid##*/}"
        if is_xray_pid "$pid"; then
            printf '%s\n' "$pid"
        fi
    done
}

xray_pid() {
    xray_pids | head -n1 || true
}

is_xray_running() {
    [[ -n "$(xray_pid)" ]]
}

# Linux keeps the process start time across exec. Parse after the final ") "
# because the command name in /proc/PID/stat may itself contain spaces or ")".
process_start_time() {
    local pid="$1" stat_line
    local -a fields=()
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "$XRAY_PROC_ROOT/$pid/stat" || return 1
    [[ "$stat_line" == "$pid ("* && "$stat_line" == *") "* ]] || return 1
    IFS=' ' read -r -a fields <<< "${stat_line##*) }"
    (( ${#fields[@]} >= 20 )) || return 1
    [[ "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

# Call under LOCK_FILE. A live claim covers the close-lock-to-exec interval;
# the start time prevents an old claim from matching an unrelated reused PID.
# Return 0 for a live claim, 1 for no claim, and 2 if stale state cannot be removed.
has_live_entrypoint_claim() {
    local state_file="${LOCK_FILE}.entrypoint" pid started extra current
    [[ -e "$state_file" || -L "$state_file" ]] || return 1
    if IFS=' ' read -r pid started extra < "$state_file" &&
       [[ "$pid" =~ ^[1-9][0-9]*$ && "$started" =~ ^[0-9]+$ && -z "$extra" ]] &&
       current="$(process_start_time "$pid")" && [[ "$current" == "$started" ]]; then
        return 0
    fi
    rm -f -- "$state_file" || { echo "Could not remove stale Xray entrypoint state." >&2; return 2; }
    return 1
}

write_entrypoint_claim() {
    local pid="$1" started tmp state_file="${LOCK_FILE}.entrypoint"
    started="$(process_start_time "$pid")" || { echo "Cannot identify the foreground entrypoint process." >&2; return 1; }
    tmp="$(mktemp "${state_file}.XXXXXX")" || return 1
    if ! chmod 600 "$tmp" || ! printf '%s %s\n' "$pid" "$started" > "$tmp" || ! mv -fT -- "$tmp" "$state_file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Start Xray in the background and make sure it is actually running
start_xray() {
    if is_xray_running; then
        echo ">>> Xray is already running (PID $(xray_pid))."
        return 0
    fi
    local claim_status
    if has_live_entrypoint_claim; then
        echo "A foreground Xray entrypoint is starting; manage its lifecycle through Docker or your provider's panel." >&2
        return 1
    else
        claim_status=$?
        [[ "$claim_status" == 1 ]] || return 1
    fi
    validate_config || return 1
    if [[ -L "$XRAY_LOG" || ( -e "$XRAY_LOG" && ! -f "$XRAY_LOG" ) ]] ||
       ! { : >> "$XRAY_LOG" && chmod 600 -- "$XRAY_LOG"; }; then
        echo "Could not prepare the private Xray log at $XRAY_LOG." >&2
        return 1
    fi
    echo ">>> Starting Xray..."
    (
        # The server must not retain the installer's configuration lock.
        if [[ -n "${INSTALL_LOCK_FD:-}" ]]; then
            exec {INSTALL_LOCK_FD}>&-
        fi
        if [[ -n "${CONFIG_LOCK_FD:-}" ]]; then
            exec {CONFIG_LOCK_FD}>&-
        fi
        exec nohup "$XRAY_BIN" run -config "$CONFIG"
    ) < /dev/null >> "$XRAY_LOG" 2>&1 &
    local started_pid=$!
    sleep 2
    if is_xray_pid "$started_pid"; then
        echo ">>> Xray started (PID $started_pid)."
    else
        echo "Xray failed to start. Recent log ($XRAY_LOG):" >&2
        tail -n 20 "$XRAY_LOG" >&2 2>/dev/null || true
        return 1
    fi
}

# Stopping PID 1 terminates the container, so its lifecycle belongs to Docker.
can_restart_xray() {
    if is_xray_pid 1; then
        echo "Xray is the container's main process (PID 1). Restart or stop the container through Docker or your provider's panel." >&2
        return 1
    fi
    local claim_status
    if has_live_entrypoint_claim; then
        echo "Xray is managed by a foreground entrypoint. Restart or stop the container through Docker or your provider's panel." >&2
        return 1
    else
        claim_status=$?
        [[ "$claim_status" == 1 ]] || return 1
    fi
    return 0
}

# Stop Xray and wait until it has exited (so port 443 is free for a restart)
stop_xray() {
    can_restart_xray || return 1
    is_xray_running || return 0
    local pid
    local -a pids=()
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(xray_pids)
    echo ">>> Stopping Xray..."
    for pid in "${pids[@]}"; do
        if is_xray_pid "$pid"; then
            kill -TERM -- "$pid" 2>/dev/null || true
        fi
    done
    for _ in {1..10}; do
        is_xray_running || { echo ">>> Xray stopped."; return 0; }
        sleep 0.5
    done
    for pid in "${pids[@]}"; do
        # Recheck identity before escalation in case the original process exited.
        if is_xray_pid "$pid"; then
            kill -KILL -- "$pid" 2>/dev/null || true
        fi
    done
    for _ in {1..10}; do
        is_xray_running || { echo ">>> Xray stopped."; return 0; }
        sleep 0.1
    done
    echo "Xray is still running; refusing to start a second instance." >&2
    return 1
}

restart_xray() {
    validate_config || return 1
    can_restart_xray || return 1
    stop_xray || return 1
    start_xray
}

# ==============================================================================
# Autostart (no systemd): cron watchdog, OpenRC local.d or rc.local
# ==============================================================================

AUTOSTART_BIN="/usr/local/bin/xray-autostart"
ENTRYPOINT_BIN="/usr/local/bin/xray-entrypoint"
AUTOSTART_MARKER="# xray-autostart"
OPENRC_LOCAL="/etc/local.d/xray.start"
RC_LOCAL="/etc/rc.local"

write_launcher_header() {
    printf '#!/usr/bin/env bash\n%s\nset -euo pipefail\numask 077\n' "$AUTOSTART_MARKER"
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf 'XRAY_BIN=%q\nCONFIG=%q\nXRAY_LOG=%q\nLOCK_FILE=%q\nXRAY_PROC_ROOT=%q\nLOGROTATE_CONF=%q\n' \
        "$XRAY_BIN" "$CONFIG" "$XRAY_LOG" "$LOCK_FILE" "$XRAY_PROC_ROOT" "$LOGROTATE_CONF"
}

# Generate independent launchers: a locked background watchdog for init/cron,
# and a foreground entrypoint whose exec makes Xray the container's main process.
write_autostart_launcher() (
    local autostart_tmp="" entrypoint_tmp=""
    trap 'rm -f "$autostart_tmp" "$entrypoint_tmp"' EXIT
    autostart_tmp=$(mktemp "${AUTOSTART_BIN}.XXXXXX") || return 1
    entrypoint_tmp=$(mktemp "${ENTRYPOINT_BIN}.XXXXXX") || return 1
    {
        write_launcher_header
        declare -f acquire_config_lock validate_config is_xray_pid xray_pids xray_pid is_xray_running process_start_time has_live_entrypoint_claim start_xray
        cat <<'LAUNCHER'
[[ -x "$XRAY_BIN" && -f "$CONFIG" ]] || exit 0
command -v flock >/dev/null 2>&1 || { echo "flock is required for Xray autostart." >&2; exit 1; }
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
if acquire_config_lock quiet; then
    :
else
    status=$?
    [[ "$status" == 75 ]] && exit 0
    exit "$status"
fi
if command -v logrotate >/dev/null 2>&1 && [[ -f "$LOGROTATE_CONF" ]]; then
    logrotate "$LOGROTATE_CONF" || echo "Xray log rotation failed; check logrotate configuration." >&2
fi
if has_live_entrypoint_claim; then
    exit 0
else
    [[ "$?" == 1 ]] || exit 1
fi
is_xray_running && exit 0
INSTALL_LOCK_FD=9
start_xray
LAUNCHER
    } > "$autostart_tmp" || return 1
    {
        write_launcher_header
        declare -f acquire_config_lock validate_config is_xray_pid xray_pids xray_pid is_xray_running process_start_time has_live_entrypoint_claim write_entrypoint_claim
        cat <<'ENTRYPOINT'
[[ -x "$XRAY_BIN" && -f "$CONFIG" ]] || { echo "Xray binary or configuration is missing." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock is required for the Xray entrypoint." >&2; exit 1; }
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock 9
acquire_config_lock || exit 1
if has_live_entrypoint_claim; then
    echo "A foreground Xray entrypoint is already active." >&2
    exit 1
else
    [[ "$?" == 1 ]] || exit 1
fi
if is_xray_running; then
    echo "Xray is already running. Use a single foreground entrypoint per container." >&2
    exit 1
fi
validate_config || exit 1
write_entrypoint_claim "$$" || exit 1
exec {CONFIG_LOCK_FD}>&-
exec 9>&-
exec "$XRAY_BIN" run -config "$CONFIG"
ENTRYPOINT
    } > "$entrypoint_tmp" || return 1
    chmod 755 "$autostart_tmp" "$entrypoint_tmp" || return 1
    mv -fT -- "$autostart_tmp" "$AUTOSTART_BIN" || return 1
    mv -fT -- "$entrypoint_tmp" "$ENTRYPOINT_BIN"
)

# Is a cron daemon running in this container right now?
cron_running() {
    command -v crontab &>/dev/null || return 1
    pgrep -x cron &>/dev/null || pgrep -x crond &>/dev/null || pgrep -f 'busybox crond' &>/dev/null
}

# Print the autostart hook that is currently installed: cron|openrc|rc.local|none
autostart_mechanism() {
    if crontab -l 2>/dev/null | grep -xF -- "* * * * * $AUTOSTART_BIN $AUTOSTART_MARKER" >/dev/null; then
        echo "cron"
    elif grep -qxF -- "$AUTOSTART_MARKER" "$OPENRC_LOCAL" 2>/dev/null; then
        echo "openrc"
    elif grep -qxF -- "$AUTOSTART_BIN $AUTOSTART_MARKER" "$RC_LOCAL" 2>/dev/null; then
        echo "rc.local"
    else
        echo "none"
    fi
}

# Refresh launchers on every run, preserving an already installed init/cron hook.
setup_autostart() {
    write_autostart_launcher || return 1
    [[ "$(autostart_mechanism)" != "none" ]] && return 0

    if cron_running; then
        # Every minute: covers container restarts and Xray crashes.
        # (busybox crond has no @reboot, so a per-minute check is used everywhere)
        { crontab -l 2>/dev/null || true; echo "* * * * * $AUTOSTART_BIN $AUTOSTART_MARKER"; } | crontab - || return 1
        echo ">>> Autostart: cron checks Xray every minute and starts it if needed."
    elif [[ -d /run/openrc ]] && command -v rc-update &>/dev/null; then
        if [[ -e "$OPENRC_LOCAL" || -L "$OPENRC_LOCAL" ]]; then
            echo "The OpenRC hook $OPENRC_LOCAL is already in use. Configure $ENTRYPOINT_BIN for automatic startup." >&2
            return 0
        fi
        mkdir -p "$(dirname "$OPENRC_LOCAL")" || return 1
        if ! printf '#!/bin/sh\n%s\n%s\n' "$AUTOSTART_MARKER" "$AUTOSTART_BIN" > "$OPENRC_LOCAL" ||
           ! chmod 755 "$OPENRC_LOCAL" || ! rc-update add local default; then
            rm -f "$OPENRC_LOCAL" || true
            echo "Could not install the OpenRC autostart hook." >&2
            return 1
        fi
        echo ">>> Autostart: OpenRC starts Xray at container boot ($OPENRC_LOCAL)."
    elif [[ -f "$RC_LOCAL" ]] && [[ "$(cat /proc/1/comm 2>/dev/null)" == "init" ]]; then
        if grep -q '^exit 0' "$RC_LOCAL"; then
            sed -i "0,/^exit 0/s|^exit 0|$AUTOSTART_BIN $AUTOSTART_MARKER\nexit 0|" "$RC_LOCAL" || return 1
        else
            echo "$AUTOSTART_BIN $AUTOSTART_MARKER" >> "$RC_LOCAL" || return 1
        fi
        chmod +x "$RC_LOCAL" || return 1
        echo ">>> Autostart: $RC_LOCAL starts Xray at container boot."
    else
        echo "Warning: no cron, OpenRC or rc.local found — Xray will not start automatically." >&2
        echo "For a Docker CMD/ENTRYPOINT or provider startup command, use: $ENTRYPOINT_BIN" >&2
        return 0
    fi
}

# Remove every autostart hook and the launcher
remove_autostart() {
    local cron_line="* * * * * $AUTOSTART_BIN $AUTOSTART_MARKER" cron_entries
    if cron_entries=$(crontab -l 2>/dev/null) && grep -qxF -- "$cron_line" <<< "$cron_entries"; then
        # grep -v exits 1 when our line was the only one — that is fine
        { grep -vxF -- "$cron_line" <<< "$cron_entries" || true; } | crontab - || return 1
    fi
    if grep -qxF -- "$AUTOSTART_MARKER" "$OPENRC_LOCAL" 2>/dev/null; then
        rm -f -- "$OPENRC_LOCAL" || return 1
    fi
    if grep -qxF -- "$AUTOSTART_BIN $AUTOSTART_MARKER" "$RC_LOCAL" 2>/dev/null; then
        sed -i "\|^$AUTOSTART_BIN $AUTOSTART_MARKER\$|d" "$RC_LOCAL" || return 1
    fi
    rm -f -- "$AUTOSTART_BIN" "$ENTRYPOINT_BIN" "${LOCK_FILE}.entrypoint" || return 1
}

# Human-readable autostart state for the status block
autostart_status() {
    if is_xray_pid 1; then
        echo "container entrypoint (PID 1)"
        return 0
    fi
    if has_live_entrypoint_claim; then
        echo "container entrypoint (foreground)"
        return 0
    fi
    case "$(autostart_mechanism)" in
        cron)
            if cron_running; then
                echo "cron (checks every minute)"
            else
                echo "cron (daemon stopped)"
            fi
            ;;
        openrc)   echo "OpenRC (at container boot)" ;;
        rc.local) echo "rc.local (at container boot)" ;;
        *)        echo "none (use $ENTRYPOINT_BIN as the container startup command)" ;;
    esac
}

# ==============================================================================
# Packages
# ==============================================================================

# Install jq if it is not already present
ensure_jq() {
    command -v jq &>/dev/null && return 0
    echo ">>> Installing jq..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y jq
    elif command -v dnf &>/dev/null; then
        dnf install -y jq
    elif command -v yum &>/dev/null; then
        yum install -y epel-release && yum install -y jq
    elif command -v apk &>/dev/null; then
        apk add --no-cache jq
    elif command -v pacman &>/dev/null; then
        pacman -S --needed --noconfirm jq
    else
        echo "Please install 'jq' manually." >&2; exit 1
    fi
}

# Install all required packages for a fresh installation
# (procps provides pgrep/pkill, which minimal images often lack)
install_deps() {
    echo -e "\n>>> Installing dependencies..."
    local -a package_install
    local qr_package=qrencode
    if command -v apt-get &>/dev/null; then
        apt-get update -y || return 1
        package_install=(env DEBIAN_FRONTEND=noninteractive apt-get install -y)
        "${package_install[@]}" curl ca-certificates unzip tar uuid-runtime jq openssl procps util-linux logrotate || return 1
    elif command -v dnf &>/dev/null; then
        package_install=(dnf install -y)
        "${package_install[@]}" curl ca-certificates unzip tar jq openssl procps-ng util-linux logrotate || return 1
    elif command -v yum &>/dev/null; then
        package_install=(yum install -y)
        "${package_install[@]}" epel-release || return 1
        "${package_install[@]}" curl ca-certificates unzip tar jq openssl procps-ng util-linux logrotate || return 1
    elif command -v apk &>/dev/null; then
        package_install=(apk add --no-cache)
        qr_package=libqrencode-tools
        "${package_install[@]}" curl ca-certificates unzip tar jq openssl procps-ng util-linux logrotate || return 1
    elif command -v pacman &>/dev/null; then
        package_install=(pacman -S --needed --noconfirm)
        "${package_install[@]}" curl ca-certificates unzip tar jq openssl procps-ng util-linux logrotate || return 1
    else
        echo "Unsupported package manager. Install dependencies manually." >&2
        return 1
    fi
    if ! command -v qrencode &>/dev/null && ! "${package_install[@]}" "$qr_package"; then
        echo "Optional qrencode package unavailable. The installer will display client links as text." >&2
    fi
}

# Check the release archive before installing executable code.
verify_xray_checksum() {
    local archive="$1" digest_file="$2" expected actual
    expected="$(awk -F '=' '/^SHA(2-)?256[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print tolower($2)}' "$digest_file")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Missing or invalid SHA256 in the Xray release digest." >&2; return 1;
    }
    actual="$(sha256sum "$archive" | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]] || {
        echo "Xray archive SHA256 verification failed." >&2; return 1;
    }
}

# Also used to repair an interrupted install without touching its configuration.
install_xray_binary() (
    local version="${XRAY_VERSION:-}" arch_pkg tmp_dir staged_bin="" zip_name url
    if [[ -z "$version" ]]; then
        version="$(curl -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty')" || return 1
    fi
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Unable to determine a valid Xray release version." >&2; return 1;
    }
    case "$(uname -m)" in
        x86_64|amd64)  arch_pkg="Xray-linux-64" ;;
        aarch64|arm64) arch_pkg="Xray-linux-arm64-v8a" ;;
        armv7l)        arch_pkg="Xray-linux-arm32-v7a" ;;
        armv6l)        arch_pkg="Xray-linux-arm32-v6" ;;
        *) echo "Unsupported CPU architecture: $(uname -m)" >&2; return 1 ;;
    esac
    tmp_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$tmp_dir"; [[ -z "$staged_bin" ]] || rm -f -- "$staged_bin"' EXIT
    zip_name="$arch_pkg.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/$version/$zip_name"
    echo ">>> Downloading Xray-core $version ($arch_pkg)..."
    curl -fL --connect-timeout 10 --max-time 300 "$url" -o "$tmp_dir/$zip_name" || return 1
    curl -fsSL --connect-timeout 10 --max-time 60 "$url.dgst" -o "$tmp_dir/$zip_name.dgst" || return 1
    verify_xray_checksum "$tmp_dir/$zip_name" "$tmp_dir/$zip_name.dgst" || return 1
    unzip -qo "$tmp_dir/$zip_name" -d "$tmp_dir" || return 1
    "$tmp_dir/xray" version >/dev/null || return 1
    install -d "$(dirname "$XRAY_BIN")" || return 1
    staged_bin="$(mktemp "$(dirname "$XRAY_BIN")/.xray.XXXXXX")" || return 1
    install -m 755 "$tmp_dir/xray" "$staged_bin" || return 1
    mv -fT -- "$staged_bin" "$XRAY_BIN" || return 1
)

prepare_image() {
    install_deps || return 1
    if [[ ! -x "$XRAY_BIN" ]]; then
        install_xray_binary || return 1
    fi
    write_autostart_launcher
}

# Existing installations may predate the cryptographic-tool dependency.
ensure_crypto_tool() {
    command -v openssl &>/dev/null && return 0
    echo ">>> Installing OpenSSL to derive the REALITY public key..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y openssl
    elif command -v yum &>/dev/null; then
        yum install -y openssl
    elif command -v apk &>/dev/null; then
        apk add --no-cache openssl
    elif command -v pacman &>/dev/null; then
        pacman -S --needed --noconfirm openssl
    else
        echo "Install OpenSSL before adding clients." >&2
        return 1
    fi
    command -v openssl &>/dev/null
}

# Check the REALITY target against Project X's minimum requirements:
# TLS 1.3, HTTP/2 (needed by XHTTP) and no redirect to another domain.
# Warns and asks before continuing; network problems look the same as "no TLS 1.3".
check_sni_target() {
    local sni="$1" validation="${2:-interactive}" result http_ver code redirect redirect_host answer
    local problems=()
    echo -e "\n>>> Checking SNI target https://$sni (TLS 1.3, HTTP/2, no redirect)..."
    result="$(curl -sS -o /dev/null --tlsv1.3 --http2 --connect-timeout 5 --max-time 10 \
        -w '%{http_version} %{http_code} %{redirect_url}' "https://$sni/" 2>/dev/null || true)"
    read -r http_ver code redirect <<< "$result"
    if [[ -z "$code" || "$code" == "000" ]]; then
        problems+=("no TLS 1.3 connection (site unreachable or TLS 1.3 not supported)")
    else
        [[ "$http_ver" == "2" ]] || problems+=("no HTTP/2 support (got HTTP/$http_ver)")
        if [[ -n "${redirect:-}" ]]; then
            redirect_host="${redirect#*://}"; redirect_host="${redirect_host%%[/:?]*}"
            [[ "$redirect_host" == "$sni" ]] || problems+=("redirects to another domain: $redirect_host")
        fi
    fi
    if (( ${#problems[@]} == 0 )); then
        echo ">>> SNI target looks good."
        return 0
    fi
    echo "Warning: $sni does not meet REALITY target requirements:" >&2
    printf '   - %s\n' "${problems[@]}" >&2
    if [[ "$validation" == strict ]]; then
        echo "Set XRAY_SNI to a reachable domain that passes the checks." >&2
        return 1
    fi
    read -rp "Continue anyway? [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted. Choose another SNI domain." >&2; return 1; }
}

# Export client-side routing for INCY and Happ; the server config is unchanged.
show_client_routing() {
    local dir profile profile_json payload incy_link happ_link
    dir="$(dirname "$CONFIG")"
    profile="$dir/ru-direct.json"
    profile_json=$(cat <<'ROUTING'
{
  "Name": "Russian domains direct",
  "GlobalProxy": "true",
  "RemoteDNSType": "DoH",
  "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
  "RemoteDNSIP": "1.1.1.1",
  "DomesticDNSType": "DoU",
  "DomesticDNSDomain": "",
  "DomesticDNSIP": "1.1.1.1",
  "Geoipurl": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
  "Geositeurl": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
  "DirectSites": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"],
  "DirectIp": ["geoip:private"],
  "ProxySites": [],
  "ProxyIp": [],
  "BlockSites": [],
  "BlockIp": [],
  "DomainStrategy": "AsIs",
  "FakeDNS": "false"
}
ROUTING
    ) || return 1
    payload="$(jq -ce . <<< "$profile_json" | base64 | tr -d '\r\n')" || return 1
    [[ -n "$payload" ]] || return 1
    incy_link="incy://routing/onadd/$payload"
    happ_link="happ://routing/onadd/$payload"
    write_private_file "$profile" "$profile_json" || return 1
    write_private_file "$dir/ru-direct-incy.txt" "$incy_link" || return 1
    write_private_file "$dir/ru-direct-happ.txt" "$happ_link" || return 1

    echo ""
    echo "Optional client routing: Russian domains direct, other destinations via VPN."
    echo "Import the VLESS link first, then import the routing link for your app:"
    printf '\nINCY (Android/iPhone):\n%s\n' "$incy_link"
    printf '\nHapp (Windows):\n%s\n' "$happ_link"
    echo ""
    echo "Select the profile, wait for geo files to download, then reconnect the VPN."
    echo "This profile covers .ru/.su/.xn--p1ai and the category-ru domain list."
    echo "Profile saved to: $profile"
    echo "Import links saved to: $dir/ru-direct-incy.txt and $dir/ru-direct-happ.txt"
}

# Build a VLESS+REALITY URI and display it along with a QR code
# Arguments: uuid server public_key short_id sni [network] [path] [port] [flow] [mode]
show_connection_info() {
    local uuid="$1" server="$2" pbk="$3" sid="$4" sni="$5" network="${6:-tcp}" path="${7:-/}"
    local port="${8:-}" flow="${9-xtls-rprx-vision}" mode="${10:-auto}"
    local uri spx host encoded_sni encoded_path encoded_mode encoded_flow
    host="$(format_uri_host "$server")" || { echo "Cannot generate a link with an invalid server address." >&2; return 1; }
    if [[ -z "$port" ]]; then port="$(get_server_port)" || return 1; fi
    validate_server_port "$port" || return 1
    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ && "$pbk" =~ ^[A-Za-z0-9_-]{43}$ && -n "$sni" ]] || {
        echo "Cannot generate a client link: invalid UUID, public key or SNI." >&2; return 1;
    }
    encoded_sni=$(jq -rn --arg value "$sni" '$value | @uri') || return 1
    # spiderX: crawler start path, recommended to differ per client
    spx=$(generate_short_id) || return 1
    uri="vless://${uuid}@${host}:${port}?encryption=none&security=reality&pbk=${pbk}&sid=${sid}&fp=chrome&sni=${encoded_sni}&spx=%2F${spx}"
    if [[ "$network" == "xhttp" ]]; then
        encoded_path=$(jq -rn --arg value "$path" '$value | @uri') || return 1
        encoded_mode=$(jq -rn --arg value "$mode" '$value | @uri') || return 1
        uri+="&type=xhttp&path=${encoded_path}&mode=${encoded_mode}"
    else
        uri+="&type=tcp"
        if [[ -n "$flow" ]]; then
            encoded_flow=$(jq -rn --arg value "$flow" '$value | @uri') || return 1
            uri+="&flow=${encoded_flow}"
        fi
    fi
    uri+="#${sid}-${encoded_sni}"

    echo ""
    echo "Generated VLESS+REALITY URI (copy or scan):"
    echo "$uri"

    if command -v qrencode &>/dev/null; then
        local png png_tmp
        png="$(dirname "$CONFIG")/vless-${uuid}.png"
        if png_tmp=$(mktemp "${png}.XXXXXX") && printf '%s' "$uri" | qrencode -o "$png_tmp" -l H -t png &&
           [[ -s "$png_tmp" ]] && mv -fT -- "$png_tmp" "$png"; then
            printf '%s' "$uri" | qrencode -t ANSIUTF8 || true
            echo -e "\nQR code saved to: $png"
        else
            [[ -z "$png_tmp" ]] || rm -f -- "$png_tmp"
            echo "QR code generation failed; use the client link above." >&2
        fi
    else
        echo -e "\nqrencode not available — QR code generation skipped."
    fi

    show_client_routing || echo "Could not export the optional routing profile; regenerate it from menu option 6." >&2
}

check_managed_inbound() {
    if ! jq -e '.inbounds[0] | .protocol == "vless" and .streamSettings.security == "reality" and (.settings.clients | type == "array")' "$CONFIG" >/dev/null; then
        echo "The first inbound must be a VLESS + REALITY server managed by this installer." >&2
        return 1
    fi
}

get_connection_network() {
    local network
    network="$(jq -r '.inbounds[0].streamSettings.network // "tcp"' "$CONFIG")" || return 1
    case "$network" in
        tcp|raw|xhttp) printf '%s\n' "$network" ;;
        *) echo "Unsupported inbound transport: $network." >&2; return 1 ;;
    esac
}

# Print the chosen zero-based index to stdout; the list and prompt go to stderr.
choose_client_index() {
    local action="$1" list choice count i
    local -a uuids
    list="$(jq -r '.inbounds[0].settings.clients[].id' "$CONFIG")" || return 1
    [[ -n "$list" ]] || { echo "No clients configured." >&2; return 1; }
    mapfile -t uuids <<< "$list"
    count="${#uuids[@]}"

    printf '\nCurrent clients:\n\n' >&2
    for i in "${!uuids[@]}"; do
        printf '   %d) %s\n' "$((i + 1))" "${uuids[$i]}" >&2
    done
    read -rp "Select the client to $action [1-$count]: " choice || return 1

    # Strip leading zeros and bound the number before Bash arithmetic can overflow.
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        choice="${choice#"${choice%%[!0]*}"}"
        if (( ${#choice} > 0 && ${#choice} <= ${#count} )) && (( 10#$choice <= count )); then
            printf '%d\n' "$((10#$choice - 1))"
            return 0
        fi
    fi
    echo "Invalid selection." >&2
    return 1
}

export_client_link() {
    ensure_jq || return 1
    ensure_crypto_tool || return 1
    check_managed_inbound || return 1

    local idx uuid server port pbk sid sni network path mode flow
    idx="$(choose_client_index export)" || return 1
    uuid="$(jq -er --argjson index "$idx" '.inbounds[0].settings.clients[$index].id' "$CONFIG")" || return 1
    flow="$(jq -r --argjson index "$idx" '.inbounds[0].settings.clients[$index].flow // ""' "$CONFIG")" || return 1
    network="$(get_connection_network)" || return 1
    path="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$CONFIG")" || return 1
    mode="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode // "auto"' "$CONFIG")" || return 1
    sni="$(jq -er '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")" || return 1
    # The REALITY Short ID set is shared across clients. An empty ID may be allowed.
    sid="$(jq -er 'first(.inbounds[0].streamSettings.realitySettings.shortIds[] | strings | select(test("^([0-9a-fA-F]{2}){0,8}$")))' "$CONFIG")" || {
        echo "The REALITY inbound has no valid Short ID for client links." >&2
        return 1
    }
    server="$(get_server_address)" || return 1
    port="$(get_server_port)" || return 1
    pbk="$(get_public_key)" || return 1
    show_connection_info "$uuid" "$server" "$pbk" "$sid" "$sni" "$network" "$path" "$port" "$flow" "$mode"
}

# ==============================================================================
# Fresh installation (interactive)
# ==============================================================================

new_install() {
    local mode="${1:-start}" sni_validation=interactive
    if is_xray_installed; then
        echo "An existing config must be repaired, not overwritten: $CONFIG" >&2
        return 1
    fi
    validate_configuration_environment || return 1
    echo ""
    echo "Welcome to the Xray VLESS+REALITY installer (Docker mode, no systemd)!"
    echo ""

    # Prepared images already contain the network and validation tools.
    if [[ "$mode" == configure ]]; then
        if [[ ! -x "$XRAY_BIN" || ! -x "$ENTRYPOINT_BIN" ]]; then
            echo "Xray and its entrypoint are required. Build the prepared image before configuring its volume." >&2
            return 1
        fi
    else
        install_deps || return 1
    fi

    # ---- Client-facing address and REALITY target ----
    local server sni detected input
    if [[ -n "${XRAY_SERVER_ADDRESS:-}" ]]; then
        server="$XRAY_SERVER_ADDRESS"
        sni="$XRAY_SNI"
        sni_validation=strict
    else
        detected="$(detect_public_ip)"
        if [[ -n "$detected" ]]; then
            echo "Detected public IP: $detected"
            read -rp "Server address for clients (IP or domain) [$detected]: " input || return 1
            server="${input:-$detected}"
        else
            echo "Unable to auto-detect public IP." >&2
            read -rp "Enter the server's public IP or domain: " server || return 1
        fi
        echo ""
        read -rp "Enter the SNI domain (e.g. www.cloudflare.com): " sni || return 1
        while ! validate_sni_domain "$sni"; do
            read -rp "Enter a valid SNI domain without a scheme or port: " sni || return 1
        done
    fi
    if [[ "$server" == \[*\] ]]; then server="${server:1:-1}"; fi
    validate_server_address "$server" || { echo "Enter a valid server IP or domain without a scheme or port." >&2; return 1; }

    # ---- DNS selection ----
    local dns_choice=2 dns1 dns2
    if [[ "$sni_validation" == interactive ]]; then
        echo ""
        echo "Select a DNS server for Xray:"
        echo "   1) Current system resolvers"
        echo "   2) Google        (8.8.8.8, 8.8.4.4)"
        echo "   3) Cloudflare    (1.1.1.1, 1.0.0.1)"
        echo "   4) OpenDNS       (208.67.222.222, 208.67.220.220)"
        echo "   5) Quad9         (9.9.9.9, 149.112.112.112)"
        echo "   6) AdGuard DNS   (94.140.14.14, 94.140.15.15)"
        read -rp "DNS [1-6, default 2]: " dns_choice || return 1
    fi
    case "${dns_choice:-2}" in
        1)
            dns1="$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)"
            dns2="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk 'NR==2{print $2}' || true)"
            if [[ -z "$dns1" ]]; then
                dns1="8.8.8.8"; dns2="8.8.4.4"
                echo "No system resolvers found. Falling back to Google DNS."
            fi
            ;;
        3)  dns1="1.1.1.1";         dns2="1.0.0.1" ;;
        4)  dns1="208.67.222.222";   dns2="208.67.220.220" ;;
        5)  dns1="9.9.9.9";         dns2="149.112.112.112" ;;
        6)  dns1="94.140.14.14";    dns2="94.140.15.15" ;;
        *)  dns1="8.8.8.8";         dns2="8.8.4.4" ;;
    esac

    # ---- Transport ----
    local transport_choice=1 network xhttp_path=""
    if [[ "$sni_validation" == interactive ]]; then
        echo ""
        echo "Select a transport:"
        echo "   1) TCP + XTLS Vision  (default; supported by all client apps)"
        echo "   2) XHTTP              (newer, splits traffic into HTTP requests and is harder"
        echo "                          to fingerprint; check that your client app supports it)"
        read -rp "Transport [1-2, default 1]: " transport_choice || return 1
    fi
    if [[ "${transport_choice:-1}" == "2" ]]; then
        network="xhttp"
        xhttp_path="/$(openssl rand -hex 4 2>/dev/null || generate_short_id)"
    else
        network="tcp"
    fi

    # ---- Confirmation summary ----
    echo ""
    echo "Xray VLESS+REALITY will be installed with these settings:"
    echo ""
    echo "   Server IP  : $server"
    echo "   SNI domain : $sni"
    echo "   DNS servers: $dns1${dns2:+, $dns2}"
    echo "   Transport  : $network"
    echo ""
    if [[ "$sni_validation" == interactive ]]; then
        read -rp "Press Enter to continue or Ctrl+C to abort..." || return 1
    fi

    # ---- Download latest Xray-core binary (skipped if already present) ----
    if [[ -x "$XRAY_BIN" ]]; then
        echo -e "\n>>> Using existing Xray binary: $XRAY_BIN"
    else
        install_xray_binary || return 1
    fi
    install -d -m 750 "$(dirname "$CONFIG")" || return 1

    # ---- Verify the SNI target site ----
    check_sni_target "$sni" "$sni_validation" || return 1

    # ---- Generate X25519 key pair for REALITY ----
    local key_output private_key public_key
    key_output=$("$XRAY_BIN" x25519)

    # Use $NF (last field) to handle varying output formats across Xray versions
    # Support both old ("Private key: / Public key:") and new ("PrivateKey: / Password:") formats
    private_key=$(echo "$key_output" | awk '/PrivateKey/{print $NF}')
    [[ -z "$private_key" ]] && private_key=$(echo "$key_output" | awk '/Private key:/{print $3}')

    public_key=$(echo "$key_output" | awk '/Password/{print $NF}')
    [[ -z "$public_key" ]] && public_key=$(echo "$key_output" | awk '/Public key:/{print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        echo "Failed to generate X25519 keys." >&2
        exit 1
    fi

    # ---- Generate first client credentials ----
    local uuid short_id
    uuid="$(generate_uuid)"
    short_id="$(generate_short_id)"

    # ---- Write config.json (with DNS section) ----
    local dns_json="\"$dns1\""
    [[ -n "$dns2" ]] && dns_json="\"$dns1\", \"$dns2\""

    # Transport-specific parts: Vision flow for TCP, path/mode for XHTTP
    local client_json xhttp_json=""
    if [[ "$network" == "xhttp" ]]; then
        client_json="{ \"id\": \"$uuid\" }"
        xhttp_json=$'\n        "xhttpSettings": { "path": "'"$xhttp_path"'", "mode": "auto" },'
    else
        client_json="{ \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\" }"
    fi

    local config_tmp listen="0.0.0.0"
    [[ "$server" == *:* ]] && listen="::"
    config_tmp="$(mktemp "$(dirname "$CONFIG")/.config.XXXXXX")" || return 1
    cat > "$config_tmp" <<EOF || { rm -f -- "$config_tmp"; return 1; }
{
  "dns": {
    "servers": [$dns_json],
    "tag": "dns-internal"
  },
  "log": {
    "access": "none",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "listen": "$listen",
      "protocol": "vless",
      "settings": {
        "clients": [
          $client_json
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "$network",$xhttp_json
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$sni:443",
          "xver": 0,
          "serverNames": [
            "$sni"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["dns-internal"], "outboundTag": "direct" },
      { "type": "field", "ip": $PRIVATE_IPS_JSON, "outboundTag": "block" }
    ]
  },
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIP" } },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
    if ! set_config_permissions "$config_tmp" || ! validate_config "$config_tmp" ||
       { [[ "$mode" == configure ]] && ! save_deployment_port "$config_tmp"; } ||
       ! write_private_file "$(dirname "$CONFIG")/public.key" "$public_key" ||
       ! write_private_file "$SERVER_ADDR_FILE" "$server" ||
       ! mv -fT -- "$config_tmp" "$CONFIG"; then
        rm -f -- "$config_tmp"
        return 1
    fi

    if [[ "$mode" == configure ]]; then
        show_connection_info "$uuid" "$server" "$public_key" "$short_id" "$sni" "$network" "$xhttp_path" || return 1
        echo "Config saved to $CONFIG."
        return 0
    fi

    if ! restart_xray || ! setup_log_rotation || ! setup_autostart; then
        echo "The config was saved. Use menu option 3 to start Xray and option 8 to export the client link after correcting the startup problem." >&2
        return 1
    fi

    # ---- Display connection info ----
    show_connection_info "$uuid" "$server" "$public_key" "$short_id" "$sni" "$network" "$xhttp_path" || return 1

    cat <<EOF

Xray-core VLESS + REALITY installation completed!

Configuration file : $CONFIG
Xray process       : running (PID $(xray_pid)), log: $XRAY_LOG
Fake SNI           : $sni
Connect to host    : $server
Public key         : $public_key (saved to /etc/xray/public.key)
Server address     : saved to $SERVER_ADDR_FILE
Transport          : $network${xhttp_path:+ (path $xhttp_path)}
Short ID           : $short_id
UUID               : $uuid

Autostart          : $(autostart_status)
Make sure port 443 of the container is published.
EOF
}

# ==============================================================================
# Add a new client to the running server
# ==============================================================================

add_client() {
    ensure_jq || return 1
    ensure_crypto_tool || return 1
    validate_config || return 1
    check_managed_inbound || return 1

    # Resolve all connection parameters before changing the working config.
    local server port pbk sni network xhttp_path xhttp_mode uuid short_id existing_sids tmp
    server="$(get_server_address)" || return 1
    port="$(get_server_port)" || return 1
    pbk="$(get_public_key)" || return 1
    network="$(get_connection_network)" || return 1
    xhttp_path="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$CONFIG")" || return 1
    xhttp_mode="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode // "auto"' "$CONFIG")" || return 1
    sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG")" || return 1
    [[ -n "$sni" ]] || { echo "The REALITY inbound has no server name for client links." >&2; return 1; }
    uuid="$(generate_uuid)" || return 1
    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] || { echo "Failed to generate a UUID." >&2; return 1; }
    if jq -e --arg uid "$uuid" 'any(.inbounds[0].settings.clients[]; .id == $uid)' "$CONFIG" >/dev/null; then
        echo "Generated UUID already exists; retry adding the client." >&2
        return 1
    fi
    existing_sids=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[]? // empty' "$CONFIG" | tr '\n' ' ') || return 1
    short_id="$(generate_short_id "$existing_sids")" || return 1

    echo ""
    echo "Adding new client..."
    echo "  UUID     : $uuid"
    echo "  Short ID : $short_id"

    # The entry point holds the lock until validation, restart and output finish.
    tmp=$(mktemp "$(dirname "$CONFIG")/.config-edit.XXXXXX") || return 1
    # XHTTP clients have no flow (XTLS Vision works only over TCP)
    if ! jq --arg uid "$uuid" --arg sid "$short_id" --arg net "$network" '
        (.inbounds[0].settings.clients //= []) |
        .inbounds[0].settings.clients += [if $net == "xhttp" then {"id":$uid} else {"id":$uid,"flow":"xtls-rprx-vision"} end] |
        (.inbounds[0].streamSettings.realitySettings.shortIds //= []) |
        .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]
    ' "$CONFIG" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    apply_config_change "$tmp" || return 1

    show_connection_info "$uuid" "$server" "$pbk" "$short_id" "$sni" "$network" "$xhttp_path" "$port" xtls-rprx-vision "$xhttp_mode" || return 1

    echo ""
    echo "Client added successfully! Xray has been restarted."
}

# ==============================================================================
# Remove an existing client from the server
# ==============================================================================

remove_client() {
    ensure_jq || return 1
    validate_config || return 1
    check_managed_inbound || return 1

    local num_clients confirm idx target_uuid
    num_clients=$(jq -er '.inbounds[0].settings.clients | select(type == "array") | length' "$CONFIG") || return 1

    # Refuse to remove the last remaining client
    if [[ "$num_clients" -le 1 ]]; then
        echo ""
        echo "There is only one client configured."
        echo "Cannot remove the last client — use option 4 to remove Xray entirely."
        return
    fi

    idx="$(choose_client_index remove)" || return 1
    target_uuid="$(jq -er --argjson index "$idx" '.inbounds[0].settings.clients[$index].id' "$CONFIG")" || return 1

    echo ""
    read -rp "Confirm removal of client $target_uuid? [y/N]: " confirm || return 1
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Aborted."; return; }

    # Revoking the UUID removes access without invalidating other clients' SIDs.
    local tmp
    tmp=$(mktemp "$(dirname "$CONFIG")/.config-edit.XXXXXX") || return 1
    if ! jq --arg uid "$target_uuid" '
        .inbounds[0].settings.clients |= map(select(.id != $uid))
    ' "$CONFIG" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    apply_config_change "$tmp" || return 1

    # Clean up QR code image if it exists
    if [[ "$target_uuid" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
        rm -f -- "$(dirname "$CONFIG")/vless-${target_uuid}.png"
    fi

    echo "Client removed. Xray has been restarted."
}

# ==============================================================================
# Completely uninstall Xray and clean up all related files
# ==============================================================================

remove_managed_config() {
    local dir="${CONFIG%/*}" qr name
    for qr in "$dir"/vless-*.png; do
        name="${qr##*/}"
        if [[ "$name" =~ ^vless-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.png$ ]]; then
            rm -f -- "$qr" || return 1
        fi
    done
    rm -f -- "$SERVER_ADDR_FILE" "${SERVER_ADDR_FILE%/*}/server.port" "${CONFIG}.bak" \
        "$dir/public.key" "$dir/ru-direct.json" "$dir/ru-direct-incy.txt" "$dir/ru-direct-happ.txt" || return 1
    # Keep the directory, unrelated files and the shared lock inode in place.
    rm -f -- "$CONFIG"
}

remove_xray() {
    local confirm index
    if [[ -L "$CONFIG" || ( -e "$CONFIG" && ! -f "$CONFIG" ) ]]; then
        echo "Cannot remove the existing config path: $CONFIG is not a regular file." >&2
        return 1
    fi
    if [[ -f "$CONFIG" && ! -f "$SERVER_ADDR_FILE" && ! -f "${CONFIG%/*}/public.key" ]] && ! check_managed_inbound; then
        echo "The installer did not recognize the existing configuration. Its files have been preserved." >&2
        return 1
    fi
    echo ""
    read -rp "Remove Xray and its managed configuration from $CONFIG? [y/N]: " confirm || return 1
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

    echo ""
    # The shared lock keeps the watchdog from restarting Xray during removal.
    stop_xray || return 1
    remove_autostart || return 1

    echo ">>> Removing Xray binary, configuration, log and autostart..."
    rm -f -- "$LOGROTATE_CONF" "$XRAY_LOG" || return 1
    for index in {1..7}; do
        rm -f -- "$XRAY_LOG.$index" "$XRAY_LOG.$index.gz" || return 1
    done
    rm -f -- "$XRAY_BIN" || return 1
    # Leave the configuration in place until all other cleanup succeeds so a
    # retry still opens the management menu.
    remove_managed_config || return 1

    echo ""
    echo "Xray has been completely removed."
}

# ==============================================================================
# Management menu (shown when Xray is already installed)
# ==============================================================================

# Print a short summary of the process state and configuration
show_status() {
    local pid state startup version server port clients sni log_location
    pid="$(xray_pid)"
    if [[ -n "$pid" ]]; then state="running (PID $pid)"; else state="stopped"; fi
    version="$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}' || true)"
    server="$(head -n1 "$SERVER_ADDR_FILE" 2>/dev/null || true)"
    port="$(get_server_port 2>/dev/null || true)"
    startup="$(autostart_status)"
    log_location="$XRAY_LOG"
    if [[ "$startup" == 'container entrypoint '* ]]; then log_location="docker logs"; fi

    # Don't install jq just to show the menu — print "?" if it is missing
    local transport="?"
    clients="?"; sni="?"
    if command -v jq &>/dev/null; then
        clients="$(jq '.inbounds[0].settings.clients | length' "$CONFIG" 2>/dev/null || echo "?")"
        sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "?"' "$CONFIG" 2>/dev/null || echo "?")"
        transport="$(jq -r '.inbounds[0].streamSettings | if .network == "xhttp" then "XHTTP (path \(.xhttpSettings.path // "/"))" else "TCP + XTLS Vision" end' "$CONFIG" 2>/dev/null || echo "?")"
    fi

    echo ""
    echo "   Service  : $state"
    echo "   Autostart: $startup"
    echo "   Version  : ${version:-unknown}"
    echo "   Address  : ${server:-not saved}"
    echo "   Port     : ${port:-unknown}"
    echo "   SNI      : $sni"
    echo "   Transport: $transport"
    echo "   Clients  : $clients"
    echo "   Log      : $log_location"
}

manage_menu() {
    echo ""
    echo "Xray VLESS+REALITY is already installed (Docker mode)."
    show_status
    echo ""
    echo "Select an option:"
    echo "   1) Add a new client"
    echo "   2) Remove an existing client"
    echo "   3) Start / restart Xray"
    echo "   4) Remove Xray"
    echo "   5) Exit"
    echo "   6) Client routing: Russian domains direct (INCY/Happ)"
    echo "   7) Change server address (IP or domain)"
    echo "   8) Export existing client link"
    echo "   9) Change external port"

    local option
    read -rp "Option [1-9]: " option || return 1
    case "$option" in
        1) ensure_xray_runtime && add_client ;;
        2) ensure_xray_runtime && remove_client ;;
        3) ensure_xray_runtime && restart_xray ;;
        4) remove_xray ;;
        5) exit 0 ;;
        6) ensure_jq && show_client_routing ;;
        7) change_server_address ;;
        8) export_client_link ;;
        9) change_server_port ;;
        *) echo "Invalid option." >&2; return 1 ;;
    esac
}

# ==============================================================================
# Entry point
# ==============================================================================

ensure_xray_runtime() {
    [[ -x "$XRAY_BIN" ]] || prepare_existing_install
}

install_missing_docker() (
    local answer installer url='https://get.docker.com/'
    local -a admin=()
    printf 'Docker was not found. Install the latest stable Docker Engine from %s with root or sudo? [y/N] ' "$url" >&2
    if ! IFS= read -r answer || [[ "${answer,,}" != y && "${answer,,}" != yes ]]; then
        echo "Docker installation cancelled." >&2
        return 1
    fi
    if (( EUID != 0 )); then
        if ! command -v sudo >/dev/null; then
            echo "Installing Docker requires root or sudo." >&2
            return 1
        fi
        admin=(sudo --)
    fi

    installer="$(mktemp)" || return 1
    trap 'rm -f -- "$installer"' EXIT
    if command -v curl >/dev/null; then
        curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
            --output "$installer" "$url" || return 1
    elif command -v wget >/dev/null; then
        wget --https-only --timeout=30 --tries=2 -O "$installer" "$url" || return 1
    else
        echo "Install curl or wget to download the Docker installer." >&2
        return 1
    fi
    if [[ ! -s "$installer" ]]; then
        echo "The Docker installer download was empty." >&2
        return 1
    fi

    # Keep the official package source and a full installation even when the
    # caller has exported options for the standalone Docker installer.
    unset DOWNLOAD_URL REPO_FILE VERSION DRY_RUN REPO_ONLY NO_AUTOSTART SBX
    if ! "${admin[@]}" sh "$installer" --channel stable; then
        echo "Docker installation failed. See https://docs.docker.com/engine/install/." >&2
        return 1
    fi
)

docker_engine_is_linux() {
    local engine
    engine="$("$@" info --format '{{.OSType}}' 2>/dev/null)" && [[ "$engine" == linux ]]
}

ensure_deployment_docker() {
    local -n selected_docker="$1"
    if command -v docker >/dev/null; then
        if docker_engine_is_linux "${selected_docker[@]}"; then
            return 0
        fi
        echo "--deploy needs access to a running Linux Docker Engine. Check that 'docker info' works." >&2
        return 1
    fi
    if [[ "$(uname -s)" != Linux ||
        ( -n "${DOCKER_HOST:-}" && "$DOCKER_HOST" != unix:///var/run/docker.sock ) ||
        "${DOCKER_CONTEXT:-default}" != default ]]; then
        echo "Automatic Docker installation requires a local Linux host. See https://docs.docker.com/engine/install/." >&2
        return 1
    fi
    install_missing_docker || return 1
    if ! command -v docker >/dev/null; then
        echo "Docker installation finished but the CLI is unavailable. Check that 'docker info' works." >&2
        return 1
    fi
    # A saved Docker context may outlive its CLI. Use the just-installed local engine.
    selected_docker=(docker --host unix:///var/run/docker.sock)
    if docker_engine_is_linux "${selected_docker[@]}"; then
        return 0
    fi

    local -a admin=()
    if (( EUID != 0 )); then
        # Fresh installs generally require sudo for Docker socket access.
        admin=(sudo --)
        selected_docker=(sudo -- "${selected_docker[@]}")
        if docker_engine_is_linux "${selected_docker[@]}"; then
            return 0
        fi
    fi
    if command -v systemctl >/dev/null &&
       "${admin[@]}" systemctl enable --now docker.service &&
       docker_engine_is_linux "${selected_docker[@]}"; then
        return 0
    fi
    echo "Docker is installed but the Linux engine is unavailable. Check the Docker service and 'docker info'." >&2
    return 1
}

build_deployment_image() (
    local image="$1" version="$2" label="$3" source="${BASH_SOURCE[0]}" context
    shift 3
    if [[ ! -f "$source" ]]; then
        echo "Save this script to a file before running --deploy." >&2
        return 1
    fi
    context="$(mktemp -d)" || return 1
    trap 'rm -f -- "$context/xray-install-docker.sh"; rmdir -- "$context"' EXIT
    cp -- "$source" "$context/xray-install-docker.sh" || return 1
    "$@" build --tag "$image" --label "$label" --build-arg "XRAY_VERSION=$version" --file - "$context" <<'DOCKERFILE'
FROM debian:bookworm-slim

ARG XRAY_VERSION
COPY --chmod=755 xray-install-docker.sh /usr/local/sbin/xray-install-docker
RUN /usr/local/sbin/xray-install-docker --prepare \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 443/tcp
ENTRYPOINT ["/usr/local/bin/xray-entrypoint"]
DOCKERFILE
)

wait_for_deployment() {
    local container="$1" name="$2" attempt
    shift 2
    for ((attempt = 0; attempt < 12; attempt++)); do
        if "$@" exec "$container" bash -c ': >/dev/tcp/127.0.0.1/443 || : >/dev/tcp/::1/443' >/dev/null 2>&1; then
            echo "Xray is running in container $name."
            echo "Manage client links with: $* exec -it $name /usr/local/sbin/xray-install-docker"
            return 0
        fi
        sleep 1
    done
    echo "Xray did not become ready. Check: $* logs $name" >&2
    return 1
}

deploy_on_docker_host() {
    local name="${XRAY_DOCKER_NAME:-xray-vless}" port="${XRAY_DOCKER_PORT:-443}" version="${XRAY_VERSION:-v26.11.9}"
    local owner running published container volume image mount label
    local object_label='io.github.1517mb.xray-installer'
    local -a docker_cli=(docker) input_flags=(-i) configure_env

    if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || (( ${#name} > 63 )); then
        echo "XRAY_DOCKER_NAME must contain at most 63 lower-case letters, digits and single hyphens between words." >&2
        return 1
    fi
    if ! validate_server_port "$port"; then
        echo "XRAY_DOCKER_PORT must be a port from 1 to 65535." >&2
        return 1
    fi
    validate_configuration_environment || return 1
    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "XRAY_VERSION must be an Xray release tag such as v26.11.9." >&2
        return 1
    fi
    ensure_deployment_docker docker_cli || return 1

    if owner="$("${docker_cli[@]}" container inspect --format "{{ index .Config.Labels \"$object_label\" }}" "$name" 2>/dev/null)"; then
        if [[ "$owner" != "$name" ]]; then
            echo "Container $name already exists and is not managed by this installer. Choose a different XRAY_DOCKER_NAME." >&2
            return 1
        fi
        if [[ -n "${XRAY_DOCKER_PORT:-}" ]]; then
            published="$("${docker_cli[@]}" container inspect --format '{{range index .HostConfig.PortBindings "443/tcp"}}{{println .HostPort}}{{end}}' "$name")" || return 1
            if [[ "$published" != "$port" ]]; then
                echo "Container $name already has a different published port. Recreate it using the same configuration volume to change the port." >&2
                return 1
            fi
        fi
        running="$("${docker_cli[@]}" container inspect --format '{{.State.Running}}' "$name")" || return 1
        if [[ "$running" != true ]]; then
            "${docker_cli[@]}" container start "$name" >/dev/null || return 1
        fi
        wait_for_deployment "$name" "$name" "${docker_cli[@]}"
        return
    fi

    volume="$name-config"
    image="$name-local:$version"
    label="$object_label=$name"
    mount="type=volume,source=$volume,target=/etc/xray"

    if owner="$("${docker_cli[@]}" volume inspect --format "{{ index .Labels \"$object_label\" }}" "$volume" 2>/dev/null)" && [[ "$owner" != "$name" ]]; then
        echo "Volume $volume already exists and is not managed by this installer. Choose a different XRAY_DOCKER_NAME." >&2
        return 1
    fi
    if owner="$("${docker_cli[@]}" image inspect --format "{{ index .Config.Labels \"$object_label\" }}" "$image" 2>/dev/null)" && [[ "$owner" != "$name" ]]; then
        echo "Image $image already exists and is not managed by this installer. Choose a different XRAY_DOCKER_NAME." >&2
        return 1
    fi
    build_deployment_image "$image" "$version" "$label" "${docker_cli[@]}" || return 1

    "${docker_cli[@]}" volume create --label "$label" "$volume" >/dev/null || return 1
    owner="$("${docker_cli[@]}" volume inspect --format "{{ index .Labels \"$object_label\" }}" "$volume")" || return 1
    if [[ "$owner" != "$name" ]]; then
        echo "Volume $volume is not managed by this installer. Choose a different XRAY_DOCKER_NAME." >&2
        return 1
    fi
    if [[ -t 0 && -t 1 ]]; then input_flags=(-it); fi
    configure_env=(--env "XRAY_DOCKER_PORT=$port")
    if [[ -n "${XRAY_SERVER_ADDRESS:-}" ]]; then
        configure_env+=(--env "XRAY_SERVER_ADDRESS=$XRAY_SERVER_ADDRESS" --env "XRAY_SNI=$XRAY_SNI")
    fi
    "${docker_cli[@]}" run --rm "${input_flags[@]}" --mount "$mount" "${configure_env[@]}" \
        --entrypoint /usr/local/sbin/xray-install-docker "$image" --configure || return 1
    container="$("${docker_cli[@]}" container create --name "$name" --label "$label" --init --restart unless-stopped \
        --log-driver local --mount "$mount" --publish "$port:443/tcp" "$image")" || return 1
    if ! "${docker_cli[@]}" container start "$container" >/dev/null; then
        "${docker_cli[@]}" container rm "$container" >/dev/null || true
        echo "Could not start container $name. Its configuration is saved in volume $volume." >&2
        return 1
    fi
    wait_for_deployment "$container" "$name" "${docker_cli[@]}"
}

# This script must be executed as root
if [[ "$#" == 1 && ( "$1" == --help || "$1" == -h ) ]]; then
    echo "Usage: $0 [--deploy|--prepare|--configure]"
    exit 0
fi
if [[ "$#" -gt 1 || ( "$#" == 1 && "$1" != --deploy && "$1" != --prepare && "$1" != --configure ) ]]; then
    echo "Usage: $0 [--deploy|--prepare|--configure]" >&2
    exit 2
fi
if [[ "${1:-}" == --deploy ]]; then
    deploy_on_docker_host
    exit 0
fi
if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

ensure_lock_tool || exit 1
acquire_install_lock || exit 1

if [[ "${1:-}" == --prepare ]]; then
    prepare_image
    exit 0
fi
acquire_config_lock || exit 1

if is_xray_installed && [[ ! -f "$CONFIG" || -L "$CONFIG" ]]; then
    echo "The existing config path is not a regular file: $CONFIG" >&2
    exit 1
fi

if [[ "${1:-}" == --configure ]]; then
    if is_xray_installed; then
        validate_config || exit 1
        save_deployment_port "$CONFIG" || exit 1
        echo "Configuration already exists at $CONFIG. Run the installer without flags to manage clients."
    else
        new_install configure
    fi
elif is_xray_installed; then
    if [[ -x "$XRAY_BIN" ]]; then
        if prepare_existing_install; then
            if can_restart_xray >/dev/null 2>&1; then
                offer_private_block || echo "The existing configuration was kept." >&2
            fi
        else
            echo "Xray startup tools could not be refreshed. Review the messages above." >&2
        fi
    else
        echo "Xray binary is missing. Options 1–3 will attempt to restore it." >&2
    fi
    manage_menu
else
    new_install
fi
