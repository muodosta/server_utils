# shellcheck shell=bash
# Проверки окружения и мелкие помощники.

OS_ID=""; OS_VER=""; OS_CODENAME=""; OS_PRETTY=""

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Скрипт нужно запускать от root (sudo -i)."
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — неизвестная система."
    # Читаем в субшелле, чтобы переменные os-release (VERSION, NAME, ...)
    # не перетёрли переменные скрипта.
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
    OS_CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
    OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-$OS_ID}")
}

have() { command -v "$1" >/dev/null 2>&1; }

# Текущий порт SSH из действующей конфигурации (а не из закомментированной строки).
#
# Все конвейеры здесь принудительно гасятся через "|| true". Причина: в скрипте
# включены "set -e" и "set -o pipefail", а "sshd -T" может вернуть ненулевой код
# (нет host-ключей на свежей системе, socket-активация в Debian 13, Match-блоки),
# и тогда падала бы вся подстановка $(current_ssh_port), а ERR-трап печатал бы
# ложную ошибку. Отсутствие порта здесь — не ошибка, а штатный случай: вернём 22.
current_ssh_port() {
    local p=""
    if have sshd; then
        p=$( { sshd -T 2>/dev/null || true; } | awk '/^port /{print $2; exit}' || true )
    fi
    # В Debian 13 SSH по умолчанию socket-activated: порт задаёт ssh.socket.
    if [[ -z "$p" ]] && systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
        p=$( { systemctl show ssh.socket -p Listen --value 2>/dev/null || true; } \
             | grep -oE '[0-9]+ ' | head -1 | tr -d ' ' || true )
    fi
    echo "${p:-22}"
}

# Включена ли socket-активация SSH (Debian 13 / trixie).
ssh_socket_activated() {
    systemctl is-enabled ssh.socket >/dev/null 2>&1
}

# Внешний (default route) интерфейс.
wan_iface() {
    have ip || return 0
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true
}

# Основной внешний IP (для подсказок пользователю).
wan_ip() {
    have ip || { echo "<IP сервера>"; return 0; }
    local a
    a=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
    echo "${a:-<IP сервера>}"
}

# IP, с которого мы сейчас подключены по SSH — кандидат в whitelist.
current_ssh_client_ip() {
    [[ -n "${SSH_CLIENT:-}" ]] && awk '{print $1}' <<<"$SSH_CLIENT" && return 0
    [[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $1}' <<<"$SSH_CONNECTION" && return 0
    return 0
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
