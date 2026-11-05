#!/bin/bash
# ============================================================
# СКРИПТ АВТООБНОВЛЕНИЯ БОТА
# ============================================================
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /etc/telegram_bot/bot_config.sh

GITHUB_REPO="https://github.com/Woolagaroo/woo-wrt-tgbot/releases/latest/download"
FILES="telegram_bot.sh event_monitor.sh notify.sh wifi.sh explorer.sh bot_config.sh watchdog.sh restart_bot.sh boot_notify.sh uninstall_bot.sh update.sh VERSION"

TMP_DIR="/tmp/tgbot_update_$$"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR" || exit 1

_download_file() {
    local f="$1"
    local url="$GITHUB_REPO/$f"
    local out="$TMP_DIR/$f"

    local http_code
    http_code=$(wget -q -T 15 --server-response -O "$out" "$url" 2>&1 \
        | awk '/^  HTTP\//{code=$2} END{print code}')

    if [ -z "$http_code" ] || [ "$http_code" != "200" ]; then
        echo "❌ HTTP $http_code для $f"
        return 1
    fi
    if [ ! -s "$out" ]; then
        echo "❌ Пустой файл: $f"
        return 1
    fi
    if head -n 1 "$out" | grep -qiE "<!DOCTYPE html|<html"; then
        echo "❌ HTML вместо файла: $f"
        return 1
    fi
    return 0
}

echo "$(date): Начало обновления..." >> /tmp/telegram_bot/logs/bot.log

if ! _download_file "VERSION"; then
    rm -rf "$TMP_DIR"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="❌ <b>Ошибка обновления</b>: не удалось скачать VERSION." \
        -d parse_mode="HTML" >/dev/null 2>&1
    exit 1
fi

NEW_VER=$(tr -d 'v \n\r' < "$TMP_DIR/VERSION")
CUR_VER=$(tr -d 'v \n\r' < /etc/telegram_bot/VERSION 2>/dev/null)
if [ -n "$CUR_VER" ] && [ "$NEW_VER" = "$CUR_VER" ]; then
    rm -rf "$TMP_DIR"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="ℹ️ <b>Обновление не требуется</b>: уже v${CUR_VER}." \
        -d parse_mode="HTML" >/dev/null 2>&1
    exit 0
fi

for f in $FILES; do
    [ "$f" = "VERSION" ] && continue
    if ! _download_file "$f"; then
        echo "$(date): Ошибка скачивания $f. Обновление отменено." >> /tmp/telegram_bot/logs/bot.log
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="❌ <b>Ошибка обновления</b>: не удалось скачать <code>$f</code>. Система не изменена." \
            -d parse_mode="HTML" >/dev/null 2>&1
        rm -rf "$TMP_DIR"
        exit 1
    fi
done

mkdir -p /etc/telegram_bot.new_$$
for f in $FILES; do
    cp "$TMP_DIR/$f" "/etc/telegram_bot.new_$$/$f" || {
        rm -rf "/etc/telegram_bot.new_$$" "$TMP_DIR"
        exit 1
    }
done

mv /etc/telegram_bot.new_$$ "$TMP_DIR/new_dir"
mv /etc/telegram_bot "$TMP_DIR/old_dir"
mv "$TMP_DIR/new_dir" /etc/telegram_bot
[ -f "$TMP_DIR/old_dir/.env" ] && [ ! -f /etc/telegram_bot/.env ] && cp -a "$TMP_DIR/old_dir/.env" /etc/telegram_bot/
[ -d "$TMP_DIR/old_dir/data" ] && [ ! -d /etc/telegram_bot/data ] && cp -a "$TMP_DIR/old_dir/data" /etc/telegram_bot/

chmod +x /etc/telegram_bot/*.sh
rm -rf "$TMP_DIR"

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="✅ <b>Бот обновлён до v${NEW_VER}</b>
🔄 Перезапускаюсь..." \
    -d parse_mode="HTML" >/dev/null 2>&1

sleep 2
/etc/init.d/woo-wrt-tgbot restart >/dev/null 2>&1
