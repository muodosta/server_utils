# shellcheck shell=bash
register_module docker 0 "Docker CE + compose" \
    "Официальный репозиторий, ротация логов, фильтрация портов контейнеров через DOCKER-USER"

mod_docker_ask() {
    ask_yn  CFG_DOCKER_USERGRP "Добавить ${CFG_USER_NAME:-пользователя} в группу docker?" y
    ask_yn  CFG_DOCKER_FW "Ограничить доступ к опубликованным портам контейнеров?" y
    if (( CFG_DOCKER_FW )); then
        log_info "Docker пишет правила в iptables ДО вашего файрвола — 'docker run -p 5432:5432'"
        log_info "открывает порт всему интернету, даже если nftables/ufw его не открывали."
        ask_cfg CFG_DOCKER_FW_OPEN  "Порты контейнеров, открытые всем (через пробел)" "80 443"
        ask_cfg CFG_DOCKER_FW_ALLOW "Источники с полным доступом к контейнерам" "${CFG_FW_SSH_ALLOW:-}"
    fi
}

mod_docker_apply() {
    log_step "Docker"
    apt_install ca-certificates curl gnupg

    if ! pkg_installed docker-ce; then
        if ! (( DRY_RUN )); then
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/debian/gpg" \
                -o /etc/apt/keyrings/docker.asc || die "не скачался ключ Docker"
            chmod a+r /etc/apt/keyrings/docker.asc
        fi
        write_file /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${OS_CODENAME} stable
EOF
        APT_UPDATED=0
        apt_update
    fi
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Без лимита логи контейнеров растут бесконечно и однажды забивают диск.
    write_file /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false
}
EOF
    svc_enable docker
    run systemctl restart docker

    if (( CFG_DOCKER_USERGRP )) && [[ -n "${CFG_USER_NAME:-}" ]]; then
        run usermod -aG docker "$CFG_USER_NAME"
        log_warn "Группа docker равносильна root — выдавайте её осознанно."
    fi

    if (( CFG_DOCKER_FW )); then
        apt_install iptables
        write_file /usr/local/sbin/docker-user-fw.sh 0750 <<EOF
#!/bin/bash
# Сгенерировано debian-init. Фильтрация трафика к опубликованным портам
# контейнеров. Docker обрабатывает цепочку DOCKER-USER ДО своих правил,
# поэтому это единственное штатное место для таких ограничений.
set -e
WAN="\$(ip -4 route show default | awk '{print \$5; exit}')"
ALLOW="${CFG_DOCKER_FW_ALLOW}"
OPEN="${CFG_DOCKER_FW_OPEN}"

iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for src in \$ALLOW; do
    iptables -A DOCKER-USER -s "\$src" -j RETURN
done
for p in \$OPEN; do
    iptables -A DOCKER-USER -p tcp --dport "\$p" -j RETURN
done
[ -n "\$WAN" ] && iptables -A DOCKER-USER -i "\$WAN" -j DROP
iptables -A DOCKER-USER -j RETURN
EOF
        write_file /etc/systemd/system/docker-user-fw.service <<'EOF'
[Unit]
Description=Правила DOCKER-USER (debian-init)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-user-fw.sh

[Install]
WantedBy=multi-user.target
EOF
        run systemctl daemon-reload
        svc_enable docker-user-fw
        run systemctl restart docker-user-fw
        log_ok "DOCKER-USER: открыты порты [${CFG_DOCKER_FW_OPEN}], полный доступ с [${CFG_DOCKER_FW_ALLOW:-—}]"
    fi

    log_ok "Docker установлен"
}

mod_docker_verify() {
    (( DRY_RUN )) && return 0
    log_info "$(docker --version 2>/dev/null); $(docker compose version 2>/dev/null)"
    (( ${CFG_DOCKER_FW:-0} )) && iptables -S DOCKER-USER 2>/dev/null | sed 's/^/    /'
    return 0
}
