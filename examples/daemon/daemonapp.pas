unit daemonapp;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, CustApp, syncobjs, eventlog, maxtypes, maxsendertypes,
  receiverthread
  ;

const
  // Granularity, in milliseconds, of the main-loop wait: the loop checks the
  // stop flag and the receiver liveness once per round, so this is also the
  // shutdown latency after the stop flag is raised
  MainLoopIdleMs = 200;

var
  // Set by the signal handler, checked by the main loop: a signal handler
  // may only raise a flag, any object access or logging from it would be
  // unsafe (the same shape as examples/Webhook). Declared in the interface
  // on purpose: it is the one piece of loop state an offline test of the
  // daemon must reset before calling Run (td-091)
  gStop: Boolean = False;

type

  { TDaemonApplication }

  TDaemonApplication = class(TCustomApplication)
  private
    FReceiver: TLongPollingThread;
    FLogger: TEventLog;
    FLogCS: TCriticalSection;
    // True while this class still owns FLogger: the Logger setter of the
    // receiver thread transfers the ownership to the thread, which frees the
    // logger in its destructor - after the transfer this class must not
    // touch it. The flag covers the constructor failure paths where the
    // transfer never happened (the destructor runs when a constructor raises)
    FLoggerOwned: Boolean;
    // False until Start succeeds: a stop signal (or a failed Start) in the
    // window between the handler setup and Start leaves a suspended,
    // never-started thread, on which both a bare Free and a lone WaitFor
    // deadlock - StopReceiver drains such a thread with Terminate-then-Start
    FReceiverStarted: Boolean;
    procedure HandleUpdate({%H-}ASender: TObject; AnUpdate: TMaxUpdateObj);
    procedure Log(AEventType: TEventType; const AMsg: String);
    procedure StopReceiver;
  protected
    { The only place the real receiver is created. A virtual on purpose
      (td-091): the offline failed-start test swaps in a stub receiver here
      without touching any other daemon code }
    function CreateReceiver: TLongPollingThread; virtual;
    { The single funnel of every FReceiver.Start of the start/stop window -
      the failed-start attempt of DoRun and the drain of a never-started
      thread in StopReceiver. TThread.Start is not virtual (FPC 3.2.2), so a
      receiver stub cannot intercept the start itself: the seam of the
      offline failed-start test lives one level up, here (td-091) }
    procedure StartReceiver; virtual;
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  {$IFDEF UNIX}
  baseunix, // fpSignal/SIGINT/SIGTERM of the stop switch and the fpLStat/
            // fpGeteuid of the default-log guard below
  {$ENDIF}
  configuration
  ;

{$IFDEF UNIX}
procedure StopSignalHandler({%H-}SigNum: LongInt); cdecl;
begin
  gStop:=True;
end;

// The default log path for an empty [Daemon] LogFile, resolved by this unit
// instead of left to the TEventLog activation (td-090): the temp directory
// of the process (SysUtils.GetTempDir - the per-user folder on macOS, TMPDIR
// or /tmp on the service hosts) plus the binary-named .log, the shape the
// FCL empty-FileName activation produced (td-085). Computing it here - not
// replicating the FCL rule in a check - is the point: the guarded string is
// literally the name the logger opens, the two can never drift apart (the
// FCL resolution itself is not ours to predict: on darwin 24 the empty-
// FileName activation landed in /tmp while GetTempDir returns the per-user
// folder - pinned empirically)
function DefaultTempLogPath: String;
begin
  Result:=IncludeTrailingPathDelimiter(GetTempDir(False))
    +ChangeFileExt(ExtractFileName(ParamStr(0)), '.log');
end;

// The symlink-relocation guard (td-090): in a shared temp directory a local
// attacker can plant the default path as a symlink to an own file BEFORE the
// first start - AppendContent would follow it and stream the log (chat ids)
// into a file the attacker controls; the 0600 umask of the lpr protects the
// file the daemon creates, not the target of a foreign symlink. Only two
// states are allowed at the default path: nothing (this run creates the file
// itself, private via the umask) and a regular file owned by this very
// account - the leftover of a previous run of the same daemon, the one case
// AppendContent must keep working for. Everything else (a symlink, a fifo or
// device, a foreign-owned file) is a fail-fast EMaxConfig before any file is
// touched - the same shape as the empty-token check next to the call site;
// under a service manager the message lands in the journal on every restart
// until a human removes the plant or sets an explicit [Daemon] LogFile. Out
// of scope: the check-then-activate race (a plant swapped in between) would
// need O_NOFOLLOW open semantics - forking fcl-base, which td-090 rules out;
// the sticky temp directory already blocks replacing the path once the
// daemon owns the file
procedure VerifyDefaultTempLog(const APath: String);
var
  SB: Stat;
begin
  if fpLStat(APath, SB)<>0 then
    Exit;
  if not fpS_ISREG(SB.st_mode) then
    raise EMaxConfig.Create('Refusing to log to the default location '+APath
      +': the path is taken by a symlink or another non-regular file (a '
      +'planted one would move the log into a foreign file). Remove it or '
      +'set [Daemon] LogFile in '
      +ChangeFileExt(ParamStr(0), '.ini'));
  if SB.st_uid<>fpGeteuid then
    raise EMaxConfig.Create('Refusing to log to the default location '+APath
      +': the path already holds a file owned by another account. Remove it '
      +'or set [Daemon] LogFile in '
      +ChangeFileExt(ParamStr(0), '.ini'));
end;
{$ENDIF}

{ TDaemonApplication }

procedure TDaemonApplication.Log(AEventType: TEventType; const AMsg: String);
begin
  // TEventLog has no internal locking (FCL 3.2.2): the update handlers run
  // in the receiver thread while the main thread logs the lifecycle events,
  // so every write goes through one section (the same shape as
  // examples/Webhook)
  FLogCS.Enter;
  try
    case AEventType of
      etError: FLogger.Error(AMsg);
      etWarning: FLogger.Warning(AMsg);
      etDebug: FLogger.Debug(AMsg);
    else
      FLogger.Info(AMsg);
    end;
  finally
    FLogCS.Leave;
  end;
end;

procedure TDaemonApplication.HandleUpdate(ASender: TObject;
  AnUpdate: TMaxUpdateObj);
begin
  // With SynchronizeEvents=False this runs in the receiver thread: by
  // contract the handler must be thread-safe and GUI-free - one locked log
  // write and nothing else. The message TEXT is deliberately not logged
  // (only its length): a daemon log lives unattended in /var/log or the
  // launchd log, message texts are personal data - the same reason the
  // library's LogDebug stays off by default
  Log(etInfo, Format('[Daemon] update %s, chat %d, text length %d',
    [AnUpdate.UpdateTypeStr, AnUpdate.ChatId, AnUpdate.MessageBodyTextLength]));
end;

procedure TDaemonApplication.StopReceiver;
begin
  if FReceiver=Nil then
    Exit;
  // Harmless when the receiver already finished on its own (a configuration
  // error terminates it from inside its Execute): the flag is already set,
  // the join below is what actually synchronizes the shutdown
  FReceiver.Terminate;
  // A receiver created suspended and never started (the stop signal arrived
  // between the handler setup and Start, or Start itself failed) would
  // deadlock here: WaitFor joins a thread that never ran, and a bare Free
  // deadlocks the same way (TThread.Destroy joins too). Execute begins with
  // "while not Terminated", so starting it after Terminate exits it at once
  // and the join below returns immediately
  if not FReceiverStarted then
    StartReceiver;
  // Bounded by one in-flight long-poll request (the broker HTTP timeout is
  // max(TMaxSender.Timeout, polling window + 3 s), 30 s with the defaults)
  // plus one plain 1 s retry pause Sleep does not interrupt (the transport
  // and 429 backoff ladder is different - it is interrupted in 100 ms
  // slices), plus up to one MainLoopIdleMs round: about 31 s worst case.
  // The shipped unit templates leave a wide margin above it:
  // TimeoutStopSec=45 (systemd) and ExitTimeOut=45 (launchd)
  FReceiver.WaitFor;
  // Frees the moved logger too: nothing may log through FLogger after this
  FReceiver.Free;
  FReceiver:=Nil;
end;

function TDaemonApplication.CreateReceiver: TLongPollingThread;
begin
  Result:=TLongPollingThread.Create;
end;

procedure TDaemonApplication.StartReceiver;
begin
  FReceiver.Start;
end;

procedure TDaemonApplication.DoRun;
var
  // True when the loop ended because the receiver finished on its own (and
  // the stop flag is not set): decides the exit code below. A local, not a
  // field - nothing outside DoRun reads it
  ReceiverDied: Boolean;
begin
  {$IFDEF UNIX}
  // Signals are the stop switch: systemd and launchd stop the service with
  // SIGTERM, SIGINT covers Ctrl-C of a foreground manual run. The handler
  // only raises the flag, the shutdown runs in the main loop
  fpSignal(SIGINT, @StopSignalHandler);
  fpSignal(SIGTERM, @StopSignalHandler);
  {$ENDIF}
  // The handlers are installed only here - earlier a signal kills the
  // process by the default disposition, there is nothing to guard. The check
  // closes the window between the fpSignal calls above and this line: a stop
  // that already arrived must not start the receiver, otherwise it would
  // poll on until its first window ends before noticing Terminate (the same
  // guard as examples/Webhook). A signal after the check is harmless: the
  // loop below exits at once and StopReceiver drains even a never-started
  // thread
  if not gStop then
  begin
    // A failed thread start (or the log write announcing it) must not leave
    // the orphaned receiver around:
    // stop it through the same safe path as the normal shutdown (a failed
    // Start can leave the thread suspended and never started - freeing it
    // directly would deadlock). TCustomApplication.Run catches an exception
    // escaping DoRun and calls DoRun again until FTerminated is set, so the
    // order inside this handler is load-bearing: ExitCode and Terminate come
    // FIRST, everything after them must be allowed to fail. The cleanup
    // drains a never-started thread with one more Start, and a persistent
    // start failure (an exhausted process/pid/memory limit on an unattended
    // host) raises there the same way - an exception escaping the handler
    // would skip the rest of it, leave FTerminated=False and Run would call
    // DoRun again: an infinite loop of failed starts instead of the honest
    // non-zero exit, the service manager never sees the exit code and stderr
    // grows without bound (td-086, the loop mechanics confirmed empirically
    // on FPC 3.2.2). The cleanup is best-effort for the same reason: a lost
    // cleanup exception is cheaper than the loop, the destructor drains
    // whatever this pass could not. The re-raise still reports the original
    // cause - the runtime prints it to stderr (the journal under systemd)
    try
      Log(etInfo, '[Daemon] starting the long polling receiver');
      StartReceiver;
      FReceiverStarted:=True;
    except
      ExitCode:=1;
      Terminate;
      try
        StopReceiver;
      except
        // deliberately empty - the cleanup exception must not cancel the
        // exit fixed by the two lines above (see the comment before the try)
      end;
      raise;
    end;
  end;
  try
    try
      // The main loop only waits - polling runs in the receiver thread. It
      // must NOT call CheckSynchronize: with SynchronizeEvents=False nothing
      // is ever queued on the synchronize side, that is the whole point of the
      // daemon path. FReceiver is never Nil here (a failed Start re-raises
      // above, before the loop; the Nil term is defensive only): a stop signal
      // that arrived before the start makes the loop exit at once, the finally
      // below then drains the suspended never-started thread
      while (not gStop) and (FReceiver<>Nil) and (not FReceiver.Finished) do
        Sleep(MainLoopIdleMs);
      ReceiverDied:=(not gStop) and (FReceiver<>Nil) and FReceiver.Finished;
      // Logged BEFORE StopReceiver: the join below frees the receiver and with
      // it the moved logger - nothing may log through FLogger after it
      if ReceiverDied then
        Log(etError, '[Daemon] receiver stopped on its own, exiting for the service manager to restart');
    except
      // The third door (td-092): the only realistic exception of the body is
      // the Log(etError) write above failing (the logger medium is gone - a
      // full disk, a vanished file). Unguarded, it escapes DoRun with
      // FTerminated=False: Run makes a second pass, the guarded start
      // re-enters, meets FReceiver=Nil (the drain below of the first pass has
      // already freed the receiver) and the AV replaces the root cause in the
      // journal - the exit code stays 1 and no loop is possible (the start
      // door terminates that second pass), but the diagnosis is lost. Same
      // load-bearing order as both other doors: the exit is fixed FIRST, the
      // re-raise only reports the original cause through ShowException (the
      // journal under systemd)
      ExitCode:=1;
      Terminate;
      raise;
    end;
  finally
    // The drain is a first Start attempt of its own here: with the stop
    // signal already set the guarded start above is skipped, the loop exits
    // at once and StopReceiver starts the suspended never-started receiver
    // - a persistent start failure raises in the finally exactly like it
    // does in the failed-start handler above. Unguarded, the exception
    // would escape DoRun skipping ExitCode and Terminate (the lines after
    // this block included): FTerminated stays False, Run calls DoRun again
    // and every pass repeats the raising drain - the same infinite loop of
    // failed starts td-086 closed for the except door, still open in this
    // second one. Same best-effort shape, same load-bearing order: the exit
    // is fixed FIRST, the re-raise only reports the cause through
    // ShowException (the journal under systemd), the destructor drains
    // whatever this pass could not. If the guarded body itself raised, the
    // re-raise replaces that exception with the drain failure - the honest
    // cause: the exit code is the drain's either way
    try
      StopReceiver;
    except
      ExitCode:=1;
      Terminate;
      raise;
    end;
  end;
  // A clean SIGTERM stop exits 0: systemd (Restart=on-failure) and launchd
  // (KeepAlive/SuccessfulExit=false) keep a clean exit stopped. A receiver
  // that died on its own (a configuration error the thread could not retry,
  // see TLongPollingThread.Execute) exits 1, so the service manager restarts
  // the daemon - the reconnect policy of this example lives in the unit
  // files, not in the process (their start rate limit stops a crash loop)
  if ReceiverDied then
    ExitCode:=1;
  Terminate;
end;

constructor TDaemonApplication.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  // Created before everything that logs and released after the receiver
  // stops (see Destroy): every log write passes through this section
  FLogCS:=TCriticalSection.Create;
  // Fail fast with the library's configuration-error class, BEFORE any file
  // is touched: a misconfigured start must not even create the log file. An
  // empty token would otherwise surface only as a polling failure after the
  // start. The runtime prints the exception to stderr - under systemd it
  // lands in the journal, under launchd in the StandardErrorPath file
  if Conf.MaxToken=EmptyStr then
    raise EMaxConfig.Create('Token is not configured: put the bot token into the [Max] section of '
      +ChangeFileExt(ParamStr(0), '.ini'));
  FLoggerOwned:=True;
  FLogger:=TEventLog.Create(nil);
  FLogger.LogType:=ltFile;
  // A daemon restart must not wipe the log of the previous run
  FLogger.AppendContent:=True;
  FLogger.Identification:='max-daemon';
  // Empty [Daemon] LogFile: the FCL activation would resolve the default to
  // a binary-named .log in the system temp directory, not next to the binary
  // like the ini file (verified via lsof on FPC 3.2.2; under systemd
  // PrivateTmp it lands in the service's namespaced /tmp - td-085). Instead
  // of leaving that resolution to the activation, this unit computes the
  // default itself, so the path is checked BEFORE the logger opens it
  // (td-090): an unchecked activation would follow a symlink planted at the
  // default path into a file a local attacker controls. Set [Daemon] LogFile
  // explicitly for a stable, rotatable location.
  if Conf.LogFile<>EmptyStr then
    FLogger.FileName:=Conf.LogFile
  else
  begin
    {$IFDEF UNIX}
    FLogger.FileName:=DefaultTempLogPath;
    VerifyDefaultTempLog(FLogger.FileName);
    {$ENDIF}
  end;
  FLogger.Active:=True;
  // Created suspended; every setting below must be in place before Start -
  // the receiver reads them per poll/per event. Nothing between the Create
  // and the end of the constructor can raise (plain field assignments only);
  // should a future raising line appear, the destructor is the guard: its
  // StopReceiver drains a never-started suspended thread (Terminate-then-
  // Start, Execute exits at once) instead of deadlocking in a bare Free
  FReceiver:=CreateReceiver;
  // Ownership of the logger moves to the thread here (the Logger setter
  // frees the previously set one): the thread frees it in its destructor
  FReceiver.Logger:=FLogger;
  FLoggerOwned:=False;
  // Deterministic Terminate + WaitFor + Free on stop: with the default
  // FreeOnTerminate=True a WaitFor from the main thread would be
  // use-after-free
  FReceiver.FreeOnTerminate:=False;
  // THE daemon switch (td-024): False delivers the receive events right in
  // the receiver thread. A headless process has no synchronize pump -
  // nothing calls CheckSynchronize - so the default True would deliver the
  // first event into a queue nobody drains: the updates would never surface.
  // Must be set BEFORE Start: the gate reads it per event, so changing it
  // while the thread runs mixes delivery threads
  FReceiver.SynchronizeEvents:=False;
  FReceiver.OnReceiveUpdate:=@HandleUpdate;
  // The thread creates its own TMaxBot; the configuration goes through it.
  // An empty EndPoint keeps the default API endpoint (the same semantics
  // as examples/LongPolling)
  FReceiver.Bot.Token:=Conf.MaxToken;
  FReceiver.Bot.APIEndPoint:=Conf.MaxEndPoint;
  // LogDebug stays off by default: the debug log contains message texts
  // and chat ids. Enable it explicitly when troubleshooting.
end;

destructor TDaemonApplication.Destroy;
begin
  // Normal path: DoRun has already stopped and freed the receiver (and with
  // it the moved logger), FReceiver is Nil and StopReceiver exits at once.
  // Constructor failure paths: the same drain also covers a suspended,
  // never-started thread, which would deadlock a bare Free. FLoggerOwned
  // covers the paths where the logger ownership transfer never happened
  StopReceiver;
  if FLoggerOwned then
    FLogger.Free;
  FLogCS.Free;
  inherited Destroy;
end;

end.
