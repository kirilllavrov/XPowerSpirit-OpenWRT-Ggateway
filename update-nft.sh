#!/bin/sh
# OpenWrt — создание nftables правил для Xray TProxy через fw4 интеграцию
# Для OpenWrt 22.03+ с fw4

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

    # Создаём файл для интеграции с fw4
    cat > /etc/nftables.d/99-xray-tproxy.nft << 'NFTEOF'
# Xray TProxy integration with fw4
# Этот файл автоматически включается fw4

table inet xray {
    chain xray_tproxy {
        type filter hook prerouting priority mangle + 10; policy accept;
        
        # 1. Bypass локальных и служебных подсетей
        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16
        } return;
        
        # 2. Bypass DoH/DNS-серверов
        ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0 } return;
        
        # 3. Bypass управления Cudy (SSH, WebUI)
        ip daddr 192.168.1.120 tcp dport 22 return;
        ip daddr 192.168.1.120 tcp dport 80 return;
        ip daddr 192.168.1.120 tcp dport 443 return;
NFTEOF

    # Добавляем bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "        ip daddr $ip return;" >> /etc/nftables.d/99-xray-tproxy.nft
            logger -t update-nft "Bypass IP added: $ip"
        fi
    done

    cat >> /etc/nftables.d/99-xray-tproxy.nft << 'NFTEOF'
        
        # 4. Bypass уже помеченного трафика (от самого Xray)
        meta mark 0x1 return;
        
        # 5. TProxy для TCP и UDP с LAN
        iifname "br-lan" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
        iifname "br-lan" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFTEOF

    # Перезагружаем firewall для применения правил
    service firewall restart
    
    logger -t update-nft "Xray TProxy rules applied via fw4 integration"
}

setup_network