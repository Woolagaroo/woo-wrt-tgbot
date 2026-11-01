#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# ==============================================================================
# 📶 МОДУЛЬ УПРАВЛЕНИЯ WI-FI
# ==============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -f "/etc/telegram_bot/bot_config.sh" ]; then
        source /etc/telegram_bot/bot_config.sh
    else
        echo "❌ Ошибка: bot_config.sh не найден" >&2
        exit 1
    fi
    echo "=== wifi.sh loaded (v12.0) ===" >> /tmp/telegram_bot/logs/bot.log
    check_required_utilities || exit 1
fi

# ==============================================================================
# 🚀 РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ И БАЗОВЫЕ НАСТРОЙКИ
# ==============================================================================

_WIFI_FIX_LOCK="/var/lock/wifi_fix.lock"
WIFI_MSG_ID_FILE="/tmp/telegram_bot/wifi/msg_id"
WIFI_EDIT_MODE_FILE="/tmp/telegram_bot/wifi/edit_mode"
WIFI_EDIT_MSG_ID_FILE="/tmp/telegram_bot/wifi/edit_msg_id"
WIFI_CREATE_RADIO_FILE="/tmp/telegram_bot/wifi/create_radio"
WIFI_EDIT_SECTION_FILE="/tmp/telegram_bot/wifi/edit_section"

CURRENT_WIFI_MENU_FILE="/tmp/telegram_bot/wifi/current_menu"
CURRENT_WIFI_BAND_FILE="/tmp/telegram_bot/wifi/current_band"
CURRENT_WIFI_CREATE_TYPE_FILE="/tmp/telegram_bot/wifi/current_create_type"

_WIFI_PENDING_INVALID_FILE="/tmp/telegram_bot/wifi/pending_invalid_inputs"
_WIFI_PENDING_ERROR_FILE="/tmp/telegram_bot/wifi/pending_error_msgs"
_WIFI_INPUT_MSG_ID=""

# ==============================================================================
# 🛠️ РАЗДЕЛ 2: ОБЩИЕ УТИЛИТЫ (CORE)
# ==============================================================================

_wifi_safe_reload() {
    local rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 wifi reload
        rc=$?
        if [ "$rc" -eq 124 ]; then
            echo "$(date): wifi reload timeout (30s)" >> /tmp/telegram_bot/logs/bot.log
        fi
    else
        wifi reload
        rc=$?
    fi
    return $rc
}

_wait_for_radio_ready() {
    local radio_num="$1"
    local timeout_down="${2:-8}"
    local timeout_up="${3:-20}"
    local count=0
    local iface=""
    
    if [ "$radio_num" = "0" ]; then
        iface="$INTERFACE_24"
    else
        iface="$INTERFACE_5"
    fi
    if [ -z "$iface" ]; then
        local i phy
        for i in $(iw dev 2>/dev/null | grep -E '^[[:space:]]+Interface' | awk '{print $2}'); do
            phy=$(iw dev "$i" info 2>/dev/null | grep -E '^[[:space:]]+wiphy' | awk '{print $2}')
            if [ "$phy" = "$radio_num" ]; then
                iface="$i"
                break
            fi
        done
    fi
    [ -z "$iface" ] && iface="phy${radio_num}-ap0"

    sleep 2
    local disappeared=0
    count=0
    while [ $count -lt $timeout_down ]; do
        if ! iw dev "$iface" info 2>/dev/null | grep -q "type AP"; then
            disappeared=1
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    case "$timeout_up" in
        ''|*[!0-9]*) ;;
        0|1)
            [ "$disappeared" -eq 1 ] && return 0 || return 1
            ;;
    esac

    count=0
    while [ $count -lt $timeout_up ]; do
        local info=$(iw dev "$iface" info 2>/dev/null)
        if [ -n "$info" ] && echo "$info" | grep -q "type AP"; then
            local channel=$(echo "$info" | grep -m1 "channel" | awk '{print $2}')
            if [ -n "$channel" ] && [ "$channel" != "0" ] && [ "$channel" != "unknown" ]; then
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

_wifi_send_temp() {
    local text="$1"
    local keyboard="$2"
    local response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2
}

_wifi_delete_message() {
    local msg_id="$1"
    [ -n "$msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
        -d chat_id="$CHAT_ID" -d message_id="$msg_id" >/dev/null 2>&1
}

_wifi_send_main() {
    local text="$1"
    local keyboard="$2"
    local response
    local new_id
    date +%s > /tmp/telegram_bot/wifi/last_activity 2>/dev/null
    local msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)

    if [ -n "$msg_id" ]; then
        response=$(curl_retry --connect-timeout 5 --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$msg_id" --data-urlencode text="$text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        if echo "$response" | grep -q '"ok":false'; then
            if echo "$response" | grep -qi "message is not modified"; then
                return 0
            fi
            rm -f "$WIFI_MSG_ID_FILE"
            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$keyboard" 2>&1)
            new_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
            [ -n "$new_id" ] && echo "$new_id" > "$WIFI_MSG_ID_FILE"
        fi
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        new_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
        [ -n "$new_id" ] && echo "$new_id" > "$WIFI_MSG_ID_FILE"
    fi
}

_wifi_send_edit() {
    local text="$1"
    local keyboard="$2"
    local response
    local new_id
    date +%s > /tmp/telegram_bot/wifi/last_activity 2>/dev/null
    local msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)

    if [ -n "$msg_id" ]; then
        response=$(curl_retry --connect-timeout 5 --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$msg_id" --data-urlencode text="$text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        if echo "$response" | grep -q '"ok":false'; then
            if echo "$response" | grep -qi "message is not modified"; then
                return 0
            fi
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" >/dev/null 2>&1
            rm -f "$WIFI_MSG_ID_FILE"

            response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$keyboard" 2>&1)
            new_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
            [ -n "$new_id" ] && echo "$new_id" > "$WIFI_MSG_ID_FILE"
        fi
    else
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        new_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
        [ -n "$new_id" ] && echo "$new_id" > "$WIFI_MSG_ID_FILE"
    fi
}

_wifi_send_prompt() {
    local text="$1"
    local keyboard="$2"
    local response
    local new_id
    local old_prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
    if [ -n "$old_prompt_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$old_prompt_id" >/dev/null 2>&1
        rm -f "$WIFI_EDIT_MSG_ID_FILE"
    fi
    response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$keyboard" 2>&1)
    new_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
    [ -n "$new_id" ] && echo "$new_id" > "$WIFI_EDIT_MSG_ID_FILE"
}

_wifi_answer_cb() {
    [ "$_WIFI_CB_ANSWERED" = "1" ] && return 0
    _WIFI_CB_ANSWERED=1
    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" "$@"
}

_wifi_cleanup_success_msg() {
    local _sf="/tmp/telegram_bot/wifi/success_msg_id"
    if [ -f "$_sf" ]; then
        local _mid=$(cat "$_sf" 2>/dev/null | tr -d '\n\r ')
        if [ -n "$_mid" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1
        fi
        rm -f "$_sf"
    fi
}

_wifi_pending_add() {
    local _file="$1" _mid="$2"
    [ -z "$_mid" ] && return 0
    echo "$_mid" >> "$_file" 2>/dev/null
}

_wifi_pending_flush() {
    local _f _mid
    for _f in "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_PENDING_ERROR_FILE"; do
        [ -f "$_f" ] || continue
        while IFS= read -r _mid; do
            [ -z "$_mid" ] && continue
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
                -d chat_id="$CHAT_ID" -d message_id="$_mid" >/dev/null 2>&1
        done < "$_f"
        rm -f "$_f"
    done
}

_wifi_input_finalize() {
    _wifi_pending_flush
    if [ -n "$_WIFI_INPUT_MSG_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_WIFI_INPUT_MSG_ID" >/dev/null 2>&1
        _WIFI_INPUT_MSG_ID=""
    fi
}

_wifi_is_valid_input() {
    local str="$1"
    case "$str" in
        *[$'\001'-$'\037']*|*$'\177'*)
            return 1 ;;
    esac
    return 0
}

_generate_iface_name() {
    local prefix="$1"
    local radio="$2"
    local timestamp=$(date +%s)
    echo "${prefix}_${radio}_${timestamp}"
}

_wifi_mode_display() {
    case "$1" in
        ap) echo "Точка доступа" ;;
        sta) echo "Клиент" ;;
        mesh) echo "Wi-Fi Mesh (802.11s)" ;;
        *) echo "Неизвестно" ;;
    esac
}

_wifi_enc_display() {
    case "$1" in
        none) echo "Без шифрования" ;;
        owe) echo "OWE" ;;
        psk) echo "WPA-PSK" ;;
        psk2) echo "WPA2-PSK" ;;
        "psk-mixed") echo "WPA-PSK/WPA2-PSK" ;;
        sae) echo "WPA3-SAE" ;;
        "sae-mixed") echo "WPA2-PSK/WPA3-SAE Mixed" ;;
        "sae-compat") echo "WPA2-PSK/WPA3-SAE Compatibility" ;;
        wpa) echo "WPA-EAP" ;;
        wpa2) echo "WPA2-EAP" ;;
        wpa3) echo "WPA3-EAP 192-bit" ;;
        "wpa3-mixed") echo "WPA2-EAP/WPA3-EAP Mixed" ;;
        wep) echo "WEP" ;;
        *) echo "$1" ;;
    esac
}

_parse_radio_info() {
    local iface="$1"
    local channel="N/A"
    local freq="N/A"
    local bitrate="N/A"
    local signal="N/A"
    local noise="N/A"

    if command -v iwinfo >/dev/null 2>&1; then
        local info=$(iwinfo "$iface" info 2>/dev/null)
        if [ -n "$info" ]; then
            local chan_line=$(echo "$info" | grep -m1 "Channel:")
            if [ -n "$chan_line" ]; then
                channel=$(echo "$chan_line" | sed -n 's/.*Channel: \([0-9]*\).*/\1/p')
                freq=$(echo "$chan_line" | sed -n 's/.*(\([0-9.]* GHz\)).*/\1/p')
                [ -z "$freq" ] && freq=$(echo "$chan_line" | sed -n 's/.*(\([0-9.]*GHz\)).*/\1/p')
            fi
            bitrate=$(echo "$info" | grep -m1 "^[[:space:]]*Bit Rate:" | awk '{print $3" "$4}')
            signal=$(echo "$info" | grep -m1 "^[[:space:]]*Signal:" | awk '{print $2" "$3}' | sed 's/[,[]*//g' | awk '{print $1" "$2}')
            noise=$(echo "$info" | grep -m1 "^[[:space:]]*Noise:" | awk '{print $2" "$3}' | sed 's/[,[]*//g' | awk '{print $1" "$2}')
        fi
    fi

    if [ -z "$freq" ] || [ "$freq" = "N/A" ]; then
        local iw_out=$(iw dev "$iface" info 2>/dev/null)
        if [ -n "$iw_out" ]; then
            local freq_mhz=$(echo "$iw_out" | grep -m1 "frequency" | awk '{print $2}')
            if [ -n "$freq_mhz" ] && [ "$freq_mhz" != "0" ]; then
                freq=$(awk -v f="$freq_mhz" 'BEGIN{printf "%.3f", f/1000}')
                freq="${freq} GHz"
            fi
        fi
    fi

    if [ -z "$channel" ] || [ "$channel" = "N/A" ]; then
        local iw_out=$(iw dev "$iface" info 2>/dev/null)
        [ -n "$iw_out" ] && channel=$(echo "$iw_out" | grep -m1 "channel" | awk '{print $2}')
    fi

    signal=$(echo "$signal" | sed 's/[,[]*//g' | awk '{print $1" "$2}')
    noise=$(echo "$noise" | sed 's/[,[]*//g' | awk '{print $1" "$2}')
    [ -z "$signal" ] && signal="N/A"
    [ -z "$noise" ] && noise="N/A"
    [ -z "$bitrate" ] && bitrate="N/A"
    [ -z "$channel" ] && channel="N/A"
    [ -z "$freq" ] && freq="N/A"

    echo "$channel|$freq|$bitrate|$signal|$noise"
}

_scan_temp_cleanup() {
    local tmp_iface="$1"
    if [ -n "$tmp_iface" ]; then
        if iw dev "$tmp_iface" del 2>/dev/null; then
            echo "DEBUG: removed temp interface $tmp_iface" >> /tmp/telegram_bot/logs/bot.log
        fi
    fi
}

# ==============================================================================
# ⚙️ РАЗДЕЛ 3: СОСТОЯНИЕ МЕНЮ И ВАЛИДАЦИЯ
# ==============================================================================

_wifi_set_current_menu() { echo "$1" > "$CURRENT_WIFI_MENU_FILE"; }
_wifi_get_current_menu() { cat "$CURRENT_WIFI_MENU_FILE" 2>/dev/null || echo "main"; }

_wifi_set_current_band() { echo "$1" > "$CURRENT_WIFI_BAND_FILE"; }
_wifi_get_current_band() { cat "$CURRENT_WIFI_BAND_FILE" 2>/dev/null || echo "24"; }

_wifi_set_current_create_type() { echo "$1" > "$CURRENT_WIFI_CREATE_TYPE_FILE"; }
_wifi_get_current_create_type() { cat "$CURRENT_WIFI_CREATE_TYPE_FILE" 2>/dev/null || echo ""; }

_wifi_is_callback_allowed() {
    local callback="$1"
    if [ "$callback" = "wifi_nop" ] || [ "$callback" = "wifi_nop_channel" ] || [ "$callback" = "wifi_nop_80211b" ] || [ "$callback" = "wifi_cancel_edit" ] || [ "$callback" = "wifi_sta_retry_password" ]; then
        return 0
    fi

    local menu="$(_wifi_get_current_menu)"
    local band="$(_wifi_get_current_band)"
    local create_type="$(_wifi_get_current_create_type)"
    
    case "$menu" in
        "main")
            case "$callback" in
                wifi_radio_0|wifi_radio_1|wifi_restart_radio_0|wifi_restart_radio_1|wifi_vif_menu|wifi_refresh_status|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "radio_settings")
            case "$callback" in
                wifi_radio_${band}_channel|wifi_radio_${band}_width|wifi_radio_${band}_country|wifi_radio_${band}_txpower|wifi_radio_${band}_standard|wifi_radio_${band}_legacy_toggle|wifi_radio_${band}_refresh|wifi_back_main|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "channel")
            case "$callback" in
                wifi_radio_${band}_set_channel_*|wifi_radio_${band}|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "txpower")
            case "$callback" in
                wifi_radio_${band}_set_power_*|wifi_radio_${band}|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "width")
            case "$callback" in
                wifi_radio_${band}_set_width_*|wifi_radio_${band}|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "standard")
            case "$callback" in
                wifi_radio_${band}_set_standard_*|wifi_radio_${band}|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "country")
            case "$callback" in
                wifi_radio_${band}_set_country_*|wifi_radio_${band}|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "vif_menu")
            case "$callback" in
                wifi_vif_select_*|wifi_vif_refresh|wifi_create_ap|wifi_create_sta|wifi_create_guest|wifi_back_main|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "create_radio")
            case "$callback" in
                wifi_create_radio_24|wifi_create_radio_5|wifi_vif_menu|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "sta_scan")
            case "$callback" in
                wifi_sta_select_*|wifi_create_sta|wifi_sta_refresh|wifi_cancel|wifi_vif_menu) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "network_edit")
            case "$callback" in
                wifi_edit_ssid|wifi_edit_key|wifi_edit_encryption|wifi_show_password_toggle|wifi_toggle_network|wifi_delete_network|wifi_network_edit_back|wifi_vif_menu|wifi_cancel|wifi_enc_set_*|wifi_confirm_delete_yes|wifi_confirm_delete_no) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        "encryption")
            case "$callback" in
                wifi_enc_set_*|wifi_network_edit_back|wifi_cancel) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

_wifi_get_error_text() {
    local menu="$(_wifi_get_current_menu)"
    case "$menu" in
        "radio_settings")  echo "Выберите параметр или нажмите Закрыть" ;;
        "channel")         echo "Выберите канал или нажмите Закрыть" ;;
        "txpower")         echo "Выберите Мощность или нажмите Закрыть" ;;
        "width")           echo "Выберите Ширину или нажмите Закрыть" ;;
        "standard")        echo "Выберите Стандарт или нажмите Закрыть" ;;
        "country")         echo "Выберите Страну или нажмите Закрыть" ;;
        "vif_menu")        echo "Выберите сеть или нажмите Закрыть" ;;
        "create_radio")    echo "Выберите радио или нажмите Закрыть" ;;
        "sta_scan")        echo "Выберите сеть или нажмите Закрыть" ;;
        "network_edit")    echo "Выберите действие или нажмите Закрыть" ;;
        "encryption")      echo "Выберите тип или нажмите Закрыть" ;;
        *)                 echo "Выберите действие или нажмите Закрыть" ;;
    esac
}

_wifi_redraw_current_menu() {
    local old_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    if [ -n "$old_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1
        rm -f "$WIFI_MSG_ID_FILE"
    fi

    local menu="$(_wifi_get_current_menu)"
    local band="$(_wifi_get_current_band)"
    local create_type="$(_wifi_get_current_create_type)"
    case "$menu" in
        "main")            show_wifi_main ;;
        "radio_settings")  show_wifi_radio_settings "$band" ;;
        "channel")         show_wifi_radio_channel "$band" ;;
        "txpower")         show_wifi_radio_txpower "$band" ;;
        "width")           show_wifi_radio_width "$band" ;;
        "standard")        show_wifi_radio_standard "$band" ;;
        "country")         show_wifi_radio_select_country "$band" ;;
        "vif_menu")        show_wifi_vif_menu ;;
        "create_radio")    _wifi_create_choose_radio "$create_type" ;;
        "sta_scan")        _wifi_create_sta_step2 ;;
        "network_edit")    
            local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
            local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
            local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
            local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
            local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
            [ -z "$disabled" ] && disabled="0"
            show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
            ;;
        "encryption")      _wifi_edit_encryption_start ;;
        *)                 show_wifi_main ;;
    esac
}

# ==============================================================================
# 🔧 РАЗДЕЛ 4: UCI И АППАРАТНЫЕ ОПЕРАЦИИ
# ==============================================================================

_get_radio_path() {
    local band="$1"
    [ "$band" = "24" ] && echo "radio0" || echo "radio1"
}

_wifi_get_radio_param() {
    local band="$1"
    local param="$2"
    local radio=$(_get_radio_path "$band")
    local val=$(uci -q get "wireless.$radio.$param" 2>/dev/null)

    if [ "$param" = "country" ]; then
        if [ -z "$val" ] || [ "$val" = "00" ]; then
            echo "default"
            return 0
        fi
    fi
    echo "$val"
}

_wifi_channel_to_freq() {
    local band="$1"
    local ch="$2"
    case "$ch" in ''|*[!0-9]*) return 0 ;; esac

    if [ "$band" = "24" ]; then
        if [ "$ch" -ge 1 ] && [ "$ch" -le 13 ]; then echo $((2412 + (ch - 1) * 5))
        elif [ "$ch" = "14" ]; then echo 2484; fi
    else
        if [ "$ch" -ge 36 ] && [ "$ch" -le 64 ]; then echo $((5180 + (ch - 36) * 5))
        elif [ "$ch" -ge 100 ] && [ "$ch" -le 144 ]; then echo $((5500 + (ch - 100) * 5))
        elif [ "$ch" -ge 149 ] && [ "$ch" -le 165 ]; then echo $((5745 + (ch - 149) * 5)); fi
    fi
}

_wifi_apply_channel_live() {
    local band="$1"
    local channel="$2"
    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
    local radio=$(_get_radio_path "$band")

    local freq=$( _wifi_channel_to_freq "$band" "$channel" )
    if [ -z "$freq" ]; then
        _wifi_set_radio_param "$band" "channel" "$channel"
        return
    fi

    if ! hostapd_cli -i "$iface" ping 2>/dev/null | grep -q "PONG"; then
        _wifi_set_radio_param "$band" "channel" "$channel"
        return
    fi

    local htmode=$(uci -q get "wireless.$radio.htmode" 2>/dev/null)
    local bw=20
    local mode_flag="ht"
    local sec_offset=""
    
    case "$htmode" in
        ""|NOHT) mode_flag=""; bw=20 ;;
        HT20|HE20|VHT20) mode_flag="ht"; bw=20 ;;
        HT40|HE40|VHT40)
            mode_flag="ht"; bw=40
            if [ "$band" = "24" ]; then
                [ "$channel" -le 7 ] && sec_offset="sec_channel_offset=1" || sec_offset="sec_channel_offset=-1"
            else
                sec_offset="sec_channel_offset=1"
            fi
            ;;
        VHT80|HE80|VHT160|HE160)
            _wifi_set_radio_param "$band" "channel" "$channel"
            return
            ;;
        *) mode_flag="ht"; bw=20 ;;
    esac

    local cmd_out
    if [ -n "$sec_offset" ]; then
        cmd_out=$(hostapd_cli -i "$iface" chan_switch 10 "$freq" "$sec_offset" bandwidth=$bw $mode_flag 2>&1)
    elif [ -n "$mode_flag" ]; then
        cmd_out=$(hostapd_cli -i "$iface" chan_switch 10 "$freq" "$mode_flag" bandwidth=$bw 2>&1)
    else
        cmd_out=$(hostapd_cli -i "$iface" chan_switch 10 "$freq" bandwidth=$bw 2>&1)
    fi

    if [ "$cmd_out" != "OK" ]; then
        _wifi_set_radio_param "$band" "channel" "$channel"
        return
    fi

    sleep 3
    local actual=$(iw dev "$iface" info 2>/dev/null | awk '/channel/ {print $2; exit}')
    if [ "$actual" != "$channel" ]; then
        _wifi_set_radio_param "$band" "channel" "$channel"
        return
    fi

    if [ "$htmode" != "NOHT" ] && [ -n "$htmode" ]; then
        if iw dev "$iface" info 2>/dev/null | grep -q "(no HT)"; then
            _wifi_set_radio_param "$band" "channel" "$channel"
            return
        fi
    fi

    (
        flock -w 30 200 || exit 1
        uci set "wireless.$radio.channel=$channel"
        uci commit wireless
    ) 200>/var/lock/wifi_fix.lock
}

_get_phy_for_iface() {
    local iface="$1"
    [ -z "$iface" ] && return 1
    local phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy" $2; exit}')
    [ -n "$phy" ] && echo "$phy" && return 0
    return 1
}

_wifi_apply_txpower_live() {
    local band="$1"
    local value="$2"
    local radio=$(_get_radio_path "$band")
    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"

    case "$value" in
        ''|*[!0-9]*)
            _wifi_set_radio_param "$band" "txpower" "$value"
            return
            ;;
    esac

    (
        flock -w 30 200 || exit 1
        uci set "wireless.$radio.txpower=$value"
        uci commit wireless
    ) 200>/var/lock/wifi_fix.lock

    local phy=$(_get_phy_for_iface "$iface")
    if [ -z "$phy" ] || ! command -v iw >/dev/null 2>&1; then
        _wifi_safe_reload
        return
    fi

    local mbm=$((value * 100))
    if ! iw phy "$phy" set txpower fixed "$mbm" 2>/dev/null; then
        _wifi_safe_reload
        return
    fi

    sleep 1
    local actual=$(iw dev "$iface" info 2>/dev/null | awk '/txpower/ {split($2,a,"."); print a[1]; exit}')

    if [ "$value" -gt 0 ] && [ "$actual" = "0" ]; then
        return 0
    fi

    if [ "$actual" != "$value" ]; then
        _wifi_safe_reload
    fi
}

_wifi_set_radio_param() {
    local band="$1"
    local param="$2"
    local value="$3"
    local radio=$(_get_radio_path "$band")

    (
    flock -w 60 200 || {
        exit 1
    }

    if [ -z "$value" ]; then
        uci delete "wireless.$radio.$param" 2>/dev/null
    else
        uci set "wireless.$radio.$param=$value"
    fi
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_fix_invalid_channel() {
    local band="$1"
    local lock_fd
    exec {lock_fd}>/var/lock/wifi_fix.lock
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        return 0
    fi

    local radio=$(_get_radio_path "$band")
    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
	
    if _wifi_has_sta_on_radio "$band"; then
        exec {lock_fd}>&-
        return 0
    fi

    local cur_ch=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
    if [ -z "$cur_ch" ] || [ "$cur_ch" = "auto" ]; then
        exec {lock_fd}>&-
        return 0
    fi

    local _u_c=$(uci -q get "wireless.$radio.country" 2>/dev/null)
    if [ -n "$_u_c" ] && [ "$_u_c" != "00" ]; then
        local _cur_reg=$(iw reg get 2>/dev/null | grep -m1 '^country' | awk '{print $2}' | tr -d ':')
        if [ "$_cur_reg" != "$_u_c" ]; then
            iw reg set "$_u_c" 2>/dev/null
            sleep 1
        fi
    fi

    local valid=$(iwinfo "$iface" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p')
    if echo "$valid" | grep -qx "$cur_ch"; then
        exec {lock_fd}>&-
        return 0
    fi

    local new_ch=$(iwinfo "$iface" freqlist 2>/dev/null | grep -vE 'RADAR_DETECTION|NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p' | sort -n | head -1)
    [ -z "$new_ch" ] && new_ch=$(echo "$valid" | sort -n | head -1)
    if [ -z "$new_ch" ]; then
        exec {lock_fd}>&-
        return 1
    fi

    uci set "wireless.$radio.channel=$new_ch"
    uci commit wireless
    exec {lock_fd}>&-
    return 2   
}

_wifi_autocheck_channels() {
    local lock_fd
    exec {lock_fd}>/var/lock/wifi_fix.lock
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        return 0
    fi

    local fixed=0
    local band radio iface cur_ch valid new_ch

    for band in "24" "5"; do
        radio=$(_get_radio_path "$band")
        iface="$INTERFACE_24"
        [ "$band" = "5" ] && iface="$INTERFACE_5"
        [ -z "$iface" ] && continue
		
        if _wifi_has_sta_on_radio "$band"; then
            echo "$(date): _wifi_autocheck_channels: пропускаю $band, так как активен STA" >> /tmp/telegram_bot/logs/bot.log
            continue
        fi

        cur_ch=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
        if [ -z "$cur_ch" ] || [ "$cur_ch" = "auto" ]; then
            continue
        fi

        local _u_c=$(uci -q get "wireless.$radio.country" 2>/dev/null)
        if [ -n "$_u_c" ] && [ "$_u_c" != "00" ]; then
            local _cur_reg=$(iw reg get 2>/dev/null | grep -m1 '^country' | awk '{print $2}' | tr -d ':')
            if [ "$_cur_reg" != "$_u_c" ]; then
                iw reg set "$_u_c" 2>/dev/null
                sleep 1
            fi
        fi

        valid=$(iwinfo "$iface" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p')
        if echo "$valid" | grep -qx "$cur_ch"; then
            continue
        fi

        new_ch=$(iwinfo "$iface" freqlist 2>/dev/null | grep -vE 'RADAR_DETECTION|NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p' | sort -n | head -1)
        [ -z "$new_ch" ] && new_ch=$(echo "$valid" | sort -n | head -1)
        [ -z "$new_ch" ] && continue

        uci set "wireless.$radio.channel=$new_ch"
        fixed=1
    done

    if [ "$fixed" = "1" ]; then
        uci commit wireless
        _wifi_safe_reload
        _wait_for_radio_ready 0 1 15 &
        _wait_for_radio_ready 1 1 15 &
        wait
    fi

    exec {lock_fd}>&-
    return 0
}

_wifi_set_country() {
    local band="$1"
    local country="$2"

    (
    flock -w 60 200 || exit 1

    if [ "$country" = "default" ]; then
        uci -q get wireless.radio0 >/dev/null 2>&1 && uci -q delete wireless.radio0.country
        uci -q get wireless.radio1 >/dev/null 2>&1 && uci -q delete wireless.radio1.country
        iw reg set 00 2>/dev/null
    else
        uci -q get wireless.radio0 >/dev/null 2>&1 && uci set wireless.radio0.country="$country"
        uci -q get wireless.radio1 >/dev/null 2>&1 && uci set wireless.radio1.country="$country"
        iw reg set "$country" 2>/dev/null
    fi

    local i
    for i in $(seq 1 5); do
        sleep 1
        local reg_now=$(iw reg get 2>/dev/null | grep -m1 '^country' | awk '{print $2}' | tr -d ':')
        if [ "$country" = "default" ]; then
            [ "$reg_now" = "00" ] && break
        else
            [ "$reg_now" = "$country" ] && break
        fi
    done

    local cur_ch24=$(uci -q get wireless.radio0.channel 2>/dev/null)
    local cur_ch5=$(uci -q get wireless.radio1.channel 2>/dev/null)

    local valid24=$(iwinfo "$INTERFACE_24" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p')
    local valid5=$(iwinfo "$INTERFACE_5" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p')

    local ch24 ch5

    if [ -n "$cur_ch24" ] && [ "$cur_ch24" != "auto" ] && echo "$valid24" | grep -qx "$cur_ch24"; then
        ch24="$cur_ch24"
    else
        ch24=$(iwinfo "$INTERFACE_24" freqlist 2>/dev/null | grep -vE 'RADAR_DETECTION|NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p' | sort -n | head -1)
        [ -z "$ch24" ] && ch24=$(echo "$valid24" | sort -n | head -1)
        [ -z "$ch24" ] && ch24=1
    fi

    if [ -n "$cur_ch5" ] && [ "$cur_ch5" != "auto" ] && echo "$valid5" | grep -qx "$cur_ch5"; then
        ch5="$cur_ch5"
    else
        ch5=$(iwinfo "$INTERFACE_5" freqlist 2>/dev/null | grep -vE 'RADAR_DETECTION|NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p' | sort -n | head -1)
        [ -z "$ch5" ] && ch5=$(echo "$valid5" | sort -n | head -1)
        [ -z "$ch5" ] && ch5=36
    fi

    uci -q get wireless.radio0 >/dev/null 2>&1 && uci set wireless.radio0.channel="$ch24"
    uci -q get wireless.radio1 >/dev/null 2>&1 && uci set wireless.radio1.channel="$ch5"
    uci -q get wireless.radio0 >/dev/null 2>&1 && uci -q delete wireless.radio0.acs_exclude_dfs
    uci -q get wireless.radio1 >/dev/null 2>&1 && uci -q delete wireless.radio1.acs_exclude_dfs

    for r in radio0 radio1; do
        uci -q delete wireless.$r.vht_oper_chwidth
        uci -q delete wireless.$r.vht_oper_centr_freq_seg0_idx
        uci -q delete wireless.$r.vht_oper_centr_freq_seg1_idx
        uci -q delete wireless.$r.he_bss_color
        uci -q delete wireless.$r.he_ldpc
        uci -q delete wireless.$r.he_su_beamformer
        uci -q delete wireless.$r.he_su_beamformee
        uci -q delete wireless.$r.he_mu_beamformer
        uci -q delete wireless.$r.he_operation
        uci -q delete wireless.$r.he_mu_edca
        uci -q delete wireless.$r.he_csa
        uci -q delete wireless.$r.require_mode
    done

    local _err_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}'
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек страны." "$_err_kb" >/dev/null 2>&1
        return 1
    fi

    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi при смене страны." "$_err_kb" >/dev/null 2>&1
        return 1
    fi

    local iface
    for iface in "$INTERFACE_24" "$INTERFACE_5"; do
        [ -z "$iface" ] && continue
        ip link show "$iface" >/dev/null 2>&1 || continue
        if ! ip link show "$iface" | grep -q "UP"; then
            ip link set "$iface" up 2>/dev/null
        fi
    done

    show_wifi_radio_select_country "$band"
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_get_channel_list() {
    local band="$1"
    local country="$2"      
    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
    local radio=$(_get_radio_path "$band")

    local uci_country=$(uci -q get "wireless.$radio.country" 2>/dev/null)
    if [ -n "$uci_country" ] && [ "$uci_country" != "00" ]; then
        local cur_reg=$(iw reg get 2>/dev/null | grep -m1 '^country' | awk '{print $2}' | tr -d ':')
        if [ "$cur_reg" != "$uci_country" ]; then
            iw reg set "$uci_country" 2>/dev/null
            sleep 1
        fi
    fi

    local htmode=$(uci -q get "wireless.$radio.htmode" 2>/dev/null)
    local legacy=$(uci -q get "wireless.$radio.legacy_rates" 2>/dev/null)
    [ -z "$legacy" ] && legacy="0"
    local allow_ch14=0
    if [ "$band" = "24" ] && { [ "$htmode" = "NOHT" ] || [ -z "$htmode" ]; } && [ "$legacy" = "1" ]; then
        allow_ch14=1
    fi

    local list=$(iwinfo "$iface" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p' | sort -n | uniq)

    if [ -z "$list" ]; then
        local phy="phy0"
        [ "$band" = "5" ] && phy="phy1"
        list=$(iw phy "$phy" info 2>/dev/null | grep -E '^\s*\* [0-9]+ MHz \[[0-9]+\]' | grep -v '(disabled)' | awk -F'[][]' '{print $2}' | sort -n | uniq)
    fi

    local filtered=""
    local ch
    for ch in $list; do
        if [ "$ch" = "14" ] && [ "$allow_ch14" != "1" ]; then continue; fi
        filtered="$filtered $ch"
    done

    if [ -z "$filtered" ]; then
        local cur_ch=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
        if [ -n "$cur_ch" ] && [ "$cur_ch" != "auto" ]; then filtered=" $cur_ch"; fi
    fi

    local result="auto"
    for ch in $filtered; do result="$result $ch"; done
    echo "$result"
}

_wifi_get_power_list() {
    local band="$1"
    local iface="$INTERFACE_24"
    local phy="phy0"
    [ "$band" = "5" ] && { iface="$INTERFACE_5"; phy="phy1"; }

    local list=$(iwinfo "$iface" txpowerlist 2>/dev/null | awk '{ for(i=1;i<=NF;i++) if(tolower($i)=="dbm"){ print $(i-1); break } }' | sort -n | uniq)
    if [ -z "$list" ] && [ -n "$phy" ]; then
        list=$(iwinfo "$phy" txpowerlist 2>/dev/null | awk '{ for(i=1;i<=NF;i++) if(tolower($i)=="dbm"){ print $(i-1); break } }' | sort -n | uniq)
    fi

    if [ -n "$list" ]; then
        echo "$list" | tr '\n' ' '
        echo "|0"  
        return 0
    fi

    local out="" i
    for i in $(seq 0 20); do out="$out $i"; done
    echo "$out"
    echo "|1" 
}

_wifi_get_current_power() {
    local band="$1"
    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
    local list=$(iwinfo "$iface" txpowerlist 2>/dev/null)
    if [ -n "$list" ]; then
        echo "$list" | grep -m1 -E '^\*' | grep -oE '[0-9]+' | head -1
    else
        echo ""
    fi
}

_wifi_get_width_list() {
    local band="$1"
    local standard="$2"
    local widths=()
    if [ "$band" = "24" ]; then
        widths=("HT20" "HT40")
        if [ "$standard" = "ax" ]; then widths=("HE20" "HE40"); fi
    else
        widths=("HT20" "HT40")
        if [ "$standard" = "ac" ]; then
            widths=("VHT20" "VHT40" "VHT80" "VHT160")
        elif [ "$standard" = "ax" ]; then
            widths=("HE20" "HE40" "HE80" "HE160")
        fi
    fi
    echo "${widths[@]}"
}

_wifi_standard_display() {
    local htmode="$1"
    if [ -z "$htmode" ]; then
        echo "N/A"
        return
    fi
    case "$htmode" in
        HE*) echo "ax" ;;
        VHT*) echo "ac" ;;
        HT*) echo "n" ;;
        NOHT) echo "Legacy" ;;
        *) echo "$htmode" ;;
    esac
}

_wifi_has_sta_on_radio() {
    local band="$1"
    local radio=$(_get_radio_path "$band")
    local sec
    for sec in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        local dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
        local mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
        local disabled=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
        if [ "$dev" = "$radio" ] && [ "$mode" = "sta" ] && [ "$disabled" != "1" ]; then
            return 0
        fi
    done
    return 1
}

_wifi_save_radio_params() {
    local radio="$1"
    [ -z "$radio" ] && return 1
    local save_file="/tmp/telegram_bot/wifi/radio_saved_${radio}.txt"
    local tmp_file="${save_file}.tmp.$$"

    if [ -f "$save_file" ] && [ -s "$save_file" ]; then return 0; fi

    local cur_channel=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
    local cur_htmode=$(uci -q get "wireless.$radio.htmode" 2>/dev/null)
    [ -z "$cur_channel" ] && cur_channel="auto"

    {
        echo "channel=$cur_channel"
        echo "htmode=$cur_htmode"
    } > "$tmp_file"

    if [ -s "$tmp_file" ]; then mv "$tmp_file" "$save_file"; else rm -f "$tmp_file"; return 1; fi
    return 0
}

_wifi_restore_radio_params() {
    local radio="$1"
    [ -z "$radio" ] && return 1
    local save_file="/tmp/telegram_bot/wifi/radio_saved_${radio}.txt"
    if [ ! -s "$save_file" ]; then return 0; fi

    local saved_channel=""
    local saved_htmode=""

    while IFS='=' read -r key value; do
        case "$key" in
            channel) saved_channel="$value" ;;
            htmode)  saved_htmode="$value" ;;
        esac
    done < "$save_file"

    local changed=0

    if [ -n "$saved_channel" ]; then
        local iface="$INTERFACE_24"
        [ "$radio" = "radio1" ] && iface="$INTERFACE_5"

        if [ -n "$iface" ] && [ "$saved_channel" != "auto" ]; then
            local valid_channels=$(iwinfo "$iface" freqlist 2>/dev/null | grep -v 'NO_IR' | sed -n 's/.*Channel \([0-9]\+\).*/\1/p')
            if [ -n "$valid_channels" ] && ! echo "$valid_channels" | grep -qx "$saved_channel"; then
                saved_channel=""
            fi
        fi

        if [ -n "$saved_channel" ]; then
            local cur_channel=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
            if [ "$cur_channel" != "$saved_channel" ]; then
                uci set "wireless.$radio.channel=$saved_channel"
                changed=1
            fi
        fi
    fi

    if [ -n "$saved_htmode" ]; then
        local cur_htmode=$(uci -q get "wireless.$radio.htmode" 2>/dev/null)
        if [ "$cur_htmode" != "$saved_htmode" ]; then
            uci set "wireless.$radio.htmode=$saved_htmode"
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then uci commit wireless; fi
    rm -f "$save_file"
    return 0
}

# ==============================================================================
# 🖥️ РАЗДЕЛ 5: UI РАДИО И ОСНОВНЫЕ НАСТРОЙКИ
# ==============================================================================

_wifi_build_radio_settings_content() {
    local band="$1"
    [ -z "$band" ] && band="24"
    local radio=$(_get_radio_path "$band")
    local freq="2.4"
    [ "$band" = "5" ] && freq="5"

    local channel=$(_wifi_get_radio_param "$band" "channel")
    local htmode=$(_wifi_get_radio_param "$band" "htmode")
    if [ -z "$htmode" ]; then
        htmode=$(ubus call network.wireless status 2>/dev/null | jq -r ".$(_get_radio_path "$band").config.htmode" 2>/dev/null)
    fi
    local standard_display=$(_wifi_standard_display "$htmode")
    if [ "$standard_display" = "Legacy" ]; then
        if [ "$band" = "24" ]; then standard_display="b/g"; else standard_display="a"; fi
    fi
    local country=$(_wifi_get_radio_param "$band" "country")
    [ "$country" = "default" ] && country="Default"
    local txpower=$(_wifi_get_radio_param "$band" "txpower")
    local disabled=$(uci -q get "wireless.$radio.disabled" 2>/dev/null || echo "0")
    local legacy=$(uci -q get "wireless.$radio.legacy_rates" 2>/dev/null || echo "0")
    [ "$legacy" = "1" ] && legacy="true" || legacy="false"

    local status_icon="🟢"
    [ "$disabled" = "1" ] && status_icon="🔴"

    local channel_locked="false"
    if _wifi_has_sta_on_radio "$band"; then channel_locked="true"; fi

    local safe_country=$(html_escape "$country")
    local legacy_label="🔲"
    [ "$legacy" = "true" ] && legacy_label="✅"
    local legacy_status=""
    if [ "$band" = "24" ]; then
        legacy_status="$([ "$legacy" = "true" ] && echo "Включён" || echo "Отключён")"
    else
        legacy_status="---"
    fi

    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
    local real_freq=""
    if [ -n "$iface" ]; then
        IFS='|' read -r _ real_freq _ _ _ <<< "$(_parse_radio_info "$iface")"
        if [ -z "$real_freq" ] || [ "$real_freq" = "N/A" ]; then real_freq="${freq} GHz"; fi
    else
        real_freq="${freq} GHz"
    fi

    local col1="Страна: ${safe_country}"
    local col2="Канал: ${channel} (${real_freq})"
    local col3="Стандарт: ${standard_display}"
    
    while [ ${#col1} -lt 23 ]; do col1="$col1 "; done
    while [ ${#col2} -lt 23 ]; do col2="$col2 "; done
    while [ ${#col3} -lt 23 ]; do col3="$col3 "; done

    local table="<pre>🎛️ НАСТРОЙКИ RADIO${radio#radio} (${freq} GHz) ${status_icon}

${SEP46}
${col1}        Мощность: ${txpower} dBm
${col2}        Ширина: ${htmode}
${col3}        802.11b: ${legacy_status}
${SEP46}
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите параметр для изменения:</pre>"

    local buttons=""
    buttons="$buttons[{\"text\":\"🌍 Страна\",\"callback_data\":\"wifi_radio_${band}_country\"},{\"text\":\"⚡ Мощность\",\"callback_data\":\"wifi_radio_${band}_txpower\"}],"
    if [ "$channel_locked" = "false" ]; then
        buttons="$buttons[{\"text\":\"🔢 Канал\",\"callback_data\":\"wifi_radio_${band}_channel\"},{\"text\":\"↔️ Ширина\",\"callback_data\":\"wifi_radio_${band}_width\"}],"
    else
        buttons="$buttons[{\"text\":\"🔒 Канал\",\"callback_data\":\"wifi_nop_channel\"},{\"text\":\"↔️ Ширина\",\"callback_data\":\"wifi_radio_${band}_width\"}],"
    fi
    buttons="$buttons[{\"text\":\"📡 Стандарт\",\"callback_data\":\"wifi_radio_${band}_standard\"},"
    if [ "$band" = "24" ]; then
        local legacy_label="🔲"
        [ "$legacy" = "true" ] && legacy_label="✅"
        buttons="${buttons}{\"text\":\"${legacy_label}  ⚙️ 802.11b\",\"callback_data\":\"wifi_radio_${band}_legacy_toggle\"}"
    else
        buttons="${buttons}{\"text\":\"🔒 802.11b\",\"callback_data\":\"wifi_nop_80211b\"}"
    fi
    buttons="$buttons],"
    buttons="$buttons[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_back_main\"},{\"text\":\"🔄 Обновить\",\"callback_data\":\"wifi_radio_${band}_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"

    local keyboard="{\"inline_keyboard\":[$buttons]}"
    echo "$table|$keyboard"
}

show_wifi_main() {
    touch /tmp/telegram_bot/wifi/active.lock
    _wifi_set_current_menu "main"
    _wifi_set_current_band "24"
    _wifi_set_current_create_type ""

    if [ -f "/tmp/telegram_bot/state/bot_menu_msg_id" ]; then
        cat "/tmp/telegram_bot/state/bot_menu_msg_id" > "$WIFI_MSG_ID_FILE"
        rm -f "/tmp/telegram_bot/state/bot_menu_msg_id"
    fi

    local fix24 fix5
    _wifi_fix_invalid_channel "24"; fix24=$?
    _wifi_fix_invalid_channel "5";  fix5=$?

    if [ "$fix24" = "2" ] || [ "$fix5" = "2" ]; then
        _wifi_safe_reload
        _wait_for_radio_ready 0 1 15 &
        _wait_for_radio_ready 1 1 15 &
        wait
    fi

    IFS='|' read -r ch24 freq24 bitrate24 signal24 noise24 <<< "$(_parse_radio_info "$INTERFACE_24")"
    IFS='|' read -r ch5 freq5 bitrate5 signal5 noise5 <<< "$(_parse_radio_info "$INTERFACE_5")"

    local table="<pre>📡 СТАТУС РАДИО

${SEP46}
RADIO0 (2.4 GHz)
 Канал: ${ch24} (${freq24})        Битрейт: ${bitrate24}
  
RADIO1 (5 GHz)
 Канал: ${ch5} (${freq5})       Битрейт: ${bitrate5}
${SEP46}
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите действие:</pre>"

    local keyboard='{"inline_keyboard":[
        [{"text":"⚙️ Radio0️⃣ (2.4 GHz)","callback_data":"wifi_radio_0"},{"text":"Перезапустить 0️⃣","callback_data":"wifi_restart_radio_0"}],
        [{"text":"⚙️ Radio1️⃣ (5 GHz)","callback_data":"wifi_radio_1"},{"text":"Перезапустить 1️⃣","callback_data":"wifi_restart_radio_1"}],
        [{"text":"🌐 Управление сетями (VIF)","callback_data":"wifi_vif_menu"}],
        [{"text":"🔄 Обновить","callback_data":"wifi_refresh_status"},{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]
    ]}'

    if [ -f "$WIFI_MSG_ID_FILE" ] && [ -s "$WIFI_MSG_ID_FILE" ]; then
        _wifi_send_edit "$table" "$keyboard"
    else
        _wifi_send_main "$table" "$keyboard"
    fi
}

show_wifi_radio_settings() {
    local band="$1"
    _wifi_set_current_menu "radio_settings"
    _wifi_set_current_band "$band"

    local fix_rc
    _wifi_fix_invalid_channel "$band"; fix_rc=$?
    if [ "$fix_rc" = "2" ]; then
        _wifi_safe_reload
        local _radio_num
        [ "$band" = "5" ] && _radio_num=1 || _radio_num=0
        _wait_for_radio_ready "$_radio_num" 1 15
    fi

    local content=$(_wifi_build_radio_settings_content "$band")
    local table="${content%|*}"
    local keyboard="${content#*|}"
    _wifi_send_edit "$table" "$keyboard"
}

show_wifi_radio_channel() {
    local band="$1"
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "channel"
    _wifi_set_current_band "$band"
    
    if _wifi_has_sta_on_radio "$band"; then
        _wifi_send_main "❌ <b>Изменение канала заблокировано!</b>
На данном радиомодуле активен режим Клиента (STA). 
Канал фиксирован внешней сетью." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_radio_'"$band"'"}]]}'
        return
    fi

    local current=$(_wifi_get_radio_param "$band" "channel")
    local country=$(_wifi_get_radio_param "$band" "country")
    local channels=($(_wifi_get_channel_list "$band" "$country"))

    local table="<pre>🔢 ВЫБОР КАНАЛА

${SEP46}
${SEP46}
Текущий канал: ${current}
${SEP46}
${SEP46}

Выберите канал:</pre>"

    local buttons=""
    local row=""
    local cnt=0
    for ch in "${channels[@]}"; do
        local label="$ch"
        [ "$ch" = "$current" ] && label="✅ $ch" || label="🔲 $ch"
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_radio_${band}_set_channel_$ch\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 5 ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[$row]"
    fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_radio_${band}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"
    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

show_wifi_radio_txpower() {
    local band="$1"
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "txpower"
    _wifi_set_current_band "$band"
    
    local country=$(_wifi_get_radio_param "$band" "country")
    [ "$country" = "default" ] && country="Default"
    local current_uci=$(_wifi_get_radio_param "$band" "txpower")
    local current_iwinfo=$(_wifi_get_current_power "$band")
    [ -z "$current_iwinfo" ] && current_iwinfo="$current_uci"
    
    local _raw_power=$(_wifi_get_power_list "$band")
    local power_list="${_raw_power%|*}"
    local _is_fallback="${_raw_power#*|}"
    local powers=($power_list)
    local min=${powers[0]}
    local max="${powers[$((${#powers[@]} - 1))]}"

    local _range_note=""
    if [ "$_is_fallback" = "1" ]; then
        _range_note="
⚠️ Интерфейс не поднят, диапазон приблизительный.
Реальные значения определит драйвер при применении."
    fi

    local table="<pre>⚡ ВЫБОР МОЩНОСТИ

${SEP46}
${SEP46}
Страна: ${country}
Диапазон: ${min}–${max} dBm${_range_note}
Текущая: ${current_iwinfo} dBm
${SEP46}
${SEP46}

Выберите уровень мощности:</pre>"

    local buttons=""
    local row=""
    local cnt=0
    for p in "${powers[@]}"; do
        local label="$p"
        [ "$p" = "$current_iwinfo" ] && label="✅ $p" || label="🔲 $p"
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_radio_${band}_set_power_$p\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 6 ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[$row]"
    fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_radio_${band}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"
    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

show_wifi_radio_width() {
    local band="$1"
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "width"
    _wifi_set_current_band "$band"
    
    local current=$(_wifi_get_radio_param "$band" "htmode")
    local standard=$(_wifi_standard_display "$current")
    local widths=($(_wifi_get_width_list "$band" "$standard"))

    if [ "$band" = "24" ]; then
        local channel=$(_wifi_get_radio_param "$band" "channel")
        if [ "$channel" != "auto" ] && [ "$channel" != "0" ] && [ -n "$channel" ]; then
            local filtered=()
            for w in "${widths[@]}"; do
                local allow=1
                case "$w" in
                    HT40|HE40)
                        if [ "$channel" -ge 1 ] && [ "$channel" -le 7 ]; then allow=1
                        elif [ "$channel" -ge 5 ] && [ "$channel" -le 13 ]; then allow=1
                        else allow=0; fi
                        ;;
                    *) allow=1 ;;
                esac
                [ $allow -eq 1 ] && filtered+=("$w")
            done
            widths=("${filtered[@]}")
        fi
    fi

    local found=0
    for w in "${widths[@]}"; do [ "$w" = "$current" ] && found=1; done
    [ $found -eq 0 ] && widths+=("$current")

    local table="<pre>↔️ ВЫБОР ШИРИНЫ КАНАЛА

${SEP46}
${SEP46}
Текущая: ${current}
${SEP46}
${SEP46}

Выберите ширину:</pre>"

    local buttons=""
    local row=""
    local cnt=0
    for w in "${widths[@]}"; do
        local label="$w"
        [ "$w" = "$current" ] && label="✅ $w" || label="🔲 $w"
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_radio_${band}_set_width_$w\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 4 ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[$row]"
    fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_radio_${band}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"
    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

show_wifi_radio_standard() {
    local band="$1"
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "standard"
    _wifi_set_current_band "$band"
    
    local current_htmode=$(_wifi_get_radio_param "$band" "htmode")
    local current_display=$(_wifi_standard_display "$current_htmode")
    if [ "$current_display" = "Legacy" ]; then
        if [ "$band" = "24" ]; then current_display="b/g"; else current_display="a"; fi
    fi

    local current_short=""
    case "$current_htmode" in
        HE*) current_short="ax" ;;
        VHT*) current_short="ac" ;;
        HT*) current_short="n" ;;
        NOHT) current_short="legacy" ;;
        *) current_short="$current_htmode" ;;
    esac

    local modes=()
    if [ "$band" = "24" ]; then
        modes=("legacy|b/g" "n|N" "ax|AX")
    else
        modes=("legacy|a" "n|N" "ac|AC" "ax|AX")
    fi

    local table="<pre>📡 ВЫБОР СТАНДАРТА

${SEP46}
${SEP46}
Текущий: ${current_display}
${SEP46}
${SEP46}

Выберите стандарт:</pre>"

    local row=""
    for item in "${modes[@]}"; do
        local code="${item%|*}"
        local label="${item#*|}"
        if [ "$code" = "$current_short" ]; then label="✅ $label"; else label="🔲 $label"; fi
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_radio_${band}_set_standard_$code\"}"
    done

    local buttons=""
    if [ -n "$row" ]; then buttons="[$row]"; fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_radio_${band}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"

    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

show_wifi_radio_select_country() {
    local band="$1"
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "country"
    _wifi_set_current_band "$band"
    
    local current=$(_wifi_get_radio_param "$band" "country")
    local min=0
    local max=20
    
    sleep 1
    local power_list=$(_wifi_get_power_list "$band")
    local powers=($power_list)
    
    if [ ${#powers[@]} -ge 1 ]; then
        min=${powers[0]}
        max="${powers[$((${#powers[@]} - 1))]}"
    fi
    
    _show_country_table "$band" "$current" "$min" "$max"
}

_show_country_table() {
    local band="$1"
    local current="$2"
    local min="$3"
    local max="$4"

    if [ -z "$min" ] || [ -z "$max" ] || { [ "$min" -eq 0 ] && [ "$max" -eq 0 ]; }; then
        min=0
        max=20
    fi

    local countries=("default|Default" "PA|🇵🇦 PA")
    local current_display="$current"
    [ "$current_display" = "default" ] && current_display="Default"

    local table="<pre>🌍 ВЫБОР СТРАНЫ

${SEP46}
${SEP46}
Текущая страна: ${current_display}
Доступный диапазон: ${min}–${max} dBm
${SEP46}
${SEP46}

Выберите страну:</pre>"

    local buttons=""
    local row=""
    local cnt=0
    local item code label
    for item in "${countries[@]}"; do
        code="${item%|*}"
        label="${item#*|}"
        if [ "$code" = "$current" ]; then label="✅ $label"; else label="🔲 $label"; fi
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_radio_${band}_set_country_$code\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 2 ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[$row]"
    fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_radio_${band}\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"
    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

_wifi_toggle_legacy() {
    local band="$1"
    if [ "$band" != "24" ]; then return; fi

    (
    flock -w 60 200 || exit 1

    local radio=$(_get_radio_path "$band")
    local current=$(uci -q get "wireless.$radio.legacy_rates" 2>/dev/null || echo "0")
    if [ "$current" = "1" ]; then
        uci set "wireless.$radio.legacy_rates=0"
    else
        uci set "wireless.$radio.legacy_rates=1"
    fi
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    local content=$(_wifi_build_radio_settings_content "$band")
    local table="${content%|*}"
    local keyboard="${content#*|}"
    _wifi_send_edit "$table" "$keyboard"
        ) 200>/var/lock/wifi_fix.lock
}

# ==============================================================================
# 🌐 РАЗДЕЛ 6: УПРАВЛЕНИЕ СЕТЯМИ (VIF) И РЕДАКТИРОВАНИЕ
# ==============================================================================

show_wifi_vif_menu() {
    _wifi_set_current_menu "vif_menu"
    _wifi_set_current_create_type ""

    local list=""
    local num=1
    local section_names=()
    local ssids=()
    local devices=()
    local modes=()
    local disableds=()

    local _sec_real
    for _sec_real in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        local mode=$(uci -q get "wireless.$_sec_real.mode" 2>/dev/null)
        [ -z "$mode" ] && continue

        local ssid=$(uci -q get "wireless.$_sec_real.ssid" 2>/dev/null)
        local device=$(uci -q get "wireless.$_sec_real.device" 2>/dev/null)
        local disabled=$(uci -q get "wireless.$_sec_real.disabled" 2>/dev/null)
        [ -z "$disabled" ] && disabled="0"

        local display_name=""
        if [ "$mode" = "mesh" ]; then display_name=$(uci -q get "wireless.$_sec_real.mesh_id" 2>/dev/null)
        else display_name="$ssid"; fi
        [ -z "$display_name" ] && display_name="Unnamed"

        section_names+=("$_sec_real")
        ssids+=("$display_name")
        devices+=("${device:-radio?}")
        modes+=("$mode")
        disableds+=("$disabled")

        local dev_short="${device:-radio?}"
        local ssid_display="$display_name"
        local status_icon="🟢"
        if [ "$disabled" = "1" ]; then
            status_icon="🔴"
        elif [ "$mode" = "sta" ]; then
            local _sta_iface=$(ubus call network.wireless status 2>/dev/null | jq -r --arg sec "$_sec_real" '.[] | .interfaces[]? | select(.section == $sec) | .ifname' 2>/dev/null | head -1)
            if [ -n "$_sta_iface" ] && iw dev "$_sta_iface" link 2>/dev/null | grep -q "Not connected"; then
                status_icon="🔴"
            fi
        fi

        local mode_display=""
        case "$mode" in
            "ap")   mode_display="[ ap ]" ;;
            "sta")  mode_display="[sta ]" ;;
            "mesh") mode_display="[mesh]" ;;
            *)      mode_display="[$mode]" ;;
        esac

        local _raw_name="$ssid_display"
        if [ ${#_raw_name} -gt 25 ]; then _raw_name="${_raw_name:0:24}…"; fi
        local _raw_len=${#_raw_name}
        local _name=$(html_escape "$_raw_name")
        local _pad=$((25 - _raw_len))
        [ "$_pad" -lt 0 ] && _pad=0
        local _sp=$(printf '%*s' "$_pad" '')
        
        list="${list}${num}|${dev_short}|${mode_display}|${_name}${_sp}|${status_icon}"$'\n'
        num=$((num+1))
    done

    local total=0
    if [ -z "$list" ]; then
        list="   Нет созданных сетей.\n"
    else
        total="${#section_names[@]}"
    fi

    {
        echo "${#section_names[@]}"
        for i in "${!section_names[@]}"; do
            echo "${section_names[$i]}|${ssids[$i]}|${devices[$i]}|${modes[$i]}|${disableds[$i]}"
        done
    } > /tmp/telegram_bot/wifi/vif_list

    local formatted_list=""
    if [ "$total" -gt 0 ]; then
        local _hdr_name="Имя"
        local _hdr_pad=$((25 - ${#_hdr_name}))
        [ "$_hdr_pad" -lt 0 ] && _hdr_pad=0
        local _hdr_name_field="${_hdr_name}$(printf '%*s' "$_hdr_pad" '')"

        formatted_list="№  Радио  Тип     ${_hdr_name_field}  Статус"$'\n'
        formatted_list="${formatted_list}-- ------ ------  -------------------------  ------"$'\n'

        local _n _d _m _nm _s _row
        while IFS='|' read -r _n _d _m _nm _s; do
            [ -z "$_n" ] && continue
            printf -v _row "%-2s %-6s %-6s  %s    %s  " "$_n" "$_d" "$_m" "$_nm" "$_s"
            formatted_list="${formatted_list}${_row}"$'\n'
        done <<< "$list"
    else
        formatted_list="   Нет созданных сетей."$'\n'
    fi

    local table="<pre>🌐 СПИСОК СЕТЕЙ (VIF)

${SEP46}
${formatted_list}${SEP46}
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите сеть для настройки или создайте новую</pre>"

    local buttons=""
    local row=""
    local cnt=0
    if [ "$total" -gt 0 ]; then
        for ((i=1; i<=total; i++)); do
            [ -n "$row" ] && row="$row,"
            row="$row{\"text\":\"$i\",\"callback_data\":\"wifi_vif_select_$i\"}"
            cnt=$((cnt+1))
            if [ $cnt -eq 5 ]; then
                [ -n "$buttons" ] && buttons="$buttons,"
                buttons="$buttons[$row]"
                row=""
                cnt=0
            fi
        done
        if [ -n "$row" ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
        fi
        buttons="$buttons,"
    fi

    buttons="$buttons[{\"text\":\"👥 Гостевая сеть\",\"callback_data\":\"wifi_create_guest\"},{\"text\":\"📡 Клиент (STA)\",\"callback_data\":\"wifi_create_sta\"}],"
    buttons="$buttons[{\"text\":\"🏠 Точка доступа (AP)\",\"callback_data\":\"wifi_create_ap\"}],"
    buttons="$buttons[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_back_main\"},{\"text\":\"🔄 Обновить\",\"callback_data\":\"wifi_vif_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"

    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_edit "$table" "$keyboard"
}

_wifi_build_network_edit_content() {
    local section="$1"
    local ssid="$2"
    local device="$3"
    local mode="$4"
    local disabled="$5"

    local key=$(uci -q get "wireless.$section.key" 2>/dev/null || echo "")
    local enc=$(uci -q get "wireless.$section.encryption" 2>/dev/null || echo "none")
    local enc_display=$(_wifi_enc_display "$enc")
    local mode_display=$(_wifi_mode_display "$mode")
    local safe_ssid=$(html_escape "$ssid")

    local status_icon="🟢"
    local status_text="Включена"
    local toggle_text="Выключить"
    if [ "$disabled" = "1" ]; then
        status_icon="🔴"
        status_text="Выключена"
        toggle_text="Включить"
    fi

    local show_password_file="/tmp/telegram_bot/wifi/show_password_${section}.txt"
    local show_password="false"
    if [ -f "$show_password_file" ]; then
        show_password=$(cat "$show_password_file" 2>/dev/null || echo "false")
    fi

    local password_display=""
    if [ -z "$key" ]; then
        password_display="(не задан)"
    elif [ "$show_password" = "true" ]; then
        password_display="$key"
    else
        password_display=$(printf '%*s' ${#key} '' | tr ' ' '*')
    fi

    local eye_label="👁️ Показать"
    if [ "$show_password" = "true" ]; then
        eye_label="🔒 Скрыть"
    fi

    local table="<pre>📡 Управление сетью ${safe_ssid}

${SEP46}
Радио: ${device}
Режим: ${mode_display}
SSID: ${safe_ssid}
Пароль: ${password_display}
Шифрование: ${enc_display}
Статус: ${status_icon} ${status_text}
${SEP46}
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите действие:</pre>"

    local keyboard='{"inline_keyboard":[
        [{"text":"✏️ SSID","callback_data":"wifi_edit_ssid"},{"text":"🔑 Пароль","callback_data":"wifi_edit_key"}],
        [{"text":"🔒 Шифрование","callback_data":"wifi_edit_encryption"},{"text":"'"${eye_label}"'","callback_data":"wifi_show_password_toggle"}],
        [{"text":"🔃 '"${toggle_text}"'","callback_data":"wifi_toggle_network"},{"text":"🗑️ Удалить","callback_data":"wifi_delete_network"}],
        [{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"},{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]
    ]}'

    echo "$table|$keyboard"
}

show_wifi_network_edit() {
    local section="$1"
    local ssid="$2"
    local device="$3"
    local mode="$4"
    local disabled="$5"
    local use_edit="${6:-true}"
    _wifi_set_current_menu "network_edit"

    rm -f /tmp/telegram_bot/wifi/create_type "$WIFI_CREATE_RADIO_FILE"
    echo "$section" > "$WIFI_EDIT_SECTION_FILE"

    local content=$(_wifi_build_network_edit_content "$section" "$ssid" "$device" "$mode" "$disabled")
    local table="${content%|*}"
    local keyboard="${content#*|}"

    if [ "$use_edit" = "true" ]; then
        _wifi_send_edit "$table" "$keyboard"
    else
        _wifi_send_main "$table" "$keyboard"
    fi
}

_wifi_edit_ssid_start() {
    echo "edit_ssid" > "$WIFI_EDIT_MODE_FILE"
    _wifi_send_prompt "✏️ Введите новый SSID (от 1 до 32 символов):" \
        '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
}

_wifi_edit_ssid_finish() {
    (
    trap '_bot_mark_busy_end' EXIT
    local new_ssid="$1"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    _bot_mark_busy_start "wifi_edit"
    
    if [ -z "$section" ]; then
        _wifi_send_main "❌ Ошибка: секция не определена." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    uci set "wireless.$section.ssid=$new_ssid"
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
    [ -z "$disabled" ] && disabled="0"

    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="✅ <b>Имя сети изменено</b>" -d parse_mode="HTML" > /dev/null 2>&1
    show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled" "false"
    )
}

_wifi_edit_key_start() {
    echo "edit_key" > "$WIFI_EDIT_MODE_FILE"
    _wifi_send_prompt "🔑 Введите новый пароль (мин. 8 симв. 
или введите 1 символ для открытой сети)" \
        '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
}

_wifi_edit_key_finish() {
    (
    trap '_bot_mark_busy_end' EXIT
    local new_key="$1"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    _bot_mark_busy_start "wifi_edit"
    
    if [ -z "$section" ]; then
        _wifi_send_main "❌ Ошибка: секция не определена." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    if [ -z "$new_key" ]; then
        uci set "wireless.$section.encryption=none"
        uci -q delete "wireless.$section.key"
    else
        uci set "wireless.$section.key=$new_key"
        local current_enc=$(uci -q get "wireless.$section.encryption")
        if [ -z "$current_enc" ] || [ "$current_enc" = "none" ]; then
            uci set "wireless.$section.encryption=psk2"
        fi
    fi

    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
    [ -z "$disabled" ] && disabled="0"

    if [ -z "$new_key" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="✅ <b>Сеть стала открытой (без пароля)</b>" -d parse_mode="HTML" > /dev/null 2>&1
    else
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="✅ <b>Пароль изменён</b>" -d parse_mode="HTML" > /dev/null 2>&1
    fi
    show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled" "false"
    )
}

_wifi_edit_encryption_start() {
    local response
    _wifi_set_current_menu "encryption"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    if [ -z "$section" ]; then
        _wifi_send_main "❌ Ошибка: секция не определена." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi
    local current=$(uci -q get "wireless.$section.encryption" 2>/dev/null || echo "none")
    local encs=(
        "psk-mixed|WPA/WPA2"
        "psk2|WPA2-PSK"
        "sae-mixed|WPA2/WPA3"
        "sae|WPA3-SAE"
        "owe|OWE"
        "none|Open"
    )

    local table="<pre>🔒 ВЫБОР ШИФРОВАНИЯ

${SEP46}
${SEP46}
Текущий: $(_wifi_enc_display "$current")
${SEP46}
${SEP46}

Выберите тип шифрования:</pre>"

    local buttons=""
    local row=""
    local cnt=0
    for item in "${encs[@]}"; do
        local code="${item%|*}"
        local label="${item#*|}"
        if [ "$code" = "$current" ]; then label="✅ $label"; else label="🔲 $label"; fi
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$label\",\"callback_data\":\"wifi_enc_set_$code\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 2 ]; then
            [ -n "$buttons" ] && buttons="$buttons,"
            buttons="$buttons[$row]"
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[$row]"
    fi
    buttons="$buttons,[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_network_edit_back\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]"
    local keyboard="{\"inline_keyboard\":[$buttons]}"

    local msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    if [ -n "$msg_id" ]; then
        response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
            --data-urlencode text="$table" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
        if echo "$response" | grep -q '"ok":false'; then
            _wifi_send_main "$table" "$keyboard"
        fi
    else
        _wifi_send_main "$table" "$keyboard"
    fi
}

_wifi_edit_encryption_finish() {
    (
    trap '_bot_mark_busy_end' EXIT
    local new_enc="$1"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    _bot_mark_busy_start "wifi_edit"
    
    if [ -z "$section" ]; then
        _wifi_send_main "❌ Ошибка: секция не определена." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    uci set "wireless.$section.encryption=$new_enc"
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    _wifi_set_current_menu "network_edit"

    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
    [ -z "$disabled" ] && disabled="0"
    show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
    )
}

_wifi_find_zone_by_name() {
    local zone_name="$1"
    uci show firewall 2>/dev/null | grep -E "\.name='${zone_name}'" | head -1 | cut -d'.' -f2 | cut -d'=' -f1
}

_wifi_ensure_wwan_firewall() {
    local zone_section=$(_wifi_find_zone_by_name "wan")
    if [ -z "$zone_section" ]; then return 1; fi

    local current_nets=$(uci -q get "firewall.${zone_section}.network" 2>/dev/null)
    if echo "$current_nets" | tr ' ' '\n' | grep -qx "wwan"; then
        return 0
    fi

    uci add_list "firewall.${zone_section}.network=wwan" 2>/dev/null
    if [ $? -ne 0 ]; then return 1; fi

    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null
    return 0
}

_wifi_toggle_network() {
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    if [ -z "$section" ]; then
        _wifi_send_main "❌ Ошибка: секция не определена." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    (
    flock -w 90 200 || exit 1

    local current=$(uci -q get "wireless.$section.disabled" 2>/dev/null || echo "0")
    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local device=$(uci -q get "wireless.$section.device" 2>/dev/null)

    if [ "$current" = "0" ]; then
        uci set "wireless.$section.disabled=1"
        if [ "$mode" = "sta" ]; then
            _wifi_restore_radio_params "$device"
        fi
    else
        uci set "wireless.$section.disabled=0"
        if [ "$mode" = "sta" ]; then
            _wifi_save_radio_params "$device"
            if ! uci -q get network.wwan >/dev/null 2>&1; then
                uci set network.wwan=interface
                uci set network.wwan.proto='dhcp'
                uci set network.wwan.metric='20'
                uci commit network
            else
                uci set network.wwan.metric='20'
                uci commit network
            fi
            _wifi_ensure_wwan_firewall
            ubus call network reload 2>/dev/null
        fi
    fi

    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    if [ "$mode" = "sta" ] && [ "$current" != "0" ]; then
        (
            exec 200>&-
            sleep 3
            _wifi_check_sta_connection_and_rollback "$section" "$device"
        ) &
    fi

    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
    [ -z "$disabled" ] && disabled="0"

    local content=$(_wifi_build_network_edit_content "$section" "$ssid" "$device" "$mode" "$disabled")
    local table="${content%|*}"
    local keyboard="${content#*|}"
    _wifi_send_edit "$table" "$keyboard"
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_delete_network() {
    local callback_id="$1"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    if [ -z "$section" ]; then
        _wifi_answer_cb -d callback_query_id="$callback_id" -d text="❌ Ошибка: секция не определена" >/dev/null 2>&1
        return
    fi

    (
    flock -w 90 200 || exit 1
    rm -f "/tmp/telegram_bot/wifi/show_password_${section}.txt" 2>/dev/null

    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local net=$(uci -q get "wireless.$section.network" 2>/dev/null)
    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local created_by=$(uci -q get "wireless.$section.created_by" 2>/dev/null)

    if [ "$mode" = "sta" ]; then
        local monitor_pid_file="/tmp/telegram_bot/wifi/sta_monitor_${section}.pid"
        if [ -f "$monitor_pid_file" ]; then
            local pid=$(cat "$monitor_pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
            rm -f "$monitor_pid_file"
        fi
    fi

    if [ "$mode" = "sta" ]; then
        local radio_dev=$(uci -q get "wireless.$section.device" 2>/dev/null)
        if [ -n "$radio_dev" ]; then _wifi_restore_radio_params "$radio_dev"; fi
    fi

    uci delete "wireless.$section" 2>/dev/null

    if [ -n "$net" ] && [ "$net" != "lan" ] && [ "$created_by" = "tgbot" ]; then
        local other=$(uci show wireless 2>/dev/null | grep -E "wireless\..*\.network='$net'" | grep -vF "wireless.$section.")
        if [ -z "$other" ]; then
            if [ "$(uci -q get "network.$net.created_by" 2>/dev/null)" = "tgbot" ]; then
                uci delete "network.$net" 2>/dev/null
                if [ "$net" = "wwan" ]; then
                    for zone in $(uci show firewall 2>/dev/null | grep -E "firewall\.[^=]+=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
                        uci -q del_list "firewall.$zone.network=wwan" 2>/dev/null
                    done
                    uci commit firewall 2>/dev/null
                fi
            fi

            if [ "$(uci -q get "network.${net}_bridge.created_by" 2>/dev/null)" = "tgbot" ]; then
                uci delete "network.${net}_bridge" 2>/dev/null
            fi

            if [ "$(uci -q get "dhcp.$net.created_by" 2>/dev/null)" = "tgbot" ]; then
                uci delete "dhcp.$net" 2>/dev/null
                uci commit dhcp 2>/dev/null
            fi

            local rule_idx=$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.@rule\[\([0-9]\+\)\]=rule$/\1/p' | sort -rn)
            local idx _name _created
            for idx in $rule_idx; do
                _created=$(uci -q get "firewall.@rule[$idx].created_by" 2>/dev/null)
                [ "$_created" = "tgbot" ] || continue
                _name=$(uci -q get "firewall.@rule[$idx].name" 2>/dev/null)
                case "$_name" in "Allow-DHCP-Guest"|"Allow-DNS-Guest") uci delete "firewall.@rule[$idx]" 2>/dev/null ;; esac
            done

            local fwd_idx=$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | sort -rn)
            for idx in $fwd_idx; do
                _created=$(uci -q get "firewall.@forwarding[$idx].created_by" 2>/dev/null)
                [ "$_created" = "tgbot" ] || continue
                local _src=$(uci -q get "firewall.@forwarding[$idx].src" 2>/dev/null)
                local _dest=$(uci -q get "firewall.@forwarding[$idx].dest" 2>/dev/null)
                if [ "$_src" = "$net" ] || [ "$_dest" = "$net" ]; then uci delete "firewall.@forwarding[$idx]" 2>/dev/null; fi
            done

            local zone_idx=$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.@zone\[\([0-9]\+\)\]=zone$/\1/p' | sort -rn)
            for idx in $zone_idx; do
                _created=$(uci -q get "firewall.@zone[$idx].created_by" 2>/dev/null)
                [ "$_created" = "tgbot" ] || continue
                local _zname=$(uci -q get "firewall.@zone[$idx].name" 2>/dev/null)
                if [ "$_zname" = "$net" ]; then
                    local _znets=$(uci -q get "firewall.@zone[$idx].network" 2>/dev/null)
                    local _rem=$(echo "$_znets" | tr ' ' '\n' | grep -v '^$' | grep -v "^${net}$" | wc -l)
                    if [ "$_rem" -eq 0 ]; then uci delete "firewall.@zone[$idx]" 2>/dev/null; fi
                fi
            done

            uci commit firewall 2>/dev/null
            uci commit network 2>/dev/null
            /etc/init.d/firewall reload 2>/dev/null
            /etc/init.d/network reload 2>/dev/null

            if ip link show "br-${net}" >/dev/null 2>&1; then ip link set "br-${net}" down 2>/dev/null; fi
        fi
    fi

    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    rm -f "$WIFI_EDIT_SECTION_FILE"
    _wifi_answer_cb -d callback_query_id="$callback_id" --data-urlencode "text=✅ Сеть '$ssid' удалена" >/dev/null 2>&1
    show_wifi_vif_menu
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_show_password_toggle() {
    local callback_id="$1"
    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    if [ -z "$section" ]; then
        _wifi_answer_cb -d callback_query_id="$callback_id" -d text="❌ Ошибка: секция не определена" >/dev/null 2>&1
        return
    fi
    local show_file="/tmp/telegram_bot/wifi/show_password_${section}.txt"
    local current="false"
    if [ -f "$show_file" ]; then current=$(cat "$show_file" 2>/dev/null || echo "false"); fi
    if [ "$current" = "true" ]; then echo "false" > "$show_file"; else echo "true" > "$show_file"; fi

    local msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    if [ -z "$msg_id" ]; then
        local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
        local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
        local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
        local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
        [ -z "$disabled" ] && disabled="0"
        show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
        return
    fi

    local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
    local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
    local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
    [ -z "$disabled" ] && disabled="0"

    local content=$(_wifi_build_network_edit_content "$section" "$ssid" "$device" "$mode" "$disabled")
    local table="${content%|*}"
    local keyboard="${content#*|}"

    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
        --data-urlencode text="$table" -d parse_mode="HTML" \
        --data-urlencode "reply_markup=$keyboard" >/dev/null 2>&1
}

# ==============================================================================
# 🏗️ РАЗДЕЛ 7: СОЗДАНИЕ СЕТЕЙ (AP, GUEST, STA)
# ==============================================================================

_wifi_create_choose_radio() {
    local type="$1"
    echo "$type" > /tmp/telegram_bot/wifi/create_type
    _wifi_set_current_menu "create_radio"
    _wifi_set_current_create_type "$type"
    rm -f "$WIFI_EDIT_SECTION_FILE"

    local table="<pre>📡 Выберите радио для новой сети

${SEP46}
${SEP46}
Тип сети: $(echo "$type" | tr '[:lower:]' '[:upper:]')
${SEP46}
${SEP46}

Выберите радио:</pre>"

    local keyboard='{"inline_keyboard":[
        [{"text":"📡 Radio0️⃣ (2.4 GHz)","callback_data":"wifi_create_radio_24"}, {"text":"📡 Radio1️⃣ (5 GHz)","callback_data":"wifi_create_radio_5"}],
        [{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"},{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]
    ]}'
    _wifi_send_edit "$table" "$keyboard"
}

_wifi_create_radio_selected() {
    local band="$1"
    local type=$(cat /tmp/telegram_bot/wifi/create_type 2>/dev/null)
    if [ -z "$type" ]; then
        _wifi_send_main "❌ Ошибка: тип сети не определён." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi
    echo "$band" > "$WIFI_CREATE_RADIO_FILE"
    case "$type" in
        ap) _wifi_create_ap_step2 ;;
        guest) _wifi_create_guest_step2 ;;
        sta) _wifi_create_sta_step2 ;;
        *) _wifi_send_main "❌ Неизвестный тип сети." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
            rm -f /tmp/telegram_bot/wifi/create_type ;;
    esac
}

_wifi_create_ap_start() { _wifi_create_choose_radio "ap"; }

_wifi_create_ap_step2() {
    echo "ap_ssid" > "$WIFI_EDIT_MODE_FILE"
    _wifi_send_prompt "✏️ Введите SSID для новой точки доступа 
	(от 1 до 32 символов):" \
        '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
}

_wifi_create_ap_finish() {
    local ssid="$1"
    local password="$2"
    local band=$(cat "$WIFI_CREATE_RADIO_FILE" 2>/dev/null)
    [ -z "$band" ] && band="24"
    local radio=$(_get_radio_path "$band")
    local iface_name=$(_generate_iface_name "ap" "$radio")

    _bot_mark_busy_start "wifi_ap"

    (
    trap '_bot_mark_busy_end' EXIT
    flock -w 90 200 || {
        send_message "⚠️ Wi-Fi занят другой операцией, попробуйте через минуту" >/dev/null 2>&1
        exit 1
    }

    local _radio_menu_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    local _prog_msg_id=$( _wifi_send_temp "⏳ <b>Создаю точку доступа '$ssid'…</b>
Настраиваю Wi-Fi…" "" )
    rm -f "$WIFI_MSG_ID_FILE"

    uci set wireless."$iface_name"=wifi-iface
    uci set wireless."$iface_name".device="$radio"
    uci set wireless."$iface_name".mode="ap"
    uci set wireless."$iface_name".network="lan"
    uci set wireless."$iface_name".ssid="$ssid"
    uci set wireless."$iface_name".created_by='tgbot'
    
    if [ -z "$password" ]; then
        uci set wireless."$iface_name".encryption="none"
        uci -q delete wireless."$iface_name".key
    else
        uci set wireless."$iface_name".encryption="psk2"
        uci set wireless."$iface_name".key="$password"
    fi
    
    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" \
        --data-urlencode text="⏳ <b>Создаю точку доступа '$ssid'…</b>
Перезапускаю Wi-Fi, ожидайте…" -d parse_mode="HTML" >/dev/null 2>&1

    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    rm -f "$WIFI_CREATE_RADIO_FILE" /tmp/telegram_bot/wifi/create_type

    local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
    [ -n "$prompt_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" >/dev/null 2>&1
    rm -f "$WIFI_EDIT_MSG_ID_FILE"

    [ -n "$_radio_menu_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_radio_menu_msg_id" >/dev/null 2>&1

    if [ -n "$_prog_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" \
            --data-urlencode text="✅ <b>Точка доступа '$ssid' создана на $radio.</b>" -d parse_mode="HTML" >/dev/null 2>&1
        echo "$_prog_msg_id" > /tmp/telegram_bot/wifi/success_msg_id
    else
        local _s_id=$( _wifi_send_temp "✅ Точка доступа '$ssid' создана на $radio." "" )
        echo "$_s_id" > /tmp/telegram_bot/wifi/success_msg_id
    fi
    rm -f "$WIFI_MSG_ID_FILE"
    show_wifi_vif_menu
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_create_guest_start() { _wifi_create_choose_radio "guest"; }

_wifi_create_guest_step2() {
    echo "guest_ssid" > "$WIFI_EDIT_MODE_FILE"
    _wifi_send_prompt "✏️ Введите SSID для гостевой сети 
	(от 1 до 32 символов):" \
        '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
}

_wifi_find_free_guest_subnet() {
    local occupied=""
    local ip prefix

    for ip in $(uci show network 2>/dev/null | grep -oE "\.ipaddr='[0-9.]+'" | cut -d"'" -f2); do
        [ -z "$ip" ] && continue
        prefix=$(echo "$ip" | cut -d'.' -f1-3)
        occupied="$occupied $prefix"
    done

    for ip in $(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1); do
        [ -z "$ip" ] && continue; [ "$ip" = "127.0.0.1" ] && continue
        prefix=$(echo "$ip" | cut -d'.' -f1-3)
        occupied="$occupied $prefix"
    done

    for ip in $(ip route show 2>/dev/null | awk '/^192\.168\./ {print $1}' | cut -d'/' -f1); do
        [ -z "$ip" ] && continue
        prefix=$(echo "$ip" | cut -d'.' -f1-3)
        occupied="$occupied $prefix"
    done

    if ip route show 2>/dev/null | grep -qE '^192\.168\.0\.0/([0-9]|1[0-6])[[:space:]]'; then return 1; fi

    local n
    for n in $(seq 3 254); do
        local cand="192.168.$n"
        if echo " $occupied " | grep -q " $cand "; then continue; fi
        echo "192.168.$n.1 255.255.255.0"
        return 0
    done
    return 1
}

_wifi_create_guest_finish() {
    local ssid="$1"
    local password="$2"
    local band=$(cat "$WIFI_CREATE_RADIO_FILE" 2>/dev/null)
    [ -z "$band" ] && band="24"
    local radio=$(_get_radio_path "$band")
    local iface_name=$(_generate_iface_name "guest" "$radio")

    _bot_mark_busy_start "wifi_guest"
    (
    trap '_bot_mark_busy_end' EXIT
    flock -w 120 200 || {
        send_message "⚠️ Wi-Fi занят другой операцией, попробуйте через минуту" >/dev/null 2>&1
        exit 1
    }

    local _radio_menu_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    local _prog_msg_id=$( _wifi_send_temp "⏳ <b>Создаю гостевую сеть '$ssid'…</b>
Настраиваю сеть и DHCP…" "" )
    rm -f "$WIFI_MSG_ID_FILE"

    if ! uci -q get network.guest >/dev/null 2>&1; then
        local guest_subnet=$(_wifi_find_free_guest_subnet)
        if [ -z "$guest_subnet" ]; then
            uci delete "wireless.$iface_name" 2>/dev/null
            uci commit wireless
            _wifi_send_main "❌ <b>Не удалось создать гостевую сеть</b>

Все подсети диапазона:  
<code>192.168.3.0/24</code>–<code>192.168.254.0/24</code>
уже заняты или конфликтуют с существующими маршрутами.

Проверьте:
• UCI-адреса интерфейсов: <code>uci show network</code>
• Маршруты: <code>ip route</code>
• Свободные IP: <code>ip -4 addr</code>" \
                '{"inline_keyboard":[[{"text":"🌐 Список сетей","callback_data":"wifi_vif_menu"}]]}'
            return 1
        fi

        local guest_ip="${guest_subnet% *}"
        local guest_mask="${guest_subnet#* }"

        uci set network.guest="interface"
        uci set network.guest.proto="static"
        uci set network.guest.ipaddr="$guest_ip"
        uci set network.guest.netmask="$guest_mask"
        uci set network.guest.created_by='tgbot'
    fi

    if ! uci -q get network.guest_bridge >/dev/null 2>&1; then
        uci set network.guest_bridge="device"
        uci set network.guest_bridge.name="br-guest"
        uci set network.guest_bridge.type="bridge"
        uci set network.guest_bridge.created_by='tgbot'
    fi

    local _guest_bridge_name=$(uci -q get network.guest_bridge.name 2>/dev/null)
    if [ -z "$_guest_bridge_name" ]; then
        _guest_bridge_name="br-guest"
        uci set network.guest_bridge.name="br-guest"
    fi

    local _cur_guest_device=$(uci -q get network.guest.device 2>/dev/null)
    if [ "$_cur_guest_device" != "$_guest_bridge_name" ]; then
        uci set network.guest.device="$_guest_bridge_name"
    fi

    uci commit network

    if ! uci -q get dhcp.guest >/dev/null 2>&1; then
        uci set dhcp.guest=dhcp
        uci set dhcp.guest.interface='guest'
        uci set dhcp.guest.start='100'
        uci set dhcp.guest.limit='150'
        uci set dhcp.guest.leasetime='12h'
        uci set dhcp.guest.created_by='tgbot'
        uci commit dhcp
    fi

    local zone_section=$(uci show firewall 2>/dev/null | grep -E "\.name='guest'" | head -1 | cut -d'.' -f2 | cut -d'=' -f1)

    if [ -z "$zone_section" ]; then
        local new_zone_section=$(uci add firewall zone 2>/dev/null)
        if [ -z "$new_zone_section" ]; then
            uci -q delete "wireless.$iface_name" 2>/dev/null
            uci -q delete "dhcp.guest" 2>/dev/null
            uci -q delete "network.guest" 2>/dev/null
            uci -q delete "network.guest_bridge" 2>/dev/null
            uci commit wireless 2>/dev/null; uci commit network 2>/dev/null; uci commit dhcp 2>/dev/null
            send_message "❌ <b>Не удалось создать firewall-зону для гостевой сети</b>
Установка отменена." >/dev/null 2>&1
            return 1
        fi

        local _leaked_name=$(uci -q get "firewall.$new_zone_section.name" 2>/dev/null)
        local _leaked_net=$(uci -q get "firewall.$new_zone_section.network" 2>/dev/null)
        if [ -n "$_leaked_name" ] || [ -n "$_leaked_net" ]; then
            uci -q delete "wireless.$iface_name" 2>/dev/null; uci -q delete "dhcp.guest" 2>/dev/null
            uci -q delete "network.guest" 2>/dev/null; uci -q delete "network.guest_bridge" 2>/dev/null
            uci commit wireless 2>/dev/null; uci commit network 2>/dev/null; uci commit dhcp 2>/dev/null
            send_message "❌ <b>Ошибка создания firewall-зоны</b>
Установка отменена (защита от повреждения)." >/dev/null 2>&1
            return 1
        fi

        zone_section="$new_zone_section"
        uci set "firewall.$zone_section.name=guest"
        uci set "firewall.$zone_section.output=ACCEPT"
        uci set "firewall.$zone_section.forward=REJECT"
        uci set "firewall.$zone_section.masq=1"
        uci set "firewall.$zone_section.created_by=tgbot"
    fi
	
    uci set "firewall.$zone_section.input=REJECT"
    uci set "firewall.$zone_section.network=guest"
    uci set "firewall.$zone_section.enabled=1"

    local _dhcp_rule_idx=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@rule\[[0-9]*\]\)\.name='Allow-DHCP-Guest'$/\1/p" | head -1)
    if [ -n "$_dhcp_rule_idx" ]; then
        uci set "firewall.$_dhcp_rule_idx.enabled='1'"
        uci set "firewall.$_dhcp_rule_idx.src='guest'"
        uci set "firewall.$_dhcp_rule_idx.proto='udp'"
        uci set "firewall.$_dhcp_rule_idx.dest_port='67-68'"
        uci set "firewall.$_dhcp_rule_idx.target='ACCEPT'"
    else
        uci add firewall rule > /dev/null
        uci set firewall.@rule[-1].name='Allow-DHCP-Guest'
        uci set firewall.@rule[-1].enabled='1'
        uci set firewall.@rule[-1].src='guest'
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].dest_port='67-68'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci set firewall.@rule[-1].created_by='tgbot'
    fi

    local _dns_rule_idx=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@rule\[[0-9]*\]\)\.name='Allow-DNS-Guest'$/\1/p" | head -1)
    if [ -n "$_dns_rule_idx" ]; then
        uci set "firewall.$_dns_rule_idx.enabled='1'"
        uci set "firewall.$_dns_rule_idx.src='guest'"
        uci set "firewall.$_dns_rule_idx.proto='tcp udp'"
        uci set "firewall.$_dns_rule_idx.dest_port='53'"
        uci set "firewall.$_dns_rule_idx.target='ACCEPT'"
    else
        uci add firewall rule > /dev/null
        uci set firewall.@rule[-1].name='Allow-DNS-Guest'
        uci set firewall.@rule[-1].enabled='1'
        uci set firewall.@rule[-1].src='guest'
        uci set firewall.@rule[-1].proto='tcp udp'
        uci set firewall.@rule[-1].dest_port='53'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci set firewall.@rule[-1].created_by='tgbot'
    fi

    local has_fwd=0
    local i
    for i in $(seq 0 50); do
        local _s=$(uci -q get "firewall.@forwarding[$i].src" 2>/dev/null)
        local _d=$(uci -q get "firewall.@forwarding[$i].dest" 2>/dev/null)
        if [ "$_s" = "guest" ] && [ "$_d" = "wan" ]; then 
            has_fwd=1
            break
        fi
    done

    if [ "$has_fwd" -eq 0 ]; then
        uci add firewall forwarding > /dev/null
        uci set firewall.@forwarding[-1].src='guest'
        uci set firewall.@forwarding[-1].dest='wan'
        uci set firewall.@forwarding[-1].created_by='tgbot'
    fi

    uci commit firewall

    [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" \
        --data-urlencode text="⏳ <b>Создаю гостевую сеть '$ssid'…</b>
Применяю правила firewall и перезапускаю DHCP…" -d parse_mode="HTML" >/dev/null 2>&1

    /etc/init.d/firewall reload 2>/dev/null
    /etc/init.d/dnsmasq reload 2>/dev/null

    uci set wireless."$iface_name"=wifi-iface
    uci set wireless."$iface_name".device="$radio"
    uci set wireless."$iface_name".mode="ap"
    uci set wireless."$iface_name".network="guest"
    uci set wireless."$iface_name".ssid="$ssid"
    uci set wireless."$iface_name".isolate="1"
    uci set wireless."$iface_name".created_by='tgbot'

    if [ -z "$password" ]; then
        uci set wireless."$iface_name".encryption="none"
        uci -q delete wireless."$iface_name".key
    else
        uci set wireless."$iface_name".encryption="psk2"
        uci set wireless."$iface_name".key="$password"
    fi

    uci commit wireless
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" \
        --data-urlencode text="⏳ <b>Создаю гостевую сеть '$ssid'…</b>
Перезапускаю Wi-Fi, ожидайте…" -d parse_mode="HTML" >/dev/null 2>&1

    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then
        send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1
        return 1
    fi

    rm -f "$WIFI_CREATE_RADIO_FILE" /tmp/telegram_bot/wifi/create_type

    local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
    [ -n "$prompt_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" >/dev/null 2>&1
    rm -f "$WIFI_EDIT_MSG_ID_FILE"

    [ -n "$_radio_menu_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_radio_menu_msg_id" >/dev/null 2>&1
    if [ -n "$_prog_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" \
            --data-urlencode text="✅ <b>Гостевая сеть '$ssid' создана на $radio.</b>" -d parse_mode="HTML" >/dev/null 2>&1
        echo "$_prog_msg_id" > /tmp/telegram_bot/wifi/success_msg_id
    else
        local _s_id=$( _wifi_send_temp "✅ Гостевая сеть '$ssid' создана на $radio." "" )
        echo "$_s_id" > /tmp/telegram_bot/wifi/success_msg_id
    fi
    rm -f "$WIFI_MSG_ID_FILE"
    show_wifi_vif_menu
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_create_sta_start() {
    rm -f /tmp/telegram_bot/wifi/sta_essid /tmp/telegram_bot/wifi/sta_enc
    rm -f "$WIFI_EDIT_MODE_FILE"
    _wifi_create_choose_radio "sta"
}

_wifi_create_sta_step2() {
    local _SCAN_TEMP_IFACE=""
    local band=$(cat "$WIFI_CREATE_RADIO_FILE" 2>/dev/null)
    [ -z "$band" ] && band="24"
    _wifi_set_current_menu "sta_scan"
    _wifi_set_current_band "$band"

    local radio_path=$(_get_radio_path "$band")
    local existing_sta_ssid=""

    local _sec_real
    for _sec_real in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        local dev=$(uci -q get "wireless.$_sec_real.device" 2>/dev/null)
        local mode=$(uci -q get "wireless.$_sec_real.mode" 2>/dev/null)
        local disabled=$(uci -q get "wireless.$_sec_real.disabled" 2>/dev/null)

        if [ "$dev" = "$radio_path" ] && [ "$mode" = "sta" ] && [ "$disabled" != "1" ]; then
            existing_sta_ssid=$(uci -q get "wireless.$_sec_real.ssid" 2>/dev/null)
            break
        fi
    done

    if [ -n "$existing_sta_ssid" ]; then
        local radio_display="Radio0 (2.4 GHz)"
        [ "$band" = "5" ] && radio_display="Radio1 (5 GHz)"
        _wifi_send_main "⚠️ <b>На $radio_display активен режим 
Клиента (STA)</b>

Текущее подключение: <b>$existing_sta_ssid</b>

Нельзя создать второе STA на этом радио. 
Удалите или отключите существующее 
в разделе «Список сетей» и повторите." \
            '{"inline_keyboard":[[{"text":"🌐 Список сетей","callback_data":"wifi_vif_menu"},{"text":"⬅️ Назад","callback_data":"wifi_create_sta"}]]}'
        return
    fi

    local iface="$INTERFACE_24"
    [ "$band" = "5" ] && iface="$INTERFACE_5"
    local scan_iface="$iface"

    if ! ip link show "$iface" >/dev/null 2>&1; then
        local phy="phy0"
        [ "$band" = "5" ] && phy="phy1"
        local temp_name="scan_tmp_$$"
        if iw phy "$phy" interface add "$temp_name" type managed 2>/dev/null; then
            ip link set "$temp_name" up
            _SCAN_TEMP_IFACE="$temp_name"
            scan_iface="$temp_name"
            trap "_scan_temp_cleanup '$temp_name'" RETURN
        else
            _wifi_send_main "❌ Не удалось создать временный интерфейс для сканирования." \
                '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
            return
        fi
    fi

    sleep 1

    local scan_output=""
    if command -v timeout >/dev/null 2>&1; then
        scan_output=$(timeout 20 iwinfo "$scan_iface" scan 2>/dev/null)
    else
        scan_output=$(iwinfo "$scan_iface" scan 2>/dev/null)
    fi

    _scan_temp_cleanup "$_SCAN_TEMP_IFACE"
    trap - RETURN

    if [ -z "$scan_output" ]; then
        _wifi_send_main "❌ Не удалось выполнить сканирование на $iface." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    local networks=$(echo "$scan_output" | gawk '
        BEGIN { RS = ""; FS = "\n" }
        {
            essid = ""; signal = ""; enc = ""; enc_uci = "psk2"
            for (i = 1; i <= NF; i++) {
                line = $i
                if (line ~ /ESSID:/) {
                    essid = line; sub(/.*ESSID: /, "", essid); gsub(/^"|"$/, "", essid)
                }
                if (line ~ /Signal:/) {
                    signal = line; sub(/.*Signal: /, "", signal); sub(/ dBm.*/, "", signal)
                }
                if (line ~ /Encryption:/) {
                    enc = line; sub(/.*Encryption: /, "", enc)
                    enc_uci = "psk2"
                    if (enc ~ /NONE/) { enc_uci = "none" }
                    else if (enc ~ /WEP/) { enc_uci = "wep" }
                    else if (enc ~ /WPA.*SAE/ || enc ~ /SAE.*WPA/ || enc ~ /WPA2.*WPA3/ || enc ~ /WPA3.*WPA2/ || enc ~ /mixed.*WPA.*WPA3/) { enc_uci = "sae-mixed" }
                    else if (enc ~ /SAE/ || enc ~ /WPA3/) { enc_uci = "sae" }
                    else if (enc ~ /OWE/) { enc_uci = "owe" }
                    else if (enc ~ /mixed WPA\/WPA2/ || enc ~ /WPA.*WPA2/ || enc ~ /WPA2.*WPA/ || enc ~ /WPA\/WPA2/) { enc_uci = "psk-mixed" }
                    else if (enc ~ /WPA2/ || enc ~ /CCMP/) { enc_uci = "psk2" }
                    else if (enc ~ /WPA/ || enc ~ /TKIP/) { enc_uci = "psk" }
                }
            }
            if (essid != "") { print essid "|" signal "|" enc "|" enc_uci }
        }
    ')
    echo "$networks" > /tmp/telegram_bot/wifi/scan_result

    if [ -z "$networks" ]; then
        _wifi_send_main "❌ Нет доступных сетей для сканирования." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi

    local COL_NAME=27
    local COL_ENCR=10
    local COL_SIGNAL=3

    local table_rows=""
    local total=0
    while IFS='|' read -r essid signal enc enc_uci; do
        total=$((total + 1))
        local _raw_essid="$essid"
        if [ ${#_raw_essid} -gt "$COL_NAME" ]; then _raw_essid="${_raw_essid:0:$((COL_NAME - 1))}…"; fi
        local essid_len=${#_raw_essid}
        local safe_essid=$(html_escape "$_raw_essid")
        local essid_pad=$((COL_NAME - essid_len))
        [ "$essid_pad" -lt 0 ] && essid_pad=0
        local essid_padded="${safe_essid}$(printf '%*s' "$essid_pad" '')"

        local enc_display=""
        case "$enc_uci" in
            "none") enc_display="Open" ;; "wep") enc_display="WEP" ;; "psk-mixed") enc_display="WPA/WPA2" ;;
            "sae-mixed") enc_display="WPA2/WPA3" ;; "sae") enc_display="WPA3" ;; "owe") enc_display="OWE" ;;
            "psk2") enc_display="WPA2" ;; "psk") enc_display="WPA" ;; *) enc_display="Unknown" ;;
        esac

        local enc_raw="${enc_display:0:$COL_ENCR}"
        local enc_len=${#enc_raw}
        local enc_padded=""
        if [ $enc_len -lt $COL_ENCR ]; then
            local left=$(( ($COL_ENCR - $enc_len) / 2 ))
            local right=$(( $COL_ENCR - $enc_len - left ))
            enc_padded=$(printf "%*s%s%*s" $left "" "$enc_raw" $right "")
        else
            enc_padded="$enc_raw"
        fi
        local signal_padded=$(printf "%${COL_SIGNAL}s" "$signal")

        printf -v line "%-2s  %s %s  %${COL_SIGNAL}s dBm" "$total" "$essid_padded" "$enc_padded" "$signal_padded"
        table_rows="${table_rows}${line}"$'\n'
    done < /tmp/telegram_bot/wifi/scan_result

    if [ -z "$table_rows" ]; then
        _wifi_send_main "❌ Нет доступных сетей для сканирования." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_create_sta"}]]}'
        return
    fi

    local table="<pre>🔍 ДОСТУПНЫЕ СЕТИ на $iface

${SEP46}
№   Имя                         Шифрование  Сигнал
--  --------------------------- ----------  -------
${table_rows}${SEP46}
🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')

Выберите сеть, нажав на кнопку с номером:</pre>"

    local rows=()
    local row=""
    local cnt=0
    for ((i=1; i<=total; i++)); do
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$i\",\"callback_data\":\"wifi_sta_select_$i\"}"
        cnt=$((cnt+1))
        if [ $cnt -eq 7 ]; then
            rows+=("[$row]")
            row=""
            cnt=0
        fi
    done
    if [ -n "$row" ]; then rows+=("[$row]"); fi

    rows+=("[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wifi_create_sta\"},{\"text\":\"🔄 Обновить\",\"callback_data\":\"wifi_sta_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"wifi_cancel\"}]")

    local buttons=""
    for r in "${rows[@]}"; do
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons$r"
    done
    local keyboard="{\"inline_keyboard\":[$buttons]}"
    _wifi_send_main "$table" "$keyboard"
}

_wifi_create_sta_select() {
    local num="$1"
    local networks=$(cat /tmp/telegram_bot/wifi/scan_result 2>/dev/null)
    local selected=$(echo "$networks" | sed -n "${num}p")
    if [ -z "$selected" ]; then
        _wifi_send_main "❌ Неверный номер сети." \
            '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
        return
    fi
    local essid=$(echo "$selected" | cut -d'|' -f1)
    local enc_uci=$(echo "$selected" | cut -d'|' -f4)
    echo "$essid" > /tmp/telegram_bot/wifi/sta_essid
    echo "$enc_uci" > /tmp/telegram_bot/wifi/sta_enc

    if [ "$enc_uci" = "none" ]; then
        _wifi_create_sta_connect "$essid" "" "none"
    else
        echo "sta_password" > "$WIFI_EDIT_MODE_FILE"
        _wifi_send_prompt "🔑 Введите пароль для сети $essid :" \
            '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
    fi
}

_wifi_check_sta_connection_and_rollback() {
    local section="$1"
    local radio="$2"
    local timeout=10
    local count=0
    local iface=""
    local radio_num="${radio#radio}"

    while [ $count -lt $timeout ]; do
        iface=$(ubus call network.wireless status 2>/dev/null | jq -r ".radio${radio_num}.interfaces[] | select(.config.mode == \"sta\") | .ifname" 2>/dev/null | head -1)
        if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then break; fi
        sleep 2
        count=$((count+1))
    done

    if [ -z "$iface" ]; then
        _wifi_rollback_sta "$section" "$radio" "Интерфейс не появился"
        return
    fi

    count=0
    local ip=""
    while [ $count -lt $timeout ]; do
        ip=$(ip addr show "$iface" 2>/dev/null | grep -o "inet [0-9.]*" | awk '{print $2}' | head -1)
        if [ -n "$ip" ]; then return 0; fi
        sleep 2
        count=$((count+1))
    done

    _wifi_rollback_sta "$section" "$radio" "IP не получен"
}

_wifi_rollback_sta() {
    local section="$1"
    local radio="$2"
    local reason="$3"
    local _ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
    [ -z "$_ssid" ] && _ssid="$section"

    (
    flock -w 90 200 || exit 1

    if [ -z "$reason" ]; then reason="неизвестная ошибка"; fi

    if uci -q get "wireless.$section" >/dev/null 2>&1; then
        uci set "wireless.$section.disabled=1"
        uci commit wireless
    fi
    
    _wifi_restore_radio_params "$radio"

    if uci -q get network.wwan >/dev/null 2>&1; then
        local _wwan_owner=$(uci -q get network.wwan.created_by 2>/dev/null)
        if [ "$_wwan_owner" = "tgbot" ]; then
            uci delete network.wwan
            uci commit network
            for zone in $(uci show firewall | grep -E "firewall\.[^=]+=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
                uci -q del_list "firewall.$zone.network=wwan" 2>/dev/null
            done
            uci commit firewall
            /etc/init.d/firewall reload 2>/dev/null
        fi
    fi

    local title=""
    local emoji="⚠️"
    if echo "$reason" | grep -qE "Интерфейс не появился|IP не получен"; then
        title="Включение STA не удалось"; emoji="❌"
    else
        title="Соединение STA потеряно"
    fi

    local _kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="${emoji} <b>${title}</b>

📡 Сеть: <code>${_ssid}</code>
Причина: ${reason}.
STA отключена." -d parse_mode="HTML" --data-urlencode "reply_markup=$_kb" >/dev/null 2>&1

    (
        ubus call network reload 2>/dev/null
        sleep 3
        _wifi_safe_reload 2>/dev/null
        sleep 3

        local monitor_pid_file="/tmp/telegram_bot/wifi/sta_monitor_${section}.pid"
        if [ -f "$monitor_pid_file" ]; then
            local pid=$(cat "$monitor_pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
            rm -f "$monitor_pid_file"
        fi

        if [ -f "/tmp/telegram_bot/wifi/active.lock" ]; then
            local old_vif_msg_id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null)
            if [ -n "$old_vif_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_vif_msg_id" >/dev/null 2>&1
                rm -f /tmp/telegram_bot/wifi/msg_id
            fi
            show_wifi_vif_menu
        fi
    ) &
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_create_sta_connect() {
    local ssid="$1"
    local password="$2"
    local encryption="$3"

    _bot_mark_busy_start "wifi_sta"

    (
    trap '_bot_mark_busy_end' EXIT
    flock -w 120 200 || {
        send_message "⚠️ Wi-Fi занят другой операцией, попробуйте через минуту" >/dev/null 2>&1
        exit 1
    }

    local band=$(cat "$WIFI_CREATE_RADIO_FILE" 2>/dev/null)
    [ -z "$band" ] && band="24"
    local radio=$(_get_radio_path "$band")
    local radio_num="${radio#radio}"
	
    _wifi_save_radio_params "$radio"

    local all_ifaces=$(iw dev 2>/dev/null | grep -E "^Interface" | awk '{print $2}')
    for iface in $all_ifaces; do
        [ -z "$iface" ] && continue
        local iface_info=$(iw dev "$iface" info 2>/dev/null)
        local iface_phy=$(echo "$iface_info" | grep -E "^[[:space:]]*wiphy" | awk '{print $2}')
        [ "$iface_phy" != "$radio_num" ] && continue
        local iface_type=$(echo "$iface_info" | grep -E "^[[:space:]]*type" | awk '{print $2}')
        
        if [ "$iface_type" = "managed" ]; then
            case "$iface" in
                sta_*|ap_*|guest_*)
                    iw dev "$iface" del 2>/dev/null
                    ;;
                *)
                    echo "$(date): _wifi_create_sta_connect: пропускаю живой интерфейс $iface" >> /tmp/telegram_bot/logs/bot.log
                    ;;
            esac
        fi
    done

    local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
    [ -n "$prompt_id" ] && _wifi_delete_message "$prompt_id"
    rm -f "$WIFI_EDIT_MSG_ID_FILE"

    local old_list_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    [ -n "$old_list_id" ] && _wifi_delete_message "$old_list_id"
    rm -f "$WIFI_MSG_ID_FILE"

    local tmp_msg=$( _wifi_send_temp "🔄 <b>Подключение к сети '$ssid'...</b>" "" )
    echo "$tmp_msg" > /tmp/telegram_bot/wifi/connecting_msg_id

    local sec_list=$(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p')
    local -a sec_arr=()
    while IFS= read -r _s; do [ -n "$_s" ] && sec_arr+=("$_s"); done <<< "$sec_list"

    local _i
    for ((_i=${#sec_arr[@]}-1; _i>=0; _i--)); do
        local sec_name="${sec_arr[_i]}"
        local dev=$(uci -q get "wireless.$sec_name.device" 2>/dev/null)
        local mode=$(uci -q get "wireless.$sec_name.mode" 2>/dev/null)
        local _created=$(uci -q get "wireless.$sec_name.created_by" 2>/dev/null)
        
        if [ "$dev" = "$radio" ] && [ "$mode" = "sta" ]; then
            if [ "$_created" != "tgbot" ]; then
                echo "$(date): _wifi_create_sta_connect: пропускаю чужую STA $sec_name" >> /tmp/telegram_bot/logs/bot.log
                continue
            fi
            local monitor_pid_file="/tmp/telegram_bot/wifi/sta_monitor_${sec_name}.pid"
            if [ -f "$monitor_pid_file" ]; then
                local pid=$(cat "$monitor_pid_file" 2>/dev/null)
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
                rm -f "$monitor_pid_file"
            fi
            uci delete "wireless.$sec_name" 2>/dev/null
        fi
    done
    
    uci commit wireless
    if [ $? -ne 0 ]; then send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1; return 1; fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then send_message "❌ Ошибка при перезапуске Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1; return 1; fi
    sleep 1

    local _wwan_existed=0
    if uci -q get network.wwan >/dev/null 2>&1; then
        _wwan_existed=1
        uci set network.wwan.metric='20'
        uci commit network
    else
        _wwan_existed=0
        uci set network.wwan=interface
        uci set network.wwan.proto='dhcp'
        uci set network.wwan.metric='20'
        uci set network.wwan.created_by='tgbot'
        uci commit network
    fi

    _wifi_ensure_wwan_firewall

    local iface_name=$(_generate_iface_name "sta" "$radio")
    uci set wireless."$iface_name"=wifi-iface
    uci set wireless."$iface_name".device="$radio"
    uci set wireless."$iface_name".mode="sta"
    uci set wireless."$iface_name".network="wwan"
    uci set wireless."$iface_name".ssid="$ssid"
    uci set wireless."$iface_name".created_by='tgbot'
    if [ -z "$encryption" ] || [ "$encryption" = "none" ]; then
        uci set wireless."$iface_name".encryption="none"
    else
        uci set wireless."$iface_name".encryption="$encryption"
        [ -n "$password" ] && uci set wireless."$iface_name".key="$password"
    fi
    uci set wireless."$iface_name".disassociate_low_ack='0'
    uci set wireless."$iface_name".disabled='0'
    
    uci commit wireless
    if [ $? -ne 0 ]; then send_message "❌ Ошибка при сохранении настроек Wi-Fi." '{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"wifi_cancel"}]]}' >/dev/null 2>&1; return 1; fi
    sleep 2
    _wifi_safe_reload
    if [ $? -ne 0 ]; then send_message "❌ Ошибка при перезапуске Wi-Fi для $radio." >/dev/null 2>&1; return 1; fi
    sleep 1

    local iface=""
    local timeout=15
    local count=0
    while [ $count -lt $timeout ]; do
        iface=$(ubus call network.wireless status 2>/dev/null | jq -r ".radio${radio_num}.interfaces[] | select(.config.mode == \"sta\") | .ifname" 2>/dev/null | head -1)
        if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then break; fi
        sleep 1
        count=$((count+1))
    done

    if [ -z "$iface" ] || ! ip link show "$iface" >/dev/null 2>&1; then
        uci delete "wireless.$iface_name" 2>/dev/null
        if [ "$_wwan_existed" = "0" ]; then
            uci delete network.wwan 2>/dev/null
            for zone in $(uci show firewall 2>/dev/null | grep -E "firewall\.[^=]+=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
                uci -q del_list "firewall.$zone.network=wwan" 2>/dev/null
            done
            uci commit firewall
        fi
        uci commit wireless; uci commit network
        sleep 2
        _wifi_safe_reload
        sleep 1
        local err_text="❌ <b>Не удалось создать интерфейс для сети '$ssid'.</b>"
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$tmp_msg" --data-urlencode text="$err_text" -d parse_mode="HTML" >/dev/null 2>&1
        _wifi_create_sta_step2
        return 1
    fi

    local ip=""
    local ip_timeout=20
    local ip_count=0
    while [ $ip_count -lt $ip_timeout ]; do
        ip=$(ip addr show "$iface" 2>/dev/null | grep -o "inet [0-9.]*" | awk '{print $2}' | head -1)
        if [ -n "$ip" ]; then break; fi
        sleep 1
        ip_count=$((ip_count+1))
    done

    if [ -n "$ip" ]; then
        _wifi_delete_message "$tmp_msg"
        rm -f /tmp/telegram_bot/wifi/connecting_msg_id

        local success_msg="✅ <b>Роутер подключён к сети '$ssid' на $radio.</b>
🌐 IP адрес: $ip"
        local _s_id=$( _wifi_send_temp "$success_msg" "" )
        echo "$_s_id" > /tmp/telegram_bot/wifi/success_msg_id

        rm -f "$WIFI_CREATE_RADIO_FILE" /tmp/telegram_bot/wifi/create_type /tmp/telegram_bot/wifi/scan_result /tmp/telegram_bot/wifi/sta_essid /tmp/telegram_bot/wifi/sta_enc
        show_wifi_vif_menu
        return 0
    else
        uci delete "wireless.$iface_name" 2>/dev/null
        if [ "$_wwan_existed" = "0" ]; then
            uci delete network.wwan 2>/dev/null
            for zone in $(uci show firewall 2>/dev/null | grep -E "firewall\.[^=]+=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
                uci -q del_list "firewall.$zone.network=wwan" 2>/dev/null
            done
            uci commit firewall
        fi
        uci commit wireless; uci commit network
        
        if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then iw dev "$iface" del 2>/dev/null; fi
        sleep 2
        _wifi_safe_reload
        sleep 1

        local err_text="❌ <b>Не удалось подключиться к сети '$ssid'.</b>
Проверьте правильность ввода пароля."
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d chat_id="$CHAT_ID" -d message_id="$tmp_msg" --data-urlencode text="$err_text" -d parse_mode="HTML" >/dev/null 2>&1

        _wifi_create_sta_step2
        return 1
    fi
        ) 200>/var/lock/wifi_fix.lock
}

_wifi_monitor_sta_connection() {
    local iface="$1"
    local section="$2"
    local radio="$3"

    printf 'stamon_%s' "${radio#radio}" > /proc/$$/comm 2>/dev/null

    local check_interval=10
    local max_failures=3
    local fail_count=0

    while true; do
        if ! uci -q get "wireless.$section" >/dev/null 2>&1; then break; fi
        local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null || echo "0")
        if [ "$disabled" = "1" ]; then break; fi

        local error=0
        if ! ip link show "$iface" >/dev/null 2>&1; then
            error=1
        else
            # Самая надежная проверка: спрашиваем у драйвера, есть ли коннект
            local iw_info=$(iw dev "$iface" link 2>/dev/null)
            if echo "$iw_info" | grep -q "Not connected"; then
                error=1
            else
                local ip=$(ip addr show "$iface" 2>/dev/null | grep -o "inet [0-9.]*" | awk '{print $2}' | head -1)
                if [ -z "$ip" ]; then error=1; fi
            fi
        fi

        if [ $error -eq 1 ]; then
            fail_count=$((fail_count + 1))
        else
            fail_count=0
        fi

        if [ $fail_count -ge $max_failures ]; then
            _wifi_rollback_sta "$section" "$radio" "Потеря соединения c $iface"
            break
        fi
        sleep $check_interval
    done
    rm -f "/tmp/telegram_bot/wifi/sta_monitor_${section}.pid"
}

_wifi_start_all_sta_monitors() {
    local started=0
    local skipped=0

    for pid_file in /tmp/telegram_bot/wifi/sta_monitor_*.pid; do
        [ -f "$pid_file" ] || continue
        local _sec_from_file=$(basename "$pid_file" | sed 's/^sta_monitor_//;s/\.pid$//')
        if ! uci -q get "wireless.$_sec_from_file" >/dev/null 2>&1; then
            local _orphan_pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$_orphan_pid" ] && kill -0 "$_orphan_pid" 2>/dev/null; then kill "$_orphan_pid" 2>/dev/null; fi
            rm -f "$pid_file"
        fi
    done

    local sec_list=$(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p')
    local sec_name
    for sec_name in $sec_list; do
        [ -z "$sec_name" ] && continue
        local mode=$(uci -q get "wireless.$sec_name.mode" 2>/dev/null)
        [ "$mode" = "sta" ] || continue
        local disabled=$(uci -q get "wireless.$sec_name.disabled" 2>/dev/null)
        [ "$disabled" = "1" ] && continue

        local section="$sec_name"
        local radio=$(uci -q get "wireless.$section.device" 2>/dev/null)
        [ -z "$radio" ] && continue
        local radio_num="${radio#radio}"

        local iface=$(ubus call network.wireless status 2>/dev/null | jq -r ".radio${radio_num}.interfaces[] | select(.config.mode == \"sta\") | .ifname" 2>/dev/null | head -1)
        if [ -z "$iface" ]; then continue; fi

        local pid_file="/tmp/telegram_bot/wifi/sta_monitor_${section}.pid"
        local alive=0

        if [ -f "$pid_file" ]; then
            local old_pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                if tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -q "$section"; then alive=1; else rm -f "$pid_file"; fi
            else
                rm -f "$pid_file"
            fi
        fi

        if [ "$alive" = "0" ]; then
            local _scan_pid _scan_cmd
            for _scan_dir in /proc/[0-9]*; do
                _scan_pid="${_scan_dir#/proc/}"
                [ -r "$_scan_dir/cmdline" ] || continue
                _scan_cmd=$(tr '\0' ' ' < "$_scan_dir/cmdline" 2>/dev/null)
                case "$_scan_cmd" in
                    *_wifi_monitor_sta_connection*"$section"*) echo "$_scan_pid" > "$pid_file"; alive=1; break ;;
                esac
            done
        fi

        if [ "$alive" = "1" ]; then
            skipped=$((skipped+1))
        else
            rm -f "$pid_file"
            if command -v setsid >/dev/null 2>&1; then
                setsid /bin/bash -c "
                    exec 200>&-
                    . /etc/telegram_bot/bot_config.sh
                    . /etc/telegram_bot/wifi.sh 2>/dev/null
                    echo \$\$ > '$pid_file'
                    _wifi_monitor_sta_connection '$iface' '$section' '$radio'
                " </dev/null >>/tmp/telegram_bot/logs/bot.log 2>&1 200<&- &
            else
                /bin/bash -c "
                    exec 200>&-
                    . /etc/telegram_bot/bot_config.sh
                    . /etc/telegram_bot/wifi.sh 2>/dev/null
                    echo \$\$ > '$pid_file'
                    _wifi_monitor_sta_connection '$iface' '$section' '$radio'
                " </dev/null >>/tmp/telegram_bot/logs/bot.log 2>&1 200<&- &
            fi
            started=$((started+1))
        fi
    done
    return 0
}

# ==============================================================================
# ✍️ РАЗДЕЛ 8: ОБРАБОТЧИКИ ВВОДА И CALLBACK-КНОПОК
# ==============================================================================

_send_input_error() {
    local err_msg="$1"

    local old_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
    if [ -n "$old_msg_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1
        rm -f "$WIFI_MSG_ID_FILE"
    fi

    _wifi_pending_add "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_INPUT_MSG_ID"
    _WIFI_INPUT_MSG_ID=""

    local response=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="❌ $err_msg" -d parse_mode="HTML" 2>&1)
    local error_msg_id=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
    _wifi_pending_add "$_WIFI_PENDING_ERROR_FILE" "$error_msg_id"

    local mode=$(cat "$WIFI_EDIT_MODE_FILE" 2>/dev/null)

    if [ "$mode" = "edit_ssid" ]; then
        _wifi_edit_ssid_start
        return
    fi
    if [ "$mode" = "edit_key" ]; then
        _wifi_edit_key_start
        return
    fi

    local create_type=$(cat /tmp/telegram_bot/wifi/create_type 2>/dev/null)
    if [ -n "$create_type" ]; then
        if [ -f "$WIFI_CREATE_RADIO_FILE" ]; then
            case "$create_type" in
                "ap")    _wifi_create_ap_step2 ;;
                "guest") _wifi_create_guest_step2 ;;
                "sta")   _wifi_create_sta_step2 ;;
                *)       show_wifi_vif_menu ;;
            esac
            return
        else
            _wifi_create_choose_radio "$create_type"
            return
        fi
    fi

    local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
    if [ -n "$section" ]; then
        local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
        local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
        local m=$(uci -q get "wireless.$section.mode" 2>/dev/null)
        local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
        [ -z "$disabled" ] && disabled="0"
        show_wifi_network_edit "$section" "$ssid" "$device" "$m" "$disabled" "false"
    else
        show_wifi_vif_menu
    fi
}

handle_wifi_text_input() {
    local text="$1"
    local mode=$(cat "$WIFI_EDIT_MODE_FILE" 2>/dev/null)
    [ -z "$mode" ] && return 1

    _WIFI_INPUT_MSG_ID="$_IN_TEXT_MSG_ID"
    _IN_TEXT_MSG_ID=""

    local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
    [ -n "$prompt_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
        -d chat_id="$CHAT_ID" -d message_id="$prompt_id" >/dev/null 2>&1
    rm -f "$WIFI_EDIT_MSG_ID_FILE"

    case "$mode" in
        "ap_ssid"|"guest_ssid"|"edit_ssid")
            if [ -z "$text" ]; then
                _send_input_error "SSID не может быть пустым."
                return
            fi

            local _ssid_bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
            if [ "$_ssid_bytes" -gt 32 ]; then
                local _sym_len=${#text}
                _send_input_error "SSID слишком длинный: ${_ssid_bytes} байт (лимит 32).
Символов: ${_sym_len}. Кириллица = 2 байта/символ,
поэтому максимум ~16 русских букв.
Сократите имя или используйте латиницу."
                return
            fi
            if ! _wifi_is_valid_input "$text"; then
                _send_input_error "Разрешены: латиница, кирилица, цифры, 
спецсимволы. Введите верно:"
                return
            fi

            if [ "$mode" = "edit_ssid" ]; then
                _wifi_input_finalize
                _wifi_edit_ssid_finish "$text"
                rm -f "$WIFI_EDIT_MODE_FILE"
                return
            fi

            _wifi_input_finalize
            echo "$text" > /tmp/telegram_bot/wifi/new_ap_ssid
            local next_mode="ap_password"
            local prompt_text="️🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):"
            if [ "$mode" = "guest_ssid" ]; then
                next_mode="guest_password"
                prompt_text="🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):"
            fi
            echo "$next_mode" > "$WIFI_EDIT_MODE_FILE"
            _wifi_send_prompt "$prompt_text" \
                '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
            ;;

        "ap_password"|"guest_password"|"edit_key")
            if ! _wifi_is_valid_input "$text"; then
                _wifi_pending_add "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_INPUT_MSG_ID"
                _WIFI_INPUT_MSG_ID=""
                local _eresp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="❌ Разрешены: латиница, кирилица, цифры, 
спецсимволы. Попробуйте ещё раз:" -d parse_mode="HTML" 2>&1)
                local _emid=$(echo "$_eresp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
                _wifi_pending_add "$_WIFI_PENDING_ERROR_FILE" "$_emid"
                
                local prompt_text=""
                case "$mode" in
                    "ap_password") prompt_text="🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):" ;;
                    "guest_password") prompt_text="🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):" ;;
                    "edit_key") prompt_text="🔑 Введите новый пароль (мин. 8 симв. 
или введите 1 символ для открытой сети):" ;;
                esac
                _wifi_send_prompt "$prompt_text" \
                    '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
                return
            fi

            local len=${#text}
            local is_open=0
            if [ "$len" -eq 0 ] || [ "$len" -eq 1 ]; then
                is_open=1
            elif [ "$len" -lt 8 ]; then
                _wifi_pending_add "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_INPUT_MSG_ID"
                _WIFI_INPUT_MSG_ID=""
                local _eresp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="❌ Количество символов меньше 8, 
введите правильное количество." -d parse_mode="HTML" 2>&1)
                local _emid=$(echo "$_eresp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
                _wifi_pending_add "$_WIFI_PENDING_ERROR_FILE" "$_emid"
                local prompt_text=""
                case "$mode" in
                    "ap_password") prompt_text="🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):" ;;
                    "guest_password") prompt_text="🔑 Введите пароль (мин. 8 символов или 
введите 1 символ для открытой сети):" ;;
                    "edit_key") prompt_text="🔑 Введите новый пароль (мин. 8 символов 
или введите 1 символ для открытой сети):" ;;
                esac
                _wifi_send_prompt "$prompt_text" \
                    '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
                return
            fi

            if [ "$mode" = "edit_key" ]; then
                _wifi_input_finalize
                if [ "$is_open" -eq 1 ]; then _wifi_edit_key_finish ""; else _wifi_edit_key_finish "$text"; fi
                rm -f "$WIFI_EDIT_MODE_FILE"
                return
            fi

            local ssid=$(cat /tmp/telegram_bot/wifi/new_ap_ssid 2>/dev/null)
            if [ -z "$ssid" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="❌ SSID не найден." -d parse_mode="HTML" > /dev/null 2>&1
                show_wifi_vif_menu
                return
            fi

            _wifi_input_finalize
            if [ "$mode" = "ap_password" ]; then
                if [ "$is_open" -eq 1 ]; then _wifi_create_ap_finish "$ssid" ""; else _wifi_create_ap_finish "$ssid" "$text"; fi
            elif [ "$mode" = "guest_password" ]; then
                if [ "$is_open" -eq 1 ]; then _wifi_create_guest_finish "$ssid" ""; else _wifi_create_guest_finish "$ssid" "$text"; fi
            fi
            rm -f /tmp/telegram_bot/wifi/new_ap_ssid "$WIFI_EDIT_MODE_FILE"
            ;;

        "sta_password")
            if ! _wifi_is_valid_input "$text"; then
                _wifi_pending_add "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_INPUT_MSG_ID"
                _WIFI_INPUT_MSG_ID=""
                local _eresp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="❌ Разрешены: латиница, кирилица, цифры,  
спецсимволы. Попробуйте ещё раз:" -d parse_mode="HTML" 2>&1)
                local _emid=$(echo "$_eresp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
                _wifi_pending_add "$_WIFI_PENDING_ERROR_FILE" "$_emid"
                local essid=$(cat /tmp/telegram_bot/wifi/sta_essid 2>/dev/null)
                _wifi_send_prompt "🔑 Введите пароль для сети $essid 
(минимум 8 символов):" \
                    '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
                return
            fi
            if [ ${#text} -lt 8 ]; then
                _wifi_pending_add "$_WIFI_PENDING_INVALID_FILE" "$_WIFI_INPUT_MSG_ID"
                _WIFI_INPUT_MSG_ID=""
                local _eresp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                    -d chat_id="$CHAT_ID" --data-urlencode text="❌ Количество символов меньше 8, 
введите правильное количество." -d parse_mode="HTML" 2>&1)
                local _emid=$(echo "$_eresp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
                _wifi_pending_add "$_WIFI_PENDING_ERROR_FILE" "$_emid"
                local essid=$(cat /tmp/telegram_bot/wifi/sta_essid 2>/dev/null)
                _wifi_send_prompt "🔑 Введите пароль для сети $essid 
(минимум 8 символов):" \
                    '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
                return
            fi
            local ssid=$(cat /tmp/telegram_bot/wifi/sta_essid 2>/dev/null)
            local enc_uci=$(cat /tmp/telegram_bot/wifi/sta_enc 2>/dev/null)
            if [ -z "$ssid" ]; then
                _send_input_error "SSID не найден."
                return
            fi
            _wifi_input_finalize
            _wifi_create_sta_connect "$ssid" "$text" "$enc_uci"
            ;;
        *)
            rm -f "$WIFI_EDIT_MODE_FILE"
            _wifi_send_main "❌ Неизвестный режим ввода." \
                '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_back_main"}]]}'
            ;;
    esac
}

handle_wifi_callback() {
    (
    trap '_bot_mark_busy_end' EXIT
    local callback_data="$1"
    local callback_id="$2"
    local message_id="$3"
    local chat_id="$4"
    _WIFI_CB_ANSWERED=""
	
    _wifi_cleanup_success_msg

    if [ -n "$chat_id" ] && [ "$chat_id" != "$CHAT_ID" ]; then
        _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⛔ Доступ запрещён" > /dev/null 2>&1
        return
    fi

    if [ ! -f "/tmp/telegram_bot/wifi/active.lock" ]; then
        _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⚠️ Выберите действие в меню Wi-Fi" -d show_alert="true" > /dev/null 2>&1
        return
    fi

    if ! _wifi_is_callback_allowed "$callback_data"; then
        local cur_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
        if [ -n "$cur_msg_id" ] && [ "$message_id" = "$cur_msg_id" ]; then
            _wifi_answer_cb -d callback_query_id="$callback_id" > /dev/null 2>&1
            return
        fi
        local err_text="$(_wifi_get_error_text)"
        _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⚠️ $err_text" -d show_alert="true" > /dev/null 2>&1
        _wifi_redraw_current_menu
        return
    fi

   # [ -n "$message_id" ] && [ ! -f "$WIFI_MSG_ID_FILE" ] && echo "$message_id" > "$WIFI_MSG_ID_FILE"

    if [ -f "$WIFI_EDIT_MODE_FILE" ]; then
        case "$callback_data" in
            wifi_cancel_edit|wifi_sta_retry_password) : ;;
            *)
                local _pid=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
                if [ -n "$_pid" ]; then
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_pid" >/dev/null 2>&1
                fi
                rm -f "$WIFI_EDIT_MSG_ID_FILE" "$WIFI_EDIT_MODE_FILE"
                rm -f /tmp/telegram_bot/wifi/new_ap_ssid
                ;;
        esac
    fi

    case "$callback_data" in
        wifi_restart_radio_0|wifi_restart_radio_1|wifi_radio_*_set_channel_*|wifi_radio_*_set_country_*| \
        wifi_radio_*_set_width_*|wifi_radio_*_set_standard_*|wifi_radio_*_set_power_*|wifi_radio_*_legacy_toggle| \
        wifi_sta_refresh|wifi_create_sta|wifi_sta_select_*|wifi_toggle_network|wifi_delete_network|wifi_enc_set_*)
            _bot_mark_busy_start "wifi"
            ;;
    esac

    case "$callback_data" in
        wifi_refresh_status) show_wifi_main ;;
        wifi_back_main) show_wifi_main ;;
        wifi_radio_0|wifi_radio_24) show_wifi_radio_settings "24" ;;
        wifi_radio_1|wifi_radio_5) show_wifi_radio_settings "5" ;;
        wifi_restart_radio_0)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="🔄 Radio0 перезапускается..." -d show_alert="false" >/dev/null 2>&1
            ubus call network.wireless down '{ "device": "radio0" }' 2>/dev/null
            _wait_for_radio_ready 0 5 1
            ubus call network.wireless up '{ "device": "radio0" }' 2>/dev/null
            _wait_for_radio_ready 0 1 15
            
            local old_msg_id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null)
            if [ -n "$old_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1
                rm -f /tmp/telegram_bot/wifi/msg_id
            fi
            local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✅ <b>Radio0 перезапущено</b>" -d parse_mode="HTML" 2>&1)
            local _s_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
            [ -n "$_s_id" ] && echo "$_s_id" > /tmp/telegram_bot/wifi/success_msg_id
            show_wifi_main
            ;;
        wifi_restart_radio_1)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="🔄 Radio1 перезапускается..." -d show_alert="false" >/dev/null 2>&1
            sleep 2
            ubus call network.wireless down '{ "device": "radio1" }' 2>/dev/null
            _wait_for_radio_ready 1 5 1
            ubus call network.wireless up '{ "device": "radio1" }' 2>/dev/null
            _wait_for_radio_ready 1 1 35
            
            local old_msg_id=$(cat /tmp/telegram_bot/wifi/msg_id 2>/dev/null)
            if [ -n "$old_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$old_msg_id" >/dev/null 2>&1
                rm -f /tmp/telegram_bot/wifi/msg_id
            fi
            local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="✅ <b>Radio1 перезапущено</b>" -d parse_mode="HTML" 2>&1)
            local _s_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
            [ -n "$_s_id" ] && echo "$_s_id" > /tmp/telegram_bot/wifi/success_msg_id
            show_wifi_main
            ;;
        wifi_radio_24_channel|wifi_radio_5_channel)
            local band=""; case "$callback_data" in wifi_radio_24_channel) band="24" ;; wifi_radio_5_channel) band="5" ;; esac
            show_wifi_radio_channel "$band" ;;
        wifi_radio_24_width|wifi_radio_5_width)
            local band=""; case "$callback_data" in wifi_radio_24_width) band="24" ;; wifi_radio_5_width) band="5" ;; esac
            show_wifi_radio_width "$band" ;;
        wifi_radio_24_standard|wifi_radio_5_standard)
            local band=""; case "$callback_data" in wifi_radio_24_standard) band="24" ;; wifi_radio_5_standard) band="5" ;; esac
            show_wifi_radio_standard "$band" ;;
        wifi_radio_24_txpower|wifi_radio_5_txpower)
            local band=""; case "$callback_data" in wifi_radio_24_txpower) band="24" ;; wifi_radio_5_txpower) band="5" ;; esac
            show_wifi_radio_txpower "$band" ;;
        wifi_radio_24_country|wifi_radio_5_country)
            local band=""; case "$callback_data" in wifi_radio_24_country) band="24" ;; wifi_radio_5_country) band="5" ;; esac
            show_wifi_radio_select_country "$band" ;;
        wifi_radio_24_legacy_toggle|wifi_radio_5_legacy_toggle)
            local band="${callback_data#wifi_radio_}"; band="${band%_legacy_toggle}"
            _wifi_toggle_legacy "$band" ;;
        wifi_radio_24_refresh|wifi_radio_5_refresh)
            local band="${callback_data#wifi_radio_}"; band="${band%_refresh}"
            _wifi_answer_cb -d callback_query_id="$callback_id" >/dev/null 2>&1
            show_wifi_radio_settings "$band"
            return ;;
        wifi_radio_24_set_country_*|wifi_radio_5_set_country_*)
            local band="${callback_data#wifi_radio_}"; band="${band%_set_country_*}"
            local country="${callback_data##*_set_country_}"
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⏳ Применяю страну $country, ожидайте..." >/dev/null 2>&1
            _wifi_set_country "$band" "$country"
            return ;;
        wifi_radio_24_set_power_*|wifi_radio_5_set_power_*)
            local band="${callback_data#wifi_radio_}"; band="${band%_set_power_*}"
            local power="${callback_data##*_set_power_}"
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⏳ Меняю мощность на ${power} dBm..." >/dev/null 2>&1
            _wifi_apply_txpower_live "$band" "$power"
            show_wifi_radio_txpower "$band"
            return ;;
        wifi_radio_24_set_channel_*|wifi_radio_5_set_channel_*)
            local band="${callback_data#wifi_radio_}"; band="${band%_set_channel_*}"
            local ch="${callback_data##*_set_channel_}"
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⏳ Меняю канал на $ch..." >/dev/null 2>&1
            _wifi_apply_channel_live "$band" "$ch"
            show_wifi_radio_channel "$band"
            return ;;
        wifi_radio_24_set_width_*|wifi_radio_5_set_width_*)
            local band="${callback_data#wifi_radio_}"; band="${band%_set_width_*}"
            local width="${callback_data##*_set_width_}"
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⏳ Меняю ширину на $width..." >/dev/null 2>&1

            if [ "$band" = "24" ]; then
                local current_htmode=$(_wifi_get_radio_param "$band" "htmode")
                local current_standard="n"
                if [[ "$current_htmode" == HE* ]]; then current_standard="ax"
                elif [[ "$current_htmode" == VHT* ]]; then current_standard="ac"
                elif [[ "$current_htmode" == HT* ]]; then current_standard="n"
                elif [[ "$current_htmode" == "NOHT" ]]; then current_standard="legacy"; fi

                case "$width" in
                    "HT20") case "$current_standard" in "ax") width="HE20" ;; "ac") width="VHT20" ;; "n") width="HT20" ;; "legacy") width="NOHT" ;; *) width="HT20" ;; esac ;;
                    "HT40") case "$current_standard" in "ax") width="HE40" ;; "ac") width="VHT40" ;; "n") width="HT40" ;; "legacy") width="NOHT" ;; *) width="HT40" ;; esac ;;
                esac
            fi
            _wifi_set_radio_param "$band" "htmode" "$width"
            show_wifi_radio_width "$band"
            return ;;
        wifi_radio_24_set_standard_*|wifi_radio_5_set_standard_*)
            local band="${callback_data#wifi_radio_}"; band="${band%_set_standard_*}"
            local std="${callback_data##*_set_standard_}"
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⏳ Меняю стандарт на $std..." >/dev/null 2>&1

            local radio=$(_get_radio_path "$band")
            uci -q delete "wireless.$radio.vht_oper_chwidth" 2>/dev/null
            uci -q delete "wireless.$radio.vht_oper_centr_freq_seg0_idx" 2>/dev/null
            uci -q delete "wireless.$radio.vht_oper_centr_freq_seg1_idx" 2>/dev/null
            uci -q delete "wireless.$radio.he_bss_color" 2>/dev/null
            uci -q delete "wireless.$radio.he_ldpc" 2>/dev/null
            uci -q delete "wireless.$radio.he_su_beamformer" 2>/dev/null
            uci -q delete "wireless.$radio.he_su_beamformee" 2>/dev/null
            uci -q delete "wireless.$radio.he_mu_beamformer" 2>/dev/null
            uci -q delete "wireless.$radio.he_operation" 2>/dev/null
            uci -q delete "wireless.$radio.he_mu_edca" 2>/dev/null
            uci -q delete "wireless.$radio.he_csa" 2>/dev/null
            uci -q delete "wireless.$radio.require_mode" 2>/dev/null

            local new_htmode=""
            case "$std" in
                "legacy") new_htmode="NOHT" ;;
                "n") new_htmode="HT20" ;;
                "ac") if [ "$band" = "24" ]; then new_htmode="HT40"; else new_htmode="VHT80"; fi ;;
                "ax") if [ "$band" = "24" ]; then new_htmode="HE40"; else new_htmode="HE80"; fi ;;
                *) new_htmode="HT20" ;;
            esac

            uci set "wireless.$radio.htmode=$new_htmode"
            uci commit wireless
            _wifi_safe_reload
            show_wifi_radio_standard "$band"
            return ;;
        wifi_vif_menu) show_wifi_vif_menu ;;
        wifi_vif_refresh)
            _wifi_answer_cb -d callback_query_id="$callback_id" >/dev/null 2>&1
            show_wifi_vif_menu
            return ;;
        wifi_vif_select_*)
            local num="${callback_data#wifi_vif_select_}"
            if [ ! -f "/tmp/telegram_bot/wifi/vif_list" ]; then
                _wifi_send_main "❌ Список сетей устарел. Обновите меню." '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
                return
            fi
            local total=$(head -1 /tmp/telegram_bot/wifi/vif_list)
            if [ "$num" -gt "$total" ] || [ "$num" -lt 1 ]; then
                _wifi_send_main "❌ Неверный номер сети." '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
                return
            fi
            local line=$(sed -n "$((num+1))p" /tmp/telegram_bot/wifi/vif_list)
            local section=$(echo "$line" | cut -d'|' -f1)
            local ssid=$(echo "$line" | cut -d'|' -f2)
            local device=$(echo "$line" | cut -d'|' -f3)
            local mode=$(echo "$line" | cut -d'|' -f4)
            local disabled=$(echo "$line" | cut -d'|' -f5)
            show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
            ;;
        wifi_show_password_toggle) _wifi_show_password_toggle "$callback_id" ;;
        wifi_create_ap) _wifi_create_ap_start ;;
        wifi_create_guest) _wifi_create_guest_start ;;
        wifi_sta_retry_password)
            local essid=$(cat /tmp/telegram_bot/wifi/sta_essid 2>/dev/null)
            if [ -z "$essid" ]; then
                _wifi_send_main "❌ Ошибка: сеть не выбрана." '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"wifi_vif_menu"}]]}'
                return
            fi
            echo "sta_password" > "$WIFI_EDIT_MODE_FILE"
            _wifi_send_prompt "🔑 Введите пароль для сети $essid 
			(минимум 8 символов):" '{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"wifi_cancel_edit"}]]}'
            ;;
        wifi_create_sta)
            rm -f /tmp/telegram_bot/wifi/sta_essid /tmp/telegram_bot/wifi/sta_enc
            rm -f "$WIFI_EDIT_MODE_FILE"
            _wifi_create_sta_start
            ;;
        wifi_create_radio_24|wifi_create_radio_5)
            local band="${callback_data#wifi_create_radio_}"
            _wifi_create_radio_selected "$band"
            ;;
        wifi_sta_refresh) _wifi_create_sta_step2 ;;
        wifi_sta_select_*)
            local num="${callback_data#wifi_sta_select_}"
            _wifi_create_sta_select "$num"
            ;;
        wifi_edit_ssid) _wifi_edit_ssid_start ;;
        wifi_edit_key) _wifi_edit_key_start ;;
        wifi_edit_encryption) _wifi_edit_encryption_start ;;
        wifi_enc_set_*)
            local new_enc="${callback_data#wifi_enc_set_}"
            _wifi_edit_encryption_finish "$new_enc"
            ;;
        wifi_network_edit_back)
            local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
            if [ -n "$section" ]; then
                local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
                local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
                local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
                local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
                [ -z "$disabled" ] && disabled="0"
                show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
            else
                show_wifi_vif_menu
            fi
            ;;
        wifi_toggle_network) _wifi_toggle_network ;;
        wifi_delete_network)
            local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
            if [ -z "$section" ]; then
                _wifi_answer_cb -d callback_query_id="$callback_id" -d text="❌ Ошибка: секция не определена" >/dev/null 2>&1
                return
            fi
            local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
            [ -z "$ssid" ] && ssid=$(uci -q get "wireless.$section.mesh_id" 2>/dev/null)
            local safe_ssid=$(html_escape "$ssid")
            
            local text="⚠️ <b>Удаление сети</b>
            
Вы действительно хотите удалить сеть <b>$safe_ssid</b>?
Это действие нельзя отменить."
            local kb='{"inline_keyboard":[[{"text":"✅ Да, удалить","callback_data":"wifi_confirm_delete_yes"},{"text":"❌ Отмена","callback_data":"wifi_confirm_delete_no"}]]}'
            _wifi_send_edit "$text" "$kb"
            _wifi_answer_cb -d callback_query_id="$callback_id" >/dev/null 2>&1
            ;;
        wifi_confirm_delete_yes) _wifi_delete_network "$callback_id" ;;
        wifi_confirm_delete_no)
            local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
            if [ -n "$section" ]; then
                local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
                [ -z "$ssid" ] && ssid=$(uci -q get "wireless.$section.mesh_id" 2>/dev/null)
                local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
                local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
                local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
                [ -z "$disabled" ] && disabled="0"
                show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled"
            else
                show_wifi_vif_menu
            fi
            _wifi_answer_cb -d callback_query_id="$callback_id" >/dev/null 2>&1
            ;;
        wifi_nop_channel)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⛔ Канал заблокирован: активен режим Клиента (STA)" -d show_alert="false" >/dev/null 2>&1
            ;;
        wifi_nop_80211b)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⛔ 802.11b заблокирован: доступен только на 2.4 GHz" -d show_alert="false" >/dev/null 2>&1
            ;;
        wifi_nop)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⛔ Действие недоступно в текущем режиме" -d show_alert="false" >/dev/null 2>&1
            ;;
        wifi_cancel_edit)
            _wifi_pending_flush
            _WIFI_INPUT_MSG_ID=""
            local create_type=$(cat /tmp/telegram_bot/wifi/create_type 2>/dev/null)
            
            local prompt_id=$(cat "$WIFI_EDIT_MSG_ID_FILE" 2>/dev/null)
            [ -n "$prompt_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$prompt_id" >/dev/null 2>&1
            rm -f "$WIFI_EDIT_MSG_ID_FILE" "$WIFI_EDIT_MODE_FILE" /tmp/telegram_bot/wifi/create_type "$WIFI_CREATE_RADIO_FILE" /tmp/telegram_bot/wifi/new_ap_ssid /tmp/telegram_bot/wifi/sta_essid /tmp/telegram_bot/wifi/sta_enc

            local error_msg_id=$(cat /tmp/telegram_bot/wifi/error_msg_id 2>/dev/null)
            if [ -n "$error_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$error_msg_id" >/dev/null 2>&1
                rm -f /tmp/telegram_bot/wifi/error_msg_id
            fi

            local main_msg_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
            if [ -n "$main_msg_id" ]; then
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$main_msg_id" >/dev/null 2>&1
                rm -f "$WIFI_MSG_ID_FILE"
            fi

            if [ -n "$create_type" ]; then
                _wifi_create_choose_radio "$create_type"
                return
            fi

            local section=$(cat "$WIFI_EDIT_SECTION_FILE" 2>/dev/null)
            if [ -n "$section" ]; then
                local ssid=$(uci -q get "wireless.$section.ssid" 2>/dev/null)
                local device=$(uci -q get "wireless.$section.device" 2>/dev/null)
                local mode=$(uci -q get "wireless.$section.mode" 2>/dev/null)
                local disabled=$(uci -q get "wireless.$section.disabled" 2>/dev/null)
                [ -z "$disabled" ] && disabled="0"
                show_wifi_network_edit "$section" "$ssid" "$device" "$mode" "$disabled" "false"
            else
                rm -f /tmp/telegram_bot/wifi/edit_section
                show_wifi_vif_menu
            fi
            ;;
        wifi_cancel)
            _wifi_pending_flush
            _WIFI_INPUT_MSG_ID=""
            local main_id=$(cat "$WIFI_MSG_ID_FILE" 2>/dev/null)
            [ -n "$main_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$main_id" >/dev/null 2>&1
            rm -f "$WIFI_MSG_ID_FILE" "$WIFI_EDIT_MSG_ID_FILE" "$WIFI_EDIT_MODE_FILE" /tmp/telegram_bot/wifi/active.lock /tmp/telegram_bot/wifi/create_type "$WIFI_CREATE_RADIO_FILE" /tmp/telegram_bot/wifi/edit_section /tmp/telegram_bot/wifi/new_ap_ssid
            
            send_menu
            _wifi_answer_cb -d callback_query_id="$callback_id" --data-urlencode "text=🛜 Настройка Wi-Fi закрыта" >/dev/null 2>&1
            ;;
        *)
            _wifi_answer_cb -d callback_query_id="$callback_id" -d text="⚠️ Неизвестное действие" -d show_alert="true" > /dev/null 2>&1
            _wifi_redraw_current_menu
            ;;
    esac
    _wifi_answer_cb -d callback_query_id="$callback_id" > /dev/null 2>&1
    )
}