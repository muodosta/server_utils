# shellcheck shell=bash
register_module f2b 1 "Защита от брутфорса (fail2ban или CrowdSec)" \
    "Бан по количеству неудачных попыток, whitelist своих адресов"

mod_f2b_ask() {
    ask_choice CFG_F2B_ENGINE "Движок" "fail2ban crowdsec" fail2ban
    if [[ "$CFG_F2B_ENGINE" == fail2ban ]]; then
        ask_cfg CFG_F2B_BANTIME  "Время бана" "1h"
        ask_cfg CFG_F2B_MAXRETRY "Попыток до бана" "5"
        ask_cfg CFG_F2B_IGNORE   "Адреса-исключения через пробел" "${CFG_FW_SSH_ALLOW:-}"
    fi
}

_f2b_apply_fail2ban() {
    # python3-systemd нужен для backend=systemd: в Debian 12+ логи sshd
    # лежат только в журнале, файла /var/log/auth.log может не быть вовсе.
    apt_install fail2ban python3-systemd

    local banaction="nftables-multiport"
    [[ "${CFG_FW_BACKEND:-nftables}" == ufw ]] && banaction="ufw"

    write_file /etc/fail2ban/jail.local <<EOF
# Сгенерировано debian-init
[DEFAULT]
backend    = systemd
bantime    = ${CFG_F2B_BANTIME}
findtime   = 10m
maxretry   = ${CFG_F2B_MAXRETRY}
ignoreip   = 127.0.0.1/8 ::1 ${CFG_F2B_IGNORE}
banaction  = ${banaction}
banaction_allports = ${banaction}[type=allports]

# Рецидивистов баним надолго
[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 5

[sshd]
enabled  = true
port     = ${CFG_SSH_PORT:-22}
mode     = aggressive
EOF

    svc_enable fail2ban
    run systemctl restart fail2ban
    log_ok "fail2ban настроен (banaction=${banaction})"
}

_f2b_apply_crowdsec() {
    if ! pkg_installed crowdsec; then
        log_info "подключаю репозиторий CrowdSec"
        run bash -c 'curl -fsSL https://install.crowdsec.net | bash' \
            || die "Не удалось подключить репозиторий CrowdSec (нет сети?)"
        apt_update
    fi
    apt_install crowdsec
    if [[ "${CFG_FW_BACKEND:-nftables}" == ufw ]]; then
        apt_install crowdsec-firewall-bouncer-iptables
    else
        apt_install crowdsec-firewall-bouncer-nftables
    fi
    svc_enable crowdsec
    log_ok "CrowdSec установлен (cscli metrics / cscli decisions list)"
}

mod_f2b_apply() {
    log_step "Защита от брутфорса (${CFG_F2B_ENGINE})"
    case "$CFG_F2B_ENGINE" in
        fail2ban) _f2b_apply_fail2ban ;;
        crowdsec) _f2b_apply_crowdsec ;;
    esac
}

mod_f2b_verify() {
    (( DRY_RUN )) && return 0
    if [[ "$CFG_F2B_ENGINE" == fail2ban ]]; then
        fail2ban-client status 2>/dev/null | sed 's/^/    /' || log_warn "fail2ban не отвечает"
    else
        cscli metrics 2>/dev/null | head -12 | sed 's/^/    /' || true
    fi
}
