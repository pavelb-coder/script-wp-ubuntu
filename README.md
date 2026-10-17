# script-wp-ubuntu

Скрипты для Ubuntu:
- `install_smbclient.sh` — установка smbclient (Samba-клиент);
- `fix_wp_upload_max_filesize.sh` — исправление ошибки WordPress «Загруженный файл
  превышает директиву upload_max_filesize в php.ini.»

## install_smbclient.sh

Скрипт для Ubuntu, устанавливающий **smbclient** (Samba-клиент: доступ к SMB/CIFS-шарам из консоли).
Также работает на Debian и других apt-дистрибутивах.

### Возможности

- идемпотентность: если smbclient уже установлен, выводится версия, код возврата 0;
- проверка ОС (Ubuntu/Debian, предупреждение для остальных apt-дистрибутивов);
- автоподъём прав: при запуске не от root скрипт перезапускает себя через sudo;
- `apt-get update` при сбое сети не фатален — попытка установки из кэша;
- **обход блокировки apt/dpkg**: если `/var/lib/dpkg/lock-frontend` и другие локи удерживаются
  процессом (обычно фоновое автообновление unattended-upgrades), скрипт определяет держателя
  по имени и PID, ждёт освобождения (по умолчанию до 300 с, настраивается `--lock-timeout`)
  и повторяет установку; если лок перехвачен между проверкой и установкой — один повтор
  после ожидания. Держатель лока ищется через `fuser` (psmisc), а при его отсутствии —
  сканированием `/proc/*/fd` (работает в минимальных контейнерах);
- верификация после установки: бинарник в PATH, версия, статус в dpkg, ответ на `--usage`;
- без цвета в неинтерактивном выводе (пригодно для CI и логов).

### Использование

```bash
chmod +x install_smbclient.sh
sudo ./install_smbclient.sh                        # установка
sudo ./install_smbclient.sh --force                # принудительное обновление/переустановка
sudo ./install_smbclient.sh --no-update            # пропустить apt-get update
sudo ./install_smbclient.sh --lock-timeout 600     # ждать освобождения лока dpkg до 10 минут
sudo ./install_smbclient.sh --lock-timeout 0       # не ждать блокировку (старое поведение)
./install_smbclient.sh --help                      # справка
```

Коды возврата: `0` — успех (в т.ч. «уже установлен»), `1` — ошибка, `2` — неверные аргументы.

### Тестирование

```bash
tests/test_install.sh                 # статика + мок-тесты логики + реальная установка
tests/test_install.sh --skip-install  # без этапа с реальными apt-зеркалами
tests/test_install.sh --with-server   # + интеграционный тест с локальным smbd (порт 4450):
                                      #   smbclient -L, put/get round-trip
```

Мок-тесты подменяют `apt-get`/`dpkg-query`/`smbclient` в PATH и покрывают все ветки
логики без сети и реальных пакетов: свежая установка, идемпотентность, `--force`,
`--no-update`, ошибки apt, провал верификации.

### Примеры использования smbclient

```bash
smbclient -L //server -U user                # список шар сервера
smbclient //server/share -U user             # интерактивный сеанс
smbclient //server/share -N -c 'get file'    # анонимное скачивание файла
```

## fix_wp_upload_max_filesize.sh

Исправляет ошибку WordPress **«Загруженный файл превышает директиву upload_max_filesize
в php.ini.»** при загрузке файлов через админку.

Что делает:
1. находит установки WordPress (`wp-settings.php`) в `/var/www`, `/srv` (или через `--wp-path`);
2. правит php.ini только веб-SAPI (fpm, apache2, cgi) — CLI не трогает;
3. ставит `upload_max_filesize = 64M`, поднимает `post_max_size` (>= upload)
   и `memory_limit` (>= post, минимум 128M; `-1` не трогает);
4. бэкапит каждый изменённый php.ini (`php.ini.bak.<метка времени>`);
5. перезагружает `phpX.Y-fpm` / `apache2` (systemctl → service → предупреждение);
6. опционально `--user-ini` — пишет `.user.ini` в корень WordPress.

```bash
sudo ./fix_wp_upload_max_filesize.sh                      # поиск WP + лимит 64M
sudo ./fix_wp_upload_max_filesize.sh --size 128M          # другой лимит
sudo ./fix_wp_upload_max_filesize.sh --wp-path /var/www/html --user-ini
sudo ./fix_wp_upload_max_filesize.sh --dry-run            # только показать изменения
sudo ./fix_wp_upload_max_filesize.sh --no-restart         # без перезагрузки сервисов
sudo ./fix_wp_upload_max_filesize.sh --force              # применить, даже если WP не найден
```

Коды возврата: `0` — успех (в т.ч. «лимиты уже достаточны»), `1` — ошибка, `2` — неверные аргументы.

### Тестирование

```bash
tests/test_wp_upload.sh    # 28 проверок на мок-окружении (не требует PHP/WordPress)
```

Примечание: если файлы большого размера не грузятся и после этого скрипта — проверьте
`client_max_body_size` в nginx (ошибка 413) и `LimitRequestBody` в Apache: это отдельные
ограничения веб-сервера, не относящиеся к php.ini.
