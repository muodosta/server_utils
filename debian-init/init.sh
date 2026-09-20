#!/usr/bin/env bash
#
# debian-init — интерактивная первоначальная настройка VPS на Debian 12/13.
# https://github.com/muodosta/server_utils
#
# Логика работы:
#   1) регистрация модулей   -> 2) выбор в меню -> 3) ВСЕ вопросы сразу
#   4) сводка и подтверждение -> 5) применение с проверкой -> 6) отчёт
# Вопросы задаются до применения, чтобы скрипт не останавливался на середине
# и не ждал ввода посреди установки пакетов.

set -Eeuo pipefail

APP_VERSION="0.1.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
ASSUME_YES=0
LIST_ONLY=0
PROFILE=""
CONFIG_FILE=""
ONLY_MODULES=""
SSH_KEY_MISSING=0

usage() {
    cat <<EOF
debian-init ${APP_VERSION} — первоначальная настройка VPS (Debian 12/13)

Использование: sudo ./init.sh [опции]

  --profile NAME   загрузить profiles/NAME.conf (minimal | docker | web)
  --config FILE    загрузить произвольный файл конфигурации
  --only "a b c"   выполнить только указанные модули (id через пробел)
  --dry-run        ничего не менять, только показать действия
  -y, --yes        не задавать вопросов, брать значения по умолчанию/из конфига
  --list           показать список модулей и выйти
  -h, --help       эта справка

Примеры:
  sudo ./init.sh                            # интерактивно
  sudo ./init.sh --dry-run                  # репетиция
  sudo ./init.sh --profile docker -y        # без вопросов, по профилю
  sudo ./init.sh --only "firewall ssh"      # только файрвол и SSH
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --profile)  PROFILE="${2:?}"; shift ;;
        --config)   CONFIG_FILE="${2:?}"; shift ;;
        --only)     ONLY_MODULES="${2:?}"; shift ;;
        --list)     LIST_ONLY=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
    esac
    shift
done

# --- библиотеки ---------------------------------------------------------------
for f in "$SCRIPT_DIR"/lib/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
done

trap 'log_err "Сбой в строке ${LINENO}. Бэкап конфигов: ${BACKUP_DIR}. Лог: ${LOG_FILE}"' ERR

# --- реестр модулей -----------------------------------------------------------
MOD_IDS=()
declare -A MOD_TITLE MOD_DESC MOD_DEF MOD_SEL MOD_STATUS

register_module() {
    local id=$1 def=$2 title=$3 desc=$4
    MOD_IDS+=("$id")
    MOD_TITLE["$id"]="$title"
    MOD_DESC["$id"]="$desc"
    MOD_DEF["$id"]="$def"
    MOD_SEL["$id"]="$def"
    MOD_STATUS["$id"]="—"
}

for f in "$SCRIPT_DIR"/modules/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
done

if (( LIST_ONLY )); then
    printf '%-10s %-3s %s\n' "ID" "По умолч." "Модуль"
    for id in "${MOD_IDS[@]}"; do
        printf '%-10s %-9s %s\n' "$id" "$( ((MOD_DEF[$id])) && echo да || echo нет)" "${MOD_TITLE[$id]}"
    done
    exit 0
fi

# --- проверки окружения -------------------------------------------------------
require_root
detect_os
touch "$LOG_FILE" 2>/dev/null || true

log_step "debian-init ${APP_VERSION}"
log_info "Система: ${OS_PRETTY} (${OS_CODENAME})"
log_info "Бэкап изменяемых файлов: ${BACKUP_DIR}"
log_info "Лог: ${LOG_FILE}"
(( DRY_RUN )) && log_warn "РЕЖИМ DRY-RUN: ничего меняться не будет"

if [[ "$OS_ID" != debian ]]; then
    log_warn "Ожидался Debian, обнаружено: $OS_ID"
    ask_yn CONTINUE_ANYWAY "Продолжить всё равно?" n
    (( CONTINUE_ANYWAY )) || exit 1
fi
case "$OS_CODENAME" in
    bookworm|trixie) ;;
    *) log_warn "Скрипт проверялся на Debian 12 (bookworm) и 13 (trixie)." ;;
esac

# --- профиль/конфиг -----------------------------------------------------------
[[ -n "$PROFILE" ]] && CONFIG_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"
if [[ -n "$CONFIG_FILE" ]]; then
    [[ -r "$CONFIG_FILE" ]] || die "Не читается файл конфигурации: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    log_ok "Конфигурация загружена: $CONFIG_FILE"
fi

# Выбор модулей из конфига или из --only
if [[ -n "$ONLY_MODULES" ]]; then MODULES="$ONLY_MODULES"; fi
if [[ -n "${MODULES:-}" ]]; then
    for id in "${MOD_IDS[@]}"; do MOD_SEL["$id"]=0; done
    for id in $MODULES; do
        [[ -v MOD_SEL["$id"] ]] || die "Неизвестный модуль: $id"
        MOD_SEL["$id"]=1
    done
fi

# --- меню ---------------------------------------------------------------------
print_menu() {
    local i=1 id
    echo
    printf '%s  Выберите, что применить:%s\n\n' "$C_BOLD" "$C_OFF"
    for id in "${MOD_IDS[@]}"; do
        printf '  %2d) [%s] %s\n      %s%s%s\n' "$i" \
            "$( ((MOD_SEL[$id])) && echo "${C_GRN}x${C_OFF}" || echo ' ')" \
            "${MOD_TITLE[$id]}" "$C_DIM" "${MOD_DESC[$id]}" "$C_OFF"
        ((i++))
    done
    cat <<EOF

  Команды: номера через пробел — переключить | a — все | n — ничего
           d — по умолчанию | i <номер> — описание | s — запустить | q — выход
EOF
}

menu_loop() {
    local input tok idx id
    while true; do
        print_menu
        read -r -p "  > " input </dev/tty || input="s"
        input="${input,,}"
        case "$input" in
            s|"" ) break ;;
            q    ) echo "Отменено."; exit 0 ;;
            a    ) for id in "${MOD_IDS[@]}"; do MOD_SEL["$id"]=1; done ;;
            n    ) for id in "${MOD_IDS[@]}"; do MOD_SEL["$id"]=0; done ;;
            d    ) for id in "${MOD_IDS[@]}"; do MOD_SEL["$id"]="${MOD_DEF[$id]}"; done ;;
            i*   )
                idx="${input#i}"; idx="${idx// /}"
                if [[ $idx =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#MOD_IDS[@]} )); then
                    id="${MOD_IDS[idx-1]}"
                    printf '\n  %s%s%s\n  id: %s\n  %s\n' \
                        "$C_BOLD" "${MOD_TITLE[$id]}" "$C_OFF" "$id" "${MOD_DESC[$id]}"
                    read -r -p "  [Enter] " _ </dev/tty || true
                fi ;;
            *    )
                for tok in $input; do
                    if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#MOD_IDS[@]} )); then
                        id="${MOD_IDS[tok-1]}"
                        MOD_SEL["$id"]=$(( 1 - ${MOD_SEL[$id]} ))
                    fi
                done ;;
        esac
    done
}

(( ASSUME_YES )) || menu_loop

SELECTED=()
for id in "${MOD_IDS[@]}"; do (( MOD_SEL[$id] )) && SELECTED+=("$id"); done
(( ${#SELECTED[@]} )) || { echo "Ничего не выбрано."; exit 0; }

# --- фаза вопросов ------------------------------------------------------------
log_step "Параметры (все вопросы задаются сейчас, применение — после подтверждения)"
for id in "${SELECTED[@]}"; do
    if declare -F "mod_${id}_ask" >/dev/null; then
        printf '\n  %s· %s%s\n' "$C_BOLD" "${MOD_TITLE[$id]}" "$C_OFF"
        "mod_${id}_ask"
    fi
done

# --- сводка -------------------------------------------------------------------
log_step "Будет применено"
for id in "${SELECTED[@]}"; do echo "    • ${MOD_TITLE[$id]}"; done
echo
[[ -n "${CFG_SSH_PORT:-}" ]]     && echo "    SSH-порт:        ${CFG_SSH_PORT}"
[[ -n "${CFG_USER_NAME:-}" ]]    && echo "    Пользователь:    ${CFG_USER_NAME}"
[[ -n "${CFG_FW_BACKEND:-}" ]]   && echo "    Файрвол:         ${CFG_FW_BACKEND}"
[[ -n "${CFG_FW_SSH_ALLOW:-}" ]] && echo "    SSH разрешён с:  ${CFG_FW_SSH_ALLOW}"
echo

if ! (( ASSUME_YES )) && ! (( DRY_RUN )); then
    confirm_word "ДА" "Применить эти изменения?" || { echo "Отменено."; exit 0; }
fi

# --- применение ---------------------------------------------------------------
FAILED=0
for id in "${SELECTED[@]}"; do
    if "mod_${id}_apply"; then
        MOD_STATUS["$id"]="ok"
        declare -F "mod_${id}_verify" >/dev/null && "mod_${id}_verify" || true
    else
        MOD_STATUS["$id"]="ОШИБКА"
        FAILED=1
        log_err "Модуль ${id} завершился с ошибкой — продолжаю остальные."
    fi
done

# --- отчёт --------------------------------------------------------------------
REPORT="/root/server-init-report.txt"
if ! (( DRY_RUN )); then
    {
        echo "debian-init ${APP_VERSION} — отчёт от $(date '+%F %T %Z')"
        echo "Хост: $(hostname -f 2>/dev/null || hostname)  (${OS_PRETTY})"
        echo
        echo "Модули:"
        for id in "${SELECTED[@]}"; do printf '  %-8s %-10s %s\n' "${MOD_STATUS[$id]}" "$id" "${MOD_TITLE[$id]}"; done
        echo
        echo "Ключевые параметры:"
        echo "  SSH-порт:       ${CFG_SSH_PORT:-не менялся}"
        echo "  Пользователь:   ${CFG_USER_NAME:-—}"
        echo "  Файрвол:        ${CFG_FW_BACKEND:-—}"
        echo "  SSH whitelist:  ${CFG_FW_SSH_ALLOW:-любой источник}"
        echo "  Брутфорс:       ${CFG_F2B_ENGINE:-—}"
        echo "  Бэкап:          ${CFG_BK_ENGINE:-—} -> ${CFG_BK_REPO:-—}"
        echo
        echo "Бэкап изменённых файлов: ${BACKUP_DIR}"
        echo "Откат файла: cp -a ${BACKUP_DIR}/etc/... /etc/..."
        echo "Полный лог: ${LOG_FILE}"
        echo
        echo "ПАРОЛИ И ТОКЕНЫ В ЭТОТ ОТЧЁТ НЕ ЗАПИСЫВАЮТСЯ."
    } >"$REPORT"
    chmod 600 "$REPORT"
fi

log_step "Готово"
for id in "${SELECTED[@]}"; do printf '    %-8s %s\n' "${MOD_STATUS[$id]}" "${MOD_TITLE[$id]}"; done
echo
(( DRY_RUN )) || log_ok "Отчёт: ${REPORT}"
if [[ -n "${CFG_SSH_PORT:-}" ]]; then
    log_warn "Проверьте вход в НОВОМ окне до закрытия текущей сессии:"
    echo "        ssh -p ${CFG_SSH_PORT} ${CFG_SSH_ALLOWUSERS:-${CFG_USER_NAME:-root}}@$(wan_ip)"
fi
exit "$FAILED"
