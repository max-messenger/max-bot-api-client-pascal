# Webhook echo bot (console, HTTPS webhook endpoint)

Console example: a bot that receives MAX updates over a webhook (instead of
long polling) and echoes every `message_created` text back to the same chat.
Built on `TMaxWebhookReceiver` (the `maxwebhook` unit of the library): the
delivery contract - the secret check with the 403 form, the oversize/depth
gates, the always-200 delivery policy, the HTTPS endpoint with the PEM pair
and the per-connection IO deadline - lives in the unit, the example is a
client of it and only wires the configuration, the subscription lifecycle
and the echo.

Please create an INI file next to the binary (`max_webhook.ini`):

```ini
[Max]
;; Bot token
Token=
;; Optional: custom API endpoint
EndPoint=
[Webhook]
;; Public HTTPS URL to register on start (https://host/...); empty = do not register
URL=
;; Listen port (the platform requires public 443; use a high port for a local test)
Port=443
;; PEM files for the server certificate (full chain) and the private key
CertFile=
KeyFile=
;; Optional shared secret: when set, the subscription is registered with it,
;; every delivery must carry it in the X-Max-Bot-Api-Secret header, requests
;; without it (or with another value) are answered 403. Leave it empty only
;; when the endpoint is not public: fill it in before a public host - empty
;; here means an unauthenticated public endpoint that accepts forged updates
Secret=
;; Library debug logging: the full JSON of every update (message texts, chat
;; ids - personal data) goes into the log file. Off by default
Debug=false
```

Run:

```bash
./max_webhook
```

On start the bot registers the subscription (`SetWebhook`) when `URL` is set,
then serves HTTPS requests until Ctrl-C (SIGINT) or SIGTERM. On stop it deletes
the subscription (`DeleteWebhook`).

## Live check needs a public host

A real webhook check needs a publicly reachable HTTPS endpoint on port 443 with
a certificate trusted by the platform - not possible from a dev machine behind
NAT, and self-signed certificates are rejected. Typical setups:

- a VPS with a domain and Let's Encrypt (certbot): put the full-chain PEM and
  the key paths into `CertFile`/`KeyFile`, the public URL into `URL`, a long
  random string into `Secret`. The key
  must be **RSA** (`certbot certonly --key-type rsa ...`): FPC 3.2.2 loads the
  server key through `SSL_CTX_use_RSAPrivateKey_file`, so an ECDSA key - the
  certbot default - is silently rejected and every HTTPS connection is reset
  on the TLS handshake with nothing in the log (see the notes below);
- a tunnel with a trusted certificate for a one-off test.

Before a public deploy fill `Secret` in (a long random string), or take the
example off the public host: with `Secret=` left empty the endpoint is
unauthenticated - anyone who learns the URL can POST a forged update and the
bot processes it as a genuine one; the start-up warning line in the log is
the only signal.

The `openssl -nodes` key is unencrypted and the INI file holds the bot token:
on a multi-user VPS make both readable by the owner only and run the bot under
a dedicated user.

```bash
chmod 600 key.pem max_webhook.ini
```

## Local smoke test (no platform)

Self-signed pair for the local TLS check only:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 -subj /CN=localhost
```

INI with `URL=` empty (nothing is registered), `Port=8443`, `CertFile=cert.pem`,
`KeyFile=key.pem`. Then:

```bash
curl -k https://127.0.0.1:8443/            # any request is answered 200 {}
curl -k -X POST https://127.0.0.1:8443/ \
  -H 'Content-Type: application/json' \
  -d '{"update_type":"message_created","message":{"recipient":{"chat_id":123},"body":{"text":"ping"}}}'
```

A valid token in `[Max]` makes the echo real: the bot sends "ping" back to the
chat. The request body is a single update object (the webhook body is not the
`{"updates":[...]}` envelope of long polling). With `Secret=` set, the same
request must also carry the matching `-H 'X-Max-Bot-Api-Secret: <secret>'` -
otherwise it is answered `403` with an empty body and nothing is parsed.

## Notes and limitations

- Webhook and long polling are mutually exclusive: while the URL subscription
  is active, `GetUpdates`-based delivery is paused; the subscription is deleted
  on stop.
- Endpoint behavior - the secret check and the 403 form, always-200 on
  delivery faults, the body size and JSON depth limits, the per-connection
  IO deadline and its reverse-proxy caveats - is the `TMaxWebhookReceiver`
  contract; the canonical text is the unit header of `maxwebhook.pas`,
  not this example.
- Authentication: the endpoint is public by construction, so with `Secret=` set
  the subscription is registered with the secret, the platform echoes it in the
  `X-Max-Bot-Api-Secret` header of every delivery, and the receiver compares
  every request against it - a mismatch (including a missing header) is
  answered `403` with an empty body and the body is never parsed. With an
  empty `Secret` the check is off entirely: every request is processed as a
  genuine update.
- Message texts are personal data: the console line per echo (and the log file
  when `Debug=true`) contains the text of every received message and the chat
  id - keep the console and the log out of reach of everyone but the bot's
  user.
- The server needs the OpenSSL library loadable at runtime (the same
  requirement as the HTTPS features of the library; see the main README for
  TLS notes). A broken TLS configuration (empty or mistyped `CertFile`/
  `KeyFile`, a busy port) stops the example on start with an `EMaxConfig`
  message - the validation is the receiver's `Start` contract.
- The example logs into a `TEventLog` file and leaves its `FileName` empty: the
  FCL logger resolves that into the system temp directory, not next to the
  binary - under systemd `PrivateTmp` the log is invisible from outside and is
  lost with the unit. On a multi-user host a local attacker can also plant
  that default path as a symlink to a file they control before the first
  start - the log (chat ids) follows into their file; the daemon example
  refuses such a path, this example has no guard. Set `TEventLog.FileName`
  explicitly in a stable directory with log rotation for anything long-lived.
- The server private key must be RSA on FPC 3.2.2: its `openssl` unit binds
  the key loader to `SSL_CTX_use_RSAPrivateKey_file`, and a failed
  per-connection SSL accept is swallowed by ssockets without logging - a
  rejected (e.g. ECDSA) key shows up as a connection reset on the TLS
  handshake with an empty log, not as an error message.
- Production alternative: terminate TLS behind a reverse proxy and keep the
  bot on plain HTTP - this example demonstrates the server-side TLS path
  instead.
- The echo send is synchronous and serialized by a critical section: a slow
  API reply stalls the processing of further webhooks. Conscious demo
  tradeoff; a production host would use a queue with a worker and send
  timeouts.
- The body size check (the receiver's `MaxBodySize`, 1 MB by default) runs
  after the server has already read the whole request body into memory: it
  skips the processing of an oversized update but cannot protect the memory
  itself - that is a job for a reverse proxy in front.
