#!/bin/bash
# ============================================================
# СКРИПТ АВТООБНОВЛЕНИЯ БОТА
# ============================================================
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /etc/telegram_bot/bot_config.sh

GITHUB_REPO="https://github.com/Woolagaroo/woo-wrt-tgbot/releases/latest/download"
FILES="telegram_bot.sh event_monitor.sh notify.sh wifi.sh explorer.sh bot_config.sh watchdog.sh restart_bot.sh boot_notify.sh uninstall_bot.sh VERSION"

echo "$(date): Начало обновления..." >> /tmp/telegram_bot/logs/bot.log

rm -rf /tmp/tgbot_update
mkdir -p /tmp/tgbot_update
cd /tmp/tgbot_update || exit 1

for file in $FILES; do
    wget -q -T 15 -O "$file" "$GITHUB_REPO/$file"
    if [ $? -ne 0 ] || [ ! -s "$file" ]; then
        echo "$(date): Ошибка скачивания $file. Обновление отменено." >> /tmp/telegram_bot/logs/bot.log
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="❌ <b>Ошибка обновления</b>: не удалось скачать <code>$file</code>. Проверьте интернет." \
            -d parse_mode="HTML" >/dev/null 2>&1
        rm -rf /tmp/tgbot_update
        exit 1
    fi
done

mv -f *.sh VERSION /etc/telegram_bot/ 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$(date): Ошибка перемещения файлов." >> /tmp/telegram_bot/logs/bot.log
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="❌ <b>Ошибка обновления</b>: не удалось заменить файлы в <code>/etc/telegram_bot/</code>." \
        -d parse_mode="HTML" >/dev/null 2>&1
    rm -rf /tmp/tgbot_update
    exit 1
fi

chmod +x /etc/telegram_bot/*.sh
rm -rf /tmp/tgbot_update

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="✅ <b>Бот успешно обновлён!</b>
🔄 Перезапускаюсь..." \
    -d parse_mode="HTML" >/dev/null 2>&1

sleep 2

/etc/init.d/woo-wrt-tgbot restart >/dev/null 2>&1