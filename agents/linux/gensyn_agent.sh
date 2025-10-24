#!/usr/bin/env bash
# Gensyn heartbeat agent (Linux)
# Sends node health to central server every run (use with systemd timer)
set -euo pipefail

# --- Config --------------------------------------------------------------------
# You can override via env or /etc/gensyn-agent.env
SERVER_URL="${SERVER_URL:-http://YOUR_MONITOR_HOST:8080}"
SHARED_SECRET="${SHARED_SECRET:-super-long-random-secret}"
NODE_ID="${NODE_ID:-$(hostname)-gensyn}"
META="${META:-}"                 # e.g. "hetzner-fsn1,ram=16g"
SCREEN_NAME="${SCREEN_NAME:-gensyn}"
CHECK_PORT="${CHECK_PORT:-true}" # check local UI port 3000
PORT="${PORT:-3000}"
IP_CMD="${IP_CMD:-https://ifconfig.me}"

# Доп. параметры детекции
AUTO_KILL_EMPTY_SCREEN="${AUTO_KILL_EMPTY_SCREEN:-false}"
# «боевые» процессы (нода реально работает)
ALLOW_REGEX="${ALLOW_REGEX:-rgym_exp\.runner\.swarm_launcher|hivemind_cli/p2pd|(^|[/[:space:]])rl-swarm([[:space:]]|$)|python[^ ]*.*rgym_exp}"
# «обёртки»/стабы (не считаем здоровьем)
DENY_REGEX="${DENY_REGEX:-run_rl_swarm\.sh|while[[:space:]]+true|sleep[[:space:]]+60}"
# считать UP, если боевой процесс найден без screen
PROC_FALLBACK_WITHOUT_SCREEN="${PROC_FALLBACK_WITHOUT_SCREEN:-true}"

# Optional: global env file
if [[ -f /etc/gensyn-agent.env ]]; then
  # shellcheck disable=SC1091
  . /etc/gensyn-agent.env
fi

# --- Helpers -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

log() { printf '[%s] %s\n' "$(date -u +%F'T'%T'Z')" "$*" >&2; }

# Имя screen-сессии вида "12345.gensyn"
screen_session_name() {
  have screen || return 1
  screen -list 2>/dev/null \
    | sed -nE "s/^[[:space:]]*([0-9]+\.${SCREEN_NAME})[[:space:]].*/\1/p" \
    | head -n1
}

# Есть ли В ЭТОЙ screen «боевой» процесс (по ALLOW), не попадающий под DENY?
has_target_in_screen() {
  local sname="$1" p args
  [[ -z "$sname" ]] && return 1
  have pgrep || return 1
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # процесс действительно запущен внутри этой screen? (проверяем STY)
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "STY=$sname"; then
      args=$(ps -p "$p" -o args= 2>/dev/null || true)
      # отфильтруем обёртки
      if ! grep -Eiq "$DENY_REGEX" <<<"$args"; then
        return 0
      fi
    fi
  done < <(pgrep -f "$ALLOW_REGEX" 2>/dev/null)
  return 1
}

screen_ok() {
  # screen считается «ок», если есть именованная сессия и в ней найден боевой процесс
  local sname; sname="$(screen_session_name || true)"
  [[ -n "$sname" ]] && has_target_in_screen "$sname"
}

proc_ok() {
  # если нет screen — по желанию считаем UP при наличии боевых процессов без screen
  [[ "$PROC_FALLBACK_WITHOUT_SCREEN" != "true" ]] && return 1
  have pgrep && pgrep -f "$ALLOW_REGEX" >/dev/null 2>&1
}

port_ok() {
  if [[ "${CHECK_PORT}" != "true" ]]; then return 0; fi
  # Try bash /dev/tcp; fallback to nc if available
  if timeout 1 bash -c ">/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
    return 0
  elif have nc && nc -z -w1 127.0.0.1 "${PORT}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

public_ip() {
  (curl -fsS --max-time 2 "${IP_CMD}" || true) | tr -d '\r\n'
}

# --- Health check --------------------------------------------------------------
status="DOWN"

# Определим имя сессии один раз (для авто-килла)
sname="$(screen_session_name || true)"

if [[ -n "$sname" ]]; then
  if has_target_in_screen "$sname" && port_ok; then
    status="UP"
  else
    # пустая screen — можно аккуратно закрыть (опционально)
    if [[ "$AUTO_KILL_EMPTY_SCREEN" == "true" ]]; then
      screen -S "$SCREEN_NAME" -X quit || true
      log "INFO: auto-closed empty screen $SCREEN_NAME"
    fi
  fi
else
  # без screen: допускаем UP, если боевой процесс есть и порт ок (если включено)
  if proc_ok && port_ok; then
    status="UP"
  fi
fi

IP="$(public_ip)"

payload=$(printf '{"node_id":"%s","ip":"%s","meta":"%s","status":"%s"}' \
  "$NODE_ID" "${IP}" "${META}" "${status}")

# --- Send heartbeat ------------------------------------------------------------
if ! have curl; then
  log "ERROR: curl not found"; exit 1
fi

curl -fsS -X POST "${SERVER_URL%/}/api/heartbeat" \
  -H "Authorization: Bearer ${SHARED_SECRET}" \
  -H "Content-Type: application/json" \
  --data "${payload}" >/dev/null 2>&1 || {
    log "WARN: heartbeat send failed"
    exit 0
  }

# optional local log
log "beat node_id=${NODE_ID} status=${status} ip=${IP}"
