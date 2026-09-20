# shellcheck shell=bash
# Логирование: в консоль (с цветом) и в файл одновременно.

LOG_FILE="${LOG_FILE:-/var/log/server-init.log}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_OFF=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
    C_OFF=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

_log_file() {
    # Пишем в файл только если можем (при --dry-run от не-root файла может не быть)
    [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]] 2>/dev/null || return 0
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" >>"$LOG_FILE" 2>/dev/null || true
}

log_step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_CYN" "$*" "$C_OFF"; _log_file STEP "$*"; }
log_info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; _log_file INFO "$*"; }
log_ok()   { printf '    %s✔%s %s\n' "$C_GRN" "$C_OFF" "$*"; _log_file OK "$*"; }
log_warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; _log_file WARN "$*"; }
log_err()  { printf '    %s✖%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; _log_file ERROR "$*"; }
die()      { log_err "$*"; exit 1; }
