#!/usr/bin/env bash
#
# vpn-node-tuner — tuning of the Linux network stack for VPN nodes
#                  (Xray / sing-box / 3X-UI / Remnawave)
#
# https://github.com/nektona/vpn-node-tuner
# MIT License
#
# Deliberately no `set -e`: this is an interactive tool, and a non-zero exit
# from grep/sysctl inside a menu must not kill the whole session.
set -uo pipefail

SCRIPT_VERSION="1.0.0"
REPO_SLUG="nektona/vpn-node-tuner"
RAW_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/vpn-node-tuner.sh"

CMD_NAME="vpntune"
INSTALL_PATH="/usr/local/bin/${CMD_NAME}"

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"
CONF_DIR="/etc/vpn-node-tuner"
CONF_FILE="${CONF_DIR}/config"
PARAMS_FILE="${CONF_DIR}/params.conf"
STATE_DIR="/var/lib/vpn-node-tuner"

BLOCK_START="# ===== vpn-node-tuner (start) ====="
BLOCK_END="# ===== vpn-node-tuner (end) ====="
MAX_BACKUPS=10

LANG_CODE="${VPNTUNE_LANG:-}"
PROFILE=""
MODE="auto"
ASSUME_YES=0
SWAP_SIZE=""
SERVICE_ARG=""

# ---------------------------------------------------------------- colours ---

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m';  C_CYA=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED="";   C_GRN="";  C_YLW=""
    C_BLU="";   C_CYA=""
fi

# ------------------------------------------------------------------- i18n ---
# T <russian> <english>  — every user-visible string goes through this.

T() {
    if [ "$LANG_CODE" = "ru" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_CYA}•${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GRN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YLW}!${C_RESET} $*"; }
err()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
dim()  { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
hr()   { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"; }

title() {
    printf '\n%s\n' "${C_BOLD}${C_BLU}$*${C_RESET}"
    hr
}

die() { err "$*"; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [ "$(id -u)" -eq 0 ]; }

need_root() {
    if ! is_root; then
        err "$(T 'Нужны права root. Запустите через sudo:' 'Root privileges required. Run with sudo:')"
        say "    sudo ${CMD_NAME} $*"
        return 1
    fi
    return 0
}

# Always read from the terminal, never from the loop's stdin: several menus
# feed a here-document into `while read`, and a plain `read` would eat it.
_read() {
    if [ -r /dev/tty ]; then
        read -r "$@" < /dev/tty
    else
        read -r "$@"
    fi
}

pause() {
    printf '\n%s' "${C_DIM}$(T 'Enter — продолжить...' 'Press Enter to continue...')${C_RESET}"
    _read _ || true
    printf '\n'
}

# confirm <question> [default:y|n]
confirm() {
    local q="$1" def="${2:-y}" hint ans
    [ "$ASSUME_YES" = "1" ] && return 0
    if [ "$def" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '%s ' "${C_BOLD}${q}${C_RESET} ${hint}"
    _read ans || ans=""
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    [ -z "$ans" ] && ans="$def"
    [ "$ans" = "y" ] || [ "$ans" = "yes" ] || [ "$ans" = "д" ] || [ "$ans" = "да" ]
}

ask() {
    local prompt="$1" default="${2:-}" ans
    if [ -n "$default" ]; then
        printf '%s ' "${prompt} ${C_DIM}[${default}]${C_RESET}"
    else
        printf '%s ' "$prompt"
    fi
    _read ans || ans=""
    [ -z "$ans" ] && ans="$default"
    printf '%s' "$ans"
}

# ------------------------------------------------------------- environment ---

detect_ram_mb() {
    local kb
    kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    [ -z "$kb" ] && { printf '0'; return; }
    printf '%s' "$(( kb / 1024 ))"
}

profile_for_ram() {
    local mb="$1"
    if   [ "$mb" -lt 1536 ]; then printf '1g'
    elif [ "$mb" -lt 3072 ]; then printf '2g'
    elif [ "$mb" -lt 6144 ]; then printf '4g'
    else                          printf '8g'
    fi
}

detect_virt() {
    if has_cmd systemd-detect-virt; then
        systemd-detect-virt 2>/dev/null || printf 'none'
    else
        printf 'unknown'
    fi
}

is_container() {
    case "$(detect_virt)" in
        lxc|lxc-libvirt|openvz|docker|podman|systemd-nspawn) return 0 ;;
        *) return 1 ;;
    esac
}

default_iface() {
    ip route show default 2>/dev/null | awk '{print $5; exit}'
}

os_pretty() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null
        printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}"
    else
        printf '%s' "$(uname -s) $(uname -r)"
    fi
}

sysctl_get() { sysctl -n "$1" 2>/dev/null | tr -s ' \t' ' ' | sed 's/^ *//;s/ *$//'; }

bbr_available() {
    local avail
    avail="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
    case " $avail " in *" bbr "*) return 0 ;; esac
    modprobe tcp_bbr >/dev/null 2>&1 || true
    avail="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
    case " $avail " in *" bbr "*) return 0 ;; esac
    return 1
}

# -------------------------------------------------------------- parameters ---

PKEYS=""            # newline-separated ordered key list
PVAL_FILE=""        # temp file with "key<TAB>value" pairs

pset() {
    PKEYS="${PKEYS}$1
"
    printf '%s\t%s\n' "$1" "$2" >> "$PVAL_FILE"
}

pget() {
    [ -n "$PVAL_FILE" ] && [ -f "$PVAL_FILE" ] || return 1
    awk -F'\t' -v k="$1" '$1==k {print $2; found=1} END {exit !found}' "$PVAL_FILE"
}

pkeys_list() { printf '%s' "$PKEYS" | sed '/^$/d'; }

preset_params() {
    PKEYS=""
    [ -n "$PVAL_FILE" ] && rm -f "$PVAL_FILE"
    PVAL_FILE="$(mktemp)"
}

pdrop() {
    local drop="$1" tmp
    PKEYS="$(pkeys_list | grep -vxF "$drop")
"
    tmp="$(mktemp)"
    awk -F'\t' -v k="$drop" '$1!=k' "$PVAL_FILE" > "$tmp"
    mv "$tmp" "$PVAL_FILE"
}

# Group of a parameter — used only to lay out comments in sysctl.conf.
param_group() {
    case "$1" in
        net.core.default_qdisc|net.ipv4.tcp_congestion_control)            printf 'cc' ;;
        net.core.rmem_max|net.core.wmem_max|net.ipv4.tcp_rmem|net.ipv4.tcp_wmem) printf 'buf' ;;
        net.ipv4.tcp_slow_start_after_idle)                                printf 'idle' ;;
        net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|net.core.netdev_max_backlog) printf 'queue' ;;
        net.ipv4.ip_local_port_range|net.ipv4.tcp_tw_reuse|net.ipv4.tcp_fin_timeout) printf 'ports' ;;
        net.ipv4.tcp_keepalive_*)                                          printf 'keepalive' ;;
        vm.*)                                                              printf 'mem' ;;
        *)                                                                 printf 'extra' ;;
    esac
}

group_title() {
    case "$1" in
        cc)        T 'BBR + честная очередь (fair queueing)' 'BBR + fair queueing' ;;
        buf)       T 'Буферы сокетов' 'Socket buffers' ;;
        idle)      T 'Не сбрасывать скорость после простоя (gRPC / XHTTP / HTTP-2)' 'Do not reset the window after idle (gRPC / XHTTP / HTTP-2)' ;;
        queue)     T 'Очереди соединений' 'Connection queues' ;;
        ports)     T 'Порты и переиспользование сокетов' 'Ports and socket reuse' ;;
        keepalive) T 'Keepalive: быстрее вычищать мёртвые сессии' 'Keepalive: reap dead sessions faster' ;;
        mem)       T 'Память' 'Memory' ;;
        *)         T 'Дополнительно' 'Extra' ;;
    esac
}

param_desc() {
    case "$1" in
        net.core.default_qdisc)
            T 'Планировщик очередей. fq — штатная пара для BBR (pacing). Альтернатива: fq_codel.' \
              'Queueing discipline. fq is the standard companion for BBR (pacing). Alternative: fq_codel.' ;;
        net.ipv4.tcp_congestion_control)
            T 'Алгоритм управления перегрузкой. bbr держит скорость на каналах с потерями лучше, чем cubic.' \
              'Congestion control algorithm. bbr holds throughput on lossy links better than cubic.' ;;
        net.core.rmem_max|net.core.wmem_max)
            T 'Системный потолок буфера сокета — сколько максимум может запросить приложение.' \
              'System-wide socket buffer ceiling — the maximum an application may request.' ;;
        net.ipv4.tcp_rmem)
            T 'Буферы приёма TCP: <минимум> <по умолчанию> <максимум> в байтах. Ядро подбирает размер само.' \
              'TCP receive buffers: <min> <default> <max> in bytes. The kernel autotunes within these bounds.' ;;
        net.ipv4.tcp_wmem)
            T 'Буферы отправки TCP: <минимум> <по умолчанию> <максимум> в байтах.' \
              'TCP send buffers: <min> <default> <max> in bytes.' ;;
        net.ipv4.tcp_slow_start_after_idle)
            T '0 — не сбрасывать окно перегрузки после паузы. Убирает «раскачку» после паузы в плеере.' \
              '0 — do not reset the congestion window after an idle period. Removes the ramp-up stall after a pause.' ;;
        net.core.somaxconn)
            T 'Длина очереди установленных, но ещё не принятых приложением соединений.' \
              'Queue length for established connections not yet accepted by the application.' ;;
        net.ipv4.tcp_max_syn_backlog)
            T 'Очередь полуоткрытых (SYN) соединений.' \
              'Queue of half-open (SYN) connections.' ;;
        net.core.netdev_max_backlog)
            T 'Очередь пакетов между сетевой картой и обработкой в ядре.' \
              'Packet queue between the NIC and kernel processing.' ;;
        net.ipv4.ip_local_port_range)
            T 'Диапазон исходящих портов. Xray открывает исходящее соединение на каждый запрос клиента.' \
              'Outbound port range. Xray opens an outbound connection per client request.' ;;
        net.ipv4.tcp_tw_reuse)
            T '1 — переиспользовать сокеты в TIME_WAIT для исходящих. Для ноды безопасно, снимает исчерпание портов.' \
              '1 — reuse TIME_WAIT sockets for outbound connections. Safe for a node, avoids port exhaustion.' ;;
        net.ipv4.tcp_fin_timeout)
            T 'Сколько секунд держать сокет в FIN_WAIT_2.' \
              'How many seconds to keep a socket in FIN_WAIT_2.' ;;
        net.ipv4.tcp_keepalive_time)
            T 'Через сколько секунд простоя отправить первый keepalive-пробник.' \
              'Idle seconds before the first keepalive probe.' ;;
        net.ipv4.tcp_keepalive_intvl)
            T 'Интервал между keepalive-пробниками, секунды.' \
              'Interval between keepalive probes, seconds.' ;;
        net.ipv4.tcp_keepalive_probes)
            T 'Сколько пробников без ответа до разрыва соединения.' \
              'Unanswered probes before the connection is dropped.' ;;
        vm.swappiness)
            T 'Насколько охотно ядро свопит. 10 — только под реальным давлением.' \
              'How eagerly the kernel swaps. 10 — only under real pressure.' ;;
        vm.vfs_cache_pressure)
            T 'Насколько агрессивно вычищается кеш dentry/inode. 50 — держать дольше.' \
              'How aggressively dentry/inode cache is reclaimed. 50 — keep it longer.' ;;
        *)  T 'Дополнительный параметр.' 'Additional parameter.' ;;
    esac
}

# build_params <profile> — fills PKEYS/PVAL_FILE with the profile defaults.
build_params() {
    local p="$1" bufmax somax synbl netdev

    case "$p" in
        1g) bufmax=16777216; somax=4096;  synbl=4096;  netdev=8192  ;;
        2g) bufmax=16777216; somax=8192;  synbl=8192;  netdev=16384 ;;
        4g) bufmax=33554432; somax=16384; synbl=16384; netdev=32768 ;;
        8g) bufmax=67108864; somax=32768; synbl=32768; netdev=65536 ;;
        *)  err "$(T 'Неизвестный профиль:' 'Unknown profile:') $p"; return 1 ;;
    esac

    preset_params

    pset net.core.default_qdisc              "fq"
    pset net.ipv4.tcp_congestion_control     "bbr"

    pset net.core.rmem_max                   "$bufmax"
    pset net.core.wmem_max                   "$bufmax"
    pset net.ipv4.tcp_rmem                   "4096 87380 $bufmax"
    pset net.ipv4.tcp_wmem                   "4096 65536 $bufmax"

    pset net.ipv4.tcp_slow_start_after_idle  "0"

    pset net.core.somaxconn                  "$somax"
    pset net.ipv4.tcp_max_syn_backlog        "$synbl"
    pset net.core.netdev_max_backlog         "$netdev"

    pset net.ipv4.ip_local_port_range        "1024 65535"
    pset net.ipv4.tcp_tw_reuse               "1"
    pset net.ipv4.tcp_fin_timeout            "15"

    pset net.ipv4.tcp_keepalive_time         "600"
    pset net.ipv4.tcp_keepalive_intvl        "30"
    pset net.ipv4.tcp_keepalive_probes       "5"

    pset vm.swappiness                       "10"
    pset vm.vfs_cache_pressure               "50"
}

save_params() {
    mkdir -p "$CONF_DIR"
    {
        printf '# %s\n' "$(T 'Значения, применяемые vpn-node-tuner. Правится через меню.' \
                              'Values applied by vpn-node-tuner. Edit via the menu.')"
        local k v
        pkeys_list | while IFS= read -r k; do
            v="$(pget "$k")"
            printf '%s = %s\n' "$k" "$v"
        done
    } > "$PARAMS_FILE"
    chmod 0644 "$PARAMS_FILE"
}

load_params() {
    [ -f "$PARAMS_FILE" ] || return 1
    preset_params
    local line k v
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) : ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        k="$(printf '%s' "$k" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$k" ] && pset "$k" "$v"
    done < "$PARAMS_FILE"
    [ -n "$(pkeys_list)" ]
}

# ----------------------------------------------------------------- config ---

load_config() {
    [ -f "$CONF_FILE" ] || return 1
    local line k v
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            LANG_CODE) [ -z "$LANG_CODE" ] && LANG_CODE="$v" ;;
            PROFILE)   [ -z "$PROFILE" ]   && PROFILE="$v" ;;
            MODE)      MODE="$v" ;;
        esac
    done < "$CONF_FILE"
    return 0
}

save_config() {
    is_root || return 0
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
# vpn-node-tuner ${SCRIPT_VERSION}
LANG_CODE=${LANG_CODE}
PROFILE=${PROFILE}
MODE=${MODE}
APPLIED_AT=$(date '+%Y-%m-%d %H:%M:%S')
APPLIED_VERSION=${SCRIPT_VERSION}
EOF
    chmod 0644 "$CONF_FILE"
}

choose_language() {
    printf '\n'
    say "  ${C_BOLD}1)${C_RESET} Русский"
    say "  ${C_BOLD}2)${C_RESET} English"
    printf '\n%s ' "Выберите язык / Choose language [1]:"
    local a; _read a || a=""
    case "$a" in
        2|e|en|E|EN) LANG_CODE="en" ;;
        *)           LANG_CODE="ru" ;;
    esac
    save_config
}

# ------------------------------------------------------- sysctl.conf edits ---

backup_sysctl() {
    local dst="${SYSCTL_FILE}.bak-$(date '+%Y-%m-%d-%H%M%S')"
    cp -a "$SYSCTL_FILE" "$dst" 2>/dev/null || return 1
    printf '%s' "$dst"
}

list_backups() {
    ls -1t "${SYSCTL_FILE}".bak-* 2>/dev/null
}

prune_backups() {
    local n=0 f
    list_backups | while IFS= read -r f; do
        n=$((n + 1))
        [ "$n" -gt "$MAX_BACKUPS" ] && rm -f "$f"
    done
}

# Removes our managed block (and the hand-written one from the original guide).
strip_managed_block() {
    local file="$1" tmp
    [ -f "$file" ] || return 0
    tmp="$(mktemp)"
    awk '
        /^# =====[[:space:]]*vpn-node-tuner[[:space:]]*\(start\)/  { skip=1; next }
        /^# =====[[:space:]]*VPN node tuning[[:space:]]*\(start\)/ { skip=1; next }
        /^# =====[[:space:]]*vpn-node-tuner[[:space:]]*\(end\)/    { skip=0; next }
        /^# =====[[:space:]]*VPN node tuning[[:space:]]*\(end\)/   { skip=0; next }
        skip != 1 { print }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Comments out our keys that are still set elsewhere in the same file, so the
# "last occurrence wins" rule can no longer surprise anyone.
comment_duplicate_keys() {
    local file="$1" keyfile tmp
    keyfile="$(mktemp)"; tmp="$(mktemp)"
    pkeys_list > "$keyfile"
    awk -v keyfile="$keyfile" -v tag="# [vpn-node-tuner: disabled duplicate] " '
        BEGIN { while ((getline l < keyfile) > 0) if (l != "") keys[l] = 1 }
        /^[[:space:]]*#/ { print; next }
        {
            p = index($0, "=")
            if (p == 0) { print; next }
            k = substr($0, 1, p - 1)
            gsub(/[[:space:]]/, "", k)
            gsub(/\//, ".", k)
            if (k in keys) { print tag $0; next }
            print
        }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$keyfile" "$tmp"
}

render_block() {
    local k v g prev=""
    printf '%s\n' "$BLOCK_START"
    printf '# %s %s — %s\n' "$(T 'Сгенерировано' 'Generated by')" \
        "vpn-node-tuner ${SCRIPT_VERSION}" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# %s: %s | RAM: %s MB | %s\n' \
        "$(T 'Профиль' 'Profile')" "$PROFILE" "$(detect_ram_mb)" "https://github.com/${REPO_SLUG}"
    printf '# %s\n' "$(T 'Не правьте вручную: блок перезаписывается целиком.' \
                          'Do not edit by hand: the block is rewritten as a whole.')"
    printf '\n'
    pkeys_list | while IFS= read -r k; do
        v="$(pget "$k")"
        g="$(param_group "$k")"
        if [ "$g" != "$prev" ]; then
            [ -n "$prev" ] && printf '\n'
            printf '# %s\n' "$(group_title "$g")"
            prev="$g"
        fi
        printf '%s = %s\n' "$k" "$v"
    done
    printf '\n%s\n' "$BLOCK_END"
}

write_block() {
    local tmp
    touch "$SYSCTL_FILE" 2>/dev/null || return 1
    strip_managed_block "$SYSCTL_FILE"
    comment_duplicate_keys "$SYSCTL_FILE"
    # drop trailing blank lines, then append
    tmp="$(mktemp)"
    awk 'BEGIN{blank=0} { if ($0 ~ /^[[:space:]]*$/) { blank++ } else { while (blank>0) { print ""; blank-- }; print } }' \
        "$SYSCTL_FILE" > "$tmp" && cat "$tmp" > "$SYSCTL_FILE"
    rm -f "$tmp"
    printf '\n' >> "$SYSCTL_FILE"
    render_block >> "$SYSCTL_FILE"
}

# Extracts keys the kernel refused, from `sysctl -p` output.
parse_failed_keys() {
    sed -n \
        -e 's#^sysctl: cannot stat /proc/sys/\([^:]*\).*#\1#p' \
        -e 's#^sysctl: setting key "\([^"]*\)".*#\1#p' \
        -e "s#^sysctl: permission denied on key ['\"]\([^'\"]*\)['\"].*#\1#p" \
        | tr '/' '.' | sed 's/[[:space:]]*$//' | sort -u
}

apply_qdisc() {
    local ifc qd
    qd="$(pget net.core.default_qdisc)" || return 0
    ifc="$(default_iface)"
    [ -n "$ifc" ] || return 0
    has_cmd tc || return 0
    if tc qdisc replace dev "$ifc" root "$qd" 2>/dev/null; then
        ok "$(T 'qdisc' 'qdisc') ${C_BOLD}${qd}${C_RESET} $(T 'навешен на интерфейс' 'attached to interface') ${C_BOLD}${ifc}${C_RESET}"
    else
        warn "$(T 'Не удалось навесить qdisc на' 'Could not attach qdisc to') ${ifc} — $(T 'применится после перезагрузки' 'it will apply after a reboot')"
    fi
}

show_preview() {
    local k v cur
    title "$(T 'Что изменится' 'What will change')"
    printf '%-38s %-22s %s\n' "$(T 'Параметр' 'Parameter')" "$(T 'Сейчас' 'Current')" "$(T 'Станет' 'New')"
    hr
    pkeys_list | while IFS= read -r k; do
        v="$(pget "$k")"
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && cur="n/a"
        if [ "$cur" = "$v" ]; then
            printf '%-38s %-22s %s\n' "$k" "$cur" "${C_DIM}= $(T 'без изменений' 'unchanged')${C_RESET}"
        else
            printf '%-38s %-22s %s\n' "$k" "$cur" "${C_GRN}${v}${C_RESET}"
        fi
    done
    hr
    say "$(T 'Файл:' 'File:') ${C_BOLD}${SYSCTL_FILE}${C_RESET}"
}

preflight_checks() {
    local cc virt
    virt="$(detect_virt)"

    if is_container; then
        warn "$(T 'Обнаружен контейнер:' 'Container detected:') ${virt}"
        say "  $(T 'Часть сетевых sysctl в контейнерах недоступна — такие ключи будут отброшены автоматически.' \
                  'Some network sysctls are unavailable inside containers — such keys will be dropped automatically.')"
    fi

    cc="$(pget net.ipv4.tcp_congestion_control)" || cc=""
    if [ "$cc" = "bbr" ] && ! bbr_available; then
        warn "$(T 'BBR недоступен в этом ядре.' 'BBR is not available in this kernel.')"
        say "  $(T 'Доступны:' 'Available:') $(sysctl_get net.ipv4.tcp_available_congestion_control)"
        if confirm "$(T 'Использовать cubic вместо bbr?' 'Use cubic instead of bbr?')" y; then
            pdrop net.ipv4.tcp_congestion_control
            pset net.ipv4.tcp_congestion_control "cubic"
        else
            return 1
        fi
    fi

    if grep -qs 'tcp_tw_recycle' "$SYSCTL_FILE" /etc/sysctl.d/*.conf 2>/dev/null; then
        warn "$(T 'В конфигурации найден tcp_tw_recycle — он ломает NAT-клиентов и удалён из ядра с 4.12.' \
                  'tcp_tw_recycle found in the configuration — it breaks NAT clients and was removed in kernel 4.12.')"
        say "  $(T 'Рекомендуется убрать эту строку вручную.' 'Removing that line by hand is recommended.')"
    fi
    return 0
}

apply_tuning() {
    need_root "apply" || return 1

    if [ "$MODE" = "custom" ] && [ -f "$PARAMS_FILE" ]; then
        load_params || build_params "$PROFILE" || return 1
        info "$(T 'Используются ручные значения из' 'Using manual values from') ${PARAMS_FILE}"
    else
        build_params "$PROFILE" || return 1
    fi

    preflight_checks || { warn "$(T 'Отменено.' 'Cancelled.')"; return 1; }

    show_preview
    printf '\n'
    if ! confirm "$(T 'Применить и записать в /etc/sysctl.conf?' 'Apply and write to /etc/sysctl.conf?')" y; then
        warn "$(T 'Отменено.' 'Cancelled.')"
        return 1
    fi

    local backup
    backup="$(backup_sysctl)" || { err "$(T 'Не удалось сделать бэкап.' 'Backup failed.')"; return 1; }
    ok "$(T 'Бэкап:' 'Backup:') ${backup}"
    prune_backups

    local attempt=1 out failed k
    while :; do
        write_block || { err "$(T 'Не удалось записать файл.' 'Could not write the file.')"; return 1; }
        out="$(sysctl -p "$SYSCTL_FILE" 2>&1)"
        failed="$(printf '%s\n' "$out" | parse_failed_keys)"
        if [ -z "$failed" ] || [ "$attempt" -ge 3 ]; then
            break
        fi
        warn "$(T 'Ядро не приняло эти ключи, убираю их из конфига:' 'The kernel rejected these keys, removing them:')"
        # No pipe here: pdrop must run in this shell, not in a subshell.
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            say "    ${C_YLW}${k}${C_RESET}"
            pdrop "$k"
        done <<EOF
$failed
EOF
        attempt=$((attempt + 1))
    done

    if [ -n "$failed" ]; then
        warn "$(T 'Часть ключей осталась непринятой:' 'Some keys are still rejected:')"
        printf '%s\n' "$out" | grep -i 'sysctl:' | sed 's/^/    /'
    fi

    ok "$(T 'Параметры применены.' 'Parameters applied.')"
    apply_qdisc
    save_params
    save_config

    printf '\n'
    info "$(T 'Уже установленные TCP-соединения продолжат работать со старыми параметрами.' \
              'Already established TCP connections keep the old parameters.')"
    say "  $(T 'Чтобы изменения затронули клиентов — перезапустите сервис и переподключите клиента:' \
              'To make the change reach clients — restart the service and reconnect the client:')"
    local svc
    svc="$(detect_services | head -1)"
    [ -z "$svc" ] && svc="xray"
    say "    ${C_BOLD}systemctl restart ${svc}${C_RESET}"
    return 0
}

# ----------------------------------------------------------- custom wizard ---

wizard_custom() {
    need_root "apply --manual" || return 1

    if [ -f "$PARAMS_FILE" ] && confirm "$(T 'Взять за основу прошлые ручные значения?' 'Start from your previous manual values?')" y; then
        load_params || build_params "$PROFILE"
    else
        build_params "$PROFILE" || return 1
    fi

    title "$(T 'Ручная настройка значений' 'Manual value editing')"
    say "$(T 'Enter — принять предложенное, «-» — не задавать этот параметр вообще,' \
             'Enter — accept the suggestion, "-" — do not set this parameter at all,')"
    say "$(T 'или введите своё значение.' 'or type your own value.')"
    printf '\n'

    local keys k v cur ans drops=""
    keys="$(pkeys_list)"
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        v="$(pget "$k")"
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && cur="—"
        hr
        say "${C_BOLD}${k}${C_RESET}"
        dim "  $(param_desc "$k")"
        say "  $(T 'сейчас' 'current'): ${cur}"
        printf '  %s ' "$(T 'значение' 'value') ${C_DIM}[${v}]${C_RESET}:"
        _read ans || ans=""
        if [ "$ans" = "-" ]; then
            drops="${drops}${k}
"
            warn "  $(T 'параметр не будет записан' 'parameter will not be written')"
        elif [ -n "$ans" ]; then
            pdrop "$k"; pset "$k" "$ans"
        fi
    done <<EOF
$keys
EOF

    while IFS= read -r k; do
        [ -n "$k" ] && pdrop "$k"
    done <<EOF
$drops
EOF

    MODE="custom"
    save_params
    hr
    show_preview
    printf '\n'
    if confirm "$(T 'Применить эти значения?' 'Apply these values?')" y; then
        ASSUME_YES=1
        apply_tuning
        ASSUME_YES=0
    else
        warn "$(T 'Значения сохранены, но не применены.' 'Values saved but not applied.')"
        say "  $(T 'Применить позже:' 'Apply later:') ${CMD_NAME} apply"
    fi
}

# ------------------------------------------------------------------ status ---

cmd_status() {
    local ram profile ifc qd cc

    ram="$(detect_ram_mb)"
    profile="${PROFILE:-$(profile_for_ram "$ram")}"
    ifc="$(default_iface)"

    title "$(T 'Система' 'System')"
    printf '  %-26s %s\n' "$(T 'ОС' 'OS')"          "$(os_pretty)"
    printf '  %-26s %s\n' "$(T 'Ядро' 'Kernel')"    "$(uname -r)"
    printf '  %-26s %s\n' "$(T 'Виртуализация' 'Virtualisation')" "$(detect_virt)"
    printf '  %-26s %s MB\n' "RAM"                  "$ram"
    printf '  %-26s %s\n' "$(T 'Интерфейс' 'Interface')" "${ifc:-—}"
    printf '  %-26s %s\n' "$(T 'Профиль по RAM' 'Profile by RAM')" "$profile"

    if [ -f "$CONF_FILE" ]; then
        local applied_at applied_ver applied_mode
        applied_at="$(grep '^APPLIED_AT=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        applied_ver="$(grep '^APPLIED_VERSION=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        applied_mode="$(grep '^MODE=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        printf '  %-26s %s\n' "$(T 'Применено' 'Applied')" "${applied_at:-—} (v${applied_ver:-?}, ${applied_mode:-auto})"
    fi

    title "$(T 'Блок в /etc/sysctl.conf' 'Managed block in /etc/sysctl.conf')"
    if grep -qF "$BLOCK_START" "$SYSCTL_FILE" 2>/dev/null; then
        ok "$(T 'блок найден' 'block present')"
    else
        warn "$(T 'блок не найден — тюнинг ещё не применялся' 'block not found — tuning has not been applied yet')"
    fi

    title "$(T 'Текущие значения ядра' 'Current kernel values')"
    local keys
    if [ -f "$PARAMS_FILE" ] && load_params; then :; else build_params "$profile"; fi
    keys="$(pkeys_list)"
    printf '  %-38s %-24s %s\n' "$(T 'Параметр' 'Parameter')" "$(T 'Сейчас' 'Current')" "$(T 'Ожидается' 'Expected')"
    hr
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        local want cur mark
        want="$(pget "$k")"
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && cur="n/a"
        if [ "$cur" = "$want" ]; then mark="${C_GRN}✓${C_RESET}"; else mark="${C_YLW}≠${C_RESET}"; fi
        printf '%s %-38s %-24s %s\n' "$mark" "$k" "$cur" "$want"
    done <<EOF
$keys
EOF

    title "$(T 'qdisc на интерфейсе' 'qdisc on the interface')"
    if [ -n "$ifc" ] && has_cmd tc; then
        qd="$(tc qdisc show dev "$ifc" 2>/dev/null | head -1)"
        say "  ${qd:-—}"
        case "$qd" in
            *pfifo_fast*) warn "  $(T 'Всё ещё pfifo_fast — примените тюнинг или перезагрузите сервер.' \
                                      'Still pfifo_fast — apply the tuning or reboot the server.')" ;;
        esac
    else
        say "  —"
    fi

    cc="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
    title "$(T 'Доступные алгоритмы' 'Available algorithms')"
    say "  ${cc:-—}"

    title "Swap"
    if has_cmd swapon && [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        swapon --show 2>/dev/null | sed 's/^/  /'
    else
        warn "  $(T 'swap отсутствует' 'no swap configured')"
        [ "$ram" -lt 1536 ] && say "  $(T 'На 1 ГБ RAM без swap падение сервиса — вопрос времени (пункт меню 5).' \
                                          'On 1 GB RAM without swap an OOM kill is only a matter of time (menu item 5).')"
    fi
}

# --------------------------------------------------------- A/B experiments ---

ab_set() {
    local k="$1" v="$2"
    if sysctl -w "$k=$v" >/dev/null 2>&1; then
        ok "${k} = ${v} $(T '(на лету, до перезагрузки)' '(runtime only, until reboot)')"
    else
        err "$(T 'Не удалось установить' 'Failed to set') ${k}"
    fi
}

menu_ab() {
    need_root "ab" || return 1
    while :; do
        title "$(T 'A/B-эксперименты (без записи в файл)' 'A/B experiments (nothing is written to disk)')"
        say "$(T 'Значения применяются на лету и сбросятся при перезагрузке.' \
                 'Values are applied at runtime and reset on reboot.')"
        say "$(T 'Схема: применить → перезапустить Xray → переподключить клиента → замерить.' \
                 'Routine: apply → restart Xray → reconnect the client → measure.')"
        printf '\n'
        printf '  %-30s %s\n' "$(T 'алгоритм' 'congestion')" "$(sysctl_get net.ipv4.tcp_congestion_control)"
        printf '  %-30s %s\n' "qdisc"                        "$(sysctl_get net.core.default_qdisc)"
        printf '  %-30s %s\n' "tcp_notsent_lowat"            "$(sysctl_get net.ipv4.tcp_notsent_lowat)"
        printf '  %-30s %s\n' "tcp_mtu_probing"              "$(sysctl_get net.ipv4.tcp_mtu_probing)"
        printf '\n'
        say "  ${C_BOLD}1)${C_RESET} fq_codel $(T 'вместо' 'instead of') fq   $(T '— если pacing конфликтует с сетевухой VPS' '— if pacing conflicts with the VPS NIC')"
        say "  ${C_BOLD}2)${C_RESET} fq        $(T 'обратно' 'back')"
        say "  ${C_BOLD}3)${C_RESET} cubic $(T 'вместо' 'instead of') bbr      $(T '— если у провайдера шейпер/полисер' '— if the provider shapes or polices traffic')"
        say "  ${C_BOLD}4)${C_RESET} bbr       $(T 'обратно' 'back')"
        say "  ${C_BOLD}5)${C_RESET} tcp_notsent_lowat = 131072  $(T '(умеренно против bufferbloat)' '(moderate anti-bufferbloat)')"
        say "  ${C_BOLD}6)${C_RESET} tcp_notsent_lowat = 262144  $(T '(мягче)' '(gentler)')"
        say "  ${C_BOLD}7)${C_RESET} tcp_notsent_lowat = 32768   $(T '(агрессивно, может срезать пик)' '(aggressive, may cut peak speed)')"
        say "  ${C_BOLD}8)${C_RESET} tcp_notsent_lowat $(T 'вернуть дефолт ядра' 'restore kernel default')"
        say "  ${C_BOLD}9)${C_RESET} tcp_mtu_probing = 1         $(T '(если крупные передачи зависают)' '(if large transfers stall)')"
        say "  ${C_BOLD}10)${C_RESET} $(T 'Закрепить текущие значения в /etc/sysctl.conf' 'Persist current values into /etc/sysctl.conf')"
        say "  ${C_BOLD}0)${C_RESET} $(T 'Назад' 'Back')"
        printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
        local c ifc; _read c || c=""
        ifc="$(default_iface)"
        case "$c" in
            1) ab_set net.core.default_qdisc fq_codel
               [ -n "$ifc" ] && has_cmd tc && tc qdisc replace dev "$ifc" root fq_codel 2>/dev/null && ok "tc: fq_codel → $ifc" ;;
            2) ab_set net.core.default_qdisc fq
               [ -n "$ifc" ] && has_cmd tc && tc qdisc replace dev "$ifc" root fq 2>/dev/null && ok "tc: fq → $ifc" ;;
            3) ab_set net.ipv4.tcp_congestion_control cubic ;;
            4) ab_set net.ipv4.tcp_congestion_control bbr ;;
            5) ab_set net.ipv4.tcp_notsent_lowat 131072 ;;
            6) ab_set net.ipv4.tcp_notsent_lowat 262144 ;;
            7) ab_set net.ipv4.tcp_notsent_lowat 32768 ;;
            8) ab_set net.ipv4.tcp_notsent_lowat 4294967295 ;;
            9) ab_set net.ipv4.tcp_mtu_probing 1 ;;
            10) ab_persist ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')" ;;
        esac
        pause
    done
}

ab_persist() {
    if [ -f "$PARAMS_FILE" ] && load_params; then :; else build_params "$PROFILE" || return 1; fi
    local k v cur
    for k in net.core.default_qdisc net.ipv4.tcp_congestion_control \
             net.ipv4.tcp_notsent_lowat net.ipv4.tcp_mtu_probing; do
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && continue
        case "$k" in
            net.ipv4.tcp_notsent_lowat) [ "$cur" = "4294967295" ] && { pdrop "$k"; continue; } ;;
            net.ipv4.tcp_mtu_probing)   [ "$cur" = "0" ] && { pdrop "$k"; continue; } ;;
        esac
        v="$(pget "$k" 2>/dev/null)" || v=""
        [ -n "$v" ] && pdrop "$k"
        pset "$k" "$cur"
    done
    MODE="custom"
    save_params
    ASSUME_YES=1; apply_tuning; ASSUME_YES=0
}

# -------------------------------------------------------------------- swap ---

menu_swap() {
    need_root "swap" || return 1
    title "Swap"
    free -h 2>/dev/null | sed 's/^/  /'
    printf '\n'
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        ok "$(T 'swap уже настроен:' 'swap is already configured:')"
        swapon --show 2>/dev/null | sed 's/^/  /'
        confirm "$(T 'Всё равно создать ещё один swap-файл?' 'Create an additional swap file anyway?')" n || return 0
    else
        warn "$(T 'swap отсутствует.' 'No swap configured.')"
        say "  $(T 'Swap не ускоряет сервер — он не даёт OOM-killer убить Xray при кратковременном пике.' \
                  'Swap does not speed up the server — it keeps the OOM killer from killing Xray during a short spike.')"
    fi

    local ram size path
    ram="$(detect_ram_mb)"
    if [ "$ram" -lt 3072 ]; then size="2G"; else size="4G"; fi
    [ -n "$SWAP_SIZE" ] && size="$SWAP_SIZE"
    size="$(ask "$(T 'Размер swap-файла:' 'Swap file size:')" "$size")"
    path="/swapfile"
    if [ -e "$path" ]; then
        path="$(ask "$(T '/swapfile уже существует. Другой путь:' '/swapfile already exists. Another path:')" "/swapfile2")"
    fi

    confirm "$(T 'Создать' 'Create') ${path} (${size})?" y || return 0

    if ! fallocate -l "$size" "$path" 2>/dev/null; then
        warn "$(T 'fallocate не сработал, использую dd (это дольше)...' 'fallocate failed, falling back to dd (slower)...')"
        local mb
        case "$size" in
            *G|*g) mb=$(( ${size%[Gg]} * 1024 )) ;;
            *M|*m) mb="${size%[Mm]}" ;;
            *)     mb=2048 ;;
        esac
        rm -f "$path"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=progress 2>&1 | tail -2
    fi
    chmod 600 "$path"
    mkswap "$path" >/dev/null 2>&1 || { err "mkswap failed"; rm -f "$path"; return 1; }
    swapon "$path" || { err "swapon failed"; rm -f "$path"; return 1; }

    if ! grep -qs "^${path} " /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.bak-$(date '+%Y-%m-%d-%H%M%S')" 2>/dev/null
        printf '%s none swap sw 0 0\n' "$path" >> /etc/fstab
        ok "$(T 'запись добавлена в /etc/fstab' 'entry added to /etc/fstab')"
    fi

    ok "$(T 'swap подключён' 'swap enabled')"
    swapon --show 2>/dev/null | sed 's/^/  /'
    free -h 2>/dev/null | sed 's/^/  /'
}

# ---------------------------------------------------------------- FD limits ---

detect_services() {
    systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^(xray|sing-box|singbox|x-ui|3x-ui|remnanode|remnawave.*|hysteria.*|marzban.*)\.service$' \
        | sort -u
}

service_nofile() {
    local svc="$1" pid out
    pid="$(systemctl show -p MainPID --value "$svc" 2>/dev/null)"
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        printf '%s' "$(T '— (не запущен)' '— (not running)')"
        return
    fi
    out="$(awk '/Max open files/ {print $4" / "$5; exit}' "/proc/${pid}/limits" 2>/dev/null)"
    printf '%s' "${out:-—}"
}

menu_limits() {
    need_root "limits" || return 1
    title "$(T 'Лимиты файловых дескрипторов' 'File descriptor limits')"
    say "$(T 'Каждое клиентское соединение — минимум один дескриптор. Дефолт 1024 исчерпывается' \
             'Every client connection is at least one descriptor. The 1024 default runs out')"
    say "$(T 'на десятках активных клиентов, в логах появляется «too many open files».' \
             'at a few dozen active clients, and the log fills with "too many open files".')"
    printf '\n'

    local svcs svc
    svcs="$(detect_services)"
    if [ -n "$svcs" ]; then
        say "$(T 'Найденные сервисы:' 'Services found:')"
        printf '%s\n' "$svcs" | while IFS= read -r s; do
            [ -n "$s" ] && printf '  %-24s nofile: %s\n' "$s" "$(service_nofile "$s")"
        done
        printf '\n'
    else
        warn "$(T 'Известные сервисы не найдены.' 'No known services found.')"
    fi

    local svc_default="$SERVICE_ARG"
    [ -z "$svc_default" ] && svc_default="$(printf '%s' "$svcs" | head -1)"
    svc="$(ask "$(T 'Имя сервиса (пусто — пропустить):' 'Service name (empty — skip):')" "$svc_default")"

    if [ -n "$svc" ]; then
        case "$svc" in *.service) : ;; *) svc="${svc}.service" ;; esac
        if ! systemctl cat "$svc" >/dev/null 2>&1; then
            err "$(T 'Сервис не найден:' 'Service not found:') $svc"
        else
            local dir="/etc/systemd/system/${svc}.d"
            mkdir -p "$dir"
            cat > "${dir}/override.conf" <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
            ok "$(T 'Создан override:' 'Override created:') ${dir}/override.conf"
            systemctl daemon-reload
            if confirm "$(T 'Перезапустить' 'Restart') ${svc}? $(T '(клиенты кратковременно отвалятся)' '(clients will briefly disconnect)')" n; then
                systemctl restart "$svc" && ok "$(T 'перезапущен' 'restarted')"
                sleep 1
                say "  nofile: $(service_nofile "$svc")"
            else
                warn "$(T 'Лимит вступит в силу после перезапуска сервиса.' 'The limit takes effect after the service restarts.')"
            fi
        fi
    fi

    printf '\n'
    if confirm "$(T 'Прописать также системный лимит в /etc/security/limits.conf?' 'Also write the system limit into /etc/security/limits.conf?')" y; then
        cp -a "$LIMITS_FILE" "${LIMITS_FILE}.bak-$(date '+%Y-%m-%d-%H%M%S')" 2>/dev/null
        strip_managed_block "$LIMITS_FILE"
        {
            printf '\n%s\n' "$BLOCK_START"
            printf '* soft nofile 1048576\n'
            printf '* hard nofile 1048576\n'
            printf 'root soft nofile 1048576\n'
            printf 'root hard nofile 1048576\n'
            printf '%s\n' "$BLOCK_END"
        } >> "$LIMITS_FILE"
        ok "$(T 'limits.conf обновлён (действует на интерактивные сессии, не на systemd-сервисы)' \
                'limits.conf updated (applies to interactive sessions, not to systemd services)')"
    fi

    if has_cmd docker; then
        printf '\n'
        info "$(T 'Если нода запущена в Docker, лимиты из limits.conf контейнер не увидит. В docker-compose.yml:' \
                  'If the node runs in Docker, limits.conf does not reach the container. In docker-compose.yml:')"
        cat <<'EOF'
    services:
      remnanode:
        ulimits:
          nofile:
            soft: 1048576
            hard: 1048576
EOF
    fi
}

# ------------------------------------------------------------- diagnostics ---

diag_conflicts() {
    title "$(T 'Кто ещё задаёт те же ключи' 'Who else sets the same keys')"
    local hits
    hits="$(grep -RIn -E 'tcp_congestion_control|default_qdisc|rmem|wmem|somaxconn|syn_backlog|notsent_lowat|slow_start|netdev_max_backlog' \
        /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ 2>/dev/null | grep -v 'vpn-node-tuner')"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | sed 's/^/  /'
        printf '\n'
        info "$(T '/etc/sysctl.conf читается последним при sysctl --system, поэтому перекроет эти файлы.' \
                  '/etc/sysctl.conf is read last by sysctl --system, so it overrides these files.')"
    else
        ok "$(T 'конфликтов в /etc/sysctl.d/ не найдено' 'no conflicts found in /etc/sysctl.d/')"
    fi
}

diag_malformed() {
    title "$(T 'Слипшиеся строки в /etc/sysctl.conf' 'Malformed lines in /etc/sysctl.conf')"
    local hits
    hits="$(grep -n -E '^[^#]*[^[:space:]]+[[:space:]]*#' "$SYSCTL_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
        warn "$(T 'Комментарий в той же строке, что и параметр, — частая причина «молча не применилось»:' \
                  'A comment on the same line as a parameter is a common cause of silent failures:')"
        printf '%s\n' "$hits" | sed 's/^/  /'
    else
        ok "$(T 'проблемных строк не найдено' 'no problematic lines found')"
    fi
}

diag_sockets() {
    title "$(T 'Живые сокеты' 'Live sockets')"
    if ! has_cmd ss; then warn "ss not found"; return; fi
    say "$(T 'Прогоните трафик через VPN, затем смотрите на bbr / rtt / cwnd:' \
             'Push traffic through the VPN, then look for bbr / rtt / cwnd:')"
    ss -tin state established 2>/dev/null | head -30 | sed 's/^/  /'
    printf '\n'
    local n
    n="$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    say "  $(T 'Установленных TCP-соединений:' 'Established TCP connections:') ${C_BOLD}${n}${C_RESET}"
}

diag_memory() {
    title "$(T 'Память' 'Memory')"
    free -h 2>/dev/null | sed 's/^/  /'
    printf '\n'
    say "  ${C_DIM}/proc/net/sockstat — TCP mem $(T 'в страницах по 4 КБ' 'in 4 KB pages')${C_RESET}"
    cat /proc/net/sockstat 2>/dev/null | sed 's/^/  /'
    printf '\n'
    local oom
    oom="$(dmesg -T 2>/dev/null | grep -i -E 'oom|killed process' | tail -5)"
    if [ -n "$oom" ]; then
        err "$(T 'В dmesg есть следы OOM-killer:' 'OOM killer traces found in dmesg:')"
        printf '%s\n' "$oom" | sed 's/^/  /'
        printf '\n'
        say "  $(T 'Снизьте максимум буферов (профиль ниже) и убедитесь, что есть swap.' \
                  'Lower the buffer maximum (a smaller profile) and make sure swap exists.')"
    else
        ok "$(T 'следов OOM-killer нет' 'no OOM killer traces')"
    fi
}

menu_diag() {
    while :; do
        title "$(T 'Диагностика' 'Diagnostics')"
        say "  ${C_BOLD}1)${C_RESET} $(T 'Полная проверка' 'Full check')"
        say "  ${C_BOLD}2)${C_RESET} $(T 'Конфликты в /etc/sysctl.d/' 'Conflicts in /etc/sysctl.d/')"
        say "  ${C_BOLD}3)${C_RESET} $(T 'Слипшиеся строки в sysctl.conf' 'Malformed lines in sysctl.conf')"
        say "  ${C_BOLD}4)${C_RESET} $(T 'Живые сокеты (bbr / rtt / cwnd)' 'Live sockets (bbr / rtt / cwnd)')"
        say "  ${C_BOLD}5)${C_RESET} $(T 'Память, TCP-буферы, OOM' 'Memory, TCP buffers, OOM')"
        say "  ${C_BOLD}6)${C_RESET} $(T 'Перечитать sysctl (sysctl -p) и показать ошибки' 'Re-read sysctl (sysctl -p) and show errors')"
        say "  ${C_BOLD}0)${C_RESET} $(T 'Назад' 'Back')"
        printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
        local c; _read c || c=""
        case "$c" in
            1) cmd_status; diag_conflicts; diag_malformed; diag_memory ;;
            2) diag_conflicts ;;
            3) diag_malformed ;;
            4) diag_sockets ;;
            5) diag_memory ;;
            6) title "sysctl -p"; sysctl -p "$SYSCTL_FILE" 2>&1 | sed 's/^/  /' ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')" ;;
        esac
        pause
    done
}

# ------------------------------------------------------ backups and restore ---

menu_backups() {
    need_root "restore" || return 1
    while :; do
        title "$(T 'Бэкапы и откат' 'Backups and rollback')"
        local list n=0
        list="$(list_backups)"
        if [ -z "$list" ]; then
            warn "$(T 'Бэкапов нет.' 'No backups yet.')"
        else
            printf '%s\n' "$list" | while IFS= read -r f; do
                [ -n "$f" ] && printf '  %s  %s\n' "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%16s' '')" "$f"
            done
        fi
        printf '\n'
        say "  ${C_BOLD}1)${C_RESET} $(T 'Восстановить из бэкапа' 'Restore from a backup')"
        say "  ${C_BOLD}2)${C_RESET} $(T 'Удалить только блок vpn-node-tuner' 'Remove only the vpn-node-tuner block')"
        say "  ${C_BOLD}3)${C_RESET} $(T 'Показать текущий блок' 'Show the current block')"
        say "  ${C_BOLD}0)${C_RESET} $(T 'Назад' 'Back')"
        printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
        local c; _read c || c=""
        case "$c" in
            1)
                [ -z "$list" ] && { warn "$(T 'Нечего восстанавливать.' 'Nothing to restore.')"; pause; continue; }
                local f
                f="$(ask "$(T 'Путь к бэкапу:' 'Backup path:')" "$(printf '%s' "$list" | head -1)")"
                if [ -f "$f" ]; then
                    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.before-restore-$(date '+%Y-%m-%d-%H%M%S')"
                    cp -a "$f" "$SYSCTL_FILE" && ok "$(T 'Восстановлено из' 'Restored from') $f"
                    sysctl --system 2>&1 | grep -i 'sysctl:' | sed 's/^/  /'
                    warn "$(T 'Для гарантированного сброса qdisc перезагрузите сервер: reboot' \
                              'Reboot the server to reset qdisc reliably: reboot')"
                else
                    err "$(T 'Файл не найден.' 'File not found.')"
                fi
                ;;
            2)
                cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak-$(date '+%Y-%m-%d-%H%M%S')"
                strip_managed_block "$SYSCTL_FILE"
                ok "$(T 'Блок удалён. Значения ядра останутся до перезагрузки.' \
                        'Block removed. Kernel values persist until reboot.')"
                ;;
            3)
                title "$(T 'Текущий блок' 'Current block')"
                awk -v s="$BLOCK_START" -v e="$BLOCK_END" \
                    'index($0,s){f=1} f{print "  " $0} index($0,e){f=0}' "$SYSCTL_FILE" 2>/dev/null
                ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')" ;;
        esac
        pause
    done
}

# --------------------------------------------------------------- baselines ---

baseline_snapshot() {
    mkdir -p "$STATE_DIR"
    local f="${STATE_DIR}/baseline-$(date '+%Y-%m-%d-%H%M%S').txt"
    {
        printf '# vpn-node-tuner baseline %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# %s | kernel %s | RAM %s MB\n\n' "$(os_pretty)" "$(uname -r)" "$(detect_ram_mb)"
        local k
        for k in net.ipv4.tcp_congestion_control net.core.default_qdisc \
                 net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
                 net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_notsent_lowat \
                 net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog \
                 net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
                 vm.swappiness vm.vfs_cache_pressure; do
            printf '%s = %s\n' "$k" "$(sysctl_get "$k")"
        done
        printf '\n# free -h\n'; free -h 2>/dev/null
        printf '\n# sockstat\n'; cat /proc/net/sockstat 2>/dev/null
        printf '\n# qdisc\n'; tc qdisc show dev "$(default_iface)" 2>/dev/null
    } > "$f"
    ok "$(T 'Снимок сохранён:' 'Snapshot saved:') $f"
}

menu_baseline() {
    while :; do
        title "$(T 'Замеры' 'Measurements')"
        say "$(T 'Тюнинг без замера «до» бесполезен — вы не отличите улучшение от совпадения.' \
                 'Tuning without a "before" measurement is pointless — you cannot tell improvement from coincidence.')"
        printf '\n'
        say "  ${C_BOLD}1)${C_RESET} $(T 'Снять снимок состояния ядра (baseline)' 'Take a kernel state snapshot (baseline)')"
        say "  ${C_BOLD}2)${C_RESET} $(T 'Сравнить с последним снимком' 'Compare with the last snapshot')"
        say "  ${C_BOLD}3)${C_RESET} $(T 'Команды для замеров с клиента' 'Client-side measurement commands')"
        say "  ${C_BOLD}0)${C_RESET} $(T 'Назад' 'Back')"
        printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
        local c; _read c || c=""
        case "$c" in
            1) need_root "baseline" && baseline_snapshot ;;
            2)
                local last cur
                last="$(ls -1t "${STATE_DIR}"/baseline-*.txt 2>/dev/null | head -1)"
                if [ -z "$last" ]; then
                    warn "$(T 'Снимков нет — сначала пункт 1.' 'No snapshots yet — use item 1 first.')"
                else
                    cur="$(mktemp)"
                    baseline_snapshot >/dev/null 2>&1
                    local new
                    new="$(ls -1t "${STATE_DIR}"/baseline-*.txt 2>/dev/null | head -1)"
                    title "$(T 'Отличия' 'Differences')"
                    diff -u "$last" "$new" | grep -E '^[+-]' | grep -v '^[+-][+-]' | sed 's/^/  /'
                    rm -f "$cur"
                fi
                ;;
            3)
                title "$(T 'Запускать с клиента, не на сервере' 'Run from the client, not on the server')"
                cat <<EOF
  # $(T 'Задержка: серия, а не одно число. Важен mdev — это и есть «заикания».' \
        'Latency: a series, not a single number. mdev is what you feel as stutter.')
  ping -c 100 SERVER_IP | tail -3

  # $(T 'Маршрут и потери по хопам' 'Route and per-hop loss')
  mtr -rwzbc 100 SERVER_IP

  # $(T 'Пропускная способность (iperf3 -s на сервере, закройте порт после теста)' \
        'Throughput (iperf3 -s on the server, close the port after the test)')
  iperf3 -c SERVER_IP -p 5201 -P 8 -t 20

  # Bufferbloat: waveform.com/tools/bufferbloat  ($(T 'цель — A или A+' 'target — A or A+'))
EOF
                ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')" ;;
        esac
        pause
    done
}

# ------------------------------------------------- install/update/uninstall ---

cmd_install() {
    need_root "install" || return 1
    local src="$0"
    if [ "$(readlink -f "$src" 2>/dev/null)" = "$INSTALL_PATH" ]; then
        ok "$(T 'Уже установлено:' 'Already installed:') ${INSTALL_PATH}"
        say "$(T 'Обновление:' 'To update:') ${C_BOLD}${CMD_NAME} update${C_RESET}"
        return 0
    fi
    if [ ! -f "$src" ] || [ ! -r "$src" ]; then
        # Started via `bash <(curl ...)`: $0 is a pipe, fetch a real copy.
        src="$(mktemp)"
        info "$(T 'Скачиваю скрипт...' 'Downloading the script...')"
        curl -fsSL "$RAW_URL" -o "$src" || { err "$(T 'Не удалось скачать.' 'Download failed.')"; return 1; }
    fi
    install -m 0755 "$src" "$INSTALL_PATH" || { err "$(T 'Не удалось установить.' 'Install failed.')"; return 1; }
    mkdir -p "$CONF_DIR" "$STATE_DIR"
    save_config
    ok "$(T 'Установлено:' 'Installed:') ${INSTALL_PATH}"
    say "$(T 'Теперь просто наберите:' 'Now just type:') ${C_BOLD}${CMD_NAME}${C_RESET}"
}

cmd_uninstall() {
    need_root "uninstall" || return 1
    title "$(T 'Удаление' 'Uninstall')"
    if confirm "$(T 'Убрать блок из /etc/sysctl.conf?' 'Remove the block from /etc/sysctl.conf?')" y; then
        cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak-$(date '+%Y-%m-%d-%H%M%S')" 2>/dev/null
        strip_managed_block "$SYSCTL_FILE"
        ok "$(T 'блок удалён' 'block removed')"
    fi
    if confirm "$(T 'Удалить конфиг и снимки?' 'Delete the config and snapshots?')" n; then
        rm -rf "$CONF_DIR" "$STATE_DIR"
        ok "$(T 'удалено' 'deleted')"
    fi
    if confirm "$(T 'Удалить сам скрипт' 'Remove the script itself') (${INSTALL_PATH})?" y; then
        rm -f "$INSTALL_PATH"
        ok "$(T 'удалено' 'deleted')"
    fi
    warn "$(T 'Значения ядра остаются активными до перезагрузки.' 'Kernel values stay active until reboot.')"
}

cmd_update() {
    need_root "update" || return 1
    local tmp remote
    tmp="$(mktemp)"
    info "$(T 'Проверяю обновления...' 'Checking for updates...')"
    curl -fsSL "$RAW_URL" -o "$tmp" || { err "$(T 'Не удалось скачать.' 'Download failed.')"; rm -f "$tmp"; return 1; }
    remote="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
    if [ -z "$remote" ]; then
        err "$(T 'Не удалось определить версию в скачанном файле.' 'Could not read the version from the downloaded file.')"
        rm -f "$tmp"; return 1
    fi
    say "  $(T 'установлено' 'installed'): ${SCRIPT_VERSION}"
    say "  $(T 'доступно' 'available'):   ${remote}"
    if [ "$remote" = "$SCRIPT_VERSION" ]; then
        ok "$(T 'У вас последняя версия.' 'You are on the latest version.')"
        rm -f "$tmp"; return 0
    fi
    if confirm "$(T 'Обновить?' 'Update?')" y; then
        install -m 0755 "$tmp" "$INSTALL_PATH" && ok "$(T 'Обновлено до' 'Updated to') ${remote}"
    fi
    rm -f "$tmp"
}

# ------------------------------------------------------------------- menu ---

banner() {
    printf '\n'
    say "${C_BOLD}${C_BLU}  vpn-node-tuner${C_RESET} ${C_DIM}v${SCRIPT_VERSION}${C_RESET}"
    say "${C_DIM}  $(T 'тюнинг сетевого стека для VPN-нод (Xray / sing-box / 3X-UI / Remnawave)' \
                       'network stack tuning for VPN nodes (Xray / sing-box / 3X-UI / Remnawave)')${C_RESET}"
    hr
    local ram profile applied
    ram="$(detect_ram_mb)"
    profile="${PROFILE:-$(profile_for_ram "$ram")}"
    if grep -qsF "$BLOCK_START" "$SYSCTL_FILE" 2>/dev/null; then
        applied="${C_GRN}$(T 'применён' 'applied')${C_RESET}"
    else
        applied="${C_YLW}$(T 'не применён' 'not applied')${C_RESET}"
    fi
    printf '  RAM: %s MB   %s: %s   %s: %s\n' \
        "$ram" "$(T 'профиль' 'profile')" "${C_BOLD}${profile}${C_RESET}" \
        "$(T 'тюнинг' 'tuning')" "$applied"
    hr
}

main_menu() {
    while :; do
        clear 2>/dev/null || true
        banner
        say "  ${C_BOLD}1)${C_RESET}  $(T 'Статус — что применено сейчас' 'Status — what is applied right now')"
        say "  ${C_BOLD}2)${C_RESET}  $(T 'Применить тюнинг (автопрофиль по RAM)' 'Apply tuning (profile auto-detected by RAM)')"
        say "  ${C_BOLD}3)${C_RESET}  $(T 'Применить тюнинг (ручные значения)' 'Apply tuning (manual values)')"
        say "  ${C_BOLD}4)${C_RESET}  $(T 'A/B-эксперименты (на лету, без записи)' 'A/B experiments (runtime, nothing written)')"
        say "  ${C_BOLD}5)${C_RESET}  $(T 'Swap' 'Swap')"
        say "  ${C_BOLD}6)${C_RESET}  $(T 'Лимиты файловых дескрипторов' 'File descriptor limits')"
        say "  ${C_BOLD}7)${C_RESET}  $(T 'Диагностика' 'Diagnostics')"
        say "  ${C_BOLD}8)${C_RESET}  $(T 'Бэкапы и откат' 'Backups and rollback')"
        say "  ${C_BOLD}9)${C_RESET}  $(T 'Замеры' 'Measurements')"
        say "  ${C_BOLD}10)${C_RESET} $(T 'Выбрать профиль вручную' 'Choose the profile manually')"
        say "  ${C_BOLD}11)${C_RESET} $(T 'Язык / Language' 'Language / Язык')"
        say "  ${C_BOLD}12)${C_RESET} $(T 'Обновить скрипт' 'Update the script')"
        say "  ${C_BOLD}0)${C_RESET}  $(T 'Выход' 'Exit')"
        printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
        local c; _read c || c=""
        case "$c" in
            1)  cmd_status; pause ;;
            2)  MODE="auto"; apply_tuning; pause ;;
            3)  wizard_custom; pause ;;
            4)  menu_ab ;;
            5)  menu_swap; pause ;;
            6)  menu_limits; pause ;;
            7)  menu_diag ;;
            8)  menu_backups ;;
            9)  menu_baseline ;;
            10) choose_profile; pause ;;
            11) choose_language ;;
            12) cmd_update; pause ;;
            0|q|exit) printf '\n'; exit 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1 ;;
        esac
    done
}

choose_profile() {
    title "$(T 'Профиль' 'Profile')"
    printf '  %-6s %-12s %-12s %s\n' "" "RAM" "$(T 'буферы' 'buffers')" "somaxconn"
    say "  ${C_BOLD}1)${C_RESET} 1g    < 1.5 GB     16 MB        4096"
    say "  ${C_BOLD}2)${C_RESET} 2g    1.5–3 GB     16 MB        8192"
    say "  ${C_BOLD}3)${C_RESET} 4g    3–6 GB       32 MB        16384"
    say "  ${C_BOLD}4)${C_RESET} 8g    > 6 GB       64 MB        32768"
    say "  ${C_BOLD}0)${C_RESET} $(T 'авто (по RAM)' 'auto (by RAM)')"
    printf '\n%s ' "$(T 'Выбор:' 'Choice:')"
    local c; _read c || c=""
    case "$c" in
        1) PROFILE="1g" ;;
        2) PROFILE="2g" ;;
        3) PROFILE="4g" ;;
        4) PROFILE="8g" ;;
        *) PROFILE="$(profile_for_ram "$(detect_ram_mb)")" ;;
    esac
    MODE="auto"
    save_config
    ok "$(T 'Профиль:' 'Profile:') ${PROFILE}"
}

# ------------------------------------------------------------------- main ---

usage() {
    cat <<EOF
vpn-node-tuner ${SCRIPT_VERSION} — https://github.com/${REPO_SLUG}

$(T 'ИСПОЛЬЗОВАНИЕ' 'USAGE')
  ${CMD_NAME}                        $(T 'интерактивное меню' 'interactive menu')
  ${CMD_NAME} <$(T 'команда' 'command')> [$(T 'опции' 'options')]

$(T 'КОМАНДЫ' 'COMMANDS')
  install                    $(T 'установить как команду' 'install as a system command') ${CMD_NAME}
  apply                      $(T 'применить тюнинг' 'apply the tuning')
  status                     $(T 'показать текущее состояние' 'show the current state')
  check                      $(T 'диагностика: конфликты, ошибки, память' 'diagnostics: conflicts, errors, memory')
  swap                       $(T 'настроить swap' 'configure swap')
  limits                     $(T 'лимиты файловых дескрипторов' 'file descriptor limits')
  baseline                   $(T 'снять снимок состояния ядра' 'take a kernel state snapshot')
  restore                    $(T 'откат из бэкапа' 'roll back from a backup')
  update                     $(T 'обновить скрипт' 'update the script')
  uninstall                  $(T 'удалить' 'remove')

$(T 'ОПЦИИ' 'OPTIONS')
  --profile 1g|2g|4g|8g      $(T 'профиль вместо автоопределения' 'profile instead of auto-detection')
  --yes, -y                  $(T 'не задавать вопросов' 'do not ask questions')
  --lang ru|en               $(T 'язык вывода' 'output language')
  --size <2G>                $(T 'размер swap-файла (для swap)' 'swap file size (for swap)')
  --service <name>           $(T 'имя сервиса (для limits)' 'service name (for limits)')
  --version, -v              $(T 'версия' 'version')
  --help, -h                 $(T 'эта справка' 'this help')

$(T 'ПРИМЕРЫ' 'EXAMPLES')
  bash <(curl -Ls https://github.com/${REPO_SLUG}/raw/main/vpn-node-tuner.sh) @ install
  ${CMD_NAME} apply --profile 2g --yes
  ${CMD_NAME} status
EOF
}

main() {
    # DigneZzZ-style argument marker for `bash <(curl ...) @ install`
    if [ "${1:-}" = "@" ]; then shift; fi

    load_config || true

    local cmd=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) PROFILE="${2:-}"; shift 2 ;;
            --lang)    LANG_CODE="${2:-}"; shift 2 ;;
            --size)    SWAP_SIZE="${2:-}"; shift 2 ;;
            --service) SERVICE_ARG="${2:-}"; shift 2 ;;
            -y|--yes)  ASSUME_YES=1; shift ;;
            -f|--force) ASSUME_YES=1; shift ;;
            -v|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help) LANG_CODE="${LANG_CODE:-ru}"; usage; exit 0 ;;
            -*) err "Unknown option: $1"; exit 1 ;;
            *) [ -z "$cmd" ] && cmd="$1"; shift ;;
        esac
    done

    if [ ! -r /proc/meminfo ]; then
        LANG_CODE="${LANG_CODE:-en}"
        die "$(T 'Этот скрипт работает только на Linux.' 'This script only runs on Linux.')"
    fi

    if [ -z "$LANG_CODE" ]; then
        if [ -t 0 ] && [ -z "$cmd" ]; then
            choose_language
        else
            LANG_CODE="ru"
        fi
    fi

    [ -z "$PROFILE" ] && PROFILE="$(profile_for_ram "$(detect_ram_mb)")"

    case "$cmd" in
        "")         [ -t 0 ] || { usage; exit 0; }; main_menu ;;
        install)    cmd_install ;;
        apply)      apply_tuning ;;
        status)     cmd_status ;;
        check)      cmd_status; diag_conflicts; diag_malformed; diag_memory ;;
        swap)       menu_swap ;;
        limits)     menu_limits ;;
        baseline)   need_root baseline && baseline_snapshot ;;
        restore)    menu_backups ;;
        update)     cmd_update ;;
        uninstall)  cmd_uninstall ;;
        menu)       main_menu ;;
        *)          err "$(T 'Неизвестная команда:' 'Unknown command:') $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
