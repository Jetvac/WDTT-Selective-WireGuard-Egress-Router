#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.2.0"
CONFIG_FILE="/etc/wdtt-egress-router.conf"
DROPIN_DIR="/etc/systemd/system/wdtt.service.d"
DROPIN_FILE="$DROPIN_DIR/90-german-egress.conf"

WG_IF="wg-de"
WG_IP="10.8.1.3"
WDTT_IF="wdtt0"
WDTT_NET="10.66.66.0/24"
PROBE_IP="10.66.66.2"
ROUTE_TABLE="51888"
RULE_PREF="10666"
CHAIN="WDTT_EGRESS_DE"
COMMENT_OUT="WDTT_EGRESS_DE_OUT"
COMMENT_IN="WDTT_EGRESS_DE_IN"
COMMENT_NAT="WDTT_EGRESS_DE_SNAT"
SKIP_EGRESS_TEST="0"

WDTT_SETUP_REPO="XXcipherX/vkturn-vps-setup"
WDTT_SETUP_BRANCH="main"
WDTT_SETUP_SCRIPT="wdtt-systemd-setup.sh"
WDTT_SOURCE_REPO="XXcipherX/proxy-turn-vk-android"
WDTT_SOURCE_CLONE_URL="https://github.com/XXcipherX/proxy-turn-vk-android.git"
WDTT_ENV_FILE="/etc/wdtt/wdtt.env"
WDTT_SOURCE_DIR="/opt/wdtt/source"
WDTT_BIN="/usr/local/bin/wdtt-server"

log()  { printf '[wdtt-egress] %s\n' "$*"; }
warn() { printf '[wdtt-egress] WARNING: %s\n' "$*" >&2; }
die()  { printf '[wdtt-egress] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
WDTT selective WireGuard egress router

Usage:
  wdtt-egress-router.sh install [options]
  wdtt-egress-router.sh reconfigure [options]
  wdtt-egress-router.sh enable
  wdtt-egress-router.sh disable
  wdtt-egress-router.sh apply
  wdtt-egress-router.sh status
  wdtt-egress-router.sh probe
  wdtt-egress-router.sh wdtt-version
  wdtt-egress-router.sh update-wdtt [--check]
  wdtt-egress-router.sh uninstall

Actions:
  install        Save configuration, enable persistence and apply routing.
  reconfigure    Same as install; updates saved routing parameters safely.
  enable         Re-enable saved WDTT egress routing and persistence.
  disable        Remove only runtime routing/NAT/FORWARD changes and disable persistence.
                 Saved configuration and WireGuard are kept.
  apply          Apply saved routing rules. Used by systemd after WDTT starts.
  status         Show routes, WireGuard state and counters.
  probe          Test Internet egress through WireGuard without changing the host default route.
  wdtt-version   Show installed server-core ref/commit and the latest stable GitHub release.
  update-wdtt    Update native WDTT to the latest stable release of XXcipherX/proxy-turn-vk-android.
                 The vkturn-vps-setup installer is used only as the build/install mechanism.
                 --check only compares versions and changes nothing.
  uninstall      Remove routing changes, persistence and saved router configuration.
                 WireGuard, WDTT and 3x-ui are not removed.

Options for install/reconfigure:
  --wg-if NAME            WireGuard egress interface. Default: wg-de
  --wg-ip IPv4            IPv4 assigned to WireGuard interface. Default: 10.8.1.3
  --wdtt-if NAME          WDTT interface. Default: wdtt0
  --wdtt-net CIDR         WDTT client subnet. Default: 10.66.66.0/24
  --probe-ip IPv4         Address from WDTT subnet used for route diagnostics. Default: 10.66.66.2
  --table NUMBER          Dedicated policy-routing table. Default: 51888
  --rule-pref NUMBER      Policy-rule priority. Default: 10666
  --skip-egress-test      Skip Internet test through WireGuard during install

Safety model:
  - never changes the main/default route;
  - never changes INPUT or OUTPUT;
  - never flushes third-party chains or tables;
  - uses its own policy table, ip rule, FORWARD chain and one scoped SNAT rule;
  - refuses to install if normal host traffic already uses the selected WireGuard interface.
USAGE
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root."
}

need_commands() {
    local cmd
    for cmd in ip iptables wg systemctl sysctl awk grep sed curl; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

parse_install_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --wg-if)       [ "$#" -ge 2 ] || die "$1 requires a value"; WG_IF="$2"; shift 2 ;;
            --wg-ip)       [ "$#" -ge 2 ] || die "$1 requires a value"; WG_IP="$2"; shift 2 ;;
            --wdtt-if)     [ "$#" -ge 2 ] || die "$1 requires a value"; WDTT_IF="$2"; shift 2 ;;
            --wdtt-net)    [ "$#" -ge 2 ] || die "$1 requires a value"; WDTT_NET="$2"; shift 2 ;;
            --probe-ip)    [ "$#" -ge 2 ] || die "$1 requires a value"; PROBE_IP="$2"; shift 2 ;;
            --table)       [ "$#" -ge 2 ] || die "$1 requires a value"; ROUTE_TABLE="$2"; shift 2 ;;
            --rule-pref)   [ "$#" -ge 2 ] || die "$1 requires a value"; RULE_PREF="$2"; shift 2 ;;
            --skip-egress-test) SKIP_EGRESS_TEST="1"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

validate_number() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name must be an integer, got: $value" ;;
    esac
    [ "$value" -ge 1 ] || die "$name must be greater than zero."
}

validate_config() {
    validate_number "ROUTE_TABLE" "$ROUTE_TABLE"
    validate_number "RULE_PREF" "$RULE_PREF"
    [ "$ROUTE_TABLE" -ne 253 ] && [ "$ROUTE_TABLE" -ne 254 ] && [ "$ROUTE_TABLE" -ne 255 ] || die "Do not use local/main/default routing tables."
    [ -n "$WG_IF" ] && [ -n "$WDTT_IF" ] && [ -n "$WG_IP" ] && [ -n "$WDTT_NET" ] || die "Configuration contains empty values."
    [ "${#CHAIN}" -le 28 ] || die "iptables chain name is too long."
}

check_interfaces() {
    ip link show dev "$WG_IF" >/dev/null 2>&1 || die "WireGuard interface $WG_IF does not exist. Start it first."
    wg show "$WG_IF" >/dev/null 2>&1 || die "$WG_IF exists but is not a WireGuard interface."
    ip -4 -o addr show dev "$WG_IF" | awk '{print $4}' | grep -Eq "^${WG_IP//./\\.}/[0-9]+$" || die "$WG_IF does not have IPv4 $WG_IP."

    ip link show dev "$WDTT_IF" >/dev/null 2>&1 || die "WDTT interface $WDTT_IF does not exist. Is wdtt.service running?"
    ip -4 route show dev "$WDTT_IF" | grep -Fq "$WDTT_NET" || warn "Could not confirm route $WDTT_NET on $WDTT_IF; continuing because the interface exists."
}

check_wg_handshake() {
    local latest now age
    latest="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'BEGIN{m=0} {if ($2>m) m=$2} END{print m+0}')"
    if [ "$latest" -eq 0 ]; then
        warn "No successful WireGuard handshake is visible on $WG_IF yet."
        return 0
    fi
    now="$(date +%s)"
    age=$((now - latest))
    if [ "$age" -gt 180 ]; then
        warn "Latest WireGuard handshake is ${age}s old."
    else
        log "WireGuard handshake OK (${age}s ago)."
    fi
}

host_route_to_internet() {
    ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true
}

assert_host_not_using_wg() {
    local route
    route="$(host_route_to_internet)"
    [ -n "$route" ] || die "Could not determine the host route to 1.1.1.1."
    if printf '%s\n' "$route" | grep -Eq "(^|[[:space:]])dev[[:space:]]+$WG_IF([[:space:]]|$)"; then
        die "Normal host traffic already routes through $WG_IF. Ensure Table = off in /etc/wireguard/$WG_IF.conf before continuing."
    fi
}

main_default() {
    ip -4 route show table main default | sed '/^[[:space:]]*$/d'
}

check_route_table_conflict() {
    local routes bad
    routes="$(ip -4 route show table "$ROUTE_TABLE" 2>/dev/null || true)"
    [ -z "$routes" ] && return 0

    bad="$(printf '%s\n' "$routes" | grep -Ev "^default dev ${WG_IF}([[:space:]]|$)" || true)"
    [ -z "$bad" ] || die "Routing table $ROUTE_TABLE is already used by other routes:\n$bad"
}

check_rule_conflict() {
    local line
    line="$(ip -4 rule show | awk -v p="$RULE_PREF:" '$1 == p {print; exit}')"
    [ -z "$line" ] && return 0
    if ! printf '%s\n' "$line" | grep -Fq "from $WDTT_NET" || ! printf '%s\n' "$line" | grep -Eq "(lookup|table)[[:space:]]+$ROUTE_TABLE([[:space:]]|$)"; then
        die "Policy-rule priority $RULE_PREF is already occupied: $line"
    fi
}

ensure_chain_rule() {
    local mode="$1"
    shift
    if ! iptables -w 5 -C "$CHAIN" "$@" 2>/dev/null; then
        if [ "$mode" = "insert" ]; then
            iptables -w 5 -I "$CHAIN" 1 "$@"
        else
            iptables -w 5 -A "$CHAIN" "$@"
        fi
    fi
}

remove_all_jump_by_comment() {
    local comment="$1" nums n
    while :; do
        nums="$(iptables -w 5 -L FORWARD --line-numbers -n 2>/dev/null | grep -F "/* $comment */" | awk '{print $1}' | sort -rn || true)"
        [ -n "$nums" ] || break
        while read -r n; do
            [ -n "$n" ] && iptables -w 5 -D FORWARD "$n"
        done <<< "$nums"
    done
}

install_forward_rules() {
    iptables -w 5 -N "$CHAIN" 2>/dev/null || true

    ensure_chain_rule append -i "$WDTT_IF" -s "$WDTT_NET" -j DROP
    ensure_chain_rule insert -i "$WG_IF" -o "$WDTT_IF" -d "$WDTT_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ensure_chain_rule insert -i "$WDTT_IF" -s "$WDTT_NET" -o "$WG_IF" -j ACCEPT

    remove_all_jump_by_comment "$COMMENT_IN"
    remove_all_jump_by_comment "$COMMENT_OUT"

    iptables -w 5 -I FORWARD 1 -i "$WG_IF" -o "$WDTT_IF" -m comment --comment "$COMMENT_IN" -j "$CHAIN"
    iptables -w 5 -I FORWARD 1 -i "$WDTT_IF" -s "$WDTT_NET" -m comment --comment "$COMMENT_OUT" -j "$CHAIN"
}

install_snat_rule() {
    if ! iptables -w 5 -t nat -C POSTROUTING -s "$WDTT_NET" -o "$WG_IF" -m comment --comment "$COMMENT_NAT" -j SNAT --to-source "$WG_IP" 2>/dev/null; then
        iptables -w 5 -t nat -I POSTROUTING 1 -s "$WDTT_NET" -o "$WG_IF" -m comment --comment "$COMMENT_NAT" -j SNAT --to-source "$WG_IP"
    fi
}

install_policy_route() {
    check_route_table_conflict
    check_rule_conflict

    ip -4 route replace default dev "$WG_IF" table "$ROUTE_TABLE"

    while ip -4 rule del pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE" 2>/dev/null; do
        :
    done
    ip -4 rule add pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE"
    ip -4 route flush cache 2>/dev/null || true
}

apply_sysctls() {
    sysctl -q -w net.ipv4.ip_forward=1
    sysctl -q -w "net.ipv4.conf.${WG_IF}.rp_filter=2" || true
    sysctl -q -w "net.ipv4.conf.${WDTT_IF}.rp_filter=2" || true
}

route_diagnostics() {
    local host_route policy_route
    host_route="$(host_route_to_internet)"
    policy_route="$(ip -4 route get 1.1.1.1 from "$PROBE_IP" iif "$WDTT_IF" 2>/dev/null | head -n1 || true)"

    log "Host route:   $host_route"
    log "WDTT route:   ${policy_route:-<not resolved>}"

    printf '%s\n' "$host_route" | grep -Eq "(^|[[:space:]])dev[[:space:]]+$WG_IF([[:space:]]|$)" && die "Host traffic unexpectedly started using $WG_IF."
    printf '%s\n' "$policy_route" | grep -Eq "(^|[[:space:]])dev[[:space:]]+$WG_IF([[:space:]]|$)" || die "WDTT policy route does not resolve through $WG_IF."
}

apply_rules() {
    need_root
    need_commands
    load_config
    validate_config
    check_interfaces
    assert_host_not_using_wg

    local default_before default_after
    default_before="$(main_default)"

    apply_sysctls
    install_policy_route
    install_forward_rules
    install_snat_rule

    default_after="$(main_default)"
    if [ "$default_before" != "$default_after" ]; then
        warn "Main default route changed unexpectedly. Removing WDTT egress rules."
        remove_runtime_rules
        die "Main default route before:\n$default_before\nMain default route after:\n$default_after"
    fi

    assert_host_not_using_wg
    route_diagnostics
    log "Selective WDTT egress through $WG_IF is active."
}

probe_egress() {
    need_root
    need_commands
    load_config
    validate_config
    check_interfaces
    assert_host_not_using_wg
    check_route_table_conflict
    check_rule_conflict

    local temp_pref result
    temp_pref=$((RULE_PREF - 1))
    [ "$temp_pref" -gt 0 ] || die "RULE_PREF is too small for a temporary probe rule."

    if ip -4 rule show | awk -v p="$temp_pref:" '$1 == p {found=1} END{exit !found}'; then
        die "Temporary probe priority $temp_pref is already in use. Choose another --rule-pref."
    fi

    ip -4 route replace default dev "$WG_IF" table "$ROUTE_TABLE"
    ip -4 rule add pref "$temp_pref" from "$WG_IP/32" table "$ROUTE_TABLE"

    cleanup_probe() {
        ip -4 rule del pref "$temp_pref" from "$WG_IP/32" table "$ROUTE_TABLE" 2>/dev/null || true
        ip -4 route flush cache 2>/dev/null || true
    }
    trap cleanup_probe EXIT INT TERM

    result="$(curl -4 --interface "$WG_IP" --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org 2>/dev/null || true)"
    cleanup_probe
    trap - EXIT INT TERM

    [ -n "$result" ] || die "Internet egress test through $WG_IF failed. Check NAT/routing on the German WireGuard server."
    log "WireGuard Internet egress works. Public IPv4: $result"
}

write_config() {
    umask 077
    cat > "$CONFIG_FILE" <<EOF_CONF
WG_IF='$WG_IF'
WG_IP='$WG_IP'
WDTT_IF='$WDTT_IF'
WDTT_NET='$WDTT_NET'
PROBE_IP='$PROBE_IP'
ROUTE_TABLE='$ROUTE_TABLE'
RULE_PREF='$RULE_PREF'
CHAIN='$CHAIN'
COMMENT_OUT='$COMMENT_OUT'
COMMENT_IN='$COMMENT_IN'
COMMENT_NAT='$COMMENT_NAT'
SKIP_EGRESS_TEST='$SKIP_EGRESS_TEST'
EOF_CONF
    chmod 600 "$CONFIG_FILE"
}

install_persistence() {
    local self
    self="$(readlink -f "$0")"
    [ -x "$self" ] || die "Script must be executable before install: chmod +x $self"

    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN_FILE" <<EOF_UNIT
[Unit]
Wants=wg-quick@${WG_IF}.service
After=wg-quick@${WG_IF}.service

[Service]
ExecStartPost=${self} apply
EOF_UNIT

    systemctl daemon-reload
}

remove_persistence() {
    rm -f "$DROPIN_FILE"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
}

install_all() {
    need_root
    need_commands
    load_config
    parse_install_options "$@"
    validate_config
    check_interfaces
    check_wg_handshake
    assert_host_not_using_wg
    check_route_table_conflict
    check_rule_conflict

    if [ "$SKIP_EGRESS_TEST" != "1" ]; then
        probe_egress
    else
        warn "Skipping WireGuard Internet egress test by request."
    fi

    write_config
    install_persistence
    apply_rules

    log "Installed persistent configuration: $CONFIG_FILE"
    log "Installed WDTT systemd drop-in: $DROPIN_FILE"
    log "No INPUT/OUTPUT rules or main/default routes were changed."
}

remove_runtime_rules() {
    while ip -4 rule del pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE" 2>/dev/null; do
        :
    done
    ip -4 route del default dev "$WG_IF" table "$ROUTE_TABLE" 2>/dev/null || true
    ip -4 route flush cache 2>/dev/null || true

    remove_all_jump_by_comment "$COMMENT_IN"
    remove_all_jump_by_comment "$COMMENT_OUT"

    while iptables -w 5 -t nat -C POSTROUTING -s "$WDTT_NET" -o "$WG_IF" -m comment --comment "$COMMENT_NAT" -j SNAT --to-source "$WG_IP" 2>/dev/null; do
        iptables -w 5 -t nat -D POSTROUTING -s "$WDTT_NET" -o "$WG_IF" -m comment --comment "$COMMENT_NAT" -j SNAT --to-source "$WG_IP"
    done

    iptables -w 5 -F "$CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$CHAIN" 2>/dev/null || true
}

disable_all() {
    need_root
    need_commands
    load_config
    validate_config
    remove_runtime_rules
    remove_persistence
    log "WDTT German egress is disabled. Saved configuration remains in $CONFIG_FILE."
    log "WireGuard, WDTT, 3x-ui, INPUT/OUTPUT and the main routing table were left untouched."
}

enable_all() {
    need_root
    need_commands
    [ -f "$CONFIG_FILE" ] || die "Saved configuration not found: $CONFIG_FILE. Run install first."
    load_config
    validate_config
    check_interfaces
    check_wg_handshake
    assert_host_not_using_wg
    install_persistence
    apply_rules
    log "WDTT German egress is enabled and persistent."
}

uninstall_all() {
    need_root
    need_commands
    load_config
    validate_config

    remove_runtime_rules
    remove_persistence
    rm -f "$CONFIG_FILE"
    log "Removed WDTT egress policy/NAT rules, persistence and saved router configuration."
    log "WireGuard, WDTT, 3x-ui and unrelated firewall/routing rules were left untouched."
}

fetch_latest_setup_commit() {
    local api_url sha
    api_url="https://api.github.com/repos/${WDTT_SETUP_REPO}/commits/${WDTT_SETUP_BRANCH}"
    sha="$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url" | grep -Eo '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -n1 | grep -Eo '[0-9a-f]{40}' || true)"
    [ -n "$sha" ] || die "Could not resolve latest ${WDTT_SETUP_REPO}/${WDTT_SETUP_BRANCH} commit."
    printf '%s' "$sha"
}

fetch_latest_wdtt_release() {
    local api_url json tag
    api_url="https://api.github.com/repos/${WDTT_SOURCE_REPO}/releases/latest"
    json="$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url")" || die "Could not query latest WDTT release from GitHub."
    tag="$(printf '%s' "$json" | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"
    [ -n "$tag" ] || die "GitHub response did not contain a release tag."
    printf '%s' "$tag" | grep -Eq '^[A-Za-z0-9._-]+$' || die "Unsafe release tag received from GitHub: $tag"
    printf '%s' "$tag"
}

installed_wdtt_ref() {
    local ref=""
    if [ -f "$WDTT_ENV_FILE" ]; then
        ref="$(sed -n 's/^WDTT_SOURCE_REF=//p' "$WDTT_ENV_FILE" | tail -n1)"
    fi
    printf '%s' "$ref"
}

installed_wdtt_commit() {
    if [ -d "$WDTT_SOURCE_DIR/.git" ]; then
        git -C "$WDTT_SOURCE_DIR" rev-parse --short=12 HEAD 2>/dev/null || true
    fi
}

show_wdtt_version() {
    need_root
    need_commands
    command -v git >/dev/null 2>&1 || die "git is required."

    local latest ref commit
    latest="$(fetch_latest_wdtt_release)"
    ref="$(installed_wdtt_ref)"
    commit="$(installed_wdtt_commit)"

    printf 'WDTT server core:\n'
    printf '  repository:     https://github.com/%s\n' "$WDTT_SOURCE_REPO"
    printf '  configured ref: %s\n' "${ref:-<unknown>}"
    printf '  source commit:  %s\n' "${commit:-<unknown>}"
    printf '  latest release: %s\n' "$latest"

    if [ -n "$ref" ] && [ "$ref" = "$latest" ]; then
        printf '  status:         up to date\n'
    else
        printf '  status:         update available or installed ref is not pinned to latest release\n'
    fi
}

backup_wdtt_before_update() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 700 "$dir"

    [ -f "$WDTT_BIN" ] && cp -a "$WDTT_BIN" "$dir/wdtt-server"
    [ -f "$WDTT_ENV_FILE" ] && cp -a "$WDTT_ENV_FILE" "$dir/wdtt.env"
    [ -f /etc/systemd/system/wdtt.service ] && cp -a /etc/systemd/system/wdtt.service "$dir/wdtt.service"
    [ -f /etc/systemd/system/wdtt-firewall.service ] && cp -a /etc/systemd/system/wdtt-firewall.service "$dir/wdtt-firewall.service"
    [ -f /usr/local/lib/wdtt/apply-firewall.sh ] && cp -a /usr/local/lib/wdtt/apply-firewall.sh "$dir/apply-firewall.sh"
    [ -f /usr/local/lib/wdtt/run-wdtt.sh ] && cp -a /usr/local/lib/wdtt/run-wdtt.sh "$dir/run-wdtt.sh"
}

restore_wdtt_after_failed_update() {
    local dir="$1"
    warn "WDTT update failed. Attempting to restore the previous runtime files from $dir"

    [ -f "$dir/wdtt-server" ] && install -m 0755 "$dir/wdtt-server" "$WDTT_BIN"
    [ -f "$dir/wdtt.env" ] && install -m 0600 "$dir/wdtt.env" "$WDTT_ENV_FILE"
    [ -f "$dir/wdtt.service" ] && cp -a "$dir/wdtt.service" /etc/systemd/system/wdtt.service
    [ -f "$dir/wdtt-firewall.service" ] && cp -a "$dir/wdtt-firewall.service" /etc/systemd/system/wdtt-firewall.service
    [ -f "$dir/apply-firewall.sh" ] && install -m 0755 "$dir/apply-firewall.sh" /usr/local/lib/wdtt/apply-firewall.sh
    [ -f "$dir/run-wdtt.sh" ] && install -m 0755 "$dir/run-wdtt.sh" /usr/local/lib/wdtt/run-wdtt.sh

    systemctl daemon-reload || true
    systemctl restart wdtt-firewall.service 2>/dev/null || true
    systemctl restart wdtt.service 2>/dev/null || true

    if systemctl is-active --quiet wdtt.service; then
        warn "Previous WDTT runtime was restored and wdtt.service is active again."
    else
        warn "Automatic rollback could not restore an active wdtt.service. Inspect: journalctl -u wdtt -n 150 --no-pager"
    fi
}

update_wdtt() {
    need_root
    need_commands
    command -v bash >/dev/null 2>&1 || die "bash is required."
    command -v git >/dev/null 2>&1 || die "git is required."
    command -v mktemp >/dev/null 2>&1 || die "mktemp is required."
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
    systemctl cat wdtt.service >/dev/null 2>&1 || die "wdtt.service was not found. This updater supports the native systemd WDTT installation."
    [ -f "$WDTT_ENV_FILE" ] || die "WDTT environment file not found: $WDTT_ENV_FILE"

    local check_only="0"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) check_only="1"; shift ;;
            -h|--help)
                printf 'Usage: %s update-wdtt [--check]\n' "$0"
                return 0
                ;;
            *) die "Unknown update-wdtt option: $1" ;;
        esac
    done

    local latest current commit setup_commit tmp raw_url before_bin_sha after_bin_sha backup_dir routing_was_enabled="0"
    latest="$(fetch_latest_wdtt_release)"
    current="$(installed_wdtt_ref)"
    commit="$(installed_wdtt_commit)"

    log "WDTT server-core repository: https://github.com/${WDTT_SOURCE_REPO}"
    log "Installed ref: ${current:-<unknown>} (${commit:-unknown commit})"
    log "Latest stable release: $latest"

    if [ "$check_only" = "1" ]; then
        if [ "$current" = "$latest" ]; then
            log "WDTT is already pinned to the latest stable release."
        else
            log "WDTT update is available."
        fi
        return 0
    fi

    if [ "$current" = "$latest" ] && systemctl is-active --quiet wdtt.service; then
        log "WDTT is already pinned to $latest and the service is active. Nothing to update."
        return 0
    fi

    [ -f "$DROPIN_FILE" ] && routing_was_enabled="1"

    setup_commit="$(fetch_latest_setup_commit)"
    raw_url="https://raw.githubusercontent.com/${WDTT_SETUP_REPO}/${setup_commit}/${WDTT_SETUP_SCRIPT}"
    tmp="$(mktemp /tmp/wdtt-systemd-setup.XXXXXX.sh)"
    backup_dir="/etc/wdtt/backups/router-update-$(date -u +%Y%m%dT%H%M%SZ)"

    cleanup_update() {
        rm -f "$tmp"
    }
    trap cleanup_update EXIT INT TERM

    log "Using vkturn-vps-setup installer snapshot ${setup_commit:0:12} only as the build/install mechanism."
    log "Downloading immutable installer snapshot..."
    curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "$raw_url"
    bash -n "$tmp" || die "Downloaded WDTT installer failed bash syntax validation."
    chmod 700 "$tmp"

    backup_wdtt_before_update "$backup_dir"
    log "Pre-update runtime backup: $backup_dir"

    before_bin_sha=""
    [ -f "$WDTT_BIN" ] && before_bin_sha="$(sha256sum "$WDTT_BIN" | awk '{print $1}')"

    log "Updating WDTT server core to release $latest..."
    if ! bash "$tmp" install --source-repo "$WDTT_SOURCE_CLONE_URL" --source-ref "$latest"; then
        restore_wdtt_after_failed_update "$backup_dir"
        die "WDTT update to $latest failed. Previous runtime files were restored where possible."
    fi

    if ! systemctl is-active --quiet wdtt.service; then
        restore_wdtt_after_failed_update "$backup_dir"
        die "WDTT installer returned successfully, but wdtt.service is not active after the update."
    fi

    after_bin_sha=""
    [ -f "$WDTT_BIN" ] && after_bin_sha="$(sha256sum "$WDTT_BIN" | awk '{print $1}')"

    if [ "$routing_was_enabled" = "1" ]; then
        log "Selective egress was enabled before the update; re-applying it after WDTT restart..."
        apply_rules
    else
        log "Selective egress was disabled before the update; leaving it disabled."
        remove_runtime_rules
    fi

    if [ -n "$before_bin_sha" ] && [ "$before_bin_sha" = "$after_bin_sha" ]; then
        log "WDTT binary checksum is unchanged after rebuilding release $latest."
    else
        log "WDTT binary was rebuilt and replaced successfully."
    fi

    log "WDTT is now pinned to release $latest."
    log "wdtt.service is active."

    cleanup_update
    trap - EXIT INT TERM
}

show_status() {
    need_root
    load_config
    validate_config

    printf 'WDTT egress router v%s\n\n' "$VERSION"
    printf 'Configuration:\n'
    printf '  WG_IF=%s\n  WG_IP=%s\n  WDTT_IF=%s\n  WDTT_NET=%s\n  ROUTE_TABLE=%s\n  RULE_PREF=%s\n\n' \
        "$WG_IF" "$WG_IP" "$WDTT_IF" "$WDTT_NET" "$ROUTE_TABLE" "$RULE_PREF"

    printf 'Persistence:\n'
    if [ -f "$DROPIN_FILE" ]; then
        printf '  enabled (%s)\n' "$DROPIN_FILE"
    else
        printf '  disabled\n'
    fi

    printf '\nNormal host route:\n'
    ip -4 route get 1.1.1.1 2>/dev/null || true

    printf '\nPolicy rule:\n'
    ip -4 rule show | grep -E "^${RULE_PREF}:" || true

    printf '\nPolicy table:\n'
    ip -4 route show table "$ROUTE_TABLE" 2>/dev/null || true

    printf '\nWireGuard:\n'
    wg show "$WG_IF" 2>/dev/null || true

    printf '\nWDTT egress chain:\n'
    iptables -w 5 -vnL "$CHAIN" 2>/dev/null || true

    printf '\nWDTT egress jumps:\n'
    iptables -w 5 -vnL FORWARD --line-numbers 2>/dev/null | grep -E "${COMMENT_OUT}|${COMMENT_IN}" || true

    printf '\nWDTT SNAT:\n'
    iptables -w 5 -t nat -vnL POSTROUTING --line-numbers 2>/dev/null | grep -F "$COMMENT_NAT" || true

    printf '\nWDTT service:\n'
    systemctl is-active wdtt.service 2>/dev/null || true
}

ACTION="${1:-}"
[ -n "$ACTION" ] || { usage; exit 1; }
shift || true

case "$ACTION" in
    install|reconfigure) install_all "$@" ;;
    enable)      [ "$#" -eq 0 ] || die "enable does not accept options"; enable_all ;;
    disable)     [ "$#" -eq 0 ] || die "disable does not accept options"; disable_all ;;
    apply)       [ "$#" -eq 0 ] || die "apply does not accept options; change $CONFIG_FILE or run reconfigure"; apply_rules ;;
    probe)       [ "$#" -eq 0 ] || die "probe does not accept options; change $CONFIG_FILE or run reconfigure"; probe_egress ;;
    status)      [ "$#" -eq 0 ] || die "status does not accept options"; show_status ;;
    wdtt-version) [ "$#" -eq 0 ] || die "wdtt-version does not accept options"; show_wdtt_version ;;
    update-wdtt) update_wdtt "$@" ;;
    uninstall)   [ "$#" -eq 0 ] || die "uninstall does not accept options"; uninstall_all ;;
    -h|--help|help) usage ;;
    *) die "Unknown action: $ACTION" ;;
esac
