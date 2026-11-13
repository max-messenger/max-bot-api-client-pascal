# Daemon example (console, headless long polling)

Console example: a bot for an unattended host (a Linux systemd service, a
macOS launchd job, a nohup'ed process). It receives updates via long polling
and writes one log line per update into a `TEventLog` file - it sends
nothing back. The point of the example is the headless plumbing, not the bot
logic:

- the receiver runs with `SynchronizeEvents := False` (`TLongPollingThread`
  from the LCL-free `receiverthread` unit): the events are delivered right
  in the receiver thread. A headless process has no synchronize pump -
  nothing calls `CheckSynchronize` - so the default `True` would sink every
  event into a queue nobody drains;
- the update handler is thread-safe and GUI-free by contract: one locked log
  write, nothing else;
- SIGTERM (and SIGINT for a foreground run) stops the daemon gracefully: the
  signal handler only raises a flag, the main loop sees it and joins the
  receiver (`Terminate` + `WaitFor` + `Free`);
- the reconnect policy lives in the service manager, not in the process:
  a clean stop exits 0 (the manager keeps it stopped), a receiver that died
  on its own (a configuration error) exits 1 and the manager restarts the
  daemon, rate-limited by the unit template.

Build (from this directory):

```bash
mkdir -p lib && fpc -B -dni18n -dUseCThreads -Fu../.. -Fu../../bot_ex -FUlib max_daemon.lpr
```

`-dni18n` excludes the Lazarus `Translations` unit pulled by `bot_ex/maxbot`
(the test runner builds with the same switch); `-dUseCThreads` is mandatory:
on UNIX the build is green without it and the first thread crashes at runtime
(error 232).

Please create an INI file next to the binary (`max_daemon.ini`):

```ini
[Max]
;; Bot token
Token=
;; Optional: custom API endpoint
EndPoint=
[Daemon]
;; Optional: log file path; empty = a .log file named after the binary in
;; the temp directory (under systemd PrivateTmp - the service's own /tmp),
;; not next to the binary; a planted default path refuses to start (see
;; Notes). Set it explicitly.
LogFile=
```

Create the file 600 BEFORE the token goes in (the recipe of the shipped
systemd/launchd templates; a file an editor creates starts 0644 and the
token sits readable by other local accounts until a late `chmod`):

```bash
install -m 600 /dev/null max_daemon.ini
```

Then fill the token in with an editor - the mode survives the edit.

Run (foreground, Ctrl-C to stop):

```bash
./max_daemon
```

On start the daemon validates the token (an empty one fails fast with an
`EMaxConfig` on stderr before any file is created) and the default log
location (a symlink or a foreign-owned file planted at the default path is
the same `EMaxConfig` fail-fast, see Notes), starts the receiver and
logs `update <type>, chat <id>, text length <n>` per update. Message texts
are deliberately not logged (a daemon log lives unattended in `/var/log` or
the launchd log; texts are personal data - the same reason the library's
`LogDebug` stays off by default).

## How to stop it

`systemctl stop fpmax-daemon`, `launchctl bootout system/fpmax.daemon`, or a
plain `kill <pid>` - all three deliver SIGTERM, the handler raises the flag
and the main loop joins the receiver. The stop latency is one in-flight
long-poll request: the broker HTTP timeout is
`max(TMaxSender.Timeout, polling window + 3 s)`, 30 s with the defaults.
Both unit templates leave a wide margin above it (`TimeoutStopSec=45`,
`ExitTimeOut=45`).

## Service manager templates

- `systemd/fpmax-daemon.service` - `Type=simple`, `Restart=on-failure`,
  `RestartSec=5s`, `TimeoutStopSec=45`, a `StartLimitIntervalSec`/
  `StartLimitBurst` crash-loop guard, minimal hardening
  (`ProtectSystem=strict` with `ReadWritePaths` on the deploy directory,
  `UMask=0077` for the token in the ini and the chat ids in the log).
  Install steps are in the file header.
- `launchd/fpmax-daemon.plist` - `RunAtLoad`, `KeepAlive` as a dictionary
  with `SuccessfulExit=false` (the launchd mirror of `Restart=on-failure`:
  a clean exit stays stopped), `ThrottleInterval=10`, `ExitTimeOut=45`,
  stdout/stderr capture. Install steps are in the file header; they create
  a dedicated `fpmax` user, because in `/Library/LaunchDaemons` the service
  would run as root by default (a per-user `LaunchAgents` install is the
  alternative). Unlike systemd there is no restart cap: `ThrottleInterval`
  only slows a crash loop down (launchd clamps it to a minimum of 10), on a
  permanently broken configuration the restarts go on forever - watch the
  job.

Both templates assume the layout `/opt/fpmax/` with the binary, the ini and
the log together; adjust the paths if you deploy differently. The example
resolves the ini next to the binary (not the CWD), so `WorkingDirectory` is
a convenience, not a requirement; the default log with an empty
`[Daemon] LogFile` instead goes to the temp directory (see Notes).

## Notes and limitations

- The daemon needs the OpenSSL library loadable at runtime (the same
  requirement as every TLS feature of the library; see the main README for
  TLS notes).
- A `TEventLog` with `ltFile` may silently not create the log file on macOS
  (observed on darwin 24): when debugging on macOS, watch the stderr
  capture too.
- The log file is appended to forever (`AppendContent`), no rotation is
  built in. With an empty `[Daemon] LogFile` the default lands in the temp
  directory (`GetTempDir`: the per-user folder on macOS, `TMPDIR` or `/tmp`
  on the service hosts; under systemd PrivateTmp - invisible from outside),
  so point `[Daemon] LogFile` at a stable directory the host already
  rotates, or add a `logrotate` rule (systemd) / a `newsyslog` rule
  (launchd) for `/opt/fpmax`.
- The default log path is guarded against symlink relocation: a local user
  can plant the default path (a `.log` named after the binary in the temp
  directory) as a symlink to a file they control before the first start -
  the append would follow it and write the log (chat ids) into a foreign
  file, and the 0600 mode of a self-created log cannot protect the target
  of a foreign symlink. Before activating the logger the daemon checks the
  default path and refuses to start (`EMaxConfig`) when the path is taken
  by a symlink or another non-regular file, or by a file owned by another
  account; a leftover of a previous run of the same account is still
  appended to, so restarts keep their log. The fix is to remove the path or
  set `[Daemon] LogFile` explicitly.
- Restart-on-disconnect is deliberately not implemented in the process: the
  receiver thread retries transient polling failures itself and terminates
  only on a configuration error, and the unit templates restart the process
  (rate-limited) in that case. A host that wants in-process reconnection
  gets the full contract in the `SynchronizeEvents` comment of
  `receiverthread.pas` and can build on the `TDTMaxLongPollBot` component
  (the LCL-free runtime units live in the `fpmaxbot_ex` package).
- The example holds no own `TMaxSender`: it only logs. For sending from an
  update handler create an own `TMaxSender` in the handler (see
  `examples/LongPolling` for the echo logic).
