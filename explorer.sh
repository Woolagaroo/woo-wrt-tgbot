#!/bin/bash
# ==============================================================================
# 📂 МОДУЛЬ ПРОВОДНИКА (EXPLORER) ДЛЯ TELEGRAM-БОТА
# ==============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Этот модуль подключается через source из telegram_bot.sh" >&2
    exit 1
fi

# ==============================================================================
# 🚀 РАЗДЕЛ 1: КОНСТАНТЫ И ФАЙЛЫ СОСТОЯНИЯ
# ==============================================================================

_EXPL_PAGE_SIZE=30
_EXPL_MSG_ID_FILE="/tmp/telegram_bot/explorer/msg_id"
_EXPL_CUR_PATH_FILE="/tmp/telegram_bot/explorer/current_path"
_EXPL_SEL_PATH_FILE="/tmp/telegram_bot/explorer/selected"
_EXPL_SEL_TYPE_FILE="/tmp/telegram_bot/explorer/selected_type"
_EXPL_PAGE_FILE="/tmp/telegram_bot/explorer/page"
_EXPL_TOTAL_PAGES_FILE="/tmp/telegram_bot/explorer/total_pages"
_EXPL_CLIPBOARD_FILE="/tmp/telegram_bot/explorer/clipboard"
_EXPL_CUT_FILE="/tmp/telegram_bot/explorer/cut_path"
_EXPL_RENAME_MODE_FILE="/tmp/telegram_bot/explorer/rename_mode"
_EXPL_RENAME_TARGET_FILE="/tmp/telegram_bot/explorer/rename_target"
_EXPL_UPLOAD_MODE_FILE="/tmp/telegram_bot/explorer/upload_mode"
_EXPL_UPLOAD_PROMPT_MSG_FILE="/tmp/telegram_bot/explorer/upload_prompt_msg_id"
_EXPL_UPLOAD_RESULT_MSG_FILE="/tmp/telegram_bot/explorer/upload_result_msg_id"
_EXPL_UPLOAD_RESULT_PATH_FILE="/tmp/telegram_bot/explorer/upload_result_path"
_EXPL_UPLOAD_RETURN_PATH_FILE="/tmp/telegram_bot/explorer/upload_return_path"
_EXPL_UPLOAD_RETURN_PAGE_FILE="/tmp/telegram_bot/explorer/upload_return_page"
_EXPL_HISTORY_FILE="/tmp/telegram_bot/explorer/history"
_EXPL_RETURN_CONTEXT_FILE="/tmp/telegram_bot/explorer/return_context"
_EXPL_LAST_ACTIVITY_FILE="/tmp/telegram_bot/explorer/last_activity"
_EXPL_RETURN_FLAG="/tmp/telegram_bot/exec/return_to_explorer"
_EXPL_MODE_FILE="/tmp/telegram_bot/explorer/mode"
_EXPL_DEVICE_FILE="/tmp/telegram_bot/explorer/device"
_EXPL_ROUTER_ROOT_FILE="/tmp/telegram_bot/explorer/router_root"
_EXPL_USB_ROOT_FILE="/tmp/telegram_bot/explorer/usb_root"
_EXPL_DIR_SIZES_CACHE="/tmp/telegram_bot/explorer/dir_sizes_cache"
_EXPL_DIR_SIZES_TTL=300
_EXPL_UNPACK_SELECT_FILE="/tmp/telegram_bot/explorer/unpack_select_archive"
_EXPL_UNPACK_RESULT_PATH_FILE="/tmp/telegram_bot/explorer/unpack_result_path"
_EXPL_UNPACK_CONFIRM_FILE="/tmp/telegram_bot/explorer/unpack_confirm_state"
_EXPL_SAME_FOLDER_SRC_FILE="/tmp/telegram_bot/explorer/same_folder_src"
_EXPL_SEARCH_MODE_FILE="/tmp/telegram_bot/explorer/search_mode"
_EXPL_CREATE_MODE_FILE="/tmp/telegram_bot/explorer/create_mode"
_EXPL_SEARCH_RESULT_FILE="/tmp/telegram_bot/explorer/search_result"
_EXPL_INPUT_MSG_ID_FILE="/tmp/telegram_bot/explorer/input_msg_id"
_EXPL_LAST_ARCHIVE_FILE="/tmp/telegram_bot/explorer/last_archive"

# ==============================================================================
# 🛠️ РАЗДЕЛ 2: БАЗОВЫЕ УТИЛИТЫ И РАБОТА С ПУТЯМИ
# ==============================================================================

# Байты → человекочитаемо (B / KB / MB / GB).
_expl_format_size() {
    local b="$1"
    case "$b" in ''|*[!0-9]*) echo "—"; return ;; esac

    awk -v b="$b" 'BEGIN {
        if (b < 1024) {
            printf "%d B", b
        } else if (b < 1048576) {
            kb = b / 1024
            if (kb < 999.95) printf "%.1f KB", kb
            else printf "%.1f MB", b / 1048576
        } else if (b < 1073741824) {
            mb = b / 1048576
            if (mb < 999.95) printf "%.1f MB", mb
            else printf "%.1f GB", b / 1073741824
        } else {
            printf "%.1f GB", b / 1073741824
        }
    }'
}

# Возвращает абсолютный путь.
_expl_normalize_path() {
    local input="$1"
    local -a stack=()
    local IFS='/'
    local -a parts=($input)
    local p
    for p in "${parts[@]}"; do
        case "$p" in
            ''|'.') continue ;;
            '..')
                local _sz=${#stack[@]}
                if [ "$_sz" -gt 0 ]; then unset "stack[$((_sz - 1))]"; fi
                ;;
            *) stack+=("$p") ;;
        esac
    done
    local result=""
    for p in "${stack[@]}"; do result="$result/$p"; done
    [ -z "$result" ] && result="/"
    printf '%s' "$result"
}

# Родительская папка.
_expl_parent() {
    local p="$1"
    [ "$p" = "/" ] && { echo "/"; return; }
    local parent=$(dirname "$p" 2>/dev/null)
    [ -z "$parent" ] && parent="/"
    echo "$parent"
}

# "свободно/всего UNIT" для пути.
_expl_df_size_str() {
    local path="$1"
    local unit="${2:-auto}"
    local _df_out=$(df -k "$path" 2>/dev/null | tail -1)
    [ -z "$_df_out" ] && { echo "—"; return; }
    
    local _total_kb=$(echo "$_df_out" | awk '{print $2}')
    local _free_kb=$(echo "$_df_out" | awk '{print $4}')
    case "$_total_kb" in ''|*[!0-9]*) echo "—"; return ;; esac
    case "$_free_kb"  in ''|*[!0-9]*) echo "—"; return ;; esac
    
    if [ "$unit" = "GB" ]; then
        local _tg=$(awk -v v="$_total_kb" 'BEGIN{printf "%.1f", v/1048576}')
        local _fg=$(awk -v v="$_free_kb"  'BEGIN{printf "%.1f", v/1048576}')
        printf "%s/%s GB" "$_fg" "$_tg"
    else
        local _tm=$((_total_kb / 1024))
        local _fm=$((_free_kb / 1024))
        printf "%s/%s MB" "$_fm" "$_tm"
    fi
}

# Перенос длинного пути на несколько строк по слэшам.
_expl_wrap_path() {
    local path="$1"
    local first_width="${2:-46}"
    local cont_indent="${3:-      }"
    [ -z "$path" ] && return 0
    if [ ${#path} -le "$first_width" ]; then printf '%s' "$path"; return 0; fi

    local result=""
    local remaining="$path"
    local indent=""
    local avail="$first_width"

    while [ -n "$remaining" ]; do
        if [ ${#remaining} -le "$avail" ]; then
            result="${result}${indent}${remaining}"
            break
        fi
        local chunk="${remaining:0:$avail}"
        local bp=-1
        local i
        for (( i=${#chunk}-1; i>=0; i-- )); do
            if [ "${chunk:$i:1}" = "/" ]; then bp=$i; break; fi
        done
        if [ "$bp" -gt 0 ]; then
            result="${result}${indent}${remaining:0:$((bp + 1))}"$'\n'
            remaining="${remaining:$((bp + 1))}"
        else
            result="${result}${indent}${chunk}"$'\n'
            remaining="${remaining:$avail}"
        fi
        indent="$cont_indent"
    done
    printf '%s' "$result"
}

# Проверка имени файла/папки.
_expl_sanitize_name() {
    local name="$1"
    case "$name" in ''|.|..) return 1 ;; -*) return 1 ;; esac
    case "$name" in */*|*\\*|*'|'*|*':'*|*'*'*|*'?'*|*'"'*|*'<'*|*'>'*|*'$'*|*'`'*) return 1 ;; esac
    [ ${#name} -le 255 ] || return 1
    return 0
}

# Размер файла ИЛИ папки в KB.
_expl_path_size_kb() {
    local path="$1"
    local bytes
    if [ -d "$path" ]; then
        if command -v timeout >/dev/null 2>&1; then
            bytes=$(timeout 5 du -sb "$path" 2>/dev/null | awk '{print $1}')
        else
            bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        fi
    else
        bytes=$(stat -c %s "$path" 2>/dev/null)
    fi
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    echo $((bytes / 1024))
}

# ==============================================================================
# 💾 РАЗДЕЛ 3: УСТРОЙСТВА И МОНТИРОВАНИЕ (USB / ROUTER)
# ==============================================================================

# Список всех точек монтирования USB/MMC.
_expl_find_all_usb_mounts() {
    [ -r /proc/mounts ] || return 1
    awk '
        $2 == "/" || $2 == "/rom" || $2 == "/overlay" { next }
        $3 == "proc" || $3 == "sysfs" || $3 == "tmpfs" || $3 == "devtmpfs" { next }
        $3 == "devpts" || $3 == "cgroup" || $3 == "cgroup2" { next }
        $3 == "debugfs" || $3 == "tracefs" || $3 == "pstore" { next }
        $3 == "squashfs" || $3 == "jffs2" || $3 == "ubifs" { next }
        $1 ~ /^\/dev\/sd/ || $1 ~ /^\/dev\/mmcblk/ { print $2 }
    ' /proc/mounts 2>/dev/null
}

# Первая USB-точка.
_expl_find_usb_mount() {
    _expl_find_all_usb_mounts | head -1
}

# Определяет устройство по пути: "router" или "usb".
_expl_detect_device() {
    local path="$1"
    local _m
    while IFS= read -r _m; do
        [ -z "$_m" ] && continue
        case "$path" in "$_m"|"$_m"/*) echo "usb"; return ;; esac
    done < <(_expl_find_all_usb_mounts)
    echo "router"
}

# Корень текущего устройства.
_expl_current_root() {
    local _dev=$(cat "$_EXPL_DEVICE_FILE" 2>/dev/null)
    if [ "$_dev" = "usb" ]; then _expl_find_usb_mount; else echo "/"; fi
}

# Запомнить последний путь.
_expl_save_device_path() {
    local path="$1"
    local _dev="$2"
    if [ "$_dev" = "usb" ]; then echo "$path" > /tmp/telegram_bot/explorer/last_usb_path
    elif [ "$_dev" = "router" ]; then echo "$path" > /tmp/telegram_bot/explorer/last_router_path; fi
}

# Достать сохранённый путь устройства.
_expl_get_device_path() {
    local _dev="$1"
    local _f="/tmp/telegram_bot/explorer/last_router_path"
    [ "$_dev" = "usb" ] && _f="/tmp/telegram_bot/explorer/last_usb_path"

    local _p=""
    [ -f "$_f" ] && _p=$(cat "$_f" 2>/dev/null | head -1)

    if [ -n "$_p" ] && [ -d "$_p" ]; then
        local _det=$(_expl_detect_device "$_p")
        if [ "$_det" = "$_dev" ]; then echo "$_p"; return 0; fi
    fi
    if [ "$_dev" = "usb" ]; then _expl_find_usb_mount; else echo "/"; fi
}

# Читаемое имя USB-флешки.
_expl_usb_display_name() {
    local mp="$1"
    local dev="" label=""
    dev=$(awk -v m="$mp" '$2 == m {print $1; exit}' /proc/mounts 2>/dev/null)
    if [ -n "$dev" ] && command -v block >/dev/null 2>&1; then
        label=$(block info "$dev" 2>/dev/null | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p' | head -1)
    fi
    [ -z "$label" ] && [ -n "$dev" ] && label=$(basename "$dev")
    [ -z "$label" ] && label="USB"
    printf '%s' "$label"
}

# ==============================================================================
# 📊 РАЗДЕЛ 4: ДАННЫЕ ФАЙЛОВОЙ СИСТЕМЫ (СПИСКИ, ИСТОРИЯ, ПАГИНАЦИЯ)
# ==============================================================================

# Читает содержимое папки.
_expl_get_entries() {
    local path="$1"
    [ -d "$path" ] || return 1

    local raw
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 15 stat -c '%F|%s|%n' "$path"/* "$path"/.[!.]* "$path"/..?* 2>/dev/null)
        if [ $? -eq 124 ]; then
            echo "$(date): _expl_get_entries: TIMEOUT, список файлов может быть неполным" >> /tmp/telegram_bot/logs/bot.log
        fi
    else
        raw=$(stat -c '%F|%s|%n' "$path"/* "$path"/.[!.]* "$path"/..?* 2>/dev/null)
    fi
    [ -z "$raw" ] && return 0

    {
        local ftype fsize fpath_rest name
        while IFS='|' read -r ftype fsize fpath_rest; do
            [ -z "$fpath_rest" ] && continue
            name="${fpath_rest##*/}"
            [ -z "$name" ] && continue
            case "$ftype" in
                directory) printf 'D|0|%s\n' "$name" ;;
                "symbolic link")
                    if [ -d "$fpath_rest" ]; then printf 'D|0|%s\n' "$name"
                    else printf 'F|%s|%s\n' "$fsize" "$name"; fi ;;
                *) printf 'F|%s|%s\n' "$fsize" "$name" ;;
            esac
        done <<< "$raw"
    } | awk -F'|' '
        {
            n = $3
            key = ""
            pos = 1
            len = length(n)
            while (pos <= len) {
                ch = substr(n, pos, 1)
                if (ch ~ /[0-9]/) {
                    num = ""
                    while (pos <= len && substr(n, pos, 1) ~ /[0-9]/) {
                        num = num substr(n, pos, 1)
                        pos++
                    }
                    while (length(num) < 10) num = "0" num
                    key = key num
                } else {
                    key = key ch
                    pos++
                }
            }
            printf "%s|%s|%s|%s\n", $1, $2, $3, key
        }
    ' | sort -t'|' -k1,1 -k4,4 | cut -d'|' -f1-3
}

# На какой странице окажется path.
_expl_page_for_path() {
    local path="$1"
    [ -z "$path" ] && { echo 1; return; }

    local dir=$(dirname "$path" 2>/dev/null)
    local base=$(basename "$path")
    [ -z "$dir" ] && { echo 1; return; }

    local entries=$(_expl_get_entries "$dir")
    [ -z "$entries" ] && { echo 1; return; }

    local i=0
    while IFS='|' read -r _type _size name; do
        [ -z "$name" ] && continue
        i=$((i + 1))
        if [ "$name" = "$base" ]; then
            echo $(( (i - 1) / _EXPL_PAGE_SIZE + 1 ))
            return 0
        fi
    done <<< "$entries"
    echo 1
}

# Положить путь в историю навигации.
_expl_push_history() {
    local path="$1"
    local last=""
    [ -s "$_EXPL_HISTORY_FILE" ] && last=$(tail -1 "$_EXPL_HISTORY_FILE" 2>/dev/null)
    [ "$last" = "$path" ] && return 0
    echo "$path" >> "$_EXPL_HISTORY_FILE"
    local total=$(wc -l < "$_EXPL_HISTORY_FILE" 2>/dev/null | tr -d ' ')
    if [ -n "$total" ] && [ "$total" -gt 20 ]; then
        tail -20 "$_EXPL_HISTORY_FILE" > "$_EXPL_HISTORY_FILE.tmp"
        mv "$_EXPL_HISTORY_FILE.tmp" "$_EXPL_HISTORY_FILE"
    fi
}

# ==============================================================================
# 📦 РАЗДЕЛ 5: АРХИВЫ И ПАКЕТЫ
# ==============================================================================

_expl_is_archive() {
    case "$1" in *.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tar|*.zip|*.7z) return 0 ;; esac
    return 1
}

_expl_is_package() {
    case "$1" in *.ipk|*.apk) return 0 ;; esac
    return 1
}

_expl_archive_ext() {
    case "$1" in
        *.tar.gz)  echo "tar.gz" ;;
        *.tgz)     echo "tar.gz" ;;
        *.tar.bz2) echo "tar.bz2" ;;
        *.tbz)     echo "tar.bz2" ;;
        *.tbz2)    echo "tar.bz2" ;;
        *.tar.xz)  echo "tar.xz" ;;
        *.txz)     echo "tar.xz" ;;
        *.tar.zst) echo "tar.zst" ;;
        *.tar)     echo "tar" ;;
        *.zip)     echo "zip" ;;
        *.7z)      echo "7z" ;;
        *)         echo "" ;;
    esac
}

_expl_archive_single_file() {
    local path="$1"
    local atype="$2"
    local _listing=""
    case "$atype" in
        tar.gz)  _listing=$(tar tzf "$path" 2>/dev/null) ;;
        tar.bz2) _listing=$(tar tjf "$path" 2>/dev/null) ;;
        tar.xz)  _listing=$(tar tJf "$path" 2>/dev/null) ;;
        tar.zst) _listing=$(tar --zstd -tf "$path" 2>/dev/null) ;;
        tar)     _listing=$(tar tf  "$path" 2>/dev/null) ;;
        zip)     _listing=$(unzip -Z1 "$path" 2>/dev/null) ;;
        7z)      _listing=$(7z l -slt "$path" 2>/dev/null | awk '/^Path = / {sub(/^Path = /,""); print}') ;;
        *) return 1 ;;
    esac
    [ -z "$_listing" ] && return 1

    local _count=$(printf '%s\n' "$_listing" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$_count" != "1" ] && return 1
    case "$_listing" in */) return 1 ;; esac
    printf '%s' "$_listing"
    return 0
}

_expl_get_unpacked_size_kb() {
    local path="$1"
    local atype="$2"
    local total_bytes=0

    case "$atype" in
        tar.gz)  total_bytes=$(tar tzvf "$path" 2>/dev/null | awk '{s+=$3} END {print s+0}') ;;
        tar.bz2) total_bytes=$(tar tjvf "$path" 2>/dev/null | awk '{s+=$3} END {print s+0}') ;;
        tar.xz)  total_bytes=$(tar tJvf "$path" 2>/dev/null | awk '{s+=$3} END {print s+0}') ;;
        tar.zst) total_bytes=$(tar --zstd -tvf "$path" 2>/dev/null | awk '{s+=$3} END {print s+0}') ;;
        tar)     total_bytes=$(tar tvf  "$path" 2>/dev/null | awk '{s+=$3} END {print s+0}') ;;
        zip)     total_bytes=$(unzip -l "$path" 2>/dev/null | awk 'NR>3 && $1 ~ /^[0-9]+$/ {sum+=$1} END {print sum+0}') ;;
        7z)      total_bytes=$(7z l -slt "$path" 2>/dev/null | awk '/^Size = / {s+=$3} END {print s+0}') ;;
    esac
    case "$total_bytes" in ''|*[!0-9]*) total_bytes=0 ;; esac
    echo $((total_bytes / 1024))
}

# ==============================================================================
# 🖥️ РАЗДЕЛ 6: ОТРИСОВКА ИНТЕРФЕЙСА
# ==============================================================================

_expl_send_or_edit() {
    local text="$1"
    local keyboard="$2"
    local explicit_msg_id="$3"
    _bot_dbg "$(date): SEND_OR_EDIT ENTER msg_id=$explicit_msg_id" >> /tmp/telegram_bot/logs/bot.log

    local msg_id="$explicit_msg_id"
    [ -z "$msg_id" ] && [ -f "$_EXPL_MSG_ID_FILE" ] && msg_id=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')

    if [ -n "$msg_id" ]; then
        local resp
        if [ -n "$keyboard" ]; then
            resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
                --data-urlencode text="$text" -d parse_mode="HTML" \
                --data-urlencode "reply_markup=$keyboard" 2>&1)
        else
            resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
                -d chat_id="$CHAT_ID" -d message_id="$msg_id" \
                --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
        fi
        _bot_dbg "$(date): SEND_OR_EDIT after edit attempt" >> /tmp/telegram_bot/logs/bot.log
        if echo "$resp" | grep -q '"ok":true'; then return 0; fi
        if echo "$resp" | grep -qi "message is not modified"; then return 0; fi
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$msg_id" >/dev/null 2>&1
        rm -f "$_EXPL_MSG_ID_FILE"
    fi

    _bot_dbg "$(date): SEND_OR_EDIT before sendMessage" >> /tmp/telegram_bot/logs/bot.log
    local resp
    if [ -n "$keyboard" ]; then
        resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" \
            --data-urlencode "reply_markup=$keyboard" 2>&1)
    else
        resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" --data-urlencode text="$text" -d parse_mode="HTML" 2>&1)
    fi
    if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
        local _err=$(echo "$resp" | jq -r '.description // "unknown"' 2>/dev/null)
        _bot_dbg "$(date): _expl_send_or_edit FAILED: $_err" >> /tmp/telegram_bot/logs/bot.log
    fi

    local new_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$new_id" ] && echo "$new_id" > "$_EXPL_MSG_ID_FILE"
    _bot_dbg "$(date): SEND_OR_EDIT EXIT" >> /tmp/telegram_bot/logs/bot.log
}

_expl_build_browser_keyboard() {
    local page="$1"
    local total_pages="$2"
    local start="$3"
    local end="$4"
    local total="$5"

    local -a _kb_rows=()

    if [ -f "$_EXPL_UNPACK_SELECT_FILE" ]; then
        if [ "$total" -gt 0 ]; then
            local _num_count=$(( end - start + 1 ))
            local _last_row_count=$(( _num_count % 8 ))
            [ "$_last_row_count" -eq 0 ] && _last_row_count=8
            local _last_row_start_num=$(( end - _last_row_count + 1 ))
            local cur_item=$start

            local need_back=0; [ "$page" -gt 1 ] && need_back=1
            local need_fwd=0; [ "$page" -lt "$total_pages" ] && need_fwd=1

            while [ "$cur_item" -lt "$_last_row_start_num" ]; do
                local btn_row=""
                local cnt=0
                while [ "$cur_item" -lt "$_last_row_start_num" ] && [ "$cnt" -lt 8 ]; do
                    [ -n "$btn_row" ] && btn_row="$btn_row,"
                    btn_row="$btn_row{\"text\":\"$cur_item\",\"callback_data\":\"expl_sel_$cur_item\"}"
                    cur_item=$((cur_item + 1))
                    cnt=$((cnt + 1))
                done
                [ -n "$btn_row" ] && _kb_rows+=("[$btn_row]")
            done

            local -a last_row_arr=()
            while [ "$cur_item" -le "$end" ]; do
                last_row_arr+=("{\"text\":\"$cur_item\",\"callback_data\":\"expl_sel_$cur_item\"}")
                cur_item=$((cur_item + 1))
            done

            if [ "$need_back" = "1" ]; then
                if [ ${#last_row_arr[@]} -eq 8 ]; then
                    last_row_arr[0]="{\"text\":\"⬅️\",\"callback_data\":\"expl_page_prev\"}"
                else
                    last_row_arr=("{\"text\":\"⬅️\",\"callback_data\":\"expl_page_prev\"}" "${last_row_arr[@]}")
                fi
            fi
            if [ "$need_fwd" = "1" ]; then
                if [ ${#last_row_arr[@]} -eq 8 ]; then
                    local last_idx=$(( ${#last_row_arr[@]} - 1 ))
                    last_row_arr[$last_idx]="{\"text\":\"➡️\",\"callback_data\":\"expl_page_next\"}"
                else
                    last_row_arr+=("{\"text\":\"➡️\",\"callback_data\":\"expl_page_next\"}")
                fi
            fi
            if [ ${#last_row_arr[@]} -gt 0 ]; then
                local IFS=","
                _kb_rows+=("[${last_row_arr[*]}]")
                unset IFS
            fi
        fi

        _kb_rows+=("[{\"text\":\"📂 Распаковать здесь\",\"callback_data\":\"expl_unpack_here\"},{\"text\":\"🚫 Отмена\",\"callback_data\":\"expl_unpack_cancel_select\"}]")

        local _cur_path=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
        local _root="/"
        local _nav2=""
        if [ "$_cur_path" != "$_root" ]; then
            _nav2="{\"text\":\"⬆️ Вверх\",\"callback_data\":\"expl_nav_up\"},"
        fi
        _nav2="$_nav2{\"text\":\"🏠 В корень\",\"callback_data\":\"expl_nav_home\"},"
        _nav2="$_nav2{\"text\":\"❌ Отмена\",\"callback_data\":\"expl_close\"}"
        _kb_rows+=("[$_nav2]")

        local _joined="" _r
        for _r in "${_kb_rows[@]}"; do [ -n "$_joined" ] && _joined="$_joined,"; _joined="$_joined$_r"; done
        echo "{\"inline_keyboard\":[$_joined]}"
        return 0
    fi

    if [ "$total" -gt 0 ]; then
        local _num_count=$(( end - start + 1 ))
        local _last_row_count=$(( _num_count % 8 ))
        [ "$_last_row_count" -eq 0 ] && _last_row_count=8
        local _last_row_start_num=$(( end - _last_row_count + 1 ))
        local cur_item=$start

        local need_back=0; [ "$page" -gt 1 ] && need_back=1
        local need_fwd=0; [ "$page" -lt "$total_pages" ] && need_fwd=1

        while [ "$cur_item" -lt "$_last_row_start_num" ]; do
            local btn_row=""
            local cnt=0
            while [ "$cur_item" -lt "$_last_row_start_num" ] && [ "$cnt" -lt 8 ]; do
                [ -n "$btn_row" ] && btn_row="$btn_row,"
                btn_row="$btn_row{\"text\":\"$cur_item\",\"callback_data\":\"expl_sel_$cur_item\"}"
                cur_item=$((cur_item + 1))
                cnt=$((cnt + 1))
            done
            [ -n "$btn_row" ] && _kb_rows+=("[$btn_row]")
        done

        local -a last_row_arr=()
        while [ "$cur_item" -le "$end" ]; do
            last_row_arr+=("{\"text\":\"$cur_item\",\"callback_data\":\"expl_sel_$cur_item\"}")
            cur_item=$((cur_item + 1))
        done

        if [ "$need_back" = "1" ]; then
            if [ ${#last_row_arr[@]} -eq 8 ]; then
                last_row_arr[0]="{\"text\":\"⬅️\",\"callback_data\":\"expl_page_prev\"}"
            else
                last_row_arr=("{\"text\":\"⬅️\",\"callback_data\":\"expl_page_prev\"}" "${last_row_arr[@]}")
            fi
        fi
        if [ "$need_fwd" = "1" ]; then
            if [ ${#last_row_arr[@]} -eq 8 ]; then
                local last_idx=$(( ${#last_row_arr[@]} - 1 ))
                last_row_arr[$last_idx]="{\"text\":\"➡️\",\"callback_data\":\"expl_page_next\"}"
            else
                last_row_arr+=("{\"text\":\"➡️\",\"callback_data\":\"expl_page_next\"}")
            fi
        fi
        if [ ${#last_row_arr[@]} -gt 0 ]; then
            local IFS=","
            _kb_rows+=("[${last_row_arr[*]}]")
            unset IFS
        fi
    fi

    if [ -s "$_EXPL_CLIPBOARD_FILE" ] || [ -s "$_EXPL_CUT_FILE" ]; then
        local _clip="{\"text\":\"📥 Вставить\",\"callback_data\":\"expl_paste\"},"
        _clip="$_clip{\"text\":\"🚫 Отмена\",\"callback_data\":\"expl_clip_cancel\"}"
        _kb_rows+=("[$_clip]")
    fi

    _kb_rows+=("[{\"text\":\"🔍 Поиск\",\"callback_data\":\"expl_search_start\"},{\"text\":\"📁 Создать\",\"callback_data\":\"expl_create_start\"}]")

    local _usb_mp=$(_expl_find_usb_mount)
    local _dev=$(cat "$_EXPL_DEVICE_FILE" 2>/dev/null)
    [ -z "$_dev" ] && _dev="router"

    local _ctrl1=""
    if [ -n "$_usb_mp" ]; then
        if [ "$_dev" = "usb" ]; then
            _ctrl1="{\"text\":\"К 📻 Роутеру\",\"callback_data\":\"expl_nav_switch\"},"
        else
            _ctrl1="{\"text\":\"К 💾 USB\",\"callback_data\":\"expl_nav_switch\"},"
        fi
    fi
    _ctrl1="$_ctrl1{\"text\":\"📤 Загрузить\",\"callback_data\":\"expl_upload_start\"},"
    _ctrl1="$_ctrl1{\"text\":\"🔄 Обновить\",\"callback_data\":\"expl_nav_refresh\"}"
    _kb_rows+=("[$_ctrl1]")

    local cur_path=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
    local _root
    if [ "$_dev" = "usb" ]; then _root="$_usb_mp"; else _root="/"; fi

    local _ctrl2=""
    if [ "$cur_path" = "$_root" ]; then
        if [ -n "$_usb_mp" ]; then
            _ctrl2="{\"text\":\"⬅️ Назад\",\"callback_data\":\"expl_nav_back\"},"
        fi
    else
        _ctrl2="{\"text\":\"⬆️ Вверх\",\"callback_data\":\"expl_nav_up\"},"
    fi
    _ctrl2="$_ctrl2{\"text\":\"🏠 В корень\",\"callback_data\":\"expl_nav_home\"},"
    _ctrl2="$_ctrl2{\"text\":\"❌ Закрыть\",\"callback_data\":\"expl_close\"}"
    _kb_rows+=("[$_ctrl2]")

    local _joined="" _r
    for _r in "${_kb_rows[@]}"; do [ -n "$_joined" ] && _joined="$_joined,"; _joined="$_joined$_r"; done
    echo "{\"inline_keyboard\":[$_joined]}"
}

_expl_build_actions_keyboard() {
    local type="$1"
    local name="${2:-}"
    local rows="["

    if [ "$type" = "D" ]; then
        rows="$rows[{\"text\":\"📂 Откр.\",\"callback_data\":\"expl_action_open\"},{\"text\":\"📋 Копир.\",\"callback_data\":\"expl_action_copy\"},{\"text\":\"✂️ Вырез.\",\"callback_data\":\"expl_action_cut\"},{\"text\":\"✏️ Имя\",\"callback_data\":\"expl_action_rename\"}],"
        rows="$rows[{\"text\":\"📦 Упаковать\",\"callback_data\":\"expl_action_pack\"},{\"text\":\"🗑️ Удалить\",\"callback_data\":\"expl_action_delete\"}],"
    else
        rows="$rows[{\"text\":\"👁 Просм.\",\"callback_data\":\"expl_action_view\"},{\"text\":\"📋 Копир.\",\"callback_data\":\"expl_action_copy\"},{\"text\":\"✂️ Вырез.\",\"callback_data\":\"expl_action_cut\"},{\"text\":\"✏️ Имя\",\"callback_data\":\"expl_action_rename\"}],"

        local _third=""
        if _expl_is_package "$name"; then
            _third="{\"text\":\"📦 Установить\",\"callback_data\":\"expl_action_install\"},"
        elif _expl_is_archive "$name"; then
            _third="{\"text\":\"📂 Распаковать\",\"callback_data\":\"expl_action_unpack\"},"
        else
            _third="{\"text\":\"📦 Упаковать\",\"callback_data\":\"expl_action_pack\"},"
        fi
        rows="$rows[${_third}{\"text\":\"🗑️ Удалить\",\"callback_data\":\"expl_action_delete\"},{\"text\":\"⬇️ Скачать\",\"callback_data\":\"expl_action_download\"}],"
    fi

    rows="$rows[{\"text\":\"⬅️ К списку\",\"callback_data\":\"expl_action_back\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"expl_close\"}]"
    rows="$rows]"
    echo "{\"inline_keyboard\":$rows}"
}

_expl_render_device_select() {
    local edit_msg_id="${1:-}"
    local -a _usb_list=()
    local _m
    while IFS= read -r _m; do [ -n "$_m" ] && _usb_list+=("$_m"); done < <(_expl_find_all_usb_mounts)

    if [ ${#_usb_list[@]} -eq 0 ]; then
        echo "router" > "$_EXPL_DEVICE_FILE"
        _expl_render_browser "/" 1 "$edit_msg_id"
        return
    fi

    echo "device_select" > "$_EXPL_MODE_FILE"
    echo "/" > "$_EXPL_ROUTER_ROOT_FILE"
    date +%s > "$_EXPL_LAST_ACTIVITY_FILE"

    local _hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    [ -z "$_hostname" ] && _hostname="Роутер"
    [ ${#_hostname} -gt 12 ] && _hostname="${_hostname:0:11}…"
    local _safe_host=$(html_escape "$_hostname")
    local _router_size=$(_expl_df_size_str "/" "MB")

    local _rows="" _row
    printf -v _row "%-2s %s %-13s %-14s %-14s" "1" "📻" "$_safe_host" "/" "$_router_size"
    _rows="${_row}"$'\n'

    local _idx=2
    for _mp in "${_usb_list[@]}"; do
        local _usb_display=$(_expl_usb_display_name "$_mp")
        [ ${#_usb_display} -gt 13 ] && _usb_display="${_usb_display:0:12}…"
        local _safe_usb_name=$(html_escape "$_usb_display")
        local _usb_path="$_mp"
        [ ${#_usb_path} -gt 13 ] && _usb_path="${_usb_path:0:12}…"
        local _safe_usb_path=$(html_escape "$_usb_path")
        local _usb_size=$(_expl_df_size_str "$_mp" "GB")

        printf -v _row "%-2s %s %-13s %-14s %-14s" "$_idx" "💾" "$_safe_usb_name" "$_safe_usb_path" "$_usb_size"
        _rows="${_rows}${_row}"$'\n'
        _idx=$((_idx + 1))
    done

    local msg="<pre>📁 ПРОВОДНИК — ВЫБОР УСТРОЙСТВА
${SEP46}
№  Устр.            Путь           Размер
-- ---------------  -------------  --------------
${_rows}${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')

Выберите устройство:</pre>"

    local _num_row=""
    for i in $(seq 1 $((_idx - 1))); do
        [ -n "$_num_row" ] && _num_row="$_num_row,"
        _num_row="${_num_row}{\"text\":\"$i\",\"callback_data\":\"expl_dev_$i\"}"
    done

    local keyboard="{\"inline_keyboard\":[[${_num_row}],[{\"text\":\"🔄 Обновить\",\"callback_data\":\"expl_dev_refresh\"},{\"text\":\"❌ Закрыть\",\"callback_data\":\"expl_close\"}]]}"
    _expl_send_or_edit "$msg" "$keyboard" "$edit_msg_id"
}

_expl_render_browser() {
    if [ -f "/tmp/telegram_bot/explorer_closed.flag" ]; then return 0; fi
    local path="$1"
    path=$(_expl_normalize_path "$path")
    [ -z "$path" ] && path="/"
    local page="${2:-1}"
    local edit_msg_id="${3:-}"

    if [ ! -d "$path" ]; then
        _expl_render_error "Папка не существует: $path"
        return 1
    fi

    local _dev=$(_expl_detect_device "$path")
    echo "$_dev" > "$_EXPL_DEVICE_FILE"
    echo "browse" > "$_EXPL_MODE_FILE"
    echo "$path" > "$_EXPL_CUR_PATH_FILE"
    date +%s > "$_EXPL_LAST_ACTIVITY_FILE"
    rm -f "$_EXPL_SEL_PATH_FILE" "$_EXPL_SEL_TYPE_FILE"
    _expl_save_device_path "$path" "$_dev"

    local entries=$(_expl_get_entries "$path")
    local total=0
    [ -n "$entries" ] && total=$(printf '%s\n' "$entries" | wc -l | tr -d ' ')
    [ -z "$total" ] && total=0

    local total_pages=$(( (total + _EXPL_PAGE_SIZE - 1) / _EXPL_PAGE_SIZE ))
    [ "$total_pages" -lt 1 ] && total_pages=1
    case "$page" in ''|*[!0-9]*) page=1 ;; esac
    [ "$page" -lt 1 ] && page=1
    [ "$page" -gt "$total_pages" ] && page="$total_pages"

    echo "$page" > "$_EXPL_PAGE_FILE"
    echo "$total_pages" > "$_EXPL_TOTAL_PAGES_FILE"

    local start=$(( (page - 1) * _EXPL_PAGE_SIZE + 1 ))
    local end=$(( page * _EXPL_PAGE_SIZE ))
    [ "$end" -gt "$total" ] && end="$total"

    declare -A _dir_sizes
    if [ "$total" -gt 0 ]; then
        local -a _paths_to_du=()
        declare -A _cache_map
        if [ -f "$_EXPL_DIR_SIZES_CACHE" ]; then
            while IFS='|' read -r c_path c_ts c_sz; do _cache_map["$c_path"]="$c_ts|$c_sz"; done < "$_EXPL_DIR_SIZES_CACHE"
        fi
        
        local _cnt=0
        local _now_ts=$(date +%s)
        while IFS='|' read -r type _size name; do
            [ -z "$name" ] && continue
            _cnt=$((_cnt + 1))
            [ "$_cnt" -lt "$start" ] && continue
            [ "$_cnt" -gt "$end" ] && break
            [ "$type" != "D" ] && continue

            local _full_p="$path/$name"
            local _c_data="${_cache_map[$_full_p]}"
            
            if [ -n "$_c_data" ]; then
                local _c_ts="${_c_data%|*}"
                local _c_sz="${_c_data#*|}"
                if [ $(( _now_ts - _c_ts )) -lt "$_EXPL_DIR_SIZES_TTL" ]; then
                    _dir_sizes["$name"]="$_c_sz"
                else
                    _paths_to_du+=("$_full_p")
                fi
            else
                _paths_to_du+=("$_full_p")
            fi
        done <<< "$entries"

        if [ ${#_paths_to_du[@]} -gt 0 ]; then
            local _du_out=""
            if command -v timeout >/dev/null 2>&1; then
                _du_out=$(timeout 3 du -sb "${_paths_to_du[@]}" 2>/dev/null)
            else
                _du_out=$(du -sb "${_paths_to_du[@]}" 2>/dev/null)
            fi
            
            if [ -n "$_du_out" ]; then
                while read -r d_sz d_p; do
                    [ -z "$d_sz" ] && continue
                    local d_name="${d_p##*/}"
                    _dir_sizes["$d_name"]="$d_sz"
                done <<< "$_du_out"

                (
                    flock -w 5 200 || exit 0
                    while read -r d_sz d_p; do
                        [ -z "$d_sz" ] && continue
                        echo "${d_p}|${_now_ts}|${d_sz}" >> "$_EXPL_DIR_SIZES_CACHE" 2>/dev/null
                    done <<< "$_du_out"
                    
                    local _total_lines=$(wc -l < "$_EXPL_DIR_SIZES_CACHE" 2>/dev/null | tr -d ' ')
                    if [ -n "$_total_lines" ] && [ "$_total_lines" -gt 200 ]; then
                        local _tmp="${_EXPL_DIR_SIZES_CACHE}.tmp.$$"
                        if tail -100 "$_EXPL_DIR_SIZES_CACHE" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
                            mv "$_tmp" "$_EXPL_DIR_SIZES_CACHE" 2>/dev/null
                        fi
                        rm -f "$_tmp" 2>/dev/null
                    fi
                ) 200>/var/lock/explorer_size_cache.lock
            fi
        fi
    fi

    local table_rows=""
    local n=0
    if [ "$total" -gt 0 ]; then
        while IFS='|' read -r type size name; do
            [ -z "$name" ] && continue
            n=$((n + 1))
            [ "$n" -lt "$start" ] && continue
            [ "$n" -gt "$end" ] && break

            local icon="📄"
            [ "$type" = "D" ] && icon="📁"

            local size_fmt="—"
            if [ "$type" = "F" ]; then
                size_fmt=$(_expl_format_size "$size")
            else
                local _dsz="${_dir_sizes[$name]}"
                [ -n "$_dsz" ] && size_fmt=$(_expl_format_size "$_dsz")
            fi

            local name_short="$name"
            [ ${#name_short} -gt 32 ] && name_short="${name_short:0:32}…"
            local safe_name=$(html_escape "$name_short")
            local pad=$((32 - ${#name_short}))
            [ "$pad" -lt 0 ] && pad=0
            local name_padded="$safe_name$(printf '%*s' "$pad" '')"

            printf -v row "%-4s %s %-33s  %-9s" "$n" "$icon" "$name_padded" "$size_fmt"
            table_rows="${table_rows}${row}"$'\n'
        done <<< "$entries"
    else
        table_rows="   (папка пуста)"$'\n'
    fi

    local header="📁 ПРОВОДНИК"
    [ "$total_pages" -gt 1 ] && header="📁 ПРОВОДНИК (стр. $page / $total_pages)"
    local _path_wrapped=$(_expl_wrap_path "$path" 49 "   ")
    local path_esc=$(html_escape "$_path_wrapped")

    local msg="<pre>${header}
${SEP46}
📂 ${path_esc}
${SEP46}
№    Имя                                   Размер
---- ------------------------------------  --------
${table_rows}
${SEP46}
🕒 $(date '+%Y-%m-%d %H:%M:%S')

Выберите элемент:</pre>"

    local keyboard=$(_expl_build_browser_keyboard "$page" "$total_pages" "$start" "$end" "$total")
    _expl_send_or_edit "$msg" "$keyboard" "$edit_msg_id"
}

_expl_render_error() {
    local text="$1"
    local safe=$(html_escape "$text")
    local msg="<pre>❌ ОШИБКА
${SEP46}
${SEP46}
${safe}
${SEP46}
${SEP46}</pre>"

    local keyboard
    if [ -f "$_EXPL_SEL_PATH_FILE" ]; then
        keyboard='{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"expl_error_back"},{"text":"📁 К списку","callback_data":"expl_action_back"}]]}'
    else
        keyboard='{"inline_keyboard":[[{"text":"⬅️ К списку","callback_data":"expl_action_back"},{"text":"❌ Закрыть","callback_data":"expl_close"}]]}'
    fi
    _expl_send_or_edit "$msg" "$keyboard" ""
}

_expl_show_actions() {
    if [ -f "/tmp/telegram_bot/explorer_closed.flag" ]; then return 0; fi
    local path="$1"
    path=$(_expl_normalize_path "$path")
    [ -z "$path" ] && path="/"
    local type="$2"
    local edit_msg_id="${3:-}"

    echo "$path" > "$_EXPL_SEL_PATH_FILE"
    echo "$type" > "$_EXPL_SEL_TYPE_FILE"
    date +%s > "$_EXPL_LAST_ACTIVITY_FILE"
    echo "actions" > "$_EXPL_MODE_FILE"

    local name=$(basename "$path")
    local safe_name=$(html_escape "$name")
    local parent=$(dirname "$path")
    local _parent_wrapped=$(_expl_wrap_path "$parent" 49 "   ")
    local parent_esc=$(html_escape "$_parent_wrapped")

    local info_type="Файл"
    local info_extra=""
    if [ "$type" = "D" ]; then
        info_type="Папка"
        local cnt=$(find "$path" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
        info_extra="Элементов внутри (файлы/папки): $cnt"
    fi

    local size_hr="—"
    if [ "$type" = "F" ]; then
        local sz=$(stat -c %s "$path" 2>/dev/null)
        [ -z "$sz" ] && sz=0
        size_hr=$(_expl_format_size "$sz")
    else
        local _du_out=""
        if command -v timeout >/dev/null 2>&1; then
            _du_out=$(timeout 3 du -sb "$path" 2>/dev/null)
            local _du_rc=$?
            if [ "$_du_rc" = "124" ]; then size_hr="считается…"; fi
        else
            _du_out=$(du -sb "$path" 2>/dev/null)
        fi
        if [ -n "$_du_out" ]; then
            local _dusz=$(echo "$_du_out" | awk '{print $1}')
            case "$_dusz" in ''|*[!0-9]*) : ;; *) size_hr=$(_expl_format_size "$_dusz") ;; esac
        fi
    fi

    local mtime=$(stat -c %y "$path" 2>/dev/null | cut -d'.' -f1)
    [ -z "$mtime" ] && mtime="—"

    local icon="📄"; [ "$type" = "D" ] && icon="📁"

    local _path_wrapped=$(_expl_wrap_path "$path")
    local _path_esc=$(html_escape "$_path_wrapped")

    local info_block="📂 ${parent_esc}
${SEP46}
${icon} ${safe_name}
Путь: ${_path_esc}
Тип: $info_type
Размер: $size_hr"
    [ -n "$info_extra" ] && info_block="${info_block}
$info_extra"
    info_block="${info_block}
Изменён: $mtime"

    local msg="<pre>📁 ПРОВОДНИК
${SEP46}
${info_block}
${SEP46}
Выберите действие:</pre>"

    local keyboard=$(_expl_build_actions_keyboard "$type" "$name")
    _expl_send_or_edit "$msg" "$keyboard" "$edit_msg_id"
}

# ==============================================================================
# ⚙️ РАЗДЕЛ 7: ДЕЙСТВИЯ НАД ФАЙЛАМИ (КОПИРОВАНИЕ, УДАЛЕНИЕ, АРХИВЫ)
# ==============================================================================

_expl_do_open_dir() {
    local path="$1"
    local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
    [ -n "$cur" ] && _expl_push_history "$cur"
    _expl_render_browser "$path" 1 ""
}

_expl_do_cut() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    echo "$path" > "$_EXPL_CUT_FILE"
    rm -f "$_EXPL_CLIPBOARD_FILE"
}

_expl_do_copy() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    echo "$path" > "$_EXPL_CLIPBOARD_FILE"
    rm -f "$_EXPL_CUT_FILE"
}

_expl_do_paste() {
    local target_dir="$1"
    local msg_id="${2:-}"
    local is_move=0
    local src=""

    if [ -s "$_EXPL_CUT_FILE" ]; then
        src=$(cat "$_EXPL_CUT_FILE" 2>/dev/null); is_move=1
    elif [ -s "$_EXPL_CLIPBOARD_FILE" ]; then
        src=$(cat "$_EXPL_CLIPBOARD_FILE" 2>/dev/null)
    else
        _expl_render_error "Буфер пуст"
        return
    fi

    src=$(_expl_normalize_path "$src")
    [ -z "$src" ] && src="/"
    [ -e "$src" ] || { _expl_render_error "Источник не найден: $src"; rm -f "$_EXPL_CLIPBOARD_FILE" "$_EXPL_CUT_FILE"; return; }

    local base=$(basename "$src")
    local dest="$target_dir/$base"
    dest=$(_expl_normalize_path "$dest")
    [ -z "$dest" ] && dest="/"

    if [ "$src" = "$dest" ]; then
        rm -f "$_EXPL_CLIPBOARD_FILE"
        echo "$src" > "$_EXPL_SAME_FOLDER_SRC_FILE"
        local _sf_esc=$(html_escape "$src")
        local msg="<pre>❌ Нельзя копировать файл в ту же папку
${SEP46}
${SEP46}
Источник: <code>$_sf_esc</code>
${SEP46}
${SEP46}
Файл/Папка уже находится в этой папке.
Используйте «📝 В новое имя», при следующей попытке 
или выберите другую папку.</pre>"
        local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_same_folder_back"}]]}'
        _expl_send_or_edit "$msg" "$keyboard" ""
        return 0
    fi

    local _src_kb=0
    if [ -d "$src" ]; then
        _src_kb=$(_expl_path_size_kb "$src")
    else
        local _sz=$(stat -c %s "$src" 2>/dev/null)
        case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
        _src_kb=$((_sz / 1024))
    fi

    local _free_kb=$(df -k "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    case "$_free_kb" in ''|*[!0-9]*) _free_kb=0 ;; esac

    if [ "$_src_kb" -gt 0 ] && [ "$_free_kb" -gt 0 ] && [ "$_free_kb" -lt "$_src_kb" ]; then
        local free_hr=$(awk -v v="$_free_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        local need_hr=$(awk -v v="$_src_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        _expl_render_error "Недостаточно места в целевой папке

Свободно: $free_hr
Нужно минимум: $need_hr

Освободите место и повторите."
        return
    fi

    if [ ! -e "$dest" ]; then
        _expl_paste_do "$src" "$dest" "copy" "$is_move" "$msg_id"
        return
    fi

    printf '%s\n%s\n%s\n' "$src" "$dest" "$is_move" > /tmp/telegram_bot/explorer/paste_state

    local _dest_wrapped_conflict=$(_expl_wrap_path "$dest" 46 "      ")
    local _type_desc
    if [ -d "$src" ]; then
        local _cnt=0; [ -d "$dest" ] && _cnt=$(ls -1A "$dest" 2>/dev/null | wc -l | tr -d ' ')
        local _dest_esc=$(html_escape "$_dest_wrapped_conflict")
        _type_desc="📁 Папка уже существует
$_dest_esc
Внутри: ${_cnt} элемент(ов)"
    else
        local _dest_esc=$(html_escape "$_dest_wrapped_conflict")
        _type_desc="📄 Файл уже существует
$_dest_esc"
    fi

    local _src_wrapped_conflict=$(_expl_wrap_path "$src" 42 "          ")
    local safe_src=$(html_escape "$_src_wrapped_conflict")

    local msg="<pre>📁 ПРОВОДНИК — ВСТАВКА
${SEP46}
${SEP46}
Источник: $safe_src

${_type_desc}
${SEP46}
${SEP46}
Как поступить?</pre>"

    local keyboard='{"inline_keyboard":[
[{"text":"♻️ Перезаписать","callback_data":"expl_paste_overwrite"},{"text":"⏭ Пропустить","callback_data":"expl_paste_skip"}],
[{"text":"📝 В новое имя","callback_data":"expl_paste_new"},{"text":"🔙 Отмена","callback_data":"expl_paste_cancel"}]
]}'
    _expl_send_or_edit "$msg" "$keyboard" ""
}

_expl_paste_do() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    local is_move="${4:-0}"
    local msg_id="${5:-}"

    local base=$(basename "$src")
    local rc=0
    local _T=""
    [ -n "$(command -v timeout)" ] && _T="timeout 120"

    if [ "$mode" = "new" ]; then
        local i=1
        local new_dest="${dest}_1"
        while [ -e "$new_dest" ] && [ "$i" -le 99 ]; do i=$((i + 1)); new_dest="${dest}_${i}"; done
        dest="$new_dest"
    fi

    if [ "$is_move" = "1" ]; then
        if [ "$mode" = "skip" ] && [ -e "$dest" ]; then
            rc=0
        elif [ -d "$src" ] && [ -d "$dest" ] && [ "$mode" = "overwrite" ]; then
            $_T cp -af "$src"/. "$dest"/ 2>/dev/null && $_T rm -rf "$src" 2>/dev/null || rc=$?
        else
            $_T mv -f "$src" "$dest" 2>/dev/null || rc=$?
        fi
        rm -f "$_EXPL_CUT_FILE"
    elif [ -d "$src" ]; then
        if [ -d "$dest" ] && [ "$mode" != "new" ]; then
            case "$mode" in
                overwrite) $_T cp -af "$src"/. "$dest"/ 2>/dev/null || rc=$? ;;
                skip)      $_T cp -an "$src"/. "$dest"/ 2>/dev/null || rc=$? ;;
            esac
        else
            $_T cp -a "$src" "$dest" 2>/dev/null || rc=$?
        fi
    else
        if [ -e "$dest" ] && [ "$mode" = "skip" ]; then rc=0
        else $_T cp -af "$src" "$dest" 2>/dev/null || rc=$?; fi
    fi

    rm -f /tmp/telegram_bot/explorer/paste_state

    if [ "$rc" != "0" ]; then _expl_render_error "Ошибка копирования (код $rc)"; return; fi

    rm -f "$_EXPL_CLIPBOARD_FILE" "$_EXPL_CUT_FILE"

    if [ "$is_move" = "1" ]; then
        if [ "$mode" = "skip" ] && [ -e "$dest" ]; then _EXPL_LAST_TOAST="⏭ Пропущено (уже существует)"
        elif [ "$mode" = "new" ]; then _EXPL_LAST_TOAST="✅ Перемещено (с новым именем)"
        else _EXPL_LAST_TOAST="✅ Перемещено"; fi
    else
        if [ "$mode" = "skip" ] && [ -e "$dest" ]; then _EXPL_LAST_TOAST="⏭ Пропущено (уже существует)"
        elif [ "$mode" = "new" ]; then _EXPL_LAST_TOAST="✅ Скопировано (с новым именем)"
        elif [ "$mode" = "overwrite" ]; then _EXPL_LAST_TOAST="♻️ Перезаписано"
        else _EXPL_LAST_TOAST="✅ Скопировано"; fi
    fi

    local _target_dir=$(dirname "$dest")
    [ -z "$_target_dir" ] || [ "$_target_dir" = "." ] && _target_dir="/"
    local _target_page=$(_expl_page_for_path "$dest")
    case "$_target_page" in ''|*[!0-9]*) _target_page=1 ;; esac

    _expl_render_browser "$_target_dir" "$_target_page" "$msg_id"
}

_expl_show_rename_dialog() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    local name=$(basename "$path")
    local safe=$(html_escape "$name")
    echo "1" > "$_EXPL_RENAME_MODE_FILE"
    echo "$path" > "$_EXPL_RENAME_TARGET_FILE"

    local _path_wrapped=$(_expl_wrap_path "$path" 46 "      ")
    local _path_esc=$(html_escape "$_path_wrapped")

    local msg="<pre>📁 ПРОВОДНИК — ПЕРЕИМЕНОВАНИЕ
${SEP46}
📄 $safe
Путь: ${_path_esc}
${SEP46}
✏️ Введите новое имя:

(только имя, без путей и слешей)
Пример: my_script.sh</pre>"
    local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_rename_cancel"}]]}'
    _expl_send_or_edit "$msg" "$keyboard" ""
}

_expl_handle_rename_text() {
    local new_name="$1"
    local target=$(cat "$_EXPL_RENAME_TARGET_FILE" 2>/dev/null)
    [ -z "$target" ] && { rm -f "$_EXPL_RENAME_MODE_FILE"; return 1; }

    if ! _expl_sanitize_name "$new_name"; then
        local msg="❌ <b>Недопустимое имя</b>

Нельзя: / \\ | : * ? &quot; &lt; &gt; &amp; \$ \`
Нельзя: начинать с . или -
Максимум 255 символов

Введите другое имя или нажмите Отмена."
        local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_rename_cancel"}]]}'
        _expl_send_or_edit "$msg" "$keyboard" ""
        return 0
    fi

    local dir=$(dirname "$target")
    local new_path="$dir/$new_name"
    if [ -e "$new_path" ] && [ "$new_path" != "$target" ]; then
        local _safe=$(html_escape "$new_name")
        local msg="❌ <b>Файл <code>$_safe</code> уже существует.</b>
Введите другое имя или нажмите Отмена."
        local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_rename_cancel"}]]}'
        _expl_send_or_edit "$msg" "$keyboard" ""
        return 0
    fi

    if ! mv "$target" "$new_path" 2>/dev/null; then
        rm -f "$_EXPL_RENAME_MODE_FILE" "$_EXPL_RENAME_TARGET_FILE"
        _expl_render_error "Ошибка переименования"
        return 1
    fi

    rm -f "$_EXPL_RENAME_MODE_FILE" "$_EXPL_RENAME_TARGET_FILE"

    if [ -n "$_IN_TEXT_MSG_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
        _IN_TEXT_MSG_ID=""
    fi

    local _old_msg=""
    [ -f "$_EXPL_MSG_ID_FILE" ] && _old_msg=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    if [ -n "$_old_msg" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_msg" >/dev/null 2>&1
        rm -f "$_EXPL_MSG_ID_FILE"
    fi

    local page=$(_expl_page_for_path "$new_path")
    case "$page" in ''|*[!0-9]*) page=1 ;; esac
    _expl_render_browser "$dir" "$page" ""
    return 0
}

_expl_show_delete_confirm() {
    local path="$1"
    local type="$2"
    local name=$(basename "$path")
    local safe=$(html_escape "$name")
    local icon="📄"; [ "$type" = "D" ] && icon="📁"

    local _norm=$(_expl_normalize_path "$path")
    [ -z "$_norm" ] && _norm="$path"

    local extra=""
    if [ "$type" = "D" ]; then
        local cnt=$(ls -1A "$path" 2>/dev/null | wc -l | tr -d ' ')
        [ "$cnt" -gt 0 ] && extra="⚠️ Внутри $cnt файлов — удалятся вместе с папкой"
    fi

    local _path_wrapped=$(_expl_wrap_path "$path" 46 "      ")
    local _path_esc=$(html_escape "$_path_wrapped")

    local _is_sys=0
    case "$_norm" in
        /|/bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/lib|/lib/*|/lib64|/lib64/*|\
        /etc|/etc/*|/var|/var/*|/www|/www/*|/root|/root/*|\
        /dev|/dev/*|/proc|/proc/*|/sys|/sys/*|\
        /rom|/rom/*|/overlay|/overlay/*) _is_sys=1 ;;
    esac

    local _sys_warning=""
    local keyboard=""

    if [ "$_is_sys" = "1" ]; then
        _sys_warning="
🚨 <b>ВНИМАНИЕ! ЭТО СИСТЕМНЫЙ ПУТЬ!</b>

Удаление этого файла или папки может:
• Нарушить работу сети (пропадет Wi-Fi/интернет)
• Привести к невозможности загрузить роутер ("кирпич")
• Сбросить настройки системы

Продолжайте только если вы АБСОЛЮТНО уверены
в том, что делаете."
        keyboard='{"inline_keyboard":[[{"text":"🚨 ДА, Я УВЕРЕН","callback_data":"expl_confirm_delete_yes"},{"text":"❌ Отмена","callback_data":"expl_confirm_delete_no"}]]}'
    else
        _sys_warning=""
        keyboard='{"inline_keyboard":[[{"text":"🗑️ Да, удалить","callback_data":"expl_confirm_delete_yes"},{"text":"❌ Отмена","callback_data":"expl_confirm_delete_no"}]]}'
    fi

    local msg="<pre>📁 ПРОВОДНИК — УДАЛЕНИЕ
${SEP46}
${SEP46}
${icon} ${safe}
Путь: ${_path_esc}"
    [ -n "$extra" ] && msg="${msg}
$extra"
    msg="${msg}
${SEP46}
${SEP46}${_sys_warning}
⚠️ Удалить безвозвратно?
Это действие нельзя отменить.</pre>"

    _expl_send_or_edit "$msg" "$keyboard" ""
}

_expl_do_delete() {
    local path="$1"
    [ -z "$path" ] && { _expl_render_error "Пустой путь"; return; }

    case "/$path/" in
        */../*) _expl_render_error "Запрещено: путь содержит компонент '..'"; return ;;
    esac

    local _norm=$(_expl_normalize_path "$path")
    [ -z "$_norm" ] && _norm="$path"

    case "$_norm" in
        /tmp/telegram_bot|/tmp/telegram_bot/*|\
        /tmp/.bot_*|/tmp/.exec_*|/tmp/.first_boot|/tmp/.offset_recovery_pending|\
        /tmp/exec_session|/tmp/exec_session/*|\
        /tmp/exec_output_state|/tmp/exec_output_state/*|\
        /tmp/explorer_*|/tmp/online_*|/tmp/bandix_*|\
        /tmp/known_macs_merged|/tmp/send_long_*)
            _expl_render_error "Запрещено удалять служебный файл бота:
$_norm"
            return ;;
        /etc/telegram_bot|/etc/telegram_bot/*)
            _expl_render_error "Запрещено удалять файл бота:
$_norm"
            return ;;
    esac

    if command -v timeout >/dev/null 2>&1; then
        if ! timeout 10 rm -rf "$_norm" 2>/dev/null; then _expl_render_error "Ошибка удаления или таймаут"; return; fi
    else
        if ! rm -rf "$_norm" 2>/dev/null; then _expl_render_error "Ошибка удаления"; return; fi
    fi

    local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
    local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
    case "$page" in ''|*[!0-9]*) page=1 ;; esac

    if [ "$_norm" = "$cur" ]; then
        cur=$(dirname "$cur")
        [ -z "$cur" ] || [ "$cur" = "." ] && cur="/"
    fi

    _expl_render_browser "$cur" "$page" ""
}

_expl_do_pack() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    if [ ! -e "$path" ]; then _expl_render_error "Файл или папка не найдены: $path"; return; fi

    case "$path" in
        /proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
            local _p_esc=$(html_escape "$path")
            _expl_render_error "Нельзя запаковать виртуальную ФС

Путь:
$_p_esc"
            return ;;
    esac

    local base=$(basename "$path")
    local parent=$(dirname "$path")
    [ -z "$parent" ] || [ "$parent" = "." ] && parent="/"

    local _dev=$(_expl_detect_device "$path")
    local _target_dir="/tmp"
    local _where_note="в /tmp (временная память)"

    if [ "$_dev" = "usb" ]; then
        _target_dir="$parent"
        _where_note="на USB ($_target_dir)"
    fi

    local _free_kb=$(df -k "$_target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    local _size_kb=$(_expl_path_size_kb "$path")
    case "$_free_kb" in ''|*[!0-9]*) _free_kb=0 ;; esac
    case "$_size_kb" in ''|*[!0-9]*) _size_kb=0 ;; esac
    local _need_kb=$(( _size_kb + _size_kb / 10 ))

    if [ "$_need_kb" -gt 0 ] && [ "$_free_kb" -gt 0 ] && [ "$_free_kb" -lt "$_need_kb" ]; then
        local _fh=$(awk -v v="$_free_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        local _sh=$(awk -v v="$_need_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        _expl_render_error "Недостаточно места ${_where_note}

Свободно:      $_fh
Нужно минимум: $_sh"
        return
    fi

    local archive="${_target_dir}/${base}.tar.gz"
    if [ -e "$archive" ]; then
        local i=1
        while [ -e "$archive" ] && [ "$i" -le 99 ]; do archive="${_target_dir}/${base}_${i}.tar.gz"; i=$((i + 1)); done
    fi
    rm -f "$archive"
    local _tar_err _tar_rc
    if command -v timeout >/dev/null 2>&1; then
        _tar_err=$(timeout 120 tar czf "$archive" -C "$parent" -- "$base" 2>&1 >/dev/null)
    else
        _tar_err=$(tar czf "$archive" -C "$parent" -- "$base" 2>&1 >/dev/null)
    fi
    _tar_rc=$?

    if [ "$_tar_rc" != "0" ]; then
        if [ "$_tar_rc" = "1" ] && [ -s "$archive" ]; then :; else
            local _reason=""
            case "$_tar_err" in
                *"No space left"*) _reason="Нет места в /tmp. Освободите раздел и повторите." ;;
                *"Permission denied"*) _reason="Нет прав на чтение одного из файлов внутри." ;;
                *"Read-only file system"*) _reason="Раздел только для чтения. Запаковка невозможна." ;;
                *"File changed as we read it"*) _reason="Файл изменялся во время чтения. Повторите попытку." ;;
                *"socket ignored"*) _reason="Внутри папки есть сокеты. Они пропущены, но архив создан." ;;
                *"Cannot stat"*) _reason="Один из файлов исчез во время архивации." ;;
                "") _reason="tar вернул код $_tar_rc без сообщения." ;;
                *) _reason="$_tar_err" ;;
            esac
            local _p_esc=$(html_escape "$path")
            local _reason_esc=$(html_escape "$_reason")
            _expl_render_error "Не удалось создать архив

Путь:
$_p_esc

Код tar: $_tar_rc
Причина: $_reason_esc"
            rm -f "$archive"
            return
        fi
    fi

    if [ ! -s "$archive" ]; then
        local _p_esc=$(html_escape "$path")
        _expl_render_error "Архив создан, но пустой (0 байт)

Путь:
$_p_esc"
        rm -f "$archive"
        return
    fi

    local sz=$(stat -c %s "$archive" 2>/dev/null); [ -z "$sz" ] && sz=0
    local size_hr=$(_expl_format_size "$sz")
    local safe_base=$(html_escape "$base")
    local _archive_wrapped=$(_expl_wrap_path "$archive" 46 "      ")
    local safe_archive=$(html_escape "$_archive_wrapped")

    printf '%s' "$archive" > "$_EXPL_LAST_ARCHIVE_FILE"

    local msg="<pre>✅ Архив создан
${SEP46}
${SEP46}
📦 ${safe_base}.tar.gz
Путь: $safe_archive
Размер: $size_hr
${SEP46}
${SEP46}</pre>"

    local keyboard='{"inline_keyboard":[
[{"text":"⬇️ Скачать","callback_data":"expl_archive_download"},{"text":"🗑️ Удалить архив","callback_data":"expl_archive_delete"}],
[{"text":"↩️ К списку","callback_data":"expl_archive_back"},{"text":"📂 К архиву","callback_data":"expl_archive_open"}]
]}'
    _expl_send_or_edit "$msg" "$keyboard" ""
}

_expl_do_unpack() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    if [ ! -f "$path" ]; then _expl_render_error "Файл не найден: $path"; return; fi

    local base=$(basename "$path")
    local atype=$(_expl_archive_ext "$base")
    if [ -z "$atype" ]; then _expl_render_error "Неизвестный формат архива: $base"; return; fi

    local need_tool=""
    case "$atype" in
        tar.gz)  command -v gzip  >/dev/null 2>&1 || need_tool="gzip" ;;
        tar.bz2) command -v bzip2 >/dev/null 2>&1 || need_tool="bzip2" ;;
        tar.xz)  command -v xz    >/dev/null 2>&1 || need_tool="xz-utils" ;;
        tar.zst) command -v zstd  >/dev/null 2>&1 || need_tool="zstd" ;;
        zip)     command -v unzip >/dev/null 2>&1 || need_tool="unzip" ;;
        7z)      command -v 7z    >/dev/null 2>&1 || need_tool="p7zip" ;;
    esac
    if [ -n "$need_tool" ]; then _expl_render_error "Для .${atype} нужен пакет: ${need_tool}
Установите: apk add ${need_tool}"; return; fi

    echo "$path" > "$_EXPL_UNPACK_SELECT_FILE"
    echo "unpack_select" > "$_EXPL_MODE_FILE"

    local _start_dir=$(dirname "$path")
    [ -d "$_start_dir" ] || _start_dir="/"
    _expl_render_browser "$_start_dir" 1 ""
}

_expl_is_dangerous_unpack_target() {
    local t=$(_expl_normalize_path "$1")
    [ -z "$t" ] && return 1
    case "$t" in
        /|/overlay|/overlay/*|/rom|/rom/*|/etc|/etc/*|\
        /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|\
        /www|/www/*|/var|/var/*) return 0 ;;
    esac
    return 1
}

_expl_unpack_needs_reboot() {
    case "$1" in /|/overlay|/overlay/*) return 0 ;; esac
    return 1
}

_expl_unpack_do() {
    local path="$1"
    local target=$(_expl_normalize_path "$2")
    [ -z "$target" ] && target="/"
    local mode="$3"

    local base=$(basename "$path")
    local atype=$(_expl_archive_ext "$base")
    local _single_file=$(_expl_archive_single_file "$path" "$atype")

    if [ "$mode" = "new" ]; then
        local i=1
        local new_target="${target}_1"
        while [ -e "$new_target" ] && [ "$i" -le 99 ]; do i=$((i + 1)); new_target="${target}_${i}"; done
        target="$new_target"
    fi

    if [ "$mode" = "skip" ] && [ -e "$target" ]; then
        rm -f /tmp/telegram_bot/explorer/unpack_state
        local safe_base=$(html_escape "$base")
        local _target_wrapped_skip=$(_expl_wrap_path "$target" 52 "   ")
        local safe_target=$(html_escape "$_target_wrapped_skip")
        local msg="<pre>⏭ Пропущено (уже существует)
${SEP46}
${SEP46}
📦 ${safe_base}
$safe_target
${SEP46}
${SEP46}</pre>"
        local keyboard='{"inline_keyboard":[[{"text":"↩️ К архиву","callback_data":"expl_error_back"}]]}'
        _expl_send_or_edit "$msg" "$keyboard" ""
        return
    fi

    local rc=0
    local _T=""
    [ -n "$(command -v timeout)" ] && _T="timeout 120"

    local _free_kb=$(df -k "$target" 2>/dev/null | tail -1 | awk '{print $4}')
    local _need_kb=$(_expl_get_unpacked_size_kb "$path" "$atype")
    
    if [ "$_need_kb" -eq 0 ]; then
        _need_kb=$(( $(_expl_path_size_kb "$path") * 5 ))
    else
        _need_kb=$(( _need_kb + _need_kb / 10 ))
    fi
    
    case "$_free_kb" in ''|*[!0-9]*) _free_kb=0 ;; esac
    case "$_need_kb" in ''|*[!0-9]*) _need_kb=0 ;; esac

    if [ "$_free_kb" -gt 0 ] && [ "$_need_kb" -gt 0 ] && [ "$_free_kb" -lt "$_need_kb" ]; then
        local _fh=$(awk -v v="$_free_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        local _sh=$(awk -v v="$_need_kb" 'BEGIN{printf "%.1f MB", v/1024}')
        _expl_render_error "Недостаточно места в целевой папке

Папка: $target
Свободно: $_fh
Нужно: $_sh"
        rm -f /tmp/telegram_bot/explorer/unpack_state
        return
    fi

    if [ -n "$_single_file" ]; then
        mkdir -p "$target" 2>/dev/null || { _expl_render_error "Не удалось создать папку: $target"; rm -f /tmp/telegram_bot/explorer/unpack_state; return; }
        local _sf_dir=$(dirname "$_single_file"); [ "$_sf_dir" = "." ] && _sf_dir=""

        case "$atype" in
            tar.gz)  $_T tar xzf "$path" -C "$target" -- "$_single_file" 2>/dev/null || rc=$? ;;
            tar.bz2) $_T tar xjf "$path" -C "$target" -- "$_single_file" 2>/dev/null || rc=$? ;;
            tar.xz)  $_T tar xJf "$path" -C "$target" -- "$_single_file" 2>/dev/null || rc=$? ;;
            tar.zst) $_T tar --zstd -xf "$path" -C "$target" -- "$_single_file" 2>/dev/null || rc=$? ;;
            tar)     $_T tar xf  "$path" -C "$target" -- "$_single_file" 2>/dev/null || rc=$? ;;
            zip)
                local _tmpd=$(mktemp -d /tmp/unpack_single_XXXXXX 2>/dev/null)
                if $_T unzip -q -o "$path" -d "$_tmpd" 2>/dev/null; then
                    [ -n "$_sf_dir" ] && mkdir -p "$target/$_sf_dir"
                    mv "$_tmpd/$_single_file" "$target/$_single_file" 2>/dev/null || rc=$?
                else rc=1; fi
                rm -rf "$_tmpd" ;;
            7z)
                local _tmpd=$(mktemp -d /tmp/unpack_single_XXXXXX 2>/dev/null)
                if $_T 7z x -y -o"$_tmpd" "$path" >/dev/null 2>&1; then
                    [ -n "$_sf_dir" ] && mkdir -p "$target/$_sf_dir"
                    mv "$_tmpd/$_single_file" "$target/$_single_file" 2>/dev/null || rc=$?
                else rc=1; fi
                rm -rf "$_tmpd" ;;
        esac
    else
        mkdir -p "$target" 2>/dev/null || { _expl_render_error "Не удалось создать папку: $target"; rm -f /tmp/telegram_bot/explorer/unpack_state; return; }
        local keep=0
        local skip_flag=""
        if [ "$mode" = "skip" ]; then
            case "$atype" in tar.*|tar) keep=1 ;; zip) skip_flag="-n" ;; esac
        fi

        case "$target" in
            /|/overlay|/overlay/*|/etc|/etc/*|/usr|/usr/*|\
            /bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|\
            /www|/www/*|/var|/var/*|/root|/root/*)
                local _tar_listing=""
                case "$atype" in
                    tar.gz)  _tar_listing=$(tar tzf "$path" 2>/dev/null) ;;
                    tar.bz2) _tar_listing=$(tar tjf "$path" 2>/dev/null) ;;
                    tar.xz)  _tar_listing=$(tar tJf "$path" 2>/dev/null) ;;
                    tar.zst) _tar_listing=$(tar --zstd -tf "$path" 2>/dev/null) ;;
                    tar)     _tar_listing=$(tar tf  "$path" 2>/dev/null) ;;
                esac
                if [ -n "$_tar_listing" ]; then
                    local _e _edir
                    while IFS= read -r _e; do
                        [ -z "$_e" ] && continue
                        case "$_e" in
                            */) mkdir -p "$target/$_e" 2>/dev/null ;;
                            *)  _edir=$(dirname "$_e"); [ "$_edir" != "." ] && mkdir -p "$target/$_edir" 2>/dev/null; touch "$target/$_e" 2>/dev/null ;;
                        esac
                    done <<< "$_tar_listing"
                fi ;;
        esac

        local _rc
        case "$atype" in
            tar.gz)  if [ "$keep" = "1" ]; then $_T tar xzkf "$path" -C "$target" 2>/dev/null; _rc=$?; [ "$_rc" -le 1 ] && _rc=0; else $_T tar xzf "$path" -C "$target" 2>/dev/null; _rc=$?; fi ;;
            tar.bz2) if [ "$keep" = "1" ]; then $_T tar xjkf "$path" -C "$target" 2>/dev/null; _rc=$?; [ "$_rc" -le 1 ] && _rc=0; else $_T tar xjf "$path" -C "$target" 2>/dev/null; _rc=$?; fi ;;
            tar.xz)  if [ "$keep" = "1" ]; then $_T tar xJkf "$path" -C "$target" 2>/dev/null; _rc=$?; [ "$_rc" -le 1 ] && _rc=0; else $_T tar xJf "$path" -C "$target" 2>/dev/null; _rc=$?; fi ;;
            tar.zst) if [ "$keep" = "1" ]; then $_T tar --zstd -xkf "$path" -C "$target" 2>/dev/null; _rc=$?; [ "$_rc" -le 1 ] && _rc=0; else $_T tar --zstd -xf "$path" -C "$target" 2>/dev/null; _rc=$?; fi ;;
            tar)     if [ "$keep" = "1" ]; then $_T tar xkf "$path" -C "$target" 2>/dev/null; _rc=$?; [ "$_rc" -le 1 ] && _rc=0; else $_T tar xf "$path" -C "$target" 2>/dev/null; _rc=$?; fi ;;
            zip)     $_T unzip -q -o $skip_flag "$path" -d "$target" 2>/dev/null; _rc=$? ;;
            7z)      $_T 7z x -y -o"$target" "$path" >/dev/null 2>&1; _rc=$? ;;
            *)       _rc=1 ;;
        esac
        rc=$_rc
    fi

    rm -f /tmp/telegram_bot/explorer/unpack_state
    if [ "$rc" != "0" ]; then _expl_render_error "Ошибка распаковки (код $rc)"; return; fi

    local safe_base=$(html_escape "$base")
    local _target_wrapped=$(_expl_wrap_path "$target" 46 "      ")
    local safe_target=$(html_escape "$_target_wrapped")
    local _msg

    if [ -n "$_single_file" ]; then
        local _fname_esc=$(html_escape "$_single_file")
        local _fsz=$(stat -c %s "$target" 2>/dev/null); [ -z "$_fsz" ] && _fsz=0
        local _fhr=$(_expl_format_size "$_fsz")
        _msg="<pre>✅ Файл распакован
${SEP46}
${SEP46}
📦 ${safe_base}
📄 $_fname_esc
Путь: $safe_target/$_fname_esc
Размер: $_fhr
${SEP46}
${SEP46}</pre>"
    else
        local _files=0
        local _listing=""
        case "$atype" in
            tar.gz)  _listing=$(tar tzf "$path" 2>/dev/null) ;;
            tar.bz2) _listing=$(tar tjf "$path" 2>/dev/null) ;;
            tar.xz)  _listing=$(tar tJf "$path" 2>/dev/null) ;;
            tar.zst) _listing=$(tar --zstd -tf "$path" 2>/dev/null) ;;
            tar)     _listing=$(tar tf  "$path" 2>/dev/null) ;;
            zip)     _listing=$(unzip -Z1 "$path" 2>/dev/null) ;;
            7z)      _listing=$(7z l -slt "$path" 2>/dev/null | awk '/^Path = / {sub(/^Path = /,""); print}') ;;
        esac
        if [ -n "$_listing" ]; then _files=$(printf '%s\n' "$_listing" | sed '/^$/d' | grep -cv '/$'); fi
        case "$_files" in ''|*[!0-9]*) _files=0 ;; esac

        local _arcsz=$(stat -c %s "$path" 2>/dev/null); case "$_arcsz" in ''|*[!0-9]*) _arcsz=0 ;; esac
        local _shr=$(_expl_format_size "$_arcsz")

        _msg="<pre>✅ Архив распакован
${SEP46}
${SEP46}
📦 ${safe_base}
📁 $safe_target
Файлов: ${_files}
Размер архива: $_shr
${SEP46}
${SEP46}</pre>"
    fi

    local _result_dir="$target"; [ -z "$_result_dir" ] && _result_dir="/"
    printf '%s' "$_result_dir" > "$_EXPL_UNPACK_RESULT_PATH_FILE"

    local keyboard='{"inline_keyboard":[[{"text":"📁 В проводник","callback_data":"expl_unpack_goto"},{"text":"↩️ К архиву","callback_data":"expl_error_back"}]]}'
    _expl_send_or_edit "$_msg" "$keyboard" ""
}

_expl_wrap_text() {
    local text="$1"
    local lim="${2:-52}"
    printf '%s\n' "$text" | LC_ALL=C awk -v lim="$lim" -v q="'" '
        function escape(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); gsub(q, "\\&#39;", s); return s }
        function vlen(s,    n, pos, rest, cols) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); if (rest ~ /^&amp;/) { cols += 1; pos += 5; continue } if (rest ~ /^&lt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&gt;/) { cols += 1; pos += 4; continue } if (rest ~ /^&quot;/) { cols += 1; pos += 6; continue } if (rest ~ /^&#39;/) { cols += 1; pos += 5; continue } if (rest ~ /^[\000-\177]/) { cols += 1; pos += 1; continue } if (rest ~ /^[\300-\337]/) { cols += 1; pos += 2; continue } if (rest ~ /^[\340-\357]/) { cols += 2; pos += 3; continue } if (rest ~ /^[\360-\367]/) { cols += 2; pos += 4; continue } cols += 1; pos += 1 } return cols }
        function cut_at_cols(s, k,    n, pos, rest, cols, step, colw) { n = length(s); pos = 1; cols = 0; while (pos <= n) { rest = substr(s, pos); step = 1; colw = 1; if (rest ~ /^&amp;/) { step = 5 } else if (rest ~ /^&lt;/) { step = 4 } else if (rest ~ /^&gt;/) { step = 4 } else if (rest ~ /^&quot;/) { step = 6 } else if (rest ~ /^&#39;/) { step = 5 } else if (rest ~ /^[\000-\177]/) { step = 1 } else if (rest ~ /^[\300-\337]/) { step = 2; colw = 1 } else if (rest ~ /^[\340-\357]/) { step = 3; colw = 2 } else if (rest ~ /^[\360-\367]/) { step = 4; colw = 2 } if (cols + colw > k) break; cols += colw; pos += step } return pos - 1 }
        function find_break(chunk,    i, lo, ch) { lo = length(chunk) - 40; if (lo < 1) lo = 1; for (i = length(chunk); i >= lo; i--) { if (substr(chunk, i, 1) == " ") return i "|sp" } for (i = length(chunk); i >= lo; i--) { ch = substr(chunk, i, 1); if (ch == "/" || ch == "-" || ch == ":" || ch == "[") return i "|sep" } return "0|none" }
        { esc = escape($0); add_indent = 0; while (length(esc) > 0) { prefix = (add_indent == 1) ? "   " : ""; avail = lim - vlen(prefix); if (vlen(esc) <= avail) { print prefix esc; break } cut = cut_at_cols(esc, avail); chunk = substr(esc, 1, cut); brk = find_break(chunk); split(brk, arr, "|"); bpos = arr[1] + 0; bmode = arr[2]; if (bpos > 0 && bmode == "sp") { print prefix substr(esc, 1, bpos - 1); esc = substr(esc, bpos + 1); add_indent = 0; continue } else if (bpos > 0 && bmode == "sep") { print prefix substr(esc, 1, bpos); esc = substr(esc, bpos + 1); add_indent = 0; continue } print prefix chunk; esc = substr(esc, cut + 1); add_indent = 1 } }'
}

_expl_do_install() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    if [ ! -f "$path" ]; then _expl_render_error "Файл не найден: $path"; return; fi

    local name=$(basename "$path")
    local ext=""
    case "$name" in *.*) ext="${name##*.}" ;; esac
    ext=$(printf '%s' "$ext" | tr 'A-Z' 'a-z')

    if [ "$ext" != "ipk" ] && [ "$ext" != "apk" ]; then _expl_render_error "Установка поддерживается только для .ipk и .apk"; return; fi

    local pkg_mgr=""
    if [ "$ext" = "ipk" ]; then
        if ! command -v opkg >/dev/null 2>&1; then _expl_render_error "Пакет .ipk, но opkg не найден в системе."; return; fi
        pkg_mgr="opkg"
    else
        if ! command -v apk >/dev/null 2>&1; then _expl_render_error "Пакет .apk, но apk не найден в системе."; return; fi
        pkg_mgr="apk"
    fi

    local sz=$(stat -c %s "$path" 2>/dev/null); [ -z "$sz" ] && sz=0
    local size_hr=$(_expl_format_size "$sz")
    local safe_name=$(html_escape "$name")

    local _prog_msg="<pre>📦 ПРОВОДНИК — УСТАНОВКА
${SEP46}
📄 ${safe_name}
Размер: ${size_hr}
Менеджер: ${pkg_mgr}
${SEP46}
⏳ Устанавливаю, это может занять до 2 минут...</pre>"
    _expl_send_or_edit "$_prog_msg" "" ""

    (
        exec 200>&- 2>/dev/null
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
        i=0
        while [ "$i" -lt 24 ]; do echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot; sleep 10 & wait $! 2>/dev/null; i=$((i + 1)); done
    ) &
    local _hb_pid=$!

    local _apk_sock="/tmp/telegram_bot/exec/apk_install.sock"
    local _apk_log="/tmp/telegram_bot/exec/apk_install.log"
    local _apk_cmd=""
    local rc=0
    local output=""

    if [ "$pkg_mgr" = "opkg" ]; then
        _apk_cmd="$(command -v opkg) install '$path'"
    else
        _apk_cmd="$(command -v apk) add --allow-untrusted '$path'"
    fi

    rm -f "$_apk_sock" "$_apk_log"
    
    setsid sexpect -sock "$_apk_sock" spawn -t 300 -nohup -nonblock -logfile "$_apk_log" /bin/sh -c "$_apk_cmd" </dev/null >/dev/null 2>&1 &
    
    local _wait_sec=0
    local _found_prompt=0
    local _prompt_text=""

    while [ "$_wait_sec" -lt 4 ]; do
        if grep -q "\[y/N\]\|\[Y/n\]\|(y/n)\|\[y/n\]" "$_apk_log" 2>/dev/null; then
            _found_prompt=1
            break
        fi
        sleep 1
        _wait_sec=$((_wait_sec + 1))
    done

    if [ "$_found_prompt" = "1" ]; then
        _prompt_text=$(tail -n 10 "$_apk_log" | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' | grep -v '^$' | tail -n 4)
        local _safe_prompt=$(html_escape "$_prompt_text")
        
        local _msg="<pre>⚠️ Пакет требует подтверждения:
${_safe_prompt}

Продолжить установку?</pre>"
        local _kb="{\"inline_keyboard\":[[{\"text\":\"✅ Да\",\"callback_data\":\"apk_ans_yes\"},{\"text\":\"❌ Нет\",\"callback_data\":\"apk_ans_no\"}]]}"
        
        echo "$_apk_sock" > /tmp/telegram_bot/exec/apk_wait_sock
        echo "$_apk_log" > /tmp/telegram_bot/exec/apk_wait_log
        echo "$path" > /tmp/telegram_bot/exec/apk_wait_path  # <--- ДОБАВЛЕНА ВОТ ЭТА СТРОКА
        
        if [ -n "$_hb_pid" ] && kill -0 "$_hb_pid" 2>/dev/null; then pkill -TERM -P "$_hb_pid" 2>/dev/null; kill -TERM "$_hb_pid" 2>/dev/null; fi
        echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot
        
        _expl_send_or_edit "$_msg" "$_kb" ""
        return
    fi
    
    sleep 2
    if ! sexpect -sock "$_apk_sock" expect -re "." -timeout 1 >/dev/null 2>&1; then rc=1; else rc=0; fi
    output=$(cat "$_apk_log" 2>/dev/null | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
    sexpect -sock "$_apk_sock" close >/dev/null 2>&1

    if [ -n "$_hb_pid" ] && kill -0 "$_hb_pid" 2>/dev/null; then
        pkill -TERM -P "$_hb_pid" 2>/dev/null; kill -TERM "$_hb_pid" 2>/dev/null; pkill -9 -P "$_hb_pid" 2>/dev/null; kill -9 "$_hb_pid" 2>/dev/null
    fi
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot

    local safe_output=$(_expl_wrap_text "$output" 52)
    if [ ${#safe_output} -gt 3000 ]; then safe_output="${safe_output:0:3000}… 
(вывод обрезан)"; fi
    local status_icon="✅"; [ "$rc" != "0" ] && status_icon="❌"
    local result_msg="<pre>${status_icon} УСТАНОВКА ЗАВЕРШЕНА (код $rc)
${SEP46}
📄 ${safe_name}
Менеджер: ${pkg_mgr}
${SEP46}
${safe_output}
${SEP46}</pre>"
    local keyboard="{\"inline_keyboard\":[[{\"text\":\"⬅️ К списку\",\"callback_data\":\"expl_action_back\"}]]}"
    _expl_send_or_edit "$result_msg" "$keyboard" ""
}

# ==============================================================================
# 🌐 РАЗДЕЛ 8: ОБМЕН С TELEGRAM (СКАЧИВАНИЕ, ПРОСМОТР, ЗАГРУЗКА)
# ==============================================================================

_expl_do_download() {
    local path=$(_expl_normalize_path "$1")
    [ -z "$path" ] && path="/"
    if [ ! -f "$path" ]; then _expl_render_error "Файл не найден"; return; fi

    local sz=$(stat -c %s "$path" 2>/dev/null); [ -z "$sz" ] && sz=0
    if [ "$sz" -gt 52428800 ]; then _expl_render_error "Файл больше 50 МБ — Telegram не примет.
Размер: $(_expl_format_size "$sz")"; return; fi

    local base=$(basename "$path")
    local safe_base=$(html_escape "$base")
    local size_hr=$(_expl_format_size "$sz")

    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" --data-urlencode text="⏳ Отправляю файл...
📄 ${safe_base} (${size_hr})" -d parse_mode="HTML" >/dev/null 2>&1

    local resp=$(curl -s --connect-timeout 10 --max-time 120 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" -F "chat_id=$CHAT_ID" -F "document=@${path}" 2>&1)
    if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
        local err=$(echo "$resp" | jq -r '.description // "unknown"' 2>/dev/null)
        _expl_render_error "Ошибка отправки: $err"
    fi
}

_expl_view_check() {
    local path="$1"
    if [ ! -f "$path" ]; then echo "Файл не найден"; return 1; fi

    case "$path" in
        *.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tar|\
        *.zip|*.7z|*.rar|*.ipk|*.apk|*.gz|*.xz|*.bz2|*.zst|*.lz4|\
        *.gif|*.webp|*.ico|*.mp3|*.mp4|*.avi|*.mkv|*.mov|*.wav|*.flac|*.ogg|\
        *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|\
        *.so|*.so.*|*.a|*.o|*.ko|*.bin|*.img|*.elf)
            echo "Просмотр недоступен (бинарный файл или архив).

Используйте ⬇️ Скачать, чтобы сохранить и открыть на устройстве."
            return 1 ;;
    esac

    local sz=$(stat -c %s "$path" 2>/dev/null); case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt 1048576 ]; then echo "Просмотр недоступен — файл больше 1 МБ.
Используйте ⬇️ Скачать."; return 1; fi

    if command -v file >/dev/null 2>&1; then
        local fdesc=$(file -b "$path" 2>/dev/null)
        case "$fdesc" in
            *ELF*|*executable*|*binary*|*data*|*"image data"*|*"compressed data"*|\
            *"gzip compressed"*|*"Zip archive"*|*"bzip2 compressed"*|*"XZ compressed"*|\
            *"POSIX tar archive"*|*"Mach-O"*|*"PE32"*)
                echo "Просмотр недоступен — файл определён как бинарный/архив.
Используйте ⬇️ Скачать."
                return 1 ;;
        esac
    else
        local _nulls=$(head -c 512 "$path" 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')
        case "$_nulls" in ''|*[!0-9]*) _nulls=0 ;; esac
        if [ "$_nulls" -gt 0 ]; then echo "Просмотр недоступен — файл содержит бинарные данные.
Используйте ⬇️ Скачать."; return 1; fi
    fi
    return 0
}

_expl_do_view() {
    local path="$1"
    if [ -f "$_EXPL_RETURN_FLAG" ] && [ -f "/tmp/telegram_bot/exec/output/msg_id.txt" ]; then
        _bot_dbg "$(date): _expl_do_view: view уже открыт, игнор" >> /tmp/telegram_bot/logs/bot.log
        return 0
    fi

    local _reason=$(_expl_view_check "$path")
    if [ $? -ne 0 ]; then _expl_render_error "$_reason"; return; fi

    local _prog_msg_id=$(send_message_and_get_id "⏳ <b>Читаю файл…</b>
<code>$(html_escape "$path")</code>")
    touch /tmp/telegram_bot/explorer/view_lock

    if ! _exec_session_active; then
        _exec_session_start || {
            [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" >/dev/null 2>&1
            _expl_render_error "Не удалось запустить /exec сессию"
            return
        }
    fi

    printf '%s' "$path" > "$_EXPL_RETURN_CONTEXT_FILE"
    touch "$_EXPL_RETURN_FLAG"

    local _qpath; printf -v _qpath '%q' "$path"
    local _display_cmd="cat $_qpath"

    _exec_session_send "$_display_cmd" 90
    local rc=$?

    case "$rc" in
        0|99)
            _exec_send_output "$_display_cmd" "$_EXEC_OUTPUT" "${_EXEC_LAST_RC:-0}" "$_prog_msg_id"
            rm -f /tmp/telegram_bot/explorer/view_lock ;;
        1|4)
            [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" >/dev/null 2>&1
            printf '%s' "$_display_cmd" > /tmp/telegram_bot/exec/session/last_cmd 2>/dev/null
            local _wait_msg_id=$(send_message_and_get_id "⏳ <b>Файл читается…</b>
Результат появится автоматически.")
            [ -n "$_wait_msg_id" ] && echo "$_wait_msg_id" > "$_EXEC_WAIT_MSG_FILE" ;;
        *)
            [ -n "$_prog_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_prog_msg_id" >/dev/null 2>&1
            _expl_render_error "Не удалось прочитать файл (rc=$rc)"
            rm -f "$_EXPL_RETURN_FLAG" /tmp/telegram_bot/explorer/view_lock ;;
    esac
}

_expl_show_upload_prompt() {
    local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
    local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
    [ -z "$cur" ] && cur="/"; [ -z "$page" ] && page=1

    echo "$cur" > "$_EXPL_UPLOAD_RETURN_PATH_FILE"
    echo "$page" > "$_EXPL_UPLOAD_RETURN_PAGE_FILE"

    local _bm_id=""
    [ -f "$_EXPL_MSG_ID_FILE" ] && _bm_id=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    if [ -n "$_bm_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_bm_id" >/dev/null 2>&1
        rm -f "$_EXPL_MSG_ID_FILE"
    fi

    echo "1" > "$_EXPL_UPLOAD_MODE_FILE"

    local _cur_wrapped=$(_expl_wrap_path "$cur" 49 "   ")
    local cur_esc=$(html_escape "$_cur_wrapped")
    local _dev=$(cat "$_EXPL_DEVICE_FILE" 2>/dev/null)
    local _dir_note="в <code>/tmp/</code> (временная память)"
    if [ "$_dev" = "usb" ]; then _dir_note="в текущую папку USB"; fi

    local msg="<pre>📁 ПРОВОДНИК — ЗАГРУЗКА
${SEP46}
📂 ${cur_esc}
${SEP46}
⏳ Ожидаю файл от вас

Отправьте файл, пакет opkg/apk в чат. Он сохранится
${_dir_note} с исходным именем.

Ограничения:
• Максимум 20 МБ (лимит Bot API)
• Имя файла: без / \\
${SEP46}</pre>"
    local keyboard='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_upload_cancel"}]]}'

    local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$keyboard" 2>&1)
    local _new_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$_new_id" ] && echo "$_new_id" > "$_EXPL_UPLOAD_PROMPT_MSG_FILE"
}

_expl_handle_document() {
    local doc_json="$1"
	local _up_err_kb='{"inline_keyboard":[[{"text":"❌ Закрыть","callback_data":"expl_upload_cancel"}]]}'
    local file_id=$(echo "$doc_json" | jq -r '.file_id // ""')
    local file_name=$(echo "$doc_json" | jq -r '.file_name // ""')
    local file_size=$(echo "$doc_json" | jq -r '.file_size // 0')

    if [ -z "$file_id" ] || [ -z "$file_name" ]; then send_message "⚠️ Файл без имени — не могу сохранить" "$_up_err_kb"; return; fi

    file_name=$(basename "$file_name")
    case "$file_name" in ''|.|..) send_message "⚠️ Неверное имя файла" "$_up_err_kb"; return ;; esac
    if [ "$file_size" -gt 20971520 ]; then send_message "❌ Файл больше 20 МБ (Bot API не даёт скачать)" "$_up_err_kb"; return; fi

    local resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/getFile" -d "file_id=$file_id" 2>&1)
    local file_path=$(echo "$resp" | jq -r '.result.file_path // ""')
    if [ -z "$file_path" ]; then send_message "❌ Не удалось получить путь файла от Telegram" "$_up_err_kb"; return; fi

    local _dev=$(cat "$_EXPL_DEVICE_FILE" 2>/dev/null)
    local target_dir="/tmp"
    local _is_tmp=1

    if [ "$_dev" = "usb" ]; then
        local _ret_path=$(cat "$_EXPL_UPLOAD_RETURN_PATH_FILE" 2>/dev/null)
        if [ -n "$_ret_path" ] && [ -d "$_ret_path" ]; then target_dir="$_ret_path"; _is_tmp=0
        else
            target_dir=$(_expl_find_usb_mount)
            if [ -n "$target_dir" ]; then _is_tmp=0; else target_dir="/tmp"; fi
        fi
    fi

    local dest="$target_dir/$file_name"
    if [ -e "$dest" ]; then
        local i=1
        while [ -e "$dest" ] && [ "$i" -le 99 ]; do dest="$target_dir/${file_name}_${i}"; i=$((i + 1)); done
    fi

    curl -s --connect-timeout 10 --max-time 60 "https://api.telegram.org/file/bot$BOT_TOKEN/$file_path" -o "$dest" 2>/dev/null
    if [ ! -s "$dest" ]; then send_message "❌ Ошибка загрузки файла" "$_up_err_kb"; rm -f "$dest"; return; fi

    local sz=$(stat -c %s "$dest" 2>/dev/null); [ -z "$sz" ] && sz=0
    local size_hr=$(_expl_format_size "$sz")
    local _dest_wrapped=$(_expl_wrap_path "$dest" 46 "      ")
    local safe_dest=$(html_escape "$_dest_wrapped")

    rm -f "$_EXPL_UPLOAD_MODE_FILE"

    local _up_id=""
    [ -f "$_EXPL_UPLOAD_PROMPT_MSG_FILE" ] && _up_id=$(cat "$_EXPL_UPLOAD_PROMPT_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
    if [ -n "$_up_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_up_id" >/dev/null 2>&1
        rm -f "$_EXPL_UPLOAD_PROMPT_MSG_FILE"
    fi

    echo "$dest" > "$_EXPL_UPLOAD_RESULT_PATH_FILE"

    local _footer=""
    if [ "$_is_tmp" = "1" ]; then _footer="💡 Файл во временной памяти /tmp.
При перезагрузке роутера исчезнет."; fi
local _result_msg="<pre>✅ Файл загружен
${SEP46}
${SEP46}
📄 $(html_escape "$file_name")
Путь: $safe_dest
Размер: $size_hr
${SEP46}
${SEP46}
${_footer}</pre>"
    local _result_kb='{"inline_keyboard":[[{"text":"📁 К списку","callback_data":"expl_upload_back"},{"text":"📄 К файлу","callback_data":"expl_upload_tofile"}]]}'

    local _resp=$(curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$_result_msg" -d parse_mode="HTML" --data-urlencode "reply_markup=$_result_kb" 2>&1)
    local _new_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$_new_id" ] && echo "$_new_id" > "$_EXPL_UPLOAD_RESULT_MSG_FILE"

    _bot_dbg "$(date): EXPL: upload result msg_id=$_new_id path=$dest" >> /tmp/telegram_bot/logs/bot.log
}

# ==============================================================================
# 🏁 РАЗДЕЛ 9: ЖИЗНЕННЫЙ ЦИКЛ (ВХОД, ЗАКРЫТИЕ, ВОЗВРАТ)
# ==============================================================================

_expl_close_view() {
    local _vm_id=""
    [ -f "/tmp/telegram_bot/exec/output/msg_id.txt" ] && _vm_id=$(cat /tmp/telegram_bot/exec/output/msg_id.txt 2>/dev/null | tr -d '\n\r ')
    if [ -n "$_vm_id" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_vm_id" >/dev/null 2>&1
    fi
    rm -rf /tmp/telegram_bot/exec/output 2>/dev/null
    rm -f "$_EXPL_RETURN_FLAG" "$_EXPL_RETURN_CONTEXT_FILE" /tmp/telegram_bot/explorer/view_lock 2>/dev/null
    _bot_dbg "$(date): _expl_close_view: закрыт просмотр (msg_id=$_vm_id)" >> /tmp/telegram_bot/logs/bot.log
}

_expl_return_from_exec() {
    if [ -f /tmp/telegram_bot/exec/output/msg_id.txt ]; then
        local _exec_msg_id=$(cat /tmp/telegram_bot/exec/output/msg_id.txt 2>/dev/null | tr -d '\n\r ')
        [ -n "$_exec_msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_exec_msg_id" >/dev/null 2>&1
    fi
    rm -rf /tmp/telegram_bot/exec/output 2>/dev/null

    local path=""
    [ -f "$_EXPL_RETURN_CONTEXT_FILE" ] && path=$(cat "$_EXPL_RETURN_CONTEXT_FILE" 2>/dev/null | head -1)

    if [ -z "$path" ] || [ ! -e "$path" ]; then
        local dir="/"
        if [ -n "$path" ]; then dir=$(dirname "$path"); [ -z "$dir" ] && dir="/"; fi
        rm -f "$_EXPL_RETURN_FLAG"

        local page=$(_expl_page_for_path "$path")
        case "$page" in ''|*[!0-9]*) page=1 ;; esac
        _expl_render_browser "$dir" "$page" ""
        return
    fi

    echo "$path" > "$_EXPL_SEL_PATH_FILE"
    if [ -d "$path" ]; then echo "D" > "$_EXPL_SEL_TYPE_FILE"; else echo "F" > "$_EXPL_SEL_TYPE_FILE"; fi
    rm -f "$_EXPL_RETURN_FLAG"

    local _cur_msg_id=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    local _sel_type=$(cat "$_EXPL_SEL_TYPE_FILE" 2>/dev/null)
    [ -z "$_sel_type" ] && _sel_type="F"

    _expl_show_actions "$path" "$_sel_type" "$_cur_msg_id"
}

show_explorer() {
    rm -f /tmp/telegram_bot/explorer_closed.flag
    if [ -f "/tmp/telegram_bot/state/bot_menu_msg_id" ]; then
        cat "/tmp/telegram_bot/state/bot_menu_msg_id" > "$_EXPL_MSG_ID_FILE"
        rm -f "/tmp/telegram_bot/state/bot_menu_msg_id"
    else
        if [ -f "$_EXPL_MSG_ID_FILE" ]; then
            local _old_id=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
            [ -n "$_old_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_old_id" >/dev/null 2>&1
            rm -f "$_EXPL_MSG_ID_FILE"
        fi
    fi

    rm -f "$_EXPL_HISTORY_FILE" "$_EXPL_CUR_PATH_FILE" "$_EXPL_SEL_PATH_FILE" \
          "$_EXPL_SEL_TYPE_FILE" "$_EXPL_PAGE_FILE" "$_EXPL_TOTAL_PAGES_FILE" \
          "$_EXPL_RENAME_MODE_FILE" "$_EXPL_RENAME_TARGET_FILE" "$_EXPL_UPLOAD_MODE_FILE" \
          "$_EXPL_RETURN_CONTEXT_FILE" "$_EXPL_ROUTER_ROOT_FILE" "$_EXPL_USB_ROOT_FILE"

    local _usb_mp=$(_expl_find_usb_mount)
    if [ -n "$_usb_mp" ]; then
        _expl_render_device_select ""
    else
        echo "router" > "$_EXPL_DEVICE_FILE"
        _expl_render_browser "/" 1 ""
    fi
}

_expl_close() {
    pkill -9 -f "du -sb" 2>/dev/null
    rm -f "$_EXPL_UNPACK_SELECT_FILE" "$_EXPL_UNPACK_CONFIRM_FILE" 2>/dev/null
    local msg_id=$(cat "$_EXPL_MSG_ID_FILE" 2>/dev/null | tr -d '\n\r ')
    [ -n "$msg_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$msg_id" >/dev/null 2>&1
    rm -rf /tmp/telegram_bot/explorer/* 2>/dev/null
    rm -f /tmp/telegram_bot/explorer/view_lock /tmp/telegram_bot/exec/return_to_explorer 2>/dev/null
    touch /tmp/telegram_bot/explorer_closed.flag
    send_menu
}

# ==============================================================================
# 🔄 РАЗДЕЛ 10: ОБРАБОТЧИКИ СОБЫТИЙ (CALLBACK И ТЕКСТ)
# ==============================================================================

_expl_handle_callback() {
    local cb="$1"
    local cb_id="$2"
    local msg_id="$3"
    local chat_id="$4"
    local _EXPL_LAST_TOAST=""

    _bot_dbg "$(date): EXPL: enter cb=$cb" >> /tmp/telegram_bot/logs/bot.log

    if [ -f "/tmp/telegram_bot/explorer/view_lock" ]; then
        _vl_stale=0

        _vl_now=$(date +%s)
        _vl_mt=$(stat -c %Y "/tmp/telegram_bot/explorer/view_lock" 2>/dev/null)
        case "$_vl_mt" in ''|*[!0-9]*) _vl_mt=$_vl_now ;; esac
        [ $((_vl_now - _vl_mt)) -gt 300 ] && _vl_stale=1

        if [ "$_vl_stale" = "0" ] && ! _exec_session_active; then
            _vl_stale=1
        fi

        if [ "$_vl_stale" = "1" ]; then
            rm -f "/tmp/telegram_bot/explorer/view_lock"
        else
            case "$cb" in
                expl_return_from_exec|expl_close) : ;;
                *)
                    curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" -d text="⏳ Файл открывается, подождите" >/dev/null 2>&1
                    return
                    ;;
            esac
        fi
    fi

    if [[ "$cb" == expl_* ]] && [ "$cb" != "expl_return_from_exec" ] && [ -f "$_EXPL_RETURN_FLAG" ] && [ -f "/tmp/telegram_bot/exec/output/msg_id.txt" ]; then
        if [ "$cb" = "expl_action_view" ]; then
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" -d text="📖 Файл уже открыт" >/dev/null 2>&1
            return
        fi
        _expl_close_view
    fi

    if [ "$chat_id" != "$CHAT_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" -d text="⛔ Доступ запрещён" >/dev/null 2>&1
        return
    fi

    date +%s > "$_EXPL_LAST_ACTIVITY_FILE"
    local _answer=""

    case "$cb" in
        expl_nav_up)
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            local _root=$(_expl_current_root)
            if [ "$cur" = "$_root" ]; then _answer="⏫ Уже в корне устройства"
            else
                local par=$(_expl_parent "$cur")
                _expl_render_browser "$par" 1 "$msg_id"
            fi ;;
        expl_nav_home)
            local _root=$(_expl_current_root)
            _expl_render_browser "$_root" 1 "$msg_id" ;;
        expl_nav_back)
            _expl_render_device_select "$msg_id" ;;
        expl_nav_switch)
            local _dev=$(cat "$_EXPL_DEVICE_FILE" 2>/dev/null)
            local _target_dev _target_path
            if [ "$_dev" = "usb" ]; then _target_dev="router"; else _target_dev="usb"; fi
            _target_path=$(_expl_get_device_path "$_target_dev")
            if [ -n "$_target_path" ] && [ -d "$_target_path" ]; then _expl_render_browser "$_target_path" 1 "$msg_id"
            else _answer="⚠️ Недоступно"; fi ;;
        expl_dev_refresh)
            _expl_render_device_select "$msg_id" ;;
        expl_dev_*)
            local _num="${cb#expl_dev_}"
            case "$_num" in
                ''|*[!0-9]*) _answer="⚠️ Неверный номер" ;;
                *)
                    if [ "$_num" = "1" ]; then _expl_render_browser "/" 1 "$msg_id"
                    else
                        local -a _arr=()
                        local _m
                        while IFS= read -r _m; do [ -n "$_m" ] && _arr+=("$_m"); done < <(_expl_find_all_usb_mounts)
                        local _i=$((_num - 2))
                        if [ "$_i" -ge 0 ] && [ "$_i" -lt "${#_arr[@]}" ]; then
                            local _mp="${_arr[$_i]}"
                            echo "$_mp" > "$_EXPL_USB_ROOT_FILE"
                            _expl_render_browser "$_mp" 1 "$msg_id"
                        else _answer="⚠️ USB не найдена"; _expl_render_device_select "$msg_id"; fi
                    fi ;;
            esac ;;
        expl_nav_refresh)
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null); [ -z "$page" ] && page=1
            _expl_render_browser "$cur" "$page" "$msg_id" ;;
        expl_page_prev)
            local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            [ -z "$page" ] && page=1; [ "$page" -gt 1 ] && page=$((page - 1))
            _expl_render_browser "$cur" "$page" "$msg_id" ;;
        expl_page_next)
            local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            local tp=$(cat "$_EXPL_TOTAL_PAGES_FILE" 2>/dev/null)
            [ -z "$page" ] && page=1; [ -z "$tp" ] && tp=1
            [ "$page" -lt "$tp" ] && page=$((page + 1))
            _expl_render_browser "$cur" "$page" "$msg_id" ;;
        expl_page_info)
            local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
            local tp=$(cat "$_EXPL_TOTAL_PAGES_FILE" 2>/dev/null)
            _answer="📄 Страница $page из $tp" ;;

        expl_sel_*)
            local num="${cb#expl_sel_}"
            case "$num" in ''|*[!0-9]*) return ;; esac
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            local entries=$(_expl_get_entries "$cur")
            local i=0; local sel_type="" sel_name=""
            while IFS='|' read -r t s n; do
                [ -z "$n" ] && continue
                i=$((i + 1))
                if [ "$i" = "$num" ]; then sel_type="$t"; sel_name="$n"; break; fi
            done <<< "$entries"

            if [ -f "$_EXPL_UNPACK_SELECT_FILE" ]; then
                if [ "$sel_type" = "D" ]; then
                    echo "$cur/$sel_name" > "$_EXPL_CUR_PATH_FILE"
                    _expl_render_browser "$cur/$sel_name" 1 "$msg_id"
                else _answer="⚠️ Выберите папку, а не файл"; fi
                return
            fi

            if [ -z "$sel_name" ]; then _answer="⚠️ Элемент не найден"
            else _expl_show_actions "$cur/$sel_name" "$sel_type" "$msg_id"; fi ;;

        expl_action_open)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -d "$path" ] && _expl_do_open_dir "$path" ;;
        expl_action_back)
            local _sel_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null | head -1)
            local _cur_path _page
            if [ -n "$_sel_path" ] && [ -e "$_sel_path" ]; then
                _cur_path=$(dirname "$_sel_path"); _page=$(_expl_page_for_path "$_sel_path")
            else
                _cur_path=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null | head -1)
                [ -z "$_cur_path" ] && _cur_path="/root"
                _page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null)
            fi
            case "$_page" in ''|*[!0-9]*) _page=1 ;; esac
            _expl_render_browser "$_cur_path" "$_page" "$msg_id" ;;
        expl_error_back)
            rm -f "$_EXPL_UNPACK_RESULT_PATH_FILE"
            local _sel_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            local _sel_type=$(cat "$_EXPL_SEL_TYPE_FILE" 2>/dev/null)
            if [ -n "$_sel_path" ] && [ -e "$_sel_path" ]; then
                [ -z "$_sel_type" ] && _sel_type="F"
                _expl_show_actions "$_sel_path" "$_sel_type" "$msg_id"
            else
                local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/root"
                _expl_render_browser "$cur" 1 "$msg_id"
            fi ;;
        expl_same_folder_back)
            local _sf_src=""
            [ -f "$_EXPL_SAME_FOLDER_SRC_FILE" ] && _sf_src=$(cat "$_EXPL_SAME_FOLDER_SRC_FILE" 2>/dev/null)
            rm -f "$_EXPL_SAME_FOLDER_SRC_FILE"
            local _parent _page
            if [ -n "$_sf_src" ] && [ -e "$_sf_src" ]; then _parent=$(dirname "$_sf_src"); _page=$(_expl_page_for_path "$_sf_src")
            else _parent=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_parent" ] && _parent="/"; _page=1; fi
            case "$_page" in ''|*[!0-9]*) _page=1 ;; esac
            _expl_render_browser "$_parent" "$_page" "$msg_id" ;;

        expl_action_copy)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            if [ -n "$path" ]; then
                _expl_do_copy "$path"; _answer="✅ Скопировано"
                _expl_render_browser "$(cat "$_EXPL_CUR_PATH_FILE")" 1 "$msg_id"
            fi ;;
        expl_action_cut)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            if [ -n "$path" ]; then
                _expl_do_cut "$path"; _answer="✂️ Вырезано"
                _expl_render_browser "$(cat "$_EXPL_CUR_PATH_FILE")" 1 "$msg_id"
            fi ;;
        expl_action_rename)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_show_rename_dialog "$path" ;;
        expl_action_delete)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            local type=$(cat "$_EXPL_SEL_TYPE_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_show_delete_confirm "$path" "$type" ;;
        expl_action_pack)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_do_pack "$path" ;;
        expl_action_unpack)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_do_unpack "$path" ;;

        expl_unpack_overwrite)
            if [ -f /tmp/telegram_bot/explorer/unpack_state ]; then
                local _a=$(sed -n '1p' /tmp/telegram_bot/explorer/unpack_state)
                local _t=$(sed -n '2p' /tmp/telegram_bot/explorer/unpack_state)
                [ -n "$_a" ] && [ -n "$_t" ] && _expl_unpack_do "$_a" "$_t" "overwrite"
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_unpack_skip)
            if [ -f /tmp/telegram_bot/explorer/unpack_state ]; then
                local _a=$(sed -n '1p' /tmp/telegram_bot/explorer/unpack_state)
                local _t=$(sed -n '2p' /tmp/telegram_bot/explorer/unpack_state)
                [ -n "$_a" ] && [ -n "$_t" ] && _expl_unpack_do "$_a" "$_t" "skip"
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_unpack_new)
            if [ -f /tmp/telegram_bot/explorer/unpack_state ]; then
                local _a=$(sed -n '1p' /tmp/telegram_bot/explorer/unpack_state)
                local _t=$(sed -n '2p' /tmp/telegram_bot/explorer/unpack_state)
                [ -n "$_a" ] && [ -n "$_t" ] && _expl_unpack_do "$_a" "$_t" "new"
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_unpack_here)
            local _up_archive=""
            [ -f "$_EXPL_UNPACK_SELECT_FILE" ] && _up_archive=$(cat "$_EXPL_UNPACK_SELECT_FILE" 2>/dev/null | head -1)
            local _up_target=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_up_target" ] && _up_target="/"

            if [ -z "$_up_archive" ] || [ ! -f "$_up_archive" ]; then
                rm -f "$_EXPL_UNPACK_SELECT_FILE" "$_EXPL_MODE_FILE"; _answer="⚠️ Архив не найден"; return
            fi

            if _expl_is_dangerous_unpack_target "$_up_target"; then
                printf '%s\n%s\n' "$_up_archive" "$_up_target" > "$_EXPL_UNPACK_CONFIRM_FILE"
                local _warn_extra=""
                if _expl_unpack_needs_reboot "$_up_target"; then _warn_extra="

⚠️ Для применения изменений потребуется
   ПЕРЕЗАГРУЗКА роутера (reboot)."; fi
                local _safe_target=$(html_escape "$_up_target")
                local _safe_archive=$(html_escape "$(basename "$_up_archive")")
local _warn_msg="<pre>⚠️ РАСПАКОВКА В СИСТЕМНЫЙ ПУТЬ

${SEP46}
Архив:   $_safe_archive
Папка:   $_safe_target
${SEP46}

Это может:
• затереть рабочие файлы,
• сломать настройки сети,
• привести роутер в нерабочее состояние.

Убедитесь, что архив содержит корректные данные
и вы понимаете последствия.${_warn_extra}

Продолжить?</pre>"
                local _warn_kb='{"inline_keyboard":[[{"text":"⚠️ Да, распаковать","callback_data":"expl_unpack_confirm_yes"},{"text":"🔙 Отмена","callback_data":"expl_unpack_confirm_no"}]]}'
                _expl_send_or_edit "$_warn_msg" "$_warn_kb" "$msg_id"
                return
            fi

            rm -f "$_EXPL_UNPACK_SELECT_FILE"
            local _free_kb=$(df -k "$_up_target" 2>/dev/null | tail -1 | awk '{print $4}')
            local _need_kb=$(_expl_get_unpacked_size_kb "$_up_archive" "$(_expl_archive_ext "$(basename "$_up_archive")")")
            
            if [ "$_need_kb" -eq 0 ]; then _need_kb=$(( $(_expl_path_size_kb "$_up_archive") * 5 )); else _need_kb=$(( _need_kb + _need_kb / 10 )); fi
            
            case "$_free_kb" in ''|*[!0-9]*) _free_kb=0 ;; esac
            case "$_need_kb" in ''|*[!0-9]*) _need_kb=0 ;; esac

            if [ "$_free_kb" -gt 0 ] && [ "$_need_kb" -gt 0 ] && [ "$_free_kb" -lt "$_need_kb" ]; then
                local _fh=$(awk -v v="$_free_kb" 'BEGIN{printf "%.1f MB", v/1024}')
                local _sh=$(awk -v v="$_need_kb" 'BEGIN{printf "%.1f MB", v/1024}')
            _expl_render_error "Недостаточно места в целевой папке

Папка: $_up_target
Свободно: $_fh
Нужно: $_sh

Распаковка отменена."
                return
            fi
            _expl_unpack_do "$_up_archive" "$_up_target" "overwrite" ;;
        expl_unpack_confirm_yes)
            local _cf_archive="" _cf_target=""
            if [ -f "$_EXPL_UNPACK_CONFIRM_FILE" ]; then
                _cf_archive=$(sed -n '1p' "$_EXPL_UNPACK_CONFIRM_FILE" 2>/dev/null)
                _cf_target=$(sed -n '2p' "$_EXPL_UNPACK_CONFIRM_FILE" 2>/dev/null)
            fi
            rm -f "$_EXPL_UNPACK_CONFIRM_FILE" "$_EXPL_UNPACK_SELECT_FILE"
            if [ -z "$_cf_archive" ] || [ ! -f "$_cf_archive" ] || [ -z "$_cf_target" ] || [ ! -d "$_cf_target" ]; then _answer="⚠️ Действие неактуально"; return; fi
            _expl_unpack_do "$_cf_archive" "$_cf_target" "overwrite" ;;
        expl_unpack_confirm_no)
            rm -f "$_EXPL_UNPACK_CONFIRM_FILE"; _answer="🚫 Отменено"
            local _no_cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_no_cur" ] && _no_cur="/"
            _expl_render_browser "$_no_cur" 1 "$msg_id" ;;
        expl_unpack_goto)
            local _ug_path=""
            [ -f "$_EXPL_UNPACK_RESULT_PATH_FILE" ] && _ug_path=$(cat "$_EXPL_UNPACK_RESULT_PATH_FILE" 2>/dev/null | head -1)
            rm -f "$_EXPL_UNPACK_RESULT_PATH_FILE"
            if [ -n "$_ug_path" ] && [ -d "$_ug_path" ]; then _expl_render_browser "$_ug_path" 1 "$msg_id"
            else _answer="⚠️ Папка распаковки не найдена"; _expl_render_browser "/tmp" 1 "$msg_id"; fi ;;
        expl_unpack_cancel_select)
            local _ucs_archive=""
            [ -f "$_EXPL_UNPACK_SELECT_FILE" ] && _ucs_archive=$(cat "$_EXPL_UNPACK_SELECT_FILE" 2>/dev/null | head -1)
            rm -f "$_EXPL_UNPACK_SELECT_FILE" "$_EXPL_MODE_FILE"; _answer="🚫 Распаковка отменена"
            if [ -n "$_ucs_archive" ] && [ -f "$_ucs_archive" ]; then _expl_show_actions "$_ucs_archive" "F" "$msg_id"; fi ;;
        expl_unpack_cancel)
            rm -f /tmp/telegram_bot/explorer/unpack_state
            local _sel_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            local _sel_type=$(cat "$_EXPL_SEL_TYPE_FILE" 2>/dev/null)
            if [ -n "$_sel_path" ] && [ -e "$_sel_path" ]; then
                [ -z "$_sel_type" ] && _sel_type="F"
                _expl_show_actions "$_sel_path" "$_sel_type" "$msg_id"
            else
                local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/root"
                _expl_render_browser "$cur" 1 "$msg_id"
            fi ;;

        expl_action_view)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            if [ -n "$path" ]; then
                local _is_image=0
                if [ -f "$path" ]; then
                    local _magic=$(head -c 4 "$path" 2>/dev/null | hexdump -v -e '/1 "%02x"')
                    case "$_magic" in 89504e47*|ffd8ff*|47494638*) _is_image=1 ;; esac
                fi
                if [ "$_is_image" = "0" ] && command -v file >/dev/null 2>&1; then
                    local _fdesc=$(file -b "$path" 2>/dev/null | tr 'A-Z' 'a-z')
                    case "$_fdesc" in *image*|*jpeg*|*png*|*gif*) _is_image=1 ;; esac
                fi
                case "$path" in *.jpg|*.jpeg|*.png|*.gif) _is_image=1 ;; esac

                if [ "$_is_image" = "1" ]; then
                    local sz=$(stat -c %s "$path" 2>/dev/null); [ -z "$sz" ] && sz=0
                    if [ "$sz" -gt 10485760 ]; then _answer="⚠️ Файл больше 10 МБ. Используйте ⬇️ Скачать."
                    else
                        _answer="⏳ Отправляю фото..."
                        (
                            exec 200>&- 2>/dev/null
                            local resp=$(curl -s --connect-timeout 10 --max-time 60 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -F "chat_id=$CHAT_ID" -F "photo=@${path}" 2>&1)
                            if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
                                local err=$(echo "$resp" | jq -r '.description // "unknown"' 2>/dev/null)
                                send_message "❌ Ошибка отправки фото: $err" '{"inline_keyboard":[[{"text":"⬅️ Назад","callback_data":"expl_action_back"}]]}'
                            fi
                        ) &
                    fi
                else _expl_do_view "$path"; fi
            fi ;;
        expl_action_download)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_do_download "$path" ;;
        expl_action_install)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            if [ -n "$path" ]; then
                local base=$(basename "$path")
                local safe_base=$(html_escape "$base")
                                local text="⚠️ <b>Установка пакета</b>

Вы действительно хотите установить пакет:
<code>${safe_base}</code>?"
                local kb='{"inline_keyboard":[[{"text":"✅ Да, установить","callback_data":"expl_install_confirm"},{"text":"❌ Отмена","callback_data":"expl_action_back"}]]}'
                _expl_send_or_edit "$text" "$kb" "$msg_id"
            fi ;;
        expl_install_confirm)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            if [ -n "$path" ] && [ -f "$path" ]; then _expl_do_install "$path"
            else _expl_render_error "Файл не найден или был удалён"; fi ;;

        expl_confirm_delete_yes)
            local path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -n "$path" ] && _expl_do_delete "$path" ;;
        expl_confirm_delete_no)
            local _sel_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            local _cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_cur" ] && _cur="/"
            local _page
            if [ -n "$_sel_path" ] && [ -e "$_sel_path" ]; then _page=$(_expl_page_for_path "$_sel_path")
            else _page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null); fi
            case "$_page" in ''|*[!0-9]*) _page=1 ;; esac
            _expl_render_browser "$_cur" "$_page" "$msg_id" ;;
        expl_rename_cancel)
            local _rt_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            [ -z "$_rt_path" ] && _rt_path=$(cat "$_EXPL_RENAME_TARGET_FILE" 2>/dev/null)
            rm -f "$_EXPL_RENAME_MODE_FILE" "$_EXPL_RENAME_TARGET_FILE"
            local _rt_dir _rt_page
            if [ -n "$_rt_path" ] && [ -e "$_rt_path" ]; then _rt_dir=$(dirname "$_rt_path"); _rt_page=$(_expl_page_for_path "$_rt_path")
            else _rt_dir=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_rt_dir" ] && _rt_dir="/"; _rt_page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null); fi
            case "$_rt_page" in ''|*[!0-9]*) _rt_page=1 ;; esac
            _expl_render_browser "$_rt_dir" "$_rt_page" "$msg_id" ;;

        expl_archive_download)
            local archive=""
            [ -f /tmp/telegram_bot/explorer/last_archive ] && archive=$(cat /tmp/telegram_bot/explorer/last_archive 2>/dev/null)
            if [ -z "$archive" ]; then
                local base=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null | xargs -r basename)
                archive="/tmp/telegram_bot/explorer/archive_${base}.tar.gz"
            fi
            [ -f "$archive" ] && _expl_do_download "$archive" ;;
        expl_archive_open)
            local archive=""
            [ -f /tmp/telegram_bot/explorer/last_archive ] && archive=$(cat /tmp/telegram_bot/explorer/last_archive 2>/dev/null)
            if [ -z "$archive" ] || [ ! -f "$archive" ]; then _answer="⚠️ Архив не найден"
            else _expl_show_actions "$archive" "F" "$msg_id"; fi ;;
        expl_archive_delete)
            local archive=""
            if [ -f "/tmp/telegram_bot/explorer/last_archive" ]; then archive=$(cat "/tmp/telegram_bot/explorer/last_archive" 2>/dev/null | tr -d '\n\r '); fi
            if [ -n "$archive" ] && [ -f "$archive" ]; then rm -f "$archive"; fi
            rm -f "/tmp/telegram_bot/explorer/last_archive"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/root"
            _expl_render_browser "$cur" 1 "$msg_id" ;;
        expl_archive_back)
            local _sel_path=$(cat "$_EXPL_SEL_PATH_FILE" 2>/dev/null)
            local _cur _page
            if [ -n "$_sel_path" ] && [ -e "$_sel_path" ]; then _cur=$(dirname "$_sel_path"); _page=$(_expl_page_for_path "$_sel_path")
            else _cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_cur" ] && _cur="/"; _page=1; fi
            case "$_page" in ''|*[!0-9]*) _page=1 ;; esac
            _expl_render_browser "$_cur" "$_page" "$msg_id" ;;

        expl_paste)
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null)
            if [ -n "$cur" ]; then
                _expl_do_paste "$cur" "$msg_id"
                if [ -f /tmp/telegram_bot/explorer/paste_state ]; then _answer=""
                else _answer="${_EXPL_LAST_TOAST:-✅ Вставлено}"; fi
            fi ;;
        expl_paste_overwrite)
            if [ -f /tmp/telegram_bot/explorer/paste_state ]; then
                local _src=$(sed -n '1p' /tmp/telegram_bot/explorer/paste_state)
                local _dst=$(sed -n '2p' /tmp/telegram_bot/explorer/paste_state)
                local _mv=$(sed -n '3p' /tmp/telegram_bot/explorer/paste_state); [ -z "$_mv" ] && _mv=0
                if [ -n "$_src" ] && [ -n "$_dst" ]; then _expl_paste_do "$_src" "$_dst" "overwrite" "$_mv" "$msg_id"; _answer="${_EXPL_LAST_TOAST}"
                else _answer="⏳ Действие неактуально"; fi
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_paste_skip)
            if [ -f /tmp/telegram_bot/explorer/paste_state ]; then
                local _src=$(sed -n '1p' /tmp/telegram_bot/explorer/paste_state)
                local _dst=$(sed -n '2p' /tmp/telegram_bot/explorer/paste_state)
                local _mv=$(sed -n '3p' /tmp/telegram_bot/explorer/paste_state); [ -z "$_mv" ] && _mv=0
                if [ -n "$_src" ] && [ -n "$_dst" ]; then _expl_paste_do "$_src" "$_dst" "skip" "$_mv" "$msg_id"; _answer="${_EXPL_LAST_TOAST}"
                else _answer="⏳ Действие неактуально"; fi
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_paste_new)
            if [ -f /tmp/telegram_bot/explorer/paste_state ]; then
                local _src=$(sed -n '1p' /tmp/telegram_bot/explorer/paste_state)
                local _dst=$(sed -n '2p' /tmp/telegram_bot/explorer/paste_state)
                local _mv=$(sed -n '3p' /tmp/telegram_bot/explorer/paste_state); [ -z "$_mv" ] && _mv=0
                if [ -n "$_src" ] && [ -n "$_dst" ]; then _expl_paste_do "$_src" "$_dst" "new" "$_mv" "$msg_id"; _answer="${_EXPL_LAST_TOAST}"
                else _answer="⏳ Действие неактуально"; fi
            else _answer="⏳ Действие неактуально"; fi ;;
        expl_paste_cancel)
            rm -f /tmp/telegram_bot/explorer/paste_state
            local _clip_src=$(cat "$_EXPL_CLIPBOARD_FILE" 2>/dev/null)
            local _parent _page
            if [ -n "$_clip_src" ] && [ -e "$_clip_src" ]; then _parent=$(dirname "$_clip_src"); _page=$(_expl_page_for_path "$_clip_src")
            else _parent=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_parent" ] && _parent="/"; _page=1; fi
            case "$_page" in ''|*[!0-9]*) _page=1 ;; esac
            _expl_render_browser "$_parent" "$_page" "$msg_id" ;;
        expl_clip_cancel)
            rm -f "$_EXPL_CLIPBOARD_FILE" "$_EXPL_CUT_FILE"; _answer="🚫 Буфер очищен"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/root"
            local page=$(cat "$_EXPL_PAGE_FILE" 2>/dev/null); [ -z "$page" ] && page=1
            _expl_render_browser "$cur" "$page" "$msg_id" ;;

        expl_search_start)
            echo "search" > "$_EXPL_SEARCH_MODE_FILE"; rm -f "$_EXPL_CREATE_MODE_FILE"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
            echo "$cur" > /tmp/telegram_bot/explorer/search_origin
            local prompt="🔍 <b>Поиск файлов и папок</b>

Введите запрос для поиска в <code>$cur</code>.
Поиск происходит рекурсивно в этой папке."
            local kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_search_cancel"}]]}'
            _expl_send_or_edit "$prompt" "$kb" "$msg_id"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" >/dev/null 2>&1
            return 0 ;;
        expl_create_start)
            echo "create" > "$_EXPL_CREATE_MODE_FILE"; rm -f "$_EXPL_SEARCH_MODE_FILE"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
            local prompt="📁 <b>Создание папки. Введите имя.</b>
Папка будет создана в <code>$cur</code>."
            local kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_create_cancel"}]]}'
            _expl_send_or_edit "$prompt" "$kb" "$msg_id"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" >/dev/null 2>&1
            return 0 ;;
        expl_search_cancel|expl_create_cancel)
            rm -f "$_EXPL_SEARCH_MODE_FILE" "$_EXPL_CREATE_MODE_FILE"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
            _expl_render_browser "$cur" 1 "$msg_id"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" >/dev/null 2>&1
            return 0 ;;
        expl_search_sel_*)
            local num="${cb#expl_search_sel_}"
            local fullpath=$(sed -n "${num}p" "$_EXPL_SEARCH_RESULT_FILE" 2>/dev/null)
            if [ -n "$fullpath" ] && [ -e "$fullpath" ]; then
                local type="F"; [ -d "$fullpath" ] && type="D"
                _expl_show_actions "$fullpath" "$type" "$msg_id"
            else
                curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" -d text="⚠️ Элемент не найден" -d show_alert="true" >/dev/null 2>&1
            fi
            return 0 ;;
        expl_search_back)
            rm -f "$_EXPL_SEARCH_MODE_FILE"
            local origin=$(cat /tmp/telegram_bot/explorer/search_origin 2>/dev/null); [ -z "$origin" ] && origin="/"
            _expl_render_browser "$origin" 1 "$msg_id"
            curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" >/dev/null 2>&1
            return 0 ;;

        expl_upload_start)
            _expl_show_upload_prompt ;;
        expl_upload_cancel)
            local _uc_id=""
            [ -f "$_EXPL_UPLOAD_PROMPT_MSG_FILE" ] && _uc_id=$(cat "$_EXPL_UPLOAD_PROMPT_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
            [ -n "$_uc_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_uc_id" >/dev/null 2>&1
            rm -f "$_EXPL_UPLOAD_PROMPT_MSG_FILE" "$_EXPL_UPLOAD_MODE_FILE"
            local _rp=$(cat "$_EXPL_UPLOAD_RETURN_PATH_FILE" 2>/dev/null); [ -z "$_rp" ] && _rp="/"
            local _rpage=$(cat "$_EXPL_UPLOAD_RETURN_PAGE_FILE" 2>/dev/null); [ -z "$_rpage" ] && _rpage=1
            rm -f "$_EXPL_UPLOAD_RETURN_PATH_FILE" "$_EXPL_UPLOAD_RETURN_PAGE_FILE"
            _expl_render_browser "$_rp" "$_rpage" "" ;;
        expl_upload_back)
            local _ub_id=""
            [ -f "$_EXPL_UPLOAD_RESULT_MSG_FILE" ] && _ub_id=$(cat "$_EXPL_UPLOAD_RESULT_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
            [ -n "$_ub_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_ub_id" >/dev/null 2>&1
            rm -f "$_EXPL_UPLOAD_RESULT_MSG_FILE" "$_EXPL_UPLOAD_RESULT_PATH_FILE"
            local _rp2=$(cat "$_EXPL_UPLOAD_RETURN_PATH_FILE" 2>/dev/null); [ -z "$_rp2" ] && _rp2="/"
            local _rpage2=$(cat "$_EXPL_UPLOAD_RETURN_PAGE_FILE" 2>/dev/null); [ -z "$_rpage2" ] && _rpage2=1
            rm -f "$_EXPL_UPLOAD_RETURN_PATH_FILE" "$_EXPL_UPLOAD_RETURN_PAGE_FILE"
            _expl_render_browser "$_rp2" "$_rpage2" "" ;;
        expl_upload_tofile)
            local _uf_path=""
            [ -f "$_EXPL_UPLOAD_RESULT_PATH_FILE" ] && _uf_path=$(cat "$_EXPL_UPLOAD_RESULT_PATH_FILE" 2>/dev/null)
            rm -f "$_EXPL_UPLOAD_RESULT_PATH_FILE"
            local _uf_id=""
            [ -f "$_EXPL_UPLOAD_RESULT_MSG_FILE" ] && _uf_id=$(cat "$_EXPL_UPLOAD_RESULT_MSG_FILE" 2>/dev/null | tr -d '\n\r ')
            [ -n "$_uf_id" ] && curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_uf_id" >/dev/null 2>&1
            rm -f "$_EXPL_UPLOAD_RESULT_MSG_FILE" "$_EXPL_UPLOAD_RETURN_PATH_FILE" "$_EXPL_UPLOAD_RETURN_PAGE_FILE"
            if [ -n "$_uf_path" ] && [ -e "$_uf_path" ]; then _expl_show_actions "$_uf_path" "F" ""
            else _expl_render_browser "/tmp" 1 ""; fi ;;
        expl_paste_back)
            local _pb_cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$_pb_cur" ] && _pb_cur="/"
            _expl_render_browser "$_pb_cur" 1 "$msg_id" ;;
        expl_return_from_exec)
            _expl_return_from_exec ;;
        expl_system_delete_yes)
            local _sd_path="" _sd_cur="" _sd_page=1
            if [ -f /tmp/telegram_bot/explorer/delete_confirm_state ]; then
                _sd_path=$(sed -n '1p' /tmp/telegram_bot/explorer/delete_confirm_state)
                _sd_cur=$(sed -n '2p' /tmp/telegram_bot/explorer/delete_confirm_state)
                _sd_page=$(sed -n '3p' /tmp/telegram_bot/explorer/delete_confirm_state)
            fi
            rm -f /tmp/telegram_bot/explorer/delete_confirm_state
            case "$_sd_page" in ''|*[!0-9]*) _sd_page=1 ;; esac
            if [ -z "$_sd_path" ] || [ ! -e "$_sd_path" ]; then _answer="⚠️ Действие неактуально"; return; fi
            if ! rm -rf "$_sd_path" 2>/dev/null; then _expl_render_error "Ошибка удаления"; return; fi
            [ -z "$_sd_cur" ] && _sd_cur="/"
            _expl_render_browser "$_sd_cur" "$_sd_page" "" ;;
        expl_system_delete_no)
            local _sd_cur="" _sd_page=1
            if [ -f /tmp/telegram_bot/explorer/delete_confirm_state ]; then
                _sd_cur=$(sed -n '2p' /tmp/telegram_bot/explorer/delete_confirm_state)
                _sd_page=$(sed -n '3p' /tmp/telegram_bot/explorer/delete_confirm_state)
            fi
            rm -f /tmp/telegram_bot/explorer/delete_confirm_state
            case "$_sd_page" in ''|*[!0-9]*) _sd_page=1 ;; esac
            [ -z "$_sd_cur" ] && _sd_cur="/"
            _expl_render_browser "$_sd_cur" "$_sd_page" "$msg_id"; _answer="🚫 Отменено" ;;
        expl_close)
            rm -f "$_EXPL_UNPACK_RESULT_PATH_FILE" "$_EXPL_UNPACK_SELECT_FILE" "$_EXPL_UNPACK_CONFIRM_FILE"
            _expl_close
            _answer="✅ Проводник закрыт" ;;
        *)
            _answer="⚠️ Неизвестное действие" ;;
    esac

    if [ -n "$_answer" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" --data-urlencode "text=$_answer" >/dev/null 2>&1
    else
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$cb_id" >/dev/null 2>&1
    fi
}

_expl_handle_text() {
    local text="$1"

    if [ -f "$_EXPL_RENAME_MODE_FILE" ]; then
        if echo "$text" | grep -qiE "^/cancel$|^отмена$|^cancel$"; then
            rm -f "$_EXPL_RENAME_MODE_FILE" "$_EXPL_RENAME_TARGET_FILE"
            local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
            _expl_render_browser "$cur" 1 ""
            return 0
        fi
        _expl_handle_rename_text "$text"
        return 0
    fi

    if [ -f "$_EXPL_SEARCH_MODE_FILE" ]; then
        _expl_handle_search_input "$text"
        return 0
    fi

    if [ -f "$_EXPL_CREATE_MODE_FILE" ]; then
        _expl_handle_create_input "$text"
        return 0
    fi
    return 1
}

_expl_handle_search_input() {
    local text="$1"
    if [ -n "$_IN_TEXT_MSG_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
        _IN_TEXT_MSG_ID=""
    fi

    if echo "$text" | grep -qiE "^/cancel$|^отмена$|^cancel$"; then
        rm -f "$_EXPL_SEARCH_MODE_FILE"
        local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
        _expl_render_browser "$cur" 1 ""
        return 0
    fi

    local query_clean=$(echo "$text" | sed 's/[*?[\]\\"`$]/\\&/g')
    local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
    local search_path="$cur"
    local _find_tmp="/tmp/telegram_bot/explorer/find_tmp.$$"
    : > "$_find_tmp"

    (
        exec 200>&- 2>/dev/null
        find "$search_path" -maxdepth 6 -iname "*${query_clean}*" 2>/dev/null
    ) > "$_find_tmp" &
    local _fpid=$!

    local _fw=0
    while [ "$_fw" -lt 10 ]; do
        kill -0 "$_fpid" 2>/dev/null || break
        sleep 1
        _fw=$((_fw + 1))
    done
    if kill -0 "$_fpid" 2>/dev/null; then kill -9 "$_fpid" 2>/dev/null; pkill -9 -P "$_fpid" 2>/dev/null; fi
    wait "$_fpid" 2>/dev/null

    head -n 50 "$_find_tmp" > "$_EXPL_SEARCH_RESULT_FILE"
    rm -f "$_find_tmp"

    local total=$(wc -l < "$_EXPL_SEARCH_RESULT_FILE" 2>/dev/null | tr -d ' ')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac

    if [ "$total" -eq 0 ]; then
        local prompt="🔍 <b>Поиск файлов и папок</b>

❌ Ничего не найдено по запросу <code>$query_clean</code>.
Попробуйте ввести другой запрос:"
        local kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_search_cancel"}]]}'
        _expl_send_or_edit "$prompt" "$kb" ""
        return 0
    fi

    rm -f "$_EXPL_SEARCH_MODE_FILE"
    local safe_query=$(html_escape "$text")
    if [ ${#safe_query} -gt 45 ]; then safe_query="${safe_query:0:42}..."; fi

    local res="<pre>📁 ПРОВОДНИК — РЕЗУЛЬТАТЫ ПОИСКА
Ищем: ${safe_query}
${SEP46}
№  Путь
-- ------------------------------------------------
"
    local i=1
    while IFS= read -r fullpath && [ "$i" -le "$total" ]; do
        [ -z "$fullpath" ] && continue
        local icon="📄"; [ -d "$fullpath" ] && icon="📁"
        local display_path="$fullpath"
        if [ ${#display_path} -gt 45 ]; then display_path="${display_path:0:20}...${display_path: -22}"; fi
        local safe_path=$(html_escape "$display_path")
        printf -v row "%-2s %s %s" "$i" "$icon" "$safe_path"
        res="${res}${row}"$'\n'
        i=$((i+1))
    done < "$_EXPL_SEARCH_RESULT_FILE"

    res="${res}${SEP46}"$'\n'
    res="${res}🕒 $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    res="${res}</pre>"

    local kb_rows=(); local row=""; local cnt=0
    for ((j=1; j<=total; j++)); do
        [ -n "$row" ] && row="$row,"
        row="$row{\"text\":\"$j\",\"callback_data\":\"expl_search_sel_$j\"}"
        cnt=$((cnt+1))
        if [ "$cnt" -eq 8 ]; then kb_rows+=("[$row]"); row=""; cnt=0; fi
    done
    [ -n "$row" ] && kb_rows+=("[$row]")
    kb_rows+=("[{\"text\":\"⬅️ Назад\",\"callback_data\":\"expl_search_back\"}]")

    local IFS=","
    local keyboard="{\"inline_keyboard\":[${kb_rows[*]}]}"
    unset IFS
    _expl_send_or_edit "$res" "$keyboard" ""
    return 0
}

_expl_handle_create_input() {
    local text="$1"
    if [ -n "$_IN_TEXT_MSG_ID" ]; then
        curl_retry -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" -d chat_id="$CHAT_ID" -d message_id="$_IN_TEXT_MSG_ID" >/dev/null 2>&1
        _IN_TEXT_MSG_ID=""
    fi

    if echo "$text" | grep -qiE "^/cancel$|^отмена$|^cancel$"; then
        rm -f "$_EXPL_CREATE_MODE_FILE"
        local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
        _expl_render_browser "$cur" 1 ""
        return 0
    fi

    if ! _expl_sanitize_name "$text"; then
        local prompt="❌ <b>Недопустимое имя папки</b>

Нельзя использовать: / \\ | : * ? &quot; &lt; &gt; &amp; \$ \`
Нельзя начинать с . или -
Максимум 255 символов.

Введите другое имя:"
        local kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_create_cancel"}]]}'
        _expl_send_or_edit "$prompt" "$kb" ""
        return 0
    fi

    local cur=$(cat "$_EXPL_CUR_PATH_FILE" 2>/dev/null); [ -z "$cur" ] && cur="/"
    local new_path="$cur/$text"

    if mkdir -p "$new_path" 2>/dev/null; then
        rm -f "$_EXPL_CREATE_MODE_FILE"
        _expl_render_browser "$cur" 1 ""
    else
        local prompt="❌ <b>Ошибка создания папки</b>

Проверьте права доступа. Введите другое имя:"
        local kb='{"inline_keyboard":[[{"text":"🔙 Отмена","callback_data":"expl_create_cancel"}]]}'
        _expl_send_or_edit "$prompt" "$kb" ""
    fi
    return 0
}