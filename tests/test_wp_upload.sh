#!/usr/bin/env bash
#
# tests/test_wp_upload.sh — тестирование fix_wp_upload_max_filesize.sh
# (исправление «Загруженный файл превышает директиву upload_max_filesize в php.ini.»)
#
# Использование:
#   ./tests/test_wp_upload.sh          — все тесты (мок-окружение, реальных сервисов не трогает)
#
# Коды возврата: 0 — все тесты пройдены, 1 — есть падения.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/fix_wp_upload_max_filesize.sh"

PASS=0
FAIL=0
ok()  { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d /tmp/wpupt.XXXXXX)"
MOCKBIN="$T/bin"; mkdir -p "$MOCKBIN"

# --- мок service/systemctl: пишут вызовы в лог; reload можно «ронять» через env
cat > "$MOCKBIN/service" <<'EOF'
#!/usr/bin/env bash
echo "service $*" >> "${T}/service.log"
if [[ "${1:-}" == "reload" && -n "${MOCK_SVC_RELOAD_FAIL:-}" ]]; then
  exit 3
fi
exit 0
EOF
cat > "$MOCKBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${T}/service.log"
if [[ "${1:-}" == "reload" && -n "${MOCK_SVC_RELOAD_FAIL:-}" ]]; then
  exit 3
fi
exit 0
EOF
chmod +x "$MOCKBIN/service" "$MOCKBIN/systemctl"
export T

# --- повышаем до root (скрипт правит /etc-подобные пути и зовёт сервисы) ----
MSUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    MSUDO="sudo -n"
  else
    echo "Нужен passwordless sudo для запуска тестов." >&2
    exit 1
  fi
fi

# --- генерация мок-окружения ------------------------------------------------
# write_ini <файл> <upload> <post> <memory>
write_ini() {
  cat > "$1" <<EOF
[PHP]
engine = On
memory_limit = $4
max_execution_time = 30
post_max_size = $3
upload_max_filesize = $2
EOF
}

# build_tree <base> <upload> <post> <memory> — php 8.2 (fpm+apache2+cli) + php 8.1 cli + WP
build_tree() {
  local base="$1" up="$2" post="$3" mem="$4"
  rm -rf "$base/etc" "$base/www"
  mkdir -p "$base/etc/php/8.2/fpm" "$base/etc/php/8.2/apache2" \
           "$base/etc/php/8.2/cli" "$base/etc/php/8.1/cli" \
           "$base/etc/php/8.2/fpm/pool.d" "$base/www/site/wp-content"
  write_ini "$base/etc/php/8.2/fpm/php.ini"     "$up" "$post" "$mem"
  write_ini "$base/etc/php/8.2/apache2/php.ini" "$up" "$post" "$mem"
  write_ini "$base/etc/php/8.2/cli/php.ini"     "$up" "$post" "$mem"
  write_ini "$base/etc/php/8.1/cli/php.ini"     "$up" "$post" "$mem"
  echo "<?php // wp" > "$base/www/site/wp-settings.php"
}

# get_ini <файл> <директива>
get_ini() {
  sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*([^;[:space:]]+).*/\1/p" "$1" | tail -1
}

backup_count() { find "$1/etc" -name 'php.ini.bak.*' 2>/dev/null | wc -l; }
svc_log()      { cat "$T/service.log" 2>/dev/null || true; }
svc_log_reset(){ rm -f "$T/service.log"; }

# run_fix [аргументы скрипта…] — окружение: мок-PHP + мок-WP + мок-service
run_fix() {
  $MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" \
    --php-conf-dir "$T/etc" --wp-path "$T/www/site" "$@"
}

echo "=== Тестирование $SCRIPT ==="

# --- 1. Статические проверки ------------------------------------------------
echo "--- 1. Статические проверки"
[[ -f "$SCRIPT" ]] && ok "скрипт существует" || bad "скрипт не найден"
[[ -x "$SCRIPT" ]] && ok "файл исполняемый" || bad "нет chmod +x"
if bash -n "$SCRIPT" 2>&1; then ok "bash -n: синтаксис корректен"; else bad "синтаксис"; fi
OUT="$("$SCRIPT" --help 2>&1)"
if [[ "$OUT" == *"upload_max_filesize"* && "$OUT" == *"Опции"* ]]; then
  ok "--help: справка на месте"
else
  bad "--help: справка не соответствует"
fi

# --- 2. Ошибки аргументов и поиск WordPress ----------------------------------
echo "--- 2. Аргументы и поиск WordPress"
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --wp-path "$T/nonexistent" 2>&1)"
[[ $? -ne 0 && "$OUT" == *"wp-settings.php"* ]] \
  && ok "несуществующий --wp-path: ошибка с пояснением" || bad "invalid --wp-path"

OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --php-conf-dir "$T/etc" --size 64MB 2>&1)"
[[ $? -ne 0 ]] && ok "неверный --size 64MB: отклонён" || bad "--size 64MB должен падать"

OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --php-conf-dir "$T/etc" 2>&1)"
[[ $? -ne 0 && "$OUT" == *"WordPress не найден"* ]] \
  && ok "без --wp-path и без WP в /var/www,/srv: понятная ошибка" || bad "WP-not-found должен падать с сообщением"

# --- 3. Свежая правка: fpm + apache2, cli не тронут, сервисы перезагружены ---
echo "--- 3. Свежая правка лимитов"
build_tree "$T" 2M 8M 128M
OUT="$(run_fix --size 64M 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"Найден установленный WordPress"* ]]; then
  ok "WordPress найден, скрипт отработал (код 0)"
else
  bad "свежая правка (код: $RC)"; printf '        вывод: %s\n' "$(echo "$OUT" | head -4)"
fi
[[ "$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize)" == "64M" ]] \
  && ok "fpm: upload_max_filesize = 64M" || bad "fpm upload"
[[ "$(get_ini "$T/etc/php/8.2/fpm/php.ini" post_max_size)" == "64M" ]] \
  && ok "fpm: post_max_size поднят до 64M" || bad "fpm post"
[[ "$(get_ini "$T/etc/php/8.2/fpm/php.ini" memory_limit)" == "128M" ]] \
  && ok "fpm: memory_limit 128M не тронут (достаточен)" || bad "fpm memory"
[[ "$(get_ini "$T/etc/php/8.2/apache2/php.ini" upload_max_filesize)" == "64M" ]] \
  && ok "apache2: upload_max_filesize = 64M" || bad "apache upload"
[[ "$(get_ini "$T/etc/php/8.2/cli/php.ini" upload_max_filesize)" == "2M" \
   && "$(get_ini "$T/etc/php/8.1/cli/php.ini" upload_max_filesize)" == "2M" ]] \
  && ok "cli php.ini не тронут (он не влияет на сайт)" || bad "cli ini должен остаться 2M"
[[ "$(backup_count "$T")" -eq 2 ]] && ok "создано ровно 2 бэкапа (fpm + apache2)" \
  || bad "бэкапов: $(backup_count "$T"), ожидалось 2"
[[ "$(svc_log)" == *"php8.2-fpm"* && "$(svc_log)" == *"apache2"* ]] \
  && ok "перезагружены php8.2-fpm и apache2" || bad "сервисы не перезагружены: $(svc_log)"

# --- 4. Идемпотентность -------------------------------------------------------
echo "--- 4. Идемпотентность"
BK_BEFORE="$(backup_count "$T")"; SVC_BEFORE="$(svc_log | wc -l)"
OUT="$(run_fix --size 64M 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"уже достаточны"* ]]; then
  ok "повторный запуск: «лимиты уже достаточны», код 0"
else
  bad "идемпотентность (код: $RC)"; printf '        вывод: %s\n' "$(echo "$OUT" | head -3)"
fi
[[ "$(backup_count "$T")" == "$BK_BEFORE" ]] && ok "новых бэкапов нет" || bad "появились лишние бэкапы"
[[ "$(svc_log | wc -l)" == "$SVC_BEFORE" ]] && ok "перезагрузок не было" || bad "лишние перезагрузки сервисов"

# --- 5. Dry-run ----------------------------------------------------------------
echo "--- 5. Dry-run"
build_tree "$T" 2M 8M 128M
OUT="$(run_fix --dry-run 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize)" == "2M" \
      && "$(backup_count "$T")" -eq 0 && "$OUT" == *"без изменений"* ]]; then
  ok "dry-run: показал изменения, ничего не тронул"
else
  bad "dry-run (код: $RC, upload=$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize))"
fi

# --- 6. Текущие лимиты больше целевых ------------------------------------------
echo "--- 6. Целевой размер меньше текущего"
build_tree "$T" 128M 128M 256M
OUT="$(run_fix --size 64M 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"уже достаточны"* \
      && "$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize)" == "128M" ]]; then
  ok "128M не понижается до 64M, код 0"
else
  bad "не должен понижать лимиты (код: $RC)"
fi

# --- 7. Граничные значения memory_limit -----------------------------------------
echo "--- 7. memory_limit: -1 и малый лимит"
build_tree "$T" 2M 8M -1
run_fix --size 64M >/dev/null 2>&1
[[ "$(get_ini "$T/etc/php/8.2/fpm/php.ini" memory_limit)" == "-1" ]] \
  && ok "memory_limit=-1 (unlimited) не тронут" || bad "memory -1 должен остаться"
build_tree "$T" 2M 8M 32M
OUT="$(run_fix --size 64M 2>&1)"
[[ "$(get_ini "$T/etc/php/8.2/fpm/php.ini" memory_limit)" == "128M" ]] \
  && ok "memory_limit 32M поднят до 128M (>= post)" || bad "memory должен стать 128M: $(get_ini "$T/etc/php/8.2/fpm/php.ini" memory_limit)"

# --- 8. .user.ini ----------------------------------------------------------------
echo "--- 8. .user.ini в корне WordPress"
build_tree "$T" 2M 8M 128M
mkdir -p "$T/www/site2"
echo "<?php // wp" > "$T/www/site2/wp-settings.php"
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --php-conf-dir "$T/etc" \
        --wp-path "$T/www/site" --wp-path "$T/www/site2" --user-ini 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$(get_ini "$T/www/site/.user.ini" upload_max_filesize)" == "64M" \
      && "$(get_ini "$T/www/site2/.user.ini" upload_max_filesize)" == "64M" ]]; then
  ok ".user.ini создан в обоих корнях WordPress"
else
  bad ".user.ini (код: $RC)"
fi
$MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --php-conf-dir "$T/etc" \
  --wp-path "$T/www/site" --wp-path "$T/www/site2" --user-ini >/dev/null 2>&1
CNT="$(grep -c "^upload_max_filesize" "$T/www/site/.user.ini")"
[[ "$CNT" == "1" ]] && ok ".user.ini идемпотентен (без дублей)" || bad "дублей в .user.ini: $CNT"

# --- 9. --no-restart и отсутствие инструментов перезагрузки ----------------------
echo "--- 9. Управление перезагрузкой"
build_tree "$T" 2M 8M 128M; svc_log_reset
OUT="$(run_fix --no-restart 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize)" == "64M" \
      && -z "$(svc_log)" && "$OUT" == *"вручную"* ]]; then
  ok "--no-restart: файлы изменены, сервисы не тронуты, есть подсказка"
else
  bad "--no-restart (код: $RC)"
fi

build_tree "$T" 2M 8M 128M; svc_log_reset
# PATH без service/systemctl — минимальный контейнер
NBIN="$T/nbin"; mkdir -p "$NBIN"
IFS=":" read -ra PDIRS <<< "$PATH"
for d in "${PDIRS[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [[ "$b" == "service" || "$b" == "systemctl" ]] && continue
    [[ -x "$f" && ! -e "$NBIN/$b" ]] && ln -s "$f" "$NBIN/$b" 2>/dev/null
  done
done
OUT="$($MSUDO env PATH="$NBIN" T="$T" "$SCRIPT" --php-conf-dir "$T/etc" --wp-path "$T/www/site" 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"вручную"* \
      && "$(get_ini "$T/etc/php/8.2/fpm/php.ini" upload_max_filesize)" == "64M" ]]; then
  ok "нет service/systemctl: предупреждение, но лимиты записаны"
else
  bad "окружение без service (код: $RC)"; printf '        вывод: %s\n' "$(echo "$OUT" | head -3)"
fi

build_tree "$T" 2M 8M 128M; svc_log_reset
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" MOCK_SVC_RELOAD_FAIL=1 "$SCRIPT" \
        --php-conf-dir "$T/etc" --wp-path "$T/www/site" 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$(svc_log)" == *"reload php8.2-fpm"* && "$(svc_log)" == *"restart php8.2-fpm"* ]]; then
  ok "reload не удался → выполнен restart"
else
  bad "fallback reload→restart (лог: $(svc_log | tr '\n' ' '))"
fi

# --- 10. Нет php.ini веб-SAPI ------------------------------------------------------
echo "--- 10. Конфигурация PHP без веб-SAPI"
rm -rf "$T/etc2"; mkdir -p "$T/etc2/php/8.2/cli"
write_ini "$T/etc2/php/8.2/cli/php.ini" 2M 8M 128M
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" T="$T" "$SCRIPT" --php-conf-dir "$T/etc2" --wp-path "$T/www/site" 2>&1)"; RC=$?
[[ $RC -ne 0 && "$OUT" == *"веб-SAPI"* ]] \
  && ok "нет fpm/apache2 php.ini: понятная ошибка" || bad "нет веб-SAPI (код: $RC)"

# --- Итог ---------------------------------------------------------------------------
echo "============================================="
echo "Итог: PASS=$PASS FAIL=$FAIL"
rm -rf "$T"
if [[ $FAIL -eq 0 ]]; then
  echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"
  exit 0
else
  echo "ЕСТЬ ПАДАЮЩИЕ ТЕСТЫ"
  exit 1
fi
