#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IP="${LAN_IP:-192.168.1.120}"  # Значение по умолчанию, можно переопределить

# Если есть файл с сохранённым IP, читаем его
if [ -f "/etc/xray/lan_ip" ]; then
    LAN_IP="$(cat /etc/xray/lan_ip 2>/dev/null)"
fi

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
    # Policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

	# Блокируем QUIC (UDP 443) до того, как пакеты попадут в TProxy
    nft add rule inet fw4 prerouting udp dport 443 drop

    # Проверяем, есть ли уже цепочка
    if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        nft add chain inet fw4 xray_tproxy
        nft add rule inet fw4 prerouting jump xray_tproxy
    else
        nft flush chain inet fw4 xray_tproxy
    fi

    # Добавляем правила (с использованием переменной LAN_IP)
    nft add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    nft add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0 } return
    nft add rule inet fw4 xray_tproxy ip daddr $LAN_IP tcp dport 22 return
    nft add rule inet fw4 xray_tproxy ip daddr $LAN_IP tcp dport 80 return
    nft add rule inet fw4 xray_tproxy ip daddr $LAN_IP tcp dport 443 return
    nft add rule inet fw4 xray_tproxy meta mark 0x1 return

    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_tproxy ip daddr $ip return
            logger -t update-nft "Bypass IP added: $ip"
        fi
    done

    nft add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    logger -t update-nft "Xray TProxy rules applied (LAN_IP: $LAN_IP)"
}

setup_network