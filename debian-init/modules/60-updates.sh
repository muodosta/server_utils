# shellcheck shell=bash
register_module updates 1 "Автообновления безопасности" \
    "unattended-upgrades только для security-репозитория, с логом и опциональной перезагрузкой"

mod_updates_ask() {
    ask_yn  CFG_UPD_REBOOT "Разрешить автоматическую перезагрузку при обновлении ядра?" n
    (( CFG_UPD_REBOOT )) && ask_cfg CFG_UPD_REBOOT_TIME "Время перезагрузки (ЧЧ:ММ)" "04:30"
    ask_cfg CFG_UPD_MAIL "E-mail для отчётов об ошибках обновления (пусто = не слать)" ""
}

mod_updates_apply() {
    log_step "Автообновления"
    apt_install unattended-upgrades apt-listchanges

    local mail_line="" reboot_line="Unattended-Upgrade::Automatic-Reboot \"false\";"
    [[ -n "$CFG_UPD_MAIL" ]] && mail_line="Unattended-Upgrade::Mail \"${CFG_UPD_MAIL}\";
Unattended-Upgrade::MailReport \"on-change\";"
    if (( CFG_UPD_REBOOT )); then
        reboot_line="Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-WithUsers \"false\";
Unattended-Upgrade::Automatic-Reboot-Time \"${CFG_UPD_REBOOT_TIME}\";"
    fi

    # Только security: обычные обновления на проде лучше ставить руками,
    # иначе однажды ночью само обновится то, на чём всё держится.
    write_file /etc/apt/apt.conf.d/52-server-init-unattended <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist { };
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
${reboot_line}
${mail_line}
EOF

    write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    svc_enable unattended-upgrades
    log_ok "автообновления безопасности включены"
}

mod_updates_verify() {
    (( DRY_RUN )) && return 0
    unattended-upgrade --dry-run --debug 2>&1 | tail -5 | sed 's/^/    /' || true
}
