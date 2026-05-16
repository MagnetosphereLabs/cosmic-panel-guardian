#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cosmic-panel-guardian"
INTERVAL_SEC=15
ACCURACY_SEC=5
COOLDOWN_SEC=45
MISS_THRESHOLD=2

# App-menu repair lane. Conservative threshold so normal open/close behavior is left alone.
APP_MENU_COOLDOWN_SEC=45
APP_LIBRARY_MAX_PROCS=6

# Tightened to the exact failure family seen from logs.
ERROR_RE='Failed to render, error: An unknown error \(0\)|eglExportDMABUFImageMESA|eglDupNativeFenceFDANDROID|Erroneous EGL call didn.t set EGLError|EGL_BAD_MATCH|EGL_BAD_PARAMETER'

# Observed COSMIC app-library / launcher wedge signatures.
# Logs alone do not trigger repair; live abnormal state must also be present.
APP_MENU_ERROR_RE='cosmic-session.*Failed to spawn scope for cosmic-(app-library|launcher).*UnitExists|cosmic-launcher.*Failed to activate another instance|cosmic-panel.*com\.system76\.CosmicPanelAppButton: Terminated|systemd.*app-cosmic-com\.system76\.CosmicAppList-.*Failed with result'

APPS_DIR="${HOME}/Apps"
INSTALL_DIR="${APPS_DIR}/${APP_NAME}"
INSTALL_PATH="${INSTALL_DIR}/panel-guardian.sh"
RAW_URL="https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh"

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_PATH="${UNIT_DIR}/${APP_NAME}.service"
TIMER_PATH="${UNIT_DIR}/${APP_NAME}.timer"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
LOG_FILE="${STATE_DIR}/guardian.log"
LAST_CHECK_FILE="${STATE_DIR}/last_check"
LAST_RESTART_FILE="${STATE_DIR}/last_restart"
MISS_COUNT_FILE="${STATE_DIR}/miss_count"
LOCK_FILE="${STATE_DIR}/check.lock"
LAST_APP_MENU_REPAIR_FILE="${STATE_DIR}/last_app_menu_repair"

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

recent_app_menu_logs() {
  local since_epoch="$1"
  journalctl --user -b --no-pager --since "@${since_epoch}" -o short-iso 2>/dev/null \
    | grep -E 'cosmic-session|cosmic-launcher|cosmic-app-library|cosmic-panel|CosmicAppLibrary|CosmicLauncher|CosmicAppList|app-cosmic-com\.system76\.CosmicAppList|UnitExists|Failed to activate another instance' \
    || true
}

proc_cmdline() {
  local pid="$1"
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/${pid}/cmdline" | sed 's/[[:space:]]*$//'
}

app_library_pids() {
  local proc pid cmd first base

  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    cmd="$(proc_cmdline "${pid}" 2>/dev/null || true)"
    [[ -z "${cmd}" ]] && continue

    first="${cmd%% *}"
    base="${first##*/}"

    if [[ "${base}" == "cosmic-app-library" ]]; then
      printf '%s\n' "${pid}"
    fi
  done
}

app_library_count() {
  app_library_pids | awk 'END { print NR + 0 }'
}

app_menu_related_pids() {
  local proc pid cmd first base matched

  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"

    # Never signal the guardian itself.
    [[ "${pid}" == "$$" ]] && continue

    cmd="$(proc_cmdline "${pid}" 2>/dev/null || true)"
    [[ -z "${cmd}" ]] && continue

    first="${cmd%% *}"
    base="${first##*/}"
    matched=0

    case "${base}" in
      cosmic-app-library|cosmic-launcher|pop-launcher)
        matched=1
        ;;
    esac

    # Shell wrappers observed in the broken state:
    #   sh -c cosmic-app-library
    #   /bin/sh -c cosmic-app-library
    if [[ "${cmd}" =~ ^(/bin/)?sh[[:space:]]+-c[[:space:]]+cosmic-app-library($|[[:space:]]) ]]; then
      matched=1
    fi

    # pop-launcher plugin children observed with cosmic-launcher.
    if [[ "${cmd}" == /usr/lib/pop-launcher/plugins/cosmic_toplevel/cosmic-toplevel* ]]; then
      matched=1
    fi

    if [[ "${cmd}" == /usr/lib/pop-launcher/plugins/pop_shell/pop-shell* ]]; then
      matched=1
    fi

    if (( matched == 1 )); then
      printf '%s\n' "${pid}"
    fi
  done | sort -n -u
}

app_library_owner_line() {
  busctl --user list 2>/dev/null \
    | awk '$1 == "com.system76.CosmicAppLibrary" { print; exit }' \
    || true
}

app_library_owner_status() {
  local line name pid proc user rest

  line="$(app_library_owner_line)"
  if [[ -z "${line}" ]]; then
    printf '%s\n' "missing"
    return
  fi

  read -r name pid proc user rest <<< "${line}"

  if [[ -z "${pid:-}" || "${pid}" == "-" || -z "${proc:-}" || "${proc}" == "n/a" || "${proc}" == "-" ]]; then
    printf '%s\n' "stale"
    return
  fi

  printf '%s\n' "ok"
}

kill_pid_list() {
  local signal="$1"
  local pid

  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    [[ "${pid}" == "$$" ]] && continue
    kill "-${signal}" "${pid}" 2>/dev/null || true
  done
}

repair_app_menu() {
  local reason="$1"
  local now last_repair before_count after_count owner_before owner_after related

  now="$(date +%s)"
  last_repair="$(read_num "${LAST_APP_MENU_REPAIR_FILE}" 0)"

  if (( now - last_repair < APP_MENU_COOLDOWN_SEC )); then
    log "app-menu cooldown active; skipped repair (${reason})"
    return 0
  fi

  printf '%s\n' "${now}" > "${LAST_APP_MENU_REPAIR_FILE}"

  before_count="$(app_library_count)"
  owner_before="$(app_library_owner_line)"

  log "app-menu repair triggered: ${reason}; before_count=${before_count}; owner=${owner_before:-none}"

  # Clean only the scopes involved in the proven app-library / launcher wedge.
  systemctl --user stop cosmic-app-library.scope cosmic-launcher.scope >/dev/null 2>&1 || true
  systemctl --user reset-failed cosmic-app-library.scope cosmic-launcher.scope >/dev/null 2>&1 || true

  sleep 1

  # Terminate only the app-menu / launcher layer.
  related="$(app_menu_related_pids)"
  if [[ -n "${related}" ]]; then
    kill_pid_list TERM <<< "${related}"
  fi

  sleep 3

  after_count="$(app_library_count)"

  # Escalate only if graceful TERM did not clear the abnormal pile-up.
  if (( after_count > APP_LIBRARY_MAX_PROCS )); then
    log "app-menu repair escalating: ${after_count} cosmic-app-library processes remain after TERM"
    related="$(app_menu_related_pids)"
    if [[ -n "${related}" ]]; then
      kill_pid_list KILL <<< "${related}"
    fi
    sleep 2
  fi

  systemctl --user reset-failed cosmic-app-library.scope cosmic-launcher.scope >/dev/null 2>&1 || true

  after_count="$(app_library_count)"
  owner_after="$(app_library_owner_line)"

  log "app-menu repair complete: after_count=${after_count}; owner=${owner_after:-none}"
}

check_app_menu() {
  local since_epoch="$1"
  local app_count owner_status logs reason journal_hit abnormal_state

  reason=""
  journal_hit=0
  abnormal_state=0

  app_count="$(app_library_count)"
  owner_status="$(app_library_owner_status)"
  logs="$(recent_app_menu_logs "${since_epoch}")"

  if [[ "${owner_status}" != "ok" ]]; then
    abnormal_state=1
    reason+="CosmicAppLibrary DBus owner ${owner_status}; "
  fi

  if (( app_count > APP_LIBRARY_MAX_PROCS )); then
    abnormal_state=1
    reason+="cosmic-app-library process count ${app_count} > ${APP_LIBRARY_MAX_PROCS}; "
  fi

  if grep -Eq "${APP_MENU_ERROR_RE}" <<< "${logs}"; then
    journal_hit=1
  fi

  # Safety rule:
  # Journal lines alone do not repair. Live state must also be abnormal.
  # This prevents closing a healthy Applications menu during normal use.
  if (( abnormal_state == 1 )); then
    if (( journal_hit == 1 )); then
      reason+="matching app-menu journal signature present; "
    fi
    repair_app_menu "${reason}"
  fi
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
    return 0
  fi

  check_app_menu "${since_epoch}"
}

install_units() {
  mkdir -p "${INSTALL_DIR}" "${UNIT_DIR}" "${STATE_DIR}"

  local src tmp
  src="${BASH_SOURCE[0]-}"

  if [[ -n "${src}" && -f "${src}" ]]; then
    install -m 0755 "${src}" "${INSTALL_PATH}"
  else
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required for install/update" >&2
      exit 1
    fi

    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"' RETURN
    curl -fsSL "${RAW_URL}" -o "${tmp}"
    install -m 0755 "${tmp}" "${INSTALL_PATH}"
    trap - RETURN
    rm -f "${tmp}"
  fi

  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=COSMIC panel guardian check

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} check
Nice=19
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
  echo "Command: ${INSTALL_PATH}"
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
  rmdir "${INSTALL_DIR}" 2>/dev/null || true
  rmdir "${APPS_DIR}" 2>/dev/null || true
  echo "Removed ${APP_NAME}"
}

status_cmd() {
  echo "== timer =="
  systemctl --user --no-pager --full status "${APP_NAME}.timer" || true
  echo

  echo "== panel process =="
  pgrep -a cosmic-panel || echo "cosmic-panel not running"
  echo

  echo "== app menu state =="
  echo "cosmic-app-library count: $(app_library_count)"
  echo "CosmicAppLibrary owner:"
  app_library_owner_line || true
  echo

  echo "== launcher/app-library processes =="
  pgrep -af 'cosmic-launcher|cosmic-app-library|pop-launcher|cosmic-panel-button' | head -n 120 || true
  echo

  echo "== guardian log =="
  tail -n 40 "${LOG_FILE}" 2>/dev/null || echo "no guardian log yet"
}

logs_cmd() {
  local since_epoch
  since_epoch="$(( $(date +%s) - 1200 ))"

  echo "== guardian log =="
  tail -n 80 "${LOG_FILE}" 2>/dev/null || echo "no guardian log yet"
  echo

  echo "== recent cosmic-panel journal =="
  journalctl --user -b --no-pager _COMM=cosmic-panel -n 120 2>/dev/null || true
  echo

  echo "== recent app-menu journal =="
  recent_app_menu_logs "${since_epoch}" | tail -n 160 || true
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
