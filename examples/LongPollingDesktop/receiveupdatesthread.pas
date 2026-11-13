unit ReceiveUpdatesThread;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, maxtypes, maxsendertypes, eventlog
  ;

type

  TOnAppendMessage = procedure (const aMessage: String) of object;

  { TReceiverThread }

  TReceiverThread=class(TThread)
  private
    FBot: TMaxSender;
    FLogger: TEventLog;
    FCurrentMessage: TMaxMessageObj;
    FOnAppendMessage: TOnAppendMessage;
    FLPTimeout: Integer;
    procedure BotReceiveMessage({%H-}ASender: TObject; AMessage: TMaxMessageObj);
    procedure BotStartCommandHandler({%H-}ASender: TObject; const {%H-}ACommand: String;
      {%H-}AMessage: TMaxMessageObj);
    procedure BotLogMessage({%H-}ASender: TObject; EventType: TEventType; const Msg: String);
    procedure SendMsgToMainThread;
  public
    constructor Create(const AToken: String);
    destructor Destroy; override;
    procedure Execute; override;
    property Bot: TMaxSender read FBot write FBot;
    property OnAppendMessage: TOnAppendMessage read FOnAppendMessage write FOnAppendMessage;
  end;

implementation

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

{ TReceiverThread }

procedure TReceiverThread.BotReceiveMessage(ASender: TObject; AMessage: TMaxMessageObj);
begin
  { You must synchronize (or make other thread-safe manipulations) due
      BotReceiveMessage is called from ReceiverThread) }
  FCurrentMessage:=AMessage;
  Synchronize(@SendMsgToMainThread);
end;

procedure TReceiverThread.BotStartCommandHandler(ASender: TObject; const ACommand: String;
  AMessage: TMaxMessageObj);
begin
  FBot.Reply('Hi! This is HelloWorld bot (Long Polling) developed in Lazarus');
end;

procedure TReceiverThread.BotLogMessage(ASender: TObject; EventType: TEventType;
  const Msg: String);
begin
  case EventType of
    etError: FLogger.Error(Msg);
    etDebug: FLogger.Debug(Msg);
  else
    FLogger.Info(Msg);
  end;
end;

procedure TReceiverThread.SendMsgToMainThread;
begin
  if Assigned(FOnAppendMessage) then
    FOnAppendMessage(FCurrentMessage.AsString);
end;

constructor TReceiverThread.Create(const AToken: String);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FBot:=TMaxSender.Create(AToken);
  FBot.APIEndPoint:=MaxAPI_URL;   // no need
  FLogger:=TEventLog.Create(nil);
  FLogger.LogType:=ltFile;
  // FBot.LogDebug stays off by default: the debug log contains message
  // texts and chat ids. Enable it explicitly when troubleshooting.
  FBot.OnLogMessage:=@BotLogMessage;
  FBot.CommandHandlers['/start']:=@BotStartCommandHandler;
  FBot.OnReceiveMessage:=@BotReceiveMessage;
  FLPTimeout:=1; // LongPolling timeout
end;

destructor TReceiverThread.Destroy;
begin
  FLogger.Free;
  FreeAndNil(FBot);
  inherited Destroy;
end;

procedure TReceiverThread.Execute;
var
  Failures: Integer;
  J, K: Integer;
begin
  // Terminate is checked between polls. The worst-case stop latency is one
  // in-flight request, hard-bounded by the broker HTTP timeout (the
  // TMaxSender.Timeout property, 30 s by default: the GetUpdates window only
  // widens it, never shortens); the common case is a single polling window
  // (FLPTimeout plus the 3-second transport margin). On top of that, at
  // most one retry pause can still play out after Terminate (Sleep is not
  // interrupted): up to the 30 s backoff cap
  Failures:=0;
  while not Terminated do
  try
    // A failed request (a bad token, an HTTP error) is not an exception any
    // more: pause so the loop does not hammer the API and the log
    if FBot.getUpdatesEx(0, FLPTimeout) then
      Failures:=0
    else
      if not Terminated then
      begin
        // one line per transition into the failure state, not one per retry
        if Failures=0 then
          FLogger.Error('[LongPolling] entering failure state: '
            +FBot.LastErrorCode+' '+FBot.LastErrorMsg);
        // transport and 429 back off, the rest keeps the historical 1 s;
        // only these two increment the ladder - permanent errors keep the
        // historical 1 s pause so a single transient failure later does not
        // inherit a 30 s sleep from a long permanent-error streak
        if (FBot.LastErrorCode='transport')
          or (FBot.LastErrorCode='too.many.requests') then
        begin
          // interruptible slice: FormDestroy/Stop must not wait out the
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
      FLogger.Error('[LongPolling] configuration error, receiver stopped: '+E.Message);
      Terminate;
    end;
    // Since td-030 a transport failure no longer raises out of getUpdates:
    // it returns False (see above). This branch is a safety net for a socket
    // error escaping from somewhere else: one line per occurrence, no dedup,
    // the pause aligned with the False path (the historical 100 ms retry
    // gave a throttling server no time to recover)
    on E: ESocketError do
    begin
      FLogger.Error('[LongPolling] unexpected socket error: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs);
    end;
    // Any other exception must not kill the loop silently: log it and retry
    on E: Exception do
    begin
      FLogger.Error('[LongPolling] getUpdates failed: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs);
    end;
  end;
end;

end.
