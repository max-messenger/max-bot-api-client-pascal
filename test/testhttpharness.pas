unit testhttpharness;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs, sockets;

const
  { The shared budget of the bounded start and stop waits: a wedged loopback
    server fails the test visibly after this long instead of hanging it;
    HarnessPollStepMs is the poll step of both wait loops }
  HarnessTimeoutMs = 5000;
  HarnessPollStepMs = 10;

type

  { TLoopbackRunner }

  { Runs one blocking start action on its own thread: TMaxWebhookReceiver.Start
  and TFPHTTPServer.Active:=True both block until stopped (the accept loop
  runs on the calling thread), so a live server is served from this thread;
  an exception out of the action cannot cross the thread boundary - it is
  captured into Error. The single copy of the runner the loopback suites
  were both carrying word for word (td-099): the action is a plain method
  pointer, so the webhook receiver passes its Start and the plain fphttpserver
  sink wraps its Active:=True in a method }
  TLoopbackRunner=class(TThread)
  private
    FStartProc: TThreadMethod;
    FError: String;
    FErrorCS: TCriticalSection;
    function GetError: String;
  protected
    procedure Execute; override;
  public
    constructor Create(AStartProc: TThreadMethod);
    destructor Destroy; override;
    property Error: String read GetError;
  end;

{ Reserves an ephemeral loopback port for the caller: bind :0, read the port
  back, close }
function PickFreePort: Word;

{ A plain connect as the readiness probe of a loopback server on APort }
function PortAccepting(APort: Word): Boolean;

{ The bounded start wait shared by both loopback suites: polls the port until
  it accepts, the runner dies (a captured start failure) or the budget runs
  out - a dead listener fails the test instead of hanging it. True = the port
  accepts }
function WaitForReady(ARunner: TLoopbackRunner; APort: Word;
  ATimeoutMs: Integer): Boolean;

{ The bounded stop join: polls the runner until it finishes or the budget
  runs out - a wedged shutdown fails the test visibly instead of hanging it.
  True = the runner finished }
function WaitForFinished(ARunner: TLoopbackRunner; ATimeoutMs: Integer): Boolean;

{ Creates a throwaway fixture file mkstemp-style and returns the created path
  (the shared recipe of the closed td-100 and its followers): the shared temp
  dir is not trusted (CWE-377/59 - SaveToFile/fmCreate follows a planted
  symlink and truncates the target), so the name carries a fresh GUID suffix
  (unpredictable) and the entry goes up through the exclusive open - per
  POSIX O_CREAT|O_EXCL fails with EEXIST on an existing entry even when that
  entry is a symlink, so a planted path can neither be truncated nor
  followed. APrefix carries the directory and the name part before the GUID
  slot, ASuffix the extension after it. The caller owns the deletion. A
  failure raises instead of asserting: the callers run inside SetUp or a test
  method, where a raise fails the test the same way an assert does }
function MakePrivateTempFile(const APrefix, ASuffix, AContent: String): String;

implementation

uses
  baseunix; // the mkstemp-style exclusive open of MakePrivateTempFile (O_EXCL)

{ TLoopbackRunner }

constructor TLoopbackRunner.Create(AStartProc: TThreadMethod);
begin
  // The field goes in before Create(False): the thread may start immediately
  FStartProc:=AStartProc;
  FError:=EmptyStr;
  // Error crosses the thread boundary (written in Execute, read by the test
  // thread): an AnsiString assignment is a refcount operation, so the access
  // is serialized
  FErrorCS:=TCriticalSection.Create;
  inherited Create(False);
end;

destructor TLoopbackRunner.Destroy;
begin
  // TThread.Destroy joins a live thread anyway; the CS must outlive it -
  // join first, then free
  if not Finished then
    WaitFor;
  FreeAndNil(FErrorCS);
  inherited Destroy;
end;

procedure TLoopbackRunner.Execute;
begin
  try
    FStartProc;
  except
    // The start failure (a bind conflict) surfaces on the test thread
    // through Error
    on E: Exception do
    begin
      FErrorCS.Enter;
      try
        FError:=E.ClassName+': '+E.Message;
      finally
        FErrorCS.Leave;
      end;
    end;
  end;
end;

function TLoopbackRunner.GetError: String;
begin
  FErrorCS.Enter;
  try
    Result:=FError;
  finally
    FErrorCS.Leave;
  end;
end;

function PickFreePort: Word;
var
  S: LongInt;
  Addr: TInetSockAddr;
  Len: LongInt;
begin
  // ssockets does not expose the port of a bound TInetServer (no public
  // getsockname path), so an ephemeral port is reserved here: bind :0, read
  // the port back, close. The tiny TOCTOU window is accepted - a stolen port
  // surfaces as the bind conflict both suites pin deliberately. A failure
  // raises instead of asserting: the caller may run outside a test method
  // (the multipart sink Create), and inside SetUp a raise fails the test the
  // same way an assert does
  S:=fpSocket(AF_INET, SOCK_STREAM, 0);
  if S<0 then
    raise Exception.Create('probe socket creation failed');
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family:=AF_INET;
    Addr.sin_port:=htons(0);
    Addr.sin_addr.s_addr:=htonl(StrToHostAddr('127.0.0.1').s_addr);
    if fpBind(S, @Addr, SizeOf(Addr))<>0 then
      raise Exception.Create('probe bind failed');
    Len:=SizeOf(Addr);
    if fpGetSockName(S, @Addr, @Len)<>0 then
      raise Exception.Create('probe getsockname failed');
    Result:=ntohs(Addr.sin_port);
  finally
    CloseSocket(S);
  end;
end;

function PortAccepting(APort: Word): Boolean;
var
  S: LongInt;
  Addr: TInetSockAddr;
begin
  // A plain connect serves as the readiness probe: the server accepts it,
  // the probe sends nothing and closes at once, the server side reads an
  // immediate EOF and tears the session down - an empty dial any listener
  // survives. The multipart sink tolerates the empty dial for its own
  // reason: fphttpserver swallows the teardown outright
  // (TFPHTTPConnectionThread.Execute catches everything)
  Result:=False;
  S:=fpSocket(AF_INET, SOCK_STREAM, 0);
  if S<0 then
    Exit;
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family:=AF_INET;
    Addr.sin_port:=htons(APort);
    Addr.sin_addr.s_addr:=htonl(StrToHostAddr('127.0.0.1').s_addr);
    Result:=fpConnect(S, @Addr, SizeOf(Addr))=0;
  finally
    CloseSocket(S);
  end;
end;

function WaitForReady(ARunner: TLoopbackRunner; APort: Word;
  ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  // The readiness signal is a probe connect that succeeds - the listening
  // socket object exists BEFORE the bind, so the probe alone is not proof;
  // the callers re-check the runner Error and the server Active state around
  // this wait. Bounded, so a dead listener fails the test instead of
  // hanging it
  Waited:=0;
  while (not PortAccepting(APort)) and (not ARunner.Finished) and
      (Waited<ATimeoutMs) do
  begin
    Sleep(HarnessPollStepMs);
    Inc(Waited, HarnessPollStepMs);
  end;
  Result:=PortAccepting(APort);
end;

function WaitForFinished(ARunner: TLoopbackRunner; ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  // The join stays bounded to fail visibly on a wedged shutdown
  Waited:=0;
  while (not ARunner.Finished) and (Waited<ATimeoutMs) do
  begin
    Sleep(HarnessPollStepMs);
    Inc(Waited, HarnessPollStepMs);
  end;
  Result:=ARunner.Finished;
end;

function MakePrivateTempFile(const APrefix, ASuffix, AContent: String): String;
var
  NewGUID: TGUID;
  FD: cInt;
  Attempt: Integer;
  Stream: THandleStream;
begin
  FD:=-1;
  for Attempt:=1 to 8 do
  begin
    if CreateGUID(NewGUID)<>0 then
      raise Exception.Create('CreateGUID failed');
    Result:=APrefix+Copy(GUIDToString(NewGUID), 2, 36)+ASuffix;
    FD:=fpOpen(Result, O_WRONLY or O_CREAT or O_EXCL, S_IRUSR or S_IWUSR);
    if FD>=0 then
      Break;
    // only a name clash is retryable - anything else fails loudly
    if fpgeterrno<>ESysEEXIST then
      raise Exception.Create('Cannot create the private temp fixture "'
        +Result+'": '+SysErrorMessage(Integer(fpgeterrno)));
  end;
  if FD<0 then
    raise Exception.Create('Cannot create the private temp fixture under "'
      +APrefix+'": all name attempts are taken');
  try
    // the RTL stream wraps the already opened fd (it does not own it)
    Stream:=THandleStream.Create(THandle(FD));
    try
      Stream.WriteBuffer(PChar(AContent)^, Length(AContent));
    finally
      Stream.Free;
      fpClose(FD);
    end;
  except
    // a partial fixture is worse than none: delete only what this call
    // created (the exclusive open guarantees the entry is ours)
    DeleteFile(Result);
    raise;
  end;
end;

end.
