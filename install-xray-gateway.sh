#!/bin/sh
# OpenWrt 25.12.x — Xray Transparent Gateway (IPv4-only)
#
# Прозрачный шлюз: устройство НЕ основной роутер.
# Основной роутер (Keenetic) раздаёт DHCP, NAT, интернет.
# Xray-шлюз получает статический IP, принимает трафик клиентов,
# обрабатывает через Xray TProxy и отправляет через основной роутер в интернет.
#
# Топология:
#   Internet → Keenetic (192.168.1.1) → Xray GW (192.168.1.2) → Клиенты
#   Клиенты: gateway=192.168.1.2, dns=192.168.1.2
#
# Параметры (все опциональны, недостающие запрашиваются интерактивно):
#   --sub=URL        URL подписки
#   --ip=X.X.X.X     Статический IP шлюза
#   --mask=X.X.X.X   Маска подсети (по умолчанию 255.255.255.0)
#   --gw=X.X.X.X     IP основного роутера
#   --sub-ua=UA      User-Agent для подписки
#   --remarks=FILTER Фильтр remarks в JSON-подписке
#   --dwl=DOMAIN     Приоритетный домен для VLESS (Base64) подписок

# Логирование
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Xray Transparent Gateway — установка на OpenWrt  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

[ "$(id -u)" != "0" ] && {
	echo "[X] Запускать нужно от root"
	exit 1
}

# Проверка зависимостей
for cmd in curl python3 unzip sha256sum; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "[X] Не найден $cmd. Установите: opkg install $cmd"
		exit 1
	fi
done

# ============================================
#   TIMEZONE + NTP
# ============================================
echo "=== Синхронизация времени ==="

uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system

ntpd -q -p ru.pool.ntp.org 2>/dev/null ||
	ntpd -q -p time.google.com 2>/dev/null ||
	echo " [!] Синхронизация времени не удалась, продолжаем..."

echo "[+] Timezone: Europe/Moscow, время синхронизировано"
echo ""

# ============================================
#   ПЕРЕМЕННЫЕ
# ============================================
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT-Ggateway/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
NFT_UPDATER="/usr/share/xray/update-nft.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"
SUB_USER_AGENT="OpenWrt-Xray/1.0"

# Сетевые параметры
LAN_IF=""
LAN_IP=""
LAN_MASK="255.255.255.0"
GATEWAY_IP=""
SUB_URL=""
REMARKS_FILTER=""
DWL_DOMAIN=""

# ============================================
#   АВТООПРЕДЕЛЕНИЕ СЕТИ
# ============================================
detect_network() {
	echo "  [1/3] Определяю сетевой интерфейс..."

	if ip link show br-lan >/dev/null 2>&1; then
		LAN_IF="br-lan"
	elif ip link show eth0 >/dev/null 2>&1; then
		LAN_IF="eth0"
	elif ip link show eth1 >/dev/null 2>&1; then
		LAN_IF="eth1"
	else
		LAN_IF=$(ip -4 addr show | grep -v 'lo\|docker\|virbr\|wg\|tun' | grep 'inet ' | head -1 | awk '{print $NF}')
	fi

	[ -z "$LAN_IF" ] && { echo "[X] Не удалось определить сетевой интерфейс"; exit 1; }
	echo "    Интерфейс: $LAN_IF"

	# Определяем текущий IP
	LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	if [ -z "$LAN_IP" ]; then
		echo "    Запрашиваю IP по DHCP..."
		udhcpc -i "$LAN_IF" -q -t 5 -n 2>/dev/null || true
		sleep 2
		LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	fi

	[ -z "$LAN_IP" ] && { echo "[X] Не удалось получить IP. Проверьте кабель."; exit 1; }

	# Определяем шлюз по умолчанию
	GATEWAY_IP=$(ip route | grep '^default' | awk '{print $3}')
	if [ -z "$GATEWAY_IP" ]; then
		SUBNET=$(echo "$LAN_IP" | cut -d'.' -f1-3)
		GATEWAY_IP="${SUBNET}.1"
	fi
}

# ============================================
#   ИНТЕРАКТИВНЫЙ ВЫБОР IP
# ============================================
configure_network() {
	echo ""
	echo "  [2/3] Настройка IP-адреса шлюза"
	echo "  ─────────────────────────────────────────────"
	echo "  Обнаружена сеть:"
	echo "    Интерфейс : $LAN_IF"
	echo "    Текущий IP: $LAN_IP"
	echo "    Маска     : $LAN_MASK"
	echo "    Роутер    : $GATEWAY_IP"
	echo ""

	# Если все параметры уже заданы через аргументы — не спрашиваем
	if [ -n "$ARG_IP" ] && [ -n "$ARG_GW" ]; then
		LAN_IP="$ARG_IP"
		GATEWAY_IP="$ARG_GW"
		[ -n "$ARG_MASK" ] && LAN_MASK="$ARG_MASK"
		echo "    → Использую параметры командной строки"
		echo "    IP: $LAN_IP, маска: $LAN_MASK, роутер: $GATEWAY_IP"
		return
	fi

	# Если IP задан аргументом, но GW нет — используем IP из аргумента, GW авто
	if [ -n "$ARG_IP" ]; then
		LAN_IP="$ARG_IP"
		[ -n "$ARG_MASK" ] && LAN_MASK="$ARG_MASK"
		[ -n "$ARG_GW" ] && GATEWAY_IP="$ARG_GW"
		echo "    → IP задан аргументом: $LAN_IP"
		echo "    Роутер (авто): $GATEWAY_IP"
	fi

	echo "  Выберите действие:"
	echo "    [1] Оставить обнаруженный IP ($LAN_IP)"
	echo "    [2] Ввести другой IP вручную"
	echo "    [3] Оставить DHCP (не рекомендуется)"
	echo ""
	printf "  Ваш выбор [1]: "
	read -r CHOICE
	CHOICE="${CHOICE:-1}"

	case "$CHOICE" in
	1)
		echo "    → Оставляю: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	2)
		echo ""
		printf "    IP адрес шлюза [${LAN_IP}]: "
		read -r NEW_IP
		[ -n "$NEW_IP" ] && LAN_IP="$NEW_IP"

		printf "    Маска подсети [${LAN_MASK}]: "
		read -r NEW_MASK
		[ -n "$NEW_MASK" ] && LAN_MASK="$NEW_MASK"

		printf "    IP основного роутера [${GATEWAY_IP}]: "
		read -r NEW_GW
		[ -n "$NEW_GW" ] && GATEWAY_IP="$NEW_GW"

		echo "    → Настройки: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	3)
		echo "    → Оставляю DHCP (IP может меняться)"
		echo "    [!] ВНИМАНИЕ: Keenetic должен всегда выдавать один и тот же IP!"
		USE_DHCP=1
		;;
	*)
		echo "    → Оставляю: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	esac
}

# ============================================
#   ВВОД ПОДПИСКИ
# ============================================
configure_subscription() {
	echo ""
	echo "  [3/3] Настройка подписки"
	echo "  ─────────────────────────────────────────────"

	if [ -n "$SUB_URL" ]; then
		echo "    URL подписки: $SUB_URL"
		return
	fi

	echo "  Введите URL подписки (или укажите --sub=URL при запуске):"
	printf "  > "
	read -r SUB_URL

	while [ -z "$SUB_URL" ]; do
		echo "  [!] URL обязателен. Введите URL подписки:"
		printf "  > "
		read -r SUB_URL
	done

	echo "    URL: $SUB_URL"
}

# ============================================
#   ПАРСЕР АРГУМЕНТОВ
# ============================================
ARG_IP=""
ARG_MASK=""
ARG_GW=""
for arg in "$@"; do
	case $arg in
	--sub=*) SUB_URL="${arg#*=}" ;;
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	--ip=*) ARG_IP="${arg#*=}" ;;
	--mask=*) ARG_MASK="${arg#*=}" ;;
	--gw=*) ARG_GW="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# ============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# ============================================
download_file() {
	local url="$1"
	local dst="$2"
	shift 2
	local max_retries=3
	local retry=1

	# Добавляем cache-buster к URL (GitHub CDN кеширует raw-файлы)
	local cache_buster="_t=$(date +%s)_r=$RANDOM"
	case "$url" in
	*raw.githubusercontent.com*) url="${url}?${cache_buster}" ;;
	esac

	while [ $retry -le $max_retries ]; do
		curl -s -L --max-time 15 \
			-H "Cache-Control: no-cache, no-store" \
			-H "Pragma: no-cache" \
			${1:+-H "$1"} \
			${2:+-H "$2"} \
			${3:+-H "$3"} \
			-o "$dst" "$url"
		local rc=$?

		if [ $rc -eq 0 ] && [ -s "$dst" ]; then
			if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
				rm -f "$dst"
			else
				return 0
			fi
		fi

		if [ $retry -lt $max_retries ]; then
			sleep 2
		fi
		retry=$((retry + 1))
	done

	return 1
}

# ============================================
#   СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# ============================================
#   1. Определение сети + выбор IP + подписка
# ============================================
echo "=== Шаг 1: Настройка сети и подписки ==="

detect_network
configure_network
configure_subscription

echo ""
echo "  Итоговые настройки:"
echo "    Интерфейс : $LAN_IF"
if [ "$USE_DHCP" = "1" ]; then
	echo "    IP адрес  : DHCP (динамический)"
else
	echo "    IP адрес  : $LAN_IP / $LAN_MASK (статический)"
fi
echo "    Роутер    : $GATEWAY_IP"
echo "    Подписка  : $SUB_URL"
echo ""

# ============================================
#   2. Сохраняем подписку и User-Agent
# ============================================
echo "=== Шаг 2: Сохранение подписки ==="
echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена"

echo "$SUB_USER_AGENT" > "$CONFIG_DIR/sub_user_agent"
echo "[+] User-Agent: $SUB_USER_AGENT"

if [ -n "$REMARKS_FILTER" ]; then
	echo "$REMARKS_FILTER" > "$CONFIG_DIR/sub_remarks"
	echo "[+] Фильтр remarks: $REMARKS_FILTER"
else
	rm -f "$CONFIG_DIR/sub_remarks"
fi

# ============================================
#   3. Настройка IP (статический или DHCP)
# ============================================
echo "=== Шаг 3: Настройка IP-адреса ==="

# Запоминаем текущий IP до изменений
OLD_IP="$LAN_IP"

# Удаляем старые WAN/wan6 интерфейсы (если были с прошлой роли роутера)
uci -q delete network.wan
uci -q delete network.wan6

if [ "$USE_DHCP" = "1" ]; then
	# Оставляем DHCP
	echo "  → Режим DHCP"
	uci set network.lan.proto='dhcp'
	uci set network.lan.ipv6='0'
else
	# Статический IP
	echo "  → Статический IP: $LAN_IP / $LAN_MASK, шлюз: $GATEWAY_IP"
	uci set network.lan.proto='static'
	uci set network.lan.ipaddr="$LAN_IP"
	uci set network.lan.netmask="$LAN_MASK"
	uci set network.lan.gateway="$GATEWAY_IP"
	uci set network.lan.ipv6='0'
fi

uci set network.lan.device="$LAN_IF"

# DNS для шлюза — внешний, не зависит от Xray.
# Клиентский DNS перехватывается nftables TProxy и идёт через Xray DoH.
# Xray dns-in на 127.0.0.1:53 доступен для явных запросов.
uci set network.lan.dns='1.0.0.1'

# Отключаем DHCP-сервер (Keenetic раздаёт адреса)
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'

# Отключаем dnsmasq и odhcpd — они не нужны (нет DHCP, DNS через TProxy + Xray dns-in)
service odhcpd stop 2>/dev/null || true
service odhcpd disable 2>/dev/null || true
service dnsmasq stop 2>/dev/null || true
service dnsmasq disable 2>/dev/null || true

# Сохраняем UCI, но НЕ применяем — сеть не трогаем до ребута.
# Все настройки (IP, DNS, маршруты) подхватятся при загрузке.
uci commit network
uci commit dhcp

if [ "$USE_DHCP" != "1" ] && [ "$LAN_IP" != "$OLD_IP" ]; then
	echo ""
	echo "  ╔══════════════════════════════════════════════════╗"
	echo "  ║  [!] IP изменится при перезагрузке:              ║"
	echo "  ║      Было : $OLD_IP"
	echo "  ║      Стало: $LAN_IP"
	echo "  ║                                                 ║"
	echo "  ║  После перезагрузки подключайтесь к $LAN_IP      ║"
	echo "  ╚══════════════════════════════════════════════════╝"
	echo ""
fi
echo "[+] UCI-конфигурация сети сохранена (применится при загрузке)"

# ============================================
#   4. Установка Xray
# ============================================
echo "=== Шаг 4: Установка Xray ==="

# Ждём доступности GitHub API
for i in $(seq 1 10); do
	if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание GitHub... ($i)"
	sleep 2
done

LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && {
	echo "  [X] Не удалось получить версию Xray"
	exit 1
}

LATEST_VER_NUM="${LATEST_VERSION#v}"

CURRENT_VERSION=""
if [ -x /usr/bin/xray ]; then
	CURRENT_VERSION=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
fi

if [ "$CURRENT_VERSION" = "$LATEST_VER_NUM" ]; then
	echo "  ✓ Xray уже актуальной версии $LATEST_VERSION, пропускаем"
else
	[ -n "$CURRENT_VERSION" ] && echo "  → Текущая версия: $CURRENT_VERSION, будет обновлено до $LATEST_VER_NUM"

	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64 | amd64) MACHINE="64" ;;
	aarch64) MACHINE="arm64-v8a" ;;
	armv7l) MACHINE="arm32-v7a" ;;
	*) MACHINE="64" ;;
	esac

	ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
	ZIP_DEST="$TMP_DIR/xray.zip"
	SHA_FILE="$STATE_DIR/xray.zip.sha256sum"
	DGST_FILE="$STATE_DIR/xray.dgst"

	extract_sha256() {
		grep '^SHA2-256' "$1" |
			sed 's/.*= *//' |
			tr -cd '0-9a-fA-F' |
			cut -c1-64
	}

	echo "  → Скачиваем .dgst для Xray..."
	download_file "${ZIP_URL}.dgst" "$DGST_FILE" || {
		echo "  [X] Не удалось скачать .dgst"
		exit 1
	}

	REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Не удалось извлечь SHA2-256 из .dgst"
		exit 1
	}
	echo "  → SHA2-256: ${REMOTE_SHA:0:16}..."

	FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
	if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
		echo "  [X] Недостаточно места в /tmp"
		exit 1
	fi

	echo "  → Скачиваем Xray ZIP..."
	download_file "$ZIP_URL" "$ZIP_DEST" || {
		echo "  [X] Не удалось скачать Xray ZIP"
		exit 1
	}

	LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает!"
		exit 1
	fi

	unzip -q "$ZIP_DEST" -d "$TMP_DIR"
	cp "$TMP_DIR/xray" /usr/bin/xray
	chmod 755 /usr/bin/xray
	echo "$REMOTE_SHA" >"$SHA_FILE"
	rm -rf "$TMP_DIR"/*.zip "$TMP_DIR"/xray
	echo "[+] Xray установлен версии $LATEST_VERSION"
fi

# ============================================
#   5. Загружаем скрипты из репозитория
# ============================================
echo "=== Шаг 5: Загрузка скриптов ==="

download_script() {
	local url="$1"
	local dst="$2"
	if download_file "$url" "$dst"; then
		chmod +x "$dst"
		echo "  → $dst"
	else
		echo "  [X] Ошибка: не удалось скачать $dst"
		exit 1
	fi
}

download_script "$REPO/xray-generate-config.py" "$GENERATOR"
download_script "$REPO/xray-sub-parser.py" "$PARSER"
download_script "$REPO/update-xray.sh" "$UPDATER"
download_script "$REPO/update-nft.sh" "$NFT_UPDATER"

echo "[+] Все скрипты загружены"

# Сохраняем IP шлюза — генератору нужен для dns-in inbound
echo "$LAN_IP" > "$CONFIG_DIR/gateway_ip"

# Сохраняем приоритетный домен в файл (генератор читает его при каждом запуске)
if [ -n "$DWL_DOMAIN" ]; then
	echo "$DWL_DOMAIN" > "$CONFIG_DIR/dwl_domain"
	echo "  → Приоритетный домен сохранён: $DWL_DOMAIN"
else
	rm -f "$CONFIG_DIR/dwl_domain"
fi

# ============================================
#   6. Геофайлы + HWID + config.json
# ============================================
echo "=== Шаг 6: Геофайлы, HWID, config.json ==="

update_geo() {
	local URL="$1"
	local DEST="$2"
	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → $BASE"
	download_file "${URL}.sha256sum" "$TMP_SHA" || {
		echo "  [X] Не удалось получить SHA256 для $BASE"
		exit 1
	}
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"
	[ -z "$REMOTE_SHA" ] && { echo "  [X] Пустой SHA256 для $BASE"; exit 1; }

	# Проверяем, не тот же ли уже файл
	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
		echo "  ✓ $BASE не изменился"
		rm -f "$TMP_SHA"
		return
	fi

	download_file "$URL" "$TMP" || {
		echo "  [X] Не удалось скачать $BASE"
		exit 1
	}
	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает для $BASE"
		rm -f "$TMP" "$TMP_SHA"
		exit 1
	fi
	mv "$TMP" "$DEST"
	echo "$REMOTE_SHA" >"$SHA_FILE"
	echo "  ✓ $BASE готов"
}

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat" \
	"$GEO_DIR/geoip.dat"

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat" \
	"$GEO_DIR/geosite.dat"

# HWID
echo "  → Генерируем HWID..."
HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
echo "$HWID" >"$HWID_FILE"
chmod 600 "$HWID_FILE"
echo "  ✓ HWID: $HWID"

# Генерация config.json
echo "  → Скачиваем подписку и генерируем config.json..."

if download_file "$SUB_URL" "/tmp/sub_raw.txt" "User-Agent: $SUB_USER_AGENT" "x-hwid: $HWID"; then
	
	if head -n 1 "/tmp/sub_raw.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
		echo "  [X] Подписка вернула HTML вместо данных"
		rm -f "/tmp/sub_raw.txt"
		exit 1
	fi

	PARSER_ARGS="python3 $PARSER --ua \"$SUB_USER_AGENT\""
	[ -n "$REMARKS_FILTER" ] && PARSER_ARGS="$PARSER_ARGS --remarks \"$REMARKS_FILTER\""

	if eval $PARSER_ARGS < "/tmp/sub_raw.txt" > "/tmp/parsed.json" 2>>"$LOG_FILE"; then
		if python3 "$GENERATOR" --format unified --output "$CONFIG_JSON" < "/tmp/parsed.json" 2>>"$LOG_FILE"; then
			echo "  ✓ config.json создан"
		else
			echo "  [X] Ошибка генератора конфига"
			exit 1
		fi
	else
		echo "  [X] Ошибка парсера подписки"
		exit 1
	fi
	rm -f "/tmp/sub_raw.txt" "/tmp/parsed.json"
else
	echo "  [X] Не удалось скачать подписку"
	exit 1
fi

if [ ! -s "$CONFIG_JSON" ]; then
	echo "  [X] config.json пуст"
	exit 1
fi

echo "[+] Геофайлы загружены, конфиг сгенерирован"

# ============================================
#   7. Проверяем config.json
# ============================================
echo "=== Шаг 7: Валидация config.json ==="
if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ config.json валиден"
else
	echo "  [X] config.json НЕ прошёл проверку!"
	xray run -test -config "$CONFIG_JSON" 2>&1 | head -20
	exit 1
fi

# ============================================
#   8. Создаём init.d для Xray
# ============================================
echo "=== Шаг 8: Init.d для Xray ==="

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=85
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    # Ждём сеть
    for i in $(seq 1 15); do
        if ip route | grep -q default; then
            break
        fi
        logger -t xray "Waiting for network... ($i)"
        sleep 2
    done

    # Сохраняем IP шлюза (нужен генератору для dns-in)
    ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 > /etc/xray/gateway_ip 2>/dev/null || true

    # Синхронизация времени (важно для TLS/REALITY)
    ntpd -q -p ru.pool.ntp.org 2>/dev/null || \
    ntpd -q -p time.google.com 2>/dev/null || \
    logger -t xray "Time sync failed, continuing"
    sleep 1

    # Проверяем geo-файлы
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    # Валидация конфига
    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    # Применяем nftables правила
    /usr/share/xray/update-nft.sh || {
        logger -t xray "Failed to apply nftables rules"
        return 1
    }

    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param file "$CONF"
    procd_close_instance

    # procd запускает сервис асинхронно — ждём до 5 секунд
    for i in $(seq 1 10); do
        sleep 1
        if pidof xray >/dev/null 2>&1; then
            logger -t xray "Xray started successfully (transparent gateway mode)"
            return 0
        fi
    done

    # Не стартанул даже через 5 секунд — чистимся
    logger -t xray "Xray failed to start — cleaning nftables"
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    return 1
}

stop_service() {
    # Убираем jump-правила из fw4
    local _handle
    _handle=$(nft -a list chain inet fw4 prerouting 2>/dev/null \
        | grep 'jump xray_tproxy' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 prerouting handle "$_handle" 2>/dev/null

    _handle=$(nft -a list chain inet fw4 output 2>/dev/null \
        | grep 'jump xray_output' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 output handle "$_handle" 2>/dev/null

    # Чистим цепочки
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null

    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    logger -t xray "Stopped, network restored"
}

service_triggers() {
    procd_add_reload_trigger "xray"
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable
echo "[+] init.d для Xray создан и включён"

# ============================================
#   9. Policy routing для TProxy
# ============================================
echo "=== Шаг 9: Policy routing ==="

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables 2>/dev/null; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing table 100 (xray) добавлена"

# ============================================
#   10. Настройка sysctl
# ============================================
echo "=== Шаг 10: Sysctl ==="

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен (ip_forward + route_localnet)"

# ============================================
#   11. Применяем nftables
# ============================================
echo "=== Шаг 11: nftables ==="
"$NFT_UPDATER" || {
	echo "  [X] Не удалось применить nftables"
	# Не фатально — Xray применит при запуске
}

# ============================================
#   12. Настройка cron
# ============================================
echo "=== Шаг 12: Cron ==="

uci set system.@system[0].cronloglevel='9'
uci commit system

CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
	echo "[+] Cron: автообновление в 2:30 ночи"
else
	echo "[-] Cron уже существует"
fi

# ============================================
#   13. Настройка hotplug
# ============================================
echo "=== Шаг 13: Hotplug ==="

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "lan" ] || exit 0

# Ждём чтобы boot завершился и Xray точно был запущен через init.d
sleep 120

# Если Xray не запущен — не трогаем, init.d сам разберётся
if ! pidof xray >/dev/null; then
    exit 0
fi

# Запускаем обновление в фоне (не стартуем Xray — это делает init.d)
/usr/share/xray/update-xray.sh &
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "[+] Hotplug: автообновление при поднятии LAN"

# ============================================
#   14. Запуск служб
# ============================================
echo "=== Шаг 14: Запуск служб ==="

service cron restart 2>/dev/null || /etc/init.d/cron restart 2>/dev/null || true
service firewall restart 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true

echo "[+] Службы готовы. Xray запустится при загрузке через init.d"

# ============================================
#   15. Финальная проверка
# ============================================
echo "=== Шаг 15: Финал ==="

echo ""
echo "============================================"
echo "  Установка завершена!"
echo ""
if [ "$USE_DHCP" != "1" ] && [ "$LAN_IP" != "$OLD_IP" ]; then
	echo "  [!] IP изменится: $OLD_IP → $LAN_IP"
	echo ""
fi
echo "  Xray-шлюз: $LAN_IP"
echo "  Основной роутер (Keenetic): $GATEWAY_IP"
echo ""
echo "  Настройте Keenetic DHCP:"
echo "    Шлюз для клиентов: $LAN_IP"
echo "    DNS для клиентов:  $LAN_IP"
echo ""
echo "  Сейчас будет перезагрузка."
echo "  После неё Xray запустится автоматически."
echo "============================================"


sleep 3
reboot
