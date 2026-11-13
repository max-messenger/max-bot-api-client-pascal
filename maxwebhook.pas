unit maxwebhook;

{$mode objfpc}{$H+}

{ TMaxWebhookReceiver: an HTTPS endpoint for MAX Bot API webhook deliveries -
  the library-side extract of what used to be the hand-rolled examples/Webhook
  server (max_webhook.lpr; td-064 rewrote the example as a client of this
  unit). The platform POSTs a single Update object per delivery;
  non-200 answers are retried by the platform for up to 8 hours, so the
  receiver answers 200 on every delivery fault and reserves the only non-200
  (403) for a request that is not a platform delivery at all (secret
  mismatch).

  Threading model: the server runs with Threaded=True, so OnUpdate/OnLog
  fire on HTTP connection threads - the handlers must be thread-safe, the
  receiver adds no synchronization of its own. OnLog also fires outside
  them: the degradation warning of a failed IO deadline on the accept
  thread and the secretless warning on the thread calling Start - the
  canonical list of the contexts (and which threats apply to which) is
  the OnLog property comment. The events are synchronous: a
  slow OnUpdate delays the 200 answer to the platform, a long-running host
  queues the work and returns.

  Update ownership: the receiver creates the TMaxUpdateObj and owns it only
  until the OnUpdate handler returns; the handler copies what it needs
  (chat_id, texts) and neither frees the object nor keeps a reference.

  Configuration (Port, Host, CertFile, KeyFile, Secret, MaxBodySize, UseSSL
  and the events) is read by request threads without any synchronization:
  set it BEFORE Start and never change it on a live receiver. This is
  deliberately weaker than the TMaxSender contract, whose setters are
  serialized.

  Start blocks in the accept loop of the calling thread until Stop; stop a
  receiver that is observed Active (the same shape as the stop watcher of
  the example). A failed bind raises EMaxConfig with the port in the
  message; any other socket failure of the start window (an accept-loop
  failure under load, say EMFILE) re-raises the original ESocketError - the
  host stops with the honest class and message, not a bind diagnosis
  (td-068). A host program on Linux or macOS needs cthreads (-dUseCThreads):
  without it the build is green and the first connection thread crashes the
  process (runtime error 232).

  TLS: UseSSL (True by default) builds an OpenSSL server handler with
  stTLSv1_2 reading the PEM pair from CertFile/KeyFile; the server key must
  be RSA - the FPC 3.2.2 openssl unit loads it through
  SSL_CTX_use_RSAPrivateKey_file, an ECDSA key resets the handshake on the
  ClientHello with an empty log.

  On Linux the unit initialization ignores SIGPIPE process-wide (the client
  brokers do the same): accepted-socket writes have no MSG_NOSIGNAL on that
  platform, so the default disposition would kill the host on the first
  client reset. The change is process-wide and permanent - reinstall the
  default disposition after uses if the host needs it. On darwin nothing
  process-wide happens: the connection socket handlers arm SO_NOSIGPIPE on
  every accepted socket (SetSocket overrides), so a write into a socket the
  client has already reset comes back as an exception instead.

  Exposure and threads contract: MaxBodySize limits the PROCESSING of a
  body only - fphttpserver has already read the whole body into memory by
  the time HandleRequest runs, so a public port 443 must sit behind (or be
  configured with) infrastructure that bounds the request size itself. Each
  accepted connection carries a ConnectionIOTimeoutMs socket deadline, but
  it is a per-recv bound, not a per-connection one: it stops a client that
  goes fully silent mid-request (including the TLS handshake phase, see
  ConnectionIOTimeoutMs), while a dribbling client (a byte once in a while
  never lets a single recv expire) and the header sizes of fphttpserver 3.2.2
  (read without a count or size limit) stay outside it - a reverse proxy
  with header and read/send timeouts is the recommended bound for those.
  An expired deadline surfaces the same way on both transports now
  (OnRequestError, etError, the platform retries): EHTTPServer on the plain
  path, and on the TLS path the ESocketError(seIOTimeout) raised by the
  Recv override of the OpenSSL connection handler - stock 3.2.2 turned it
  into a silent EOF there, a truncated request was processed and answered
  200, a lost delivery with no visible failure (td-066). What the deadline
  does NOT bound: the TLS write side of a zero-window client - the
  handshake ServerHello and the teardown close_notify block up to
  SO_SNDTIMEO each, up to ~30 s of serial accept-thread time per
  connection, all inside FCL code (td-067). Start
  is not synchronized: call it from exactly one thread. After Stop returns,
  join the thread that called Start before freeing the receiver (the shape
  of StopReceiver in test/webhookreceivertests.pas: Stop - bounded join -
  Free). }

interface

uses
  Classes, SysUtils, eventlog, fphttpserver, ssockets, maxsendertypes;

const
  // Bodies larger than this are ignored (logged, still answered 200). The
  // check runs after fphttpserver has already read the whole body into
  // memory, so it limits the expensive processing only: against a
  // memory-hungry flood the real protection is a reverse proxy in front
  DefaultMaxBodySize = 1 * 1024 * 1024;

  // Maximum nesting of [ and { accepted in a webhook body. The fpjson parser
  // (3.2.2) is recursive with no depth limit, and a stack overflow inside it
  // is not an Exception: the OS kills the process and no handler in Pascal can
  // catch that, so deep bodies are measured and rejected BEFORE GetJSON runs.
  // A real update never comes close (well under 15 levels), false rejections
  // are not a concern
  MaxJSONDepth = 64;

// Reports whether the nesting of [ and { in ABody exceeds MaxJSONDepth (the
// WHY of the limit is on the constant). A single pass, O(1) memory: string
// literals are skipped (a bracket inside quotes is data, not structure) with
// backslash escapes honored, so the count matches what the parser itself
// would recurse into. Moved here from the webhookutils unit of the
// examples/Webhook example: the receiver must pre-scan before GetJSON, a
// library unit cannot use an example unit, and the fpcunit runner in test/
// keeps pinning the escape logic with TTestWebhookScan
function JSONBodyTooDeep(const ABody: String): Boolean;

type

  { TMaxWebhookReceiver: see the unit comment for the threading model, the
    update ownership, the configuration rule and the TLS key requirement }
  TMaxWebhookReceiver = class
  private
    FServer: TFPHTTPServer;
    FPort: Word;
    FHost: String;
    FCertFile: String;
    FKeyFile: String;
    FSecret: String;
    FMaxBodySize: Integer;
    FUseSSL: Boolean;
    FConnectionIOTimeoutMs: Integer;
    FOnUpdate: TOnUpdateEvent;
    FOnLog: TLogMessageEvent;
    procedure HandleRequest({%H-}Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure GetSocketHandler({%H-}Sender: TObject; const UseSSL: Boolean;
      out AHandler: TSocketHandler);
    procedure HandleRequestError({%H-}Sender: TObject; E: Exception);
    procedure Log(AEventType: TEventType; const AMsg: String);
    function GetActive: Boolean;
  protected
    // Adapter for the server subclass (TMaxHTTPServer.OnConnectionLog): its
    // TLogMessageEvent signature carries an explicit Sender the receiver's
    // Log does not take - the degradation warning goes through the same
    // best-effort Log as every other receiver message. Protected as the test
    // seam of td-101: the pin drives the connection-log path through a test
    // subclass, the sanitization contract itself stays in Log
    procedure HandleServerLog({%H-}ASender: TObject; AEventType: TEventType;
      const AMsg: String);
    { Per-connection socket IO deadline in milliseconds: the runtime
      override point of DefaultConnectionIOTimeoutMs (15000), pinned by
      td-082. Tests shorten it - a deadline contract test must not eat the
      15 s production default - hosts may lengthen it. A non-positive value
      arms the default (see EffectiveIOTimeoutMs). The configuration is read
      by connection threads without synchronization - the unit header rule
      applies: set it BEFORE Start, on a subclass instance (protected like
      the rest of the receiver internals, no public API surface). The value
      travels through the implementation-only plumbing: GetSocketHandler
      copies it into the connection socket handlers (the pre-handshake
      SO_RCVTIMEO/SO_SNDTIMEO arm of ArmIODeadline) and Start snapshots it
      onto the server subclass (the post-handshake cache sync of
      CreateConnection) }
    property ConnectionIOTimeoutMs: Integer read FConnectionIOTimeoutMs
      write FConnectionIOTimeoutMs;
  public
    constructor Create;
    destructor Destroy; override;
    { Validates the configuration and blocks in the accept loop of the
      calling thread until Stop. Raises EMaxConfig when UseSSL is on without
      a PEM certificate pair, or when the port cannot be bound (the port is
      in the message); any other ESocketError of the start window re-raises
      unchanged - the host stops with the honest diagnosis (td-068) }
    procedure Start;
    { Thread-safe: repeats Active:=False until the server reports inactive
      (AcceptIdleTimeout bounds each round), a single stop landing before the
      accept loop raised its accepting flag would be lost. No-op on an
      inactive receiver }
    procedure Stop;
    property Port: Word read FPort write FPort;                // default 443
    property Host: String read FHost write FHost;              // '' = all interfaces
    property CertFile: String read FCertFile write FCertFile;  // PEM certificate
    property KeyFile: String read FKeyFile write FKeyFile;     // PEM, RSA key
    property Secret: String read FSecret write FSecret;        // '' = not checked
    property MaxBodySize: Integer read FMaxBodySize write FMaxBodySize; // default DefaultMaxBodySize, 0 = no limit, a negative value is rejected by Start
    property UseSSL: Boolean read FUseSSL write FUseSSL;       // default True
    property Active: Boolean read GetActive;                   // advisory
    property OnUpdate: TOnUpdateEvent read FOnUpdate write FOnUpdate;
    { Canonical list of the thread contexts Log fires from (the unit header
      and the Log body refer here for the breakdown of which threats
      apply to which): (1) request threads - ordinary delivery logging;
      (2) the ACCEPT thread - the degradation warning of a connection
      whose IO deadline could not be armed, through the OnConnectionLog
      slot of the implementation-only server subclass; (3) the thread
      calling Start - the secretless warning, raised before the accept
      loop runs once. The callback must be thread-safe in all three, and
      two prohibitions hold in EVERY context: never free the receiver
      from the callback, never call Start on it from the callback. In
      (3) this is not obvious - the callback runs while Active is still
      False - but Free is use-after-free there all the same: after the
      callback returns the same Start stack assigns Port, Address and
      UseSSL and sets Active:=True on the freed server; and a nested
      Start passes the Active guard (still False) and reenters, running
      its bind/accept cycle inside the outer Start frame. Context (2)
      adds the accept-loop rules: the callback must not block for an
      indefinite time (a slow one freezes the accept loop for its
      duration) and must not call Stop either - from the accept thread
      Stop never returns (Active only clears after the server accept
      loop has returned, which cannot happen while the callback sits on
      its stack - Stop spins on Active). Context (3) is permissive
      beyond that: a long callback is just the host's own synchronous
      start path, and Stop there is a harmless no-op - the loop in it
      runs no single round, Active is already False }
    property OnLog: TLogMessageEvent read FOnLog write FOnLog;
  end;

implementation

uses
  sslbase, sslsockets, opensslsockets, fpjson, jsonparser, maxtypes,
  openssl, fpopenssl, // SSL_ERROR_* constants and the TSSL calls of the Recv override (td-066)
  sockets // fpSetSockOpt, SOL_SOCKET, SO_RCVTIMEO/SO_SNDTIMEO, TTimeVal in ArmIODeadline
  {$IFDEF LINUX}
  , baseunix // FpSignal(SIGPIPE) in initialization
  {$ENDIF}
  {$IFDEF DARWIN}
  , baseunix // cint in ArmNoSigPipe
  {$ENDIF}
  ;

const
  // Granularity, in milliseconds, of the server accept loop when no
  // connection is pending: the loop checks its accepting flag once per
  // round, so this is also the shutdown latency after the stop flag is
  // raised
  AcceptIdleMs = 200;

  // The default of the receiver's ConnectionIOTimeoutMs property (the
  // runtime override point, td-082): the per-connection socket IO deadline
  // in milliseconds (SO_RCVTIMEO and
  // SO_SNDTIMEO on the accepted socket, armed by ArmIODeadline in the
  // connection socket handlers). Armed BEFORE the TLS handshake, not only in
  // TMaxHTTPServer.CreateConnection: ssockets performs the handshake in
  // TInetServer.SockToStream before DoConnect reaches CreateConnection, so a
  // deadline set only there would still let one silent TLS client stop the
  // single accept thread indefinitely. Without the deadline a client that
  // opens a connection and never finishes the request holds its connection
  // thread and file descriptor forever (the secret is checked only after the
  // headers are read). Deliveries are small and fast, so a generous deadline
  // never cuts a legitimate request; fphttpserver 3.2.2 has no keep-alive,
  // so there is no idle reuse the timeout could kill
  //
  // Residual risk the deadline does NOT close (td-067): a TLS client that
  // announces a zero TCP receive window serially holds the SINGLE accept
  // thread for up to ~30 s per connection - SSL_accept blocks writing the
  // ServerHello to SO_SNDTIMEO, and the teardown SSL_shutdown blocks the
  // same way writing close_notify; both locks live in FCL code
  // (opensslsockets/ssockets 3.2.2) and are not reachable without a fork.
  // A continuous zero-window strafe keeps the accept loop busy ~100% of
  // the time while deliveries pile up in the backlog and time out on the
  // platform side, with no visible fault in the receiver log. The bound
  // is a reverse proxy with read/send timeouts (the same mitigation as
  // for the dribble/header exposure, td-065)
  DefaultConnectionIOTimeoutMs = 15000;

type
  { Address in TFPCustomHTTPServer 3.2.2 is protected and TFPHTTPServer does
    not republish it, while HostName is the SSL certificate name
    (deprecated), not the bind interface. The subclass raises Address to
    published: the only compiling way to set the bind interface from
    outside. Empty (the receiver default) binds all interfaces
    (TInetServer.Create(Port)), an address like 127.0.0.1 binds that one.
    Implementation-only on purpose: the class exists for the receiver
    internals, and DropFailedSocket (freeing a listening socket) must not
    become part of the package API }
  TMaxHTTPServer = class(TFPHTTPServer)
  protected
    // Runs per accepted connection, before the request is read: the override
    // re-arms the IO deadline on the fresh socket, best-effort (see the body)
    function CreateConnection(Data: TSocketStream): TFPHTTPConnection;
      override;
  public
    { Set by TMaxWebhookReceiver.Create to the receiver's Log: the only way
      for this subclass to report a degraded connection (a failed IO-deadline
      set) through the user-configured OnLog. This slot fires on the ACCEPT
      thread (the call sits in CreateConnection), which is why callers must
      invoke it best-effort - a raising log callback must not break the
      accept loop through the very path that reports the degradation (the
      ErrorMessage convention of the library; TMaxWebhookReceiver.Log does
      the same wrapping). Distinct from OnLog on purpose: that name is the
      user-configured property of TMaxWebhookReceiver }
    OnConnectionLog: TLogMessageEvent;
    { Per-connection IO deadline in milliseconds CreateConnection writes into
      the fresh connection stream (the post-handshake cache sync - see the
      body). Copied by Start from the receiver's ConnectionIOTimeoutMs next
      to the other configuration snapshot; the two consumers (this write and
      ArmIODeadline) normalize a non-positive value to
      DefaultConnectionIOTimeoutMs - a zero deadline would silently disable
      SO_RCVTIMEO, and a zero cache would turn the Recv override's WANT_READ
      loop into a spin }
    IOTimeoutMs: Integer;
    { Frees the listening socket object a FAILED start left behind:
      SetActive(True) creates it before binding and frees it only on the
      success path (after the accept loop returns), so a failed bind would
      otherwise keep Active=True forever }
    procedure DropFailedSocket;
  published
    property Address;
  end;

  { The connection socket handlers prepare every accepted socket in their
    SetSocket override, which runs from TSocketStream.Create, before the
    first byte of that connection is exchanged: ArmIODeadline arms the
    ConnectionIOTimeoutMs deadline (both platforms) and ArmNoSigPipe arms
    SO_NOSIGPIPE (darwin only - ssockets sends with flags 0 and arms no
    per-socket option, so a write into a socket the platform has already
    reset would kill the whole host with SIGPIPE; on Linux the unit
    initialization ignores SIGPIPE process-wide instead). The deadline MUST
    be armed in SetSocket, not only in TMaxHTTPServer.CreateConnection - see
    ConnectionIOTimeoutMs. One subclass per GetSocketHandler branch - the
    plain and the OpenSSL handler have no common subclass below
    TSocketHandler to carry the override }
  TNoSigPipeSocketHandler = class(TSocketHandler)
  public
    { Per-connection IO deadline in milliseconds the SetSocket override arms
      on the raw accepted socket: GetSocketHandler copies it from the
      receiver's ConnectionIOTimeoutMs on every instance it creates. A
      non-positive value (a fresh instance) is normalized to the default by
      the consumers - see ArmIODeadline }
    IOTimeoutMs: Integer;
    procedure SetSocket(const AStream: TSocketStream); override;
  end;

  TNoSigPipeOpenSSLHandler = class(TOpenSSLSocketHandler)
  public
    // The same per-connection deadline contract as
    // TNoSigPipeSocketHandler.IOTimeoutMs - the two subclasses have no
    // common base below TSocketHandler to carry one copy (see
    // DefaultConnectionIOTimeoutMs)
    IOTimeoutMs: Integer;
    procedure SetSocket(const AStream: TSocketStream); override;
    // The expired-deadline fix of td-066: stock 3.2.2 Recv answers 0 (EOF)
    // for a WANT_READ with a positive IOTimeout - see the override body
    function Recv(const Buffer; Count: Integer): Integer; override;
  end;

// The effective per-connection deadline: a non-positive configuration value
// (only reachable through the receiver's ConnectionIOTimeoutMs property or
// a fresh handler instance) arms the default. WHY normalize here and not
// trust the assignment sites: a zero deadline silently DISABLES
// SO_RCVTIMEO - the quiet-client protection of td-066/067 would vanish
// without a trace - and a zero stream cache would turn the WANT_READ loop
// of the Recv override into a spin (the raise branches on a positive cache)
function EffectiveIOTimeoutMs(AValue: Integer): Integer;
begin
  if AValue>0 then
    Result:=AValue
  else
    Result:=DefaultConnectionIOTimeoutMs;
end;

// Shared arming of the per-connection IO deadline for both handler
// subclasses, straight on the raw accepted socket. The timing is
// load-bearing - see ConnectionIOTimeoutMs. Best-effort like ArmNoSigPipe: a
// failed FpSetSockOpt is deliberately not checked here - refusing the
// connection from inside a socket-handler callback would be worse than
// serving it without a deadline, and TMaxHTTPServer.CreateConnection
// retries the set, logging the degradation when that fails too
procedure ArmIODeadline(const AStream: TSocketStream; ATimeoutMs: Integer);
var
  TimeOut: TTimeVal;
begin
  ATimeoutMs:=EffectiveIOTimeoutMs(ATimeoutMs);
  TimeOut.tv_sec:=ATimeoutMs div 1000;
  TimeOut.tv_usec:=(ATimeoutMs mod 1000)*1000;
  FpSetSockOpt(AStream.Handle, SOL_SOCKET, SO_RCVTIMEO, @TimeOut, SizeOf(TimeOut));
  FpSetSockOpt(AStream.Handle, SOL_SOCKET, SO_SNDTIMEO, @TimeOut, SizeOf(TimeOut));
end;

{$IFDEF DARWIN}
// Shared arming of SO_NOSIGPIPE for both handler subclasses. SO_NOSIGPIPE
// comes from the sockets unit (4130 on the darwin 3.2.2 toolchain, verified
// by probe, same value the FCL client broker relies on). A failed call is
// deliberately not checked: without the flag the worst case is the process
// dying on a write into an RST socket, and there is no meaningful recovery
// to attempt inside a socket-handler callback
procedure ArmNoSigPipe(const AStream: TSocketStream);
var
  One: cint;
begin
  One:=1;
  FpSetSockOpt(AStream.Handle, SOL_SOCKET, SO_NOSIGPIPE, @One, SizeOf(One));
end;
{$ENDIF}

procedure TNoSigPipeSocketHandler.SetSocket(const AStream: TSocketStream);
begin
  inherited SetSocket(AStream);
  ArmIODeadline(AStream, IOTimeoutMs);
  {$IFDEF DARWIN}
  ArmNoSigPipe(AStream);
  {$ENDIF}
end;

procedure TNoSigPipeOpenSSLHandler.SetSocket(const AStream: TSocketStream);
begin
  inherited SetSocket(AStream);
  ArmIODeadline(AStream, IOTimeoutMs);
  {$IFDEF DARWIN}
  ArmNoSigPipe(AStream);
  {$ENDIF}
end;

function TNoSigPipeOpenSSLHandler.Recv(const Buffer; Count: Integer): Integer;
var
  sslErr: Integer;
  Err: ESocketError;
begin
  // A re-implementation of TOpenSSLSocketHandler.Recv (3.2.2) with the
  // expired-deadline branch fixed (td-066): stock upstream turns
  // SSL_ERROR_WANT_READ into SSL_ERROR_ZERO_RETURN whenever the cached
  // IOTimeout is positive and answers 0 (EOF), so an expired deadline looks
  // like EOF; what that costs (a truncated request processed and answered
  // 200, a lost delivery the platform does not retry) is the unit header's
  // story. Raising ESocketError(seIOTimeout) here gives the TLS read the
  // plain transport's fate - verified offline and on the deploy host, see
  // the td-066 archive
  //
  // WHY not a guard around inherited: the conversion happens INSIDE it, and
  // its 0 result is indistinguishable from a genuine close_notify EOF. FSSL
  // is reached through the public SSL property. Two private upstream fields
  // are left alone on purpose: FSSLLastError (no accessible setter) is not
  // maintained and SSLLastErrorString is not cleared - nothing in
  // ssockets/sslsockets/fphttpserver reads either after Recv
  //
  // Renegotiation, the flagged td-066 risk: on this unit's BLOCKING sockets
  // SSL_read reports WANT_READ only when its underlying recv FAILED (a
  // completed renegotiation read is application data like any other), and
  // the failure kinds are told apart by fpGetErrno, which still holds the
  // recv result here - SSL_get_error only inspects the OpenSSL error queue
  // and performs no syscall. EINTR (a signal interrupted the read) retries,
  // exactly like the EINTR loop of the plain TSocketHandler.Recv; anything
  // else with a positive deadline is treated as the expiry (on a blocking
  // socket a WANT_READ that is not an interrupted wait has no data coming).
  // The errno is read through fpGetErrno and NOT sockets.SocketError: that
  // function returns a threadvar cache the sockets unit refreshes only
  // around its own wrappers, while SSL.Read reaches recv through the C
  // library, which never writes the cache - reading it is what kept the
  // EINTR retry of 144059a dead. WANT_WRITE keeps the upstream retry loop -
  // bounded per round by SO_SNDTIMEO, the residual accept-thread strafe
  // documented at ConnectionIOTimeoutMs (td-067)
  repeat
    Result:=SSL.Read(@Buffer, Count);
    sslErr:=SSL.GetError(Result);
    if (sslErr=SSL_ERROR_WANT_READ) and (Socket.IOTimeout>0) and
       (fpGetErrno<>ESysEINTR) then
    begin
      // seIOTimeout carries the programmatic contract (the E.Code a host
      // can match); the ssockets resourcestring behind that code is about
      // SETTING a timeout ("Failed to set IO Timeout to %d") and would read
      // as the degraded-deadline warning of CreateConnection, so CreateFmt
      // supplies the message of what actually happened - this text is what
      // the receiver's OnRequestError log prints
      Err:=ESocketError.CreateFmt('TLS read hit the %d ms socket IO deadline, connection closed',
        [Socket.IOTimeout]);
      Err.Code:=seIOTimeout;
      raise Err;
    end;
  until not (sslErr in [SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE]);
  if (sslErr=SSL_ERROR_ZERO_RETURN) then
    Result:=0;
end;

// WHY the full scan instead of a plain <>: the secret is the only
// authentication barrier of the endpoint, and a plain comparison exits on
// the first differing byte, so the answer timings of the 403s could
// theoretically recover the secret byte by byte. The fold reads the WHOLE
// provided value and mixes every byte difference into one accumulator that
// also carries the length difference: nothing but the final test may
// observe a mismatch. Call-site precondition: ASecret is not empty (the
// caller skips the check without a configured secret) - without it the
// wrap-around index below would divide by zero
function SecretMatches(const AProvided, ASecret: String): Boolean;
var
  I, Diff: Integer;
begin
  Diff:=Length(AProvided) xor Length(ASecret);
  for I:=1 to Length(AProvided) do
    Diff:=Diff or (Ord(AProvided[I]) xor Ord(ASecret[((I-1) mod Length(ASecret))+1]));
  Result:=(Diff=0);
end;

// The log-forging guard (td-083), applied inside TMaxWebhookReceiver.Log.
// fpjson parser messages embed fragments of the request body
// (jsonscanner.rsj 'Invalid character at line %d, pos %d: %s',
// jsonreader.rsj 'got token "%s"'), so control bytes in a crafted body -
// CR and LF above all - would forge extra lines in the operator log and
// break the correlation with the reverse-proxy log. Every byte below 0x20
// is escaped to the visible \xNN form: the forged line break is gone while
// the diagnostics survive (the operator still sees where the parser choked
// and which byte tripped it). The record's alternative - logging only the
// ClassName plus the line/pos parsed out of the message - was declined: it
// would couple the receiver to the resourcestring texts of the FCL and
// blank the message of every non-parser exception (a failed OnUpdate
// handler, say). Bytes >= 0x20 pass through unchanged, including the
// non-ASCII ones: they cannot break the line structure of the log
function SanitizeLogText(const AMsg: String): String;
var
  I, J, ResLen: Integer;
  Hex: String;
begin
  // Two byte passes with one exact allocation instead of concatenation in
  // the loop: pass 1 sizes the result (an escaped byte costs 4 chars
  // against 1), pass 2 fills it
  ResLen:=Length(AMsg);
  for I:=1 to Length(AMsg) do
    if Ord(AMsg[I])<32 then
      Inc(ResLen, 3);
  SetLength(Result, ResLen);
  J:=1;
  for I:=1 to Length(AMsg) do
  begin
    if Ord(AMsg[I])>=32 then
    begin
      Result[J]:=AMsg[I];
      Inc(J);
    end
    else
    begin
      Hex:=IntToHex(Ord(AMsg[I]), 2);
      Result[J]:='\';
      Result[J+1]:='x';
      Result[J+2]:=Hex[1];
      Result[J+3]:=Hex[2];
      Inc(J, 4);
    end;
  end;
end;

function JSONBodyTooDeep(const ABody: String): Boolean;
var
  I, Depth: Integer;
  InString: Boolean;
begin
  Result:=False;
  Depth:=0;
  InString:=False;
  I:=1;
  while I<=Length(ABody) do
  begin
    if InString then
    begin
      // A backslash skips the next character: \" must not close the string,
      // \\ must not skip a second one
      if ABody[I]='\' then
        Inc(I)
      else if ABody[I]='"' then
        InString:=False;
    end
    else
      case ABody[I] of
        '"':
          InString:=True;
        '[', '{':
          begin
            Inc(Depth);
            if Depth>MaxJSONDepth then
              Exit(True);
          end;
        ']', '}':
          // Guard against malformed bodies closing more than they opened:
          // depth only matters as an upper bound here
          if Depth>0 then
            Dec(Depth);
      end;
    Inc(I);
  end;
end;

{ TMaxWebhookReceiver }

procedure TMaxWebhookReceiver.Log(AEventType: TEventType; const AMsg: String);
begin
  // Best-effort log, the ErrorMessage convention of the library: a raising
  // user callback must not break the 200 delivery contract it reports
  // through (the swallow in maxsendertypes.ApiCall is deliberate for the
  // same reason). Fires from several thread contexts, not only the request
  // threads - the canonical list is the OnLog property comment
  if not Assigned(FOnLog) then
    Exit;
  // The log-forging guard of td-083 lives HERE, not at the callers: one
  // choke point keeps the "every logged text is sanitized" invariant
  // structural instead of maintaining it by enumerating the call sites -
  // any current or future caller that logs embedded exception text (the
  // OnConnectionLog degradation warning is already one) is covered
  // automatically. SanitizeLogText is idempotent, so texts that carried no
  // control bytes - the constants and the Format calls with numbers - come
  // out byte for byte unchanged
  try
    FOnLog(Self, AEventType, SanitizeLogText(AMsg));
  except
  end;
end;

procedure TMaxWebhookReceiver.HandleServerLog(ASender: TObject;
  AEventType: TEventType; const AMsg: String);
begin
  Log(AEventType, AMsg);
end;

procedure TMaxWebhookReceiver.GetSocketHandler(Sender: TObject;
  const UseSSL: Boolean; out AHandler: TSocketHandler);
var
  PlainHandler: TNoSigPipeSocketHandler;
  Handler: TNoSigPipeOpenSSLHandler;
begin
  // Requested per accepted connection, and UseSSL here is the server-level
  // UseSSL of that moment: a plain connection (UseSSL:=False - a reverse
  // proxy in front, or the offline tests) gets a plain handler - building
  // the OpenSSL one unconditionally would fail the whole accept loop on a
  // host where the OpenSSL library does not load. The TLS handler is taken
  // over by the connection and freed together with itself. The PEM files
  // are read and the SSL context is built by the OpenSSL layer on EVERY
  // accepted connection (3.2.2 has no keep-alive, so this is a per-request
  // cost): accepted as the deliberate trade against the platform throttling
  // rapid new TLS connections, with the RSA handshake dominating it - do not
  // add a context cache without measurements. TSSLData.Value expects DER
  // bytes, so for PEM files FileName is the supported way. The KEY must be
  // RSA: an ECDSA one resets the handshake on the ClientHello with an empty
  // log (see the unit comment)
  if not UseSSL then
  begin
    PlainHandler:=TNoSigPipeSocketHandler.Create;
    // The configured deadline rides every handler instance: SetSocket arms
    // it on the raw accepted socket (see IOTimeoutMs)
    PlainHandler.IOTimeoutMs:=FConnectionIOTimeoutMs;
    AHandler:=PlainHandler;
    Exit;
  end;
  Handler:=TNoSigPipeOpenSSLHandler.Create;
  Handler.IOTimeoutMs:=FConnectionIOTimeoutMs;
  Handler.CertificateData.Certificate.FileName:=FCertFile;
  Handler.CertificateData.PrivateKey.FileName:=FKeyFile;
  Handler.SSLType:=stTLSv1_2;
  AHandler:=Handler;
end;

procedure TMaxWebhookReceiver.HandleRequestError(Sender: TObject;
  E: Exception);
const
  // The exact text of the fphttpserver 3.2.2 fault raised for a connection
  // that delivered NO request data (the client connected and closed: a
  // health probe, a port scanner). ReadRequestHeaders exits silently on the
  // empty request line, but InitRequestVars afterwards still raises EHTTP
  // because no method arrived - the one per-connection fault that is pure
  // noise, not a delivery or a TLS failure. Matched by the full message
  // text: the resourcestring behind it is declared in httpdefs'
  // IMPLEMENTATION section and cannot be referenced by name. If the text
  // ever drifts, the filter degrades to logging these again - visible in
  // the test suite (EmptyBodyAnswers200 pins a log-free receiver), not a
  // silently missed failure
  NoRequestMethodMsg = 'No REQUEST_METHOD passed from server.';
begin
  if E.Message=NoRequestMethodMsg then
    Exit;
  // Best-effort like every log here: the 200 delivery contract must not
  // break through the very path that reports why a connection went wrong.
  // This hook sees every unexpected exception of an established connection,
  // its text is not guaranteed to be free of peer-controlled fragments -
  // Log sanitizes it on the way out (td-083)
  Log(etError, E.ClassName+': '+E.Message);
end;

procedure TMaxWebhookReceiver.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Tree: TJSONData;
  Update: TMaxUpdateObj;
begin
  // The endpoint is public by construction: the URL is the only barrier and
  // anyone who learns it can POST a forged update on behalf of the bot. When
  // a secret is configured, the platform (which received it in the
  // subscription call) echoes it in the X-Max-Bot-Api-Secret header of every
  // delivery: a request with another value - or without the header at all -
  // is not a platform delivery, so it is answered 403 with an empty body
  // before any of the processing below runs on it
  if (FSecret<>EmptyStr) and
     (not SecretMatches(ARequest.GetCustomHeader('X-Max-Bot-Api-Secret'),
       FSecret)) then
  begin
    Log(etWarning, '[Webhook] request with a wrong X-Max-Bot-Api-Secret, rejected');
    AResponse.Code:=403;
    AResponse.Content:=EmptyStr;
    Exit;
  end;
  Update:=Nil;
  try
    try
      // 0 means "no limit" (a negative value cannot get here - Start
      // rejects it): the guard keeps the unlimited mode expressible, 0
      // would otherwise silently turn the receiver into "ignore every
      // non-empty body" while still answering 200
      if (FMaxBodySize>0) and (Length(ARequest.Content)>FMaxBodySize) then
        Log(etWarning, Format('Webhook body of %d bytes exceeds the %d bytes limit, ignored',
          [Length(ARequest.Content), FMaxBodySize]))
      else if (ARequest.Content<>EmptyStr) and JSONBodyTooDeep(ARequest.Content) then
        Log(etWarning, Format('Webhook body nests deeper than the %d level limit, ignored',
          [MaxJSONDepth]))
      else if ARequest.Content<>EmptyStr then
      begin
        // The body is a single Update object (not the {"updates":[...]} envelope
        // of long polling). TMaxObj.Create takes ownership of the parsed tree
        // and frees it in its destructor, so the tree is passed directly: fpjson
        // copies every string while parsing, nothing here keeps a reference into
        // the request buffer freed after this handler returns
        Tree:=GetJSON(ARequest.Content);
        if Tree is TJSONObject then
        begin
          Update:=TMaxUpdateObj.Create(TJSONObject(Tree));
          if Assigned(FOnUpdate) then
            FOnUpdate(Self, Update);
        end
        else
        begin
          // Freed before the log: a failed log write must not leak the tree,
          // the outer except below would otherwise swallow the exception
          Tree.Free;
          Log(etWarning, 'Webhook body is not a JSON object, ignored');
        end;
      end;
    except
      // A malformed body or a failed handler must not become a non-200 reply:
      // the platform treats any non-200 as a failed delivery and retries it
      // for up to 8 hours - log here and answer 200 anyway. The parser
      // messages embed body fragments; Log sanitizes the message on the
      // way out (td-083)
      on E: Exception do
        Log(etError, '[Webhook] request failed: ['+E.ClassName+'] '+E.Message);
    end;
  finally
    // The receiver owns the update until this handler returns; the OnUpdate
    // handler copied what it needed
    Update.Free;
  end;
  AResponse.Code:=200;
  AResponse.ContentType:='application/json';
  AResponse.Content:='{}';
end;

procedure TMaxHTTPServer.DropFailedSocket;
begin
  FreeServerSocket;
end;

function TMaxHTTPServer.CreateConnection(Data: TSocketStream): TFPHTTPConnection;
begin
  // Normally a second, harmless write of the value ArmIODeadline has
  // already armed on the raw socket (TSocketStream.Create reads the socket
  // options BEFORE SetSocket runs, so IOTimeout still holds the pre-arm
  // default here and this set always executes). WHY keep the second set
  // instead of dropping it as redundant: it syncs the handler's IOTimeout
  // CACHE with the kernel - ArmIODeadline writes the socket options behind
  // the cache's back, and the OpenSSL transport branches on the cached
  // field: stock TOpenSSLSocketHandler.Recv turned a positive cache into a
  // silent EOF on WANT_READ, and the Recv override of
  // TNoSigPipeOpenSSLHandler keys its deadline raise on the same cache
  // (td-066); the write also insures a future GetSocketHandler branch that
  // forgets to call ArmIODeadline. Do not remove the write or add a
  // getsockopt skip guard - either changes the TLS-path behavior. The
  // second reason to keep it, and the reason for best-effort: a failed
  // setsockopt on ONE connection must not kill the accept loop - the
  // raised ESocketError would surface from StartAccepting and leave Start
  // with its honest class and message (td-068), stopping the host, with
  // the accepted stream leaked. Serving the connection
  // without a deadline is the graceful degradation, symmetric with
  // ArmNoSigPipe; the warning keeps it visible. The callback is invoked
  // best-effort for the same accept-loop reason - see the OnConnectionLog
  // comment
  try
    Data.IOTimeout:=EffectiveIOTimeoutMs(IOTimeoutMs);
  except
    on E: ESocketError do
      if Assigned(OnConnectionLog) then
        try
          OnConnectionLog(Self, etWarning, 'IO deadline not set on a connection: '+E.Message);
        except
        end;
  end;
  Result:=inherited CreateConnection(Data);
end;

function TMaxWebhookReceiver.GetActive: Boolean;
begin
  // True from the moment the listening socket object exists (the accept
  // loop may still be starting) until the Active:=True call has returned;
  // the same value the Stop loop waits on
  Result:=FServer.Active;
end;

constructor TMaxWebhookReceiver.Create;
begin
  inherited Create;
  FServer:=TMaxHTTPServer.Create(nil);
  // Server-side degradation warnings (a failed IO-deadline set on one
  // connection) go through the receiver's best-effort Log, so they reach the
  // user OnLog without ever breaking the accept loop
  TMaxHTTPServer(FServer).OnConnectionLog:=@HandleServerLog;
  // Every connection is served in its own thread: a slow handler delays its
  // own delivery, not the whole endpoint
  FServer.Threaded:=True;
  FServer.UseSSL:=True;
  // WHY: with a plain blocking accept the server loop cannot be stopped at
  // all on a quiet server (ssockets retries an interrupted accept forever
  // and a stopped loop never re-checks its flag while blocked). The idle
  // timeout moves the wait into select rounds that re-check the accepting
  // flag, which makes Stop effective within AcceptIdleMs
  FServer.AcceptIdleTimeout:=AcceptIdleMs;
  FServer.OnRequest:=@HandleRequest;
  FServer.OnGetSocketHandler:=@GetSocketHandler;
  // fphttpserver routes every unexpected exception of an ESTABLISHED
  // connection here: IO errors, the IO deadline on either transport (plain:
  // EHTTPServer; TLS: the ESocketError(seIOTimeout) of the Recv override,
  // td-066), protocol-level EHTTP. TLS handshake failures never reach the
  // hook - a
  // failed handshake is absorbed silently in TInetServer.SockToStream (the
  // documented ECDSA "empty log" symptom is exactly that silence, this hook
  // does not cure it), and a handshake killed by the IO deadline dies the
  // same way. A connection that delivered no request line DOES arrive, as
  // the EHTTP "No REQUEST_METHOD" raised by InitRequestVars - filtered by
  // the text match in HandleRequestError. The server wraps the callback in
  // try..except, and Log is best-effort itself
  FServer.OnRequestError:=@HandleRequestError;
  // Max requires public HTTPS on port 443 for a webhook endpoint
  FPort:=443;
  FUseSSL:=True;
  FMaxBodySize:=DefaultMaxBodySize;
  FConnectionIOTimeoutMs:=DefaultConnectionIOTimeoutMs;
end;

destructor TMaxWebhookReceiver.Destroy;
begin
  // Stop first: in-flight request threads finish their requests and are
  // reaped by the server destructor, which runs before the fields the
  // request handlers read are freed
  if FServer.Active then
    Stop;
  FServer.Free;
  inherited Destroy;
end;

procedure TMaxWebhookReceiver.Start;
begin
  if FServer.Active then
    Exit;
  // No PEM files - no HTTPS endpoint: fail fast with a clear message
  // instead of a cryptic SSL error on the first request. EMaxConfig: a host
  // configuration error, the class the library raises for a broken
  // configuration (td-013) - receivers catch it before Exception and stop
  // visibly. The files are probed for existence too: a mistyped path would
  // otherwise reset every TLS handshake with no clue in the log
  if FUseSSL then
  begin
    if (FCertFile=EmptyStr) or (FKeyFile=EmptyStr) then
      raise EMaxConfig.Create('CertFile/KeyFile are not set: the webhook receiver needs a PEM certificate pair');
    if not FileExists(FCertFile) then
      raise EMaxConfig.Create('CertFile "'+FCertFile+'" does not exist');
    if not FileExists(FKeyFile) then
      raise EMaxConfig.Create('KeyFile "'+FKeyFile+'" does not exist');
  end;
  // 0 is the documented "no limit" mode; a negative limit is a
  // configuration error - reject it instead of silently acting as the
  // unlimited mode it does not mean
  if FMaxBodySize<0 then
    raise EMaxConfig.Create(Format('MaxBodySize %d is negative: set 0 for "no limit" or a positive byte count', [FMaxBodySize]));
  // A secretless receiver accepts forged updates from anyone who finds the
  // URL: legitimate behind a filtering proxy, but a host binding all
  // interfaces (or an explicit public address) must say so in the log - a
  // warning, not an exception, the secretless deploy is supported
  if (FSecret=EmptyStr) and (FHost<>'127.0.0.1') and (FHost<>'localhost') then
    Log(etWarning, 'Secret is not set: the receiver accepts unauthenticated deliveries from anyone, set Secret to require the platform echo header');
  // The configuration is read by request threads with no synchronization:
  // this snapshot is the only handover, changes on a live receiver are not
  // supported (see the unit comment). Address lives on the implementation
  // subclass only (published there), hence the cast
  FServer.Port:=FPort;
  TMaxHTTPServer(FServer).Address:=FHost;
  // The deadline rides the same snapshot: CreateConnection writes it into
  // every fresh connection stream after the handshake (see the field)
  TMaxHTTPServer(FServer).IOTimeoutMs:=FConnectionIOTimeoutMs;
  FServer.UseSSL:=FUseSSL;
  try
    // Blocks in the accept loop until Stop: with Threaded:=True the loop
    // runs on the CALLING thread and Active:=True returns only when the
    // server is stopped
    FServer.Active:=True;
  except
    // The bind happens synchronously on the calling thread before the
    // accept loop starts (TInetServer.Bind inside Active:=True): a port
    // conflict must stop the host visibly, not kill it silently - EMaxConfig
    // with the port, by design (td-013). seBindFailed identifies that phase
    // unambiguously: within this window it is raised by exactly one place,
    // TInetServer.Bind (the EMaxConfig contract keeps the original message,
    // which already carries the bind text). Any OTHER ESocketError of the
    // window - socket creation, listen, an accept-loop failure like EMFILE
    // under load - is NOT a bind problem: renaming it into "bind failed"
    // sent incident response after the wrong port, so it re-raises with its
    // honest class, code and message and the host stops on it (td-068;
    // continuing the accept loop is not reachable without an fphttpserver
    // fork - DoAcceptError fixes aeaRaise while Active). Whatever the
    // failure, it also left
    // the half-built listening socket object in place (the success path
    // frees it only after the accept loop returns): drop it, or Active
    // would report a receiver that is down and unstartable
    on E: ESocketError do
    begin
      TMaxHTTPServer(FServer).DropFailedSocket;
      if E.Code=seBindFailed then
        raise EMaxConfig.Create(Format('Webhook bind failed on port %d: %s',
          [FPort, E.Message]))
      else
        raise;
    end;
    on E: Exception do
    begin
      // Not a socket failure: the cleanup is the same, the original
      // exception keeps its class
      TMaxHTTPServer(FServer).DropFailedSocket;
      raise;
    end;
  end;
end;

procedure TMaxWebhookReceiver.Stop;
begin
  // WHY the loop, not a single stop: a stop landing between the accept loop
  // start and the moment ssockets raises its accepting flag would lose a
  // single stop call (ssockets: StartAccepting sets the flag, StopAccepting
  // only clears it - the later start wins). The stop is repeated until the
  // server reports inactive; on an already stopped server the call is a
  // no-op (SetActive exits when the state does not change), so repetition is
  // harmless. The cost is at most one AcceptIdleMs of extra shutdown latency
  while FServer.Active do
  begin
    FServer.Active:=False;
    Sleep(AcceptIdleMs);
  end;
end;

initialization
  {$IFDEF LINUX}
  // WHY ignore SIGPIPE process-wide: the connection threads write answers
  // into sockets the client may have reset; Linux ssockets sends with flags
  // 0 (no MSG_NOSIGNAL) and has no per-socket SO_NOSIGPIPE, so the default
  // disposition would kill the whole process on the first such write.
  // Ignored, the write returns EPIPE and the connection moves on. WARNING:
  // this is process-wide and permanent - a host that needs the default
  // SIGPIPE disposition must reinstall it after uses (the Webhook example
  // only survived without it because it linked maxfclhttpclientbroker, which
  // does the same). On darwin no process-wide change happens: the connection
  // socket handlers arm per-socket SO_NOSIGPIPE (the TNoSigPipe* overrides).
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}

end.
