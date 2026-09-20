# shellcheck shell=bash
register_module base 1 "Базовая настройка системы" \
    "Обновление пакетов, базовые утилиты, hostname, часовой пояс, локали, лимит журнала systemd"

mod_base_ask() {
    ask_cfg  CFG_HOSTNAME  "Hostname сервера" "$(hostname -s)"
    ask_cfg  CFG_TIMEZONE  "Часовой пояс (UTC / Europe/Moscow / Asia/Barnaul)" "UTC"
    ask_yn   CFG_BASE_UPGRADE "Выполнить полное обновление пакетов (apt upgrade)?" y
    ask_cfg  CFG_JOURNAL_MAX  "Лимит журнала systemd на диске" "500M"
    ask_yn   CFG_BASE_PURGE "Удалить ненужное на VPS (exim4, rpcbind, nfs-common)?" y
}

mod_base_apply() {
    log_step "Базовая настройка системы"

    # needrestart в автоматический режим — иначе apt при обновлении библиотек
    # покажет псевдографический диалог и скрипт зависнет.
    if pkg_installed needrestart; then
        write_file /etc/needrestart/conf.d/99-server-init.conf <<'EOF'
# Автоматически перезапускать сервисы после обновления библиотек, без вопросов.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF
    fi

    apt_update
    if (( CFG_BASE_UPGRADE )); then
        log_info "apt upgrade (может занять несколько минут)"
        run apt-get upgrade "${APT_OPTS[@]}" -qq
    fi

    apt_install ca-certificates curl wget git jq gnupg lsb-release apt-transport-https \
                htop ncdu tmux rsync unzip zip dnsutils lsof tree file \
                bash-completion vim nano sudo iproute2 net-tools

    # Hostname + /etc/hosts: без корректной записи sudo и почта тормозят на резолве.
    if [[ -n "$CFG_HOSTNAME" && "$CFG_HOSTNAME" != "$(hostname -s)" ]]; then
        run hostnamectl set-hostname "$CFG_HOSTNAME"
    fi
    ensure_line /etc/hosts "127.0.1.1	${CFG_HOSTNAME}"

    # Часовой пояс и синхронизация времени.
    run timedatectl set-timezone "$CFG_TIMEZONE" || log_warn "часовой пояс $CFG_TIMEZONE не найден"
    if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        svc_enable systemd-timesyncd
        run timedatectl set-ntp true || true
    fi

    # Локали: ru_RU нужна, чтобы psql/файлы с кириллицей не превращались в вопросы.
    apt_install locales
    if [[ -f /etc/locale.gen ]] && ! (( DRY_RUN )); then
        backup_file /etc/locale.gen
        sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/; s/^# *\(ru_RU\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
        locale-gen >/dev/null
    fi
    run update-locale LANG=en_US.UTF-8 LC_MESSAGES=POSIX

    # Журнал systemd: на VPS с диском 20–40 ГБ дефолтные 10% быстро становятся проблемой.
    write_file /etc/systemd/journald.conf.d/99-server-init.conf <<EOF
[Journal]
Storage=persistent
SystemMaxUse=${CFG_JOURNAL_MAX}
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF
    svc_restart systemd-journald

    if (( CFG_BASE_PURGE )); then
        apt_purge exim4-base exim4-config exim4-daemon-light rpcbind nfs-common
        run apt-get autoremove "${APT_OPTS[@]}" -qq
    fi

    log_ok "Базовая настройка завершена"
}

mod_base_verify() {
    log_info "Время: $(date '+%F %T %Z'), hostname: $(hostname -f 2>/dev/null || hostname)"
    log_info "Журнал занимает: $(journalctl --disk-usage 2>/dev/null | tail -1)"
}
