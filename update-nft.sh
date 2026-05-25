#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy через fw4 интеграцию

CONF="/etc/xray/config.json"

# Извлекаем IP‑адреса серверов из config.json
extract_server_ips() {
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr and addr not in ["hole", "0.0.0.0", "127.0.0.1"]:
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

setup_network() {
    # Очистка старых правил
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Удаляем старую цепочку, если есть
    nft list chain inet fw4 xray_tproxy 2>/dev/null && nft delete chain inet fw4 xray_tproxy 2>/dev/null

    # Создаём временный файл с правилами
    cat > /tmp/xray_rules.nft << 'NFTEOF'
# Xray TProxy integration with fw4
add chain inet fw4 xray_tproxy
add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0 } return
add rule inet fw4 xray_tproxy ip daddr 192.168.1.120 tcp dport 22 return
add rule inet fw4 xray_tproxy ip daddr 192.168.1.120 tcp dport 80 return
add rule inet fw4 xray_tproxy ip daddr 192.168.1.120 tcp dport 443 return
add rule inet fw4 xray_tproxy meta mark 0x1 return
NFTEOF

    # Добавляем bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "add rule inet fw4 xray_tproxy ip daddr $ip return" >> /tmp/xray_rules.nft
            logger -t update-nft "Bypass IP added: $ip"
        fi
    done

    cat >> /tmp/xray_rules.nft << 'NFTEOF'
add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept
add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept
add rule inet fw4 prerouting jump xray_tproxy
NFTEOF

    # Применяем правила
    nft -f /tmp/xray_rules.nft

    if [ $? -eq 0 ]; then
        logger -t update-nft "Xray TProxy rules applied successfully"
        rm -f /tmp/xray_rules.nft
        # Сохраняем правила для перезагрузки
        nft list chain inet fw4 xray_tproxy > /etc/nftables.d/99-xray-tproxy.nft 2>/dev/null || true
    else
        logger -t update-nft "Failed to apply Xray TProxy rules"
        rm -f /tmp/xray_rules.nft
        return 1
    fi
}

setup_network