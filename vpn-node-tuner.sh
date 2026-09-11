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

SCRIPT_VERSION="1.2.1"
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
IN_MENU=0
SWAP_SIZE=""
SERVICE_ARG=""

# ---------------------------------------------------------------- colours ---

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m';  C_MAG=$'\033[35m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED="";   C_GRN="";  C_YLW=""
    C_BLU="";   C_MAG=""
fi

# ------------------------------------------------------------------- i18n ---
# T <russian> <english>  — every user-visible string goes through this.

T() {
    if [ "$LANG_CODE" = "ru" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "💡 $*"; }
ok()   { printf '%s\n' "✅ $*"; }
warn() { printf '%s\n' "⚠️  ${C_YLW}$*${C_RESET}"; }
err()  { printf '%s\n' "❌ ${C_RED}$*${C_RESET}" >&2; }
dim()  { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
hr()   { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"; }

# pad <text> <width> — left-align by characters. printf counts bytes, which
# breaks every column that contains Cyrillic.
pad() {
    local n
    n="$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')"
    printf '%s' "$1"
    [ "$n" -lt "$2" ] && printf '%*s' $(( $2 - n )) ''
    return 0
}

# kv <label> <value> — aligned "label   value" row inside a screen.
kv() { printf '  %s%s%s %s\n' "$C_DIM" "$(pad "$1" 24)" "$C_RESET" "$2"; }

# Section title inside a screen.
title() {
    printf '\n%s\n' "${C_BOLD}$*${C_RESET}"
    hr
}

# screen <emoji + name> — top of every submenu, matching the main menu header.
screen() {
    [ "$IN_MENU" = "1" ] && { clear 2>/dev/null || true; }
    printf '\n%s\n' "${C_BOLD}⚡ VPN Node Tuner${C_RESET} ${C_DIM}v${SCRIPT_VERSION}  ›${C_RESET}  ${C_BOLD}$*${C_RESET}"
    hr
}

# choose <max> — standard prompt, the answer lands in $CHOICE.
CHOICE=""
choose() {
    printf '\n%s ' "${C_BOLD}$(T 'Выберите пункт' 'Select option') [0-$1]:${C_RESET}"
    _read CHOICE || CHOICE=""
}

# section <header>              — bold group header inside a menu
# item <num> <label> [hint]     — aligned menu line, hint is shown in purple
section() { printf '%s\n' "${C_BOLD}$*${C_RESET}"; }

item() {
    local hint=""
    [ -n "${3:-}" ] && hint=" ${C_MAG}$3${C_RESET}"
    printf '  %s %s%s\n' "${C_BOLD}$(printf '%3s' "$1)")${C_RESET}" "$2" "$hint"
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
    # /dev/tty can exist yet be unopenable (no controlling terminal) — use stdin then.
    if { true < /dev/tty; } 2>/dev/null; then
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

# Menus return BACK when the user picked "0 — Back": nothing new is on the
# screen, so the caller must not ask for an extra Enter.
BACK=10
pause_unless_back() { [ "${1:-0}" -eq "$BACK" ] || pause; }

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
    # The prompt goes to stderr: ask is always called as $(ask ...), and stdout
    # would swallow the question into the answer.
    if [ -n "$default" ]; then
        printf '%s ' "${prompt} ${C_DIM}[${default}]${C_RESET}" >&2
    else
        printf '%s ' "$prompt" >&2
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
    local dst
    dst="${SYSCTL_FILE}.bak-$(date '+%Y-%m-%d-%H%M%S')"
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
    title "🔍 $(T 'Что изменится' 'What will change')"
    printf '  %s %s %s\n' "$(pad "$(T 'Параметр' 'Parameter')" 36)" "$(pad "$(T 'Сейчас' 'Current')" 22)" "$(T 'Станет' 'New')"
    hr
    pkeys_list | while IFS= read -r k; do
        v="$(pget "$k")"
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && cur="n/a"
        if [ "$cur" = "$v" ]; then
            printf '  %-36s %-22s %s\n' "$k" "$cur" "${C_DIM}✓ $(T 'без изменений' 'unchanged')${C_RESET}"
        else
            printf '  %-36s %-22s %s\n' "$k" "$cur" "${C_GRN}→ ${v}${C_RESET}"
        fi
    done
    hr
    kv "$(T 'Файл' 'File')" "$SYSCTL_FILE"
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
    info "$(T 'Новые параметры действуют на новые соединения — клиенты получат их, когда переподключатся.' \
              'New parameters apply to new connections — clients get them when they reconnect.')"
    local rc
    rc="$(core_restart_cmd)"
    if [ -n "$rc" ]; then
        dim "   $(T 'Перевести всех сразу — перезапуск ядра (клиенты отключатся на пару секунд):' \
                   'Move everyone at once — restart the core (clients drop for a couple of seconds):')"
        say "   ${C_BOLD}${rc}${C_RESET}"
    fi
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

    screen "✏️  $(T 'Свои значения' 'Custom values')"
    kv "Enter"                          "$(T 'принять предложенное' 'accept the suggestion')"
    kv "-"                              "$(T 'не задавать параметр вообще' 'do not set the parameter at all')"
    kv "$(T 'своё значение' 'your value')" "$(T 'записать его' 'write it')"

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
    screen "📊 $(T 'Текущее состояние' 'Current state')"
    status_body
}

status_body() {
    local ram profile ifc qd cc keys k want cur mark

    ram="$(detect_ram_mb)"
    profile="${PROFILE:-$(profile_for_ram "$ram")}"
    ifc="$(default_iface)"

    title "🖥️  $(T 'Система' 'System')"
    kv "$(T 'ОС' 'OS')"                       "$(os_pretty)"
    kv "$(T 'Ядро' 'Kernel')"                 "$(uname -r)"
    kv "$(T 'Виртуализация' 'Virtualisation')" "$(detect_virt)"
    kv "RAM"                                  "${ram} MB · $(T 'профиль' 'profile') ${profile}"
    kv "$(T 'Интерфейс' 'Interface')"         "${ifc:-—}"

    title "⚙️  $(T 'Оптимизация' 'Tuning')"
    if grep -qF "$BLOCK_START" "$SYSCTL_FILE" 2>/dev/null; then
        ok "$(T 'Применена — блок в /etc/sysctl.conf на месте' 'Applied — the block in /etc/sysctl.conf is present')"
    else
        warn "$(T 'Ещё не применялась — пункт 1 главного меню' 'Not applied yet — main menu item 1')"
    fi
    if [ -f "$CONF_FILE" ]; then
        local applied_at applied_ver applied_mode
        applied_at="$(grep '^APPLIED_AT=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        applied_ver="$(grep '^APPLIED_VERSION=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        applied_mode="$(grep '^MODE=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)"
        [ -n "$applied_at" ] && kv "$(T 'Когда' 'When')" "${applied_at} · v${applied_ver:-?} · ${applied_mode:-auto}"
    fi

    title "🧮 $(T 'Параметры ядра' 'Kernel parameters')"
    if [ -f "$PARAMS_FILE" ] && load_params; then :; else build_params "$profile"; fi
    keys="$(pkeys_list)"
    printf '     %s %s %s\n' "$(pad "$(T 'Параметр' 'Parameter')" 36)" "$(pad "$(T 'Сейчас' 'Current')" 22)" "$(T 'Ожидается' 'Expected')"
    hr
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        want="$(pget "$k")"
        cur="$(sysctl_get "$k")"
        [ -z "$cur" ] && cur="n/a"
        if [ "$cur" = "$want" ]; then mark="✅"; else mark="⚠️ "; fi
        printf '  %s %-36s %-22s %s\n' "$mark" "$k" "$cur" "${C_DIM}${want}${C_RESET}"
    done <<EOF
$keys
EOF

    title "🚦 $(T 'Очередь на интерфейсе' 'Interface queue')"
    if [ -n "$ifc" ] && has_cmd tc; then
        qd="$(tc qdisc show dev "$ifc" 2>/dev/null | head -1)"
        kv "$ifc" "${qd:-—}"
        case "$qd" in
            *pfifo_fast*) warn "$(T 'Всё ещё pfifo_fast — примените оптимизацию или перезагрузите сервер.' \
                                    'Still pfifo_fast — apply the tuning or reboot the server.')" ;;
        esac
    else
        kv "$(T 'Интерфейс' 'Interface')" "—"
    fi
    cc="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
    kv "$(T 'Доступные алгоритмы' 'Available algorithms')" "${cc:-—}"

    title "💾 Swap"
    if has_cmd swapon && [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        swapon --show 2>/dev/null | sed 's/^/  /'
    else
        warn "$(T 'swap отсутствует' 'no swap configured')"
        [ "$ram" -lt 1536 ] && info "$(T 'На 1 ГБ RAM без swap падение сервиса — вопрос времени (пункт 5).' \
                                         'On 1 GB RAM without swap an OOM kill is only a matter of time (item 5).')"
    fi
    return 0
}

# --------------------------------------------------------------- test mode ---
# A/B sessions on live traffic. Values go in only through `sysctl -w` / `tc`;
# the originals are snapshotted first and a trap puts them back on Ctrl+C, a
# dropped SSH session or any exit. Nothing reaches disk unless the user keeps
# the result at the end.

TEST_DIR="${STATE_DIR}/tests"
TEST_ORIG=""
TEST_ORIG_QDISC=""
TEST_QDISC_CHANGED=0
TEST_ACTIVE=0
TPARAM_IDS="qdisc cc buf lowat idle mtu"

# detect_core — how Xray runs here: "remnanode <container>" or "systemd <unit>".
detect_core() {
    local c u
    if has_cmd docker; then
        c="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
            | awk '$2 ~ /remnawave\/node/ {print $1; exit}')"
        [ -n "$c" ] && { printf 'remnanode %s' "$c"; return 0; }
    fi
    u="$(detect_services | head -1)"
    [ -n "$u" ] && { printf 'systemd %s' "$u"; return 0; }
    return 1
}

# core_restart_cmd — the command that restarts only the Xray core. Inside
# remnanode the node itself drives Xray through s6, so we use the same knob.
core_restart_cmd() {
    local kind name
    read -r kind name <<EOF
$(detect_core)
EOF
    case "$kind" in
        remnanode) printf 'docker exec %s /command/s6-svc -r /run/service/xray' "$name" ;;
        systemd)   printf 'systemctl restart %s' "$name" ;;
    esac
}

cake_available() {
    modprobe -n -q sch_cake 2>/dev/null \
        || grep -qs '/sch_cake.ko' "/lib/modules/$(uname -r)/modules.builtin"
}

tparam_label() {
    case "$1" in
        qdisc) printf '🚦 %s' "$(T 'Очередь (qdisc)' 'Queue (qdisc)')" ;;
        cc)    printf '🧠 %s' "$(T 'Алгоритм' 'Congestion control')" ;;
        buf)   printf '📦 %s' "$(T 'Буферы (максимум)' 'Buffers (maximum)')" ;;
        lowat) printf '📉 %s' "tcp_notsent_lowat" ;;
        idle)  printf '💤 %s' "slow_start_after_idle" ;;
        mtu)   printf '📏 %s' "tcp_mtu_probing" ;;
    esac
}

tparam_values() {
    case "$1" in
        qdisc) printf 'fq fq_codel'; cake_available && printf ' cake' ;;
        cc)    printf 'bbr cubic' ;;
        buf)   printf '8388608 16777216 33554432 67108864' ;;
        lowat) printf '4294967295 16384 32768 131072 262144' ;;
        idle)  printf '0 1' ;;
        mtu)   printf '0 1 2' ;;
    esac
}

tparam_current() {
    case "$1" in
        qdisc) sysctl_get net.core.default_qdisc ;;
        cc)    sysctl_get net.ipv4.tcp_congestion_control ;;
        buf)   sysctl_get net.ipv4.tcp_rmem | awk '{print $3}' ;;
        lowat) sysctl_get net.ipv4.tcp_notsent_lowat ;;
        idle)  sysctl_get net.ipv4.tcp_slow_start_after_idle ;;
        mtu)   sysctl_get net.ipv4.tcp_mtu_probing ;;
    esac
}

# tval_human <id> <value> — "16 MB" instead of 16777216.
tval_human() {
    case "$2" in ''|*[!0-9]*) printf '%s' "${2:-—}"; return ;; esac
    case "$1" in
        buf)   printf '%s MB' $(( $2 / 1048576 )) ;;
        lowat) if [ "$2" = "4294967295" ]; then T 'дефолт' 'default'; else printf '%s KB' $(( $2 / 1024 )); fi ;;
        *)     printf '%s' "$2" ;;
    esac
}

# tval_hint <id> <value> — one short line on when this value makes sense.
tval_hint() {
    case "$1:$2" in
        qdisc:fq)         T 'пара для BBR' 'the BBR companion' ;;
        qdisc:fq_codel)   T 'если fq даёт задержку на VPS' 'if fq adds latency on a VPS' ;;
        qdisc:cake)       T 'умная очередь, больше нагрузки на CPU' 'smart queue, more CPU' ;;
        cc:bbr)           T 'лучше на каналах с потерями' 'better on lossy links' ;;
        cc:cubic)         T 'стандарт Linux' 'Linux default' ;;
        buf:8388608)      T 'экономит RAM' 'saves RAM' ;;
        buf:16777216)     T 'хватает на 1 Гбит/с при 120 мс' 'enough for 1 Gbit/s at 120 ms' ;;
        buf:33554432)     T 'для 4+ ГБ RAM' 'for 4+ GB RAM' ;;
        buf:67108864)     T 'только при большом запасе RAM' 'only with plenty of RAM' ;;
        lowat:4294967295) T 'без ограничения' 'no limit' ;;
        lowat:16384)      T 'очень агрессивно' 'very aggressive' ;;
        lowat:32768)      T 'агрессивно, может срезать пик' 'aggressive, may cut peak speed' ;;
        lowat:131072)     T 'умеренно против bufferbloat' 'moderate anti-bufferbloat' ;;
        lowat:262144)     T 'мягко' 'gentle' ;;
        idle:0)           T 'не сбрасывать скорость после паузы' 'keep speed after a pause' ;;
        idle:1)           T 'стандарт Linux' 'Linux default' ;;
        mtu:0)            T 'выключено, стандарт' 'off, the default' ;;
        mtu:1)            T 'если крупные передачи зависают' 'if large transfers stall' ;;
        mtu:2)            T 'всегда' 'always' ;;
    esac
}

variant_add() { printf '%s\t%s\n' "$2" "$3" >> "$1"; }

# variant_from_selection <file> — expands the SEL_<id> choices into sysctl keys.
variant_from_selection() {
    local f="$1" id v r w
    : > "$f"
    for id in $TPARAM_IDS; do
        eval "v=\${SEL_${id}:-}"
        [ -z "$v" ] && continue
        case "$id" in
            qdisc) variant_add "$f" net.core.default_qdisc "$v" ;;
            cc)    variant_add "$f" net.ipv4.tcp_congestion_control "$v" ;;
            buf)
                r="$(sysctl_get net.ipv4.tcp_rmem | awk '{print $1" "$2}')"
                w="$(sysctl_get net.ipv4.tcp_wmem | awk '{print $1" "$2}')"
                variant_add "$f" net.core.rmem_max "$v"
                variant_add "$f" net.core.wmem_max "$v"
                variant_add "$f" net.ipv4.tcp_rmem "${r:-4096 87380} $v"
                variant_add "$f" net.ipv4.tcp_wmem "${w:-4096 65536} $v"
                ;;
            lowat) variant_add "$f" net.ipv4.tcp_notsent_lowat "$v" ;;
            idle)  variant_add "$f" net.ipv4.tcp_slow_start_after_idle "$v" ;;
            mtu)   variant_add "$f" net.ipv4.tcp_mtu_probing "$v" ;;
        esac
    done
}

# test_snapshot <variant> — remember the current value of every key we touch.
test_snapshot() {
    local k v ifc
    TEST_ORIG="$(mktemp)"
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] && printf '%s\t%s\n' "$k" "$(sysctl_get "$k")" >> "$TEST_ORIG"
    done < "$1"
    ifc="$(default_iface)"
    TEST_ORIG_QDISC=""
    TEST_QDISC_CHANGED=0
    [ -n "$ifc" ] && has_cmd tc && \
        TEST_ORIG_QDISC="$(tc qdisc show dev "$ifc" 2>/dev/null | awk 'NR==1 {print $2}')"
    TEST_ACTIVE=1
    trap 'test_revert' EXIT
    trap 'exit 130' INT TERM HUP
}

# test_apply <variant> — runtime only, reverted by test_revert.
test_apply() {
    local k v ifc qd="" bad=0
    while IFS=$'\t' read -r k v; do
        [ -z "$k" ] && continue
        if sysctl -w "$k=$v" >/dev/null 2>&1; then
            [ "$k" = "net.core.default_qdisc" ] && qd="$v"
        else
            warn "$(T 'Ядро не приняло' 'The kernel rejected') ${k} = ${v}"
            bad=1
        fi
    done < "$1"
    ifc="$(default_iface)"
    if [ -n "$qd" ] && [ -n "$ifc" ] && has_cmd tc; then
        if tc qdisc replace dev "$ifc" root "$qd" 2>/dev/null; then
            TEST_QDISC_CHANGED=1
        else
            warn "$(T 'Не удалось навесить' 'Could not attach') ${qd} $(T 'на' 'to') ${ifc}"
        fi
    fi
    return "$bad"
}

# test_revert — puts every snapshotted value back. Safe to call twice.
test_revert() {
    [ "$TEST_ACTIVE" = "1" ] || return 0
    TEST_ACTIVE=0
    trap - EXIT INT TERM HUP
    local k v ifc
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] && [ -n "$v" ] && sysctl -w "$k=$v" >/dev/null 2>&1
    done < "$TEST_ORIG"
    ifc="$(default_iface)"
    if [ "$TEST_QDISC_CHANGED" = "1" ] && [ -n "$ifc" ]; then
        case "$TEST_ORIG_QDISC" in
            # default (or unknown) root: deleting ours makes the kernel re-attach the default
            ''|mq|noqueue|pfifo_fast) tc qdisc del dev "$ifc" root 2>/dev/null ;;
            *) tc qdisc replace dev "$ifc" root "$TEST_ORIG_QDISC" 2>/dev/null ;;
        esac
    fi
    rm -f "$TEST_ORIG"
    ok "$(T 'Все значения возвращены как были.' 'All values are back to what they were.')"
}

# The server measures the tester's own connection: every second `ss -ti` is
# sampled, inbound sockets (local port has a listener) are grouped by client
# IP, and the IP moving the most bytes is taken as the tester.

# listen_ports — local TCP ports that have a listener, minus the SSH port.
listen_ports() {
    local ssh_port
    ssh_port="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $4}')"
    ss -Htln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un \
        | grep -vx "${ssh_port:-22}" | tr '\n' ' '
}

# sample_once "<ports>" — one line per inbound socket:
#   ip key cc bytes_acked bytes_received segs_out retrans rtt minrtt
sample_once() {
    ss -Htin state established 2>/dev/null | awk -v ports=" $1 " '
        function lport(a) { sub(/.*:/, "", a); return a }
        function host(a)  { sub(/:[0-9]+$/, "", a); gsub(/\[|\]/, "", a); sub(/^::ffff:/, "", a); return a }
        $1 ~ /^[0-9]+$/ && NF >= 4 {
            inb = index(ports, " " lport($3) " ") > 0; ip = host($4); key = $3 "-" $4; next
        }
        inb && key != "" {
            cc = "-"; ba = 0; br = 0; so = 0; rt = 0; rtt = 0; mr = 0
            for (i = 1; i <= NF; i++) {
                f = $i
                if (f ~ /^(bbr|bbr2|bbr3|cubic|reno|htcp|vegas|westwood|bic|dctcp|illinois|hybla|scalable|yeah|lp|veno|nv|cdg|highspeed)$/) cc = f
                else if (f ~ /^bytes_acked:/)    { sub(/.*:/, "", f); ba = f }
                else if (f ~ /^bytes_received:/) { sub(/.*:/, "", f); br = f }
                else if (f ~ /^segs_out:/)       { sub(/.*:/, "", f); so = f }
                else if (f ~ /^retrans:/)        { sub(/.*\//, "", f); rt = f }
                else if (f ~ /^rtt:/)            { sub(/^rtt:/, "", f); sub(/\/.*/, "", f); rtt = f }
                else if (f ~ /^minrtt:/)         { sub(/.*:/, "", f); mr = f }
            }
            print ip, key, cc, ba, br, so, rt, rtt, mr
            key = ""
        }'
}

# summarize <samples> [ip] — "ip down up rtt_min rtt_load retr% cc secs sockets"
# (ip is "-" when there was no inbound traffic at all).
summarize() {
    awk -v pin="${2:-}" '
        {
            t = $1; ip = $2; k = $3
            if (!(k in f_ba)) { f_ba[k] = $5; f_br[k] = $6; f_so[k] = $7; f_rt[k] = $8; kip[k] = ip }
            # RTT counts as "under load" when this socket moved >64 KB since the last sample
            if ((k in l_ba) && ($5 - l_ba[k]) + ($6 - l_br[k]) > 65536) { n[ip]++; r[ip, n[ip]] = $9 }
            l_ba[k] = $5; l_br[k] = $6; l_so[k] = $7; l_rt[k] = $8; kcc[k] = $4
            if ($10 > 0 && (!(ip in mn) || $10 < mn[ip])) mn[ip] = $10
            if (t0 == "" || t < t0) t0 = t
            if (t > t1) t1 = t
        }
        END {
            for (k in kip) { ip = kip[k]; tot[ip] += (l_ba[k] - f_ba[k]) + (l_br[k] - f_br[k]) }
            best = pin
            if (best == "") for (ip in tot) if (best == "" || tot[ip] > tot[best]) best = ip
            if (best == "" || !(best in tot) || tot[best] <= 0) { print "- - - - - - - 0 0"; exit }
            secs = t1 - t0; if (secs < 1) secs = 1
            for (k in kip) if (kip[k] == best) {
                dba += l_ba[k] - f_ba[k]; dbr += l_br[k] - f_br[k]
                dso += l_so[k] - f_so[k]; drt += l_rt[k] - f_rt[k]; ns++
                d = l_ba[k] - f_ba[k] + l_br[k] - f_br[k]
                if (d >= bd) { bd = d; cc = kcc[k] }
            }
            m = n[best]
            for (i = 1; i <= m; i++) a[i] = r[best, i] + 0
            for (i = 2; i <= m; i++) { v = a[i]; j = i - 1; while (j > 0 && a[j] > v) { a[j + 1] = a[j]; j-- } a[j + 1] = v }
            load = (m > 0) ? a[int((m + 1) / 2)] : 0
            printf "%s %.1f %.1f %.0f %.0f %.2f %s %d %d\n", best, dba * 8 / secs / 1e6, dbr * 8 / secs / 1e6, \
                mn[best] + 0, load, (dso > 0 ? drt * 100 / dso : 0), (cc == "" ? "-" : cc), secs, ns
        }' "$1"
}

# measure <samples-file> [ip] — samples until Enter, with a live status line.
measure() {
    local out="$1" pin="${2:-}" ports t0 now rc ip dl ul ld rt
    ports="$(listen_ports)"
    : > "$out"
    t0="$(date +%s)"
    while :; do
        now="$(date +%s)"
        sample_once "$ports" | awk -v t="$now" '{print t, $0}' >> "$out"
        read -r ip dl ul _ ld rt _ <<EOF
$(summarize "$out" "$pin")
EOF
        if [ "$ip" = "-" ]; then
            printf '\r\033[K⏱  %3ss  ·  %s' "$((now - t0))" \
                "$(T 'жду трафик от клиента…' 'waiting for client traffic…')"
        else
            printf '\r\033[K⏱  %3ss  ·  ↓ %s  ↑ %s %s  ·  RTT %s %s  ·  %s %s%%  ·  %s' \
                "$((now - t0))" "$dl" "$ul" "$(T 'Мбит/с' 'Mbit/s')" "$ld" "$(T 'мс' 'ms')" \
                "$(T 'ретр.' 'retr.')" "$rt" "$ip"
        fi
        { read -r -t 1 _ < /dev/tty; } 2>/dev/null
        rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$rc" -le 128 ] && sleep 1        # no terminal to read from: plain timer
        [ $((now - t0)) -ge "${VPNTUNE_MAX_MEASURE:-600}" ] && break
    done
    printf '\n'
}

# ask_client_numbers — optional figures from the client's own speed test:
# "down up latency grade", "-" for anything skipped.
ask_client_numbers() {
    local dl ul lat gr
    printf '%s\n' "📱 $(T 'Цифры с экрана теста на клиенте (Enter — пропустить):' \
                          'Figures from the client test screen (Enter — skip):')" >&2
    dl="$(ask "   $(T 'Загрузка, Мбит/с:' 'Download, Mbit/s:')" "")"
    [ -z "$dl" ] && { printf -- '- - - -'; return 0; }
    ul="$(ask "   $(T 'Отдача, Мбит/с:' 'Upload, Mbit/s:')" "")"
    lat="$(ask "   $(T 'Задержка под нагрузкой, мс:' 'Latency under load, ms:')" "")"
    gr="$(ask "   $(T 'Оценка bufferbloat (A+…F):' 'Bufferbloat grade (A+…F):')" "")"
    printf '%s %s %s %s' "${dl:--}" "${ul:--}" "${lat:--}" \
        "$(printf '%s' "${gr:--}" | tr '[:lower:]' '[:upper:]')"
}

grade_num() {
    case "$1" in A+) echo 6 ;; A) echo 5 ;; B) echo 4 ;; C) echo 3 ;; D) echo 2 ;; F) echo 1 ;; *) echo - ;; esac
}

# cmp_mark <a> <b> <up|down> <min-abs-diff> — ✅ better, ⚠️ worse, ≈ same.
cmp_mark() {
    awk -v a="$1" -v b="$2" -v d="$3" -v m="$4" 'BEGIN {
        if (a == "-" || b == "-") { print ""; exit }
        diff = b - a; if (d == "down") diff = -diff
        base = (a > 0 ? a : (b > 0 ? b : 1))
        if (diff < 0 ? -diff < m : diff < m) { print "≈"; exit }
        if (diff / base > 0.05) print "✅"; else if (diff / base < -0.05) print "⚠️"; else print "≈"
    }'
}

REP_GOOD=0
REP_BAD=0
REP_ROWS=0
# _trow <label> <a-shown> <b-shown> [a-cmp b-cmp direction min-diff]
_trow() {
    local mark=""
    [ -n "${6:-}" ] && mark="$(cmp_mark "$4" "$5" "$6" "$7")"
    [ -n "$mark" ] && REP_ROWS=$((REP_ROWS + 1))
    case "$mark" in ✅) REP_GOOD=$((REP_GOOD + 1)) ;; ⚠️) REP_BAD=$((REP_BAD + 1)) ;; esac
    printf '  %s %s %s %s\n' "$(pad "$1" 24)" "$(pad "$2" 14)" "$(pad "$3" 14)" "$mark"
}

# test_report <label> <A> <B> <client-A> <client-B>
test_report() {
    local ai adl aul amn ald art acc bi bdl bul bmn bld brt bcc _x
    local ca1 ca2 ca3 ca4 cb1 cb2 cb3 cb4 mb ms
    read -r ai adl aul amn ald art acc _x <<EOF
$2
EOF
    read -r bi bdl bul bmn bld brt bcc _x <<EOF
$3
EOF
    read -r ca1 ca2 ca3 ca4 <<EOF
$4
EOF
    read -r cb1 cb2 cb3 cb4 <<EOF
$5
EOF
    mb=" $(T 'Мбит/с' 'Mbit/s')"; ms=" $(T 'мс' 'ms')"
    REP_GOOD=0; REP_BAD=0; REP_ROWS=0

    title "📊 $(T 'Результат' 'Result'): A ($(T 'было' 'before')) → B ($1)"
    printf '  %s %s %s\n' "$(pad '' 24)" "$(pad 'A' 14)" "B"
    hr
    section "🖥️  $(T 'Сервер (ваше соединение):' 'Server (your connection):')"
    if [ "$ai" = "-" ] || [ "$bi" = "-" ]; then
        warn "$(T 'В одном из замеров не было трафика от клиента — сравнить нельзя.' \
                  'One of the measurements saw no client traffic — nothing to compare.')"
    else
        _trow "↓ $(T 'Загрузка' 'Download')"        "${adl}${mb}" "${bdl}${mb}" "$adl" "$bdl" up 1
        _trow "↑ $(T 'Отдача' 'Upload')"            "${aul}${mb}" "${bul}${mb}" "$aul" "$bul" up 1
        _trow "$(T 'RTT без нагрузки' 'Idle RTT')"   "${amn}${ms}" "${bmn}${ms}" "$amn" "$bmn" down 3
        _trow "$(T 'RTT под нагрузкой' 'Loaded RTT')" "${ald}${ms}" "${bld}${ms}" "$ald" "$bld" down 3
        _trow "$(T 'Ретрансмиссии' 'Retransmits')"  "${art}%"     "${brt}%"     "$art" "$brt" down 0.3
        _trow "$(T 'Алгоритм' 'Algorithm')"        "$acc"        "$bcc"
    fi
    if [ "$ca1" != "-" ] || [ "$cb1" != "-" ]; then
        section "📱 $(T 'Клиент (введено вручную):' 'Client (typed in):')"
        _trow "↓ $(T 'Загрузка' 'Download')" "$ca1" "$cb1" "$ca1" "$cb1" up 1
        _trow "↑ $(T 'Отдача' 'Upload')"     "$ca2" "$cb2" "$ca2" "$cb2" up 1
        _trow "$(T 'Задержка под нагрузкой' 'Loaded latency')" "$ca3" "$cb3" "$ca3" "$cb3" down 3
        _trow "$(T 'Оценка' 'Grade')" "$ca4" "$cb4" "$(grade_num "$ca4")" "$(grade_num "$cb4")" up 0.5
    fi
    hr
    if [ "$REP_ROWS" -eq 0 ]; then
        say "👉 ${C_YLW}${C_BOLD}$(T 'Сравнить не получилось — повторите тест, пока на клиенте идёт тест скорости через VPN.' \
                                     'Nothing to compare — repeat while a speed test runs through the VPN on the client.')${C_RESET}"
    elif [ "$REP_GOOD" -gt 0 ] && [ "$REP_BAD" -eq 0 ]; then
        say "👉 ${C_GRN}${C_BOLD}$(T 'Вариант B лучше — стоит оставить.' 'Variant B is better — worth keeping.')${C_RESET}"
    elif [ "$REP_GOOD" -gt "$REP_BAD" ]; then
        say "👉 ${C_BOLD}$(T 'Вариант B в целом лучше, но есть просадки.' 'Variant B is better overall, with some regressions.')${C_RESET}"
    elif [ "$REP_BAD" -gt "$REP_GOOD" ]; then
        say "👉 ${C_YLW}${C_BOLD}$(T 'Вариант B хуже — лучше вернуть.' 'Variant B is worse — better revert.')${C_RESET}"
    else
        say "👉 ${C_BOLD}$(T 'Существенной разницы нет — оставлять смысла нет.' 'No real difference — no reason to keep it.')${C_RESET}"
    fi
    dim "   $(T 'Один прогон шумный: для уверенности повторите тест 2–3 раза.' 'A single run is noisy: repeat the test 2–3 times to be sure.')"
}

# test_session <variant> <label> <profile:<p>|params>
test_session() {
    need_root "test" || return 1
    local variant="$1" label="$2" kind="$3" fa fb ip A B CA CB k v cur want bcc hist
    mkdir -p "$TEST_DIR"
    fa="$(mktemp)"; fb="$(mktemp)"

    screen "🧪 $(T 'Тест' 'Test'): ${label}"
    title "📝 $(T 'Что поменяется на время теста' 'What changes during the test')"
    while IFS=$'\t' read -r k v; do
        cur="$(sysctl_get "$k")"
        [ "$cur" = "$v" ] && continue
        printf '  %-36s %s → %s\n' "$k" "${C_DIM}${cur:-n/a}${C_RESET}" "${C_GRN}${v}${C_RESET}"
    done < "$variant"
    printf '\n'
    info "$(T 'В файлы ничего не пишется. Прервёте тест (Ctrl+C) или отвалится SSH — всё вернётся само.' \
              'Nothing is written to disk. Abort (Ctrl+C) or lose SSH — everything is restored automatically.')"
    dim "   $(T 'Порядок: замер A на текущих настройках → включаю вариант B → замер B → сравнение.' \
               'Order: measurement A on current settings → variant B on → measurement B → comparison.')"
    printf '\n'
    ip="$(ask "$(T 'IP клиента (Enter — определить автоматически):' 'Client IP (Enter — detect automatically):')" "")"

    test_snapshot "$variant"

    title "📏 $(T 'Замер A — текущие настройки' 'Measurement A — current settings')"
    say "👉 $(T 'На клиенте включите VPN и откройте тест скорости:' 'On the client, connect the VPN and open a speed test:')"
    say "   fast.com · speedtest.net · waveform.com/tools/bufferbloat"
    say "   $(T 'Нажмите Enter здесь и сразу запустите тест. Закончится — снова Enter.' \
               'Press Enter here and start the test right away. When it finishes — Enter again.')"
    _read _ || true
    measure "$fa" "$ip"
    A="$(summarize "$fa" "$ip")"
    if [ "${A%% *}" = "-" ]; then
        warn "$(T 'Не увидел трафика от клиента. Протокол на UDP (Hysteria2/TUIC) так не измерить.' \
                  'No client traffic seen. UDP protocols (Hysteria2/TUIC) cannot be measured this way.')"
    else
        [ -z "$ip" ] && ip="${A%% *}"
        ok "$(T 'Соединение клиента:' 'Client connection:') ${C_BOLD}${ip}${C_RESET}"
    fi
    CA="$(ask_client_numbers)"

    title "🔀 $(T 'Вариант B' 'Variant B'): ${label}"
    test_apply "$variant"
    ok "$(T 'Временные значения включены.' 'Temporary values are on.')"
    say "👉 $(T 'Выключите и включите VPN на клиенте — новые настройки действуют только на новые соединения.' \
               'Turn the VPN off and on again on the client — new settings only apply to new connections.')"
    say "   $(T 'Затем нажмите Enter и сразу запустите тот же тест. Закончится — снова Enter.' \
               'Then press Enter and start the same test right away. When it finishes — Enter again.')"
    _read _ || true
    measure "$fb" "$ip"
    B="$(summarize "$fb" "$ip")"
    CB="$(ask_client_numbers)"

    # The kernel default only reaches sockets opened after the change.
    want="$(awk -F'\t' '$1 == "net.ipv4.tcp_congestion_control" {print $2}' "$variant")"
    bcc="$(printf '%s' "$B" | awk '{print $7}')"
    if [ -n "$want" ] && [ "$bcc" != "-" ] && [ -n "$bcc" ] && [ "$bcc" != "$want" ]; then
        warn "$(T 'Соединение клиента всё ещё на' 'The client connection still runs') ${bcc}: \
$(T 'клиент не переподключился, или в конфиге Xray задан tcpCongestion.' 'the client did not reconnect, or Xray config sets tcpCongestion.')"
    fi

    hist="${TEST_DIR}/test-$(date '+%Y-%m-%d-%H%M%S').txt"
    printf 'LABEL: %s\n' "$label" > "$hist"
    test_report "$label" "$A" "$B" "$CA" "$CB" | tee -a "$hist"
    rm -f "$fa" "$fb"

    printf '\n'
    if confirm "$(T 'Оставить вариант B навсегда (запишу в /etc/sysctl.conf с бэкапом)?' \
                    'Keep variant B permanently (written to /etc/sysctl.conf with a backup)?')" n; then
        test_keep "$variant" "$kind"
    else
        test_revert
    fi
}

# test_keep <variant> <kind> — turns the tested variant into the saved config.
test_keep() {
    local k v rc=0
    case "$2" in
        profile:*) PROFILE="${2#profile:}"; MODE="auto" ;;
        *)
            if [ "$MODE" = "custom" ] && load_params; then :; else build_params "$PROFILE" || return 1; fi
            while IFS=$'\t' read -r k v; do
                [ -z "$k" ] && continue
                pdrop "$k"
                # "default" notsent_lowat means: do not set the key at all
                [ "$k" = "net.ipv4.tcp_notsent_lowat" ] && [ "$v" = "4294967295" ] && continue
                pset "$k" "$v"
            done < "$1"
            MODE="custom"
            save_params
            ;;
    esac
    ASSUME_YES=1
    apply_tuning || rc=1
    ASSUME_YES=0
    if [ "$rc" -eq 0 ]; then
        TEST_ACTIVE=0
        trap - EXIT INT TERM HUP
        rm -f "$TEST_ORIG"
    else
        test_revert
    fi
}

test_history() {
    screen "📜 $(T 'История тестового режима' 'Test mode history')"
    local files f n=0
    files="$(ls -1t "$TEST_DIR"/test-*.txt 2>/dev/null | head -10)"
    if [ -z "$files" ]; then
        dim "   $(T 'тестов пока не было' 'no tests yet')"
        return 0
    fi
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        n=$((n + 1))
        item "$n" "$(basename "$f" .txt | sed 's/^test-//')" "$(sed -n 's/^LABEL: //p' "$f")"
    done <<EOF
$files
EOF
    hr
    item 0 "⬅️  $(T 'Назад' 'Back')"
    choose "$n"
    case "$CHOICE" in ''|0|*[!0-9]*) return "$BACK" ;; esac
    f="$(printf '%s\n' "$files" | sed -n "${CHOICE}p")"
    [ -n "$f" ] || return "$BACK"
    printf '\n'; sed '1d' "$f"
    return 0
}

menu_test() {
    need_root "test" || return 1
    while :; do
        screen "🧪 $(T 'Тестовый режим' 'Test mode')"
        dim "$(T 'Сравнение настроек на живом трафике: замер на текущих → временно новый вариант → замер.' \
                 'Compare settings on live traffic: measure current → temporary variant → measure.')"
        dim "$(T 'В файлы ничего не пишется; в конце — вернуть как было или оставить.' \
                 'Nothing is written to disk; at the end — revert or keep.')"
        section "🧪 $(T 'Что тестируем:' 'What to test:')"
        item 1 "🎚️  $(T 'Профиль целиком' 'A whole profile')" "(1g / 2g / 4g / 8g)"
        item 2 "🔧 $(T 'Отдельные параметры' 'Individual parameters')" "($(T 'очередь, алгоритм, буферы…' 'queue, algorithm, buffers…'))"
        section "📜 $(T 'История:' 'History:')"
        item 3 "📜 $(T 'Результаты прошлых тестов' 'Past test results')"
        hr
        item 0 "⬅️  $(T 'Назад' 'Back')"
        choose 3
        case "$CHOICE" in
            1) test_pick_profile ;;
            2) test_pick_params ;;
            3) test_history; pause_unless_back $? ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1 ;;
        esac
    done
}

test_pick_profile() {
    local p variant applied=""
    grep -qsF "$BLOCK_START" "$SYSCTL_FILE" && [ "$MODE" = "auto" ] && applied="$PROFILE"
    screen "🎚️  $(T 'Тест профиля' 'Profile test')"
    dim "$(T 'B — выбранный профиль целиком, A — то, что работает сейчас.' \
             'B is the chosen profile as a whole, A is what runs now.')"
    printf '\n'
    profile_table "$applied"
    hr
    item 0 "⬅️  $(T 'Назад' 'Back')"
    choose 4
    case "$CHOICE" in 1) p=1g ;; 2) p=2g ;; 3) p=4g ;; 4) p=8g ;; *) return 0 ;; esac
    build_params "$p" || return 1
    variant="$(mktemp)"
    cp "$PVAL_FILE" "$variant"
    test_session "$variant" "$(T 'профиль' 'profile') ${p}" "profile:${p}"
    rm -f "$variant"
    pause
}

test_pick_params() {
    local id i n cur sel variant label
    for id in $TPARAM_IDS; do eval "SEL_${id}=''"; done
    while :; do
        screen "🔧 $(T 'Тест отдельных параметров' 'Individual parameter test')"
        dim "$(T 'Выберите параметр, затем значение. Изменённые подсвечены.' \
                 'Pick a parameter, then a value. Changed ones are highlighted.')"
        printf '\n'
        i=0; n=0
        for id in $TPARAM_IDS; do
            i=$((i + 1))
            cur="$(tparam_current "$id")"
            eval "sel=\${SEL_${id}:-}"
            if [ -n "$sel" ]; then
                n=$((n + 1))
                item "$i" "$(pad "$(tparam_label "$id")" 26) ${C_DIM}$(tval_human "$id" "$cur")${C_RESET} → ${C_GRN}${C_BOLD}$(tval_human "$id" "$sel")${C_RESET}"
            else
                item "$i" "$(pad "$(tparam_label "$id")" 26) $(tval_human "$id" "$cur")"
            fi
        done
        hr
        item 7 "▶️  $(T 'Перейти к тестированию' 'Start testing')" "(${n} $(T 'изм.' 'changed'))"
        item 8 "🧹 $(T 'Сбросить выбор' 'Clear selection')"
        item 0 "⬅️  $(T 'Назад' 'Back')"
        choose 8
        case "$CHOICE" in
            [1-6])
                # shellcheck disable=SC2086
                id="$(printf '%s\n' $TPARAM_IDS | sed -n "${CHOICE}p")"
                test_pick_value "$id"
                ;;
            7)
                if [ "$n" -eq 0 ]; then
                    warn "$(T 'Сначала выберите хотя бы одно новое значение.' 'Pick at least one new value first.')"
                    sleep 2; continue
                fi
                variant="$(mktemp)"
                variant_from_selection "$variant"
                label=""
                for id in $TPARAM_IDS; do
                    eval "sel=\${SEL_${id}:-}"
                    [ -z "$sel" ] && continue
                    label="${label:+${label}, }$(tparam_label "$id" | sed 's/^[^ ]* //') $(tval_human "$id" "$sel")"
                done
                test_session "$variant" "$label" "params"
                rm -f "$variant"
                pause
                return 0
                ;;
            8) for id in $TPARAM_IDS; do eval "SEL_${id}=''"; done ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1 ;;
        esac
    done
}

# test_pick_value <id> — numbered values for one parameter; the choice goes into SEL_<id>.
test_pick_value() {
    local id="$1" cur sel v j=0 hint vals
    cur="$(tparam_current "$id")"
    eval "sel=\${SEL_${id}:-}"
    vals="$(tparam_values "$id")"
    screen "$(tparam_label "$id")"
    for v in $vals; do
        j=$((j + 1))
        hint="($(tval_hint "$id" "$v"))"
        [ "$v" = "$cur" ] && hint="${hint} ◀ $(T 'сейчас' 'current')"
        [ -n "$sel" ] && [ "$v" = "$sel" ] && hint="${hint} ★ $(T 'выбрано' 'selected')"
        item "$j" "$(pad "$(tval_human "$id" "$v")" 10)" "$hint"
    done
    hr
    item 0 "⬅️  $(T 'Назад' 'Back')"
    choose "$j"
    case "$CHOICE" in ''|0|*[!0-9]*) return 0 ;; esac
    [ "$CHOICE" -gt "$j" ] && return 0
    # shellcheck disable=SC2086
    v="$(printf '%s\n' $vals | sed -n "${CHOICE}p")"
    # picking the current value means "leave it as it is"
    if [ "$v" = "$cur" ]; then eval "SEL_${id}=''"; else eval "SEL_${id}=\$v"; fi
}

# -------------------------------------------------------------------- swap ---

menu_swap() {
    need_root "swap" || return 1
    screen "💾 $(T 'Файл подкачки (swap)' 'Swap file')"
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
    screen "📂 $(T 'Лимиты соединений (файловые дескрипторы)' 'Connection limits (file descriptors)')"
    dim "$(T 'Каждое клиентское соединение — минимум один дескриптор. Дефолт 1024 исчерпывается' \
             'Every client connection is at least one descriptor. The 1024 default runs out')"
    dim "$(T 'на десятках активных клиентов, в логах появляется «too many open files».' \
             'at a few dozen active clients, and the log fills with "too many open files".')"

    local svcs svc
    svcs="$(detect_services)"
    title "🔎 $(T 'Найденные сервисы' 'Services found')"
    if [ -n "$svcs" ]; then
        while IFS= read -r s; do
            [ -n "$s" ] && kv "$s" "nofile $(service_nofile "$s")"
        done <<EOF
$svcs
EOF
    else
        warn "$(T 'Известные systemd-сервисы не найдены.' 'No known systemd services found.')"
    fi
    printf '\n'

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
        screen "🩺 $(T 'Диагностика' 'Diagnostics')"
        section "🔎 $(T 'Проверки:' 'Checks:')"
        item 1 "🔎 $(T 'Полная проверка' 'Full check')" "($(T 'всё сразу' 'everything at once'))"
        item 2 "🧩 $(T 'Конфликты с другими конфигами' 'Conflicts with other configs')" "(/etc/sysctl.d/)"
        item 3 "🧷 $(T 'Слипшиеся строки в sysctl.conf' 'Malformed lines in sysctl.conf')"
        section "📡 $(T 'Нагрузка:' 'Load:')"
        item 4 "📡 $(T 'Живые соединения' 'Live connections')" "(bbr / rtt / cwnd)"
        item 5 "🧠 $(T 'Память и OOM-killer' 'Memory and OOM killer')"
        item 6 "🔁 $(T 'Перечитать sysctl и показать ошибки' 'Re-read sysctl and show errors')"
        hr
        item 0 "⬅️  $(T 'Назад' 'Back')"
        choose 6
        local c="$CHOICE"
        case "$c" in
            1) status_body; diag_conflicts; diag_malformed; diag_memory ;;
            2) diag_conflicts ;;
            3) diag_malformed ;;
            4) diag_sockets ;;
            5) diag_memory ;;
            6) title "sysctl -p"; sysctl -p "$SYSCTL_FILE" 2>&1 | sed 's/^/  /' ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1; continue ;;
        esac
        pause
    done
}

# ------------------------------------------------------ backups and restore ---

menu_backups() {
    need_root "restore" || return 1
    while :; do
        screen "♻️  $(T 'Бэкапы и откат' 'Backups & rollback')"
        local list n=0 f
        list="$(list_backups)"
        section "🗂️  $(T 'Бэкапы /etc/sysctl.conf:' 'Backups of /etc/sysctl.conf:')"
        if [ -z "$list" ]; then
            dim "   $(T 'пока нет — они появляются при каждом применении' 'none yet — one is made on every apply')"
        else
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                n=$((n + 1))
                printf '   %s %s  %s\n' "${C_DIM}$(printf '%2s' "#$n")${C_RESET}" \
                    "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" "${C_DIM}${f##*/}${C_RESET}"
            done <<EOF
$list
EOF
        fi
        section "🛠️  $(T 'Действия:' 'Actions:')"
        item 1 "⏪ $(T 'Восстановить из бэкапа' 'Restore from a backup')"
        item 2 "🧹 $(T 'Удалить только блок vpn-node-tuner' 'Remove only the vpn-node-tuner block')"
        item 3 "📄 $(T 'Показать текущий блок' 'Show the current block')"
        hr
        item 0 "⬅️  $(T 'Назад' 'Back')"
        choose 3
        local c="$CHOICE"
        case "$c" in
            1)
                [ -z "$list" ] && { warn "$(T 'Нечего восстанавливать.' 'Nothing to restore.')"; pause; continue; }
                local num
                num="$(ask "$(T 'Номер бэкапа:' 'Backup number:')" "1")"
                f="$(printf '%s\n' "$list" | sed -n "${num}p" 2>/dev/null)"
                if [ -n "$f" ] && [ -f "$f" ]; then
                    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.before-restore-$(date '+%Y-%m-%d-%H%M%S')"
                    cp -a "$f" "$SYSCTL_FILE" && ok "$(T 'Восстановлено из' 'Restored from') $f"
                    sysctl --system 2>&1 | grep -i 'sysctl:' | sed 's/^/  /'
                    warn "$(T 'Для гарантированного сброса qdisc перезагрузите сервер: reboot' \
                              'Reboot the server to reset qdisc reliably: reboot')"
                else
                    err "$(T 'Нет бэкапа с таким номером.' 'No backup with that number.')"
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
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1; continue ;;
        esac
        pause
    done
}

# --------------------------------------------------------------- baselines ---

baseline_snapshot() {
    mkdir -p "$STATE_DIR"
    local f
    f="${STATE_DIR}/baseline-$(date '+%Y-%m-%d-%H%M%S').txt"
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
        screen "📏 $(T 'Замеры до / после' 'Before / after measurements')"
        dim "$(T 'Тюнинг без замера «до» бесполезен — вы не отличите улучшение от совпадения.' \
                 'Tuning without a "before" measurement is pointless — you cannot tell improvement from coincidence.')"
        dim "$(T 'Сравнить настройки на живом трафике — пункт 4 «Тестовый режим».' \
                 'To compare settings on live traffic — item 4 "Test mode".')"
        section "📸 $(T 'Снимки ядра:' 'Kernel snapshots:')"
        item 1 "📸 $(T 'Сделать снимок состояния ядра' 'Take a kernel state snapshot')" "(baseline)"
        item 2 "🔍 $(T 'Сравнить с последним снимком' 'Compare with the last snapshot')"
        section "💻 $(T 'Клиент:' 'Client:')"
        item 3 "💻 $(T 'Команды для замеров с клиента' 'Client-side measurement commands')"
        item 4 "📜 $(T 'История тестового режима' 'Test mode history')"
        hr
        item 0 "⬅️  $(T 'Назад' 'Back')"
        choose 4
        local c="$CHOICE"
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
            4) test_history; pause_unless_back $?; continue ;;
            0|q) return 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1; continue ;;
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

# version_gt A B — true when version A is newer than version B.
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

cmd_update() {
    need_root "update" || return 1
    local tmp remote now
    tmp="$(mktemp)"
    info "$(T 'Проверяю обновления...' 'Checking for updates...')"
    # raw.githubusercontent.com caches files for ~5 minutes; a unique query
    # string makes it return the current file right after a release.
    if ! curl -fsSL -H 'Cache-Control: no-cache' "${RAW_URL}?t=$(date +%s)" -o "$tmp"; then
        err "$(T 'Не удалось скачать.' 'Download failed.')"
        rm -f "$tmp"; return 1
    fi
    remote="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
    if [ -z "$remote" ] || ! bash -n "$tmp" 2>/dev/null; then
        err "$(T 'Скачанный файл повреждён — обновление отменено.' 'The downloaded file is broken — update cancelled.')"
        rm -f "$tmp"; return 1
    fi
    say "  $(T 'установлено' 'installed'): ${SCRIPT_VERSION}"
    say "  $(T 'доступно' 'available'):   ${remote}"
    if ! version_gt "$remote" "$SCRIPT_VERSION"; then
        ok "$(T 'У вас последняя версия.' 'You are on the latest version.')"
        rm -f "$tmp"; return 0
    fi
    if ! confirm "$(T 'Обновить?' 'Update?')" y; then
        rm -f "$tmp"; return 0
    fi

    # Install next to the target and rename over it: the running copy keeps
    # its own inode, so this process is never reading a half-written file.
    if ! install -m 0755 "$tmp" "${INSTALL_PATH}.new" || ! mv -f "${INSTALL_PATH}.new" "$INSTALL_PATH"; then
        err "$(T 'Не удалось установить.' 'Install failed.')"
        rm -f "$tmp" "${INSTALL_PATH}.new"; return 1
    fi
    rm -f "$tmp"

    now="$("$INSTALL_PATH" --version 2>/dev/null)"
    if [ "$now" != "$remote" ]; then
        err "$(T 'После установки версия' 'After install the version is') ${now:-?}, $(T 'ожидалась' 'expected') ${remote}"
        return 1
    fi
    ok "$(T 'Обновлено:' 'Updated:') ${SCRIPT_VERSION} → ${C_BOLD}${remote}${C_RESET}"

    # This process still runs the old code from memory — hand over to the new one.
    if [ "$IN_MENU" = "1" ]; then
        info "$(T 'Перезапускаю меню с новой версией...' 'Restarting the menu with the new version...')"
        sleep 1
        exec "$INSTALL_PATH" menu
    fi
}

# ------------------------------------------------------------------- menu ---

banner() {
    local ram ifc cc qd
    ram="$(detect_ram_mb)"
    ifc="$(default_iface)"
    cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
    qd="$(sysctl_get net.core.default_qdisc)"

    printf '\n%s\n' "${C_BOLD}⚡ VPN Node Tuner${C_RESET} ${C_DIM}v${SCRIPT_VERSION}${C_RESET}"
    hr
    if grep -qsF "$BLOCK_START" "$SYSCTL_FILE" 2>/dev/null; then
        say "${C_BOLD}${C_GRN}✅ $(T 'Оптимизация применена' 'Optimization applied')${C_RESET}"
    else
        say "${C_BOLD}${C_YLW}⚠️  $(T 'Оптимизация не применена' 'Optimization not applied')${C_RESET}"
    fi
    say "💾 ${C_BLU}RAM ${ram} MB${C_RESET}  ·  🧠 ${C_BLU}${cc:-?} + ${qd:-?}${C_RESET}  ·  🔌 ${C_BLU}${ifc:-?}${C_RESET}"
    hr
}

main_menu() {
    IN_MENU=1
    while :; do
        clear 2>/dev/null || true
        banner

        section "🔧 $(T 'Оптимизация:' 'Tuning:')"
        item 1  "🚀 $(T 'Применить оптимизацию' 'Apply optimization')" "($(T 'профиль' 'profile') ${PROFILE})"
        item 2  "✏️  $(T 'Свои значения' 'Custom values')"
        item 3  "🎚️  $(T 'Сменить профиль RAM' 'Change RAM profile')"
        item 4  "🧪 $(T 'Тестовый режим' 'Test mode')" "($(T 'без записи в файл' 'nothing written to disk'))"

        section "🖥️  $(T 'Сервер:' 'Server:')"
        item 5  "💾 $(T 'Файл подкачки' 'Swap file')" "(swap)"
        item 6  "📂 $(T 'Лимиты соединений' 'Connection limits')" "($(T 'файловые дескрипторы' 'file descriptors'))"

        section "📊 $(T 'Проверка:' 'Monitoring:')"
        item 7  "📊 $(T 'Текущее состояние' 'Current state')"
        item 8  "🩺 $(T 'Диагностика' 'Diagnostics')"
        item 9  "📏 $(T 'Замеры до / после' 'Before / after measurements')"

        section "🛠️  $(T 'Обслуживание:' 'Maintenance:')"
        item 10 "♻️  $(T 'Бэкапы и откат' 'Backups & rollback')"
        item 11 "🌐 $(T 'Язык / Language' 'Language / Язык')"
        item 12 "🔄 $(T 'Проверить обновления' 'Check for updates')"

        hr
        item 0  "⬅️  $(T 'Выход' 'Exit')"
        dim "GitHub: ${REPO_SLUG}"
        printf '%s ' "${C_BOLD}$(T 'Выберите пункт [0-12]:' 'Select option [0-12]:')${C_RESET}"

        local c; _read c || c=""
        case "$c" in
            1)  MODE="auto"; screen "🚀 $(T 'Применить оптимизацию' 'Apply optimization')"; apply_tuning; pause ;;
            2)  wizard_custom; pause ;;
            3)  choose_profile; pause_unless_back $? ;;
            4)  menu_test ;;
            5)  menu_swap; pause ;;
            6)  menu_limits; pause ;;
            7)  cmd_status; pause ;;
            8)  menu_diag ;;
            9)  menu_baseline ;;
            10) menu_backups ;;
            11) choose_language ;;
            12) screen "🔄 $(T 'Проверить обновления' 'Check for updates')"; cmd_update; pause ;;
            0|q|exit) printf '\n'; exit 0 ;;
            *) warn "$(T 'Неизвестный пункт' 'Unknown item')"; sleep 1 ;;
        esac
    done
}

choose_profile() {
    screen "🎚️  $(T 'Профиль RAM' 'RAM profile')"
    profile_table "$PROFILE"
    item 5 "🤖 $(T 'Автоматически по RAM' 'Automatically by RAM')"
    hr
    item 0 "⬅️  $(T 'Назад' 'Back')"
    choose 5
    case "$CHOICE" in
        1) PROFILE="1g" ;;
        2) PROFILE="2g" ;;
        3) PROFILE="4g" ;;
        4) PROFILE="8g" ;;
        5) PROFILE="$(profile_for_ram "$(detect_ram_mb)")" ;;
        *) return "$BACK" ;;
    esac
    MODE="auto"
    save_config
    printf '\n'
    ok "$(T 'Профиль:' 'Profile:') ${C_BOLD}${PROFILE}${C_RESET}"
    info "$(T 'Чтобы применить — пункт 1 главного меню.' 'To apply it — main menu item 1.')"
}

# profile_table [current] — numbered 1..4 profile list with RAM / buffers / queues.
profile_table() {
    local current="${1:-}" auto p r b s i=0 hint
    auto="$(profile_for_ram "$(detect_ram_mb)")"
    printf '      %s %s %s %s\n' "$(pad '' 4)" "$(pad 'RAM' 10)" "$(pad "$(T 'Буферы' 'Buffers')" 8)" "somaxconn"
    while IFS='|' read -r p r b s; do
        [ -z "$p" ] && continue
        i=$((i + 1)); hint=""
        [ "$p" = "$auto" ] && hint="($(T 'подходит по RAM' 'matches RAM'))"
        [ -n "$current" ] && [ "$p" = "$current" ] && hint="${hint} ◀ $(T 'текущий' 'current')"
        item "$i" "$(pad "$p" 4) $(pad "$r" 10) $(pad "$b" 8) $(pad "$s" 6)" "$hint"
    done <<EOF
1g|< 1.5 GB|16 MB|4096
2g|1.5–3 GB|16 MB|8192
4g|3–6 GB|32 MB|16384
8g|> 6 GB|64 MB|32768
EOF
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
