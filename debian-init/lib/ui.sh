# shellcheck shell=bash
# Интерактивный ввод. Всё читается из /dev/tty, чтобы работало и при запуске
# через пайп. Если переменная уже задана (профиль/--config) — вопрос не задаётся.

_tty_read() { read -r "$@" </dev/tty; }

# ask_cfg VAR "Вопрос" "значение по умолчанию"
ask_cfg() {
    local var=$1 prompt=$2 def=${3:-} ans
    if [[ -n "${!var:-}" ]]; then
        log_info "$prompt = ${!var} (из конфига)"; return 0
    fi
    if (( ASSUME_YES )); then printf -v "$var" '%s' "$def"; return 0; fi
    _tty_read -p "  ${C_CYN}?${C_OFF} ${prompt}${def:+ [${def}]}: " ans || ans=""
    [[ -z "$ans" ]] && ans="$def"
    printf -v "$var" '%s' "$ans"
}

# ask_yn VAR "Вопрос" y|n   -> в переменной окажется 1 или 0
ask_yn() {
    local var=$1 prompt=$2 def=${3:-y} ans hint
    if [[ -n "${!var:-}" ]]; then
        log_info "$prompt = ${!var} (из конфига)"; return 0
    fi
    if (( ASSUME_YES )); then
        printf -v "$var" '%s' "$([[ $def == y ]] && echo 1 || echo 0)"; return 0
    fi
    hint=$([[ $def == y ]] && echo 'Y/n' || echo 'y/N')
    while true; do
        _tty_read -p "  ${C_CYN}?${C_OFF} ${prompt} [${hint}]: " ans || ans=""
        [[ -z "$ans" ]] && ans="$def"
        case "${ans,,}" in
            y|yes|д|да) printf -v "$var" '%s' 1; return 0 ;;
            n|no|н|нет) printf -v "$var" '%s' 0; return 0 ;;
            *) echo "     Ответьте y или n." ;;
        esac
    done
}

# ask_choice VAR "Вопрос" "вар1 вар2 вар3" "по умолчанию"
ask_choice() {
    local var=$1 prompt=$2 opts=$3 def=$4 ans o
    if [[ -n "${!var:-}" ]]; then
        log_info "$prompt = ${!var} (из конфига)"; return 0
    fi
    if (( ASSUME_YES )); then printf -v "$var" '%s' "$def"; return 0; fi
    while true; do
        _tty_read -p "  ${C_CYN}?${C_OFF} ${prompt} (${opts// /|}) [${def}]: " ans || ans=""
        [[ -z "$ans" ]] && ans="$def"
        for o in $opts; do
            [[ "$o" == "$ans" ]] && { printf -v "$var" '%s' "$ans"; return 0; }
        done
        echo "     Допустимые значения: $opts"
    done
}

# ask_secret VAR "Вопрос"  — ввод без эха
ask_secret() {
    local var=$1 prompt=$2 ans
    if [[ -n "${!var:-}" ]]; then log_info "$prompt = *** (из конфига)"; return 0; fi
    if (( ASSUME_YES )); then printf -v "$var" '%s' ""; return 0; fi
    _tty_read -s -p "  ${C_CYN}?${C_OFF} ${prompt}: " ans || ans=""
    echo
    printf -v "$var" '%s' "$ans"
}

# Пауза с подтверждением произвольным словом (для необратимых шагов).
confirm_word() {
    local want=$1 prompt=$2 ans
    _tty_read -p "  ${C_YEL}!${C_OFF} ${prompt} (введите ${want}): " ans || ans=""
    [[ "$ans" == "$want" ]]
}
