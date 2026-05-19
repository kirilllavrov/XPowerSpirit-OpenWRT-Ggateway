#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)
# Cudy как прозрачный шлюз (Keenetic как основной роутер)

# Логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy на Cudy ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "Запускать нужно от root"
	exit 1
}

# Переменные
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

# Настройки сети Cudy (можно переопределить через аргументы)
LAN_IP="192.168.1.120"
LAN_NETMASK="255.255.255.0"
GATEWAY="192.168.1.1"
DNS_SERVER="127.0.0.1"

DWL_DOMAIN=""
SUB_URL=""

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--sub=*) SUB_URL="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	--lan-ip=*) LAN_IP="${arg#*=}" ;;
	--gateway=*) GATEWAY="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Валидация
if [ -z "$SUB_URL" ]; then
	echo "[!] Ошибка: --sub=URL обязателен"
	exit 1
fi

# Создаём необходимые директории
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# =============================================
# Единые функции загрузки (curl)
# =============================================

# Базовая загрузка файла
fetch_url() {
	local url="$1"
	local dst="$2"
	local max_retries=3
	local retry=1

	while [ $retry -le $max_retries ]; do
		curl -s -L --user-agent "OpenWrt-Xray/1.0" --max-time 15 -o "$dst" "$url"
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

# Загрузка с кастомным заголовком (для подписки)
fetch_url_with_header() {
	local url="$1"
	local dst="$2"
	local header="$3"
	local max_retries=2
	local retry=1

	while [ $retry -le $max_retries ]; do
		curl -s -L --user-agent "OpenWrt-Xray/1.0" -H "$header" --max-time 20 -o "$dst" "$url"
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

ntpd -q -p 77.88.8.8 2>/dev/null ||
	ntpd -q -p 1.1.1.1 2>/dev/null ||
	echo " [!] Синхронизация времени не удалась, продолжаем..."

echo "[+] Timezone установлен в Europe/Moscow, время синхронизировано"

# =============================================
# 2. Сохраняем подписку
# =============================================
echo "2. Сохраняем подписку..."
echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена: $SUB_URL"

# =============================================
# 3. Отключаем IPv6
# =============================================
echo "3. Отключаем IPv6..."

uci set network.lan.ipv6='0'
uci set network.wan.ipv6='0'
uci -q delete network.wan6
uci commit network

echo "[+] IPv6 отключён"

# =============================================
# 4. Установка Xray из GitHub
# =============================================
echo "4. Устанавливаем Xray из GitHub..."

# Ждём доступности GitHub API
for i in $(seq 1 10); do
	if curl -s --user-agent "OpenWrt-Xray/1.0" --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание доступа к GitHub... ($i)"
	sleep 2
done

# Получаем версию Xray
LATEST_VERSION=$(curl -s --user-agent "OpenWrt-Xray/1.0" --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
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
	fetch_url "${ZIP_URL}.dgst" "$DGST_FILE" || {
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
		fetch_url "$ZIP_URL" "$ZIP_DEST" || {
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
# 5. Загружаем скрипты из репозитория
# =============================================
echo "5. Загружаем скрипты из репозитория..."

download() {
	local url="$1"
	local dst="$2"

	if fetch_url "$url" "$dst"; then
		chmod +x "$dst"
		echo "  → $dst"
	else
		echo "  [X] Ошибка: не удалось скачать $dst"
		exit 1
	fi
}

download "$REPO/xray-generate-config.py" "$GENERATOR"
download "$REPO/xray-sub-parser.py" "$PARSER"
download "$REPO/update-xray.sh" "$UPDATER"
download "$REPO/update-nft.sh" "$NFT_UPDATER"

if [ -n "$DWL_DOMAIN" ]; then
	echo "  → Добавляем домен в whitelist: $DWL_DOMAIN"
	sed -i "s/DOMAIN_WHITELIST = \[/DOMAIN_WHITELIST = [\n    \"$DWL_DOMAIN\",/" "$GENERATOR"
fi

echo "[+] Все скрипты загружены и готовы к использованию"

# =============================================
# 6. Создаём init.d для Xray
# =============================================
echo "6. Создаём init.d для Xray..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    ntpd -q -p 77.88.8.8 2>/dev/null || \
    ntpd -q -p 1.0.0.1 2>/dev/null || \
    logger -t xray "Time sync failed, continuing anyway"
    sleep 1

    # Применяем базовые nftables правила (без резолвинга прокси)
    if [ -x /usr/share/xray/update-nft.sh ]; then
        /usr/share/xray/update-nft.sh --no-resolve &
    else
        logger -t xray "update-nft.sh not found or not executable"
    fi

    # Проверяем наличие геофайлов
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh manually"
    fi

    # Проверяем валидность конфига
    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json — run update-xray.sh manually"
    fi

    # Запускаем Xray
    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param file "$CONF"
    procd_close_instance

    sleep 1
    if ! pidof xray >/dev/null; then
        logger -t xray "Xray failed to start — disabling TProxy"
        nft delete table inet xray 2>/dev/null
        while ip rule del fwmark 2 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null
        return 1
    fi

    logger -t xray "Xray started successfully"
}

stop_service() {
    nft delete table inet xray 2>/dev/null
    while ip rule del fwmark 2 table 100 2>/dev/null; do :; done
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
# 7. Настраиваем routing
# =============================================
echo "7. Настраиваем routing..."

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing настроен"

# =============================================
# 8. Настраиваем sysctl
# =============================================
echo "8. Настраиваем sysctl:"

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен"

# =============================================
# 9. Geo + HWID + config.json
# =============================================
echo "9. Скачиваем геофайлы, делаем HWID, генерируем config.json..."

update_geo() {
	local URL="$1"
	local DEST="$2"

	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → Скачиваем $BASE"

	fetch_url "${URL}.sha256sum" "$TMP_SHA" || {
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	}
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"

	if [ -z "$REMOTE_SHA" ]; then
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	fi

	fetch_url "$URL" "$TMP" || {
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

echo "  → Генерируем config.json из подписки..."
if fetch_url_with_header "$SUB_URL" "/tmp/sub_raw.txt" "x-hwid: $HWID"; then
	python3 "$PARSER" <"/tmp/sub_raw.txt" >"/tmp/parsed_outbounds.json" || {
		echo "  [X] Ошибка парсера подписки"
		rm -f "/tmp/sub_raw.txt"
		exit 1
	}
	python3 "$GENERATOR" --output "$CONFIG_JSON" <"/tmp/parsed_outbounds.json" || {
		echo "  [X] Ошибка генератора конфига"
		rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
		exit 1
	}
	rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
else
	echo "  [X] Не удалось скачать подписку"
	exit 1
fi

if [ ! -s "$CONFIG_JSON" ]; then
	echo "  [X] Ошибка: не удалось создать config.json" >>"$LOG_FILE"
	exit 1
fi
echo "  ✓ config.json создан"
echo ""
echo "[+] Геофайлы загружены, конфиг сгенерирован"

# =============================================
# 10. Cron: автообновление в 2.30 ночи
# =============================================
echo "10. Настройка Crontab..."

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
# 11. Настройка hotplug (автообновление после поднятия LAN)
# =============================================
echo "11. Настройка hotplug..."

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "lan" ] || exit 0

# Запускаем обновление в фоне (один раз после поднятия сети)
/usr/share/xray/update-xray.sh &
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "[+] Hotplug для автообновления после поднятия LAN настроен"

# =============================================
# 12. Запуск и рестарт служб
# =============================================
echo "12. Запускаем службы..."

service odhcpd stop 2>/dev/null || true
service odhcpd disable 2>/dev/null || true
service dnsmasq stop 2>/dev/null || true
service dnsmasq disable 2>/dev/null || true
uci set dhcp.lan.ignore='1'
uci commit dhcp
sleep 2

service cron restart
service firewall restart

sleep 3
service xray start
sleep 3

echo "[+] Службы запущены"

sleep 3

# =============================================
# 13. Проверяем config.json и Xray
# =============================================
echo "13. Проверяем config.json для Xray на валидность..."
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
echo "=== Установка Xray завершена ==="

#=============================================
# 14. Настройка сети для прозрачного шлюза
# =============================================
echo "14. Настройка сети для прозрачного шлюза..."

# Настраиваем статический IP для роутера
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_NETMASK"
uci set network.lan.gateway="$GATEWAY"
uci set network.lan.dns="$DNS_SERVER 1.0.0.1"
uci commit network
echo "[+] DHCP на роутере отключён"
echo "[+] Роутер настроен: IP=$LAN_IP, шлюз=$GATEWAY, DNS=$DNS_SERVER 1.0.0.1"

# Обновляем IP в nftables скрипте для корректного bypass управления
if [ -f "$NFT_UPDATER" ]; then
	sed -i "s/ip daddr [0-9.]\+ tcp dport/ip daddr $LAN_IP tcp dport/" "$NFT_UPDATER"
	echo "[+] IP в nftables обновлён: $LAN_IP"
fi

echo ""
echo "=== Установка Xray завершена ==="
echo "=== Роутер настроен как прозрачный шлюз ==="
echo "=== IP роутера после перезагрузки: $LAN_IP ==="
echo ""
echo "Перезагружаем роутер для применения всех настроек..."

reboot
