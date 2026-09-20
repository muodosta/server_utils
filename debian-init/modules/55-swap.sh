# shellcheck shell=bash
register_module swap 1 "Swap-файл" \
    "Большинство VPS идут без swap, и OOM-killer убивает базу при пиках памяти"

mod_swap_ask() {
    local ram_mb suggest
    ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    if   (( ram_mb <= 2048 )); then suggest="2G"
    elif (( ram_mb <= 8192 )); then suggest="4G"
    else                            suggest="4G"; fi
    log_info "RAM: ${ram_mb} МБ"
    ask_cfg CFG_SWAP_SIZE "Размер swap-файла (0 = не создавать)" "$suggest"
}

mod_swap_apply() {
    log_step "Swap"
    [[ "$CFG_SWAP_SIZE" == "0" ]] && { log_info "пропущено по запросу"; return 0; }

    if swapon --show 2>/dev/null | grep -q .; then
        log_info "swap уже активен: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
        return 0
    fi

    local f=/swapfile
    if (( DRY_RUN )); then
        log_info "[dry-run] создал бы $f размером $CFG_SWAP_SIZE"
        return 0
    fi

    # fallocate быстрее, но на некоторых ФС swap его не принимает — fallback на dd.
    if ! fallocate -l "$CFG_SWAP_SIZE" "$f" 2>/dev/null; then
        local mb; mb=$(numfmt --from=iec "$CFG_SWAP_SIZE" 2>/dev/null); mb=$((mb/1024/1024))
        dd if=/dev/zero of="$f" bs=1M count="$mb" status=none
    fi
    chmod 600 "$f"
    mkswap "$f" >/dev/null
    swapon "$f"
    ensure_line /etc/fstab "/swapfile none swap sw 0 0"
    log_ok "swap ${CFG_SWAP_SIZE} создан"
}

mod_swap_verify() {
    (( DRY_RUN )) && return 0
    free -h | sed 's/^/    /'
}
