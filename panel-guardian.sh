#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cosmic-panel-guardian"
INTERVAL_SEC=2
ACCURACY_SEC=1
COOLDOWN_SEC=45
MISS_THRESHOLD=2

# App-menu repair. Faster than the panel-render cooldown because the app menu
# should recover quickly, while still preventing repeated repair loops.
APP_MENU_COOLDOWN_SEC=8
APP_LIBRARY_MAX_PROCS=6

# Tightened to the exact failure family seen from logs.
ERROR_RE='Failed to render, error: An unknown error \(0\)|eglExportDMABUFImageMESA|eglDupNativeFenceFDANDROID|Erroneous EGL call didn.t set EGLError|EGL_BAD_MATCH|EGL_BAD_PARAMETER'

# Observed COSMIC app-library / launcher wedge signatures.
# Logs alone do not trigger repair; live abnormal state must also be present.
APP_MENU_ERROR_RE='cosmic-session.*Failed to spawn scope for cosmic-(app-library|launcher).*UnitExists|cosmic-launcher.*Failed to activate another instance|cosmic-panel.*com\.system76\.CosmicPanelAppButton: Terminated|systemd.*app-cosmic-com\.system76\.CosmicAppList-.*Failed with result'

# Fatal render/panic signatures seen when the app menu/button fails to reopen.
# These are repair context. They only cause a process restart if live app-menu
# state is also abnormal. If COSMIC already recovered, do not restart it again.
APP_MENU_FATAL_RE='cosmic-session.*(cosmic-app-library exited with error 101|panicked.*cosmic-app-library|wgpu error: Validation Error|Handling wgpu errors as fatal)|cosmic-panel.*com\.system76\.CosmicPanelAppButton:.*(panicked|wgpu error: Validation Error|Handling wgpu errors as fatal|SCTK failed to send Control::AboutToWait)'

# Fresh app-list scope/resource failures seen when COSMIC launches from the app menu.
# These are repair context. A failed transient AppList scope alone is not enough
# to kill a healthy cosmic-app-library process.
APP_MENU_SCOPE_FATAL_RE='app-cosmic-com\.system76\.CosmicAppList-[0-9]+\.scope:.*(PID .* vanished|No PIDs left|Failed with result .resources.|Failed to add PIDs|Failed to start app-cosmic-com\.system76\.CosmicAppList)'

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

  journalctl --user -b --no-pager --since "@${since_epoch}" -o short-iso \
    _COMM=cosmic-session _COMM=cosmic-panel _COMM=cosmic-launcher _COMM=systemd 2>/dev/null \
    | grep -E 'cosmic-app-library|cosmic-launcher|CosmicAppLibrary|CosmicLauncher|CosmicAppList|CosmicPanelAppButton|app-cosmic-com\.system76\.CosmicAppList|UnitExists|Failed to activate another instance|Failed to spawn scope|Failed with result|Terminated|panicked|wgpu error: Validation Error|Handling wgpu errors as fatal|SCTK failed to send Control::AboutToWait|exited with error 101' \
    || true
}

app_library_pids() {
  pgrep -f '(^|/)cosmic-app-library($|[[:space:]])' 2>/dev/null \
    | awk -v self="$$" '$1 ~ /^[0-9]+$/ && $1 != self { print }' \
    || true
}

app_library_count() {
  local count
  count="$(app_library_pids | wc -l | tr -d '[:space:]')"
  printf '%s\n' "${count:-0}"
}

app_menu_related_pids() {
  {
    pgrep -f '(^|/)cosmic-app-library($|[[:space:]])' 2>/dev/null || true
    pgrep -f '(^|/)cosmic-launcher($|[[:space:]])' 2>/dev/null || true
    pgrep -f '(^|/)pop-launcher($|[[:space:]])' 2>/dev/null || true
    pgrep -f '(^|/)(ba)?sh[[:space:]]+-c[[:space:]]+cosmic-app-library($|[[:space:]])' 2>/dev/null || true
    pgrep -f '^/usr/lib/pop-launcher/plugins/cosmic_toplevel/cosmic-toplevel($|[[:space:]])' 2>/dev/null || true
    pgrep -f '^/usr/lib/pop-launcher/plugins/pop_shell/pop-shell($|[[:space:]])' 2>/dev/null || true
  } | awk -v self="$$" '$1 ~ /^[0-9]+$/ && $1 != self { print }' | sort -n -u
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
  
  if [[ ! "${pid}" =~ ^[0-9]+$ || ! -d "/proc/${pid}" ]]; then
    printf '%s\n' "stale"
    return
  fi
  
  if [[ "${proc}" != cosmic-app-libr* && "${proc}" != cosmic-app-library* ]]; then
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

  sleep 0.3

  # Terminate only the app-menu / launcher layer.
  related="$(app_menu_related_pids)"
  if [[ -n "${related}" ]]; then
    kill_pid_list TERM <<< "${related}"
  fi

  sleep 1

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
  local app_count owner_status logs reason journal_hit fatal_hit scope_hit abnormal_state

  reason=""
  journal_hit=0
  fatal_hit=0
  scope_hit=0
  abnormal_state=0

  app_count="$(app_library_count)"
  owner_status="$(app_library_owner_status)"
  logs="$(recent_app_menu_logs "${since_epoch}")"

  # Live-state checks are the only things that should force a process restart.
  if [[ "${owner_status}" != "ok" ]]; then
    abnormal_state=1
    reason+="CosmicAppLibrary DBus owner ${owner_status}; "
  fi

  if (( app_count > APP_LIBRARY_MAX_PROCS )); then
    abnormal_state=1
    reason+="cosmic-app-library process count ${app_count} > ${APP_LIBRARY_MAX_PROCS}; "
  fi

  # Journal signatures are context. They explain why a repair is needed if the
  # live state is bad, but they should not kill a recovered app-library by themselves.
  if grep -Eq "${APP_MENU_FATAL_RE}" <<< "${logs}"; then
    fatal_hit=1
    reason+="fresh app-menu wgpu/panic failure in journal; "
  fi

  if grep -Eq "${APP_MENU_SCOPE_FATAL_RE}" <<< "${logs}"; then
    scope_hit=1
    reason+="fresh CosmicAppList scope/resource failure in journal; "
  fi

  if grep -Eq "${APP_MENU_ERROR_RE}" <<< "${logs}"; then
    journal_hit=1
    reason+="matching app-menu journal signature present; "
  fi

  # Fast recovered path:
  # If COSMIC already respawned app-library and DBus is healthy, do not restart it.
  # Reset failed transient scope state only, then leave the user's next click alone.
  if (( abnormal_state == 0 )); then
    if (( fatal_hit == 1 || scope_hit == 1 || journal_hit == 1 )); then
      systemctl --user reset-failed \
        cosmic-app-library.scope \
        cosmic-launcher.scope \
        'app-cosmic-com.system76.CosmicAppList-*.scope' \
        >/dev/null 2>&1 || true

      log "app-menu event observed but live state is healthy; no process restart (${reason})"
    fi

    return 0
  fi

  repair_app_menu "${reason}"
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
