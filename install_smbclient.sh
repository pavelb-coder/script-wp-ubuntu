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
  --force       Принудительно обновить/переустановить пакет, даже если он уже установлен
  --no-update   Не выполнять 'apt-get update' перед установкой
  -h, --help    Показать эту справку

Без опций скрипт идемпотентен: если ${PKG} уже установлен,
выводится версия и скрипт завершается с кодом 0.
EOF
}

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)     FORCE=true; shift ;;
    --no-update) NO_UPDATE=true; shift ;;
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
if [[ "$NO_UPDATE" == true ]]; then
  log_info "apt-get update пропущен (--no-update)."
elif ! apt-get update -y; then
  log_warn "apt-get update завершился с ошибкой — пробуем установить из кэша."
fi

log_info "Установка ${PKG}…"
if ! apt-get install -y --no-install-recommends "$PKG"; then
  die "Не удалось установить ${PKG}. Проверьте доступность apt-зеркал и повторите попытку."
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
