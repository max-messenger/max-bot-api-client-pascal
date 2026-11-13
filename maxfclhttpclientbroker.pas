unit maxfclhttpclientbroker;

{$mode objfpc}{$H+}

interface

{ Requires FPC 3.2.0+: TSSLSocketHandler.GetDefaultHandler and CertificateData
  used below first appeared in 3.2.0. Also requires an OpenSSL exporting
  X509_check_host - and X509_check_ip_asc when the endpoint is addressed by an
  IP literal: without the needed symbol every verified HTTPS request fails
  closed with an exception. The ExplSSL branch for FPC 3.0.x is gone:
  it could not compile even on 3.0.x, so this unit never supported it. }

uses
  Classes, SysUtils, ssockets, maxbasehttpclient, fphttpclient;

type

  { TFCLHTTPClient }

  TFCLHTTPClient=class(TBaseHTTPClient)
  private
    FHTTPClient: TFPHTTPClient;
    FSSLCAFile: String;
    FSSLVerifyCert: Boolean;
    { Invariant: FSSLExpectedHost is not reset between requests, so every
      request verb must call SetExpectedHost first - otherwise the host check
      would run against the host of the previous request }
    FSSLExpectedHost: String;
    { Set together with FSSLExpectedHost (same invariant): True when the host
      is an IP literal - a dotted quad or contains ':' - so the certificate is
      matched by X509_check_ip_asc instead of X509_check_host }
    FSSLExpectedHostIsIP: Boolean;
    procedure CheckCertificateHost(Sender: TObject; var Allow: Boolean);
    procedure PrepareHeaders;
    procedure SetExpectedHost(const AURL: String);
    procedure HttpClientGetSocketHandler(Sender: TObject; const UseSSL: Boolean;
      out AHandler: TSocketHandler);
  protected
    function GetAllowRedirect: Boolean; override;
    function GetCookies: TStrings; override;
    function GetHTTPProxyHost: String; override;
    function GetHTTPProxyPassword: String; override;
    function GetHTTPProxyPort: Word; override;
    function GetHTTPProxyUsername: String; override;
    function GetInternalHTTPClient: TObject; override;
    function GetIOTimeout: Integer; override;
    function GetRequestBody: TStream; override;
    function GetRequestHeaders: TStrings; override;
    function GetResponseHeaders: TStrings; override;
    function GetResponseStatusCode: Integer; override;
    function GetResponseStatusText: String; override;
    function GetSSLCAFile: String; override;
    function GetSSLVerifyCert: Boolean; override;
    procedure SetAllowRedirect(AValue: Boolean); override;
    procedure SetCookies(AValue: TStrings); override;
    procedure SetHTTPProxyHost(AValue: String); override;
    procedure SetHTTPProxyPassword(AValue: String); override;
    procedure SetHTTPProxyPort(AValue: Word); override;
    procedure SetHTTPProxyUsername(AValue: String); override;
    procedure SetIOTimeout(AValue: Integer); override;
    procedure SetRequestBody(AValue: TStream); override;
    procedure SetRequestHeaders(AValue: TStrings); override;
    procedure SetSSLCAFile(AValue: String); override;
    procedure SetSSLVerifyCert(AValue: Boolean); override;
  public
    procedure AddHeader(const AHeader, AValue: String); override;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class function EncodeUrlElement(S: String): String; override;
    procedure FileFormPost(const AURL: string; FormData: TStrings; AFieldName, AFileName: string;
      const Response: TStream); override;    
    function FilesFormPost(const AURL: string; FormData: TStrings; const AFiles: TStrings): String; override;
    function StreamsFormPost(const AURL: string; FormData: TStrings; const AFiles: TStrings): String; override;
    function FormPost(const URL: string; FormData: TStrings): String; override;
    function Get(const AUrl: String): String; override;
    function Post(const URL: string): String; override;
    function Put(const URL: string): String; override;
    function Delete(const URL: string): String; override;
    procedure StreamFormPost(const AURL: string; FormData: TStrings; const AFieldName,
      AFileName: string; const AStream: TStream; const Response: TStream); override;
  end;

{$IF FPC_FULLVERSION <= 30004}
{ TRawByteStringStream }

  TRawByteStringStream = Class(TBytesStream)
  public
    Constructor Create (const aData : RawByteString); overload;
    function DataString: RawByteString;

    function ReadString(Count: Longint): RawByteString;
    procedure WriteString(const AString: RawByteString);
  end;
{$ENDIF}

implementation

uses
  sslsockets, opensslsockets, fpopenssl, openssl, uriparser, dynlibs, ctypes
  {$IFDEF UNIX}
  , baseunix // fpSelect liveness probe of the reused socket; Linux: SIGPIPE
  {$ENDIF}
  {$IFDEF DARWIN}
  , sockets // SO_NOSIGPIPE / FpSetSockOpt in TNoSigPipeOpenSSLHandler.SetSocket
  {$ENDIF}
  ;

Const
  CRLF = #13#10;

type
  { The openssl unit of FPC 3.2.2 does not bind X509_check_host - resolve it
    from the already loaded libcrypto at runtime. }
  TX509CheckHost=function(x: PX509; chk: PAnsiChar; chklen: SizeUInt;
    flags: cUInt; peername: PPAnsiChar): cInt; cdecl;
  { The iPAddress-SAN matcher for IP-literal hosts - the openssl unit does not
    bind it either; int X509_check_ip_asc(X509 *x, const char *ipasc,
    unsigned int flags) per openssl/x509.h. }
  TX509CheckIPAsc=function(x: PX509; ipasc: PAnsiChar; flags: cUInt): cInt; cdecl;
  { Same for the peer certificate accessor: libssl of OpenSSL 3 only exports the
    new name, so the openssl unit's own wrapper returns nil there. }
  TSSLGetPeerCertificate=function(ssl: PSSL): PX509; cdecl;

  { SSL socket handler that arms SO_NOSIGPIPE on the socket fd right after it
    is created and before Connect (SetSocket is called from TSocketStream.Create,
    so the flag is armed before the first byte leaves the process). WHY: with
    keep-alive the client can write into a connection the server has already
    reset, and on darwin a write into such a socket kills the whole process
    with SIGPIPE - ssockets sends with flags 0, neither MSG_NOSIGNAL nor
    SO_NOSIGPIPE exist by default. On Linux the override is a pass-through:
    that platform has no per-socket SO_NOSIGPIPE, the unit initialization
    ignores SIGPIPE process-wide instead. }
  TNoSigPipeOpenSSLHandler=class(TOpenSSLSocketHandler)
  public
    procedure SetSocket(const AStream: TSocketStream); override;
  end;

  { TFPHTTPClient with the 3.2.2 keep-alive defects fixed: bounded retry,
    body-safe re-send, no silent duplicate of a non-idempotent request and
    no zombie socket left behind after a transport error. The live socket is
    reached through the handler captured in GetSocketHandler (FSocket itself
    is private in TFPCustomHTTPClient): TSocketHandler.Socket is public. }
  TMaxKeepAliveHTTPClient=class(TFPHTTPClient)
  private
    { The handler of the current connection; refreshed on every connect and
      dropped on disconnect - the handler dies together with its stream }
    FLastHandler: TSocketHandler;
  protected
    procedure DoKeepConnectionRequest(const AURI: TURI; const AMethod: string;
      AStream: TStream; const AAllowedResponseCodes: array of Integer;
      AHeadersOnly, AIsHttps: Boolean); override;
    function ReadResponse(Stream: TStream;
      const AllowedResponseCodes: array of Integer;
      HeadersOnly: Boolean=False): Boolean; override;
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;
    procedure DisconnectFromServer; override;
    { EOF-before-status retry is safe only for bodyless idempotent verbs }
    class function CanAutoRetry(const AMethod: string): Boolean;
    { False = the captured connection may still be alive; True = do not write
      into it. Cannot always decide (no captured handler, plain HTTP path) -
      then False, the request degrades to the stock behavior }
    function ReusedSocketIsDead: Boolean;
  public
    { Drops the socket so the next request reconnects; safe to call twice }
    procedure ResetTransport;
  end;

function ResolveX509CheckHost: TX509CheckHost;
// Not cached: a lookup costs microseconds next to the per-request handshake,
// and a unit-level cache would be mutable state shared by all threads.
begin
  Result:=Nil;
  // X509_* lives in libcrypto, which openssl.pas keeps in SSLUtilHandle
  // (the same handle it binds X509_free from).
  if SSLUtilHandle<>0 then
    Result:=TX509CheckHost(GetProcAddress(SSLUtilHandle,'X509_check_host'));
  if (Result=Nil) and (SSLLibHandle<>0) then
    Result:=TX509CheckHost(GetProcAddress(SSLLibHandle,'X509_check_host'));
end;

function ResolveGetPeerCertificate: TSSLGetPeerCertificate;
begin
  Result:=Nil;
  if SSLLibHandle<>0 then begin
    Result:=TSSLGetPeerCertificate(GetProcAddress(SSLLibHandle,'SSL_get_peer_certificate'));
    if Result=Nil then
      Result:=TSSLGetPeerCertificate(GetProcAddress(SSLLibHandle,'SSL_get1_peer_certificate'));
  end;
end;

function ResolveX509CheckIPAsc: TX509CheckIPAsc;
// Not cached, same reasoning as ResolveX509CheckHost above.
begin
  Result:=Nil;
  // X509_* lives in libcrypto, which openssl.pas keeps in SSLUtilHandle
  // (the same handle it binds X509_free from).
  if SSLUtilHandle<>0 then
    Result:=TX509CheckIPAsc(GetProcAddress(SSLUtilHandle,'X509_check_ip_asc'));
  if (Result=Nil) and (SSLLibHandle<>0) then
    Result:=TX509CheckIPAsc(GetProcAddress(SSLLibHandle,'X509_check_ip_asc'));
end;

function IsIPv4Literal(const S: String): Boolean;
// Exactly four dot-separated numeric groups, each 0..255: a dotted-quad IPv4
// literal. Everything else is treated as a DNS name - a DNS name missed here
// would only shift the failure into the IP branch (X509_check_ip_asc does not
// match DNS names), never weaken the host check.
var
  I, Start, Octets: Integer;
  Value: Int64;
begin
  Result:=False;
  Octets:=0;
  I:=1;
  while I<=Length(S) do begin
    Start:=I;
    while (I<=Length(S)) and (S[I] in ['0'..'9']) do
      Inc(I);
    if (I=Start) or (I-Start>3) then
      Exit;
    Val(Copy(S,Start,I-Start),Value);
    if Value>255 then
      Exit;
    Inc(Octets);
    // A dot separates groups, so it is only valid with a next group after it:
    // a trailing dot ('1.2.3.4.') must fail the check, not be consumed here
    // (consuming it would let the final I>Length(S) accept '1.2.3.4.').
    if (I<Length(S)) and (S[I]='.') then
      Inc(I)
    else
      Break;
  end;
  Result:=(Octets=4) and (I>Length(S));
end;

{$IF FPC_FULLVERSION <= 30004}
{ TRawByteStringStream }

constructor TRawByteStringStream.Create(const aData: RawByteString);
begin
  Inherited Create;
  If Length(aData)>0 then
    begin
    WriteBuffer(aData[1],Length(aData));
    Position:=0;
    end;
end;

function TRawByteStringStream.DataString: RawByteString;
begin
  Result:='';
  SetLength(Result,Size);
  if Size>0 then
    Move(Memory^, Result[1], Size);
end;

function TRawByteStringStream.ReadString(Count: Longint): RawByteString;
Var
  NewLen : Longint;

begin
  NewLen:=Size-Position;
  If NewLen>Count then NewLen:=Count;
  Result:='';
  if NewLen>0 then
    begin
    SetLength(Result, NewLen);
    Move(Bytes[Position],Result[1],NewLen);
    Position:=Position+Newlen;
    end;
end;

procedure TRawByteStringStream.WriteString(const AString: RawByteString);
begin
  if Length(AString)>0 then
    WriteBuffer(AString[1],Length(AString));
end;
{$ENDIF}

{ TNoSigPipeOpenSSLHandler }

procedure TNoSigPipeOpenSSLHandler.SetSocket(const AStream: TSocketStream);
{$IFDEF DARWIN}
var
  One: cint;
{$ENDIF}
begin
  inherited SetSocket(AStream);
  {$IFDEF DARWIN}
  // SO_NOSIGPIPE comes from the sockets unit (4130 on the darwin 3.2.2
  // toolchain, verified by probe). A failed call is deliberately not checked:
  // without the flag the worst case is the pre-keep-alive behavior (the
  // process dies on a write into an RST socket), there is no meaningful
  // recovery to attempt inside a socket-handler callback
  One:=1;
  FpSetSockOpt(AStream.Handle, SOL_SOCKET, SO_NOSIGPIPE, @One, SizeOf(One));
  {$ENDIF}
end;

{ TMaxKeepAliveHTTPClient }

class function TMaxKeepAliveHTTPClient.CanAutoRetry(const AMethod: string
  ): Boolean;
begin
  // EOF before a status line leaves unknown whether the server processed the
  // request, so only bodyless idempotent verbs may be repeated automatically:
  // a silent repeat of POST/PUT would be a silent duplicate of e.g.
  // POST /messages - those surface the failure to the caller instead
  Result:=(CompareText(AMethod,'GET')=0) or (CompareText(AMethod,'HEAD')=0)
    or (CompareText(AMethod,'DELETE')=0);
end;

function TMaxKeepAliveHTTPClient.GetSocketHandler(const UseSSL: Boolean
  ): TSocketHandler;
begin
  // GetSocketHandler runs from ConnectToServer only, so the capture is
  // refreshed on every (re)connect; the broker's OnGetSocketHandler (TLS
  // policy + TNoSigPipeOpenSSLHandler) is applied by the inherited call
  Result:=inherited GetSocketHandler(UseSSL);
  FLastHandler:=Result;
end;

procedure TMaxKeepAliveHTTPClient.DisconnectFromServer;
begin
  inherited DisconnectFromServer;
  // The handler is destroyed together with its stream (TSocketStream.Destroy
  // -> FreeAndNil(FHandler)): the reference must not survive the disconnect
  FLastHandler:=nil;
end;

procedure TMaxKeepAliveHTTPClient.ResetTransport;
begin
  // The one uniform drop for every path of this class: the next request
  // reconnects. FreeAndNil in DisconnectFromServer is nil-safe, calling it
  // twice is harmless (the failed-connect path is already clean)
  DisconnectFromServer;
end;

function TMaxKeepAliveHTTPClient.ReusedSocketIsDead: Boolean;
var
  FDs: TFDSet;
  TV: TTimeVal;
  H: Longint;
begin
  // No captured handler (never connected, or plain HTTP without our handler):
  // treat as alive - the request behaves exactly like the stock client and
  // the error paths below still clean up
  Result:=False;
  if not Assigned(FLastHandler) then
    Exit;
  if not Assigned(FLastHandler.Socket) then
    Exit(True);
  H:=FLastHandler.Socket.Handle;
  fpFD_Zero(FDs);
  fpFD_Set(H, FDs);
  TV.tv_sec:=0;
  TV.tv_usec:=0;
  // A reused socket readable when no response is pending means the peer has
  // closed it (EOF) or sent garbage: do not write into it. No response can be
  // pending here - ReadResponse drains the body of every previous answer
  // (Content-Length/chunked/till-EOF) and there is no pipelining; a false
  // positive costs one reconnect, not a failed request
  Result:=(fpSelect(H+1, @FDs, nil, nil, @TV)>0);
end;

procedure TMaxKeepAliveHTTPClient.DoKeepConnectionRequest(const AURI: TURI;
  const AMethod: string; AStream: TStream;
  const AAllowedResponseCodes: array of Integer; AHeadersOnly, AIsHttps: Boolean
  );
var
  T: Boolean;
  CHost: string;
  CPort: Word;
  Reconnects: Integer;
begin
  // The 3.2.2 stock loop with four fixes: a liveness probe before reusing a
  // connection, a rewind of RequestBody before every send, a reconnect limit
  // and an idempotency filter on the EOF retry, and no zombie socket after a
  // transport exception (the stock loop leaves FSocket assigned, every
  // following request then fails on the dead socket forever)
  // The stock ExtractHostPort helper is private in 3.2.2 - the same logic
  // inline, protected ProxyActive/Proxy carry it
  if ProxyActive then begin
    CHost:=Proxy.Host;
    CPort:=Proxy.Port;
  end else begin
    CHost:=AURI.Host;
    CPort:=AURI.Port;
  end;
  T:=False;
  Reconnects:=0;
  repeat
    // A server that closed the idle connection (FIN) must not surface as a
    // failed write: reconnect silently, the request goes out on a fresh
    // connection and succeeds on the first attempt
    if ReusedSocketIsDead then
      ResetTransport;
    if not IsConnected then
      ConnectToServer(CHost,CPort,AIsHttps);
    try
      // Rewind before every send: the EOF retry below would otherwise go out
      // with Content-Length=N and 0 body bytes (3.2.2 never rewinds)
      if Assigned(RequestBody) then
        RequestBody.Position:=0;
      if not Terminated then
        SendRequest(AMethod,AURI);
      if not Terminated then
        begin
        T:=ReadResponse(AStream,AAllowedResponseCodes,AHeadersOnly);
        If Not T Then
          begin
          // EOF before a status line: the request may have been processed
          if not CanAutoRetry(AMethod) then
            raise EHTTPClient.Create('connection closed before a response arrived: '
              +AMethod+' is not retried automatically');
          // The reconnect limit replaces the stock unlimited loop (a server
          // that closes every connection before answering would spin forever)
          if Reconnects>=1 then
            raise EHTTPClient.Create('connection closed before a response arrived'
              +' after 1 reconnect');
          Inc(Reconnects);
          ReconnectToServer(CHost,CPort,AIsHttps);
          end;
        end;
    except
      // After ANY exception (write into a reset socket, read failure; a
      // failed connect is already clean and a repeated disconnect is harmless)
      ResetTransport;
      raise;
    end;
    // Normal completion - stock semantics: close only when the request asked
    // for it (request-level Connection: close) or the client was terminated.
    // A response-level Connection: close is handled in ReadResponse below
    if HasConnectionClose or Terminated then
      ResetTransport;
  until T or Terminated;
end;

function TMaxKeepAliveHTTPClient.ReadResponse(Stream: TStream;
  const AllowedResponseCodes: array of Integer; HeadersOnly: Boolean): Boolean;
begin
  Result:=inherited ReadResponse(Stream, AllowedResponseCodes, HeadersOnly);
  // 3.2.2 honors only a request-level Connection: close: a server answering
  // with Connection: close would otherwise keep the socket in the pool and
  // the next request would spend a roundtrip discovering the EOF
  if Result
    and (CompareText(TFPCustomHTTPClient.GetHeader(ResponseHeaders,'Connection'),
      'close')=0) then
    ResetTransport;
end;

{ TFCLHTTPClient }

const
  // td-077: the recognizable suffix stays (a body dump stays attributable to
  // this broker in the logs); the uniqueness lives in the random part
  cBoundarySuffix = '_multipart_boundary';

{ A fresh multipart boundary: 32 hex digits from the OS CSPRNG (CreateGUID is
  a v4 UUID there) plus the fixed suffix. WHY not Randomize+Random: the stock
  Format('%.8x_multipart_boundary',[Random($ffffff)]) pattern (fphttpclient.pp)
  has no Randomize anywhere in the process - the first value repeated between
  runs, and a boundary predictable in advance lets a file crafted against it
  inject multipart parts (td-077). The GUID carries 122 random bits unknown
  until the call. CreateGUID returns a status - checked (the class
  convention, see maxsendertypes.pas): a failure raises instead of degrading
  to a weaker generator - a silently predictable boundary would reinstate the
  exact td-077 vector this code exists to close }
function NewMultipartBoundary: String;
var
  G: TGUID;
begin
  if CreateGUID(G)=0 then
    Result:=StringReplace(Copy(GUIDToString(G), 2, 36), '-', '', [rfReplaceAll])
      +cBoundarySuffix
  else
    raise EHTTPClient.Create('CreateGUID failed');
end;

{ True when the buffer already contains the boundary bytes: a file part
  holding them would end early on the server side and the rest would be read
  as extra form parts (td-077). ABuf/ALen is one contiguous in-memory range -
  the buffered callers scan the file-part range of the TRawByteStringStream
  body they have just assembled, so this is a single pass over memory the
  upload already paid for, never an extra read of the source file }
function BodyContainsBoundary(ABuf: Pointer; ALen: PtrUInt;
  const ABoundary: String): Boolean;
var
  P: PByte;
  I: PtrUInt;
  J: SizeInt;
begin
  Result:=False;
  if (ABuf=Nil) or (ALen<PtrUInt(Length(ABoundary))) then
    Exit;
  P:=PByte(ABuf);
  I:=0;
  while PtrUInt(Length(ABoundary))+I<=ALen do
  begin
    // IndexByte is the RTL memchr (verified on 3.2.2: -1 when absent,
    // 0-based index otherwise); the first boundary byte is a hex digit of the
    // GUID, so candidates are ordinary content bytes. A candidate in the last
    // Length-1 bytes of the range cannot be a full occurrence - bail before
    // CompareMem would read Length bytes past the scanned range
    J:=IndexByte((P+I)^, SizeInt(ALen-I), Ord(ABoundary[1]));
    if J<0 then
      Exit;
    Inc(I, J);
    if I+PtrUInt(Length(ABoundary))>ALen then
      Exit;
    if CompareMem(P+I, Pointer(@ABoundary[1]), Length(ABoundary)) then
      Exit(True);
    Inc(I);
  end;
end;

function TFCLHTTPClient.FilesFormPost(const AURL: string; FormData: TStrings; const AFiles: TStrings): String;
Var
  S, Sep : string;
  SS : TRawByteStringStream;
  I: Integer;
  N,V, aFieldName, aFileName: String;
  F: TFileStream;
  PartStart: Int64;
begin
  SetExpectedHost(AURL);
  Sep:=NewMultipartBoundary;
  AddHeader('Content-Type','multipart/form-data; boundary='+Sep);
  SS:=TRawByteStringStream.Create();
  try
    if (FormData<>Nil) then
      for I:=0 to FormData.Count -1 do
        begin
        // not url encoded
        FormData.GetNameValue(I,N,V);
        S :='--'+Sep+CRLF;
        S:=S+Format('Content-Disposition: form-data; name="%s"'+CRLF+CRLF+'%s'+CRLF,[N, V]);
        SS.WriteBuffer(S[1],Length(S));
        end;
    if (AFiles<>Nil) then
      for I:=0 to AFiles.Count-1 do
        begin
          AFiles.GetNameValue(I,aFieldName,aFileName);
          S:='--'+Sep+CRLF;
          s:=s+Format('Content-Disposition: form-data; name="%s"; filename="%s"'+CRLF,
            [aFieldName,ExtractFileName(aFileName)]);
          s:=s+'Content-Type: application/octet-string'+CRLF+CRLF;
          SS.WriteBuffer(S[1],Length(S));
          F:=TFileStream.Create(aFileName,fmOpenRead or fmShareDenyWrite);
          try
            F.Seek(0, soFromBeginning);
            // td-077: scan ONLY the file bytes - the framing around them is
            // written by this method and contains the boundary by design.
            // The bytes are already in memory here (the copy below), the
            // scan is one extra pass over them, never a re-read of the file;
            // a collision means the file part would end early on the server
            // side, so the request fails closed and the boundary value stays
            // out of the message (the td-019 form of a security diagnostic)
            PartStart:=SS.Size;
            SS.CopyFrom(F,F.Size);
            if BodyContainsBoundary(PByte(SS.Memory)+PartStart,
              PtrUInt(SS.Size-PartStart), Sep) then
              raise EHTTPClient.Create('multipart boundary collides with the uploaded file');
            S:=CRLF;
            SS.WriteBuffer(S[1],Length(S));
          finally
            F.Free;
          end;
        end;

    S:='--'+Sep+'--'+CRLF;
    SS.WriteBuffer(S[1],Length(S));
    SS.Position:=0;
    RequestBody:=SS;
    Result:=Post(AURL);
  finally
    RequestBody:=Nil;
    SS.Free;
  end;
end;

function TFCLHTTPClient.StreamsFormPost(const AURL: string; FormData: TStrings;
  const AFiles: TStrings): String;
Var
  S, Sep : string;
  SS : TRawByteStringStream;
  I: Integer;
  N,V, aFieldName, aFileName: String;
  F: TStream;
  PartStart: Int64;
begin
  SetExpectedHost(AURL);
  Sep:=NewMultipartBoundary;
  AddHeader('Content-Type','multipart/form-data; boundary='+Sep);
  SS:=TRawByteStringStream.Create();
  try
    if (FormData<>Nil) then
      for I:=0 to FormData.Count -1 do
        begin
        // not url encoded
        FormData.GetNameValue(I,N,V);
        S :='--'+Sep+CRLF;
        S:=S+Format('Content-Disposition: form-data; name="%s"'+CRLF+CRLF+'%s'+CRLF,[N, V]);
        SS.WriteBuffer(S[1],Length(S));
        end;
    if (AFiles<>Nil) then
      for I:=0 to AFiles.Count-1 do
        begin
          if not (AFiles.Objects[i] is TStream) then continue;
          AFiles.GetNameValue(I,aFieldName,aFileName);
          S:='--'+Sep+CRLF;
          s:=s+Format('Content-Disposition: form-data; name="%s"; filename="%s"'+CRLF,
            [aFieldName,ExtractFileName(aFileName)]);
          s:=s+'Content-Type: application/octet-string'+CRLF+CRLF;
          SS.WriteBuffer(S[1],Length(S));
          F:=AFiles.Objects[i] as TStream;
          F.Seek(0, soFromBeginning);
          // td-077: same file-bytes-only collision gate as FilesFormPost -
          // the framing around this range contains the boundary by design
          PartStart:=SS.Size;
          SS.CopyFrom(F,F.Size);
          if BodyContainsBoundary(PByte(SS.Memory)+PartStart,
            PtrUInt(SS.Size-PartStart), Sep) then
            raise EHTTPClient.Create('multipart boundary collides with the uploaded file');
          S:=CRLF;
          SS.WriteBuffer(S[1],Length(S));
        end;

    S:='--'+Sep+'--'+CRLF;
    SS.WriteBuffer(S[1],Length(S));
    SS.Position:=0;
    RequestBody:=SS;
    Result:=Post(AURL);
  finally
    RequestBody:=Nil;
    SS.Free;
  end;
end;

procedure TFCLHTTPClient.CheckCertificateHost(Sender: TObject; var Allow: Boolean);

Var
  Cert : PX509;
  CheckHost : TX509CheckHost;
  CheckIPAsc : TX509CheckIPAsc;
  GetPeerCert : TSSLGetPeerCertificate;
  Match : cInt;

begin
  // Fail-closed: every problem below raises - the callback never returns with
  // Allow=False. Allow is True either because verification is switched off
  // (see below) or because all checks have passed.
  if not FSSLVerifyCert then begin
    // Verification was switched off explicitly, no host expectation applies.
    Allow:=True;
    exit;
  end;
  // Runs after the handshake succeeded, so the chain is already validated:
  // here we only add the host name check that FPC 3.2.2 leaves out.
  if FSSLExpectedHost=EmptyStr then
    raise EHTTPClient.Create('TLS host check failed: the request URL has no host name');
  if not (Sender is TOpenSSLSocketHandler) then
    raise EHTTPClient.Create('TLS host check failed: unsupported SSL socket handler');
  // Each host form resolves only its own matcher: an IP literal never runs
  // the DNS check and a DNS name never runs the IP check. A missing symbol
  // fails the request exactly like below - fail closed.
  if FSSLExpectedHostIsIP then begin
    CheckIPAsc:=ResolveX509CheckIPAsc;
    if not Assigned(CheckIPAsc) then
      raise EHTTPClient.Create('TLS host check failed: X509_check_ip_asc is not available in the loaded OpenSSL');
  end else begin
    CheckHost:=ResolveX509CheckHost;
    if not Assigned(CheckHost) then
      raise EHTTPClient.Create('TLS host check failed: X509_check_host is not available in the loaded OpenSSL');
  end;
  GetPeerCert:=ResolveGetPeerCertificate;
  if not Assigned(GetPeerCert) then
    raise EHTTPClient.Create('TLS host check failed: SSL_get_peer_certificate is not available in the loaded OpenSSL');
  Cert:=GetPeerCert(TOpenSSLSocketHandler(Sender).SSL.SSL);
  if Cert=Nil then
    raise EHTTPClient.Create('TLS host check failed: the server did not present a certificate');
  try
    if FSSLExpectedHostIsIP then
      // X509_check_ip_asc compares the textual address against the iPAddress
      // SAN entries - X509_check_host matches DNS names only
      Match:=CheckIPAsc(Cert,PAnsiChar(FSSLExpectedHost),0)
    else
      Match:=CheckHost(Cert,PAnsiChar(FSSLExpectedHost),Length(FSSLExpectedHost),0,Nil);
  finally
    // The peer certificate accessor hands out a new reference, release it.
    X509Free(Cert);
  end;
  // Match contract of both functions: 1 = match, 0 = no match, <0 = error -
  // only a match passes, everything else fails the request.
  if Match<>1 then
    raise EHTTPClient.Create('TLS host check failed: certificate is not issued for "'+FSSLExpectedHost+'"');
  Allow:=True;
end;

procedure TFCLHTTPClient.PrepareHeaders;
begin
  FHTTPClient.AddHeader('User-Agent', UserAgent);
end;

procedure TFCLHTTPClient.SetExpectedHost(const AURL: String);
var
  Host: String;
begin
  // fphttpclient hands the host to the socket (SNI) but not to the SSL handler,
  // so take it from the request URL the same way fphttpclient parses it.
  Host:=ParseURI(AURL,False).Host;
  // ParseURI keeps the brackets of an IPv6 literal and both matchers expect
  // the bare address - strip them, then let CheckCertificateHost pick between
  // X509_check_ip_asc (IP literal) and X509_check_host (DNS name)
  if (Length(Host)>=2) and (Host[1]='[') and (Host[Length(Host)]=']') then
    Host:=Copy(Host,2,Length(Host)-2);
  FSSLExpectedHost:=Host;
  FSSLExpectedHostIsIP:=IsIPv4Literal(Host) or (Pos(':',Host)>0);
end;

procedure TFCLHTTPClient.HttpClientGetSocketHandler(Sender: TObject;
  const UseSSL: Boolean; out AHandler: TSocketHandler);
begin
  // A fresh handler is created per connection; apply our TLS policy each time.
  if UseSSL then begin
    // WHY not TSSLSocketHandler.GetDefaultHandler: our subclass arms
    // SO_NOSIGPIPE on the socket fd before Connect (darwin) - a write into a
    // connection the peer has reset must come back as an exception, not kill
    // the process with SIGPIPE. Point fix: the default handler class of the
    // process stays untouched.
    AHandler:=TNoSigPipeOpenSSLHandler.Create;
    with TSSLSocketHandler(AHandler) do begin
      // WHY no SSLType pin: on FPC 3.2.2 the default (stAny) negotiates TLS 1.2/1.3;
      // the old stTLSv1_2 pin only ever lived in the ExplSSL branch, which was dead
      // code on this toolchain. Pin a floor when a requirement appears.
      VerifyPeerCert:=FSSLVerifyCert;
      if FSSLCAFile<>EmptyStr then
        CertificateData.CertCA.FileName:=FSSLCAFile;
      // WHY OnVerifyCertificate: FPC 3.2.2 validates the chain but never the host
      // name (SSL_set1_host/X509_check_host are not bound by its openssl unit), so
      // a MITM with any publicly trusted certificate would pass and read the
      // Authorization header.
      OnVerifyCertificate:=@CheckCertificateHost;
    end;
  end;
end;

function TFCLHTTPClient.GetAllowRedirect: Boolean;
begin
  Result:=FHTTPClient.AllowRedirect;
end;

function TFCLHTTPClient.GetCookies: TStrings;
begin
  Result:=FHTTPClient.Cookies;
end;

function TFCLHTTPClient.GetHTTPProxyHost: String;
begin
  Result:=FHTTPClient.Proxy.Host;
end;

function TFCLHTTPClient.GetHTTPProxyPassword: String;
begin
  Result:=FHTTPClient.Proxy.Password;
end;

function TFCLHTTPClient.GetHTTPProxyPort: Word;
begin
  Result:=FHTTPClient.Proxy.Port;
end;

function TFCLHTTPClient.GetHTTPProxyUsername: String;
begin
  Result:=FHTTPClient.Proxy.UserName;
end;

function TFCLHTTPClient.GetInternalHTTPClient: TObject;
begin
  Result:=FHTTPClient;
end;

function TFCLHTTPClient.GetIOTimeout: Integer;
begin
  Result:=FHTTPClient.IOTimeout;
end;

function TFCLHTTPClient.GetRequestBody: TStream;
begin
  Result:=FHTTPClient.RequestBody;
end;

function TFCLHTTPClient.GetRequestHeaders: TStrings;
begin
  Result:=FHTTPClient.RequestHeaders;
end;

function TFCLHTTPClient.GetResponseHeaders: TStrings;
begin
  Result:=FHTTPClient.ResponseHeaders;
end;

function TFCLHTTPClient.GetResponseStatusCode: Integer;
begin
  Result:=FHTTPClient.ResponseStatusCode;
end;

function TFCLHTTPClient.GetResponseStatusText: String;
begin
  Result:=FHTTPClient.ResponseStatusText;
end;

procedure TFCLHTTPClient.SetAllowRedirect(AValue: Boolean);
begin
  FHTTPClient.AllowRedirect:=AValue;
end;

procedure TFCLHTTPClient.SetCookies(AValue: TStrings);
begin
  FHTTPClient.Cookies:=AValue;
end;

procedure TFCLHTTPClient.SetHTTPProxyHost(AValue: String);
begin
  FHTTPClient.Proxy.Host:=AValue;
end;

procedure TFCLHTTPClient.SetHTTPProxyPassword(AValue: String);
begin
  FHTTPClient.Proxy.Password:=AValue;
end;

procedure TFCLHTTPClient.SetHTTPProxyPort(AValue: Word);
begin
  FHTTPClient.Proxy.Port:=AValue;
end;

procedure TFCLHTTPClient.SetHTTPProxyUsername(AValue: String);
begin
  FHTTPClient.Proxy.UserName:=AValue;
end;

procedure TFCLHTTPClient.SetIOTimeout(AValue: Integer);
begin
  FHTTPClient.IOTimeout:=AValue;
end;

function TFCLHTTPClient.GetSSLCAFile: String;
begin
  Result:=FSSLCAFile;
end;

function TFCLHTTPClient.GetSSLVerifyCert: Boolean;
begin
  Result:=FSSLVerifyCert;
end;

procedure TFCLHTTPClient.SetSSLCAFile(AValue: String);
begin
  FSSLCAFile:=AValue;
end;

procedure TFCLHTTPClient.SetSSLVerifyCert(AValue: Boolean);
begin
  FSSLVerifyCert:=AValue;
end;

procedure TFCLHTTPClient.SetRequestBody(AValue: TStream);
begin
  FHTTPClient.RequestBody:=AValue;
end;

procedure TFCLHTTPClient.SetRequestHeaders(AValue: TStrings);
begin
  FHTTPClient.RequestHeaders:=AValue;
end;

procedure TFCLHTTPClient.AddHeader(const AHeader, AValue: String);
begin
  FHTTPClient.AddHeader(AHeader, AValue);
end;

constructor TFCLHTTPClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // WHY the keep-alive subclass with KeepConnection=True: MAX throttles rapid
  // new TLS connections (~6-8 in a row start failing with resets and the
  // failure sticks for about a minute, td-032), so every request must reuse
  // one persistent connection. TMaxKeepAliveHTTPClient fixes the 3.2.2
  // keep-alive defects (unbounded retry, unrewound body, silent duplicate of
  // POST, zombie sockets) before the reuse is switched on
  FHTTPClient:=TMaxKeepAliveHTTPClient.Create(AOwner);
  // The setter forces HTTP/1.1 itself (1.0 would silently disable reuse)
  FHTTPClient.KeepConnection:=True;
  FSSLVerifyCert:=True;
  FHTTPClient.OnGetSocketHandler:=@HttpClientGetSocketHandler;
end;

destructor TFCLHTTPClient.Destroy;
begin
  FreeAndNil(FHTTPClient);
  inherited Destroy;
end;

class function TFCLHTTPClient.EncodeUrlElement(S: String): String;
begin
  Result:=fphttpclient.EncodeURLElement(S);
end;

procedure TFCLHTTPClient.FileFormPost(const AURL: string; FormData: TStrings; AFieldName,
  AFileName: string; const Response: TStream);
var
  F: TFileStream;
begin
  // td-077: the stock FileFormPost of the internal client opened the file and
  // delegated to the STOCK StreamFormPost - the one builder of this path whose
  // boundary stayed the deterministic Random($ffffff) hex. Open the file here
  // and go through OUR hardened StreamFormPost instead: TMaxMultipartStream
  // matches the stock byte layout one-to-one (td-048), SetExpectedHost runs
  // inside it, and the boundary is the CSPRNG one
  F:=TFileStream.Create(AFileName,fmOpenRead or fmShareDenyWrite);
  try
    StreamFormPost(AURL, FormData, AFieldName, ExtractFileName(AFileName), F, Response);
  finally
    F.Free;
  end;
end;

function TFCLHTTPClient.FormPost(const URL: string; FormData: TStrings
  ): String;
begin
  SetExpectedHost(URL);
  PrepareHeaders;
  Result:=FHTTPClient.FormPost(URL, FormData);
end;

function TFCLHTTPClient.Get(const AUrl: String): String;
var
  SS: TStringStream;
begin
  SetExpectedHost(AUrl);
  PrepareHeaders;
  // Empty allowed-response list: every status is returned to the caller with
  // its body. The stock TFPCustomHTTPClient.Get gates on [200] and drops the
  // error body of a failed request (the caller reads ResponseStatusCode)
  SS:=TStringStream.Create('');
  try
    FHTTPClient.HTTPMethod('GET', AUrl, SS, []);
    Result:=SS.DataString;
  finally
    SS.Free;
  end;
end;

function TFCLHTTPClient.Post(const URL: string): String;
var
  SS: TStringStream;
begin
  SetExpectedHost(URL);
  PrepareHeaders;
  // See Get: the caller decides success by ResponseStatusCode
  SS:=TStringStream.Create('');
  try
    FHTTPClient.HTTPMethod('POST', URL, SS, []);
    Result:=SS.DataString;
  finally
    SS.Free;
  end;
end;

function TFCLHTTPClient.Put(const URL: string): String;
var
  SS: TStringStream;
begin
  SetExpectedHost(URL);
  PrepareHeaders;
  SS:=TStringStream.Create('');
  try
    // See Get: no status gate, the body must survive a failed request
    FHTTPClient.HTTPMethod('PUT', URL, SS, []);
    Result:=SS.DataString;
  finally
    SS.Free;
  end;
end;

function TFCLHTTPClient.Delete(const URL: string): String;
var
  SS: TStringStream;
begin
  SetExpectedHost(URL);
  PrepareHeaders;
  SS:=TStringStream.Create('');
  try
    // See Get: no status gate, the body must survive a failed request
    FHTTPClient.HTTPMethod('DELETE', URL, SS, []);
    Result:=SS.DataString;
  finally
    SS.Free;
  end;
end;

procedure TFCLHTTPClient.StreamFormPost(const AURL: string; FormData: TStrings; const AFieldName,
  AFileName: string; const AStream: TStream; const Response: TStream);
var
  lBoundary: string;
  MP: TMaxMultipartStream;
begin
  // td-048: the stock StreamFormPost copies the whole file into an
  // intermediate memory stream before the request - the composite streams
  // the file bytes straight from AStream into the socket (RAM 1x -> 0x) and
  // byte-matches the stock body layout
  SetExpectedHost(AURL);
  // td-077: the boundary is 122 random bits from the OS CSPRNG now (was the
  // deterministic Random($ffffff) hex shared with the stock builder). The
  // content-vs-boundary scan of the buffered siblings is deliberately NOT
  // here: this path streams the file bytes straight into the socket
  // (td-048, the file never sits in RAM) - a scan would need an extra full
  // pass over the source stream, and a non-file stream would pay a full
  // re-read (or a re-download). The tradeoff is sound: the boundary is
  // unknown until this call, so content crafted BEFORE it contains the
  // 51-char string with ~2^-122 per position, and the content is
  // host-controlled, not attacker-supplied (the td-077 risk model)
  lBoundary:=NewMultipartBoundary;
  AddHeader('Content-Type','multipart/form-data; boundary='+lBoundary);
  MP:=TMaxMultipartStream.Create(lBoundary, FormData, AFieldName, AFileName, AStream);
  try
    RequestBody:=MP;
    try
      // The two-argument Post lives on the INTERNAL client only: the
      // unqualified Post(AURL, Response) does not compile - TFCLHTTPClient
      // overrides Post(URL): String (above). The internal Post forwards to
      // HTTPMethod('POST', URL, Response, []) - the response lands in the
      // stream, no status gate (the caller reads ResponseStatusCode), the
      // keep-alive loop applies RequestBody and rewinds it per attempt
      FHTTPClient.Post(AURL, Response);
    finally
      RequestBody:=Nil;
    end;
  finally
    MP.Free;
  end;
end;

initialization
  {$IFDEF LINUX}
  // WHY ignore SIGPIPE process-wide: keep-alive writes into sockets the peer
  // may have reset; Linux ssockets sends with flags 0 (no MSG_NOSIGNAL) and
  // has no per-socket SO_NOSIGPIPE, so the default disposition would kill the
  // whole process on the first such write. Ignored, the write returns EPIPE
  // and the transport recovers by reconnecting. WARNING: this is process-wide
  // and permanent - a host that needs the default SIGPIPE disposition must
  // reinstall it after uses. On darwin no process-wide change happens: the
  // per-socket SO_NOSIGPIPE of TNoSigPipeOpenSSLHandler covers it.
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}
  TFCLHTTPClient.UnregisterClientClass;
  TFCLHTTPClient.RegisterClientClass;

end.

