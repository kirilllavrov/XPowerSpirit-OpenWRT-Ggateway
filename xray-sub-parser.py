#!/usr/bin/env python3
import sys
import base64
import json
import urllib.parse as urlparse
import urllib.request
import re
import syslog


# -----------------------------
# ЛОГИРОВАНИЕ ОШИБОК
# -----------------------------
def log_error(msg: str) -> None:
    """Отправляет сообщение об ошибке в syslog и в stderr"""
    syslog.syslog(syslog.LOG_ERR, f"xray-parser: {msg}")
    print(msg, file=sys.stderr)


# -----------------------------
# НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def normalize_tag(tag: str) -> str:
    tag = urlparse.unquote(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание (без эмодзи во избежание re.error)
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


# -----------------------------
# ЗАГРУЗКА URL
# -----------------------------
def try_download(data: str) -> tuple[str, bool]:
    """
    Загружает данные по URL, если передан HTTP/HTTPS URL.
    Возвращает (содержимое, успех).
    """
    if not (data.startswith("http://") or data.startswith("https://")):
        return data, True

    try:
        with urllib.request.urlopen(data, timeout=10) as r:
            content = r.read()

            # Проверяем, что это не HTML ошибка
            content_lower = content.lower()
            if b"<html" in content_lower or b"<!doctype" in content_lower:
                log_error(f"Subscription returned HTML, not VLESS: {data}")
                return "", False

            return content.decode("utf-8", errors="replace"), True
    except Exception as e:
        log_error(f"Failed to download subscription: {e}")
        return "", False


# -----------------------------
# УМНОЕ BASE64 (с поддержкой URL-safe)
# -----------------------------
def try_base64_decode(data: str) -> tuple[str, bool]:
    """Декодирует Base64, если это возможно. Возвращает (результат, успех)."""
    data = data.strip()

    # Если уже содержит vless:// — не трогаем
    if "vless://" in data:
        return data, True

    # Конвертируем URL-safe → стандартный Base64
    b64 = data.replace('-', '+').replace('_', '/')

    # Пробуем с padding и без
    for s in (b64, b64 + '=' * (-len(b64) % 4)):
        try:
            decoded = base64.b64decode(s).decode("utf-8", errors="replace")
            if "vless://" in decoded:
                return decoded, True
        except Exception:
            continue

    return data, False


# -----------------------------
# SAFE JSON PARSER FOR extra=
# -----------------------------
def parse_extra_json(extra_raw: str):
    if not extra_raw:
        return None
    try:
        decoded = urlparse.unquote(extra_raw)
        return json.loads(decoded)
    except Exception:
        return None


# -----------------------------
# ПАРСЕР VLESS
# -----------------------------
def parse_vless_uri(uri: str, idx: int):
    parsed = urlparse.urlparse(uri)

    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443

    # ТЕГ
    fragment = parsed.fragment or ""
    tag = normalize_tag(fragment) if fragment else f"proxy-vless-{idx}"

    # QUERY
    q = urlparse.parse_qs(parsed.query)

    def get_param(key, default=None):
        v = q.get(key)
        return v[0] if v else default

    # БАЗОВЫЕ ПОЛЯ
    uuid = user
    encryption = get_param("encryption", "none")
    flow = get_param("flow", None)

    # ТРАНСПОРТ
    network = get_param("type", "tcp").lower()
    if network in ("h2", "http2"):
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        network = "tcp"

    # SECURITY
    security = get_param("security", "none").lower()
    if security in ("tls", "xtls"):
        security_mode = "tls"
    elif security == "reality":
        security_mode = "reality"
    else:
        security_mode = "none"

    sni = get_param("sni", None)
    fp = get_param("fp", None)
    alpn_raw = get_param("alpn", None)
    alpn = [x.strip() for x in alpn_raw.split(",")] if alpn_raw else None
    allow_insecure = get_param("allowInsecure", "0") in ("1", "true", "yes")

    # REALITY
    pbk = get_param("pbk", None)
    sid = get_param("sid", None)
    spx = get_param("spx", None)

    # WS / HTTP / XHTTP / gRPC
    path = get_param("path", "/")
    host_header = get_param("host", None)
    grpc_service = get_param("serviceName", None) or get_param("grpc-service-name", None)
    xhttp_mode = get_param("mode", None)
    extra_raw = get_param("extra", None)

    # SETTINGS
    user_obj = {"id": uuid, "encryption": encryption}
    if flow:
        user_obj["flow"] = flow

    settings = {
        "vnext": [
            {
                "address": host,
                "port": port,
                "users": [user_obj]
            }
        ]
    }

    # STREAM SETTINGS
    stream = {"network": network}

    # TLS / REALITY
    if security_mode == "tls":
        stream["security"] = "tls"
        tls = {}
        if sni:
            tls["serverName"] = sni
        if alpn:
            tls["alpn"] = alpn
        if fp:
            tls["fingerprint"] = fp
        if allow_insecure:
            tls["allowInsecure"] = True
        if tls:
            stream["tlsSettings"] = tls

    elif security_mode == "reality":
        stream["security"] = "reality"
        reality = {}
        if sni:
            reality["serverName"] = sni
        if pbk:
            reality["publicKey"] = pbk
        if sid:
            reality["shortId"] = sid
        if spx:
            reality["spiderX"] = spx
        if fp:
            reality["fingerprint"] = fp
        stream["realitySettings"] = reality

    # NETWORK-SPECIFIC
    if network == "ws":
        ws = {"path": path}
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws

    elif network == "grpc":
        grpc = {}
        if grpc_service:
            grpc["serviceName"] = grpc_service
        stream["grpcSettings"] = grpc

    elif network == "http":
        http = {"path": path}
        if host_header:
            http["host"] = [host_header]
        stream["httpSettings"] = http

    elif network == "xhttp":
        xhttp = {"path": path}
        if host_header:
            xhttp["host"] = [host_header]
        if xhttp_mode:
            xhttp["mode"] = xhttp_mode

        extra_obj = parse_extra_json(extra_raw)
        if extra_obj:
            xhttp["extra"] = extra_obj

        stream["xhttpSettings"] = xhttp

    return {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream
    }


# -----------------------------
# MAIN
# -----------------------------
def main():
    raw = sys.stdin.read().strip()
    if not raw:
        log_error("Empty input")
        print("[]")
        sys.exit(1)

    # Загружаем по URL, если нужно
    data, success = try_download(raw)
    if not success or not data:
        log_error("Failed to download subscription")
        print("[]")
        sys.exit(1)

    # Пробуем декодировать Base64
    data, decoded = try_base64_decode(data)
    if not decoded:
        log_error("Failed to decode Base64 (no vless:// found after decoding)")
        print("[]")
        sys.exit(1)

    # Проверяем, что в данных есть vless://
    if "vless://" not in data:
        log_error("No vless:// URIs found in subscription")
        print("[]")
        sys.exit(1)

    lines = [l.strip() for l in data.splitlines() if l.strip()]

    outbounds = []
    idx = 0

    for line in lines:
        if line.startswith("vless://"):
            ob = parse_vless_uri(line, idx)
            if ob:
                outbounds.append(ob)
                idx += 1

    if not outbounds:
        log_error("No valid vless:// URIs parsed")
        print("[]")
        sys.exit(1)

    print(json.dumps(outbounds, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()