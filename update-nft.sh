#!/bin/sh
# OpenWrt — nftables правила для Xray Transparent Gateway
#
# Режим: прозрачный шлюз (не основной роутер)
# Только клиентский трафик с LAN проксируется через Xray TProxy.

CONF="/etc/xray/config.json"

# ============================================
#   АВТООПРЕДЕЛЕНИЕ LAN
# ============================================
if ip link show br-lan >/dev/null 2>&1; then
    LAN_IF="br-lan"
elif ip link show eth0 >/dev/null 2>&1; then
    LAN_IF="eth0"
elif ip link show eth1 >/dev/null 2>&1; then
    LAN_IF="eth1"
else
    LAN_IF=$(ip -4 addr show | grep -v 'lo\|docker\|virbr\|wg\|tun' | grep 'inet ' | head -1 | awk '{print $NF}')
fi

if [ -z "$LAN_IF" ]; then
    echo "[X] Не удалось определить LAN интерфейс" >&2
    exit 1
fi

echo "→ LAN интерфейс: $LAN_IF"

# ============================================
#   ИЗВЛЕЧЕНИЕ IP ПРОКСИ-СЕРВЕРОВ ИЗ config.json
# ============================================
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
            if isinstance(addr, str) and "." in addr and addr not in ("hole", "0.0.0.0", "127.0.0.1"):
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================
setup_network() {
    echo "→ Настройка policy routing..."

    # Очищаем предыдущие правила
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    # Policy routing: пакеты с mark=1 → table 100 → lo (для TProxy)
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    echo "→ Настройка nftables..."

    # ── Цепочка PREROUTING (xray_tproxy) ──
    # Перехватывает трафик клиентов из LAN, направляет в Xray TProxy
    if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        nft add chain inet fw4 xray_tproxy
        nft add rule inet fw4 prerouting jump xray_tproxy
    else
        nft flush chain inet fw4 xray_tproxy
    fi

    # 1. Защита от петель: трафик Xray (mark=2) — не трогаем
    nft add rule inet fw4 xray_tproxy meta mark 2 return

    # 2. DHCP — не трогаем
    nft add rule inet fw4 xray_tproxy udp dport { 67, 68 } return

    # 3. DNS (port 53) от клиентов — ВСЕГДА через Xray TProxy
    #    Это должно быть ДО bypass приватных IP, чтобы DNS-запросы к Xray GW (192.168.1.2:53)
    #    не обходили TProxy. Так клиентский DNS всегда идёт через Xray DoH — без утечек.
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" udp dport 53 tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" tcp dport 53 tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # 4. Публичные DNS (не-DNS трафик к этим IP) — bypass
    #    Клиентский DNS (порт 53) уже перехвачен правилом 3.
    #    Собственный DNS шлюза идёт через OUTPUT (не попадает в PREROUTING).
    nft add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return

    # 5. Прокси-серверы (VPS) — bypass (чтобы Xray мог к ним подключиться без повторного проксирования)
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_tproxy ip daddr $ip return
        fi
    done

    # 6. Локальные/приватные/мультикаст адреса — не трогаем
    #    DNS на этих адресах уже перехвачен правилом 3
    nft add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } return

    # 7. Блокировка QUIC (UDP/443) на входе — ДО TProxy
    #    QUIC не поддерживается VLESS+XTLS, поэтому блокируем чтобы браузеры использовали TCP/HTTPS
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" udp dport 443 drop

    # 8. TProxy: весь остальной трафик с LAN → Xray (порт 12345)
    #    mark=1 нужен для policy routing (таблица 100 → lo)
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # ── Цепочка OUTPUT (xray_output) ──
    # Минимальная защита: предотвращаем случайное проксирование трафика самого шлюза.
    # Собственный трафик шлюза НЕ проксируется.
    if ! nft list chain inet fw4 xray_output 2>/dev/null | grep -q "chain xray_output"; then
        nft add chain inet fw4 xray_output
        nft add rule inet fw4 output jump xray_output
    else
        nft flush chain inet fw4 xray_output
    fi

    # ВСЁ возвращаем (не проксируем трафик шлюза)
    # Это заглушка на будущее, если понадобится проксировать и шлюз тоже
    nft add rule inet fw4 xray_output return

    logger -t update-nft "Xray TProxy rules applied (transparent gateway mode)"
}

setup_network
