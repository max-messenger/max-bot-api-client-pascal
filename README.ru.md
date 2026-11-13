# fpmax

Библиотека FreePascal/Lazarus для MAX Bot API ([dev.max.ru](https://dev.max.ru)). Целевые операционные системы: Linux и macOS.

Библиотека **не использует никаких сторонних библиотек**, кроме встроенных юнитов FPC (`fcl-web`, `fcl-net`, `openssl` входят в поставку FPC). Вы можете использовать её как самостоятельно, так и в составе других библиотек, к примеру, как [плагин](https://github.com/Al-Muhandis/brook-telegram/) к Brook-framework/Brook4FreePascal.

## Тулчейн и сборка

Зафиксированный тулчейн (обе CI-джобы и локальные сборки): FPC 3.2.2 + Lazarus 4.4 (см. `.github/workflows/make.yml`).

Консольные сборки. Команды запускаются из корня репозитория; собирайте всегда с `-FU` в отдельный каталог `lib`:

``` bash
# консольный тест-раннер + офлайн-сюиты
mkdir -p test/lib
fpc -B -dni18n -dUseCThreads -Futest -Fubot_ex -Fu. -Fuexamples/daemon -FEtest -FUtest/lib test/console.lpr

# примеры (каждый собирается из своего каталога)
cd examples/LongPolling && mkdir -p lib && fpc -B -Fu../.. -FUlib max_longpolling.lpr
cd examples/Webhook && mkdir -p lib && fpc -B -dUseCThreads -Fu../.. -FUlib max_webhook.lpr
cd examples/daemon && mkdir -p lib && fpc -B -dni18n -dUseCThreads -Fu../.. -Fu../../bot_ex -FUlib max_daemon.lpr
```

`mkdir -p` обязателен: компилятор сам не создаёт выходной каталог. `-FU` держит скомпилированные `.ppu`/`.o` вне каталогов с исходниками, где они могли бы затенить ppu пакета при следующей сборке в IDE. Примеру daemon дополнительно нужны `-dni18n` (исключает лазарусовский юнит `Translations`, который тянет `bot_ex/maxbot`; тем же ключом собирается тест-раннер) и свой `-Fu../../bot_ex`.

Lazarus-проекты (`*.lpi` примеров) собираются через `lazbuild`; сама библиотека устанавливается в IDE через пакеты `fpmax.lpk` / `fpmax_dt.lpk`.

## Пакеты и структура

- `fpmax.lpk` - рантайм-юниты: `maxtypes` (модель данных), `maxsendertypes` (отправитель API `TMaxSender` с резолвом доверия TLS), HTTP-брокеры (`maxbasehttpclient` + FCL-брокер `maxfclhttpclientbroker`), `maxutils`, `maxstatlog`, `maxwebhook` (`TMaxWebhookReceiver`, приёмник вебхуков).
- `fpmax_dt.lpk` - design-time компонент `DTMaxLongPollBot` (готовый long polling бот).
- `fpmaxbot_ex.lpk` - прикладной фреймворк `TMaxBot` (юниты `bot_ex`) поверх отправителя, плюс рантайм-юниты DT-компонента `maxbot_dt.pas` и `receiverthread.pas` (оба свободны от LCL).

Примечание: design-time пакет линкует LCL. Non-GUI-хостам следует брать рантайм-юниты из `fpmaxbot_ex` - юнит-приёмник свободен от LCL, а примеры daemon и Webhook показывают headless-хосты.

Примечание о безопасности: свойство `Token` design-time компонента объявлено с `stored False` (td-026). Гарантия действует на запись и только для форм, сохранённых этой и будущими версиями пакета: они никогда не пишут токен в файл формы `.lfm` и в бинарник, в который скомпилирован ресурс формы. Чтение флаг не проверяет: `.lfm`, сохранённый старой версией пакета - или с добавленной рукой строкой `Token = ...` - по-прежнему несёт рабочий токен и загружает его при открытии формы. После апгрейда проверьте свои `.lfm` на `Token =`; первое же пересохранение такой старой формы в IDE молча выкинет строку токена, и бот упадёт на старте с ошибкой `Token for bot is not specified!`. Значение `Token`, введённое в Инспекторе объектов, не записывается ни в файл формы, ни в какой другой артефакт, который производит пакет, значит не попадает и в запущенную программу - задавайте токен в рантайме, как делают примеры.

## Авторизация

Библиотека передаёт голый токен доступа в заголовке `Authorization`, без префикса `Bearer` (согласно документации API dev.max.ru).

## TLS и российский доверенный корневой сертификат

Как библиотека резолвит доверие TLS (`TMaxSender`):

- явный `SSLCAFile` задаёт пин доверия и на FCL-транспорте является **единственным** якорем; канонический контракт - док-комментарий `SSLCAFile` в `maxbasehttpclient.pas` (td-010);
- по умолчанию (пустой `SSLCAFile`, проверка включена) склеивает шипованный `certs/russian-trusted-root-ca.pem` (ищется только рядом с бинарником) с системным бандлом в один якорь;
- если не найден ни один источник - резолв вызывает исключение (fail-closed).

Linux (Debian/Ubuntu): системный бандл - `/etc/ssl/certs/ca-certificates.crt`. Установка корня в систему:

``` bash
cp certs/russian-trusted-root-ca.pem /usr/local/share/ca-certificates/russian-trusted-root-ca.crt
update-ca-certificates
```

macOS: **библиотека читает PEM-бандлы, а не Keychain**. Проще всего держать каталог `certs/` рядом с бинарником: шипованный бандл уже доверяет хосту API, а склейка с системным добавляет Let's Encrypt для upload-хостов. Альтернативы: дописать корень в системный PEM-бандл (`/etc/ssl/cert.pem`, `/opt/homebrew/etc/openssl@3/cert.pem`, `/usr/local/etc/openssl@3/cert.pem`) или задать `SSLCAFile` явно. Установка корня в Keychain - общесистемный вариант для GUI-приложений и curl:

``` bash
security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/russian-trusted-root-ca.pem
```

Учтите, что fp-max Keychain не читает. Экспорт корня в PEM для ручных проверок:

``` bash
security find-certificate -a -c "Russian Trusted Root CA" -p
```

Оговорки:

- `SSLVerifyCert := False` отключает проверку сертификата - только для локального теста, это открывает канал man-in-the-middle.
- На стандартных хостах обычный барьер - загрузка библиотеки OpenSSL, а не сертификаты (известные ограничения: на macOS `InitSSLInterface` нужны библиотеки OpenSSL с именами 1.1; в Debian безверсионный `libssl.so` ставится пакетом `libssl-dev`).

## Получение обновлений

- **Long polling**: `TMaxSender.GetUpdatesEx` или design-time компонент `DTMaxLongPollBot` (см. контракт `SynchronizeEvents` в `receiverthread.pas`).
- **Webhook**: обёртки `SetWebhook` / `DeleteWebhook` у `TMaxSender`, приёмник `TMaxWebhookReceiver` из юнита `maxwebhook` (`Start` блокируется до `Stop`; ответ - 200 на любую сбойную доставку и 403 только при несовпадении секрета; неудачный бинд поднимает `EMaxConfig` с портом в сообщении; любой другой `ESocketError` стартового окна - отказавший accept, а не бинд - уходит наружу как есть и останавливает хост с честным диагнозом) и полноценный пример в `examples/Webhook` (HTTPS-клиент вебхуков на `TMaxWebhookReceiver` с OpenSSL). Два механизма доставки взаимоисключающие: пока активна подписка по URL, доставка long polling приостановлена. Платформа требует строго HTTPS на порту 443 с публично доверенным сертификатом; серверный ключ должен быть RSA.
- **Inline-клавиатуры**: `MakeInlineKeyboardAttachment` из `maxsendertypes` собирает массив вложений `SendMessageEx` из плоских пар `Text,Payload` - одна строка callback-кнопок, двумерная по построению (`payload.buttons` обязан быть 2D: плоский массив отвергается с HTTP 400).
- Non-GUI-хосты: поддерживаются - запускайте приёмник с `SynchronizeEvents := False` и используйте рантайм-юниты напрямую; пример `daemon` - headless long-polling-хост с логом `TEventLog`, корректной остановкой по SIGTERM и поставляемыми шаблонами юнит-файлов systemd/launchd (`examples/daemon`), пример Webhook - headless-образец на `TMaxWebhookReceiver`.

## Примеры

| Каталог | Что показывает |
| --- | --- |
| `LongPolling` | консольный эхо-бот, один поток, long polling |
| `Webhook` | консольный эхо-бот, HTTPS-клиент `TMaxWebhookReceiver` (OpenSSL) |
| `daemon` | headless-демон: long polling с `SynchronizeEvents=False`, `TEventLog`, корректная остановка по SIGTERM, шаблоны юнит-файлов systemd/launchd |
| `LongPollingDesktop` | настольное GUI, обновления в отдельном потоке |
| `DesignTime` | настольное GUI на компоненте `DTMaxLongPollBot` |
| `getMe` | настольное GUI, один вызов API, без получения обновлений |
| `SimpleSendMessage` | консоль, отправка одного сообщения |
| `linux_pclocker` | консоль с окном X11/Cairo, только Linux |

## Тесты

См. `test/readme.md`: как собрать консольный раннер, какие сюиты выполняются офлайн (`TTestSenderTypes`, `TTestMaxBot`, `TTestTLSTrust`) и какие - онлайн против реального бота (`TTestSender`).
