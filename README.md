# XPowerSpirit-OpenWRT-Ggateway

Установка Xray на OpenWRT — два режима работы.

## Режимы

### 1. Прозрачный шлюз (Transparent Gateway) — `install-xray-gateway.sh`
Устройство OpenWRT **НЕ** является основным роутером. Работает как прозрачный прокси-шлюз для клиентов локальной сети.

```
Internet
   │
Keenetic (основной роутер: NAT, DHCP, DNS fallback)
   │ 192.168.1.1
   ├── Xray GW (статический IP 192.168.1.2)
   │      └── TProxy :12345 → routing → proxy/direct/block
   │
   └── Клиенты (gateway=192.168.1.2, dns=192.168.1.2)
```

**Запуск:**
```sh
sh install-xray-gateway.sh --sub=https://your-subscription.url
```

**Параметры:**
| Параметр | Назначение |
|---|---|
| `--sub=URL` | URL подписки (обязателен) |
| `--sub-ua=UA` | User-Agent для запроса подписки |
| `--remarks=FILTER` | Фильтр по имени профиля в JSON-подписке |
| `--ip=X.X.X.X` | Статический IP шлюза (автоопределение если не указан) |
| `--gw=X.X.X.X` | IP основного роутера/Keenetic (автоопределение) |

**Настройка Keenetic после установки:**
- DHCP: шлюз по умолчанию = IP Xray-устройства
- DHCP: DNS-сервер = IP Xray-устройства

### 2. Основной роутер (Main Router) — `install-openwrt-xray.sh`
Устройство OpenWRT **является** основным роутером (PPPoE/WAN, DHCP, NAT, DNS).

```
Internet
   │
Xray OpenWRT (PPPoE, NAT, DHCP, DNS)
   │
   ├── LAN клиенты
   └── Guest WiFi (опционально)
```

**Запуск:**
```sh
sh install-openwrt-xray.sh --sub=https://your-subscription.url [--pppoe=1 ...] [--guest=1 ...]
```

## Состав проекта

| Файл | Роль |
|---|---|
| `install-xray-gateway.sh` | Установка в режиме прозрачного шлюза |
| `install-openwrt-xray.sh` | Установка в режиме основного роутера |
| `update-xray.sh` | Автообновление (cron + hotplug) |
| `update-nft.sh` | Применение nftables правил TProxy |
| `xray-sub-parser.py` | Парсер подписок (VLESS Base64 + JSON Happ/Sing-box) |
| `xray-generate-config.py` | Генератор config.json (DNS, routing, балансировка) |
| `setup-led-status.sh` | LED-индикация статуса Xray/интернета |

## Схема обновления

```
Cron (2:30) / Hotplug (WAN/LAN up)
        │
        ▼
  update-xray.sh
        ├─► Обновление Xray (GitHub Releases, SHA-верификация)
        ├─► Обновление geoip.dat + geosite.dat
        ├─► Скачивание подписки → парсер → генератор → config.json
        ├─► Валидация: xray run -test
        ├─► Применение nftables: update-nft.sh
        └─► Перезапуск Xray
```

## DNS (без утечек)

```
Клиенты → Xray GW:53 → TProxy → Xray routing (port 53 → dns-out → hijack)
                                                                │
dnsmasq (шлюз) → 127.0.0.1:5353 → Xray dns-local → routing ────┘
                                                                │
                                                     dns-inbuilt
                                                   ├─ ru-домены → DoH Yandex
                                                   └─ остальные → DoH Cloudflare / NextDNS
```

## Балансировка

При нескольких прокси-серверах в подписке:
- Стратегия **leastLoad** (выбор самых стабильных)
- **burstObservatory**: пинг google.com/generate_204 каждую минуту
- expected=2 сервера, maxRTT=800ms, baselines=[200ms]
- fallback → direct при падении всех серверов
- Режим **hole**: если подписка истекла → весь трафик напрямую

## Защита от петель

- Все outbound'ы Xray имеют `sockopt.mark=2`
- nftables PREROUTING: `meta mark 2 return`
- IP прокси-серверов извлекаются из config.json → bypass в nftables

## Блокировка QUIC

QUIC (UDP/443) блокируется на двух уровнях:
1. nftables: `udp dport 443 drop` (до TProxy)
2. Xray routing: `port 443 network udp → block`
Причина: VLESS+XTLS не поддерживает UDP, браузеры автоматически переходят на TCP/HTTPS.
