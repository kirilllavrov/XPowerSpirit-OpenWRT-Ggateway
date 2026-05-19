#!/bin/sh
# OpenWrt — Настройка LED для индикации интернета и Xray
# Проверено для Cudy WR3000S v1
# Проверить наличие LED: ls /sys/class/leds/

echo "=== Настройка LED Xray ==="

# Проверяем, существуют ли LED
if [ ! -d "/sys/class/leds/white:wps" ]; then
    echo "[X] LED white:wps не найден"
    exit 1
fi
if [ ! -d "/sys/class/leds/white:wan-online" ]; then
    echo "[X] LED white:wan-online не найден"
    exit 1
fi

# Удаляем ВСЕ старые LED-конфигурации
while uci -q delete system.@led[0]; do :; done 2>/dev/null || true
uci commit system
service led restart

# LED 1: Xray трафик (wps мигает при трафике через lo)
uci add system led
uci set system.@led[-1].name='Xray_Status'
uci set system.@led[-1].sysfs='white:wps'
uci set system.@led[-1].trigger='netdev'
uci set system.@led[-1].interval='100'
uci set system.@led[-1].dev='lo'
uci set system.@led[-1].mode='tx rx'
uci commit system
service led restart

# LED 2: Интернет (проверка через gen_204)
cat > /usr/share/xray/net-check.sh << 'EOF'
#!/bin/sh
if curl -fs --max-time 5 https://www.google.com/gen_204 >/dev/null 2>&1; then
    echo "default-on" > /sys/class/leds/white:wan-online/trigger
else
    echo "none" > /sys/class/leds/white:wan-online/trigger
fi
exit 0
EOF
chmod +x /usr/share/xray/net-check.sh

# Добавляем в cron
CRON_ENTRY="* * * * * /usr/share/xray/net-check.sh"
if ! crontab -l 2>/dev/null | grep -qF "net-check.sh"; then
    (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
    echo "[+] Cron-задача для индикации интернета добавлена"
fi
service cron restart

# Первая проверка сразу
sleep 10
/usr/share/xray/net-check.sh

echo "[+] LED настроены:"
echo "    white:wps        — мигает при трафике Xray (lo)"
echo "    white:wan-online — горит при доступе в интернет (проверка раз в минуту)"