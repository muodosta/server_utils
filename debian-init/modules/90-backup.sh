# shellcheck shell=bash
register_module backup 0 "Бэкапы (restic или borg)" \
    "Скрипт + systemd-таймер, шифрование, ротация снапшотов"

mod_backup_ask() {
    ask_choice CFG_BK_ENGINE "Движок" "restic borg" restic
    ask_cfg    CFG_BK_PATHS  "Что бэкапить (через пробел)" "/etc /root /home /opt /var/www"
    if [[ "$CFG_BK_ENGINE" == restic ]]; then
        log_info "Репозиторий: /mnt/backup | sftp:user@host:/path | s3:https://endpoint/bucket"
        ask_cfg CFG_BK_REPO "Репозиторий restic" "/var/backups/restic"
        ask_cfg CFG_BK_S3_KEY "AWS_ACCESS_KEY_ID (только для s3, иначе пусто)" ""
        [[ -n "$CFG_BK_S3_KEY" ]] && ask_secret CFG_BK_S3_SECRET "AWS_SECRET_ACCESS_KEY"
    else
        log_info "Репозиторий: /var/backups/borg | ssh://user@host:22/~/repo"
        ask_cfg CFG_BK_REPO "Репозиторий borg" "/var/backups/borg"
    fi
    ask_secret CFG_BK_PASS "Пароль шифрования репозитория"
    ask_cfg    CFG_BK_TIME "Время запуска (формат systemd OnCalendar)" "*-*-* 03:30:00"
    ask_cfg    CFG_BK_KEEP "Хранить: дней недель месяцев" "7 4 6"
}

mod_backup_apply() {
    log_step "Бэкапы (${CFG_BK_ENGINE})"
    if [[ -z "$CFG_BK_PASS" ]]; then
        log_warn "Пустой пароль репозитория — модуль пропущен."
        return 0
    fi
    read -r KEEP_D KEEP_W KEEP_M <<<"$CFG_BK_KEEP"

    write_file /etc/server-init/backup.env 0600 <<EOF
BK_REPO='${CFG_BK_REPO}'
BK_PASS='${CFG_BK_PASS}'
BK_PATHS='${CFG_BK_PATHS}'
KEEP_DAILY='${KEEP_D:-7}'
KEEP_WEEKLY='${KEEP_W:-4}'
KEEP_MONTHLY='${KEEP_M:-6}'
AWS_ACCESS_KEY_ID='${CFG_BK_S3_KEY:-}'
AWS_SECRET_ACCESS_KEY='${CFG_BK_S3_SECRET:-}'
EOF

    if [[ "$CFG_BK_ENGINE" == restic ]]; then
        apt_install restic
        write_file /usr/local/sbin/server-backup.sh 0750 <<'EOF'
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
. /etc/server-init/backup.env
export RESTIC_REPOSITORY="$BK_REPO"
export RESTIC_PASSWORD="$BK_PASS"
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

restic snapshots >/dev/null 2>&1 || restic init

# shellcheck disable=SC2086
restic backup $BK_PATHS \
    --exclude-caches \
    --exclude '/var/www/*/cache' \
    --exclude '*.tmp' \
    --tag auto

restic forget --prune \
    --keep-daily   "$KEEP_DAILY" \
    --keep-weekly  "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY"

restic check --read-data-subset=5%
EOF
    else
        apt_install borgbackup
        write_file /usr/local/sbin/server-backup.sh 0750 <<'EOF'
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
. /etc/server-init/backup.env
export BORG_REPO="$BK_REPO"
export BORG_PASSPHRASE="$BK_PASS"

borg list >/dev/null 2>&1 || borg init --encryption=repokey-blake2

# shellcheck disable=SC2086
borg create --stats --compression zstd,3 \
    "::{hostname}-{now:%Y%m%d-%H%M%S}" $BK_PATHS \
    --exclude '*.tmp' --exclude '/var/cache/*'

borg prune \
    --keep-daily   "$KEEP_DAILY" \
    --keep-weekly  "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY"

borg compact
EOF
    fi

    write_file /etc/systemd/system/server-backup.service <<'EOF'
[Unit]
Description=Резервное копирование (debian-init)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/server-backup.sh
EOF

    write_file /etc/systemd/system/server-backup.timer <<EOF
[Unit]
Description=Расписание резервного копирования

[Timer]
OnCalendar=${CFG_BK_TIME}
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    run systemctl daemon-reload
    svc_enable server-backup.timer
    log_ok "бэкап настроен: ${CFG_BK_REPO}, запуск ${CFG_BK_TIME}"
    log_warn "Проверьте восстановление вручную: бэкап без теста восстановления — не бэкап."
    log_info "Первый прогон: systemctl start server-backup.service && journalctl -u server-backup -f"
}

mod_backup_verify() {
    (( DRY_RUN )) && return 0
    systemctl list-timers server-backup.timer --no-pager 2>/dev/null | head -3 | sed 's/^/    /'
}
