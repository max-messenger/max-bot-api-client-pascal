unit maxbasehttpclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type

  EHTTPClient = class(Exception);

  TBaseClientClass = class of TBaseHTTPClient;

  { TMaxMultipartStream }

  { A multipart/form-data body assembled from in-memory literals plus the
    source stream of the uploaded file: boundaries and part headers are
    produced on the fly, the file bytes are never copied into an intermediate
    buffer (td-048). Size is precomputed in the constructor - SendRequest
    needs it for Content-Length, fphttpclient 3.2.2 auto-adds the header from
    RequestBody.Size when it is absent - and must be exact before the first
    Read. Seek(0, soBeginning) rewinds the internal cursor AND the source
    stream: the keep-alive loop (TMaxKeepAliveHTTPClient) rewinds RequestBody
    before every send attempt, so a retry must replay the identical body }
  TMaxMultipartStream=class(TStream)
  private
    FHead: String;       // boundaries + part headers + form fields, in memory
    FHeadLen: Int64;
    FTail: String;       // CRLF + closing boundary + CRLF, in memory
    FTailLen: Int64;
    FSource: TStream;    // the uploaded file's bytes, NOT owned
    FFileSize: Int64;
    FSourceOffset: Int64; // where this stream has positioned FSource (-1 = not yet)
    FSize: Int64;
    FPosition: Int64;
    { Keeps the invariant "FSource stands at FSourceOffset": reads inside the
      file part and seeks across it both go through here, so the source is
      touched only when the requested offset actually differs }
    procedure PositionSource(AOffset: Int64);
  public
    { ABoundary is formatted by the CALLER (the brokers generate it per
      request, the composite does not know the format); AFormData holds the
      plain form fields (nil and a zero-count list are both valid - the
      UploadFile path passes an empty list); AFieldName/AFileName label the
      file part; AStream is the file content, its position is irrelevant }
    constructor Create(const ABoundary: String; AFormData: TStrings;
      const AFieldName, AFileName: String; AStream: TStream);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  protected
    function GetSize: Int64; override;
  end;

  { TMaxStringBodyStream }

  { A read-only stream over the bytes of an existing string. ApiCall
    serializes the JSON body once and hands the string to the transport
    through this stream: TStringStream.Create(S) would memcpy the whole body
    into its internal buffer, keeping the body twice in RAM (td-048). The
    string is held by reference - a refcount bump, the bytes are never
    moved. The contract the transports rely on is kept intact: Size is exact
    before the first Read (fphttpclient builds Content-Length from it) and
    Seek(0, soBeginning) rewinds it (the keep-alive loop rewinds RequestBody
    before every send attempt, a retry replays the identical bytes) }
  TMaxStringBodyStream=class(TStream)
  private
    FRef: String;     // keeps the buffer alive, NOT a copy of the data
    FData: Pointer;   // start of the character data, nil when empty
    FSize: Int64;
    FPosition: Int64;
  public
    constructor Create(const AData: String);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  protected
    function GetSize: Int64; override;
  end;

  { TBaseHTTPClient }

  TBaseHTTPClient=class(TComponent)
  private
    FUserAgent: String;
  protected
    function GetAllowRedirect: Boolean; virtual; abstract;
    function GetCookies: TStrings; virtual; abstract;
    function GetHTTPProxyHost: String; virtual; abstract;
    function GetHTTPProxyPassword: String; virtual; abstract;
    function GetHTTPProxyPort: Word; virtual; abstract;
    function GetHTTPProxyUsername: String; virtual; abstract;
    function GetInternalHTTPClient: TObject; virtual; abstract;
    function GetRequestBody: TStream; virtual; abstract;
    function GetRequestHeaders: TStrings; virtual; abstract;
    function GetResponseHeaders: TStrings; virtual; abstract;
    function GetResponseStatusCode: Integer; virtual; abstract;
    function GetResponseStatusText: String; virtual; abstract;
    function GetIOTimeout: Integer; virtual; abstract;
    function GetSSLCAFile: String; virtual; abstract;
    function GetSSLVerifyCert: Boolean; virtual; abstract;
    procedure SetAllowRedirect(AValue: Boolean); virtual; abstract;
    procedure SetCookies(AValue: TStrings); virtual; abstract;
    procedure SetHTTPProxyHost(AValue: String); virtual; abstract;
    procedure SetHTTPProxyPassword(AValue: String); virtual; abstract;
    procedure SetHTTPProxyPort(AValue: Word); virtual; abstract;
    procedure SetHTTPProxyUsername(AValue: String); virtual; abstract;
    procedure SetRequestBody(AValue: TStream); virtual; abstract;
    procedure SetRequestHeaders(AValue: TStrings); virtual; abstract;
    procedure SetIOTimeout(AValue: Integer); virtual; abstract;
    procedure SetSSLCAFile(AValue: String); virtual; abstract;
    procedure SetSSLVerifyCert(AValue: Boolean); virtual; abstract;
  public
    procedure AddHeader(Const AHeader,AValue : String); virtual; abstract;
    class function EncodeUrlElement(S: String): String; virtual; abstract;
    procedure FileFormPost(const AURL: string; FormData: TStrings; AFieldName, AFileName: string;
      const Response: TStream); virtual; abstract;
    function FilesFormPost(const AURL: string; FormData: TStrings; const AFiles: TStrings): String; virtual; abstract;
    function StreamsFormPost(const AURL: string; FormData: TStrings; const AFiles: TStrings): String; virtual; abstract;
    function FormPost(const URL: string; FormData : TStrings): String; virtual; abstract;
    function Get(const AUrl: String): String; virtual; abstract;
    function Post(const URL: string) : String; virtual; abstract;
    function Put(const URL: string): String; virtual; abstract;    // body via RequestBody
    function Delete(const URL: string): String; virtual; abstract;
    procedure StreamFormPost(const AURL: string; FormData: TStrings;
      const AFieldName, AFileName: string; const AStream: TStream;
      const Response: TStream); virtual; abstract;
    class function GetClientClass: TBaseClientClass;
    class procedure RegisterClientClass;
    class procedure UnregisterClientClass;
    property AllowRedirect: Boolean read GetAllowRedirect write SetAllowRedirect;
    property Cookies: TStrings read GetCookies write SetCookies;
    property RequestBody: TStream read GetRequestBody write SetRequestBody;
    property RequestHeaders: TStrings read GetRequestHeaders write SetRequestHeaders;
    property ResponseHeaders: TStrings read GetResponseHeaders;
    property ResponseStatusCode: Integer read GetResponseStatusCode;
    property ResponseStatusText: String read GetResponseStatusText;
    property HTTPProxyHost: String read GetHTTPProxyHost write SetHTTPProxyHost;
    property HTTPProxyPort: Word read GetHTTPProxyPort write SetHTTPProxyPort;
    property HTTPProxyUsername: String read GetHTTPProxyUsername write SetHTTPProxyUsername;
    property HTTPProxyPassword: String read GetHTTPProxyPassword write SetHTTPProxyPassword;
    Property IOTimeout : Integer read GetIOTimeout write SetIOTimeout;
    { Path to a PEM bundle with trusted root CAs for server certificate
      verification. Empty = no explicit bundle is handed to the TLS backend;
      whether verification then succeeds depends on that backend.
      The FCL client loads the bundle and nothing else - the pin is EXCLUSIVE,
      an empty SSLCAFile means zero roots and the handshake fails closed
      (td-010); TMaxSender is unaffected - its default policy hands the
      broker the merged shipped+system bundle by design }
    property SSLCAFile: String read GetSSLCAFile write SetSSLCAFile;
    { Verify the server certificate chain. Verification is on by default:
      MAX API must be reached over validated TLS. }
    property SSLVerifyCert: Boolean read GetSSLVerifyCert write SetSSLVerifyCert;
    property InternalHTTPClient: TObject read GetInternalHTTPClient;
    property UserAgent: String read FUserAgent write FUserAgent;
  end;

implementation

const
  CRLF = #13#10;

var
  _BaseHTTPClientClass: TBaseClientClass = nil;

{ TMaxMultipartStream }

{ The byte layout matches the stock buffered builder one-to-one (the stock
  TFPCustomHTTPClient.StreamFormPost): per form field "--BOUNDARY"CRLF Content-Disposition CRLF CRLF
  value CRLF, then the file part "--BOUNDARY"CRLF Content-Disposition with
  filename CRLF Content-Type CRLF CRLF <raw file bytes>, then CRLF
  "--BOUNDARY--"CRLF }

constructor TMaxMultipartStream.Create(const ABoundary: String;
  AFormData: TStrings; const AFieldName, AFileName: String; AStream: TStream);
var
  I: Integer;
  N, V: String;
begin
  inherited Create;
  if not Assigned(AStream) then
    raise EStreamError.Create('TMaxMultipartStream: the file stream is required');
  FSource:=AStream;
  FHead:='';
  if Assigned(AFormData) then
    for I:=0 to AFormData.Count-1 do
    begin
      AFormData.GetNameValue(I, N, V);
      FHead:=FHead+'--'+ABoundary+CRLF
        +'Content-Disposition: form-data; name="'+N+'"'+CRLF+CRLF+V+CRLF;
    end;
  FHead:=FHead+'--'+ABoundary+CRLF
    +'Content-Disposition: form-data; name="'+AFieldName+'"; filename="'
    +ExtractFileName(AFileName)+'"'+CRLF
    +'Content-Type: application/octet-string'+CRLF+CRLF;
  FTail:=CRLF+'--'+ABoundary+'--'+CRLF;
  FHeadLen:=Length(FHead);
  FTailLen:=Length(FTail);
  // The file is NOT read here: only its Size feeds the Content-Length
  FFileSize:=AStream.Size;
  FSize:=FHeadLen+FFileSize+FTailLen;
  FPosition:=0;
  FSourceOffset:=-1;
end;

procedure TMaxMultipartStream.PositionSource(AOffset: Int64);
begin
  if AOffset<>FSourceOffset then
  begin
    FSource.Position:=AOffset;
    FSourceOffset:=AOffset;
  end;
end;

function TMaxMultipartStream.Read(var Buffer; Count: Longint): Longint;
var
  P: PByte;
  Chunk: Longint;
begin
  Result:=0;
  if Count<=0 then
    Exit;
  P:=@Buffer;
  // the in-memory head (boundaries, part headers, form fields)
  if FPosition<FHeadLen then
  begin
    Chunk:=FHeadLen-FPosition;
    if Chunk>Count then
      Chunk:=Count;
    Move(FHead[1+FPosition], P^, Chunk);
    Inc(FPosition, Chunk);
    Inc(P, Chunk);
    Inc(Result, Chunk);
    Dec(Count, Chunk);
  end;
  // the file part: read straight from the source, no intermediate buffer
  if (Count>0) and (FPosition<FHeadLen+FFileSize) then
  begin
    PositionSource(FPosition-FHeadLen);
    Chunk:=FHeadLen+FFileSize-FPosition;
    if Chunk>Count then
      Chunk:=Count;
    Chunk:=FSource.Read(P^, Chunk);
    // the source decides how much it served: keep the offset invariant true
    Inc(FSourceOffset, Chunk);
    Inc(FPosition, Chunk);
    Inc(P, Chunk);
    Inc(Result, Chunk);
    Dec(Count, Chunk);
    // The source stopped inside the file part: its Size promised FFileSize
    // bytes, the Content-Length is already built on that promise, and the
    // head (possibly with part of the file) may be on the wire - the body
    // cannot be repaired, so fail loudly instead of gluing the closing
    // boundary into the middle of the file part or shipping a body shorter
    // than Content-Length (the server side would wait for the missing tail
    // forever). A short but non-empty read is fine: streams may serve less
    // than asked, the next Read retries the same spot
    if (Chunk=0) and (FPosition<FHeadLen+FFileSize) then
      raise EStreamError.Create(Format(
        'TMaxMultipartStream: the source stream ended after %d of %d promised file bytes',
        [FPosition-FHeadLen, FFileSize]));
  end;
  // the epilog (closing boundary): only past the file part - a short source
  // read leaves FPosition inside the file part and must not pull the tail
  // over the file bytes (the tail index would run before the start of FTail)
  if (Count>0) and (FPosition>=FHeadLen+FFileSize) and (FPosition<FSize) then
  begin
    Chunk:=FSize-FPosition;
    if Chunk>Count then
      Chunk:=Count;
    Move(FTail[1+FPosition-FHeadLen-FFileSize], P^, Chunk);
    Inc(FPosition, Chunk);
    Inc(Result, Chunk);
  end;
end;

function TMaxMultipartStream.Seek(const Offset: Int64; Origin: TSeekOrigin
  ): Int64;
var
  Target: Int64;
begin
  case Origin of
    soBeginning:
      Target:=Offset;
    soCurrent:
      Target:=FPosition+Offset;
    soEnd:
      Target:=FSize+Offset;
  else
    raise EStreamError.Create('TMaxMultipartStream: unsupported seek origin');
  end;
  if (Target<0) or (Target>FSize) then
    raise EStreamError.Create('TMaxMultipartStream: seek outside the multipart body');
  // a target inside the file part moves the source with it; a target in the
  // literals leaves the source alone - Read repositions it lazily
  if (Target>FHeadLen) and (Target<FHeadLen+FFileSize) then
    PositionSource(Target-FHeadLen);
  FPosition:=Target;
  Result:=Target;
end;

function TMaxMultipartStream.GetSize: Int64;
begin
  // Precomputed in the constructor: exact before the first Read, the file is
  // never touched for it
  Result:=FSize;
end;

{ TMaxStringBodyStream }

constructor TMaxStringBodyStream.Create(const AData: String);
begin
  inherited Create;
  // Assigning to FRef only bumps the refcount of the caller's buffer: the
  // body exists in memory exactly once and this stream serves its bytes
  // straight from that buffer
  FRef:=AData;
  FSize:=Length(FRef);
  if FSize>0 then
    FData:=@FRef[1]
  else
    FData:=nil;
  FPosition:=0;
end;

function TMaxStringBodyStream.Read(var Buffer; Count: Longint): Longint;
var
  Chunk: Int64;
begin
  Result:=0;
  if Count<=0 then
    Exit;
  Chunk:=FSize-FPosition;
  if Chunk>Count then
    Chunk:=Count;
  if Chunk>0 then
  begin
    Move((PByte(FData)+FPosition)^, Buffer, Chunk);
    Inc(FPosition, Chunk);
    Result:=Chunk;
  end;
end;

function TMaxStringBodyStream.Seek(const Offset: Int64; Origin: TSeekOrigin
  ): Int64;
var
  Target: Int64;
begin
  case Origin of
    soBeginning:
      Target:=Offset;
    soCurrent:
      Target:=FPosition+Offset;
    soEnd:
      Target:=FSize+Offset;
  else
    raise EStreamError.Create('TMaxStringBodyStream: unsupported seek origin');
  end;
  if (Target<0) or (Target>FSize) then
    raise EStreamError.Create('TMaxStringBodyStream: seek outside the body');
  FPosition:=Target;
  Result:=Target;
end;

function TMaxStringBodyStream.GetSize: Int64;
begin
  // Length of the referenced buffer, exact before the first Read
  Result:=FSize;
end;

{ TBaseHTTPClient }

class procedure TBaseHTTPClient.RegisterClientClass;
begin
  if Assigned(_BaseHTTPClientClass) then
    raise EHTTPClient.Create('HTTP client class already registered!');
  _BaseHTTPClientClass := Self;
end;

class procedure TBaseHTTPClient.UnregisterClientClass;
begin
  _BaseHTTPClientClass := nil;
end;

class function TBaseHTTPClient.GetClientClass: TBaseClientClass;
begin
  if not Assigned(_BaseHTTPClientClass) then
    raise EHTTPClient.Create('No HTTP client class registered! Please use RegisterClientClass procedure');
  Result:=_BaseHTTPClientClass;
end;

end.

