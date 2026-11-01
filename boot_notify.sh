#!/bin/bash
# ============================================================
# УВЕДОМЛЕНИЕ О ЗАВЕРШЕНИИ ЗАГРУЗКИ РОУТЕРА
# ============================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /etc/telegram_bot/bot_config.sh

check_required_utilities || exit 1

for i in $(seq 1 30); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then break; fi
    sleep 1
done

_uptime_sec=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
_boot_ts=$(( $(date +%s) - _uptime_sec ))
_boot_time=$(date -d "@$_boot_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
[ -z "$_boot_time" ] && _boot_time="Неизвестно"

if [ -f "/etc/telegram_bot/data/.reboot_from_bot" ]; then
    rm -f "/etc/telegram_bot/data/.reboot_from_bot"
    send_tg "🔄 <b>Роутер перезагрузился:</b>
🕒 Время загрузки: <code>$_boot_time</code>
📡 Сеть доступна: <code>$(date '+%Y-%m-%d %H:%M:%S')</code>"
else
    send_tg "🔄 <b>Роутер загрузился:</b>
🕒 Время загрузки: <code>$_boot_time</code>
📡 Сеть доступна: <code>$(date '+%Y-%m-%d %H:%M:%S')</code>"
fi