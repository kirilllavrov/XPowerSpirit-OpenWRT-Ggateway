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

# Удаляем только старые Xray-конфигурации LED (остальные LED системы не трогаем)
for idx in $(seq 0 9); do
    name="$(uci -q get system.@led[$idx].name 2>/dev/null || true)"
    case "$name" in
        Xray_Status|xray_traffic|wan_online|Xray_Traffic|Internet_Status)
            uci delete system.@led[$idx] 2>/dev/null && {
                # После удаления индексы сдвигаются — начинаем заново
                idx=0
            }
            ;;
    esac
done 2>/dev/null || true
uci commit system
/etc/init.d/led restart 2>/dev/null || service led restart 2>/dev/null || true

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
# Проверка доступа в интернет через стандартный endpoint Android/Chrome
if curl -fs --max-time 5 https://connectivitycheck.gstatic.com/generate_204 >/dev/null 2>&1; then
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