# shellcheck shell=bash
register_module sysctl 1 "Параметры ядра (sysctl)" \
    "BBR+fq, защита сетевого стека, лимиты, опционально отключение IPv6"

mod_sysctl_ask() {
    ask_yn CFG_SYSCTL_BBR  "Включить TCP BBR + fq (обычно заметно лучше на дальних каналах)?" y
    ask_yn CFG_SYSCTL_NOV6 "Полностью отключить IPv6?" n
    ask_cfg CFG_SYSCTL_SWAPPINESS "vm.swappiness" "10"
}

mod_sysctl_apply() {
    log_step "Параметры ядра"

    local bbr=""
    if (( CFG_SYSCTL_BBR )); then
        bbr="net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
    fi

    local nov6=""
    if (( CFG_SYSCTL_NOV6 )); then
        nov6="net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1"
    fi

    write_file /etc/sysctl.d/99-server-init.conf <<EOF
# Сгенерировано debian-init

# --- Сеть: защита от спуфинга и лишней маршрутизации ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1

# --- Производительность ---
${bbr}
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152

# --- Память ---
vm.swappiness = ${CFG_SYSCTL_SWAPPINESS}
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 0

# --- Ядро ---
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0

${nov6}
EOF

    # Лимит открытых файлов — упирается почти любой сервис под нагрузкой.
    write_file /etc/security/limits.d/99-server-init.conf <<'EOF'
*  soft  nofile  65535
*  hard  nofile  65535
root soft nofile 65535
root hard nofile 65535
EOF

    run sysctl --system >/dev/null
    log_ok "sysctl применён"
}

mod_sysctl_verify() {
    (( DRY_RUN )) && return 0
    log_info "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
    log_info "qdisc: $(sysctl -n net.core.default_qdisc)"
}
