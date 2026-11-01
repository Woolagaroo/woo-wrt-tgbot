#!/bin/bash
# ============================================================
# АВТО-УСТАНОВЩИК / ОБНОВЛЯТОР TELEGRAM-БОТА ДЛЯ OPENWRT
# ============================================================

GITHUB_REPO="https://github.com/Woolagaroo/woo-wrt-tgbot/releases/latest/download"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Ошибка: скрипт должен быть запущен от имени root (введите sudo -i)"
    exit 1
fi

echo "===================================================="
echo "🤖 УСТАНОВКА / ОБНОВЛЕНИЕ TELEGRAM-БОТА ДЛЯ OPENWRT"
echo "===================================================="

# 1. Определение пакетного менеджера
if command -v apk >/dev/null 2>&1; then
    INSTALL_CMD="apk add --no-cache"
elif command -v opkg >/dev/null 2>&1; then
    INSTALL_CMD="opkg update && opkg install"
else
    echo "❌ Не удалось определить пакетный менеджер."
    exit 1
fi

# 2. Проверка обязательных пакетов
echo -e "\n📦 Проверка обязательных пакетов..."
REQ_PKGS="bash curl jq gawk iwinfo hostapd-utils flock procps-ng-pkill sed coreutils-timeout coreutils-stat coreutils-du findutils"
MISSING_REQ=""

for pkg in $REQ_PKGS; do
    case "$pkg" in
        "procps-ng-pkill") cmd="pkill" ;;
        "hostapd-utils") cmd="hostapd_cli" ;;
        "coreutils-timeout") cmd="timeout" ;;
        *) cmd="$pkg" ;;
    esac
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_REQ="$MISSING_REQ $pkg"
    fi
done

if [ -n "$MISSING_REQ" ]; then
    echo "⚠️ Отсутствуют обязательные пакеты:$MISSING_REQ"
        read -p "Установить их сейчас? (y/n): " ans < /dev/tty
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        $INSTALL_CMD $MISSING_REQ || { echo "❌ Ошибка установки."; exit 1; }
    else
    echo "❌ Установка отменена. Отсутствуют обязательные зависимости."
    exit 1
    fi
else
    echo "✅ Обязательные пакеты на месте."
fi

# 3. Установка опциональных пакетов
echo -e "\n📦 Проверка опциональных пакетов..."
echo " (нужны для получения частоты cpu, терминала, теста скорости и Wake-on-LAN)"
OPT_PKGS="mhz sexpect speedtestcpp etherwake"
MISSING_OPT=""

for pkg in $OPT_PKGS; do
    case "$pkg" in
        "speedtestcpp") cmd="speedtest" ;;
        *) cmd="$pkg" ;;
    esac
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_OPT="$MISSING_OPT $pkg"
    fi
done

if [ -n "$MISSING_OPT" ]; then
    echo "⚠️ Не установлены:$MISSING_OPT"
        read -p "Установить их? (y/n): " ans < /dev/tty
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        $INSTALL_CMD $MISSING_OPT
    fi
else
    echo "✅ Опциональные пакеты на месте."
fi

# 4. Запрос токена и ID
echo -e "\n🔑 Настройка конфигурации"
mkdir -p /etc/telegram_bot/data
chmod 700 /etc/telegram_bot/data
touch /etc/telegram_bot/data/.no_reply_kb
chmod 600 /etc/telegram_bot/data/.no_reply_kb

if [ -f "/etc/telegram_bot/.env" ]; then
    echo "✅ Файл конфигурации .env уже существует. Настройки сохранены."
else
    echo "⚠️ Файл .env не найден. Это первая установка."
    read -p "Введите BOT_TOKEN (от @BotFather): " BOT_TOKEN < /dev/tty
    read -p "Введите CHAT_ID (от @userinfobot): " CHAT_ID < /dev/tty
    
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        echo "❌ Токен или Chat ID пусты. Установка прервана."
        exit 1
    fi
    
    echo "BOT_TOKEN=\"$BOT_TOKEN\"" > /etc/telegram_bot/.env
    echo "CHAT_ID=\"$CHAT_ID\"" >> /etc/telegram_bot/.env
    chmod 600 /etc/telegram_bot/.env
    echo "✅ Конфигурация сохранена."
fi

# 5. Скачивание файлов с GitHub
echo "📥 Скачивание файлов бота..."
TMP_DIR="/tmp/tgbot_install_$$"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR" || exit 1

FILES="telegram_bot.sh event_monitor.sh notify.sh wifi.sh explorer.sh bot_config.sh watchdog.sh restart_bot.sh boot_notify.sh uninstall_bot.sh VERSION woo-wrt-tgbot"
for file in $FILES; do
    wget -q -T 15 -O "$file" "$GITHUB_REPO/$file"
    
    if [ $? -ne 0 ] || [ ! -s "$file" ]; then
        echo "❌ Ошибка: не удалось скачать '$file'."
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    if head -n 1 "$file" | grep -qi "<!DOCTYPE html>"; then
        echo "❌ Ошибка: не удалось скачать '$file' (получен HTML вместо файла)."
        rm -rf "$TMP_DIR"
        exit 1
    fi
done

# Скачиваем init-скрипт
if [ ! -s "woo-wrt-tgbot" ]; then
    echo "❌ Ошибка: не удалось скачать init-скрипт."
    rm -rf "$TMP_DIR"
    exit 1
fi

mv -f *.sh VERSION /etc/telegram_bot/
mv -f woo-wrt-tgbot /etc/init.d/woo-wrt-tgbot

cd /
rm -rf "$TMP_DIR"

chmod +x /etc/telegram_bot/*.sh
chmod +x /etc/init.d/woo-wrt-tgbot

# 6. Настройка UCI
[ -f /etc/config/telegram_bot ] || touch /etc/config/telegram_bot
uci set telegram_bot.main=main
uci commit telegram_bot

# 7. Включение и запуск
echo "🚀 Запуск службы..."
/etc/init.d/woo-wrt-tgbot enable
sleep 2
/etc/init.d/woo-wrt-tgbot start

echo -e "\n===================================================="
echo "✅ УСТАНОВКА/ОБНОВЛЕНИЕ ЗАВЕРШЕНЫ!"
echo "Бот запущен. Напишите ему /start в Telegram."
echo "Логи: tail -f /tmp/telegram_bot/logs/bot.log"
echo "===================================================="