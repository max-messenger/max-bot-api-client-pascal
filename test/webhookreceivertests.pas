unit webhookreceivertests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, eventlog, syncobjs, sockets, ssockets, fpcunit,
  testregistry, maxtypes, maxsendertypes, maxbasehttpclient, sslbase,
  sslsockets, opensslsockets, openssl, maxwebhook, testhttpharness;

type

  { TTestWebhookReceiver }

  { Offline end-to-end tests of TMaxWebhookReceiver: every test drives a real
  receiver bound to 127.0.0.1 (loopback HTTP(S), no bot API network) through
  the registered HTTP client and pins the delivery contract - the 200-on-
  everything answer with the single 403 secret exception, the log levels and
  the ownership of the delivered update }
  TTestWebhookReceiver=class(TTestCase)
  private
    FReceiver: TMaxWebhookReceiver;
    FPort: Word;
    FStartThread: TLoopbackRunner;
    { A wedged stop is final: the runner went to FreeOnTerminate and the
      receiver must never be freed under its live accept thread (td-104) }
    FWedged: Boolean;
    FCaptureCS: TCriticalSection;
    FLogs: TStringList;
    FUpdates: Integer;
    FUpdateType: TMaxUpdateType;
    FChatId: Int64;
    FText: String;
    procedure HandleUpdate({%H-}ASender: TObject; AnUpdate: TMaxUpdateObj);
    procedure HandleLog({%H-}ASender: TObject; EventType: TEventType;
      const Msg: String);
    function HasLog(AEventType: TEventType; const APart: String): Boolean;
    function HasLogWithRawControl(AEventType: TEventType;
      const APart: String): Boolean;
    function CaptureDump: String;
    function HasLine(const APrefix, ALine, APart: String): Boolean;
    function AnswerBody(const AResp: String): String;
    { The blocking start the harness runner serves on its own thread: the
      accept loop of the receiver lives there until Stop }
    procedure RunReceiver;
    procedure WireReceiver(AReceiver: TMaxWebhookReceiver);
    procedure UseReceiver(AReceiver: TMaxWebhookReceiver);
    procedure SetUpTLS;
    procedure StartReceiver;
    procedure StopReceiver;
    procedure SendTruncatedTLSRequest;
    function PostBody(const ABody: String; const ASecret: String;
      out ACode: Integer): String;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DeliversUpdateAndAnswers200;
    procedure SecretMismatchIsRejectedWith403;
    procedure SecretMatchDelivers;
    procedure OversizeBodyIgnored;
    procedure NonJSONBodyAnswers200;
    procedure ParseErrorLogEscapesControlBytes;
    procedure ConnectionLogWarningEscapesControlBytes;
    procedure NonObjectJSONAnswers200;
    procedure DeepBodyIgnored;
    procedure EmptyBodyAnswers200;
    procedure BindConflictRaisesWithPort;
    procedure TLSDeliversUpdate;
    procedure TLSTruncatedRequestHitsDeadline;
  end;

implementation

const
  // The same inline literal TTestWebhookScan.UpdateBodyIsAccepted pins for
  // the depth scanner; repeated here on purpose - no shared fixture-literal
  // unit (the shared loopback harness lives in testhttpharness)
  TestUpdateBody = '{"update_type":"message_created","message":'+
    '{"recipient":{"chat_id":123},"body":{"text":"ping"}}}';

  // The shortened per-connection IO deadline of the TLS deadline contract
  // test: comfortably above the loopback TLS handshake and the truncated
  // send (tens of ms), far below the 15 s production default the test must
  // not eat (td-082). The client timeout of the truncated leg stays above
  // it on purpose - the SERVER deadline must be the first to fire
  TestDeadlineMs = 700;

type
  { Test receiver with the per-connection IO deadline shortened through the
    protected ConnectionIOTimeoutMs property (td-082): the deadline contract
    test must not eat the 15 s production default }
  TShortDeadlineReceiver=class(TMaxWebhookReceiver)
  public
    constructor Create(ADeadlineMs: Integer);
  end;

  { Test receiver exposing the protected HandleServerLog adapter (the td-101
    seam): the pin drives the TMaxHTTPServer.OnConnectionLog path - the call
    site of the setsockopt degradation warning - without standing up a live
    server; the sanitization contract itself stays in the receiver's Log }
  TLogExposeReceiver=class(TMaxWebhookReceiver)
  public
    procedure HandleServerLog({%H-}ASender: TObject; AEventType: TEventType;
      const AMsg: String);
  end;

// The single source of the level prefixes: HandleLog writes them and HasLog
// reads them back - a divergent copy would silently blind the assertions
function LogPrefix(AEventType: TEventType): String;
begin
  case AEventType of
    etDebug: Result:='debug: ';
    etWarning: Result:='warning: ';
    etError: Result:='error: ';
  else
    Result:='info: ';
  end;
end;

// One captured line shaped for a failure report: every byte below 0x20 is
// shown in the same \xNN form the td-083 pin asserts on, so a raw byte that
// survived into the log is visible in the dump without forging line breaks
// inside the failure report itself. A cold-path copy and not a call into the
// sanitizer: SanitizeLogText is implementation-private in maxwebhook, and
// this is report shaping beside the guard, not the guard under test
function DumpVisible(const ALine: String): String;
var
  I: Integer;
begin
  Result:=EmptyStr;
  for I:=1 to Length(ALine) do
    if Ord(ALine[I])>=32 then
      Result:=Result+ALine[I]
    else
      Result:=Result+'\x'+IntToHex(Ord(ALine[I]), 2);
end;

{ TShortDeadlineReceiver }

{ A receiver shaped the way a host customizes the per-connection IO
  deadline: the protected ConnectionIOTimeoutMs property is reachable from a
  subclass constructor, so the deadline contract test runs the production
  path with a short value instead of eating the 15 s default (td-082) }
constructor TShortDeadlineReceiver.Create(ADeadlineMs: Integer);
begin
  inherited Create;
  ConnectionIOTimeoutMs:=ADeadlineMs;
end;

{ TLogExposeReceiver }

{ A pure visibility lift, not a re-implementation: the same-name declaration
  only shadows the static protected method of the base, the body rides the
  inherited one }
procedure TLogExposeReceiver.HandleServerLog(ASender: TObject;
  AEventType: TEventType; const AMsg: String);
begin
  inherited HandleServerLog(ASender, AEventType, AMsg);
end;

{ TTestWebhookReceiver }

function TTestWebhookReceiver.HasLine(const APrefix, ALine,
  APart: String): Boolean;
begin
  // The level prefix and the searched fragment are checked separately: the
  // messages carry their own [Webhook] tag between the two
  Result:=(Copy(ALine, 1, Length(APrefix))=APrefix) and (Pos(APart, ALine)>0);
end;

function TTestWebhookReceiver.AnswerBody(const AResp: String): String;
begin
  // fpweb's TResponse keeps Content in a TStrings, so the sent body always
  // carries one trailing line ending (the Content-Length counts it - the
  // live example ships the same byte). Strip exactly that line ending for
  // the assertions
  Result:=AResp;
  if Copy(Result, Length(Result), 1)=#10 then
    Delete(Result, Length(Result), 1);
  if Copy(Result, Length(Result), 1)=#13 then
    Delete(Result, Length(Result), 1);
end;

procedure TTestWebhookReceiver.SetUp;
begin
  FCaptureCS:=TCriticalSection.Create;
  FLogs:=TStringList.Create;
  FUpdates:=0;
  FWedged:=False;
  FPort:=PickFreePort;
  // OpenSSL warm-up BEFORE any test starts its server. WHY: the first SSL
  // touch of a TLS test happens on TWO threads at once (the receiver's
  // connection thread and the HTTP client of the same test), and the
  // openssl 3.2.2 InitSSLInterface answers a caller that blocked on its
  // init critical section with a stale False even when the concurrent
  // initializer has just succeeded - the spurious EInOutError "Could not
  // initialize OpenSSL library" that kills a TLS test non-deterministically.
  // One sequential call here wins the race for every later thread: the call
  // is idempotent (a no-op once loaded) and its result is deliberately
  // ignored - on a host where OpenSSL does not load, the suite must degrade
  // exactly as before (the plain tests green, the TLS tests red with their
  // own error)
  InitSSLInterface;
  FReceiver:=TMaxWebhookReceiver.Create;
  WireReceiver(FReceiver);
end;

procedure TTestWebhookReceiver.TearDown;
begin
  // Stop is repeated until the server reports inactive and the join is
  // bounded: a wedged shutdown fails the test visibly instead of hanging it
  StopReceiver;
  // td-104: on a wedged stop the accept thread may still sit inside Start
  // (FReceiver) and a connection thread inside the capture handlers
  // (FCaptureCS/FLogs), so a free under them is the use-after-free this
  // record pins - the fixture leaks them deliberately, and StopReceiver has
  // already reported the wedged stop loudly
  if not FWedged then
  begin
    FreeAndNil(FReceiver);
    FreeAndNil(FCaptureCS);
    FreeAndNil(FLogs);
  end;
  inherited TearDown;
end;

procedure TTestWebhookReceiver.HandleUpdate(ASender: TObject;
  AnUpdate: TMaxUpdateObj);
begin
  // Copy what the assertions need: the receiver owns the object only until
  // this handler returns (the documented contract)
  FCaptureCS.Enter;
  try
    Inc(FUpdates);
    FUpdateType:=AnUpdate.UpdateType;
    FChatId:=AnUpdate.Message.ChatId;
    FText:=AnUpdate.Message.Body.Text;
  finally
    FCaptureCS.Leave;
  end;
end;

procedure TTestWebhookReceiver.HandleLog(ASender: TObject;
  EventType: TEventType; const Msg: String);
begin
  FCaptureCS.Enter;
  try
    FLogs.Add(LogPrefix(EventType)+Msg);
  finally
    FCaptureCS.Leave;
  end;
end;

function TTestWebhookReceiver.HasLog(AEventType: TEventType;
  const APart: String): Boolean;
var
  I: Integer;
begin
  FCaptureCS.Enter;
  try
    Result:=False;
    for I:=0 to FLogs.Count-1 do
      Result:=Result or HasLine(LogPrefix(AEventType), FLogs[I], APart);
  finally
    FCaptureCS.Leave;
  end;
end;

function TTestWebhookReceiver.HasLogWithRawControl(AEventType: TEventType;
  const APart: String): Boolean;
var
  I, J: Integer;
begin
  // The negative half of the td-083 pin: among the lines matching APart a
  // raw control byte must not survive - the log-forging guard turns every
  // byte below 0x20 into the visible \xNN form, so a raw byte in the capture
  // means the line reached OnLog unguarded, forged line break included
  Result:=False;
  FCaptureCS.Enter;
  try
    for I:=0 to FLogs.Count-1 do
      if HasLine(LogPrefix(AEventType), FLogs[I], APart) then
        for J:=1 to Length(FLogs[I]) do
          if Ord(FLogs[I][J])<32 then
            Exit(True);
  finally
    FCaptureCS.Leave;
  end;
end;

function TTestWebhookReceiver.CaptureDump: String;
var
  I: Integer;
begin
  // The failure-path diagnostics of the td-083 pin (td-097): the report of
  // a red content assert must show the lines the parser actually produced,
  // not just name the missing fragment - the positive half rides on the
  // whole body reaching the parser (the transport race), and the capture is
  // the only witness of what arrived instead. Each line lands escaped, so
  // the dump is safe to read whatever the capture holds
  Result:=EmptyStr;
  FCaptureCS.Enter;
  try
    if FLogs.Count>0 then
      Result:=LineEnding;
    for I:=0 to FLogs.Count-1 do
      Result:=Result+'  | '+DumpVisible(FLogs[I])+LineEnding;
  finally
    FCaptureCS.Leave;
  end;
end;

procedure TTestWebhookReceiver.RunReceiver;
begin
  FReceiver.Start;
end;

procedure TTestWebhookReceiver.WireReceiver(AReceiver: TMaxWebhookReceiver);
begin
  // The single copy of the standard wiring every receiver of the suite is
  // served through: the HTTP tests run plain loopback HTTP (no OpenSSL load
  // required on the host, the TLS tests opt back in through SetUpTLS) and
  // both events land in the fixture. A new mandatory callback belongs here,
  // not in a call site - SetUp and UseReceiver share the one wiring
  AReceiver.UseSSL:=False;
  AReceiver.OnUpdate:=@HandleUpdate;
  AReceiver.OnLog:=@HandleLog;
end;

procedure TTestWebhookReceiver.UseReceiver(AReceiver: TMaxWebhookReceiver);
begin
  // SetUp creates the standard receiver; a test that needs a subclass
  // instance (the shortened deadline) swaps it here BEFORE any other
  // configuration, and the standard wiring is re-applied to the replacement
  // through the same WireReceiver SetUp uses
  FreeAndNil(FReceiver);
  FReceiver:=AReceiver;
  WireReceiver(FReceiver);
end;

procedure TTestWebhookReceiver.SetUpTLS;
var
  CertPath: String;
  KeyPath: String;
begin
  // The fixtures are repository files; the runner is launched from the
  // repository root (README.md), so the relative path is the stable form
  CertPath:='test'+DirectorySeparator+'certs'+DirectorySeparator+
    'webhook-test-cert.pem';
  KeyPath:='test'+DirectorySeparator+'certs'+DirectorySeparator+
    'webhook-test-key.pem';
  AssertTrue('the TLS fixtures are missing ('+CertPath+'), run from the repository root',
    FileExists(CertPath) and FileExists(KeyPath));
  FReceiver.UseSSL:=True;
  FReceiver.CertFile:=CertPath;
  FReceiver.KeyFile:=KeyPath;
end;

procedure TTestWebhookReceiver.StartReceiver;
var
  Runner: TLoopbackRunner;
begin
  // The configuration is only read before Start (the documented contract)
  FReceiver.Host:='127.0.0.1';
  FReceiver.Port:=FPort;
  // Start blocks: the accept loop lives on the runner thread
  Runner:=TLoopbackRunner.Create(@RunReceiver);
  try
    // Active turns true as soon as the listening socket object exists -
    // BEFORE the bind - so the readiness signal is a probe connect that
    // succeeds; a start failure (a bind conflict) finishes the runner with
    // Error instead. Both ends are checked: bounded, so a dead listener
    // fails the test instead of hanging it
    WaitForReady(Runner, FPort, HarnessTimeoutMs);
    if Runner.Error<>EmptyStr then
      Fail('the receiver did not start: '+Runner.Error);
    AssertTrue('the receiver does not accept connections', PortAccepting(FPort));
    AssertTrue('the ready receiver does not report active', FReceiver.Active);
  finally
    FStartThread:=Runner;
  end;
end;

procedure TTestWebhookReceiver.StopReceiver;
var
  Runner: TLoopbackRunner;
  Joined: Boolean;
begin
  if FStartThread=Nil then
    Exit;
  FReceiver.Stop;
  Runner:=FStartThread;
  FStartThread:=Nil;
  // Stop returned, so the server is down and the runner is (almost) done;
  // the join stays bounded to fail visibly on a wedged shutdown. td-104:
  // the join rides the finally - on every path the runner is either freed
  // (joined) or handed to its own thread (FreeOnTerminate), never left as a
  // dangling reference; the receiver is freed by TearDown only behind the
  // FWedged mark the wedged path sets
  Joined:=False;
  try
    Joined:=WaitForFinished(Runner, HarnessTimeoutMs);
    if Joined then
    begin
      Runner.WaitFor;
      Runner.Free;
      Runner:=Nil;
    end;
  finally
    if Runner<>Nil then
    begin
      // wedged: the runner object goes with its thread, the receiver stays
      // alive under its accept loop - the deliberate leak instead of the
      // use-after-free (td-104)
      FWedged:=True;
      Runner.FreeOnTerminate:=True;
      Runner:=Nil;
    end;
  end;
  // the loud report comes AFTER the hand-off: a wedged stop must surface as
  // this named failure, not as a random AV from freeing the receiver under
  // its live accept loop
  AssertTrue('the receiver stop is wedged: the accept thread did not join '
    +'within '+IntToStr(HarnessTimeoutMs)+' ms - the receiver is left alive '
    +'(not freed), the runner self-frees', Joined);
end;

function TTestWebhookReceiver.PostBody(const ABody: String;
  const ASecret: String; out ACode: Integer): String;
var
  Client: TBaseHTTPClient;
begin
  // The class factory returns the broker-registered client (the runner
  // links exactly one); SSLVerifyCert:=False covers the TLS test, the
  // self-signed fixture pair would fail verification otherwise
  Client:=TBaseHTTPClient.GetClientClass.Create(nil);
  try
    Client.IOTimeout:=5000;
    Client.SSLVerifyCert:=False;
    if ASecret<>EmptyStr then
      Client.AddHeader('X-Max-Bot-Api-Secret', ASecret);
    // The same body transport ApiCall uses: the stream is exact before the
    // first read (Content-Length) and freed by the caller
    Client.RequestBody:=TMaxStringBodyStream.Create(ABody);
    try
      if FReceiver.UseSSL then
        Result:=Client.Post(Format('https://127.0.0.1:%d/', [FPort]))
      else
        Result:=Client.Post(Format('http://127.0.0.1:%d/', [FPort]));
    finally
      Client.RequestBody.Free;
      Client.RequestBody:=Nil;
    end;
    ACode:=Client.ResponseStatusCode;
  finally
    Client.Free;
  end;
end;

procedure TTestWebhookReceiver.DeliversUpdateAndAnswers200;
var
  Code: Integer;
  Resp: String;
begin
  StartReceiver;
  Resp:=PostBody(TestUpdateBody, EmptyStr, Code);
  AssertEquals('a valid delivery is answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('exactly one OnUpdate shot', 1, FUpdates);
  AssertEquals('the delivered update type',
    Ord(utMessageCreated), Ord(FUpdateType));
  AssertEquals('the delivered chat id', 123, FChatId);
  AssertEquals('the delivered text', 'ping', FText);
  StopReceiver;
end;

procedure TTestWebhookReceiver.SecretMismatchIsRejectedWith403;
var
  Code: Integer;
  Resp: String;
begin
  FReceiver.Secret:='s3cret';
  StartReceiver;
  Resp:=PostBody(TestUpdateBody, 'wrong', Code);
  AssertEquals('a wrong secret is rejected with 403', 403, Code);
  AssertEquals('the 403 answer is empty', EmptyStr, Resp);
  AssertEquals('a rejected request never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the rejection is logged as a warning',
    HasLog(etWarning, 'wrong X-Max-Bot-Api-Secret'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.SecretMatchDelivers;
var
  Code: Integer;
  Resp: String;
begin
  FReceiver.Secret:='s3cret';
  StartReceiver;
  Resp:=PostBody(TestUpdateBody, 's3cret', Code);
  AssertEquals('the matching secret is delivered with 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('exactly one OnUpdate shot', 1, FUpdates);
  StopReceiver;
end;

procedure TTestWebhookReceiver.OversizeBodyIgnored;
var
  Code: Integer;
  Resp: String;
begin
  FReceiver.MaxBodySize:=64;
  StartReceiver;
  // 256 payload bytes against the 64-byte limit set above (a const cannot
  // build this: StringOfChar is no constant expression)
  Resp:=PostBody('{"x":"'+StringOfChar('a', 256)+'"}', EmptyStr, Code);
  AssertEquals('an oversized body is still answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('an oversized body never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the oversize is logged as a warning',
    HasLog(etWarning, 'exceeds the 64 bytes limit'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.NonJSONBodyAnswers200;
var
  Code: Integer;
  Resp: String;
begin
  StartReceiver;
  Resp:=PostBody('this is not json', EmptyStr, Code);
  AssertEquals('a non-JSON body is still answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('a non-JSON body never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the parse failure is logged as an error (the generic except)',
    HasLog(etError, 'request failed'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.ParseErrorLogEscapesControlBytes;
const
  // The td-097 bounded delivery retry: the observed flake was a red positive
  // assert on a raced body delivery (the 'request failed' line arrived, the
  // forged token inside it did not), so the send is re-rolled on its own new
  // connection while the escaped CR/LF form has not shown up. Not a
  // weakening: the asserts below are unchanged and run after the loop - a
  // sanitizer regression misses the escaped form on every attempt and still
  // goes red on the positives, and a raw byte surviving beside the escaped
  // form is caught by the negative assert at the end
  MaxDeliveryAttempts = 3;
var
  Code: Integer;
  Resp: String;
  Attempt: Integer;
begin
  // The td-083 log-forging guard pinned end-to-end through the public
  // receiver path: the body is one JSON string token whose escapes decode
  // to raw control bytes below 0x20 - \n\r\n to CR/LF, the line-forging
  // pair, and the \u001B\u0001 \u-forms to ESC/SOH beside them. The fpjson
  // parser embeds that token decoded in its "got token" error and the
  // generic except logs it - unsanitized the CRLF would forge line breaks
  // in the operator log and break the very capture this test reads. The
  // escape-shaped literals are deliberate: Pascal strings have no
  // backslash escapes, so "\n\r\n\u001B\u0001" below IS the JSON escape
  // text on the wire and "\x0A\x0D\x0A" with "\x1B\x01" ARE the
  // 4-chars-per-byte sanitized forms to match
  StartReceiver;
  for Attempt:=1 to MaxDeliveryAttempts do
  begin
    Resp:=PostBody('{"a" "\n\r\n\u001B\u0001" 1}', EmptyStr, Code);
    if HasLog(etError, '\x0A\x0D\x0A') then
      Break;
  end;
  AssertEquals('a malformed body is still answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('a malformed body never reaches OnUpdate', 0, FUpdates);
  // Every content assert carries the capture dump in its message: it is
  // built on every run and only shown on the failure path, and a red here
  // must show what the parser actually logged - escaped or raw - not just
  // name the fragment that went missing (td-097)
  AssertTrue('the parse failure is logged as an error (the generic except)'+
    CaptureDump, HasLog(etError, 'request failed'));
  AssertTrue('the CR/LF of the forged token reaches the log escaped only'+
    CaptureDump, HasLog(etError, '\x0A\x0D\x0A'));
  AssertTrue('the ESC/SOH of the forged token reach the log escaped only'+
    CaptureDump, HasLog(etError, '\x1B\x01'));
  AssertFalse('no raw control byte survives into the logged line'+CaptureDump,
    HasLogWithRawControl(etError, 'request failed'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.ConnectionLogWarningEscapesControlBytes;
var
  Receiver: TLogExposeReceiver;
begin
  // The td-101 pin of the OnConnectionLog sanitization: the degradation
  // warning is assembled at the call site ('IO deadline not set on a
  // connection: '+E.Message, the failed setsockopt branch of
  // TMaxHTTPServer.CreateConnection), and the E.Message of a socket error is
  // peer-controlled text. The td-083 guard lives in Log, so the same
  // escaped-only contract must hold on this path - driven here through the
  // protected HandleServerLog seam (the test subclass exposes it) with the
  // exact message shape of the call site and the same control bytes the
  // td-083 pin forges. The receiver is only constructed, never started: Log
  // just forwards the sanitized text to the wired OnLog and never touches
  // the server object. The escape-shaped literals keep their td-083
  // meaning - the #10#13#10#27#1 bytes ARE the raw payload, the \xNN
  // strings ARE the sanitized forms to match
  Receiver:=TLogExposeReceiver.Create;
  UseReceiver(Receiver);
  Receiver.HandleServerLog(Nil, etWarning,
    'IO deadline not set on a connection: '#10#13#10#27#1);
  AssertTrue('the degradation warning is logged as a warning'+CaptureDump,
    HasLog(etWarning, 'IO deadline not set on a connection:'));
  AssertTrue('the CR/LF of the socket error reaches the log escaped only'+
    CaptureDump, HasLog(etWarning,
    'IO deadline not set on a connection: \x0A\x0D\x0A'));
  AssertTrue('the ESC/SOH of the socket error reach the log escaped only'+
    CaptureDump, HasLog(etWarning, '\x1B\x01'));
  AssertFalse('no raw control byte survives into the logged line'+CaptureDump,
    HasLogWithRawControl(etWarning, 'IO deadline not set'));
end;

procedure TTestWebhookReceiver.NonObjectJSONAnswers200;
var
  Code: Integer;
  Resp: String;
begin
  StartReceiver;
  Resp:=PostBody('[1,2,3]', EmptyStr, Code);
  AssertEquals('a non-object JSON body is still answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('a non-object body never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the shape fault is logged as a warning',
    HasLog(etWarning, 'not a JSON object'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.DeepBodyIgnored;
var
  Code: Integer;
  DeepBody: String;
  Resp: String;
begin
  // One opener over MaxJSONDepth: the pre-scan must reject it before
  // GetJSON gets a chance to overflow the stack
  DeepBody:=StringOfChar('[', MaxJSONDepth div 2)+
    StringOfChar('{', MaxJSONDepth div 2)+'{';
  StartReceiver;
  Resp:=PostBody(DeepBody, EmptyStr, Code);
  AssertEquals('a too-deep body is still answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('a too-deep body never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the depth fault is logged as a warning',
    HasLog(etWarning, 'nests deeper'));
  StopReceiver;
end;

procedure TTestWebhookReceiver.EmptyBodyAnswers200;
var
  Code: Integer;
  Resp: String;
begin
  StartReceiver;
  Resp:=PostBody(EmptyStr, EmptyStr, Code);
  AssertEquals('an empty body is answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('an empty body fires no events', 0, FUpdates);
  AssertTrue('an empty body logs nothing', FLogs.Count=0);
  StopReceiver;
end;

procedure TTestWebhookReceiver.BindConflictRaisesWithPort;
var
  Occupier: LongInt;
  Addr: TInetSockAddr;
begin
  // Occupy the port with a listening socket. Deliberately no SO_REUSEADDR
  // on it: the server side turns ReuseAddress on, and on darwin two
  // REUSEADDR listeners may coexist - the conflict must come from the
  // occupied side
  Occupier:=fpSocket(AF_INET, SOCK_STREAM, 0);
  AssertTrue('occupier socket creation failed', Occupier>=0);
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family:=AF_INET;
    Addr.sin_port:=htons(FPort);
    Addr.sin_addr.s_addr:=htonl(StrToHostAddr('127.0.0.1').s_addr);
    AssertTrue('occupier bind failed', fpBind(Occupier, @Addr, SizeOf(Addr))=0);
    AssertTrue('occupier listen failed', fpListen(Occupier, 1)=0);
    // Start on the TEST thread: the bind happens synchronously before the
    // blocking accept loop, so the exception flies without a runner thread
    FReceiver.Host:='127.0.0.1';
    FReceiver.Port:=FPort;
    try
      FReceiver.Start;
      Fail('a bind conflict must raise EMaxConfig');
    except
      on E: EMaxConfig do
      begin
        AssertTrue('the message names the port ('+E.Message+')',
          Pos(IntToStr(FPort), E.Message)>0);
        AssertTrue('the original bind error is kept ('+E.Message+')',
          Pos('Binding of socket failed', E.Message)>0);
        AssertFalse('a failed bind never reports the receiver active',
          FReceiver.Active);
      end;
    end;
  finally
    CloseSocket(Occupier);
  end;
end;

procedure TTestWebhookReceiver.TLSDeliversUpdate;
var
  Code: Integer;
  Resp: String;
begin
  SetUpTLS;
  StartReceiver;
  Resp:=PostBody(TestUpdateBody, EmptyStr, Code);
  AssertEquals('the TLS delivery is answered 200', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('exactly one OnUpdate shot', 1, FUpdates);
  StopReceiver;
end;

procedure TTestWebhookReceiver.SendTruncatedTLSRequest;
var
  Handler: TOpenSSLSocketHandler;
  Sock: TInetSocket;
  Req: String;
  Buf: array[0..255] of Char;
  N: Integer;
  Answered: Boolean;
begin
  // A raw TLS client (the same shape fphttpclient uses: TInetSocket over a
  // socket handler), NOT the registered broker: the transports read the
  // request body with TStream.ReadBuffer, so a stream that promises more
  // than it serves aborts the request on the CLIENT side before any
  // silence - the truncation must happen on the wire. The client completes
  // the TLS handshake, sends a request head promising a body it never
  // finishes and then holds the connection SILENT past the server deadline:
  // freeing the socket early would turn the deadline expiry into a plain
  // EOF (a different branch of the contract)
  Handler:=TOpenSSLSocketHandler.Create;
  Handler.SSLType:=stTLSv1_2;
  // The stream takes the handler over: freed together with the socket
  Sock:=TInetSocket.Create('127.0.0.1', FPort, Handler);
  try
    Sock.Connect;
    Req:='POST / HTTP/1.1'#13#10+
         'Host: 127.0.0.1'#13#10+
         'Content-Length: 64'#13#10+
         #13#10+
         '{"partial":';
    Sock.WriteBuffer(Req[1], Length(Req));
    // The silence phase: the receiver's body read blocks mid-request until
    // the (shortened) deadline expires, and the deadline must fire while
    // the client is still connected; the extra margin covers the teardown
    Sleep(TestDeadlineMs+400);
    // Nothing may come back on this connection: the deadline kill closes it
    // without an answer (the td-066 contract), so a read attempt sees only
    // the teardown - a positive read would mean the connection survived and
    // an HTTP answer was sent
    Answered:=False;
    try
      Sock.IOTimeout:=500;
      N:=Sock.Read(Buf, SizeOf(Buf));
      Answered:=N>0;
    except
      // a read error on the killed connection is also "no answer"
    end;
    AssertTrue('the killed connection carries no HTTP answer', not Answered);
  finally
    Sock.Free;
  end;
end;

procedure TTestWebhookReceiver.TLSTruncatedRequestHitsDeadline;
var
  Code: Integer;
  Resp: String;
begin
  // The td-082 contract of the deadline path, pinned offline: a TLS client
  // that promises a body it never finishes is left blocked mid-request in
  // the receiver until the (shortened) socket IO deadline expires - the
  // td-066 Recv override must turn that into ESocketError(seIOTimeout)
  // surfaced as etError through OnRequestError, with the connection closed
  // WITHOUT an answer and no delivery processed (stock 3.2.2 saw a silent
  // EOF here and answered 200 to a truncated request). The deadline comes
  // from the protected receiver property through a subclass - the shape a
  // host customizing the value would use
  UseReceiver(TShortDeadlineReceiver.Create(TestDeadlineMs));
  SetUpTLS;
  StartReceiver;
  SendTruncatedTLSRequest;
  AssertEquals('a truncated request never reaches OnUpdate', 0, FUpdates);
  AssertTrue('the deadline expiry is logged as an error',
    HasLog(etError, 'deadline'));
  // The killed connection must not hurt the accept loop: a full request
  // straight after still delivers and answers 200 - the happy path of
  // TLSDeliversUpdate, run across the fault
  Resp:=PostBody(TestUpdateBody, EmptyStr, Code);
  AssertEquals('the receiver survives the killed connection', 200, Code);
  AssertEquals('the answer is the empty JSON object', '{}', AnswerBody(Resp));
  AssertEquals('exactly one OnUpdate shot', 1, FUpdates);
  StopReceiver;
end;

initialization
  RegisterTests([TTestWebhookReceiver]);

end.
