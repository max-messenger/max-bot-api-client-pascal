unit multipartboundarytests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs, fphttpserver, fpcunit, testregistry,
  maxbasehttpclient, testhttpharness;

type

  { TTestMultipartSink }

  { The local loopback receiver of TTestMultipartBoundary (td-096): a plain
    HTTP server that takes the broker's outgoing multipart request and keeps
    its Content-Type header and raw body, so the tests can compare the
    boundary the broker puts in the header with the one it puts in the body.
    No TLS, 127.0.0.1 only. The capture is overwritten per request; with
    Threaded:=True the handler runs on a connection thread, so the fields
    are guarded }
  TTestMultipartSink=class
  private
    FServer: TFPHTTPServer;
    FRunner: TLoopbackRunner;
    FCS: TCriticalSection;
    FPort: Word;
    FContentType: String;
    FBody: String;
    FCount: Integer;
    { A wedged stop is final: the runner went to FreeOnTerminate and the
      server must never be freed under its live accept thread (td-104) }
    FWedged: Boolean;
    procedure HandleRequest({%H-}Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    { The blocking start the harness runner serves on its own thread:
      TFPHTTPServer.Active:=True blocks until the server is stopped }
    procedure RunServer;
    { The bounded stop Stop and Destroy share: repeats the stop until the
      server reports inactive AND the runner has finished, then joins and
      frees the runner. True = down and joined, the sink is safe to free;
      False = wedged - the runner was handed to its own thread
      (FreeOnTerminate, td-104) and the caller must free nothing }
    function TryStop: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Starts the accept loop on the runner thread and waits (bounded) until
      the port accepts; raises what the start attempt raised }
    procedure Start;
    { Stops the accept loop and joins the runner; raises if the loop does
      not come down in time - a wedged stop leaves the sink unfreeable (the
      runner self-frees, the server leaks deliberately, td-104) }
    procedure Stop;
    { The Content-Type header of the last captured request }
    function ContentType: String;
    { The raw body of the last captured request }
    function Body: String;
    { How many requests the sink has taken so far }
    function RequestCount: Integer;
    property Port: Word read FPort;
  end;

  { TTestMultipartBoundary }

  { td-077/td-096: the boundary controls of the multipart upload pinned
    end-to-end. The suite drives the REGISTERED broker (each runner links
    exactly one) against TTestMultipartSink and pins what the harness makes
    observable: the boundary in the body framing is the boundary of the
    Content-Type header, two sequential calls produce different boundaries
    (a deterministic or per-process-repeated boundary would reinstate the
    td-077 file-crafting vector), and a file whose bytes hold the REAL
    boundary captured from an earlier call passes the buffered collision
    gate without a false positive - the gate rejects the CURRENT call's
    boundary only, and a regression to pattern matching or to a whole-body
    scan turns these uploads red. The collision raise itself (a file holding
    the CURRENT call's boundary) stays untestable through the public API:
    the boundary is fresh per call and reaches no observable place before
    the gate runs (the FCL header seam is FCL- and StreamsFormPost-only;
    the brokers must not grow test-only surface - td-096) }
  TTestMultipartBoundary=class(TTestCase)
  private
    FSink: TTestMultipartSink;
    { Sends AContent as the file part through StreamFormPost, the verb the
      TMaxSender.UploadFile production path uses (maxsendertypes.pas), and
      returns the answer body }
    function PostStream(const AContent: String): String;
    { Sends the file at APath through FilesFormPost, the buffered verb whose
      file bytes pass the td-077 collision gate }
    function PostFile(const APath: String): String;
    { The boundary= value of a captured Content-Type header }
    function HeaderBoundary(const AContentType: String): String;
    { The boundary of a captured body, read off the opening delimiter }
    function FrameBoundary(const ABody: String): String;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure BodyBoundaryMatchesContentType;
    procedure BoundaryDiffersBetweenCalls;
    procedure FileWithCapturedBoundaryPassesTheGate;
  end;

implementation

{ TTestMultipartSink }

type
  { Address is protected in TFPCustomHttpServer 3.2.2 and an empty one binds
    all interfaces (TInetServer.Create(Port)): raising it here is the only
    way for the sink to pin 127.0.0.1 - the TMaxHTTPServer pattern
    (maxwebhook.pas), implementation-only on purpose }
  TTestLoopbackServer=class(TFPHTTPServer)
  public
    property Address;
  end;

procedure TTestMultipartSink.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
begin
  FCS.Enter;
  try
    Inc(FCount);
    FContentType:=ARequest.ContentType;
    FBody:=ARequest.Content;
  finally
    FCS.Leave;
  end;
  // fphttpserver has already read the whole body into Content (the broker
  // bodies are far below any sane limit here), the answer is irrelevant to
  // the tests beyond being a well-formed 200
  AResponse.Code:=200;
  AResponse.Content:='{}';
end;

procedure TTestMultipartSink.RunServer;
begin
  // blocks in the accept loop until the server is stopped
  FServer.Active:=True;
end;

constructor TTestMultipartSink.Create;
begin
  FCS:=TCriticalSection.Create;
  FPort:=PickFreePort;
  FServer:=TTestLoopbackServer.Create(nil);
  FServer.Port:=FPort;
  // the class comment promises 127.0.0.1 only: the pin rides the
  // implementation subclass (Address lives there), and PickFreePort plus
  // PortAccepting already probe that address, so the contract matches
  TTestLoopbackServer(FServer).Address:='127.0.0.1';
  FServer.Threaded:=True;
  // WHY: with a plain blocking accept the server loop cannot be stopped at
  // all on a quiet server (ssockets retries an interrupted accept forever
  // and a stopped loop never re-checks its flag while blocked). The idle
  // timeout moves the wait into select rounds that re-check the accepting
  // flag, which makes Stop effective - the TMaxWebhookReceiver.Create
  // pattern (maxwebhook.pas)
  FServer.AcceptIdleTimeout:=200;
  FServer.OnRequest:=@HandleRequest;
end;

destructor TTestMultipartSink.Destroy;
var
  Joined: Boolean;
begin
  // TryStop itself raises nothing, but the server shutdown inside it may:
  // a destructor swallows - pure insurance, and this destructor runs on
  // both free paths: TearDown stops first and FreeAndNil then runs it, a
  // failed SetUp frees the sink directly - the swallow keeps a wedged stop
  // off the Start error path
  Joined:=False;
  try
    Joined:=TryStop;
  except
  end;
  // td-104: the server and the capture critical section die only under a
  // JOINED runner - on a wedged stop the accept thread may still sit inside
  // RunServer (Active:=True) and a connection thread inside HandleRequest
  // (FCS), so a free under them is the use-after-free this record pins.
  // The wedged path handed the runner to its own thread (FreeOnTerminate)
  // and the rest leaks deliberately; the loud report belongs to Stop (the
  // TearDown path), never to a destructor
  if Joined then
  begin
    FServer.Free;
    FreeAndNil(FCS);
  end;
  inherited Destroy;
end;

procedure TTestMultipartSink.Start;
begin
  FRunner:=TLoopbackRunner.Create(@RunServer);
  WaitForReady(FRunner, FPort, HarnessTimeoutMs);
  if FRunner.Error<>EmptyStr then
    raise Exception.Create('the multipart sink did not start: '+FRunner.Error);
  if not PortAccepting(FPort) then
    raise Exception.Create('the multipart sink does not accept connections');
end;

function TTestMultipartSink.TryStop: Boolean;
var
  Waited: Integer;
begin
  // a wedged stop is final: the runner is already self-freeing and the
  // server stays alive under its accept thread
  if FWedged then
    Exit(False);
  Result:=True;
  if FRunner=Nil then
    Exit;
  // WHY the loop, not a single stop: a stop landing between the accept
  // loop start and the moment ssockets raises its accepting flag would be
  // lost (ssockets: StartAccepting sets the flag, StopAccepting only clears
  // it - the later start wins), so the stop is repeated until the server
  // reports inactive AND the runner has returned - the repetition also
  // closes that not-yet-started window (the TMaxWebhookReceiver.Stop
  // pattern), the budget stays ~5 s
  Waited:=0;
  while (FServer.Active or not FRunner.Finished) and
      (Waited<HarnessTimeoutMs) do
  begin
    FServer.Active:=False;
    Sleep(20);
    Inc(Waited, 20);
  end;
  if FServer.Active or not FRunner.Finished then
  begin
    // td-104: the runner object must never be freed under its live thread
    // (the free would join a wedged accept loop forever) and the sink must
    // never free the server under it - hand the object to the thread itself
    // (FreeOnTerminate), drop the reference and mark the sink unfreeable;
    // the leak is the deliberate trade against the use-after-free
    FWedged:=True;
    FRunner.FreeOnTerminate:=True;
    FRunner:=Nil;
    Exit(False);
  end;
  // Finished is pinned by the bounded poll above, so this WaitFor only
  // reaps the thread - never the unbounded join of a wedged accept loop
  FRunner.WaitFor;
  FreeAndNil(FRunner);
end;

procedure TTestMultipartSink.Stop;
begin
  // a wedged shutdown is a test failure on the TearDown path, not silence:
  // the raise also keeps FreeAndNil(FSink) off the wedged sink, so the
  // destructor cannot free the server under the live accept thread
  if not TryStop then
    raise Exception.Create('the multipart sink stop is wedged: the accept loop '
      +'did not come down within '+IntToStr(HarnessTimeoutMs)+' ms - the sink '
      +'is not freed and the runner thread is left self-freeing');
end;

function TTestMultipartSink.ContentType: String;
begin
  FCS.Enter;
  try
    Result:=FContentType;
  finally
    FCS.Leave;
  end;
end;

function TTestMultipartSink.Body: String;
begin
  FCS.Enter;
  try
    Result:=FBody;
  finally
    FCS.Leave;
  end;
end;

function TTestMultipartSink.RequestCount: Integer;
begin
  FCS.Enter;
  try
    Result:=FCount;
  finally
    FCS.Leave;
  end;
end;

{ TTestMultipartBoundary }

const
  { Same literal the stock builders assemble with (the maxbasehttpclient one
    is implementation-local, not visible here) }
  CRLF=#13#10;
  { The file bytes the stream verb uploads: pure ASCII, no boundary-shaped
    structure, big enough that a truncated body cannot pass for whole }
  cBoundaryProbeContent='multipart boundary probe payload 0123456789: '
    +'the sink captures this file part verbatim;';

procedure TTestMultipartBoundary.SetUp;
begin
  inherited SetUp;
  // fpcunit does not call TearDown when SetUp raises: a failed Create or
  // Start would leak the sink (sometimes with a live accept thread), so it
  // is cleaned up here before re-raising
  FSink:=TTestMultipartSink.Create;
  try
    FSink.Start;
  except
    FSink.Free; // the destructor already swallows a wedged Stop
    FSink:=Nil;
    raise;
  end;
end;

procedure TTestMultipartBoundary.TearDown;
begin
  // Stop lives in the destructor too, but here it may raise: a wedged
  // shutdown is a test failure, not silence. The guard is defensive
  // insurance against an fpcunit build reaching TearDown with no sink
  if Assigned(FSink) then
    FSink.Stop;
  FreeAndNil(FSink);
  inherited TearDown;
end;

function TTestMultipartBoundary.PostStream(const AContent: String): String;
var
  Client: TBaseHTTPClient;
  Src: TStringStream;
  Resp: TStringStream;
begin
  // the class factory returns the broker-registered client (the runner
  // links exactly one) - the same wiring the webhookreceivertests PostBody
  // uses; plain loopback HTTP, no TLS knobs
  Client:=TBaseHTTPClient.GetClientClass.Create(nil);
  try
    Client.IOTimeout:=5000;
    Src:=TStringStream.Create(AContent);
    try
      Resp:=TStringStream.Create('');
      try
        Client.StreamFormPost(Format('http://127.0.0.1:%d/', [FSink.Port]),
          Nil, 'data', 'probe.bin', Src, Resp);
        Result:=Resp.DataString;
      finally
        Resp.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Client.Free;
  end;
end;

function TTestMultipartBoundary.PostFile(const APath: String): String;
var
  Client: TBaseHTTPClient;
  Files: TStringList;
begin
  Client:=TBaseHTTPClient.GetClientClass.Create(nil);
  try
    Client.IOTimeout:=5000;
    Files:=TStringList.Create;
    try
      Files.Values['data']:=APath;
      Result:=Client.FilesFormPost(Format('http://127.0.0.1:%d/', [FSink.Port]),
        Nil, Files);
    finally
      Files.Free;
    end;
  finally
    Client.Free;
  end;
end;

function TTestMultipartBoundary.HeaderBoundary(const AContentType: String
  ): String;
var
  I: Integer;
begin
  I:=Pos('boundary=', AContentType);
  AssertTrue('the captured Content-Type declares a multipart boundary, got: '
    +AContentType, I>0);
  Result:=Copy(AContentType, I+Length('boundary='), MaxInt);
end;

function TTestMultipartBoundary.FrameBoundary(const ABody: String): String;
begin
  // the opening delimiter is the first line of the body: --<boundary>CRLF
  AssertTrue('the captured body starts with an opening delimiter',
    (Copy(ABody, 1, 2)='--') and (Pos(CRLF, ABody)>3));
  Result:=Copy(ABody, 3, Pos(CRLF, ABody)-3);
end;

procedure TTestMultipartBoundary.BodyBoundaryMatchesContentType;
var
  B: String;
begin
  PostStream(cBoundaryProbeContent);
  AssertEquals('exactly one request reached the sink', 1,
    FSink.RequestCount);
  B:=HeaderBoundary(FSink.ContentType);
  AssertEquals('the body framing carries the boundary of the Content-Type header',
    B, FrameBoundary(FSink.Body));
end;

procedure TTestMultipartBoundary.BoundaryDiffersBetweenCalls;
var
  First: String;
  Second: String;
  Payload: String;
begin
  PostStream(cBoundaryProbeContent);
  First:=HeaderBoundary(FSink.ContentType);
  AssertEquals('the first body framing carries the first header boundary',
    First, FrameBoundary(FSink.Body));
  // the second upload carries the REAL boundary of the first call in its
  // bytes - the td-077 attack shape, a file crafted against a boundary the
  // client has legitimately received. The boundary is fresh per call, so
  // the request must go out (and out with a different boundary): a repeated
  // boundary here would make the crafted file an injection
  Payload:='--'+First+CRLF+'crafted against the captured boundary';
  PostStream(Payload);
  AssertEquals('the second request reached the sink', 2, FSink.RequestCount);
  Second:=HeaderBoundary(FSink.ContentType);
  AssertTrue('two sequential calls produce different boundaries, both were: '
    +First, Second<>First);
  AssertEquals('the second body framing carries the second header boundary',
    Second, FrameBoundary(FSink.Body));
  // the crafted bytes traveled verbatim inside the file part: the only
  // occurrence of the first boundary in the second body is the payload
  // (the framing carries the second boundary)
  AssertTrue('the file bytes with the captured boundary reach the wire verbatim',
    Pos(Payload, FSink.Body)>0);
end;

procedure TTestMultipartBoundary.FileWithCapturedBoundaryPassesTheGate;
var
  First: String;
  Path: String;
  FileBody: String;
begin
  // the buffered verb runs the td-077 collision gate over the file bytes,
  // so this file - holding the REAL boundary the broker itself produced a
  // call earlier - pins what the gate must NOT do: a false positive on a
  // boundary-shaped payload (a regression to pattern matching or to a
  // whole-body scan, whose framing holds the boundary by design, would
  // raise here). The gate rejects the CURRENT call's boundary only
  PostStream(cBoundaryProbeContent);
  First:=HeaderBoundary(FSink.ContentType);
  FileBody:='stale boundary inside: '+First
    +' - the collision gate must not fire on it';
  // the shared temp dir is not trusted, so the fixture goes up mkstemp-style
  // through the shared harness helper (td-100): unpredictable GUID name,
  // exclusive creation - a planted path can neither be truncated nor followed
  Path:=MakePrivateTempFile(IncludeTrailingPathDelimiter(GetTempDir)
    +'fpmax-boundary-probe-', '.bin', FileBody);
  try
    PostFile(Path);
  finally
    DeleteFile(Path);
  end;
  AssertEquals('the buffered request reached the sink', 2, FSink.RequestCount);
  AssertTrue('a file holding a previous call boundary does not trip the gate',
    HeaderBoundary(FSink.ContentType)<>First);
  AssertTrue('the file bytes arrive verbatim', Pos(FileBody, FSink.Body)>0);
end;

initialization
  RegisterTests([TTestMultipartBoundary]);

end.
