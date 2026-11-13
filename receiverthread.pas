unit receiverthread;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, maxtypes, maxsendertypes, eventlog, maxbot
  ;

type

  TLongPollingThread = class;

  { TThreadedBot }

  TThreadedBot=class(TMaxBot)
  private
    FThread: TLongPollingThread;
    FCurrentCallback: TMaxCallbackObj;
    FCurrentEditedMessage: TMaxMessageObj;
    FCurrentUpdate: TMaxUpdateObj;
    procedure SynDoReceiveMessage;
    procedure SynDoReceiveCallback;
    procedure SynDoReceiveUpdate;
    procedure SynDoReceiveEditedMessage;
  public
    procedure DoReceiveMessage(AMessage: TMaxMessageObj); override;
    procedure DoReceiveCallback(ACallback: TMaxCallbackObj); override;
    procedure DoReceiveUpdate(AnUpdate: TMaxUpdateObj); override;
  end;

  { TLongPollingThread }

  TLongPollingThread=class(TThread)
  private
    FLogger: TEventLog;
    FBot: TThreadedBot;
    FOnReceiveCallack: TCallbackEvent;
    FOnReceiveEditedMessage: TMessageEvent;
    FOnReceiveMessageUpdate: TMessageEvent;
    FOnReceiveUpdate: TOnUpdateEvent;
    FLPTimeout: Integer;
    FSynchronizeEvents: Boolean;
    FDelivering: Integer;
    function GetDelivering: Boolean;
    function GetLogger: TEventLog;
    procedure SetLogger(AValue: TEventLog);
    procedure BotLogMessage({%H-}ASender: TObject; EventType: TEventType; const Msg: String);
  protected
    { Delivers a receive or disconnect event: with SynchronizeEvents=False
      right here, in the receiver thread - the only way a host without a
      synchronize pump gets it at all }
    procedure DeliverEvent(AMethod: TThreadMethod);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
    { Assigning transfers ownership: the previously set logger is freed,
      the assigned one is owned by the thread and freed in Destroy }
    property Logger: TEventLog read GetLogger write SetLogger;
    property Bot: TThreadedBot read FBot;
    { True while a receive or disconnect event handler is being delivered }
    property Delivering: Boolean read GetDelivering;
    property LongpollingTimeout: Integer read FLPTimeout write FLPTimeout;
    { The delivery contract of the receive and disconnect events. True
      (default): through TThread.Synchronize - the host must pump the
      synchronize queue (a GUI event loop does, or an explicit
      CheckSynchronize call in a main-thread loop).
      False: the handlers execute in this receiver thread and must be
      thread-safe and GUI-free. The handlers must not touch the component
      that owns the thread either: its fields (StartText, HelpText,
      ReplyMarkups, Token, the lazily created SenderBot) belong to the main
      thread - for sending, create an own TMaxSender in the handler.
      Either mode: the handlers must not call StopReceiver/StartReceiver/
      Destroy of the component - the nested call would deadlock, so an
      EDTMaxBot is raised (and lands in the log) instead. The refusal
      covers StopReceiver/Destroy; StartReceiver is a silent no-op while
      Active. To reconnect after a disconnect, schedule the restart on the
      host's own task queue or a dedicated worker thread. The restart must
      begin with StopReceiver: after a disconnect the component's
      Active stays True, so a lone StartReceiver (or Active:=True)
      is a silent no-op - retry
      StopReceiver from the host thread until it returns without an
      exception, then StartReceiver. Free/Destroy of the component from a
      handler is refused the same way, but the instance is left
      under-destroyed (a leak): destroy it from the host thread only.
      Set before Start: the gate reads it per event, so changing it while the
      thread runs mixes delivery threads between events }
    property SynchronizeEvents: Boolean read FSynchronizeEvents write FSynchronizeEvents default True;
    property OnReceiveCallack: TCallbackEvent read FOnReceiveCallack write FOnReceiveCallack;
    property OnReceiveMessageUpdate: TMessageEvent read FOnReceiveMessageUpdate write FOnReceiveMessageUpdate;
    property OnReceiveUpdate: TOnUpdateEvent read FOnReceiveUpdate write FOnReceiveUpdate;
    property OnReceiveEditedMessage: TMessageEvent read FOnReceiveEditedMessage write FOnReceiveEditedMessage;
  end;

implementation

uses
  ssockets
  ;

const
  // td-013 receiver retry policy (examples/LongPolling is the reference):
  // transport failures and HTTP 429 back off exponentially, every other
  // error keeps the historical one-second pause
  BackoffBaseMs = 1000;
  BackoffMaxMs = 30000;

// ladder: 1, 2, 4, 8, 16 s, then the 30 s cap (1000 shl 5 = 32000 is cut
// by the cap); the shift guard keeps shl inside the Integer range
function BackoffMs(AConsecutiveFailures: Integer): Integer;
var
  Shift: Integer;
begin
  Shift:=AConsecutiveFailures;
  if Shift>5 then
    Shift:=5;
  Result:=BackoffBaseMs shl Shift;
  if Result>BackoffMaxMs then
    Result:=BackoffMaxMs;
end;

{ TThreadedBot }

procedure TThreadedBot.SynDoReceiveMessage;
begin
  FThread.FOnReceiveMessageUpdate(Self, CurrentMessage);
end;

procedure TThreadedBot.SynDoReceiveCallback;
begin
  FThread.FOnReceiveCallack(Self, FCurrentCallback)
end;

procedure TThreadedBot.SynDoReceiveUpdate;
begin
  FThread.FOnReceiveUpdate(Self, FCurrentUpdate);
end;

procedure TThreadedBot.SynDoReceiveEditedMessage;
begin
  FThread.FOnReceiveEditedMessage(Self, FCurrentEditedMessage);
end;

procedure TThreadedBot.DoReceiveMessage(AMessage: TMaxMessageObj);
begin
  inherited DoReceiveMessage(AMessage);
  if Assigned(FThread.FOnReceiveMessageUpdate) then
    FThread.DeliverEvent(@SynDoReceiveMessage);
end;

procedure TThreadedBot.DoReceiveCallback(ACallback: TMaxCallbackObj);
begin
  inherited DoReceiveCallback(ACallback);
  if Assigned(FThread.FOnReceiveCallack) then
  begin
    FCurrentCallback:=ACallback;
    FThread.DeliverEvent(@SynDoReceiveCallback);
  end;
end;

procedure TThreadedBot.DoReceiveUpdate(AnUpdate: TMaxUpdateObj);
begin
  inherited DoReceiveUpdate(AnUpdate);
  // This second gate is load-bearing: the Exit of the base DoReceiveUpdate
  // only leaves the base method, so a rejected update (a banned author)
  // returns here - and must not reach FCurrentUpdate and the GUI events
  if not AcceptUpdate(AnUpdate) then
    Exit;
  FCurrentUpdate:=AnUpdate;
  if Assigned(FThread.FOnReceiveEditedMessage) and
    (AnUpdate.UpdateType=utMessageEdited) then
  begin
    FCurrentEditedMessage:=AnUpdate.Message;
    FThread.DeliverEvent(@SynDoReceiveEditedMessage);
  end;
  if Assigned(FThread.FOnReceiveUpdate) then
    FThread.DeliverEvent(@SynDoReceiveUpdate);
end;

{ TLongPollingThread }

function TLongPollingThread.GetDelivering: Boolean;
begin
  Result:=FDelivering>0;
end;

procedure TLongPollingThread.DeliverEvent(AMethod: TThreadMethod);
begin
  // The counter must be released on the exception path too: in the False
  // branch it comes out of the handler, in the True branch TThread.Synchronize
  // re-raises the handler exception here in the receiver thread
  Inc(FDelivering);
  try
    if FSynchronizeEvents then
      Synchronize(AMethod)
    else
      AMethod;
  finally
    Dec(FDelivering);
  end;
end;

procedure TLongPollingThread.SetLogger(AValue: TEventLog);
begin
  if FLogger=AValue then Exit;
  FLogger.Free;
  FLogger:=AValue;
end;

function TLongPollingThread.GetLogger: TEventLog;
begin
  if not Assigned(FLogger) then
  begin
    FLogger:=TEventLog.Create(nil);
    FLogger.Identification:='Receiver thread';
    FLogger.LogType:=ltFile;
    FLogger.AppendContent:=True;
  end;
  Result:=FLogger;
end;

procedure TLongPollingThread.BotLogMessage(ASender: TObject; EventType: TEventType;
  const Msg: String);
begin
  case EventType of
    etError: Logger.Error(Msg);
    etDebug: Logger.Debug(Msg);
  else
    Logger.Info(Msg);
  end;
end;

constructor TLongPollingThread.Create;
begin
  inherited Create(True);
  FreeOnTerminate:=True;
  FBot:=TThreadedBot.Create(EmptyStr);
  FBot.FThread:=self;
  FBot.OnLogMessage:=@BotLogMessage;
  FLPTimeout:=4;
  FSynchronizeEvents:=True;
  //Logger.Info('Log started');
end;

destructor TLongPollingThread.Destroy;
begin
  FreeAndNil(FBot);
  FreeAndNil(FLogger);
  inherited Destroy;
end;

procedure TLongPollingThread.Execute;
var
  Failures: Integer;
  J, K: Integer;
begin
  // Terminate is checked between polls. The worst-case stop latency is one
  // in-flight request, hard-bounded by the broker HTTP timeout (the
  // TMaxSender.Timeout property, 30 s by default: the GetUpdates window only
  // widens it, never shortens); the common case is a single polling window
  // (LongPollingTime plus the 3-second transport margin). On top of that, at
  // most one retry pause can still play out after Terminate: the transport
  // and 429 ladder is interrupted in 100 ms slices (see below), only the
  // plain 1 s pause of the permanent-error and exception paths can play out
  // in full
  Failures:=0;
  while not Terminated do
  try
    // A failed request (a bad token, an HTTP error, and since td-030 also a
    // transport failure - ApiCall folds those into the False contract with
    // LastErrorCode='transport') is not an exception any more: pause so the
    // loop does not hammer the API and the log. This is now THE reconnect
    // pause of a long-polling window that ended in any failure
    if FBot.getUpdatesEx(0, FLPTimeout) then
      Failures:=0
    else
      if not Terminated then
      begin
        // one line per transition into the failure state, not one per retry
        if Failures=0 then
          Logger.Error('[LongPolling] entering failure state: '
            +FBot.LastErrorCode+' '+FBot.LastErrorMsg);
        // transport and 429 back off, the rest keeps the historical 1 s;
        // only these two increment the ladder - permanent errors keep the
        // historical 1 s pause so a single transient failure later does not
        // inherit a 30 s sleep from a long permanent-error streak
        if (FBot.LastErrorCode='transport')
          or (FBot.LastErrorCode='too.many.requests') then
        begin
          // interruptible slice: StopReceiver/Destroy must not wait out the
          // whole backoff rung (a plain Sleep ignores Terminate)
          J:=BackoffMs(Failures);
          while (J>0) and not Terminated do
          begin
            K:=100; if K>J then K:=J;
            Sleep(K); Dec(J, K);
          end;
        end
        else
          Sleep(BackoffBaseMs);
        if not Terminated then
          Inc(Failures);
      end;
  except
    // FIRST in the handler chain: EMaxConfig descends from Exception. A
    // configuration error fails every retry, so stop visibly instead of
    // logging one line a second forever (td-013)
    on E: EMaxConfig do
    begin
      Logger.Error('[LongPolling] configuration error, receiver stopped: '+E.Message);
      Terminate;
    end;
    // Since td-030 a transport failure no longer raises out of getUpdates:
    // it returns False (see above). This branch is a safety net for a socket
    // error escaping from somewhere else: one line per occurrence, no dedup,
    // the pause aligned with the False path
    on E: ESocketError do
    begin
      Logger.Error('[LongPolling] unexpected socket error: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs);
    end;
    // Any other exception must not kill the loop silently: DoTerminate fires
    // OnDisconnectReceiver without a reason, so log the cause here and retry
    on E: Exception do
    begin
      Logger.Error('[LongPolling] getUpdates failed: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs);
    end;
  end;
end;

end.
