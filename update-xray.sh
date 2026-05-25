#!/bin/sh
# OpenWrt — обновление Xray, geoip, geosite, подписки и config.json
# Поддерживает два формата подписки:
#   - Base64 (VLESS URI) - User-Agent: OpenWrt-Xray/1.0
#   - JSON (Happ/Sing-box) - User-Agent: happ/3.21 или singbox

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# Блокировка от одновременного запуска
LOCK_FILE="/var/lock/xray-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Другой экземпляр уже запущен" >&2
    exit 1
fi

LOG="/tmp/log/xray-update.log"

die() {
    echo "[X] $1" | tee -a "$LOG"
    exit 1
}

# Единая функция загрузки (curl)
fetch_url() {
    local url="$1"
    local dst="$2"
    local max_retries=2
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

CONFIG_DIR="/etc/xray"
SUB_FILE="$CONFIG_DIR/subscription.url"
CONFIG_JSON="$CONFIG_DIR/config.json"
HWID_FILE="$CONFIG_DIR/hwid"
SUB_USER_AGENT_FILE="$CONFIG_DIR/sub_user_agent"
SUB_REMARKS_FILE="$CONFIG_DIR/sub_remarks"

STATE_DIR="/etc/xray/state"
TMP_DIR="/tmp/xray_update"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"

GEO_DIR="/usr/share/xray"
GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat"
GEOSITE_URL="https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"

mkdir -p "$STATE_DIR" "$TMP_DIR"

echo "===== $(date) =====" >>"$LOG"

extract_sha256() {
    grep '^SHA2-256' "$1" |
        sed 's/.*= *//' |
        tr -cd '0-9a-fA-F' |
        cut -c1-64
}

# =============================================
#   Очистка/ротация логов
# =============================================
rotate_log() {
    local log="$1"
    local max_size="${2:-1048576}" # по умолчанию 1MB
    [ -f "$log" ] || return
    local size=$(stat -c%s "$log" 2>/dev/null || wc -c <"$log")
    if [ "$size" -gt "$max_size" ]; then
        : >"$log"
        echo "[*] Лог очищен: $log" >>"$LOG"
    fi
}
# Применяем к логам Xray
rotate_log "/tmp/log/xray-access.log" 524288 # 512KB
rotate_log "/tmp/log/xray-error.log" 262144  # 256KB
rotate_log "$LOG" 262144

# Проверка свободного места в /
FREE_SPACE_ROOT=$(df / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_ROOT" -lt 10240 ]; then
    die "Недостаточно места в / (нужно минимум 10MB, доступно ${FREE_SPACE_ROOT}KB)"
fi

# ============================
#   HWID + подписка + настройки
# ============================

[ -f "$HWID_FILE" ] || die "Нет HWID (файл $HWID_FILE)"
HWID="$(cat "$HWID_FILE" | tr -d '\n\r')"
[ -z "$HWID" ] && die "HWID пуст"

[ -f "$SUB_FILE" ] || die "Нет subscription.url (файл $SUB_FILE)"
SUB_URL="$(cat "$SUB_FILE" | tr -d '\n\r')"
[ -z "$SUB_URL" ] && die "Пустой URL подписки"

# Читаем User-Agent для подписки
SUB_USER_AGENT="OpenWrt-Xray/1.0"
if [ -f "$SUB_USER_AGENT_FILE" ]; then
    SUB_USER_AGENT="$(cat "$SUB_USER_AGENT_FILE" | tr -d '\n\r')"
fi
echo "→ User-Agent: $SUB_USER_AGENT" >>"$LOG"

# Читаем фильтр remarks для JSON-формата
REMARKS_FILTER=""
if [ -f "$SUB_REMARKS_FILE" ]; then
    REMARKS_FILTER="$(cat "$SUB_REMARKS_FILE" | tr -d '\n\r')"
    echo "→ Фильтр remarks: $REMARKS_FILTER" >>"$LOG"
fi

# ============================
#   Обновление Xray
# ============================

echo "→ Проверка обновлений Xray..." >>"$LOG"

# Ожидание доступности GitHub API
for i in $(seq 1 5); do
    if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

LATEST_VERSION=$(curl -s --user-agent "OpenWrt-Xray/1.0" --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

if [ -z "$LATEST_VERSION" ]; then
    echo "[!] Не удалось получить версию Xray — пропускаем обновление" >>"$LOG"
else
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

    if fetch_url "${ZIP_URL}.dgst" "$STATE_DIR/xray.dgst"; then
        REMOTE_SHA=$(extract_sha256 "$STATE_DIR/xray.dgst")

        if [ -n "$REMOTE_SHA" ]; then
            FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
            if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
                echo "[!] Недостаточно места в /tmp (нужно минимум 20MB) — пропускаем" >>"$LOG"
            elif [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
                echo "✓ Xray ZIP не изменился" >>"$LOG"
            else
                echo "→ Скачиваем Xray ZIP..." >>"$LOG"
                if fetch_url "$ZIP_URL" "$ZIP_DEST"; then
                    LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
                    if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
                        echo "$REMOTE_SHA" >"$SHA_FILE"
                        unzip -q "$ZIP_DEST" -d "$TMP_DIR"
                        if [ -f "$TMP_DIR/xray" ]; then
                            # Останавливаем Xray перед обновлением
                            /etc/init.d/xray stop 2>/dev/null
                            cp "$TMP_DIR/xray" /usr/bin/xray
                            chmod 755 /usr/bin/xray
                            echo "[+] Xray обновлён до $LATEST_VERSION" >>"$LOG"
                        else
                            echo "[!] Не удалось распаковать Xray" >>"$LOG"
                        fi
                    else
                        echo "[X] SHA не совпадает для Xray ZIP" >>"$LOG"
                    fi
                else
                    echo "[!] Не удалось скачать Xray ZIP" >>"$LOG"
                fi
            fi
        else
            echo "[!] Не удалось извлечь SHA из .dgst" >>"$LOG"
        fi
    else
        echo "[!] Не удалось скачать .dgst" >>"$LOG"
    fi
fi

# ============================
#   GEOIP / GEOSITE
# ============================

update_geo() {
    local URL="$1"
    local DEST="$2"
    local BASE=$(basename "$DEST")
    local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"
    local TMP_DEST="${TMP_DIR}/${BASE}"
    local TMP_SHA="${TMP_DIR}/${BASE}.sha256"

    echo "→ Обновление $BASE..." >>"$LOG"

    # Скачиваем SHA256
    if ! fetch_url "${URL}.sha256sum" "$TMP_SHA"; then
        echo "[!] Не удалось скачать sha256sum для $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    REMOTE_SHA=$(cut -d' ' -f1 "$TMP_SHA")
    if [ -z "$REMOTE_SHA" ]; then
        echo "[!] Пустой sha256sum для $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    # Проверяем, нужно ли обновлять
    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
        echo "✓ $BASE не изменился" >>"$LOG"
        return 0
    fi

    # Скачиваем сам файл
    if ! fetch_url "$URL" "$TMP_DEST"; then
        echo "[!] Не удалось скачать $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    # Проверяем SHA
    LOCAL_SHA=$(sha256sum "$TMP_DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "[X] SHA не совпадает для $BASE" >>"$LOG"
        rm -f "$TMP_DEST"
        return 1
    fi

    # Атомарное обновление
    mv "$TMP_DEST" "$DEST"
    echo "$REMOTE_SHA" >"$SHA_FILE"
    echo "[+] $BASE обновлён" >>"$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# ============================
#   Генерация config.json (поддерживает оба формата)
# ============================

echo "→ Генерация config.json (User-Agent: $SUB_USER_AGENT)..." >>"$LOG"

# Скачиваем подписку
if curl -s -L -H "User-Agent: $SUB_USER_AGENT" -H "x-hwid: $HWID" "$SUB_URL" -o "$TMP_DIR/sub.txt"; then
    
    # Проверяем, что скачалось не HTML
    if head -n 1 "$TMP_DIR/sub.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        echo "[X] Подписка вернула HTML, а не данные" >>"$LOG"
    else
        # Определяем формат по User-Agent
        case "$SUB_USER_AGENT" in
            *happ*|*Happ*|*HAPP*|*singbox*|*Singbox*|*sfa*|*sfi*|*sfm*|*sft*|*karing*)
                # JSON формат (Happ, Sing-box, Karing)
                echo "  → Используем JSON формат (прямая генерация)" >>"$LOG"
                if [ -n "$REMARKS_FILTER" ]; then
                    echo "  → Фильтр remarks: $REMARKS_FILTER" >>"$LOG"
                fi

                # Делаем бекап текущего config.json
                cp "$CONFIG_JSON" "$CONFIG_JSON.bak" 2>/dev/null || true

                if [ -n "$REMARKS_FILTER" ]; then
                    python3 "$GENERATOR" --format json --output "$TMP_DIR/config.json" --remarks "$REMARKS_FILTER" < "$TMP_DIR/sub.txt" 2>>"$LOG"
                else
                    python3 "$GENERATOR" --format json --output "$TMP_DIR/config.json" < "$TMP_DIR/sub.txt" 2>>"$LOG"
                fi

                if [ -f "$TMP_DIR/config.json" ] && xray run -test -config "$TMP_DIR/config.json" >>"$LOG" 2>&1; then
                    mv "$TMP_DIR/config.json" "$CONFIG_JSON"
                    echo "[+] Новый config.json установлен (JSON формат)" >>"$LOG"
                else
                    echo "[X] Новый config.json невалиден" >>"$LOG"
                    # Восстанавливаем бекап
                    if [ -f "$CONFIG_JSON.bak" ]; then
                        cp "$CONFIG_JSON.bak" "$CONFIG_JSON"
                        echo "[!] Восстановлен предыдущий config.json из бекапа" >>"$LOG"
                    fi
                fi
                ;;
            *)
                # Base64 формат (VLESS URI)
                echo "  → Используем Base64 формат (VLESS URI -> парсер)" >>"$LOG"
                
                # Делаем бекап текущего config.json
                cp "$CONFIG_JSON" "$CONFIG_JSON.bak" 2>/dev/null || true
                
                if python3 "$PARSER" < "$TMP_DIR/sub.txt" > "$TMP_DIR/parsed.json" 2>>"$LOG"; then
                    if python3 "$GENERATOR" --format vless --output "$TMP_DIR/config.json" < "$TMP_DIR/parsed.json" 2>>"$LOG"; then
                        if [ -f "$TMP_DIR/config.json" ] && xray run -test -config "$TMP_DIR/config.json" >>"$LOG" 2>&1; then
                            mv "$TMP_DIR/config.json" "$CONFIG_JSON"
                            echo "[+] Новый config.json установлен (VLESS формат)" >>"$LOG"
                        else
                            echo "[X] Новый config.json невалиден" >>"$LOG"
                            # Восстанавливаем бекап
                            if [ -f "$CONFIG_JSON.bak" ]; then
                                cp "$CONFIG_JSON.bak" "$CONFIG_JSON"
                                echo "[!] Восстановлен предыдущий config.json из бекапа" >>"$LOG"
                            fi
                        fi
                    else
                        echo "[X] Ошибка генератора конфига (VLESS)" >>"$LOG"
                    fi
                else
                    echo "[X] Ошибка парсера подписки (VLESS)" >>"$LOG"
                fi
                ;;
        esac
    fi
else
    echo "[!] Не удалось скачать подписку" >>"$LOG"
fi

# Очистка временных файлов
rm -f "$TMP_DIR/sub.txt" "$TMP_DIR/parsed.json" "$TMP_DIR/config.json"

# ============================
#   Финальная проверка config.json
# ============================

if [ -f "$CONFIG_JSON" ]; then
    if ! xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
        echo "[X] Итоговый config.json невалиден — отключаем Xray" >>"$LOG"
        /etc/init.d/xray stop 2>/dev/null
        exit 1
    fi
else
    echo "[X] config.json отсутствует — отключаем Xray" >>"$LOG"
    /etc/init.d/xray stop 2>/dev/null
    exit 1
fi

# ============================
#   Обновление nftables правил (через fw4 интеграцию)
# ============================

echo "→ Обновление nftables правил..." >>"$LOG"
if /usr/share/xray/update-nft.sh >>"$LOG" 2>&1; then
    echo "[+] nftables правила обновлены" >>"$LOG"
else
    echo "[X] Ошибка при обновлении nftables" >>"$LOG"
fi

# ============================
#   Перезапуск Xray
# ============================

echo "→ Перезапуск Xray..." >>"$LOG"
if /etc/init.d/xray restart >>"$LOG" 2>&1; then
    echo "[+] Xray перезапущен успешно" >>"$LOG"
else
    echo "[!] Не удалось перезапустить Xray" >>"$LOG"
fi

echo "===== Готово =====" >>"$LOG"

# Очистка временных файлов
rm -rf "$TMP_DIR"

# Снятие блокировки
flock -u 200