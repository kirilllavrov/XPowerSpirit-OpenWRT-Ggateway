#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"

# Автоопределение LAN интерфейса
if ip link show br-lan >/dev/null 2>&1; then
    LAN_IF="br-lan"
else
    # Fallback: читаем из UCI
    LAN_IF=$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo "br-lan")
    # Если UCI вернул несколько интерфейсов (bridge), берём первый
    LAN_IF="${LAN_IF%% *}"
fi

# Автоопределение Guest интерфейса
if ip link show br-guest >/dev/null 2>&1; then
    GUEST_IF="br-guest"
else
    GUEST_IF=$(uci -q get network.guest.device || uci -q get network.guest.ifname || echo "")
    GUEST_IF="${GUEST_IF%% *}"
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

    # Создаём цепочку xray_tproxy (PREROUTING)
    if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        nft add chain inet fw4 xray_tproxy
        nft add rule inet fw4 prerouting jump xray_tproxy
    else
        nft flush chain inet fw4 xray_tproxy
    fi

    # Создаём цепочку xray_output (OUTPUT — для проксирования трафика самого роутера)
    if ! nft list chain inet fw4 xray_output 2>/dev/null | grep -q "chain xray_output"; then
        nft add chain inet fw4 xray_output
        nft add rule inet fw4 output jump xray_output
    else
        nft flush chain inet fw4 xray_output
    fi

    # ========== PREROUTING (xray_tproxy) ==========

    # Если пакет уже отмаркирован Xray (mark 2) — пропускаем (защита от петель)
    nft add rule inet fw4 xray_tproxy meta mark 2 return

    # Базовые bypass
    nft add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    nft add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return

    # DHCP — НЕ ТРОГАЕМ
    nft add rule inet fw4 xray_tproxy udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_tproxy ip daddr $ip return
        fi
    done

    # Гостевая сеть (если существует)
    if [ -n "$GUEST_IF" ] && ip link show "$GUEST_IF" >/dev/null 2>&1; then
        nft add rule inet fw4 xray_tproxy iifname "$GUEST_IF" return
    fi

    # Блокировка QUIC (UDP/443) — ДО TProxy, иначе пакет уйдёт в Xray до проверки
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" udp dport 443 drop

    # TProxy для LAN (сохраняем оригинальный mark 0x1 для policy routing)
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # TProxy для трафика самого роутера (перенаправлен из OUTPUT с mark 0x1 через lo)
    # Эти правила не имеют iifname — сработают для пакетов, уже отмаркированных OUTPUT chain
    nft add rule inet fw4 xray_tproxy meta mark 0x1 meta l4proto tcp tproxy ip to 127.0.0.1:12345 accept
    nft add rule inet fw4 xray_tproxy meta mark 0x1 meta l4proto udp tproxy ip to 127.0.0.1:12345 accept

    # ========== OUTPUT (xray_output — трафик самого роутера) ==========

    # Loop prevention: пакеты с mark 2 (от Xray outbound) — пропускаем, не трогаем
    nft add rule inet fw4 xray_output meta mark 2 return

    # Базовые bypass (локальные сети)
    nft add rule inet fw4 xray_output ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    nft add rule inet fw4 xray_output ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return
    nft add rule inet fw4 xray_output udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_output ip daddr $ip return
        fi
    done

    # Помечаем mark 1 для перенаправления через PREROUTING → TProxy
    nft add rule inet fw4 xray_output meta l4proto tcp meta mark set 1
    nft add rule inet fw4 xray_output meta l4proto udp meta mark set 1

    logger -t update-nft "Xray TProxy rules applied"
}

setup_network