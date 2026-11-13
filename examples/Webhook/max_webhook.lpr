program max_webhook;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  // cwstring: without the widechar manager string conversions turn every
  // non-ASCII character into '?', corrupting non-Latin echo texts
  cwstring,
  {$ENDIF}
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  {$IFDEF UNIX}
  baseunix,
  {$ENDIF}
  Classes, SysUtils, CustApp, syncobjs, eventlog,
  maxsendertypes, maxtypes, maxfclhttpclientbroker, configuration,
  maxwebhook
  ;

const
  // Granularity, in milliseconds, of both waits of the stop watcher: the
  // flag poll and the pause between the stop repetitions (the repetitions of
  // an active receiver are paced by the receiver's own AcceptIdleMs, this
  // one only bridges the not-yet-started window, see TStopWatcher.Execute)
  StopPollMs = 100;

var
  // Set by the signal handler, checked by the watcher thread: a signal handler
  // may only raise a flag, any object access or logging from it would be unsafe
  gStop: Boolean = False;

  // Set by the main thread once its Start call has returned (or the start was
  // skipped): the watcher repeats the receiver stop until it sees this flag,
  // see TStopWatcher.Execute
  gServerDown: Boolean = False;

type

  { TStopWatcher }

  TStopWatcher = class(TThread)
  private
    FReceiver: TMaxWebhookReceiver;
  public
    constructor Create(AReceiver: TMaxWebhookReceiver); reintroduce;
    procedure Execute; override;
  end;

  { TWebhookApplication }

  TWebhookApplication = class(TCustomApplication)
  private
    FBot: TMaxSender;
    FLogger: TEventLog;
    FLogCS: TCriticalSection;
    FReceiver: TMaxWebhookReceiver;
    FCS: TCriticalSection;
    FWatcher: TStopWatcher;
    FRegistered: Boolean;
    procedure ProcessUpdate({%H-}ASender: TObject; AUpdate: TMaxUpdateObj);
    procedure RegisterSubscription;
    procedure UnregisterSubscription;
    procedure LibraryLogMessage({%H-}ASender: TObject; EventType: TEventType;
      const Msg: String);
    procedure Log(AEventType: TEventType; const AMsg: String);
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

{$IFDEF UNIX}
procedure StopSignalHandler({%H-}SigNum: LongInt); cdecl;
begin
  gStop:=True;
end;
{$ENDIF}

{ TStopWatcher }

constructor TStopWatcher.Create(AReceiver: TMaxWebhookReceiver);
begin
  FReceiver:=AReceiver;
  inherited Create(False);
end;

procedure TStopWatcher.Execute;
begin
  // WHY the shutdown lives in a side thread: Start runs the accept loop on
  // the CALLER thread and returns only when the receiver is stopped, so the
  // main thread cannot watch the stop flag itself
  while not gStop do
    Sleep(StopPollMs);
  // WHY the loop, not a single Stop: a signal landing between the main
  // thread's gStop check and the receiver raising its accepting flag inside
  // Start would lose a single stop call - Stop is a no-op while the receiver
  // does not report Active yet, and the start would then block in the accept
  // loop forever with nobody stopping it (ssockets: StartAccepting sets the
  // flag, StopAccepting only clears it - the later start wins). Once the
  // receiver is Active, its own Stop does the repetition internally (it
  // repeats the stop until the server reports inactive), so the loop below
  // only bridges the not-yet-started window and ends when the main thread
  // confirms that its Start has returned (or the start was skipped). On a
  // stopped receiver Stop is a no-op, so repetition is harmless
  while not gServerDown do
  begin
    FReceiver.Stop;
    Sleep(StopPollMs);
  end;
end;

{ TWebhookApplication }

procedure TWebhookApplication.LibraryLogMessage(ASender: TObject;
  EventType: TEventType; const Msg: String);
begin
  // One handler for both library callbacks: TMaxSender.OnLogMessage and
  // TMaxWebhookReceiver.OnLog share the TLogMessageEvent signature. The
  // receiver fires it from request threads, from the accept thread and from
  // the thread calling Start (the canonical context list is the OnLog
  // property comment in maxwebhook) - every context is covered by the locked
  // Log below, and none of them frees or restarts the receiver, which is
  // what the OnLog contract prohibits
  Log(EventType, Msg);
end;

procedure TWebhookApplication.Log(AEventType: TEventType; const AMsg: String);
begin
  // TEventLog has no internal locking (FCL 3.2.2) and request threads log
  // concurrently with the main thread, so every write goes through one
  // section. Deliberately not FCS: this fires from ApiCall while the caller
  // already holds FCS for SendMessage, and TCriticalSection reentrancy is not
  // guaranteed outside Windows
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

procedure TWebhookApplication.ProcessUpdate(ASender: TObject;
  AUpdate: TMaxUpdateObj);
var
  AChatId: Int64;
  AText: String;
begin
  // The receiver owns the update and frees it as soon as this handler
  // returns: chat id and text are copied out by value below, nothing here
  // frees the object or keeps a reference into it (the ownership contract of
  // OnUpdate)
  Log(etInfo, 'Webhook update: '+AUpdate.UpdateTypeStr);
  if AUpdate.UpdateType<>utMessageCreated then
    Exit;
  AChatId:=AUpdate.Message.ChatId;
  AText:=AUpdate.Message.Body.Text;
  // A message without text (photo, sticker, file) has nothing to echo: the
  // send would drop the empty 'text' field, the API would answer with an
  // error and every media update would log an echo failure (mirror of the
  // empty-text guard in the LongPolling echo). Attachments are not echoed by
  // this example at all
  if AText=EmptyStr then
    Exit;
  // Echo the incoming text back to the same chat. One TMaxSender serves all
  // request threads: SendMessage calls must not interleave. Enter/Leave
  // strictly in a try..finally pair: the receiver swallows handler exceptions
  // and answers 200 - without finally a raised exception would leave the
  // section locked forever and every next request would hang on Enter.
  // Conscious tradeoff: the synchronous send holds the section, so a slow
  // API reply stalls all webhook processing; a production host would use a
  // queue with a worker and send timeouts instead
  FCS.Enter;
  try
    if not FBot.SendMessage(AChatId, AText) then
      Log(etError, Format('[Webhook] echo to chat %d failed: %s %s',
        [AChatId, FBot.LastErrorCode, FBot.LastErrorMsg]));
  finally
    FCS.Leave;
  end;
  WriteLn('Echo to chat ', AChatId, ' sent: ', AText);
end;

procedure TWebhookApplication.RegisterSubscription;
begin
  if Conf.WebhookURL=EmptyStr then
    Exit;
  try
    // A failed registration must not prevent the server from starting: only
    // while the URL subscription is absent the platform keeps delivering
    // updates to long polling instead. The secret travels with the
    // subscription: the platform echoes it in the X-Max-Bot-Api-Secret header
    // of every delivery, which is what the receiver's secret check compares
    // against Conf.WebhookSecret
    if FBot.SetWebhook(Conf.WebhookURL, Conf.WebhookSecret) then
      FRegistered:=True
    else
      Log(etError, '[Webhook] SetWebhook failed: '+FBot.LastErrorCode+' '+FBot.LastErrorMsg);
  except
    on E: Exception do
      Log(etError, '[Webhook] SetWebhook failed: ['+E.ClassName+'] '+E.Message);
  end;
end;

procedure TWebhookApplication.UnregisterSubscription;
begin
  // Only delete what this run actually registered
  if not FRegistered then
    Exit;
  FRegistered:=False;
  try
    // The receiver no longer accepts connections, but in-flight request
    // threads still run SendMessage under FCS, and ApiCall mutates the shared
    // TMaxSender fields (error code/message, response) with no internal
    // locking: the delete must take the same section
    FCS.Enter;
    try
      if not FBot.DeleteWebhook(Conf.WebhookURL) then
        Log(etError, '[Webhook] DeleteWebhook failed: '+FBot.LastErrorCode+' '+FBot.LastErrorMsg);
    finally
      FCS.Leave;
    end;
  except
    on E: Exception do
      Log(etError, '[Webhook] DeleteWebhook failed: ['+E.ClassName+'] '+E.Message);
  end;
end;

procedure TWebhookApplication.DoRun;
begin
  {$IFDEF UNIX}
  // Signals are the stop switch: the handler only raises the flag, the
  // shutdown runs in the watcher thread
  fpSignal(SIGINT, @StopSignalHandler);
  fpSignal(SIGTERM, @StopSignalHandler);
  {$ENDIF}
  RegisterSubscription;
  // Nil from the start: the finally block below is the sole owner of the
  // watcher, and Create itself (thread/memory) can fail - the object must be
  // inside the try it is released in
  FWatcher:=Nil;
  try
    FWatcher:=TStopWatcher.Create(FReceiver);
    // Blocks in the accept loop until the watcher stops the receiver (see
    // TStopWatcher.Execute). A signal that already arrived during the
    // registration network call must not start the server: the watcher would
    // stop an inactive receiver (a no-op) and exit, and this thread would
    // then block in the accept loop forever with the stop flag set and
    // nobody reading it. A broken configuration stops the host visibly
    // through the library contract of Start (EMaxConfig: no PEM pair, a
    // mistyped CertFile/KeyFile path, a failed bind with the port in the
    // message) - there is no example-side configuration check to duplicate
    if not gStop then
      FReceiver.Start;
  finally
    gStop:=True;
    // Before the WaitFor: the accept loop is over here (Start returned, or
    // the start was skipped), so the watcher's stop repetitions may end;
    // waiting first would deadlock the skipped-start case, where nobody but
    // this thread can confirm the receiver is down
    gServerDown:=True;
    if FWatcher<>Nil then
    begin
      FWatcher.WaitFor;
      FWatcher.Free;
    end;
    // The watcher's Stop has returned, so the receiver is down: in-flight
    // request threads finish on their own and are reaped by the receiver
    // destructor, which runs before the bot it serves is freed. The delete
    // below runs on the same thread that called Start - the thread the unit
    // contract names as the receiver's last user before it is freed
    UnregisterSubscription;
  end;
  Terminate;
end;

constructor TWebhookApplication.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  // Created before everything that logs and freed after the logger stops
  // being used (see Destroy): every log write passes through this section
  FLogCS:=TCriticalSection.Create;
  FLogger:=TEventLog.Create(nil);
  FLogger.LogType:=ltFile;
  FLogger.Active:=True;
  FBot:=TMaxSender.Create(Conf.MaxToken);
  with FBot do
  begin
    // Off unless the ini asks for it: with LogDebug the library writes the
    // full JSON of every update (message texts, chat ids - personal data)
    // into the log file
    LogDebug:=Conf.WebhookDebug;
    OnLogMessage:=@LibraryLogMessage;
    APIEndPoint:=Conf.MaxEndPoint;
  end;
  FCS:=TCriticalSection.Create;
  // Everything the hand-rolled server of this example used to do itself -
  // the secret check with the 403 form, the oversize/depth gates, the
  // always-200 delivery policy, the TLS handler with the PEM pair and
  // stTLSv1_2, the per-connection IO deadline - is the delivery contract of
  // TMaxWebhookReceiver now: the example is a client of the unit and only
  // wires the configuration and the events. Defaults the ini does not touch:
  // UseSSL=True (public HTTPS), MaxBodySize=DefaultMaxBodySize (1 MB), the
  // 15 s connection IO deadline. The server key must be RSA (certbot:
  // --key-type rsa) - the FPC 3.2.2 openssl unit loads no ECDSA keys
  FReceiver:=TMaxWebhookReceiver.Create;
  FReceiver.Port:=Conf.WebhookPort;
  FReceiver.CertFile:=Conf.WebhookCertFile;
  FReceiver.KeyFile:=Conf.WebhookKeyFile;
  FReceiver.Secret:=Conf.WebhookSecret;
  FReceiver.OnUpdate:=@ProcessUpdate;
  FReceiver.OnLog:=@LibraryLogMessage;
end;

destructor TWebhookApplication.Destroy;
begin
  // The receiver is stopped in DoRun and the watcher is joined there, before
  // this destructor frees the objects its request threads use (Stop - join -
  // Free is the shutdown shape of the unit contract)
  FReceiver.Free;
  FBot.Free;
  FCS.Free;
  FLogger.Free;
  FLogCS.Free;
  inherited Destroy;
end;

var
  Application: TWebhookApplication;
begin
  Application:=TWebhookApplication.Create(nil);
  Application.Title:='Test Max Webhook App';
  Application.Run;
  Application.Free;
end.
