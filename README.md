# script-wp-ubuntu

## install_smbclient.sh

Скрипт для Ubuntu, устанавливающий **smbclient** (Samba-клиент: доступ к SMB/CIFS-шарам из консоли).
Также работает на Debian и других apt-дистрибутивах.

### Возможности

- идемпотентность: если smbclient уже установлен, выводится версия, код возврата 0;
- проверка ОС (Ubuntu/Debian, предупреждение для остальных apt-дистрибутивов);
- автоподъём прав: при запуске не от root скрипт перезапускает себя через sudo;
- `apt-get update` при сбое сети не фатален — попытка установки из кэша;
- верификация после установки: бинарник в PATH, версия, статус в dpkg, ответ на `--usage`;
- без цвета в неинтерактивном выводе (пригодно для CI и логов).

### Использование

```bash
chmod +x install_smbclient.sh
sudo ./install_smbclient.sh              # установка
sudo ./install_smbclient.sh --force      # принудительное обновление/переустановка
sudo ./install_smbclient.sh --no-update  # пропустить apt-get update
./install_smbclient.sh --help            # справка
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
