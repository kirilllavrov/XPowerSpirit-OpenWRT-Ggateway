#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

# Логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "Запускать нужно от root"
	exit 1
}

# Переменные
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

DWL_DOMAIN=""
SUB_URL=""
REMARKS_FILTER=""

# Гостевая сеть
GUEST_ENABLED=0
GUEST_NET="guest"
GUEST_IP="192.168.2.1"
DL_GUEST="5120"
UL_GUEST="5120"

# PPPoE переменные
PPPOE_ENABLED=0
PPPOE_USER=""
PPPOE_PASS=""

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--guest=1) GUEST_ENABLED=1 ;;
	--guest-ip=*) GUEST_IP="${arg#*=}" ;;
	--guest-dl=*) DL_GUEST="${arg#*=}" ;;
	--guest-ul=*) UL_GUEST="${arg#*=}" ;;
	--sub=*) SUB_URL="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	--pppoe=1) PPPOE_ENABLED=1 ;;
	--pppoe-user=*) PPPOE_USER="${arg#*=}" ;;
	--pppoe-pass=*) PPPOE_PASS="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Валидация
if [ -z "$SUB_URL" ]; then
	echo "[!] Ошибка: --sub=URL обязателен"
	exit 1
fi

if [ $PPPOE_ENABLED -eq 1 ]; then
	if [ -z "$PPPOE_USER" ] || [ -z "$PPPOE_PASS" ]; then
		echo "[!] Ошибка: --pppoe=1 требует --pppoe-user и --pppoe-pass"
		exit 1
	fi
fi

# Создаём необходимые директории
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# =============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# =============================================

# Универсальная загрузка файла (с поддержкой до 3 кастомных заголовков)
# Использование:
#   download_file "URL" "DEST" ["HEADER1" "HEADER2" "HEADER3"]
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

# =============================================
# 1. Устанавливаем Timezone и синхронизируем время
# =============================================
echo "1. Устанавливаем Timezone и синхронизируем время..."
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system

ntpd -q -p ru.pool.ntp.org 2>/dev/null ||
	ntpd -q -p time.google.com 2>/dev/null ||
	echo " [!] Синхронизация времени не удалась, продолжаем..."

echo "[+] Timezone установлен в Europe/Moscow, время синхронизировано"

# =============================================
# 2. Просим подписку
# =============================================
echo "2. Просим подписку..."
echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена: $SUB_URL"

# =============================================
# 2.5. Сохраняем User-Agent и remarks фильтр
# =============================================
echo "$SUB_USER_AGENT" > "$CONFIG_DIR/sub_user_agent"
echo "[+] User-Agent сохранён: $SUB_USER_AGENT"

if [ -n "$REMARKS_FILTER" ]; then
    echo "$REMARKS_FILTER" > "$CONFIG_DIR/sub_remarks"
    echo "[+] Фильтр remarks сохранён: $REMARKS_FILTER"
else
    rm -f "$CONFIG_DIR/sub_remarks"
fi

# =============================================
# 3. Отключаем IPv6
# =============================================
echo "3. Отключаем IPv6..."

uci set network.lan.ipv6='0'
uci set network.wan.ipv6='0'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci -q delete network.wan6
uci commit network
uci commit dhcp

/etc/init.d/odhcpd stop 2>/dev/null || true
/etc/init.d/odhcpd disable 2>/dev/null || true

if ! service network restart; then
	echo "  [X] Не удалось перезапустить сеть после отключения IPv6"
	exit 1
fi
sleep 5
for i in $(seq 1 10); do
	ip link show br-lan >/dev/null 2>&1 && break
	sleep 2
done

echo "[+] IPv6 отключён"

# =============================================
# 3.5. Настройка PPPoE (если включён)
# =============================================
if [ $PPPOE_ENABLED -eq 1 ]; then
	echo "3.5. Настройка PPPoE соединения..."
	
	uci set network.wan.proto='pppoe'
	uci set network.wan.device='wan'
	uci set network.wan.username="$PPPOE_USER"
	uci set network.wan.password="$PPPOE_PASS"
	uci set network.wan.keepalive='4 5'
	uci set network.wan.mtu='1492'
	uci set network.wan.ipv6='0'
	uci set network.wan.peerdns='1'
	uci set network.wan.defaultroute='1'
	
	uci commit network
	
	echo "[+] PPPoE настроен (логин: $PPPOE_USER)"
fi

# =============================================
# 4. Настраиваем гостевую сеть и лимиты скорости (если включена)
# =============================================
if [ $GUEST_ENABLED -eq 1 ]; then
	echo "4. Настройка Guest Network и SQM:"

	# 4.1. Guest Bridge + Interface
	uci -q delete network.${GUEST_NET}_dev
	uci set network.${GUEST_NET}_dev="device"
	uci set network.${GUEST_NET}_dev.type="bridge"
	uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"
	uci set network.${GUEST_NET}_dev.bridge_empty="1"
	uci set network.${GUEST_NET}_dev.mtu="1500"

	uci -q delete network.$GUEST_NET
	uci set network.$GUEST_NET="interface"
	uci set network.$GUEST_NET.proto="static"
	uci set network.$GUEST_NET.device="br-${GUEST_NET}"
	uci set network.$GUEST_NET.ipaddr="$GUEST_IP"
	uci set network.$GUEST_NET.netmask="255.255.255.0"
	uci set network.$GUEST_NET.force_link="1"
	uci commit network
	echo "  → Guest Bridge + Interface настроены: br-${GUEST_NET} (${GUEST_IP}/24)"

	# 4.2. DHCP Guest
	uci -q delete dhcp.$GUEST_NET
	uci set dhcp.$GUEST_NET="dhcp"
	uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
	uci set dhcp.$GUEST_NET.start="100"
	uci set dhcp.$GUEST_NET.limit="150"
	uci set dhcp.$GUEST_NET.leasetime="12h"
	uci set dhcp.$GUEST_NET.force="1"
	uci set dhcp.$GUEST_NET.ignore="0"
	uci commit dhcp
	echo "  → DHCP для Guest настроен: $GUEST_NET"

	# 4.3. Firewall Guest Zone + Rules
	uci -q delete firewall.$GUEST_NET
	uci set firewall.$GUEST_NET="zone"
	uci set firewall.$GUEST_NET.name="$GUEST_NET"
	uci set firewall.$GUEST_NET.network="$GUEST_NET"
	uci set firewall.$GUEST_NET.input="REJECT"
	uci set firewall.$GUEST_NET.output="ACCEPT"
	uci set firewall.$GUEST_NET.forward="REJECT"
	uci set firewall.$GUEST_NET.masq="1"
	uci set firewall.$GUEST_NET.mtu_fix="1"
	echo "  → Firewall зона для Guest создана: $GUEST_NET"

	# 4.4 Firewall DNS
	uci -q delete firewall.${GUEST_NET}_dns
	uci set firewall.${GUEST_NET}_dns="rule"
	uci set firewall.${GUEST_NET}_dns.name="Allow-DNS-Guest"
	uci set firewall.${GUEST_NET}_dns.src="$GUEST_NET"
	uci set firewall.${GUEST_NET}_dns.dest_port="53"
	uci set firewall.${GUEST_NET}_dns.proto="tcp udp"
	uci set firewall.${GUEST_NET}_dns.target="ACCEPT"
	echo "  → Firewall правило для DNS создано: $GUEST_NET"

	# 4.5 Firewall DHCP
	uci -q delete firewall.${GUEST_NET}_dhcp
	uci set firewall.${GUEST_NET}_dhcp="rule"
	uci set firewall.${GUEST_NET}_dhcp.name="Allow-DHCP-Guest"
	uci set firewall.${GUEST_NET}_dhcp.src="$GUEST_NET"
	uci set firewall.${GUEST_NET}_dhcp.dest_port="67-68"
	uci set firewall.${GUEST_NET}_dhcp.proto="udp"
	uci set firewall.${GUEST_NET}_dhcp.target="ACCEPT"
	echo "  → Firewall правило для DHCP создано: $GUEST_NET"

	# 4.6 Forward to WAN
	uci -q delete firewall.${GUEST_NET}_wan
	uci set firewall.${GUEST_NET}_wan="forwarding"
	uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
	uci set firewall.${GUEST_NET}_wan.dest="wan"
	uci commit firewall
	echo "  → Firewall правило для доступа Guest в WAN создано: $GUEST_NET → wan"

	# 4.7 Настраиваем SQM только для Guest
	uci -q delete sqm.$GUEST_NET
	uci set sqm.$GUEST_NET="queue"
	uci set sqm.$GUEST_NET.interface="br-${GUEST_NET}"
	uci set sqm.$GUEST_NET.download="$DL_GUEST"
	uci set sqm.$GUEST_NET.upload="$UL_GUEST"
	uci set sqm.$GUEST_NET.qdisc="cake"
	uci set sqm.$GUEST_NET.script="piece_of_cake.qos"
	uci set sqm.$GUEST_NET.enabled="1"
	uci commit sqm
	echo "  → SQM настроен для Guest: ${DL_GUEST}kbps down / ${UL_GUEST}kbps up"

	echo "Применяем сетевые изменения..."
	if ! service network restart; then
		echo "  [X] Не удалось перезапустить сеть после настройки гостевой сети"
		exit 1
	fi
	sleep 5
	for i in $(seq 1 10); do
		ip link show br-guest >/dev/null 2>&1 && break
		sleep 1
	done
	service firewall restart

	echo "[+] Настройка Guest Network и SQM завершена"
else
	echo "4. Пропускаем настройку гостевой сети (--guest=1 не указан)"
fi

# =============================================
# 5. Установка Xray из GitHub
# =============================================
echo "5. Устанавливаем Xray из GitHub..."

# Ждём доступности GitHub API
for i in $(seq 1 10); do
	if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание доступа к GitHub... ($i)"
	sleep 2
done

# Получаем версию Xray
LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && {
	echo "  [X] Ошибка: не удалось получить версию Xray"
	exit 1
}

LATEST_VER_NUM="${LATEST_VERSION#v}"

# Проверяем, какая версия уже установлена
CURRENT_VERSION=""
if [ -x /usr/bin/xray ]; then
	CURRENT_VERSION=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
fi

if [ "$CURRENT_VERSION" = "$LATEST_VER_NUM" ]; then
	echo "  ✓ Xray уже актуальной версии $LATEST_VERSION, пропускаем установку"
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

	echo "  → Версия: $LATEST_VERSION, архитектура: $MACHINE"
	echo "  → URL: ${ZIP_URL}.dgst"

	echo "  → Скачиваем .dgst для Xray..."
	download_file "${ZIP_URL}.dgst" "$DGST_FILE" || {
		echo "  [X] Ошибка: не удалось скачать .dgst для Xray"
		exit 1
	}

	if [ ! -s "$DGST_FILE" ] || ! grep -q 'SHA2-256' "$DGST_FILE" 2>/dev/null; then
		echo "  [X] Ошибка: .dgst файл пустой или не содержит SHA2-256"
		echo "  → Содержимое ответа:"
		cat "$DGST_FILE" 2>/dev/null || echo " (файл пустой)"
		exit 1
	fi

	REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Ошибка: не удалось извлечь SHA2-256 из .dgst"
		exit 1
	}

	echo "  → Ожидаемый SHA2-256: ${REMOTE_SHA:0:16}..."

	FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
	if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
		echo "  [X] Недостаточно места в /tmp (нужно минимум 20MB)" >>"$LOG_FILE"
		exit 1
	fi

	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$ZIP_DEST" ]; then
		echo "  ✓ Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
	else
		echo "  → Скачиваем Xray ZIP (${LATEST_VERSION})..."
		download_file "$ZIP_URL" "$ZIP_DEST" || {
			echo "  [X] Ошибка: не удалось скачать Xray ZIP"
			exit 1
		}

		if [ ! -s "$ZIP_DEST" ]; then
			echo "  [X] Ошибка: скачанный ZIP пустой"
			exit 1
		fi

		LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
		if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
			echo "  [X] Ошибка: SHA не совпадает!"
			echo "  ожидалось: $REMOTE_SHA"
			echo "  получено : $LOCAL_SHA"
			exit 1
		fi

		echo "$REMOTE_SHA" >"$SHA_FILE"
	fi

	unzip -q "$ZIP_DEST" -d "$TMP_DIR"

	cp "$TMP_DIR/xray" /usr/bin/xray
	chmod 755 /usr/bin/xray

	rm -rf "$TMP_DIR"
	echo "[+] Xray установлен версии $LATEST_VERSION"
fi

# =============================================
# 6. Загружаем скрипты из репозитория
# =============================================
echo "6. Загружаем скрипты из репозитория..."

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

if [ -n "$DWL_DOMAIN" ]; then
	echo "  → Добавляем домен в whitelist: $DWL_DOMAIN"
	sed -i "s/DOMAIN_WHITELIST = \[/DOMAIN_WHITELIST = [\n    \"$DWL_DOMAIN\",/" "$GENERATOR"
fi

echo "[+] Все скрипты загружены и готовы к использованию"

# =============================================
# 7. Настройка DNS (dnsmasq → Xray)
# =============================================
echo "7. Настраиваем DNS (dnsmasq → Xray)..."

uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].max_cache_ttl='1800'

uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci add_list dhcp.@dnsmasq[0].server='77.88.8.8'
uci commit dhcp

echo "[+] DNS настроен (dnsmasq → Xray:5353 + fallback 77.88.8.8)"

# =============================================
# 8. Создаём init.d для Xray
# =============================================
echo "8. Создаём init.d для Xray..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    ntpd -q -p ru.pool.ntp.org 2>/dev/null || \
    ntpd -q -p time.google.com 2>/dev/null || \
    logger -t xray "Time sync failed, continuing anyway"
    sleep 1
    
    for i in $(seq 1 15); do
        if ip route | grep -q default && resolveip -4 google.com >/dev/null 2>&1; then
            break
        fi
        logger -t xray "Waiting for network/DNS... ($i)"
        sleep 2
    done

    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    /usr/share/xray/update-nft.sh || return 1

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
        logger -t xray "Xray failed to start — disabling TProxy"
        nft flush chain inet fw4 xray_tproxy 2>/dev/null
        nft delete chain inet fw4 xray_tproxy 2>/dev/null
        nft flush chain inet fw4 xray_output 2>/dev/null
        nft delete chain inet fw4 xray_output 2>/dev/null
        while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null
        return 1
    fi

    logger -t xray "Xray started successfully"
}

stop_service() {
    # Удаляем jump xray_tproxy из prerouting (по handle)
    local _handle
    _handle=$(nft -a list chain inet fw4 prerouting 2>/dev/null \
        | grep 'jump xray_tproxy' \
        | sed 's/.*handle //' \
        | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 prerouting handle "$_handle" 2>/dev/null

    # Удаляем jump xray_output из output (по handle)
    _handle=$(nft -a list chain inet fw4 output 2>/dev/null \
        | grep 'jump xray_output' \
        | sed 's/.*handle //' \
        | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 output handle "$_handle" 2>/dev/null

    # Очищаем и удаляем цепочки
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null

    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    logger -t xray "Stopped, network cleaned"
}

service_triggers() {
    procd_add_reload_trigger "xray"
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable

echo "[+] init.d для Xray создан и включён"

# =============================================
# 9. Настраиваем routing
# =============================================
echo "9. Настраиваем routing..."

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing настроен"

# =============================================
# 10. Настраиваем sysctl
# =============================================
echo "10. Настраиваем sysctl:"

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен"

# =============================================
# 11. Geo + HWID + config.json (с поддержкой двух форматов)
# =============================================
echo "11. Скачиваем геофайлы, делаем HWID, генерируем config.json..."

update_geo() {
	local URL="$1"
	local DEST="$2"

	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → Скачиваем $BASE"

	download_file "${URL}.sha256sum" "$TMP_SHA" || {
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	}
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"

	if [ -z "$REMOTE_SHA" ]; then
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	fi

	download_file "$URL" "$TMP" || {
		echo "  [X] Не удалось скачать $BASE" >>"$LOG_FILE"
		exit 1
	}

	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"

	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает для $BASE" >>"$LOG_FILE"
		echo "ожидаемый: $REMOTE_SHA" >>"$LOG_FILE"
		echo "фактический:   $LOCAL_SHA" >>"$LOG_FILE"
		rm -f "$TMP" "$TMP_SHA"
		exit 1
	fi

	mv "$TMP" "$DEST"
	echo "$REMOTE_SHA" >"$SHA_FILE"

	echo "  ✓ $BASE скачан и проверен"
}

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat" \
	"$GEO_DIR/geoip.dat"

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat" \
	"$GEO_DIR/geosite.dat"

echo "  → Генерируем HWID..."
HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
echo "$HWID" >"$HWID_FILE"
chmod 600 "$HWID_FILE"
echo "  ✓ HWID сохранён: $HWID"

echo "  → Генерируем config.json из подписки (User-Agent: $SUB_USER_AGENT)..."

# Скачиваем подписку с заголовками
if download_file "$SUB_URL" "/tmp/sub_raw.txt" "User-Agent: $SUB_USER_AGENT" "x-hwid: $HWID"; then
    
    # Проверяем, что скачалось не HTML
    if head -n 1 "/tmp/sub_raw.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        echo "  [X] Подписка вернула HTML, а не данные"
        rm -f "/tmp/sub_raw.txt"
        exit 1
    fi
    
    # Единый пайплайн: парсер (с автоопределением формата) → генератор
    PARSER_ARGS="python3 $PARSER --ua \"$SUB_USER_AGENT\""
    [ -n "$REMARKS_FILTER" ] && PARSER_ARGS="$PARSER_ARGS --remarks \"$REMARKS_FILTER\""
    
    if eval $PARSER_ARGS < "/tmp/sub_raw.txt" > "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"; then
        if python3 "$GENERATOR" --format unified --output "$CONFIG_JSON" < "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"; then
            echo "  ✓ config.json создан"
        else
            echo "  [X] Ошибка генератора конфига"
            rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
            exit 1
        fi
    else
        echo "  [X] Ошибка парсера подписки"
        rm -f "/tmp/sub_raw.txt"
        exit 1
    fi
    rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
else
    echo "  [X] Не удалось скачать подписку"
    exit 1
fi

if [ ! -s "$CONFIG_JSON" ]; then
    echo "  [X] Ошибка: не удалось создать config.json" >>"$LOG_FILE"
    exit 1
fi
echo ""
echo "[+] Геофайлы загружены, конфиг сгенерирован"

# =============================================
# 12. Cron: автообновление в 2.30 ночи
# =============================================
echo "12. Настройка Crontab..."

uci set system.@system[0].cronloglevel='9'
uci commit system

CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(
		crontab -l 2>/dev/null || true
		echo "$CRON_ENTRY"
	) | crontab -
	echo "[+] Cron-задача для обновления Xray добавлена: $CRON_ENTRY"
else
	echo "[-] Cron-задача уже существует, пропускаем"
fi

# =============================================
# 13. Настройка hotplug (автообновление после включения WAN)
# =============================================
echo "13. Настройка hotplug..."

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

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
echo "[+] Hotplug для автообновления после включения WAN настроен"

# =============================================
# 14. Запуск и рестарт служб
# =============================================
echo "14. Запускаем службы..."

service cron restart
service firewall restart

if [ $GUEST_ENABLED -eq 1 ]; then
	service sqm restart
fi

sleep 3
service xray start
sleep 3
service dnsmasq restart

echo "[+] Службы запущены"

sleep 3

# =============================================
# 15. Проверяем config.json и Xray
# =============================================
echo "15. Проверяем config.json для Xray на валидность..."
if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ $CONFIG_JSON прошел проверку"
else
	echo "  [X] $CONFIG_JSON НЕ прошел проверку!"
	exit 1
fi

echo "  → Проверяем, запущен ли Xray:"
if pgrep -a xray >/dev/null; then
	echo "  ✓ Xray запущен"
else
	echo "  [X] Xray НЕ запущен"
fi

echo ""
echo "=== Установка завершена ==="