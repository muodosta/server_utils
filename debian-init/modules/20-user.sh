# shellcheck shell=bash
register_module user 1 "Пользователь с sudo и SSH-ключом" \
    "Создание не-root пользователя, установка публичного ключа, права sudo"

mod_user_ask() {
    ask_cfg CFG_USER_NAME "Имя пользователя" "admin"
    if [[ ! $CFG_USER_NAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        die "Недопустимое имя пользователя: $CFG_USER_NAME"
    fi
    ask_cfg CFG_USER_KEY "Публичный SSH-ключ (пусто = скопировать ключи root)" ""
    if [[ -n "$CFG_USER_KEY" && ! $CFG_USER_KEY =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2|sk-) ]]; then
        die "Это не похоже на публичный ключ: ${CFG_USER_KEY:0:30}..."
    fi
    ask_yn  CFG_USER_SETPASS  "Задать пароль пользователю (нужен для sudo)?" y
    if (( CFG_USER_SETPASS )) && [[ -z "${CFG_USER_PASS:-}" ]]; then
        local p1 p2
        while true; do
            ask_secret p1 "Пароль для $CFG_USER_NAME"
            ask_secret p2 "Повторите пароль"
            [[ "$p1" == "$p2" && -n "$p1" ]] && { CFG_USER_PASS="$p1"; break; }
            log_warn "Пароли не совпадают или пусты, повторите."
        done
    fi
    ask_yn CFG_USER_NOPASSWD "Разрешить sudo без пароля (NOPASSWD)?" n
}

mod_user_apply() {
    log_step "Пользователь ${CFG_USER_NAME}"

    if id -u "$CFG_USER_NAME" >/dev/null 2>&1; then
        log_info "пользователь уже существует"
    else
        run useradd -m -s /bin/bash "$CFG_USER_NAME"
        log_ok "пользователь создан"
    fi
    run usermod -aG sudo "$CFG_USER_NAME"

    if (( CFG_USER_SETPASS )) && [[ -n "${CFG_USER_PASS:-}" ]] && ! (( DRY_RUN )); then
        printf '%s:%s\n' "$CFG_USER_NAME" "$CFG_USER_PASS" | chpasswd
        log_info "пароль установлен"
    fi

    # SSH-ключи. Это единственный способ войти после хардненинга SSH,
    # поэтому здесь же жёстко проверяем, что ключ вообще есть.
    local home="/home/$CFG_USER_NAME" akf
    akf="$home/.ssh/authorized_keys"
    if ! (( DRY_RUN )); then
        mkdir -p "$home/.ssh"
        if [[ -n "$CFG_USER_KEY" ]]; then
            grep -qxF -- "$CFG_USER_KEY" "$akf" 2>/dev/null || printf '%s\n' "$CFG_USER_KEY" >>"$akf"
            log_ok "публичный ключ добавлен"
        elif [[ -s /root/.ssh/authorized_keys ]]; then
            cat /root/.ssh/authorized_keys >>"$akf"
            sort -u "$akf" -o "$akf"
            log_ok "ключи скопированы от root"
        fi
        touch "$akf"
        chmod 700 "$home/.ssh"; chmod 600 "$akf"
        chown -R "$CFG_USER_NAME:$CFG_USER_NAME" "$home/.ssh"

        if [[ ! -s "$akf" ]]; then
            log_warn "У $CFG_USER_NAME НЕТ ни одного SSH-ключа!"
            log_warn "Если дальше отключить вход по паролю — доступ к серверу будет потерян."
            SSH_KEY_MISSING=1
        fi
    fi

    if (( CFG_USER_NOPASSWD )); then
        write_file "/etc/sudoers.d/90-${CFG_USER_NAME}" 0440 <<EOF
${CFG_USER_NAME} ALL=(ALL) NOPASSWD:ALL
EOF
        if ! (( DRY_RUN )) && ! visudo -cf "/etc/sudoers.d/90-${CFG_USER_NAME}" >/dev/null; then
            rm -f "/etc/sudoers.d/90-${CFG_USER_NAME}"
            die "Некорректный sudoers-файл, откатил."
        fi
    fi

    # Таймаут sudo и безопасный PATH.
    write_file /etc/sudoers.d/10-server-init 0440 <<'EOF'
Defaults        timestamp_timeout=15
Defaults        passwd_tries=3
Defaults        logfile="/var/log/sudo.log"
EOF
    if ! (( DRY_RUN )) && ! visudo -cf /etc/sudoers.d/10-server-init >/dev/null; then
        rm -f /etc/sudoers.d/10-server-init
        log_warn "sudoers-дефолты не применены (ошибка синтаксиса)"
    fi

    log_ok "Пользователь настроен"
}

mod_user_verify() {
    (( DRY_RUN )) && return 0
    log_info "группы: $(id -nG "$CFG_USER_NAME" 2>/dev/null)"
    log_info "ключей в authorized_keys: $(grep -c '^ssh\|^ecdsa\|^sk-' "/home/$CFG_USER_NAME/.ssh/authorized_keys" 2>/dev/null || echo 0)"
}
