#!/usr/bin/env bash
#
# tests/test_install.sh — тестирование install_smbclient.sh
#
# Использование:
#   ./tests/test_install.sh                 — статика + мок-тесты + реальная установка
#   ./tests/test_install.sh --with-server   — дополнительно: интеграционный тест с локальным smbd
#   ./tests/test_install.sh --skip-install  — пропустить этап, требующий доступных apt-зеркал
#   ./tests/test_install.sh --help          — справка
#
# Коды возврата: 0 — все тесты пройдены, 1 — есть падения.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install_smbclient.sh"

WITH_SERVER=false
SKIP_INSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-server)  WITH_SERVER=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    -h|--help)
      sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# --- каркас ---------------------------------------------------------------
PASS=0
FAIL=0

ok()  { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }

# check <описание> <ожидание: 0|nonzero> <команда…>
check() {
  local desc="$1" expect="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$expect" == "0" && $rc -eq 0 ]]; then
    ok "$desc"
  elif [[ "$expect" == "nonzero" && $rc -ne 0 ]]; then
    ok "$desc"
  else
    bad "$desc (код возврата: $rc, ожидалось: $expect)"
    [[ -n "$out" ]] && printf '        вывод: %s\n' "$(echo "$out" | head -3)"
  fi
}

# check_contains <описание> <подстрока> <команда…>
check_contains() {
  local desc="$1" needle="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 && "$out" == *"$needle"* ]]; then
    ok "$desc"
  else
    bad "$desc (код: $rc, подстрока не найдена: «$needle»)"
    [[ -n "$out" ]] && printf '        вывод: %s\n' "$(echo "$out" | head -3)"
  fi
}

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  SUDO="sudo -E"
fi

echo "=== Тестирование $INSTALLER ==="

# --- 1. Статические проверки ----------------------------------------------
echo "--- 1. Статические проверки"
if [[ -f "$INSTALLER" ]]; then ok "скрипт существует"; else bad "скрипт не найден: $INSTALLER"; fi
if [[ -x "$INSTALLER" ]]; then ok "файл исполняемый"; else bad "нет права на выполнение (chmod +x)"; fi

check "bash -n: синтаксис корректен" 0 bash -n "$INSTALLER"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: замечаний нет" 0 shellcheck -x "$INSTALLER"
else
  echo "  SKIP  shellcheck не установлен (apt-get install -y shellcheck)"
fi

# --- 2. Интерфейс командной строки -----------------------------------------
echo "--- 2. Аргументы командной строки"
check_contains "--help: выводит справку" "Использование" "$INSTALLER" --help
check "неизвестный аргумент: выход с ошибкой" nonzero "$INSTALLER" --no-such-flag

# --- 3. Мок-тесты логики (без сети) -----------------------------------------
echo "--- 3. Мок-тесты (фейковые apt-get/dpkg-query/smbclient)"
# Скрипт при EUID!=0 перезапускает себя через sudo; смоделировать root
# фейковым sudo нельзя (EUID в bash read-only), поэтому мок-сюиту запускаем
# под настоящим sudo -n. Фейковые бинарники перехватывают только apt/dpkg/smbclient.
MSUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    MSUDO="sudo -n"
  else
    echo "  SKIP  нужны права root (passwordless sudo) для мок-тестов"
  fi
fi

if [[ -n "$MSUDO" || ${EUID} -eq 0 ]]; then
MOCKBIN="$(mktemp -d /tmp/smbmock-bin.XXXXXX)"
MOCKSTATEDIR="$(mktemp -d /tmp/smbmock-state.XXXXXX)"

cat > "$MOCKBIN/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "${MOCKSTATEDIR}/apt.log"
case " $* " in
  *" update "*) exit "${MOCK_APT_UPDATE_RC:-0}" ;;
  *" install "*)
    if [[ "${MOCK_APT_INSTALL_RC:-0}" -ne 0 ]]; then exit "$MOCK_APT_INSTALL_RC"; fi
    touch "${MOCKSTATEDIR}/installed"; exit 0 ;;
esac
exit 0
EOF

cat > "$MOCKBIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ -f "${MOCKSTATEDIR}/installed" ]]; then
  echo "install ok installed"; exit 0
fi
exit 1
EOF

cat > "$MOCKBIN/smbclient" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_SMBCLIENT_RC:-0}" -ne 0 ]]; then exit "$MOCK_SMBCLIENT_RC"; fi
case "${1:-}" in
  --version|-V) echo "Version 4.19.0-mock"; exit 0 ;;
  --usage|-h)   exit 0 ;;
esac
exit 0
EOF

chmod +x "$MOCKBIN/apt-get" "$MOCKBIN/dpkg-query" "$MOCKBIN/smbclient"

mock_run() { $MSUDO env PATH="$MOCKBIN:$PATH" MOCKSTATEDIR="$MOCKSTATEDIR" "$INSTALLER" "$@"; }
mock_count() { grep -c "^apt-get install" "$MOCKSTATEDIR/apt.log" 2>/dev/null || true; }

# 3.1 Свежая установка
rm -rf "$MOCKSTATEDIR"; mkdir -p "$MOCKSTATEDIR"
OUT="$(mock_run 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"Установка завершена успешно"* ]]; then
  ok "мок: свежая установка завершается успешно"
else
  bad "мок: свежая установка (код: $RC)"; printf '        вывод: %s\n' "$(echo "$OUT" | head -3)"
fi
if grep -q "^apt-get update" "$MOCKSTATEDIR/apt.log" 2>/dev/null && [[ "$(mock_count)" == "1" ]]; then
  ok "мок: вызван apt-get update и ровно один apt-get install"
else
  bad "мок: неверный набор вызовов apt-get"
fi
if [[ "$OUT" == *"4.19.0-mock"* ]]; then
  ok "мок: версия smbclient выводится"
else
  bad "мок: версия smbclient не выведена"
fi

# 3.2 Идемпотентность
OUT="$(mock_run 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"уже установлен"* && "$(mock_count)" == "1" ]]; then
  ok "мок: повторный запуск — «уже установлен», без повторной установки"
else
  bad "мок: идемпотентность (код: $RC, установок: $(mock_count))"
fi

# 3.3 --force
OUT="$(mock_run --force 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$(mock_count)" == "2" ]]; then
  ok "мок: --force выполняет переустановку"
else
  bad "мок: --force (код: $RC, установок: $(mock_count))"
fi

# 3.4 --no-update
rm -rf "$MOCKSTATEDIR"; mkdir -p "$MOCKSTATEDIR"
OUT="$(mock_run --no-update 2>&1)"; RC=$?
if [[ $RC -ne 0 ]]; then
  bad "мок: --no-update (код: $RC)"
elif grep -q "^apt-get update" "$MOCKSTATEDIR/apt.log" 2>/dev/null; then
  bad "мок: --no-update всё равно вызвал apt-get update"
elif grep -q "^apt-get install" "$MOCKSTATEDIR/apt.log" 2>/dev/null; then
  ok "мок: --no-update пропускает apt-get update"
else
  bad "мок: --no-update — install не вызван"
fi

# 3.5 Ошибка apt-get install
rm -rf "$MOCKSTATEDIR"; mkdir -p "$MOCKSTATEDIR"
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" MOCKSTATEDIR="$MOCKSTATEDIR" MOCK_APT_INSTALL_RC=100 "$INSTALLER" 2>&1)"; RC=$?
if [[ $RC -ne 0 && "$OUT" == *"Не удалось установить"* ]]; then
  ok "мок: ошибка apt-get install — скрипт падает с понятной ошибкой"
else
  bad "мок: обработка ошибки apt-get install (код: $RC)"
fi

# 3.6 Ошибка apt-get update — не фатальна, если install доступен
rm -rf "$MOCKSTATEDIR"; mkdir -p "$MOCKSTATEDIR"
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" MOCKSTATEDIR="$MOCKSTATEDIR" MOCK_APT_UPDATE_RC=100 "$INSTALLER" 2>&1)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == *"из кэша"* && "$OUT" == *"Установка завершена успешно"* ]]; then
  ok "мок: сбой apt-get update не фатален (установка из кэша)"
else
  bad "мок: сбой apt-get update (код: $RC)"
fi

# 3.7 Сломанный smbclient после установки — верификация ловит
rm -rf "$MOCKSTATEDIR"; mkdir -p "$MOCKSTATEDIR"
OUT="$($MSUDO env PATH="$MOCKBIN:$PATH" MOCKSTATEDIR="$MOCKSTATEDIR" MOCK_SMBCLIENT_RC=1 "$INSTALLER" 2>&1)"; RC=$?
if [[ $RC -ne 0 && "$OUT" == *"Не удалось получить версию"* ]]; then
  ok "мок: верификация ловит сломанный smbclient"
else
  bad "мок: верификация не сработала (код: $RC)"
fi

$MSUDO rm -rf "$MOCKBIN" "$MOCKSTATEDIR" 2>/dev/null || rm -rf "$MOCKBIN" "$MOCKSTATEDIR"
fi # мок-сюита

# --- 4. Реальная установка --------------------------------------------------
if [[ "$SKIP_INSTALL" == true ]]; then
  echo "--- 4. Реальная установка — SKIP (--skip-install)"
else
  echo "--- 4. Реальная установка (требует доступных apt-зеркал)"
  check_contains "реальная установка: успешна" "Установка завершена успешно" \
    $SUDO "$INSTALLER"

  check "smbclient доступен в PATH" 0 bash -c 'command -v smbclient'
  check_contains "smbclient --version: выводит версию" "Samba" smbclient --version
  check "smbclient --usage: отвечает" 0 smbclient --usage
fi

# --- 5. Интеграционный тест с локальным Samba-сервером ----------------------
if [[ "$WITH_SERVER" == true ]]; then
  echo "--- 5. Интеграционный тест (локальный smbd, порт 4450)"
  if ! command -v smbd >/dev/null 2>&1; then
    if ! $SUDO apt-get install -y samba >/dev/null 2>&1; then
      bad "не удалось установить samba для интеграционного теста"
    fi
  fi
  if command -v smbd >/dev/null 2>&1; then
    SMBCONF="$(mktemp -d /tmp/smbtest.XXXXXX)"
    SHARE="$SMBCONF/share"
    mkdir -p "$SHARE" "$SMBCONF"/{locks,state,cache,private}
    chmod 0777 "$SHARE"
    echo "integration-test-payload" > "$SMBCONF/src.txt"

    cat > "$SMBCONF/smb.conf" <<EOF
[global]
   workgroup = WORKGROUP
   server string = smbclient-integration-test
   map to guest = Bad User
   smb ports = 4450
   log file = $SMBCONF/log.%m
   log level = 1
   pid directory = $SMBCONF
   lock directory = $SMBCONF/locks
   state directory = $SMBCONF/state
   cache directory = $SMBCONF/cache
   private dir = $SMBCONF/private

[testshare]
   path = $SHARE
   browseable = yes
   read only = no
   guest ok = yes
   force user = nobody
EOF
    $SUDO smbd --daemon --configfile="$SMBCONF/smb.conf" 2>"$SMBCONF/smbd.err"
    sleep 2

    check_contains "smbclient -L: сервер отвечает, шара видна" "testshare" \
      smbclient -L localhost -p 4450 -N -g

    check_contains "smbclient put: запись файла в шару" "putting" \
      smbclient //localhost/testshare -p 4450 -N -c "put $SMBCONF/src.txt dst.txt"

    ROUNDTRIP="$(smbclient //localhost/testshare -p 4450 -N -c 'get dst.txt /dev/stdout' 2>/dev/null)"
    if [[ "$ROUNDTRIP" == "integration-test-payload" ]]; then
      ok "smbclient get: файл читается обратно, содержимое совпадает"
    else
      bad "smbclient get: содержимое не совпало: «$ROUNDTRIP»"
    fi

    if [[ -f "$SMBCONF/smbd.pid" ]]; then
      $SUDO kill "$(cat "$SMBCONF/smbd.pid")" 2>/dev/null || true
    else
      $SUDO pkill -f "smbd.*$SMBCONF" 2>/dev/null || true
    fi
    rm -rf "$SMBCONF"
  fi
fi

# --- Итог -------------------------------------------------------------------
echo "============================================="
echo "Итог: PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"
  exit 0
else
  echo "ЕСТЬ ПАДАЮЩИЕ ТЕСТЫ"
  exit 1
fi
