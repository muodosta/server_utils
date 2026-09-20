# shellcheck shell=bash
register_module ssh 1 "Хардненинг SSH" \
    "drop-in 99-hardening.conf, смена порта, запрет пароля, авто-откат при потере доступа"

mod_ssh_ask() {
    ask_cfg    CFG_SSH_PORT "SSH-порт" "$(current_ssh_port)"
    valid_port "$CFG_SSH_PORT" || die "Некорректный порт: $CFG_SSH_PORT"
    ask_yn     CFG_SSH_NOPASS "Запретить вход по паролю (только ключи)?" y
    ask_choice CFG_SSH_ROOT   "Вход для root" "no prohibit-password yes" no
    ask_cfg    CFG_SSH_ALLOWUSERS "AllowUsers через пробел (пусто = не ограничивать)" "${CFG_USER_NAME:-}"
    ask_cfg    CFG_SSH_ROLLBACK "Секунд до авто-отката, если вы не подтвердите вход" "300"
}

mod_ssh_apply() {
    log_step "Хардненинг SSH"
    apt_install openssh-server

    # Проверка на «выстрел в ногу»: запрет пароля без ключей = потеря сервера.
    if (( CFG_SSH_NOPASS )) && [[ "${SSH_KEY_MISSING:-0}" == 1 ]]; then
        log_err "Запрет пароля запрошен, но у пользователя нет SSH-ключей."
        if ! (( ASSUME_YES )) && ! confirm_word "ПОНИМАЮ" "Продолжить всё равно?"; then
            log_warn "Оставляю вход по паролю включённым."
            CFG_SSH_NOPASS=0
        fi
    fi

    local allow_line=""
    [[ -n "$CFG_SSH_ALLOWUSERS" ]] && allow_line="AllowUsers ${CFG_SSH_ALLOWUSERS}"

    # Именно drop-in: в Debian 12+ основной sshd_config содержит Include
    # /etc/ssh/sshd_config.d/*.conf, и наши правки переживут обновление пакета.
    write_file /etc/ssh/sshd_config.d/99-hardening.conf 0600 <<EOF
# Сгенерировано debian-init
Port ${CFG_SSH_PORT}
Protocol 2
AddressFamily any

PermitRootLogin ${CFG_SSH_ROOT}
PubkeyAuthentication yes
PasswordAuthentication $( ((CFG_SSH_NOPASS)) && echo no || echo yes )
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes
${allow_line}

MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
PermitTunnel no
PrintMotd no

# Только современные алгоритмы
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

    # Debian 13 (trixie): sshd запускается через socket-активацию, и директива
    # Port в конфиге игнорируется — порт слушает ssh.socket. Без этого блока
    # смена порта «молча не сработает».
    local socket_mode=0
    if ssh_socket_activated; then
        socket_mode=1
        log_info "обнаружена socket-активация (ssh.socket) — задаю порт там"
        write_file /etc/systemd/system/ssh.socket.d/99-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=${CFG_SSH_PORT}
EOF
        run systemctl daemon-reload
    fi

    if ! (( DRY_RUN )); then
        sshd -t || die "sshd -t не прошёл — конфиг НЕ применён, SSH не тронут."
    fi

    # Страховка: таймер, который через N секунд вернёт всё как было.
    # Отменяется только после того, как вы подтвердите успешный вход в новом окне.
    local rollback_enabled=0
    if ! (( DRY_RUN )) && ! (( ASSUME_YES )); then
        cat >/usr/local/sbin/ssh-rollback.sh <<'ROLLBACK'
#!/bin/bash
# Аварийный откат хардненинга SSH (запускается таймером systemd).
rm -f /etc/ssh/sshd_config.d/99-hardening.conf
rm -f /etc/systemd/system/ssh.socket.d/99-port.conf
systemctl daemon-reload
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
logger -t server-init "SSH hardening rolled back automatically"
ROLLBACK
        chmod 700 /usr/local/sbin/ssh-rollback.sh
        systemctl stop ssh-rollback.timer 2>/dev/null || true
        systemd-run --unit=ssh-rollback --on-active="${CFG_SSH_ROLLBACK}" \
            /usr/local/sbin/ssh-rollback.sh >/dev/null 2>&1 && rollback_enabled=1
        (( rollback_enabled )) && log_info "авто-откат вооружён на ${CFG_SSH_ROLLBACK} сек"
    elif (( ASSUME_YES )); then
        log_warn "Неинтерактивный режим: авто-откат не вооружён, проверьте доступ вручную."
    fi

    if (( socket_mode )); then
        run systemctl restart ssh.socket
    fi
    run systemctl restart ssh 2>/dev/null || run systemctl restart sshd

    if (( rollback_enabled )); then
        local ip; ip=$(wan_ip)
        echo
        log_warn "НЕ ЗАКРЫВАЙТЕ эту сессию."
        echo "    Откройте НОВОЕ окно терминала и проверьте вход:"
        echo "        ssh -p ${CFG_SSH_PORT} ${CFG_SSH_ALLOWUSERS:-${CFG_USER_NAME:-root}}@${ip}"
        if confirm_word "OK" "Вход работает?"; then
            systemctl stop ssh-rollback.timer 2>/dev/null || true
            rm -f /usr/local/sbin/ssh-rollback.sh
            log_ok "Авто-откат отменён, настройки SSH зафиксированы."
        else
            log_warn "Выполняю откат немедленно."
            systemctl stop ssh-rollback.timer 2>/dev/null || true
            /usr/local/sbin/ssh-rollback.sh
            rm -f /usr/local/sbin/ssh-rollback.sh
            die "SSH возвращён к исходной конфигурации. Разберитесь с доступом и запустите скрипт заново."
        fi
    fi

    log_ok "SSH настроен на порт ${CFG_SSH_PORT}"
}

mod_ssh_verify() {
    (( DRY_RUN )) && return 0
    log_info "слушает: $(ss -tlnp 2>/dev/null | grep -E "sshd|ssh.socket|:${CFG_SSH_PORT}\b" | head -3 | tr '\n' ' ')"
    log_info "PasswordAuthentication: $(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
}
