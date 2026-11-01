#!/bin/bash
# ============================================================
# Полное удаление Telegram-бота с роутера
# ============================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

BOT_TOKEN=""
CHAT_ID=""
if [ -f /etc/telegram_bot/.env ]; then
    . /etc/telegram_bot/.env 2>/dev/null
fi

LOGFILE="/tmp/uninstall_bot.log"
echo "=== $(date): начало удаления бота ===" > "$LOGFILE"

# Флаг
touch /etc/telegram_bot/.bot_disabled
chmod 600 /etc/telegram_bot/.bot_disabled
echo "флаг установлен" >> "$LOGFILE"

# Watchdog
pkill -9 -f "/etc/telegram_bot/watchdog.sh" 2>/dev/null
sleep 1
echo "watchdog убит" >> "$LOGFILE"

# event_monitor
pkill -9 -f "/etc/telegram_bot/event_monitor.sh" 2>/dev/null
sleep 1
echo "event_monitor убит" >> "$LOGFILE"

# Прощальное сообщение
if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    curl -s --connect-timeout 5 --max-time 10 -X POST \
        "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="🗑 <b>Бот удалён</b>

Файлы бота и автозапуск удалены с роутера.
Настройки сетей, Wi-Fi и firewall — <b>сохранены</b>." \
        -d parse_mode="HTML" \
        --data-urlencode 'reply_markup={"remove_keyboard":true}' >/dev/null 2>&1
    echo "прощальное сообщение отправлено" >> "$LOGFILE"
    sleep 2
fi

# telegram_bot
pkill -9 -f "/etc/telegram_bot/telegram_bot.sh" 2>/dev/null
sleep 2
echo "telegram_bot убит" >> "$LOGFILE"

# Cron: только строки бота
if [ -f /etc/crontabs/root ]; then
    grep -vE 'telegram_bot|event_monitor|watchdog\.sh|restart_bot\.sh|/etc/telegram_bot/notify\.sh' \
        /etc/crontabs/root > /tmp/cron.clean 2>/dev/null
    mv /tmp/cron.clean /etc/crontabs/root
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null
    echo "cron очищен" >> "$LOGFILE"
fi

# UCI: только секция telegram_bot
if uci -q get telegram_bot >/dev/null 2>&1; then
    uci -q delete telegram_bot 2>/dev/null
    uci commit telegram_bot 2>/dev/null
    rm -f /etc/config/telegram_bot 2>/dev/null
    echo "telegram_bot UCI удалён" >> "$LOGFILE"
fi

# init.d скрипт
if [ -f /etc/init.d/woo-wrt-tgbot ]; then
    /etc/init.d/woo-wrt-tgbot disable 2>/dev/null
    /etc/init.d/woo-wrt-tgbot stop 2>/dev/null
    rm -f /etc/init.d/woo-wrt-tgbot
    rm -f /etc/rc.d/K10woo-wrt-tgbot /etc/rc.d/S99woo-wrt-tgbot
    echo "init.d удалён" >> "$LOGFILE"
fi

# Файлы бота
rm -f /etc/telegram_bot/telegram_bot.sh
rm -f /etc/telegram_bot/event_monitor.sh
rm -f /etc/telegram_bot/notify.sh
rm -f /etc/telegram_bot/wifi.sh
rm -f /etc/telegram_bot/explorer.sh
rm -f /etc/telegram_bot/bot_config.sh
rm -f /etc/telegram_bot/watchdog.sh
rm -f /etc/telegram_bot/restart_bot.sh
rm -f /etc/telegram_bot/.env
rm -f /etc/telegram_bot/boot_notify.sh
rm -f /etc/telegram_bot/.bot_disabled
rmdir /etc/telegram_bot/data 2>/dev/null
rmdir /etc/telegram_bot 2>/dev/null

# Данные и состояние
rm -f /etc/telegram_bot/data/.last_update_id
rm -f /etc/telegram_bot/data/.known_macs
rm -f /etc/telegram_bot/data/.known_macs0
rm -f /etc/telegram_bot/data/.target_device.conf
rm -f /etc/telegram_bot/data/.event_mute_list
rm -f /etc/telegram_bot/data/.event_mute_disabled
rm -f /etc/telegram_bot/data/.blocked_from_whitelist.txt
rm -f /etc/telegram_bot/data/.max_uptime
rm -f /etc/telegram_bot/data/.bandix_days_backup
rm -f /etc/telegram_bot/data/.bandix_profiles_order.txt
rm -f /etc/telegram_bot/data/device_names.txt
rm -f /etc/telegram_bot/data/wol.conf
rm -f /root/.wget-hsts

# Бэкапы
rm -f /etc/telegram_bot/*.sh.bak*
rm -f /etc/telegram_bot/*.sh.bak.*
rm -f /etc/telegram_bot/*.sh.new*

echo "файлы удалены" >> "$LOGFILE"

# Вся рантайм-структура бота
rm -rf /tmp/telegram_bot 2>/dev/null

# Locks
rm -f /var/lock/telegram_bot.lock /var/lock/event_monitor.lock 2>/dev/null
rm -f /var/lock/restart_bot.lock /var/lock/restart_event.lock 2>/dev/null
rm -f /var/lock/wifi_fix.lock /var/lock/explorer_size_cache.lock 2>/dev/null

echo "временные файлы удалены" >> "$LOGFILE"
echo "=== $(date): удаление завершено ===" >> "$LOGFILE"

# Самоудаление
rm -f /etc/telegram_bot/uninstall_bot.sh "$0" 2>/dev/null

exit 0
