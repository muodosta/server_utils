# shellcheck shell=bash
register_module telegram 0 "Telegram-алерты о входах по SSH" \
    "PAM-хук: уведомление в Telegram при каждом успешном входе"

mod_telegram_ask() {
    ask_secret CFG_TG_TOKEN "Telegram bot token (от @BotFather)"
    ask_cfg    CFG_TG_CHAT  "Chat ID (свой ID или -100... для группы)" ""
    ask_yn     CFG_TG_SUDO  "Уведомлять также о sudo-командах?" n
}

mod_telegram_apply() {
    log_step "Telegram-алерты"
    if [[ -z "$CFG_TG_TOKEN" || -z "$CFG_TG_CHAT" ]]; then
        log_warn "Не задан токен или chat_id — модуль пропущен."
        return 0
    fi
    apt_install curl libpam-modules

    write_file /etc/server-init/telegram.env 0600 <<EOF
TG_BOT_TOKEN='${CFG_TG_TOKEN}'
TG_CHAT_ID='${CFG_TG_CHAT}'
EOF

    write_file /usr/local/sbin/ssh-telegram-notify.sh 0750 <<'EOF'
#!/bin/bash
# Вызывается pam_exec при открытии сессии sshd.
[ "$PAM_TYPE" = "open_session" ] || exit 0
[ -r /etc/server-init/telegram.env ] || exit 0
# shellcheck disable=SC1091
. /etc/server-init/telegram.env

HOST="$(hostname -f 2>/dev/null || hostname)"
MSG="🔐 SSH-вход
Сервер: ${HOST}
Пользователь: ${PAM_USER}
IP: ${PAM_RHOST:-локально}
Время: $(date '+%F %T %Z')"

# В фоне и с таймаутом: недоступный Telegram не должен тормозить логин.
( curl -sS -m 10 -X POST \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${MSG}" >/dev/null 2>&1 & ) &
exit 0
EOF

    ensure_line /etc/pam.d/sshd "session optional pam_exec.so quiet /usr/local/sbin/ssh-telegram-notify.sh"

    if (( CFG_TG_SUDO )); then
        ensure_line /etc/sudoers.d/99-telegram-log "Defaults log_output"
        log_info "sudo-логирование включено (sudoreplay -l)"
    fi

    if ! (( DRY_RUN )); then
        if curl -sS -m 10 -X POST "https://api.telegram.org/bot${CFG_TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${CFG_TG_CHAT}" \
            --data-urlencode "text=✅ debian-init: уведомления с $(hostname) подключены" \
            | grep -q '"ok":true'; then
            log_ok "тестовое сообщение доставлено"
        else
            log_warn "Telegram не принял сообщение — проверьте токен и chat_id."
        fi
    fi
}
