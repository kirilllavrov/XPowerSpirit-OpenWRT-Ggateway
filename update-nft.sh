#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy
# Генерирует /etc/nftables.d/99-xray-tproxy.nft
# Файл подхватывается fw4 (include "/etc/nftables.d/*.nft")
# и переживает service firewall restart

CONF="/etc/xray/config.json"
LAN_IP="${LAN_IP:-192.168.1.120}"
NFT_FILE="/etc/nftables.d/99-xray-tproxy.nft"

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

    # Создаём/очищаем цепочку
    nft add chain inet fw4 xray_tproxy 2>/dev/null || true
    nft flush chain inet fw4 xray_tproxy

    # Генерируем файл для fw4 (подхватится при include)
    cat > "$NFT_FILE" <<EOF
# Xray TProxy — автосгенерировано $(date)
# Добавляет цепочку с правилами TProxy в таблицу fw4.
# Применяется nft -f, а также автоматически подхватывается fw4
# при перезагрузке файрвола (service firewall restart).

add chain inet fw4 xray_tproxy
add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return
add rule inet fw4 xray_tproxy ip daddr $LAN_IP tcp dport { 22, 80, 443 } return
add rule inet fw4 xray_tproxy meta mark { 0x1, 0x2 } return
EOF

    # Добавляем IP прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "add rule inet fw4 xray_tproxy ip daddr $ip return" >> "$NFT_FILE"
            logger -t update-nft "Bypass IP added: $ip"
        fi
    done

    # QUIC block + TProxy
    cat >> "$NFT_FILE" <<EOF
add rule inet fw4 xray_tproxy udp dport 443 drop
add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
add rule inet fw4 xray_tproxy iifname "br-lan" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
EOF

    # Применяем правила
    nft -f "$NFT_FILE"

    # Добавляем jump-правило в prerouting (если его нет после fw4 reload)
    if ! nft list chain inet fw4 prerouting 2>/dev/null | grep -q "jump xray_tproxy"; then
        nft add rule inet fw4 prerouting jump xray_tproxy
    fi

    logger -t update-nft "Xray TProxy rules applied (LAN_IP: $LAN_IP)"
}

setup_network