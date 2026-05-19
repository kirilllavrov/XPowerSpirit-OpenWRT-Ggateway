#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IF="br-lan"

# Автоопределение LAN интерфейса, если br-lan отсутствует
if ! ip link show br-lan >/dev/null 2>&1; then
    LAN_IF=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$LAN_IF" ] && LAN_IF="br-lan"
    logger -t update-nft "LAN интерфейс auto-detected: $LAN_IF"
fi

# Извлекаем IP‑адреса серверов из config.json
extract_server_ips() {
    local raw

    # Пробуем Python-парсер
    raw=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr:
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null)

    # Fallback на grep
    if [ -z "$raw" ]; then
        raw=$(grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null |
            sed 's/.*"\([^"]*\)"$/\1/' |
            sort -u)
    fi

    [ -z "$raw" ] && return

    # Разделяем IP и домены, резолвим домены
    local ips=""
    while IFS= read -r addr; do
        case "$addr" in
            "hole" | "0.0.0.0" | "127.0.0.1" | "")
                continue
                ;;
            *[a-zA-Z]*)
                # Домен — резолвим через 77.88.8.8 (Яндекс DNS, быстрый и надёжный)
                local resolved
                resolved=$(resolveip -4 "$addr" 77.88.8.8 2>/dev/null)
                if [ -n "$resolved" ]; then
                    ips="$ips,$resolved"
                    logger -t update-nft "Resolved $addr → $resolved"
                else
                    logger -t update-nft "Failed to resolve $addr"
                fi
                ;;
            *.*.*.*)
                # Уже IP — проверяем валидность
                if echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    ips="$ips,$addr"
                fi
                ;;
        esac
    done <<EOF
$raw
EOF

    echo "$ips" | sed 's/^,//'
}

setup_network() {
    # Очистка старых правил
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Bypass IPs (прокси-серверы из подписки)
    local bypass_ips
    bypass_ips=$(extract_server_ips)

    # nftables
    nft list table inet xray >/dev/null 2>&1 && nft delete table inet xray
    local nft_file="/tmp/xray.nft"

    cat >"$nft_file" <<NFT
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 1. Bypass локальных и служебных подсетей
        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            224.0.0.0/3
        } return;

        # 2. Bypass DoH/DNS-серверов (чтобы Xray мог отправлять DoH-запросы)
        ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0 } return;

        # 3. Bypass управления Cudy (SSH, WebUI)
        ip daddr 192.168.1.120 tcp dport { 22, 80, 443 } return;

NFT

    # 4. Bypass прокси-серверов (чтобы трафик к прокси не зацикливался)
    if [ -n "$bypass_ips" ]; then
        VALID_IPS=$(echo "$bypass_ips" | tr ',' '\n' | grep -Ex '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$VALID_IPS" ]; then
            cat >>"$nft_file" <<NFT
        # 4. Bypass прокси-серверов
        ip daddr { $VALID_IPS } return;
NFT
            logger -t update-nft "Bypass IPs added: $VALID_IPS"
        fi
    fi

    cat >>"$nft_file" <<NFT

        # 5. Bypass уже помеченного трафика (от самого Xray)
        meta mark 0x1 return;

        # 6. DNS — не трогаем (Xray сам слушает 53 порт)
        udp dport 53 return;

        # 7. DHCP — не трогаем
        udp dport { 67, 68 } return;

        # 8. Всё остальное с LAN → TProxy
        iifname "$LAN_IF" meta l4proto { tcp, udp } \
            tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFT

    if nft -f "$nft_file"; then
        logger -t update-nft "Network rules applied successfully"
    else
        logger -t update-nft "nftables apply failed"
        rm -f "$nft_file"
        return 1
    fi

    rm -f "$nft_file"
}

setup_network