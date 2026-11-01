#!/bin/bash

if [ -z "$BASH_VERSION" ]; then
    echo "❌ Ошибка: этот скрипт требует bash. Установите: opkg install bash (или apk add bash)" >&2
    exit 1
fi

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
source /etc/telegram_bot/bot_config.sh

# ==============================================================================
# 🚀 РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ И БАЗОВЫЕ НАСТРОЙКИ
# ==============================================================================

WIFI_EDIT_MSG_ID_FILE="/tmp/telegram_bot/wifi/edit_msg_id"
WIFI_EDIT_MODE_FILE="/tmp/telegram_bot/wifi/edit_mode"
check_required_utilities || exit 1

_setup_bot_commands

. /etc/telegram_bot/wifi.sh 2>/dev/null
. /etc/telegram_bot/explorer.sh 2>/dev/null

if [ -f "/etc/telegram_bot/.bot_disabled" ]; then
    echo "=== $(date): бот отключён флагом /etc/telegram_bot/.bot_disabled ===" >> "$LOG_FILE" 2>/dev/null
    exit 0
fi

LOCK_FILE="/var/lock/telegram_bot.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "❌ Бот уже запущен" >&2
    exit 1
fi
echo $$ > "$LOCK_FILE"

cleanup() {
    rm -f /tmp/telegram_bot/speed/state.json /tmp/telegram_bot/speed/device_list
    rm -f /tmp/telegram_bot/state/threshold_msg_id
    if [ -f /tmp/telegram_bot/flags/skip_msg_id ]; then
        _cid=$(cat /tmp/telegram_bot/flags/skip_msg_id 2>/dev/null)
        [ -n "$_cid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_cid" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/flags/skip_msg_id
    fi
    rm -f /tmp/telegram_bot/services/list.json /tmp/telegram_bot/services/selected.json /tmp/telegram_bot/services/page /tmp/telegram_bot/services/msg_id /tmp/telegram_bot/critical/msg_id
    rm -rf /tmp/telegram_bot/state/* /tmp/telegram_bot/services/* \
           /tmp/telegram_bot/critical/state/* /tmp/telegram_bot/online/* \
           /tmp/telegram_bot/traffic/* /tmp/telegram_bot/speed/* \
           /tmp/telegram_bot/wol/* /tmp/telegram_bot/reboot/* \
           /tmp/telegram_bot/wifi/* /tmp/telegram_bot/explorer/* \
           /tmp/telegram_bot/target/* \
           /tmp/telegram_bot/exec/session /tmp/telegram_bot/exec/output \
           /tmp/telegram_bot/exec/wait_msg_id /tmp/telegram_bot/exec/defer_msgs \
           /tmp/telegram_bot/exec/return_to_explorer \
           /tmp/telegram_bot/exec/msgs_*.txt /tmp/telegram_bot/exec/pending_user_msgs 2>/dev/null
    rm -f  /tmp/telegram_bot/flags/first_boot \
           /tmp/telegram_bot/flags/busy_since \
           /tmp/telegram_bot/flags/busy_until \
           /tmp/telegram_bot/flags/busy_hb_pid \
           /tmp/telegram_bot/flags/skip_msg_id \
           /tmp/telegram_bot/flags/offset_recovery_pending \
           /tmp/telegram_bot/flags/restarting \
           /tmp/telegram_bot/flags/bot_debug \
           2>/dev/null
    rm -f /tmp/telegram_bot/state/bot_disable_msg_id /tmp/telegram_bot/state/bot_uninstall_msg_id
    rm -f /tmp/telegram_bot/speed/limit_msg_id /tmp/telegram_bot/speed/msg_id /tmp/telegram_bot/speed/state.json
    rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name /tmp/telegram_bot/wol/msg_id /tmp/telegram_bot/wol/result_msg_id
	rm -f /tmp/telegram_bot/state/speedtest_msg_id
    for file in /tmp/telegram_bot/wifi/edit_msg_id /tmp/telegram_bot/wol/msg_id; do
        if [ -f "$file" ]; then
            msg_id=$(cat "$file" 2>/dev/null)
            if [ -n "$msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                    -d chat_id="$CHAT_ID" -d message_id="$msg_id" > /dev/null 2>&1
            fi
            rm -f "$file"
        fi
    done
    for pid_file in /tmp/telegram_bot/wifi/sta_monitor_*.pid; do
        [ -f "$pid_file" ] || continue
        pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$pid_file"
    done
}
trap cleanup EXIT TERM INT

# Файлы состояния
SPEED_DEVICE_LIST="/tmp/telegram_bot/speed/device_list"
SPEED_USER_MSGS_FILE="/tmp/telegram_bot/speed/user_msgs"
LAST_UPDATE_FILE="/tmp/telegram_bot/state/.last_update_id"
LOG_FILE="/tmp/telegram_bot/logs/bot.log"
SPEED_MSG_ID=""
SERVICES_MSG_ID=""
SYSTEM_MSG_ID_FILE="/tmp/telegram_bot/state/system_msg_id"
SYSTEM_MSG_ID=""
UPTIME_MSG_ID_FILE="/tmp/telegram_bot/state/uptime_msg_id"
UPTIME_MSG_ID=""
ONLINE_MSG_ID=""
ONLINE_MSG_ID_FILE="/tmp/telegram_bot/online/msg_id"
ONLINE_STATIC_MAC_FILE="/tmp/telegram_bot/online/static_mac"
ONLINE_STATIC_NAME_FILE="/tmp/telegram_bot/online/static_name"
ONLINE_STATIC_IP_FILE="/tmp/telegram_bot/online/static_ip"
ONLINE_STATIC_ORIG_NAME_FILE="/tmp/telegram_bot/online/static_orig_name"
ONLINE_STATIC_ORIG_IP_FILE="/tmp/telegram_bot/online/static_orig_ip"
ONLINE_STATIC_INPUT_FILE="/tmp/telegram_bot/online/static_input"
ONLINE_ERROR_MSG_FILE="/tmp/telegram_bot/online/input_error_msg_id"
TRAFFIC_MSG_ID_FILE="/tmp/telegram_bot/traffic/msg_id"
TRAFFIC_MSG_ID=""
WOL_MSG_ID_FILE="/tmp/telegram_bot/wol/msg_id"
WOL_LAST_ACTIVITY_FILE="/tmp/telegram_bot/wol/last_activity"
SPEED_LAST_ACTIVITY_FILE="/tmp/telegram_bot/speed/last_activity"
WIFI_LAST_ACTIVITY_FILE="/tmp/telegram_bot/wifi/last_activity"
REBOOT_MSG_ID_FILE="/tmp/telegram_bot/reboot/msg_id"
REBOOT_LAST_ACTIVITY_FILE="/tmp/telegram_bot/reboot/last_activity"
_services_set_msg_id() { SERVICES_MSG_ID="$1"; }
CRITICAL_MSG_ID=""
_critical_set_msg_id() { CRITICAL_MSG_ID="$1"; }
SERVICES_MODE_FILE="/tmp/telegram_bot/services/mode"
SERVICES_LAST_RESULT=""
SERVICES_LAST_ACTIVITY_FILE="/tmp/telegram_bot/services/last_activity"

echo "=== Бот запущен $(date) ===" > "$LOG_FILE"
rm -f /tmp/telegram_bot/wifi/state.json /tmp/telegram_bot/wifi/msg_id /tmp/telegram_bot/wifi/edit_mode /tmp/telegram_bot/wifi/edit_msg_id
rm -f /tmp/telegram_bot/wifi/show_password*.txt /tmp/telegram_bot/wifi/scan_result
rm -f /tmp/telegram_bot/wifi/edit_section /tmp/telegram_bot/wifi/create_type /tmp/telegram_bot/wifi/create_radio
rm -f /tmp/telegram_bot/wifi/current_menu /tmp/telegram_bot/wifi/current_band /tmp/telegram_bot/wifi/current_create_type
rm -f /tmp/telegram_bot/wifi/error_msg_id /tmp/telegram_bot/wifi/sta_essid /tmp/telegram_bot/wifi/sta_enc
rm -f /tmp/telegram_bot/wifi/new_ap_ssid /tmp/telegram_bot/wifi/connecting_msg_id
rm -f /tmp/telegram_bot/wifi/active.lock

rm -f "$ONLINE_MSG_ID_FILE" "$TRAFFIC_MSG_ID_FILE" "$SYSTEM_MSG_ID_FILE" "$UPTIME_MSG_ID_FILE"
rm -f /tmp/telegram_bot/state/bot_disable_msg_id /tmp/telegram_bot/state/bot_uninstall_msg_id
( _services_get_cached_list > /dev/null 2>&1 ) &

if [ -f "/tmp/telegram_bot/services/msg_id" ]; then
    msg_id=$(cat "/tmp/telegram_bot/services/msg_id" 2>/dev/null)
    if [ -n "$msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$msg_id" > /dev/null 2>&1
    fi
    rm -f "/tmp/telegram_bot/services/msg_id"
fi
if [ -f "/tmp/telegram_bot/critical/msg_id" ]; then
    msg_id=$(cat "/tmp/telegram_bot/critical/msg_id" 2>/dev/null)
    if [ -n "$msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$msg_id" > /dev/null 2>&1
    fi
    rm -f "/tmp/telegram_bot/critical/msg_id"
fi
rm -f "$SERVICES_LAST_ACTIVITY_FILE"

SPEED_ERROR_MSG_ID_FILE="/tmp/telegram_bot/speed/error_msg_id"

# ==============================================================================
# 🛠️ РАЗДЕЛ 2: ОБЩИЕ УТИЛИТЫ (CORE)
# ==============================================================================

_update_activity() {
    local file="$1"
    [ -n "$file" ] && date +%s > "$file" 2>/dev/null
}

_check_activity_timeout() {
    local file="$1"
    local timeout="${2:-600}"
    if [ ! -f "$file" ]; then
        return 0
    fi
    local now=$(date +%s)
    local last=$(cat "$file" 2>/dev/null || echo 0)
    case "$last" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ $((now - last)) -gt "$timeout" ]; then
        return 1
    fi
    return 0
}

_clear_previous_error() {
    if [ -f "/tmp/telegram_bot/state/event_toggle_msg_id" ]; then
        local _etid=$(cat "/tmp/telegram_bot/state/event_toggle_msg_id" 2>/dev/null)
        [ -n "$_etid" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_etid" >/dev/null 2>&1
        rm -f "/tmp/telegram_bot/state/event_toggle_msg_id"
    fi
    if [ -f "/tmp/telegram_bot/state/keyboard_toggle_msg_id" ]; then
        local _ktid=$(cat "/tmp/telegram_bot/state/keyboard_toggle_msg_id" 2>/dev/null)
        [ -n "$_ktid" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_ktid" >/dev/null 2>&1
        rm -f "/tmp/telegram_bot/state/keyboard_toggle_msg_id"
    fi
    local _f="$SPEED_ERROR_MSG_ID_FILE"
    if [ -f "$_f" ]; then
        local _fid
        while IFS= read -r _fid; do
            [ -z "$_fid" ] && continue
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$_fid" > /dev/null 2>&1
        done < "$_f"
        rm -f "$_f"
    fi
}

_show_error_msg() {
    local text="$1"
    local response
    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$text" \
        -d parse_mode="HTML" 2>&1)
    local _id
    _id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
    if [ -n "$_id" ]; then
        echo "$_id" >> "$SPEED_ERROR_MSG_ID_FILE"
    fi
}

send_message() {
    local text="$1"
    local keyboard="$2"

    if [ -f "/tmp/telegram_bot/flags/no_reply_kb" ] && [ "$keyboard" = "$MAIN_KEYBOARD" ]; then
        keyboard='{"remove_keyboard":true}'
    fi

    local response
    if [ -n "$keyboard" ]; then
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" \
            -d disable_web_page_preview="true" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" \
            -d disable_web_page_preview="true" 2>&1)
    fi
    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        local err=$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null)
        echo "$(date): send_message failed: $err" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi
    return 0
}

send_long_message() {
    local text="$1"
    local keyboard="$2"
    local max_len=3900

    if [ ${#text} -le $max_len ]; then
        send_message "$text" "$keyboard"
        return
    fi

    local inner="$text"
    local had_pre=0
    case "$text" in
        "<pre>"*"</pre>")
            had_pre=1
            inner="${text#<pre>}"
            inner="${inner%</pre>}"
            ;;
    esac

    local first=1
    local accum=""
    local temp_file="/tmp/send_msg_$$"
    printf '%s\n' "$inner" > "$temp_file"

    while IFS= read -r line; do
        if [ ${#line} -gt $max_len ]; then
            if [ -n "$accum" ]; then
                _send_part "$accum" "$keyboard" "$first" "$had_pre"
                first=0
                accum=""
            fi
            local rest="$line"
            while [ ${#rest} -gt $max_len ]; do
                _send_part "${rest:0:$max_len}" "$keyboard" "$first" "$had_pre"
                first=0
                rest="${rest:$max_len}"
            done
            accum="$rest"
            continue
        fi

        if [ $(( ${#accum} + ${#line} + 1 )) -gt $max_len ]; then
            _send_part "$accum" "$keyboard" "$first" "$had_pre"
            first=0
            accum="$line"
        else
            if [ -z "$accum" ]; then
                accum="$line"
            else
                accum="${accum}"$'\n'"${line}"
            fi
        fi
    done < "$temp_file"

    if [ -n "$accum" ]; then
        _send_part "$accum" "$keyboard" "$first" "$had_pre"
    fi
    rm -f "$temp_file"
}

_send_part() {
    local content="$1"
    local keyboard="$2"
    local first="$3"
    local had_pre="$4"

    local out="$content"
    if [ "$had_pre" = "1" ]; then
        out="<pre>${content}</pre>"
    fi

    if [ "$first" = "1" ] && [ -n "$keyboard" ]; then
        send_message "$out" "$keyboard"
    else
        send_message "$out"
    fi
}

send_message_and_get_id() {
    local text="$1"
    local keyboard="$2"

    if [ -f "/etc/telegram_bot/data/.no_reply_kb" ] && [ "$keyboard" = "$MAIN_KEYBOARD" ]; then
        keyboard='{"remove_keyboard":true}'
    fi

    local response
    if [ -n "$keyboard" ]; then
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" \
            -d disable_web_page_preview="true" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$text" \
            -d parse_mode="HTML" \
            -d disable_web_page_preview="true" 2>&1)
    fi

    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        local err=$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null)
        echo "$(date): send_message_and_get_id failed: $err" >> /tmp/telegram_bot/logs/bot.log
        echo ""
        return 1
    fi

    local msg_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
    if [ -z "$msg_id" ]; then
        echo "$(date): send_message_and_get_id: ok=true но message_id пуст" >> /tmp/telegram_bot/logs/bot.log
        echo ""
        return 1
    fi
    echo "$msg_id"
    return 0
}

edit_message_reply_markup() {
    local chat_id="$1"
    local message_id="$2"
    local keyboard="$3"
    local response
    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageReplyMarkup" \
        -d chat_id="$chat_id" \
        -d message_id="$message_id" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        local err=$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null)
        echo "$(date): edit_message_reply_markup failed: $err" >> /tmp/telegram_bot/logs/bot.log
    fi
}

_expl_visual_len() {
    local s="$1"
    local len=0
    local i ch code
    local n=${#s}
    for ((i=0; i<n; i++)); do
        ch="${s:i:1}"
        code=$(printf "%d" "'$ch" 2>/dev/null)
        if [ "$code" -ge 65024 ] && [ "$code" -le 65039 ]; then
            continue
        fi
        if [ -z "$code" ] || [ "$code" -lt 9728 ]; then
            len=$((len+1))
        else
            len=$((len+2))
        fi
    done
    echo "$len"
}

# ==============================================================================
# 🏠 РАЗДЕЛ 3: ГЛАВНОЕ МЕНЮ
# ==============================================================================

MAIN_KEYBOARD='{"keyboard":[
    ["🔴 Перезагрузить роутер", "🕒 Время работы"],
    ["📊 Статус системы", "📋 Журнал событий"],
    ["🛜 Настройка Wi-Fi", "🔧 Автозапуск"],
    ["🖥️ Клиенты онлайн", "📊 Трафик"],
    ["⏱ Ограничить скорость", "🌐 Wake-on-LAN"],
    ["📁 Проводник", "📖 Справка"]
],"resize_keyboard":true,"one_time_keyboard":true}'

send_menu() {
    local _kb="$MAIN_KEYBOARD"
    if [ -f /tmp/telegram_bot/flags/no_reply_kb ]; then
        _kb='{"remove_keyboard":true}'
    fi
    _send_menu_tracked "🏠 <b>Выберите действие</b>" "$_kb"
}

# ==============================================================================
# ⚙️ РАЗДЕЛ 4: АВТОЗАПУСК (SERVICES)
# ==============================================================================

set_services_mode() {
    echo "$1" > "$SERVICES_MODE_FILE"
}

get_services_mode() {
    if [ -f "$SERVICES_MODE_FILE" ]; then
        cat "$SERVICES_MODE_FILE"
    else
        echo "0"
    fi
}

_services_update_last_activity() {
    date +%s > "$SERVICES_LAST_ACTIVITY_FILE"
}

_services_check_activity() {
    local now=$(date +%s)
    local last=0
    [ -f "$SERVICES_LAST_ACTIVITY_FILE" ] && last=$(cat "$SERVICES_LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
    if [ $((now - last)) -gt 600 ]; then
        return 1
    fi
    return 0
}

CACHE_FILE="/tmp/telegram_bot/services/cache.json"
CACHE_TTL=300  

_services_get_cached_list() {
    if [ -f "$CACHE_FILE" ]; then
        local age_min=$(find "$CACHE_FILE" -mmin +$((CACHE_TTL / 60)) 2>/dev/null)
        if [ -z "$age_min" ]; then
            cat "$CACHE_FILE"
            return
        fi
    fi
    local list=$(_services_get_list)
    echo "$list" > "${CACHE_FILE}.tmp.$$" && mv "${CACHE_FILE}.tmp.$$" "$CACHE_FILE"
    echo "$list"
}

_services_invalidate_cache() {
    rm -f "$CACHE_FILE"
}

_services_get_page() {
    local page_file="/tmp/telegram_bot/services/page"
    if [ ! -f "$page_file" ]; then
        echo "1" > "$page_file"
    fi
    cat "$page_file"
}

_services_set_page() {
    local page="$1"
    echo "$page" > "/tmp/telegram_bot/services/page"
}

_services_get_list() {
    local services=$(ls /etc/init.d/ 2>/dev/null | grep -v 'README' | sort)

    declare -A prio_map
    for link in /etc/rc.d/S[0-9][0-9]*; do
        [ -e "$link" ] || continue
        base="${link##*/}"
        prio="${base:1:2}"
        name="${base:3}"
        [ -n "$name" ] && prio_map["$name"]="$prio"
    done

    local ubus_json=$(ubus call service list 2>/dev/null)

    declare -A status_map
    while IFS='=' read -r k v; do
        status_map["$k"]="$v"
    done <<< "$(echo "$ubus_json" | jq -r 'to_entries[] | "\(.key)=\(if ([.value.instances[]?.running] | any) then "running" else "stopped" end)"' 2>/dev/null)"

    local json="["
    local first=1

    for svc in $services; do
        local status="${status_map[$svc]:-stopped}"
        local priority="${prio_map[$svc]}"
        if [ -z "$priority" ]; then
            priority=$(awk -F= '/^START=/{print $2; exit}' "/etc/init.d/$svc" 2>/dev/null)
            [ -z "$priority" ] && priority="-"
        fi
        local enabled="Отключён"
        [ -n "${prio_map[$svc]}" ] && enabled="Включено"
        if [ $first -eq 1 ]; then
            first=0
        else
            json="$json,"
        fi
        json="$json{\"name\":\"$svc\",\"status\":\"$status\",\"priority\":\"$priority\",\"enabled\":\"$enabled\"}"
    done
    json="$json]"
    echo "$json" | jq -c 'sort_by(if .priority == "-" then 999 else (.priority | tonumber) end)'
}

_services_get_selected() {
    local sel_file="/tmp/telegram_bot/services/selected.json"
    if [ ! -f "$sel_file" ]; then
        echo "[]" > "$sel_file"
    fi
    cat "$sel_file"
}

_services_set_selected() {
    local selected="$1"
    printf "%s" "$selected" > "/tmp/telegram_bot/services/selected.json"
}

show_services() {
    local edit_msg_id="$1"
    _services_update_last_activity

    local list_json=$(_services_get_cached_list)
    local total
    local _svc_err_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
    
    if ! total=$(echo "$list_json" | jq '. | length' 2>/dev/null); then
        send_message "❌ <b>Ошибка получения списка служб (сбой JSON)</b>" "$_svc_err_kb"
        return 1
    fi
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
        send_message "❌ <b>Список служб пуст</b>" "$_svc_err_kb"
        return 1
    fi

    local selected_json=$(_services_get_selected)
    local current_page=$(_services_get_page)
    local page_size=21
    local total_pages=$(( (total + page_size - 1) / page_size ))
    
    if [ "$current_page" -gt "$total_pages" ]; then
        current_page="$total_pages"
        _services_set_page "$current_page"
    fi

    local start=$(( (current_page - 1) * page_size + 1 ))
    local end=$(( start + page_size - 1 ))
    [ "$end" -gt "$total" ] && end="$total"

    local data=$(echo "$list_json" | jq -r --argjson start "$start" --argjson end "$end" '
        .[$start-1:$end] | to_entries[] | "\($start + .key)|\(.value.name)|\(.value.status)|\(.value.priority)|\(.value.enabled)"'
    )

    local table_body=""
    local header="№  Служба                 PR  Автозапуск  Статус"$'\n'
    header="${header}-- ---------------------- --  ---------- ----------"$'\n'
    table_body="$header"

    if [ -n "$data" ]; then
        while IFS='|' read -r num name status priority enabled; do
            local short_name=$(printf "%-22.22s" "$name")
            local status_icon="🟢"
            case "$status" in
                stopped) status_icon="🔴" ;;
                idle)    status_icon="🟡" ;;
            esac
            printf -v line "%-2s %-22s %2s   %10s  %s %s" "$num" "$short_name" "$priority" "$enabled" "$status_icon" "$status"
            table_body="${table_body}${line}"$'\n'
        done <<< "$data"
    else
        table_body="${header}   Нет служб на этой странице"$'\n'
    fi

    local sel_count=$(echo "$selected_json" | jq '. | length')
    local sel_line=""
    if [ "$sel_count" -gt 0 ]; then
        local sel_list=$(echo "$selected_json" | jq -r '.[]' | tr '\n' ' ' | sed 's/ $//')
        sel_line="Выбрано: $sel_list"
    else
        sel_line="Выбрано: (нет) "
    fi

    local legend="${SEP46}"$'\n'
    legend="${legend}Легенда:  ⇄ – автозапуск включено/отключено"$'\n'
    legend="${legend}          ▷ – старт          ↻ – перезапустить"$'\n'
    legend="${legend}          ⇅ – перезагрузить   □ – остановить"
	
    local results_block=""
    if [ -n "$SERVICES_LAST_RESULT" ]; then
        local _cmd_label="${SERVICES_LAST_CMD:-команда}"
        local _safe_results
        _safe_results=$(printf '%s' "$SERVICES_LAST_RESULT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        _safe_results=$(printf '%b' "$_safe_results")
        while [ "${_safe_results%$'\n'}" != "$_safe_results" ]; do
            _safe_results="${_safe_results%$'\n'}"
        done
        results_block="${SEP46}"$'\n'
        results_block="${results_block}📊 РЕЗУЛЬТАТ ${_cmd_label^^}:"$'\n'
        results_block="${results_block}${_safe_results}"$'\n'
        SERVICES_LAST_RESULT=""
        SERVICES_LAST_CMD=""
    fi

    local table="<pre>📋 УПРАВЛЕНИЕ АВТОЗАПУСКОМ (стр. $current_page/$total_pages)"$'\n'
    table="${table}"$'\n'
    table="${table}${SEP46}"$'\n'
    table="${table}${table_body}"
    table="${table}${SEP46}"$'\n'
    table="${table}${sel_line}"$'\n'
    table="${table}${results_block}"
    table="${table}${legend}"$'\n'
    table="${table}${SEP46}"$'\n'
    table="${table}🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    table="${table}"$'\n'
    table="${table}Выберите № службы кнопками (можно несколько):</pre>"

    local rows=()
    local current_row=""
    local row_count=0
    local all_num_rows=()
    local last_row_len=0
    
    for ((i=start; i<=end; i++)); do
        [ -n "$current_row" ] && current_row="$current_row,"
        current_row="$current_row{\"text\":\"$i\",\"callback_data\":\"svc_select_$i\"}"
        row_count=$((row_count + 1))
        if [ "$row_count" -eq 8 ]; then
            all_num_rows+=("$current_row")
            current_row=""
            row_count=0
        fi
    done
    if [ -n "$current_row" ]; then
        all_num_rows+=("$current_row")
        last_row_len=$row_count
    else
        last_row_len=8
    fi

    local nav_back=""
    [ "$current_page" -gt 1 ] && nav_back="{\"text\":\"⬅️\",\"callback_data\":\"svc_page_prev\"}"
    local nav_fwd=""
    [ "$current_page" -lt "$total_pages" ] && nav_fwd="{\"text\":\"➡️\",\"callback_data\":\"svc_page_next\"}"
    local btn_reset="{\"text\":\"↩️\",\"callback_data\":\"svc_reset_selection\"}"
    
    local control_count=1
    [ -n "$nav_back" ] && control_count=$((control_count + 1))
    [ -n "$nav_fwd" ] && control_count=$((control_count + 1))

    if [ ${#all_num_rows[@]} -gt 0 ]; then
        local last_idx=$(( ${#all_num_rows[@]} - 1 ))
        if [ $((last_row_len + control_count)) -le 8 ]; then
            local merged_row=""
            [ -n "$nav_back" ] && merged_row="$nav_back,"
            merged_row="${merged_row}${all_num_rows[$last_idx]}"
            merged_row="${merged_row},${btn_reset}"
            [ -n "$nav_fwd" ] && merged_row="${merged_row},${nav_fwd}"
            all_num_rows[$last_idx]="$merged_row"
        else
            local ctrl_row=""
            [ -n "$nav_back" ] && ctrl_row="$nav_back,"
            ctrl_row="${ctrl_row}${btn_reset}"
            [ -n "$nav_fwd" ] && ctrl_row="${ctrl_row},${nav_fwd}"
            all_num_rows+=("$ctrl_row")
        fi
    else
        local ctrl_row=""
        [ -n "$nav_back" ] && ctrl_row="$nav_back,"
        ctrl_row="${ctrl_row}${btn_reset}"
        [ -n "$nav_fwd" ] && ctrl_row="${ctrl_row},${nav_fwd}"
        all_num_rows+=("$ctrl_row")
    fi

    for r in "${all_num_rows[@]}"; do
        rows+=("[$r]")
    done

    rows+=("[{\"text\":\"⇄\",\"callback_data\":\"svc_toggle\"},{\"text\":\"▷\",\"callback_data\":\"svc_start\"},{\"text\":\"↻\",\"callback_data\":\"svc_restart\"},{\"text\":\"⇅\",\"callback_data\":\"svc_reload\"},{\"text\":\"□\",\"callback_data\":\"svc_stop\"}]")
    rows+=("[{\"text\":\"🔄 Обновить\",\"callback_data\":\"svc_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"svc_cancel\"}]")

    local keyboard="{\"inline_keyboard\":"
    local first_row=1
    local joined=""
    for r in "${rows[@]}"; do
        [ $first_row -eq 1 ] && first_row=0 || joined="$joined,"
        joined="$joined$r"
    done
    keyboard="$keyboard[$joined]}"

    if [ -n "$edit_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$edit_msg_id" \
            --data-urlencode text="$table" \
            -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" > /dev/null 2>&1
        _services_set_msg_id "$edit_msg_id"
        echo "$edit_msg_id" > /tmp/telegram_bot/services/msg_id
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$table" \
            -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        local new_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
        _services_set_msg_id "$new_id"
        echo "$new_id" > /tmp/telegram_bot/services/msg_id
    fi
}

# ==============================================================================
# ⏱️ РАЗДЕЛ 5: ОГРАНИЧЕНИЕ СКОРОСТИ (SPEED LIMIT)
# ==============================================================================

_get_progress_indicator() {
    local current_step="$1"
    local total_steps=4
    local steps_names=("Входящая скорость" "Исходящая скорость" "Время действия" "Дни недели")
    local filled=""
    local i=0
    while [ $i -lt $total_steps ]; do
        if [ $i -lt $current_step ]; then
            filled="${filled}●"
        else
            filled="${filled}○"
        fi
        i=$((i + 1))
    done
    local dots=""
    i=0
    while [ $i -lt ${#filled} ]; do
        dots="${dots}${filled:$i:1} "
        i=$((i + 1))
    done
    dots="${dots% }"
    local step_name="${steps_names[$((current_step - 1))]}"
    echo "$dots  Шаг $current_step/$total_steps: $step_name"
}

_get_speed_state() {
    local state_file="/tmp/telegram_bot/speed/state.json"
    if [ ! -f "$state_file" ]; then
        return 1
    fi
    if ! jq empty "$state_file" 2>/dev/null; then
        rm -f "$state_file"
        return 1
    fi
    cat "$state_file"
    return 0
}

_update_speed_state() {
    local step="$1"
    local mac="$2"
    local name="$3"
    local rx_bytes="$4"
    local rx_display="$5"
    local tx_bytes="$6"
    local tx_display="$7"
    local start_time="$8"
    local end_time="$9"
    local days_mask="${10}"
    local manual="${11:-false}"
    local from_profile="${12:-false}"
    days_mask=$((days_mask + 0))

    jq -n \
        --arg step "$step" \
        --arg mac "$mac" \
        --arg name "$name" \
        --argjson rx_bytes "${rx_bytes:-0}" \
        --arg rx_display "$rx_display" \
        --argjson tx_bytes "${tx_bytes:-0}" \
        --arg tx_display "$tx_display" \
        --arg start_time "$start_time" \
        --arg end_time "$end_time" \
        --argjson days_mask "$days_mask" \
        --argjson manual "$manual" \
        --argjson from_profile "$from_profile" \
        '{
            step: $step, mac: $mac, name: $name,
            rx_bytes: $rx_bytes, rx_display: $rx_display,
            tx_bytes: $tx_bytes, tx_display: $tx_display,
            start_time: $start_time, end_time: $end_time,
            days_mask: $days_mask, manual: $manual, from_profile: $from_profile
        }' > /tmp/telegram_bot/speed/state.json
}

_speed_track_user_msg() {
    local _mid="$1"
    [ -z "$_mid" ] && return 0
    echo "$_mid" >> "$SPEED_USER_MSGS_FILE" 2>/dev/null
}

_speed_cleanup_user_msgs() {
    local _f="$SPEED_USER_MSGS_FILE"
    [ -f "$_f" ] || return 0
    local _mid
    while IFS= read -r _mid; do
        [ -z "$_mid" ] && continue
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1
    done < "$_f"
    rm -f "$_f"
}

reset_device_selection() {
    rm -f "/tmp/telegram_bot/speed/state.json" "/tmp/telegram_bot/speed/device_list"
    rm -f "/tmp/telegram_bot/speed/limit_msg_id"
    rm -f "/tmp/telegram_bot/speed/msg_id"
    SPEED_MSG_ID=""
}

_build_device_table() {
    local mac="$1"
    local name="$2"
    local ip="$3"
    local rx_display="$4"
    local tx_display="$5"
    local time_display="$6"
    local days_display="$7"
    local status_msg="$8"
    local extra_text="$9"
    local step="${10:-1}"
    local extra_lines=""

    local safe_name=$(html_escape "$name")   

    [ -z "$ip" ] && ip="N/A"
    [ -z "$rx_display" ] && rx_display="——"
    [ -z "$tx_display" ] && tx_display="——"
    [ -z "$time_display" ] && time_display=""
    [ -z "$days_display" ] && days_display=""
    [ -z "$extra_text" ] && extra_text=""

    if echo "$rx_display" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        rx_display=$(/etc/telegram_bot/notify.sh format_speed "$(echo "$rx_display" | cut -d'.' -f1)" 2>/dev/null || echo "$rx_display")
    fi
    if echo "$tx_display" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        tx_display=$(/etc/telegram_bot/notify.sh format_speed "$(echo "$tx_display" | cut -d'.' -f1)" 2>/dev/null || echo "$tx_display")
    fi

    if [ -n "$rx_display" ] && [ "$rx_display" != "——" ]; then
        extra_lines="${extra_lines}⬇️ Входящая: ${rx_display}\n"
    fi
    if [ -n "$tx_display" ] && [ "$tx_display" != "——" ]; then
        extra_lines="${extra_lines}⬆️ Исходящая: ${tx_display}\n"
    fi
    if [ -n "$time_display" ]; then
        extra_lines="${extra_lines}🕛 Действует: ${time_display}\n"
    fi
    if [ -n "$days_display" ]; then
        extra_lines="${extra_lines}📅 Дни: ${days_display}\n"
    fi

    local progress=$(_get_progress_indicator "$step")

    local msg="<pre>${progress}

${status_msg}
$SEP46
📱 $safe_name
🌐 $ip
🔗 $mac
${extra_lines}$SEP46"
    if [ -n "$extra_text" ]; then
        msg="${msg}\n$(printf '%52s' '')\n${extra_text}"
    fi
    msg="${msg}</pre>"
    printf '%b\n' "$msg"
}

_send_and_save_id() {
    local text="$1"
    local keyboard="$2"
    local id_file="$3"
    _update_activity "$SPEED_LAST_ACTIVITY_FILE"

    local msg_id=""
    if [ -f "$id_file" ] && [ -s "$id_file" ]; then
        msg_id=$(cat "$id_file" 2>/dev/null)
    fi
    if [ -z "$msg_id" ] && [ -n "$SPEED_MSG_ID" ]; then
        msg_id="$SPEED_MSG_ID"
    fi

    if [ -n "$msg_id" ]; then
        echo "$msg_id" > "$id_file"
        if [ -f "/tmp/telegram_bot/speed/state.json" ]; then
            local new_state
            if new_state=$(_get_speed_state); then
                echo "$new_state" | jq --arg mid "$msg_id" '.message_id = $mid' > "/tmp/telegram_bot/speed/state.json"
            fi
        fi
    fi

    if [ -n "$msg_id" ]; then
        local response
        if [ -n "$keyboard" ]; then
            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
                --data-urlencode text="$text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$keyboard" 2>&1)
        else
            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
                --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
        fi
        if echo "$response" | grep -q '"ok":false'; then
            local err_desc
            err_desc=$(echo "$response" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//;s/"$//')
            if echo "$err_desc" | grep -qi "message is not modified"; then
                return 0
            fi
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" > /dev/null 2>&1
            rm -f "$id_file"
            if [ -n "$keyboard" ]; then
                response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
                    --data-urlencode "reply_markup=$keyboard" 2>&1)
            else
                response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
            fi
            local new_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
            if [ -n "$new_id" ]; then
                echo "$new_id" > "$id_file"
                SPEED_MSG_ID="$new_id"
            fi
        else
            local new_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
            if [ -n "$new_id" ] && [ "$new_id" != "$msg_id" ]; then
                echo "$new_id" > "$id_file"
                SPEED_MSG_ID="$new_id"
            fi
        fi
    else
        local response
        if [ -n "$keyboard" ]; then
            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$keyboard" 2>&1)
        else
            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
        fi
        local new_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
        if [ -n "$new_id" ]; then
            echo "$new_id" > "$id_file"
            SPEED_MSG_ID="$new_id"
        fi
    fi
}

_resend_current_table() {
    local state_file="/tmp/telegram_bot/speed/state.json"
    if [ ! -f "$state_file" ]; then return; fi
    local state
    if ! state=$(_get_speed_state); then return; fi

    local step=$(echo "$state" | jq -r '.step // ""')
    local mac=$(echo "$state" | jq -r '.mac // ""')
    local name=$(echo "$state" | jq -r '.name // ""')
    local rx_display=$(echo "$state" | jq -r '.rx_display // ""')
    local tx_display=$(echo "$state" | jq -r '.tx_display // ""')
    local start_time=$(echo "$state" | jq -r '.start_time // ""')
    local end_time=$(echo "$state" | jq -r '.end_time // ""')
    local days_mask=$(echo "$state" | jq -r '.days_mask // 127')
    local manual=$(echo "$state" | jq -r '.manual // false')

    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
    [ -z "$ip" ] && ip="N/A"

    local time_display=""
    if [ -n "$start_time" ] && [ -n "$end_time" ]; then
        time_display="${start_time} - ${end_time}"
    fi

    local status_msg=""
    local extra_text=""
    local keyboard=""

    local progress_step=1
    case "$step" in
        "choose_tx") progress_step=2 ;;
        "choose_time") progress_step=3 ;;
        "interval_input") progress_step=3 ;;
        "choose_days") progress_step=4 ;;
        *) progress_step=1 ;;
    esac

    case "$step" in
        "device_selected")
            status_msg="✅ Вы выбрали устройство:"
            extra_text="Выберите действие, нажав на кнопку ниже:"
            keyboard=$(get_speed_action_keyboard_with_back)
            ;;
        "choose_rx")
            if [ "$manual" = "true" ]; then
                status_msg="✅ Вы выбрали устройство:"
                extra_text="✏️ Введите число в MB/s (например: 0.3)"
                keyboard='{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'
            else
                status_msg="✅ Вы выбрали устройство:"
                extra_text="🕒 ЗАДАЙТЕ ВХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ"
                keyboard=$(get_speed_keyboard_with_back)
            fi
            ;;
        "choose_tx")
            if [ "$manual" = "true" ]; then
                status_msg="✅ Входящая скорость установлена: $rx_display"
                extra_text="✏️ Введите число в MB/s (например: 0.3)"
                keyboard='{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'
            else
                status_msg="✅ Входящая скорость установлена: $rx_display"
                extra_text="🕒 ЗАДАЙТЕ ИСХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ"
                keyboard=$(get_speed_keyboard_with_back)
            fi
            ;;
        "choose_time")
            status_msg="✅ Ограничения скорости установлены"
            extra_text="🕒 ЗАДАЙТЕ ВРЕМЯ ДЕЙСТВИЯ ЛИМИТА"
            keyboard=$(get_duration_keyboard_with_back)
            ;;
        "choose_days")
            status_msg="✅ Время установлено"
            extra_text="📅 ВЫБЕРИТЕ ДНИ ДЕЙСТВИЯ ЛИМИТА"
            keyboard=$(get_days_keyboard_with_back "$days_mask")
            ;;
        "interval_input")
            status_msg="✅ Ограничения скорости установлены"
            extra_text="✏️ Введите интервал времени: ЧЧ:ММ-ЧЧ:ММ"
            keyboard='{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'
            ;;
        *)
            status_msg="⚠️ Неизвестное состояние"
            extra_text="Попробуйте начать заново"
            keyboard='{"inline_keyboard":[[{"text":"❌ Отмена","callback_data":"cancel"}]]}'
            ;;
    esac

    if [ -z "$step" ]; then
        reset_device_selection
        send_message "⚠️ Ошибка состояния. Попробуйте заново." "$MAIN_KEYBOARD"
        return
    fi

    local table=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "$time_display" "" "$status_msg" "$extra_text" "$progress_step")
    _send_and_save_id "$table" "$keyboard" "/tmp/telegram_bot/speed/msg_id"
    SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
}

show_device_list() {
    rm -f /tmp/telegram_bot/speed/limit_selected_uuid
    local _err_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'

    if ! command -v jq >/dev/null 2>&1; then
        send_message "❌ <b>Ошибка:</b> для работы требуется jq. Установите: <code>apk add jq</code>" "$_err_kb"
        return
    fi

    if ! ubus list luci.bandix 2>/dev/null | grep -q "^luci.bandix$"; then
        send_message "⚠️ <b>Пакет luci.bandix не установлен.</b>

Скачайте и установите:
🔗 <a href=\"https://github.com/timsaya/openwrt-bandix/releases\">openwrt-bandix</a>
🔗 <a href=\"https://github.com/timsaya/luci-app-bandix/releases\">luci-app-bandix</a>

После установки перезапустите бота:
<code>/restart</code>" "$_err_kb"
        return
    fi

    devices_json=$(ubus call luci.bandix getStatus 2>/dev/null)
    if [ -z "$devices_json" ]; then
        send_message "⚠️ <b>Ошибка:</b> не удалось получить список устройств." "$_err_kb"
        return
    fi

    local limits_json=$(ubus call luci.bandix getScheduleLimits 2>/dev/null)
    local arp_macs=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -vE "FAILED|INCOMPLETE" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | tr '[:upper:]' '[:lower:]' | sort -u)
    local tmp_file="/tmp/device_list_tmp"
    rm -f "$tmp_file"
    local devices_raw=$(echo "$devices_json" | jq -r '.d[] | select(.conn != null and .conn != "") | "\(.mac | ascii_downcase)|\(.host // "Unknown")"' 2>/dev/null | sort)

    local count=0
    local table_data=""
    local num=1

    while IFS='|' read -r mac host; do
        [ -z "$mac" ] && continue
        if echo "$arp_macs" | grep -q -x "$mac"; then
            local name=$(echo "$host" | sed 's/\.lan$//')
            [ -z "$name" ] && name="$mac"
            local safe_name=$(html_escape "$name")   

            local active_count=0
            local total_count=0
            if [ -n "$limits_json" ]; then
                active_count=$(echo "$limits_json" | jq -r "[.data.limits[] | select(.mac | ascii_downcase == \"$mac\") | select((.time_slot.days // []) | length > 0)] | length" 2>/dev/null)
                total_count=$(echo "$limits_json" | jq -r "[.data.limits[] | select(.mac | ascii_downcase == \"$mac\")] | length" 2>/dev/null)
            fi
            
            local limits_display=""
            if [ "$total_count" -gt 0 ]; then
                if [ "$active_count" -gt 0 ]; then
                    limits_display="✅ $active_count / $total_count"
                else
                    limits_display="🔴 0 / $total_count"
                fi
            else
                limits_display="----"
            fi

            table_data="${table_data}${num}|${safe_name}|${limits_display}"$'\n'
            echo "$mac|$name" >> "$tmp_file"
            count=$((count + 1))
            num=$((num + 1))
        fi
    done <<< "$devices_raw"

    if [ ! -f "$tmp_file" ] || [ "$count" -eq 0 ]; then
        send_message "⚠️ <b>Нет активных устройств.</b>" "$_err_kb"
        return
    fi

    mv "$tmp_file" "$SPEED_DEVICE_LIST"
    local table=$(printf "%s" "$table_data" | awk -F'|' '
    BEGIN {
        printf "%-2s %-26s  %-20s\n", "№", "Устройство",  "Профили (Акт./Всего)"
        printf "%-2s %-26s  %-20s\n", "--", "--------------------------", "--------------------"
    }
    {
        num = $1; name = $2; limits = $3
        if (length(name) > 26) name = substr(name, 1, 26)
        if (limits == "----") { limits = "      ----      " } else { limits = "    " limits "    " }
        printf "%-2s %-26s    %-16s\n", num, name, limits
    }')

    local msg="<pre>📊 УПРАВЛЕНИЕ СКОРОСТЬЮ

$SEP46
${table}
$SEP46
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите устройство, нажав на кнопку с номером</pre>"

    local keyboard=$(get_device_choice_keyboard "$SPEED_DEVICE_LIST")
    _send_and_save_id "$msg" "$keyboard" "/tmp/telegram_bot/speed/msg_id"
}

_get_device_limits() {
    local mac="$1"
    if ! ubus list luci.bandix 2>/dev/null | grep -q "^luci.bandix$"; then return; fi
    local limits_json=$(ubus call luci.bandix getScheduleLimits 2>/dev/null)
    if [ -z "$limits_json" ]; then return; fi
    echo "$limits_json" | jq -r ".data.limits[] | select(.mac | ascii_downcase == \"$mac\") | \"\(.id)|\(.wan_rx_rate_limit)|\(.wan_tx_rate_limit)|\(.time_slot.start)|\(.time_slot.end)|\(.time_slot.days)\"" 2>/dev/null
}

_limit_toggle_profile() {
    local id="$1"
    local mac="$2"
    local backup_file="/etc/telegram_bot/data/.bandix_days_backup"
    local limits_json
    limits_json=$(ubus call luci.bandix getScheduleLimits 2>/dev/null)
    [ -z "$limits_json" ] && return 1

    local current_days rx tx start end
    current_days=$(echo "$limits_json" | jq -c ".data.limits[] | select(.id == \"$id\") | .time_slot.days" 2>/dev/null)
    rx=$(echo "$limits_json"           | jq -r ".data.limits[] | select(.id == \"$id\") | .wan_rx_rate_limit" 2>/dev/null)
    tx=$(echo "$limits_json"           | jq -r ".data.limits[] | select(.id == \"$id\") | .wan_tx_rate_limit" 2>/dev/null)
    start=$(echo "$limits_json"        | jq -r ".data.limits[] | select(.id == \"$id\") | .time_slot.start" 2>/dev/null)
    end=$(echo "$limits_json"          | jq -r ".data.limits[] | select(.id == \"$id\") | .time_slot.end" 2>/dev/null)

    if [ -z "$current_days" ] || [ "$current_days" = "null" ]; then return 1; fi
    local days_clean=$(echo "$current_days" | tr -d '[]' | tr ',' ' ')

    if [ -z "$days_clean" ]; then
        local saved_days=""
        if [ -f "$backup_file" ]; then
            saved_days=$(awk -F'|' -v id="$id" '$1 == id { print $2; exit }' "$backup_file" 2>/dev/null)
            sed -i "\|^${id}|d" "$backup_file" 2>/dev/null
        fi
        [ -z "$saved_days" ] && saved_days="[1,2,3,4,5,6,7]"
        ubus call luci.bandix updateScheduleLimit \
            "{\"id\":\"$id\",\"mac\":\"$mac\",\"start_time\":\"$start\",\"end_time\":\"$end\",\"days\":\"$saved_days\",\"wan_rx_rate_limit\":$rx,\"wan_tx_rate_limit\":$tx}" >/dev/null
    else
        if ! grep -q -F "${id}|" "$backup_file" 2>/dev/null; then
            echo "${id}|${current_days}" >> "$backup_file"
        fi
        ubus call luci.bandix updateScheduleLimit \
            "{\"id\":\"$id\",\"mac\":\"$mac\",\"start_time\":\"$start\",\"end_time\":\"$end\",\"days\":\"[]\",\"wan_rx_rate_limit\":$rx,\"wan_tx_rate_limit\":$tx}" >/dev/null
    fi
    return 0
}

_limit_build_profiles_keyboard() {
    local total="$1"
    local selected_uuid="$2"
    shift 2
    local profiles=("$@")
    local keyboard='{"inline_keyboard":['

    local row1=""
    if [ "$total" -gt 0 ]; then
        local i=1
        for profile in "${profiles[@]}"; do
            IFS='|' read -r id _ _ _ _ _ <<< "$profile"
            local mark="🔲"
            [ "$id" = "$selected_uuid" ] && mark="✅"
            [ -n "$row1" ] && row1="$row1,"
            row1="$row1{\"text\":\"$mark $i\",\"callback_data\":\"limit_select_${id}\"}"
            i=$((i+1))
        done
    fi
    keyboard="$keyboard[$row1],"

    if [ -n "$selected_uuid" ]; then
        local sel_days=""
        for profile in "${profiles[@]}"; do
            IFS='|' read -r id _ _ _ _ days <<< "$profile"
            if [ "$id" = "$selected_uuid" ]; then sel_days="$days"; break; fi
        done
        local sel_days_clean=$(echo "$sel_days" | tr -d '[]' | tr ',' ' ')
        local toggle_text="🔴 Выключить"
        [ -z "$sel_days_clean" ] && toggle_text="🟢 Включить"
        keyboard="$keyboard[{\"text\":\"$toggle_text\",\"callback_data\":\"limit_toggle_${selected_uuid}\"},{\"text\":\"🗑️ Удалить\",\"callback_data\":\"limit_delete_${selected_uuid}\"}],"
    fi

    if [ "$total" -lt 5 ]; then
        keyboard="$keyboard[{\"text\":\"➕ Добавить профиль\",\"callback_data\":\"limit_add_new\"},"
    else
        keyboard="$keyboard[{\"text\":\"⚠️ Лимит 5/5\",\"callback_data\":\"limit_max_reached\"},"
    fi
    keyboard="$keyboard{\"text\":\"🗑️ Удалить все\",\"callback_data\":\"limit_remove_all\"}],"
    keyboard="$keyboard[{\"text\":\"⬅️ Назад\",\"callback_data\":\"limit_back\"},{\"text\":\"❌ Отмена\",\"callback_data\":\"cancel\"}]"
    keyboard="$keyboard]}"
    echo "$keyboard"
}

show_device_limits() {
    local mac="$1"
    local name="$2"
    if [ ${#name} -gt 17 ]; then name="${name:0:17}"; fi
    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
    [ -z "$ip" ] && ip="N/A"

    local profiles=$(_get_device_limits "$mac")
    local profile_ids=()
    local profile_data=()
    local total_profiles=0

    while IFS='|' read -r id rx tx start end days; do
        if [ -n "$id" ]; then
            total_profiles=$((total_profiles + 1))
            profile_ids+=("$id")
            profile_data+=("$id|$rx|$tx|$start|$end|$days")
        fi
    done <<< "$profiles"

    local _order_file="/etc/telegram_bot/data/.bandix_profiles_order.txt"
    local _ordered_uuids=""
    if [ -f "$_order_file" ]; then
        _ordered_uuids=$(awk -F'|' -v m="$mac" 'tolower($1) == tolower(m) {print $2}' "$_order_file")
    fi

    local sorted_data=()
    if [ "$total_profiles" -gt 0 ]; then
        for _ou in $_ordered_uuids; do
            for _pd in "${profile_data[@]}"; do
                IFS='|' read -r _id _ <<< "$_pd"
                if [ "$_id" = "$_ou" ]; then sorted_data+=("$_pd"); break; fi
            done
        done
        for _pd in "${profile_data[@]}"; do
            IFS='|' read -r _id _ <<< "$_pd"
            local _found=0
            for _ou in $_ordered_uuids; do [ "$_id" = "$_ou" ] && _found=1 && break; done
            if [ "$_found" = "0" ]; then
                sorted_data+=("$_pd")
                echo "${mac}|${_id}" >> "$_order_file"
            fi
        done
        profile_data=("${sorted_data[@]}")
        profile_ids=()
        for _pd in "${profile_data[@]}"; do
            IFS='|' read -r _id _ <<< "$_pd"
            profile_ids+=("$_id")
        done
    fi

    if [ "$total_profiles" -gt 0 ]; then
        printf '%s\n' "${profile_ids[@]}" > /tmp/telegram_bot/speed/limit_profiles_order
    else
        : > /tmp/telegram_bot/speed/limit_profiles_order
    fi

    local max_profiles=5
    local free_slots=$((max_profiles - total_profiles))
    local status_line=""
    if [ "$free_slots" -gt 0 ]; then
        status_line="📊 Свободно: ${free_slots} из ${max_profiles}"
    else
        status_line="⚠️ Достигнут лимит: ${total_profiles}/${max_profiles} профилей"
    fi

    local selected_uuid=""
    [ -f /tmp/telegram_bot/speed/limit_selected_uuid ] && selected_uuid=$(cat /tmp/telegram_bot/speed/limit_selected_uuid 2>/dev/null | tr -d '\n\r ')
    if [ -n "$selected_uuid" ]; then
        local found=0
        for pid in "${profile_ids[@]}"; do [ "$pid" = "$selected_uuid" ] && found=1 && break; done
        if [ "$found" = "0" ]; then
            selected_uuid=""
            rm -f /tmp/telegram_bot/speed/limit_selected_uuid
        fi
    fi

    local list_lines=""
    local profile_num=1
    local day_names=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")

    for profile in "${profile_data[@]}"; do
        IFS='|' read -r id rx tx start end days <<< "$profile"

        local rx_human=""
        if [ "$rx" -ge 1073741824 ]; then rx_human="$(awk -v v="$rx" 'BEGIN{printf "%.1f", v/1073741824}') GB/s"
        elif [ "$rx" -ge 1048576 ]; then rx_human="$(awk -v v="$rx" 'BEGIN{printf "%d", v/1048576}') MB/s"
        elif [ "$rx" -ge 1024 ]; then rx_human="$(awk -v v="$rx" 'BEGIN{printf "%d", v/1024}') KB/s"
        else rx_human="${rx} B/s"; fi
        [ ${#rx_human} -gt 8 ] && rx_human="${rx_human:0:8}"

        local tx_human=""
        if [ "$tx" -ge 1073741824 ]; then tx_human="$(awk -v v="$tx" 'BEGIN{printf "%.1f", v/1073741824}') GB/s"
        elif [ "$tx" -ge 1048576 ]; then tx_human="$(awk -v v="$tx" 'BEGIN{printf "%d", v/1048576}') MB/s"
        elif [ "$tx" -ge 1024 ]; then tx_human="$(awk -v v="$tx" 'BEGIN{printf "%d", v/1024}') KB/s"
        else tx_human="${tx} B/s"; fi
        [ ${#tx_human} -gt 8 ] && tx_human="${tx_human:0:8}"

        local rx_padded=$(printf "%8s" "$rx_human")
        local tx_padded=$(printf "%8s" "$tx_human")
        local time_display="${start}-${end}"
        local days_clean=$(echo "$days" | tr -d '[]' | tr ',' ' ')
        local days_display=""
        local status_mark=""
        if [ -z "$days_clean" ]; then
            status_mark="   🔴"
            days_display="Выключен"
        else
            local selected=""
            for d in $days_clean; do
                local idx=$((d - 1))
                selected="${selected}${day_names[$idx]}"
            done
            days_display="$selected"
        fi

        printf -v line1 "%-2s   %8s    %8s     ⏰ %s%s" "$profile_num" "$rx_padded" "$tx_padded" "$time_display" "$status_mark"
        printf -v line2 "%-2s   %8s    %8s     📅 %s" "" "" "" "$days_display"
        list_lines="${list_lines}${line1}"$'\n'
        list_lines="${list_lines}${line2}"$'\n'
        list_lines="${list_lines}"$'\n'
        profile_num=$((profile_num+1))
    done

    list_lines="${list_lines%$'\n'}"
    list_lines="${list_lines%$'\n'}"
    local safe_name=$(html_escape "$name")

    local table="<pre>📊 УПРАВЛЕНИЕ ПРОФИЛЯМИ ДЛЯ ${safe_name}
$SEP46
${status_line}
$SEP46
№    ⬇️Вход.     ⬆️Исход.    Продолжительность
-    --------    --------    ----------------------
${list_lines}
$SEP46

Выберите профиль, нажав на кнопку</pre>"

    local keyboard
    keyboard=$(_limit_build_profiles_keyboard "$total_profiles" "$selected_uuid" "${profile_data[@]}")
    _send_and_save_id "$table" "$keyboard" "/tmp/telegram_bot/speed/limit_msg_id"
}

_show_dialog_error() {
    local err_msg=""
    case "$step" in
        "device_selected") err_msg="Выберите действие или нажмите Отмена" ;;
        "choose_rx") if [ "$manual" = "true" ]; then err_msg="Введите число или нажмите Отмена"; else err_msg="Выберите лимит или нажмите Отмена"; fi ;;
        "choose_tx") if [ "$manual" = "true" ]; then err_msg="Введите число или нажмите Отмена"; else err_msg="Выберите лимит или нажмите Отмена"; fi ;;
        "choose_time") err_msg="Выберите время или нажмите Отмена." ;;
        "choose_days") err_msg="Выберите дни или нажмите Отмена." ;;
        "interval_input") err_msg="Неверный ввод. Верно: ЧЧ:ММ-ЧЧ:ММ" ;;
        *) err_msg="Завершите действие или нажмите Отмена" ;;
    esac
    if [ -z "$SPEED_MSG_ID" ] && [ -f "/tmp/telegram_bot/speed/msg_id" ]; then
        SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
    fi

    if [ -n "$SPEED_MSG_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1
        SPEED_MSG_ID=""
    fi
    rm -f /tmp/telegram_bot/speed/msg_id

    _speed_cleanup_user_msgs

    _show_error_msg "⚠️ $err_msg"
    _resend_current_table
}

# Клавиатуры скорости
get_speed_action_keyboard_with_back() { echo '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'; }
get_device_choice_keyboard() {
    local devices_file="$1"
    if [ ! -f "$devices_file" ]; then echo '{"inline_keyboard":[[{"text":"Нет устройств","callback_data":"none"}]]}'; return; fi
    local total=$(wc -l < "$devices_file" 2>/dev/null | tr -d ' ')
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then echo '{"inline_keyboard":[[{"text":"Нет устройств","callback_data":"none"}]]}'; return; fi
    local cols=5; [ "$total" -gt 10 ] && cols=8
    local keyboard='{"inline_keyboard":['; local row=1; local i=1
    while [ $i -le $total ]; do
        [ $row -gt 1 ] && keyboard="$keyboard,"
        keyboard="$keyboard["; local first_in_row=1; local j=0
        while [ $j -lt $cols ] && [ $i -le $total ]; do
            if [ $first_in_row -eq 1 ]; then first_in_row=0; else keyboard="$keyboard,"; fi
            keyboard="$keyboard{\"text\":\"$i\",\"callback_data\":\"select_$i\"}"
            i=$((i + 1)); j=$((j + 1))
        done
        keyboard="$keyboard]"; row=$((row + 1))
    done
    keyboard="$keyboard,[{\"text\":\"🔄 Обновить\",\"callback_data\":\"refresh_devices\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"cancel\"}]]}"
    echo "$keyboard"
}
get_speed_keyboard_with_back() { echo '{"inline_keyboard":[[{"text":"5 KB/s","callback_data":"speed_5120"},{"text":"25 KB/s","callback_data":"speed_25600"}],[{"text":"50 KB/s","callback_data":"speed_51200"},{"text":"500 KB/s","callback_data":"speed_512000"}],[{"text":"1 MB/s","callback_data":"speed_1048576"},{"text":"✏️ Свой лимит","callback_data":"speed_custom"}],[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'; }
get_duration_keyboard_with_back() { echo '{"inline_keyboard":[[{"text":"15 мин","callback_data":"dur_15"},{"text":"30 мин","callback_data":"dur_30"}],[{"text":"✏️ Интервал (время)","callback_data":"dur_custom"},{"text":"Постоянно","callback_data":"dur_0"}],[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}'; }
get_days_keyboard_with_back() {
    local days_mask="$1"; local days=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс"); local keyboard='{"inline_keyboard":['
    local row=""
    for i in {0..3}; do
        local bit=$((1 << i)); local checked=$((days_mask & bit)); local label="${days[$i]}"
        if [ $checked -ne 0 ]; then label="✅ $label"; else label="🔲 $label"; fi
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"day_$i\"}"
    done
    keyboard="$keyboard[$row],"
    row=""
    for i in {4..6}; do
        local bit=$((1 << i)); local checked=$((days_mask & bit)); local label="${days[$i]}"
        if [ $checked -ne 0 ]; then label="✅ $label"; else label="🔲 $label"; fi
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"day_$i\"}"
    done
    keyboard="$keyboard[$row],[{\"text\":\"⬅️ Назад\",\"callback_data\":\"back\"},{\"text\":\"✅ Готово\",\"callback_data\":\"days_done\"},{\"text\":\"❌ Отмена\",\"callback_data\":\"cancel\"}]]}"
    echo "$keyboard"
}
get_traffic_period_keyboard() {
    local active="$1"
    local keyboard='{"inline_keyboard":['
    local buttons=(
        "day: 1 день"
        "week: 7 дней"
        "month: 30 дней"
        "quarter: 90 дней"
    )
    local first=1
    keyboard="$keyboard["
    for item in "${buttons[@]}"; do
        local period="${item%:*}"
        local label="${item#*:}"
        if [ "$first" -eq 0 ]; then
            keyboard="$keyboard,"     
        fi
        first=0
        if [ "$period" = "$active" ]; then
            keyboard="$keyboard{\"text\":\"✅$label\",\"callback_data\":\"traffic_$period\"}"
        else
            keyboard="$keyboard{\"text\":\"🔲$label\",\"callback_data\":\"traffic_$period\"}"
        fi
    done
    keyboard="$keyboard]"
    keyboard="$keyboard,[{\"text\":\"🔄 Обновить\",\"callback_data\":\"traffic_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"traffic_cancel\"}]"
    keyboard="$keyboard]}"
    echo "$keyboard"
}
get_reboot_confirm_keyboard() {
    echo '{"inline_keyboard":[[{"text":"✅ Да, перезагрузить","callback_data":"reboot_confirm"},{"text":"❌ Отмена","callback_data":"reboot_cancel"}]]}'
}

# ==============================================================================
# 🌐 РАЗДЕЛ 6: КЛИЕНТЫ ОНЛАЙН (ONLINE & STATIC IP)
# ==============================================================================

_online_has_blocked_macs() {
    local RECOVERY_FILE="/etc/telegram_bot/data/.blocked_from_whitelist.txt"
    if [ -s "$RECOVERY_FILE" ]; then
        if grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}\|' "$RECOVERY_FILE" 2>/dev/null; then return 0; fi
    fi
    local _sec _m _mf
    for _sec in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        _m=$(uci -q get "wireless.$_sec.mode" 2>/dev/null); [ "$_m" = "ap" ] || continue
        _mf=$(uci -q get "wireless.$_sec.macfilter" 2>/dev/null); [ "$_mf" = "deny" ] || continue
        if [ -n "$(uci -q get "wireless.$_sec.maclist" 2>/dev/null)" ]; then return 0; fi
    done
    return 1
}

_build_online_keyboard() {
    local state=$(cat /tmp/telegram_bot/online/state 2>/dev/null); [ -z "$state" ] && state="none"
    local block_text="🚫 Блок. Интернет"; local unblock_text="✅ Вкл. Интернет"
    case "$state" in
        block)   block_text="🚫 Свернуть" ;;
        unblock) unblock_text="✅ Свернуть" ;;
    esac

    local PAGE_SIZE=20
    local page=$(cat /tmp/telegram_bot/online/page 2>/dev/null); case "$page" in ''|*[!0-9]*) page=1 ;; esac
    local total=0
    if [ -f "/tmp/telegram_bot/online/last_devices" ]; then
        total=$(wc -l < /tmp/telegram_bot/online/last_devices 2>/dev/null | tr -d ' ')
    fi
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    local total_pages=0; [ "$total" -gt 0 ] && total_pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))
    [ "$page" -lt 1 ] && page=1
    [ "$total_pages" -gt 0 ] && [ "$page" -gt "$total_pages" ] && page="$total_pages"
    local page_start=$(( (page - 1) * PAGE_SIZE + 1 ))
    local page_end=$(( page * PAGE_SIZE )); [ "$page_end" -gt "$total" ] && page_end="$total"

    local fixip_text="📌 Зафиксировать IP"; local wifi_text="📶 Сбросить WiFi"
    case "$state" in
        fixip) fixip_text="📌 Свернуть" ;;
        wifi)  wifi_text="📶 Свернуть" ;;
    esac

    local rows="[{\"text\":\"${fixip_text}\",\"callback_data\":\"online_toggle_fixip\"},{\"text\":\"${wifi_text}\",\"callback_data\":\"online_toggle_wifi\"}]"

    if [ "$state" = "fixip" ] || [ "$state" = "wifi" ]; then
        local nums_row="["; local cnt=0; local max_cols=8
        if [ -f "/tmp/telegram_bot/online/last_devices" ]; then
            while IFS='|' read -r num mac; do
                [ -z "$num" ] && continue; [ -z "$mac" ] && continue
                case "$num" in ''|*[!0-9]*) continue ;; esac
                [ "$num" -lt "$page_start" ] && continue; [ "$num" -gt "$page_end" ] && continue
                local cb=""
                if [ "$state" = "fixip" ]; then cb="online_fixip_${num}"
                else
                    if ! grep -q -x -F "$mac" /tmp/telegram_bot/online/wifi_macs 2>/dev/null; then continue; fi
                    cb="online_wifi_${num}"
                fi
                [ "$cnt" -gt 0 ] && nums_row="$nums_row,"
                nums_row="$nums_row{\"text\":\"$num\",\"callback_data\":\"$cb\"}"
                cnt=$((cnt+1))
                if [ "$cnt" -eq "$max_cols" ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; nums_row="["; cnt=0; fi
            done < /tmp/telegram_bot/online/last_devices
        fi
        if [ "$cnt" -gt 0 ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; fi
    fi

    rows="$rows,[{\"text\":\"${block_text}\",\"callback_data\":\"online_toggle_block\"},{\"text\":\"${unblock_text}\",\"callback_data\":\"online_toggle_unblock\"}]"

    if [ "$state" = "block" ] || [ "$state" = "unblock" ]; then
        local nums_row="["; local cnt=0; local max_cols=8
        if [ -f "/tmp/telegram_bot/online/last_devices" ]; then
            while IFS='|' read -r num mac; do
                [ -z "$num" ] && continue; [ -z "$mac" ] && continue
                case "$num" in ''|*[!0-9]*) continue ;; esac
                [ "$num" -lt "$page_start" ] && continue; [ "$num" -gt "$page_end" ] && continue
                local is_blocked=0
                if [ -f "/tmp/telegram_bot/online/blocked_macs" ] && grep -q -x -F "$mac" /tmp/telegram_bot/online/blocked_macs 2>/dev/null; then is_blocked=1; fi
                local cb=""
                if [ "$state" = "block" ]; then
                    [ "$is_blocked" = "1" ] && continue
                    cb="online_blk_${num}"
                else
                    [ "$is_blocked" = "0" ] && continue
                    cb="online_unblk_${num}"
                fi
                [ "$cnt" -gt 0 ] && nums_row="$nums_row,"
                nums_row="$nums_row{\"text\":\"$num\",\"callback_data\":\"$cb\"}"
                cnt=$((cnt+1))
                if [ "$cnt" -eq "$max_cols" ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; nums_row="["; cnt=0; fi
            done < /tmp/telegram_bot/online/last_devices
        fi
        if [ "$cnt" -gt 0 ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; fi
    fi

    if [ "$total_pages" -gt 1 ]; then
        local nav_row="["; local first=1
        if [ "$page" -gt 1 ]; then nav_row="$nav_row{\"text\":\"⬅️ Назад\",\"callback_data\":\"online_page_prev\"}"; first=0; fi
        [ "$first" = "0" ] && nav_row="$nav_row,"
        nav_row="$nav_row{\"text\":\"📄 $page / $total_pages\",\"callback_data\":\"online_page_info\"}"
        if [ "$page" -lt "$total_pages" ]; then nav_row="$nav_row,{\"text\":\"Далее ➡️\",\"callback_data\":\"online_page_next\"}"; fi
        nav_row="$nav_row]"
        rows="$rows,$nav_row"
    fi

    rows="$rows,[{\"text\":\"🔄 Обновить\",\"callback_data\":\"online_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"online_cancel\"}]"
    echo "{\"inline_keyboard\":[$rows]}"
}

_render_static_edit() {
    local mac name ip orig_name orig_ip
    mac=$(cat "$ONLINE_STATIC_MAC_FILE" 2>/dev/null)
    name=$(cat "$ONLINE_STATIC_NAME_FILE" 2>/dev/null)
    ip=$(cat "$ONLINE_STATIC_IP_FILE" 2>/dev/null)
    orig_name=$(cat "$ONLINE_STATIC_ORIG_NAME_FILE" 2>/dev/null)
    orig_ip=$(cat "$ONLINE_STATIC_ORIG_IP_FILE" 2>/dev/null)

    [ -z "$mac" ] && { _render_online_message "$(cat "$ONLINE_MSG_ID_FILE" 2>/dev/null)"; return; }
    local label_name="Текущее имя устройства"; [ "$name" != "$orig_name" ] && label_name="Новое имя устройства"
    local label_ip="Текущий IP адрес"; [ "$ip" != "$orig_ip" ] && label_ip="Новый IP адрес"
    local safe_name=$(html_escape "$name"); local safe_mac=$(html_escape "$mac"); local safe_ip=$(html_escape "$ip")

    local text="<pre>📌 Фиксация статического IP
${SEP46}
${SEP46}
${label_name}: <code>${safe_name}</code>
MAC-адрес: <code>${safe_mac}</code>
${label_ip}: <code>${safe_ip}</code>
${SEP46}
${SEP46}</pre>"
    local keyboard='{"inline_keyboard":[[{"text":"✏️ Имя устройства","callback_data":"nl_static_edit_name"},{"text":"🌐 Статический IP","callback_data":"nl_static_edit_ip"}],[{"text":"💾 Сохранить","callback_data":"nl_static_save"},{"text":"🔙 Отмена","callback_data":"nl_static_cancel"}]]}'
    local msg_id=$(cat "$ONLINE_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    [ -z "$msg_id" ] && return 1
    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id" --data-urlencode text="$text" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" >/dev/null 2>&1
}

_render_static_edit_recreate() {
    _cleanup_static_input_prompt
    local mac=$(cat "$ONLINE_STATIC_MAC_FILE" 2>/dev/null)
    local name=$(cat "$ONLINE_STATIC_NAME_FILE" 2>/dev/null)
    local ip=$(cat "$ONLINE_STATIC_IP_FILE" 2>/dev/null)
    local orig_name=$(cat "$ONLINE_STATIC_ORIG_NAME_FILE" 2>/dev/null)
    local orig_ip=$(cat "$ONLINE_STATIC_ORIG_IP_FILE" 2>/dev/null)
    [ -z "$mac" ] && return 1
    local label_name="Текущее имя устройства"; [ "$name" != "$orig_name" ] && label_name="Новое имя устройства"
    local label_ip="Текущий IP адрес"; [ "$ip" != "$orig_ip" ] && label_ip="Новый IP адрес"
    local safe_name=$(html_escape "$name"); local safe_mac=$(html_escape "$mac"); local safe_ip=$(html_escape "$ip")
    local text="<pre>📌 Фиксация статического IP
${SEP46}
${SEP46}
${label_name}: <code>${safe_name}</code>
MAC-адрес: <code>${safe_mac}</code>
${label_ip}: <code>${safe_ip}</code>
${SEP46}
${SEP46}</pre>"
    local keyboard='{"inline_keyboard":[[{"text":"✏️ Имя устройства","callback_data":"nl_static_edit_name"},{"text":"🌐 Статический IP","callback_data":"nl_static_edit_ip"}],[{"text":"💾 Сохранить","callback_data":"nl_static_save"},{"text":"🔙 Отмена","callback_data":"nl_static_cancel"}]]}'
    local old_msg_id=$(cat "$ONLINE_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    if [ -n "$old_msg_id" ]; then
        local resp
        resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" --data-urlencode text="$text" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        if echo "$resp" | jq -e '.ok' >/dev/null 2>&1 || echo "$resp" | grep -qi "message is not modified"; then return 0; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1
        rm -f "$ONLINE_MSG_ID_FILE"
    fi
    local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
    local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$new_id" ] && echo "$new_id" > "$ONLINE_MSG_ID_FILE"
}

_render_static_input_prompt() {
    local mode="$1"
    local value="$2"
    local _old_prompt="/tmp/telegram_bot/online/input_prompt_msg_id"
    if [ -f "$_old_prompt" ]; then
        local _old_id=$(cat "$_old_prompt" 2>/dev/null | tr -d '\n\r ')
        [ -n "$_old_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_id" >/dev/null 2>&1
        rm -f "$_old_prompt"
    fi
    local label
    if [ "$mode" = "name" ]; then label="Введите новое имя:"; else label="Введите новый IP:"; fi
    local safe=$(html_escape "$value")
    local text="${label}

Текущее значение: <code>${safe}</code>
(тапните по нему, чтобы скопировать)"
    local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"nl_input_cancel"}]]}'
    local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
    local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$new_id" ] && echo "$new_id" > "$_old_prompt"
}

_cleanup_static_input_prompt() {
    local _pf="/tmp/telegram_bot/online/input_prompt_msg_id"
    [ -f "$_pf" ] || return 0
    local _pid=$(cat "$_pf" 2>/dev/null | tr -d '\n\r ')
    [ -n "$_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1
    rm -f "$_pf"
}

_cleanup_static_input_error() {
    local _f="$ONLINE_ERROR_MSG_FILE"
    [ -f "$_f" ] || return 0
    local _eid
    while IFS= read -r _eid; do
        [ -z "$_eid" ] && continue
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1
    done < "$_f"
    rm -f "$_f"
}

_cleanup_static_invalid_inputs() {
    local _f="/tmp/telegram_bot/online/input_invalid_msgs"
    [ -f "$_f" ] || return 0
    local _iid
    while IFS= read -r _iid; do
        [ -z "$_iid" ] && continue
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_iid" >/dev/null 2>&1
    done < "$_f"
    rm -f "$_f"
}

_render_online_message() {
    local edit_msg_id="$1"
    local page=$(cat /tmp/telegram_bot/online/page 2>/dev/null); case "$page" in ''|*[!0-9]*) page=1 ;; esac
    local known_total=$(cat /tmp/telegram_bot/online/total_pages 2>/dev/null); case "$known_total" in ''|*[!0-9]*) known_total=0 ;; esac
    if [ "$known_total" -gt 0 ] && [ "$page" -gt "$known_total" ]; then page="$known_total"; echo "$page" > /tmp/telegram_bot/online/page; fi

    local result
    _bot_mark_busy_start "online"
    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout 30 /etc/telegram_bot/notify.sh online "$page" 2>&1)
        if [ $? -eq 124 ]; then result="⚠️ Команда 'Клиенты онлайн' превысила время ожидания"; fi
    else
        result=$(/etc/telegram_bot/notify.sh online "$page" 2>&1)
    fi
    _bot_mark_busy_end

    local state=$(cat /tmp/telegram_bot/online/state 2>/dev/null); [ -z "$state" ] && state="none"
    if [ "$state" != "none" ]; then
        local _trim="${result%</pre>}"; local _prompt=""
        case "$state" in
            block)   _prompt="Выберите устройство для блокировки:" ;;
            unblock) _prompt="Выберите устройство для разблокировки:" ;;
            fixip)   _prompt="Выберите устройство для фиксации IP:" ;;
            wifi)    _prompt="Выберите устройство для сброса WiFi:" ;;
            *)       _prompt="Выберите устройство:" ;;
        esac
        result="${_trim}"$'\n\n'"${_prompt}</pre>"
    fi

    local kb=$(_build_online_keyboard)
    local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$edit_msg_id" --data-urlencode text="$result" -d parse_mode="HTML" --data-urlencode "reply_markup=$kb" 2>&1)
    if echo "$_resp" | grep -q '"ok":false'; then
        local _err_desc=$(echo "$_resp" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//;s/"$//')
        if ! echo "$_err_desc" | grep -qi "message is not modified"; then
            echo "DEBUG _render_online_message: edit failed: $_err_desc" >> /tmp/telegram_bot/logs/bot.log
        fi
    fi
}

# ==============================================================================
# 🌐 РАЗДЕЛ 7: WAKE-ON-LAN (WOL)
# ==============================================================================

_wol_get_lan_devices() {
    local _known_lan="/etc/telegram_bot/data/.known_lan_macs"
    touch "$_known_lan"

    local current_lan=""
    declare -A _p2n
    if [ -d "/sys/class/net/$LAN_IFACE/brif" ]; then
        local _p _ifn _h
        for _p in "/sys/class/net/$LAN_IFACE/brif/"*; do
            [ -e "$_p" ] || continue
            _ifn=$(basename "$_p")
            _h=$(cat "$_p/port_no" 2>/dev/null)
            [ -n "$_h" ] && _p2n["$((_h))"]="$_ifn"
        done
    fi
    if command -v brctl >/dev/null 2>&1; then
        while read -r _port _mac _loc _age; do
            [ "$_port" = "port" ] && continue
            [ "$_loc" = "yes" ] && continue
            _ifn="${_p2n[$_port]}"
            case "$_ifn" in lan[0-9]*|eth[0-9]*) current_lan="${current_lan}"$'\n'"$_mac" ;; esac
        done < <(brctl showmacs "$LAN_IFACE" 2>/dev/null)
    elif command -v bridge >/dev/null 2>&1; then
        while read -r _mac _dev _ifn _rest; do
            case "$_ifn" in lan[0-9]*|eth[0-9]*) current_lan="${current_lan}"$'\n'"$_mac" ;; esac
        done < <(bridge fdb show br "$LAN_IFACE" 2>/dev/null | grep "master $LAN_IFACE")
    fi
    
    echo "$current_lan" | sed '/^$/d' | sort -u >> "$_known_lan"
    sort -u "$_known_lan" -o "$_known_lan"

    local final_macs=$(cat "$_known_lan")
    declare -A manual_names_cache
    local sec
    for sec in $(uci show telegram_bot | grep "=wol_manual$" | cut -d. -f2 | cut -d= -f1); do
        local mmac=$(uci -q get "telegram_bot.$sec.mac")
        local mname=$(uci -q get "telegram_bot.$sec.name")
        [ -z "$mmac" ] && continue
        manual_names_cache["$mmac"]="$mname"
        if ! echo "$final_macs" | grep -qx "$mmac"; then final_macs="${final_macs}"$'\n'"$mmac"; fi
    done

    final_macs=$(echo "$final_macs" | tr 'A-Z' 'a-z' | grep -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' | sort -u)

    local router_macs="" _f _m
    for _f in /sys/class/net/*/address; do
        _m=$(cat "$_f" 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')
        [ -n "$_m" ] && [ "$_m" != "00:00:00:00:00:00" ] && router_macs="${router_macs}${_m}"$'\n'
    done
    if [ -n "$router_macs" ]; then
        final_macs=$(printf '%s' "$final_macs" | grep -vFf <(printf '%s' "$router_macs") || true)
    fi

    [ -z "$final_macs" ] && return 0

    local i=1
    for mac in $final_macs; do
        local name="${manual_names_cache[$mac]}"
        if [ -z "$name" ]; then name=$(bash -c ". /etc/telegram_bot/notify.sh 2>/dev/null; get_device_name '$mac'" 2>/dev/null); fi
        [ -z "$name" ] && name="$mac"
        echo "${i}|${name}|${mac}"
        i=$((i + 1))
    done
}

show_wol_menu() {
    local edit_msg_id="$1"
    local _manual_file="/etc/telegram_bot/data/.wol_manual_devices"
    touch "$_manual_file"
    local is_del_mode=0
    [ -f "/tmp/telegram_bot/wol/delete_mode" ] && is_del_mode=1
    local devices=$(_wol_get_lan_devices)
    local total=0
    [ -n "$devices" ] && total=$(echo "$devices" | wc -l | tr -d ' ')
    
    local selected_mac=$(uci -q get telegram_bot.wol.mac 2>/dev/null)
    local selected_name=$(uci -q get telegram_bot.wol.name 2>/dev/null)
    
    local table=""
    if [ "$is_del_mode" = "1" ]; then
        local m_idx=1
        local m_sec
        for m_sec in $(uci show telegram_bot | grep "=wol_manual$" | cut -d. -f2 | cut -d= -f1); do
            local mmac=$(uci -q get "telegram_bot.$m_sec.mac")
            local mname=$(uci -q get "telegram_bot.$m_sec.name")
            [ -z "$mmac" ] && continue
            local short_name="$mname"
            [ ${#short_name} -gt 21 ] && short_name="${short_name:0:21}"
            local vlen=$(_expl_visual_len "$short_name")
            local pad=$((23 - vlen)); [ "$pad" -lt 0 ] && pad=0
            local spaces=$(printf "%*s" "$pad" "")
            local status_pad="  🔲  "
            printf -v row "%-2s %s%s %s %s" "$m_idx" "$short_name" "$spaces" "$mmac" "$status_pad"
            table="${table}${row}"$'\n'
            m_idx=$((m_idx+1))
        done
        [ -z "$table" ] && table="   (Нет добавленных вручную устройств)"$'\n'
    else
        while IFS='|' read -r num name mac; do
            [ -z "$num" ] && continue
            local status="🔲"
            [ "$mac" = "$selected_mac" ] && status="✅"
            local short_name="$name"
            [ ${#short_name} -gt 21 ] && short_name="${short_name:0:21}"
            local vlen=$(_expl_visual_len "$short_name")
            local pad=$((23 - vlen)); [ "$pad" -lt 0 ] && pad=0
            local spaces=$(printf "%*s" "$pad" "")
            local status_pad="  $status  "
            printf -v row "%-2s %s%s %s %s" "$num" "$short_name" "$spaces" "$mac" "$status_pad"
            table="${table}${row}"$'\n'
        done <<< "$devices"
        if [ "$total" -eq 0 ]; then table="   (Нет устройств)"$'\n'; fi
    fi
    
    local msg="<pre>🌐 ПРОБУЖДЕНИЕ ПО СЕТИ (Wake-on-LAN)
${SEP46}
№  Имя                     MAC               Статус
-- ----------------------- ----------------- ------
${table}${SEP46}
"
    if [ "$is_del_mode" = "1" ]; then msg="${msg}Удалить введенное вручную устройство:"
    elif [ -n "$selected_mac" ]; then msg="${msg}Выбрано: ${selected_name} (${selected_mac})"
    else msg="${msg}Выберите устройство:"; fi
    msg="${msg}</pre>"
    
    local buttons=""
    local row=""
    local row_count=0
    local manual_added=0
    
    if [ "$is_del_mode" = "1" ]; then
        local m_count=$(grep -c '|' "$_manual_file" 2>/dev/null); [ -z "$m_count" ] && m_count=0
        for ((j=1; j<=m_count; j++)); do
            [ -n "$row" ] && row="$row,"
            row="$row{\"text\":\"$j\",\"callback_data\":\"wol_del_$j\"}"
            row_count=$((row_count + 1))
            if [ "$row_count" -eq 8 ]; then buttons="$buttons[$row],"; row=""; row_count=0; fi
        done
        [ -n "$row" ] && buttons="$buttons[$row],"
        buttons="$buttons[{\"text\":\"🔙 Отмена\",\"callback_data\":\"wol_del_cancel\"}]"
    else
        for ((j=1; j<=total; j++)); do
            [ -n "$row" ] && row="$row,"
            row="$row{\"text\":\"$j\",\"callback_data\":\"wol_sel_$j\"}"
            row_count=$((row_count + 1))
            if [ "$row_count" -eq 6 ] || [ "$j" -eq "$total" ]; then
                if [ "$manual_added" -eq 0 ]; then
                    row="$row,{\"text\":\"✏️\",\"callback_data\":\"wol_manual\"},{\"text\":\"🗑️\",\"callback_data\":\"wol_del_toggle\"}"
                    manual_added=1
                fi
                buttons="$buttons[$row],"; row=""; row_count=0
            fi
        done
        if [ "$total" -eq 0 ]; then buttons="[{\"text\":\"✏️\",\"callback_data\":\"wol_manual\"},{\"text\":\"🗑️\",\"callback_data\":\"wol_del_toggle\"}],"; fi
        buttons="$buttons[{\"text\":\"💤 Разбудить\",\"callback_data\":\"wol_wake\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wol_cancel\"}]"
    fi
    
    local kb="{\"inline_keyboard\":[$buttons]}"
    local _wol_file="/tmp/telegram_bot/wol/msg_id"
    local _mid="$edit_msg_id"
    if [ -z "$_mid" ] && [ -f "$_wol_file" ]; then _mid=$(cat "$_wol_file" 2>/dev/null); fi
    
    if [ -n "$_mid" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_mid" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$kb" >/dev/null 2>&1
        echo "$_mid" > "$_wol_file"
    else
        local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$kb" 2>&1)
        local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
        [ -n "$new_id" ] && echo "$new_id" > "$_wol_file"
    fi
}

# ==============================================================================
# 🔇 РАЗДЕЛ 8: ЖУРНАЛ СОБЫТИЙ И ИГНОР (MUTE)
# ==============================================================================

_MUTE_STATE_DEL_OPEN="/tmp/telegram_bot/state/mute_del_open"
_MUTE_STATE_ADD_MODE="/tmp/telegram_bot/state/mute_add_mode"
_MUTE_MSG_ID="/tmp/telegram_bot/state/mute_msg_id"
_MUTE_PROMPT_MSG_ID="/tmp/telegram_bot/state/mute_prompt_msg_id"
_MUTE_ERROR_MSG_ID="/tmp/telegram_bot/state/mute_error_msg_id"

_build_mute_keyboard() {
    local is_del_open="$1"
    local total="$2"
    local rows=""
    local del_btn="🗑 Удалить паттерн"
    [ "$is_del_open" = "1" ] && del_btn="🗑 Свернуть"
    rows="[{\"text\":\"➕ Добавить паттерн\",\"callback_data\":\"mute_add\"},{\"text\":\"${del_btn}\",\"callback_data\":\"mute_del_toggle\"}]"

    if [ "$is_del_open" = "1" ] && [ "$total" -gt 0 ]; then
        local nums_row="["; local cnt=0
        for ((i=1; i<=total; i++)); do
            [ "$cnt" -gt 0 ] && nums_row="$nums_row,"
            nums_row="$nums_row{\"text\":\"$i\",\"callback_data\":\"mute_del_$i\"}"
            cnt=$((cnt+1))
            if [ "$cnt" -eq 8 ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; nums_row="["; cnt=0; fi
        done
        if [ "$cnt" -gt 0 ]; then nums_row="$nums_row]"; rows="$rows,$nums_row"; fi
    fi
    rows="$rows,[{\"text\":\"❌ Закрыть\",\"callback_data\":\"mute_close\"},{\"text\":\"🗑 Удалить все\",\"callback_data\":\"mute_clear\"}]"
    echo "{\"inline_keyboard\":[$rows]}"
}

show_mute_menu() {
    if [ -f "$_MUTE_MSG_ID" ]; then
        local old_id=$(cat "$_MUTE_MSG_ID" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$old_id" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$old_id" >/dev/null 2>&1
        fi
        rm -f "$_MUTE_MSG_ID"
    fi

    local is_del_open=0
    [ -f "$_MUTE_STATE_DEL_OPEN" ] && is_del_open=1
    local file="/etc/telegram_bot/data/.event_mute_list"
    local status_line=""
    [ "$(uci -q get telegram_bot.main.event_mute_disabled 2>/dev/null)" = "1" ] && status_line=$'\n⏹️ ВСЕ УВЕДОМЛЕНИЯ ВЫКЛЮЧЕНЫ'

    local patterns=""
    if [ -f "$file" ] && [ -s "$file" ]; then patterns=$(grep -vE '^\s*(#|$)' "$file" 2>/dev/null); fi
    local total=0; [ -n "$patterns" ] && total=$(echo "$patterns" | wc -l | tr -d ' ')

    local table=""
    if [ "$total" -eq 0 ]; then
        table="   Игнорируемых событий нет."
    else
        local num=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local rest="$line"
            local first=1
            while [ ${#rest} -gt 49 ]; do
                local chunk="${rest:0:49}"
                local pos=0
                local i
                for ((i = 48; i >= 0; i--)); do
                    local ch="${chunk:$i:1}"
                    if [ "$ch" = " " ] || [ "$ch" = "|" ]; then pos=$i; break; fi
                done
                local cut_len=49
                if [ $pos -gt 0 ]; then cut_len=$pos
                else
                    local rest_after="${rest:49}"
                    local match="${rest_after%%[ |]*}"
                    if [ ${#match} -lt ${#rest_after} ]; then cut_len=$((49 + ${#match})); else cut_len=${#rest}; fi
                fi
                local piece=$(html_escape "${rest:0:$cut_len}")
                rest="${rest:$cut_len}"
                rest="${rest#"${rest%%[![:space:]]*}"}"
                if [ $first -eq 1 ]; then printf -v row "%-2s %s" "$num" "$piece"; first=0
                else printf -v row "   %s" "$piece"; fi
                table="${table}${row}"$'\n'
            done
            local piece=$(html_escape "$rest")
            if [ $first -eq 1 ]; then printf -v row "%-2s %s" "$num" "$piece"
            else printf -v row "   %s" "$piece"; fi
            table="${table}${row}"$'\n'
            num=$((num + 1))
        done <<< "$patterns"
    fi

    local msg="<pre>🔇 ИГНОРИРУЕМЫЕ СОБЫТИЯ${status_line}
$SEP46
№  Паттерн
-- -------------------------------------------------
${table}
$SEP46

Всего: ${total}</pre>"

    local keyboard=$(_build_mute_keyboard "$is_del_open" "$total")
    local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    local new_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$new_id" ] && echo "$new_id" > "$_MUTE_MSG_ID"
}

# ==============================================================================
# 📌 РАЗДЕЛ 9: СНЯТИЕ ФИКСАЦИИ IP (UNFIXIP)
# ==============================================================================

_unfixip_show_list() {
    local edit_msg_id="$1"
    local sel_file="/tmp/telegram_bot/state/unfixip_selected.json"
    [ ! -f "$sel_file" ] && echo "[]" > "$sel_file"
    local selected_json=$(cat "$sel_file" 2>/dev/null)
    local hosts=()
    local sec
    for sec in $(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\(@host\[[0-9]*\]\)=host$/\1/p"); do
        local name=$(uci -q get "dhcp.$sec.name" 2>/dev/null)
        local mac=$(uci -q get "dhcp.$sec.mac" 2>/dev/null)
        local ip=$(uci -q get "dhcp.$sec.ip" 2>/dev/null)
        [ -z "$name" ] && name="Unknown"; [ -z "$mac" ] && mac="—"; [ -z "$ip" ] && ip="—"
        hosts+=("$name|$mac|$ip")
    done
    local total=${#hosts[@]}
    local header="№  Имя             MAC               IP"$'\n'
    header="${header}-- --------------- ----------------- ---------------"$'\n'
    local table_body="$header"
    local i=1
    for h in "${hosts[@]}"; do
        IFS='|' read -r name mac ip <<< "$h"
        local short_name=$(printf "%-15.15s" "$name")
        local short_mac=$(printf "%-17.17s" "$mac")
        printf -v line "%-2s %-15s %-17s %s" "$i" "$short_name" "$short_mac" "$ip"
        table_body="${table_body}${line}"$'\n'
        i=$((i+1))
    done
    if [ "$total" -eq 0 ]; then table_body="${header}   (Список пуст)"$'\n'; fi

    local sel_count=$(echo "$selected_json" | jq '. | length' 2>/dev/null)
    local sel_line=""
    if [ "$sel_count" -gt 0 ]; then
        local sel_list=$(echo "$selected_json" | jq -r '.[]' | tr '\n' ' ' | sed 's/ $//')
        sel_line="Выбрано: $sel_list"
    else
        sel_line="Выбрано: (нет)"
    fi

    local msg="<pre>📌 ФИКСАЦИЯ IP (dhcp hosts)
${SEP46}
${table_body}${SEP46}
${sel_line}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')
Выберите № для снятия фиксации:</pre>"

    local rows=()
    local current_row=""
    local r_cnt=0
    local btn_reset="{\"text\":\"↩️\",\"callback_data\":\"unfixip_reset\"}"
    for ((j=1; j<=total; j++)); do
        [ -n "$current_row" ] && current_row="$current_row,"
        current_row="$current_row{\"text\":\"$j\",\"callback_data\":\"unfixip_sel_$j\"}"
        r_cnt=$((r_cnt + 1))
        if [ "$r_cnt" -eq 8 ]; then rows+=("[$current_row]"); current_row=""; r_cnt=0; fi
    done
    if [ -n "$current_row" ]; then current_row="${current_row},${btn_reset}"; rows+=("[$current_row]")
    else rows+=("[${btn_reset}]"); fi
    rows+=("[{\"text\":\"🔄 Обновить\",\"callback_data\":\"unfixip_refresh\"},{\"text\":\"🗑️ Снять фикс\",\"callback_data\":\"unfixip_remove\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"unfixip_close\"}]")

    local joined=""
    for r in "${rows[@]}"; do [ -n "$joined" ] && joined="$joined,"; joined="$joined$r"; done
    local keyboard="{\"inline_keyboard\":[$joined]}"

    if [ -n "$edit_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$edit_msg_id" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" >/dev/null 2>&1
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        local new_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
        [ -n "$new_id" ] && echo "$new_id" > "/tmp/telegram_bot/state/unfixip_msg_id"
    fi
}

# ==============================================================================
# 📖 РАЗДЕЛ 10: СПРАВКА И ПОРОГИ (HELP & THRESHOLD)
# ==============================================================================

show_help() {
    local _meta_line=""
    local _id_file="/tmp/telegram_bot/state/help_msg_id"
    if [ -f "$_id_file" ]; then
        local _old_id=$(cat "$_id_file" 2>/dev/null | tr -d '\n\r ')
        [ -n "$_old_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_id" >/dev/null 2>&1
    fi
    local _meta=$(_bot_build_string 2>/dev/null)
    if [ -n "$_meta" ]; then _meta_line="👤 ${_meta}"; fi

    local text="<pre>📖 СПРАВКА — КОМАНДЫ БОТА
$SEP46

📊 МОНИТОРИНГ
  /online        — клиенты онлайн
  /traffic       — трафик по устройствам
  /system        — статус системы
  /uptime        — время работы
  /critical      — журнал событий
  /speedtest     — замер скорости интернета
  /threshold     — пороги RAM / температуры

⚙️ УПРАВЛЕНИЕ
  /wifi          — настройка Wi-Fi
  /services      — автозапуск служб
  /speed         — ограничить скорость
  /wake          — Wake-on-LAN
  /reboot        — перезагрузить роутер
  /unfixip       — меню сброса фиксации IP
  
🔗 УВЕДОМЛЕНИЯ подключения/отключения от сети
  /target        — показать настройки
  
🔇 БЛОКИРОВКА уведомлений о новых критич. событиях 
  /mute info     — показать настройки
  /event off     — выключить все крит. уведомления
  /event on      — включить обратно
  
🗂️ НАСТРОЙКА ИСТОРИИ ЛОГОВ (для скачивания)
  /event history — показать настройки
  
⌨️ Кнопки команд
  /kb            — вкл/выкл reply-клавиатуру
  
🔧 ТЕРМИНАЛ
  /exec _info    — справка терминал
  
🔄 БОТ
  /status        — статус
  /restart       — перезапустить
  /disable       — ПОЛНОЕ отключение
  /uninstall     — ПОЛНОЕ УДАЛЕНИЕ
$SEP46
                                     ${_meta_line}</pre>
🔗 <b>GitHub:</b> <a href=\"https://github.com/Woolagaroo/woo-wrt-tgbot\">woo-wrt-tgbot</a>"

    local _kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"help_close"}]]}'
    local _mid=$(send_message_and_get_id "$text" "$_kb")
    [ -n "$_mid" ] && echo "$_mid" > "$_id_file"
}

_threshold_render_table() {
    local _prefix="${1:-}"
    local _id_file="/tmp/telegram_bot/state/threshold_msg_id"
    local _thr_en _thr_ram _thr_cpu _thr_wifi _thr_cd
    _thr_en=$(uci -q get telegram_bot.thresholds.enabled 2>/dev/null)
    _thr_ram=$(uci -q get telegram_bot.thresholds.ram_free_min 2>/dev/null)
    _thr_cpu=$(uci -q get telegram_bot.thresholds.cpu_temp_max 2>/dev/null)
    _thr_wifi=$(uci -q get telegram_bot.thresholds.wifi_temp_max 2>/dev/null)
    _thr_cd=$(uci -q get telegram_bot.thresholds.cooldown 2>/dev/null)

    local _cd_r _cd_c _cd_w
    _cd_r=$(uci -q get telegram_bot.thresholds.cooldown_ram 2>/dev/null)
    _cd_c=$(uci -q get telegram_bot.thresholds.cooldown_cpu 2>/dev/null)
    _cd_w=$(uci -q get telegram_bot.thresholds.cooldown_wifi 2>/dev/null)

    case "$_thr_en"   in ''|*[!0-9]*) _thr_en=1 ;; esac
    case "$_thr_ram"  in ''|*[!0-9]*) _thr_ram=10 ;; esac
    case "$_thr_cpu"  in ''|*[!0-9]*) _thr_cpu=85 ;; esac
    case "$_thr_wifi" in ''|*[!0-9]*) _thr_wifi=85 ;; esac
    case "$_thr_cd"   in ''|*[!0-9]*) _thr_cd=600 ;; esac
    case "$_cd_r"     in ''|*[!0-9]*) _cd_r="$_thr_cd" ;; esac
    case "$_cd_c"     in ''|*[!0-9]*) _cd_c="$_thr_cd" ;; esac
    case "$_cd_w"     in ''|*[!0-9]*) _cd_w="$_thr_cd" ;; esac

    local _en_icon="🟢 Включён"; [ "$_thr_en" = "0" ] && _en_icon="🔴 Выключен"
    local _ram_line="&lt; ${_thr_ram} MB свободно"; [ "$_thr_ram" = "0" ] && _ram_line="⛔ отключено"
    local _cpu_line="&gt; ${_thr_cpu}°C"; [ "$_thr_cpu" = "0" ] && _cpu_line="⛔ отключено"
    local _wifi_line="&gt; ${_thr_wifi}°C"; [ "$_thr_wifi" = "0" ] && _wifi_line="⛔ отключено"
    local _prefix_block=""; [ -n "$_prefix" ] && _prefix_block="${_prefix}

"

    local _text="<pre>${_prefix_block}📊 ПОРОГИ RAM / ТЕМПЕРАТУРЫ

${SEP46}
Мониторинг:  ${_en_icon}
${SEP46}
RAM:         ${_ram_line}
CPU:         ${_cpu_line}
Wi-Fi:       ${_wifi_line}
${SEP46}
Cooldown RAM:    ${_cd_r} сек ($((_cd_r / 60)) мин)
Cooldown CPU:    ${_cd_c} сек ($((_cd_c / 60)) мин)
Cooldown Wi-Fi:  ${_cd_w} сек ($((_cd_w / 60)) мин)
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')

 /threshold on | off    — вкл / выкл
 /threshold ram N       — порог RAM (MB)
 /threshold cpu N       — порог CPU (°C)
 /threshold wifi N      — порог Wi-Fi (°C)
 /threshold ram_cd N    — cooldown RAM (сек)
 /threshold cpu_cd N    — cooldown CPU (сек)
 /threshold wifi_cd N   — cooldown Wi-Fi (сек)
 /threshold cooldown N  — установить все три
 /threshold reset       — сбросить к дефолтам</pre>"

    if [ -f "$_id_file" ]; then
        local _old_id=$(cat "$_id_file" 2>/dev/null | tr -d '\n\r ')
        [ -n "$_old_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_id" >/dev/null 2>&1
        rm -f "$_id_file"
    fi

    date +%s > /tmp/telegram_bot/state/threshold_last_activity
    local _thr_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"threshold_close"}]]}'
    local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$_text" \
        -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$_thr_kb" 2>&1)
    local _new_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$_new_id" ] && echo "$_new_id" > "$_id_file"
}

# ==============================================================================
# 🎯 РАЗДЕЛ 11: ОТСЛЕЖИВАНИЕ УСТРОЙСТВ (TARGET)
# ==============================================================================

_target_collect_all_macs() {
    local macs=""
    if [ -n "$LAN_IFACE" ]; then macs="${macs}"$'\n'"$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')"; fi
    if [ -n "$INTERFACE_24" ]; then macs="${macs}"$'\n'"$(iw dev "$INTERFACE_24" station dump 2>/dev/null | awk '/Station/ {print $2}')"; fi
    if [ -n "$INTERFACE_5" ]; then macs="${macs}"$'\n'"$(iw dev "$INTERFACE_5" station dump 2>/dev/null | awk '/Station/ {print $2}')"; fi
    local tf="/etc/telegram_bot/data/.target_device.conf"
    if [ -f "$tf" ]; then macs="${macs}"$'\n'"$(cut -d'|' -f1 "$tf" 2>/dev/null)"; fi
    echo "$macs" | tr 'A-Z' 'a-z' | grep -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' | sort -u
}

_target_build_keyboard() {
    local page="$1"; local total_pages="$2"; local start="$3"; local end="$4"
    local kb_rows=(); local row=""; local cnt=0
    for ((j=start; j<=end; j++)); do
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$j\",\"callback_data\":\"target_sel_$j\"}"
        cnt=$((cnt+1))
        if [ "$cnt" -eq 8 ]; then kb_rows+=("[$row]"); row=""; cnt=0; fi
    done
    [ -n "$row" ] && kb_rows+=("[$row]")

    local nav_row="["
    if [ "$page" -gt 1 ]; then nav_row="${nav_row}{\"text\":\"⬅️\",\"callback_data\":\"target_page_prev\"},"; fi
    nav_row="${nav_row}{\"text\":\"🔄 Обновить\",\"callback_data\":\"target_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"target_close\"}"
    if [ "$page" -lt "$total_pages" ]; then nav_row="${nav_row},{\"text\":\"➡️\",\"callback_data\":\"target_page_next\"}"; fi
    nav_row="${nav_row}]"
    kb_rows+=("$nav_row")

    local IFS=","; local keyboard="{\"inline_keyboard\":[${kb_rows[*]}]}"; unset IFS
    echo "$keyboard"
}

_target_render_list() {
    local page="${1:-1}"; local msg_id="$2"; local page_size=40
    local all_macs=$(_target_collect_all_macs)
    if [ -z "$all_macs" ]; then
        _expl_send_or_edit "<pre>📡 СПИСОК УСТРОЙСТВ\n\nНет активных устройств.</pre>" '{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"target_refresh"},{"text":"❌ Закрыть","callback_data":"target_close"}]]}' "$msg_id"
        return
    fi
    local total=$(echo "$all_macs" | wc -l | tr -d ' ')
    local total_pages=$(( (total + page_size - 1) / page_size )); [ "$total_pages" -lt 1 ] && total_pages=1
    [ "$page" -gt "$total_pages" ] && page="$total_pages"
    local start=$(( (page - 1) * page_size + 1 )); local end=$(( page * page_size )); [ "$end" -gt "$total" ] && end="$total"
    echo "$page" > /tmp/telegram_bot/target/page
    echo "$all_macs" > /tmp/telegram_bot/target/all_macs

    local table=""; local i=1; local tf="/etc/telegram_bot/data/.target_device.conf"
    while IFS= read -r mac; do
        [ -z "$mac" ] && continue
        if [ "$i" -ge "$start" ] && [ "$i" -le "$end" ]; then
            local name=""
            if [ -f "$tf" ]; then name=$(awk -F'|' -v m="$mac" 'tolower($1)==m {print $2; exit}' "$tf" 2>/dev/null); fi
            [ -z "$name" ] && name=$(bash -c ". /etc/telegram_bot/notify.sh 2>/dev/null; get_device_name '$mac'" 2>/dev/null)
            [ -z "$name" ] && name="$mac"
            local status="🔲"
            if [ -f "$tf" ] && grep -qi "^${mac}|" "$tf"; then status="✅"; fi
            local short_name="$name"; [ ${#short_name} -gt 21 ] && short_name="${short_name:0:21}"
            local vlen=$(_expl_visual_len "$short_name")
            local pad=$((23 - vlen)); [ "$pad" -lt 0 ] && pad=0
            local spaces=$(printf "%*s" "$pad" "")
            local status_pad="  $status  "
            printf -v row "%-2s %s%s %s %s" "$i" "$short_name" "$spaces" "$mac" "$status_pad"
            table="${table}${row}"$'\n'
        fi
        i=$((i+1))
    done <<< "$all_macs"

    local header="📡 СПИСОК УСТРОЙСТВ"; [ "$total_pages" -gt 1 ] && header="📡 СПИСОК УСТРОЙСТВ (стр. $page / $total_pages)"
    local msg="<pre>${header}
${SEP46}
№  Имя                     MAC               Статус
-- ----------------------- ----------------- ------
${table}${SEP46}

Выберите устройство для вкл./откл. уведомлений о 
подключении к сети, нажав на кнопку ниже:</pre>"

    local _t_msg_file="/tmp/telegram_bot/target/msg_id"
    local _mid="$msg_id"; [ -z "$_mid" ] && [ -f "$_t_msg_file" ] && _mid=$(cat "$_t_msg_file" 2>/dev/null)
    if [ -n "$_mid" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_mid" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$(_target_build_keyboard "$page" "$total_pages" "$start" "$end")" >/dev/null 2>&1
        echo "$_mid" > "$_t_msg_file"
    else
        local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$(_target_build_keyboard "$page" "$total_pages" "$start" "$end")" 2>&1)
        local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
        [ -n "$new_id" ] && echo "$new_id" > "$_t_msg_file"
    fi
}

_target_render_detail() {
    local mac="$1"; local msg_id="$2"
    local temp_name=""; [ -f "/tmp/telegram_bot/target/temp_name" ] && temp_name=$(cat /tmp/telegram_bot/target/temp_name)
    local temp_status=""; [ -f "/tmp/telegram_bot/target/temp_status" ] && temp_status=$(cat /tmp/telegram_bot/target/temp_status)
    local tf="/etc/telegram_bot/data/.target_device.conf"
    local orig_name=""; local orig_status="0"
    if [ -f "$tf" ] && grep -qi "^${mac}|" "$tf"; then
        orig_name=$(awk -F'|' -v m="$mac" 'tolower($1)==m {print $2; exit}' "$tf"); orig_status="1"
    fi
    [ -z "$temp_name" ] && temp_name="$orig_name"
    [ -z "$temp_name" ] && temp_name=$(bash -c ". /etc/telegram_bot/notify.sh 2>/dev/null; get_device_name '$mac'" 2>/dev/null)
    [ -z "$temp_name" ] && temp_name="$mac"
    [ ${#temp_name} -gt 41 ] && temp_name="${temp_name:0:41}…"
    [ -z "$temp_status" ] && temp_status="$orig_status"
    
    echo "$mac" > /tmp/telegram_bot/target/current_mac
    echo "$temp_name" > /tmp/telegram_bot/target/temp_name
    echo "$temp_status" > /tmp/telegram_bot/target/temp_status

    local status_str="🔲 Не отслеживается"; [ "$temp_status" = "1" ] && status_str="✅ Отслеживается"
    local msg="<pre>📡 УПРАВЛЕНИЕ УВЕДОМЛЕНИЯМИ
${SEP46}
${SEP46}
📱 Имя: ${temp_name}
🔗 MAC: ${mac}
📊 Статус: ${status_str}
${SEP46}
${SEP46}</pre>"

    local btn_toggle=""
    if [ "$temp_status" = "1" ]; then btn_toggle='{"text":"🗑️ Удалить из слежки","callback_data":"target_toggle"}'
    else btn_toggle='{"text":"➕ Добавить в слежку","callback_data":"target_toggle"}'; fi

    local keyboard="{\"inline_keyboard\":[[${btn_toggle},{\"text\":\"✏️ Изменить имя\",\"callback_data\":\"target_rename\"}],[{\"text\":\"⬅️ Назад\",\"callback_data\":\"target_back\"},{\"text\":\"💾 Сохранить\",\"callback_data\":\"target_save\"}]]}"
    local _t_msg_file="/tmp/telegram_bot/target/msg_id"
    local _mid="$msg_id"; [ -z "$_mid" ] && [ -f "$_t_msg_file" ] && _mid=$(cat "$_t_msg_file" 2>/dev/null)
    if [ -n "$_mid" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_mid" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" >/dev/null 2>&1
        echo "$_mid" > "$_t_msg_file"
    else
        local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
        [ -n "$new_id" ] && echo "$new_id" > "$_t_msg_file"
    fi
}

# ==============================================================================
# 🔧 РАЗДЕЛ 12: ТЕРМИНАЛ (EXEC)
# ==============================================================================

_exec_render_page() {
    local page="$1"; local msg_id_to_edit="$2"; local state_dir="/tmp/telegram_bot/exec/output"; local page_size=50
    [ -d "$state_dir" ] || return 1
    local total_pages=$(cat "$state_dir/total.txt" 2>/dev/null); case "$total_pages" in ''|*[!0-9]*) total_pages=1 ;; esac
    case "$page" in ''|*[!0-9]*) page=1 ;; esac
    [ "$page" -lt 1 ] && page=1; [ "$page" -gt "$total_pages" ] && page="$total_pages"

    local start=$(( (page - 1) * page_size + 1 )); local end=$(( page * page_size ))
    local body=$(sed -n "${start},${end}p" "$state_dir/full.txt" 2>/dev/null)
    local cmd=$(cat "$state_dir/cmd.txt" 2>/dev/null); local rc=$(cat "$state_dir/rc.txt" 2>/dev/null); [ -z "$rc" ] && rc=0
    local cmd_esc=$(html_escape "$cmd")

    local rc_icon="✅"; [ "$rc" = "124" ] && rc_icon="🕒"; [ "$rc" != "0" ] && [ "$rc" != "124" ] && rc_icon="⚠️"
    local header="⚡ КОМАНДА"; [ "$total_pages" -gt 1 ] && header="⚡ КОМАНДА (стр. ${page} / ${total_pages})"

    local _cmd_prefixed="\$ ${cmd_esc}"
    local _cmd_wrapped=$(printf '%s\n' "$_cmd_prefixed" | LC_ALL=C awk -v lim=52 -v indent="   " -v q="'" '
        function vlen(s,    n, pos, rest, cols) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); if (rest ~ /^&amp;/) { cols += 1; pos += 5; continue } if (rest ~ /^&lt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&gt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&quot;/) { cols += 1; pos += 6; continue } if (rest ~ /^&#39;/) { cols += 1; pos += 5; continue } if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue } if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue } if (rest ~ /^[\340-\357]/) { cols += 2; pos += 3; continue } if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue } cols += 1; pos += 1 } return cols }
        function cut_at_cols(s, k,    n, pos, rest, cols, step, colw) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); step = 1; colw = 1; if (rest ~ /^&amp;/) { step = 5 } else if (rest ~ /^&lt;/) { step = 4 } else if (rest ~ /^&gt;/) { step = 4 } else if (rest ~ /^&quot;/) { step = 6 } else if (rest ~ /^&#39;/) { step = 5 } else if (rest ~ /^[\000-\177]/) { step = 1 } else if (rest ~ /^[\300-\337]/) { step = 2; colw = 1 } else if (rest ~ /^[\340-\357]/) { step = 3; colw = 2 } else if (rest ~ /^[\360-\367]/) { step = 4; colw = 2 } if (cols + colw > k) break; cols += colw; pos += step } return pos - 1 }
        function find_break(chunk,    i, lo, ch) { lo = length(chunk) - 40; if (lo < 1) lo = 1; for (i = length(chunk); i >= lo; i--) { if (substr(chunk, i, 1) == " ") return i "|sp" } for (i = length(chunk); i >= lo; i--) { ch = substr(chunk, i, 1); if (ch == "/" || ch == "-" || ch == ":") return i "|sep" } return "0|none" }
        { esc = $0; add_indent = 0; while (length(esc) > 0) { prefix = (add_indent == 1) ? indent : ""; avail = lim - vlen(prefix); if (vlen(esc) <= avail) { print prefix esc; break } cut = cut_at_cols(esc, avail); chunk = substr(esc, 1, cut); brk = find_break(chunk); split(brk, arr, "|"); bpos = arr[1] + 0; bmode = arr[2]; if (bpos > 0 && bmode == "sp") { print prefix substr(esc, 1, bpos - 1); esc = substr(esc, bpos + 1); add_indent = 0; continue } else if (bpos > 0 && bmode == "sep") { print prefix substr(esc, 1, bpos); esc = substr(esc, bpos + 1); add_indent = 0; continue } print prefix chunk; esc = substr(esc, cut + 1); add_indent = 1 } }')

    local msg=$(printf '<pre>%s\n%s\n%s\n%s\n%s код %s\n%s\n%s\n%s\n%s</pre>' "$header" "$SEP46" "$SEP46" "$_cmd_wrapped" "$rc_icon" "$rc" "$SEP46" "$SEP46" "$body" "$SEP46")
    local _pag_btns=()
    if [ "$page" -eq 1 ]; then _pag_btns+=("{\"text\":\"⬇️ Скачать\",\"callback_data\":\"exec_download\"}"); fi
    if [ "$total_pages" -gt 1 ]; then
        if [ "$page" -gt 1 ]; then _pag_btns+=("{\"text\":\"⬅️ Назад\",\"callback_data\":\"exec_page_prev\"}"); fi
        if [ "$page" -lt "$total_pages" ]; then _pag_btns+=("{\"text\":\"Далее ➡️\",\"callback_data\":\"exec_page_next\"}"); fi
    fi
    _pag_btns+=("{\"text\":\"❌ Закрыть\",\"callback_data\":\"exec_close\"}")
    local _pag_row=""; if [ ${#_pag_btns[@]} -gt 0 ]; then local IFS=","; _pag_row="[${_pag_btns[*]}]"; fi
    local keyboard=""; if [ -n "$_pag_row" ]; then keyboard="{\"inline_keyboard\":[${_pag_row}]}"; fi

    if [ -n "$msg_id_to_edit" ]; then
        local _edit_resp
        if [ -n "$keyboard" ]; then _edit_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        else _edit_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" --data-urlencode text="$msg" -d parse_mode="HTML" 2>&1); fi
        if ! echo "$_edit_resp" | grep -q '"ok":true'; then return 1; fi
        echo "$msg_id_to_edit" > "$state_dir/msg_id.txt"
    else
        local resp
        if [ -n "$keyboard" ]; then resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        else resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" 2>&1); fi
        local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
        [ -n "$new_id" ] && echo "$new_id" > "$state_dir/msg_id.txt"
    fi
    echo "$page" > "$state_dir/page.txt"
    return 0
}

_exec_send_output() {
    local cmd="$1"; local out="$2"; local rc="$3"; local msg_id_to_edit="$4"
    local wrap_limit=52; local wrap_indent="   "; local page_size=50; local file_threshold=10000

    (
        exec 200>&- 2>/dev/null; trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT; i=0
        while [ "$i" -lt 30 ]; do echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot; sleep 10 & wait $! 2>/dev/null; i=$((i + 1)); done
    ) &
    local _hb_pid=$!
	
    local _dw_id_to_clean=""
    if [ -f "$_EXEC_DEFER_FILE" ]; then
        local _dw_id=$(cat "$_EXEC_DEFER_FILE" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_dw_id" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_dw_id" --data-urlencode text="🕒 <b>Нажатия меню пропущены</b>
Повторите действия при необходимости." -d parse_mode="HTML" >/dev/null 2>&1
            _dw_id_to_clean="$_dw_id"
        fi
        rm -f "$_EXEC_DEFER_FILE"
        if [ -n "$msg_id_to_edit" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" >/dev/null 2>&1; msg_id_to_edit=""; fi
    fi
	
    if command -v iconv >/dev/null 2>&1; then out=$(printf '%s\n' "$out" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null); fi
    local wrap_file="/tmp/telegram_bot/exec/wrap_$$"
    printf '%s\n' "$out" | LC_ALL=C awk -v lim="$wrap_limit" -v indent="$wrap_indent" -v q="'" '
        function escape(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); gsub(q, "\\&#39;", s); return s }
        function vlen(s,    n, pos, rest, cols) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); if (rest ~ /^&amp;/) { cols += 1; pos += 5; continue } if (rest ~ /^&lt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&gt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&quot;/) { cols += 1; pos += 6; continue } if (rest ~ /^&#39;/) { cols += 1; pos += 5; continue } if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue } if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue } if (rest ~ /^[\340-\357]/) { cols += 2; pos += 3; continue } if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue } cols += 1; pos += 1 } return cols }
        function cut_at_cols(s, k,    n, pos, rest, cols, step, colw) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); step = 1; colw = 1; if (rest ~ /^&amp;/) { step = 5 } else if (rest ~ /^&lt;/) { step = 4 } else if (rest ~ /^&gt;/) { step = 4 } else if (rest ~ /^&quot;/) { step = 6 } else if (rest ~ /^&#39;/) { step = 5 } else if (rest ~ /^[\000-\177]/) { step = 1 } else if (rest ~ /^[\300-\337]/) { step = 2; colw = 1 } else if (rest ~ /^[\340-\357]/) { step = 3; colw = 2 } else if (rest ~ /^[\360-\367]/) { step = 4; colw = 2 } if (cols + colw > k) break; cols += colw; pos += step } return pos - 1 }
        function find_break(chunk,    i, lo, ch) { lo = length(chunk) - 40; if (lo < 1) lo = 1; for (i = length(chunk); i >= lo; i--) { if (substr(chunk, i, 1) == " ") return i "|sp" } for (i = length(chunk); i >= lo; i--) { ch = substr(chunk, i, 1); if (ch == "/" || ch == "-" || ch == ":") return i "|sep" } return "0|none" }
        { esc = escape($0); add_indent = 0; while (length(esc) > 0) { prefix = (add_indent == 1) ? indent : ""; avail = lim - vlen(prefix); if (vlen(esc) <= avail) { print prefix esc; break } cut = cut_at_cols(esc, avail); chunk = substr(esc, 1, cut); brk = find_break(chunk); split(brk, arr, "|"); bpos = arr[1] + 0; bmode = arr[2]; if (bpos > 0 && bmode == "sp") { print prefix substr(esc, 1, bpos - 1); esc = substr(esc, bpos + 1); add_indent = 0; continue } else if (bpos > 0 && bmode == "sep") { print prefix substr(esc, 1, bpos); esc = substr(esc, bpos + 1); add_indent = 0; continue } print prefix chunk; esc = substr(esc, cut + 1); add_indent = 1 } }' > "$wrap_file"

    local state_dir="/tmp/telegram_bot/exec/output"
    rm -rf "$state_dir"; mkdir -p "$state_dir"; mv "$wrap_file" "$state_dir/full.txt"
    printf '%s\n' "$out" > "$state_dir/raw.txt"

    if [ ! -s "$state_dir/full.txt" ]; then printf '(вывод пуст или произошла ошибка при обработке)' > "$state_dir/full.txt"; fi
    if [ -s "$state_dir/full.txt" ] && [ -n "$(tail -c1 "$state_dir/full.txt")" ]; then printf '\n' >> "$state_dir/full.txt"; fi

    printf '%s' "$cmd" > "$state_dir/cmd.txt"
    printf '%s' "$rc"  > "$state_dir/rc.txt"

    local total_lines=$(wc -l < "$state_dir/full.txt" 2>/dev/null | tr -d ' ')
    case "$total_lines" in ''|*[!0-9]*) total_lines=0 ;; esac
    local total_pages=$(( (total_lines + page_size - 1) / page_size )); [ "$total_pages" -lt 1 ] && total_pages=1
    printf '%s' "$total_pages" > "$state_dir/total.txt"
    printf '1' > "$state_dir/page.txt"

    local _render_rc=0; _exec_render_page 1 "$msg_id_to_edit" || _render_rc=$?
    local _final_mid=$(cat "$state_dir/msg_id.txt" 2>/dev/null)
    if [ -n "$_final_mid" ]; then
        if [ -n "$_dw_id_to_clean" ]; then 
            echo "$_dw_id_to_clean" >> "/tmp/telegram_bot/exec/msgs_${_final_mid}.txt"
        fi
        if [ -f "/tmp/telegram_bot/exec/pending_user_msgs" ]; then 
            cat /tmp/telegram_bot/exec/pending_user_msgs >> "/tmp/telegram_bot/exec/msgs_${_final_mid}.txt" 2>/dev/null
            rm -f /tmp/telegram_bot/exec/pending_user_msgs
        fi
    fi
	
    case "$cmd" in
        "bash /tmp/telegram_bot/exec/script_"*.sh*)
            local _sf=$(echo "$cmd" | awk '{print $2}')
            if [ -n "$_sf" ] && [ -f "$_sf" ]; then rm -f "$_sf" && echo "$(date): _exec_send_output: удалён $_sf" >> /tmp/telegram_bot/logs/bot.log; fi
            ;;
    esac

    if [ -n "$_hb_pid" ] && kill -0 "$_hb_pid" 2>/dev/null; then
        pkill -TERM -P "$_hb_pid" 2>/dev/null; kill -TERM "$_hb_pid" 2>/dev/null; pkill -9 -P "$_hb_pid" 2>/dev/null; kill -9 "$_hb_pid" 2>/dev/null
    fi
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot
    return "$_render_rc"
}

_get_event_history_table() {
    local _h_status="🟢 Включен"
    [ "$(uci -q get telegram_bot.main.log_history_disabled 2>/dev/null)" = "1" ] && _h_status="🔴 Отключен"
    
    local _h_size=$(uci -q get telegram_bot.log.max_size_mb 2>/dev/null)
    case "$_h_size" in ''|*[!0-9]*) _h_size=2 ;; esac

    cat <<EOF
<pre>📋 НАСТРОЙКИ ИСТОРИИ ЛОГОВ

${SEP46}
Сбор:  ${_h_status}
Лимит: ${_h_size} МБ
${SEP46}

/event history on     — включить
/event history off    — выключить
/event history size N — размер в МБ (1-5)</pre>
EOF
}

_run_speedtest_ui() {
    local msg_id="$1"
    local is_edit="$2"
    local _st_kb='{"inline_keyboard":[[{"text":"🔄 Повторить","callback_data":"speedtest_repeat"},{"text":"❌ Закрыть","callback_data":"speedtest_close"}]]}'

    if [ "$is_edit" = "1" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id" --data-urlencode text="⏳ <b>Замеряю скорость…</b>
Ожидайте ~ 20-30 секунд." -d parse_mode="HTML" >/dev/null 2>&1
    else
        msg_id=$(send_message_and_get_id "⏳ <b>Замеряю скорость…</b>
Ожидайте ~ 20-30 секунд." "" | tr -d '\n\r ')
        echo "$msg_id" > /tmp/telegram_bot/state/speedtest_msg_id
    fi

    local st_result
    _bot_mark_busy_start "speedtest"
    if command -v timeout >/dev/null 2>&1; then
        st_result=$(timeout 90 /etc/telegram_bot/notify.sh speedtest 2>&1)
        [ $? -eq 124 ] && st_result="<pre>⚠️ Speedtest превысил время ожидания (90 сек)</pre>"
    else 
        st_result=$(/etc/telegram_bot/notify.sh speedtest 2>&1)
    fi
    _bot_mark_busy_end

    if [ -n "$msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id" --data-urlencode text="$st_result" -d parse_mode="HTML" --data-urlencode "reply_markup=$_st_kb" > /dev/null 2>&1
        echo "$msg_id" > /tmp/telegram_bot/state/speedtest_msg_id
    else
        send_message "$st_result" "$_st_kb"
    fi
}

# ==============================================================================
# ⚙️ РАЗДЕЛ 13: ОБРАБОТЧИКИ КОМАНД И КНОПОК (HANDLERS)
# ==============================================================================

handle_command() {
    local text="$1"
    if [ -f "/tmp/telegram_bot/flags/skip_msg_id" ]; then
        local _skip_id=$(cat "/tmp/telegram_bot/flags/skip_msg_id" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_skip_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_skip_id" >/dev/null 2>&1 & fi
        rm -f "/tmp/telegram_bot/flags/skip_msg_id"
    fi
    : "${_IN_TEXT_MSG_ID:=}"
    text=$(printf '%s' "$text" | sed 's/\xef\xb8\x8f//g')
	
    if [ -f "/tmp/telegram_bot/state/threshold_error_msg_id" ]; then
        local _teid=$(cat /tmp/telegram_bot/state/threshold_error_msg_id 2>/dev/null)
        [ -n "$_teid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_teid" >/dev/null 2>&1
        rm -f "/tmp/telegram_bot/state/threshold_error_msg_id"
    fi
    echo "handle_command called with: $text" >> /tmp/telegram_bot/logs/bot.log

    # --- WOL Rename Mode ---
    if [ -f "/tmp/telegram_bot/target/rename_mode" ]; then
        local _tm_mac=$(cat /tmp/telegram_bot/target/current_mac 2>/dev/null)
        local _pmsg=$(cat /tmp/telegram_bot/target/rename_prompt_msg_id 2>/dev/null)
        local _emsg=$(cat /tmp/telegram_bot/target/error_msg_id 2>/dev/null)
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        if [ -n "$_pmsg" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pmsg" >/dev/null 2>&1; rm -f /tmp/telegram_bot/target/rename_prompt_msg_id; fi
        if echo "$text" | grep -qiE "^/cancel$|^отмена$|^cancel$"; then
            rm -f /tmp/telegram_bot/target/rename_mode
            if [ -n "$_emsg" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_emsg" >/dev/null 2>&1; rm -f /tmp/telegram_bot/target/error_msg_id; fi
            _target_render_detail "$_tm_mac" ""; return
        fi
        local _err_text=""
        if [ -z "$text" ] || [ ${#text} -gt 64 ]; then _err_text="⚠️ Имя должно быть от 1 до 64 символов."
        elif echo "$text" | grep -qF '|'; then _err_text="❌ Символ | в имени запрещён."; fi
        if [ -n "$_err_text" ]; then
            if [ -n "$_emsg" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_emsg" >/dev/null 2>&1; fi
            local _new_emsg=$(send_message_and_get_id "$_err_text"); [ -n "$_new_emsg" ] && echo "$_new_emsg" > /tmp/telegram_bot/target/error_msg_id
            local _kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"target_cancel_rename"}]]}'
            local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✏️ <b>Введите новое имя:</b>" -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" 2>&1)
            local _new_pmsg=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_new_pmsg" ] && echo "$_new_pmsg" > /tmp/telegram_bot/target/rename_prompt_msg_id; return
        fi
        echo "$text" > /tmp/telegram_bot/target/temp_name
        rm -f /tmp/telegram_bot/target/rename_mode /tmp/telegram_bot/target/rename_prompt_msg_id
        if [ -n "$_emsg" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_emsg" >/dev/null 2>&1; rm -f /tmp/telegram_bot/target/error_msg_id; fi
        _target_render_detail "$_tm_mac" ""; return
    fi	

    # --- Online Static IP Input Mode ---
    if [ -f "$ONLINE_STATIC_INPUT_FILE" ]; then
        local _mode=$(cat "$ONLINE_STATIC_INPUT_FILE" 2>/dev/null)
        local _orig_value=""
        if [ "$_mode" = "name" ]; then _orig_value=$(cat "$ONLINE_STATIC_NAME_FILE" 2>/dev/null)
        elif [ "$_mode" = "ip" ]; then _orig_value=$(cat "$ONLINE_STATIC_IP_FILE" 2>/dev/null); fi
        local _err=""; local _rc=0
        if [ "$_mode" = "name" ]; then _err=$(bash -c '. /etc/telegram_bot/notify.sh 2>/dev/null; _nl_validate_name "$1"' _ "$text" 2>&1); _rc=$?
        elif [ "$_mode" = "ip" ]; then _err=$(bash -c '. /etc/telegram_bot/notify.sh 2>/dev/null; _nl_validate_ip "$1"' _ "$text" 2>&1); _rc=$?
        else rm -f "$ONLINE_STATIC_INPUT_FILE"; return; fi
        if [ "$_rc" != "0" ]; then
            if [ -n "$_IN_TEXT_MSG_ID" ]; then echo "$_IN_TEXT_MSG_ID" >> /tmp/telegram_bot/online/input_invalid_msgs; _IN_TEXT_MSG_ID=""; fi
            _cleanup_static_input_prompt
            if [ -n "$_err" ]; then
                local _err_esc=$(html_escape "$_err")
                local _err_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="❌ <b>Ошибка ввода</b>

${_err_esc}" -d parse_mode="HTML" 2>&1)
                local _err_id=$(echo "$_err_resp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_err_id" ] && echo "$_err_id" >> "$ONLINE_ERROR_MSG_FILE"
            fi
            _render_static_input_prompt "$_mode" "$_orig_value"; return
        fi
        if [ "$_mode" = "name" ]; then echo "$text" > "$ONLINE_STATIC_NAME_FILE"
        elif [ "$_mode" = "ip" ]; then echo "$text" > "$ONLINE_STATIC_IP_FILE"; fi
        rm -f "$ONLINE_STATIC_INPUT_FILE"; _cleanup_static_input_prompt; _cleanup_static_input_error; _cleanup_static_invalid_inputs
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        _render_static_edit_recreate; return
    fi

    # --- Global Commands ---
    if echo "$text" | grep -qiE "^/keyboard$|^/kb$|^клавиатура$"; then
        if [ -f "/tmp/telegram_bot/state/keyboard_toggle_msg_id" ]; then
            local _old_kb=$(cat "/tmp/telegram_bot/state/keyboard_toggle_msg_id" 2>/dev/null)
            [ -n "$_old_kb" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_kb" >/dev/null 2>&1
            rm -f "/tmp/telegram_bot/state/keyboard_toggle_msg_id"
        fi

        local _kb_flag="/etc/telegram_bot/data/.no_reply_kb"; local _action=""; local _kb_toast=""
        if [ -f "$_kb_flag" ]; then
            rm -f "$_kb_flag"; _action="⌨️ <b>Клавиатура включена</b>

Кнопки внизу чата снова доступны."; _kb_toast="$MAIN_KEYBOARD"
        else
            touch "$_kb_flag"; _action="⌨️ <b>Клавиатура отключена</b>

Управление — только через меню команд"; _kb_toast='{"remove_keyboard":true}'
        fi
        local _kb_msg_id=$(send_message_and_get_id "$_action" "$_kb_toast")
        [ -n "$_kb_msg_id" ] && echo "$_kb_msg_id" > /tmp/telegram_bot/state/keyboard_toggle_msg_id
        return
    fi

    if echo "$text" | grep -qiE "^/restart$|^перезапуск$|^restart$"; then
        local _restart_msg_id=$(send_message_and_get_id "🔄 <b>Перезапуск бота...</b>")
        [ -n "$_restart_msg_id" ] && echo "$_restart_msg_id" > /tmp/telegram_bot/state/bot_restart_msg_id
        sleep 1
        if [ -n "$CURRENT_UPDATE_ID" ]; then
            echo "$CURRENT_UPDATE_ID" > "$LAST_UPDATE_FILE"
        fi
        /etc/telegram_bot/restart_bot.sh > /tmp/telegram_bot/logs/restart.log 2>&1 &
        sleep 3; exit 0
    fi

    # --- Explorer Text Input ---
    if [ -f "/tmp/telegram_bot/explorer/rename_mode" ] || [ -f "/tmp/telegram_bot/explorer/search_mode" ] || [ -f "/tmp/telegram_bot/explorer/create_mode" ]; then
        case "$text" in
            "🔴 Перезагрузить роутер"|"🕒 Время работы"|"📊 Статус системы"|"📋 Журнал событий"|"🛜 Настройка Wi-Fi"|"🔧 Автозапуск"|"🖥️ Клиенты онлайн"|"📊 Трафик"|"⏱ Ограничить скорость"|"🌐 Wake-on-LAN"|"📁 Проводник"|"/start"|"/menu"|"/help")
                rm -f /tmp/telegram_bot/explorer/rename_mode /tmp/telegram_bot/explorer/rename_target
                rm -f /tmp/telegram_bot/explorer/search_mode /tmp/telegram_bot/explorer/create_mode ;;
            *) if _expl_handle_text "$text"; then return; fi ;;
        esac
    fi

    _clear_previous_error

    # --- Wi-Fi Text Input ---
    if [ -f "/tmp/telegram_bot/wifi/edit_mode" ]; then
        local menu_commands=("Автозапуск" "Клиенты онлайн" "Трафик" "Статус системы" "Ограничить скорость" "Wake-on-LAN" "Время работы" "Настройка Wi-Fi" "Журнал событий" "Перезагрузить роутер")
        local _is_blocked=0
        for menu_cmd in "${menu_commands[@]}"; do if [[ "$text" == *"$menu_cmd"* ]]; then _is_blocked=1; break; fi; done
        if [[ "$text" == /* ]]; then _is_blocked=1; fi
        if [ "$_is_blocked" = "1" ]; then
            if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
            local wifi_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$wifi_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$wifi_msg_id" >/dev/null 2>&1; rm -f "$WIFI_MSG_ID_FILE"; fi
            _show_error_msg "⚠️ <b>Сначала завершите ввод</b>"
            local mode=$(cat "$WIFI_EDIT_MODE_FILE" 2>/dev/null)
            case "$mode" in
                "edit_ssid") _wifi_edit_ssid_start ;;
                "edit_key") _wifi_edit_key_start ;;
                "ap_ssid") _wifi_create_ap_step2 ;;
                "ap_password") _wifi_send_prompt "✏️ Введите пароль (мин. 8 символов или введите 1 символ для открытой сети):" '{"inline_keyboard":[[{"text":"❌ Отмена","callback_data":"wifi_cancel_edit"}]]}' ;;
                "guest_ssid") _wifi_create_guest_step2 ;;
                "guest_password") _wifi_send_prompt "✏️ Введите пароль (мин. 8 символов или введите 1 символ для открытой сети):" '{"inline_keyboard":[[{"text":"❌ Отмена","callback_data":"wifi_cancel_edit"}]]}' ;;
                "sta_password")
                    local essid=$(cat /tmp/telegram_bot/wifi/sta_essid 2>/dev/null)
                    if [ -n "$essid" ]; then echo "sta_password" > "$WIFI_EDIT_MODE_FILE"; _wifi_send_prompt "🔑 Введите пароль для сети $essid (минимум 8 символов):" '{"inline_keyboard":[[{"text":"❌ Отмена","callback_data":"wifi_cancel_edit"}]]}'
                    else show_wifi_vif_menu; fi ;;
                *) _wifi_redraw_current_menu ;;
            esac
            return
        fi
        if echo "$text" | grep -qiE "^отмена$|^cancel$"; then
            if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
            handle_wifi_callback "wifi_cancel_edit" "" "" "$CHAT_ID"; return
        fi
        handle_wifi_text_input "$text"; return
    fi

    # --- Speed Device List Text Input ---
    if [ -f "$SPEED_DEVICE_LIST" ] && [ ! -f "/tmp/telegram_bot/speed/state.json" ]; then
        case "$text" in
            "🔴 Перезагрузить роутер"|"🕒 Время работы"|"📊 Статус системы"|"📋 Журнал событий"|"🛜 Настройка Wi-Fi"|"🔧 Автозапуск"|"🖥️ Клиенты онлайн"|"📊 Трафик"|"⏱ Ограничить скорость"|"🌐 Wake-on-LAN"|"📁 Проводник"|"/start"|"/menu"|"/help")
                rm -f "$SPEED_DEVICE_LIST"; reset_device_selection ;;
            *)
                if echo "$text" | grep -qiE "отмена|menu|start|/start|/menu|^$"; then
                    rm -f "$SPEED_DEVICE_LIST"; reset_device_selection; send_menu; return
                fi
                if [ -n "$SPEED_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1; SPEED_MSG_ID=""; fi
                rm -f /tmp/telegram_bot/speed/msg_id
                _show_error_msg "⚠️ <b>Выберите устройство или нажмите Отмена</b>"
                show_device_list; return ;;
        esac
    fi

    # --- WOL Setup Text Input ---
    if [ -f "/tmp/telegram_bot/wol/setup_mode" ]; then
        local mode=$(cat /tmp/telegram_bot/wol/setup_mode)
        if echo "$text" | grep -qiE "^отмена$|^cancel$"; then
            rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name
            local _pid=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$_pid" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1; rm -f "$WIFI_EDIT_MSG_ID_FILE"; fi
            send_message "❌ Настройка WOL отменена"; send_menu; return
        fi
        case "$mode" in
            "wol_name")
                if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" > /dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
                echo "$text" > /tmp/telegram_bot/wol/name; echo "wol_mac" > /tmp/telegram_bot/wol/setup_mode
                local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
                if [ -n "$prompt_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" > /dev/null 2>&1; rm -f "$WIFI_EDIT_MSG_ID_FILE"; fi
                local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wol_cancel_setup"}]]}'
                response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✏️ Введите MAC-адрес устройства:" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
                local new_prompt_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
                [ -n "$new_prompt_id" ] && echo "$new_prompt_id" > "$WIFI_EDIT_MSG_ID_FILE"
                return ;;
            "wol_mac")
                local mac="$text"
                if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" > /dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
                if ! echo "$mac" | grep -q '^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$'; then
                    local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
                    if [ -n "$prompt_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" > /dev/null 2>&1; rm -f "$WIFI_EDIT_MSG_ID_FILE"; fi
                    local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wol_cancel_setup"}]]}'
                    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="❌ Неверный формат MAC-адреса.
Правильный формат: XX:XX:XX:XX:XX:XX.
Попробуйте ещё раз:" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
                    local err_msg_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null)
                    [ -n "$err_msg_id" ] && echo "$err_msg_id" > "$WIFI_EDIT_MSG_ID_FILE"
                    return
                fi
                local name=$(cat /tmp/telegram_bot/wol/name 2>/dev/null); [ -z "$name" ] && name="Unknown"
                
                # Удаляем старую запись с таким же MAC из UCI (если есть)
                local m_sec
                for m_sec in $(uci show telegram_bot | grep "=wol_manual$" | cut -d. -f2 | cut -d= -f1); do
                    local check_mac=$(uci -q get "telegram_bot.$m_sec.mac")
                    if [ "$check_mac" = "$mac" ]; then uci delete "telegram_bot.$m_sec"; fi
                done
                
                # Добавляем новую UCI-секцию для ручного устройства
                local new_sec=$(uci add telegram_bot wol_manual)
                uci set "telegram_bot.$new_sec.mac=$mac"
                uci set "telegram_bot.$new_sec.name=$name"
                
                local existing_mac=$(uci -q get telegram_bot.wol.mac 2>/dev/null)
                if [ -z "$existing_mac" ]; then
                    uci set telegram_bot.wol=wol
                    uci set telegram_bot.wol.name="$name"
                    uci set telegram_bot.wol.mac="$mac"
                fi
                uci commit telegram_bot
                local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
                if [ -n "$prompt_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" > /dev/null 2>&1; rm -f "$WIFI_EDIT_MSG_ID_FILE"; fi
                rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name
                local wol_msg_id=$(cat /tmp/telegram_bot/wol/msg_id 2>/dev/null)
                if [ -n "$wol_msg_id" ]; then show_wol_menu "$wol_msg_id"
                else show_wol_menu; fi
                return ;;
            *) rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name; send_message "⚠️ Настройка WOL прервана. Попробуйте снова."; return ;;
        esac
    fi

    # --- Speed Profiles Table Text Input ---
    if [ -f "/tmp/telegram_bot/speed/limit_msg_id" ]; then
        local mac=""; local name=""
        if [ -f "/tmp/telegram_bot/speed/state.json" ]; then
            mac=$(cat /tmp/telegram_bot/speed/state.json 2>/dev/null | jq -r '.mac // ""')
            name=$(cat /tmp/telegram_bot/speed/state.json 2>/dev/null | jq -r '.name // ""')
        fi
        if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then
            mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null)
            name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null)
        fi
        if echo "$text" | grep -qiE "отмена|menu|start|/start|/menu"; then
            rm -f /tmp/telegram_bot/speed/limit_msg_id; reset_device_selection; send_menu; return
        fi
        if [ -n "$text" ]; then
            if [ -n "$SPEED_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1; SPEED_MSG_ID=""; fi
            rm -f /tmp/telegram_bot/speed/limit_msg_id
            _show_error_msg "⚠️ Выберите действие или нажмите Отмена"
            if [ -n "$mac" ] && [ -n "$name" ]; then show_device_limits "$mac" "$name"; fi
            return
        fi
    fi

    # --- Speed Wizard Text Input ---
    local state_file="/tmp/telegram_bot/speed/state.json"
    if [ -f "$state_file" ]; then
        local state=$(cat "$state_file")
        local step=$(echo "$state" | jq -r '.step // ""')
        local mac=$(echo "$state" | jq -r '.mac // ""')
        local name=$(echo "$state" | jq -r '.name // ""')
        local rx_bytes=$(echo "$state" | jq -r '.rx_bytes // 0')
        local rx_display=$(echo "$state" | jq -r '.rx_display // ""')
        local tx_bytes=$(echo "$state" | jq -r '.tx_bytes // 0')
        local tx_display=$(echo "$state" | jq -r '.tx_display // ""')
        local manual=$(echo "$state" | jq -r '.manual // false')

        if echo "$text" | grep -qi "отмена"; then
            if [ -n "$_IN_TEXT_MSG_ID" ]; then _speed_track_user_msg "$_IN_TEXT_MSG_ID"; _IN_TEXT_MSG_ID=""; fi
            _speed_cleanup_user_msgs; reset_device_selection; send_menu; return
        fi
        case "$step" in
            "device_selected") _show_dialog_error; return ;;
            "choose_rx")
                if [ "$manual" = "true" ]; then
                    local input=$(echo "$text" | sed 's/,/./g')
                    if echo "$input" | grep -qE '^[0-9.]+$' && awk -v v="$input" 'BEGIN{exit !(v > 0)}'; then
                        local speed_bytes=$(awk -v m="$input" 'BEGIN{printf "%d", m*1048576}')
                        [ -z "$speed_bytes" ] || [ "$speed_bytes" -le 0 ] && speed_bytes=1
                        local display_speed="${input} MB/s"
                        _update_speed_state "choose_tx" "$mac" "$name" "$speed_bytes" "$display_speed" "" "" "" "" 127 "false"
                        local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                        local msg=$(_build_device_table "$mac" "$name" "$ip" "$display_speed" "" "" "" "✅ Входящая скорость установлена: $display_speed" "🕒  ЗАДАЙТЕ ИСХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "2")
                        
                        _speed_cleanup_user_msgs
                        _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                        SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                        return
                    else _show_dialog_error; return; fi
                else
                    if [ -n "$SPEED_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1; SPEED_MSG_ID=""; rm -f /tmp/telegram_bot/speed/msg_id; fi
                    _show_error_msg "⚠️ Выберите лимит или нажмите Отмена"; _resend_current_table; return
                fi ;;
            "choose_tx")
                if [ "$manual" = "true" ]; then
                    local input=$(echo "$text" | sed 's/,/./g')
                    if echo "$input" | grep -qE '^[0-9.]+$' && awk -v v="$input" 'BEGIN{exit !(v > 0)}'; then
                        local speed_bytes=$(awk -v m="$input" 'BEGIN{printf "%d", m*1048576}')
                        [ -z "$speed_bytes" ] || [ "$speed_bytes" -le 0 ] && speed_bytes=1
                        local display_speed="${input} MB/s"
                        _update_speed_state "choose_time" "$mac" "$name" "$rx_bytes" "$rx_display" "$speed_bytes" "$display_speed" "" "" 127 "false"
                        local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                        local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$display_speed" "" "" "✅ Ограничения скорости установлены" "🕒  ЗАДАЙТЕ ВРЕМЯ ДЕЙСТВИЯ ЛИМИТА" "3")
                        
                        _speed_cleanup_user_msgs
                        _send_and_save_id "$msg" "$(get_duration_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                        SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                        return
                    else _show_dialog_error; return; fi
                else
                    if [ -n "$SPEED_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1; SPEED_MSG_ID=""; rm -f /tmp/telegram_bot/speed/msg_id; fi
                    _show_error_msg "⚠️ Выберите лимит или нажмите Отмена"; _resend_current_table; return
                fi ;;
            "choose_time")
                if [ -n "$SPEED_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SPEED_MSG_ID" > /dev/null 2>&1; SPEED_MSG_ID=""; rm -f /tmp/telegram_bot/speed/msg_id; fi
                _show_error_msg "⚠️ Выберите время или нажмите Отмена"; _resend_current_table; return ;;
            "interval_input")
                local cleaned=$(echo "$text" | tr -d ' ')
                local full_state=$(_get_speed_state); local from_profile=$(echo "$full_state" | jq -r '.from_profile // false')
                if echo "$cleaned" | grep -qE '^([0-1][0-9]|2[0-3]):[0-5][0-9]-([0-1][0-9]|2[0-3]):[0-5][0-9]$'; then
                    local interval="$cleaned"; local new_start=$(echo "$interval" | cut -d'-' -f1); local new_end=$(echo "$interval" | cut -d'-' -f2)
                    _update_speed_state "choose_days" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "$new_start" "$new_end" 127 "false" "$from_profile"
                    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                    local time_display="${new_start} - ${new_end}"
                    local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "$time_display" "" "✅ Время установлено" "  📅   ВЫБЕРИТЕ ДНИ ДЕЙСТВИЯ ЛИМИТА" "4")
                    
                    _speed_cleanup_user_msgs
                    _send_and_save_id "$msg" "$(get_days_keyboard_with_back 127)" "/tmp/telegram_bot/speed/msg_id"
                    SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                    return
                else _show_dialog_error; return; fi ;;
            "choose_days") _show_dialog_error; return ;;
            *) reset_device_selection; send_message "⚠️ Ошибка состояния. Попробуйте заново." "$MAIN_KEYBOARD"; return ;;
        esac
        _resend_current_table; return
    fi

    # --- Main Menu Commands ---
    local cmd="$text"
    if [ "$cmd" != "Настройка Wi-Fi" ] && [ "$cmd" != "wifi" ] && [ -f "/tmp/telegram_bot/wifi/active.lock" ]; then
        local old_wifi_msg_id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null)
        if [ -n "$old_wifi_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_wifi_msg_id" >/dev/null 2>&1; fi
        rm -f /tmp/telegram_bot/wifi/msg_id
        local err_text="$(_wifi_get_error_text)"
        _show_error_msg "⚠️ <b>$err_text</b>"
        _wifi_redraw_current_menu; return
    fi

    if [[ "$text" == *"🔧 Автозапуск"* ]] || [[ "$text" == "/services" ]]; then
        reset_device_selection; _services_set_selected "[]"; _services_set_page "1"; rm -f /tmp/telegram_bot/services/list.json
        set_services_mode "1"; _services_invalidate_cache; rm -f "$SERVICES_LAST_ACTIVITY_FILE"
        _bot_kill_main_menu
        local _old_svc_id=$(cat /tmp/telegram_bot/services/msg_id 2>/dev/null)
        if [ -n "$_old_svc_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_svc_id" >/dev/null 2>&1 & fi
        rm -f /tmp/telegram_bot/services/msg_id; _services_set_msg_id ""
        show_services; return
    fi

    if [[ "$text" == "🛜 Настройка Wi-Fi" ]] || [[ "$text" == "/wifi" ]]; then
        rm -f /tmp/telegram_bot/wifi/state.json /tmp/telegram_bot/wifi/edit_mode /tmp/telegram_bot/wifi/edit_section 2>/dev/null
        _bot_kill_main_menu
        local _old_wifi_id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null)
        if [ -n "$_old_wifi_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_wifi_id" >/dev/null 2>&1 & fi
        rm -f /tmp/telegram_bot/wifi/msg_id
        show_wifi_main; reset_device_selection; return
    fi
	
    if [[ "$text" =~ ^/exec[[:space:]]+exit([[:space:]]+[0-9]+)?$ ]]; then
        if _exec_session_active; then _exec_session_stop 2>/dev/null; fi
        rm -f /tmp/telegram_bot/exec/wait_msg_id /tmp/telegram_bot/exec/session/last_cmd
        send_message "✅ <b>Exec-сессия закрыта</b>

Новая будет создана заново при следующей команде."; return
    fi

    if [[ "$text" == "/exec "* || "$text" == "/exec"$'\n'* || "$text" == "/exec" ]]; then
        local _exec_cmd="${text#/exec}"; _exec_cmd="${_exec_cmd# }"; _exec_cmd="${_exec_cmd#$'\n'}"

        if [ "$_exec_cmd" = "_info" ]; then
            if [ -n "$_IN_TEXT_MSG_ID" ]; then 
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
                _IN_TEXT_MSG_ID=""
            fi

            local _old_info_mid=$(cat /tmp/telegram_bot/state/exec_info_msg_id 2>/dev/null | tr -d '\n\r ')
            if [ -n "$_old_info_mid" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_info_mid" >/dev/null 2>&1
                rm -f /tmp/telegram_bot/state/exec_info_msg_id
            fi

            local _sep20="===================="
            local _info_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"exec_info_close"}]]}'
            local _info_mid=$(send_message_and_get_id "<pre>📖 EXEC — ПОЛНАЯ СПРАВКА
${SEP46}
${SEP46}
🔹 ОБЫЧНЫЙ ВВОД

  Вы отправляете боту команду, например:
    /exec echo ok
  Бот выполняет команду и отвечает в виде блока:

  ⚡ КОМАНДА             ← заголовок
  ${_sep20} ~ 
  ${_sep20} ~ 
  \$ echo ok              ← ваша команда
  ✅ код 0               ← код возврата
  ${_sep20} ~ 
  ${_sep20} ~ 
  ok                     ← результат
  ${_sep20} ~ ← есть разделитель,
                            команда завершена
${SEP46}
🔹 ОЖИДАНИЕ ВВОДА [waiting]

  Вы отправляете боту команду, ожидающую
  от пользователя ввода, например:
    /exec head -n 1
  Бот выполняет команду и ожидает в режиме
  [waiting] с таким блоком:

  ⏳ КОМАНДА ОЖИДАЕТ ВВОД
  ${_sep20} ~
  ${_sep20} ~
  \$ head -n 1            ← ваша команда
  ${_sep20} ~
  ${_sep20} ~
  (команда ожидает ввод)     
                         ← разделителя нет,
                            бот ждет ввод

  Ваш ответ, например:  /exec Hello, world!

  Команда выполнится и бот выведет результат:

  ⚡ КОМАНДА
  ${_sep20} ~
  ${_sep20} ~
  \$ Hello, world!        ← ваша команда
  ✅ код 0
  ${_sep20} ~
  ${_sep20} ~
  Hellow, world!         ← результат
  ${_sep20} ~ ← есть разделитель,
                            команда завершена
${SEP46}
	
🔹 КОДЫ ВОЗВРАТА
 ✅ код 0    - успех
 ⚠️ код 1    - общая ошибка
 ⚠️ код 2    - ошибка использования (bad option)
 ⚠️ код 127  - команда не найдена
 🕒 код 124  - timeout
 ⚠️ код 130  - прервано (Ctrl+C)

🔹 УПРАВЛЕНИЕ СЕССИЕЙ
  /exec _info    - эта справка
  /exec _status  - статус сессии
  /exec _exit    - закрыть сессию
  /exec _ctrlc   - прервать команду (Ctrl+C)
  /exec _eof     - завершить stdin (Ctrl+D)

🔹 ПРИНЦИП РАБОТЫ
• Persistent bash - одна сессия, состояние 
  между командами сохраняется (переменные, cd)
• Если команда просит ввести данные (пароль,
  подтверждение y/n) - бот переходит в режим
  [waiting] и ждёт ваш ответ следующим /exec.
• Если обычная команда выполняется > 90 сек, 
  бот переходит в режим [running], результат 
  появится автоматически по мере готовности.
${SEP46}</pre>" "$_info_kb")
            
            if [ -n "$_info_mid" ]; then
                echo "$_info_mid" > /tmp/telegram_bot/state/exec_info_msg_id
            fi
            return
        fi
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            echo "$_IN_TEXT_MSG_ID" >> "/tmp/telegram_bot/exec/pending_user_msgs"
            _IN_TEXT_MSG_ID="" 
        fi

        _exec_session_check_timeout
        if [ "$_exec_cmd" = "_status" ]; then
            _exec_session_status
            if [ "$?" = "0" ]; then send_message "📟 <b>Exec-сессия активна</b>

<pre>$_EXEC_STATUS</pre>"
            else send_message "📟 <b>Exec-сессия не активна</b>"; fi
            return
        fi
        if [ "$_exec_cmd" = "_eof" ]; then
            if ! _exec_session_active; then send_message "ℹ️ <b>Сессия не активна</b>"; return; fi
            sexpect -sock "$_EXEC_SOCK" send $'\x04' 2>/dev/null
            send_message "📤 <b>EOF отправлен (Ctrl+D)</b>"; return
        fi
        if [ "$_exec_cmd" = "_exit" ]; then
            if _exec_session_active; then _exec_session_stop; send_message "✅ <b>Exec-сессия закрыта</b>"
            else send_message "ℹ️ <b>Сессия не была активна</b>"; fi
            return
        fi

        if ! command -v sexpect >/dev/null 2>&1; then send_message "⚠️ <b>Требуется пакет sexpect</b>" "$_err_kb"; return; fi
        if ! _exec_session_active; then _exec_session_start; if [ "$?" != "0" ]; then send_message "❌ <b>Не удалось запустить exec-сессию</b>" "$_err_kb"; return; fi; fi

        local _first_word=$(echo "$_exec_cmd" | awk '{print $1}')
        if [ "$_first_word" = "ping" ]; then
            case "$_exec_cmd" in *" -c "*|*" -c"*) : ;; *) _exec_cmd="${_exec_cmd} -c 4" ;; esac
        fi

        if [ -f "$_EXEC_WAIT_MSG_FILE" ]; then
            local _old_wait_id=$(cat "$_EXEC_WAIT_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
            if [ -n "$_old_wait_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_wait_id" > /dev/null 2>&1; fi
            rm -f "$_EXEC_WAIT_MSG_FILE"
        fi

        local _exec_cmd_disp=$(html_escape "${_exec_cmd:0:100}")
        local _exec_msg_id=$(send_message_and_get_id "⏳ <b>Выполняется…</b>
<code>\$ ${_exec_cmd_disp}</code>")
        
        _exec_session_send "$_exec_cmd" 90
        local _exec_rc=$?

        if [ "$_exec_rc" = "5" ]; then
            if [ -n "$_exec_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                    -d chat_id="$CHAT_ID" -d message_id="$_exec_msg_id" \
                    --data-urlencode text="⚠️ <b>Другая команда уже выполняется</b>
Дождитесь завершения или прервите: <code>/exec _ctrlc</code>" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            else
                send_message "⚠️ <b>Другая команда уже выполняется</b>
Дождитесь завершения или прервите: <code>/exec _ctrlc</code>" "$_err_kb"
            fi
            return
        fi

        if [ "$_exec_rc" = "99" ]; then
            local _exec_out="$_EXEC_OUTPUT"; [ -z "$_exec_out" ] && _exec_out="(нет вывода до прерывания)"
            if declare -F _exec_send_output >/dev/null 2>&1; then _exec_send_output "$_exec_cmd" "$_exec_out" "${_EXEC_LAST_RC:-130}" "$_exec_msg_id"; fi
            rm -f "$_EXEC_WAIT_MSG_FILE"
            send_message "🛑 <b>Команда прервана</b>"; return
        fi

        if [ "$_exec_rc" = "3" ]; then
            rm -f "$_EXEC_WAIT_MSG_FILE"
            if [ -n "$_exec_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_exec_msg_id" --data-urlencode text="$_EXEC_OUTPUT" -d parse_mode="HTML" > /dev/null 2>&1
            else send_message "$_EXEC_OUTPUT"; fi
            return
        fi

        if [ "$_exec_rc" = "2" ]; then
            _exec_session_stop; _exec_session_start
            if ! _exec_session_active; then send_message "❌ <b>Не удалось пересоздать exec-сессию</b>"; return; fi
            _exec_session_send "$_exec_cmd" 8; _exec_rc=$?
        fi

        local _exec_out="$_EXEC_OUTPUT"
        if [ "$_exec_rc" = "2" ]; then rm -f "$_EXEC_WAIT_MSG_FILE"; send_message "❌ <b>Exec-сессия потеряна</b>" "$_err_kb"; return; fi
        if [ "$_exec_rc" = "100" ]; then send_message "🛑 <b>Exec-сессия закрыта</b>"; rm -f "$_EXEC_WAIT_MSG_FILE" /tmp/telegram_bot/exec/session/last_cmd; return; fi

        if [ "$_exec_rc" = "4" ]; then
            [ -z "$_exec_out" ] && _exec_out="(команда выполняется)"
            printf '%s' "$_exec_cmd" > /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null
            local _cmd_esc=$(html_escape "$_exec_cmd"); local _cmd_prefixed="\$ ${_cmd_esc}"
            local _cmd_wrapped=$(printf '%s\n' "$_cmd_prefixed" | LC_ALL=C awk -v lim=52 -v indent="   " -v q="'" '
                function vlen(s,    n, pos, rest, cols) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); if (rest ~ /^&amp;/) { cols += 1; pos += 5; continue } if (rest ~ /^&lt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&gt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&quot;/) { cols += 1; pos += 6; continue } if (rest ~ /^&#39;/) { cols += 1; pos += 5; continue } if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue } if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue } if (rest ~ /^[\340-\357]/) { cols += 2; pos += 3; continue } if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue } cols += 1; pos += 1 } return cols }
                function cut_at_cols(s, k,    n, pos, rest, cols, step, colw) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); step = 1; colw = 1; if (rest ~ /^&amp;/) { step = 5 } else if (rest ~ /^&lt;/) { step = 4 } else if (rest ~ /^&gt;/) { step = 4 } else if (rest ~ /^&quot;/) { step = 6 } else if (rest ~ /^&#39;/) { step = 5 } else if (rest ~ /^[\000-\177]/) { step = 1 } else if (rest ~ /^[\300-\337]/) { step = 2; colw = 1 } else if (rest ~ /^[\340-\357]/) { step = 3; colw = 2 } else if (rest ~ /^[\360-\367]/) { step = 4; colw = 2 } if (cols + colw > k) break; cols += colw; pos += step } return pos - 1 }
                function find_break(chunk,    i, lo, ch) { lo = length(chunk) - 40; if (lo < 1) lo = 1; for (i = length(chunk); i >= lo; i--) { if (substr(chunk, i, 1) == " ") return i "|sp" } for (i = length(chunk); i >= lo; i--) { ch = substr(chunk, i, 1); if (ch == "/" || ch == "-" || ch == ":") return i "|sep" } return "0|none" }
                { esc = $0; add_indent = 0; while (length(esc) > 0) { prefix = (add_indent == 1) ? indent : ""; avail = lim - vlen(prefix); if (vlen(esc) <= avail) { print prefix esc; break } cut = cut_at_cols(esc, avail); chunk = substr(esc, 1, cut); brk = find_break(chunk); split(brk, arr, "|"); bpos = arr[1] + 0; bmode = arr[2]; if (bpos > 0 && bmode == "sp") { print prefix substr(esc, 1, bpos - 1); esc = substr(esc, bpos + 1); add_indent = 0; continue } else if (bpos > 0 && bmode == "sep") { print prefix substr(esc, 1, bpos); esc = substr(esc, bpos + 1); add_indent = 0; continue } print prefix chunk; esc = substr(esc, cut + 1); add_indent = 1 } }')

            local _msg="<pre>⏳ КОМАНДА ВЫПОЛНЯЕТСЯ
${SEP46}
${SEP46}
${_cmd_wrapped}
${SEP46}
${SEP46}
Ожидание результата... Прервать: /exec _ctrlc</pre>"

            if [ -n "$_exec_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_exec_msg_id" --data-urlencode text="$_msg" -d parse_mode="HTML" > /dev/null 2>&1; echo "$_exec_msg_id" > "$_EXEC_WAIT_MSG_FILE"
            else send_message "$_msg"; fi
            return
        fi

        if [ "$_exec_rc" = "1" ]; then
            [ -z "$_exec_out" ] && _exec_out="(команда ожидает ввод)"
            printf '%s' "$_exec_cmd" > /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null
            local _cmd_esc=$(html_escape "$_exec_cmd"); local _cmd_prefixed="\$ ${_cmd_esc}"
            local _cmd_wrapped=$(printf '%s\n' "$_cmd_prefixed" | LC_ALL=C awk -v lim=52 -v indent="   " -v q="'" '
                function vlen(s,    n, pos, rest, cols) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); if (rest ~ /^&amp;/) { cols += 1; pos += 5; continue } if (rest ~ /^&lt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&gt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&quot;/) { cols += 1; pos += 6; continue } if (rest ~ /^&#39;/) { cols += 1; pos += 5; continue } if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue } if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue } if (rest ~ /^[\340-\357]/) { cols += 2; pos += 3; continue } if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue } cols += 1; pos += 1 } return cols }
                function cut_at_cols(s, k,    n, pos, rest, cols, step, colw) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); step = 1; colw = 1; if (rest ~ /^&amp;/) { step = 5 } else if (rest ~ /^&lt;/) { step = 4 } else if (rest ~ /^&gt;/) { step = 4 } else if (rest ~ /^&quot;/) { step = 6 } else if (rest ~ /^&#39;/) { step = 5 } else if (rest ~ /^[\000-\177]/) { step = 1 } else if (rest ~ /^[\300-\337]/) { step = 2; colw = 1 } else if (rest ~ /^[\340-\357]/) { step = 3; colw = 2 } else if (rest ~ /^[\360-\367]/) { step = 4; colw = 2 } if (cols + colw > k) break; cols += colw; pos += step } return pos - 1 }
                function find_break(chunk,    i, lo, ch) { lo = length(chunk) - 40; if (lo < 1) lo = 1; for (i = length(chunk); i >= lo; i--) { if (substr(chunk, i, 1) == " ") return i "|sp" } for (i = length(chunk); i >= lo; i--) { ch = substr(chunk, i, 1); if (ch == "/" || ch == "-" || ch == ":") return i "|sep" } return "0|none" }
                { esc = $0; add_indent = 0; while (length(esc) > 0) { prefix = (add_indent == 1) ? indent : ""; avail = lim - vlen(prefix); if (vlen(esc) <= avail) { print prefix esc; break } cut = cut_at_cols(esc, avail); chunk = substr(esc, 1, cut); brk = find_break(chunk); split(brk, arr, "|"); bpos = arr[1] + 0; bmode = arr[2]; if (bpos > 0 && bmode == "sp") { print prefix substr(esc, 1, bpos - 1); esc = substr(esc, bpos + 1); add_indent = 0; continue } else if (bpos > 0 && bmode == "sep") { print prefix substr(esc, 1, bpos); esc = substr(esc, bpos + 1); add_indent = 0; continue } print prefix chunk; esc = substr(esc, cut + 1); add_indent = 1 } }')

            local _msg="<pre>⏳ <b>КОМАНДА ОЖИДАЕТ ВВОД</b>
${SEP46}
${SEP46}
${_cmd_wrapped}
${SEP46}
${SEP46}
${_exec_out}</pre>

Отправьте ваш ответ командой:
<code>/exec ответ</code>

Завершить stdin (EOF): <code>/exec _eof</code>
Прервать команду: <code>/exec _ctrlc</code>
Завершить сессию: <code>/exec _exit</code>"

            if [ -n "$_exec_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_exec_msg_id" --data-urlencode text="$_msg" -d parse_mode="HTML" > /dev/null 2>&1; echo "$_exec_msg_id" > "$_EXEC_WAIT_MSG_FILE"
            else send_message "$_msg"; fi
            return
        fi

        [ -z "$_exec_out" ] && _exec_out="(нет вывода)"
        local _display_cmd="$_exec_cmd"
        if [ -f /tmp/telegram_bot/exec/session/last_cmd ]; then
            local _saved_cmd=$(cat /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null)
            if [ -n "$_saved_cmd" ] && [ "$_saved_cmd" != "$_exec_cmd" ]; then _display_cmd="$_saved_cmd"; fi
        fi
        if declare -F _exec_send_output >/dev/null 2>&1; then _exec_send_output "$_display_cmd" "$_exec_out" "${_EXEC_LAST_RC:-0}" "$_exec_msg_id"; fi
        rm -f "$_EXEC_WAIT_MSG_FILE" /tmp/telegram_bot/exec/session/last_cmd
        return
    fi
	
    if [[ "$text" == "/unfixip" ]] || [[ "$text" == "/unfixip "* ]]; then
        local _uf_arg="${text#/unfixip}"; _uf_arg="${_uf_arg# }"; _uf_arg=$(echo "$_uf_arg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$_uf_arg" ]; then
            _bot_kill_main_menu; rm -f /tmp/telegram_bot/state/unfixip_selected.json
            local _old_uf_id=$(cat /tmp/telegram_bot/state/unfixip_msg_id 2>/dev/null)
            if [ -n "$_old_uf_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_uf_id" >/dev/null 2>&1 & fi
            _unfixip_show_list; return
        fi
        local _uf_is_mac=0 _uf_is_ip=0; local _uf_mac_lc=""; local _uf_ip=""
        if echo "$_uf_arg" | grep -qE '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'; then _uf_is_mac=1; _uf_mac_lc=$(echo "$_uf_arg" | tr 'A-Z' 'a-z')
        elif echo "$_uf_arg" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            local _oct_valid=1; local _oct
            for _oct in ${_uf_arg//./ }; do if [ "$_oct" -gt 255 ]; then _oct_valid=0; break; fi; done
            if [ "$_oct_valid" = "0" ]; then send_message "❌ <b>Неверный IP</b>"; return; fi
            _uf_is_ip=1; _uf_ip="$_uf_arg"
        else send_message "❌ <b>Не распознано</b>"; return; fi
        
        local _uf_idx=0; local _uf_found=""
        while [ "$_uf_idx" -lt 500 ]; do
            local _sec="dhcp.@host[$_uf_idx]"
            if ! uci -q get "$_sec" >/dev/null 2>&1; then break; fi
            local _ci=$(uci -q get "$_sec.ip" 2>/dev/null); local _cm=$(uci -q get "$_sec.mac" 2>/dev/null)
            if [ "$_uf_is_mac" = "1" ]; then if [ -n "$_cm" ] && [ "$(echo "$_cm" | tr 'A-Z' 'a-z')" = "$_uf_mac_lc" ]; then _uf_found="$_uf_idx"; break; fi
            else if [ -n "$_ci" ] && [ "$_ci" = "$_uf_ip" ]; then _uf_found="$_uf_idx"; break; fi; fi
            _uf_idx=$((_uf_idx + 1))
        done
        if [ -z "$_uf_found" ]; then send_message "ℹ️ Фиксация не найдена"; return; fi
        
        local _sec="dhcp.@host[$_uf_found]"; local _nm=$(uci -q get "$_sec.name" 2>/dev/null); local _mm=$(uci -q get "$_sec.mac" 2>/dev/null); local _im=$(uci -q get "$_sec.ip" 2>/dev/null)
        uci delete "$_sec" 2>/dev/null; uci commit dhcp 2>/dev/null; /etc/init.d/dnsmasq reload 2>/dev/null
        if [ -n "$_mm" ]; then local _mm_lc=$(echo "$_mm" | tr 'A-Z' 'a-z'); if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then grep -vi "^${_mm_lc} " "/etc/telegram_bot/data/device_names.txt" > "/etc/telegram_bot/data/device_names.txt.tmp" 2>/dev/null; mv "/etc/telegram_bot/data/device_names.txt.tmp" "/etc/telegram_bot/data/device_names.txt" 2>/dev/null; fi; fi
        send_message "🗑 Фиксация снята"; return
    fi
	
    if [[ "$text" == "/target" ]]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        if [ -f "/tmp/telegram_bot/target/msg_id" ]; then
            local _old_tgt_id=$(cat "/tmp/telegram_bot/target/msg_id" 2>/dev/null | tr -d '\n\r ')
            if [ -n "$_old_tgt_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                    -d chat_id="$CHAT_ID" -d message_id="$_old_tgt_id" >/dev/null 2>&1
            fi
        fi
        rm -rf /tmp/telegram_bot/target; mkdir -p /tmp/telegram_bot/target
        _bot_kill_main_menu; _target_render_list 1 ""; return
    fi
	
    if [[ "$text" == "/threshold" ]] || [[ "$text" == "/threshold "* ]]; then
        local _thr_arg="${text#/threshold}"; _thr_arg="${_thr_arg# }"
        if ! uci -q get telegram_bot.thresholds.enabled >/dev/null 2>&1; then
            [ -f /etc/config/telegram_bot ] || touch /etc/config/telegram_bot
            uci set telegram_bot.thresholds=thresholds; uci set telegram_bot.thresholds.enabled='1'; uci set telegram_bot.thresholds.ram_free_min='20'; uci set telegram_bot.thresholds.cpu_temp_max='75'; uci set telegram_bot.thresholds.wifi_temp_max='85'; uci set telegram_bot.thresholds.cooldown='600'; uci set telegram_bot.thresholds.cooldown_ram='600'; uci set telegram_bot.thresholds.cooldown_cpu='600'; uci set telegram_bot.thresholds.cooldown_wifi='600'; uci commit telegram_bot
        fi
        if [ -z "$_thr_arg" ] || [ "$_thr_arg" = "show" ]; then _threshold_render_table; return; fi
        if [ "$_thr_arg" = "on" ] || [ "$_thr_arg" = "off" ]; then
            local _new_val="1"; [ "$_thr_arg" = "off" ] && _new_val="0"
            uci set telegram_bot.thresholds.enabled="$_new_val"; uci commit telegram_bot
            local _label="🟢 Мониторинг RAM/температуры включён"; [ "$_new_val" = "0" ] && _label="🔴 Мониторинг RAM/температуры выключен"
            _threshold_render_table "$_label"; return
        fi
        if [ "$_thr_arg" = "reset" ]; then
            uci set telegram_bot.thresholds.enabled='1'; uci set telegram_bot.thresholds.ram_free_min='20'; uci set telegram_bot.thresholds.cpu_temp_max='75'; uci set telegram_bot.thresholds.wifi_temp_max='85'; uci set telegram_bot.thresholds.cooldown='600'; uci set telegram_bot.thresholds.cooldown_ram='600'; uci set telegram_bot.thresholds.cooldown_cpu='600'; uci set telegram_bot.thresholds.cooldown_wifi='600'; uci commit telegram_bot
            _threshold_render_table "✅ Пороги сброшены к дефолтам"; return
        fi
        local _key=$(echo "$_thr_arg" | awk '{print $1}'); local _val=$(echo "$_thr_arg" | awk '{print $2}')
        if [ -z "$_val" ]; then 
            local _err_id=$(send_message_and_get_id "⚠️ <b>Не указано значение</b>")
            [ -n "$_err_id" ] && echo "$_err_id" > /tmp/telegram_bot/state/threshold_error_msg_id
            return
        fi
        case "$_val" in 
            ''|*[!0-9]*) 
                local _err_id=$(send_message_and_get_id "⚠️ <b>Значение должно быть числом</b>")
                [ -n "$_err_id" ] && echo "$_err_id" > /tmp/telegram_bot/state/threshold_error_msg_id
                return 
                ;; 
        esac
        local _uci_key="" _min=0 _max=999999 _unit=""
        case "$_key" in
            ram)      _uci_key="ram_free_min";  _min=0;  _max=500;   _unit="MB"  ;;
            cpu)      _uci_key="cpu_temp_max";  _min=0;  _max=120;   _unit="°C"  ;;
            wifi)     _uci_key="wifi_temp_max"; _min=0;  _max=120;   _unit="°C"  ;;
            ram_cd)   _uci_key="cooldown_ram";  _min=60; _max=86400; _unit="сек" ;;
            cpu_cd)   _uci_key="cooldown_cpu";  _min=60; _max=86400; _unit="сек" ;;
            wifi_cd)  _uci_key="cooldown_wifi"; _min=60; _max=86400; _unit="сек" ;;
            cooldown) _uci_key="__all_cooldowns__"; _min=60; _max=86400; _unit="сек" ;;
            *) 
                local _err_id=$(send_message_and_get_id "⚠️ <b>Неизвестный параметр</b>")
                [ -n "$_err_id" ] && echo "$_err_id" > /tmp/telegram_bot/state/threshold_error_msg_id
                return 
                ;;
        esac
        if [ "$_val" -lt "$_min" ] 2>/dev/null || [ "$_val" -gt "$_max" ] 2>/dev/null; then 
            local _err_id=$(send_message_and_get_id "⚠️ <b>Значение вне диапазона</b>")
            [ -n "$_err_id" ] && echo "$_err_id" > /tmp/telegram_bot/state/threshold_error_msg_id
            return
        fi
        if [ "$_uci_key" = "__all_cooldowns__" ]; then
            uci set "telegram_bot.thresholds.cooldown=$_val"; uci set "telegram_bot.thresholds.cooldown_ram=$_val"; uci set "telegram_bot.thresholds.cooldown_cpu=$_val"; uci set "telegram_bot.thresholds.cooldown_wifi=$_val"
        else uci set "telegram_bot.thresholds.$_uci_key=$_val"; fi
        uci commit telegram_bot
        local _note=""
        [ "$_val" = "0" ] && _note=" (⛔ отключено)"
        local _prefix="✅ Порог обновлён: <b>${_key}</b> = ${_val} ${_unit}${_note}"
        [ "$_key" = "cooldown" ] && _prefix="✅ Все cooldown = ${_val} сек"
        rm -f /tmp/telegram_bot/state/threshold_last
		_threshold_render_table "$_prefix"; return
    fi
	
    if [ "$text" = "/event history" ] || [ "$text" = "/event history info" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        rm -f /tmp/telegram_bot/state/event_history_msgs.txt
        local _old_eh_mid=$(cat /tmp/telegram_bot/state/event_history_table_msg_id 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_old_eh_mid" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$_old_eh_mid" >/dev/null 2>&1
            rm -f /tmp/telegram_bot/state/event_history_table_msg_id
        fi
        local _eh_text=$(_get_event_history_table)
        local _eh_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"event_history_close"}]]}'
        local _eh_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="$_eh_text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$_eh_kb" 2>&1)
        local _new_mid=$(echo "$_eh_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
        if [ -n "$_new_mid" ]; then
            echo "$_new_mid" > /tmp/telegram_bot/state/event_history_table_msg_id
            echo "$_new_mid" >> /tmp/telegram_bot/state/event_history_msgs.txt
        fi
        return
    fi

    if [ "$text" = "/event history off" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        uci set telegram_bot.main.log_history_disabled='1'; uci commit telegram_bot
        local _eh_mid=$(cat /tmp/telegram_bot/state/event_history_table_msg_id 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_eh_mid" ]; then
            local _eh_text=$(_get_event_history_table)
            local _eh_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"event_history_close"}]]}'
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$_eh_mid" \
                --data-urlencode text="$_eh_text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$_eh_kb" >/dev/null 2>&1
        fi
        return
    fi

    if [ "$text" = "/event history on" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        uci delete telegram_bot.main.log_history_disabled; uci commit telegram_bot
        local _eh_mid=$(cat /tmp/telegram_bot/state/event_history_table_msg_id 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_eh_mid" ]; then
            local _eh_text=$(_get_event_history_table)
            local _eh_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"event_history_close"}]]}'
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$_eh_mid" \
                --data-urlencode text="$_eh_text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$_eh_kb" >/dev/null 2>&1
        fi
        return
    fi

    if [[ "$text" == "/event history size "* ]]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        local _size_arg="${text#/event history size }"; _size_arg="${_size_arg// /}"
        case "$_size_arg" in
            ''|*[!0-9]*) return ;;
        esac
        if [ "$_size_arg" -lt 1 ] || [ "$_size_arg" -gt 5 ]; then return; fi
        [ -f /etc/config/telegram_bot ] || touch /etc/config/telegram_bot
        if ! uci -q get telegram_bot.log >/dev/null 2>&1; then uci set telegram_bot.log=log; fi
        uci set telegram_bot.log.max_size_mb="$_size_arg"; uci commit telegram_bot
        local _eh_mid=$(cat /tmp/telegram_bot/state/event_history_table_msg_id 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_eh_mid" ]; then
            local _eh_text=$(_get_event_history_table)
            local _eh_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"event_history_close"}]]}'
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$_eh_mid" \
                --data-urlencode text="$_eh_text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$_eh_kb" >/dev/null 2>&1
        fi
        return
    fi
	
    if [ "$text" = "/event off" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        if [ -f "/tmp/telegram_bot/state/event_toggle_msg_id" ]; then
            local _old_evt=$(cat "/tmp/telegram_bot/state/event_toggle_msg_id" 2>/dev/null)
            [ -n "$_old_evt" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_evt" >/dev/null 2>&1
            rm -f "/tmp/telegram_bot/state/event_toggle_msg_id"
        fi

        uci set telegram_bot.main.event_mute_disabled='1'; uci commit telegram_bot
        local _mid=$(send_message_and_get_id "⏹️ <b>Все уведомления выключены</b>

События продолжат попадать в журнал,
но push-сообщения приходить не будут.

Включить: <code>/event on</code>")
        [ -n "$_mid" ] && echo "$_mid" > /tmp/telegram_bot/state/event_toggle_msg_id
        return
    fi

    if [ "$text" = "/event on" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        if [ -f "/tmp/telegram_bot/state/event_toggle_msg_id" ]; then
            local _old_evt=$(cat "/tmp/telegram_bot/state/event_toggle_msg_id" 2>/dev/null)
            [ -n "$_old_evt" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_evt" >/dev/null 2>&1
            rm -f "/tmp/telegram_bot/state/event_toggle_msg_id"
        fi

        uci delete telegram_bot.main.event_mute_disabled; uci commit telegram_bot
        local _mid=$(send_message_and_get_id "🔔 <b>Уведомления включены</b>

Важные события снова будут 
приходить с учётом списка <code>/mute info</code>.")
        [ -n "$_mid" ] && echo "$_mid" > /tmp/telegram_bot/state/event_toggle_msg_id
        return
    fi
	
    if [[ "$text" == "/mute" ]] || [[ "$text" == "/mute info" ]]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then 
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
            _IN_TEXT_MSG_ID=""
        fi
        rm -f "$_MUTE_STATE_DEL_OPEN"
        show_mute_menu
        return
    fi

    if [ -f "$_MUTE_STATE_ADD_MODE" ]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        if echo "$text" | grep -qiE "^отмена$|^cancel$|^/cancel$"; then
            rm -f "$_MUTE_STATE_ADD_MODE"
            if [ -f "$_MUTE_PROMPT_MSG_ID" ]; then _pid=$(cat "$_MUTE_PROMPT_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1; rm -f "$_MUTE_PROMPT_MSG_ID"; fi
            if [ -f "$_MUTE_ERROR_MSG_ID" ]; then _eid=$(cat "$_MUTE_ERROR_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_eid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1; rm -f "$_MUTE_ERROR_MSG_ID"; fi
            local _menu_id=""; [ -f "$_MUTE_MSG_ID" ] && _menu_id=$(cat "$_MUTE_MSG_ID" 2>/dev/null | tr -d '\n\r ')
            show_mute_menu "$_menu_id"; return
        fi
        local _err=""
        if [ ${#text} -lt 3 ]; then _err="Слишком короткий паттерн. Минимум 3 символа."
        elif [ ${#text} -gt 128 ]; then _err="Слишком длинный паттерн. Максимум 128 символов."
        elif echo "$text" | grep -q '[А-Яа-яЁё]'; then _err="Кириллица запрещена. Используйте латиницу (a-z, A-Z), цифры и спецсимв."; fi
        
        if [ -n "$_err" ]; then
            if [ -f "$_MUTE_ERROR_MSG_ID" ]; then _eid=$(cat "$_MUTE_ERROR_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_eid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1; fi
            if [ -f "$_MUTE_PROMPT_MSG_ID" ]; then _old_pid=$(cat "$_MUTE_PROMPT_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_old_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_pid" >/dev/null 2>&1; fi
            local _err_text="❌ <b>Ошибка ввода</b>

${_err}

Попробуйте еще раз или нажмите Отмена."
            local _eresp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$_err_text" -d parse_mode="HTML" 2>&1)
            local _emid=$(echo "$_eresp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_emid" ] && echo "$_emid" > "$_MUTE_ERROR_MSG_ID"
            local _presp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✏️ Введите слово или фразу для блока:" -d parse_mode="HTML" --data-urlencode "reply_markup={\"inline_keyboard\":[[{\"text\":\"🔙 Отмена\",\"callback_data\":\"mute_cancel\"}]]}" 2>&1)
            local _pmid=$(echo "$_presp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_pmid" ] && echo "$_pmid" > "$_MUTE_PROMPT_MSG_ID"
            return
        fi

        local _mute_arg=$(printf '%s\n' "$text" | tr 'A-Z' 'a-z'); local _mute_esc=$(_escape_user_pattern "$_mute_arg")
        if ! grep -qF -- "$_mute_esc" "$_EVENT_MUTE_FILE" 2>/dev/null; then printf '%s\n' "$_mute_esc" >> "$_EVENT_MUTE_FILE"; fi
        rm -f "$_MUTE_STATE_ADD_MODE"
        if [ -f "$_MUTE_PROMPT_MSG_ID" ]; then _pid=$(cat "$_MUTE_PROMPT_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1; rm -f "$_MUTE_PROMPT_MSG_ID"; fi
        if [ -f "$_MUTE_ERROR_MSG_ID" ]; then _eid=$(cat "$_MUTE_ERROR_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_eid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1; rm -f "$_MUTE_ERROR_MSG_ID"; fi
        local _menu_id=""; [ -f "$_MUTE_MSG_ID" ] && _menu_id=$(cat "$_MUTE_MSG_ID" 2>/dev/null | tr -d '\n\r ')
        show_mute_menu "$_menu_id"; return
    fi
	
    if [[ "$text" == "/help" ]] || [[ "$text" == "📖 Справка" ]]; then
        if [ -n "$_IN_TEXT_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi
        reset_device_selection; show_help; return
    fi
	
    if [[ "$text" == "/disable" ]]; then
        reset_device_selection
        local _dis_kb='{"inline_keyboard":[[{"text":"🛑 Да, отключить","callback_data":"disable_confirm"},{"text":"❌ Отмена","callback_data":"disable_cancel"}]]}'
        local _dis_mid=$(send_message_and_get_id "⚠️ <b>Полное отключение бота</b>

Это действие:
• Остановит telegram_bot, event_monitor, watchdog
• Заблокирует автозапуск (даже после ребута)

<b>Обратно включить можно только из консоли роутера:</b>
<code>rm /etc/telegram_bot/.bot_disabled</code>
<code>/etc/telegram_bot/restart_bot.sh</code>

Продолжить?" "$_dis_kb")
        [ -n "$_dis_mid" ] && echo "$_dis_mid" > /tmp/telegram_bot/state/bot_disable_msg_id
        return
    fi
	
    if [[ "$text" == "/uninstall" ]]; then
        reset_device_selection
        local _un_kb='{"inline_keyboard":[[{"text":"🛑 ДА, УДАЛИТЬ","callback_data":"uninstall_confirm"},{"text":"❌ Отмена","callback_data":"uninstall_cancel"}]]}'
        local _un_mid=$(send_message_and_get_id "⚠️ <b>ПОЛНОЕ УДАЛЕНИЕ БОТА</b>

Это действие <b>НЕОБРАТИМО</b>:

• Удалит все скрипты бота из <code>/root</code>
• Уберёт записи из crontab и rc.local
• Удалит настройки бота в UCI 
 (<code>telegram_bot</code>: пороги, cooldown)
• Удалит все временные файлы и логи

⚠️ Продолжить?" "$_un_kb")
        [ -n "$_un_mid" ] && echo "$_un_mid" > /tmp/telegram_bot/state/bot_uninstall_msg_id
        return
    fi
	
    if [[ "$text" == "/speedtest" ]] || [[ "$text" == "⚡ Speedtest" ]]; then
        reset_device_selection
        _run_speedtest_ui "" "0"
        return
    fi
	
    case "$cmd" in
        *"Статус бота"*|"/status")
            local old_msg_id=$(cat /tmp/telegram_bot/state/status_msg_id 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & fi
            
            _bot_mark_busy_start "status"
            if command -v timeout >/dev/null 2>&1; then
                result=$(timeout 15 /etc/telegram_bot/notify.sh status 2>&1)
            else
                result=$(/etc/telegram_bot/notify.sh status 2>&1)
            fi
            _bot_mark_busy_end
            
            local _new_ver=$(_bot_check_update)
            local _upd_btn=""
            if [ -n "$_new_ver" ]; then
                _upd_btn="{\"text\":\"📥 Обновить до v$_new_ver\",\"callback_data\":\"bot_update\"},"
            fi
            local kb="{\"inline_keyboard\":[[${_upd_btn}{\"text\":\"🔄 Обновить\",\"callback_data\":\"status_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"status_close\"}]]}"

            local new_msg_id=$(_bot_edit_menu_to_section "$result" "$kb")
            if [ -n "$new_msg_id" ]; then echo "$new_msg_id" > /tmp/telegram_bot/state/status_msg_id; fi
            ;;
        *"Клиенты онлайн"*|"/online")
            local old_msg_id=$(cat "$ONLINE_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & rm -f "$ONLINE_MSG_ID_FILE"; fi
            ONLINE_MSG_ID=""; echo "none" > /tmp/telegram_bot/online/state; echo "1" > /tmp/telegram_bot/online/page
            _bot_mark_busy_start "online"
            if command -v timeout >/dev/null 2>&1; then
                result=$(timeout 30 /etc/telegram_bot/notify.sh online 1 2>&1); if [ $? -eq 124 ]; then result="⚠️ Команда 'Клиенты онлайн' превысила время ожидания"; fi
            else result=$(/etc/telegram_bot/notify.sh online 1 2>&1); fi
            _bot_mark_busy_end
            local kb=$(_build_online_keyboard); local new_msg_id=""
            if [ ${#result} -le 4000 ]; then new_msg_id=$(_bot_edit_menu_to_section "$result" "$kb"); else send_long_message "$result" "$kb"; fi
            if [ -n "$new_msg_id" ]; then echo "$new_msg_id" > "$ONLINE_MSG_ID_FILE"; ONLINE_MSG_ID="$new_msg_id"; fi ;;
        *"Журнал событий"*|"/critical")
            rm -f /tmp/telegram_bot/critical/dl_menu_open
            local old_msg_id=$(cat /tmp/telegram_bot/critical/msg_id 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & rm -f /tmp/telegram_bot/critical/msg_id; fi
            _bot_mark_busy_start "critical"
            if command -v timeout >/dev/null 2>&1; then
                result=$(timeout 30 /etc/telegram_bot/notify.sh critical init 2>&1); if [ $? -eq 124 ]; then result="⚠️ Команда 'Журнал событий' превысила время ожидания"; fi
            else result=$(/etc/telegram_bot/notify.sh critical init 2>&1); fi
            _bot_mark_busy_end
            if [[ "$result" == *"||"* ]]; then text="${result%||*}"; keyboard="${result#*||}"; else text="$result"; keyboard=""; fi
            msg_id=$(_bot_edit_menu_to_section "$text" "$keyboard")
            if [ -n "$msg_id" ]; then /etc/telegram_bot/notify.sh critical setmsgid "$msg_id" > /dev/null 2>&1; _critical_set_msg_id "$msg_id"; echo "$msg_id" > /tmp/telegram_bot/critical/msg_id; fi ;;
        *"Время работы"*|"/uptime")
            local old_msg_id=$(cat "$UPTIME_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & 
                rm -f "$UPTIME_MSG_ID_FILE"; fi
            UPTIME_MSG_ID=""
            if command -v timeout >/dev/null 2>&1; then result=$(timeout 30 /etc/telegram_bot/notify.sh uptime 2>&1); 
                if [ $? -eq 124 ]; then result="⚠️ Команда 'Время работы' превысила время ожидания"; fi
            else result=$(/etc/telegram_bot/notify.sh uptime 2>&1); fi
            local _uptime_kb='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"uptime_refresh"},{"text":"❌ Закрыть","callback_data":"uptime_close"}]]}'
            new_msg_id=$(_bot_edit_menu_to_section "$result" "$_uptime_kb")
            if [ -n "$new_msg_id" ]; then echo "$new_msg_id" > "$UPTIME_MSG_ID_FILE"; 
            UPTIME_MSG_ID="$new_msg_id"; fi ;;
        *"Статус системы"*|"/system")
            local old_msg_id=$(cat "$SYSTEM_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & rm -f "$SYSTEM_MSG_ID_FILE"; fi
            SYSTEM_MSG_ID=""
            _bot_mark_busy_start "system"
            if command -v timeout >/dev/null 2>&1; then
                result=$(timeout 30 /etc/telegram_bot/notify.sh system 2>&1); if [ $? -eq 124 ]; then result="⚠️ Команда 'Статус системы' превысила время ожидания"; fi
            else result=$(/etc/telegram_bot/notify.sh system 2>&1); fi
            _bot_mark_busy_end
            local kb='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"system_refresh"},{"text":"❌ Закрыть","callback_data":"system_close"}]]}'
            new_msg_id=$(_bot_edit_menu_to_section "$result" "$kb")
            if [ -n "$new_msg_id" ]; then echo "$new_msg_id" > "$SYSTEM_MSG_ID_FILE"; SYSTEM_MSG_ID="$new_msg_id"; fi ;;
        *"Трафик"*|"/traffic")
            local old_msg_id=$(cat "$TRAFFIC_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$old_msg_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1 & rm -f "$TRAFFIC_MSG_ID_FILE"; fi
            TRAFFIC_MSG_ID=""
            _bot_mark_busy_start "traffic"
            if command -v timeout >/dev/null 2>&1; then
                traffic_data=$(timeout 30 /etc/telegram_bot/notify.sh traffic day 2>&1); if [ $? -eq 124 ]; then traffic_data="⚠️ Команда 'Трафик' превысила время ожидания."; fi
            else traffic_data=$(/etc/telegram_bot/notify.sh traffic day 2>&1); fi
            _bot_mark_busy_end
            echo "day" > /tmp/telegram_bot/traffic/active_period
            local keyboard=$(get_traffic_period_keyboard "day")
            if [ ${#traffic_data} -le 4000 ]; then new_msg_id=$(_bot_edit_menu_to_section "$traffic_data" "$keyboard"); else send_long_message "$traffic_data" "$keyboard"; fi
            if [ -n "$new_msg_id" ]; then echo "$new_msg_id" > "$TRAFFIC_MSG_ID_FILE"; TRAFFIC_MSG_ID="$new_msg_id"; fi ;;
        *"Wake-on-LAN"*|"/wake")
            local old_wol_msg=$(cat /tmp/telegram_bot/wol/msg_id 2>/dev/null)
            if [ -n "$old_wol_msg" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_wol_msg" >/dev/null 2>&1 & rm -f /tmp/telegram_bot/wol/msg_id; fi
            rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name /tmp/telegram_bot/wol/delete_mode
            show_wol_menu ;;
        *"Перезагрузить роутер"*|"/reboot")
            local old_reboot_id=""; [ -f "$REBOOT_MSG_ID_FILE" ] && old_reboot_id=$(cat "$REBOOT_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$old_reboot_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_reboot_id" >/dev/null 2>&1 & rm -f "$REBOOT_MSG_ID_FILE" "$REBOOT_LAST_ACTIVITY_FILE"; fi
            local keyboard=$(get_reboot_confirm_keyboard)
            local reboot_id=$(_bot_edit_menu_to_section "⚠️ <b>Действительно хотите перезагрузить роутер?</b> Связь пропадёт на 1–2 минуты." "$keyboard")
            if [ -n "$reboot_id" ]; then echo "$reboot_id" > "$REBOOT_MSG_ID_FILE"; _update_activity "$REBOOT_LAST_ACTIVITY_FILE"; fi ;;
        *"Ограничить скорость"*|"/speed")
            rm -f "$SPEED_USER_MSGS_FILE"
            if [ -n "$_IN_TEXT_MSG_ID" ]; then _speed_track_user_msg "$_IN_TEXT_MSG_ID"; _IN_TEXT_MSG_ID=""; fi
            _bot_kill_main_menu
            local _old_speed_id=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            if [ -n "$_old_speed_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_speed_id" >/dev/null 2>&1 & fi
            rm -f /tmp/telegram_bot/speed/msg_id /tmp/telegram_bot/speed/limit_msg_id; SPEED_MSG_ID=""
            show_device_list ;;
        *"Проводник"*|"/explorer")
            _bot_kill_main_menu; show_explorer ;;
        "/start"|"/menu")
            send_menu; reset_device_selection ;;
        *)
            send_menu; reset_device_selection ;;
    esac
}	

handle_callback() {
    local callback_data="$1"
    local callback_id="$2"
    local message_id="$3"
    local chat_id="$4"
    if [ -f "/tmp/telegram_bot/flags/skip_msg_id" ]; then
        local _skip_id=$(cat "/tmp/telegram_bot/flags/skip_msg_id" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_skip_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_skip_id" >/dev/null 2>&1 & fi
        rm -f "/tmp/telegram_bot/flags/skip_msg_id"
    fi
    if [ "$chat_id" != "$CHAT_ID" ]; then
        echo "$(date): Unauthorized callback from $chat_id: $callback_data" >> /tmp/telegram_bot/logs/bot.log
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⛔ Доступ запрещён" > /dev/null 2>&1
        return
    fi
	
    if [[ "$callback_data" =~ ^(expl_|svc_|critical_|system_refresh|traffic_|wol_wake|limit_|speed_remove|nl_static_save) ]]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1 &
    fi
	
    local _expected_mid=""; local _need_check=0
    if [[ "$callback_data" == "speed_set_continue" ]] || [[ "$callback_data" == "speed_remove_continue" ]] || [[ "$callback_data" == "close_to_menu" ]] || [[ "$callback_data" == "wol_cancel_setup" ]]; then
        _need_check=0
    else
        case "$callback_data" in
            unfixip_*)           _expected_mid=$(cat /tmp/telegram_bot/state/unfixip_msg_id 2>/dev/null); _need_check=1 ;;
            target_*)            _expected_mid=$(cat /tmp/telegram_bot/target/msg_id 2>/dev/null); _need_check=1 ;;
            mute_*)              _expected_mid=$(cat /tmp/telegram_bot/state/mute_msg_id 2>/dev/null); _need_check=1 ;;
            online_*|nl_static_*) _expected_mid=$(cat /tmp/telegram_bot/online/msg_id 2>/dev/null); _need_check=1 ;;
            traffic_*)           _expected_mid=$(cat /tmp/telegram_bot/traffic/msg_id 2>/dev/null); _need_check=1 ;;
            system_*)            _expected_mid=$(cat /tmp/telegram_bot/state/system_msg_id 2>/dev/null); _need_check=1 ;;
            wol_*)               _expected_mid=$(cat /tmp/telegram_bot/wol/msg_id 2>/dev/null); _need_check=1 ;;
            reboot_*)            _expected_mid=$(cat /tmp/telegram_bot/reboot/msg_id 2>/dev/null); _need_check=1 ;;
            critical_*)          _expected_mid=$(cat /tmp/telegram_bot/critical/msg_id 2>/dev/null); _need_check=1 ;;
            select_*|speed_*|dur_*|day_*|days_done) _expected_mid=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null); _need_check=1 ;;
            limit_*)             _expected_mid=$(cat /tmp/telegram_bot/speed/limit_msg_id 2>/dev/null); _need_check=1 ;;
            expl_*)              _need_check=0 ;;
            *)                   _need_check=0 ;;
        esac
    fi

    if [ "$_need_check" = "1" ]; then
        _expected_mid=$(echo "$_expected_mid" | tr -d '\n\r ')
        if [ -z "$_expected_mid" ] || [ "$_expected_mid" != "$message_id" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
            return
        fi
    fi

    if [[ "$callback_data" == "newdev_close" ]] || [[ "$callback_data" =~ ^newdev_close_([0-9a-fA-F:]{17})$ ]]; then
        if [[ "$callback_data" =~ ^newdev_close_([0-9a-fA-F:]{17})$ ]]; then
            local _nd_mac_lc=$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')
            rm -f "/tmp/telegram_bot/state/newdev_${_nd_mac_lc}.msg"
        fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Окно закрыто" >/dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^newdev_deny_([0-9a-fA-F:]{17})$ ]]; then
        local _nd_mac="${BASH_REMATCH[1]}"
        local _nd_mac_lc=$(echo "$_nd_mac" | tr 'A-Z' 'a-z')
        local _nd_msg_file="/tmp/telegram_bot/state/newdev_${_nd_mac_lc}.msg"

        /etc/telegram_bot/notify.sh block_mac "$_nd_mac_lc" >/dev/null 2>&1

        if [ -f "$_nd_msg_file" ]; then
            local _nd_orig=$(cat "$_nd_msg_file" 2>/dev/null)
            if [ -n "$_nd_orig" ]; then
                # Отрезаем всё начиная с "Для изоляции" до конца
                local _nd_clean=$(printf '%s\n' "$_nd_orig" | sed '/Для изоляции/,$d')
                
                _nd_clean="${_nd_clean/🆕 НОВОЕ УСТРОЙСТВО В СЕТИ/🚫 УСТРОЙСТВО ЗАБЛОКИРОВАНО}"
                
                _nd_clean="${_nd_clean%</pre>}"
                local _nd_new_text="${_nd_clean}
${SEP46}
MAC-адрес добавлен в черный список.</pre>"
                
                local _close_kb="{\"inline_keyboard\":[[{\"text\":\"❌ Закрыть\",\"callback_data\":\"newdev_close_${_nd_mac}\"}]]}"
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$_nd_new_text" -d parse_mode="HTML" --data-urlencode "reply_markup=$_close_kb" >/dev/null 2>&1
            fi
            rm -f "$_nd_msg_file"
        fi

        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🚫 Заблокирован: $_nd_mac" >/dev/null 2>&1
        return
    fi
	
    case "$callback_data" in
        disable_confirm|disable_cancel)
            local _dis_mid=""; [ -f /tmp/telegram_bot/state/bot_disable_msg_id ] && _dis_mid=$(cat /tmp/telegram_bot/state/bot_disable_msg_id 2>/dev/null | tr -d '\n\r ')
            if [ -z "$_dis_mid" ] || [ "$message_id" != "$_dis_mid" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
                if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
                rm -f /tmp/telegram_bot/state/bot_disable_msg_id; return
            fi ;;
        uninstall_confirm|uninstall_cancel)
            local _un_mid=""; [ -f /tmp/telegram_bot/state/bot_uninstall_msg_id ] && _un_mid=$(cat /tmp/telegram_bot/state/bot_uninstall_msg_id 2>/dev/null | tr -d '\n\r ')
            if [ -z "$_un_mid" ] || [ "$message_id" != "$_un_mid" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
                if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
                rm -f /tmp/telegram_bot/state/bot_uninstall_msg_id; return
            fi ;;
    esac
	
    if [ "$callback_data" = "speedtest_repeat" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Запускаю тест..." >/dev/null 2>&1
        _run_speedtest_ui "$message_id" "1"
        return
    fi

    if [ "$callback_data" = "speedtest_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/state/speedtest_msg_id
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚡ Speedtest закрыт" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "bot_update" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Запускаю обновление..." >/dev/null 2>&1
        
        if command -v setsid >/dev/null 2>&1; then
            setsid /bin/bash /etc/telegram_bot/update.sh </dev/null >/dev/null 2>&1 &
        else
            /bin/bash /etc/telegram_bot/update.sh </dev/null >/dev/null 2>&1 &
        fi
        return
    fi

    if [ "$callback_data" = "status_refresh" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Обновляю..." >/dev/null 2>&1
        _bot_mark_busy_start "status_refresh"
        local result=$(/etc/telegram_bot/notify.sh status 2>&1)
        _bot_mark_busy_end
        local kb='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"status_refresh"},{"text":"📥 Обновить бота","callback_data":"bot_update"},{"text":"❌ Закрыть","callback_data":"status_close"}]]}'
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$result" -d parse_mode="HTML" --data-urlencode "reply_markup=$kb" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "close_error" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Окно закрыто" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "status_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/state/status_msg_id
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📊 Статус закрыт" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "help_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/state/help_msg_id
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📖 Справка закрыта" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "exec_info_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/state/exec_info_msg_id  # <--- ОЧИЩАЕМ ID ПРИ ЗАКРЫТИИ
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📖 Справка закрыта" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "uptime_refresh" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Обновляю..." >/dev/null 2>&1
        local result=""
        if command -v timeout >/dev/null 2>&1; then
            result=$(timeout 30 /etc/telegram_bot/notify.sh uptime 2>&1)
            if [ $? -eq 124 ]; then result="⚠️ Команда 'Время работы' превысила время ожидания"; fi
        else result=$(/etc/telegram_bot/notify.sh uptime 2>&1); fi
        local _uptime_kb='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"uptime_refresh"},{"text":"❌ Закрыть","callback_data":"uptime_close"}]]}'
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$message_id" \
            --data-urlencode text="$result" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$_uptime_kb" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "uptime_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f "$UPTIME_MSG_ID_FILE"
        UPTIME_MSG_ID=""
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Окно закрыто" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "system_refresh" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⏳ Обновляю статус системы..." -d show_alert="false" >/dev/null 2>&1
        _bot_mark_busy_start "system_refresh"
        local result=""
        if command -v timeout >/dev/null 2>&1; then
            result=$(timeout 30 /etc/telegram_bot/notify.sh system 2>&1); local _rc=$?
            if [ "$_rc" -eq 124 ]; then result="⚠️ Команда 'Статус системы' превысила 
время ожидания (30 сек)"; fi
        else result=$(/etc/telegram_bot/notify.sh system 2>&1); fi
        _bot_mark_busy_end
        local kb='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"system_refresh"},{"text":"❌ Закрыть","callback_data":"system_close"}]]}'
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$result" -d parse_mode="HTML" --data-urlencode "reply_markup=$kb" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "system_close" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        rm -f "$SYSTEM_MSG_ID_FILE"; send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=📊 Статус системы закрыт" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "threshold_close" ]; then
        local _id=$(cat /tmp/telegram_bot/state/threshold_msg_id 2>/dev/null)
        [ -n "$_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_id" >/dev/null 2>&1
        if [ -f "/tmp/telegram_bot/state/threshold_error_msg_id" ]; then
            local _teid=$(cat /tmp/telegram_bot/state/threshold_error_msg_id 2>/dev/null)
            [ -n "$_teid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_teid" >/dev/null 2>&1
            rm -f "/tmp/telegram_bot/state/threshold_error_msg_id"
        fi

        rm -f /tmp/telegram_bot/state/threshold_msg_id /tmp/telegram_bot/state/threshold_last_activity
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Меню закрыто" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "event_history_close" ]; then
        if [ -f "/tmp/telegram_bot/state/event_history_msgs.txt" ]; then
            while IFS= read -r _mid; do [ -n "$_mid" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1 & done < "/tmp/telegram_bot/state/event_history_msgs.txt"
            rm -f "/tmp/telegram_bot/state/event_history_msgs.txt"
        fi
        rm -f /tmp/telegram_bot/state/event_history_table_msg_id
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=✅ Окно закрыто" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "critical_dl_toggle" ]; then
        if [ -f "/etc/telegram_bot/data/.log_history_disabled" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⚠️ Сбор логов отключен. Включите: /event history on" -d show_alert="true" > /dev/null 2>&1
            return
        fi
        _bot_mark_busy_start "critical_refresh"
        if [ -f /tmp/telegram_bot/critical/dl_menu_open ]; then
            rm -f /tmp/telegram_bot/critical/dl_menu_open
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1
        else
            touch /tmp/telegram_bot/critical/dl_menu_open
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⏳ Сбор логов для скачивания..." -d show_alert="false" >/dev/null 2>&1
        fi
        local _resp=""
        if command -v timeout >/dev/null 2>&1; then
            _resp=$(timeout 30 /etc/telegram_bot/notify.sh critical refresh); local _rc=$?
            if [ "$_rc" -eq 124 ]; then _bot_mark_busy_end; send_message "⚠️ <b>Журнал не ответил за 30 сек</b>"; return; fi
        else _resp=$(/etc/telegram_bot/notify.sh critical refresh); fi
        _bot_mark_busy_end
        local _text="${_resp%||*}"; local _kb="${_resp#*||}"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$_text" -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^critical_dl_red_([0-9]+)h_ ]]; then
        local _hours="${BASH_REMATCH[1]}"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⚠️ Лог за последние ${_hours}ч ещё не накопился" -d show_alert="false" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^critical_dl_([0-9]+)h_(.+)$ ]]; then
        local _hours="${BASH_REMATCH[1]}"; local _filter="${BASH_REMATCH[2]}"; local _filter_name="$_filter"; [ "$_filter" = "none" ] || [ -z "$_filter" ] && _filter_name="all"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⏳ Формирую лог за ${_hours}ч..." > /dev/null 2>&1
        _bot_mark_busy_start "critical_download"
        local _res=""
        if command -v timeout >/dev/null 2>&1; then
            _res=$(timeout 60 /etc/telegram_bot/notify.sh critical download "$_hours" "$_filter"); local _rc=$?
            if [ "$_rc" -eq 124 ]; then _bot_mark_busy_end; send_message "⚠️ <b>Подготовка лога превысила 60 сек</b>"; return; fi
        else _res=$(/etc/telegram_bot/notify.sh critical download "$_hours" "$_filter"); fi
        _bot_mark_busy_end
        if [ "$_res" = "EMPTY" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⚠️ За этот период логов не найдено." -d show_alert="true" > /dev/null 2>&1
        elif [[ "$_res" == OK\|* ]]; then
            local _msg="${_res#OK|}"; local _out_file="/tmp/telegram_bot/critical/download_${_hours}h_${_filter}.txt"
            if [ -f "$_out_file" ]; then
                local _tmp_doc="/tmp/telegram_bot/critical/log_${_hours}h_${_filter_name}.txt"; cp "$_out_file" "$_tmp_doc"
                local _resp=$(curl -s --connect-timeout 10 --max-time 120 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" -F "chat_id=$CHAT_ID" -F "document=@${_tmp_doc}" --form-string "caption=✅ Лог успешно скачан: 
      ${_msg}" 2>&1)
                rm -f "$_out_file" "$_tmp_doc"
                if ! echo "$_resp" | jq -e '.ok' >/dev/null 2>&1; then local _err=$(echo "$_resp" | jq -r '.description // "unknown"' 2>/dev/null)
    send_message "❌ Ошибка отправки файла: $_err" '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"critical_cancel"}]]}'; fi
            else send_message "❌ Ошибка: файл не был создан."; fi
        else send_message "$_res"; fi
        return
    fi

    if [ "$callback_data" = "apk_ans_yes" ] || [ "$callback_data" = "apk_ans_no" ]; then
        local _sock=$(cat /tmp/telegram_bot/exec/apk_wait_sock 2>/dev/null)
        local _log=$(cat /tmp/telegram_bot/exec/apk_wait_log 2>/dev/null)
        local _path=$(cat /tmp/telegram_bot/exec/apk_wait_path 2>/dev/null)
        
        if [ -z "$_sock" ] || [ ! -S "$_sock" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Сессия установки устарела" -d show_alert="true" >/dev/null 2>&1
            rm -f /tmp/telegram_bot/exec/apk_wait_sock /tmp/telegram_bot/exec/apk_wait_log /tmp/telegram_bot/exec/apk_wait_path
            return
        fi

        local _ans="n"
        [ "$callback_data" = "apk_ans_yes" ] && _ans="y"

        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="Отправляю ответ '$_ans'..." >/dev/null 2>&1
        sexpect -sock "$_sock" send -enter "$_ans" 2>/dev/null
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="⏳ <b>Установка продолжается...</b>" -d parse_mode="HTML" >/dev/null 2>&1

        (
            sexpect -sock "$_sock" wait >/dev/null 2>&1
            local _rc=$?
            
            local _out=$(cat "$_log" 2>/dev/null | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r')
            sexpect -sock "$_sock" close >/dev/null 2>&1
            rm -f "$_sock" /tmp/telegram_bot/exec/apk_wait_sock /tmp/telegram_bot/exec/apk_wait_log /tmp/telegram_bot/exec/apk_wait_path

            local _name=$(basename "$_path")
            local _safe_out=$(_expl_wrap_text "$_out" 52)
            
            local _status="✅"
            [ "$_rc" != "0" ] && _status="❌"
            
            local _res_msg="<pre>${_status} УСТАНОВКА ЗАВЕРШЕНА (код $_rc)
${SEP46}
📄 ${_name}
Менеджер: apk
${SEP46}
${_safe_out}
${SEP46}</pre>"
            
            local _kb="{\"inline_keyboard\":[[{\"text\":\"⬅️ К списку\",\"callback_data\":\"expl_action_back\"}]]}"
            
            _expl_send_or_edit "$_res_msg" "$_kb" "$message_id"
        ) 200>&- &
        
        return
    fi

    if [ "$callback_data" = "exec_close" ]; then
        local _msg_file="/tmp/telegram_bot/exec/msgs_${message_id}.txt"
        if [ -f "$_msg_file" ]; then
            while read -r _umid; do [ -n "$_umid" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_umid" >/dev/null 2>&1 & done < "$_msg_file"
            rm -f "$_msg_file"
        fi
        local _wait_id=$(cat /tmp/telegram_bot/exec/wait_msg_id 2>/dev/null)
        if [ "$_wait_id" = "$message_id" ]; then rm -f /tmp/telegram_bot/exec/wait_msg_id; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=✅ Окно закрыто" >/dev/null 2>&1
        if [ -f "$_EXPL_RETURN_FLAG" ]; then _expl_return_from_exec
        else
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
            local _state_mid=$(cat /tmp/telegram_bot/exec/output/msg_id.txt 2>/dev/null)
            if [ "$_state_mid" = "$message_id" ]; then rm -rf /tmp/telegram_bot/exec/output/*; fi
        fi
        return
    fi

    if [ "$callback_data" = "exec_download" ]; then
        local _out_msg_id=""; [ -f /tmp/telegram_bot/exec/output/msg_id.txt ] && _out_msg_id=$(cat /tmp/telegram_bot/exec/output/msg_id.txt 2>/dev/null | tr -d '\n\r ')
        if [ -z "$_out_msg_id" ] || [ "$message_id" != "$_out_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Подготовка файла..." > /dev/null 2>&1
        local _raw_file="/tmp/telegram_bot/exec/output/raw.txt"
        if [ -f "$_raw_file" ]; then
            local _full_cmd=$(cat /tmp/telegram_bot/exec/output/cmd.txt 2>/dev/null | tr -d '\n\r'); local _filename=""
            if [[ "$_full_cmd" =~ ^cat[[:space:]]+(.+)$ ]]; then
                local _filepath="${BASH_REMATCH[1]}"; _filepath="${_filepath%\"}"; _filepath="${_filepath#\"}"; _filepath="${_filepath%\'}"; _filepath="${_filepath#\'}"
                _filename=$(basename "$_filepath" 2>/dev/null); _filename=$(echo "$_filename" | sed 's/[^a-zA-Z0-9_.-]//g')
            fi
            if [ -z "$_filename" ]; then
                _filename=$(echo "$_full_cmd" | awk '{print $1}' | sed 's/[^a-zA-Z0-9_.-]//g'); [ -z "$_filename" ] && _filename="exec_output"
                case "$_filename" in *.txt) ;; *) _filename="${_filename}.txt" ;; esac
            fi
            curl -s --connect-timeout 10 --max-time 120 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" -F "chat_id=$CHAT_ID" -F "document=@${_raw_file};filename=${_filename}" > /dev/null 2>&1
        else send_message "❌ Файл не найден."; fi
        return
    fi

    if [[ "$callback_data" == exec_page_* ]]; then
        local _state_dir="/tmp/telegram_bot/exec/output"
        if [ ! -d "$_state_dir" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        local _cur_page=$(cat "$_state_dir/page.txt" 2>/dev/null); local _total_pages=$(cat "$_state_dir/total.txt" 2>/dev/null)
        case "$_cur_page" in ''|*[!0-9]*) _cur_page=1 ;; esac; case "$_total_pages" in ''|*[!0-9]*) _total_pages=1 ;; esac
        case "$callback_data" in
            exec_page_prev) [ "$_cur_page" -gt 1 ] && _cur_page=$((_cur_page - 1)) ;;
            exec_page_next) [ "$_cur_page" -lt "$_total_pages" ] && _cur_page=$((_cur_page + 1)) ;;
            exec_page_info) curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📄 Страница $_cur_page из $_total_pages" > /dev/null 2>&1; return ;;
        esac
        _exec_render_page "$_cur_page" "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" == unfixip_sel_* ]]; then
        local num="${callback_data#unfixip_sel_}"; local sel_file="/tmp/telegram_bot/state/unfixip_selected.json"; [ ! -f "$sel_file" ] && echo "[]" > "$sel_file"
        local selected_json=$(cat "$sel_file")
        if echo "$selected_json" | jq -e ".[] | select(. == $num)" >/dev/null 2>&1; then selected_json=$(echo "$selected_json" | jq "del(.[] | select(. == $num))")
        else selected_json=$(echo "$selected_json" | jq ". + [$num]"); fi
        echo "$selected_json" > "$sel_file"
        _unfixip_show_list "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1
        return
    fi
	
    if [ "$callback_data" = "unfixip_reset" ]; then
        echo "[]" > "/tmp/telegram_bot/state/unfixip_selected.json"; _unfixip_show_list "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Выбор сброшен" >/dev/null 2>&1
        return
    fi
    if [ "$callback_data" = "unfixip_refresh" ]; then
        _unfixip_show_list "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Обновлено" >/dev/null 2>&1
        return
    fi
    if [ "$callback_data" = "unfixip_remove" ]; then
        local sel_file="/tmp/telegram_bot/state/unfixip_selected.json"; local selected_json=$(cat "$sel_file" 2>/dev/null); local selected_nums=$(echo "$selected_json" | jq -r '.[]')
        if [ -z "$selected_nums" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Не выбрано ни одного номера" >/dev/null 2>&1; return; fi
        
        _bot_mark_busy_start "unfixip_remove" 
        
        local _removed_count=0; local all_secs=($(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\(@host\[[0-9]*\]\)=host$/\1/p"))
        for num in $selected_nums; do
            local sec="${all_secs[$((num-1))]}"
            if [ -n "$sec" ]; then
                local mac=$(uci -q get "dhcp.$sec.mac" 2>/dev/null)
                uci delete "dhcp.$sec" 2>/dev/null; _removed_count=$((_removed_count + 1))
                if [ -n "$mac" ]; then
                    local mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')
                    if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
                        grep -vi "^${mac_lc} " "/etc/telegram_bot/data/device_names.txt" > "/etc/telegram_bot/data/device_names.txt.tmp" 2>/dev/null
                        mv "/etc/telegram_bot/data/device_names.txt.tmp" "/etc/telegram_bot/data/device_names.txt" 2>/dev/null
                    fi
                fi
            fi
        done
        uci commit dhcp 2>/dev/null; /etc/init.d/dnsmasq reload 2>/dev/null
        _bot_mark_busy_end
        echo "[]" > "$sel_file"; _unfixip_show_list "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Снято фиксаций: $_removed_count" >/dev/null 2>&1
        return
    fi
    if [ "$callback_data" = "unfixip_close" ]; then
        local _mid=$(cat "/tmp/telegram_bot/state/unfixip_msg_id" 2>/dev/null)
        [ -n "$_mid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1
        rm -f /tmp/telegram_bot/state/unfixip_msg_id /tmp/telegram_bot/state/unfixip_selected.json
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Управление фиксацией IP Закрыто" >/dev/null 2>&1
        return
    fi

    if [[ "$callback_data" == target_* ]]; then
        local _t_page=$(cat /tmp/telegram_bot/target/page 2>/dev/null); [ -z "$_t_page" ] && _t_page=1
        case "$callback_data" in
            target_close)
                rm -rf /tmp/telegram_bot/target
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
                send_menu ;;
            target_refresh) _target_render_list "$_t_page" "$message_id" ;;
            target_page_prev) [ "$_t_page" -gt 1 ] && _t_page=$((_t_page - 1)); _target_render_list "$_t_page" "$message_id" ;;
            target_page_next) _t_page=$((_t_page + 1)); _target_render_list "$_t_page" "$message_id" ;;
            target_sel_*)
                local _num="${callback_data#target_sel_}"; local _mac=$(sed -n "${_num}p" /tmp/telegram_bot/target/all_macs 2>/dev/null)
                if [ -n "$_mac" ]; then rm -f /tmp/telegram_bot/target/temp_name /tmp/telegram_bot/target/temp_status; _target_render_detail "$_mac" "$message_id"; fi ;;
            target_toggle)
                local _cur_status=$(cat /tmp/telegram_bot/target/temp_status 2>/dev/null)
                [ "$_cur_status" = "1" ] && echo "0" > /tmp/telegram_bot/target/temp_status || echo "1" > /tmp/telegram_bot/target/temp_status
                _target_render_detail "$(cat /tmp/telegram_bot/target/current_mac)" "$message_id" ;;
            target_rename)
                echo "1" > /tmp/telegram_bot/target/rename_mode
                local _prompt="✏️ <b>Введите новое имя:</b>"; local _kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"target_cancel_rename"}]]}'
                local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$_prompt" -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" 2>&1)
                local _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_mid" ] && echo "$_mid" > /tmp/telegram_bot/target/rename_prompt_msg_id ;;
            target_cancel_rename)
                rm -f /tmp/telegram_bot/target/rename_mode
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
                if [ -f "/tmp/telegram_bot/target/error_msg_id" ]; then local _emsg=$(cat /tmp/telegram_bot/target/error_msg_id 2>/dev/null); [ -n "$_emsg" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_emsg" >/dev/null 2>&1; rm -f /tmp/telegram_bot/target/error_msg_id; fi
                if [ -f "/tmp/telegram_bot/target/rename_prompt_msg_id" ]; then local _pmsg=$(cat /tmp/telegram_bot/target/rename_prompt_msg_id 2>/dev/null); [ -n "$_pmsg" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pmsg" >/dev/null 2>&1; rm -f /tmp/telegram_bot/target/rename_prompt_msg_id; fi
                _target_render_detail "$(cat /tmp/telegram_bot/target/current_mac)" "" ;;
            target_back) _target_render_list "$_t_page" "$message_id" ;;
            target_save)
                local _mac=$(cat /tmp/telegram_bot/target/current_mac 2>/dev/null); local _name=$(cat /tmp/telegram_bot/target/temp_name 2>/dev/null); local _status=$(cat /tmp/telegram_bot/target/temp_status 2>/dev/null); local tf="/etc/telegram_bot/data/.target_device.conf"
                if [ "$_status" = "1" ]; then
                    if [ -f "$tf" ]; then grep -vi "^${_mac}|" "$tf" > "${tf}.tmp" 2>/dev/null; mv "${tf}.tmp" "$tf"; fi
                    echo "${_mac}|${_name}" >> "$tf"
                else if [ -f "$tf" ]; then grep -vi "^${_mac}|" "$tf" > "${tf}.tmp" 2>/dev/null; mv "${tf}.tmp" "$tf"; fi; fi
                rm -f /tmp/telegram_bot/target/temp_name /tmp/telegram_bot/target/temp_status
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Изменения сохранены" >/dev/null 2>&1
                _target_render_list "$_t_page" "$message_id" ;;
        esac
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1
        return
    fi
	
    if [[ "$callback_data" == mute_* ]]; then
        case "$callback_data" in
            mute_add)
                rm -f "$_MUTE_STATE_DEL_OPEN"; touch "$_MUTE_STATE_ADD_MODE"
                [ -n "$message_id" ] && echo "$message_id" > "$_MUTE_MSG_ID"
                if [ -f "$_MUTE_PROMPT_MSG_ID" ]; then _pid=$(cat "$_MUTE_PROMPT_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1; fi
                if [ -f "$_MUTE_ERROR_MSG_ID" ]; then _eid=$(cat "$_MUTE_ERROR_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_eid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1; fi
                local _presp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✏️ Введите слово или фразу для блока.
(латиница, цифры и спецсимв., 3-128 симв.)" -d parse_mode="HTML" --data-urlencode "reply_markup={\"inline_keyboard\":[[{\"text\":\"🔙 Отмена\",\"callback_data\":\"mute_cancel\"}]]}" 2>&1)
                local _pmid=$(echo "$_presp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_pmid" ] && echo "$_pmid" > "$_MUTE_PROMPT_MSG_ID" ;;
            mute_del_toggle)
                if [ -f "$_MUTE_STATE_DEL_OPEN" ]; then rm -f "$_MUTE_STATE_DEL_OPEN"; else touch "$_MUTE_STATE_DEL_OPEN"; fi
                show_mute_menu "$message_id" ;;
            mute_del_*)
                local _num="${callback_data#mute_del_}"; local _file="/etc/telegram_bot/data/.event_mute_list"
                local _patterns=$(grep -vE '^\s*(#|$)' "$_file" 2>/dev/null); local _new_patterns=$(echo "$_patterns" | sed "${_num}d")
                cat > "$_file" <<'MUTE_EOF'
# ──────────────────────────────────────────────────────────
# Игнорируемые события event_monitor
# ──────────────────────────────────────────────────────────
# Формат: один regex на строку.
# Строки, начинающиеся с # — комментарии.

MUTE_EOF
                if [ -n "$_new_patterns" ]; then echo "$_new_patterns" >> "$_file"; fi
                show_mute_menu "$message_id" ;;
            mute_clear)
                local _msg="<pre>⚠️ Вы действительно хотите удалить ВСЕ паттерны?</pre>"
                local _kb='{"inline_keyboard":[[{"text":"✅ Да, удалить все","callback_data":"mute_clear_confirm"},{"text":"❌ Отмена","callback_data":"mute_clear_cancel"}]]}'
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$_msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" >/dev/null 2>&1 ;;
            mute_clear_confirm)
                cat > "$_EVENT_MUTE_FILE" <<'MUTE_EOF'
# ──────────────────────────────────────────────────────────
# Игнорируемые события event_monitor
# ──────────────────────────────────────────────────────────
MUTE_EOF
                chmod 600 "$_EVENT_MUTE_FILE"; rm -f "$_MUTE_STATE_DEL_OPEN"; show_mute_menu "$message_id" ;;
            mute_clear_cancel) show_mute_menu "$message_id" ;;
            mute_cancel)
                rm -f "$_MUTE_STATE_ADD_MODE"
                if [ -f "$_MUTE_PROMPT_MSG_ID" ]; then _pid=$(cat "$_MUTE_PROMPT_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_pid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1; rm -f "$_MUTE_PROMPT_MSG_ID"; fi
                if [ -f "$_MUTE_ERROR_MSG_ID" ]; then _eid=$(cat "$_MUTE_ERROR_MSG_ID" 2>/dev/null | tr -d '\n\r '); [ -n "$_eid" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_eid" >/dev/null 2>&1; rm -f "$_MUTE_ERROR_MSG_ID"; fi
                local _menu_id=""; [ -f "$_MUTE_MSG_ID" ] && _menu_id=$(cat "$_MUTE_MSG_ID" 2>/dev/null | tr -d '\n\r ')
                show_mute_menu "$_menu_id" ;;
            mute_close)
                rm -f "$_MUTE_STATE_DEL_OPEN" "$_MUTE_MSG_ID" "$_MUTE_STATE_ADD_MODE" "$_MUTE_PROMPT_MSG_ID" "$_MUTE_ERROR_MSG_ID"
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" >/dev/null 2>&1
                send_menu ;;
        esac
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1
        return
    fi

    if [[ "$callback_data" == expl_* ]]; then
        if [ "$callback_data" != "expl_return_from_exec" ]; then
            local _expected_mid=""
            case "$callback_data" in
                expl_upload_back|expl_upload_tofile) _expected_mid=$(cat /tmp/telegram_bot/explorer/upload_result_msg_id 2>/dev/null | tr -d '\n\r ') ;;
                expl_upload_cancel) _expected_mid=$(cat /tmp/telegram_bot/explorer/upload_prompt_msg_id 2>/dev/null | tr -d '\n\r ') ;;
                *) _expected_mid=$(cat /tmp/telegram_bot/explorer/msg_id 2>/dev/null | tr -d '\n\r ') ;;
            esac
            if [ -z "$_expected_mid" ] || [ "$_expected_mid" != "$message_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
                return
            fi
        fi
        _bot_mark_busy_start "explorer"; _expl_handle_callback "$callback_data" "$callback_id" "$message_id" "$chat_id"; _bot_mark_busy_end
        return
    fi

    _clear_previous_error

    if [[ "$callback_data" == wifi_* ]] && [[ ! -f "/tmp/telegram_bot/wifi/active.lock" ]]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
        return
    fi
  
  if [[ "$callback_data" == wifi_* ]]; then
        if [ -n "$message_id" ]; then
            case "$callback_data" in
                wifi_cancel_edit|wifi_show_password_toggle|wifi_sta_retry_password) : ;;
                *) echo "$message_id" > "$WIFI_MSG_ID_FILE" ;;
            esac
        fi
        handle_wifi_callback "$callback_data" "$callback_id" "$message_id" "$chat_id"; return
    fi

    if [ "$callback_data" = "speed_set_continue" ]; then
        rm -f /tmp/telegram_bot/speed/set_msg_id
        local _mac=$(cat /tmp/telegram_bot/speed/last_mac 2>/dev/null | tr -d '\n\r '); local _name=$(cat /tmp/telegram_bot/speed/last_name 2>/dev/null | tr -d '\n\r ')
        rm -f /tmp/telegram_bot/speed/last_mac /tmp/telegram_bot/speed/last_name
        if [ -n "$_mac" ]; then
            _update_speed_state "device_selected" "$_mac" "$_name" "" "" "" "" "" "" 127 "false" "false"
            echo "$message_id" > /tmp/telegram_bot/speed/limit_msg_id; SPEED_MSG_ID="$message_id"
            show_device_limits "$_mac" "$_name"
        else send_message "⚠️ Устройство не найдено. Откройте меню заново."; send_menu; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "speed_remove_continue" ]; then
        rm -f /tmp/telegram_bot/speed/remove_msg_id
        echo "$message_id" > /tmp/telegram_bot/speed/msg_id; SPEED_MSG_ID="$message_id"
        show_device_list
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "close_to_menu" ]; then
        for _f in /tmp/telegram_bot/speed/set_msg_id /tmp/telegram_bot/speed/remove_msg_id; do
            if [ -f "$_f" ]; then _m=$(cat "$_f" 2>/dev/null); [ -n "$_m" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_m" > /dev/null 2>&1; rm -f "$_f"; fi
        done
        rm -f /tmp/telegram_bot/speed/last_mac /tmp/telegram_bot/speed/last_name
        rm -f "$SPEED_DEVICE_LIST" "/tmp/telegram_bot/speed/state.json"
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🕒 Ограничение скорости закрыто" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "nl_static_edit_name" ]; then
        local _cur_name=$(cat "$ONLINE_STATIC_NAME_FILE" 2>/dev/null); echo "name" > "$ONLINE_STATIC_INPUT_FILE"
        _render_static_input_prompt "name" "$_cur_name"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "nl_static_edit_ip" ]; then
        local _cur_ip=$(cat "$ONLINE_STATIC_IP_FILE" 2>/dev/null); echo "ip" > "$ONLINE_STATIC_INPUT_FILE"
        _render_static_input_prompt "ip" "$_cur_ip"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "nl_static_save" ]; then
        local _mac=$(cat "$ONLINE_STATIC_MAC_FILE" 2>/dev/null); local _name=$(cat "$ONLINE_STATIC_NAME_FILE" 2>/dev/null); local _ip=$(cat "$ONLINE_STATIC_IP_FILE" 2>/dev/null)
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⏳ Сохранение настроек, ожидайте..." -d show_alert="false" > /dev/null 2>&1
        _bot_mark_busy_start "static_ip"
        local _err=$( ( . /etc/telegram_bot/notify.sh 2>/dev/null; _nl_save_static_ip "$_mac" "$_name" "$_ip" ) 2>&1 ); local _rc=$?
        _bot_mark_busy_end
        if [ "$_rc" != "0" ]; then local _e_esc=$(html_escape "$_err"); send_message "❌ <b>Ошибка сохранения</b>

${_e_esc}"; return; fi
        rm -f "$ONLINE_STATIC_MAC_FILE" "$ONLINE_STATIC_NAME_FILE" "$ONLINE_STATIC_IP_FILE" "$ONLINE_STATIC_ORIG_NAME_FILE" "$ONLINE_STATIC_ORIG_IP_FILE" "$ONLINE_STATIC_INPUT_FILE"
        echo "none" > /tmp/telegram_bot/online/state
        _render_online_message "$message_id"
        return
    fi

    if [ "$callback_data" = "nl_static_cancel" ]; then
        rm -f "$ONLINE_STATIC_MAC_FILE" "$ONLINE_STATIC_NAME_FILE" "$ONLINE_STATIC_IP_FILE" "$ONLINE_STATIC_ORIG_NAME_FILE" "$ONLINE_STATIC_ORIG_IP_FILE" "$ONLINE_STATIC_INPUT_FILE"
        _cleanup_static_input_prompt; _cleanup_static_input_error; _cleanup_static_invalid_inputs
        echo "none" > /tmp/telegram_bot/online/state
        _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "nl_input_cancel" ]; then
        rm -f "$ONLINE_STATIC_INPUT_FILE"
        _cleanup_static_input_prompt; _cleanup_static_input_error; _cleanup_static_invalid_inputs
        _render_static_edit
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_refresh" ]; then
        _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_cancel" ]; then
        _cleanup_static_input_prompt; _cleanup_static_input_error
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
        rm -f "$ONLINE_MSG_ID_FILE" /tmp/telegram_bot/online/state /tmp/telegram_bot/online/last_devices /tmp/telegram_bot/online/blocked_macs /tmp/telegram_bot/online/page /tmp/telegram_bot/online/total_pages
        ONLINE_MSG_ID=""; send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🖥️ Клиенты онлайн закрыты" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_toggle_fixip" ]; then
        local cur=$(cat /tmp/telegram_bot/online/state 2>/dev/null)
        if [ "$cur" = "fixip" ]; then echo "none" > /tmp/telegram_bot/online/state; else echo "fixip" > /tmp/telegram_bot/online/state; fi
        _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_toggle_wifi" ]; then
        local cur=$(cat /tmp/telegram_bot/online/state 2>/dev/null)
        if [ "$cur" = "wifi" ]; then echo "none" > /tmp/telegram_bot/online/state
        else
            if [ ! -s /tmp/telegram_bot/online/wifi_macs ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="Нет Wi-Fi устройств" > /dev/null 2>&1; return; fi
            echo "wifi" > /tmp/telegram_bot/online/state
        fi
        _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_toggle_block" ]; then
        local cur=$(cat /tmp/telegram_bot/online/state 2>/dev/null)
        if [ "$cur" = "block" ]; then echo "none" > /tmp/telegram_bot/online/state; else echo "block" > /tmp/telegram_bot/online/state; fi
        _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_toggle_unblock" ]; then
        local cur=$(cat /tmp/telegram_bot/online/state 2>/dev/null)
        if [ "$cur" = "unblock" ]; then
            echo "none" > /tmp/telegram_bot/online/state; _render_online_message "$message_id"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        fi
        if ! _online_has_blocked_macs; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="Нет заблокированных устройств" > /dev/null 2>&1; return; fi
        echo "unblock" > /tmp/telegram_bot/online/state; _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_page_prev" ]; then
        local page=$(cat /tmp/telegram_bot/online/page 2>/dev/null); case "$page" in ''|*[!0-9]*) page=1 ;; esac; [ "$page" -gt 1 ] && page=$((page - 1))
        echo "$page" > /tmp/telegram_bot/online/page; _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_page_next" ]; then
        local page=$(cat /tmp/telegram_bot/online/page 2>/dev/null); case "$page" in ''|*[!0-9]*) page=1 ;; esac; local total_pages=$(cat /tmp/telegram_bot/online/total_pages 2>/dev/null); case "$total_pages" in ''|*[!0-9]*) total_pages=1 ;; esac
        [ "$page" -lt "$total_pages" ] && page=$((page + 1)); echo "$page" > /tmp/telegram_bot/online/page
        sleep 2; _render_online_message "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "online_page_info" ]; then
        local page=$(cat /tmp/telegram_bot/online/page 2>/dev/null); case "$page" in ''|*[!0-9]*) page=1 ;; esac; local total_pages=$(cat /tmp/telegram_bot/online/total_pages 2>/dev/null); case "$total_pages" in ''|*[!0-9]*) total_pages=1 ;; esac
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📄 Страница $page из $total_pages" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^online_fixip_([0-9]+)$ ]]; then
        local num="${BASH_REMATCH[1]}"; local mac=$(awk -F'|' -v n="$num" '$1 == n {print $2; exit}' /tmp/telegram_bot/online/last_devices 2>/dev/null)
        if [ -z "$mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не найдено" > /dev/null 2>&1; return; fi
        local cur_name=$(bash -c '. /etc/telegram_bot/notify.sh 2>/dev/null; _nl_get_name "'"$mac"'"' 2>/dev/null); local cur_ip=$(bash -c '. /etc/telegram_bot/notify.sh 2>/dev/null; _nl_get_ip "'"$mac"'"' 2>/dev/null)
        [ -z "$cur_name" ] && cur_name="$mac"; [ -z "$cur_ip" ] && cur_ip="N/A"
        echo "$mac" > "$ONLINE_STATIC_MAC_FILE"; echo "$cur_name" > "$ONLINE_STATIC_NAME_FILE"; echo "$cur_ip" > "$ONLINE_STATIC_IP_FILE"
        echo "$cur_name" > "$ONLINE_STATIC_ORIG_NAME_FILE"; echo "$cur_ip" > "$ONLINE_STATIC_ORIG_IP_FILE"
        rm -f "$ONLINE_STATIC_INPUT_FILE" "$ONLINE_STATIC_ORIG_NAME_FILE.input"
        echo "fixip_edit" > /tmp/telegram_bot/online/state
        _render_static_edit
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^online_wifi_([0-9]+)$ ]]; then
        local num="${BASH_REMATCH[1]}"; local mac=$(awk -F'|' -v n="$num" '$1 == n {print $2; exit}' /tmp/telegram_bot/online/last_devices 2>/dev/null)
        if [ -z "$mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не найдено" > /dev/null 2>&1; return; fi
        local iface=""; local _i
        for _i in phy0-ap0 phy0-ap1 phy1-ap0 phy1-ap1; do
            if iw dev "$_i" station dump 2>/dev/null | grep -qi "$mac"; then iface="$_i"; break; fi
        done
        if [ -z "$iface" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не в Wi-Fi" > /dev/null 2>&1; return; fi
        hostapd_cli -i "$iface" deauthenticate "$mac" >/dev/null 2>&1
        local mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=WiFi сброшен для 🔗 $mac_lc" -d show_alert="false" > /dev/null 2>&1
        ( exec 200>&- 2>/dev/null; sleep 5; _render_online_message "$message_id" ) </dev/null >/dev/null 2>&1 200<&- &
        return
    fi

    if [[ "$callback_data" =~ ^online_blk_([0-9]+)$ ]]; then
        local num="${BASH_REMATCH[1]}"; local mac=$(awk -F'|' -v n="$num" '$1 == n {print $2; exit}' /tmp/telegram_bot/online/last_devices 2>/dev/null)
        if [ -z "$mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не найдено" > /dev/null 2>&1; return; fi
        /etc/telegram_bot/notify.sh block_mac "$mac" > /dev/null 2>&1; local _blk_rc=$?; local _answer=""
        case "$_blk_rc" in 0) _answer="🚫 Заблокирован: $mac" ;; 2) _answer="⚠️ MAC не в белом списке — уже без доступа" ;; *) _answer="⚠️ Ошибка блокировки" ;; esac
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=$_answer" > /dev/null 2>&1
        ( sleep 3; _render_online_message "$message_id" ) </dev/null >/dev/null 2>&1 200<&- &
        return
    fi

    if [[ "$callback_data" =~ ^online_unblk_([0-9]+)$ ]]; then
        local num="${BASH_REMATCH[1]}"; local mac=$(awk -F'|' -v n="$num" '$1 == n {print $2; exit}' /tmp/telegram_bot/online/last_devices 2>/dev/null)
        if [ -z "$mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не найдено" > /dev/null 2>&1; return; fi
        /etc/telegram_bot/notify.sh unblock_mac "$mac" > /dev/null 2>&1; local _unblk_rc=$?
        if ! _online_has_blocked_macs; then echo "none" > /tmp/telegram_bot/online/state; fi
        local _answer=""; case "$_unblk_rc" in 0) _answer="✅ Разблокирован: $mac" ;; *) _answer="⚠️ Ошибка разблокировки" ;; esac
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=$_answer" > /dev/null 2>&1
        ( sleep 5; _render_online_message "$message_id" ) </dev/null >/dev/null 2>&1 200<&- &
        return
    fi

    if [ "$callback_data" = "refresh_devices" ]; then
        show_device_list
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ -f "$SPEED_DEVICE_LIST" ] && [ ! -f "/tmp/telegram_bot/speed/state.json" ]; then
        case "$callback_data" in
            cancel|close_to_menu)
                rm -f "$SPEED_DEVICE_LIST"; reset_device_selection
                if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
                send_menu; rm -f /tmp/telegram_bot/speed/msg_id
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🕒 Ограничение скорости закрыто" > /dev/null 2>&1
                return ;;
            select_*|refresh_devices) : ;;
        esac
    fi

    if [[ "$callback_data" =~ ^svc_ ]]; then
        local _svc_cur_id=""; [ -f /tmp/telegram_bot/services/msg_id ] && _svc_cur_id=$(cat /tmp/telegram_bot/services/msg_id 2>/dev/null | tr -d '\n\r ')
        if [ -z "$_svc_cur_id" ] || [ "$_svc_cur_id" != "$message_id" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1
            return
        fi
    fi
	
    if [[ "$callback_data" =~ ^svc_select_([0-9]+)$ ]]; then
        local num="${BASH_REMATCH[1]}"; local selected_json=$(_services_get_selected); local selected=$(echo "$selected_json" | jq -c '.')
        if echo "$selected" | jq -e ".[] | select(. == $num)" >/dev/null 2>&1; then selected=$(echo "$selected" | jq "del(.[] | select(. == $num))")
        else selected=$(echo "$selected" | jq ". + [$num]"); fi
        _services_set_selected "$selected"
        if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi
	
    if [ "$callback_data" = "svc_page_prev" ] || [ "$callback_data" = "svc_page_next" ] || [ "$callback_data" = "svc_page_info" ]; then
        if [ "$callback_data" = "svc_page_info" ]; then
            local current_page=$(_services_get_page); local list_json=$(_services_get_cached_list); local total=$(echo "$list_json" | jq '. | length'); local page_size=15; local total_pages=$(( (total + page_size - 1) / page_size ))
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📄 Страница $current_page из $total_pages" > /dev/null 2>&1
            return
        fi
        local current_page=$(_services_get_page); local list_json=$(_services_get_cached_list); local total=$(echo "$list_json" | jq '. | length'); local page_size=15; local total_pages=$(( (total + page_size - 1) / page_size ))
        if [ "$callback_data" = "svc_page_prev" ] && [ "$current_page" -gt 1 ]; then current_page=$((current_page - 1))
        elif [ "$callback_data" = "svc_page_next" ] && [ "$current_page" -lt "$total_pages" ]; then current_page=$((current_page + 1))
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Уже на крайней странице" > /dev/null 2>&1; return; fi
        _services_set_page "$current_page"
        if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^svc_(start|stop|restart|reload|toggle|refresh|back|cancel|reset_selection)$ ]]; then
        local action="${BASH_REMATCH[1]}"
        if [ "$action" = "reset_selection" ]; then
            _services_set_selected "[]"
            if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Выбор сброшен" > /dev/null 2>&1
            return
        fi

        if [ "$action" = "start" ] || [ "$action" = "stop" ] || [ "$action" = "restart" ] || [ "$action" = "reload" ] || [ "$action" = "toggle" ]; then
            local selected_json=$(_services_get_selected); local selected_nums=$(echo "$selected_json" | jq -r '.[]')
            if [ -z "$selected_nums" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Не выбрано ни одной службы" > /dev/null 2>&1; return; fi
            local list_json=$(_services_get_cached_list); local names=(); local first_name=""
            for num in $selected_nums; do
                local name=$(echo "$list_json" | jq -r ".[$((num-1))].name // \"\"")
                if [ -n "$name" ]; then names+=("$name"); [ -z "$first_name" ] && first_name="$name"; fi
            done
            if [ ${#names[@]} -eq 0 ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Выбранные службы не найдены" > /dev/null 2>&1; return; fi
            local results=""; local cmd=""

            if [ "$action" = "stop" ]; then
                for name in "${names[@]}"; do
                    /etc/init.d/"$name" stop 2>&1
                    if [ "$name" = "zram" ]; then swapoff /dev/zram0 2>/dev/null; swapoff /dev/zram1 2>/dev/null; fi
                    sleep 1
                    if pgrep -f "$name" >/dev/null 2>&1; then
                        pkill -9 -f "$name" 2>/dev/null
                        if command -v killall >/dev/null 2>&1; then killall -9 "$name" 2>/dev/null; fi
                        results="${results}⚠️ $name: остановлен принудительно (pkill/killall)\n"
                    else results="${results}✅ $name: остановлен\n"; fi
                done
                _services_invalidate_cache; rm -f /tmp/telegram_bot/services/list.json; _services_get_cached_list > /dev/null 2>&1
                if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
                if [ ${#names[@]} -eq 1 ]; then local popup_text="✅ $first_name остановлен"; else local popup_text="✅ ${#names[@]} служб остановлены"; fi
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="$popup_text" > /dev/null 2>&1
                return
            fi

            if [ "$action" = "toggle" ]; then
                for name in "${names[@]}"; do
                    local enabled=$(/etc/init.d/"$name" enabled 2>/dev/null && echo "yes" || echo "no")
                    if [ "$enabled" = "yes" ]; then
                        /etc/init.d/"$name" disable 2>&1
                        if [ $? -eq 0 ]; then results="${results}✅ $name: автозапуск отключён\n"; else results="${results}❌ $name: ошибка отключения\n"; fi
                    else
                        /etc/init.d/"$name" enable 2>&1
                        if [ $? -eq 0 ]; then results="${results}✅ $name: автозапуск включён\n"; else results="${results}❌ $name: ошибка включения\n"; fi
                    fi
                done
                _services_invalidate_cache; rm -f /tmp/telegram_bot/services/list.json
                if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
                if [ ${#names[@]} -eq 1 ]; then local popup_text="✅ Автозапуск переключён для $first_name"; else local popup_text="✅ Автозапуск переключён для ${#names[@]} служб"; fi
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="$popup_text" > /dev/null 2>&1
                return
            fi

            case "$action" in start) cmd="start" ;; restart) cmd="restart" ;; reload) cmd="reload" ;; esac
            _bot_mark_busy_start "services"
            for name in "${names[@]}"; do
                local output=$(/etc/init.d/"$name" "$cmd" 2>&1); local status=$?
                if [ "$status" -eq 0 ]; then results="${results}✅ $name: $cmd успешно\n"
                else results="${results}❌ $name: $cmd ошибка (код $status)\n$output\n"; fi
            done
            _bot_mark_busy_end; _services_invalidate_cache; rm -f /tmp/telegram_bot/services/list.json

            local ok_count=0; local fail_count=0; local failed_names=""; local _r
            while IFS= read -r _r; do
                case "$_r" in
                    "✅ "*) ok_count=$((ok_count + 1)) ;;
                    "❌ "*) fail_count=$((fail_count + 1)); local _fn="${_r#❌ }"; _fn="${_fn%%:*}"; failed_names="${failed_names}${_fn}, " ;;
                esac
            done <<< "$results"
            failed_names="${failed_names%, }"

            local popup_text=""
            if [ "$fail_count" -eq 0 ]; then
                if [ ${#names[@]} -eq 1 ]; then popup_text="✅ $first_name: $cmd выполнен"; else popup_text="✅ $cmd: $ok_count ok"; fi
            elif [ "$ok_count" -eq 0 ]; then
                if [ "$fail_count" -eq 1 ]; then popup_text="❌ $cmd: $failed_names упала"; else popup_text="❌ $cmd: все $fail_count упали: $failed_names"; fi
            else popup_text="⚠️ $cmd: $ok_count ok, $fail_count ошибок: $failed_names"; fi

            SERVICES_LAST_RESULT="$results"; SERVICES_LAST_CMD="$cmd"
            if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="$popup_text" > /dev/null 2>&1
            return
        fi

        if [ "$action" = "refresh" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Обновляю список служб..." > /dev/null 2>&1
            _bot_mark_busy_start "services_refresh"; _services_invalidate_cache; rm -f /tmp/telegram_bot/services/list.json
            if [ -n "$SERVICES_MSG_ID" ]; then show_services "$SERVICES_MSG_ID"; else show_services; fi
            _bot_mark_busy_end
            return
        fi

        if [ "$action" = "back" ] || [ "$action" = "cancel" ]; then
            set_services_mode "0"; _services_set_selected "[]"; _services_set_page "1"; rm -f /tmp/telegram_bot/services/list.json
            if [ -n "$SERVICES_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SERVICES_MSG_ID" > /dev/null 2>&1; _services_set_msg_id ""; rm -f /tmp/telegram_bot/services/msg_id; fi
            rm -f "$SERVICES_LAST_ACTIVITY_FILE"; send_menu
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🔧 Управление Автозапуском закрыто" > /dev/null 2>&1
            return
        fi
    fi

    # --- WOL Callbacks ---
    if [[ "$callback_data" == wol_sel_* ]]; then
        local num="${callback_data#wol_sel_}"; local devices=$(_wol_get_lan_devices); local mac=$(echo "$devices" | awk -F'|' -v n="$num" '$1==n {print $3}')
        if [ -n "$mac" ]; then
            local selected_mac=$(uci -q get telegram_bot.wol.mac 2>/dev/null)
            if [ "$mac" = "$selected_mac" ]; then 
                uci -q delete telegram_bot.wol
            else
                local name=$(echo "$devices" | awk -F'|' -v n="$num" '$1==n {print $2}')
                uci set telegram_bot.wol=wol
                uci set telegram_bot.wol.name="$name"
                uci set telegram_bot.wol.mac="$mac"
            fi
            uci commit telegram_bot
            show_wol_menu "$message_id"
        fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "wol_del_toggle" ]; then
        touch /tmp/telegram_bot/wol/delete_mode; show_wol_menu "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="Удалить введенное вручную устройство" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "wol_del_cancel" ]; then
        rm -f /tmp/telegram_bot/wol/delete_mode; show_wol_menu "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" == wol_del_* ]]; then
        local num="${callback_data#wol_del_}"; local count=1; local del_mac=""; local del_name=""
        local m_sec
        for m_sec in $(uci show telegram_bot | grep "=wol_manual$" | cut -d. -f2 | cut -d= -f1); do
            if [ "$count" -eq "$num" ]; then
                del_mac=$(uci -q get "telegram_bot.$m_sec.mac")
                del_name=$(uci -q get "telegram_bot.$m_sec.name")
                uci delete "telegram_bot.$m_sec"
                break
            fi
            count=$((count+1))
        done
        if [ -n "$del_mac" ]; then
            local selected_mac=$(uci -q get telegram_bot.wol.mac 2>/dev/null)
            if [ "$selected_mac" = "$del_mac" ]; then uci -q delete telegram_bot.wol; fi
            uci commit telegram_bot
        fi
        show_wol_menu "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Удалено: ${del_name:-$del_mac}" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "wol_manual" ]; then
        echo "wol_name" > /tmp/telegram_bot/wol/setup_mode
        local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wol_cancel_setup"}]]}'
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✏️ Введите имя устройства:" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
        local prompt_id=$(echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$prompt_id" ] && echo "$prompt_id" > "$WIFI_EDIT_MSG_ID_FILE"
        _update_activity "$WOL_LAST_ACTIVITY_FILE"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "wol_wake" ]; then
        local selected_mac=$(uci -q get telegram_bot.wol.mac 2>/dev/null)
        if [ -z "$selected_mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Сначала выберите устройство из списка" -d show_alert="true" > /dev/null 2>&1; return; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        _bot_mark_busy_start "wake"; local result
        if command -v timeout >/dev/null 2>&1; then
            result=$(timeout 30 /etc/telegram_bot/notify.sh wake 2>&1); if [ $? -eq 124 ]; then result="⚠️ Команда 'Разбудить' превысила время ожидания"; fi
        else result=$(/etc/telegram_bot/notify.sh wake 2>&1); fi
        _bot_mark_busy_end
        local _kb='{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wol_back"},{"text":"❌ Закрыть","callback_data":"wol_cancel"}]]}'
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$result" -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" > /dev/null 2>&1
        echo "$message_id" > /tmp/telegram_bot/wol/msg_id
        return
    fi

    if [ "$callback_data" = "wol_back" ]; then
        show_wol_menu "$message_id"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi
	
    if [ "$callback_data" = "wol_cancel" ]; then
        local wol_msg_id=$(cat /tmp/telegram_bot/wol/msg_id 2>/dev/null)
        if [ -n "$wol_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$wol_msg_id" > /dev/null 2>&1; rm -f /tmp/telegram_bot/wol/msg_id; fi
        send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🌐 Wake-on-LAN закрыт" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "wol_cancel_setup" ]; then
        if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
        local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
        if [ -n "$prompt_id" ] && [ "$prompt_id" != "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" > /dev/null 2>&1; fi
        rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name; rm -f "$WIFI_EDIT_MSG_ID_FILE"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✏️ Ручной ввод отменен" > /dev/null 2>&1
        local _wol_msg_id=$(cat /tmp/telegram_bot/wol/msg_id 2>/dev/null); if [ -z "$_wol_msg_id" ]; then show_wol_menu; fi
        return
    fi

    # --- Back / Cancel / Reboot / Traffic / Critical / Speed Callbacks ---
    if [ "$callback_data" = "back" ]; then
        local state_file="/tmp/telegram_bot/speed/state.json"
        if [ ! -f "$state_file" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        local state
        if ! state=$(_get_speed_state); then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Ошибка состояния" > /dev/null 2>&1; return; fi
        local step=$(echo "$state" | jq -r '.step // ""'); local mac=$(echo "$state" | jq -r '.mac // ""'); local name=$(echo "$state" | jq -r '.name // ""')
        local rx_bytes=$(echo "$state" | jq -r '.rx_bytes // 0'); local rx_display=$(echo "$state" | jq -r '.rx_display // ""')
        local tx_bytes=$(echo "$state" | jq -r '.tx_bytes // 0'); local tx_display=$(echo "$state" | jq -r '.tx_display // ""')
        local manual=$(echo "$state" | jq -r '.manual // false'); local from_profile=$(echo "$state" | jq -r '.from_profile // false')
        if [ -z "$SPEED_MSG_ID" ] && [ -f "/tmp/telegram_bot/speed/msg_id" ]; then SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null); fi
        case "$step" in
            "choose_rx")
                if [ "$manual" = "true" ]; then
                    _update_speed_state "choose_rx" "$mac" "$name" "" "" "" "" "" "" 127 "false" "$from_profile"
                    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                    local msg=$(_build_device_table "$mac" "$name" "$ip" "" "" "" "" "✅ Вы выбрали устройство:" "🕒  ЗАДАЙТЕ ВХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "1")
                    _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                    SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к выбору скорости" > /dev/null 2>&1
                else
                    if [ "$from_profile" = "true" ]; then
                        _update_speed_state "device_selected" "$mac" "$name" "" "" "" "" "" "" 127 "false" "false"
                        show_device_limits "$mac" "$name"
                        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к профилям" > /dev/null 2>&1
                    else
                        local old_msg_id="$SPEED_MSG_ID"; if [ -z "$old_msg_id" ] && [ -f "/tmp/telegram_bot/speed/msg_id" ]; then old_msg_id=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null); fi
                        reset_device_selection; SPEED_MSG_ID="$old_msg_id"; show_device_list
                        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к списку устройств" > /dev/null 2>&1
                    fi
                fi
                return ;;
            "choose_tx")
                if [ "$manual" = "true" ]; then
                    _update_speed_state "choose_tx" "$mac" "$name" "$rx_bytes" "$rx_display" "" "" "" "" 127 "false" "$from_profile"
                    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                    local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "" "" "" "✅ Входящая скорость установлена: $rx_display" "🕒  ЗАДАЙТЕ ИСХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "2")
                    _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                    SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к выбору исходящей скорости" > /dev/null 2>&1
                else
                    _update_speed_state "choose_rx" "$mac" "$name" "$rx_bytes" "$rx_display" "" "" "" "" 127 "false" "$from_profile"
                    local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                    local msg=$(_build_device_table "$mac" "$name" "$ip" "" "" "" "" "✅ Вы выбрали устройство:" "🕒  ЗАДАЙТЕ ВХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "1")
                    _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                    SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к входящей скорости" > /dev/null 2>&1
                fi
                return ;;
            "choose_time")
                _update_speed_state "choose_tx" "$mac" "$name" "$rx_bytes" "$rx_display" "" "" "" "" 127 "false" "$from_profile"
                local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "" "" "" "✅ Входящая скорость установлена: $rx_display" "🕒  ЗАДАЙТЕ ИСХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "2")
                _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к исходящей скорости" > /dev/null 2>&1
                return ;;
            "choose_days"|"interval_input")
                local start_time=$(echo "$state" | jq -r '.start_time // ""'); local end_time=$(echo "$state" | jq -r '.end_time // ""')
                _update_speed_state "choose_time" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "$start_time" "$end_time" 127 "false" "$from_profile"
                local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                local time_display=""; if [ -n "$start_time" ] && [ -n "$end_time" ]; then time_display="${start_time} - ${end_time}"; fi
                local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "$time_display" "" "✅ Ограничения скорости установлены" "🕒 ЗАДАЙТЕ ВРЕМЯ ДЕЙСТВИЯ ЛИМИТА" "3")
                _send_and_save_id "$msg" "$(get_duration_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
                SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к выбору времени" > /dev/null 2>&1
                return ;;
            *)
                local old_msg_id="$SPEED_MSG_ID"; if [ -z "$old_msg_id" ] && [ -f "/tmp/telegram_bot/speed/msg_id" ]; then old_msg_id=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null); fi
                reset_device_selection; SPEED_MSG_ID="$old_msg_id"; show_device_list
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к списку устройств" > /dev/null 2>&1
                return ;;
        esac
    fi

    if [ "$callback_data" = "uninstall_confirm" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
        touch /etc/telegram_bot/.bot_disabled; chmod 600 /etc/telegram_bot/.bot_disabled
        if [ -x /etc/telegram_bot/uninstall_bot.sh ]; then
            if [ -n "$CURRENT_UPDATE_ID" ]; then echo "$CURRENT_UPDATE_ID" > "$LAST_UPDATE_FILE"; fi
            if command -v setsid >/dev/null 2>&1; then setsid /bin/bash /etc/telegram_bot/uninstall_bot.sh </dev/null >/dev/null 2>&1 200<&- &
            else /bin/bash /etc/telegram_bot/uninstall_bot.sh </dev/null >/dev/null 2>&1 200<&- & fi
        else
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="❌ <b>Ошибка:</b> uninstall_bot.sh не найден" -d parse_mode="HTML" > /dev/null 2>&1
            rm -f /etc/telegram_bot/.bot_disabled; return
        fi
        sleep 30; exit 0
    fi

    if [ "$callback_data" = "uninstall_cancel" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Отменено" > /dev/null 2>&1
        if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
        rm -f /tmp/telegram_bot/state/bot_uninstall_msg_id; send_menu; return
    fi

    if [ "$callback_data" = "disable_confirm" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        touch /etc/telegram_bot/.bot_disabled; chmod 600 /etc/telegram_bot/.bot_disabled
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="🛑 <b>Бот полностью отключён</b>

Для включения из консоли:
<code>rm /etc/telegram_bot/.bot_disabled</code>
<code>/etc/telegram_bot/restart_bot.sh</code>" -d parse_mode="HTML" --data-urlencode 'reply_markup={"remove_keyboard":true}' > /dev/null 2>&1
        if [ -n "$CURRENT_UPDATE_ID" ]; then echo "$CURRENT_UPDATE_ID" > "$LAST_UPDATE_FILE"; fi
        pkill -9 -f event_monitor.sh 2>/dev/null; pkill -9 -f watchdog.sh 2>/dev/null; pkill -9 -f restart_bot.sh 2>/dev/null
        sleep 1; pkill -9 -f telegram_bot.sh 2>/dev/null; exit 0
    fi

    if [ "$callback_data" = "disable_cancel" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Отменено" > /dev/null 2>&1
        if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
        rm -f /tmp/telegram_bot/state/bot_disable_msg_id; send_menu; return
    fi

    if [ "$callback_data" = "cancel" ]; then
        local state_file="/tmp/telegram_bot/speed/state.json"
        if [ ! -f "$state_file" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
        rm -f /tmp/telegram_bot/speed/msg_id /tmp/telegram_bot/speed/limit_selected_uuid
        _speed_cleanup_user_msgs; reset_device_selection; send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=🕒 Ограничение скорости закрыто" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "reboot_confirm" ]; then
        local reboot_stored_id=""; [ -f "$REBOOT_MSG_ID_FILE" ] && reboot_stored_id=$(cat "$REBOOT_MSG_ID_FILE" 2>/dev/null)
        if [ -z "$reboot_stored_id" ] || [ "$reboot_stored_id" != "$message_id" ] || ! _check_activity_timeout "$REBOOT_LAST_ACTIVITY_FILE" 600; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Команда устарела, запросите перезагрузку заново" -d show_alert="true" > /dev/null 2>&1
            rm -f "$REBOOT_MSG_ID_FILE" "$REBOOT_LAST_ACTIVITY_FILE"; return
        fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
        rm -f "$REBOOT_MSG_ID_FILE" "$REBOOT_LAST_ACTIVITY_FILE"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Перезагрузка..." > /dev/null 2>&1
        /etc/telegram_bot/notify.sh reboot_now; reset_device_selection
        return
    fi

    if [ "$callback_data" = "reboot_cancel" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
        rm -f "$REBOOT_MSG_ID_FILE" "$REBOOT_LAST_ACTIVITY_FILE"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Перезагрузка отменена" > /dev/null 2>&1
        send_menu; reset_device_selection; return
    fi

    if [[ "$callback_data" =~ ^traffic_(day|week|month|quarter)$ ]]; then
        local period="${BASH_REMATCH[1]}"; echo "$period" > /tmp/telegram_bot/traffic/active_period
        local traffic_data=""
        _bot_mark_busy_start "traffic"
        if command -v timeout >/dev/null 2>&1; then
            traffic_data=$(timeout 30 /etc/telegram_bot/notify.sh traffic "$period" 2>&1); if [ $? -eq 124 ]; then traffic_data="⚠️ Команда 'Трафик' превысила время ожидания."; fi
        else traffic_data=$(/etc/telegram_bot/notify.sh traffic "$period" 2>&1); fi
        _bot_mark_busy_end
        local keyboard=$(get_traffic_period_keyboard "$period")
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$traffic_data" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" > /dev/null 2>&1
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "traffic_refresh" ]; then
        local period=$(cat /tmp/telegram_bot/traffic/active_period 2>/dev/null); [ -z "$period" ] && period="day"
        local traffic_data=""
        _bot_mark_busy_start "traffic"
        if command -v timeout >/dev/null 2>&1; then
            traffic_data=$(timeout 30 /etc/telegram_bot/notify.sh traffic "$period" 2>&1); if [ $? -eq 124 ]; then traffic_data="⚠️ Команда 'Трафик' превысила время ожидания."; fi
        else traffic_data=$(/etc/telegram_bot/notify.sh traffic "$period" 2>&1); fi
        _bot_mark_busy_end
        local keyboard=$(get_traffic_period_keyboard "$period")
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$traffic_data" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" > /dev/null 2>&1
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="🔄 Обновлено" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "traffic_cancel" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
        rm -f "$TRAFFIC_MSG_ID_FILE" /tmp/telegram_bot/traffic/active_period
        TRAFFIC_MSG_ID=""; send_menu
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=📊 Трафик закрыт" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^critical_ ]]; then
        local action=""; local param=""
        case "$callback_data" in
            critical_filter_menu) action="filter_menu" ;;
            critical_filter_apply_critical) action="filter_apply"; param="critical" ;;
            critical_filter_apply_error)    action="filter_apply"; param="error" ;;
            critical_filter_apply_warn)     action="filter_apply"; param="warn" ;;
            critical_filter_apply_net)      action="filter_apply"; param="net" ;;
            critical_filter_apply_wifi)     action="filter_apply"; param="wifi" ;;
            critical_filter_apply_system)   action="filter_apply"; param="system" ;;
            critical_filter_reset) action="filter_reset" ;;
            critical_filter_back) action="filter_back" ;;
            critical_page_prev) action="page"; param="prev" ;;
            critical_page_next) action="page"; param="next" ;;
            critical_page_info)
                local state_file="/tmp/telegram_bot/critical/state/state_${CHAT_ID}.txt"; local page=""
                if [ -f "$state_file" ]; then page=$(head -1 "$state_file" 2>/dev/null); fi
                [ -z "$page" ] && page="?"
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="📄 Вы находитесь на странице $page" > /dev/null 2>&1
                return ;;
            critical_refresh) action="refresh" ;;	
            critical_cancel)
                local crit_msg_id=$(cat /tmp/telegram_bot/critical/msg_id 2>/dev/null)
                if [ -n "$crit_msg_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$crit_msg_id" > /dev/null 2>&1; rm -f /tmp/telegram_bot/critical/msg_id; fi
                if [ -n "$message_id" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1; fi
                rm -f "/tmp/telegram_bot/critical/state/state_${CHAT_ID}.txt"; send_menu
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=📋 Журнал событий закрыт" > /dev/null 2>&1
                return ;;
        esac
        case "$callback_data" in critical_filter_apply_*|critical_filter_reset|critical_filter_back|critical_page_prev|critical_page_next) rm -f /tmp/telegram_bot/critical/dl_menu_open ;; esac
        if [ "$action" = "refresh" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" --data-urlencode "text=⏳ Обновляю журнал..." -d show_alert="false" >/dev/null 2>&1
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" >/dev/null 2>&1; fi
        _bot_mark_busy_start "critical_callback"
        local response=""
        if command -v timeout >/dev/null 2>&1; then
            response=$(timeout 30 /etc/telegram_bot/notify.sh critical "$action" "$param" 2>&1); local _rc=$?
            if [ "$_rc" -eq 124 ]; then _bot_mark_busy_end; send_message "⚠️ <b>Журнал не ответил за 30 сек</b>"; return; fi
        else response=$(/etc/telegram_bot/notify.sh critical "$action" "$param" 2>&1); fi
        _bot_mark_busy_end
        text="${response%||*}"; keyboard="${response#*||}"
        local crit_msg_id=$(cat /tmp/telegram_bot/critical/msg_id 2>/dev/null)
        if [ -n "$crit_msg_id" ]; then msg_id_to_edit="$crit_msg_id"; else msg_id_to_edit="$message_id"; fi
        if [ ${#text} -gt 4000 ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" >/dev/null 2>&1
            send_long_message "$text" "$keyboard"
        else
            if [ "$text" = "$response" ]; then 
                edit_response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
            else 
                edit_response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$msg_id_to_edit" --data-urlencode text="$text" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
            fi
        fi
        return
    fi

    if echo "$callback_data" | grep -q '^select_[0-9]\+$'; then
        if [ -n "$message_id" ]; then echo "$message_id" > /tmp/telegram_bot/speed/msg_id; SPEED_MSG_ID="$message_id"; fi
        if [ ! -f "$SPEED_DEVICE_LIST" ]; then show_device_list; return; fi
        local num=$(echo "$callback_data" | cut -d'_' -f2); local mac=$(awk -F'|' -v n="$num" 'NR==n {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); local name=$(awk -F'|' -v n="$num" 'NR==n {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null)
        if [ -z "$mac" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Устройство не найдено" > /dev/null 2>&1; return; fi
        _update_speed_state "device_selected" "$mac" "$name" "" "" "" "" "" "" 127 "false" "false"
        local limits=$(_get_device_limits "$mac"); local has_limits=0
        if [ -n "$limits" ]; then local count=$(echo "$limits" | grep -c '|' 2>/dev/null || echo "0"); [ "$count" -gt 0 ] && has_limits=1; fi
        if [ "$has_limits" -eq 1 ]; then
            rm -f /tmp/telegram_bot/speed/limit_msg_id; _update_speed_state "device_selected" "$mac" "$name" "" "" "" "" "" "" 127 "false" "false"; show_device_limits "$mac" "$name"
        else
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            _update_speed_state "choose_rx" "$mac" "$name" "" "" "" "" "" "" 127 "false" "false"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "" "" "" "" "✅ Вы выбрали устройство:" "🕒  ЗАДАЙТЕ ВХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "1")
            _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
        fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    local state_file="/tmp/telegram_bot/speed/state.json"
    if [ ! -f "$state_file" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
    local state
    if ! state=$(_get_speed_state); then reset_device_selection; curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Ошибка состояния" > /dev/null 2>&1; return; fi
    local step=$(echo "$state" | jq -r '.step // ""'); local mac=$(echo "$state" | jq -r '.mac // ""'); local name=$(echo "$state" | jq -r '.name // ""')
    local rx_bytes=$(echo "$state" | jq -r '.rx_bytes // 0'); local rx_display=$(echo "$state" | jq -r '.rx_display // ""')
    local tx_bytes=$(echo "$state" | jq -r '.tx_bytes // 0'); local tx_display=$(echo "$state" | jq -r '.tx_display // ""')
    local manual=$(echo "$state" | jq -r '.manual // false'); local from_profile=$(echo "$state" | jq -r '.from_profile // false')

    if [ "$callback_data" = "speed_custom" ]; then
        if [ "$step" = "choose_rx" ]; then
            _update_speed_state "choose_rx" "$mac" "$name" "" "" "" "" "" "" 127 "true" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "" "" "" "" "✅ Вы выбрали устройство:" "✏️ Введите число в MB/s (например: 0.3)" "1")
            _send_and_save_id "$msg" '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}' "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        elif [ "$step" = "choose_tx" ]; then
            echo "$SPEED_MSG_ID" > /tmp/telegram_bot/speed/old_msg_id
            _update_speed_state "choose_tx" "$mac" "$name" "$rx_bytes" "$rx_display" "" "" "" "" 127 "true" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "" "" "" "✅ Входящая скорость установлена: $rx_display" "✏️ Введите число в MB/s (например: 0.3)" "2")
            _send_and_save_id "$msg" '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}' "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
    fi

    if [[ "$callback_data" =~ ^speed_([0-9]+)$ ]]; then
        local speed_value="${BASH_REMATCH[1]}"; local speed_bytes_bandix="$speed_value"
        if [ "$speed_value" -ge 1048576 ]; then display_speed="$(awk -v v="$speed_value" 'BEGIN{printf "%.1f", v/1048576}') MB/s"
        elif [ "$speed_value" -ge 1024 ]; then display_speed="$((speed_value / 1024)) KB/s"
        else display_speed="${speed_value} B/s"; fi
        if [ "$step" = "choose_rx" ]; then
            _update_speed_state "choose_tx" "$mac" "$name" "$speed_bytes_bandix" "$display_speed" "" "" "" "" 127 "false" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "$display_speed" "" "" "" "✅ Входящая скорость установлена: $display_speed" "🕒  ЗАДАЙТЕ ИСХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "2")
            _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        elif [ "$step" = "choose_tx" ]; then
            _update_speed_state "choose_time" "$mac" "$name" "$rx_bytes" "$rx_display" "$speed_bytes_bandix" "$display_speed" "" "" 127 "false" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$display_speed" "" "" "✅ Ограничения скорости установлены" "🕒  ЗАДАЙТЕ ВРЕМЯ ДЕЙСТВИЯ ЛИМИТА" "3")
            _send_and_save_id "$msg" "$(get_duration_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
    fi

    if [[ "$callback_data" =~ ^dur_([0-9]+)$ ]]; then
        if [ "$step" != "choose_time" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        local dur="${BASH_REMATCH[1]}"
        if [ "$dur" = "0" ]; then
            _update_speed_state "choose_days" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "00:00" "23:59" 127 "false" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "00:00 - 23:59" "" "✅ Время установлено" "📅  ВЫБЕРИТЕ ДНИ ДЕЙСТВИЯ ЛИМИТА" "4")
            _send_and_save_id "$msg" "$(get_days_keyboard_with_back 127)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
        else
            local now_hours=$(date +%H); local now_minutes=$(date +%M); local new_start=$(date +%H:%M)
            local total_minutes=$((10#$now_hours * 60 + 10#$now_minutes + dur)); local end_hours=$((total_minutes / 60 % 24)); local end_minutes=$((total_minutes % 60))
            printf -v new_end "%02d:%02d" $end_hours $end_minutes
            _update_speed_state "choose_days" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "$new_start" "$new_end" 127 "false" "$from_profile"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "${new_start} - ${new_end}" "" "✅ Время установлено" "📅  ВЫБЕРИТЕ ДНИ ДЕЙСТВИЯ ЛИМИТА" "4")
            _send_and_save_id "$msg" "$(get_days_keyboard_with_back 127)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
        fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "dur_custom" ]; then
        if [ "$step" != "choose_time" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        _update_speed_state "interval_input" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "" "" 127 "false" "$from_profile"
        local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
        local msg=$(_build_device_table "$mac" "$name" "$ip" "$rx_display" "$tx_display" "" "" "✅ Ограничения скорости установлены" "✏️ Введите интервал времени: ЧЧ:ММ-ЧЧ:ММ" "3")
        _send_and_save_id "$msg" '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"back"},{"text":"❌ Отмена","callback_data":"cancel"}]]}' "/tmp/telegram_bot/speed/msg_id"
        SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^day_([0-9])$ ]]; then
        if [ "$step" != "choose_days" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        local current_state
        if ! current_state=$(_get_speed_state); then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Ошибка состояния" > /dev/null 2>&1; return; fi
        local current_days_mask=$(echo "$current_state" | jq -r '.days_mask // 127'); current_days_mask=$((current_days_mask + 0))
        local day_idx="${BASH_REMATCH[1]}"; local bit=$((1 << day_idx)); local new_mask=$((current_days_mask ^ bit))
        local current_start_time=$(echo "$current_state" | jq -r '.start_time // ""'); local current_end_time=$(echo "$current_state" | jq -r '.end_time // ""')
        local current_rx_bytes=$(echo "$current_state" | jq -r '.rx_bytes // 0'); local current_tx_bytes=$(echo "$current_state" | jq -r '.tx_bytes // 0')
        local current_rx_display=$(echo "$current_state" | jq -r '.rx_display // ""'); local current_tx_display=$(echo "$current_state" | jq -r '.tx_display // ""')
        local current_name=$(echo "$current_state" | jq -r '.name // ""'); local current_mac=$(echo "$current_state" | jq -r '.mac // ""'); local current_from_profile=$(echo "$current_state" | jq -r '.from_profile // false')
        _update_speed_state "choose_days" "$current_mac" "$current_name" "$current_rx_bytes" "$current_rx_display" "$current_tx_bytes" "$current_tx_display" "$current_start_time" "$current_end_time" "$new_mask" "false" "$current_from_profile"
        edit_message_reply_markup "$CHAT_ID" "$message_id" "$(get_days_keyboard_with_back "$new_mask")"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [ "$callback_data" = "days_done" ]; then
        if [ "$step" != "choose_days" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Действие неактуально" > /dev/null 2>&1; return; fi
        local new_state
        if ! new_state=$(_get_speed_state); then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⏳ Ошибка состояния" > /dev/null 2>&1; return; fi
        local mac=$(echo "$new_state" | jq -r '.mac // ""'); local rx_bytes=$(echo "$new_state" | jq -r '.rx_bytes // 0'); local tx_bytes=$(echo "$new_state" | jq -r '.tx_bytes // 0')
        local rx_display=$(echo "$new_state" | jq -r '.rx_display // ""'); local tx_display=$(echo "$new_state" | jq -r '.tx_display // ""')
        local start_time=$(echo "$new_state" | jq -r '.start_time // ""'); local end_time=$(echo "$new_state" | jq -r '.end_time // ""')
        local days_mask=$(echo "$new_state" | jq -r '.days_mask // 127'); local from_profile=$(echo "$new_state" | jq -r '.from_profile // false'); local name=$(echo "$new_state" | jq -r '.name // ""')
        days_mask=$((days_mask + 0))
        if [ "$days_mask" -eq 0 ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Выберите хотя бы один день недели" -d show_alert="true" > /dev/null 2>&1; return; fi
        if [ -z "$start_time" ] || [ -z "$end_time" ]; then
            start_time="00:00"; end_time="23:59"; _update_speed_state "choose_days" "$mac" "$name" "$rx_bytes" "$rx_display" "$tx_bytes" "$tx_display" "$start_time" "$end_time" "$days_mask" "false" "$from_profile"
        fi
        local args=("set_speed" "$mac" "$rx_bytes" "$tx_bytes" "$rx_display" "$tx_display" "$start_time" "$end_time" "$days_mask")
        _bot_mark_busy_start "speed_limit"
        if command -v timeout >/dev/null 2>&1; then
            result=$(timeout 30 /etc/telegram_bot/notify.sh "${args[@]}" 2>&1); if [ $? -eq 124 ]; then result="⚠️ Операция превысила время ожидания (30 сек)"; fi
        else result=$(/etc/telegram_bot/notify.sh "${args[@]}" 2>&1); fi
        _bot_mark_busy_end
        echo "$mac" > /tmp/telegram_bot/speed/last_mac; echo "$name" > /tmp/telegram_bot/speed/last_name
        _speed_cleanup_user_msgs; reset_device_selection
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$message_id" > /dev/null 2>&1
        local _set_kb='{"inline_keyboard":[[{"text":"Продолжить","callback_data":"speed_set_continue"},{"text":"Закрыть","callback_data":"close_to_menu"}]]}'
        local _set_msg_id=$(send_message_and_get_id "$result" "$_set_kb")
        [ -n "$_set_msg_id" ] && echo "$_set_msg_id" > /tmp/telegram_bot/speed/set_msg_id
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^limit_select_ ]]; then
        local sel_id="${callback_data#limit_select_}"; local cur_sel=""; [ -f /tmp/telegram_bot/speed/limit_selected_uuid ] && cur_sel=$(cat /tmp/telegram_bot/speed/limit_selected_uuid 2>/dev/null | tr -d '\n\r ')
        if [ "$cur_sel" = "$sel_id" ]; then rm -f /tmp/telegram_bot/speed/limit_selected_uuid; else echo "$sel_id" > /tmp/telegram_bot/speed/limit_selected_uuid; fi
        local state; local mac="" name=""
        if state=$(_get_speed_state 2>/dev/null) && [ -n "$state" ]; then mac=$(echo "$state" | jq -r '.mac // ""'); name=$(echo "$state" | jq -r '.name // ""'); fi
        if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null); fi
        if [ -n "$mac" ]; then show_device_limits "$mac" "$name"; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^limit_toggle_ ]]; then
        local toggle_id="${callback_data#limit_toggle_}"; local state; local mac="" name=""
        if state=$(_get_speed_state 2>/dev/null) && [ -n "$state" ]; then mac=$(echo "$state" | jq -r '.mac // ""'); name=$(echo "$state" | jq -r '.name // ""'); fi
        if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null); fi
        if [ -n "$mac" ]; then
            local toggle_result=""
            if _limit_toggle_profile "$toggle_id" "$mac"; then
                local days_now=$(ubus call luci.bandix getScheduleLimits 2>/dev/null | jq -c ".data.limits[] | select(.id == \"$toggle_id\") | .time_slot.days" 2>/dev/null)
                local dc=$(echo "$days_now" | tr -d '[]' | tr ',' ' ')
                if [ -z "$dc" ]; then toggle_result="🔴 Профиль выключен"; else toggle_result="🟢 Профиль включён"; fi
            else toggle_result="❌ Ошибка переключения"; fi
            show_device_limits "$mac" "$name"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="$toggle_result" > /dev/null 2>&1
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Устройство не определено" > /dev/null 2>&1; fi
        return
    fi
	
    if [ "$callback_data" = "limit_add_new" ]; then
        local state; local mac=""; local name=""
        if state=$(_get_speed_state 2>/dev/null) && [ -n "$state" ]; then mac=$(echo "$state" | jq -r '.mac // ""'); name=$(echo "$state" | jq -r '.name // ""'); fi
        if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null); fi
        if [ -n "$mac" ]; then
            local msg_id=$(cat /tmp/telegram_bot/speed/limit_msg_id 2>/dev/null)
            if [ -n "$msg_id" ]; then SPEED_MSG_ID="$msg_id"; rm -f /tmp/telegram_bot/speed/limit_msg_id; fi
            rm -f /tmp/telegram_bot/speed/msg_id
            _update_speed_state "choose_rx" "$mac" "$name" "" "" "" "" "" "" 127 "false" "true"
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local msg=$(_build_device_table "$mac" "$name" "$ip" "" "" "" "" "✅ Вы выбрали устройство:" "🕒  ЗАДАЙТЕ ВХОДЯЩУЮ СКОРОСТЬ ОГРАНИЧЕНИЯ" "1")
            _send_and_save_id "$msg" "$(get_speed_keyboard_with_back)" "/tmp/telegram_bot/speed/msg_id"
            SPEED_MSG_ID=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null)
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Ошибка: устройство не выбрано" > /dev/null 2>&1; show_device_list; fi
        return
    fi

    if [ "$callback_data" = "limit_remove_all" ]; then
        local state; local mac=""; local name=""
        if state=$(_get_speed_state 2>/dev/null) && [ -n "$state" ]; then mac=$(echo "$state" | jq -r '.mac // ""'); name=$(echo "$state" | jq -r '.name // ""'); fi
        if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null); fi
        if [ -n "$mac" ]; then
		_bot_mark_busy_start "limit_remove_all"
            rm -f /tmp/telegram_bot/speed/limit_selected_uuid; local _order_file="/etc/telegram_bot/data/.bandix_profiles_order.txt"
            if [ -f "$_order_file" ]; then grep -v "^${mac}|" "$_order_file" > "${_order_file}.tmp" 2>/dev/null; mv "${_order_file}.tmp" "$_order_file" 2>/dev/null; fi
            local profiles=$(_get_device_limits "$mac")
            while IFS='|' read -r id rx tx start end days; do if [ -n "$id" ]; then ubus call luci.bandix deleteScheduleLimit "{\"id\":\"$id\"}" > /dev/null 2>&1; fi; done <<< "$profiles"
            _bot_mark_busy_end
			reset_device_selection
            local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
            local device_name=""; local devices_json=$(ubus call luci.bandix getStatus 2>/dev/null)
            if [ -n "$devices_json" ]; then device_name=$(echo "$devices_json" | jq -r ".d[] | select(.mac | ascii_downcase == \"$mac\") | .host // \"\"" 2>/dev/null | head -1); device_name=$(echo "$device_name" | sed 's/\.lan$//'); fi
            [ -z "$device_name" ] && device_name="$mac"
            local msg="<pre>✅ <b>Ограничения сняты для устройства:</b>
$SEP46
$SEP46
📱 $device_name
🌐 $ip
🔗 $mac
🕒 $(date '+%Y-%m-%d %H:%M:%S')
$SEP46
$SEP46</pre>"
            local _rm_kb='{"inline_keyboard":[[{"text":"Продолжить","callback_data":"speed_remove_continue"},{"text":"Закрыть","callback_data":"close_to_menu"}]]}'
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$_rm_kb" > /dev/null 2>&1
            echo "$message_id" > /tmp/telegram_bot/speed/remove_msg_id; rm -f /tmp/telegram_bot/speed/limit_msg_id
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Все ограничения сняты" > /dev/null 2>&1
        else curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Ошибка: устройство не выбрано" > /dev/null 2>&1; show_device_list; fi
        return
    fi

    if [ "$callback_data" = "limit_back" ]; then
        local msg_id=$(cat /tmp/telegram_bot/speed/limit_msg_id 2>/dev/null); if [ -n "$msg_id" ]; then SPEED_MSG_ID="$msg_id"; fi
        rm -f /tmp/telegram_bot/speed/limit_msg_id /tmp/telegram_bot/speed/msg_id /tmp/telegram_bot/speed/limit_selected_uuid /tmp/telegram_bot/speed/state.json /tmp/telegram_bot/speed/device_list
        show_device_list
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="↩️ Назад к списку устройств" > /dev/null 2>&1
        return
    fi

    if [[ "$callback_data" =~ ^limit_delete_ ]]; then
        local id="${callback_data#limit_delete_}"
        if [ -n "$id" ]; then
            local cur_sel=""; [ -f /tmp/telegram_bot/speed/limit_selected_uuid ] && cur_sel=$(cat /tmp/telegram_bot/speed/limit_selected_uuid 2>/dev/null | tr -d '\n\r ')
            if [ "$cur_sel" = "$id" ]; then
                rm -f /tmp/telegram_bot/speed/limit_selected_uuid; local _order_file="/etc/telegram_bot/data/.bandix_profiles_order.txt"
                if [ -f "$_order_file" ]; then grep -v "^${mac}|${id}$" "$_order_file" > "${_order_file}.tmp" 2>/dev/null; mv "${_order_file}.tmp" "$_order_file" 2>/dev/null; fi
            fi
            local state; local mac=""; local name=""
            if state=$(_get_speed_state 2>/dev/null) && [ -n "$state" ]; then mac=$(echo "$state" | jq -r '.mac // ""'); name=$(echo "$state" | jq -r '.name // ""'); fi
            if [ -z "$mac" ] && [ -f "$SPEED_DEVICE_LIST" ]; then mac=$(awk -F'|' 'NR==1 {print $1}' "$SPEED_DEVICE_LIST" 2>/dev/null); name=$(awk -F'|' 'NR==1 {print $2}' "$SPEED_DEVICE_LIST" 2>/dev/null); fi
            if [ -n "$mac" ]; then
			_bot_mark_busy_start "limit_delete"
                ubus call luci.bandix deleteScheduleLimit "{\"id\":\"$id\"}" > /dev/null 2>&1
                local profiles_after=$(_get_device_limits "$mac"); local count_after=0
                if [ -n "$profiles_after" ]; then count_after=$(echo "$profiles_after" | grep -c '|' 2>/dev/null || echo "0"); fi
                _bot_mark_busy_end
                if [ "$count_after" -eq 0 ]; then
                    reset_device_selection; local ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [ -z "$ip" ] && ip="N/A"
                    local device_name=""; local devices_json=$(ubus call luci.bandix getStatus 2>/dev/null)
                    if [ -n "$devices_json" ]; then device_name=$(echo "$devices_json" | jq -r ".d[] | select(.mac | ascii_downcase == \"$mac\") | .host // \"\"" 2>/dev/null | head -1); device_name=$(echo "$device_name" | sed 's/\.lan$//'); fi
                    [ -z "$device_name" ] && device_name="$mac"
                    local msg="<pre>✅ <b>Ограничения сняты для устройства:</b>
$SEP46
$SEP46
📱 $device_name
🌐 $ip
🔗 $mac
🕒 $(date '+%Y-%m-%d %H:%M:%S')
$SEP46
$SEP46</pre>"
                    local _rm_kb='{"inline_keyboard":[[{"text":"Продолжить","callback_data":"speed_remove_continue"},{"text":"Закрыть","callback_data":"close_to_menu"}]]}'
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$message_id" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$_rm_kb" > /dev/null 2>&1
                    
                    echo "$message_id" > /tmp/telegram_bot/speed/remove_msg_id; rm -f /tmp/telegram_bot/speed/limit_msg_id
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Все ограничения сняты" > /dev/null 2>&1
                else
                    show_device_limits "$mac" "$name"
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="✅ Профиль удалён" > /dev/null 2>&1
                fi
            else
                show_device_list; curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Устройство не найдено" > /dev/null 2>&1
            fi
        else
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="❌ Ошибка удаления" > /dev/null 2>&1
        fi
        return
    fi

    if [ "$callback_data" = "limit_max_reached" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" -d text="⚠️ Достигнут лимит: 5 профилей. Удалите один из существующих." -d show_alert="true" > /dev/null 2>&1
        return
    fi

    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$callback_id" > /dev/null 2>&1
    send_message "⚠️ <b>Ошибка:</b> Установите скорость либо нажмите «❌ Отмена»."
    reset_device_selection
}

# ==============================================================================
# ИНИЦИАЛИЗАЦИЯ UCI
# ==============================================================================
if ! uci -q get telegram_bot.main >/dev/null 2>&1; then
    [ -f /etc/config/telegram_bot ] || touch /etc/config/telegram_bot
    uci set telegram_bot.main=main
    uci commit telegram_bot
fi

# ==============================================================================
# 🏁 РАЗДЕЛ 14: ЗАПУСК И ГЛАВНЫЙ ЦИКЛ (BOOT & MAIN LOOP)
# ==============================================================================

_get_actual_offset() {
    local response
    response=$(curl_retry --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=-1&limit=1" 2>/dev/null)
    if [ -z "$response" ]; then return 1; fi
    if ! echo "$response" | jq -e '.ok' >/dev/null 2>&1; then return 1; fi
    local last_id=$(echo "$response" | jq -r '.result[-1].update_id // empty' 2>/dev/null)
    if [ -z "$last_id" ]; then echo "9999999999"; return 0; fi
    echo $((last_id + 1))
    return 0
}

if [ -f "$LAST_UPDATE_FILE" ]; then
    LAST_UPDATE_ID=$(cat "$LAST_UPDATE_FILE" 2>/dev/null | tr -d '\n\r')
    if [ -z "$LAST_UPDATE_ID" ] || [ "$LAST_UPDATE_ID" -le 1 ]; then
        if recovered=$(_get_actual_offset); then LAST_UPDATE_ID="$recovered"; echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
        else touch /tmp/telegram_bot/flags/offset_recovery_pending; fi
    fi
else
    if recovered=$(_get_actual_offset); then LAST_UPDATE_ID="$recovered"; echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"
    else LAST_UPDATE_ID=1; touch /tmp/telegram_bot/flags/offset_recovery_pending; fi
fi

if [ "$LAST_UPDATE_ID" = "0" ]; then
    temp_updates=$(curl_retry --connect-timeout 5 "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=0&limit=1")
    if echo "$temp_updates" | jq -e '.result[0]' >/dev/null 2>&1; then
        last_id=$(echo "$temp_updates" | jq -r '.result[-1].update_id')
        if [ -n "$last_id" ] && [ "$last_id" != "null" ]; then LAST_UPDATE_ID=$((last_id + 1)); echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"; fi
    fi
fi

if [ -f "/tmp/telegram_bot/flags/restarting" ]; then
    rm -f "/tmp/telegram_bot/flags/restarting"
    sleep 2
    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=-1" >/dev/null 2>&1
    sleep 1
    _restart_msg_id=""
    if [ -f "/tmp/telegram_bot/state/bot_restart_msg_id" ]; then _restart_msg_id=$(cat /tmp/telegram_bot/state/bot_restart_msg_id 2>/dev/null | tr -d '\n\r '); fi
    _restart_edit_ok=0
    if [ -n "$_restart_msg_id" ]; then
        _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$_restart_msg_id" --data-urlencode text="✅ <b>Бот перезапущен</b>
🕒 $(date '+%Y-%m-%d %H:%M:%S')" -d parse_mode="HTML" 2>&1)
        if echo "$_resp" | jq -e '.ok' >/dev/null 2>&1; then _restart_edit_ok=1; fi
    fi
    rm -f /tmp/telegram_bot/state/bot_restart_msg_id
    if [ "$_restart_edit_ok" = "0" ]; then send_message "✅ <b>Бот перезапущен</b>
🕒 $(date '+%Y-%m-%d %H:%M:%S')"; fi
    send_menu
else
    sleep 2
    send_tg "✅ <b>Бот полностью готов к работе!</b>
🕒 Время запуска: <code>$(date '+%Y-%m-%d %H:%M:%S')</code>
💡 Все модули загружены."
    send_menu
fi

echo "Бот запущен" >> "$LOG_FILE"
rm -f /tmp/telegram_bot/wol/setup_mode /tmp/telegram_bot/wol/name /tmp/telegram_bot/wol/result_msg_id

while true; do
    rotate_log "/tmp/telegram_bot/logs/bot.log"
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot

    if [ -f "/tmp/telegram_bot/flags/offset_recovery_pending" ]; then
        if recovered=$(_get_actual_offset); then
            if [ -z "$LAST_UPDATE_ID" ] || [ "$recovered" -gt "$LAST_UPDATE_ID" ]; then LAST_UPDATE_ID="$recovered"; echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"; fi
            rm -f /tmp/telegram_bot/flags/offset_recovery_pending
        fi
    fi

    if [ "$(get_services_mode)" = "1" ] && ! _services_check_activity; then
        if [ -n "$SERVICES_MSG_ID" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$SERVICES_MSG_ID" > /dev/null 2>&1; _services_set_msg_id ""; rm -f /tmp/telegram_bot/services/msg_id; fi
        set_services_mode "0"; rm -f "$SERVICES_LAST_ACTIVITY_FILE"
    fi

    if [ -f "$WOL_MSG_ID_FILE" ] && ! _check_activity_timeout "$WOL_LAST_ACTIVITY_FILE" 600; then
        _id=$(cat "$WOL_MSG_ID_FILE" 2>/dev/null); [ -n "$_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_id" > /dev/null 2>&1
        rm -f "$WOL_MSG_ID_FILE" "$WOL_LAST_ACTIVITY_FILE"
    fi
    if [ -f "/tmp/telegram_bot/speed/msg_id" ] && ! _check_activity_timeout "$SPEED_LAST_ACTIVITY_FILE" 600; then
        _id=$(cat /tmp/telegram_bot/speed/msg_id 2>/dev/null); [ -n "$_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_id" > /dev/null 2>&1
        rm -f /tmp/telegram_bot/speed/msg_id "$SPEED_LAST_ACTIVITY_FILE" /tmp/telegram_bot/speed/state.json /tmp/telegram_bot/speed/device_list /tmp/telegram_bot/speed/limit_msg_id /tmp/telegram_bot/speed/limit_selected_uuid
        SPEED_MSG_ID=""
    fi
    if [ -f "/tmp/telegram_bot/wifi/msg_id" ] && ! _check_activity_timeout "$WIFI_LAST_ACTIVITY_FILE" 600; then
        _id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null); [ -n "$_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_id" > /dev/null 2>&1
        rm -f /tmp/telegram_bot/wifi/msg_id "$WIFI_LAST_ACTIVITY_FILE" /tmp/telegram_bot/wifi/active.lock /tmp/telegram_bot/wifi/edit_mode /tmp/telegram_bot/wifi/edit_section
    fi
    if [ -f "$REBOOT_MSG_ID_FILE" ] && ! _check_activity_timeout "$REBOOT_LAST_ACTIVITY_FILE" 600; then
        _id=$(cat "$REBOOT_MSG_ID_FILE" 2>/dev/null); [ -n "$_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_id" > /dev/null 2>&1
        rm -f "$REBOOT_MSG_ID_FILE" "$REBOOT_LAST_ACTIVITY_FILE"
    fi
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot

    _exec_autopush_result

    if [ -f /tmp/telegram_bot/exec/wait_msg_id ]; then _poll_timeout=8; _poll_max=15; else _poll_timeout=30; _poll_max=35; fi
    updates=$(curl_retry "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?timeout=$_poll_timeout&offset=$((LAST_UPDATE_ID+1))")
    
    if [ -n "$updates" ] && echo "$updates" | jq empty >/dev/null 2>&1; then
        _bot_batch_size=$(echo "$updates" | jq -r '.result | length'); case "$_bot_batch_size" in ''|*[!0-9]*) _bot_batch_size=0 ;; esac

        if [ "$_bot_batch_size" -ge 2 ]; then
            _bot_busy_info=$(_bot_check_busy 10)
            if [ $? -eq 0 ]; then
                _bot_op="${_bot_busy_info%%|*}"; _bot_dur="${_bot_busy_info##*|}"
                _bot_cb_count=$(echo "$updates" | jq -r '[.result[] | select(.callback_query != null)] | length'); case "$_bot_cb_count" in ''|*[!0-9]*) _bot_cb_count=0 ;; esac
                _bot_msg_count=$(echo "$updates" | jq -r '[.result[] | select(.message.text != null)] | length'); case "$_bot_msg_count" in ''|*[!0-9]*) _bot_msg_count=0 ;; esac

                if [ "$_bot_cb_count" -gt 0 ]; then
                    _bot_all_cb=$(echo "$updates" | jq -r '.result[] | select(.callback_query != null) | .callback_query.id // empty')
                    _bot_last_cb=$(echo "$_bot_all_cb" | tail -1); _bot_cb_id=""
                    while IFS= read -r _bot_cb_id; do
                        [ -z "$_bot_cb_id" ] && continue
                        if [ "$_bot_cb_id" = "$_bot_last_cb" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$_bot_cb_id" --data-urlencode text="🕒 Пропущено нажатий: ${_bot_cb_count} (операция ${_bot_op} завершилась)" -d show_alert="false" >/dev/null 2>&1 &
                        else curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$_bot_cb_id" >/dev/null 2>&1 & fi
                    done <<< "$_bot_all_cb"
                fi

                if [ "$_bot_msg_count" -gt 0 ]; then
                    _bot_prev_skip_id=""; if [ -f /tmp/telegram_bot/flags/skip_msg_id ]; then _bot_prev_skip_id=$(cat /tmp/telegram_bot/flags/skip_msg_id 2>/dev/null | tr -d '\n\r '); fi
                    if [ -n "$_bot_prev_skip_id" ]; then curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_bot_prev_skip_id" >/dev/null 2>&1 & fi
                    echo "$updates" | jq -r '.result[] | select(.message.text != null) | .message.message_id' | while read -r _umid; do [ -n "$_umid" ] && curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_umid" >/dev/null 2>&1 & done
                    sleep 1
                    _bot_skip_text="🕒 <b>Операция ${_bot_op} завершилась (${_bot_dur} сек).</b>
Пропущено команд: <b>${_bot_msg_count}</b>.
Повторите, если нужно."
                    _bot_skip_resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$_bot_skip_text" -d parse_mode="HTML" 2>&1)
                    _bot_skip_id=$(echo "$_bot_skip_resp" | jq -r '.result.message_id // empty' 2>/dev/null); [ -n "$_bot_skip_id" ] && echo "$_bot_skip_id" > /tmp/telegram_bot/flags/skip_msg_id
                fi

                _bot_last_uid=$(echo "$updates" | jq -r '.result[-1].update_id // empty')
                if [ -n "$_bot_last_uid" ]; then LAST_UPDATE_ID="$_bot_last_uid"; echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"; fi
                continue
            fi
        fi

        _total_updates=$(echo "$updates" | jq -r '.result | length'); case "$_total_updates" in ''|*[!0-9]*) _total_updates=0 ;; esac
        
        _i=0
        while [ "$_i" -lt "$_total_updates" ]; do
            CURRENT_UPDATE_ID=$(echo "$updates" | jq -r ".result[$_i].update_id // empty")
            _clear_previous_error
            if echo "$updates" | jq -e ".result[$_i].callback_query" >/dev/null 2>&1; then
                callback_data=$(echo "$updates" | jq -r ".result[$_i].callback_query.data // \"\"")
                callback_id=$(echo "$updates" | jq -r ".result[$_i].callback_query.id // \"\"")
                message_id=$(echo "$updates" | jq -r ".result[$_i].callback_query.message.message_id // 0")
                chat_id=$(echo "$updates" | jq -r ".result[$_i].callback_query.message.chat.id // 0")
                if [ -n "$callback_data" ]; then handle_callback "$callback_data" "$callback_id" "$message_id" "$chat_id"; fi
            elif echo "$updates" | jq -e ".result[$_i].message.text" >/dev/null 2>&1; then
                text=$(echo "$updates" | jq -r ".result[$_i].message.text // \"\"")
                in_chat_id=$(echo "$updates" | jq -r ".result[$_i].message.chat.id // 0")
                _IN_TEXT_MSG_ID=$(echo "$updates" | jq -r ".result[$_i].message.message_id // empty")
                if [ -n "$text" ] && [ "$in_chat_id" = "$CHAT_ID" ]; then
                    if [ -f "/tmp/telegram_bot/speed/state.json" ] || [ -f "/tmp/telegram_bot/speed/msg_id" ] || [ -f "$SPEED_DEVICE_LIST" ] || [ -f "/tmp/telegram_bot/speed/limit_msg_id" ]; then
                        case "$text" in /start*|/menu|/help|/restart*|/exec*|/target*|/mute*|/event*|/threshold*) : ;; *) _speed_track_user_msg "$_IN_TEXT_MSG_ID" ;; esac
                    fi
                    case "$text" in
                        /start|/start\ *|/exec|/exec\ *|/restart|/restart\ *) : ;;
                        /*|"📋 Журнал событий"|"📊 Статус системы"|"🖥️ Клиенты онлайн"|"📊 Трафик"|"⏱ Ограничить скорость"|"🕒 Время работы"|"🛜 Настройка Wi-Fi"|"🔧 Автозапуск"|"🌐 Wake-on-LAN"|"📁 Проводник"|"🔴 Перезагрузить роутер"|"📖 Справка")
                            _umid=$(echo "$updates" | jq -r ".result[$_i].message.message_id // empty")
                            if [ -n "$_umid" ]; then curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_umid" >/dev/null 2>&1; _IN_TEXT_MSG_ID=""; fi ;;
                    esac
                    handle_command "$text"
                fi
            elif echo "$updates" | jq -e ".result[$_i].message.document" >/dev/null 2>&1; then
                if [ -f "/tmp/telegram_bot/explorer/upload_mode" ]; then _doc_json=$(echo "$updates" | jq -c ".result[$_i].message.document"); _expl_handle_document "$_doc_json"; fi
            fi
            _i=$((_i + 1))
        done
        _last_uid=$(echo "$updates" | jq -r '.result[-1].update_id // empty')
        if [ -n "$_last_uid" ] && [ "$_last_uid" != "$LAST_UPDATE_ID" ]; then 
            LAST_UPDATE_ID="$_last_uid"; 
            echo "$LAST_UPDATE_ID" > "$LAST_UPDATE_FILE"; 
        fi
    else
        if [ -n "$updates" ]; then
            echo "$(date): getUpdates вернул не-JSON: ${updates:0:50}..." >> /tmp/telegram_bot/logs/bot.log
        fi
        sleep 10
    fi
    sleep 1
done