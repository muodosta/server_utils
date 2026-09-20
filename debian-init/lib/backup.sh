# shellcheck shell=bash
# Любой изменяемый файл сначала копируется в BACKUP_DIR с сохранением пути,
# чтобы откат был тривиальным: cp -a $BACKUP_DIR/etc/ssh/... /etc/ssh/...

BACKUP_DIR="${BACKUP_DIR:-/root/.server-init-backup-$(date +%Y%m%d-%H%M%S)}"

backup_file() {
    local f=$1
    [[ -e "$f" ]] || return 0
    (( DRY_RUN )) && return 0
    mkdir -p "$BACKUP_DIR"
    cp -a --parents "$f" "$BACKUP_DIR/" 2>/dev/null || true
}

# write_file /path/to/file [mode] <<'EOF' ... EOF
write_file() {
    local path=$1 mode=${2:-0644} content
    content=$(cat)
    if (( DRY_RUN )); then
        printf '    [dry-run] записал бы %s (%s строк, mode %s)\n' \
            "$path" "$(wc -l <<<"$content")" "$mode"
        return 0
    fi
    backup_file "$path"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
    chmod "$mode" "$path"
    log_info "записан $path"
}

# run <команда...> — выполняет или печатает при --dry-run
run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# Добавить строку в файл, если её там ещё нет (идемпотентность).
ensure_line() {
    local file=$1 line=$2
    if (( DRY_RUN )); then
        printf '    [dry-run] строка в %s: %s\n' "$file" "$line"; return 0
    fi
    [[ -e "$file" ]] || { mkdir -p "$(dirname "$file")"; : >"$file"; }
    grep -qxF -- "$line" "$file" && return 0
    backup_file "$file"
    printf '%s\n' "$line" >>"$file"
    log_info "в $file добавлено: $line"
}
