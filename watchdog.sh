#!/bin/bash
# ============================================================
# СЛУЖБА МОНИТОРИНГА И ПЕРЕЗАПУСКА БОТА (WATCHDOG)
# ============================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /etc/telegram_bot/bot_config.sh

# Корректное завершение по сигналу
_wd_shutdown() {
    echo "$(date): watchdog: получен сигнал остановки, убиваю детей" >> /tmp/telegram_bot/logs/watchdog.log
    pkill -TERM -f "/etc/telegram_bot/telegram_bot.sh" 2>/dev/null
    pkill -TERM -f "/etc/telegram_bot/event_monitor.sh" 2>/dev/null
    pkill -TERM -f "hostapd_cli.*-a /etc/telegram_bot/notify.sh" 2>/dev/null
    pkill -TERM -f "/etc/telegram_bot/restart_bot.sh" 2>/dev/null
    pkill -TERM -f "sexpect -sock /tmp/telegram_bot/exec/session/sock" 2>/dev/null
    pkill -TERM -f "_wifi_monitor_sta_connection" 2>/dev/null
    sleep 2
    pkill -9 -f "/etc/telegram_bot/telegram_bot.sh" 2>/dev/null
    pkill -9 -f "/etc/telegram_bot/event_monitor.sh" 2>/dev/null
    pkill -9 -f "hostapd_cli.*-a /etc/telegram_bot/notify.sh" 2>/dev/null
    pkill -9 -f "/etc/telegram_bot/restart_bot.sh" 2>/dev/null
    pkill -9 -f "sexpect -sock /tmp/telegram_bot/exec/session/sock" 2>/dev/null
    pkill -9 -f "_wifi_monitor_sta_connection" 2>/dev/null

    local _pf _sp
    for _pf in /tmp/telegram_bot/wifi/sta_monitor_*.pid; do
        [ -f "$_pf" ] || continue
        _sp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
        [ -n "$_sp" ] && kill -9 "$_sp" 2>/dev/null
        rm -f "$_pf"
    done
    exit 0
}
trap _wd_shutdown TERM INT

# Первичный запуск
if [ ! -f "/etc/telegram_bot/.bot_disabled" ]; then
    echo "$(date): watchdog: initial launch" >> /tmp/telegram_bot/logs/watchdog.log
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/bot
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/event
    /etc/telegram_bot/restart_bot.sh
    sleep 20
else
    echo "$(date): watchdog: .bot_disabled активен, запуск пропущен" >> /tmp/telegram_bot/logs/watchdog.log
fi

HEARTBEAT_FILE="/tmp/telegram_bot/heartbeat/bot"
TIMEOUT=80
RESTART_FLAG="/tmp/telegram_bot/flags/restarting"
RESTART_LOCK="/var/lock/restart_bot.lock"
EVENT_HEARTBEAT_FILE="/tmp/telegram_bot/heartbeat/event"
EVENT_TIMEOUT=300
EVENT_RESTART_LOCK="/var/lock/restart_event.lock"

while true; do
    echo "$(date +%s)" > /tmp/telegram_bot/heartbeat/watchdog
    rotate_log "/tmp/telegram_bot/logs/watchdog.log"

    [ -f "/etc/telegram_bot/.bot_disabled" ] && { sleep 60; continue; }

    if [ -f "$RESTART_LOCK" ]; then
        LOCK_AGE=$(($(date +%s) - $(stat -c %Y "$RESTART_LOCK" 2>/dev/null || date +%s)))
        if [ "$LOCK_AGE" -gt 30 ]; then
            STUCK_PIDS=$(pgrep -f "/etc/telegram_bot/restart_bot.sh" 2>/dev/null)
            if [ -n "$STUCK_PIDS" ]; then
                echo "$(date): Зависший restart lock (${LOCK_AGE}с) — убиваю: $STUCK_PIDS" >> /tmp/telegram_bot/logs/watchdog.log
                for _pid in $STUCK_PIDS; do pkill -9 -P "$_pid" 2>/dev/null; done
                sleep 1
                for _pid in $STUCK_PIDS; do kill -9 "$_pid" 2>/dev/null; done
                sleep 1
            elif [ "$LOCK_AGE" -gt 300 ]; then
                rm -f "$RESTART_LOCK" 2>/dev/null
                echo "$(date): Удалён устаревший lock-файл (${LOCK_AGE}с)" >> /tmp/telegram_bot/logs/watchdog.log
            fi
        fi
    fi

    if [ -f "$RESTART_FLAG" ]; then
        FLAG_AGE=$(($(date +%s) - $(stat -c %Y "$RESTART_FLAG" 2>/dev/null || date +%s)))
        if [ "$FLAG_AGE" -gt 30 ]; then
            rm -f "$RESTART_FLAG"
            echo "$(date): Удалён зависший флаг перезапуска (возраст: ${FLAG_AGE}с)" >> /tmp/telegram_bot/logs/watchdog.log
        else
            sleep 30; continue
        fi
    fi

    # Проверка heartbeat бота
    NEED_RESTART=0
    NOW=$(date +%s)
    LAST=0

    if [ ! -f "$HEARTBEAT_FILE" ]; then
        NEED_RESTART=1
    else
        _hb_value=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')
        echo "$_hb_value" | grep -qE '^[0-9]+$' && LAST="$_hb_value"
        if [ "$LAST" = "0" ] || [ $((NOW - LAST)) -gt $TIMEOUT ]; then NEED_RESTART=1; fi
    fi

    if [ $NEED_RESTART -eq 1 ]; then
        echo "$(date): Watchdog инициирует перезапуск (heartbeat: $((NOW - LAST)) сек.)" >> /tmp/telegram_bot/logs/watchdog.log
        if command -v setsid >/dev/null 2>&1; then
            setsid /etc/telegram_bot/restart_bot.sh </dev/null >/dev/null 2>&1 &
        else
            /etc/telegram_bot/restart_bot.sh </dev/null >/dev/null 2>&1
        fi
        sleep 5
    fi

    # Проверка heartbeat event_monitor
    _evt_need=0
    _evt_now=$(date +%s)
    _evt_last=0
    if [ ! -f "$EVENT_HEARTBEAT_FILE" ]; then
        _evt_need=1
    else
        _evt_hb=$(cat "$EVENT_HEARTBEAT_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')
        echo "$_evt_hb" | grep -qE '^[0-9]+$' && _evt_last="$_evt_hb"
        if [ "$_evt_last" = "0" ] || [ $((_evt_now - _evt_last)) -gt $EVENT_TIMEOUT ]; then _evt_need=1; fi
    fi

    if [ $_evt_need -eq 1 ]; then
        echo "$(date): Watchdog: event heartbeat устарел — перезапуск event_monitor" >> /tmp/telegram_bot/logs/watchdog.log
        ( 
            flock -n 200 || exit 0
            echo $$ >&200
            pkill -9 -f "/etc/telegram_bot/event_monitor.sh" 2>/dev/null
            sleep 2
            if command -v setsid >/dev/null 2>&1; then
                setsid /bin/bash /etc/telegram_bot/event_monitor.sh </dev/null >>/tmp/telegram_bot/logs/event_monitor.log 2>&1 200<&- &
            else
                /bin/bash /etc/telegram_bot/event_monitor.sh </dev/null >>/tmp/telegram_bot/logs/event_monitor.log 2>&1 200<&- &
            fi
        ) 200>"$EVENT_RESTART_LOCK"
    fi

    sleep 30
done