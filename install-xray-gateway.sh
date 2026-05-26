#!/bin/sh
# OpenWrt 25.12.x — Xray Transparent Gateway (IPv4-only)
#
# Режим прозрачного шлюза:
#   Устройство НЕ является основным роутером.
#   Основной роутер (Keenetic) раздаёт DHCP, NAT, интернет.
#   Xray-шлюз получает статический IP, принимает трафик клиентов,
#   обрабатывает через Xray TProxy и отправляет через основной роутер в интернет.
#
# Топология:
#   Internet → Keenetic (192.168.1.1) → Xray GW (192.168.1.2) → Клиенты
#   Клиенты: gateway=192.168.1.2, dns=192.168.1.2

# Логирование
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray Transparent Gateway ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "[X] Запускать нужно от root"
	exit 1
}

# ============================================
#   ПЕРЕМЕННЫЕ
# ============================================
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
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

# Сетевые параметры (автоопределение или ручное задание)
LAN_IF=""
LAN_IP=""
LAN_MASK="255.255.255.0"
KEENETIC_IP=""
SUB_URL=""
REMARKS_FILTER=""

# ============================================
#   АВТООПРЕДЕЛЕНИЕ СЕТИ
# ============================================
detect_network() {
	echo "→ Автоопределение сетевых параметров..."

	# Ищем LAN интерфейс (bridge или eth)
	if ip link show br-lan >/dev/null 2>&1; then
		LAN_IF="br-lan"
	elif ip link show eth0 >/dev/null 2>&1; then
		LAN_IF="eth0"
	elif ip link show eth1 >/dev/null 2>&1; then
		LAN_IF="eth1"
	else
		# Пробуем найти интерфейс с IP
		LAN_IF=$(ip -4 addr show | grep -v 'lo\|docker\|virbr\|wg\|tun' | grep 'inet ' | head -1 | awk '{print $NF}')
	fi

	if [ -z "$LAN_IF" ]; then
		echo "[X] Не удалось определить сетевой интерфейс"
		exit 1
	fi
	echo "  → LAN интерфейс: $LAN_IF"

	# Определяем текущий IP и шлюз
	LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	if [ -z "$LAN_IP" ]; then
		# Если нет IP, пробуем получить через DHCP
		echo "  → Запрашиваю IP по DHCP..."
		udhcpc -i "$LAN_IF" -q -t 5 -n 2>/dev/null || true
		sleep 2
		LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	fi

	if [ -z "$LAN_IP" ]; then
		echo "[X] Не удалось получить IP-адрес на $LAN_IF"
		echo "  → Проверьте подключение кабеля к Keenetic"
		exit 1
	fi
	echo "  → Текущий IP: $LAN_IP"

	# Определяем Keenetic (текущий default gateway)
	KEENETIC_IP=$(ip route | grep '^default' | awk '{print $3}')
	if [ -z "$KEENETIC_IP" ]; then
		# Пробуем угадать: первый IP подсети
		SUBNET=$(echo "$LAN_IP" | cut -d'.' -f1-3)
		KEENETIC_IP="${SUBNET}.1"
		echo "  → Шлюз не найден, предполагаю: $KEENETIC_IP"
	else
		echo "  → Основной шлюз (Keenetic): $KEENETIC_IP"
	fi
}

# ============================================
#   ПАРСЕР АРГУМЕНТОВ
# ============================================
for arg in "$@"; do
	case $arg in
	--sub=*) SUB_URL="${arg#*=}" ;;
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--ip=*) LAN_IP="${arg#*=}" ;;
	--mask=*) LAN_MASK="${arg#*=}" ;;
	--gw=*) KEENETIC_IP="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Валидация
if [ -z "$SUB_URL" ]; then
	echo "[X] Ошибка: --sub=URL обязателен"
	exit 1
fi

# ============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# ============================================
download_file() {
	local url="$1"
	local dst="$2"
	shift 2
	local max_retries=3
	local retry=1

	while [ $retry -le $max_retries ]; do
		curl -s -L --max-time 15 \
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
#   1. Автоопределение сети
# ============================================
echo "1. Определяем сетевые параметры..."
detect_network
echo "[+] Сеть определена: $LAN_IF = $LAN_IP, шлюз = $KEENETIC_IP"

# ============================================
#   2. Сохраняем подписку
# ============================================
echo "2. Сохраняем подписку..."
echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена: $SUB_URL"

echo "$SUB_USER_AGENT" > "$CONFIG_DIR/sub_user_agent"
echo "[+] User-Agent: $SUB_USER_AGENT"

if [ -n "$REMARKS_FILTER" ]; then
	echo "$REMARKS_FILTER" > "$CONFIG_DIR/sub_remarks"
	echo "[+] Фильтр remarks: $REMARKS_FILTER"
else
	rm -f "$CONFIG_DIR/sub_remarks"
fi

# ============================================
#   3. Настройка статического IP
# ============================================
echo "3. Настраиваем статический IP ($LAN_IP/$LAN_MASK, шлюз $KEENETIC_IP)..."

# Удаляем старые WAN/wan6 интерфейсы (если были с прошлой роли роутера)
uci -q delete network.wan
uci -q delete network.wan6

# Настраиваем LAN как статический
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_MASK"
uci set network.lan.gateway="$KEENETIC_IP"
uci set network.lan.ipv6='0'

# Убеждаемся, что LAN привязан к правильному устройству
uci set network.lan.device="$LAN_IF"

# DNS: dnsmasq форвардит на Xray (127.0.0.1:5353) для собственных нужд шлюза
# Клиентский DNS перехватывается nftables TProxy (правило 3) и идёт через Xray DoH
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci add_list dhcp.@dnsmasq[0].server='77.88.8.8'

# Отключаем DHCP-сервер (Keenetic раздаёт адреса)
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'

uci commit network
uci commit dhcp

# Применяем сетевые изменения
echo "  → Применяем настройки сети..."
/etc/init.d/network reload 2>/dev/null || service network reload 2>/dev/null || true
sleep 3

# Проверяем, что IP применился
ACTUAL_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [ "$ACTUAL_IP" != "$LAN_IP" ]; then
	echo "  [!] IP не совпадает (ожидалось $LAN_IP, получено $ACTUAL_IP)"
	echo "  → Пробуем принудительно..."
	ip addr flush dev "$LAN_IF" 2>/dev/null
	ip addr add "${LAN_IP}/24" dev "$LAN_IF"
	ip route add default via "$KEENETIC_IP" 2>/dev/null
	sleep 1
fi

echo "[+] Статический IP настроен: $LAN_IP, шлюз: $KEENETIC_IP"

# ============================================
#   4. Настройка DNS (dnsmasq → Xray)
# ============================================
echo "4. Настраиваем DNS..."

uci set dhcp.@dnsmasq[0].cachesize='1000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].max_cache_ttl='1800'
uci commit dhcp

# Перезапускаем dnsmasq (без DHCP, только DNS forwarder)
/etc/init.d/dnsmasq restart 2>/dev/null || service dnsmasq restart 2>/dev/null || true

echo "[+] DNS настроен (dnsmasq → 127.0.0.1:5353 → Xray DoH + fallback 77.88.8.8)"

# ============================================
#   5. Установка Xray из GitHub
# ============================================
echo "5. Устанавливаем Xray из GitHub..."

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
#   6. Загружаем скрипты из репозитория
# ============================================
echo "6. Загружаем скрипты..."

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

# ============================================
#   7. Геофайлы + HWID + config.json
# ============================================
echo "7. Скачиваем геофайлы, HWID, генерируем config.json..."

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
#   8. Проверяем config.json
# ============================================
echo "8. Валидация config.json..."
if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ config.json валиден"
else
	echo "  [X] config.json НЕ прошёл проверку!"
	xray run -test -config "$CONFIG_JSON" 2>&1 | head -20
	exit 1
fi

# ============================================
#   9. Создаём init.d для Xray
# ============================================
echo "9. Создаём init.d для Xray..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    # Синхронизация времени (важно для TLS/REALITY)
    ntpd -q -p ru.pool.ntp.org 2>/dev/null || \
    ntpd -q -p time.google.com 2>/dev/null || \
    logger -t xray "Time sync failed, continuing"
    sleep 1

    # Ждём сеть и DNS
    for i in $(seq 1 15); do
        if ip route | grep -q default; then
            break
        fi
        logger -t xray "Waiting for network... ($i)"
        sleep 2
    done

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

    sleep 1
    if ! pidof xray >/dev/null; then
        logger -t xray "Xray failed to start — cleaning nftables"
        nft flush chain inet fw4 xray_tproxy 2>/dev/null
        nft delete chain inet fw4 xray_tproxy 2>/dev/null
        nft flush chain inet fw4 xray_output 2>/dev/null
        nft delete chain inet fw4 xray_output 2>/dev/null
        while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null
        return 1
    fi

    logger -t xray "Xray started successfully (transparent gateway mode)"
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
#   10. Настройка routing (policy routing для TProxy)
# ============================================
echo "10. Настраиваем policy routing..."

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables 2>/dev/null; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing table 100 (xray) добавлена"

# ============================================
#   11. Настройка sysctl
# ============================================
echo "11. Настраиваем sysctl..."

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен (ip_forward + route_localnet)"

# ============================================
#   12. Применяем nftables
# ============================================
echo "12. Применяем nftables правила..."
"$NFT_UPDATER" || {
	echo "  [X] Не удалось применить nftables"
	# Не фатально — Xray применит при запуске
}

# ============================================
#   13. Настройка cron
# ============================================
echo "13. Настройка cron..."

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
#   14. Настройка hotplug
# ============================================
echo "14. Настройка hotplug..."

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "lan" ] || exit 0

if ! pidof xray >/dev/null; then
    /etc/init.d/xray start
    sleep 5
fi

for i in 1 2 3 4 5 6 7; do
    sleep 5
    if curl -fs --max-time 3 https://www.google.com/gen_204 >/dev/null; then
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "[+] Hotplug: автообновление при поднятии LAN"

# ============================================
#   15. Запуск служб
# ============================================
echo "15. Запускаем службы..."

service cron restart 2>/dev/null || /etc/init.d/cron restart 2>/dev/null || true
service firewall restart 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true

sleep 2
/etc/init.d/xray start
sleep 3

# Перезапускаем dnsmasq (чтобы подхватил настройки после Xray)
/etc/init.d/dnsmasq restart 2>/dev/null || service dnsmasq restart 2>/dev/null || true

# ============================================
#   16. Финальная проверка
# ============================================
echo "16. Финальная проверка..."

if pgrep -a xray >/dev/null; then
	echo "  ✓ Xray запущен"
else
	echo "  [!] Xray НЕ запущен — проверьте логи:"
	echo "      tail -f /tmp/log/xray-error.log"
fi

echo ""
echo "============================================"
echo "  Установка завершена!"
echo ""
echo "  Xray-шлюз: $LAN_IP"
echo "  Основной роутер (Keenetic): $KEENETIC_IP"
echo ""
echo "  Настройте Keenetic DHCP:"
echo "    Шлюз для клиентов: $LAN_IP"
echo "    DNS для клиентов:  $LAN_IP"
echo ""
echo "  Проверка: curl --interface $LAN_IF https://ifconfig.me"
echo "============================================"
