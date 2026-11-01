#!/bin/bash
# ============================================================
# restart_bot.sh — перезапуск telegram_bot и event_monitor.
# ============================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

LOCK_FILE="/var/lock/restart_bot.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date): Перезапуск уже выполняется, выхожу." >> /tmp/telegram_bot/logs/restart.log
    exit 0
fi
echo $$ >&200

rm -f /tmp/telegram_bot/flags/restarting

. /etc/telegram_bot/bot_config.sh
rotate_log "/tmp/telegram_bot/logs/restart.log"

if [ -f "/etc/telegram_bot/.bot_disabled" ]; then
    echo "$(date): restart_bot: бот отключён флагом /etc/telegram_bot/.bot_disabled, выход" >> /tmp/telegram_bot/logs/restart.log
    exit 0
fi

# ============================================================
# Флаг first_boot: не считать ребут роутера «перезапуском бота»
# ============================================================
if [ -f "/tmp/telegram_bot/flags/first_boot" ]; then
    rm -f "/tmp/telegram_bot/flags/first_boot"
    echo "$(date): Первый запуск после загрузки, флаг перезапуска НЕ создан" >> /tmp/telegram_bot/logs/restart.log
else
    touch /tmp/telegram_bot/flags/restarting
    echo "$(date): Создан флаг /tmp/telegram_bot/flags/restarting" >> /tmp/telegram_bot/logs/restart.log
fi

echo "=== Перезапуск бота $(date '+%Y-%m-%d %H:%M:%S') ===" >> /tmp/telegram_bot/logs/restart.log

# ============================================================
# Мягкая остановка STA-мониторов
# ============================================================
_stopped_monitors=0
_pids_to_wait=()

for pid_file in /tmp/telegram_bot/wifi/sta_monitor_*.pid; do
    [ -f "$pid_file" ] || continue
    _pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null
        _pids_to_wait+=("$_pid")
        _stopped_monitors=$((_stopped_monitors + 1))
    fi
    rm -f "$pid_file"
done

for _pdir in /proc/[0-9]*; do
    _p="${_pdir#/proc/}"
    [ -r "/proc/$_p/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q "_wifi_monitor_sta_connection"; then
        kill "$_p" 2>/dev/null
        _pids_to_wait+=("$_p")
        _stopped_monitors=$((_stopped_monitors + 1))
        echo "DEBUG: restart_bot: убит осиротевший монитор PID=$_p" >> /tmp/telegram_bot/logs/restart.log
    fi
done

if [ ${#_pids_to_wait[@]} -gt 0 ]; then
    _wait_start=$(date +%s)
    while [ $(( $(date +%s) - _wait_start )) -lt 3 ]; do
        _any_alive=0
        for _wp in "${_pids_to_wait[@]}"; do
            kill -0 "$_wp" 2>/dev/null && _any_alive=1 && break
        done
        [ "$_any_alive" = "0" ] && break
        sleep 1
    done
    for _wp in "${_pids_to_wait[@]}"; do
        if kill -0 "$_wp" 2>/dev/null; then
            echo "DEBUG: restart_bot: монитор PID=$_wp не умер по SIGTERM за 3с, отправляю SIGKILL" >> /tmp/telegram_bot/logs/restart.log
            kill -9 "$_wp" 2>/dev/null
        fi
    done
fi

[ "$_stopped_monitors" -gt 0 ] && echo "✅ Остановлено STA-мониторов: $_stopped_monitors" >> /tmp/telegram_bot/logs/restart.log

# ============================================================
# Очистка рантайма
# ============================================================
rm -rf /tmp/telegram_bot/state/*           2>/dev/null
rm -rf /tmp/telegram_bot/services/*        2>/dev/null
rm -rf /tmp/telegram_bot/critical/state/*  2>/dev/null
rm -rf /tmp/telegram_bot/online/*          2>/dev/null
rm -rf /tmp/telegram_bot/traffic/*         2>/dev/null
rm -rf /tmp/telegram_bot/speed/*           2>/dev/null
rm -rf /tmp/telegram_bot/wol/*             2>/dev/null
rm -rf /tmp/telegram_bot/reboot/*          2>/dev/null
rm -rf /tmp/telegram_bot/wifi/*            2>/dev/null
rm -rf /tmp/telegram_bot/explorer/*        2>/dev/null
rm -rf /tmp/telegram_bot/target/*          2>/dev/null
rm -rf /tmp/telegram_bot/exec/session      2>/dev/null
rm -rf /tmp/telegram_bot/exec/output       2>/dev/null
rm -f  /tmp/telegram_bot/exec/wait_msg_id  2>/dev/null
rm -f  /tmp/telegram_bot/exec/defer_msgs   2>/dev/null
rm -f  /tmp/telegram_bot/exec/return_to_explorer 2>/dev/null
rm -f  /tmp/telegram_bot/exec/wrap_*       2>/dev/null
rm -f  /tmp/telegram_bot/exec/script_*     2>/dev/null
rm -f  /tmp/telegram_bot/flags/first_boot  2>/dev/null
rm -f  /tmp/telegram_bot/flags/busy_since  2>/dev/null
rm -f  /tmp/telegram_bot/flags/busy_until  2>/dev/null
rm -f  /tmp/telegram_bot/flags/busy_hb_pid 2>/dev/null
rm -f  /tmp/telegram_bot/flags/skip_msg_id 2>/dev/null
rm -f  /tmp/telegram_bot/flags/offset_recovery_pending 2>/dev/null
if [ -f /tmp/telegram_bot/state/event_toggle_msg_id ]; then
    _evt_mid=$(cat /tmp/telegram_bot/state/event_toggle_msg_id 2>/dev/null)
    if [ -n "$_evt_mid" ]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" -d message_id="$_evt_mid" >/dev/null 2>&1
    fi
    rm -f /tmp/telegram_bot/state/event_toggle_msg_id
fi

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteWebhook" >/dev/null 2>&1
echo "✅ Вебхук сброшен" >> /tmp/telegram_bot/logs/restart.log

# ============================================================
# Остановка старых процессов
# ============================================================
pkill -9 -f telegram_bot.sh 2>/dev/null
pkill -9 -f "event_monitor.sh _lan_worker" 2>/dev/null
pkill -9 -f event_monitor.sh 2>/dev/null
pkill -9 -f "hostapd_cli.*-a /etc/telegram_bot/notify.sh" 2>/dev/null

# exec-сессия держит sexpect + inner bash + всё дерево команд.
if [ -n "$_EXEC_SOCK" ]; then
    pkill -9 -f "sexpect -sock $_EXEC_SOCK" 2>/dev/null
else
    echo "$(date): restart_bot: _EXEC_SOCK пуст, pkill sexpect пропущен" >> /tmp/telegram_bot/logs/restart.log
fi
pkill -9 -f "/tmp/telegram_bot/exec/session/inner.sh" 2>/dev/null

# ============================================================
# Убить всех держателей flock
# ============================================================
_killed_lock_holders=0
for _pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ "$_pid" = "$$" ] && continue
    [ -d "/proc/$_pid/fd" ] || continue
    for _fd in /proc/$_pid/fd/*; do
        _tgt=$(readlink "$_fd" 2>/dev/null)
        case "$_tgt" in
            *telegram_bot.lock*|*event_monitor.lock*)
                kill -9 "$_pid" 2>/dev/null && _killed_lock_holders=$((_killed_lock_holders + 1))
                break
                ;;
        esac
    done
done

if [ "$_killed_lock_holders" -gt 0 ]; then
    echo "✅ Убито дополнительных держателей flock: $_killed_lock_holders" >> /tmp/telegram_bot/logs/restart.log
fi

echo "✅ Процессы остановлены" >> /tmp/telegram_bot/logs/restart.log

sleep 3

# ============================================================
# Запуск новых процессов
# ============================================================
if command -v setsid >/dev/null 2>&1; then
    setsid /bin/bash /etc/telegram_bot/telegram_bot.sh </dev/null >/tmp/telegram_bot/logs/bot.log 2>&1 200<&- &
    setsid /bin/bash /etc/telegram_bot/event_monitor.sh </dev/null >/tmp/telegram_bot/logs/event_monitor.log 2>&1 200<&- &
else
    /bin/bash /etc/telegram_bot/telegram_bot.sh </dev/null >/tmp/telegram_bot/logs/bot.log 2>&1 200<&- &
    /bin/bash /etc/telegram_bot/event_monitor.sh </dev/null >/tmp/telegram_bot/logs/event_monitor.log 2>&1 200<&- &
fi

sleep 3

_tg_alive=0
_em_alive=0
if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "/etc/telegram_bot/telegram_bot.sh" >/dev/null 2>&1 && _tg_alive=1
    pgrep -f "/etc/telegram_bot/event_monitor.sh" >/dev/null 2>&1 && _em_alive=1
else
    ps w | grep -v grep | grep -q "/etc/telegram_bot/telegram_bot.sh" && _tg_alive=1
    ps w | grep -v grep | grep -q "/etc/telegram_bot/event_monitor.sh" && _em_alive=1
fi

if [ "$_tg_alive" = "1" ] && [ "$_em_alive" = "1" ]; then
    echo "✅ Оба процесса запущены (telegram_bot+event_monitor)" >> /tmp/telegram_bot/logs/restart.log
else
    echo "❌ ПРОВАЛ ЗАПУСКА: telegram_bot=$_tg_alive event_monitor=$_em_alive" >> /tmp/telegram_bot/logs/restart.log
    if command -v curl >/dev/null 2>&1 && [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
        _err_text="❌ <b>Провал перезапуска бота</b>
telegram_bot: ${_tg_alive}
event_monitor: ${_em_alive}
🕒 $(date '+%Y-%m-%d %H:%M:%S')
Проверьте: <code>tail -30 /tmp/telegram_bot/logs/bot.log</code>"
        curl -s --connect-timeout 5 --max-time 10 -X POST \
            "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode text="$_err_text" \
            -d parse_mode="HTML" >/dev/null 2>&1
    fi
fi

# ============================================================
# Watchdog: запуск только если procd его не поднял
# ============================================================
if ! pgrep -f "/etc/telegram_bot/watchdog.sh" >/dev/null 2>&1; then
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/bash /etc/telegram_bot/watchdog.sh </dev/null >>/tmp/telegram_bot/logs/watchdog.log 2>&1 200<&- &
    else
        /bin/bash /etc/telegram_bot/watchdog.sh </dev/null >>/tmp/telegram_bot/logs/watchdog.log 2>&1 200<&- &
    fi
    sleep 1
    if pgrep -f "/etc/telegram_bot/watchdog.sh" >/dev/null 2>&1; then
        echo "✅ Watchdog запущен" >> /tmp/telegram_bot/logs/restart.log
    else
        echo "❌ Watchdog не запустился" >> /tmp/telegram_bot/logs/restart.log
    fi
fi

# ============================================================
# hostapd_cli
# ============================================================
iface24=$(_find_iface_for_radio 0)
iface5=$(_find_iface_for_radio 1)

[ -z "$iface24" ] && iface24="phy0-ap0"
[ -z "$iface5" ]  && iface5="phy1-ap0"

if command -v hostapd_cli >/dev/null 2>&1; then
    ip link show "$iface24" >/dev/null 2>&1 && /usr/sbin/hostapd_cli -a /etc/telegram_bot/notify.sh -B -i "$iface24" 2>/dev/null 200<&- || true
    ip link show "$iface5"  >/dev/null 2>&1 && /usr/sbin/hostapd_cli -a /etc/telegram_bot/notify.sh -B -i "$iface5"  2>/dev/null 200<&- || true
fi

echo "=== Перезапуск завершен $(date) ===" >> /tmp/telegram_bot/logs/restart.log
exit 0