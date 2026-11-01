#!/bin/bash
# ============================================================
# БАЗОВЫЙ КОНФИГ И ОБЩИЕ ФУНКЦИИ БОТА
# ============================================================

umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
cd / 2>/dev/null || true
shopt -u patsub_replacement 2>/dev/null

# ============================================================
# СОЗДАНИЕ РАНТАЙМ-СТРУКТУРЫ /tmp/telegram_bot/
# ============================================================
mkdir -p /tmp/telegram_bot/logs \
         /tmp/telegram_bot/flags \
         /tmp/telegram_bot/state \
         /tmp/telegram_bot/heartbeat \
         /tmp/telegram_bot/explorer \
         /tmp/telegram_bot/exec \
         /tmp/telegram_bot/wifi \
         /tmp/telegram_bot/services \
         /tmp/telegram_bot/online \
         /tmp/telegram_bot/traffic \
         /tmp/telegram_bot/speed \
         /tmp/telegram_bot/wol \
         /tmp/telegram_bot/reboot \
         /tmp/telegram_bot/critical/state

# ============================================================
# ПРОВЕРКА ТОКЕН И CHAT_ID
# ============================================================
if [ -f "/etc/telegram_bot/.env" ]; then
    . /etc/telegram_bot/.env
else
    echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Файл /etc/telegram_bot/.env не найден!" >&2
    echo "Создайте его и поместите туда BOT_TOKEN и CHAT_ID." >&2
    exit 1
fi

# ============================================================
# ПРОВЕРКА ОБЯЗАТЕЛЬНЫХ ПЕРЕМЕННЫХ
# ============================================================
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    {
        echo "$(date): КРИТИЧЕСКАЯ ОШИБКА: BOT_TOKEN или CHAT_ID не заданы"
        echo "  BOT_TOKEN=[${BOT_TOKEN:0:20}...]"
        echo "  CHAT_ID=[$CHAT_ID]"
    } >> /tmp/telegram_bot/logs/bot.log 2>/dev/null
    echo "❌ BOT_TOKEN или CHAT_ID не заданы в /etc/telegram_bot/bot_config.sh" >&2
    return 1 2>/dev/null || exit 1
fi


# Разделитель - при ширине >=416dp на любом смартфоне выглядит хорошо.
SEP46="===================================================="
# SEP46="▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"   
	

# ============================================================
# ПРОВЕРКА УТИЛИТ
# ============================================================
# Критические — без них бот вообще не работает.
BOT_REQUIRED_COMMANDS=("bash" "curl" "jq" "gawk" "iw" "iwinfo" "hostapd_cli" "flock" "pkill" "sed" "uci")
# Опциональные — без них часть функций недоступна.
BOT_OPTIONAL_COMMANDS=("mhz" "timeout" "speedtest" "sexpect" "etherwake")

_bot_pkg_for_cmd() {
    case "$1" in
        bash)         echo "bash" ;;
        curl)         echo "curl" ;;
        jq)           echo "jq" ;;
        gawk)         echo "gawk" ;;
        iw)           echo "iw" ;;
        iwinfo)       echo "iwinfo" ;;
        hostapd_cli)  echo "hostapd-utils" ;;
        etherwake)    echo "etherwake" ;;
        flock)        echo "flock" ;;
        pkill)        echo "procps-ng" ;;
        sed)          echo "sed" ;;
        mhz)          echo "mhz" ;;
        timeout)      echo "coreutils-timeout" ;;
        speedtest)    echo "speedtestcpp" ;;
        sexpect)      echo "sexpect" ;;
        *)            echo "$1" ;;
    esac
}

_cmd_runs_ok() {
    local cmd="$1"
    local path
    path=$(command -v "$cmd" 2>/dev/null) || return 1
    [ -n "$path" ] || return 1
    [ -x "$path" ] || return 1
    [ -s "$path" ] || return 1
    return 0
}

# Возвращает номер syscall read для текущей архитектуры.
_read_syscall_num() {
    case "$(uname -m)" in
        aarch64|arm64)      echo 63   ;;
        armv7l|armv6l|armv5*) echo 3   ;;
        x86_64)             echo 0    ;;
        i386|i486|i586|i686) echo 3   ;;       
		mips64*)            echo 63   ;;
        mips*)              echo 3    ;;
        riscv64)            echo 63   ;;
        *)
            echo 63
            ;;
    esac
}

check_required_utilities() {
    local mode="${1:-default}"
    local missing_critical=()
    local missing_optional=()
    local cmd

    for cmd in "${BOT_REQUIRED_COMMANDS[@]}"; do
        _cmd_runs_ok "$cmd" || missing_critical+=("$cmd")
    done
    for cmd in "${BOT_OPTIONAL_COMMANDS[@]}"; do
        _cmd_runs_ok "$cmd" || missing_optional+=("$cmd")
    done

    case "$mode" in
        quiet)
            [ ${#missing_critical[@]} -eq 0 ] && return 0 || return 1
            ;;
        print)
            [ ${#missing_critical[@]} -gt 0 ] && printf '%s\n' "${missing_critical[@]}"
            [ ${#missing_optional[@]} -gt 0 ] && printf 'OPTIONAL:%s\n' "${missing_optional[@]}"
            return 0
            ;;
    esac

    if [ ${#missing_critical[@]} -eq 0 ] && [ ${#missing_optional[@]} -eq 0 ]; then
        return 0
    fi

    local pkg_manager
    if command -v apk >/dev/null 2>&1; then
        pkg_manager="apk add"
    else
        pkg_manager="opkg install"
    fi

    local pkgs_to_install=""
    for cmd in "${missing_critical[@]}" "${missing_optional[@]}"; do
        pkgs_to_install="$pkgs_to_install $(_bot_pkg_for_cmd "$cmd")"
    done
    pkgs_to_install=$(echo "$pkgs_to_install" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')

    local full_msg=""
    if [ ${#missing_critical[@]} -gt 0 ]; then
        full_msg="❌ <b>Отсутствуют критические утилиты:</b>
<code>${missing_critical[*]}</code>"
    fi
    if [ ${#missing_optional[@]} -gt 0 ]; then
        [ -n "$full_msg" ] && full_msg="${full_msg}"
        local _hint=""
        local _c
        for _c in "${missing_optional[@]}"; do
            case "$_c" in
                timeout) _hint="${_hint}без timeout команды могут зависать при сбое сети; " ;;
                sexpect) _hint="${_hint}без sexpect не работает /exec; " ;;
            esac
        done
        if [ -n "$_hint" ]; then
            _hint="(${_hint%; })"
        else
            _hint="(часть функций будет недоступна)"
        fi
        full_msg="${full_msg}⚠️ <b>Отсутствуют опциональные утилиты:</b>
<code>${missing_optional[*]}</code>
${_hint}"
    fi
    full_msg="${full_msg}

📦 <b>Установите:</b>
<code>$pkg_manager $pkgs_to_install</code>"

    if command -v curl >/dev/null 2>&1 && [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
        (
            flock -w 5 200 || exit 0
            
            local _warn_list_file="/tmp/telegram_bot/state/utils_warned_list"
            local _warn_time_file="/tmp/telegram_bot/state/utils_warned_ts"
            
            local _last_list=""
            [ -f "$_warn_list_file" ] && _last_list=$(cat "$_warn_list_file" 2>/dev/null | tr -d '\n\r')
            
            local _now=$(date +%s)
            local _last_time=0
            [ -f "$_warn_time_file" ] && _last_time=$(cat "$_warn_time_file" 2>/dev/null || echo 0)
            
            if [ "$_last_list" != "$pkgs_to_install" ] || [ $((_now - _last_time)) -gt 86400 ]; then
                echo "$pkgs_to_install" > "$_warn_list_file"
                echo "$_now" > "$_warn_time_file"
                
                curl -s --connect-timeout 5 --max-time 10 -X POST \
                    "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" \
                    --data-urlencode text="$full_msg" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            fi
        ) 200>/tmp/telegram_bot/flags/utils_warn.lock
    fi

    [ ${#missing_critical[@]} -eq 0 ] && return 0 || return 1
}

_is_read_wait() {
    local _pid="$1"
    [ -z "$_pid" ] && return 1

    if [ ! -d "/proc/$_pid" ]; then
        return 1
    fi
    local state
    state=$(awk '{print $3}' /proc/$_pid/stat 2>/dev/null)
    [ "$state" = "Z" ] && return 1

    local _sc
    _sc=$(awk '{print $1}' /proc/$_pid/syscall 2>/dev/null)
    [ -z "$_sc" ] && return 1

    local _expect
    _expect=$(_read_syscall_num)
    [ "$_sc" = "$_expect" ]
}

# ============================================================
# СЕТЕВЫЕ ИНТЕРФЕЙСЫ 
# ============================================================
# LAN-интерфейс (мост).
if [ -z "$LAN_IFACE" ]; then
    LAN_IFACE="$(uci -q get network.lan.device 2>/dev/null)"
    if [ -z "$LAN_IFACE" ] || ! ip link show "$LAN_IFACE" >/dev/null 2>&1; then
        LAN_IFACE="$(uci -q get network.lan.ifname 2>/dev/null | awk '{print $1}')"
    fi
    if [ -z "$LAN_IFACE" ] || ! ip link show "$LAN_IFACE" >/dev/null 2>&1; then
        LAN_IFACE="br-lan"
    fi
fi
# ============================================================
# WI-FI ИНТЕРФЕЙСЫ — АВТООПРЕДЕЛЕНИЕ
# ============================================================

_iface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

# Ищет AP-интерфейс для указанного радио (0 или 1).
_find_iface_for_radio() {
    local radio_num="$1"
    local iface_name=""

    # 1. ubus
    if command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local ubus_iface
        ubus_iface=$(ubus call network.wireless status 2>/dev/null \
            | jq -r ".radio${radio_num}.interfaces[]? | select(.config.mode == \"ap\") | .ifname // empty" 2>/dev/null \
            | head -1)
        if [ -n "$ubus_iface" ] && _iface_exists "$ubus_iface"; then
            echo "$ubus_iface"
            return 0
        fi
    fi

    # 2. UCI
    local sec
    for sec in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
        local dev mode dis
        dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
        mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
        dis=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
        [ "$dev" = "radio${radio_num}" ] || continue
        [ "$mode" = "ap" ] || continue
        [ "$dis" = "1" ] && continue
        iface_name=$(uci -q get "wireless.$sec.ifname" 2>/dev/null)
        if [ -n "$iface_name" ] && _iface_exists "$iface_name"; then
            echo "$iface_name"
            return 0
        fi
    done

    # 3. iw dev
    local iw_ifaces
    iw_ifaces=$(iw dev 2>/dev/null | awk '/^[[:space:]]*Interface / {print $2}')
    local i
    for i in $iw_ifaces; do
        local phy type
        phy=$(iw dev "$i" info 2>/dev/null | awk '/wiphy/ {print $2}')
        type=$(iw dev "$i" info 2>/dev/null | awk '/type/ {print $2; exit}')
        if [ "$phy" = "$radio_num" ] && [ "$type" = "AP" ] && _iface_exists "$i"; then
            echo "$i"
            return 0
        fi
    done

    if [ "$radio_num" = "0" ]; then
        for name in "phy0-ap0" "wlan0" "ath0" "ra0"; do
            _iface_exists "$name" && { echo "$name"; return 0; }
        done
    else
        for name in "phy1-ap0" "wlan1" "ath1" "ra1"; do
            _iface_exists "$name" && { echo "$name"; return 0; }
        done
    fi
    return 1
}

if [ -z "$INTERFACE_24" ]; then
    iface_24=$(_find_iface_for_radio 0)
    if [ -n "$iface_24" ]; then
        INTERFACE_24="$iface_24"
    fi
fi

if [ -z "$INTERFACE_5" ]; then
    iface_5=$(_find_iface_for_radio 1)
    if [ -n "$iface_5" ]; then
        INTERFACE_5="$iface_5"
    fi
fi

if [ -z "$INTERFACE_24" ]; then
    if _iface_exists "phy0-ap0"; then
        INTERFACE_24="phy0-ap0"
    else
        echo "$(date): WARNING: AP-интерфейс 2.4 ГГц не найден" >> /tmp/telegram_bot/logs/bot.log
        INTERFACE_24=""
    fi
fi

if [ -z "$INTERFACE_5" ]; then
    if _iface_exists "phy1-ap0"; then
        INTERFACE_5="phy1-ap0"
    else
        echo "$(date): WARNING: AP-интерфейс 5 ГГц не найден" >> /tmp/telegram_bot/logs/bot.log
        INTERFACE_5=""
    fi
fi

# ============================================================
# TARGET-УСТРОЙСТВА (уведомления о подкл/откл от WiFi)
# ============================================================
_TARGET_DEVICE_FILE="/etc/telegram_bot/data/.target_device.conf"

# Имя устройства по MAC или пусто.
_target_get_name() {
    local mac="$1"
    local file="$_TARGET_DEVICE_FILE"
    [ -f "$file" ] || return 1
    awk -F'|' -v m="$mac" 'tolower($1)==tolower(m){print $2; exit;}' "$file" 2>/dev/null
}

# ============================================================
# CURL С ПОВТОРАМИ
# ============================================================
curl_retry() {
    trap 'rm -f /tmp/curl_out_$$_* /tmp/curl_err_$$_*' EXIT
    local response=""
    local exit_code=0
    local total_wait=0
    local max_total_wait=30
    local err_attempts=0
    local max_err_attempts=3
    local err_delay=1
    local retry_after=0

    while :; do
        local _curl_tmp="/tmp/curl_out_$$_${RANDOM}"
        local _curl_err="/tmp/curl_err_$$_${RANDOM}"
        : > "$_curl_tmp"
        : > "$_curl_err"

        (
            exec 200>&- 2>/dev/null
            curl -s --connect-timeout 5 --max-time 35 -H "Connection: close" "$@" > "$_curl_tmp" 2>"$_curl_err"
            echo $? > "${_curl_tmp}.rc"
        ) &
        local _cpid=$!

        local _cdone=0
        local _cw=0
        while [ "$_cw" -lt 40 ]; do
            if ! kill -0 "$_cpid" 2>/dev/null; then
                _cdone=1
                break
            fi
            sleep 1
            _cw=$((_cw + 1))
        done

        if [ "$_cdone" = "1" ]; then
            wait "$_cpid" 2>/dev/null
            exit_code=$(cat "${_curl_tmp}.rc" 2>/dev/null)
            [ -z "$exit_code" ] && exit_code=0
            response=$(cat "$_curl_tmp" 2>/dev/null)
        else
            kill -9 "$_cpid" 2>/dev/null
            pkill -9 -P "$_cpid" 2>/dev/null
            exit_code=1
            response=""
            echo "$(date): curl_retry: TIMEOUT (killed) $*" >> /tmp/telegram_bot/logs/bot.log
        fi
        rm -f "$_curl_tmp" "$_curl_err" "${_curl_tmp}.rc"

        if [ $exit_code -eq 0 ] && [ -n "$response" ]; then

            if echo "$response" | jq -e '.error_code == 429' >/dev/null 2>&1; then
                retry_after=$(echo "$response" | jq -r '.parameters.retry_after // 3' 2>/dev/null)
                case "$retry_after" in ''|*[!0-9]*) retry_after=3 ;; esac
                [ "$retry_after" -gt 30 ] && retry_after=30

                if [ $((total_wait + retry_after)) -gt "$max_total_wait" ]; then
                    echo "$(date): curl_retry: 429, бюджет ${max_total_wait}s исчерпан" >> /tmp/telegram_bot/logs/bot.log
                    printf '%s' "$response"
                    return 0
                fi

                total_wait=$((total_wait + retry_after))
                echo "$(date): curl_retry: 429, ждём ${retry_after}s" >> /tmp/telegram_bot/logs/bot.log
                sleep "$retry_after"
                continue
            fi

            printf '%s' "$response"
            return 0
        fi

        err_attempts=$((err_attempts + 1))
        if [ "$err_attempts" -ge "$max_err_attempts" ]; then
            echo "$(date): curl_retry: curl failed after ${err_attempts} попыток (exit=${exit_code})" >> /tmp/telegram_bot/logs/bot.log
            printf '%s' "$response"
            return 1
        fi
        sleep "$err_delay"
        err_delay=$((err_delay * 2))
    done
}

# ============================================================
# HTML-ЭКРАНИРОВАНИЕ
# ============================================================
html_escape() {
    local s="$1"
    local a='&amp;' l='&lt;' g='&gt;' q='&quot;' ap='&#39;'

    s=${s//&/$a}
    s=${s//</$l}
    s=${s//>/$g}
    s=${s//\"/$q}
    s=${s//\'/$ap}

    printf '%s' "$s"
}

# ============================================================
# ПОЛУЧЕНИЕ SSID
# ============================================================
get_ssid() {
    local iface="$1"
    local ssid=""

    if command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        ssid=$(ubus call network.wireless status 2>/dev/null \
            | jq -r --arg ifn "$iface" '
                .[] | .interfaces[]?
                | select(.ifname == $ifn and .config.mode == "ap")
                | .config.ssid // empty
            ' 2>/dev/null | head -1)
    fi

    if [ -z "$ssid" ]; then
        local radio=""
        if [ "$iface" = "$INTERFACE_24" ]; then
            radio="radio0"
        elif [ "$iface" = "$INTERFACE_5" ]; then
            radio="radio1"
        fi

        if [ -n "$radio" ]; then
            local sections
            sections=$(uci show wireless 2>/dev/null \
                | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p")
            local sec
            for sec in $sections; do
                local dev mode
                dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
                mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
                if [ "$dev" = "$radio" ] && [ "$mode" = "ap" ]; then
                    local disabled
                    disabled=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
                    if [ "$disabled" != "1" ]; then
                        ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
                        [ -n "$ssid" ] && break
                    fi
                fi
            done
        fi
    fi

    if [ -z "$ssid" ]; then
        case "$iface" in
            *"phy0"*|*"24"*) echo "2.4 ГГц" ;;
            *"phy1"*|*"5"*)  echo "5 ГГц" ;;
            *) echo "$iface" ;;
        esac
    else
        echo "$ssid"
    fi
}

# ============================================================
# ОТПРАВКА В TELEGRAM
# ============================================================
send_tg() {
    local response
    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$1" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" 2>&1)
    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        local err=$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null)
        echo "$(date): send_tg failed: $err" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi
    return 0
}

send_tg_kb() {
    local text="$1"
    local keyboard="$2"
    local response
    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$text" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        local err
        err=$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null)
        echo "$(date): send_tg_kb failed: $err" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi
    echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null
    return 0
}

# ============================================================
# DHCP LEASES
# ============================================================
DHCP_LEASES="$(uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null)"
if [ -z "$DHCP_LEASES" ]; then
    DHCP_LEASES="/tmp/dhcp.leases"
fi

# ============================================================
# РОТАЦИЯ ЛОГОВ
# ============================================================
rotate_log() {
    local log_file="$1"
    local max_size=$((1024 * 1024))   # 1 МБ
    local lines_to_keep=500

    [ -f "$log_file" ] || return 0

    local size
    size=$(wc -c "$log_file" 2>/dev/null | awk '{print $1}')

    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac

    [ "$size" -gt "$max_size" ] || return 0

    local tmp="${log_file}.tmp"
    tail -n "$lines_to_keep" "$log_file" > "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        : > "$log_file"
        cat "$tmp" >> "$log_file"
    fi
    rm -f "$tmp"
}

# ============================================================
# МАРКЕРЫ ДЛИТЕЛЬНЫХ ОПЕРАЦИЙ
# ============================================================
_bot_mark_busy_start() {
    local op_name="${1:-unknown}"
    echo "$(date +%s)|${op_name}" > /tmp/telegram_bot/flags/busy_since

    if [ -f /tmp/telegram_bot/flags/busy_hb_pid ]; then
        local old_pid
        old_pid=$(cat /tmp/telegram_bot/flags/busy_hb_pid 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            return 0
        fi
        rm -f /tmp/telegram_bot/flags/busy_hb_pid
    fi

    local _keeper_parent_pid=$$
    (
        exec 200>&- 2>/dev/null
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
        printf 'keeper' > /proc/$$/comm 2>/dev/null  # <--- ДОБАВЛЕНА ЭТА СТРОКА
        i=0
        while [ -f /tmp/telegram_bot/flags/busy_since ] && [ "$i" -lt 30 ]; do
            if ! kill -0 "$_keeper_parent_pid" 2>/dev/null; then
                echo "$(date): _bot_mark_busy_start: keeper: parent $_keeper_parent_pid умер, выходим" >> /tmp/telegram_bot/logs/bot.log
                rm -f /tmp/telegram_bot/flags/busy_hb_pid
                exit 0
            fi
            echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot
            sleep 10 &
            wait $! 2>/dev/null
            i=$((i + 1))
        done
    ) &
    echo $! > /tmp/telegram_bot/flags/busy_hb_pid
}

_bot_mark_busy_end() {
    local since_file="/tmp/telegram_bot/flags/busy_since"

    if [ -f /tmp/telegram_bot/flags/busy_hb_pid ]; then
        local hb_pid
        hb_pid=$(cat /tmp/telegram_bot/flags/busy_hb_pid 2>/dev/null)
        if [ -n "$hb_pid" ] && kill -0 "$hb_pid" 2>/dev/null; then
            local _hb_comm=""
            [ -r "/proc/$hb_pid/comm" ] && _hb_comm=$(cat "/proc/$hb_pid/comm" 2>/dev/null)
            
            if [ "$_hb_comm" = "keeper" ]; then
                pkill -TERM -P "$hb_pid" 2>/dev/null
                kill -TERM "$hb_pid" 2>/dev/null
                pkill -9 -P "$hb_pid" 2>/dev/null
                kill -9 "$hb_pid" 2>/dev/null
            else
                echo "$(date): _bot_mark_busy_end: PID $hb_pid переиспользован (сейчас: $_hb_comm), не убиваю" >> /tmp/telegram_bot/logs/bot.log
            fi
        fi
        rm -f /tmp/telegram_bot/flags/busy_hb_pid
    fi

    [ -f "$since_file" ] || return 0

    local since
    since=$(cat "$since_file" 2>/dev/null)
    [ -z "$since" ] && { rm -f "$since_file"; return 0; }

    local start_ts op_name
    start_ts=$(echo "$since" | cut -d'|' -f1)
    op_name=$(echo "$since"  | cut -d'|' -f2)

    case "$start_ts" in
        ''|*[!0-9]*) rm -f "$since_file"; return 0 ;;
    esac

    local now dur
    now=$(date +%s)
    dur=$((now - start_ts))
    [ "$dur" -lt 0 ] && dur=0

    echo "${now}|${op_name}|${dur}" > /tmp/telegram_bot/flags/busy_until
    rm -f "$since_file"
}

_bot_check_busy() {
    local ttl="${1:-5}"
    local until_file="/tmp/telegram_bot/flags/busy_until"
    [ -f "$until_file" ] || return 1

    local until_data
    until_data=$(cat "$until_file" 2>/dev/null)
    [ -z "$until_data" ] && { rm -f "$until_file"; return 1; }

    local until_ts op_name dur
    until_ts=$(echo "$until_data" | cut -d'|' -f1)
    op_name=$(echo "$until_data"  | cut -d'|' -f2)
    dur=$(echo "$until_data"      | cut -d'|' -f3)

    case "$until_ts" in
        ''|*[!0-9]*) rm -f "$until_file"; return 1 ;;
    esac

    local now age
    now=$(date +%s)
    age=$((now - until_ts))
    [ "$age" -lt 0 ] && age=0

    if [ "$age" -gt 60 ]; then
        rm -f "$until_file"
        return 1
    fi

    if [ "$age" -gt "$ttl" ]; then
        return 1
    fi

    echo "${op_name}|${dur}"
    return 0
}

# ============================================================
# AWK-КЛАССИФИКАТОР ЛОГОВ
# ============================================================

AWK_CLASSIFY='
function classify_line(line,    body, body_low, sev) {
    sev = ""
    if (match(line, /\.(emerg|alert|crit|err|warn|notice|info|debug)[ :]/, sevm)) {
        sev = sevm[1]
    }

    # Отрезаем типичный префикс syslog, чтобы искать в теле.
    body = line
    sub(/^[A-Za-z]{3} +[A-Za-z]{3} +[0-9]+ [0-9:]+ [0-9]{4} [^ ]+ [a-z]+\.[a-z]+ [^:]+: /, "", body)
    sub(/^[A-Za-z]{3} +[0-9]+ [0-9:]+ [^ ]+ [a-z]+\.[a-z]+ [^:]+: /, "", body)
    sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]+[^ ]* [^ ]+ [a-z]+\.[a-z]+ [^:]+: /, "", body)
    body_low = tolower(body)

    if (body_low ~ /\[debug\]|\[info\]|\[notice\]/) {
        g_level = "info"
    } else if (body_low ~ /\[fatal|\[panic|\[crit/) {
        g_level = "crit"
    } else if (body_low ~ /\[err|\[error/) {
        g_level = "err"
    } else if (body_low ~ /\[warn|\[warning/) {
        g_level = "warn"
    } else {
        body_sev = "info"
        if (body_low ~ /(^|[^a-z])panic([^a-z]|$)|(^|[^a-z])oom([^a-z]|$)|(^|[^a-z])emerg([^a-z]|$)|(^|[^a-z])fatal([^a-z]|$)/)       body_sev = "crit"
        else if (body_low ~ /(^|[^a-z])error([^a-z]|$)|(^|[^a-z])critical([^a-z]|$)|(^|[^a-z])err:/)     body_sev = "err"
        else if (body_low ~ /(^|[^a-z])warn([^a-z]|$)|(^|[^a-z])warning([^a-z]|$)|(^|[^a-z])alert([^a-z]|$)|(^|[^a-z])timeout([^a-z]|$)/) body_sev = "warn"

        if (sev == "emerg" || sev == "alert" || sev == "crit" || body_sev == "crit") {
            g_level = "crit"
        } else if (sev == "err" || body_sev == "err") {
            g_level = "err"
        } else if (sev == "warn" || body_sev == "warn") {
            g_level = "warn"
        } else {
            g_level = "info"
        }
    }

    g_sev = sev
    g_body_low = body_low
    g_full_low = tolower(line)
    return g_level
}

function classify_category(line,    lvl, fl) {
    lvl = classify_line(line)
    if (lvl == "crit" || lvl == "err" || lvl == "warn") {
        g_category = lvl
        return g_category
    }
    fl = g_full_low
    if (fl ~ /netifd|pppd|pppoe|ppp|dhcp|dnsmasq|odhcpd/)  g_category = "net"
    else if (fl ~ /hostapd|wifi|ath|mt76|iwlwifi|wlan/)   g_category = "wifi"
    else if (fl ~ /kernel|dmesg|flash|storage|opkg|apk/)   g_category = "system"
    else                                                     g_category = "none"
    return g_category
}

function visual_len(s,    n, tmp) {
    n = length(s)
    tmp = s; while (match(tmp, /&amp;/)) { n -= 4; tmp = substr(tmp, RSTART + 5) }
    tmp = s; while (match(tmp, /&lt;/))  { n -= 3; tmp = substr(tmp, RSTART + 4) }
    tmp = s; while (match(tmp, /&gt;/))  { n -= 3; tmp = substr(tmp, RSTART + 4) }
    return n
}
'

# ============================================================
# ФИЛЬТР ИГНОРИРУЕМЫХ СОБЫТИЙ
# ============================================================
_EVENT_MUTE_FILE="/etc/telegram_bot/data/.event_mute_list"

_event_mute_ensure_file() {
    [ -f "$_EVENT_MUTE_FILE" ] && return 0
    cat > "$_EVENT_MUTE_FILE" <<'MUTE_EOF'
# ──────────────────────────────────────────────────────────
# Игнорируемые события event_monitor
# ──────────────────────────────────────────────────────────
# Формат: один regex на строку.
# Строки, начинающиеся с # — комментарии.
# --- TorrServer (DEBUG-логи в daemon.err) ---
TorrServer\[[0-9]+\]: .*(XPathDBRouter|Bonjour: advertising|No migration needed|Viewed migration result|trackerslist loaded from|Storage:|MCP Streamable|Client config:|PublicIp4:|Local IPs:|System DNS check passed|DNS resolution successful|Start http server at|Set listen port to random|Start TorrServer MatriX|=========== START|msg="Multicasting|msg="dht server|NIL github\.com|Check web port|Server stopped gracefully|Signal catched:)
# --- Системные шумы ---
rmdir\[ctrl_interface=
Keepalive timeout
possible DNS-rebind attack
crond.*started
ModemManager
procd: Got unexpected signal
MUTE_EOF
    chmod 600 "$_EVENT_MUTE_FILE"
}

_event_mute_build_filter() {
    local src="$_EVENT_MUTE_FILE"
    [ -s "$src" ] || return 1
    local tmp="/tmp/.event_mute_active.$$"
    grep -vE '^[[:space:]]*(#|$)' "$src" > "$tmp" 2>/dev/null
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    echo "$tmp"
}

_escape_user_pattern() {
    printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# ============================================================
# ============================================================
_EXEC_SESS_DIR="/tmp/telegram_bot/exec/session"
_EXEC_SOCK="$_EXEC_SESS_DIR/sock"
_EXEC_LOG="$_EXEC_SESS_DIR/log"
_EXEC_PID_FILE="$_EXEC_SESS_DIR/pid"
_EXEC_INNER_PID_FILE="$_EXEC_SESS_DIR/inner_pid"
_EXEC_LAST_FILE="$_EXEC_SESS_DIR/last_ts"
_EXEC_START_FILE="$_EXEC_SESS_DIR/start_ts"
_EXEC_STATE_FILE="$_EXEC_SESS_DIR/state"
_EXEC_MARK_FILE="$_EXEC_SESS_DIR/mark"
_EXEC_TIMEOUT=900
_EXEC_WAIT_MSG_FILE="/tmp/telegram_bot/exec/wait_msg_id"
_EXEC_DEFER_FILE="/tmp/telegram_bot/exec/defer_msgs"

_exec_session_active() {
    [ -f "$_EXEC_PID_FILE" ] || return 1
    local pid
    pid=$(cat "$_EXEC_PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -S "$_EXEC_SOCK" ] || return 1
    return 0
}

_exec_reap_orphans() {
    local current_pid=""
    local current_inner=""
    [ -f "$_EXEC_PID_FILE" ] && current_pid=$(cat "$_EXEC_PID_FILE" 2>/dev/null)
    [ -f "$_EXEC_INNER_PID_FILE" ] && current_inner=$(cat "$_EXEC_INNER_PID_FILE" 2>/dev/null)

    local killed=0
    local d pid target
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ -r "$d/cmdline" ] || continue

        [ -n "$current_pid" ] && [ "$pid" = "$current_pid" ] && continue
        [ -n "$current_inner" ] && [ "$pid" = "$current_inner" ] && continue

        [ -e "$d/fd/200" ] || continue
        target=$(readlink "$d/fd/200" 2>/dev/null)
        case "$target" in
            *'telegram_bot.lock (deleted)'*)
                kill -9 "$pid" 2>/dev/null && killed=$((killed + 1))
                ;;
        esac
    done

    [ "$killed" -gt 0 ] && echo "$(date): _exec_reap_orphans: убито $killed сирот" >> /tmp/telegram_bot/logs/bot.log
    return 0
}

_exec_session_start() {
    _exec_reap_orphans

    if _exec_session_active; then
        local state last_ts now idle
        state=$(cat "$_EXEC_STATE_FILE" 2>/dev/null)
        last_ts=$(cat "$_EXEC_LAST_FILE" 2>/dev/null)
        case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
        now=$(date +%s)
        idle=$((now - last_ts))

        if [ "$state" = "waiting" ] && [ "$idle" -gt 300 ]; then
            echo "$(date): _exec_session_start: сессия висит в waiting ${idle}s, пересоздаю" >> /tmp/telegram_bot/logs/bot.log
            _exec_session_stop
        else
            return 0
        fi
    fi

    if ! command -v sexpect >/dev/null 2>&1; then
        echo "$(date): _exec_session_start: sexpect не найден" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi

    rm -rf "$_EXEC_SESS_DIR"
    mkdir -p "$_EXEC_SESS_DIR"
    : > "$_EXEC_LOG"

    setsid sexpect -sock "$_EXEC_SOCK" spawn -t "$_EXEC_TIMEOUT" -nohup -nonblock \
    -logfile "$_EXEC_LOG" /bin/bash --norc --noprofile \
    </dev/null >/dev/null 2>&1 200<&-

    local _wait_sec=0
    local sexpect_pid=""
    while [ "$_wait_sec" -lt 5 ]; do
        if [ -S "$_EXEC_SOCK" ]; then
            sexpect_pid=$(pgrep -f "sexpect -sock $_EXEC_SOCK" 2>/dev/null | head -1)
            if [ -n "$sexpect_pid" ]; then
                break
            fi
        fi
        sleep 1
        _wait_sec=$((_wait_sec + 1))
    done

    if [ -z "$sexpect_pid" ]; then
        echo "$(date): _exec_session_start: sexpect не запустился (pgrep пусто)" >> /tmp/telegram_bot/logs/bot.log
        echo "$(date): DEBUG ps w:" >> /tmp/telegram_bot/logs/bot.log
        ps w 2>&1 | grep sexpect >> /tmp/telegram_bot/logs/bot.log 2>&1
        echo "$(date): DEBUG pgrep -af sexpect:" >> /tmp/telegram_bot/logs/bot.log
        pgrep -af sexpect >> /tmp/telegram_bot/logs/bot.log 2>&1
        echo "$(date): DEBUG ls exec_session:" >> /tmp/telegram_bot/logs/bot.log
        ls -la "$_EXEC_SESS_DIR" >> /tmp/telegram_bot/logs/bot.log 2>&1
        _exec_session_stop
        return 1
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout 5 sexpect -sock "$_EXEC_SOCK" send -enter \
            "stty -echo 2>/dev/null; set +H; unset HISTFILE; PS1='__PROMPT__ '" 2>/dev/null
    else
        sexpect -sock "$_EXEC_SOCK" send -enter \
            "stty -echo 2>/dev/null; set +H; unset HISTFILE; PS1='__PROMPT__ '" 2>/dev/null
    fi
    sleep 1

    local inner_pid
    inner_pid=$(pgrep -P "$sexpect_pid" bash 2>/dev/null | head -1)
    if [ -z "$inner_pid" ]; then
        echo "$(date): _exec_session_start: inner bash не найден (sexpect_pid=$sexpect_pid)" >> /tmp/telegram_bot/logs/bot.log
        _exec_session_stop
        return 1
    fi

    echo "$sexpect_pid" > "$_EXEC_PID_FILE"
    echo "$inner_pid"   > "$_EXEC_INNER_PID_FILE"
    date +%s > "$_EXEC_START_FILE"
    date +%s > "$_EXEC_LAST_FILE"
    echo "idle" > "$_EXEC_STATE_FILE"

    echo "$(date): _exec_session_start: sexpect=$sexpect_pid inner=$inner_pid sock=$_EXEC_SOCK" >> /tmp/telegram_bot/logs/bot.log
    return 0
}

_exec_clean_output() {
    local raw="$1"
    printf '%s' "$raw" | sed -E '
        s/\x1b\[[0-9;?]*[a-zA-Z]//g;
        s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g;
        s/\x1b[()][AB012]//g;
        s/\x1b[=>]//g;
        s/\x1b[MDE78c]//g;
    ' | tr -d '\r' | sed 's/__PROMPT__ //g'
}

_exec_session_send() {
    local cmd="$1"
    local wait_sec="${2:-90}"

    _EXEC_OUTPUT=""
    _EXEC_LAST_RC=0

    # Blacklist: интерактивные TTY-программы, имеют сломанный вывод.
    local first_word
    first_word=$(echo "$cmd" | awk '{print $1}')
    case "$first_word" in
        vi|vim|nano|pico|ed|emacs|joe|mcedit| \
        top|htop|atop|iotop|iftop|nethogs| \
        less|more|most| \
        mc|nnn|ranger|lf| \
        screen|tmux|byobu| \
        watch|tload|slurm|bmon| \
        alpine|mutt|pine|irssi|weechat| \
        whiptail|dialog| \
        lynx|links|w3m|elinks|browsh)
            _EXEC_OUTPUT="❌ <b>Команда '$first_word' не поддерживается</b>

Причина: интерактивная TTY-программа, требует интерактивной работы.

Что использовать вместо:
  vi/vim/nano  →  cat, sed, awk
  top/htop     →  ps, cat /proc/loadavg
  less/more    →  cat, grep, head, tail
  mc           →  ls, cd, cp, mv, rm"
            return 3
            ;;
    esac

    # Блокируем бесконечные команды с флагом -f
    if echo "$cmd" | grep -qE '(^| )(tail|journalctl|logread|dmesg)( .*)?( -f| --follow| -w| --wait)'; then
        _EXEC_OUTPUT="❌ <b>Команда с флагом отслеживания (-f / -w) не поддерживается</b>

Причина: такая команда будет работать бесконечно, 
блокируя exec-сессию и не давая получить результат.

Что использовать вместо:
  tail -f file       →  tail -n 50 file
  journalctl -f   →  journalctl -n 50
  logread -f      →  logread | tail -n 50
  dmesg -w      →  dmesg | tail -n 50"
        return 3
    fi

    _exec_session_active || return 2

    local state
    state=$(cat "$_EXEC_STATE_FILE" 2>/dev/null)
    [ -z "$state" ] && state="idle"

    local inner_pid
    inner_pid=$(cat "$_EXEC_INNER_PID_FILE" 2>/dev/null)
    [ -z "$inner_pid" ] && return 2
    kill -0 "$inner_pid" 2>/dev/null || return 2

    if [ "$state" = "waiting" ] || [ "$state" = "running" ]; then
        local cur_mark_chk
        cur_mark_chk=$(cat "$_EXEC_MARK_FILE" 2>/dev/null)
        if [ -n "$cur_mark_chk" ] && grep -q "${cur_mark_chk}END_RC=" "$_EXEC_LOG" 2>/dev/null; then
            if ! pgrep -P "$inner_pid" >/dev/null 2>&1; then
                echo "idle" > "$_EXEC_STATE_FILE"
                state="idle"
                rm -f "$_EXEC_MARK_FILE"
                echo "$(date): _exec_session_send: state исправлен waiting→idle (END_RC уже в логе)" >> /tmp/telegram_bot/logs/bot.log
            fi
        fi
    fi

    local before_size
    before_size=$(wc -c < "$_EXEC_LOG" 2>/dev/null)
    case "$before_size" in ''|*[!0-9]*) before_size=0 ;; esac

    # ============================================================
    # WAITING
    # ============================================================
    if [ "$state" = "waiting" ]; then
        local cur_mark
        cur_mark=$(cat "$_EXEC_MARK_FILE" 2>/dev/null)

        if command -v timeout >/dev/null 2>&1; then
            timeout 5 sexpect -sock "$_EXEC_SOCK" send -enter "$cmd" 2>/dev/null
        else
            sexpect -sock "$_EXEC_SOCK" send -enter "$cmd" 2>/dev/null
        fi
        date +%s > "$_EXEC_LAST_FILE"

        local last_start_line=""
        if [ -n "$cur_mark" ]; then
            last_start_line=$(grep -n "${cur_mark}START" "$_EXEC_LOG" 2>/dev/null \
                | tail -1 | cut -d: -f1)
        fi

        local i=0
        while [ "$i" -lt 5 ]; do
            if [ -n "$cur_mark" ] && grep -q "${cur_mark}END_RC=" "$_EXEC_LOG" 2>/dev/null; then

                local _tail
                if [ -n "$last_start_line" ]; then
                    _tail=$(tail -n +"$last_start_line" "$_EXEC_LOG" 2>/dev/null)
                else
                    _tail=$(cat "$_EXEC_LOG" 2>/dev/null)
                fi

                _EXEC_LAST_RC=$(echo "$_tail" \
                    | grep -o "${cur_mark}END_RC=[0-9]*" | tail -1 \
                    | sed 's/.*=//')
                [ -z "$_EXEC_LAST_RC" ] && _EXEC_LAST_RC=0

                _EXEC_OUTPUT=$(echo "$_tail" \
                    | sed -n "/${cur_mark}START/,/${cur_mark}END_RC=/p" \
                    | sed '1d;$d')

                _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")

                _EXEC_OUTPUT=$(printf '%s' "$_EXEC_OUTPUT" \
                    | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

                echo "idle" > "$_EXEC_STATE_FILE"
                rm -f "$_EXEC_MARK_FILE"
                return 0
            fi
            sleep 1
            i=$((i + 1))
        done

        local _tail
        if [ -n "$last_start_line" ]; then
            _tail=$(tail -n +"$last_start_line" "$_EXEC_LOG" 2>/dev/null)
            _EXEC_OUTPUT=$(echo "$_tail" | sed '1d')
        else
            _EXEC_OUTPUT=""
        fi
        _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")

        return 1
    fi

    # ============================================================
    # RUNNING 
    # ============================================================
    if [ "$state" = "running" ]; then
        _EXEC_OUTPUT=""
        _EXEC_LAST_RC=0
        return 5
    fi

    # ============================================================
    # IDLE
    # ============================================================
    local mark="__M$$_${RANDOM}_$(date +%s)__"
    echo "$mark" > "$_EXEC_MARK_FILE"
    echo "running" > "$_EXEC_STATE_FILE"

    printf '%s' "$cmd" > /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null

    local _sent="echo ${mark}START; $cmd; echo ${mark}END_RC=\$?"
    echo "$(date): _exec_session_send: BEFORE sexpect send" >> /tmp/telegram_bot/logs/bot.log

    if command -v timeout >/dev/null 2>&1; then
        timeout 5 sexpect -sock "$_EXEC_SOCK" send "$_sent" 2>/dev/null
    else
        sexpect -sock "$_EXEC_SOCK" send "$_sent" 2>/dev/null
    fi
    sleep 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 sexpect -sock "$_EXEC_SOCK" send $'\n' 2>/dev/null
    else
        sexpect -sock "$_EXEC_SOCK" send $'\n' 2>/dev/null
    fi

    echo "$(date): _exec_session_send: AFTER sexpect send" >> /tmp/telegram_bot/logs/bot.log
    date +%s > "$_EXEC_LAST_FILE"

    local i=0
    local quiet_sec=3
    local quiet_elapsed=0
    local last_size="$before_size"

    while [ "$i" -lt "$wait_sec" ]; do
        echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot

        if [ $((i % 3)) -eq 0 ] && [ "$i" -gt 0 ] && [ -n "$BOT_TOKEN" ]; then
            local _peek_offset=$((LAST_UPDATE_ID + 1))
            local _peek
            _peek=$(curl -s --connect-timeout 2 --max-time 4 \
                "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$_peek_offset&limit=100" 2>/dev/null)

            if [ -n "$_peek" ] && echo "$_peek" | jq -e '.ok' >/dev/null 2>&1; then
                local _peek_count
                _peek_count=$(echo "$_peek" | jq -r '.result | length' 2>/dev/null)
                case "$_peek_count" in ''|*[!0-9]*) _peek_count=0 ;; esac

                local _pi=0
                while [ "$_pi" -lt "$_peek_count" ]; do
                    local _puid _ptype _ptext _pcb_id
                    _puid=$(echo "$_peek" | jq -r ".result[$_pi].update_id // empty" 2>/dev/null)
                    [ -z "$_puid" ] && { _pi=$((_pi + 1)); continue; }

                    _ptype=$(echo "$_peek" | jq -r \
                        "if .result[$_pi].callback_query then \"callback\" elif .result[$_pi].message.text then \"message\" else \"other\" end" \
                        2>/dev/null)

                    case "$_ptype" in
                        callback)
                            _pcb_id=$(echo "$_peek" | jq -r ".result[$_pi].callback_query.id // empty" 2>/dev/null)
                            if [ -n "$_pcb_id" ]; then
                                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" \
                                    -d callback_query_id="$_pcb_id" \
                                    --data-urlencode text="⏳ Дождитесь выполнения команды" \
                                    -d show_alert="false" >/dev/null 2>&1
                            fi
                            LAST_UPDATE_ID="$_puid"
                            echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                            ;;

                        message)
                            _ptext=$(echo "$_peek" | jq -r ".result[$_pi].message.text // \"\"" 2>/dev/null)
                            _pmsg_id=$(echo "$_peek" | jq -r ".result[$_pi].message.message_id // empty" 2>/dev/null)
							
                            if echo "$_ptext" | grep -qiE "^/restart$|^перезапуск$|^restart$"; then
                                LAST_UPDATE_ID="$_puid"
                                echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                echo "$(date): peek: /restart перехвачен, останавливаю exec и запускаю restart_bot.sh" >> /tmp/telegram_bot/logs/bot.log

                                local _rst_resp
                                _rst_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                                    -d chat_id="$CHAT_ID" \
                                    --data-urlencode text="🔄 <b>Перезапуск бота...</b>" \
                                    -d parse_mode="HTML" 2>&1)
                                local _rst_mid
                                _rst_mid=$(echo "$_rst_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
                                if [ -n "$_rst_mid" ]; then
                                    echo "$_rst_mid" > /tmp/telegram_bot/state/bot_restart_msg_id
                                fi

                                _exec_session_kill 2>/dev/null
                                _exec_session_stop 2>/dev/null

                                if [ -f "$_EXEC_DEFER_FILE" ]; then
                                    while IFS= read -r _did; do
                                        [ -z "$_did" ] && continue
                                        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                                            -d chat_id="$CHAT_ID" \
                                            -d message_id="$_did" >/dev/null 2>&1
                                    done < "$_EXEC_DEFER_FILE"
                                    rm -f "$_EXEC_DEFER_FILE"
                                fi

                                /etc/telegram_bot/restart_bot.sh > /tmp/telegram_bot/logs/restart.log 2>&1 &

                                sleep 1
                                exit 0
                            fi

                            case "$_ptext" in
                                "/exec _eof")
                                    LAST_UPDATE_ID="$_puid"
                                    echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                    echo "$(date): peek: _eof — Ctrl+D в PTY" >> /tmp/telegram_bot/logs/bot.log
                                    sexpect -sock "$_EXEC_SOCK" send $'\x04' 2>/dev/null
                                    ;;

                                "/exec _exit")
                                    LAST_UPDATE_ID="$_puid"
                                    echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                    echo "$(date): peek: _exit — принудительное закрытие" >> /tmp/telegram_bot/logs/bot.log
                                    _exec_session_kill 2>/dev/null
                                    _exec_session_stop 2>/dev/null
                                    return 100
                                    ;;

                                "/exec _ctrlc")
                                    LAST_UPDATE_ID="$_puid"
                                    echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                    echo "$(date): peek: _ctrlc перехвачен, consume+kill" >> /tmp/telegram_bot/logs/bot.log

                                    _exec_session_kill

                                    local _rc_wait=0
                                    while [ "$_rc_wait" -lt 5 ]; do
                                        if tail -c +$((before_size + 1)) "$_EXEC_LOG" 2>/dev/null \
                                                | grep -q "${mark}END_RC="; then
                                            break
                                        fi
                                        sleep 1
                                        _rc_wait=$((_rc_wait + 1))
                                    done

                                    local _tail_k
                                    _tail_k=$(tail -c +$((before_size + 1)) "$_EXEC_LOG" 2>/dev/null)

                                    _EXEC_LAST_RC=$(echo "$_tail_k" \
                                        | grep -o "${mark}END_RC=[0-9]*" | tail -1 \
                                        | sed 's/.*=//')
                                    # 143/137 после Ctrl+C — это 130 по смыслу.
                                    if [ -z "$_EXEC_LAST_RC" ] || [ "$_EXEC_LAST_RC" = "143" ] || [ "$_EXEC_LAST_RC" = "137" ]; then
                                        _EXEC_LAST_RC=130
                                    fi

                                    _EXEC_OUTPUT=$(echo "$_tail_k" \
                                        | sed -n "/${mark}START/,/${mark}END_RC=/p" \
                                        | sed '1d;$d')
                                    _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")

                                    return 99
                                    ;;

                                "/exec _status")
                                    LAST_UPDATE_ID="$_puid"
                                    echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                    _exec_session_status
                                    local _st_text="📟 <b>Exec-сессия активна (выполняется команда)</b>

<pre>$_EXEC_STATUS</pre>"
                                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                                        -d chat_id="$CHAT_ID" \
                                        --data-urlencode text="$_st_text" \
                                        -d parse_mode="HTML" >/dev/null 2>&1
                                    echo "$(date): peek: _status обработан в wait loop" >> /tmp/telegram_bot/logs/bot.log
                                    ;;

                                *)
                                    if [ -f "$_EXEC_DEFER_FILE" ]; then
                                        local _prev_dw
                                        _prev_dw=$(cat "$_EXEC_DEFER_FILE" 2>/dev/null | tr -d '\n\r ')
                                        if [ -n "$_prev_dw" ]; then
                                            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                                                -d chat_id="$CHAT_ID" \
                                                -d message_id="$_prev_dw" >/dev/null 2>&1
                                        fi
                                    fi

                                    local _dw_resp
                                    _dw_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                                        -d chat_id="$CHAT_ID" \
                                        --data-urlencode text="⏳ Дождитесь выполнения команды" \
                                        -d parse_mode="HTML" 2>&1)
                                    local _dw_mid
                                    _dw_mid=$(echo "$_dw_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
                                    if [ -n "$_dw_mid" ]; then
                                        echo "$_dw_mid" > "$_EXEC_DEFER_FILE"
                                    fi
                                    if [ -n "$_pmsg_id" ]; then
                                        echo "$_pmsg_id" >> "/tmp/telegram_bot/exec/pending_user_msgs"
                                    fi
                                    LAST_UPDATE_ID="$_puid"
                                    echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                                    ;;
                            esac
                            ;;
                        *)
                            LAST_UPDATE_ID="$_puid"
                            echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
                            ;;
                    esac

                    _pi=$((_pi + 1))
                done
            fi
        fi

        if grep -q "${mark}END_RC=" "$_EXEC_LOG" 2>/dev/null; then

            local _tail
            _tail=$(cat "$_EXEC_LOG" 2>/dev/null)

            _EXEC_LAST_RC=$(echo "$_tail" \
                | grep -o "${mark}END_RC=[0-9]*" | tail -1 \
                | sed 's/.*=//')
            [ -z "$_EXEC_LAST_RC" ] && _EXEC_LAST_RC=0

            _EXEC_OUTPUT=$(echo "$_tail" \
                | sed -n "/${mark}START/,/${mark}END_RC=/p" \
                | sed '1d;$d')

            _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")
            _EXEC_OUTPUT=$(printf '%s' "$_EXEC_OUTPUT" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

            echo "idle" > "$_EXEC_STATE_FILE"
            rm -f "$_EXEC_MARK_FILE"
            return 0
        fi

        local cur_size
        cur_size=$(wc -c < "$_EXEC_LOG" 2>/dev/null)
        case "$cur_size" in ''|*[!0-9]*) cur_size=0 ;; esac

        if [ "$cur_size" -gt "$last_size" ]; then
            quiet_elapsed=0
            last_size="$cur_size"
        else
            quiet_elapsed=$((quiet_elapsed + 1))
        fi

        if [ "$quiet_elapsed" -ge "$quiet_sec" ]; then
            if pgrep -P "$inner_pid" >/dev/null 2>&1; then
                local _early_child _early_sc
                _early_child=$(pgrep -P "$inner_pid" 2>/dev/null | head -1)
                if _is_read_wait "$_early_child"; then
                    local _tail
                    _tail=$(tail -c +$((before_size + 1)) "$_EXEC_LOG" 2>/dev/null)
                    _EXEC_OUTPUT=$(echo "$_tail" \
                        | sed -n "/${mark}START/,\$p" \
                        | sed '1d')
                    _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")
                    echo "waiting" > "$_EXEC_STATE_FILE"
                    return 1
                fi
                quiet_elapsed=0
                sleep 1
                i=$((i + 1))
                continue
            else
                quiet_elapsed=0
                sleep 1
                i=$((i + 1))
                continue
            fi
        fi

        sleep 1
        i=$((i + 1))
    done

    local _tail
    _tail=$(tail -c +$((before_size + 1)) "$_EXEC_LOG" 2>/dev/null)
    _EXEC_OUTPUT=$(echo "$_tail" \
        | sed -n "/${mark}START/,\$p" | sed '1d')
    _EXEC_OUTPUT=$(_exec_clean_output "$_EXEC_OUTPUT")

    if ! grep -q "${mark}END_RC=" "$_EXEC_LOG" 2>/dev/null \
       && sed -n "/${mark}START/,\$p" "$_EXEC_LOG" 2>/dev/null | grep -q '__PROMPT__' \
       && ! pgrep -P "$inner_pid" >/dev/null 2>&1; then
        echo "$(date): _exec_session_send: fallback — PROMPT без END_RC, код 1" >> /tmp/telegram_bot/logs/bot.log
        echo "idle" > "$_EXEC_STATE_FILE"
        rm -f "$_EXEC_MARK_FILE"
        _EXEC_LAST_RC=1
        return 0
    fi

    if pgrep -P "$inner_pid" >/dev/null 2>&1; then
        local _child_pid
        _child_pid=$(pgrep -P "$inner_pid" 2>/dev/null | head -1)

        if _is_read_wait "$_child_pid"; then
            echo "waiting" > "$_EXEC_STATE_FILE"
            return 1
        else
            echo "running" > "$_EXEC_STATE_FILE"
            return 4
        fi
    else
        echo "waiting" > "$_EXEC_STATE_FILE"
        return 1
    fi
}

_exec_session_refresh_state() {
    local state
    state=$(cat "$_EXEC_STATE_FILE" 2>/dev/null)
    case "$state" in
        waiting) ;;
        *) return 0 ;;
    esac

    local cur_mark
    cur_mark=$(cat "$_EXEC_MARK_FILE" 2>/dev/null)
    [ -z "$cur_mark" ] && return 0

    if grep -q "${cur_mark}END_RC=" "$_EXEC_LOG" 2>/dev/null; then
        local inner_pid
        inner_pid=$(cat "$_EXEC_INNER_PID_FILE" 2>/dev/null)

        if [ -z "$inner_pid" ] || ! pgrep -P "$inner_pid" >/dev/null 2>&1; then
            echo "idle" > "$_EXEC_STATE_FILE"
            echo "$(date): _exec_session_refresh_state: waiting → idle (END_RC в логе)" >> /tmp/telegram_bot/logs/bot.log
        fi
    fi
}

_exec_session_status() {
    _exec_session_refresh_state

    _EXEC_STATUS=""
    if ! _exec_session_active; then
        _EXEC_STATUS="не активна"
        return 1
    fi

    local sexpect_pid inner_pid start_ts last_ts state now
    sexpect_pid=$(cat "$_EXEC_PID_FILE" 2>/dev/null)
    inner_pid=$(cat "$_EXEC_INNER_PID_FILE" 2>/dev/null)
    start_ts=$(cat "$_EXEC_START_FILE" 2>/dev/null)
    last_ts=$(cat "$_EXEC_LAST_FILE" 2>/dev/null)
    state=$(cat "$_EXEC_STATE_FILE" 2>/dev/null)
    now=$(date +%s)

    case "$start_ts" in ''|*[!0-9]*) start_ts=$now ;; esac
    case "$last_ts"  in ''|*[!0-9]*) last_ts=$now ;; esac
    [ -z "$state" ] && state="idle"

    local state_label="готова"
    [ "$state" = "waiting" ] && state_label="ждёт ввод"
    [ "$state" = "running" ] && state_label="выполняется"

    _EXEC_STATUS="PID=$inner_pid uptime=$((now - start_ts))s idle=$((now - last_ts))s  [$state_label]"
    return 0
}

_exec_session_stop() {
    rm -f "$_EXEC_WAIT_MSG_FILE" "$_EXEC_MARK_FILE" "$_EXEC_DEFER_FILE"

    if [ -n "$_EXEC_SOCK" ]; then
        pkill -9 -f "sexpect -sock $_EXEC_SOCK" 2>/dev/null
    fi

    sexpect -sock "$_EXEC_SOCK" close 2>/dev/null

    sleep 1

    local pid
    if [ -f "$_EXEC_PID_FILE" ]; then
        pid=$(cat "$_EXEC_PID_FILE" 2>/dev/null)
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    fi

    rm -rf "$_EXEC_SESS_DIR"
    return 0
}

_exec_all_descendants() {
    local root_pid="$1"
    local result=""
    local queue="$root_pid"
    local visited="$root_pid"

    local iterations=0
    while [ -n "$queue" ] && [ "$iterations" -lt 20 ]; do
        iterations=$((iterations + 1))
        local next_queue=""
        local p
        for p in $queue; do
            local kids
            kids=$(pgrep -P "$p" 2>/dev/null)
            local k
            for k in $kids; do
                case " $visited " in
                    *" $k "*) continue ;;
                esac
                visited="$visited $k"
                result="$result $k"
                next_queue="$next_queue $k"
            done
        done
        queue="$next_queue"
    done

    result="${result# }"
    printf '%s' "$result"
}

# Прерывает текущую команду (аналог Ctrl+C).
_exec_session_kill() {
    _exec_session_active || return 1

    local inner_pid
    inner_pid=$(cat "$_EXEC_INNER_PID_FILE" 2>/dev/null)
    [ -z "$inner_pid" ] && return 1

    local had_children=0

    local descendants
    descendants=$(_exec_all_descendants "$inner_pid")

    if [ -z "$descendants" ]; then
        sleep 1
        descendants=$(_exec_all_descendants "$inner_pid")
    fi

    if [ -n "$descendants" ]; then
        had_children=1

        local dp
        for dp in $descendants; do
            kill -INT "$dp" 2>/dev/null
        done
        sleep 1

        descendants=$(_exec_all_descendants "$inner_pid")
        for dp in $descendants; do
            kill -TERM "$dp" 2>/dev/null
        done
        sleep 1

        descendants=$(_exec_all_descendants "$inner_pid")
        for dp in $descendants; do
            kill -9 "$dp" 2>/dev/null
        done
    fi

    sexpect -sock "$_EXEC_SOCK" send -enter $'\x03' 2>/dev/null
    sleep 1

    echo "idle" > "$_EXEC_STATE_FILE"
    rm -f "$_EXEC_MARK_FILE"

    [ "$had_children" = "1" ] && return 0 || return 1
}

_exec_autopush_result() {
    [ -f /tmp/telegram_bot/exec/wait_msg_id ] || return 1
    [ -f "$_EXEC_MARK_FILE" ] || return 1

    local msg_id
    msg_id=$(cat /tmp/telegram_bot/exec/wait_msg_id 2>/dev/null | tr -d '\n\r ')
    [ -z "$msg_id" ] && return 1

    local mark
    mark=$(cat "$_EXEC_MARK_FILE" 2>/dev/null)
    [ -z "$mark" ] && return 1

    grep -q "${mark}END_RC=" "$_EXEC_LOG" 2>/dev/null || return 1

    local _tail
    _tail=$(cat "$_EXEC_LOG" 2>/dev/null)

    local rc
    rc=$(echo "$_tail" | grep -o "${mark}END_RC=[0-9]*" | tail -1 | sed 's/.*=//')
    [ -z "$rc" ] && rc=0

    if [ "$rc" = "143" ] || [ "$rc" = "137" ]; then
        rc=130
    fi

    local out
    out=$(echo "$_tail" | sed -n "/${mark}START/,/${mark}END_RC=/p" | sed '1d;$d')
    out=$(_exec_clean_output "$out")
    out=$(printf '%s' "$out" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
    [ -z "$out" ] && out="(нет вывода)"

    local cmd
    cmd=$(cat /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null)
    [ -z "$cmd" ] && cmd="(команда)"

    if declare -F _exec_send_output >/dev/null 2>&1; then
        _exec_send_output "$cmd" "$out" "$rc" "$msg_id"
        
        if [ "$?" -ne 0 ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" \
                -d message_id="$msg_id" >/dev/null 2>&1
            _exec_send_output "$cmd" "$out" "$rc" ""
        fi
    fi

    rm -f /tmp/telegram_bot/explorer/view_lock 2>/dev/null
    rm -f /tmp/telegram_bot/exec/wait_msg_id /tmp/telegram_bot/exec/session/last_cmd
    rm -f "$_EXEC_MARK_FILE"

    echo "idle" > "$_EXEC_STATE_FILE"

    echo "$(date): _exec_autopush_result: rc=$rc msg_id=$msg_id (new msg below defer spam)" >> /tmp/telegram_bot/logs/bot.log
    return 0
}

# Авто-таймаут сессии.
_exec_session_check_timeout() {
    _exec_session_active || return 0
    [ -f "$_EXEC_LAST_FILE" ] || return 0

    local last_ts now idle
    last_ts=$(cat "$_EXEC_LAST_FILE" 2>/dev/null)
    case "$last_ts" in ''|*[!0-9]*) return 0 ;; esac

    now=$(date +%s)
    idle=$((now - last_ts))
    if [ "$idle" -gt "$_EXEC_TIMEOUT" ]; then
        echo "$(date): _exec_session_check_timeout: idle=${idle}s, closing" >> /tmp/telegram_bot/logs/bot.log
        _exec_session_stop
    fi
    return 0
}

_event_mute_ensure_file

# ============================================================
# РЕГИСТРАЦИЯ МЕНЮ КОМАНД
# ============================================================
_setup_bot_commands() {
    local commands='[
        {"command":"online",    "description":"🖥️ Клиенты онлайн"},
        {"command":"speed",     "description":"⏱ Ограничить скорость"},
        {"command":"traffic",   "description":"📊 Трафик по устройствам"},		
        {"command":"wifi",      "description":"🛜 Настройка Wi-Fi"},
        {"command":"services",  "description":"🔧 Автозапуск служб"},
        {"command":"explorer",  "description":"📁 Проводник"},
        {"command":"system",    "description":"📊 Статус системы"},
        {"command":"critical",  "description":"📋 Журнал событий"},
        {"command":"wake",      "description":"🌐 Wake-on-LAN"},
        {"command":"unfixip",   "description":"📌 Снять фиксацию IP"},
        {"command":"speedtest", "description":"⚡ Speedtest"},
        {"command":"uptime",    "description":"🕒 Время работы роутера"},
        {"command":"reboot",    "description":"🔴 Перезагрузить роутер"},
		{"command":"status",    "description":"📊 Статус бота"},
        {"command":"help",      "description":"📖 Справка по командам"}
    ]'
    (
        local _try=0
        while [ "$_try" -lt 10 ]; do
            local _resp
            _resp=$(curl -s --connect-timeout 5 --max-time 10 \
                -X POST "https://api.telegram.org/bot$BOT_TOKEN/setMyCommands" \
                --data-urlencode "commands=$commands" 2>/dev/null)
            
            if echo "$_resp" | jq -e '.ok' >/dev/null 2>&1; then
                echo "$(date): _setup_bot_commands: команды успешно зарегистрированы" >> /tmp/telegram_bot/logs/bot.log
                return 0
            fi
            
            _try=$((_try + 1))
            sleep 10
        done
        echo "$(date): _setup_bot_commands: не удалось зарегистрировать команды после 10 попыток" >> /tmp/telegram_bot/logs/bot.log
    ) >/dev/null 2>&1 &
}

# ============================================================
# АВТОФИКС ПЕРЕВОДОВ СТРОК В AWK
# ============================================================
_fix_awk_multiline() {
    local input="$1"
    [ -z "$input" ] && return 0

    local in_dq=0
    local result=""
    local i=0
    local len=${#input}
    local prev_start=0
    local ch line stripped q_count

    while [ "$i" -lt "$len" ]; do
        ch="${input:$i:1}"
        if [ "$ch" = $'\n' ]; then
            line="${input:$prev_start:$((i - prev_start))}"

            if [ "$prev_start" -eq 0 ]; then
                result="$line"
            elif [ "$in_dq" = "1" ]; then
                result="${result}\\n${line}"
            else
                result="${result}"$'\n'"${line}"
            fi

            stripped="${line//\\\"/}"
            q_count="${stripped//[^\"]/}"
            if [ $(( ${#q_count} % 2 )) -eq 1 ]; then
                if [ "$in_dq" = "1" ]; then in_dq=0; else in_dq=1; fi
            fi

            prev_start=$((i + 1))
        fi
        i=$((i + 1))
    done

    if [ "$prev_start" -lt "$len" ]; then
        line="${input:$prev_start}"
        if [ "$prev_start" -eq 0 ]; then
            result="$line"
        elif [ "$in_dq" = "1" ]; then
            result="${result}\\n${line}"
        else
            result="${result}"$'\n'"${line}"
        fi
    fi

    printf '%s' "$result"
}

# ============================================================
# ТЕМПЕРАТУРЫ — УНИВЕРСАЛЬНОЕ ЧТЕНИЕ
# ============================================================
_sys_normalize_temp_raw() {
    local raw="$1"

    case "$raw" in
        ''|-) return 1 ;;
    esac

    local _abs="${raw#-}"
    case "$_abs" in
        ''|*[!0-9]*) return 1 ;;
    esac

    # Если > 1000 — миллиградусы
    if [ "$_abs" -gt 1000 ]; then
        echo $((raw / 1000))
        return 0
    fi

    # Если <= 100 — готовые градусы 
    if [ "$_abs" -le 100 ]; then
        echo "$raw"
        return 0
    fi

    return 1
}

_sys_cpu_temp_raw() {
    local p zone_type hw_name raw _norm

    for p in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$p" ] || continue
        zone_type=$(cat "${p%/temp}/type" 2>/dev/null)
        case "$zone_type" in
            cpu-thermal|cpu_thermal|cpu|soc-thermal|soc_thermal|soc|x86_pkg_temp|coretemp|acpitz)
                raw=$(cat "$p" 2>/dev/null)
                _norm=$(_sys_normalize_temp_raw "$raw") || continue
                echo "$_norm"
                return 0
                ;;
        esac
    done

    for p in /sys/class/hwmon/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        hw_name=$(cat "${p%/temp1_input}/name" 2>/dev/null)
        case "$hw_name" in
            cpu_thermal|cpu-thermal|cpu|soc_thermal|soc-thermal|soc|coretemp|k10temp|zenpower)
                raw=$(cat "$p" 2>/dev/null)
                _norm=$(_sys_normalize_temp_raw "$raw") || continue
                echo "$_norm"
                return 0
                ;;
        esac
    done

    for p in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$p" ] || continue
        raw=$(cat "$p" 2>/dev/null)
        _norm=$(_sys_normalize_temp_raw "$raw") || continue
        echo "$_norm"
        return 0
    done

    for p in /sys/class/hwmon/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        raw=$(cat "$p" 2>/dev/null)
        _norm=$(_sys_normalize_temp_raw "$raw") || continue
        echo "$_norm"
        return 0
    done

    return 1
}

_sys_cpu_temp() {
    local t
    t=$(_sys_cpu_temp_raw)
    if [ -n "$t" ]; then echo "${t}°C"; else echo "N/A"; fi
}

_sys_wifi_temp_raw() {
    local phy_name="${1:-phy0}"
    local p hw_name raw _norm

    for p in /sys/class/hwmon/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        hw_name=$(cat "${p%/temp1_input}/name" 2>/dev/null)
        case "$hw_name" in
            *"$phy_name"*)
                raw=$(cat "$p" 2>/dev/null)
                _norm=$(_sys_normalize_temp_raw "$raw") || continue
                echo "$_norm"
                return 0
                ;;
        esac
    done

    for p in /sys/class/ieee80211/"$phy_name"/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        raw=$(cat "$p" 2>/dev/null)
        _norm=$(_sys_normalize_temp_raw "$raw") || continue
        echo "$_norm"
        return 0
    done

    for p in /sys/class/ieee80211/"$phy_name"/device/hwmon/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        raw=$(cat "$p" 2>/dev/null)
        _norm=$(_sys_normalize_temp_raw "$raw") || continue
        echo "$_norm"
        return 0
    done

    for p in /sys/class/net/"${phy_name}-ap0"/device/hwmon/hwmon*/temp1_input \
             /sys/class/net/"$phy_name"/device/hwmon/hwmon*/temp1_input; do
        [ -f "$p" ] || continue
        raw=$(cat "$p" 2>/dev/null)
        _norm=$(_sys_normalize_temp_raw "$raw") || continue
        echo "$_norm"
        return 0
    done

    return 1
}

_sys_wifi_temp() {
    local phy="${1:-phy0}"
    local t
    t=$(_sys_wifi_temp_raw "$phy")
    if [ -n "$t" ]; then echo "${t}°C"; else echo "N/A"; fi
}

# ============================================================
# МЕНЮ — ОТПРАВКА С УЧЁТОМ ФЛАГА /keyboard
# ============================================================
_BOT_MENU_MSG_FILE="/tmp/telegram_bot/state/bot_menu_msg_id"

_send_menu_tracked() {
    local text="${1:-🏠 <b>Выберите действие</b>}"
    local keyboard="${2:-$MAIN_KEYBOARD}"

    if [ -f "/etc/telegram_bot/data/.no_reply_kb" ]; then
        keyboard='{"remove_keyboard":true}'
    fi

    if [ -f "$_BOT_MENU_MSG_FILE" ]; then
        local _old
        _old=$(cat "$_BOT_MENU_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_old" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" \
                -d message_id="$_old" >/dev/null 2>&1
        fi
    fi

    local _resp
    if [ -n "$keyboard" ]; then
        _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
    else
        _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" 2>&1)
    fi

    local _new
    _new=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    if [ -n "$_new" ]; then
        echo "$_new" > "$_BOT_MENU_MSG_FILE"
    fi
}

_bot_kill_main_menu() {
    if [ -f "$_BOT_MENU_MSG_FILE" ]; then
        local _mid=$(cat "$_BOT_MENU_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_mid" ]; then
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1 &
        fi
        rm -f "$_BOT_MENU_MSG_FILE"
    fi
}

_bot_edit_menu_to_section() {
    local text="$1"
    local keyboard="$2"
    if [ -f "/etc/telegram_bot/data/.no_reply_kb" ] && [ "$keyboard" = "$MAIN_KEYBOARD" ]; then
        keyboard='{"remove_keyboard":true}'
    fi
    local _menu_id=""
    [ -f "$_BOT_MENU_MSG_FILE" ] && _menu_id=$(cat "$_BOT_MENU_MSG_FILE" 2>/dev/null | tr -d '\n\r ')

    if [ -n "$_IN_TEXT_MSG_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1 &
        _IN_TEXT_MSG_ID=""
    fi

    if [ -n "$_menu_id" ]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_menu_id" >/dev/null 2>&1 &
        rm -f "$_BOT_MENU_MSG_FILE"
    fi

    local resp
    resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$text" \
        -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    echo "$new_id"
    return 0
}

# Нужна только для /help.
_BOT_BUILD_ID="V29vbGFnYXJvbw=="
_bot_build_string() {
    printf '%s' "$_BOT_BUILD_ID" | base64 -d 2>/dev/null
}

_bot_check_update() {
    local local_ver="0.0.0"
    [ -f "/etc/telegram_bot/VERSION" ] && local_ver=$(cat "/etc/telegram_bot/VERSION" | tr -d '\n\r ')

    local remote_ver=$(curl -s --connect-timeout 5 --max-time 10 "https://raw.githubusercontent.com/Woolagaroo/woo-wrt-tgbot/main/VERSION" | tr -d '\n\r ')

    if [ -n "$remote_ver" ] && [ "$local_ver" != "$remote_ver" ]; then
        echo "$remote_ver"
    else
        echo ""
    fi
}

# ============================================================
# ОТЛАДОЧНЫЙ РЕЖИМ И ФУНКЦИЯ ЛОГИРОВАНИЯ
# ============================================================
if [ -f "/tmp/telegram_bot/flags/bot_debug" ]; then
    BOT_DEBUG=1
else
    BOT_DEBUG=0
fi

_bot_dbg() {
    [ "$BOT_DEBUG" = "1" ] && echo "$@" >> /tmp/telegram_bot/logs/bot.log
}

_BOT_DISABLED_FLAG="/etc/telegram_bot/.bot_disabled"
