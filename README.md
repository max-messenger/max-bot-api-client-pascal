# fpmax

FreePascal/Lazarus library for the MAX Bot API ([dev.max.ru](https://dev.max.ru)). Target operating systems: Linux and macOS.

The library **does not use any third-party libraries**, besides the built-in FPC units (`fcl-web`, `fcl-net`, `openssl` are all part of the FPC distribution). You can use it both independently and together with other libraries, for example, as a [plug-in](https://github.com/Al-Muhandis/brook-telegram/) to Brook-framework/Brook4FreePascal.

## Toolchain and building

The pinned toolchain (both CI jobs and local builds): FPC 3.2.2 + Lazarus 4.4 (see `.github/workflows/make.yml`).

Console builds. Run from the repository root; always build with `-FU` into a dedicated `lib` directory:

``` bash
# console test runner + offline suites
mkdir -p test/lib
fpc -B -dni18n -dUseCThreads -Futest -Fubot_ex -Fu. -Fuexamples/daemon -FEtest -FUtest/lib test/console.lpr

# examples (each one is built from its own folder)
cd examples/LongPolling && mkdir -p lib && fpc -B -Fu../.. -FUlib max_longpolling.lpr
cd examples/Webhook && mkdir -p lib && fpc -B -dUseCThreads -Fu../.. -FUlib max_webhook.lpr
cd examples/daemon && mkdir -p lib && fpc -B -dni18n -dUseCThreads -Fu../.. -Fu../../bot_ex -FUlib max_daemon.lpr
```

`mkdir -p` is required because the compiler does not create the output directory itself. `-FU` keeps the compiled `.ppu`/`.o` files out of the source folders, where they could shadow the ppu of the package on the next IDE build. The daemon example additionally needs `-dni18n` (excludes the Lazarus `Translations` unit pulled by `bot_ex/maxbot`, the same switch the test runner builds with) and its own `-Fu../../bot_ex`.

Lazarus projects (`*.lpi` of the examples) are built with `lazbuild`; the library itself is installed into the IDE through the `fpmax.lpk` / `fpmax_dt.lpk` packages.

## Packages and structure

- `fpmax.lpk` - the runtime units: `maxtypes` (data model), `maxsendertypes` (`TMaxSender` API sender with TLS trust resolution), the HTTP client brokers (`maxbasehttpclient` + the FCL-based `maxfclhttpclientbroker`), `maxutils`, `maxstatlog`, `maxwebhook` (`TMaxWebhookReceiver`, the webhook endpoint).
- `fpmax_dt.lpk` - the design-time component `DTMaxLongPollBot` (a ready-made long polling bot).
- `fpmaxbot_ex.lpk` - the `TMaxBot` application framework (`bot_ex` units) on top of the sender, plus the DT component runtime units `maxbot_dt.pas` and `receiverthread.pas` (both LCL-free).

Note: the design-time package links the LCL. Non-GUI hosts should take the runtime units from `fpmaxbot_ex` instead - the receiver unit is LCL-free, and the daemon and Webhook examples show headless hosts.

Security note: the `Token` property of the design-time component is declared `stored False` (td-026). The guarantee is write-side and covers forms saved by this and later versions of the package: they never write the token into the `.lfm` form file, nor into the binary resource the form is compiled into. Loading never checks the flag - a `.lfm` saved by an older package version, or with a hand-added `Token = ...` line, still carries a working token and still loads it when the form opens. After upgrading, grep your `.lfm` files for `Token =`; the first re-save of such an old form in the IDE silently drops the token line, and the bot then fails at start with `Token for bot is not specified!`. A `Token` value typed into the Object Inspector is never written to the form file or any other artifact the package produces, so it never reaches the running program either - set the token at run time, as the examples do.

## Authorization

The library sends the raw access token in the `Authorization` header, without the `Bearer` prefix (per the dev.max.ru API docs).

## TLS and the Russian trusted root certificate

How the library resolves TLS trust (`TMaxSender`):

- an explicit `SSLCAFile` pins the trust and is the **only** trust anchor on the FCL transport; the canonical contract is the `SSLCAFile` doc comment in `maxbasehttpclient.pas` (td-010);
- by default (empty `SSLCAFile`, verification on) it merges the shipped `certs/russian-trusted-root-ca.pem` (looked up next to the binary only) with the system bundle into one anchor;
- when neither source is found, the resolution fails with an exception (fail-closed).

Linux (Debian/Ubuntu): the system bundle is `/etc/ssl/certs/ca-certificates.crt`. Install the root system-wide:

``` bash
cp certs/russian-trusted-root-ca.pem /usr/local/share/ca-certificates/russian-trusted-root-ca.crt
update-ca-certificates
```

macOS: **the library reads PEM bundles, not the Keychain**. The simplest way is to keep the `certs/` folder next to the binary: the shipped bundle already trusts the API host, and merging it with the system bundle adds Let's Encrypt for the upload hosts. Alternatives: append the root to a system PEM bundle (`/etc/ssl/cert.pem`, `/opt/homebrew/etc/openssl@3/cert.pem`, `/usr/local/etc/openssl@3/cert.pem`), or set `SSLCAFile` explicitly. Installing the root into the Keychain is the system-wide option for GUI applications and curl:

``` bash
security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/russian-trusted-root-ca.pem
```

Note that fp-max does not read the Keychain. To export the root as PEM for manual checks:

``` bash
security find-certificate -a -c "Russian Trusted Root CA" -p
```

Caveats:

- `SSLVerifyCert := False` disables verification - only for a local test: it opens the channel to a man-in-the-middle.
- On stock hosts the usual barrier is loading the OpenSSL library, not certificates (known limitations: on macOS `InitSSLInterface` needs 1.1-named OpenSSL libraries; on Debian the unversioned `libssl.so` comes with `libssl-dev`).

## Receiving updates

- **Long polling**: `TMaxSender.GetUpdatesEx`, or the `DTMaxLongPollBot` design-time component (see the `SynchronizeEvents` contract in `receiverthread.pas`).
- **Webhook**: the `SetWebhook` / `DeleteWebhook` wrappers of `TMaxSender`, the `TMaxWebhookReceiver` endpoint of the `maxwebhook` unit (`Start` blocks until `Stop`; the answer is 200 on every delivery fault and 403 only on a secret mismatch; a failed bind raises `EMaxConfig` naming the port; any other `ESocketError` of the startup window - a failed accept, not a bind - propagates as is and stops the host with the honest diagnosis), and a full example in `examples/Webhook` (an HTTPS webhook client of `TMaxWebhookReceiver` with OpenSSL). The two delivery mechanisms are mutually exclusive: while the URL subscription is active, long polling delivery is paused. The platform requires strictly HTTPS on port 443 with a publicly trusted certificate; the server key must be RSA.
- **Inline keyboards**: `MakeInlineKeyboardAttachment` of `maxsendertypes` builds the `SendMessageEx` attachments array from flat `Text,Payload` pairs - one row of callback buttons, two-dimensional by construction (`payload.buttons` must be 2D: a flat array is rejected with HTTP 400).
- Non-GUI hosts: supported - run the receiver with `SynchronizeEvents := False` and use the runtime units directly; the `daemon` example is a headless long-polling host with `TEventLog` logging, graceful SIGTERM stop and shipped systemd/launchd unit templates (`examples/daemon`), the Webhook example is a headless sample built on `TMaxWebhookReceiver`.

## Examples

| Folder | What it shows |
| --- | --- |
| `LongPolling` | console echo bot, single thread, long polling |
| `Webhook` | console echo bot, HTTPS webhook client of `TMaxWebhookReceiver` (OpenSSL) |
| `daemon` | headless daemon: long polling with `SynchronizeEvents=False`, `TEventLog`, graceful SIGTERM stop, systemd/launchd unit templates |
| `LongPollingDesktop` | desktop GUI, updates received in a separate thread |
| `DesignTime` | desktop GUI built around the `DTMaxLongPollBot` component |
| `getMe` | desktop GUI, a single API call, no update receiving |
| `SimpleSendMessage` | console, sends one message |
| `linux_pclocker` | console with an X11/Cairo window, Linux only |

## Tests

See `test/readme.md`: how to build the console runner, which suites run offline (`TTestSenderTypes`, `TTestMaxBot`, `TTestTLSTrust`) and which run online against a real bot (`TTestSender`).

## Conventions

- `{$mode objfpc}{$H+}` in every unit/program; comments and identifiers in English; WHY-comments on non-obvious decisions (examples get copied).
- Debt records: `docs/tech-debt/` (catalog: `docs/tech-debt/INDEX.md`) — closed records keep their file as archive and only lose their INDEX line; anchor by symbols, never by line numbers (they drift).
