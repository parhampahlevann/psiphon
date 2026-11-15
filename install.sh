#!/usr/bin/env bash
#=====================================================================
#  Psiphon SOCKS Manager  (install.sh)
#  Ubuntu 20.04 / 22.04 / 24.04
#
#  - builds psiphon-tunnel-core (ConsoleClient) inside Docker
#  - exposes SOCKS5 on 127.0.0.1:<port> (default 31080, asked during install)
#  - optional: system-wide TCP routing through Psiphon (redsocks + iptables)
#  - menu: install / uninstall / status + traffic / live monitor / logs
#
#  Usage:  sudo bash install.sh            (menu)
#          sudo bash install.sh install|uninstall|status|on|off
#=====================================================================
set -u

APP="psiphon-socks"
BASE_DIR="/opt/${APP}"
CONF_DIR="/etc/${APP}"
CONF_FILE="${CONF_DIR}/${APP}.conf"
PSI_JSON="${BASE_DIR}/config/psiphon.json"
DATA_DIR="${BASE_DIR}/data"
BUILD_DIR="${BASE_DIR}/build"
IMAGE="${APP}:local"
CONTAINER="${APP}"
ROUTING_BIN="/usr/local/sbin/psiphon-routing"
MENU_BIN="/usr/local/bin/psiphon-menu"

# Overridable from the environment (useful when Docker Hub is blocked)
GO_IMAGE="${GO_IMAGE:-golang:1-bookworm}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-debian:bookworm-slim}"
PSIPHON_REF="${PSIPHON_REF:-master}"
DOCKER_MIRROR="${DOCKER_MIRROR:-}"

# Defaults (overridden by $CONF_FILE once installed)
SERVER_IP=""
SOCKS_PORT=31080
HTTP_PORT=31081
REDSOCKS_PORT=12345
PSI_UID=1337
EXCLUDE_CIDRS=""      # space separated, e.g. "1.2.3.4 5.6.7.0/24"
EXCLUDE_DPORTS=""     # space separated TCP destination ports that bypass Psiphon
BLOCK_IPV6=0          # 1 = reject new outbound IPv6 TCP (prevents IPv6 leak)

# ---------- helpers ----------
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
msg()  { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[X]${N} $*" >&2; }
step() { echo; echo -e "${C}==== $* ====${N}"; }
kv()   { printf "  %-30s : %b\n" "$1" "$2"; }
pause(){ echo; read -r -p "Press Enter to continue..." _ || true; }

need_root() { [[ $EUID -eq 0 ]] || { err "Run as root:  sudo bash $0"; exit 1; }; }
load_conf() { [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"; return 0; }
is_installed() { [[ -f "$PSI_JSON" && -f "$CONF_FILE" ]]; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

set_conf() { # key value
  mkdir -p "$CONF_DIR"; touch "$CONF_FILE"
  if grep -q "^$1=" "$CONF_FILE"; then
    sed -i "s|^$1=.*|$1=\"$2\"|" "$CONF_FILE"
  else
    echo "$1=\"$2\"" >> "$CONF_FILE"
  fi
}

init_conf() {
  mkdir -p "$CONF_DIR"
  [[ -f "$CONF_FILE" ]] && return 0
  cat > "$CONF_FILE" <<EOF
SERVER_IP=""
SOCKS_PORT="${SOCKS_PORT}"
HTTP_PORT="${HTTP_PORT}"
REDSOCKS_PORT="${REDSOCKS_PORT}"
PSI_UID="${PSI_UID}"
# Destinations that must NOT go through Psiphon (space separated)
EXCLUDE_CIDRS=""
EXCLUDE_DPORTS=""
# 1 = block new outbound IPv6 TCP so nothing leaks around Psiphon
BLOCK_IPV6="0"
EOF
}

# ---------- install steps ----------
install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || warn "apt-get update had errors (continuing)"
  apt-get install -y ca-certificates curl gnupg iproute2 iptables jq xxd redsocks util-linux \
    || { err "apt install failed"; return 1; }
  # we run our own redsocks instance, disable the package default one
  systemctl disable --now redsocks >/dev/null 2>&1 || true
  id redsocks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redsocks
  ok "Prerequisites installed"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker already installed and running"
  else
    msg "Installing Docker (Ubuntu docker.io package)..."
    if ! apt-get install -y docker.io; then
      warn "docker.io failed, trying get.docker.com ..."
      curl -fsSL https://get.docker.com | sh || { err "Docker install failed"; return 1; }
    fi
    systemctl enable --now docker || { err "Cannot start docker"; return 1; }
  fi
  if [[ -n "$DOCKER_MIRROR" ]]; then
    msg "Setting Docker registry mirror: $DOCKER_MIRROR"
    mkdir -p /etc/docker
    if [[ -s /etc/docker/daemon.json ]]; then
      cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
      jq --arg m "$DOCKER_MIRROR" '.["registry-mirrors"]=[$m]' /etc/docker/daemon.json.bak > /etc/docker/daemon.json
    else
      jq -n --arg m "$DOCKER_MIRROR" '{"registry-mirrors":[$m]}' > /etc/docker/daemon.json
    fi
    systemctl restart docker
  fi
}

# ---------- ports ----------
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
port_free()  { ! ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
# a port held by our own running container counts as usable (reinstall / change port)
port_ok() {
  port_free "$1" && return 0
  [[ "$1" == "${CUR_SOCKS:-}" ]] \
    && [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]
}
free_port_from() { # start [excluded ports...]
  local p="$1"; shift
  while ! port_free "$p" || [[ " $* " == *" $p "* ]]; do p=$((p+1)); done
  echo "$p"
}

choose_ports() {
  local p
  CUR_SOCKS="$SOCKS_PORT"
  [[ "$SOCKS_PORT" == "1080" ]] && SOCKS_PORT=31080   # 1080 is commonly taken
  while true; do
    read -r -p "SOCKS port [${SOCKS_PORT}]: " p || return 1
    p="${p:-$SOCKS_PORT}"
    if ! valid_port "$p"; then warn "Enter a number between 1024 and 65535"; continue; fi
    if ! port_ok "$p"; then warn "Port $p is already in use, pick another"; continue; fi
    break
  done
  SOCKS_PORT="$p"
  HTTP_PORT="$(free_port_from $((SOCKS_PORT+1)) "$SOCKS_PORT")"
  REDSOCKS_PORT="$(free_port_from "$REDSOCKS_PORT" "$SOCKS_PORT" "$HTTP_PORT")"
  set_conf SOCKS_PORT "$SOCKS_PORT"; set_conf HTTP_PORT "$HTTP_PORT"; set_conf REDSOCKS_PORT "$REDSOCKS_PORT"
  ok "Ports -> SOCKS: $SOCKS_PORT | HTTP: $HTTP_PORT | redsocks: $REDSOCKS_PORT"
}

# Extract the IPv4 from a hex-encoded Psiphon server entry
decode_ip() {
  printf '%s' "$1" | tr -d '[:space:]' | xxd -r -p 2>/dev/null | head -c 300 \
    | awk '{print $1}' | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1
}

INPUT_MODE=""; SERVER_ENTRY=""; USER_JSON=""; PCID=""; SPID=""

collect_server() {
  local in
  SERVER_IP=""; INPUT_MODE=""
  echo
  msg "Psiphon can't connect to a bare IPv4: it needs the full 'Server Entry'"
  msg "(long string containing the IP + the server's keys). Paste it below,"
  msg "or give the path (no spaces) of your own psiphon .json config."
  while true; do
    read -r -p "Server Entry / config path: " in || return 1
    in="${in//[[:space:]]/}"
    [[ -z "$in" ]] && continue
    if is_ipv4 "$in"; then
      warn "A bare IPv4 isn't enough for Psiphon (keys/cert are missing)."
      warn "Provide the Server Entry that belongs to $in, or your own config file."
      continue
    fi
    if [[ -f "$in" ]]; then
      jq empty "$in" 2>/dev/null || { err "Not valid JSON"; continue; }
      INPUT_MODE="file"; USER_JSON="$in"
    elif (( ${#in} >= 100 )); then
      INPUT_MODE="entry"; SERVER_ENTRY="$in"
      SERVER_IP="$(decode_ip "$in")"
      [[ "$in" =~ ^[0-9a-fA-F]+$ ]] || warn "Entry isn't plain hex - accepted anyway, Psiphon will validate it."
    else
      err "Neither an existing file nor a valid-looking Server Entry."; continue
    fi
    break
  done

  if is_ipv4 "$SERVER_IP"; then
    ok "Server IP detected: $SERVER_IP"
  else
    SERVER_IP=""
    read -r -p "Psiphon server IPv4 (for status/firewall exemption, Enter = skip): " SERVER_IP || true
    if [[ -n "$SERVER_IP" ]] && ! is_ipv4 "$SERVER_IP"; then warn "Invalid IPv4, ignored"; SERVER_IP=""; fi
  fi

  if [[ "$INPUT_MODE" == "entry" ]]; then
    warn "PropagationChannelId / SponsorId: the defaults below are an ASSUMPTION (unverified)."
    warn "If the server rejects the connection, use the values that belong to your server."
    read -r -p "PropagationChannelId [FFFFFFFFFFFFFFFF]: " PCID || true
    read -r -p "SponsorId            [FFFFFFFFFFFFFFFF]: " SPID || true
    PCID="${PCID:-FFFFFFFFFFFFFFFF}"; SPID="${SPID:-FFFFFFFFFFFFFFFF}"
  fi
  return 0
}

write_psiphon_json() {
  mkdir -p "$BASE_DIR/config" "$DATA_DIR"
  if [[ "$INPUT_MODE" == "file" ]]; then
    jq --argjson s "$SOCKS_PORT" --argjson h "$HTTP_PORT" \
      '.LocalSocksProxyPort=$s | .LocalHttpProxyPort=$h | .DataRootDirectory="/data"' \
      "$USER_JSON" > "$PSI_JSON" || return 1
  else
    jq -n --arg pc "$PCID" --arg sp "$SPID" --arg se "$SERVER_ENTRY" \
      --argjson s "$SOCKS_PORT" --argjson h "$HTTP_PORT" \
      '{PropagationChannelId:$pc, SponsorId:$sp, LocalSocksProxyPort:$s, LocalHttpProxyPort:$h,
        DataRootDirectory:"/data", TargetServerEntry:$se}' > "$PSI_JSON" || return 1
  fi
  chown -R "$PSI_UID:$PSI_UID" "$BASE_DIR/config" "$DATA_DIR"
  chmod 700 "$BASE_DIR/config" "$DATA_DIR"; chmod 600 "$PSI_JSON"
  init_conf
  set_conf SERVER_IP "$SERVER_IP"
}

build_image() {
  mkdir -p "$BUILD_DIR"
  cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM ${GO_IMAGE} AS build
RUN git clone --depth 1 --branch "${PSIPHON_REF}" https://github.com/Psiphon-Labs/psiphon-tunnel-core.git /src
WORKDIR /src/ConsoleClient
RUN go build -trimpath -o /out/psiphon-console-client .

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/psiphon-console-client /usr/local/bin/psiphon-console-client
ENTRYPOINT ["/usr/local/bin/psiphon-console-client"]
EOF
  msg "Building Psiphon image (a few minutes, needs Docker Hub + GitHub access)..."
  docker build -t "$IMAGE" "$BUILD_DIR"
}

run_container() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  docker run -d --name "$CONTAINER" --restart unless-stopped --network host \
    --user "${PSI_UID}:${PSI_UID}" --cap-drop ALL --security-opt no-new-privileges \
    --log-opt max-size=10m --log-opt max-file=3 \
    -v "$BASE_DIR/config:/config:ro" -v "$DATA_DIR:/data" \
    "$IMAGE" -config /config/psiphon.json >/dev/null
}

write_routing_script() {
  cat > "$ROUTING_BIN" <<'EOF'
#!/usr/bin/env bash
# psiphon-routing start|stop   (managed by install.sh - do not edit)
CONF="/etc/psiphon-socks/psiphon-socks.conf"
[[ -f "$CONF" ]] && source "$CONF"
IPT="iptables -w"; IP6T="ip6tables -w"
SOCKS_PORT="${SOCKS_PORT:-1080}"; REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"; PSI_UID="${PSI_UID:-1337}"
RS_UID="$(id -u redsocks 2>/dev/null)" || { echo "redsocks user missing"; exit 1; }

stop() {
  while $IPT -t nat -D OUTPUT -p tcp -j PSIPHON_REDIR 2>/dev/null; do :; done
  $IPT -t nat -F PSIPHON_REDIR 2>/dev/null; $IPT -t nat -X PSIPHON_REDIR 2>/dev/null
  while $IPT -D OUTPUT -j PSIPHON_ACCT 2>/dev/null; do :; done
  $IPT -F PSIPHON_ACCT 2>/dev/null; $IPT -X PSIPHON_ACCT 2>/dev/null
  if command -v ip6tables >/dev/null 2>&1; then
    while $IP6T -D OUTPUT -j PSIPHON_V6 2>/dev/null; do :; done
    $IP6T -F PSIPHON_V6 2>/dev/null; $IP6T -X PSIPHON_V6 2>/dev/null
  fi
  return 0
}

start() {
  stop
  local c p
  $IPT -t nat -N PSIPHON_REDIR || exit 1
  # Psiphon itself and redsocks must go out directly (no loops)
  $IPT -t nat -A PSIPHON_REDIR -m owner --uid-owner "$RS_UID"  -j RETURN
  $IPT -t nat -A PSIPHON_REDIR -m owner --uid-owner "$PSI_UID" -j RETURN
  for c in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
           192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 $SERVER_IP $EXCLUDE_CIDRS; do
    [[ -n "$c" ]] && $IPT -t nat -A PSIPHON_REDIR -d "$c" -j RETURN
  done
  for p in $EXCLUDE_DPORTS; do
    $IPT -t nat -A PSIPHON_REDIR -p tcp --dport "$p" -j RETURN
  done
  $IPT -t nat -A PSIPHON_REDIR -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
  $IPT -t nat -I OUTPUT 1 -p tcp -j PSIPHON_REDIR

  # byte counters for traffic going into / coming out of the Psiphon SOCKS port
  $IPT -N PSIPHON_ACCT
  $IPT -A PSIPHON_ACCT -p tcp -d 127.0.0.1 --dport "$SOCKS_PORT" -m comment --comment psiphon-up
  $IPT -A PSIPHON_ACCT -p tcp -s 127.0.0.1 --sport "$SOCKS_PORT" -m comment --comment psiphon-down
  $IPT -I OUTPUT 1 -j PSIPHON_ACCT

  if [[ "${BLOCK_IPV6:-0}" == "1" ]] && command -v ip6tables >/dev/null 2>&1; then
    $IP6T -N PSIPHON_V6
    $IP6T -A PSIPHON_V6 -o lo -j RETURN
    $IP6T -A PSIPHON_V6 -m owner --uid-owner "$PSI_UID" -j RETURN
    $IP6T -A PSIPHON_V6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    $IP6T -A PSIPHON_V6 -p tcp -j REJECT --reject-with tcp-reset
    $IP6T -I OUTPUT 1 -j PSIPHON_V6
  fi
}

case "${1:-}" in
  start) start ;;
  stop)  stop ;;
  *) echo "usage: $0 start|stop"; exit 1 ;;
esac
EOF
  chmod 755 "$ROUTING_BIN"
}

write_units() {
  local rs_bin
  rs_bin="$(command -v redsocks)" || { err "redsocks binary not found"; return 1; }
  cat > "$CONF_DIR/redsocks.conf" <<EOF
base {
  log_debug = off;
  log_info = on;
  log = "stderr";
  daemon = off;
  redirector = iptables;
}
redsocks {
  local_ip = 127.0.0.1;
  local_port = ${REDSOCKS_PORT};
  ip = 127.0.0.1;
  port = ${SOCKS_PORT};
  type = socks5;
}
EOF
  cat > /etc/systemd/system/psiphon-redsocks.service <<EOF
[Unit]
Description=redsocks (transparent TCP -> Psiphon SOCKS)
After=docker.service network-online.target

[Service]
User=redsocks
ExecStart=${rs_bin} -c ${CONF_DIR}/redsocks.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/psiphon-routing.service <<EOF
[Unit]
Description=Psiphon system-wide TCP routing (iptables)
After=docker.service psiphon-redsocks.service network-online.target
Requires=psiphon-redsocks.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ROUTING_BIN} start
ExecStop=${ROUTING_BIN} stop

[Install]
WantedBy=multi-user.target
EOF
  write_routing_script
  systemctl daemon-reload
}

install_self() {
  local me; me="$(readlink -f "$0" 2>/dev/null)"
  if [[ -f "$me" && "$me" != "$MENU_BIN" ]]; then
    install -m 755 "$me" "$MENU_BIN" && ok "Menu available any time with:  sudo psiphon-menu"
  fi
}

# ---------- runtime checks ----------
fetch_ip() { # mode: socks | direct | default
  local mode="$1" u ip
  for u in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    case "$mode" in
      socks)   ip="$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" "$u" 2>/dev/null)" ;;
      direct)  ip="$(runuser -u redsocks -- curl -4 -s --max-time 10 "$u" 2>/dev/null)" ;;
      *)       ip="$(curl -4 -s --max-time 10 "$u" 2>/dev/null)" ;;
    esac
    ip="${ip//[[:space:]]/}"
    if is_ipv4 "$ip"; then echo "$ip"; return 0; fi
  done
  return 1
}

tunnel_count() {
  docker logs --tail 1000 "$CONTAINER" 2>&1 | grep '"noticeType":"Tunnels"' | tail -n1 \
    | sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p'
}

routing_active() {
  systemctl is-active --quiet psiphon-routing.service \
    && iptables -w -t nat -S OUTPUT 2>/dev/null | grep -q PSIPHON_REDIR
}

hb() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

wait_tunnel() {
  msg "Waiting for Psiphon to connect (up to ~2 min)..."
  for _ in $(seq 1 40); do
    if [[ "$(tunnel_count)" -ge 1 ]] 2>/dev/null && [[ -n "$(fetch_ip socks)" ]]; then return 0; fi
    sleep 3
  done
  return 1
}

# ---------- actions ----------
routing_on() {
  load_conf
  systemctl enable --now psiphon-routing.service \
    && ok "System-wide TCP routing is ON (all new outbound TCP -> Psiphon)" \
    || err "Failed to enable routing (see: journalctl -u psiphon-routing -u psiphon-redsocks)"
}

routing_off() {
  systemctl disable --now psiphon-routing.service >/dev/null 2>&1
  systemctl stop psiphon-redsocks.service >/dev/null 2>&1
  [[ -x "$ROUTING_BIN" ]] && "$ROUTING_BIN" stop
  ok "System-wide routing is OFF (SOCKS 127.0.0.1:${SOCKS_PORT} still works for apps that use it)"
}

full_install() {
  local a
  if is_installed; then
    warn "Already installed. Continuing will rebuild and replace the config."
    read -r -p "Continue? [y/N]: " a || return 1
    [[ "$a" =~ ^[Yy]$ ]] || return 0
  fi

  step "1/5  Packages"
  install_packages || return 1
  step "2/5  Docker"
  install_docker || return 1

  step "3/5  Psiphon server"
  collect_server || return 1
  init_conf; load_conf
  choose_ports || return 1
  write_psiphon_json || { err "Could not write config"; return 1; }

  step "4/5  Build & run Psiphon container"
  if ! build_image; then
    err "Docker build failed. If Docker Hub / GitHub is blocked from this server, retry with e.g.:"
    err "  DOCKER_MIRROR=https://<your-mirror> GO_IMAGE=<mirror>/golang:1-bookworm RUNTIME_IMAGE=<mirror>/debian:bookworm-slim bash $0"
    return 1
  fi
  write_units || return 1
  run_container || { err "Could not start container"; return 1; }
  install_self

  step "5/5  Connection test"
  if wait_tunnel; then
    ok "Psiphon SOCKS works. Exit IP via Psiphon: $(fetch_ip socks)"
    echo
    warn "System-wide routing sends ALL new outbound TCP of this server through Psiphon"
    warn "(including other tunnels/services running here, unless you add them to EXCLUDE_* in the settings)."
    read -r -p "Enable system-wide routing now? [y/N]: " a || a=""
    if [[ "$a" =~ ^[Yy]$ ]]; then routing_on; else msg "Routing left OFF. Enable it from the menu (option 5)."; fi
  else
    err "Psiphon did not connect. Routing NOT enabled (to avoid cutting your outbound traffic)."
    err "Check logs (menu option 8): wrong Server Entry / SponsorId / PropagationChannelId is the usual cause."
  fi
}

uninstall_all() {
  local a
  warn "This removes the Psiphon container/image, routing rules, services and all config."
  read -r -p "Type 'yes' to continue: " a || return 1
  [[ "$a" == "yes" ]] || { msg "Cancelled"; return 0; }

  step "Removing routing"
  systemctl disable --now psiphon-routing.service >/dev/null 2>&1
  systemctl disable --now psiphon-redsocks.service >/dev/null 2>&1
  [[ -x "$ROUTING_BIN" ]] && "$ROUTING_BIN" stop

  step "Removing container & image"
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    docker rmi -f "$IMAGE" >/dev/null 2>&1
    read -r -p "Also remove base images ($GO_IMAGE, $RUNTIME_IMAGE)? [y/N]: " a || a=""
    [[ "$a" =~ ^[Yy]$ ]] && docker rmi "$GO_IMAGE" "$RUNTIME_IMAGE" >/dev/null 2>&1
  fi

  step "Removing files"
  rm -f /etc/systemd/system/psiphon-routing.service /etc/systemd/system/psiphon-redsocks.service
  systemctl daemon-reload
  rm -rf "$BASE_DIR" "$CONF_DIR"
  rm -f "$ROUTING_BIN"

  read -r -p "Remove the redsocks package? [Y/n]: " a || a=""
  if [[ ! "$a" =~ ^[Nn]$ ]]; then apt-get purge -y redsocks >/dev/null 2>&1; userdel redsocks >/dev/null 2>&1; fi
  read -r -p "Remove Docker packages too? (other containers may depend on it) [y/N]: " a || a=""
  if [[ "$a" =~ ^[Yy]$ ]]; then
    apt-get purge -y docker.io docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    warn "Docker packages removed. /var/lib/docker was kept (delete it manually if you want)."
  fi
  rm -f "$MENU_BIN"
  ok "Psiphon SOCKS fully uninstalled"
}

change_server() {
  is_installed || { warn "Not installed yet"; return; }
  collect_server || return
  load_conf
  write_psiphon_json || { err "Could not write config"; return; }
  load_conf
  docker restart "$CONTAINER" >/dev/null && ok "Psiphon restarted with the new server"
  routing_active && systemctl restart psiphon-routing.service
}

change_port() {
  is_installed || { warn "Not installed yet"; return; }
  load_conf
  local was_routing=0; routing_active && was_routing=1
  choose_ports || return
  jq --argjson s "$SOCKS_PORT" --argjson h "$HTTP_PORT" \
    '.LocalSocksProxyPort=$s | .LocalHttpProxyPort=$h' "$PSI_JSON" > "$PSI_JSON.tmp" \
    && mv "$PSI_JSON.tmp" "$PSI_JSON"
  chown "$PSI_UID:$PSI_UID" "$PSI_JSON"; chmod 600 "$PSI_JSON"
  write_units
  run_container
  (( was_routing )) && systemctl restart psiphon-redsocks.service psiphon-routing.service
  ok "SOCKS port is now $SOCKS_PORT"
}

edit_settings() {
  is_installed || { warn "Not installed yet"; return; }
  "${EDITOR:-nano}" "$CONF_FILE" 2>/dev/null || vi "$CONF_FILE"
  load_conf
  if routing_active; then systemctl restart psiphon-routing.service && ok "Routing rules re-applied"; fi
}

show_status() {
  load_conf
  echo -e "${C}================= Psiphon SOCKS status =================${N}"
  if ! is_installed; then warn "Not installed yet (menu option 1)."; return; fi
  command -v docker >/dev/null 2>&1 || { err "docker not found"; return; }

  local running tun real viasocks dflt up dn conns sconn rt=0
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"
  if [[ "$running" == "true" ]]; then
    kv "Container" "${G}running${N} (since $(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" | cut -d. -f1))"
  else
    kv "Container" "${R}NOT running${N}"
  fi

  if ss -Hltn "sport = :${SOCKS_PORT}" 2>/dev/null | grep -q .; then
    kv "SOCKS 127.0.0.1:${SOCKS_PORT}" "${G}listening${N}"
  else
    kv "SOCKS 127.0.0.1:${SOCKS_PORT}" "${R}down${N}"
  fi

  tun="$(tunnel_count)"
  if [[ "${tun:-0}" -ge 1 ]]; then
    kv "Psiphon tunnel" "${G}CONNECTED${N} (active tunnels: $tun)"
  else
    kv "Psiphon tunnel" "${Y}not connected yet / reconnecting${N}"
  fi

  if [[ -n "$SERVER_IP" ]]; then
    sconn="$(ss -Htun dst "$SERVER_IP" 2>/dev/null | grep -c .)"
    if (( sconn > 0 )); then kv "Psiphon server $SERVER_IP" "${G}connected ($sconn sockets)${N}"
    else kv "Psiphon server $SERVER_IP" "${Y}no open socket${N}"; fi
  fi

  if routing_active; then
    rt=1; kv "System-wide routing" "${G}ON${N}"
  else
    kv "System-wide routing" "${Y}OFF${N}"
  fi

  msg "Checking public IPs (can take a few seconds)..."
  real="$(fetch_ip direct)"; viasocks="$(fetch_ip socks)"; dflt="$(fetch_ip default)"
  kv "Real IPv4 (direct)"          "${real:-?}"
  kv "IPv4 via SOCKS (Psiphon)"    "${viasocks:-?}"
  kv "IPv4 of normal server traffic" "${dflt:-?}"

  up="$(iptables -w -L PSIPHON_ACCT -v -n -x 2>/dev/null | awk '/psiphon-up/{print $2}')"
  dn="$(iptables -w -L PSIPHON_ACCT -v -n -x 2>/dev/null | awk '/psiphon-down/{print $2}')"
  conns="$(ss -Htn state established "( dport = :${SOCKS_PORT} )" 2>/dev/null | grep -c .)"
  if [[ -n "$up" ]]; then
    kv "Traffic via Psiphon (approx)" "upload $(hb "$up")  /  download $(hb "$dn")  (since routing start)"
  else
    kv "Traffic via Psiphon (approx)" "n/a (counters exist only while routing is ON)"
  fi
  kv "Active proxied connections" "$conns"

  echo
  if (( rt == 1 )) && [[ -n "$viasocks" && "$dflt" == "$viasocks" && "$real" != "$viasocks" ]]; then
    echo -e "  ${G}[OK]${N} Server traffic is leaving through Psiphon ($viasocks) instead of your real IP (${real:-?})."
  elif (( rt == 1 )); then
    echo -e "  ${Y}[!]${N} Routing is ON but the IPs don't match as expected - check Psiphon connection/logs."
  else
    echo -e "  ${Y}[i]${N} Routing is OFF: only apps using SOCKS 127.0.0.1:${SOCKS_PORT} go through Psiphon."
  fi
  [[ "${BLOCK_IPV6:-0}" == "1" ]] || echo -e "  ${Y}[i]${N} IPv6 and UDP (incl. DNS) are NOT routed through Psiphon."
}

live_status() {
  LIVE_STOP=0; trap 'LIVE_STOP=1' INT
  while (( LIVE_STOP == 0 )); do
    clear; show_status; echo; echo "(Ctrl+C = back to menu)"
    sleep 3
  done
  trap - INT
}

show_logs() {
  command -v docker >/dev/null 2>&1 && docker logs --tail 40 "$CONTAINER" 2>&1 | cut -c1-220
  echo; msg "Routing/redsocks logs:  journalctl -u psiphon-redsocks -u psiphon-routing -n 30"
}

toggle_routing() {
  is_installed || { warn "Not installed yet"; return; }
  if routing_active; then routing_off
  else
    warn "ALL new outbound TCP of this server will go through Psiphon."
    read -r -p "Enable? [y/N]: " a || return
    [[ "$a" =~ ^[Yy]$ ]] && routing_on
  fi
}

restart_psiphon() {
  is_installed || { warn "Not installed yet"; return; }
  docker restart "$CONTAINER" >/dev/null && ok "Psiphon container restarted"
}

# ---------- menu ----------
banner() {
  clear
  echo -e "${C}==========================================${N}"
  echo -e "${C}        Psiphon SOCKS Manager             ${N}"
  echo -e "${C}==========================================${N}"
  if is_installed; then
    load_conf
    local s="stopped"; [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]] && s="running"
    local r="OFF";     routing_active && r="ON"
    echo -e "  Installed: ${G}yes${N} | container: $s | routing: $r | server: ${SERVER_IP:-n/a}"
  else
    echo -e "  Installed: ${Y}no${N}"
  fi
  echo
}

main() {
  need_root
  load_conf
  case "${1:-}" in
    install)   full_install; exit 0 ;;
    uninstall) uninstall_all; exit 0 ;;
    status)    show_status; exit 0 ;;
    on)        routing_on; exit 0 ;;
    off)       routing_off; exit 0 ;;
  esac
  local c
  while true; do
    banner
    echo "  1) Full install (Docker + Psiphon + SOCKS)"
    echo "  2) Full uninstall"
    echo "  3) Status: connection + traffic"
    echo "  4) Live status monitor"
    echo "  5) Turn system-wide routing ON / OFF"
    echo "  6) Restart Psiphon"
    echo "  7) Change Psiphon server"
    echo "  8) Show logs"
    echo "  9) Edit settings (exclusions, IPv6 block)"
    echo " 10) Change SOCKS port"
    echo "  0) Exit"
    echo
    read -r -p "Select: " c || exit 0
    case "$c" in
      1) full_install; pause ;;
      2) uninstall_all; pause ;;
      3) show_status; pause ;;
      4) live_status ;;
      5) toggle_routing; pause ;;
      6) restart_psiphon; pause ;;
      7) change_server; pause ;;
      8) show_logs; pause ;;
      9) edit_settings; pause ;;
      10) change_port; pause ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main "$@"
exit 0
