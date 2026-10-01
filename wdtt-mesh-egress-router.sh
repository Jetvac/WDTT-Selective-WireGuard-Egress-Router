#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.0"
CONFIG_FILE="/etc/wdtt-mesh-egress.conf"
NODE_ENV_FILE="/etc/wdtt-mesh-node.env"
SYSTEMD_UNIT="/etc/systemd/system/wdtt-mesh-egress.service"
WDTT_DROPIN_DIR="/etc/systemd/system/wdtt.service.d"
WDTT_DROPIN_FILE="$WDTT_DROPIN_DIR/95-mesh-egress.conf"

CF_API_BASE="https://api.cloudflare.com/client/v4"
PROFILE_NAME="WDTT Mesh egress nodes"
PROFILE_PRECEDENCE="90"
MESH_IMAGE="cloudflare/mesh:latest"
MESH_CONTAINER="cloudflare-mesh"
MESH_DOCKER_NETWORK="wdtt-mesh-net"
MESH_BRIDGE="wdttmesh0"
MESH_DOCKER_NET="172.31.255.0/29"
MESH_DOCKER_GW="172.31.255.1"
MESH_CONTAINER_IP="172.31.255.2"

ROLE=""
ACCOUNT_ID=""
TEAM_NAME=""
NODE_NAME=""
NODE_ID=""
ROUTE_ID=""
EXIT_ROUTE_ID=""
WDTT_ROUTE_ID=""
WDTT_IF="wdtt0"
WDTT_NET="10.66.66.0/24"
PROBE_IP="10.66.66.2"
ROUTE_TABLE="51889"
RULE_PREF="10667"
EXT_IF=""
DELETE_CLOUDFLARE="0"

CHAIN_MSK="WDTT_MESH_EGRESS"
CHAIN_DE="WDTT_MESH_DE"
COMMENT_MSK_OUT="WDTT_MESH_OUT"
COMMENT_MSK_IN="WDTT_MESH_IN"
COMMENT_DE="WDTT_MESH_DE_FWD"
COMMENT_DE_NAT="WDTT_MESH_DE_NAT"

log()  { printf '[wdtt-mesh] %s\n' "$*"; }
warn() { printf '[wdtt-mesh] WARNING: %s\n' "$*" >&2; }
die()  { printf '[wdtt-mesh] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
WDTT selective Cloudflare Mesh egress router

Cloudflare Mesh replaces the MSK -> AmneziaWG/WireGuard -> DE transport.
Run install-de on the German VPS first, then install-msk on the Moscow VPS.

Required environment variable for install/uninstall --delete-cloudflare:
  CLOUDFLARE_API_TOKEN

Usage:
  wdtt-mesh-egress-router.sh install-de  --account-id ID --team-name TEAM [options]
  wdtt-mesh-egress-router.sh install-msk --account-id ID --team-name TEAM [options]
  wdtt-mesh-egress-router.sh apply
  wdtt-mesh-egress-router.sh status
  wdtt-mesh-egress-router.sh disable
  wdtt-mesh-egress-router.sh enable
  wdtt-mesh-egress-router.sh uninstall [--delete-cloudflare]

Common install options:
  --account-id ID          Cloudflare account ID (required)
  --team-name TEAM         Zero Trust team name, without .cloudflareaccess.com (required)
  --node-name NAME         Mesh node name. Defaults: wdtt-de / wdtt-msk
  --wdtt-net CIDR          WDTT client network. Default: 10.66.66.0/24
  --mesh-image IMAGE       Cloudflare Mesh image. Default: cloudflare/mesh:latest

MSK options:
  --wdtt-if IFACE          WDTT interface. Default: wdtt0
  --probe-ip IPv4          Client address used for route checks. Default: 10.66.66.2
  --table NUMBER           Policy routing table. Default: 51889
  --rule-pref NUMBER       Policy rule priority. Default: 10667

DE options:
  --ext-if IFACE           Public egress interface. Auto-detected from main default route.

Cloudflare requirements:
  API token permissions:
    - Cloudflare One Connectors Write
    - Cloudflare One Networks Write
    - Zero Trust Write

  One Cloudflare setting is currently human-only and cannot be changed via API:
    "Allow all Cloudflare One traffic to reach enrolled devices" must be enabled once
    in the Cloudflare dashboard (Networking -> Mesh setup / device client settings).

Important:
  The script creates/updates an account-wide Mesh-node device profile in Include mode
  with 0.0.0.0/0 and MASQUE. Use a dedicated Zero Trust account for this WDTT egress
  if other Mesh nodes in the same account must NOT use the German exit route.
USAGE
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root."
}

validate_integer() {
  local name="$1" value="$2"
  case "$value" in ''|*[!0-9]*) die "$name must be an integer: $value" ;; esac
  [ "$value" -ge 1 ] || die "$name must be greater than zero."
}

parse_install_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --account-id) [ "$#" -ge 2 ] || die "$1 requires a value"; ACCOUNT_ID="$2"; shift 2 ;;
      --team-name) [ "$#" -ge 2 ] || die "$1 requires a value"; TEAM_NAME="$2"; shift 2 ;;
      --node-name) [ "$#" -ge 2 ] || die "$1 requires a value"; NODE_NAME="$2"; shift 2 ;;
      --wdtt-if) [ "$#" -ge 2 ] || die "$1 requires a value"; WDTT_IF="$2"; shift 2 ;;
      --wdtt-net) [ "$#" -ge 2 ] || die "$1 requires a value"; WDTT_NET="$2"; shift 2 ;;
      --probe-ip) [ "$#" -ge 2 ] || die "$1 requires a value"; PROBE_IP="$2"; shift 2 ;;
      --table) [ "$#" -ge 2 ] || die "$1 requires a value"; ROUTE_TABLE="$2"; shift 2 ;;
      --rule-pref) [ "$#" -ge 2 ] || die "$1 requires a value"; RULE_PREF="$2"; shift 2 ;;
      --ext-if) [ "$#" -ge 2 ] || die "$1 requires a value"; EXT_IF="$2"; shift 2 ;;
      --mesh-image) [ "$#" -ge 2 ] || die "$1 requires a value"; MESH_IMAGE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

validate_install_config() {
  [ -n "$ACCOUNT_ID" ] || die "--account-id is required."
  [ -n "$TEAM_NAME" ] || die "--team-name is required."
  [ -n "$NODE_NAME" ] || die "NODE_NAME is empty."
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN environment variable is required."
  validate_integer ROUTE_TABLE "$ROUTE_TABLE"
  validate_integer RULE_PREF "$RULE_PREF"
  [ "$ROUTE_TABLE" -ne 253 ] && [ "$ROUTE_TABLE" -ne 254 ] && [ "$ROUTE_TABLE" -ne 255 ] || die "Do not use local/main/default routing tables."
  command -v curl >/dev/null 2>&1 || die "curl is required."
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

install_prereqs() {
  local missing="0" cmd
  for cmd in curl jq ip iptables sysctl systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing="1"
  done
  if ! command -v docker >/dev/null 2>&1; then
    missing="1"
  fi
  [ "$missing" = "0" ] && return 0

  command -v apt-get >/dev/null 2>&1 || die "Automatic dependency install currently supports Debian/Ubuntu (apt). Install curl jq iproute2 iptables and Docker manually."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq iproute2 iptables docker.io
  systemctl enable --now docker
}

cf_api() {
  local method="$1" path="$2" body="${3:-}" response
  local -a args
  args=(--fail-with-body --silent --show-error
        --request "$method"
        --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
        --header "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(--data "$body")
  fi
  response="$(curl "${args[@]}" "${CF_API_BASE}/accounts/${ACCOUNT_ID}/${path}")" || return 1
  jq -e '.success == true' >/dev/null <<<"$response" || {
    printf '%s\n' "$response" >&2
    return 1
  }
  printf '%s' "$response"
}

ensure_cf_account_settings() {
  local body
  body='{"use_zt_virtual_ip":true,"gateway_proxy_enabled":true,"gateway_udp_proxy_enabled":true}'
  cf_api PATCH "devices/settings" "$body" >/dev/null || die "Could not enable required Cloudflare device settings. Check Zero Trust Write permission."
  log "Cloudflare unique device IPs and TCP/UDP Gateway proxy are enabled."
}

ensure_cf_mesh_profile() {
  local profiles profile_id match body includes
  profiles="$(cf_api GET "devices/policies")" || die "Could not list Cloudflare device profiles."
  profile_id="$(jq -r --arg name "$PROFILE_NAME" '.result[]? | select(.name == $name) | .id' <<<"$profiles" | head -n1)"
  match="identity.email == \"warp_connector@${TEAM_NAME}.cloudflareaccess.com\""

  if [ -z "$profile_id" ]; then
    body="$(jq -cn \
      --arg name "$PROFILE_NAME" \
      --arg desc "Dedicated full-tunnel MASQUE profile for WDTT Mesh egress" \
      --arg match "$match" \
      --argjson precedence "$PROFILE_PRECEDENCE" \
      '{name:$name,description:$desc,enabled:true,precedence:$precedence,match:$match,service_mode_v2:{mode:"warp"},tunnel_protocol:"masque",include:[{address:"0.0.0.0/0",description:"WDTT Mesh German egress"}]}')"
    profiles="$(cf_api POST "devices/policy" "$body")" || die "Could not create the Mesh node device profile."
    profile_id="$(jq -r '.result.id' <<<"$profiles")"
    log "Created Cloudflare device profile: $PROFILE_NAME ($profile_id)."
  else
    body="$(jq -cn \
      --arg desc "Dedicated full-tunnel MASQUE profile for WDTT Mesh egress" \
      --arg match "$match" \
      --argjson precedence "$PROFILE_PRECEDENCE" \
      '{description:$desc,enabled:true,precedence:$precedence,match:$match,service_mode_v2:{mode:"warp"},tunnel_protocol:"masque"}')"
    cf_api PATCH "devices/policy/${profile_id}" "$body" >/dev/null || die "Could not update Mesh node device profile."
    log "Updated Cloudflare device profile: $PROFILE_NAME ($profile_id)."
  fi

  includes='[{"address":"0.0.0.0/0","description":"WDTT Mesh German egress"}]'
  cf_api PUT "devices/policy/${profile_id}/include" "$includes" >/dev/null || die "Could not set Mesh node Split Tunnel include list."
  log "Mesh-node profile uses MASQUE and Include 0.0.0.0/0."
}

ensure_cf_node() {
  local list body created token_response
  list="$(cf_api GET "warp_connector")" || die "Could not list Cloudflare Mesh nodes."
  NODE_ID="$(jq -r --arg name "$NODE_NAME" '.result[]? | select(.name == $name and (.deleted_at == null or .deleted_at == "")) | .id' <<<"$list" | head -n1)"
  if [ -z "$NODE_ID" ]; then
    body="$(jq -cn --arg name "$NODE_NAME" '{name:$name,ha:false}')"
    created="$(cf_api POST "warp_connector" "$body")" || die "Could not create Cloudflare Mesh node $NODE_NAME."
    NODE_ID="$(jq -r '.result.id' <<<"$created")"
    [ -n "$NODE_ID" ] && [ "$NODE_ID" != "null" ] || die "Cloudflare did not return a node ID."
    log "Created Mesh node $NODE_NAME ($NODE_ID)."
  else
    log "Reusing Mesh node $NODE_NAME ($NODE_ID)."
  fi

  token_response="$(cf_api GET "warp_connector/${NODE_ID}/token")" || die "Could not obtain token for Mesh node $NODE_NAME."
  MESH_NODE_TOKEN="$(jq -er '.result | select(type == "string" and length > 0)' <<<"$token_response")" || die "Cloudflare returned an empty Mesh node token."
}

ensure_cf_route() {
  local network="$1" comment="$2" list existing existing_tunnel body created
  list="$(cf_api GET "teamnet/routes")" || die "Could not list Cloudflare network routes."
  existing="$(jq -c --arg network "$network" '.result[]? | select(.network == $network and (.deleted_at == null or .deleted_at == ""))' <<<"$list" | head -n1)"
  if [ -n "$existing" ]; then
    existing_tunnel="$(jq -r '.tunnel_id' <<<"$existing")"
    if [ "$existing_tunnel" != "$NODE_ID" ]; then
      die "Cloudflare route $network already belongs to another connector ($existing_tunnel). Remove it or use a dedicated Zero Trust account."
    fi
    ROUTE_ID="$(jq -r '.id' <<<"$existing")"
    log "Reusing Cloudflare route $network -> $NODE_NAME ($ROUTE_ID)."
    return 0
  fi

  body="$(jq -cn --arg network "$network" --arg tunnel "$NODE_ID" --arg comment "$comment" '{network:$network,tunnel_id:$tunnel,comment:$comment}')"
  created="$(cf_api POST "teamnet/routes" "$body")" || die "Could not create Cloudflare route $network -> $NODE_NAME."
  ROUTE_ID="$(jq -r '.result.id' <<<"$created")"
  [ -n "$ROUTE_ID" ] && [ "$ROUTE_ID" != "null" ] || die "Cloudflare did not return a route ID for $network."
  log "Created Cloudflare route $network -> $NODE_NAME ($ROUTE_ID)."
}

write_node_env() {
  local srcnat="$1"
  umask 077
  cat >"$NODE_ENV_FILE" <<EOF_ENV
MESH_NODE_TOKEN=${MESH_NODE_TOKEN}
SRCNAT_ENABLED=${srcnat}
EOF_ENV
  chmod 600 "$NODE_ENV_FILE"
}

ensure_docker_network() {
  if docker network inspect "$MESH_DOCKER_NETWORK" >/dev/null 2>&1; then
    return 0
  fi
  docker network create \
    --driver bridge \
    --subnet "$MESH_DOCKER_NET" \
    --gateway "$MESH_DOCKER_GW" \
    --opt "com.docker.network.bridge.name=${MESH_BRIDGE}" \
    "$MESH_DOCKER_NETWORK" >/dev/null
}

deploy_mesh_container() {
  local srcnat="$1"
  write_node_env "$srcnat"
  ensure_docker_network
  docker pull "$MESH_IMAGE" >/dev/null
  docker rm -f "$MESH_CONTAINER" >/dev/null 2>&1 || true
  docker volume create wdtt_mesh_data >/dev/null
  docker run -d \
    --name "$MESH_CONTAINER" \
    --restart unless-stopped \
    --network "$MESH_DOCKER_NETWORK" \
    --ip "$MESH_CONTAINER_IP" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --device /dev/net/tun:/dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --env-file "$NODE_ENV_FILE" \
    -v wdtt_mesh_data:/var/lib/cloudflare-warp \
    "$MESH_IMAGE" >/dev/null
  log "Cloudflare Mesh container started as $NODE_NAME."
}

ensure_jump() {
  local chain="$1" comment="$2"
  shift 2
  if ! iptables -w 5 -C FORWARD "$@" -m comment --comment "$comment" -j "$chain" 2>/dev/null; then
    iptables -w 5 -I FORWARD 1 "$@" -m comment --comment "$comment" -j "$chain"
  fi
}

remove_forward_jumps_by_comment() {
  local comment="$1" nums n
  while :; do
    nums="$(iptables -w 5 -L FORWARD --line-numbers -n 2>/dev/null | grep -F "/* $comment */" | awk '{print $1}' | sort -rn || true)"
    [ -n "$nums" ] || break
    while read -r n; do
      [ -n "$n" ] && iptables -w 5 -D FORWARD "$n"
    done <<<"$nums"
  done
}

server_ip_on_wdtt() {
  ip -4 -o addr show dev "$WDTT_IF" | awk 'NR==1{split($4,a,"/"); print a[1]}'
}

apply_msk() {
  ip link show dev "$WDTT_IF" >/dev/null 2>&1 || die "$WDTT_IF does not exist. Start wdtt.service first."
  ip link show dev "$MESH_BRIDGE" >/dev/null 2>&1 || die "$MESH_BRIDGE does not exist. Is the Mesh container running?"

  local wdtt_server_ip
  wdtt_server_ip="$(server_ip_on_wdtt)"
  [ -n "$wdtt_server_ip" ] || die "Could not determine IPv4 address on $WDTT_IF."

  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w "net.ipv4.conf.${WDTT_IF}.rp_filter=2" || true
  sysctl -q -w "net.ipv4.conf.${MESH_BRIDGE}.rp_filter=2" || true

  ip -4 route replace "$WDTT_NET" dev "$WDTT_IF" scope link src "$wdtt_server_ip" table "$ROUTE_TABLE"
  ip -4 route replace default via "$MESH_CONTAINER_IP" dev "$MESH_BRIDGE" table "$ROUTE_TABLE"

  while ip -4 rule del pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE" 2>/dev/null; do :; done
  ip -4 rule add pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE"
  ip -4 route flush cache 2>/dev/null || true

  iptables -w 5 -N "$CHAIN_MSK" 2>/dev/null || true
  iptables -w 5 -F "$CHAIN_MSK"
  iptables -w 5 -A "$CHAIN_MSK" -i "$WDTT_IF" -s "$WDTT_NET" -o "$MESH_BRIDGE" -j ACCEPT
  iptables -w 5 -A "$CHAIN_MSK" -i "$MESH_BRIDGE" -o "$WDTT_IF" -d "$WDTT_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -w 5 -A "$CHAIN_MSK" -i "$WDTT_IF" -s "$WDTT_NET" -j DROP

  remove_forward_jumps_by_comment "$COMMENT_MSK_OUT"
  remove_forward_jumps_by_comment "$COMMENT_MSK_IN"
  ensure_jump "$CHAIN_MSK" "$COMMENT_MSK_OUT" -i "$WDTT_IF" -s "$WDTT_NET"
  ensure_jump "$CHAIN_MSK" "$COMMENT_MSK_IN" -i "$MESH_BRIDGE" -o "$WDTT_IF" -d "$WDTT_NET"

  log "MSK policy routing is active: $WDTT_NET -> Cloudflare Mesh container."
}

remove_msk_runtime() {
  while ip -4 rule del pref "$RULE_PREF" from "$WDTT_NET" table "$ROUTE_TABLE" 2>/dev/null; do :; done
  ip -4 route flush table "$ROUTE_TABLE" 2>/dev/null || true
  ip -4 route flush cache 2>/dev/null || true
  remove_forward_jumps_by_comment "$COMMENT_MSK_OUT"
  remove_forward_jumps_by_comment "$COMMENT_MSK_IN"
  iptables -w 5 -F "$CHAIN_MSK" 2>/dev/null || true
  iptables -w 5 -X "$CHAIN_MSK" 2>/dev/null || true
}

apply_de() {
  ip link show dev "$MESH_BRIDGE" >/dev/null 2>&1 || die "$MESH_BRIDGE does not exist. Is the Mesh container running?"
  if [ -z "$EXT_IF" ]; then
    EXT_IF="$(ip -4 route show table main default | awk 'NR==1{print $5}')"
  fi
  [ -n "$EXT_IF" ] || die "Could not detect the DE public interface. Use --ext-if during install."
  ip link show dev "$EXT_IF" >/dev/null 2>&1 || die "DE public interface $EXT_IF does not exist."

  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w "net.ipv4.conf.${MESH_BRIDGE}.rp_filter=2" || true

  # If the Cloudflare container preserves the original WDTT source, this route
  # gives conntrack-restored return packets a path back to the Mesh node.
  ip -4 route replace "$WDTT_NET" via "$MESH_CONTAINER_IP" dev "$MESH_BRIDGE"

  iptables -w 5 -N "$CHAIN_DE" 2>/dev/null || true
  iptables -w 5 -F "$CHAIN_DE"
  iptables -w 5 -A "$CHAIN_DE" -i "$MESH_BRIDGE" -o "$EXT_IF" -j ACCEPT
  iptables -w 5 -A "$CHAIN_DE" -i "$EXT_IF" -o "$MESH_BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -w 5 -A "$CHAIN_DE" -j RETURN

  remove_forward_jumps_by_comment "$COMMENT_DE"
  ensure_jump "$CHAIN_DE" "$COMMENT_DE" -i "$MESH_BRIDGE"
  ensure_jump "$CHAIN_DE" "$COMMENT_DE" -i "$EXT_IF" -o "$MESH_BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED

  if ! iptables -w 5 -t nat -C POSTROUTING -s "$MESH_DOCKER_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE 2>/dev/null; then
    iptables -w 5 -t nat -I POSTROUTING 1 -s "$MESH_DOCKER_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE
  fi
  if ! iptables -w 5 -t nat -C POSTROUTING -s "$WDTT_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE 2>/dev/null; then
    iptables -w 5 -t nat -I POSTROUTING 1 -s "$WDTT_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE
  fi

  log "DE Mesh exit routing is active through $EXT_IF."
}

remove_de_runtime() {
  [ -n "$EXT_IF" ] || EXT_IF="$(ip -4 route show table main default | awk 'NR==1{print $5}')"
  ip -4 route del "$WDTT_NET" via "$MESH_CONTAINER_IP" dev "$MESH_BRIDGE" 2>/dev/null || true
  remove_forward_jumps_by_comment "$COMMENT_DE"
  if [ -n "$EXT_IF" ]; then
    while iptables -w 5 -t nat -C POSTROUTING -s "$MESH_DOCKER_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE 2>/dev/null; do
      iptables -w 5 -t nat -D POSTROUTING -s "$MESH_DOCKER_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE
    done
    while iptables -w 5 -t nat -C POSTROUTING -s "$WDTT_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE 2>/dev/null; do
      iptables -w 5 -t nat -D POSTROUTING -s "$WDTT_NET" -o "$EXT_IF" -m comment --comment "$COMMENT_DE_NAT" -j MASQUERADE
    done
  fi
  iptables -w 5 -F "$CHAIN_DE" 2>/dev/null || true
  iptables -w 5 -X "$CHAIN_DE" 2>/dev/null || true
}

write_config() {
  umask 077
  cat >"$CONFIG_FILE" <<EOF_CONF
ROLE='$ROLE'
ACCOUNT_ID='$ACCOUNT_ID'
TEAM_NAME='$TEAM_NAME'
NODE_NAME='$NODE_NAME'
NODE_ID='$NODE_ID'
EXIT_ROUTE_ID='$EXIT_ROUTE_ID'
WDTT_ROUTE_ID='$WDTT_ROUTE_ID'
WDTT_IF='$WDTT_IF'
WDTT_NET='$WDTT_NET'
PROBE_IP='$PROBE_IP'
ROUTE_TABLE='$ROUTE_TABLE'
RULE_PREF='$RULE_PREF'
EXT_IF='$EXT_IF'
MESH_IMAGE='$MESH_IMAGE'
MESH_CONTAINER='$MESH_CONTAINER'
MESH_DOCKER_NETWORK='$MESH_DOCKER_NETWORK'
MESH_BRIDGE='$MESH_BRIDGE'
MESH_DOCKER_NET='$MESH_DOCKER_NET'
MESH_DOCKER_GW='$MESH_DOCKER_GW'
MESH_CONTAINER_IP='$MESH_CONTAINER_IP'
EOF_CONF
  chmod 600 "$CONFIG_FILE"
}

install_persistence() {
  local self
  self="$(readlink -f "$0")"
  [ -x "$self" ] || die "Install this script as an executable file before running install."

  cat >"$SYSTEMD_UNIT" <<EOF_UNIT
[Unit]
Description=WDTT Cloudflare Mesh selective egress
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${self} apply
ExecStop=${self} disable

[Install]
WantedBy=multi-user.target
EOF_UNIT

  if [ "$ROLE" = "msk" ]; then
    mkdir -p "$WDTT_DROPIN_DIR"
    cat >"$WDTT_DROPIN_FILE" <<EOF_DROPIN
[Unit]
Wants=wdtt-mesh-egress.service
After=wdtt-mesh-egress.service

[Service]
ExecStartPost=${self} apply
EOF_DROPIN
  fi

  systemctl daemon-reload
  systemctl enable wdtt-mesh-egress.service >/dev/null
}

remove_persistence() {
  systemctl disable wdtt-mesh-egress.service >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_UNIT" "$WDTT_DROPIN_FILE"
  rmdir "$WDTT_DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
}

install_role() {
  need_root
  ROLE="$1"; shift
  [ "$ROLE" = "de" ] || [ "$ROLE" = "msk" ] || die "Invalid role: $ROLE"
  NODE_NAME="wdtt-${ROLE}"
  parse_install_options "$@"
  validate_install_config
  install_prereqs

  ensure_cf_account_settings
  ensure_cf_mesh_profile
  ensure_cf_node

  if [ "$ROLE" = "de" ]; then
    ensure_cf_route "0.0.0.0/0" "WDTT German Internet exit"
    EXIT_ROUTE_ID="$ROUTE_ID"
    if [ -z "$EXT_IF" ]; then
      EXT_IF="$(ip -4 route show table main default | awk 'NR==1{print $5}')"
    fi
    deploy_mesh_container "true"
  else
    ensure_cf_route "$WDTT_NET" "WDTT client return route to MSK"
    WDTT_ROUTE_ID="$ROUTE_ID"
    deploy_mesh_container "false"
  fi

  write_config
  install_persistence
  if [ "$ROLE" = "de" ]; then apply_de; else apply_msk; fi

  log "Installation complete for role: $ROLE"
  warn "Cloudflare requires one human-only setting: enable 'Allow all Cloudflare One traffic to reach enrolled devices' in the dashboard if it is not already enabled."
  warn "The device profile '$PROFILE_NAME' applies 0.0.0.0/0 to ALL Mesh nodes matching warp_connector@${TEAM_NAME}.cloudflareaccess.com. A dedicated Zero Trust account is strongly recommended."
}

apply_saved() {
  need_root
  [ -f "$CONFIG_FILE" ] || die "Configuration not found: $CONFIG_FILE"
  load_config
  command -v docker >/dev/null 2>&1 || die "Docker is not installed."
  docker inspect "$MESH_CONTAINER" >/dev/null 2>&1 || die "Mesh container $MESH_CONTAINER is missing."
  docker start "$MESH_CONTAINER" >/dev/null 2>&1 || true
  if [ "$ROLE" = "de" ]; then apply_de; elif [ "$ROLE" = "msk" ]; then apply_msk; else die "Unknown saved role: $ROLE"; fi
}

disable_saved() {
  need_root
  [ -f "$CONFIG_FILE" ] || { warn "Configuration not found; nothing to disable."; return 0; }
  load_config
  if [ "$ROLE" = "de" ]; then remove_de_runtime; elif [ "$ROLE" = "msk" ]; then remove_msk_runtime; fi
  log "Runtime WDTT Mesh egress rules removed. Mesh container remains installed."
}

enable_saved() {
  apply_saved
  install_persistence
  log "WDTT Mesh egress enabled."
}

show_status() {
  need_root
  [ -f "$CONFIG_FILE" ] || die "Configuration not found: $CONFIG_FILE"
  load_config
  printf 'WDTT Mesh egress router v%s\n\n' "$VERSION"
  printf 'Role:          %s\n' "$ROLE"
  printf 'Node:          %s (%s)\n' "$NODE_NAME" "$NODE_ID"
  printf 'WDTT network:  %s\n' "$WDTT_NET"
  printf 'Docker bridge: %s (%s -> %s)\n' "$MESH_BRIDGE" "$MESH_DOCKER_GW" "$MESH_CONTAINER_IP"
  printf 'Image:         %s\n\n' "$MESH_IMAGE"
  printf 'Container:\n'
  docker ps --filter "name=^/${MESH_CONTAINER}$" --format '  {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true
  printf '\nCloudflare One Client status:\n'
  docker exec "$MESH_CONTAINER" warp-cli status 2>/dev/null || true
  if [ "$ROLE" = "msk" ]; then
    printf '\nPolicy rule:\n'
    ip -4 rule show | grep -E "^${RULE_PREF}:" || true
    printf '\nPolicy table %s:\n' "$ROUTE_TABLE"
    ip -4 route show table "$ROUTE_TABLE" 2>/dev/null || true
    printf '\nFirewall chain:\n'
    iptables -w 5 -vnL "$CHAIN_MSK" 2>/dev/null || true
  else
    printf '\nDE egress interface: %s\n' "$EXT_IF"
    printf '\nRoute back to WDTT clients:\n'
    ip -4 route show "$WDTT_NET" 2>/dev/null || true
    printf '\nFirewall chain:\n'
    iptables -w 5 -vnL "$CHAIN_DE" 2>/dev/null || true
    printf '\nNAT:\n'
    iptables -w 5 -t nat -vnL POSTROUTING 2>/dev/null | grep -F "$COMMENT_DE_NAT" || true
  fi
}

delete_cloudflare_resources() {
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is required with --delete-cloudflare."
  [ -n "$ACCOUNT_ID" ] || die "Saved ACCOUNT_ID is empty."

  local rid
  for rid in "$EXIT_ROUTE_ID" "$WDTT_ROUTE_ID"; do
    [ -n "$rid" ] || continue
    cf_api DELETE "teamnet/routes/${rid}" >/dev/null || warn "Could not delete Cloudflare route $rid (it may already be gone)."
  done
  if [ -n "$NODE_ID" ]; then
    cf_api DELETE "warp_connector/${NODE_ID}" >/dev/null || warn "Could not delete Cloudflare Mesh node $NODE_ID (it may already be gone)."
  fi
  log "Saved Cloudflare route/node resources were removed where present."
}

uninstall_saved() {
  need_root
  DELETE_CLOUDFLARE="0"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --delete-cloudflare) DELETE_CLOUDFLARE="1"; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown uninstall option: $1" ;;
    esac
  done
  [ -f "$CONFIG_FILE" ] || die "Configuration not found: $CONFIG_FILE"
  load_config

  if [ "$ROLE" = "de" ]; then remove_de_runtime; elif [ "$ROLE" = "msk" ]; then remove_msk_runtime; fi
  remove_persistence
  docker rm -f "$MESH_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$MESH_DOCKER_NETWORK" >/dev/null 2>&1 || true
  docker volume rm wdtt_mesh_data >/dev/null 2>&1 || true

  if [ "$DELETE_CLOUDFLARE" = "1" ]; then
    delete_cloudflare_resources
  fi

  rm -f "$NODE_ENV_FILE" "$CONFIG_FILE"
  log "Local Cloudflare Mesh egress deployment removed."
  if [ "$DELETE_CLOUDFLARE" != "1" ]; then
    log "Cloudflare account resources were kept. Use uninstall --delete-cloudflare with CLOUDFLARE_API_TOKEN to remove this host's node/route."
  fi
}

ACTION="${1:-}"
[ -n "$ACTION" ] || { usage; exit 1; }
shift || true

case "$ACTION" in
  install-de) install_role de "$@" ;;
  install-msk) install_role msk "$@" ;;
  apply) [ "$#" -eq 0 ] || die "apply accepts no options"; apply_saved ;;
  status) [ "$#" -eq 0 ] || die "status accepts no options"; show_status ;;
  disable) [ "$#" -eq 0 ] || die "disable accepts no options"; disable_saved ;;
  enable) [ "$#" -eq 0 ] || die "enable accepts no options"; enable_saved ;;
  uninstall) uninstall_saved "$@" ;;
  -h|--help|help) usage ;;
  *) die "Unknown action: $ACTION" ;;
esac
