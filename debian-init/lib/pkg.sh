# shellcheck shell=bash
# Работа с apt. DEBIAN_FRONTEND=noninteractive + --force-confold, чтобы apt
# никогда не остановился на интерактивном диалоге посреди работы скрипта.

export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

apt_update() {
    (( APT_UPDATED )) && return 0
    log_info "apt-get update"
    run apt-get update -qq
    APT_UPDATED=1
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

apt_install() {
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    (( ${#missing[@]} )) || { log_info "уже установлено: $*"; return 0; }
    apt_update
    log_info "установка: ${missing[*]}"
    run apt-get install "${APT_OPTS[@]}" -qq "${missing[@]}"
}

apt_purge() {
    local p present=()
    for p in "$@"; do pkg_installed "$p" && present+=("$p"); done
    (( ${#present[@]} )) || return 0
    log_info "удаление: ${present[*]}"
    run apt-get purge "${APT_OPTS[@]}" -qq "${present[@]}"
}

svc_enable() {
    run systemctl enable --now "$1" >/dev/null 2>&1 || log_warn "не удалось включить $1"
}

svc_restart() {
    run systemctl restart "$1" || log_warn "не удалось перезапустить $1"
}
