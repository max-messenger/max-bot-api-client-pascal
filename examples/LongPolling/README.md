Console one-thread example: a minimal echo bot
The bot receives messages via long polling and sends each text back to the same chat.
Media messages (image, video, audio, file) get an honest echo: the file is downloaded
from the received URL and uploaded fresh through the full upload cycle, so the reply
carries a new upload token. Attachments without a downloadable URL fall back to
re-sending the received token. The text of a media message is not echoed unless
every attachment failed to fetch or upload (then the text goes out alone).

Please create INI file next to the binary (max_longpolling.ini, named after the executable):
```ini
[Max]
;; Max token of the bot
Token=
;; Optional: custom API endpoint (usually left empty)
EndPoint=
```

Running:
1. Put your bot token into the INI file.
2. Run the binary from the repository root (so the bundled `certs/` directory
   with the Russian Trusted Root CA is found for TLS verification), or copy
   `certs/` next to the binary.
3. Send a message to the bot in MAX - it replies with the same text.

The example pulls in the `cwstring` unit on UNIX: without the widechar
manager FPC string conversions turn every non-ASCII character into `?`,
which corrupts non-Latin echo texts.

The example logs into a `TEventLog` file and leaves its `FileName` empty: the
FCL logger resolves that into the system temp directory, not next to the
binary - under systemd `PrivateTmp` the log is invisible from outside and is
lost with the unit. On a multi-user host a local attacker can also plant that
default path as a symlink to a file they control before the first start - the
log (chat ids) follows into their file; the daemon example refuses such a
path, this example has no guard. Set `TEventLog.FileName` explicitly in a
stable directory with log rotation for anything long-lived.
