# shellcheck shell=bash
register_module firewall 1 "Файрвол (nftables или ufw)" \
    "Политика deny-by-default, SSH по whitelist IP, только явно перечисленные порты"

mod_firewall_ask() {
    ask_choice CFG_FW_BACKEND "Бэкенд файрвола" "nftables ufw" nftables
    ask_cfg    CFG_SSH_PORT   "SSH-порт (он будет открыт в файрволе)" "$(current_ssh_port)"
    valid_port "$CFG_SSH_PORT" || die "Некорректный порт: $CFG_SSH_PORT"

    local here; here=$(current_ssh_client_ip)
    [[ -n "$here" ]] && log_info "Сейчас вы подключены с адреса: $here"
    ask_cfg CFG_FW_SSH_ALLOW "Источники для SSH через пробел (пусто = отовсюду)" ""
    ask_cfg CFG_FW_TCP "Дополнительные TCP-порты через пробел (например: 80 443)" ""
    ask_cfg CFG_FW_UDP "Дополнительные UDP-порты через пробел" ""
    ask_yn  CFG_FW_PING "Отвечать на ping (ICMP echo)?" y
}

# Разделяем whitelist на IPv4 и IPv6 — в nftables это разные типы set.
_fw_split_allow() {
    FW_ALLOW4=(); FW_ALLOW6=()
    local a
    for a in $CFG_FW_SSH_ALLOW; do
        if [[ "$a" == *:* ]]; then FW_ALLOW6+=("$a"); else FW_ALLOW4+=("$a"); fi
    done
}

_fw_apply_nftables() {
    apt_install nftables
    _fw_split_allow

    local ssh_rule4 ssh_rule6 icmp_rule tcp_rules="" udp_rules="" set4="" set6="" p
    if (( ${#FW_ALLOW4[@]} )); then
        set4="        set ssh_allow4 { type ipv4_addr; flags interval; elements = { $(IFS=,; echo "${FW_ALLOW4[*]}") } }"
        ssh_rule4="        tcp dport ${CFG_SSH_PORT} ip saddr @ssh_allow4 ct state new accept"
    fi
    if (( ${#FW_ALLOW6[@]} )); then
        set6="        set ssh_allow6 { type ipv6_addr; flags interval; elements = { $(IFS=,; echo "${FW_ALLOW6[*]}") } }"
        ssh_rule6="        tcp dport ${CFG_SSH_PORT} ip6 saddr @ssh_allow6 ct state new accept"
    fi
    if [[ -z "$CFG_FW_SSH_ALLOW" ]]; then
        ssh_rule4="        tcp dport ${CFG_SSH_PORT} ct state new accept"
    fi

    for p in $CFG_FW_TCP; do tcp_rules+="        tcp dport ${p} ct state new accept"$'\n'; done
    for p in $CFG_FW_UDP; do udp_rules+="        udp dport ${p} ct state new accept"$'\n'; done

    if (( CFG_FW_PING )); then
        icmp_rule="        ip protocol icmp icmp type echo-request limit rate 10/second accept
        ip6 nexthdr ipv6-icmp accept"
    else
        icmp_rule="        ip6 nexthdr ipv6-icmp icmp6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, packet-too-big, destination-unreachable, time-exceeded } accept"
    fi

    write_file /etc/nftables.conf 0644 <<EOF
#!/usr/sbin/nft -f
# Сгенерировано debian-init. Правки вносите сюда, временных правил через
# "nft add rule" не оставляйте — при перезагрузке они исчезнут, и вы решите,
# что доступ есть, хотя его нет.
flush ruleset

table inet filter {
${set4}
${set6}
    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

${icmp_rule}

        # SSH
${ssh_rule4}
${ssh_rule6}

        # Дополнительные сервисы
${tcp_rules}${udp_rules}
        # Всё остальное молча отбрасывается (policy drop).
    }

    chain forward {
        # accept: иначе перестанут работать контейнеры Docker и любой NAT.
        # Фильтрация трафика к контейнерам — в цепочке DOCKER-USER (модуль docker).
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    if ! (( DRY_RUN )); then
        nft -c -f /etc/nftables.conf || die "Ошибка синтаксиса nftables — правила НЕ применены."
    fi
    # ufw и nftables одновременно — гарантированная путаница.
    if pkg_installed ufw; then
        log_warn "ufw установлен — отключаю, чтобы правила не конфликтовали"
        run ufw --force disable || true
        run systemctl disable --now ufw || true
    fi
    svc_enable nftables
    run systemctl restart nftables
    log_ok "nftables применён"
}

_fw_apply_ufw() {
    apt_install ufw
    local a p
    run ufw --force reset >/dev/null
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw logging low

    if [[ -n "$CFG_FW_SSH_ALLOW" ]]; then
        for a in $CFG_FW_SSH_ALLOW; do
            run ufw allow from "$a" to any port "$CFG_SSH_PORT" proto tcp comment 'ssh whitelist'
        done
    else
        # limit = встроенная защита от брутфорса (6 попыток за 30 сек).
        run ufw limit "${CFG_SSH_PORT}/tcp" comment 'ssh'
    fi
    for p in $CFG_FW_TCP; do run ufw allow "${p}/tcp"; done
    for p in $CFG_FW_UDP; do run ufw allow "${p}/udp"; done

    if ! (( CFG_FW_PING )) && ! (( DRY_RUN )); then
        backup_file /etc/ufw/before.rules
        sed -i 's/^-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
    fi

    run ufw --force enable
    log_ok "ufw включён"
    log_warn "Docker публикует порты в обход ufw — используйте модуль docker с DOCKER-USER."
}

mod_firewall_apply() {
    log_step "Файрвол (${CFG_FW_BACKEND})"
    if [[ -z "$CFG_FW_SSH_ALLOW" ]]; then
        log_warn "SSH будет открыт всему интернету. Whitelist по IP — самая дешёвая защита."
    fi
    case "$CFG_FW_BACKEND" in
        nftables) _fw_apply_nftables ;;
        ufw)      _fw_apply_ufw ;;
    esac
}

mod_firewall_verify() {
    (( DRY_RUN )) && return 0
    case "$CFG_FW_BACKEND" in
        nftables) nft list ruleset 2>/dev/null | grep -E 'policy|dport' | head -15 | sed 's/^/    /' ;;
        ufw)      ufw status verbose | sed 's/^/    /' ;;
    esac
}
