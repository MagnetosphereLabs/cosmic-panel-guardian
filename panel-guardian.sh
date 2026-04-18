#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cosmic-panel-guardian"
INTERVAL_SEC=15
ACCURACY_SEC=5
COOLDOWN_SEC=45
MISS_THRESHOLD=2

# Tightened to the exact failure family from your logs.
ERROR_RE='Failed to render, error: An unknown error \(0\)|eglExportDMABUFImageMESA|eglDupNativeFenceFDANDROID|Erroneous EGL call didn.t set EGLError|EGL_BAD_MATCH|EGL_BAD_PARAMETER'

BIN_DIR="${HOME}/.local/bin"
INSTALL_PATH="${BIN_DIR}/${APP_NAME}"
UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_PATH="${UNIT_DIR}/${APP_NAME}.service"
TIMER_PATH="${UNIT_DIR}/${APP_NAME}.timer"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
LOG_FILE="${STATE_DIR}/guardian.log"
LAST_CHECK_FILE="${STATE_DIR}/last_check"
LAST_RESTART_FILE="${STATE_DIR}/last_restart"
MISS_COUNT_FILE="${STATE_DIR}/miss_count"
LOCK_FILE="${STATE_DIR}/check.lock"

log() {
  mkdir -p "${STATE_DIR}"
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >> "${LOG_FILE}"
}

read_num() {
  local file="$1"
  local fallback="$2"
  if [[ -r "${file}" ]]; then
    local v
    v="$(cat "${file}" 2>/dev/null || true)"
    if [[ "${v}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${v}"
      return
    fi
  fi
  printf '%s\n' "${fallback}"
}

panel_pid() {
  pgrep -x cosmic-panel | tail -n 1 || true
}

session_pid() {
  pgrep -x cosmic-session | tail -n 1 || true
}

panel_bin() {
  command -v cosmic-panel 2>/dev/null || printf '%s\n' "/usr/bin/cosmic-panel"
}

import_session_env() {
  local pid="${1:-}"
  if [[ -n "${pid}" && -r "/proc/${pid}/environ" ]]; then
    while IFS='=' read -r key value; do
      case "${key}" in
        WAYLAND_DISPLAY|DISPLAY|XDG_SESSION_TYPE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)
          export "${key}=${value}"
          ;;
      esac
    done < <(tr '\0' '\n' < "/proc/${pid}/environ")
  fi

  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
  : "${XDG_SESSION_TYPE:=wayland}"

  if [[ -z "${WAYLAND_DISPLAY:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
    local sock=""
    sock="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | sort | head -n 1 | xargs -r basename || true)"
    if [[ -n "${sock}" ]]; then
      export WAYLAND_DISPLAY="${sock}"
    fi
  fi
}

start_panel_direct() {
  local bin
  bin="$(panel_bin)"
  if [[ ! -x "${bin}" ]]; then
    log "start fallback failed: cosmic-panel binary not found"
    return 1
  fi

  import_session_env "$(session_pid)"

  local -a env_args
  env_args=(env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}" "XDG_SESSION_TYPE=${XDG_SESSION_TYPE}")
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && env_args+=("WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
  [[ -n "${DISPLAY:-}" ]] && env_args+=("DISPLAY=${DISPLAY}")
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && env_args+=("DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}")

  nohup "${env_args[@]}" "${bin}" >/dev/null 2>&1 &
}

recent_panel_logs() {
  local since_epoch="$1"
  journalctl --user -b --no-pager --since "@${since_epoch}" _COMM=cosmic-panel -o cat 2>/dev/null || true
}

repair_panel() {
  local reason="$1"
  local now last_restart pid

  now="$(date +%s)"
  last_restart="$(read_num "${LAST_RESTART_FILE}" 0)"
  pid="$(panel_pid)"

  if (( now - last_restart < COOLDOWN_SEC )); then
    log "cooldown active; skipped repair (${reason})"
    return 0
  fi

  printf '%s\n' "${now}" > "${LAST_RESTART_FILE}"
  log "repair triggered: ${reason}"

  # Preferred path: terminate only cosmic-panel and let cosmic-session respawn it.
  if [[ -n "${pid}" ]]; then
    pkill -TERM -x cosmic-panel || true
    sleep 2
  fi

  # Fallback: if still absent, launch it directly inside the user session.
  if ! pgrep -x cosmic-panel >/dev/null 2>&1; then
    start_panel_direct || true
    sleep 2
  fi

  if pgrep -x cosmic-panel >/dev/null 2>&1; then
    printf '0\n' > "${MISS_COUNT_FILE}"
    log "repair complete"
  else
    log "repair attempted, but cosmic-panel is still not present"
  fi
}

check_once() {
  mkdir -p "${STATE_DIR}"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || exit 0

  local now last_check pid miss_count since_epoch logs

  now="$(date +%s)"
  last_check="$(read_num "${LAST_CHECK_FILE}" "$((now - INTERVAL_SEC - 5))")"
  miss_count="$(read_num "${MISS_COUNT_FILE}" 0)"
  since_epoch="${last_check}"

  if (( since_epoch < now - 90 )); then
    since_epoch=$((now - 90))
  fi

  pid="$(panel_pid)"
  printf '%s\n' "${now}" > "${LAST_CHECK_FILE}"

  if [[ -z "${pid}" ]]; then
    miss_count=$((miss_count + 1))
    printf '%s\n' "${miss_count}" > "${MISS_COUNT_FILE}"
    if (( miss_count >= MISS_THRESHOLD )); then
      repair_panel "cosmic-panel missing for ${miss_count} consecutive checks"
    fi
    exit 0
  fi

  printf '0\n' > "${MISS_COUNT_FILE}"
  logs="$(recent_panel_logs "${since_epoch}")"

  if grep -Eq "${ERROR_RE}" <<< "${logs}"; then
    repair_panel "render failure signature in cosmic-panel journal"
  fi
}

install_units() {
  mkdir -p "${BIN_DIR}" "${UNIT_DIR}" "${STATE_DIR}"

  local src
  src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

  if [[ "${src}" != "${INSTALL_PATH}" ]]; then
    install -m 0755 "${src}" "${INSTALL_PATH}"
  else
    chmod 0755 "${INSTALL_PATH}"
  fi

  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=COSMIC panel guardian check

[Service]
Type=oneshot
ExecStart=%h/.local/bin/${APP_NAME} check
Nice=10
NoNewPrivileges=true
EOF

  cat > "${TIMER_PATH}" <<EOF
[Unit]
Description=Run COSMIC panel guardian every ${INTERVAL_SEC} seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=${INTERVAL_SEC}s
AccuracySec=${ACCURACY_SEC}s
Persistent=false
Unit=${APP_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "${APP_NAME}.timer"
  systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true

  echo "Installed ${APP_NAME}"
  echo "Timer: ${TIMER_PATH}"
  echo "Service: ${SERVICE_PATH}"
  echo "State: ${STATE_DIR}"
}

uninstall_units() {
  systemctl --user disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  rm -f "${SERVICE_PATH}" "${TIMER_PATH}"
  systemctl --user daemon-reload
  rm -rf "${STATE_DIR}"
  rm -f "${INSTALL_PATH}"
  echo "Removed ${APP_NAME}"
}

status_cmd() {
  echo "== timer =="
  systemctl --user --no-pager --full status "${APP_NAME}.timer" || true
  echo
  echo "== panel process =="
  pgrep -a cosmic-panel || echo "cosmic-panel not running"
  echo
  echo "== guardian log =="
  tail -n 25 "${LOG_FILE}" 2>/dev/null || echo "no guardian log yet"
}

logs_cmd() {
  echo "== guardian log =="
  tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "no guardian log yet"
  echo
  echo "== recent cosmic-panel journal =="
  journalctl --user -b --no-pager _COMM=cosmic-panel -n 120 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage:
  ${0##*/} install
  ${0##*/} update
  ${0##*/} uninstall
  ${0##*/} check
  ${0##*/} status
  ${0##*/} logs
EOF
}

case "${1:-}" in
  install|update) install_units ;;
  uninstall|remove) uninstall_units ;;
  check) check_once ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "Unknown command: ${1:-}" >&2
    usage >&2
    exit 1
    ;;
esac
