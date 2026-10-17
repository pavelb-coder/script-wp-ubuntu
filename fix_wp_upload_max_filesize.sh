#!/usr/bin/env bash
#
# fix_wp_upload_max_filesize.sh — исправление ошибки WordPress
#   «Загруженный файл превышает директиву upload_max_filesize в php.ini.»
#
# Что делает:
#   1. находит установки WordPress (по наличию wp-settings.php);
#   2. находит php.ini веб-SAPI (fpm, apache2, cgi) — CLI php.ini намеренно
#      не трогается, он не влияет на загрузку файлов через сайт;
#   3. увеличивает upload_max_filesize и post_max_size (>= upload),
#      при необходимости поднимает memory_limit;
#   4. делает бэкап каждого изменённого php.ini;
#   5. перезагружает phpX.Y-fpm / apache2;
#   6. опционально (--user-ini) создаёт .user.ini в корне WordPress.
#
# Использование:
#   sudo ./fix_wp_upload_max_filesize.sh [ОПЦИИ]
#
# Опции:
#   --size S            Целевой размер загрузки: 64M (по умолчанию), 128M, 1G, 512K, байты
#   --wp-path DIR       Явный путь к корню WordPress (можно указывать несколько раз);
#                       без него поиск идёт в /var/www и /srv
#   --php-conf-dir DIR  Каталог с конфигами PHP (по умолчанию /etc/php);
#                       полезно для нестандартных сборок и тестов
#   --user-ini          Дополнительно записать .user.ini в корень WordPress
#                       (вступает в силу с задержкой user_ini.cache_ttl, до 5 минут)
#   --dry-run           Только показать, что будет изменено
#   --no-restart        Не перезагружать php-fpm/apache2
#   --force             Применить, даже если WordPress не найден
#   -h, --help          Справка
#
# Коды возврата: 0 — успех (в т.ч. «лимиты уже достаточны»), 1 — ошибка, 2 — неверные аргументы.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Параметры
# ---------------------------------------------------------------------------
SIZE="64M"                 # целевой upload_max_filesize
WP_PATHS=()                # явные корни WordPress (--wp-path)
SEARCH_ROOTS=(/var/www /srv)
PHP_ETC="/etc/php"         # --php-conf-dir
USER_INI=false
DRY_RUN=false
NO_RESTART=false
FORCE=false

# Логи (цвет отключается вне терминала — важно для CI)
if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log_info() { printf '%s[INFO ]%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
log_ok()   { printf '%s[ OK  ]%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
log_warn() { printf '%s[WARN ]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
log_err()  { printf '%s[ERROR]%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }
log_dry()  { printf '%s[DRY  ]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

usage() {
  sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)
      [[ -n "${2:-}" && "$2" =~ ^[0-9]+[KkMmGg]?$ ]] || { usage >&2; die "--size: ожидался размер вида 64M|1G|512K|число байт, получено: ${2:-<пусто>}"; }
      SIZE="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --wp-path)
      [[ -n "${2:-}" ]] || { usage >&2; die "--wp-path: ожидается путь к корню WordPress"; }
      WP_PATHS+=("$2"); shift 2 ;;
    --php-conf-dir)
      [[ -n "${2:-}" ]] || { usage >&2; die "--php-conf-dir: ожидается каталог"; }
      PHP_ETC="$2"; shift 2 ;;
    --user-ini)  USER_INI=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-restart) NO_RESTART=true; shift ;;
    --force)     FORCE=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "Неизвестный аргумент: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Запуск через sudo, если не root (правка /etc и перезагрузка сервисов)
# ---------------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Требуются права root. Запустите от root или установите sudo."
  log_info "Запуск через sudo (текущий пользователь не root)…"
  exec sudo -E "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Размеры: парсинг/сравнение (K/M/G, регистронезависимо)
# ---------------------------------------------------------------------------
size_to_bytes() {
  local s="$1" n unit
  s="${s^^}"
  [[ "$s" =~ ^[0-9]+[KMG]?$ ]] || return 1
  n="${s//[!0-9]/}"; unit="${s//[0-9]/}"
  case "$unit" in
    "") echo "$n" ;;
    K)  echo $((n * 1024)) ;;
    M)  echo $((n * 1024 * 1024)) ;;
    G)  echo $((n * 1024 * 1024 * 1024)) ;;
  esac
}

human_from_bytes() {
  local b=$1
  if (( b % 1073741824 == 0 )); then echo "$((b / 1073741824))G"
  elif (( b % 1048576 == 0 ));  then echo "$((b / 1048576))M"
  elif (( b % 1024 == 0 ));     then echo "$((b / 1024))K"
  else echo "$b"; fi
}

TARGET_B="$(size_to_bytes "$SIZE")" || die "Некорректный --size: $SIZE"
MEM_DEFAULT_B=$((128 * 1024 * 1024))   # к чему поднимать memory_limit, если он мал
BACKUP_SUFFIX=".bak.$(date +%Y%m%d-%H%M%S)"
DRY_WOULD=0                            # счётчик «изменений при --dry-run»

# ---------------------------------------------------------------------------
# Чтение/запись директив в ini-файлах
# ---------------------------------------------------------------------------
# ini_read <файл> <директива> — значение последней активной строки (без ';')
ini_read() {
  local v
  v="$(sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*([^;[:space:]]+).*/\1/p" "$1" 2>/dev/null | tail -1)"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  return 1
}

# ini_write <файл> <директива> <значение> — правит активные строки или дописывает
ini_write() {
  local f="$1" d="$2" v="$3"
  if grep -Eq "^[[:space:]]*${d}[[:space:]]*=" "$f"; then
    sed -i -E "s|^([[:space:]]*${d}[[:space:]]*=[[:space:]]*).*|\1${v}|" "$f"
  else
    printf '\n; added by %s\n%s = %s\n' "$SCRIPT_NAME" "$d" "$v" >> "$f"
  fi
}

# ---------------------------------------------------------------------------
# Поиск установленных WordPress
# ---------------------------------------------------------------------------
declare -A WP_SEEN=()
WP_ROOTS=()

collect_wp_root() {
  local r="$1"
  [[ -n "${WP_SEEN[$r]:-}" ]] && return 0
  WP_SEEN[$r]=1
  WP_ROOTS+=("$r")
}

if ((${#WP_PATHS[@]} > 0)); then
  for r in "${WP_PATHS[@]}"; do
    [[ -f "$r/wp-settings.php" ]] || die "В --wp-path «$r» не найден wp-settings.php — укажите корень WordPress."
    collect_wp_root "$r"
  done
else
  for root in "${SEARCH_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' w; do
      collect_wp_root "$(dirname "$w")"
    done < <(find "$root" -maxdepth 6 -type f -name wp-settings.php -print0 2>/dev/null)
  done
fi

if ((${#WP_ROOTS[@]} > 0)); then
  log_info "Найден установленный WordPress (${#WP_ROOTS[@]} шт.):"
  for r in "${WP_ROOTS[@]}"; do log_info "  - $r"; done
else
  if [[ "$FORCE" == true ]]; then
    log_warn "WordPress не найден в ${SEARCH_ROOTS[*]} — продолжаю (--force): правка php.ini без привязки к WP."
  else
    die "Установки WordPress не найдены (искал в ${SEARCH_ROOTS[*]}). Укажите корень через --wp-path или используйте --force."
  fi
fi

# ---------------------------------------------------------------------------
# Целевые php.ini веб-SAPI (CLI сознательно исключён)
# ---------------------------------------------------------------------------
shopt -s nullglob
INI_TARGETS=()
for ver_dir in "$PHP_ETC"/*/*/; do   # .../etc/php/<версия>/ (fpm, apache2, cli…)
  for sapi in fpm apache2 cgi; do
    [[ -f "${ver_dir}${sapi}/php.ini" ]] && INI_TARGETS+=("${ver_dir}${sapi}/php.ini")
  done
done
shopt -u nullglob

((${#INI_TARGETS[@]} > 0)) || die "Не найдены php.ini веб-SAPI (fpm/apache2/cgi) в $PHP_ETC. Установлен ли PHP? (php-fpm или libapache2-mod-php)"
log_info "Целевые php.ini веб-SAPI:"
for f in "${INI_TARGETS[@]}"; do log_info "  - $f"; done

# ---------------------------------------------------------------------------
# Правка лимитов
# ---------------------------------------------------------------------------
CHANGED=()
SUMMARY=()

for ini in "${INI_TARGETS[@]}"; do
  cur_up="$(ini_read "$ini" upload_max_filesize || true)"
  cur_post="$(ini_read "$ini" post_max_size || true)"
  cur_mem="$(ini_read "$ini" memory_limit || true)"

  new_up="$cur_up"; new_post="$cur_post"; new_mem="$cur_mem"

  # upload_max_filesize: целевой размер, если текущий меньше/отсутствует
  if [[ -z "$cur_up" ]] || (( $(size_to_bytes "$cur_up") < TARGET_B )); then
    new_up="$SIZE"
  fi
  UP_FINAL_B="$(size_to_bytes "$new_up")"

  # post_max_size: должен быть >= upload_max_filesize
  if [[ -z "$cur_post" ]] || (( $(size_to_bytes "$cur_post") < UP_FINAL_B )); then
    new_post="$new_up"
  fi
  POST_FINAL_B="$(size_to_bytes "$new_post")"

  # memory_limit: -1 (unlimited) не трогаем; иначе >= post_max_size, минимум 128M
  if [[ -z "$cur_mem" ]]; then
    new_mem="$(human_from_bytes "$MEM_DEFAULT_B")"
  elif [[ "$cur_mem" != "-1" ]] && (( $(size_to_bytes "$cur_mem") < POST_FINAL_B )); then
    nb=$(( POST_FINAL_B > MEM_DEFAULT_B ? POST_FINAL_B : MEM_DEFAULT_B ))
    new_mem="$(human_from_bytes "$nb")"
  fi

  if [[ "$new_up" == "$cur_up" && "$new_post" == "$cur_post" && "$new_mem" == "$cur_mem" ]]; then
    log_ok "$ini: лимиты уже достаточны (upload=${cur_up:-отсутствует}, post=${cur_post:-отсутствует}, memory=${cur_mem:-отсутствует})"
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "$ini: upload=${cur_up:-?} → ${new_up}, post=${cur_post:-?} → ${new_post}, memory=${cur_mem:-?} → ${new_mem} (без изменений — --dry-run)"
    DRY_WOULD=$((DRY_WOULD + 1))
    continue
  fi

  cp -p "$ini" "${ini}${BACKUP_SUFFIX}"
  log_info "$ini: бэкап → ${ini}${BACKUP_SUFFIX}"

  [[ "$new_up" != "$cur_up" ]]   && ini_write "$ini" upload_max_filesize "$new_up"
  [[ "$new_post" != "$cur_post" ]] && ini_write "$ini" post_max_size "$new_post"
  [[ "$new_mem" != "$cur_mem" ]] && ini_write "$ini" memory_limit "$new_mem"

  # Верификация результата
  v_up="$(ini_read "$ini" upload_max_filesize || true)"
  v_post="$(ini_read "$ini" post_max_size || true)"
  v_mem="$(ini_read "$ini" memory_limit || true)"
  [[ -n "$v_up" && "$(size_to_bytes "$v_up")" -ge "$TARGET_B" ]] || die "$ini: верификация не прошла: upload_max_filesize=${v_up:-отсутствует}"
  [[ -n "$v_post" && "$(size_to_bytes "$v_post")" -ge "$UP_FINAL_B" ]] || die "$ini: верификация не прошла: post_max_size=${v_post:-отсутствует}"
  [[ -z "$v_mem" || "$v_mem" == "-1" || "$(size_to_bytes "$v_mem")" -ge "$POST_FINAL_B" ]] \
    || die "$ini: верификация не прошла: memory_limit=$v_mem"

  CHANGED+=("$ini")
  SUMMARY+=("$ini: upload ${cur_up:-отсутствует} → ${new_up}; post ${cur_post:-отсутствует} → ${new_post}; memory ${cur_mem:-отсутствует} → ${new_mem}")
done

# ---------------------------------------------------------------------------
# .user.ini в корне WordPress (опционально)
# ---------------------------------------------------------------------------
if [[ "$USER_INI" == true && "$DRY_RUN" == false ]]; then
  for r in "${WP_ROOTS[@]}"; do
    uf="$r/.user.ini"
    if [[ ! -f "$uf" ]]; then
      : > "$uf"; chmod 644 "$uf"
    fi
    ini_write "$uf" upload_max_filesize "$SIZE"
    cur_p="$(ini_read "$uf" post_max_size || true)"
    if [[ -z "$cur_p" || "$(size_to_bytes "$cur_p")" -lt "$TARGET_B" ]]; then
      ini_write "$uf" post_max_size "$SIZE"
    fi
    log_ok "$uf: записан (учтите user_ini.cache_ttl — до 5 минут)"
  done
elif [[ "$USER_INI" == true && "$DRY_RUN" == true ]]; then
  for r in "${WP_ROOTS[@]}"; do
    log_dry "$r/.user.ini: будет записан (upload_max_filesize=$SIZE)"
  done
fi

# ---------------------------------------------------------------------------
# Перезагрузка сервисов
# ---------------------------------------------------------------------------
reload_service() {
  local svc="$1"
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl reload "$svc" >/dev/null 2>&1 || systemctl restart "$svc" >/dev/null 2>&1; then
      log_ok "Сервис ${svc} перезагружен (systemctl)."
      return 0
    fi
  elif command -v service >/dev/null 2>&1; then
    if service "$svc" reload >/dev/null 2>&1 || service "$svc" restart >/dev/null 2>&1; then
      log_ok "Сервис ${svc} перезагружен (service)."
      return 0
    fi
  fi
  log_warn "Не удалось перезагрузить ${svc} автоматически — перезапустите его вручную."
  return 1
}

if (( ${#CHANGED[@]} == 0 )); then
  if [[ "$DRY_RUN" == true && "${DRY_WOULD:-0}" -gt 0 ]]; then
    log_dry "Найдены настройки, требующие изменения (см. выше). Реальные файлы не менялись (--dry-run)."
    exit 0
  fi
  log_ok "Изменений не требуется — лимиты уже достаточны для ${SIZE}."
  exit 0
fi

declare -A SVC_FPM=()
APACHE_NEEDED=0
for ini in "${CHANGED[@]}"; do
  # <...>/<версия>/<sapi>/php.ini → версия/сапай = имена каталогов над файлом
  ver="$(basename "$(dirname "$(dirname "$ini")")")"
  sapi="$(basename "$(dirname "$ini")")"
  if [[ "$sapi" == "fpm" ]]; then
    SVC_FPM["php${ver}-fpm"]=1
  else
    APACHE_NEEDED=1
  fi
done

if [[ "$NO_RESTART" == true ]]; then
  log_warn "--no-restart: конфигурация изменена, но сервисы НЕ перезагружены. Выполните вручную:"
  ((${#SVC_FPM[@]} > 0)) && log_warn "  systemctl reload ${!SVC_FPM[*]}"
  ((APACHE_NEEDED)) && log_warn "  systemctl reload apache2"
else
  RC_BAD=0
  for svc in "${!SVC_FPM[@]}"; do
    reload_service "$svc" || RC_BAD=1
  done
  if ((APACHE_NEEDED)); then
    reload_service apache2 || RC_BAD=1
  fi
  ((RC_BAD)) && log_warn "Часть сервисов не перезагружена — новые лимиты заработают после их перезапуска."
fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
log_ok "Готово. Загрузка файлов до ${SIZE} разрешена в конфигурации PHP:"
for s in "${SUMMARY[@]}"; do log_ok "  $s"; done
if [[ "$DRY_RUN" == true ]]; then
  log_dry "Это был --dry-run: реальные файлы не менялись."
fi
exit 0
