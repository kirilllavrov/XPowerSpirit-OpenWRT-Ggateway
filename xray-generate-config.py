#!/usr/bin/env python3
import json
import sys
import re

DOMAIN_WHITELIST = [
    # "example.com"
]

def load_outbounds():
    try:
        data = json.load(sys.stdin)
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            return data
    except Exception:
        return []
    return []

def extract_address(ob):
    try:
        return ob["settings"]["vnext"][0]["address"]
    except Exception:
        return None

def extract_id(ob):
    try:
        return ob["settings"]["vnext"][0]["users"][0]["id"]
    except Exception:
        return None

def is_placeholder(ob):
    addr = extract_address(ob)
    uid = extract_id(ob)
    port = None
    try:
        port = ob["settings"]["vnext"][0]["port"]
    except Exception:
        pass
    return (
        uid == "00000000-0000-0000-0000-000000000000"
        or addr in ["0.0.0.0", "127.0.0.1", "hole"]
        or str(port) == "1"
    )

def has_hole(servers):
    for ob in servers:
        if extract_address(ob) == "hole":
            return True
    return False

def choose_best_server(servers):
    if not servers:
        return None
    servers = [s for s in servers if not is_placeholder(s)]
    if not servers:
        return None
    if DOMAIN_WHITELIST:
        for ob in servers:
            addr = extract_address(ob)
            if addr in DOMAIN_WHITELIST:
                return ob
    return servers[0]

def base_config():
    return {
        "log": {
            "loglevel": "debug",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": {
            "queryStrategy": "UseIPv4",
            "disableCache": False,
            "serveStale": True,
            "serveExpiredTTL": 1800,
            "disableFallback": False,
            "enableParallelQuery": True,
            "hosts": {
                "common.dot.dns.yandex.net": ["77.88.8.1","77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1","1.1.1.1"],
                "dns.nextdns.io": "45.90.28.0"
            },
            "servers": [
                {
                    "address": "https+local://common.dot.dns.yandex.net/dns-query",
                    "domains": ["geosite:category-ru"],
                    "skipFallback": True
                },
                {
                    "address": "https+local://cloudflare-dns.com/dns-query",
                    "skipFallback": False
                },
                {
                    "address": "https+local://dns.nextdns.io/dns-query",
                    "skipFallback": False
                }
            ]
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": 12345,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": True
                }
            },
            {
                "tag": "dns-in",
                "listen": "0.0.0.0",
                "port": 53,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "udp"
                }
            }
        ]
    }

def build_rules(chosen_tag, direct_mode=False):
    rules = [
        # DNS запросы от клиентов (inbound dns-in) → dns-out
        {
            "type": "field",
            "inboundTag": ["dns-in"],
            "outboundTag": "dns-out"
        },
        # Блокировка рекламы
        {
            "type": "field",
            "domain": ["geosite:category-ads"],
            "outboundTag": "block"
        },
        # Локальные, браузерные и российские домены — напрямую
        {
            "type": "field",
            "ip": ["geoip:ru", "geoip:private"],
            "outboundTag": "direct"
        },
        {
            "type": "field",
            "domain": [
                "geosite:private",
                "geosite:category-browser",
                "geosite:category-cdn-ru",
                "geosite:category-mobile",
                "geosite:category-ru"
            ],
            "outboundTag": "direct"
        },
    ]
    # Стриминг и игры — через прокси (для обхода geo-блокировок)
    if not direct_mode:
        rules.append({
            "type": "field",
            "domain": [
                "geosite:category-streaming",
                "geosite:category-games"
            ],
            "outboundTag": chosen_tag
        })
    # Весь остальной трафик — через прокси
    rules.append({
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": chosen_tag
    })
    return rules

def main():
    if len(sys.argv) != 3 or sys.argv[1] != "--output":
        print("Usage: xray-generate-config.py --output <file>")
        sys.exit(1)
    output_path = sys.argv[2]
    all_obs = load_outbounds()
    cfg = base_config()

    # Если в подписке есть сервер с адресом "hole" — сразу уходим в DIRECT
    if has_hole(all_obs):
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
            {
                "protocol": "dns",
                "tag": "dns-out",
                "settings": {
                    "rules": [{"action": "hijack", "qtype": "1,28"}]
                }
            }
        ]
        cfg["routing"] = {
            "domainStrategy": "IPOnDemand",
            "rules": build_rules("direct", direct_mode=True)
        }
        print("[!] Найден сервер 'hole'. Включён DIRECT-конфиг.", file=sys.stderr)
        with open(output_path, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"✓ Конфиг сохранён: {output_path}", file=sys.stderr)
        return

    chosen = choose_best_server(all_obs)
    if chosen is None:
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
            {
                "protocol": "dns",
                "tag": "dns-out",
                "settings": {
                    "rules": [{"action": "hijack", "qtype": "1,28"}]
                }
            }
        ]
        cfg["routing"] = {
            "domainStrategy": "IPOnDemand",
            "rules": build_rules("direct", direct_mode=True)
        }
        print("[!] Нет доступных серверов (только заглушки). Создан DIRECT-конфиг.", file=sys.stderr)
    else:
        chosen_tag = chosen.get("tag") or "proxy"
        chosen_tag = re.sub(r'[^\w\-]', '_', chosen_tag)[:64] or "proxy"
        if "tag" not in chosen:
            chosen["tag"] = chosen_tag
        ss = chosen.setdefault("streamSettings", {})
        sockopt = ss.setdefault("sockopt", {})
        sockopt["mark"] = 0
        sockopt["tcpKeepAliveInterval"] = 30
        sockopt["tcpNoDelay"] = True
        chosen.setdefault("mux", {"enabled": False})

        direct_sockopt = {
            "mark": 0,
            "tcpKeepAliveInterval": 30,
            "tcpNoDelay": True
        }
        cfg["outbounds"] = [
            chosen,
            {
                "protocol": "freedom",
                "tag": "direct",
                "streamSettings": {"sockopt": direct_sockopt}
            },
            {"protocol": "blackhole", "tag": "block"},
            {
                "protocol": "dns",
                "tag": "dns-out",
                "settings": {
                    "rules": [{"action": "hijack", "qtype": "1,28"}]
                }
            }
        ]
        cfg["routing"] = {
            "domainStrategy": "IPOnDemand",
            "rules": build_rules(chosen_tag, direct_mode=False)
        }
        print(f"  ✓ Выбран сервер: {chosen_tag}", file=sys.stderr)

    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг сохранён: {output_path}", file=sys.stderr)

if __name__ == "__main__":
    main()