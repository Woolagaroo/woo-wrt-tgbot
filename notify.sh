#!/bin/bash
# ============================================================
# Модуль для отправки сообщений и запросов из бота.
# ============================================================

if [ -z "$BASH_VERSION" ]; then
    echo "❌ Ошибка: этот скрипт требует bash. Установите: opkg install bash (или apk add bash)" >&2
    exit 1
fi

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

. /etc/telegram_bot/bot_config.sh

check_required_utilities || exit 1

# ============================================================
# УТИЛИТЫ
# ============================================================

# Извлекает из строки лога числовой ключ для сортировки.
_extract_ts_key() {
    local line="$1"
    # Свой формат: MM.DD HH:MM:SS
    if [[ "$line" =~ ^([0-9]{2})\.([0-9]{2})\ +([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
        local mon="${BASH_REMATCH[1]}"
        local day="${BASH_REMATCH[2]}"
        local yr=$(date +%Y)
        local cur_mon=$(date +%m)
        if [ "$((10#$mon))" -gt "$((10#$cur_mon))" ]; then
            yr=$((yr - 1))
        fi
        printf "%s%s%02d%s%s%s" "$yr" "$mon" "$((10#$day))" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        return
    fi
    local mon_name day time yr
    # ISO 8601
    if [[ "$line" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[T\ ]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
        printf "%s%s%s%s%s%s" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
        return
    fi

    local f1 f2 f3 f4 f5
    read -r f1 f2 f3 f4 f5 _ <<< "$line"
    local check_rollover=0

    if [[ "$f1" =~ ^[A-Za-z]{3}$ ]] && [[ "$f2" =~ ^[0-9]+$ ]] && [[ "$f3" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        mon_name="$f1"; day="$f2"; time="$f3"; check_rollover=1
    elif [[ "$f1" =~ ^[A-Za-z]{3}$ ]] && [[ "$f2" =~ ^[A-Za-z]{3}$ ]] && [[ "$f3" =~ ^[0-9]+$ ]] && [[ "$f4" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && [[ "$f5" =~ ^[0-9]{4}$ ]]; then
        mon_name="$f2"; day="$f3"; time="$f4"; yr="$f5"
    elif [[ "$f1" =~ ^[A-Za-z]{3}$ ]] && [[ "$f2" =~ ^[A-Za-z]{3}$ ]] && [[ "$f3" =~ ^[0-9]+$ ]] && [[ "$f4" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        mon_name="$f2"; day="$f3"; time="$f4"; check_rollover=1
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
        _cur_mon=$(date +%m); _cur_yr=$(date +%Y)
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

cleanup() {
    rm -f /tmp/telegram_bot/traffic/bandix_speeds_$$ \
          /tmp/telegram_bot/traffic/lan_data_$$ \
          /tmp/telegram_bot/traffic/table_$$ \
          /tmp/telegram_bot/reboot/times_$$.tmp 2>/dev/null
}
trap cleanup EXIT TERM INT

# ============================================================
# «КЛИЕНТЫ ОНЛАЙН»
# ============================================================
_ONLINE_COUNTER_FILE="/tmp/telegram_bot/online/counter"
_ONLINE_DEVICES_FILE="/tmp/telegram_bot/online/last_devices"
_ONLINE_BLOCKED_FILE="/tmp/telegram_bot/online/blocked_macs"

# Возвращает все MAC, которые сейчас заблокированы на AP.
_get_blocked_macs() {
    local RECOVERY_FILE="/etc/telegram_bot/data/.blocked_from_whitelist.txt"
    local macs=""

    if [ -s "$RECOVERY_FILE" ]; then
        macs=$(awk -F'|' 'NF >= 2 { print tolower($1) }' "$RECOVERY_FILE" 2>/dev/null)
    fi

    local sec
    for sec in $(uci show wireless 2>/dev/null \
        | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
        local mode macfilter list
        mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
        [ "$mode" = "ap" ] || continue
        macfilter=$(uci -q get "wireless.$sec.macfilter" 2>/dev/null)
        [ "$macfilter" = "deny" ] || continue
        list=$(uci -q get "wireless.$sec.maclist" 2>/dev/null)
        [ -n "$list" ] && macs="${macs}"$'\n'"$(echo "$list" | tr ' ' '\n')"
    done

    printf '%s\n' "$macs" | tr 'A-Z' 'a-z' \
        | grep -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' \
        | sort -u
}

# Секция «🚫 ЗАБЛОКИРОВАННЫЕ».
_render_blocked_section() {
    local page_start="${1:-1}"
    local page_end="${2:-999999}"

    local blocked_macs
    blocked_macs=$(_get_blocked_macs)
    [ -z "$blocked_macs" ] && return 0

    local blocked_data=""
    local blocked_i
    blocked_i=$(cat "$_ONLINE_COUNTER_FILE" 2>/dev/null)
    [ -z "$blocked_i" ] && blocked_i=1

    local bmac
    while IFS= read -r bmac; do
        [ -z "$bmac" ] && continue

        if grep -q -F "|${bmac}$" "$_ONLINE_DEVICES_FILE" 2>/dev/null; then
            continue
        fi

        local bname=""
        if [ -f "$DHCP_LEASES" ]; then
            bname=$(awk -v m="$bmac" 'tolower($2) == tolower(m) {print $4; exit}' "$DHCP_LEASES")
        fi
        if [ -z "$bname" ] || [ "$bname" = "*" ]; then
            if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
                bname=$(awk -v m="$bmac" 'tolower($1) == tolower(m) {print $2,$3,$4,$5; exit}' /etc/telegram_bot/data/device_names.txt)
            fi
        fi
        [ -z "$bname" ] && bname="$bmac"

        local bip=""
        bip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null \
            | while IFS= read -r _bp_line; do
                  _bp_ip="${_bp_line%% *}"
                  _bp_mac=$(printf '%s' "$_bp_line" | sed -n 's/.*lladdr \([^ ]*\).*/\1/p')
                  [ -z "$_bp_mac" ] && continue
                  _bp_mac="${_bp_mac,,}"
                  if [ "$_bp_mac" = "$bmac" ]; then
                      echo "$_bp_ip"
                      break
                  fi
              done)
        [ -z "$bip" ] && bip="N/A"

        local bname_esc
        bname_esc=$(html_escape "$bname")

        if [ "$blocked_i" -ge "$page_start" ] && [ "$blocked_i" -le "$page_end" ]; then
            blocked_data="${blocked_data}${blocked_i}|${bname_esc}|🚫|—|—|${bip}|${bmac}\n"
        fi
        echo "${blocked_i}|${bmac}" >> "$_ONLINE_DEVICES_FILE"
        blocked_i=$((blocked_i+1))
    done <<< "$blocked_macs"

    [ -z "$blocked_data" ] && return 0

    echo "$blocked_i" > "$_ONLINE_COUNTER_FILE"

    local blocked_table
    blocked_table=$(printf "%b" "$blocked_data" | awk -F'|' '
    BEGIN {
        printf "%-2s %-21s  %s\n", "№", "Имя", "Mac"
        printf "%-2s %-21s  %s\n", "--", "---------------------",   "---------------------"
    }
    {
        name = $2
        gsub(/[\x00-\x1F\x7F]/, "", name)
        mac = $7
        gsub(/[^[:print:]]/, "", mac)

        # Если имя совпадает с MAC (нет ни lease, ни override) — не дублируем.
        if (tolower(name) == tolower(mac)) name = "Unknown"

        if (length(name) > 21) name = substr(name, 1, 23)

        printf "%-2s %-21s  🔗 %s\n", $1, name, mac
    }')

    printf '🚫 ЗАБЛОКИРОВАННЫЕ\n%s\n%s' "$SEP46" "$blocked_table"
}

_is_mac_blocked() {
    local mac_lc=$(echo "$1" | tr 'A-Z' 'a-z')
    [ -f "$_ONLINE_BLOCKED_FILE" ] || return 1
    grep -q -x -F "$mac_lc" "$_ONLINE_BLOCKED_FILE" 2>/dev/null
}

# ИМЕНА / IP / СТАТИЧЕСКИЕ ПРИВЯЗКИ
# IP устройства.
_nl_get_ip() {
    local mac="$1"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')
    local _ip=""

    if [ -f "$DHCP_LEASES" ]; then
        _ip=$(awk -v m="$mac_lc" 'tolower($2) == m {print $3; exit}' "$DHCP_LEASES" 2>/dev/null)
    fi

    if [ -z "$_ip" ]; then
        _ip=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null \
            | awk -v m="$mac_lc" '
                {
                    ip=""; mac=""
                    for (i=1; i<=NF; i++) {
                        if ($i == "lladdr") mac=$(i+1)
                        else if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i
                    }
                    if (tolower(mac) == m) { print ip; exit }
                }')
    fi

    [ -z "$_ip" ] && _ip="N/A"
    printf '%s' "$_ip"
}

# Имя устройства.
_nl_get_name() {
    local mac="$1"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')
    local _name=""

    if [ -f "$DHCP_LEASES" ]; then
        _name=$(awk -v m="$mac_lc" 'tolower($2) == m {print $4; exit}' "$DHCP_LEASES" 2>/dev/null)
        [ "$_name" = "*" ] && _name=""
    fi

    if [ -z "$_name" ] && [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
        _name=$(awk -v m="$mac_lc" 'tolower($1) == m {print $2,$3,$4,$5; exit}' \
            /etc/telegram_bot/data/device_names.txt 2>/dev/null)
        _name=$(echo "$_name" | sed 's/[[:space:]]*$//')
    fi

    [ -z "$_name" ] && _name="$mac_lc"
    printf '%s' "$_name"
}

# Проверка имени по RFC 952/1123.
_nl_validate_name() {
    local name="$1"

    if [ -z "$name" ]; then
        echo "Имя не может быть пустым."
        return 1
    fi

    if [ ${#name} -gt 63 ]; then
        echo "Имя слишком длинное: ${#name} символов. Максимум 63."
        return 1
    fi

    if ! echo "$name" | grep -qE '^[A-Za-z0-9_:-]+$'; then
        echo "Недопустимые символы. 
Разрешены: a-z, A-Z, 0-9, -, _, :"
        return 1
    fi

    case "$name" in
        -*) echo "Имя не может начинаться с дефиса."; return 1 ;;
    esac

    return 0
}

# Проверка IPv4.
_nl_validate_ip() {
    local ip="$1"

    if [ -z "$ip" ]; then
        echo "IP-адрес не может быть пустым."
        return 1
    fi

    if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "Неверный формат. 
Ожидается: xxx.xxx.xxx.xxx"
        return 1
    fi

    local _oct
    for _oct in ${ip//./ }; do
        if [ "$_oct" -gt 255 ]; then
            echo "Октет $_oct больше 255."
            return 1
        fi
    done

    return 0
}

# Проверяет, занят ли IP другим устройством.
_nl_ip_in_use() {
    local ip="$1"
    local exclude_mac="$2"
    local exclude_lc
    exclude_lc=$(echo "$exclude_mac" | tr 'A-Z' 'a-z')

    local found_mac
    found_mac=$(ip neigh show dev "$LAN_IFACE" 2>/dev/null | awk -v ip="$ip" '
        {
            cmac=""; cip=""
            for (i=1; i<=NF; i++) {
                if ($i == "lladdr") cmac=$(i+1)
                else if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cip=$i
            }
            if (cip == ip) { print tolower(cmac); exit }
        }')

    if [ -n "$found_mac" ] && [ "$found_mac" != "$exclude_lc" ]; then
        printf '%s' "$found_mac"
        return 1
    fi

    local uci_owner
    uci_owner=$(uci show dhcp 2>/dev/null | awk -F"'" -v ip="$ip" -v ex="$exclude_lc" '
        /\.ip=/ { gsub(/.*\.ip=.\x27?/, ""); gsub(/\x27.*/, ""); cip=$0 }
        /\.mac=/ { gsub(/.*\.mac=.\x27?/, ""); gsub(/\x27.*/, ""); cmac=tolower($0) }
        /^dhcp\.@host\[[0-9]+\]=host$/ {
            if (cip == ip && cmac != "" && cmac != ex) { print cmac; exit }
        }
    ')

    if [ -n "$uci_owner" ]; then
        printf '%s' "$uci_owner"
        return 1
    fi

    return 0
}

# Сохраняет статическую привязку IP в UCI (dhcp host).
_nl_save_static_ip() {
    local mac="$1"
    local name="$2"
    local ip="$3"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')

    local _err
    _err=$(_nl_validate_name "$name") || { echo "$_err"; return 1; }
    _err=$(_nl_validate_ip "$ip") || { echo "$_err"; return 1; }

    local _owner
    _owner=$(_nl_ip_in_use "$ip" "$mac_lc")
    if [ $? -ne 0 ]; then
        echo "IP $ip уже занят устройством $_owner."
        return 1
    fi

    local _existing_idx=""
    local _sec
    for _sec in $(uci show dhcp 2>/dev/null | grep -oE '@host\[[0-9]+\]' | sort -u); do
        local _m
        _m=$(uci -q get "dhcp.$_sec.mac" 2>/dev/null)
        if [ -n "$_m" ] && [ "$(echo "$_m" | tr 'A-Z' 'a-z')" = "$mac_lc" ]; then
            _existing_idx="$_sec"
            break
        fi
    done

    if [ -n "$_existing_idx" ]; then
        uci set "dhcp.$_existing_idx.name=$name"
        uci set "dhcp.$_existing_idx.ip=$ip"
    else
        uci add dhcp host >/dev/null
        uci set "dhcp.@host[-1].name=$name"
        uci set "dhcp.@host[-1].mac=$mac_lc"
        uci set "dhcp.@host[-1].ip=$ip"
    fi

    uci commit dhcp 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Ошибка записи в UCI."
        return 1
    fi

    local _dn_file="/etc/telegram_bot/data/device_names.txt"
    touch "$_dn_file"
    grep -vi "^${mac_lc} " "$_dn_file" > "${_dn_file}.tmp" 2>/dev/null
    echo "${mac_lc} ${name}" >> "${_dn_file}.tmp"
    mv "${_dn_file}.tmp" "$_dn_file"
    chmod 600 "$_dn_file"

    /etc/init.d/dnsmasq reload 2>/dev/null
    return 0
}

# Удаляет статическую привязку IP для MAC.
_nl_remove_static_ip() {
    local mac="$1"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')

    local _found="-1"
    local _sec
    for _sec in $(uci show dhcp 2>/dev/null | grep -oE '@host\[[0-9]+\]' | sort -u); do
        local _m
        _m=$(uci -q get "dhcp.$_sec.mac" 2>/dev/null)
        if [ -n "$_m" ] && [ "$(echo "$_m" | tr 'A-Z' 'a-z')" = "$mac_lc" ]; then
            _found="$_sec"
            break
        fi
    done

    if [ "$_found" = "-1" ]; then
        return 1
    fi

    uci delete "dhcp.$_found" 2>/dev/null
    uci commit dhcp 2>/dev/null
    /etc/init.d/dnsmasq reload 2>/dev/null
    return 0
}

# БЛОКИРОВКА / РАЗБЛОКИРОВКА MAC
_block_mac() {
    local mac="$1"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')

    if ! echo "$mac_lc" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; then
        echo "$(date): _block_mac: invalid MAC '$mac'" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi

    local RECOVERY_FILE="/etc/telegram_bot/data/.blocked_from_whitelist.txt"
    [ -f "$RECOVERY_FILE" ] || { touch "$RECOVERY_FILE"; chmod 600 "$RECOVERY_FILE"; }

    declare -A _sec_ifname
    declare -A _sec_mf_orig

    local _ubus_json_before=""
    if command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        _ubus_json_before=$(ubus call network.wireless status 2>/dev/null)
    fi

    local sec mode
    for sec in $(uci show wireless 2>/dev/null \
        | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do

        mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
        [ "$mode" = "ap" ] || continue

        local _ifn=""
        if [ -n "$_ubus_json_before" ]; then
            _ifn=$(echo "$_ubus_json_before" | jq -r --arg s "$sec" '
                to_entries[] | .value.interfaces[]?
                | select(.section == $s)
                | .ifname // empty
            ' 2>/dev/null | head -1)
        fi
        _sec_ifname["$sec"]="$_ifn"

        local _mf0
        _mf0=$(uci -q get "wireless.$sec.macfilter" 2>/dev/null)
        _sec_mf_orig["$sec"]="$_mf0"
    done

    local processed=0

    for sec in $(uci show wireless 2>/dev/null \
        | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do

        mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
        [ "$mode" = "ap" ] || continue

        local macfilter
        macfilter=$(uci -q get "wireless.$sec.macfilter" 2>/dev/null)

        local _bm_exists=0
        if grep -qF "|${sec}|bm=1|" "$RECOVERY_FILE" 2>/dev/null; then
            _bm_exists=1
        fi

        case "$macfilter" in
            allow)
                local _list _entry _entry_lc _found=0
                _list=$(uci -q get "wireless.$sec.maclist" 2>/dev/null)
                for _entry in $_list; do
                    _entry_lc=$(echo "$_entry" | tr 'A-Z' 'a-z')
                    if [ "$_entry_lc" = "$mac_lc" ]; then
                        uci del_list "wireless.$sec.maclist=$_entry" 2>/dev/null
                        _found=1
                    fi
                done
                if [ "$_found" = "1" ]; then
                    if ! grep -qF "${mac_lc}|${sec}|" "$RECOVERY_FILE" 2>/dev/null; then
                        echo "${mac_lc}|${sec}|bm=0|os=allow|sm=" >> "$RECOVERY_FILE"
                    fi
                    processed=$((processed + 1))
                fi
                ;;

            deny)
                local _list _entry _entry_lc _found_lc=0
                _list=$(uci -q get "wireless.$sec.maclist" 2>/dev/null)
                for _entry in $_list; do
                    _entry_lc=$(echo "$_entry" | tr 'A-Z' 'a-z')
                    if [ "$_entry_lc" = "$mac_lc" ]; then
                        _found_lc=1
                        break
                    fi
                done
                if [ "$_found_lc" = "0" ]; then
                    uci add_list "wireless.$sec.maclist=$mac_lc"
                    if ! grep -qF "${mac_lc}|${sec}|" "$RECOVERY_FILE" 2>/dev/null; then
                        if [ "$_bm_exists" = "1" ]; then
                            echo "${mac_lc}|${sec}|bm=1|os=absent|sm=" >> "$RECOVERY_FILE"
                        else
                            echo "${mac_lc}|${sec}|bm=0|os=deny|sm=" >> "$RECOVERY_FILE"
                        fi
                    fi
                    processed=$((processed + 1))
                fi
                ;;

            *)
                local _stale_maclist _sm_save=""
                _stale_maclist=$(uci -q get "wireless.$sec.maclist" 2>/dev/null)
                if [ -n "$_stale_maclist" ]; then
                    _sm_save=$(echo "$_stale_maclist" | tr ' ' ',')
                fi

                uci set "wireless.$sec.macfilter=deny"
                uci -q delete "wireless.$sec.maclist"
                uci add_list "wireless.$sec.maclist=$mac_lc"

                if ! grep -qF "${mac_lc}|${sec}|" "$RECOVERY_FILE" 2>/dev/null; then
                    echo "${mac_lc}|${sec}|bm=1|os=absent|sm=${_sm_save}" >> "$RECOVERY_FILE"
                fi

                processed=$((processed + 1))
                ;;
        esac
    done

    uci commit wireless 2>/dev/null

    if [ "$processed" -eq 0 ]; then
        echo "$(date): _block_mac: $mac_lc — нечего делать (нет AP-секций с macfilter)" >> /tmp/telegram_bot/logs/bot.log
        return 2
    fi

    local _ifc2 _mf0
    for sec in "${!_sec_ifname[@]}"; do
        _ifc2="${_sec_ifname[$sec]}"
        [ -z "$_ifc2" ] && continue

        ip link show "$_ifc2" >/dev/null 2>&1 || continue
        iw dev "$_ifc2" info 2>/dev/null | grep -q "type AP" || continue

        _mf0="${_sec_mf_orig[$sec]}"

        case "$_mf0" in
            allow)
                hostapd_cli -i "$_ifc2" accept_acl DEL_MAC "$mac_lc" >/dev/null 2>&1
                hostapd_cli -i "$_ifc2" deauthenticate "$mac_lc" >/dev/null 2>&1
                echo "$(date): _block_mac: $_ifc2 (allow→удалён из whitelist)" >> /tmp/telegram_bot/logs/bot.log
                ;;
            *)
                hostapd_cli -i "$_ifc2" set macaddr_acl 0 >/dev/null 2>&1
                hostapd_cli -i "$_ifc2" deny_acl ADD_MAC "$mac_lc" >/dev/null 2>&1
                hostapd_cli -i "$_ifc2" deauthenticate "$mac_lc" >/dev/null 2>&1
                echo "$(date): _block_mac: $_ifc2 (blacklist+ADD_MAC)" >> /tmp/telegram_bot/logs/bot.log
                ;;
        esac
    done

    local _fw_rules
    _fw_rules=$(uci show firewall 2>/dev/null | grep "\.name='Block-MAC-${mac_lc}'" | cut -d'.' -f2 | cut -d'=' -f1)
    for _fw_rule in $_fw_rules; do uci delete "firewall.$_fw_rule" 2>/dev/null; done

    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name="Block-MAC-${mac_lc}"
    uci set firewall.@rule[-1].src="lan"
    uci set firewall.@rule[-1].dest="wan"
    uci set firewall.@rule[-1].src_mac="$mac_lc"
    uci set firewall.@rule[-1].proto="all"
    uci set firewall.@rule[-1].target="DROP"
    uci set firewall.@rule[-1].enabled="1"
    uci commit firewall
    
    /etc/init.d/firewall restart 2>/dev/null
    echo "$(date): _block_mac: $mac_lc LAN заблокирован через Firewall" >> /tmp/telegram_bot/logs/bot.log

    echo "$(date): _block_mac: $mac_lc OK (processed=$processed, no reload)" >> /tmp/telegram_bot/logs/bot.log
    return 0
}

# Снимает блокировку.
_unblock_mac() {
    local mac="$1"
    local mac_lc
    mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')

    if ! echo "$mac_lc" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; then
        echo "$(date): _unblock_mac: invalid MAC '$mac'" >> /tmp/telegram_bot/logs/bot.log
        return 1
    fi

    local RECOVERY_FILE="/etc/telegram_bot/data/.blocked_from_whitelist.txt"

    local _rec_lines=""
    [ -f "$RECOVERY_FILE" ] && _rec_lines=$(grep -F "${mac_lc}|" "$RECOVERY_FILE" 2>/dev/null)

    if [ -n "$_rec_lines" ]; then
        local _line _rsec _bm _os _sm
        while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            _rsec=$(echo "$_line" | cut -d'|' -f2)
            _bm=$(  echo "$_line" | cut -d'|' -f3 | sed 's/^bm=//')
            _os=$(  echo "$_line" | cut -d'|' -f4 | sed 's/^os=//')
            _sm=$(  echo "$_line" | cut -d'|' -f5 | sed 's/^sm=//')
            [ -z "$_rsec" ] && continue

            local _list _entry _entry_lc
            _list=$(uci -q get "wireless.$_rsec.maclist" 2>/dev/null)
            for _entry in $_list; do
                _entry_lc=$(echo "$_entry" | tr 'A-Z' 'a-z')
                if [ "$_entry_lc" = "$mac_lc" ]; then
                    uci del_list "wireless.$_rsec.maclist=$_entry" 2>/dev/null
                fi
            done

            if [ "$_os" = "absent" ] && [ "$_bm" = "1" ]; then
                local _remaining
                _remaining=$(uci -q get "wireless.$_rsec.maclist" 2>/dev/null)

                if [ -z "$_remaining" ]; then
                    if [ -n "$_sm" ]; then
                        local _restored _m
                        _restored=$(echo "$_sm" | tr ',' ' ')
                        uci -q delete "wireless.$_rsec.maclist"
                        for _m in $_restored; do
                            uci add_list "wireless.$_rsec.maclist=$_m"
                        done
                        echo "$(date): _unblock_mac: $_rsec → restore stale maclist" >> /tmp/telegram_bot/logs/bot.log
                    else
                        uci -q delete "wireless.$_rsec.maclist"
                    fi
                    uci -q delete "wireless.$_rsec.macfilter"
                    echo "$(date): _unblock_mac: $_rsec → macfilter удалён" >> /tmp/telegram_bot/logs/bot.log
                else
                    echo "$(date): _unblock_mac: $_rsec → deny остаётся (есть другие MAC)" >> /tmp/telegram_bot/logs/bot.log
                fi

            elif [ "$_os" = "allow" ]; then
                local _cur_mf
                _cur_mf=$(uci -q get "wireless.$_rsec.macfilter" 2>/dev/null)
                if [ "$_cur_mf" = "allow" ]; then
                    uci add_list "wireless.$_rsec.maclist=$mac_lc"
                    echo "$(date): _unblock_mac: $_rsec → whitelist восстановлен" >> /tmp/telegram_bot/logs/bot.log
                fi

            elif [ "$_os" = "deny" ]; then
                echo "$(date): _unblock_mac: $_rsec → deny (наш MAC удалён)" >> /tmp/telegram_bot/logs/bot.log
            fi
        done <<< "$_rec_lines"

        grep -vF "${mac_lc}|" "$RECOVERY_FILE" > "${RECOVERY_FILE}.tmp" 2>/dev/null
        [ -f "${RECOVERY_FILE}.tmp" ] && mv "${RECOVERY_FILE}.tmp" "$RECOVERY_FILE"

    else
        local sec
        for sec in $(uci show wireless 2>/dev/null \
            | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
            local mode
            mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
            [ "$mode" = "ap" ] || continue
            local _list _entry _entry_lc
            _list=$(uci -q get "wireless.$sec.maclist" 2>/dev/null)
            for _entry in $_list; do
                _entry_lc=$(echo "$_entry" | tr 'A-Z' 'a-z')
                if [ "$_entry_lc" = "$mac_lc" ]; then
                    uci del_list "wireless.$sec.maclist=$_entry" 2>/dev/null
                    echo "$(date): _unblock_mac: $sec → удалён LuCI-блок $mac_lc" >> /tmp/telegram_bot/logs/bot.log
                fi
            done
        done
    fi

    uci commit wireless 2>/dev/null
	
    local _fw_rules
    _fw_rules=$(uci show firewall 2>/dev/null | grep "\.name='Block-MAC-${mac_lc}'" | cut -d'.' -f2 | cut -d'=' -f1)
    if [ -n "$_fw_rules" ]; then
        for _fw_rule in $_fw_rules; do
            uci delete "firewall.$_fw_rule" 2>/dev/null
        done
        uci commit firewall
        /etc/init.d/firewall restart 2>/dev/null
        echo "$(date): _unblock_mac: $mac_lc LAN-правило Firewall удалено" >> /tmp/telegram_bot/logs/bot.log
    fi

    local _ap_ifaces=""
    local _ifc _info
    for _ifc in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        _info=$(iw dev "$_ifc" info 2>/dev/null)
        echo "$_info" | grep -q "type AP" && _ap_ifaces="$_ap_ifaces $_ifc"
    done
    _ap_ifaces="${_ap_ifaces# }"

    local _ifc2
    for _ifc2 in $_ap_ifaces; do
        hostapd_cli -i "$_ifc2" deny_acl DEL_MAC "$mac_lc" >/dev/null 2>&1
        hostapd_cli -i "$_ifc2" accept_acl DEL_MAC "$mac_lc" >/dev/null 2>&1

        if hostapd_cli -i "$_ifc2" deny_acl SHOW 2>/dev/null \
            | tr 'A-Z' 'a-z' | grep -q -F "$mac_lc"; then
            echo "$(date): _unblock_mac: $_ifc2 MAC всё ещё в deny, reconfigure" >> /tmp/telegram_bot/logs/bot.log
            hostapd_cli -i "$_ifc2" reconfigure >/dev/null 2>&1
        fi
    done

    echo "$(date): _unblock_mac: $mac_lc OK (no reload)" >> /tmp/telegram_bot/logs/bot.log
    return 0
}

# KB округляем до целого, MB/GB с одним знаком.
format_speed() {
    local speed="$1"

    case "$speed" in
        ''|*[!0-9]*) speed=0 ;;
    esac

    if [ "$speed" -eq 0 ]; then
        printf "0 KB/s"
        return
    fi

    if [ "$speed" -ge 1073741824 ]; then
        local whole=$((speed / 1073741824))
        local frac=$(( (speed % 1073741824) * 10 / 1073741824 ))
        if [ "$frac" -eq 0 ]; then
            printf "%s GB/s" "$whole"
        else
            printf "%s.%s GB/s" "$whole" "$frac"
        fi
    elif [ "$speed" -ge 1048576 ]; then
        local whole=$((speed / 1048576))
        local frac=$(( (speed % 1048576) * 10 / 1048576 ))
        if [ "$frac" -eq 0 ]; then
            printf "%s MB/s" "$whole"
        else
            printf "%s.%s MB/s" "$whole" "$frac"
        fi
    else
        local kb=$(( (speed + 512) / 1024 ))
        printf "%s KB/s" "$kb"
    fi
}

get_cpu_temp() {
    _sys_cpu_temp
}

get_wifi_temp() {
    _sys_wifi_temp "${1:-phy0}"
}

# Имя устройства.
get_device_name() {
    local mac="$1"
    local name=""
    if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
        name=$(awk -v m="$mac" 'tolower($1) == tolower(m) {print $2,$3,$4,$5; exit}' "/etc/telegram_bot/data/device_names.txt" 2>/dev/null)
        if [ -n "$name" ]; then
            echo "$name" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
            return
        fi
    fi
    name=$(awk -v m="$mac" 'tolower($2) == tolower(m) {print $4; exit}' "$DHCP_LEASES" 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "*" ]; then
        echo "$name" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
        return
    fi
    echo "$mac" | tr -d '\n\r'
}

# IP по MAC из ARP.
get_ip_for_mac() {
    local mac="$1"
    local mac_lc="${mac,,}"
    ip neigh show dev "$LAN_IFACE" 2>/dev/null \
        | while IFS= read -r _gip_line; do
              _gip_ip="${_gip_line%% *}"
              _gip_mac=$(printf '%s' "$_gip_line" | sed -n 's/.*lladdr \([^ ]*\).*/\1/p')
              [ -z "$_gip_mac" ] && continue
              _gip_mac="${_gip_mac,,}"
              if [ "$_gip_mac" = "$mac_lc" ]; then
                  echo "$_gip_ip"
                  break
              fi
          done
}

# ============================================================
# WI-FI — ТАБЛИЦА ОНЛАЙН УСТРОЙСТВ
# ============================================================

get_wifi_info() {
    local iface="$1"
    local title="$2"
    local speed_file="$3"
    local page_start="${4:-1}"
    local page_end="${5:-999999}"

    if ! command -v iw >/dev/null 2>&1; then
        echo "📡 ${title} (${iface})"
        echo "$SEP46"
        echo "   ❌ Утилита iw не найдена. Установите: opkg install iw (или apk add iw)"
        return
    fi

    declare -A name_cache
    declare -A ip_cache
    declare -A speed_cache    

    if [ -f "$DHCP_LEASES" ]; then
        while read -r _ts _mac _ip _hostname _rest; do
            [ -z "$_mac" ] && continue
            _mac="${_mac,,}"
            if [ -n "$_hostname" ] && [ "$_hostname" != "*" ] && [ "${_hostname:0:3}" != "01:" ]; then
                name_cache["$_mac"]="$_hostname"
            fi
            if [ -n "$_ip" ] && [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ip_cache["$_mac"]="$_ip"
            fi
        done < "$DHCP_LEASES"
    fi
    if [ -f "/etc/telegram_bot/data/device_names.txt" ]; then
        while read -r _mac _name; do
            [ -z "$_mac" ] && continue
            [ -z "$_name" ] && continue
            _mac="${_mac,,}"
            name_cache["$_mac"]="$_name"
        done < "/etc/telegram_bot/data/device_names.txt"
    fi

    if [ -n "$LAN_IFACE" ]; then
        while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            _ip="${_line%% *}"
            _mac=$(printf '%s' "$_line" | sed -n 's/.*lladdr \([^ ]*\).*/\1/p')
            [ -z "$_mac" ] && continue
            _mac="${_mac,,}"
            if [ -n "$_ip" ] && [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                if [ -z "${ip_cache[$_mac]}" ]; then
                    ip_cache["$_mac"]="$_ip"
                fi
            fi
        done < <(ip neigh show dev "$LAN_IFACE" 2>/dev/null)
    fi

    if [ -f "$speed_file" ]; then
        while IFS='|' read -r _m _rx _tx; do
            [ -z "$_m" ] && continue
            _m="${_m,,}"
            speed_cache["$_m"]="${_rx}|${_tx}"
        done < "$speed_file"
    fi

    local dump=$(iw dev "$iface" station dump 2>/dev/null)
    local dump_parsed=""
    if [ -n "$dump" ]; then
        dump_parsed=$(echo "$dump" | awk '
            /^Station / {
                mac = tolower($2)
                signal[mac] = "N/A"
            }
            /^[[:space:]]*signal:/ {
                if (mac != "") {
                    signal[mac] = $2
                }
            }
            END {
                for (m in signal) print m "|" signal[m]
            }
        ')
    fi

    local data=""
    local i=$(cat "$_ONLINE_COUNTER_FILE" 2>/dev/null)
    [ -z "$i" ] && i=1

    local _has_any=0
    [ -n "$dump_parsed" ] && _has_any=1

    if [ "$_has_any" = "1" ]; then
        while IFS='|' read -r mac signal; do
            [ -z "$mac" ] && continue
            if _is_mac_blocked "$mac"; then continue; fi
            name_device="${name_cache[$mac]}"
            [ -z "$name_device" ] && name_device="$mac"

            [ -z "$signal" ] && signal="N/A"

            if _is_mac_blocked "$mac"; then
                signal="🚫"
            fi

            rx_speed=0; tx_speed=0
            if [ -n "${speed_cache[$mac]}" ]; then
                rx_speed="${speed_cache[$mac]%%|*}"
                tx_speed="${speed_cache[$mac]#*|}"
            fi
            rx_fmt=$(format_speed "$rx_speed")
            tx_fmt=$(format_speed "$tx_speed")

            ip="${ip_cache[$mac]}"
            [ -z "$ip" ] && ip="N/A"

            name_device=$(html_escape "$name_device")
            if [ "$i" -ge "$page_start" ] && [ "$i" -le "$page_end" ]; then
                data="${data}${i}|${name_device}|${signal}|${rx_fmt}|${tx_fmt}|${ip}|${mac}\n"
            fi
            echo "${i}|${mac}" >> "$_ONLINE_DEVICES_FILE"
            i=$((i+1))
        done <<< "$dump_parsed"
    fi

    echo "$i" > "$_ONLINE_COUNTER_FILE"

    if [ -z "$data" ]; then
        if [ "$_has_any" = "0" ]; then
            echo "📡 ${title} (${iface})"
            echo "$SEP46"
            echo "   📡 Нет подключённых устройств"
        fi
        return
    fi

    local table=$(printf "%b" "$data" | awk -F'|' '
    BEGIN {
        printf "%-2s %-22s %-3s %10s %10s\n", "№", "Имя", "dBm", "↓ Download", "↑ Upload"
        printf "%-2s %-22s %-3s %10s %11s\n", "--", "---------------------", "---", "----------", "-----------"
    }
    {
        name = $2
        gsub(/[\x00-\x1F\x7F]/, "", name)
        name = substr(name, 1, 22)
        ip = $6
        gsub(/[^[:print:]]/, "", ip)
        mac = $7
        gsub(/[^[:print:]]/, "", mac)
        
        printf "%-2s %-22s\n", $1, name
		printf "   %s %-18s  %-3s %10s %10s\n", "🔗", mac, $3, $4, $5
        printf "   %s %s\n", "🌐", ip
        
    }')
    echo "📡 ${title} (${iface})"
    echo "$SEP46"
    echo "${table}"
}

# ============================================================
# LAN — ПРОВОДНЫЕ УСТРОЙСТВА
# ============================================================

get_lan_devices() {
    local iface="$LAN_IFACE"
    local speed_file="$1"
    local wifi_macs="$2"
    local page_start="${3:-1}"
    local page_end="${4:-999999}"
    local data=""
    local i=$(cat "$_ONLINE_COUNTER_FILE" 2>/dev/null)
    [ -z "$i" ] && i=1
    local tmp_file="/tmp/telegram_bot/traffic/lan_data_$$"
    local _has_any=0
    rm -f "$tmp_file"

    local wifi_macs_clean=$(echo "$wifi_macs" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' '\n')

    local lan_port_map=""
    if [ -d "/sys/class/net/$iface/brif" ]; then
        for p_path in "/sys/class/net/$iface/brif/"*; do
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

    if command -v brctl >/dev/null 2>&1 && brctl showmacs "$iface" 2>/dev/null | grep -q "^[[:space:]]*[0-9]"; then
        # brctl (swconfig)
        local brctl_output=$(brctl showmacs "$iface" 2>/dev/null)
        if [ -n "$brctl_output" ]; then
            echo "$brctl_output" | while read -r line; do
                [ -z "$line" ] && continue
                set -- $line
                port_no=$1
                mac_addr=$2
                is_local=$3

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
                    mac_addr=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
                    echo "$mac_addr|$matched_port"
                fi
            done > "$tmp_file"
        fi
    elif command -v bridge >/dev/null 2>&1; then
        # bridge fdb show (DSA)
        bridge fdb show br "$iface" 2>/dev/null \
            | grep "master $iface" \
            | grep -v "self" \
            | grep -v "permanent" \
            | while read -r _mac _dev _ifname _rest; do
                [ -z "$_mac" ] || [ -z "$_ifname" ] && continue
                case "$_ifname" in
                    phy*|wlan*|ath*|ra*|ap*|mon*|wl*) continue ;;
                esac
                [ "$_ifname" = "$iface" ] && continue

                _mac=$(echo "$_mac" | tr '[:upper:]' '[:lower:]')
                echo "${_mac}|${_ifname}"
            done | sort -u > "$tmp_file"
    fi

    if [ -s "$tmp_file" ]; then
        _has_any=1
        while IFS='|' read -r mac port; do
            [ -z "$mac" ] && continue

            if echo "$wifi_macs_clean" | grep -q -x "$mac"; then
                continue
            fi

            if _is_mac_blocked "$mac"; then
                continue
            fi

            # IP строго IPv4.
            ip=$(ip -4 neigh show dev "$iface" 2>/dev/null \
                | while IFS= read -r _lan_line; do
                      _lan_ip="${_lan_line%% *}"
                      _lan_mac=$(printf '%s' "$_lan_line" | sed -n 's/.*lladdr \([^ ]*\).*/\1/p')
                      [ -z "$_lan_mac" ] && continue
                      _lan_mac="${_lan_mac,,}"
                      if [ "$_lan_mac" = "$mac" ]; then
                          echo "$_lan_ip"
                          break
                      fi
                  done)
            if [ -z "$ip" ]; then
                ip=$(awk -v m="$mac" 'tolower($2) == tolower(m) {print $3; exit}' "$DHCP_LEASES" 2>/dev/null)
            fi

            case "$ip" in
                *:*|"") ip="N/A" ;;
            esac

            name_device=$(get_device_name "$mac")

            local rx_speed="0"
            local tx_speed="0"
            if [ -f "$speed_file" ]; then
                line2=$(awk -F'|' -v m="$mac" 'tolower($1) == tolower(m) {print; exit}' "$speed_file" 2>/dev/null)
                if [ -n "$line2" ]; then
                    rx_speed=$(echo "$line2" | cut -d'|' -f2)
                    tx_speed=$(echo "$line2" | cut -d'|' -f3)
                fi
            fi
            rx_fmt=$(format_speed "$rx_speed")
            tx_fmt=$(format_speed "$tx_speed")
            [ -z "$ip" ] && ip="N/A"

            local _port_num="${port#lan}"
            [ -z "$_port_num" ] && _port_num="$port"
            local _col=3
            if [ ${#_port_num} -lt $_col ]; then
                local _left=$(( ($_col - ${#_port_num}) / 2 ))
                local _right=$(( $_col - ${#_port_num} - _left ))
                _port_num=$(printf "%*s%s%*s" "$_left" "" "$_port_num" "$_right" "")
            fi

            if [ "$i" -ge "$page_start" ] && [ "$i" -le "$page_end" ]; then
                data="${data}${i}|${name_device}|${_port_num}|${rx_fmt}|${tx_fmt}|${ip}|${mac}\n"
            fi
            echo "${i}|${mac}" >> "$_ONLINE_DEVICES_FILE"
            i=$((i+1))
        done < "$tmp_file"
    fi
    rm -f "$tmp_file"

    if [ -z "$data" ]; then
        echo "$i" > "$_ONLINE_COUNTER_FILE"
        if [ "$_has_any" = "0" ] || [ "$page_start" -eq 1 ]; then
            echo "🔌 LAN (${iface})"
            echo "$SEP46"
            echo "   🔌 Нет проводных устройств"
        fi
        return
    fi

    local table=$(printf "%b" "$data" | awk -F'|' '
    BEGIN {
        printf "%-2s %-22s %3s %10s %10s\n", "№", "Имя", "Lan", "↓ Download", "↑ Upload"
        printf "%-2s %-22s %3s %10s %11s\n", "--", "---------------------", "---", "----------", "-----------"
    }
    {
        name = $2
        gsub(/[\x00-\x1F\x7F]/, "", name)
        name = substr(name, 1, 22)
        ip = $6
        gsub(/[^[:print:]]/, "", ip)
        mac = $7
        gsub(/[^[:print:]]/, "", mac)
        
        printf "%-2s %-21s\n", $1, name
        printf "   %s %-18s  %3s %10s %10s\n", "🔗", mac, $3, $4, $5
		printf "   %s %s\n", "🌐", ip
    }')

    echo "$i" > "$_ONLINE_COUNTER_FILE"

    echo "🔌 LAN (${iface})"
    echo "$SEP46"
    echo "${table}"
}

# ============================================================
# ТРАФИК
# ============================================================

bytes_to_human() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f GB", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f MB", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f KB", b/1024}'
    else
        echo "$bytes B"
    fi
}

get_traffic_body() {
    local start_ms="$1"
    local end_ms="$2"

    if ! command -v jq >/dev/null 2>&1; then
        echo "⚠️ <i>Ошибка:</i> jq не установлен."
        echo "📦 Установите: <code>apk add jq</code>"
        return 1
    fi

    local wan_iface
    wan_iface=$(uci -q get network.wan.device 2>/dev/null)
    [ -z "$wan_iface" ] && wan_iface=$(uci -q get network.wan.ifname 2>/dev/null)
    [ -z "$wan_iface" ] && wan_iface="wan"

    if ! ubus list luci.bandix 2>/dev/null | grep -q "^luci.bandix$"; then
        echo "⚠️ <i>Пакет luci-bandix не установлен.</i>"
        echo "📦 Скачайте и установите:"
        echo "   <a href=\"https://github.com/timsaya/openwrt-bandix/releases\">openwrt-bandix</a>"
        echo "   <a href=\"https://github.com/timsaya/luci-app-bandix/releases\">luci-app-bandix</a>"
        echo "💡 После установки перезапустите бота: /restart"
        return 1
    fi

    local response
    response=$(ubus call luci.bandix getTrafficUsageRanking "{\"start_ms\":$start_ms,\"end_ms\":$end_ms,\"network_type\":\"$wan_iface\"}" 2>/dev/null)

    if [ -z "$response" ]; then
        echo "⏳ <i>Нет ответа от Bandix.</i>"
        echo "💡 Возможно, служба не запущена."
        return 1
    fi

    local data
    data=$(echo "$response" | jq -r '. as $root | $root.r[] | "\(.mac)|\(.host)|\(.t_b)|\(.pct)"')
    if [ -z "$data" ]; then
        echo "📭 <i>Нет данных за период.</i>"
        echo "💡 Возможно, Bandix ещё не накопил статистику."
        return 1
    fi

    local table_data=""
    local rank=1
    echo "$data" | while IFS='|' read -r mac host tb pct; do
        [ -z "$mac" ] && continue
        [ "$tb" -eq 0 ] 2>/dev/null && continue

        if [ -n "$host" ]; then
            local name=$(echo "$host" | sed 's/\.lan$//')
        else
            local name=$(get_device_name "$mac")
        fi
        name=$(printf "%-23.23s" "$name")
        name=$(html_escape "$name")

        local tb_hr=$(bytes_to_human "$tb")
        tb_hr=$(printf "%9s" "$tb_hr")

        local pct_int
        pct_int=$(awk -v p="$pct" 'BEGIN{printf "%d", p}' 2>/dev/null)
        case "$pct_int" in ''|*[!0-9-]*) pct_int=0 ;; esac
        [ "$pct_int" -lt 0 ] && pct_int=0
        [ "$pct_int" -gt 99 ] && pct_int=99

        local bar=""
        local filled=$((pct_int / 10))
        [ $filled -gt 10 ] && filled=10
        local empty=$((10 - filled))
        for i in $(seq 1 $filled); do bar="${bar}●"; done
        for i in $(seq 1 $empty); do bar="${bar}○"; done

        pct_fixed=$(printf "%2d" "$pct_int")
        local progress="$(printf "%-10s %s" "$bar" "$pct_fixed")"

        printf "%s|%s|%s|%s\n" "$rank" "$name" "$tb_hr" "$progress"
        rank=$((rank+1))
    done > /tmp/telegram_bot/traffic/table_$$

    table_data=$(cat /tmp/telegram_bot/traffic/table_$$ 2>/dev/null)
    rm -f /tmp/telegram_bot/traffic/table_$$

    if [ -z "$table_data" ]; then
        echo "📭 <i>Нет данных о трафике за указанный период.</i>"
        return 1
    fi

    printf "%s" "$table_data" | awk -F'|' '
    BEGIN {
        printf "%-2s %-23s %-9s  %13s\n", "№", "Устройство", "Трафик", "Активность  %"
        printf "%-2s %-23s %-9s  %13s\n", "--", "-----------------------", "---------",  "--------------"
    }
    {
        printf "%-2s %-23s %-9s  %13s\n", $1, $2, $3, $4
    }'
    return 0
}

# ============================================================
# ЖУРНАЛ СОБЫТИЙ — СОСТОЯНИЕ И ОБРАБОТКА
# ============================================================

CRITICAL_STATE_DIR="/tmp/telegram_bot/critical/state"
mkdir -p "$CRITICAL_STATE_DIR" 2>/dev/null

_critical_save_state() {
    local state_file="$1"
    local page="$2"
    local page_size="$3"
    local msg_id="$4"
    local filter_value="$5"
    shift 5

    local tmp_file="${state_file}.tmp.$$"

    {
        echo "$page"
        echo "$page_size"
        echo "$msg_id"
        echo "$filter_value"
        if [ "$#" -gt 0 ]; then
            printf "%s\n" "$@"
        fi
    } > "$tmp_file"

    if [ ! -s "$tmp_file" ]; then
        echo "DEBUG: _critical_save_state: tmp_file пустой, отмена" >> /tmp/telegram_bot/logs/bot.log
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$state_file"
    return 0
}

_critical_load_state() {
    local state_file="$1"
    if [ ! -f "$state_file" ]; then
        return 1
    fi
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < "$state_file"
    CRIT_PAGE="${lines[0]}"
    CRIT_PAGE_SIZE="${lines[1]:-14}"
    CRIT_MSG_ID="${lines[2]}"
    CRIT_FILTER_VALUE="${lines[3]:-none}"
    CRIT_FULL_LIST=()
    for ((i=4; i<${#lines[@]}; i++)); do
        CRIT_FULL_LIST+=("${lines[i]}")
    done
    return 0
}

_critical_count_categories() {
    local -n input_lines="$1"
    printf "%s\n" "${input_lines[@]}" | awk "$AWK_CLASSIFY"'
    BEGIN { c["crit"]=0; c["err"]=0; c["warn"]=0; c["net"]=0; c["wifi"]=0; c["system"]=0 }
    NF {
        cat = classify_category($0)
        if (cat != "none") c[cat]++
    }
    END {
        printf "crit:%d err:%d warn:%d net:%d wifi:%d system:%d\n",
            c["crit"], c["err"], c["warn"], c["net"], c["wifi"], c["system"]
    }'
}

_critical_process_and_format() {
    local filter_value="$1"
    local page="$2"
    local page_size="${CRIT_PAGE_SIZE:-14}"
    local sep="$SEP46"

    printf "%s\n" "${CRIT_FULL_LIST[@]}" | awk \
        -v filter="$filter_value" -v page="$page" -v psize="$page_size" -v sep="$SEP46" \
        "$AWK_CLASSIFY"'
    BEGIN {
        regex_net  = "netifd|pppd|pppoe|ppp|dhcp|dnsmasq|odhcpd"
        regex_wifi = "hostapd|wifi|ath|mt76|iwlwifi|wlan"
        regex_sys  = "kernel|dmesg|flash|storage|opkg|apk"

        m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04";
        m["May"]="05"; m["Jun"]="06"; m["Jul"]="07"; m["Aug"]="08";
        m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";

        filter_suffix = ""
        if (filter == "critical")      filter_suffix = "  (🚨 Критические)"
        else if (filter == "error")    filter_suffix = "  (❌ Ошибки)"
        else if (filter == "warn")     filter_suffix = "  (⚠️ Предупрежд.)"
        else if (filter == "net")      filter_suffix = "  (🌐 Сеть / IP)"
        else if (filter == "wifi")     filter_suffix = "  (📡 Wi-Fi)"
        else if (filter == "system")   filter_suffix = "  (🖥️ Система)"

        count = 0
    }
    {
        line = $0
        cat = classify_category(line)

        matched = 0
        if (filter == "none") {
            matched = 1
        } else if (filter == "critical") {
            if (cat == "crit") matched = 1
        } else if (filter == "error") {
            if (cat == "err") matched = 1
        } else if (filter == "warn") {
            if (cat == "warn") matched = 1
        } else if (filter == "net") {
            if (cat == "net") matched = 1
        } else if (filter == "wifi") {
            if (cat == "wifi") matched = 1
        } else if (filter == "system") {
            if (cat == "system") matched = 1
        }

        if (matched) {
            filtered[count] = line
            count++
        }
    }
    END {
        for (i = 0; i < int(count/2); i++) {
            j = count - 1 - i
            tmp = filtered[i]
            filtered[i] = filtered[j]
            filtered[j] = tmp
        }

        start = (page - 1) * psize
        end = start + psize
        if (end > count) end = count
        if (start >= count) {
            printf "<pre>📋 Журнал событий%s\n\n", filter_suffix
            printf "%s\n", sep
            printf "%-3s %-5s %-8s %s %s\n", " №", "Дата", "Время", "🆔", "Текст ошибки"
            printf "%-3s %-5s %-8s %s %s\n\n", "---", "-----", "--------", "--", "------------------------------"
            printf "⚠️ Нет записей на этой странице.\n\n"
            printf "%s\n\n", sep
            printf "🕒 Обновлено: %s\n", "###TIME###"
            printf "</pre>"
            printf "||%d", count
            exit 0
        }

        printf "<pre>📋 Журнал событий%s\n\n", filter_suffix
        printf "%s\n", sep
        printf "%-3s %-5s %-8s %s %s\n", " №", "Дата", "Время", "🆔", "Текст ошибки"
        printf "%-3s %-5s %-8s %s %s\n", "---", "-----", "--------", "--", "------------------------------"

        for (i = start; i < end; i++) {
            line = filtered[i]
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
                else if (g_body_low ~ regex_sys) icon = "🖥️"
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
                        # Не нашли — рубим жёстко по limit.
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

            if (i < end - 1) printf "\n"
        }

        printf "%s\n", sep
        printf "🕒 Обновлено: %s\n", "###TIME###"
        printf "</pre>"
        printf "||%d", count
    }' 2>/dev/null
}

_critical_get_log_stats() {
    local filter="$1"
    local hist_file="/tmp/telegram_bot/critical/history.log"
    [ -f "$hist_file" ] || return 1

    local mtime=$(stat -c %Y "$hist_file" 2>/dev/null || echo 0)
    local cache_dir="/tmp/telegram_bot/critical"
    local cache_file="${cache_dir}/stats_${filter}_${mtime}.txt"

    if [ -f "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi

    local awk_parse='
    function get_ts(line,    p, mon, m, day, time, yr, t) {
        if (match(line, /^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})/)) {
            return substr(line, RSTART, 4) substr(line, RSTART+5, 2) substr(line, RSTART+8, 2) substr(line, RSTART+11, 2) substr(line, RSTART+14, 2) substr(line, RSTART+17, 2)
        }
        split(line, p, " ")
        if (p[1] ~ /^[A-Za-z]{3}$/ && p[2] ~ /^[A-Za-z]{3}$/ && p[3] ~ /^[0-9]+$/ && p[4] ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ && p[5] ~ /^[0-9]{4}$/) {
            mon=p[2]; day=p[3]; time=p[4]; yr=p[5]
        } else if (p[1] ~ /^[A-Za-z]{3}$/ && p[2] ~ /^[0-9]+$/ && p[3] ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
            mon=p[1]; day=p[2]; time=p[3]; yr=strftime("%Y")
        } else return ""
        if (mon=="Jan") m="01"; else if (mon=="Feb") m="02"; else if (mon=="Mar") m="03"; else if (mon=="Apr") m="04"; else if (mon=="May") m="05"; else if (mon=="Jun") m="06"; else if (mon=="Jul") m="07"; else if (mon=="Aug") m="08"; else if (mon=="Sep") m="09"; else if (mon=="Oct") m="10"; else if (mon=="Nov") m="11"; else if (mon=="Dec") m="12"
        split(time, t, ":")
        return sprintf("%s%s%02d%s%s%s", yr, m, day, t[1], t[2], t[3])
    }'

    local res=""
    if [ "$filter" = "none" ]; then
        local first_line=$(head -n 1 "$hist_file")
        local last_line=$(tail -n 1 "$hist_file")
        local first_ts=$(echo "$first_line" | awk "$awk_parse"'{ print get_ts($0) }')
        local last_ts=$(echo "$last_line" | awk "$awk_parse"'{ print get_ts($0) }')
        res="${first_ts}|${last_ts}"
    else
        local grep_pattern=""
        case "$filter" in
            critical) grep_pattern="panic|oom|emerg|fatal|crit|\.crit|\.emerg|\.alert" ;;
            error)    grep_pattern="err|error|\.err" ;;
            warn)     grep_pattern="warn|warning|\.warn" ;;
            net)      grep_pattern="netifd|pppd|pppoe|ppp|dhcp|dnsmasq|odhcpd" ;;
            wifi)     grep_pattern="hostapd|wifi|ath|mt76|iwlwifi|wlan" ;;
            system)   grep_pattern="kernel|dmesg|flash|storage|opkg|apk" ;;
        esac
        res=$(grep -iE "$grep_pattern" "$hist_file" | awk "$awk_parse"'
            BEGIN { first=""; last="" }
            {
                ts = get_ts($0)
                if (ts != "") {
                    if (first == "") first = ts
                    last = ts
                }
            }
            END { if (first != "") print first "|" last }
        ')
    fi

    rm -f "${cache_dir}"/stats_*_*.txt 2>/dev/null
    echo "$res" > "$cache_file"
    echo "$res"
}

_critical_keyboard_main() {
    local page="$1"
    local total="$2"
    local filter_value="$3"

    local stats=$(_critical_get_log_stats "$filter_value")
    local oldest_ts="" newest_ts=""
    if [ -n "$stats" ]; then
        oldest_ts="${stats%%|*}"
        newest_ts="${stats##*|}"
    fi

    local h_min=0
    local h_max=0

    if [ -n "$oldest_ts" ] && [ "$oldest_ts" != "0" ] && [ -n "$newest_ts" ] && [ "$newest_ts" != "0" ]; then
        local bounds
        bounds=$(gawk -v o="$oldest_ts" -v n="$newest_ts" '
        BEGIN {
            now = systime()
            y = substr(o, 1, 4); m = substr(o, 5, 2); d = substr(o, 7, 2)
            H = substr(o, 9, 2); M = substr(o, 11, 2); S = substr(o, 13, 2)
            oldest_epoch = mktime(y " " m " " d " " H " " M " " S)

            y2 = substr(n, 1, 4); m2 = substr(n, 5, 2); d2 = substr(n, 7, 2)
            H2 = substr(n, 9, 2); M2 = substr(n, 11, 2); S2 = substr(n, 13, 2)
            newest_epoch = mktime(y2 " " m2 " " d2 " " H2 " " M2 " " S2)

            age_newest = now - newest_epoch
            age_oldest = now - oldest_epoch

            # Вверх — чтобы "1.5ч назад" стало "2ч", вниз — чтобы "3.5ч" стало "3ч".
            h_min = int((age_newest + 3599) / 3600)
            if (h_min < 1) h_min = 1
            h_max = int(age_oldest / 3600)
            if (h_max < h_min) h_max = h_min

            print h_min "|" h_max
        }')
        h_min="${bounds%%|*}"
        h_max="${bounds##*|}"
    fi

    local show_set1=1
    if [ -n "$oldest_ts" ] && [ "$oldest_ts" != "0" ]; then
        local cutoff_6h
        cutoff_6h=$(gawk 'BEGIN { print strftime("%Y%m%d%H%M%S", systime() - 6*3600) }')
        if [ -n "$cutoff_6h" ] && [ "$oldest_ts" \< "$cutoff_6h" ]; then
            show_set1=0
        fi
    fi

    local keyboard='{"inline_keyboard":['
    local nav_buttons=""

    if [ "$page" -eq 1 ] && [ "$total" -gt 0 ] && [ -n "$newest_ts" ] && [ "$newest_ts" != "0" ]; then
        if [ -f "/tmp/telegram_bot/critical/dl_menu_open" ]; then
            nav_buttons="{\"text\":\"⬇️ Свернуть\",\"callback_data\":\"critical_dl_toggle\"},"
        else
            nav_buttons="{\"text\":\"⬇️ Скачать\",\"callback_data\":\"critical_dl_toggle\"},"
        fi
    fi

    if [ "$total" -gt 0 ]; then
        if [ "$page" -gt 1 ]; then
            nav_buttons="${nav_buttons}{\"text\":\"⬅️ Назад\",\"callback_data\":\"critical_page_prev\"},"
        fi
        nav_buttons="${nav_buttons}{\"text\":\"📄 $page / $total\",\"callback_data\":\"critical_page_info\"}"
        if [ "$page" -lt "$total" ]; then
            nav_buttons="${nav_buttons},{\"text\":\"Далее ➡️\",\"callback_data\":\"critical_page_next\"}"
        fi
    fi

    if [ -n "$nav_buttons" ]; then
        keyboard="$keyboard[$nav_buttons],"
    fi

    if [ "$page" -eq 1 ] && [ -f "/tmp/telegram_bot/critical/dl_menu_open" ] && [ -n "$newest_ts" ] && [ "$newest_ts" != "0" ]; then
        local t_buttons=""
        if [ "$show_set1" = "1" ]; then
            for h in 1 2 3 4 5; do
                local icon="🔴"
                local cb_action="critical_dl_red_${h}h_${filter_value}"
                if [ "$h" -ge "$h_min" ] 2>/dev/null && [ "$h" -le "$h_max" ] 2>/dev/null; then
                    icon="🟢"
                    cb_action="critical_dl_${h}h_${filter_value}"
                fi
                [ -n "$t_buttons" ] && t_buttons="$t_buttons,"
                t_buttons="${t_buttons}{\"text\":\"${icon} ${h}ч\",\"callback_data\":\"${cb_action}\"}"
            done
        else
            for h in 6 12 24 48 72; do
                local icon="🔴"
                local cb_action="critical_dl_red_${h}h_${filter_value}"
                if [ "$h" -ge "$h_min" ] 2>/dev/null && [ "$h" -le "$h_max" ] 2>/dev/null; then
                    icon="🟢"
                    cb_action="critical_dl_${h}h_${filter_value}"
                fi
                [ -n "$t_buttons" ] && t_buttons="$t_buttons,"
                t_buttons="${t_buttons}{\"text\":\"${icon} ${h}ч\",\"callback_data\":\"${cb_action}\"}"
            done
        fi
        keyboard="$keyboard[${t_buttons}],"
    fi

    keyboard="$keyboard[{\"text\":\"📊 Фильтр\",\"callback_data\":\"critical_filter_menu\"},{\"text\":\"🔄 Обновить\",\"callback_data\":\"critical_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"critical_cancel\"}]"
    keyboard="$keyboard]}"
    echo "$keyboard"
}

_critical_get_filter_menu() {
    local counts_str="$1"
    local counts=()
    IFS=' ' read -ra counts <<< "$counts_str"
    local c_crit=0 c_err=0 c_warn=0 c_net=0 c_wifi=0 c_sys=0
    for item in "${counts[@]}"; do
        key="${item%:*}"
        val="${item#*:}"
        case "$key" in
            crit) c_crit=$val ;;
            err) c_err=$val ;;
            warn) c_warn=$val ;;
            net) c_net=$val ;;
            wifi) c_wifi=$val ;;
            system) c_sys=$val ;;
        esac
    done

    local separator="$SEP46"
    local output="<pre>ℹ️ ЛЕГЕНДА И СОРТИРОВКА

${separator}
🚨 Критические     —    panic, oom, emerg, critical
❌ Ошибки          —    error
⚠️ Предупрежд.     —    warn, warning, alert
🌐 Сеть / IP       —    netifd, pppd, dhcp/dns
📡 Wi-Fi           —    hostapd
🖥️ Система         —    kernel, flash, apk/opkg
${separator}

Выберите категорию для фильтрации лога:</pre>\n"

    local keyboard='{"inline_keyboard":['\
'[{"text":"🚨 Критические ('${c_crit}')","callback_data":"critical_filter_apply_critical"},{"text":"❌ Ошибки ('${c_err}')","callback_data":"critical_filter_apply_error"}],'\
'[{"text":"⚠️ Предупрежд. ('${c_warn}')","callback_data":"critical_filter_apply_warn"},{"text":"🌐 Сеть / IP ('${c_net}')","callback_data":"critical_filter_apply_net"}],'\
'[{"text":"📡 Wi-Fi ('${c_wifi}')","callback_data":"critical_filter_apply_wifi"},{"text":"🖥️ Система ('${c_sys}')","callback_data":"critical_filter_apply_system"}],'

    keyboard="$keyboard[{\"text\":\"⬅️ Назад\",\"callback_data\":\"critical_filter_back\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"critical_cancel\"}]"

    keyboard="$keyboard]}"
    printf "%b||%s" "$output" "$keyboard"
}

# ============================================================
# ЖУРНАЛ СОБЫТИЙ — ГЛАВНЫЙ ОБРАБОТЧИК
# ============================================================
critical_main() {
    local action="$1"
    local param="$2"
    local filter="$3"
    local state_file="${CRITICAL_STATE_DIR}/state_${CHAT_ID}.txt"
    local page_size=14

    case "$action" in

    "init")
        rm -f /tmp/telegram_bot/critical/dl_menu_open

        local raw_logs
        if logread -l 1 >/dev/null 2>&1; then
            raw_logs=$(logread -l 500)
        else
            raw_logs=$(logread | tail -500)
        fi

        local awk_output=$(echo "$raw_logs" | awk "$AWK_CLASSIFY"'
        BEGIN {
            c_crit=0; c_err=0; c_warn=0; c_net=0; c_wifi=0; c_sys=0
            lines_count=0
        }
        NF {
            cat = classify_category($0)
            if (cat != "none") {
                lines[lines_count] = $0
                lines_count++
                if (cat == "crit")        c_crit++
                else if (cat == "err")    c_err++
                else if (cat == "warn")   c_warn++
                else if (cat == "net")    c_net++
                else if (cat == "wifi")   c_wifi++
                else if (cat == "system") c_sys++
            }
        }
        END {
            for (i=0; i<lines_count; i++) print lines[i]
            print "###COUNTS###"
            print c_crit
            print c_err
            print c_warn
            print c_net
            print c_wifi
            print c_sys
            print lines_count
        }' 2>/dev/null)

        local lines_part=$(printf "%s" "$awk_output" | sed '/###COUNTS###/,$d')
        local counts_part=$(printf "%s" "$awk_output" | sed -n '/###COUNTS###/,$p' | tail -n +2)

        local full_list=()
        while IFS= read -r line; do
            [ -n "$line" ] && full_list+=("$line")
        done <<< "$lines_part"

        local c_crit=$(echo "$counts_part" | sed -n '1p')
        local c_err=$(echo "$counts_part" | sed -n '2p')
        local c_warn=$(echo "$counts_part" | sed -n '3p')
        local c_net=$(echo "$counts_part" | sed -n '4p')
        local c_wifi=$(echo "$counts_part" | sed -n '5p')
        local c_sys=$(echo "$counts_part" | sed -n '6p')
        local total_lines=$(echo "$counts_part" | sed -n '7p')

        if [ -z "$total_lines" ] || [ "$total_lines" -eq 0 ]; then
            printf "%b" "✅ <b>Критических событий не обнаружено</b>"
            return 0
        fi

        local page=1
        _critical_save_state "$state_file" "$page" "$page_size" "0" "none" "${full_list[@]}"

        CRIT_FULL_LIST=("${full_list[@]}")
        CRIT_PAGE="$page"
        CRIT_PAGE_SIZE="$page_size"
        CRIT_MSG_ID="0"
        CRIT_FILTER_VALUE="none"

        local counts_str="crit:$c_crit err:$c_err warn:$c_warn net:$c_net wifi:$c_wifi system:$c_sys"
        echo "$counts_str" > "$state_file.counts" 2>/dev/null

        printf "%s\n" "${full_list[@]}" > "/tmp/telegram_bot/critical/full_export.txt"

        local result=$(_critical_process_and_format "none" "$page")
        local text="${result%||*}"
        local total="${result#*||}"
        text="${text//###TIME###/$(date '+%Y-%m-%d %H:%M:%S')}"

        if [ -z "$total" ] || [ "$total" -eq 0 ]; then
            local max_page=0
        else
            local max_page=$(( (total + page_size - 1) / page_size ))
        fi
        local keyboard=$(_critical_keyboard_main "$page" "$max_page" "none")
        echo "$text||$keyboard"
        ;;

    "setmsgid")
        local msg_id="$param"
        if [ ! -f "$state_file" ]; then return 1; fi
        _critical_load_state "$state_file" || return 1
        CRIT_MSG_ID="$msg_id"
        _critical_save_state "$state_file" "$CRIT_PAGE" "$CRIT_PAGE_SIZE" "$CRIT_MSG_ID" "$CRIT_FILTER_VALUE" "${CRIT_FULL_LIST[@]}"
        ;;

    "page")
        local direction="$param"
        if [ ! -f "$state_file" ]; then return 1; fi
        _critical_load_state "$state_file" || return 1
        local new_page="$CRIT_PAGE"
        if [ "$direction" = "prev" ] && [ "$CRIT_PAGE" -gt 1 ]; then
            new_page=$((CRIT_PAGE - 1))
        elif [ "$direction" = "next" ]; then
            new_page=$((CRIT_PAGE + 1))
        fi
        CRIT_PAGE="$new_page"
        _critical_save_state "$state_file" "$CRIT_PAGE" "$CRIT_PAGE_SIZE" "$CRIT_MSG_ID" "$CRIT_FILTER_VALUE" "${CRIT_FULL_LIST[@]}"
        local result=$(_critical_process_and_format "$CRIT_FILTER_VALUE" "$CRIT_PAGE")
        local text="${result%||*}"
        local total="${result#*||}"
        text="${text//###TIME###/$(date '+%Y-%m-%d %H:%M:%S')}"
        if [ -z "$total" ] || [ "$total" -eq 0 ]; then
            local max_page=0
        else
            local max_page=$(( (total + CRIT_PAGE_SIZE - 1) / CRIT_PAGE_SIZE ))
        fi
        local keyboard=$(_critical_keyboard_main "$CRIT_PAGE" "$max_page" "$CRIT_FILTER_VALUE")
        echo "$text||$keyboard"
        ;;

    "refresh")
        local saved_filter="none"
        local saved_page=1
        if [ -f "$state_file" ]; then
            _critical_load_state "$state_file" || return 1
            saved_filter="$CRIT_FILTER_VALUE"
        fi

        rm -f "$state_file" "$state_file.counts" 2>/dev/null

        local raw_logs
        if logread -l 1 >/dev/null 2>&1; then
            raw_logs=$(logread -l 500)
        else
            raw_logs=$(logread | tail -500)
        fi

        local awk_output=$(echo "$raw_logs" | awk "$AWK_CLASSIFY"'
        BEGIN {
            c_crit=0; c_err=0; c_warn=0; c_net=0; c_wifi=0; c_sys=0
            lines_count=0
        }
        NF {
            cat = classify_category($0)
            if (cat != "none") {
                lines[lines_count] = $0
                lines_count++
                if (cat == "crit")        c_crit++
                else if (cat == "err")    c_err++
                else if (cat == "warn")   c_warn++
                else if (cat == "net")    c_net++
                else if (cat == "wifi")   c_wifi++
                else if (cat == "system") c_sys++
            }
        }
        END {
            for (i=0; i<lines_count; i++) print lines[i]
            print "###COUNTS###"
            print c_crit
            print c_err
            print c_warn
            print c_net
            print c_wifi
            print c_sys
            print lines_count
        }' 2>/dev/null)

        local lines_part=$(printf "%s" "$awk_output" | sed '/###COUNTS###/,$d')
        local counts_part=$(printf "%s" "$awk_output" | sed -n '/###COUNTS###/,$p' | tail -n +2)

        local full_list=()
        while IFS= read -r line; do
            [ -n "$line" ] && full_list+=("$line")
        done <<< "$lines_part"

        local c_crit=$(echo "$counts_part" | sed -n '1p')
        local c_err=$(echo "$counts_part" | sed -n '2p')
        local c_warn=$(echo "$counts_part" | sed -n '3p')
        local c_net=$(echo "$counts_part" | sed -n '4p')
        local c_wifi=$(echo "$counts_part" | sed -n '5p')
        local c_sys=$(echo "$counts_part" | sed -n '6p')
        local total_lines=$(echo "$counts_part" | sed -n '7p')

        if [ -z "$total_lines" ] || [ "$total_lines" -eq 0 ]; then
            printf "%b" "✅ <b>Критических событий не обнаружено</b>"
            return 0
        fi

        _critical_save_state "$state_file" "$saved_page" "${CRIT_PAGE_SIZE:-14}" "0" "$saved_filter" "${full_list[@]}"

        CRIT_FULL_LIST=("${full_list[@]}")
        CRIT_PAGE="$saved_page"
        CRIT_PAGE_SIZE="${CRIT_PAGE_SIZE:-14}"
        CRIT_FILTER_VALUE="$saved_filter"

        local counts_str="crit:$c_crit err:$c_err warn:$c_warn net:$c_net wifi:$c_wifi system:$c_sys"
        echo "$counts_str" > "$state_file.counts" 2>/dev/null

        local result=$(_critical_process_and_format "$saved_filter" "$saved_page")
        local text="${result%||*}"
        local total="${result#*||}"
        text="${text//###TIME###/$(date '+%Y-%m-%d %H:%M:%S')}"

        if [ -z "$total" ] || [ "$total" -eq 0 ]; then
            local max_page=0
        else
            local max_page=$(( (total + CRIT_PAGE_SIZE - 1) / CRIT_PAGE_SIZE ))
        fi

        local keyboard=$(_critical_keyboard_main "$saved_page" "$max_page" "$saved_filter")
        echo "$text||$keyboard"
        ;;

    "filter_menu")
        if [ ! -f "$state_file" ]; then return 1; fi
        _critical_load_state "$state_file" || return 1

        local counts_str=""
        if [ -f "$state_file.counts" ]; then
            counts_str=$(cat "$state_file.counts" 2>/dev/null)
        fi
        if [ -z "$counts_str" ]; then
            counts_str=$(_critical_count_categories CRIT_FULL_LIST)
            echo "$counts_str" > "$state_file.counts" 2>/dev/null
        fi

        local result=$(_critical_get_filter_menu "$counts_str")
        echo "$result"
        ;;

    "filter_apply")
        local filter_value="$param"
        if [ ! -f "$state_file" ]; then return 1; fi
        _critical_load_state "$state_file" || return 1
        CRIT_FILTER_VALUE="$filter_value"
        CRIT_PAGE=1
        _critical_save_state "$state_file" "$CRIT_PAGE" "$CRIT_PAGE_SIZE" "$CRIT_MSG_ID" "$CRIT_FILTER_VALUE" "${CRIT_FULL_LIST[@]}"
        local result=$(_critical_process_and_format "$CRIT_FILTER_VALUE" "$CRIT_PAGE")
        local text="${result%||*}"
        local total="${result#*||}"
        text="${text//###TIME###/$(date '+%Y-%m-%d %H:%M:%S')}"
        if [ -z "$total" ] || [ "$total" -eq 0 ]; then
            local max_page=0
        else
            local max_page=$(( (total + CRIT_PAGE_SIZE - 1) / CRIT_PAGE_SIZE ))
        fi
        local keyboard=$(_critical_keyboard_main "$CRIT_PAGE" "$max_page" "$CRIT_FILTER_VALUE")
        echo "$text||$keyboard"
        ;;

    "filter_reset"|"filter_back")
        if [ ! -f "$state_file" ]; then return 1; fi
        _critical_load_state "$state_file" || return 1
        CRIT_FILTER_VALUE="none"
        CRIT_PAGE=1
        _critical_save_state "$state_file" "$CRIT_PAGE" "$CRIT_PAGE_SIZE" "$CRIT_MSG_ID" "$CRIT_FILTER_VALUE" "${CRIT_FULL_LIST[@]}"
        local result=$(_critical_process_and_format "none" "$CRIT_PAGE")
        local text="${result%||*}"
        local total="${result#*||}"
        text="${text//###TIME###/$(date '+%Y-%m-%d %H:%M:%S')}"
        if [ -z "$total" ] || [ "$total" -eq 0 ]; then
            local max_page=0
        else
            local max_page=$(( (total + CRIT_PAGE_SIZE - 1) / CRIT_PAGE_SIZE ))
        fi
        local keyboard=$(_critical_keyboard_main "$CRIT_PAGE" "$max_page" "none")
        echo "$text||$keyboard"
        ;;

    "download")
        local hours="$param"
        local hist_file="/tmp/telegram_bot/critical/history.log"
        local out_file="/tmp/telegram_bot/critical/download_${hours}h_${filter}.txt"

        rm -f /tmp/telegram_bot/critical/filtered.tmp
        rm -f /tmp/telegram_bot/critical/first_line.tmp
        rm -f /tmp/telegram_bot/critical/last_line.tmp
        rm -f /tmp/telegram_bot/critical/download_*h_*.txt

        if [ ! -f "$hist_file" ]; then echo "EMPTY"; return; fi

        local cutoff_ts
        cutoff_ts=$(gawk -v h="$hours" 'BEGIN { print strftime("%Y%m%d%H%M%S", systime() - h*3600) }')

        gawk -v filter="$filter" -v cutoff_ts="$cutoff_ts" "$AWK_CLASSIFY"'
        function get_ts(line,    f1,f2,f3,f4,f5, mon, day, time, yr, m_num, t, cur_mon) {
            # ISO 8601
            if (match(line, /^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})/)) {
                return substr(line, RSTART, 4) substr(line, RSTART+5, 2) substr(line, RSTART+8, 2) substr(line, RSTART+11, 2) substr(line, RSTART+14, 2) substr(line, RSTART+17, 2)
            }
            # MM.DD HH:MM:SS
            if (match(line, /^([0-9]{2})\.([0-9]{2})[ \t]+([0-9]{2}):([0-9]{2}):([0-9]{2})/)) {
                mon = substr(line, RSTART, 2)
                yr = strftime("%Y")
                cur_mon = strftime("%m")
                if (mon + 0 > cur_mon + 0) yr = yr - 1
                return yr mon substr(line, RSTART+3, 2) substr(line, RSTART+6, 2) substr(line, RSTART+9, 2) substr(line, RSTART+12, 2)
            }
            # Mon DD HH:MM:SS [YYYY]
            split(line, parts, " ")
            f1=parts[1]; f2=parts[2]; f3=parts[3]; f4=parts[4]; f5=parts[5]
            if (f1 ~ /^[A-Za-z]{3}$/ && f2 ~ /^[A-Za-z]{3}$/ && f3 ~ /^[0-9]+$/ && f4 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ && f5 ~ /^[0-9]{4}$/) {
                mon=f2; day=f3; time=f4; yr=f5
            } else if (f1 ~ /^[A-Za-z]{3}$/ && f2 ~ /^[A-Za-z]{3}$/ && f3 ~ /^[0-9]+$/ && f4 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
                mon=f2; day=f3; time=f4; yr=strftime("%Y")
            } else if (f1 ~ /^[A-Za-z]{3}$/ && f2 ~ /^[0-9]+$/ && f3 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
                mon=f1; day=f2; time=f3; yr=strftime("%Y")
            } else return "0"

            if (mon=="Jan") m_num="01"; else if (mon=="Feb") m_num="02"; else if (mon=="Mar") m_num="03"; else if (mon=="Apr") m_num="04"; else if (mon=="May") m_num="05"; else if (mon=="Jun") m_num="06"; else if (mon=="Jul") m_num="07"; else if (mon=="Aug") m_num="08"; else if (mon=="Sep") m_num="09"; else if (mon=="Oct") m_num="10"; else if (mon=="Nov") m_num="11"; else if (mon=="Dec") m_num="12"
            split(time, t, ":")
            return sprintf("%s%s%02d%s%s%s", yr, m_num, day, t[1], t[2], t[3])
        }
        NF {
            cat = classify_category($0)
            matched = 0
            if (filter == "none" || filter == "") matched = 1
            else if (filter == "critical" && cat == "crit") matched = 1
            else if (filter == "error" && cat == "err") matched = 1
            else if (filter == "warn" && cat == "warn") matched = 1
            else if (filter == "net" && cat == "net") matched = 1
            else if (filter == "wifi" && cat == "wifi") matched = 1
            else if (filter == "system" && cat == "system") matched = 1

            if (matched) {
                ts = get_ts($0)
                if (ts != "0" && ts >= cutoff_ts) {
                    print $0 >> "/tmp/telegram_bot/critical/filtered.tmp"
                    if (first == "") first = $0
                    last = $0
                }
            }
        }
        END {
            if (first != "") {
                print first > "/tmp/telegram_bot/critical/first_line.tmp"
                print last > "/tmp/telegram_bot/critical/last_line.tmp"
            }
        }' "$hist_file"

        if [ -f "/tmp/telegram_bot/critical/filtered.tmp" ] && [ -s "/tmp/telegram_bot/critical/filtered.tmp" ]; then
            mv /tmp/telegram_bot/critical/filtered.tmp "$out_file"
        else
            echo "EMPTY"
            return
        fi

        local f_ts=$(_extract_ts_key "$(cat /tmp/telegram_bot/critical/first_line.tmp)")
        local l_ts=$(_extract_ts_key "$(cat /tmp/telegram_bot/critical/last_line.tmp)")

        local f_date="${f_ts:6:2}.${f_ts:4:2}.${f_ts:2:2}"
        local f_time="${f_ts:8:2}:${f_ts:10:2}"
        local l_date="${l_ts:6:2}.${l_ts:4:2}.${l_ts:2:2}"
        local l_time="${l_ts:8:2}:${l_ts:10:2}"

        local label="$filter"
        case "$filter" in
            none|"") label="  📑" ;; critical) label="  🚨" ;; error) label="  ❌" ;;
            warn) label="  ⚠️" ;; net) label="  🌐" ;; wifi) label="  📡" ;; system) label="  🖥️" ;;
        esac

        echo "OK|${f_date} ${f_time} - ${l_date} ${l_time} ${label}"
        rm -f /tmp/telegram_bot/critical/first_line.tmp /tmp/telegram_bot/critical/last_line.tmp
        ;;

    *)
        printf "%b" "❌ Неизвестное действие"
        ;;
    esac
}

# ============================================================
# CRON — ПАРСЕР ПОЛЕЙ
# ============================================================

_cron_expand_field() {
    local value="$1"
    local min="$2"
    local max="$3"
    local result=""

    if [ "$value" = "*" ]; then
        local i
        for ((i=min; i<=max; i++)); do
            result="$result $i"
        done
        result="${result# }"
        printf '%s' "$result"
        return 0
    fi

    local -a _items
    IFS=',' read -ra _items <<< "$value"

    local item
    for item in "${_items[@]}"; do
        local step=1
        local has_step=0
        local range="$item"

        if echo "$item" | grep -qE '/'; then
            has_step=1
            range="${item%%/*}"
            step="${item##*/}"
            case "$step" in
                ''|*[!0-9]*) return 1 ;;
            esac
            step=$((10#$step))
            [ "$step" -lt 1 ] && return 1
        fi

        local start end
        if [ "$range" = "*" ]; then
            start=$min
            end=$max
        elif echo "$range" | grep -qE '^[0-9]+-[0-9]+$'; then
            start="${range%-*}"
            end="${range#*-}"
        elif echo "$range" | grep -qE '^[0-9]+$'; then
            start="$range"
            if [ "$has_step" = "1" ]; then
                end=$max
            else
                end="$range"
            fi
        else
            return 1
        fi

        start=$((10#$start))
        end=$((10#$end))

        [ "$start" -lt "$min" ] && start=$min
        [ "$end" -gt "$max" ] && end=$max
        [ "$start" -gt "$end" ] && return 1

        local i
        for ((i=start; i<=end; i+=step)); do
            result="$result $i"
        done
    done

    result=$(printf '%s\n' "$result" | tr ' ' '\n' | grep -v '^$' | sort -n -u | tr '\n' ' ')
    result="${result# }"
    result="${result% }"
    printf '%s' "$result"
    return 0
}

_cron_field_matches() {
    local value="$1"
    local min="$2"
    local max="$3"
    local needle="$4"

    local expanded
    expanded=$(_cron_expand_field "$value" "$min" "$max") || return 1

    local n
    for n in $expanded; do
        [ "$n" = "$needle" ] && return 0
    done
    return 1
}

_cron_next_match() {
    local cmin="$1"
    local chour="$2"
    local cday="$3"
    local cmonth="$4"
    local cwday="$5"
    local tz_offset="$6"

    _cron_expand_field "$cmin" 0 59 >/dev/null || return 1
    _cron_expand_field "$chour" 0 23 >/dev/null || return 1
    _cron_expand_field "$cday" 1 31 >/dev/null || return 1
    _cron_expand_field "$cmonth" 1 12 >/dev/null || return 1
    _cron_expand_field "$cwday" 0 6 >/dev/null || return 1

    local hours mins
    hours=$(_cron_expand_field "$chour" 0 23)
    mins=$(_cron_expand_field "$cmin" 0 59)

    local now_ts=$(date +%s)
    local today_start=$(( (now_ts + tz_offset) / 86400 * 86400 - tz_offset ))

    local d
    for ((d=0; d<400; d++)); do
        local day_start=$((today_start + d*86400))

        local ymd
        ymd=$(date -d "@$((day_start + 43200))" '+%Y %m %d %w' 2>/dev/null)

        local yy mm dd ww
        read -r yy mm dd ww <<< "$ymd"
        [ -z "$dd" ] && continue

        local day_match=1
        local wday_match=1

        _cron_field_matches "$cmonth" 1 12 "$((10#$mm))" || day_match=0
        _cron_field_matches "$cday" 1 31 "$((10#$dd))" || day_match=0
        _cron_field_matches "$cwday" 0 6 "$((10#$ww))" || wday_match=0

        local ok=0
        if [ "$cday" = "*" ] && [ "$cwday" = "*" ]; then
            ok=$day_match
        elif [ "$cday" = "*" ]; then
            ok=$wday_match
        elif [ "$cwday" = "*" ]; then
            ok=$day_match
        else
            if [ "$day_match" = "1" ] || [ "$wday_match" = "1" ]; then
                ok=1
            fi
        fi

        [ "$ok" != "1" ] && continue

        local h
        for h in $hours; do
            [ "$h" -lt 10 ] && h="0$h"
            local m
            for m in $mins; do
                [ "$m" -lt 10 ] && m="0$m"
                local candidate
                candidate=$(date -d "@$((day_start + ${h#0}*3600 + ${m#0}*60))" '+%s' 2>/dev/null)
                [ -z "$candidate" ] && continue
                if [ "$candidate" -gt "$now_ts" ]; then
                    printf '%s' "$candidate"
                    return 0
                fi
            done
        done
    done

    return 1
}

# ============================================================
# БЛИЖАЙШАЯ ПЕРЕЗАГРУЗКА
# ============================================================.
get_next_reboot_info() {
    local tmpfile="/tmp/telegram_bot/reboot/times_$$.tmp"
    rm -f "$tmpfile"
    local found=0

    local tz_offset=0
    local tz_str=$(date +%z 2>/dev/null)
    if [ -n "$tz_str" ] && [ ${#tz_str} -ge 5 ]; then
        local sign=${tz_str:0:1}
        local hh=${tz_str:1:2}
        local mm=${tz_str:3:2}
        if echo "$hh" | grep -qE '^[0-9]+$' && echo "$mm" | grep -qE '^[0-9]+$'; then
            local total_sec=$(( 10#$hh * 3600 + 10#$mm * 60 ))
            if [ "$sign" = "+" ]; then
                tz_offset=$total_sec
            else
                tz_offset=$(( - total_sec ))
            fi
        fi
    fi

    # watchcat
    if command -v uci >/dev/null 2>&1; then
        if uci -q get watchcat >/dev/null 2>&1; then
            local reboot_time=$(uci -q get watchcat.@watchcat[0].reboot_time 2>/dev/null)
            if [ -n "$reboot_time" ] && echo "$reboot_time" | grep -qE '^[0-9]{2}:[0-9]{2}$'; then
                local h=${reboot_time%:*}
                local m=${reboot_time#*:}
                local now_ts=$(date +%s)
                local current_day_start=$((now_ts - (now_ts % 86400)))
                local target_ts=$((current_day_start + h*3600 + m*60 - tz_offset))
                if [ "$target_ts" -lt "$now_ts" ]; then
                    target_ts=$((target_ts + 86400))
                fi
                echo "$target_ts" >> "$tmpfile"
                found=1
            fi
            local reboot_period=$(uci -q get watchcat.@watchcat[0].reboot_period 2>/dev/null)
            if [ -n "$reboot_period" ] && [ "$reboot_period" -gt 0 ] 2>/dev/null; then
                local period_sec=$((reboot_period * 60))
                local now_ts=$(date +%s)
                echo "$((now_ts + period_sec))" >> "$tmpfile"
                found=1
            fi
        fi
    fi

    # crontab
    local crontab_file="/etc/crontabs/root"
    if [ -f "$crontab_file" ]; then
        while IFS= read -r line; do
            echo "$line" | grep -q '^[[:space:]]*#' && continue
            [ -z "$line" ] && continue

            if echo "$line" | grep -qi "reboot"; then
                local clean_line=$(echo "$line" | sed -e 's/[;&|].*//')
                clean_line=$(echo "$clean_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

                if echo "$clean_line" | grep -qE '^@'; then
                    local macro=$(echo "$clean_line" | awk '{print $1}')
                    local cmd_rest=$(echo "$clean_line" | cut -d' ' -f2-)
                    if echo "$cmd_rest" | grep -qi "^reboot"; then
                        local now_ts=$(date +%s)
                        local target_ts=0
                        case "$macro" in
                            "@reboot")
                                continue
                                ;;
                            "@daily"|"@midnight")
                                local current_day_start=$((now_ts - (now_ts % 86400)))
                                target_ts=$((current_day_start - tz_offset))
                                if [ "$target_ts" -lt "$now_ts" ]; then
                                    target_ts=$((target_ts + 86400))
                                fi
                                ;;
                            "@weekly")
                                local current_wday=$(date +%w)
                                local days_until=$(( (0 - current_wday + 7) % 7 ))
                                if [ $days_until -eq 0 ]; then
                                    local now_hour=$(date +%H)
                                    local now_min=$(date +%M)
                                    if [ $now_hour -gt 0 ] || [ $now_min -gt 0 ]; then
                                        days_until=7
                                    fi
                                fi
                                local current_day_start=$((now_ts - (now_ts % 86400)))
                                target_ts=$((current_day_start + days_until*86400 - tz_offset))
                                ;;
                            "@monthly")
                                local current_month=$(date +%m)
                                local current_year=$(date +%Y)
                                local next_month=$((10#$current_month + 1))
                                local next_year=$current_year
                                if [ $next_month -gt 12 ]; then
                                    next_month=1
                                    next_year=$((current_year + 1))
                                fi
                                local next_date="${next_year}-$(printf "%02d" $next_month)-01"
                                if date -d "$next_date" +%s 2>/dev/null >/dev/null; then
                                    target_ts=$(date -d "$next_date 00:00:00" +%s 2>/dev/null)
                                else
                                    local current_day=$(date +%d)
                                    local days_in_month
                                    case $current_month in
                                        01|03|05|07|08|10|12) days_in_month=31 ;;
                                        04|06|09|11) days_in_month=30 ;;
                                        02)
                                            if [ $((current_year % 4)) -eq 0 ] && [ $((current_year % 100)) -ne 0 ] || [ $((current_year % 400)) -eq 0 ]; then
                                                days_in_month=29
                                            else
                                                days_in_month=28
                                            fi
                                            ;;
                                    esac
                                    local days_left=$((days_in_month - 10#$current_day + 1))
                                    target_ts=$((now_ts + days_left*86400))
                                    target_ts=$((target_ts - (target_ts % 86400) - tz_offset))
                                fi
                                if [ "$target_ts" -lt "$now_ts" ]; then
                                    target_ts=$((target_ts + 30*86400))
                                fi
                                ;;
                            "@yearly"|"@annually")
                                local current_year=$(date +%Y)
                                local next_year=$((current_year + 1))
                                if date -d "$next_year-01-01" +%s 2>/dev/null >/dev/null; then
                                    target_ts=$(date -d "$next_year-01-01 00:00:00" +%s 2>/dev/null)
                                else
                                    local is_leap=$(( (current_year % 4 == 0 && current_year % 100 != 0) || (current_year % 400 == 0) ))
                                    local days_in_year=$((is_leap ? 366 : 365))
                                    local current_day_of_year=$(date +%j)
                                    local days_left=$((days_in_year - 10#$current_day_of_year + 1))
                                    target_ts=$((now_ts + days_left*86400))
                                    target_ts=$((target_ts - (target_ts % 86400) - tz_offset))
                                fi
                                ;;
                            *)
                                continue
                                ;;
                        esac
                        if [ "$target_ts" -gt 0 ] && [ "$target_ts" -gt "$now_ts" ]; then
                            echo "$target_ts" >> "$tmpfile"
                            found=1
                        fi
                    fi
                else
                    local cron_min=$(echo "$clean_line" | awk '{print $1}')
                    local cron_hour=$(echo "$clean_line" | awk '{print $2}')
                    local cron_day=$(echo "$clean_line" | awk '{print $3}')
                    local cron_month=$(echo "$clean_line" | awk '{print $4}')
                    local cron_wday=$(echo "$clean_line" | awk '{print $5}')

                    local cmd_rest=$(echo "$clean_line" | awk '{$1=$2=$3=$4=$5=""; print substr($0,6)}' | sed -e 's/^[[:space:]]*//')
                    if echo "$cmd_rest" | grep -qi "^reboot"; then
                        if [ -z "$cron_min" ] || [ -z "$cron_hour" ] || [ -z "$cron_day" ] || [ -z "$cron_month" ] || [ -z "$cron_wday" ]; then
                            continue
                        fi

                        local now_ts=$(date +%s)
                        local target_ts
                        target_ts=$(_cron_next_match "$cron_min" "$cron_hour" "$cron_day" "$cron_month" "$cron_wday" "$tz_offset")

                        if [ -n "$target_ts" ] && [ "$target_ts" -gt "$now_ts" ]; then
                            echo "$target_ts" >> "$tmpfile"
                            found=1
                        fi
                    fi
                fi
            fi
        done < "$crontab_file"
    fi

    if [ "$found" -eq 1 ] && [ -s "$tmpfile" ]; then
        local min_ts=$(sort -n "$tmpfile" | head -1)
        rm -f "$tmpfile"
        echo "$min_ts|cron-or-watchcat"
        return
    fi

    rm -f "$tmpfile"
    echo "0|none"
}

# ============================================================
# МАКСИМАЛЬНЫЙ АПТАЙМ
# ============================================================
update_max_uptime() {
    local current=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
    local max=$(uci -q get telegram_bot.main.max_uptime 2>/dev/null)
    [ -z "$max" ] && max=0
    if [ -n "$current" ] && [ "$current" -gt "$max" ]; then
        uci set telegram_bot.main.max_uptime="$current"
        uci commit telegram_bot
    fi
}

# ============================================================
# SPEEDTEST
# ============================================================

_speedtest_wrap_field() {
    local label="$1"
    local text="$2"
    local indent="$3"
    local max_len=42 

    echo "$text" | LC_ALL=C awk -v label="$label" -v indent="$indent" -v max_w="$max_len" '
    function vlen(s,    n, pos, rest, cols) {
        n = length(s); pos = 1; cols = 0
        while (pos <= n) {
            rest = substr(s, pos)
            if (rest ~ /^&amp;/)       { cols += 1; pos += 5; continue }
            if (rest ~ /^&lt;/)        { cols += 1; pos += 4; continue }
            if (rest ~ /^&gt;/)        { cols += 1; pos += 4; continue }
            if (rest ~ /^&quot;/)      { cols += 1; pos += 6; continue }
            if (rest ~ /^&#39;/)       { cols += 1; pos += 5; continue }
            if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue }
            if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue }
            if (rest ~ /^[\340-\357]/) { cols += 1; pos += 3; continue }
            if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue }
            cols += 1; pos += 1
        }
        return cols
    }
    BEGIN {
        printf "%s", label;
        line_len = vlen(label);
        RS = " ";
        ORS = "";
        first = 1;
    }
    {
        word_len = vlen($0);
        if (first) {
            if (line_len + word_len > max_w) {
                printf "\n%s%s", indent, $0;
                line_len = vlen(indent) + word_len;
            } else {
                printf "%s", $0;
                line_len += word_len;
            }
            first = 0;
        } else {
            if (line_len + 1 + word_len > max_w) {
                printf "\n%s%s", indent, $0;
                line_len = vlen(indent) + word_len;
            } else {
                printf " %s", $0;
                line_len += 1 + word_len;
            }
        }
    }
    END { printf "\n"; }'
}

run_speedtest() {
    if ! command -v speedtest >/dev/null 2>&1; then
        echo "❌ <b>speedtest не установлен</b>

Установите: <code>apk add speedtestcpp</code>
После установки повторите команду."
        return 1
    fi

    local json
    if command -v timeout >/dev/null 2>&1; then
        json=$(timeout 90 speedtest --output json 2>/dev/null)
    else
        json=$(speedtest --output json 2>/dev/null)
    fi

    if [ -z "$json" ] || ! echo "$json" | jq empty 2>/dev/null; then
        echo "❌ <b>Не удалось выполнить Speedtest</b>

Возможные причины:
• Нет связи с серверами speedtest.net
• Таймаут (90 сек) — соединение медленное
• speedtestcpp вернул некорректный ответ"
        return 1
    fi

    local isp ip srv_name srv_sponsor srv_host srv_dist ping jitter dl ul
    isp=$(echo "$json"         | jq -r '.client.isp // "N/A"')
    ip=$(echo "$json"          | jq -r '.client.ip // "N/A"')
    srv_name=$(echo "$json"    | jq -r '.server.name // "N/A"')
    srv_sponsor=$(echo "$json" | jq -r '.server.sponsor // "N/A"')
    srv_host=$(echo "$json"    | jq -r '.server.host // "N/A"')
    srv_dist=$(echo "$json"    | jq -r '.server.distance // 0')
    ping=$(echo "$json"        | jq -r '.ping // 0')
    jitter=$(echo "$json"      | jq -r '.jitter // 0')
    dl=$(echo "$json"          | jq -r '.download_mbit // 0')
    ul=$(echo "$json"          | jq -r '.upload_mbit // 0')

    local safe_isp=$(html_escape "$isp")
    local safe_ip=$(html_escape "$ip")
    local safe_name=$(html_escape "$srv_name")
    local safe_sponsor=$(html_escape "$srv_sponsor")
    local safe_host=$(html_escape "$srv_host")

    local _host_wrapped
    _host_wrapped=$(_speedtest_wrap_field "🌐 Хост: " "$safe_host" "         ")
    local _isp_wrapped
    _isp_wrapped=$(_speedtest_wrap_field "🌍 ISP: " "$safe_isp" "        ")

    local output
    output="<pre>⚡ SPEEDTEST\n"
    output="${output}${SEP46}\n"
    output="${output}📡 Сервер: ${safe_name}\n"
    output="${output}🏢 Провайдер: ${safe_sponsor}\n"
    output="${output}${_host_wrapped}\n"
    output="${output}📏 Удалён: ${srv_dist} км\n"
    output="${output}${_isp_wrapped}\n"
    output="${output}🔗 IP: ${safe_ip}\n"
    output="${output}${SEP46}\n"
    output="${output}🕒 Пинг: ${ping} ms  (джиттер ${jitter} ms)\n"
    output="${output}⬇️ Загрузка: ${dl} Mbit/s\n"
    output="${output}⬆️ Отдача: ${ul} Mbit/s\n"
    output="${output}${SEP46}\n"
    output="${output}\n"
    output="${output}🕒 Обновлено: $(date '+%Y-%m-%d %H:%M:%S')\n"
    output="${output}</pre>"

    printf "%b\n" "$output"
}

# ============================================================
# СТАТУС СИСТЕМЫ
# ============================================================
get_system_info() {
    local model version architecture processor temp_c wifi_temp_24 wifi_temp_5
    local cpu_usage load_avg total_mb avail_mb cache_mb zram_total zram_free
    local disk_total disk_used disk_free freq_ghz

    model=$(ubus call system board 2>/dev/null | jq -r '.model // ""' 2>/dev/null)
    [ -z "$model" ] && model=$(cat /tmp/sysinfo/model 2>/dev/null)
    [ -z "$model" ] && model="Неизвестно"

    version=$(ubus call system board 2>/dev/null | jq -r '.release.description // ""' 2>/dev/null)
    if [ -z "$version" ] && [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release 2>/dev/null
        version="${DISTRIB_DESCRIPTION}"
    fi
    [ -z "$version" ] && version="Неизвестно"

    arch_uname=$(uname -m 2>/dev/null)
    cpu_name=$(grep -E "Processor|model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
    if echo "$cpu_name" | grep -q "Cortex-A"; then
        suffix=$(echo "$cpu_name" | sed -n 's/.*Cortex-\(A[0-9][0-9]*\).*/\1/p' | tr '[:upper:]' '[:lower:]')
        case "$suffix" in
            a53|a55|a72) architecture="${arch_uname}_cortex-${suffix}" ;;
            *) architecture="${arch_uname}" ;;
        esac
    else
        part=$(grep -m1 "CPU part" /proc/cpuinfo 2>/dev/null | awk '{print $4}')
        case "$part" in
            0xd03) architecture="${arch_uname}_cortex-a53" ;;
            0xd05) architecture="${arch_uname}_cortex-a55" ;;
            0xd08) architecture="${arch_uname}_cortex-a72" ;;
            *) architecture="${arch_uname}" ;;
        esac
    fi
    [ -z "$architecture" ] && architecture="Неизвестно"

    processor=$(ubus call system board 2>/dev/null | jq -r '.system // ""' 2>/dev/null)
    [ -z "$processor" ] && processor=$(grep -m1 -E "system type|Processor" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
    [ -z "$processor" ] && processor=$(grep -m1 "cpu model" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')
    processor=$(echo "$processor" | sed -E 's/ (ver:[0-9]+ eco:[0-9]+)//g' | sed -E 's/ +/ /g')
    [ -z "$processor" ] && processor="Неизвестно"

    temp_c=$(get_cpu_temp)
    wifi_temp_24=$(get_wifi_temp phy0)
    wifi_temp_5=$(get_wifi_temp phy1)

    cpu_usage="N/A"
    if [ -f /proc/stat ]; then
        cpu_usage=$(awk '
            BEGIN {
                # Первое чтение
                while ((getline line < "/proc/stat") > 0) {
                    split(line, a, " ")
                    if (a[1] == "cpu") {
                        total1=0; for(i=2;i<=length(a);i++) total1+=a[i];
                        idle1=a[5]+a[6];
                        break;
                    }
                }
                close("/proc/stat");
                
                system("sleep 1");
                
                # Второе чтение
                while ((getline line < "/proc/stat") > 0) {
                    split(line, a, " ")
                    if (a[1] == "cpu") {
                        total2=0; for(i=2;i<=length(a);i++) total2+=a[i];
                        idle2=a[5]+a[6];
                        break;
                    }
                }
                close("/proc/stat");
                
                diff_total = total2 - total1;
                diff_idle = idle2 - idle1;
                
                if (diff_total > 0) {
                    printf "%d", 100 * (diff_total - diff_idle) / diff_total;
                } else {
                    print "N/A";
                }
            }')
    fi

    load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
    [ -z "$load_avg" ] && load_avg="0.0 0.0 0.0"

    mem_total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_free_kb=$(grep '^MemFree:' /proc/meminfo | awk '{print $2}')
    mem_buffers_kb=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')
    mem_cached_kb=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
    mem_available_kb=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    if [ -z "$mem_available_kb" ]; then
        mem_available_kb=$((mem_free_kb + mem_buffers_kb + mem_cached_kb))
    fi
    total_mb=$((mem_total_kb / 1024))
    avail_mb=$((mem_available_kb / 1024))
    cache_mb=$(( (mem_buffers_kb + mem_cached_kb) / 1024 ))

    zram_total="N/A"
    zram_free="N/A"
    if [ -f /proc/swaps ]; then
        zram_line=$(grep -m1 'zram' /proc/swaps)
        if [ -n "$zram_line" ]; then
            zram_total_kb=$(echo "$zram_line" | awk '{print $3}')
            zram_used_kb=$(echo "$zram_line" | awk '{print $4}')
            zram_free_kb=$((zram_total_kb - zram_used_kb))
            zram_total=$((zram_total_kb / 1024))
            zram_free=$((zram_free_kb / 1024))
        fi
    fi

    df_line=$(df -k / | tail -n 1 | awk '{printf "%.0f|%.0f|%.0f", $2/1024, $3/1024, $4/1024}')
    disk_total=$(echo "$df_line" | cut -d'|' -f1)
    disk_used=$(echo "$df_line" | cut -d'|' -f2)
    disk_free=$(echo "$df_line" | cut -d'|' -f3)

    freq_ghz="N/A"
    if command -v mhz >/dev/null 2>&1; then
        mhz_out=$(mhz 2>/dev/null | grep cpu_MHz | sed 's/.*cpu_MHz=//' | awk '{print $1}')
        [ -n "$mhz_out" ] && freq_ghz=$(awk -v m="$mhz_out" 'BEGIN {printf "%.2f", m/1000}')
    elif [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
        freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
        [ -n "$freq" ] && freq_ghz=$(awk -v f="$freq" 'BEGIN {printf "%.2f", f/1000000}')
    fi

    local model_trim="$model"
    if [ ${#model_trim} -gt 35 ]; then
        model_trim="${model_trim:0:34}"
    fi
    local version_trim="$version"
    if [ ${#version_trim} -gt 35 ]; then
        version_trim="${version_trim:0:34}"
    fi

    local safe_model=$(html_escape "$model_trim")
    local safe_ver=$(html_escape "$version_trim")
    local safe_arch=$(html_escape "$architecture")
    local safe_proc=$(html_escape "$processor")
    local safe_freq=$(html_escape "$freq_ghz")
    local safe_cpu=$(html_escape "$cpu_usage")
    local safe_load=$(html_escape "$load_avg")
    local safe_temp=$(html_escape "$temp_c")
    local safe_wifi24=$(html_escape "$wifi_temp_24")
    local safe_wifi5=$(html_escape "$wifi_temp_5")
    local safe_avail=$(html_escape "$avail_mb")
    local safe_total=$(html_escape "$total_mb")
    local safe_cache=$(html_escape "$cache_mb")
    local safe_zfree=$(html_escape "$zram_free")
    local safe_ztotal=$(html_escape "$zram_total")
    local safe_dfree=$(html_escape "$disk_free")
    local safe_dtotal=$(html_escape "$disk_total")

    local output
    output="<pre>📊 СТАТУС СИСТЕМЫ\n"
    output="${output}\n"
    output="${output}${SEP46}\n"
    output="${output}🛠️ ЖЕЛЕЗО \n"
    output="${output}${SEP46}\n"
    output="${output}\n"
    output="${output}🖥️ Модель:       ${safe_model}\n"
    output="${output}🌐 Версия ОС:    ${safe_ver}\n"
    output="${output}🔩 Архитектура:  ${safe_arch}\n"
    output="${output}⚙️ Процессор:    ${safe_proc}\n"
    output="${output}📈 Частота:      ${safe_freq} GHz\n"
    output="${output}\n"
    output="${output}${SEP46}\n"
    output="${output}📊 СОСТОЯНИЕ \n"
    output="${output}${SEP46}\n"
    output="${output}\n"
    output="${output}⚡ Load:    ${safe_cpu}%     Load: ${safe_load}\n"
    output="${output}🌡️ CPU:     ${safe_temp}\n"
    output="${output}🌡️ Wi-Fi:   ${safe_wifi24} - 2.4 GHz;  ${safe_wifi5} - 5 GHz\n"
    output="${output}💾 ОЗУ:     ${safe_total} MB (своб. ${safe_avail} MB, кэш ${safe_cache} MB)\n"
    if [ "$zram_total" = "N/A" ] || [ -z "$zram_total" ]; then
        output="${output}📼 Zram:     Не используется\n"
    else
        output="${output}📼 Zram:    ${safe_ztotal} MB (своб. ${safe_zfree} MB)\n"
    fi
    output="${output}🗃️ Флэш:    ${safe_dtotal} MB (своб. ${safe_dfree} MB)\n"
    output="${output}${SEP46}\n"
    output="${output}🕒 $(date '+%Y-%m-%d %H:%M:%S')\n"
    output="${output}</pre>"

    printf "%b\n" "$output"
}

# ============================================================
# WAKE-ON-LAN
# ============================================================
wake_pc() {
    if ! command -v etherwake >/dev/null 2>&1; then
        echo "❌ <b>Ошибка:</b> etherwake не установлен. 
Установите: <code>apk add etherwake</code>"
        return
    fi

    local WOL_NAME=$(uci -q get telegram_bot.wol.name 2>/dev/null)
    local WOL_MAC=$(uci -q get telegram_bot.wol.mac 2>/dev/null)

    if [ -z "$WOL_MAC" ] || [ -z "$WOL_NAME" ]; then
        echo "⚠️ <b>Ошибка:</b> WOL не настроен или конфигурация неполная.
Используйте 'Настроить' для ввода имени и MAC."
        return
    fi

    local mac="$WOL_MAC"
    local name="$WOL_NAME"

    local ew_err
    ew_err=$(etherwake -i "$LAN_IFACE" "$mac" 2>&1)
    local ew_rc=$?
    if [ $ew_rc -ne 0 ]; then
        echo "$(date): wake_pc: etherwake failed (rc=$ew_rc): $ew_err" >> /tmp/telegram_bot/logs/bot.log
        local safe_err=$(html_escape "$ew_err")
        echo "❌ <b>Ошибка отправки magic packet</b>

Причина: <code>${safe_err}</code>

Проверьте:
• ПК подключён к сети по кабелю
• Wake-on-LAN включён в BIOS и драйвере
• MAC-адрес в настройках верный"
        return
    fi

    local ip=""
    local attempts=0
    while [ $attempts -lt 7 ]; do
        ip=$(get_ip_for_mac "$mac")
        if [ -n "$ip" ]; then
            if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                break
            else
                ip=""
            fi
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    [ -z "$ip" ] && ip="N/A"

    local separator="$SEP46"
    local name_safe=$(html_escape "$name")
    local ip_safe=$(html_escape "$ip")

    echo "<pre>✅ <b>Магический пакет отправлен</b>

$separator
🖥 $name_safe
🌐 $ip_safe
🔗 $mac
🕒 $(date '+%Y-%m-%d %H:%M:%S')
$separator
💡 Устройство должно скоро появиться в сети</pre>"
}

# ============================================================
# ОГРАНИЧЕНИЕ СКОРОСТИ ЧЕРЕЗ BANDIX
# ============================================================
set_device_speed_limit() {
    local mac="$1"
    mac=$(echo "$mac" | tr 'A-Z' 'a-z')
    local rx_limit_kbytes="$2"
    local tx_limit_kbytes="$3"
    local rx_display="$4"
    local tx_display="$5"
    local start_time="$6"
    local end_time="$7"
    local days_mask="$8"

    days_mask=$((days_mask + 0))

    if [ -z "$days_mask" ] || [ "$days_mask" -eq 0 ] 2>/dev/null; then
        days_mask=127
    fi

    if [ "$days_mask" -eq 0 ]; then
        echo "⚠️ <b>Ошибка:</b> Должен быть выбран хотя бы один день недели."
        return
    fi

    if [ -z "$mac" ] || ! echo "$mac" | grep -q ':'; then
        echo "❌ <b>Ошибка:</b> неверный MAC-адрес: $mac"
        return
    fi

    if ! echo "$rx_limit_kbytes" | grep -q '^[0-9]\+$' || ! echo "$tx_limit_kbytes" | grep -q '^[0-9]\+$'; then
        echo "⚠️ <b>Ошибка:</b> скорость должна быть числом (КБайт/с)"
        return
    fi

    local existing_profiles=$(ubus call luci.bandix getScheduleLimits 2>/dev/null | jq -r ".data.limits[] | select(.mac | ascii_downcase == \"$mac\") | .id" 2>/dev/null | wc -l)
    if [ "$existing_profiles" -ge 5 ]; then
        local device_name=$(get_device_name "$mac")
        local ip=$(get_ip_for_mac "$mac")
        [ -z "$ip" ] && ip="N/A"
        echo "⚠️ <b>Превышен лимит профилей (5)</b>
        
$SEP46
📱 $device_name
🌐 $ip
🔗 $mac
📊 Активных профилей: 5/5
$SEP46

Удалите один из существующих профилей, чтобы добавить новый."
        return
    fi

    rx_limit_kbytes=$((rx_limit_kbytes + 0))
    tx_limit_kbytes=$((tx_limit_kbytes + 0))
    [ "$rx_limit_kbytes" -eq 0 ] && rx_limit_kbytes=1
    [ "$tx_limit_kbytes" -eq 0 ] && tx_limit_kbytes=1

    days_mask=$((days_mask + 0))
    [ "$days_mask" -eq 0 ] && days_mask=127

    local days_array="["
    local first=1
    for i in {0..6}; do
        local bit=$((1 << i))
        if [ $((days_mask & bit)) -ne 0 ]; then
            if [ $first -eq 1 ]; then
                first=0
            else
                days_array="$days_array,"
            fi
            days_array="$days_array$((i+1))"
        fi
    done
    days_array="$days_array]"

    local json=$(jq -n \
        --arg mac "$mac" \
        --argjson rx "$rx_limit_kbytes" \
        --argjson tx "$tx_limit_kbytes" \
        --arg start "$start_time" \
        --arg end "$end_time" \
        --argjson days "$days_array" \
        '{
            mac: $mac,
            wan_rx_rate_limit: $rx,
            wan_tx_rate_limit: $tx,
            start_time: $start,
            end_time: $end,
            days: $days
        }')

    local response=$(ubus call luci.bandix setScheduleLimit "$json" 2>/dev/null)

    if [ -z "$response" ]; then
        echo "❌ <b>Ошибка:</b> не удалось выполнить запрос к Bandix (пустой ответ)."
        echo "Проверьте, что служба luci.bandix работает." >> /tmp/telegram_bot/logs/bot.log
        return
    fi

    local success=$(echo "$response" | jq -r '.success' 2>/dev/null)
    if [ "$success" != "true" ]; then
        echo "❌ <b>Ошибка:</b> не удалось установить ограничение. Ответ: $response"
        echo "ERROR: set_speed ubus failed: $response" >> /tmp/telegram_bot/logs/bot.log
        return
    fi

    local total_after=$(ubus call luci.bandix getScheduleLimits 2>/dev/null | jq -r ".data.limits[] | select(.mac | ascii_downcase == \"$mac\") | .id" 2>/dev/null | wc -l)

    local separator="$SEP46"

    local days_names="Пн Вт Ср Чт Пт Сб Вс"
    local used_days=""
    local unused_days=""
    local idx=0
    for day in $days_names; do
        local bit=$((1 << idx))
        if [ $((days_mask & bit)) -ne 0 ]; then
            if [ -n "$used_days" ]; then
                used_days="$used_days, "
            fi
            used_days="$used_days$day"
        else
            if [ -n "$unused_days" ]; then
                unused_days="$unused_days, "
            fi
            unused_days="$unused_days$day"
        fi
        idx=$((idx+1))
    done

    if [ "$days_mask" -eq 127 ]; then
        days_line="📅 Дни: Все дни"
    else
        if [ -z "$used_days" ]; then
            used_days="(нет)"
        fi
        days_line="📅 Дни: $used_days"
        if [ -n "$unused_days" ]; then
            days_line="$days_line (кроме $unused_days)"
        fi
    fi

    local ip=$(get_ip_for_mac "$mac")
    [ -z "$ip" ] && ip="N/A"
    local device_name=$(get_device_name "$mac")
    if [ -z "$device_name" ]; then
        device_name="$mac"
    fi
    local safe_device=$(html_escape "$device_name")

    echo "<pre>""✅ <b>Ограничения установлены для устройства:</b>"
    echo "$separator"
    echo "📱 $safe_device"
    echo "🌐 $ip"
    echo "🔗 $mac"
    echo "⬇️ Входящая: ${rx_display}"
    echo "⬆️ Исходящая: ${tx_display}"
    echo "🕛 Действует: ${start_time} - ${end_time}"
    echo "$days_line"
    echo "📊 Всего профилей: ${total_after}/5"
    echo "$separator"
    echo ""
    echo "</pre>"
}

get_bot_status() {
    # 1. Время работы бота
    local _bot_up="Неизвестно"
    if [ -f "/var/lock/telegram_bot.lock" ]; then
        local _bs=$(stat -c %Y /var/lock/telegram_bot.lock 2>/dev/null)
        local _now=$(date +%s)
        local _diff=$((_now - _bs))
        _bot_up="$((_diff / 3600))ч $(((_diff % 3600) / 60))м"
    fi

    # 2. Память
    local _bot_rss=0
    local _pids=""
    [ -f "/var/lock/telegram_bot.lock" ] && _pids=$(cat "/var/lock/telegram_bot.lock" 2>/dev/null)
    set -- $(pgrep -f 'watchdog.sh' 2>/dev/null)
    [ -n "$1" ] && _pids="$_pids $1"
    set -- $(pgrep -f 'event_monitor.sh' 2>/dev/null)
    [ -n "$1" ] && _pids="$_pids $1"

    for pid in $_pids; do
        local _rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
        [ -n "$_rss" ] && _bot_rss=$((_bot_rss + _rss))
    done
    local _bot_mb=$(awk -v kb="$_bot_rss" 'BEGIN {printf "%.1f", kb/1024}')

    # 3. Watchdog
    local _wd_st="🔴 Не активен"
    local _wd_pid=$(pgrep -f 'watchdog.sh' | head -1)
    local _wd_hb_file="/tmp/telegram_bot/heartbeat/watchdog"
    
    if [ -n "$_wd_pid" ]; then
        if [ -f "$_wd_hb_file" ]; then
            local _wd_hb=$(cat "$_wd_hb_file" 2>/dev/null)
            case "$_wd_hb" in ''|*[!0-9]*) _wd_hb=0 ;; esac
            local _now=$(date +%s)
            local _age=$((_now - _wd_hb))
            [ "$_age" -gt 60 ] && _wd_st="🟠 Завис (${_age}с)" || _wd_st="🟢 Активен (${_age}с назад)"
        else
            _wd_st="🟢 Активен (нет данных)"
        fi
    fi

    # 4. Exec-сессия
    local _exec_st="🔴 Не активна"
    if _exec_session_active; then
        local _estate=$(cat "$_EXEC_STATE_FILE" 2>/dev/null)
        case "$_estate" in
            idle)    _exec_st="🟢 Готова" ;;
            waiting) _exec_st="🟡 Ждёт ввод" ;;
            running) _exec_st="🟠 Выполняется" ;;
            *)       _exec_st="🟢 Активна" ;;
        esac
    fi

    # 5. Пинг до Telegram
    local _ping=$(curl -o /dev/null -s -w "%{time_connect}" "https://api.telegram.org/bot$BOT_TOKEN/getMe" 2>/dev/null)
    _ping=$(awk -v p="$_ping" 'BEGIN{printf "%d", p*1000}' 2>/dev/null)
    [ -z "$_ping" ] || [ "$_ping" = "0" ] && _ping="?"

    # 6. Ошибки API
    local _api_err=$(awk '/send_message failed|send_tg failed/ {c++} END {print c+0}' /tmp/telegram_bot/logs/bot.log 2>/dev/null)

    # 7. Размер на диске
    local _sz_etc=$(du -sh /etc/telegram_bot 2>/dev/null | awk '{print $1}')
    local _sz_data=$(du -sh /etc/telegram_bot/data 2>/dev/null | awk '{print $1}')
    local _sz_tmp=$(du -sh /tmp/telegram_bot 2>/dev/null | awk '{print $1}')
    [ -z "$_sz_etc" ] && _sz_etc="0B"
    [ -z "$_sz_data" ] && _sz_data="0B"
    [ -z "$_sz_tmp" ] && _sz_tmp="0B"

    cat <<EOF
<pre>📊 СТАТУС БОТА
${SEP46}
🤖 ОСНОВНОЕ
  Время работы:        ${_bot_up}
  Потребление RAM:     ${_bot_rss} KB (RSS)
  Watchdog:            ${_wd_st}
  Exec-сессия:         ${_exec_st}

📡 СЕТЬ И API
  Пинг до Telegram:    ${_ping} мс
  Ошибки API:          ${_api_err} (за сегодня)

💾 МЕСТО НА ДИСКЕ
  Скрипты (/etc):      ${_sz_etc}
  База (data):         ${_sz_data}
  Временные (/tmp):    ${_sz_tmp}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')</pre>
EOF
}

# ============================================================
# ОСНОВНОЙ CASE
# ============================================================

case "$1" in
    "online")
        _online_page="${2:-1}"
        case "$_online_page" in ''|*[!0-9]*) _online_page=1 ;; esac
        [ "$_online_page" -lt 1 ] && _online_page=1
        _online_psize=20
        _online_pstart=$(( (_online_page - 1) * _online_psize + 1 ))
        _online_pend=$(( _online_page * _online_psize ))

        echo "1" > "$_ONLINE_COUNTER_FILE"
        : > "$_ONLINE_DEVICES_FILE"

        _get_blocked_macs > "$_ONLINE_BLOCKED_FILE"

        speed_file="/tmp/telegram_bot/traffic/bandix_speeds_$$"
        ubus call luci.bandix getStatus 2>/dev/null | jq -r '.d[] | "\(.mac)|\(.t_rx_r // 0)|\(.t_tx_r // 0)"' > "$speed_file"

        all_data=""
        wifi_macs=""

        ap_list=$(ubus call network.wireless status 2>/dev/null | jq -r '
            to_entries | sort_by(.key) | .[] | .value.interfaces[]?
            | select(.config.mode == "ap")
            | "\(.ifname)|\(.config.ssid // "?")|\((.config.network // []) | join(","))"
        ')

        while IFS='|' read -r iface ssid network; do
            [ -z "$iface" ] && continue

            net_label="Wi-Fi"
            case "$network" in
                *guest*) net_label="Гостевая" ;;
            esac

            band_label="$iface"
            case "$iface" in
                *phy0*) band_label="2.4 GHz" ;;
                *phy1*) band_label="5 GHz" ;;
            esac

            title="${ssid} — ${net_label} ${band_label}"

            block=$(get_wifi_info "$iface" "$title" "$speed_file" "$_online_pstart" "$_online_pend")
            if [ -n "$block" ]; then
                all_data="${all_data}${block}"$'\n\n'
            fi

            wifi_macs="$wifi_macs $(iw dev "$iface" station dump 2>/dev/null | grep Station | awk '{print tolower($2)}')"
        done <<< "$ap_list"

        echo "$wifi_macs" | tr ' ' '\n' | sed '/^$/d' | sort -u \
            > /tmp/telegram_bot/online/wifi_macs 2>/dev/null

        wifi_macs=$(echo "$wifi_macs" | tr ' ' '\n' | sort -u | tr '\n' ' ')

        lan=$(get_lan_devices "$speed_file" "$wifi_macs" "$_online_pstart" "$_online_pend")

        rm -f "$speed_file"

        if [ -n "$lan" ]; then
            all_data="${all_data}${lan}"
        fi

        blocked_section=$(_render_blocked_section "$_online_pstart" "$_online_pend")
        if [ -n "$blocked_section" ]; then
            all_data="${all_data}

${blocked_section}
"
        fi

        while [ "${all_data#$'\n'}" != "$all_data" ]; do
            all_data="${all_data#$'\n'}"
        done
        while [ "${all_data%$'\n'}" != "$all_data" ]; do
            all_data="${all_data%$'\n'}"
        done

        _online_total=$(wc -l < "$_ONLINE_DEVICES_FILE" 2>/dev/null | tr -d ' ')
        case "$_online_total" in ''|*[!0-9]*) _online_total=0 ;; esac
        _online_tpages=$(( (_online_total + _online_psize - 1) / _online_psize ))
        [ "$_online_tpages" -lt 1 ] && _online_tpages=1
        echo "$_online_tpages" > /tmp/telegram_bot/online/total_pages

        _online_header="🖥️ Клиенты онлайн"
        [ "$_online_tpages" -gt 1 ] && _online_header="🖥️ Клиенты онлайн (стр. $_online_page / $_online_tpages)"

        printf "<pre>%s\n\n%s\n%s\n%s\n🕒 Обновлено: %s</pre>" \
            "$_online_header" "$SEP46" "$all_data" "$SEP46" "$(date '+%Y-%m-%d %H:%M:%S')"
        ;;

    "traffic")
        period_arg="${2:-day}"
        case "$period_arg" in
            day)   days=1 ;;
            week)  days=7 ;;
            month) days=30 ;;
            quarter) days=90 ;;
            *)
                if [[ "$period_arg" =~ ^[0-9]+$ ]]; then
                    days="$period_arg"
                else
                    days=1
                fi
                ;;
        esac

        now_sec=$(date +%s)

        current_day_start=$(date -d "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
        if [ -z "$current_day_start" ]; then
            tz_offset=$(date +%z | awk '
                {
                    sign = substr($0, 1, 1)
                    hh = substr($0, 2, 2)
                    mm = substr($0, 4, 2)
                    print (sign == "+" ? 1 : -1) * (hh * 3600 + mm * 60)
                }')
            [ -z "$tz_offset" ] && tz_offset=0
            current_day_start=$(( (now_sec - tz_offset) - ((now_sec - tz_offset) % 86400) + tz_offset ))
        fi

        if [ "$days" -eq 1 ]; then
            start_sec=$current_day_start
            period_label="сегодня ($(date +%d.%m.%Y))"
        else
            start_sec=$((current_day_start - (days - 1) * 86400))
            start_date=$(date -d "@$start_sec" +%d.%m.%Y 2>/dev/null || echo "??.??.????")
            end_date=$(date +%d.%m.%Y)
            period_label="с $start_date по $end_date"
        fi

        start_ms=$((start_sec * 1000))
        end_ms=$((now_sec * 1000))

        total_traffic=$(ubus call luci.bandix getTrafficUsageRanking "{\"start_ms\":$start_ms,\"end_ms\":$end_ms,\"network_type\":\"wan\"}" 2>/dev/null | jq -r '.t_b // 0')

        case "$total_traffic" in
            ''|*[!0-9]*) total_traffic=0 ;;
        esac

        if [ "$total_traffic" -eq 0 ]; then
            total_traffic="0 B"
        else
            total_traffic=$(bytes_to_human "$total_traffic")
        fi

        table=$(get_traffic_body "$start_ms" "$end_ms")
        if [ $? -ne 0 ] || [ -z "$table" ]; then
            printf "<pre>📊 РЕЙТИНГ ТРАФИКА\n\n%s\n📅 %s\n%s\n📦 Общий трафик: %s\n\nНет данных за период\n%s\n🕒 Обновлено: %s\n\nВыберите период, нажав на кнопку:</pre>" \
                "$SEP46" "$period_label" "$SEP46" "$total_traffic" "$SEP46" "$(date '+%Y-%m-%d %H:%M:%S')"
        else
            printf "<pre>📊 РЕЙТИНГ ТРАФИКА\n\n%s\n📅 %s\n%s\n📦 Общий трафик: %s\n%s\n%s\n%s\n🕒 Обновлено: %s\n\nВыберите период, нажав на кнопку:</pre>" \
                "$SEP46" "$period_label" "$SEP46" "$total_traffic" "$SEP46" "$table" "$SEP46" "$(date '+%Y-%m-%d %H:%M:%S')"
        fi
        ;;

    "critical")
        critical_main "$2" "$3" "$4"
        ;;

    "uptime")
        update_max_uptime

        current_uptime=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
        max_uptime=$(uci -q get telegram_bot.main.max_uptime 2>/dev/null || echo 0)

        current_days=$((current_uptime / 86400))
        current_hours=$(((current_uptime % 86400) / 3600))
        current_minutes=$(((current_uptime % 3600) / 60))

        max_days=$((max_uptime / 86400))
        max_hours=$(((max_uptime % 86400) / 3600))
        max_minutes=$(((max_uptime % 3600) / 60))

        boot_epoch=$(($(date +%s) - current_uptime))
        boot_date=$(date -d "@$boot_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Неизвестно")

        NBSP=$(printf "\302\240")
        reboot_info=$(get_next_reboot_info)
        reboot_ts=$(echo "$reboot_info" | cut -d'|' -f1)

        printf '%s\n' "<pre>🕒 ВРЕМЯ РАБОТЫ РОУТЕРА"
        printf '%s\n' " "
        printf '%s\n' "$SEP46"
        printf '🕒 Аптайм: %dд %dч %dмин\n' "$current_days" "$current_hours" "$current_minutes"
        printf '🏆 Рекорд: %dд %dч %dмин\n' "$max_days" "$max_hours" "$max_minutes"

        if [ "$reboot_ts" -gt 0 ]; then
            now_ts=$(date +%s)
            diff=$((reboot_ts - now_ts))
            if [ "$diff" -gt 0 ]; then
                days=$((diff / 86400))
                hours=$(((diff % 86400) / 3600))
                minutes=$(((diff % 3600) / 60))
                remain="${days}д ${hours}ч ${minutes}мин"
                printf '⏳%sСледующая перезагрузка:%s%s\n' "$NBSP" "$NBSP" "$remain"
            else
                printf '⏳%sСледующая перезагрузка:%sне запланирована\n' "$NBSP" "$NBSP"
            fi
        else
            printf '⏳%sСледующая перезагрузка:%sне запланирована\n' "$NBSP" "$NBSP"
        fi

        printf '🔄%sПоследняя перезагрузка:%s%s\n' "$NBSP" "$NBSP" "$boot_date"
        printf '%s\n' "$SEP46"
        printf '%s\n' " "
        printf '🕒 Обновлено: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')</pre>"
        ;;

    "reboot_now")
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="🔴  <b>Роутер перезагружается. Подождите...</b>" \
            -d parse_mode="HTML" > /dev/null 2>&1
        touch /etc/telegram_bot/data/.reboot_from_bot
        sleep 1
        reboot
        ;;

    "system")
        get_system_info
        ;;

    "speedtest")
        run_speedtest
        ;;

    "wake")
        wake_pc
        ;;

    "set_speed")
        set_device_speed_limit "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
        ;;

    "format_speed")
        format_speed "$2"
        ;;

    "update_max_uptime")
        update_max_uptime
        ;;

    "block_mac")
        _block_mac "$2"
        ;;

    "unblock_mac")
        _unblock_mac "$2"
        ;;
	"status")
        get_bot_status
        ;;

    *)

        if ip link show "$1" >/dev/null 2>&1; then
            IFACE_FROM_CLI="$1"
            EVENT="$2"
            MAC="$3"
        else
            IFACE_FROM_CLI=""
            EVENT="$1"
            MAC="$2"
        fi

        if [ "$EVENT" = "AP-STA-CONNECTED" ] || [ "$EVENT" = "AP-STA-DISCONNECTED" ]; then
            _matched_name=""
            _matched_name=$(_target_get_name "$MAC")

            if [ -z "$_matched_name" ]; then
                exit 0
            fi

            DEVICE_NAME="$_matched_name"
            TIME=$(date "+%Y-%m-%d %H:%M:%S")

            if [ -z "$IFACE_FROM_CLI" ]; then
                IFACE_FROM_CLI="неизвестный"
            fi

            NET_NAME=""
            if [ "$IFACE_FROM_CLI" = "$INTERFACE_24" ]; then
                NET_NAME=$(get_ssid "$INTERFACE_24")
            elif [ "$IFACE_FROM_CLI" = "$INTERFACE_5" ]; then
                NET_NAME=$(get_ssid "$INTERFACE_5")
            else
                NET_NAME="$IFACE_FROM_CLI"
            fi
            if [ -z "$NET_NAME" ]; then
                NET_NAME="$IFACE_FROM_CLI"
            fi

            safe_device=$(html_escape "$DEVICE_NAME")
            safe_net=$(html_escape "$NET_NAME")
            safe_iface=$(html_escape "$IFACE_FROM_CLI")
            _kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"close_error"}]]}'
            
            _pending_file="/tmp/telegram_bot/state/pending_disc_${MAC}"

            if [ "$EVENT" = "AP-STA-CONNECTED" ]; then
                rm -f "$_pending_file"

                MESSAGE="🔔 <b>${safe_device} подключился к WiFi ${safe_net}</b>
📡 Интерфейс: ${safe_iface}
🕒 Время: ${TIME}"
                send_tg_kb "$MESSAGE" "$_kb"
            else
                touch "$_pending_file"
                
                (
                    exec 200>&- 2>/dev/null
                    
                    sleep 10 
                    
                    if [ -f "$_pending_file" ]; then
                        rm -f "$_pending_file"
                        
                        MESSAGE="🔕 <b>${safe_device} отключился от WiFi ${safe_net}</b>
📡 Интерфейс: ${safe_iface}
🕒 Время: ${TIME}"
                        send_tg_kb "$MESSAGE" "$_kb"
                    fi
                ) </dev/null >/dev/null 2>&1 200<&- &
                
                disown
            fi
        fi
        ;;
esac