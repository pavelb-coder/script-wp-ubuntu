#!/usr/bin/env bash
#
# install_smbclient.sh — установка smbclient (Samba-клиент) на Ubuntu.
# Также работает на Debian и других apt-дистрибутивах.
#
# Использование:
#   ./install_smbclient.sh              — установить (идемпотентно)
#   ./install_smbclient.sh --force      — переустановить/обновить принудительно
#   ./install_smbclient.sh --no-update  — пропустить `apt-get update`
#   ./install_smbclient.sh -h | --help  — справка
#
# Скрипт идемпотентен: если smbclient уже установлен, повторный запуск
# просто выводит его версию и завершается с кодом 0.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Параметры (можно переопределить флагами)
# ---------------------------------------------------------------------------
FORCE=false      # --force: принудительная переустановка/обновление
NO_UPDATE=false  # --no-update: пропустить apt-get update
PKG="smbclient"
LOCK_TIMEOUT=300                 # сек. ожидания освобождения блокировок apt/dpkg (0 — не ждать)
LOCK_POLL="${SMB_LOCK_POLL:-5}"  # интервал опроса блокировок, сек. (ручка для тестов)

# ---------------------------------------------------------------------------
# Логирование (цвета отключаются, если stdout не терминал — важно для CI)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log_info() { printf '%s[INFO ]%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
log_ok()   { printf '%s[ OK  ]%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
log_warn() { printf '%s[WARN ]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
log_err()  { printf '%s[ERROR]%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

usage() {
  cat <<EOF
Установка smbclient (Samba-клиент) для Ubuntu/Debian.

Использование: ${SCRIPT_NAME} [ОПЦИИ]

Опции:
  --force              Принудительно обновить/переустановить пакет, даже если он уже установлен
  --no-update          Не выполнять 'apt-get update' перед установкой
  --lock-timeout N     Ждать освобождения блокировки apt/dpkg до N секунд (по умолчанию 300; 0 — не ждать).
                       Типичный держатель блокировки — фоновое автообновление unattended-upgrades.
  -h, --help           Показать эту справку

Без опций скрипт идемпотентен: если ${PKG} уже установлен,
выводится версия и скрипт завершается с кодом 0.
EOF
}

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Блокировки apt/dpkg: ожидание освобождения (unattended-upgrades и др.)
# ---------------------------------------------------------------------------
DPKG_LOCKS=(
  /var/lib/dpkg/lock-frontend
  /var/lib/dpkg/lock
  /var/lib/apt/lists/lock
  /var/cache/apt/archives/lock
)

# PID-ы процессов, удерживающих хотя бы один лок (пусто/код 1 — никто не держит)
lock_holders() {
  local holders
  if command -v fuser >/dev/null 2>&1; then
    holders="$(_lock_holders_fuser || true)"
  else
    holders="$(_lock_holders_proc || true)"
  fi
  [[ -n "$holders" ]] && printf '%s\n' "$holders"
}

# Вариант с fuser из пакета psmisc
_lock_holders_fuser() {
  local lock pids=""
  for lock in "${DPKG_LOCKS[@]}"; do
    [[ -e "$lock" ]] || continue
    pids+=" $(fuser "$lock" 2>/dev/null || true)"
  done
  printf '%s\n' "$pids" | tr -s ' \t\n' ' ' | tr ' ' '\n' | sort -u | grep -v '^$'
}

# Fallback без psmisc (минимальные контейнеры): сканируем открытые fd в /proc.
# Работает от root — к этому моменту скрипт уже повышен через sudo.
_lock_holders_proc() {
  local pid fd target lock
  for pid in /proc/[0-9]*; do
    for fd in "$pid"/fd/*; do
      target="$(readlink "$fd" 2>/dev/null)" || continue
      for lock in "${DPKG_LOCKS[@]}"; do
        if [[ "$target" == "$lock" || "$target" == "$lock (deleted)" ]]; then
          echo "${pid#/proc/}"
          break 2
        fi
      done
    done
  done | sort -u
}

# Имя процесса по PID: /proc/<pid>/comm, затем ps, затем просто pid
lock_holder_name() {
  local pid="$1" name=""
  name="$(cat "/proc/${pid}/comm" 2>/dev/null)" \
    || name="$(ps -o comm= -p "$pid" 2>/dev/null)" \
    || name=""
  if [[ -z "$name" ]]; then
    echo "pid ${pid}"
  else
    echo "${name} (pid ${pid})"
  fi
}

wait_for_apt_lock() {
  if (( LOCK_TIMEOUT <= 0 )); then return 0; fi
  local waited=0 pids pid names first=1
  while pids="$(lock_holders)"; do
    names=""
    for pid in $pids; do
      names+=", $(lock_holder_name "$pid")"
    done
    names="${names#, }"
    if (( first )); then
      first=0
      log_warn "Блокировка apt/dpkg удерживается процессом: ${names:-неизвестно}."
      if [[ "$names" == *unattended* ]]; then
        log_info "Похоже, работает фоновое автообновление (unattended-upgrades) — дожидаемся его завершения."
      fi
      log_info "Ожидание освобождения блокировки (до ${LOCK_TIMEOUT}s, опрос каждые ${LOCK_POLL}s)…"
    else
      log_info "Блокировка ещё удерживается (${waited}s/${LOCK_TIMEOUT}s)…"
    fi
    if (( waited >= LOCK_TIMEOUT )); then
      die "Не дождались освобождения блокировки apt/dpkg за ${LOCK_TIMEOUT}s. Запустите скрипт позже или увеличьте --lock-timeout."
    fi
    sleep "$LOCK_POLL"
    waited=$((waited + LOCK_POLL))
  done
}

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)     FORCE=true; shift ;;
    --no-update) NO_UPDATE=true; shift ;;
    --lock-timeout)
      if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
        usage >&2
        die "--lock-timeout: ожидается неотрицательное число секунд, получено: ${2:-<пусто>}"
      fi
      LOCK_TIMEOUT="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "Неизвестный аргумент: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Проверка ОС и прав
# ---------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "Скрипт предназначен для Linux."

if [[ -r /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  log_info "ОС: ${PRETTY_NAME:-неизвестно}"
  case "${ID:-}" in
    ubuntu|debian) : ;; # поддерживаемые дистрибутивы
    *)
      if [[ "${ID_LIKE:-}" == *debian* ]]; then
        log_warn "Дистрибутив ${ID:-?} не Ubuntu, но совместим с Debian — продолжаем."
      else
        log_warn "Дистрибутив ${ID:-?} не тестировался; требуется apt."
      fi
      ;;
  esac
else
  log_warn "/etc/os-release недоступен — продолжаем без проверки дистрибутива."
fi

command -v apt-get >/dev/null 2>&1 || die "apt-get не найден. Нужен apt-дистрибутив (Ubuntu/Debian)."

# Запуск через sudo, если не root
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Скрипт требует root. Запустите от root или установите sudo."
  log_info "Запуск через sudo (текущий пользователь не root)…"
  exec sudo -E "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Проверка: установлен ли уже пакет
# ---------------------------------------------------------------------------
is_installed() {
  command -v smbclient >/dev/null 2>&1 && dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "install ok installed"
}

if is_installed && [[ "$FORCE" != true ]]; then
  log_ok "${PKG} уже установлен: $(smbclient --version 2>/dev/null || echo '?')"
  log_info "Для принудительного обновления запустите: ${SCRIPT_NAME} --force"
  exit 0
fi

# ---------------------------------------------------------------------------
# Установка
# ---------------------------------------------------------------------------
APT_LOCK_OPT=(-o "DPkg::Lock::Timeout=${LOCK_TIMEOUT}")

wait_for_apt_lock

if [[ "$NO_UPDATE" == true ]]; then
  log_info "apt-get update пропущен (--no-update)."
elif ! apt-get "${APT_LOCK_OPT[@]}" update -y; then
  log_warn "apt-get update завершился с ошибкой — пробуем установить из кэша."
fi

wait_for_apt_lock

log_info "Установка ${PKG}…"
if ! apt-get "${APT_LOCK_OPT[@]}" install -y --no-install-recommends "$PKG"; then
  if (( LOCK_TIMEOUT > 0 )) && lock_holders >/dev/null 2>&1; then
    log_warn "Установка сорвалась из-за блокировки apt/dpkg. Ожидаем освобождения и повторяем один раз."
    wait_for_apt_lock
    if ! apt-get "${APT_LOCK_OPT[@]}" install -y --no-install-recommends "$PKG"; then
      die "Не удалось установить ${PKG} даже после ожидания блокировки. Проверьте apt-зеркала и процессы, держащие лок."
    fi
  else
    die "Не удалось установить ${PKG}. Проверьте доступность apt-зеркал и повторите попытку."
  fi
fi

# ---------------------------------------------------------------------------
# Верификация
# ---------------------------------------------------------------------------
command -v smbclient >/dev/null 2>&1 || die "smbclient не найден в PATH после установки."
VERSION="$(smbclient --version)" || die "Не удалось получить версию smbclient."
dpkg-query -W -f='${Status}' "$PKG" | grep -q "install ok installed" || die "Пакет ${PKG} не числится установленным в dpkg."
smbclient --usage >/dev/null 2>&1 || die "smbclient не отвечает (--usage завершился ошибкой)."

log_ok "Установка завершена успешно."
log_ok "Версия: ${VERSION}"
log_info "Пример использования: smbclient -L //<server> -U <user>"
