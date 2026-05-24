#!/usr/bin/env python3
"""
Xray Config Generator for OpenWrt TProxy (Cudy Gateway)
Поддерживает два входных формата:
  --format vless - из xray-sub-parser.py (VLESS URI -> outbounds)
  --format json  - из JSON-подписки (Happ/Sing-box) с фильтрацией по remarks

Специальная обработка "hole":
  Если в подписке обнаружен outbound с address="hole", генерируется DIRECT-конфиг
"""

import json
import sys
import re
import argparse

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

DOMAIN_WHITELIST = [
    # "example.com"
]


# ============================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

def log_error(msg: str) -> None:
    print(msg, file=sys.stderr)


def normalize_tag(tag: str) -> str:
    if not tag:
        return "proxy"
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


def normalize_outbound(ob: dict) -> dict:
    """Дополняет outbound sockopt и отключает mux"""
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}
    ob["streamSettings"]["sockopt"]["mark"] = 0
    ob["streamSettings"]["sockopt"]["tcpNoDelay"] = True
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False
    return ob


# ============================================
#   ФУНКЦИИ ДЛЯ JSON ФОРМАТА
# ============================================

def load_json_subscription() -> list:
    try:
        data = json.load(sys.stdin)
        if isinstance(data, list):
            return data
        return [data]
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return []


def has_hole_in_subscription(sub_data: list) -> bool:
    for config in sub_data:
        if "outbounds" not in config:
            continue
        for ob in config["outbounds"]:
            try:
                addr = ob.get("settings", {}).get("vnext", [{}])[0].get("address", "")
                if addr == "hole":
                    return True
            except Exception:
                pass
    return False


def extract_outbounds_from_subscription(sub_data: list, remarks_filter: str = '') -> list:
    all_outbounds = []
    seen_tags = set()
    found_profile = False
    
    for config in sub_data:
        config_remarks = config.get("remarks", "")
        
        if remarks_filter:
            if remarks_filter.lower() not in config_remarks.lower():
                print(f"  → Пропускаем профиль: {config_remarks}", file=sys.stderr)
                continue
        
        found_profile = True
        print(f"  → Используем профиль: {config_remarks}", file=sys.stderr)
        
        if "outbounds" not in config:
            continue
        
        for ob in config["outbounds"]:
            protocol = ob.get("protocol", "")
            if protocol in ["freedom", "blackhole", "dns"]:
                continue
            
            if "tag" not in ob or not ob["tag"]:
                ob["tag"] = "proxy"
            
            original_tag = ob["tag"]
            tag = normalize_tag(original_tag)
            counter = 2
            while tag in seen_tags:
                tag = f"{original_tag}-{counter}"
                tag = normalize_tag(tag)
                counter += 1
            ob["tag"] = tag
            seen_tags.add(tag)
            
            ob = normalize_outbound(ob)
            all_outbounds.append(ob)
            print(f"  → Outbound: {tag} ({protocol})", file=sys.stderr)
    
    if remarks_filter and not found_profile:
        print(f"  [X] Профиль с remarks '{remarks_filter}' не найден!", file=sys.stderr)
        print(f"  → Доступные профили:", file=sys.stderr)
        for config in sub_data:
            config_remarks = config.get("remarks", "")
            print(f"      - {config_remarks}", file=sys.stderr)
    
    return all_outbounds


# ============================================
#   ФУНКЦИИ ДЛЯ VLESS ФОРМАТА
# ============================================

def load_vless_outbounds() -> list:
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


def normalize_vless_outbound(ob: dict, chosen_tag: str) -> dict:
    if "tag" not in ob:
        ob["tag"] = chosen_tag
    ss = ob.setdefault("streamSettings", {})
    sockopt = ss.setdefault("sockopt", {})
    sockopt["mark"] = 0
    sockopt["tcpKeepAliveInterval"] = 30
    sockopt["tcpNoDelay"] = True
    ob.setdefault("mux", {"enabled": False})
    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    return {
        "log": {
            "loglevel": "none",
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
                "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
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


def build_direct_config() -> dict:
    cfg = base_config()
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
        "rules": [
            {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"},
            {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
            {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
            {"type": "field", "domain": ["geosite:private", "geosite:category-ru"], "outboundTag": "direct"},
            {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
        ]
    }
    return cfg


def build_dns_outbound() -> dict:
    return {
        "protocol": "dns",
        "tag": "dns-out",
        "settings": {
            "rules": [{"action": "hijack", "qtype": "1,28"}]
        }
    }


def build_rules(proxy_outbounds: list, direct_mode: bool = False) -> list:
    rules = [
        {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"},
        {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
        {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
        {"type": "field", "domain": [
            "geosite:private", "geosite:category-browser",
            "geosite:category-cdn-ru", "geosite:category-mobile", "geosite:category-ru"
        ], "outboundTag": "direct"},
    ]
    
    if not direct_mode and proxy_outbounds:
        target = "balancer" if len(proxy_outbounds) > 1 else proxy_outbounds[0]["tag"]
        rules.append({
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "balancerTag" if len(proxy_outbounds) > 1 else "outboundTag": target
        })
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "balancerTag" if len(proxy_outbounds) > 1 else "outboundTag": target
        })
    else:
        rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "direct"})
    
    return rules


def build_balancer(proxy_outbounds: list) -> dict:
    return {
        "tag": "balancer",
        "selector": [ob["tag"] for ob in proxy_outbounds],
        "strategy": {"type": "leastPing"},
        "fallbackTag": "direct"
    }


def build_observatory(proxy_outbounds: list) -> dict:
    return {
        "subjectSelector": [ob["tag"] for ob in proxy_outbounds],
        "probeURL": "https://www.google.com/generate_204",
        "probeInterval": "300s",
        "enableConcurrency": True
    }


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for OpenWrt TProxy (Cudy Gateway)')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--format', choices=['json', 'vless'], default='vless',
                        help='Input format: json (Happ/Sing-box) or vless (parsed outbounds)')
    parser.add_argument('--remarks', default='',
                        help='Filter outbounds by remarks (substring, case-insensitive). Only for JSON format')
    return parser.parse_args()


def main():
    args = parse_args()
    
    if args.format == 'json':
        print("  → Обработка JSON подписки", file=sys.stderr)
        
        subscription = load_json_subscription()
        if not subscription:
            log_error("Empty or invalid JSON subscription")
            sys.exit(1)
        
        if has_hole_in_subscription(subscription):
            print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
            print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
            cfg = build_direct_config()
            with open(args.output, "w") as f:
                json.dump(cfg, f, indent=2, ensure_ascii=False)
            print(f"  ✓ DIRECT-конфиг сохранён: {args.output}", file=sys.stderr)
            return
        
        proxy_outbounds = extract_outbounds_from_subscription(subscription, args.remarks)
        if not proxy_outbounds:
            log_error("No valid outbounds found in JSON subscription")
            sys.exit(1)
        
        cfg = base_config()
        
        direct_outbound = {
            "protocol": "freedom", "tag": "direct",
            "streamSettings": {"sockopt": {"mark": 0, "tcpKeepAliveInterval": 30, "tcpNoDelay": True}}
        }
        block_outbound = {"protocol": "blackhole", "tag": "block"}
        dns_outbound = build_dns_outbound()
        
        cfg["outbounds"] = proxy_outbounds + [direct_outbound, block_outbound, dns_outbound]
        cfg["observatory"] = build_observatory(proxy_outbounds)
        
        routing = {"domainStrategy": "IPOnDemand", "rules": build_rules(proxy_outbounds)}
        if len(proxy_outbounds) > 1:
            routing["balancers"] = [build_balancer(proxy_outbounds)]
        cfg["routing"] = routing
        
        print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
        if len(proxy_outbounds) > 1:
            print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов", file=sys.stderr)
        
    else:
        print("  → Обработка VLESS формата", file=sys.stderr)
        
        all_obs = load_vless_outbounds()
        cfg = base_config()
        
        if has_hole(all_obs):
            cfg["outbounds"] = [
                {"protocol": "freedom", "tag": "direct"},
                {"protocol": "blackhole", "tag": "block"},
                build_dns_outbound()
            ]
            cfg["routing"] = {
                "domainStrategy": "IPOnDemand",
                "rules": build_rules([], direct_mode=True)
            }
            print("[!] Найден сервер 'hole'. Включён DIRECT-конфиг.", file=sys.stderr)
        else:
            chosen = choose_best_server(all_obs)
            if chosen is None:
                cfg["outbounds"] = [
                    {"protocol": "freedom", "tag": "direct"},
                    {"protocol": "blackhole", "tag": "block"},
                    build_dns_outbound()
                ]
                cfg["routing"] = {
                    "domainStrategy": "IPOnDemand",
                    "rules": build_rules([], direct_mode=True)
                }
                print("[!] Нет доступных серверов. Создан DIRECT-конфиг.", file=sys.stderr)
            else:
                chosen_tag = chosen.get("tag") or "proxy"
                chosen_tag = re.sub(r'[^\w\-]', '_', chosen_tag)[:64] or "proxy"
                if "tag" not in chosen:
                    chosen["tag"] = chosen_tag
                chosen = normalize_vless_outbound(chosen, chosen_tag)
                
                direct_outbound = {
                    "protocol": "freedom", "tag": "direct",
                    "streamSettings": {"sockopt": {"mark": 0, "tcpKeepAliveInterval": 30, "tcpNoDelay": True}}
                }
                
                cfg["outbounds"] = [chosen, direct_outbound, {"protocol": "blackhole", "tag": "block"}, build_dns_outbound()]
                cfg["routing"] = {
                    "domainStrategy": "IPOnDemand",
                    "rules": build_rules([chosen])
                }
                print(f"  ✓ Выбран сервер: {chosen_tag}", file=sys.stderr)
    
    with open(args.output, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг сохранён: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()