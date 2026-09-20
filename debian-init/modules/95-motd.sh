# shellcheck shell=bash
register_module motd 0 "Информационный MOTD" \
    "Сводка при входе: нагрузка, память, диск, обновления, последние входы"

mod_motd_ask() { :; }

mod_motd_apply() {
    log_step "MOTD"
    if ! (( DRY_RUN )); then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
        : >/etc/motd
    fi

    write_file /etc/update-motd.d/20-server-init 0755 <<'EOF'
#!/bin/bash
printf '\n\033[1m %s\033[0m — %s\n' "$(hostname -f 2>/dev/null || hostname)" "$(. /etc/os-release; echo "$PRETTY_NAME")"
printf ' Uptime  : %s\n' "$(uptime -p 2>/dev/null)"
printf ' Load    : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
printf ' Memory  : %s\n' "$(free -h | awk '/Mem:/{print $3" / "$2}')"
printf ' Disk /  : %s\n' "$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
if command -v apt-get >/dev/null; then
    U=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst' || true)
    [ "${U:-0}" -gt 0 ] && printf ' Updates : \033[33m%s пакетов\033[0m\n' "$U"
fi
printf ' Last    : %s\n\n' "$(last -n 2 -w 2>/dev/null | head -2 | tail -1 | cut -c1-70)"
EOF
    log_ok "MOTD обновлён"
}
