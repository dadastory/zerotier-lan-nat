#!/usr/bin/env bash
set -euo pipefail

# Load defaults first. Environment variables passed by the caller still win.
if [[ -r /etc/default/zerotier-lan-nat ]]; then
  # shellcheck disable=SC1091
  source /etc/default/zerotier-lan-nat
fi

APP_DIR="${APP_DIR:-/opt/docker/zerotier-lan-nat}"
ROUTES_FILE="${ROUTES_FILE:-$APP_DIR/routes.conf}"
LAN_IF="${LAN_IF:-eth0}"
LAN_NET="${LAN_NET:-192.168.1.0/24}"
COMMENT="zerotier-lan-nat"

usage() {
  cat <<USAGE
Usage: $0 <command> [args]

Commands:
  start|apply|restart     Apply all routes in routes.conf
  stop                    Remove all rules managed by this tool
  status                  Show config and active iptables rules
  list                    List configured ZeroTier routes
  add <zt_if> <zt_net>    Add a route and apply, example: add ztxxxxxxxx 10.147.17.0/24
  remove <zt_if> <zt_net> Remove an exact route and apply
  remove <zt_net>         Remove routes matching this subnet and apply
  remove <zt_if>          Remove routes matching this interface and apply
USAGE
}

ensure_files() {
  mkdir -p "$APP_DIR"
  touch "$ROUTES_FILE"
}

ipt() { iptables "$@"; }

forward_chain() {
  if ipt -L DOCKER-USER -n >/dev/null 2>&1; then
    echo DOCKER-USER
  else
    echo FORWARD
  fi
}

add_filter_rule() {
  local chain="$1"; shift
  if ! ipt -C "$chain" "$@" >/dev/null 2>&1; then
    ipt -I "$chain" 1 "$@"
  fi
}

add_nat_rule() {
  if ! ipt -t nat -C POSTROUTING "$@" >/dev/null 2>&1; then
    ipt -t nat -A POSTROUTING "$@"
  fi
}

remove_all_managed_rules() {
  local chain rule
  chain="$(forward_chain)"

  while rule="$(iptables -S "$chain" | grep -- "$COMMENT" | head -n 1 || true)"; [[ -n "$rule" ]]; do
    eval "iptables ${rule/-A/-D}"
  done

  while rule="$(iptables -t nat -S POSTROUTING | grep -- "$COMMENT" | head -n 1 || true)"; [[ -n "$rule" ]]; do
    eval "iptables -t nat ${rule/-A/-D}"
  done
}

route_entries() {
  ensure_files
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    # trim leading/trailing whitespace
    line="$(awk '{$1=$1; print}' <<<"$line")"
    [[ -z "$line" ]] && continue

    local first second zt_if zt_net
    read -r first second _ <<<"$line"
    if [[ "$first" == *":"* && -z "${second:-}" ]]; then
      zt_if="${first%%:*}"
      zt_net="${first#*:}"
    else
      zt_if="$first"
      zt_net="${second:-}"
    fi

    [[ -z "$zt_if" || -z "$zt_net" ]] && continue
    printf '%s %s\n' "$zt_if" "$zt_net"
  done < "$ROUTES_FILE"
}

apply_one() {
  local zt_if="$1" zt_net="$2" chain
  chain="$(forward_chain)"

  add_filter_rule "$chain" -i "$zt_if" -o "$LAN_IF" -s "$zt_net" -d "$LAN_NET" \
    -m comment --comment "$COMMENT forward-to-lan $zt_if $zt_net" -j ACCEPT
  add_filter_rule "$chain" -i "$LAN_IF" -o "$zt_if" -s "$LAN_NET" -d "$zt_net" \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "$COMMENT return-to-zt $zt_if $zt_net" -j ACCEPT
  add_nat_rule -s "$zt_net" -d "$LAN_NET" -o "$LAN_IF" \
    -m comment --comment "$COMMENT masquerade $zt_if $zt_net" -j MASQUERADE
}

apply_rules() {
  ensure_files
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  remove_all_managed_rules
  while read -r zt_if zt_net; do
    apply_one "$zt_if" "$zt_net"
  done < <(route_entries)
}

list_routes() {
  echo "Routes file: $ROUTES_FILE"
  if ! route_entries | grep -q .; then
    echo "(no routes configured)"
    return 0
  fi
  route_entries | awk '{printf "%-16s %s\n", $1, $2}'
}

status_rules() {
  echo "APP_DIR=$APP_DIR"
  echo "ROUTES_FILE=$ROUTES_FILE"
  echo "LAN_IF=$LAN_IF"
  echo "LAN_NET=$LAN_NET"
  echo "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  echo
  list_routes
  echo
  echo "Active rules:"
  iptables -S "$(forward_chain)" | grep "$COMMENT" || true
  iptables -t nat -S POSTROUTING | grep "$COMMENT" || true
}

add_route() {
  [[ $# -eq 2 ]] || { usage >&2; exit 2; }
  ensure_files
  local zt_if="$1" zt_net="$2"
  if route_entries | awk -v i="$zt_if" -v n="$zt_net" '$1==i && $2==n {found=1} END {exit !found}'; then
    echo "Route already exists: $zt_if $zt_net"
  else
    printf '%s %s\n' "$zt_if" "$zt_net" >> "$ROUTES_FILE"
    echo "Added route: $zt_if $zt_net"
  fi
  apply_rules
}

remove_route() {
  [[ $# -eq 1 || $# -eq 2 ]] || { usage >&2; exit 2; }
  ensure_files
  local tmp removed=0 match_if="" match_net=""
  tmp="$(mktemp)"
  if [[ $# -eq 2 ]]; then
    match_if="$1"; match_net="$2"
  else
    if [[ "$1" == */* ]]; then
      match_net="$1"
    else
      match_if="$1"
    fi
  fi

  while read -r zt_if zt_net; do
    if [[ -n "$match_if" && -n "$match_net" && "$zt_if" == "$match_if" && "$zt_net" == "$match_net" ]]; then
      echo "Removed route: $zt_if $zt_net"; removed=1; continue
    elif [[ -n "$match_if" && -z "$match_net" && "$zt_if" == "$match_if" ]]; then
      echo "Removed route: $zt_if $zt_net"; removed=1; continue
    elif [[ -z "$match_if" && -n "$match_net" && "$zt_net" == "$match_net" ]]; then
      echo "Removed route: $zt_if $zt_net"; removed=1; continue
    fi
    printf '%s %s\n' "$zt_if" "$zt_net" >> "$tmp"
  done < <(route_entries)

  mv "$tmp" "$ROUTES_FILE"
  if [[ "$removed" -eq 0 ]]; then
    echo "No matching route found."
  fi
  apply_rules
}

cmd="${1:-status}"
shift || true
case "$cmd" in
  start|apply|restart) apply_rules ;;
  stop) remove_all_managed_rules ;;
  status) status_rules ;;
  list) list_routes ;;
  add) add_route "$@" ;;
  remove|rm|del|delete) remove_route "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
