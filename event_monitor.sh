#!/bin/bash
# ============================================================
# Фоновый монитор событий.
# Следит за: новыми устройствами в сети, критическими логами,
# порогами RAM/температуры, невалидными Wi-Fi каналами и
# STA-мониторами.
# ============================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

. /etc/telegram_bot/bot_config.sh

if [ -f "/etc/telegram_bot/.bot_disabled" ]; then
    exit 0
fi

# Watchdog ждёт этот файл, если устарел на 300с — перезапускает monitor.
_event_heartbeat() { echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/event; }
_event_heartbeat

# ============================================================
# LAN-МОНИТОР (только проводные порты lanN/ethN)
# ============================================================

_lan_snapshot() {
    local _br="$1"
    declare -A _p2n
    if [ -d "/sys/class/net/$_br/brif" ]; then
        local _p _ifn _h
        for _p in "/sys/class/net/$_br/brif/"*; do
            [ -e "$_p" ] || continue
            _ifn=$(basename "$_p")
            _h=$(cat "$_p/port_no" 2>/dev/null)
            [ -n "$_h" ] && _p2n["$((_h))"]="$_ifn"
        done
    fi

    local _port _mac _loc _age _ifn2
    while read -r _port _mac _loc _age; do
        [ "$_port" = "port" ] && continue
        [ "$_loc" = "yes" ] && continue
        _ifn2="${_p2n[$_port]}"
        case "$_ifn2" in
            lan[0-9]*|eth[0-9]*) printf '%s\t%s\t%s\n' "$_mac" "$_ifn2" "$_age" ;;
        esac
    done < <(brctl showmacs "$_br" 2>/dev/null)
}

_lan_monitor_loop() {
    local _br="${LAN_IFACE:-br-lan}"
    local _poll=3
    local _lost_thresh=2
    local _iteration=0

    declare -A targets
    if [ -f "/etc/telegram_bot/data/.target_device.conf" ]; then
        while IFS='|' read -r _m _n; do
            [ -z "$_m" ] && continue
            targets["$(echo "$_m" | tr A-Z a-z)"]="$_n"
        done < "/etc/telegram_bot/data/.target_device.conf"
    fi
    [ "${#targets[@]}" -eq 0 ] && return 0

    echo "$(date): lan_monitor: start br=$_br targets=${#targets[@]}" \
        >> /tmp/telegram_bot/logs/lan_monitor.log

    declare -A present lost

    local _snap_seed _sm _sp _sa
    _snap_seed=$(_lan_snapshot "$_br")
    while IFS=$'\t' read -r _sm _sp _sa; do
        [ -z "$_sm" ] && continue
        [ -z "${targets[$_sm]}" ] && continue
        local _car_seed
        _car_seed=$(cat "/sys/class/net/$_sp/carrier" 2>/dev/null)
        if [ "$_car_seed" = "1" ]; then
            present["$_sm"]=1
            echo "$(date): lan_monitor: seed $_sm ($_sp) → уже подключён" >> /tmp/telegram_bot/logs/lan_monitor.log
        fi
    done <<< "$_snap_seed"

    while true; do
        _iteration=$((_iteration + 1))

        local _snap _m _p _a
        _snap=$(_lan_snapshot "$_br")

        unset _port_of
        declare -A _port_of
        while IFS=$'\t' read -r _m _p _a; do
            [ -z "$_m" ] && continue
            _port_of["$_m"]="$_p"
        done <<< "$_snap"

        for _m in "${!targets[@]}"; do
            local _alive=0
            local _port="${_port_of[$_m]}"

            if [ -n "$_port" ]; then
                local _car
                _car=$(cat "/sys/class/net/$_port/carrier" 2>/dev/null)
                [ "$_car" = "1" ] && _alive=1
            fi

            if [ "$_alive" = "1" ]; then
                if [ -z "${present[$_m]}" ]; then
                    local _nme; _nme=$(html_escape "${targets[$_m]}")
                    local _pn;  _pn=$(html_escape "$_port")
                    local _kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
                    send_tg_kb "🔔 <b>${_nme} подключился (LAN)</b>
🔗 MAC: ${_m}
🔌 Порт: ${_pn}
🕒 $(date '+%Y-%m-%d %H:%M:%S')" "$_kb"
                    present["$_m"]=1
                    echo "$(date): lan_monitor: + $_m ($_nme, port=$_port)" \
                        >> /tmp/telegram_bot/logs/lan_monitor.log
                fi
                lost["$_m"]=0
            elif [ -n "${present[$_m]}" ]; then
                lost["$_m"]=$(( ${lost[$_m]:-0} + 1 ))
                if [ "${lost[$_m]}" -ge "$_lost_thresh" ]; then
                    local _nme; _nme=$(html_escape "${targets[$_m]}")
                    local _kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
                    send_tg_kb "🔕 <b>${_nme} отключился (LAN)</b>
🔗 MAC: ${_m}
🕒 $(date '+%Y-%m-%d %H:%M:%S')" "$_kb"
                    unset "present[$_m]" "lost[$_m]"
                    echo "$(date): lan_monitor: - $_m ($_nme)" \
                        >> /tmp/telegram_bot/logs/lan_monitor.log
                fi
            fi
        done

        sleep "$_poll"
    done
}

_lan_start_monitor() {
    local _pf="/tmp/telegram_bot/state/lan_monitor.pid"
    if [ -f "$_pf" ]; then
        local _op; _op=$(cat "$_pf" 2>/dev/null)
        [ -n "$_op" ] && kill -0 "$_op" 2>/dev/null && return 0
    fi
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/bash /etc/telegram_bot/event_monitor.sh _lan_worker \
            </dev/null >>/tmp/telegram_bot/logs/lan_monitor.log 2>&1 200<&- &
    else
        /bin/bash /etc/telegram_bot/event_monitor.sh _lan_worker \
            </dev/null >>/tmp/telegram_bot/logs/lan_monitor.log 2>&1 200<&- &
    fi
}

if [ "$1" = "_lan_worker" ]; then
    echo $$ > /tmp/telegram_bot/state/lan_monitor.pid
    _lan_monitor_loop
    rm -f /tmp/telegram_bot/state/lan_monitor.pid
    exit 0
fi

# ============================================================
# Ожидание Wi-Fi интерфейсов после ребута
# ============================================================
_wait_for_interfaces() {
    local timeout=60
    local count=0

    while [ $count -lt $timeout ]; do
        _event_heartbeat
        if [ -z "$INTERFACE_24" ]; then
            local _if24
            _if24=$(_find_iface_for_radio 0)
            [ -n "$_if24" ] && INTERFACE_24="$_if24"
        fi
        if [ -z "$INTERFACE_5" ]; then
            local _if5
            _if5=$(_find_iface_for_radio 1)
            [ -n "$_if5" ] && INTERFACE_5="$_if5"
        fi

        if [ -n "$INTERFACE_24" ] && [ -n "$INTERFACE_5" ]; then
            return 0
        fi
        sleep 2
        count=$((count + 2))
    done
    return 1
}

if [ -z "$INTERFACE_24" ] || [ -z "$INTERFACE_5" ]; then
    echo "$(date): event_monitor: ожидание Wi-Fi интерфейсов (до 60с)..." >> /tmp/telegram_bot/logs/event_monitor.log
    if _wait_for_interfaces; then
        echo "$(date): event_monitor: оба интерфейса появились: 24=$INTERFACE_24 5=$INTERFACE_5" >> /tmp/telegram_bot/logs/event_monitor.log
    else
        echo "$(date): event_monitor: WARNING — интерфейсы не поднялись за 60с (24='$INTERFACE_24' 5='$INTERFACE_5'). Деградированный режим." >> /tmp/telegram_bot/logs/event_monitor.log
    fi
fi

check_required_utilities || exit 1

if [ "$1" = "reboot" ]; then
    for i in $(seq 1 30); do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if [ -f "/etc/telegram_bot/data/.reboot_from_bot" ]; then
        rm -f "/etc/telegram_bot/data/.reboot_from_bot"
        send_tg "🔄 <b>Роутер перезагрузился: </b>  
$(date '+%Y-%m-%d %H:%M:%S')"
    else
        send_tg "🔄 <b>Роутер загрузился: </b>  
$(date '+%Y-%m-%d %H:%M:%S')"
    fi
    exit 0
fi

if [ -n "$1" ]; then
    exit 0
fi

# ============================================================
# Защита от второго экземпляра
# ============================================================
LOCK_FILE="/var/lock/event_monitor.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "❌ Монитор уже запущен" >&2
    exit 1
fi
echo $$ > "$LOCK_FILE"

echo "$(date): event_monitor запущен (PID $$)" >> /tmp/telegram_bot/logs/event_monitor.log

KNOWN_MAC_FILE="/etc/telegram_bot/data/.known_macs"

# ============================================================
# Отправка длинных сообщений
# ============================================================
send_long_tg() {
    local text="$1"
    local keyboard="${2:-}"
    local max_len=4000
    local ok=0
    local safe_text="$text"

    if [[ "$safe_text" == "<pre>"*"</pre>" ]]; then
        safe_text="${safe_text#<pre>}"
        safe_text="${safe_text%</pre>}"
    fi

    if [ ${#safe_text} -le $max_len ]; then
        if [ -n "$keyboard" ]; then
            send_tg_kb "<pre>${safe_text}</pre>" "$keyboard" || ok=1
        else
            send_tg "<pre>${safe_text}</pre>" || ok=1
        fi
        return $ok
    fi

    local tmp_file="/tmp/send_long_$$"
    printf '%s\n' "$safe_text" > "$tmp_file"
    local part=""
    
    while IFS= read -r line; do
        if [ ${#line} -gt $max_len ]; then
            if [ -n "$part" ]; then
                send_tg "<pre>${part}</pre>" || ok=1
                part=""
            fi
            local rest="$line"
            while [ ${#rest} -gt $max_len ]; do
                send_tg "<pre>${rest:0:$max_len}</pre>" || ok=1
                rest="${rest:$max_len}"
            done
            part="$rest"
            continue
        fi

        if [ $(( ${#part} + ${#line} + 1 )) -gt $max_len ]; then
            send_tg "<pre>${part}</pre>" || ok=1
            part="$line"
        else
            if [ -z "$part" ]; then
                part="$line"
            else
                part="${part}"$'\n'"${line}"
            fi
        fi
    done < "$tmp_file"
    
    if [ -n "$part" ]; then
        if [ -n "$keyboard" ]; then
            send_tg_kb "<pre>${part}</pre>" "$keyboard" || ok=1
        else
            send_tg "<pre>${part}</pre>" || ok=1
        fi
    fi
    
    rm -f "$tmp_file"
    return $ok
}

# ============================================================
# Анти-спам порогов RAM/температуры
# ============================================================
_THR_STATE_FILE="/tmp/telegram_bot/state/threshold_last"
_THR_NOW_INIT=$(date +%s)
_THR_LAST_RAM=0
_THR_LAST_CPU=0
_THR_LAST_WIFI=0

if [ -r "$_THR_STATE_FILE" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            ram)  case "$_v" in ''|*[!0-9]*) ;; *) _THR_LAST_RAM="$_v"  ;; esac ;;
            cpu)  case "$_v" in ''|*[!0-9]*) ;; *) _THR_LAST_CPU="$_v"  ;; esac ;;
            wifi) case "$_v" in ''|*[!0-9]*) ;; *) _THR_LAST_WIFI="$_v" ;; esac ;;
        esac
    done < "$_THR_STATE_FILE"
fi

_threshold_save_state() {
    {
        echo "ram=$_THR_LAST_RAM"
        echo "cpu=$_THR_LAST_CPU"
        echo "wifi=$_THR_LAST_WIFI"
    } > "$_THR_STATE_FILE" 2>/dev/null
}

_threshold_save_state

# ============================================================
# Пороги RAM / температур
# ============================================================
_threshold_ensure_config() {
    if uci -q get telegram_bot.thresholds.enabled >/dev/null 2>&1; then
        return 0
    fi

    echo "$(date): _threshold_ensure_config: создаю секцию telegram_bot.thresholds с дефолтами" >> /tmp/telegram_bot/logs/bot.log

    [ -f /etc/config/telegram_bot ] || touch /etc/config/telegram_bot

    uci set telegram_bot.thresholds=thresholds
    uci set telegram_bot.thresholds.enabled='1'
    uci set telegram_bot.thresholds.ram_free_min='20'
    uci set telegram_bot.thresholds.cpu_temp_max='75'
    uci set telegram_bot.thresholds.wifi_temp_max='85'
    uci set telegram_bot.thresholds.cooldown='600'
    uci set telegram_bot.thresholds.cooldown_ram='600'
    uci set telegram_bot.thresholds.cooldown_cpu='600'
    uci set telegram_bot.thresholds.cooldown_wifi='600'
    uci commit telegram_bot
}

_threshold_read_config() {
    THR_ENABLED=$(uci -q get telegram_bot.thresholds.enabled 2>/dev/null)
    THR_RAM_FREE_MIN=$(uci -q get telegram_bot.thresholds.ram_free_min 2>/dev/null)
    THR_CPU_TEMP_MAX=$(uci -q get telegram_bot.thresholds.cpu_temp_max 2>/dev/null)
    THR_WIFI_TEMP_MAX=$(uci -q get telegram_bot.thresholds.wifi_temp_max 2>/dev/null)
    THR_COOLDOWN=$(uci -q get telegram_bot.thresholds.cooldown 2>/dev/null)
    THR_COOLDOWN_RAM=$(uci -q get telegram_bot.thresholds.cooldown_ram 2>/dev/null)
    THR_COOLDOWN_CPU=$(uci -q get telegram_bot.thresholds.cooldown_cpu 2>/dev/null)
    THR_COOLDOWN_WIFI=$(uci -q get telegram_bot.thresholds.cooldown_wifi 2>/dev/null)

    case "$THR_ENABLED" in
        ''|*[!0-9]*) THR_ENABLED=1 ;;
    esac
    case "$THR_RAM_FREE_MIN" in
        ''|*[!0-9]*) THR_RAM_FREE_MIN=20 ;;
    esac
    case "$THR_CPU_TEMP_MAX" in
        ''|*[!0-9]*) THR_CPU_TEMP_MAX=75 ;;
    esac
    case "$THR_WIFI_TEMP_MAX" in
        ''|*[!0-9]*) THR_WIFI_TEMP_MAX=85 ;;
    esac
    case "$THR_COOLDOWN" in
        ''|*[!0-9]*) THR_COOLDOWN=600 ;;
    esac

    case "$THR_COOLDOWN_RAM" in
        ''|*[!0-9]*) THR_COOLDOWN_RAM="$THR_COOLDOWN" ;;
    esac
    case "$THR_COOLDOWN_CPU" in
        ''|*[!0-9]*) THR_COOLDOWN_CPU="$THR_COOLDOWN" ;;
    esac
    case "$THR_COOLDOWN_WIFI" in
        ''|*[!0-9]*) THR_COOLDOWN_WIFI="$THR_COOLDOWN" ;;
    esac
}

_threshold_check_and_notify() {
    _threshold_read_config

    [ "$THR_ENABLED" = "1" ] || return 0

    local now
    now=$(date +%s)

    # RAM
    if [ "$THR_RAM_FREE_MIN" -gt 0 ] 2>/dev/null; then
            if [ $((now - _THR_LAST_RAM)) -gt "$THR_COOLDOWN_RAM" ]; then
            local avail_kb total_kb avail_mb total_mb
            avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
            total_kb=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null)
            case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac
            case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac
            avail_mb=$((avail_kb / 1024))
            total_mb=$((total_kb / 1024))

            if [ "$avail_mb" -lt "$THR_RAM_FREE_MIN" ]; then
                _THR_LAST_RAM="$now"
                _threshold_save_state
                local _thr_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
                send_tg_kb "<pre>⚠️ Низкий уровень RAM
${SEP46}
${SEP46}
📊 Доступно: ${avail_mb} / ${total_mb} MB  (порог ${THR_RAM_FREE_MIN} MB)
${SEP46}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')</pre>" "$_thr_kb"
            fi
        fi
    fi

    # CPU temp
    if [ "$THR_CPU_TEMP_MAX" -gt 0 ] 2>/dev/null; then
        if [ $((now - _THR_LAST_CPU)) -gt "$THR_COOLDOWN_CPU" ]; then
            local cpu_temp
            cpu_temp=$(_sys_cpu_temp_raw)

            if [ -n "$cpu_temp" ] && [ "$cpu_temp" -gt "$THR_CPU_TEMP_MAX" ] 2>/dev/null; then
                _THR_LAST_CPU="$now"
                _threshold_save_state
                send_tg_kb "<pre>🔥 Высокая температура CPU
${SEP46}
${SEP46}
🌡️ Текущая: ${cpu_temp}°C  (порог ${THR_CPU_TEMP_MAX}°C)
${SEP46}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')</pre>" "$_thr_kb"
            fi
        fi
    fi

    # Wi-Fi temp
    if [ "$THR_WIFI_TEMP_MAX" -gt 0 ] 2>/dev/null; then
        if [ $((now - _THR_LAST_WIFI)) -gt "$THR_COOLDOWN_WIFI" ]; then
            local max_t=0 cur_t phy
            for phy in phy0 phy1; do
                cur_t=$(_sys_wifi_temp_raw "$phy")
                if [ -n "$cur_t" ] && [ "$cur_t" -gt "$max_t" ] 2>/dev/null; then
                    max_t="$cur_t"
                fi
            done

            if [ "$max_t" -gt "$THR_WIFI_TEMP_MAX" ] 2>/dev/null; then
                _THR_LAST_WIFI="$now"
                _threshold_save_state
                send_tg_kb "<pre>🔥 Высокая температура Wi-Fi
${SEP46}
${SEP46}
🌡️ Максимум: ${max_t}°C  (порог ${THR_WIFI_TEMP_MAX}°C)
${SEP46}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')</pre>" "$_thr_kb"
            fi
        fi
    fi

    return 0
}

# ============================================================
# Проверка новых устройств
# ============================================================
check_new_devices() {
    local _macs_24="" _macs_5="" _macs_lan=""

    # 1. Сбор MAC-адресов из Wi-Fi (2.4 и 5 ГГц)
    if [ -n "$INTERFACE_24" ]; then
        _macs_24=$(iw dev "$INTERFACE_24" station dump 2>/dev/null \
            | awk '/^Station/ {print tolower($2)}')
    fi

    if [ -n "$INTERFACE_5" ]; then
        _macs_5=$(iw dev "$INTERFACE_5" station dump 2>/dev/null \
            | awk '/^Station/ {print tolower($2)}')
    fi

    # 2. Сбор MAC-адресов из LAN 
    if [ -n "$LAN_IFACE" ]; then
        local _macs_lan_bridge=""
        local lan_port_map=""

        # Строим карту портов
        if [ -d "/sys/class/net/$LAN_IFACE/brif" ]; then
            local p_path
            for p_path in "/sys/class/net/$LAN_IFACE/brif/"*; do
                [ -e "$p_path" ] || continue
                local p_name=$(basename "$p_path")
                case "$p_name" in
                    wlan*|phy*|ath*|ra*|ap*|mon*|wl*) continue ;;
                esac
                [ -e "/sys/class/net/$p_name/phy80211" ] && continue

                local p_no=$(cat "$p_path/port_no" 2>/dev/null)
                if [ -n "$p_no" ]; then
                    local p_no_dec=$(printf "%d" "$p_no" 2>/dev/null)
                    lan_port_map="${lan_port_map}${p_no_dec}:${p_name} "
                fi
            done
        fi

        # Определяем MAC через brctl
        if command -v brctl >/dev/null 2>&1 && brctl showmacs "$LAN_IFACE" 2>/dev/null | grep -q "^[[:space:]]*[0-9]"; then
            _macs_lan_bridge=$(brctl showmacs "$LAN_IFACE" 2>/dev/null | while read -r line; do
                [ -z "$line" ] && continue
                set -- $line
                local port_no=$1
                local mac_addr=$2
                local is_local=$3
                if [ "$is_local" = "yes" ] || [ -z "$mac_addr" ] || [ "$port_no" = "port" ] || [ "$port_no" = "no" ]; then
                    continue
                fi
                local matched_port=""
                for entry in $lan_port_map; do
                    local p_num="${entry%%:*}"
                    local p_name="${entry#*:}"
                    if [ "$p_num" = "$port_no" ]; then
                        matched_port="$p_name"
                        break
                    fi
                done
                if [ -n "$matched_port" ]; then
                    echo "$mac_addr" | tr '[:upper:]' '[:lower:]'
                fi
            done | sort -u)
        fi

        # Определяем MAC через bridge fdb (для DSA)
        if [ -z "$_macs_lan_bridge" ] && command -v bridge >/dev/null 2>&1; then
            _macs_lan_bridge=$(bridge fdb show br "$LAN_IFACE" 2>/dev/null | grep "master $LAN_IFACE" | grep -v "self" | grep -v "permanent" | while read -r _mac _dev _ifname _rest; do
                [ -z "$_mac" ] || [ -z "$_ifname" ] && continue
                case "$_ifname" in
                    phy*|wlan*|ath*|ra*|ap*|mon*|wl*) continue ;;
                esac
                [ "$_ifname" = "$LAN_IFACE" ] && continue
                echo "$_mac" | tr '[:upper:]' '[:lower:]'
            done | sort -u)
        fi
        _macs_lan="$_macs_lan_bridge"
    fi

    # 3. Сбор MAC-адресов самого роутера
    local router_macs=""
    local _f _m
    for _f in /sys/class/net/*/address; do
        [ -f "$_f" ] || continue
        _m=$(cat "$_f" 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')
        [ -z "$_m" ] && continue
        [ "$_m" = "00:00:00:00:00:00" ] && continue
        case "$(dirname "$_f")" in */lo) continue ;; esac
        router_macs="${router_macs}${_m}"$'\n'
    done

    if command -v ubus >/dev/null 2>&1; then
        local _ubus_macs
        _ubus_macs=$(ubus call network.device status 2>/dev/null | jq -r '.[] | .macaddr? // empty' 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')
        [ -n "$_ubus_macs" ] && router_macs="${router_macs}${_ubus_macs}"$'\n'
    fi
    router_macs=$(echo "$router_macs" | sed '/^[[:space:]]*$/d' | sort -u)

    # 4. Объединение и фильтрация
    local macs=""
    macs=$(printf '%s\n%s\n%s' "$_macs_24" "$_macs_5" "$_macs_lan" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^[[:space:]]*$/d' \
        | sort -u)

    if [ -n "$router_macs" ]; then
        macs=$(printf '%s' "$macs" | grep -vFf <(printf '%s' "$router_macs") || true)
    fi

    [ -z "$macs" ] && return

    # 5. Сравнение с базой известных MAC
    local known_macs=""
    if [ -f "$KNOWN_MAC_FILE" ] && [ -s "$KNOWN_MAC_FILE" ]; then
        known_macs=$(cat "$KNOWN_MAC_FILE" | sed '/^[[:space:]]*$/d' | sort -u)
    fi

    # Первый запуск: инициализация базы
    if [ ! -f "$KNOWN_MAC_FILE" ] || [ ! -s "$KNOWN_MAC_FILE" ] || [ -z "$known_macs" ]; then
        local data=""
        local num=1
        for mac in $macs; do
            [ -z "$mac" ] && continue
            local name=""
            if [ -f "$DHCP_LEASES" ]; then
                name=$(awk -v m="$mac" 'tolower($2) == tolower(m) {print $4; exit}' "$DHCP_LEASES")
            fi
            if [ -z "$name" ] || [ "$name" = "*" ]; then
                if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
                    name=$(awk -v m="$mac" 'tolower($1) == tolower(m) {print $2,$3,$4,$5; exit}' /etc/telegram_bot/data/device_names.txt)
                fi
            fi
            [ -z "$name" ] && name="Unknown"
            local safe_name=$(html_escape "$name")

            local _net="?"
            if echo "$_macs_24" | grep -qx "$mac"; then
                _net="WiFi24"
            elif echo "$_macs_5" | grep -qx "$mac"; then
                _net="WiFi5"
            elif echo "$_macs_lan" | grep -qx "$mac"; then
                _net="LAN"
            fi

            data="${data}${num}|${safe_name}|${_net}|${mac}\n"
            num=$((num+1))
        done

        local table=$(printf "%b" "$data" | awk -F'|' '
        BEGIN {
            printf "%-2s %-22s  %-6s  %-17s\n", "№", "Имя", "Сеть", "MAC"
            printf "%-2s %-22s  %-6s  %-17s\n", "--", "----------------------", "------", "-----------------"
        }
        {
            name = $2
            if (length(name) > 22) name = substr(name, 1, 22)
            printf "%-2s %-22s  %-6s  %-17s\n", $1, name, $3, $4
        }')

        local final_msg="📱 ОБНАРУЖЕНЫ НОВЫЕ УСТРОЙСТВА В СЕТИ"$'\n\n'
        final_msg="${final_msg}${SEP46}"$'\n'
        final_msg="${final_msg}${table}"$'\n'
        final_msg="${final_msg}${SEP46}"$'\n'
        final_msg="${final_msg}🕒 $(date '+%Y-%m-%d %H:%M:%S')"

        local _init_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"newdev_close"}]]}'
        if send_long_tg "$final_msg" "$_init_kb"; then
            printf '%s\n' "$macs" > "$KNOWN_MAC_FILE.tmp"
            mv "$KNOWN_MAC_FILE.tmp" "$KNOWN_MAC_FILE"
            echo "$(date): check_new_devices: initial list (active only)" >> /tmp/telegram_bot/logs/bot.log
        else
            echo "$(date): check_new_devices: send_long_tg failed" >> /tmp/telegram_bot/logs/bot.log
        fi
        return
    fi

    # 6. Последующие запуски: поиск новых устройств
    local new_macs=""
    for mac in $macs; do
        [ -z "$mac" ] && continue
        echo "$known_macs" | grep -q -x "$mac" && continue

        local name=""
        if [ -f "$DHCP_LEASES" ]; then
            name=$(awk -v m="$mac" 'tolower($2) == tolower(m) {print $4; exit}' "$DHCP_LEASES")
        fi
        if [ -z "$name" ] || [ "$name" = "*" ]; then
            if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
                name=$(awk -v m="$mac" 'tolower($1) == tolower(m) {print $2,$3,$4,$5; exit}' /etc/telegram_bot/data/device_names.txt)
            fi
        fi
        [ -z "$name" ] && name="Unnamed Device"
        local safe_name=$(html_escape "$name")
        local safe_mac=$(html_escape "$mac")

        local _net_name=""
        if echo "$_macs_24" | grep -qx "$mac"; then
            _net_name=$(get_ssid "$INTERFACE_24")
        elif echo "$_macs_5" | grep -qx "$mac"; then
            _net_name=$(get_ssid "$INTERFACE_5")
        elif echo "$_macs_lan" | grep -qx "$mac"; then
            _net_name="LAN"
        fi
        [ -z "$_net_name" ] && _net_name="?"

        local _net_short="${_net_name:0:18}"
        local safe_net
        safe_net=$(html_escape "$_net_short")

        local _msg_time
        _msg_time=$(date '+%Y-%m-%d %H:%M:%S')

        local msg="<pre>🆕 НОВОЕ УСТРОЙСТВО В СЕТИ ${safe_net}

$SEP46
📱 Имя: $safe_name
🔗 MAC: $safe_mac
🕒 Время: ${_msg_time}
$SEP46

Для изоляции неизвестного вам устройства нажмите 
кнопку „Заблокировать“</pre>"

        local _kb="{\"inline_keyboard\":[[{\"text\":\"🚫 Заблокировать\",\"callback_data\":\"newdev_deny_${mac}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"newdev_close_${mac}\"}]]}"    
	   printf '%s' "$msg" > "/tmp/telegram_bot/state/newdev_${mac}.msg" 2>/dev/null

        local _mid
        _mid=$(send_tg_kb "$msg" "$_kb")
        if [ -n "$_mid" ]; then
            new_macs="$new_macs $mac"
        else
            echo "$(date): check_new_devices: send_tg_kb failed for $mac" >> /tmp/telegram_bot/logs/bot.log
            rm -f "/tmp/telegram_bot/state/newdev_${mac}.msg" 2>/dev/null
        fi
    done

    # 7. Обновление базы известных MAC
    if [ -n "$new_macs" ]; then
        {
            printf '%s\n' "$known_macs"
            for nmac in $new_macs; do echo "$nmac"; done
        } | sort -u | sed '/^[[:space:]]*$/d' > "$KNOWN_MAC_FILE.tmp"
        mv "$KNOWN_MAC_FILE.tmp" "$KNOWN_MAC_FILE"
    fi
}

# ============================================================
# Метка времени из строки лога
# ============================================================
_extract_ts_key() {
    local line="$1"
    local mon_name day time yr

    if [[ "$line" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[T\ ]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
        printf "%s%s%s%s%s%s" \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
            "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
        return
    fi

    if [[ "$line" =~ ^([0-9]{2})\.([0-9]{2})\ +([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
        local mon="${BASH_REMATCH[1]}"
        local day="${BASH_REMATCH[2]}"
        local time_str="${BASH_REMATCH[3]}:${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"
        local yr=$(date +%Y)
        local cur_mon=$(date +%m)
        if [ "$((10#$mon))" -gt "$((10#$cur_mon))" ]; then
            yr=$((yr - 1))
        fi
        printf "%s%s%02d%s%s%s" "$yr" "$mon" "$((10#$day))" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        return
    fi

    local f1 f2 f3 f4 f5
    read -r f1 f2 f3 f4 f5 _ <<< "$line"

    local check_rollover=0

    if [[ "$f1" =~ ^[A-Za-z]{3}$ ]] \
       && [[ "$f2" =~ ^[0-9]+$ ]] \
       && [[ "$f3" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        mon_name="$f1"; day="$f2"; time="$f3"
        check_rollover=1
    elif [[ "$f1" =~ ^[A-Za-z]{3}$ ]] \
         && [[ "$f2" =~ ^[A-Za-z]{3}$ ]] \
         && [[ "$f3" =~ ^[0-9]+$ ]] \
         && [[ "$f4" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] \
         && [[ "$f5" =~ ^[0-9]{4}$ ]]; then
        mon_name="$f2"; day="$f3"; time="$f4"; yr="$f5"
    elif [[ "$f1" =~ ^[A-Za-z]{3}$ ]] \
         && [[ "$f2" =~ ^[A-Za-z]{3}$ ]] \
         && [[ "$f3" =~ ^[0-9]+$ ]] \
         && [[ "$f4" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        mon_name="$f2"; day="$f3"; time="$f4"
        check_rollover=1
    else
        printf "00000000000000"
        return
    fi

    local mon
    case "$mon_name" in
        Jan) mon=01 ;; Feb) mon=02 ;; Mar) mon=03 ;; Apr) mon=04 ;;
        May) mon=05 ;; Jun) mon=06 ;; Jul) mon=07 ;; Aug) mon=08 ;;
        Sep) mon=09 ;; Oct) mon=10 ;; Nov) mon=11 ;; Dec) mon=12 ;;
        *) printf "00000000000000"; return ;;
    esac

    if [ "$check_rollover" -eq 1 ]; then
        local _cur_mon _cur_yr
        _cur_mon=$(date +%m)
        _cur_yr=$(date +%Y)

        if [ "$((10#$mon))" -gt "$((10#$_cur_mon))" ]; then
            yr=$((_cur_yr - 1))
        else
            yr="$_cur_yr"
        fi
    fi

    local hh=${time%%:*}
    local mm=${time#*:}; mm=${mm%%:*}
    local ss=${time##*:}

    printf "%s%s%02d%s%s%s" "$yr" "$mon" "$((10#$day))" "$hh" "$mm" "$ss"
}

# ============================================================
# Отправка пачки критических событий
# ============================================================
_critical_send_chunk() {
    local page_content="$1"
    local page_num="$2"
    local total_pages="$3"

    local header="📋 НОВЫЕ КРИТИЧЕСКИЕ СОБЫТИЯ"
    [ "$total_pages" -gt 1 ] && header="📋 НОВЫЕ КРИТИЧЕСКИЕ СОБЫТИЯ (стр. $page_num из $total_pages)"
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')

    local table=$(printf '%s\n' "$page_content" | awk \
        -v header="$header" -v sep="$SEP46" -v curtime="$current_time" \
        "$AWK_CLASSIFY"'
    BEGIN {
        regex_net  = "netifd|pppd|pppoe|ppp|dhcp|dnsmasq|odhcpd"
        regex_wifi = "hostapd|wifi|ath|mt76|iwlwifi|wlan"
        regex_sys  = "kernel|dmesg|flash|storage|opkg|apk"

        m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04";
        m["May"]="05"; m["Jun"]="06"; m["Jul"]="07"; m["Aug"]="08";
        m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";
        count = 0
    }
    length($0) > 0 {
        lines[count] = $0
        count++
    }
    END {
        # Разворачиваем: самые свежие — сверху.
        for (i = 0; i < int(count/2); i++) {
            j = count - 1 - i
            tmp = lines[i]
            lines[i] = lines[j]
            lines[j] = tmp
        }
        printf "<pre>%s\n", header
        printf "\n"
        printf "%s\n", sep
        printf "%-3s %-5s %-8s %s %s\n", " №", "Дата", "Время", "🆔", "Текст ошибки"
        printf "%-3s %-5s %-8s %s %s\n", "---", "-----", "--------", "--", "------------------------------"

        for (i = 0; i < count; i++) {
            line = lines[i]
            level = classify_line(line)

            if (match(line, /^[A-Za-z]{3} +[A-Za-z]{3} +[0-9]+ [0-9:]+ [0-9]{4}/)) {
                date_part = substr(line, RSTART, RLENGTH)
                split(date_part, parts, " ")
                month_str = parts[2]
                day = sprintf("%02d", parts[3])
                time_str = parts[4]
                date_str = m[month_str] "." day
            } else if (match(line, /^[A-Za-z]{3} +[0-9]+ [0-9:]+/)) {
                date_part = substr(line, RSTART, RLENGTH)
                split(date_part, parts, " ")
                month_str = parts[1]
                day = sprintf("%02d", parts[2])
                time_str = parts[3]
                date_str = m[month_str] "." day
            } else if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]+/)) {
                date_part = substr(line, RSTART, RLENGTH)
                gsub(/T/, " ", date_part)
                split(date_part, parts, " ")
                date_str = substr(parts[1], 6, 5)
                time_str = parts[2]
            } else {
                time_str = "??:??:??"
                date_str = "??.??"
            }

            msg = line
            sub(/^[A-Za-z]{3} +[A-Za-z]{3} +[0-9]+ [0-9:]+ [0-9]{4} /, "", msg)
            sub(/^[A-Za-z]{3} +[0-9]+ [0-9:]+ /, "", msg)
            sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]+ /, "", msg)
            sub(/^[A-Za-z]{3} +[A-Za-z]{3} +[0-9]+ [0-9:]+ /, "", msg)
            gsub(/[0-9]{4}[\/-][0-9]{2}[\/-][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/, "", msg)
            gsub(/[0-9]{4}[\/-][0-9]{2}[\/-][0-9]{2}/, "", msg)
            gsub(/^[ \t]+|[ \t]+$/, "", msg)
            gsub(/[\xc2\xa0]/, " ", msg)
            if (msg == "") msg = "(пустое сообщение)"
            gsub(/&/, "\\&amp;", msg)
            gsub(/</, "\\&lt;", msg)
            gsub(/>/, "\\&gt;", msg)

            icon = "🔹"
            if (level == "crit") icon = "🚨"
            else if (level == "err") icon = "❌"
            else if (level == "warn") icon = "⚠️"
            else {
                if (g_body_low ~ /(^|[^a-z])panic([^a-z]|$)|(^|[^a-z])oom([^a-z]|$)|(^|[^a-z])emerg([^a-z]|$)|(^|[^a-z])fatal([^a-z]|$)/) icon = "🚨"
                else if (g_body_low ~ /(^|[^a-z])err([^a-z]|$)|(^|[^a-z])error([^a-z]|$)|(^|[^a-z])critical([^a-z]|$)/) icon = "❌"
                else if (g_body_low ~ /(^|[^a-z])warn([^a-z]|$)|(^|[^a-z])warning([^a-z]|$)|(^|[^a-z])alert([^a-z]|$)|(^|[^a-z])timeout([^a-z]|$)/) icon = "⚠️"
                else if (g_body_low ~ regex_net) icon = "🌐"
                else if (g_body_low ~ regex_wifi) icon = "📡"
                else if (g_body_low ~ regex_sys) icon = "💻"
            }

            num = i + 1
            max_first = 29
            max_next = 49
            indent = "   "

            gsub(/\//, " /", msg)

            n = split(msg, atoms, /[ \t]+/)
            line_out = ""
            first = 1

            for (j = 1; j <= n; j++) {
                atom = atoms[j]
                if (atom == "") continue

                delim = (line_out == "" || substr(atom, 1, 1) == "/") ? "" : " "
                limit = (first) ? max_first : max_next

                while (visual_len(atom) > limit) {
                    if (line_out == "") {
                        # Умный разрыв: последний . - : / в [0.6*limit, limit).
                        cut = limit
                        for (k = limit - 1; k >= int(limit * 0.6); k--) {
                            ch = substr(atom, k, 1)
                            if (ch == "." || ch == "-" || ch == ":" || ch == "/") { cut = k; break }
                        }
                        chunk = substr(atom, 1, cut)
                        if (first) { printf "%-3s %-5s %-8s %s %s\n", num, date_str, time_str, icon, chunk; first = 0 }
                        else { printf "%s%s\n", indent, chunk }
                        atom = substr(atom, cut + 1)
                        limit = max_next
                    } else {
                        if (first) { printf "%-3s %-5s %-8s %s %s\n", num, date_str, time_str, icon, line_out; first = 0 }
                        else { printf "%s%s\n", indent, line_out }
                        line_out = ""
                        delim = ""
                        limit = max_next
                    }
                }

                if (line_out == "") {
                    line_out = atom
                } else if (visual_len(line_out) + visual_len(delim) + visual_len(atom) <= limit) {
                    line_out = line_out delim atom
                } else {
                    if (first) { printf "%-3s %-5s %-8s %s %s\n", num, date_str, time_str, icon, line_out; first = 0 }
                    else { printf "%s%s\n", indent, line_out }
                    line_out = atom
                }
            }

            if (line_out != "") {
                if (first) { printf "%-3s %-5s %-8s %s %s\n", num, date_str, time_str, icon, line_out }
                else { printf "%s%s\n", indent, line_out }
            }

            if (i < count - 1) printf "\n"
        }

        printf "%s\n", sep
        printf "💢 Обновлено: %s\n", curtime
        printf "</pre>"
    }')

    send_long_tg "$table" '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
}

# ============================================================
# История логов
# ============================================================
_collect_history_log() {
    [ "$(uci -q get telegram_bot.main.log_history_disabled 2>/dev/null)" = "1" ] && return 0

    local hist_file="/tmp/telegram_bot/critical/history.log"
    touch "$hist_file"

    local logs=$(timeout 15 logread -l 500 2>/dev/null)
    [ -z "$logs" ] && return 0

    local last_ts="00000000000000"
    if [ -s "$hist_file" ]; then
        local last_line=$(tail -1 "$hist_file" 2>/dev/null)
        if [ -n "$last_line" ]; then
            last_ts=$(_extract_ts_key "$last_line")
        fi
    fi

    local new_lines=""
    local max_ts="$last_ts"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts=$(_extract_ts_key "$line")

        if [ "$ts" \> "$last_ts" ]; then
            new_lines="${new_lines}${line}"$'\n'
            if [ "$ts" \> "$max_ts" ]; then max_ts="$ts"; fi
        fi
    done <<< "$logs"

    if [ -n "$new_lines" ]; then
        printf '%s' "$new_lines" >> "$hist_file"

        local max_mb
        max_mb=$(uci -q get telegram_bot.log.max_size_mb 2>/dev/null)
        case "$max_mb" in ''|*[!0-9]*) max_mb=2 ;; esac
        local max_size=$((max_mb * 1024 * 1024))
        local lines_to_keep=$((max_mb * 6000))
        [ "$lines_to_keep" -lt 10000 ] && lines_to_keep=10000

        local fsize=$(wc -c < "$hist_file" 2>/dev/null)
        if [ "${fsize:-0}" -gt "$max_size" ]; then
            tail -n "$lines_to_keep" "$hist_file" > "${hist_file}.tmp"
            mv "${hist_file}.tmp" "$hist_file"
        fi
    fi
}

# ============================================================
# Проверка критических логов
# ============================================================
check_critical_logs() {
    _collect_history_log

    [ "$(uci -q get telegram_bot.main.event_mute_disabled 2>/dev/null)" = "1" ] && return 0

    local marker_file="/tmp/.critical_last_ts"

    local logs
    logs=$(timeout 15 logread 2>/dev/null | tail -500)
    [ -z "$logs" ] && return 0

    local _mute_filter=""
    _mute_filter=$(_event_mute_build_filter)

    local filtered
    if [ -n "$_mute_filter" ] && [ -s "$_mute_filter" ]; then
        filtered=$(echo "$logs" \
            | grep -vEf "$_mute_filter" \
            | awk "$AWK_CLASSIFY"'{
                cat = classify_category($0)
                if (cat == "crit" || cat == "err" || cat == "warn") print
            }' 2>/dev/null)
        rm -f "$_mute_filter"
    else
        filtered=$(echo "$logs" \
            | awk "$AWK_CLASSIFY"'{
                cat = classify_category($0)
                if (cat == "crit" || cat == "err" || cat == "warn") print
            }' 2>/dev/null)
    fi
    [ -z "$filtered" ] && return 0

    filtered=$(echo "$filtered" | sed 's/\r//g' | sed 's/[[:space:]]*$//' | sed '/^[[:space:]]*$/d')
    [ -z "$filtered" ] && return 0

    local last_ts="00000000000000"
    local last_count=0

    if [ -f "$marker_file" ]; then
        local _md
        _md=$(cat "$marker_file" 2>/dev/null)
        case "$_md" in
            *'|'*)
                last_ts="${_md%%|*}"
                last_count="${_md##*|}"
                case "$last_count" in ''|*[!0-9]*) last_count=0 ;; esac
                ;;
            *)
                last_ts="$_md"
                last_count=0
                ;;
        esac
        case "$last_ts" in ''|*[!0-9]*) last_ts="00000000000000" ;; esac
    fi

    if [ ! -f "$marker_file" ]; then
        local init_ts="00000000000000"
        local init_count=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local ts
            ts=$(_extract_ts_key "$line")
            if [ "$ts" \> "$init_ts" ]; then
                init_ts="$ts"
                init_count=1
            elif [ "$ts" = "$init_ts" ]; then
                init_count=$((init_count + 1))
            fi
        done <<< "$filtered"
        echo "${init_ts}|${init_count}" > "$marker_file"
        return 0
    fi

    local new_lines=""
    local max_ts="$last_ts"
    local new_count="$last_count"
    local same_ts_seen=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts
        ts=$(_extract_ts_key "$line")

        if [ "$ts" \> "$last_ts" ]; then
            new_lines="${new_lines}${line}"$'\n'
            if [ "$ts" \> "$max_ts" ]; then
                max_ts="$ts"
                new_count=1
            elif [ "$ts" = "$max_ts" ]; then
                new_count=$((new_count + 1))
            fi
        elif [ "$ts" = "$last_ts" ]; then
            same_ts_seen=$((same_ts_seen + 1))
            if [ "$same_ts_seen" -gt "$last_count" ]; then
                new_lines="${new_lines}${line}"$'\n'
                new_count=$((new_count + 1))
            fi
        fi
    done <<< "$filtered"

    [ -z "$new_lines" ] && return 0

    local chunk_size=14
    local total_new
    total_new=$(printf '%s' "$new_lines" | grep -c .)
    local all_ok=1

    if [ "$total_new" -le "$chunk_size" ]; then
        _critical_send_chunk "$new_lines" 1 1 || all_ok=0
    else
        local total_chunks=$(( (total_new + chunk_size - 1) / chunk_size ))
        local chunk_num=1
        local line_idx=0
        local current_chunk=""

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            current_chunk="${current_chunk}${line}"$'\n'
            line_idx=$((line_idx + 1))

            if [ $((line_idx % chunk_size)) -eq 0 ]; then
                _critical_send_chunk "$current_chunk" "$chunk_num" "$total_chunks" || all_ok=0
                current_chunk=""
                chunk_num=$((chunk_num + 1))
                if [ "$chunk_num" -le "$total_chunks" ]; then
                    sleep 1
                fi
            fi
        done <<< "$new_lines"

        if [ -n "$current_chunk" ]; then
            _critical_send_chunk "$current_chunk" "$chunk_num" "$total_chunks" || all_ok=0
        fi
    fi

    if [ "$all_ok" -eq 1 ]; then
        if [ "$max_ts" \> "$last_ts" ] || [ "$new_count" -gt "$last_count" ]; then
            echo "${max_ts}|${new_count}" > "$marker_file"
        fi
    else
        echo "$(date): check_critical_logs: отправка не удалась, маркер не обновлён" >> /tmp/telegram_bot/logs/bot.log
    fi

    return 0
}

# Загрузка wifi.sh
if [ -f "/etc/telegram_bot/wifi.sh" ]; then
    . /etc/telegram_bot/wifi.sh 2>/dev/null
fi

# Первичный запуск
check_critical_logs
check_new_devices
echo "$(date): event_monitor переходит в основной цикл" >> /tmp/telegram_bot/logs/event_monitor.log

# ============================================================
# Главный цикл
# ============================================================
# Каждые 90 секунд:
#   - heartbeat,
#   - ротация лога,
#   - чистка старых state-файлов,
#   - восстановление iface если пропал,
#   - новые устройства,
#   - критические логи,
#   - проверка Wi-Fi каналов (из wifi.sh),
#   - запуск STA-мониторов (из wifi.sh),
#   - пороги RAM/температуры.
while true; do
    _event_heartbeat
    rotate_log "/tmp/telegram_bot/logs/event_monitor.log"
	rotate_log "/tmp/telegram_bot/logs/lan_monitor.log"
	
	if declare -F update_max_uptime >/dev/null 2>&1; then
        update_max_uptime
    fi

    find /tmp/telegram_bot/state -maxdepth 1 -name "newdev_*.msg" -mtime +3 -delete 2>/dev/null

    if [ -z "$INTERFACE_24" ]; then
        _if24_new=$(_find_iface_for_radio 0)
        if [ -n "$_if24_new" ]; then
            INTERFACE_24="$_if24_new"
            echo "$(date): event_monitor: INTERFACE_24 восстановлен: $INTERFACE_24" >> /tmp/telegram_bot/logs/event_monitor.log
        fi
    fi
    if [ -z "$INTERFACE_5" ]; then
        _if5_new=$(_find_iface_for_radio 1)
        if [ -n "$_if5_new" ]; then
            INTERFACE_5="$_if5_new"
            echo "$(date): event_monitor: INTERFACE_5 восстановлен: $INTERFACE_5" >> /tmp/telegram_bot/logs/event_monitor.log
        fi
    fi

    check_new_devices
    check_critical_logs

    if declare -F _wifi_autocheck_channels >/dev/null 2>&1; then
        _wifi_autocheck_channels >> /tmp/telegram_bot/logs/bot.log 2>&1
    fi

    if declare -F _wifi_start_all_sta_monitors >/dev/null 2>&1; then
        _wifi_start_all_sta_monitors >> /tmp/telegram_bot/logs/bot.log 2>&1
    fi
	
	if declare -F _lan_start_monitor >/dev/null 2>&1; then
        _lan_start_monitor
    fi

    _threshold_ensure_config
    _threshold_check_and_notify >> /tmp/telegram_bot/logs/bot.log 2>&1

    _event_heartbeat

    sleep 90 200<&-
done