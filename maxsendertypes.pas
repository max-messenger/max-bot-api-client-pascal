unit maxsendertypes;

{$mode objfpc}{$H+}

{ TMaxSender: wrapper over the MAX Bot API (https://dev.max.ru/docs-api).
  Endpoints (base = https://platform-api2.max.ru):
    GET    /updates?marker=&limit=&timeout= long polling
    POST   /messages?chat_id=               send a message
    PUT    /messages?chat_id=&message_id=   edit a message
    DELETE /messages?chat_id=&message_id=   delete a message
    POST   /answers?callback_id=            answer a callback
    POST   /uploads?type=                   get an upload URL (and, for video/
                                            audio, the token), then POST the
                                            file there as multipart/form-data
                                            (no Authorization on this step)
    POST   /subscriptions                   set webhook (url and the optional
                                            secret in the JSON body)
    DELETE /subscriptions?url=              remove webhook
    GET    /me                              bot info
    GET    /chats/{chat_id}                 chat or channel card }

interface

uses
  Classes, SysUtils, Math, fpJSON, jsonparser, fgl, ghashmap, ghashset,
  eventlog, maxtypes, maxstatlog, maxbasehttpclient;

type

  TLogMessageEvent = procedure(ASender: TObject; EventType: TEventType;
    const Msg: String) of object;
  TOnUpdateEvent = procedure (ASender: TObject; AnUpdate: TMaxUpdateObj) of object;
  TMessageEvent = procedure (ASender: TObject; AMessage: TMaxMessageObj) of object;
  TCallbackEvent = procedure (ASender: TObject; ACallback: TMaxCallbackObj) of object;
  TUserEvent = procedure (ASender: TObject; AUser: TMaxUserObj) of object;
  TChatEvent = procedure (ASender: TObject; AUpdate: TMaxUpdateObj) of object;
  TCommandEvent = procedure (ASender: TObject; const ACommand: String;
    AMessage: TMaxMessageObj) of object;

  { Configuration/environment error of a TMaxSender: the configuration cannot
    serve requests at all (a token with control characters, no TLS trust
    anchor, a failed merged CA bundle). Raised by design instead of the
    Boolean contract (td-013): hosts catch it BEFORE the generic Exception
    handler - a configuration error must be a visible stop, not a retry loop.
    Deliberately NOT raised for program guards (ApiCall's 'Unsupported HTTP
    verb', TMaxObj.Create): those report library misuse, not configuration }
  EMaxConfig = class(Exception);

  { TStringHash }

  TStringHash = class
    class function hash(s: String; n: Integer): Integer;
  end;

  generic TStringHashMap<T> = class(specialize THashMap<String,T,TStringHash>) end;

  TCommandHandlersMap = specialize TStringHashMap<TCommandEvent>;

  { TIntegerHash }

  TIntegerHash = class
    class function hash(i: Int64; n: Integer): Integer;
  end;

  TIntegerHashSet = specialize THashSet<Int64,TIntegerHash>;

  { TMaxSender }

  { One slot of the per-sender client pool: the client is exclusive while
    InUse, the pool critical section is held only on checkout/checkin - never
    during the HTTP request itself }
  TMaxSenderClientSlot=record
    Client: TBaseHTTPClient;
    InUse: Boolean;
    { The configuration changed while this client was checked out: it was
      built from the old configuration and dies on release }
    Stale: Boolean;
  end;

  { The configuration snapshot a pooled client is built from: a drift against
    it at Acquire replaces the pool's clients (one mechanism instead of hooks
    on every setter). Timeout is deliberately absent - it is applied per call
    (though its writes take the same pool lock, see the setters' group
    comment); this record doubles as the snapshot every client build works
    from, so a build never reads the fields directly }
  TMaxPoolConfig=record
    Token, EndPoint: String;
    ProxyHost, ProxyUser, ProxyPass: String;
    ProxyPort: Word;
    CAFile: String;
    VerifyCert: Boolean;
  end;

  TMaxSender = class
  private
    FToken: String;
    FAPIEndPoint: String;
    FMarker: String;                // opaque long-polling marker from /updates
    FTimeout: Integer;
    FSSLCAFile: String;
    FSSLVerifyCert: Boolean;
    FHTTPProxyHost: String;
    FHTTPProxyPort: Word;
    FHTTPProxyUser: String;
    FHTTPProxyPassword: String;
    FResponse: String;
    FJSONResponse: TJSONData;
    FLastErrorCode: String;  // MAX error code, e.g. "verify.token" or "chat.denied"
    FLastErrorMsg: String;
    FBotInfo: TMaxBotInfoObj;
    FChat: TMaxChatObj;
    FUpdate: TMaxUpdateObj;
    { Aliases into the FUpdate tree (they point at objects owned by
      TMaxUpdateObj/TMaxMessageObj), never freed here }
    FCurrentMessage: TMaxMessageObj;
    FCurrentUser: TMaxUserObj;
    FCurrentChatId: Int64;
    FProcessUpdate: Boolean;
    FLogDebug: Boolean;
    FOnLogMessage: TLogMessageEvent;
    FOnReceiveUpdate: TOnUpdateEvent;
    FOnReceiveMessage: TMessageEvent;
    FOnReceiveEditedMessage: TMessageEvent;
    FOnReceiveCallback: TCallbackEvent;
    FOnBotStarted: TUserEvent;
    FOnUserAdded: TUserEvent;
    FOnUserRemoved: TUserEvent;
    FOnChatTitleChanged: TChatEvent;
    FOnAnyUpdate: TOnUpdateEvent;   // called for every update type, before OnReceiveUpdate
    { The bot's own username WITHOUT the leading '@' (the consumer copies it
      from GetMe -> BotInfo.Username); ProcessCommands needs it to tell our
      mention from a foreign bot's one in group chats }
    FOwnUsername: String;
    FCommandHandlers: TCommandHandlersMap;
    FAdminUsers: TIntegerHashSet;
    FUpdateLogger: TMaxStatLog;
    procedure AssignHTTProxy(aHTTPClient: TBaseHTTPClient;
      const AConfig: TMaxPoolConfig);
    { Builds the registered HTTP client from the PASSED-IN configuration copy
      (never from the fields: the callers snapshot them under FClientPoolCS,
      so no field read here races the locked setters) - applies proxy,
      timeout, the TLS trust settings and (unless AWithAuth=False, e.g. for
      the second step of an upload, which goes to a pre-authorized URL) the
      Authorization header. Pure: no validation, no user callbacks - run
      ValidateHTTPConfig on the same copy first; this one may run while
      FClientPoolCS is held }
    function CreateHTTPClient(AWithAuth: Boolean;
      const AConfig: TMaxPoolConfig; const ACAFile: String;
      ATimeout: Integer): TBaseHTTPClient;
    { Validates the token and resolves the trust anchor from the PASSED-IN
      configuration copy: reports through the user's ErrorMessage callback
      and raises on a broken configuration (an invalid token, verification
      on with no anchor). Contract: the caller holds NO FClientPoolCS here -
      the callback may legally reconfigure the sender, and any setter (or
      AcquireAPIClient) it calls would self-deadlock on the non-reentrant
      section; the copy is taken under the lock before the call }
    procedure ValidateHTTPConfig(const AConfig: TMaxPoolConfig;
      out AResolvedCAFile: String);
    procedure DebugMessage(const AMsg: String);
    { True when S carries a control character (< #32 or #127). The upload
      inputs that travel in wire headers verbatim - the one-shot upload URL
      into the request-target, the file name into Content-Disposition - are
      rejected on it, the same class the token validation in
      ValidateHTTPConfig scans for (td-019) }
    class function HasControlChars(const S: String): Boolean;
    { Core transport: builds APIEndPoint+APath+query, sends AVerb request
      (body from ABody as JSON), stores the response and parses it.
      AVerb: 'GET' | 'POST' | 'PUT' | 'DELETE'. ATimeoutMs is the exact IO
      window of this one request in milliseconds; 0 applies the configured
      Timeout (snapshotted under the lock as usual) - GetUpdates passes its
      long-polling window through it instead of widening the shared Timeout
      field (td-018) }
    function ApiCall(const APath, AVerb: String; AQuery: TStrings;
      ABody: TJSONData; ATimeoutMs: Integer = 0): Boolean;
  protected
    procedure DoReceiveUpdate(AnUpdate: TMaxUpdateObj); virtual;
    { Gates over the received update, called from DoReceiveUpdate after the
      update is stored in FUpdate: returning False drops it - no dispatch,
      no events, no statistics (the update stays owned and freed as usual).
      May be called more than once per update (the whole override chain
      re-checks it) - keep overrides side-effect free }
    function AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean; virtual;
    { The two leaf lookups of the default trust policy (private -> protected
      + virtual: the names and bodies do not change, the virtuality lets the
      offline tests inject fixture paths instead of the hardcoded OS ones) }
    class function DefaultSystemCAFile: String; virtual;
    class function ShippedCAFile: String; virtual;
    { The default trust policy from the PASSED-IN configuration values (a
      set SSLCAFile is the single anchor as configured; an empty one with
      SSLVerifyCert=True resolves the shipped bundle AND the system store,
      merged into one per-process bundle, and RAISES when neither is found).
      May report through the user's ErrorMessage callback - the caller must
      hold no FClientPoolCS here (a setter or AcquireAPIClient re-entered
      from the callback would self-deadlock on the non-reentrant section) }
    function ResolveTrustAnchor(const ACAFile: String;
      AVerifyCert: Boolean): String;
    { The default (empty SSLCAFile) value with verification on: one merged
      bundle per process, cached under a critical section; the branching
      itself lives in the stateless ResolveDefaultCAFile }
    class function MergedDefaultCAFile: String;
    { Stateless branch of the default resolution, no cache: both paths set ->
      BuildMergedCAFile, exactly one set -> that path, none -> EmptyStr.
      Callable any number of times with any arguments }
    class function ResolveDefaultCAFile(const AShippedCAFile,
      ASystemCAFile: String): String;
    { Builder of the merged bundle: always writes a fresh temp file
      "file1 + [#10 if needed] + file2" (UNIX: inside a fresh private
      per-process temp directory) and returns its path; on any error deletes
      the partial result and re-raises }
    class function BuildMergedCAFile(const AShippedCAFile,
      ASystemCAFile: String): String;
    { Drops the merged-bundle cache under the lock: the test seam (the suite
      runs in one process - every test must start with a clean cache).
      Contract: the cache is a single global slot per process, so any override
      of ShippedCAFile/DefaultSystemCAFile must call this before the next
      MergedDefaultCAFile, or the override silently gets the previously
      cached path }
    class procedure ResetMergedCACache;
    { False keeps the update out of the UpdateLogger statistics }
    function ShouldLogUpdate(AnUpdate: TMaxUpdateObj): Boolean; virtual;
    procedure DoReceiveMessage(AMessage: TMaxMessageObj); virtual;
    procedure DoReceiveCallback(ACallback: TMaxCallbackObj); virtual;
    { Reports a failure to the OnLogMessage event with etError. Never call
      with FClientPoolCS held: the handler runs arbitrary user code, and a
      setter (or AcquireAPIClient) it calls would self-deadlock on the
      non-reentrant section - the config validation reports from outside the
      lock, from a snapshot copy }
    procedure ErrorMessage(const AMsg: String);
    { The guarded form of ErrorMessage: a raising OnLogMessage is swallowed -
      the diagnostic line is best-effort, the failure contract of the code
      that reports through it (an EmptyStr fold, a Boolean result or the
      EMaxConfig raise that follows) must survive the callback (td-072,
      td-076). Same locking contract as ErrorMessage: never with
      FClientPoolCS held. Protected (not private): the bot_ex layer
      (TMaxBot descendant) reports its own failures through it - the same
      convention (td-072, td-078, td-079) }
    procedure SafeErrorMessage(const AMsg: String);
  private
    function GetAPIEndPoint: String;
    procedure SetAPIEndPoint(AValue: String);
    { Pool-config setters: each holds FClientPoolCS - see the group comment
      at the implementations }
    procedure SetToken(AValue: String);
    procedure SetHTTPProxyUser(AValue: String);
    procedure SetHTTPProxyPassword(AValue: String);
    procedure SetHTTPProxyHost(AValue: String);
    procedure SetHTTPProxyPort(AValue: Word);
    procedure SetSSLCAFile(AValue: String);
    procedure SetSSLVerifyCert(AValue: Boolean);
    { Timeout is not a pool-config field (see the group comment at the
      implementations), but its write takes the same lock }
    procedure SetTimeout(AValue: Integer);
    function GetCommandHandlers(const Command: String): TCommandEvent;
    procedure SetCommandHandlers(const Command: String; AValue: TCommandEvent);
    { Not a pool-config field (the write takes no lock); see the property
      for the normalization }
    procedure SetOwnUsername(AValue: String);
  private
    { The per-sender client pool (keep-alive transport, td-032): a checked-out
      client is exclusive, so a slot per concurrent caller - a long poll in one
      thread and sends in another occupy two slots and never block each other }
    FClientPoolCS: TRTLCriticalSection;
    FClientPool: array of TMaxSenderClientSlot;
    FPoolConfigValid: Boolean;
    FPoolConfig: TMaxPoolConfig;
    { Checks a client out of the pool (or builds a new one) and hands back
      the endpoint and timeout the CLIENT is paired with, read in the SAME
      critical section as the checkout (td-049): the caller builds the URL
      from AEndPoint, and an endpoint snapshotted separately from the client
      raced a concurrent reconfiguration - the request could go out to the
      old endpoint with the new token (one spurious 401). On the grow path
      the pair comes from the same configuration copy the new client is
      built from, even if the fields drift again before it is installed }
    function AcquireAPIClient(out AEndPoint: String;
      out ATimeoutMs: Integer): TBaseHTTPClient;
    procedure ReleaseAPIClient(AClient: TBaseHTTPClient; AFailed: Boolean);
    { Reads the pool-config fields into AConfig (caller holds FClientPoolCS,
      the setters hold it too - no read races a write) }
    procedure ReadPoolConfig(out AConfig: TMaxPoolConfig);
    { Rebuilds the snapshot from the current fields (under lock) }
    procedure PoolConfigSnapshot;
    { True when the current fields differ from the snapshot (under lock) }
    function PoolConfigDrifted: Boolean;
    { True when AConfig differs from the current fields (under lock): the
      staleness test of a client that was built outside the lock from a copy }
    function ConfigDrifted(const AConfig: TMaxPoolConfig): Boolean;
    { Keeps the Content-Type of a previous bodied request from riding a
      bodyless one on a reused client (RequestHeaders is never cleaned by the
      brokers) }
    procedure RemoveContentTypeHeader(AHTTP: TBaseHTTPClient);
  public
    constructor Create(const AToken: String);
    destructor Destroy; override;
    procedure AddAdminUser(aUser: Int64);
    function IsAdminUser(aUser: Int64): Boolean;

    { --- API wrappers --- }
    function GetMe: Boolean;                       // GET /me -> BotInfo
    { GET /chats/{chat_id}: the card of one chat or channel of the bot. On
      True the parsed chat is in the Chat property (owned, replaced by the
      next GetChat). The schema (0.0.33) has no chat LIST endpoint: the chat
      ids come from the updates or externally }
    function GetChat(AChatId: Int64): Boolean;
    { GET /updates long polling: ALimit 1..1000 (0 = server default),
      ATimeoutSec 0..90 (0 = server default) }
    function GetUpdates(const AMarker: String; ALimit: Integer;
      ATimeoutSec: Integer): Boolean;
    { Uses the marker of the last received update; keeps the historical
      (limit, timeout) shape for compatibility }
    function GetUpdatesEx(limit: Integer; lp_timeout: Integer): Boolean;
    function SendMessage(chat_id: Int64; const AText: String): Boolean;
    function SendMessageEx(chat_id: Int64; const AText: String;
      AAttachments: TJSONArray = nil; ANotify: Boolean = True;
      AFormat: TMaxTextFormat = fmtDefault): Boolean;
    function Reply(const AText: String): Boolean;  // to the current chat
    function EditText(chat_id: Int64; const AMessageId, AText: String;
      AFormat: TMaxTextFormat = fmtDefault): Boolean;
    function DeleteMessage(chat_id: Int64; const AMessageId: String): Boolean;
    function AnswerCallbackQuery(const ACallbackId, AText: String): Boolean;
    { POST /subscriptions: register a webhook URL. ASecret (optional, 5-256
      chars of [A-Za-z0-9_-] per the schema) is echoed by the platform in the
      X-Max-Bot-Api-Secret header of every webhook request - the receiver
      compares it against its configuration to reject spoofed updates }
    function SetWebhook(const AURL: String;
      const ASecret: String = ''): Boolean;
    function DeleteWebhook(const AURL: String): Boolean;
    { Two-step upload: POST /uploads?type= then POST the file to the returned
      URL. Returns the attachment token; EmptyStr on an unassigned stream, a
      transport, upload-URL/file-name/response validation or HTTP status
      failure. Construction failures (no HTTP broker unit registered, OOM)
      and configuration errors (EMaxConfig from ValidateHTTPConfig) are not
      transport - they raise to the caller }
    function UploadFile(AnUploadType: TMaxUploadType; AStream: TStream;
      const AFileName: String): String;
    function UploadFileByFileName(AnUploadType: TMaxUploadType;
      const AFileName: String): String;
    { Media senders: ATokenOrURL is an upload token or an existing media URL }
    function sendPhoto(chat_id: Int64; const ATokenOrURL: String): Boolean;
    function sendVideo(chat_id: Int64; const ATokenOrURL: String): Boolean;
    function sendFile(chat_id: Int64; const ATokenOrURL: String): Boolean;
    function sendAudio(chat_id: Int64; const ATokenOrURL: String): Boolean;
    function sendPhotoByFileName(chat_id: Int64; const AFileName: String): Boolean;
    function sendVideoByFileName(chat_id: Int64; const AFileName: String): Boolean;
    function sendFileByFileName(chat_id: Int64; const AFileName: String): Boolean;
    function sendAudioByFileName(chat_id: Int64; const AFileName: String): Boolean;

    { Runs command handlers for AMessage text (commands start with '/'; an
      optional @bot mention before and ':params' after the command name are
      part of the grammar, td-017 - the handler still reads the full text
      from the message itself). In group chats (chat/channel) with a set
      OwnUsername the command must additionally be addressed to OUR bot:
      '@'+OwnUsername before the slash, otherwise the message is ignored }
    procedure ProcessCommands(AMessage: TMaxMessageObj; AHandlers: TCommandHandlersMap);

    { Concurrency note for the configuration properties below (APIEndPoint,
      Token, Timeout, HTTPProxy*, SSLCAFile, SSLVerifyCert): the WRITERS are
      serialized by FClientPoolCS - safe to set while the sender serves
      requests, the pool picks the change up lazily on the next acquire's
      drift check. The readers return the field DIRECTLY, without the lock
      (the section is not reentrant and GetAPIEndPoint has callers that
      already hold it). Do not READ a config property while another thread
      reconfigures the same sender: a String read racing a locked String
      write can chase a freed managed buffer. Read the configuration before
      the sender starts serving requests, or synchronize the reads on the
      host side; the library's own request paths work from snapshots taken
      under the lock }
    property APIEndPoint: String read GetAPIEndPoint write SetAPIEndPoint;
    property Token: String read FToken write SetToken;
    property Marker: String read FMarker write FMarker;
    property BotInfo: TMaxBotInfoObj read FBotInfo;
    { The card of the chat fetched by the last successful GetChat (owned,
      freed on Destroy) }
    property Chat: TMaxChatObj read FChat;
    property Response: String read FResponse;
    property JSONResponse: TJSONData read FJSONResponse;
    property LastErrorCode: String read FLastErrorCode;
    property LastErrorMsg: String read FLastErrorMsg;
    { Milliseconds. A pure configuration value: the long-polling call passes
      max(this, window + 3 s) as the per-request IO timeout and never writes
      the field (td-018) - it reads the same during and after a poll. The
      write is serialized like the other config writes (see SetTimeout); the
      read has the same limitation as the other config property readers above }
    property Timeout: Integer read FTimeout write SetTimeout;
    property ProcessUpdate: Boolean read FProcessUpdate write FProcessUpdate;
    property LogDebug: Boolean read FLogDebug write FLogDebug;
    property UpdateLogger: TMaxStatLog read FUpdateLogger write FUpdateLogger;
    property OnLogMessage: TLogMessageEvent read FOnLogMessage write FOnLogMessage;
    property OnReceiveUpdate: TOnUpdateEvent read FOnReceiveUpdate write FOnReceiveUpdate;
    property OnAnyUpdate: TOnUpdateEvent read FOnAnyUpdate write FOnAnyUpdate;
    property OnReceiveMessage: TMessageEvent read FOnReceiveMessage write FOnReceiveMessage;
    property OnReceiveEditedMessage: TMessageEvent read FOnReceiveEditedMessage write FOnReceiveEditedMessage;
    property OnReceiveCallback: TCallbackEvent read FOnReceiveCallback write FOnReceiveCallback;
    property OnBotStarted: TUserEvent read FOnBotStarted write FOnBotStarted;
    property OnUserAdded: TUserEvent read FOnUserAdded write FOnUserAdded;
    property OnUserRemoved: TUserEvent read FOnUserRemoved write FOnUserRemoved;
    property OnChatTitleChanged: TChatEvent read FOnChatTitleChanged write FOnChatTitleChanged;
    property CommandHandlers [const Command: String]: TCommandEvent read GetCommandHandlers
      write SetCommandHandlers;  // It can create command handlers by assigning their to array elements
    { The bot's own username (GetMe -> BotInfo.Username): the consumer sets
      it once after GetMe. The setter normalizes the value - Trim plus all
      leading '@' characters off - so a pasted full mention cannot disable
      the group filter (stored verbatim, a leading-@ value would compare as
      '@@bot' and match no mention). ProcessCommands uses it in group chats
      (chat/channel) to drop commands addressed to a foreign @bot; an EMPTY
      value keeps the permissive grammar (any mention accepted, no
      addressing required) - the pre-filter behavior. Plain field read,
      unlocked write (a String assignment): set it before the sender starts
      serving requests, like the other configuration properties above }
    property OwnUsername: String read FOwnUsername write SetOwnUsername;
    property CurrentMessage: TMaxMessageObj read FCurrentMessage;
    property CurrentUser: TMaxUserObj read FCurrentUser;
    property CurrentChatId: Int64 read FCurrentChatId;
    property HTTPProxyUser: String read FHTTPProxyUser write SetHTTPProxyUser;
    property HTTPProxyPassword: String read FHTTPProxyPassword write SetHTTPProxyPassword;
    property HTTPProxyHost: String read FHTTPProxyHost write SetHTTPProxyHost;
    property HTTPProxyPort: Word read FHTTPProxyPort write SetHTTPProxyPort;
    { An empty SSLCAFile with SSLVerifyCert=True trusts the shipped bundle
      (looked up ONLY next to the executable - never in the current directory,
      a writable CWD is not a trust source) AND the system store, merged into
      one per-process bundle (either source alone is enough). A set SSLCAFile
      is handed to the broker as is - the FCL broker treats the pin as the
      EXCLUSIVE trust anchor; the canonical contract is the SSLCAFile doc
      comment in maxbasehttpclient.pas (td-010). Raises when
      neither source is found - see ResolveTrustAnchor }
    property SSLCAFile: String read FSSLCAFile write SetSSLCAFile;
    { False disables certificate verification entirely - for local testing
      only; True with no resolvable trust anchor raises - see SSLCAFile }
    property SSLVerifyCert: Boolean read FSSLVerifyCert write SetSSLVerifyCert;
  end;

  TMaxBotEvent = procedure(ASender: TObject) of object;

var
  { MAX Bot API base URL. The bot token is NOT part of the URL: it is sent
    in the Authorization header of every request (see CreateHTTPClient) }
  MaxAPI_URL: String ='https://platform-api2.max.ru';

function TMaxBotSendMessage(const AToken: String; chat_id: Int64; const AMessage: String;
  AAttachments: TJSONArray = nil): Boolean;

// Compact serialization of an fpjson tree: {"key":value} / [v1,v2] with no
// whitespace outside strings. WHY not TJSONData.AsJSON: in FPC 3.2.2 it
// returns the padded form ({ "key" : "value" }), and the MAX API rejects a
// padded body carrying non-empty attachments - HTTP 400 proto.payload
// "Can't deserialize body" (verified live), while the compact form with the
// same attachments is accepted. Objects, arrays and strings are written by
// this function; every finite scalar (null, booleans, integer/int64/float
// numbers) delegates to its own AsJSON, which is already compact and is the
// single source of fpjson number formatting - a non-number float (NaN or
// Infinity) is the exception: fpjson renders it as a padded invalid token
// ("Nan", "+Inf"), so the guard raises instead. Strings keep their
// non-ASCII bytes as raw UTF-8 - the API accepts it, and re-encoding valid
// text would only risk corrupting it
function JSONCompact(AData: TJSONData): String;

{ APairs: Text1, Payload1, Text2, Payload2, ... - the flat convention of
  MaxCallbackButtons in bot_ex. Returns the SendMessageEx attachments array
  holding ONE inline_keyboard attachment whose buttons are all the pairs of
  a SINGLE row: [{"type":"inline_keyboard","payload":{"buttons":[[...]]}}].
  The result is owned by the caller: SendMessageEx and TMaxBotSendMessage
  clone their argument and free neither - free the array after the call,
  even when the send raises (a configuration error raises EMaxConfig by
  design). Do not Add() the array into another attachments array - it
  already is one. WHY the buttons array is always two-dimensional: the API
  rejects a one-dimensional buttons array with HTTP 400 proto.payload
  (verified live), so a flat result is impossible by construction. The
  strings are escaped by the serializer that writes the request body
  (JSONCompact's JSONEscapeString); no manual escaping. An odd pair count or
  an empty list is a caller bug and raises Exception. Link buttons and
  multi-row keyboards are out of scope - the row-based bot_ex helpers
  (MaxKeyboardRow / MaxCallbackButton / MaxLinkButton /
  MaxInlineKeyboardAttachment) serve those; no button record type is
  introduced - Text/Payload live only in this comment }
function MakeInlineKeyboardAttachment(
  const APairs: array of String): TJSONArray;

implementation

{$IFDEF UNIX}
uses
  baseunix; // private bundle dir + exclusive creation (FpMkDir, fpOpen/O_EXCL)
{$ENDIF}

var
  { The path of the merged default CA bundle while it is resolved.
    WHY cached here: the sources (the shipped bundle and the system store) are
    static for the lifetime of the process, and the merged temp file costs a
    ~200-333 KB write - pay it once per process, not per request (td-011).
    WHY empty is not cached: a source that appears later must be picked up,
    and the empty path costs two FileExists calls }
  _MergedDefaultCAPath: String = '';
  { Guards _MergedDefaultCAPath: CreateHTTPClient runs on the long-polling
    receiver thread, the main thread and arbitrary host threads, so the cache
    is both read and written under this lock (no unlocked fast path) }
  _MergedDefaultCALock: TRTLCriticalSection;

class function TIntegerHash.hash(i: Int64; n: Integer): Integer;
begin
  Result:=i mod n;
  if Result<0 then
    Inc(Result, n);
end;

const
  s_Authorization = 'Authorization';
  s_ContentType = 'Content-Type';
  s_JSONMime = 'application/json';
  s_PathMe = '/me';
  s_PathChats = '/chats/';
  s_PathUpdates = '/updates';
  s_PathMessages = '/messages';
  s_PathAnswers = '/answers';
  s_PathUploads = '/uploads';
  s_PathSubscriptions = '/subscriptions';
  s_ShippedCAFile = 'certs/russian-trusted-root-ca.pem';
  { The naming contract of the merged CA bundle temp location, one template
    for both directions: the build formats a fresh GUID tail into it, the
    finalization sweep formats '*' - cleanup matches by construction what
    build created. The literal hyphen before the tail scopes the match to
    GUID-suffixed entries of this pid; widening the tail to just '*' would let
    fpmax-ca-123* match a live bundle of a foreign pid 1234 - do not }
  {$IFDEF UNIX}
  { UNIX: the bundle lives inside a per-process directory (see
    BuildMergedCAFile); the inner name is a fixed const - it is unreachable
    for a foreign uid behind the fresh 0700 directory, only the directory name
    needs the unpredictable GUID tail }
  s_MergedCADirTemplate = 'fpmax-ca-%d-%s.d';
  s_MergedCABundleName = 'bundle.pem';
  {$ELSE}
  s_MergedCAFileTemplate = 'fpmax-ca-%d-%s.pem';
  {$ENDIF}

{ The single place the bundle location (GUID tail) and the cleanup mask ('*'
  tail) come from, see the s_MergedCA*Template consts }
{$IFDEF UNIX}
function MergedCADirPattern(const ATail: String): String;
begin
  Result:=Format(s_MergedCADirTemplate, [GetProcessID, ATail]);
end;
{$ELSE}
function MergedCAFilePattern(const ATail: String): String;
begin
  Result:=Format(s_MergedCAFileTemplate, [GetProcessID, ATail]);
end;
{$ENDIF}

{ One JSON string literal, quotes included: the structural characters (quote,
  backslash) and the control range (< #20) cannot travel raw - a raw quote
  would terminate the string, a raw control byte breaks the deserializer.
  Everything else passes through untouched, including all non-ASCII UTF-8
  bytes: the API accepts raw UTF-8 and re-encoding valid text would only risk
  corrupting it. The input is an AnsiString carrying UTF-8 (fpjson's
  TJSONStringType on this toolchain), so the scan is byte-wise and the
  multibyte sequences never match an ASCII structural byte. There is no
  UTF-8 validation: a non-structural byte travels as is even where it breaks
  a multibyte sequence - the transport is trusted, and fpjson's own parser
  does not validate UTF-8 either }
function JSONEscapeString(const AValue: String): String;
var
  I: Integer;
  Ch: AnsiChar;
begin
  Result:=EmptyStr;
  for I:=1 to Length(AValue) do
  begin
    Ch:=AValue[I];
    case Ch of
      // Pascal string literals have no escape syntax: '\' below is a lone
      // backslash, the JSON escape pairs are assembled at runtime
      '"':  Result+='\'+'"';
      '\':  Result+='\'+'\';
      #8:   Result+='\b';
      #9:   Result+='\t';
      #10:  Result+='\n';
      #12:  Result+='\f';
      #13:  Result+='\r';
    else
      if Ch<#32 then
        Result+=Format('\u%.4x', [Ord(Ch)])
      else
        Result+=Ch;
    end;
  end;
end;

function JSONCompact(AData: TJSONData): String;
var
  I: Integer;
  V: TJSONFloat;
begin
  // ApiCall guards with Assigned before serializing; nil stays a legal input
  // here and yields the empty string (an empty body is servable - see
  // TMaxStringBodyStream)
  if AData=nil then
    Exit(EmptyStr);
  if AData is TJSONObject then
  begin
    Result:='{';
    for I:=0 to TJSONObject(AData).Count-1 do
    begin
      if I>0 then
        Result+=',';
      // Names are strings on the wire too - a parsed key can carry the same
      // structural characters as a value
      Result+='"'+JSONEscapeString(TJSONObject(AData).Names[I])+'":'
        +JSONCompact(TJSONObject(AData).Items[I]);
    end;
    Result+='}';
  end
  else if AData is TJSONArray then
  begin
    Result:='[';
    for I:=0 to TJSONArray(AData).Count-1 do
    begin
      if I>0 then
        Result+=',';
      Result+=JSONCompact(TJSONArray(AData).Items[I]);
    end;
    Result+=']';
  end
  else if AData is TJSONString then
    // AsString is the raw stored bytes; the Value property converts through
    // a wide string and replaces every non-ASCII byte with a question mark
    // when the codepages of the units involved disagree (observed on darwin)
    Result:='"'+JSONEscapeString(TJSONString(AData).AsString)+'"'
  else if AData is TJSONFloatNumber then
  begin
    // A non-number float (NaN or Infinity) raises instead of emitting an
    // unparseable body - WHY: see the JSONCompact doc comment above. The
    // value goes through the typed AsFloat getter into a local: the inherited
    // Value property is a Variant, and IsNan/IsInfinite on it convert through
    // Single - finite doubles beyond MaxSingle crash there (EAccessViolation)
    V:=TJSONFloatNumber(AData).AsFloat;
    if IsNan(V) or IsInfinite(V) then
      raise EJSON.Create('NaN/Infinity floats are not JSON-serializable');
    Result:=AData.AsJSON;
  end
  else
    // The remaining scalars (null, booleans, integer and int64 numbers)
    Result:=AData.AsJSON;
end;

function MakeInlineKeyboardAttachment(
  const APairs: array of String): TJSONArray;
var
  I: Integer;
  Attachment, Payload, Buttons: TJSONObject;
  Rows, Row: TJSONArray;
begin
  // A dangling Text without a Payload or an empty keyboard are caller bugs:
  // fail loudly instead of shipping a body the API answers with HTTP 400
  if (Length(APairs)=0) or Odd(Length(APairs)) then
    raise Exception.Create(
      'MakeInlineKeyboardAttachment: pairs must be Text,Payload,...');
  // Built top-down: every node is attached to its parent right after Create,
  // so the single guard below frees the whole partial tree on any failure
  Result:=TJSONArray.Create;
  try
    Attachment:=TJSONObject.Create;
    Result.Add(Attachment); // the attachment is owned by the array now
    Attachment.Add('type', 'inline_keyboard');
    Payload:=TJSONObject.Create;
    Attachment.Add('payload', Payload); // the payload is owned by the attachment
    // buttons is the array OF rows and the single row is its only member:
    // putting the row straight into buttons would ship the flat 1D form the
    // API rejects with HTTP 400 proto.payload
    Rows:=TJSONArray.Create;
    Payload.Add('buttons', Rows); // the rows are owned by the payload now
    Row:=TJSONArray.Create;
    Rows.Add(Row); // the single row is owned by the rows now
    I:=0;
    while I+1<=High(APairs) do
    begin
      Buttons:=TJSONObject.Create;
      Row.Add(Buttons);
      Buttons.Add('type', 'callback');
      Buttons.Add('text', APairs[I]);
      Buttons.Add('payload', APairs[I+1]);
      Inc(I, 2);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TMaxBotSendMessage(const AToken: String; chat_id: Int64; const AMessage: String;
  AAttachments: TJSONArray): Boolean;
var
  ABot: TMaxSender;
begin
  ABot:=TMaxSender.Create(AToken);
  try
    Result:=ABot.SendMessageEx(chat_id, AMessage, AAttachments);
  finally
    ABot.Free;
  end;
end;

{ TStringHash }

class function TStringHash.hash(s: String; n: Integer): Integer;
var
  g: Integer;
  I: Integer;
begin
  Result := 0;
  s := LowerCase(s);
  for I := 1 to Length(s) do
  begin
    Result := (Result shl 4) + Ord(s[I]);
    g := Result and $F0000000;
    if g <> 0 then
    begin
      Result := Result xor (g shr 24);
      Result := Result and not g;
    end;
  end;
  Result := Result mod n;
  if Result < 0 then
    Inc(Result, n);
end;

{ TMaxSender }

procedure TMaxSender.ErrorMessage(const AMsg: String);
begin
  if Assigned(FOnLogMessage) then
    FOnLogMessage(Self, etError, AMsg);
end;

procedure TMaxSender.DebugMessage(const AMsg: String);
begin
  if FLogDebug and Assigned(FOnLogMessage) then
    FOnLogMessage(Self, etDebug, AMsg);
end;

procedure TMaxSender.SafeErrorMessage(const AMsg: String);
begin
  // ErrorMessage is a user callback: a raising callback must not break the
  // failure contract of the code that reports through it - the diagnostic
  // line is best-effort, the EmptyStr fold (or the raise right after it,
  // td-076) is the contract
  try
    ErrorMessage(AMsg);
  except
  end;
end;

class function TMaxSender.HasControlChars(const S: String): Boolean;
var
  I: Integer;
begin
  for I:=1 to Length(S) do
    if (S[I]<#32) or (S[I]=#127) then
      Exit(True);
  Result:=False;
end;

class function TMaxSender.DefaultSystemCAFile: String;
begin
  // virtual: the offline tests inject fixture paths here
  {$IFDEF LINUX}
    if FileExists('/etc/ssl/certs/ca-certificates.crt') then  // Debian/Ubuntu
      Exit('/etc/ssl/certs/ca-certificates.crt');
    if FileExists('/etc/pki/tls/certs/ca-bundle.crt') then    // RHEL family
      Exit('/etc/pki/tls/certs/ca-bundle.crt');
  {$ENDIF}
  {$IFDEF DARWIN}
    if FileExists('/etc/ssl/cert.pem') then                   // macOS system (LibreSSL)
      Exit('/etc/ssl/cert.pem');
    if FileExists('/opt/homebrew/etc/openssl@3/cert.pem') then
      Exit('/opt/homebrew/etc/openssl@3/cert.pem');
    if FileExists('/usr/local/etc/openssl@3/cert.pem') then
      Exit('/usr/local/etc/openssl@3/cert.pem');
  {$ENDIF}
  Result:=EmptyStr;
end;

class function TMaxSender.ShippedCAFile: String;
begin
  // virtual: the offline tests inject fixture paths here. No CWD fallback:
  // the current directory of a daemon or a CI runner is attacker-writable
  // territory, a planted PEM there would become a trust anchor (td-034) -
  // the shipped bundle is only trusted next to the executable or via an
  // explicit SSLCAFile
  Result:=ExtractFilePath(ParamStr(0))+s_ShippedCAFile;
  if not FileExists(Result) then
    Result:=EmptyStr;
end;

class function TMaxSender.BuildMergedCAFile(const AShippedCAFile,
  ASystemCAFile: String): String;
var
  lDest: TStream;
  lSource: TFileStream;
  lDirName: String;
  lDestName: String;
  LastByte, LF: Char;
  {$IFDEF UNIX}
  FD: cInt;
  Attempt: Integer;
  lDirCreated: Boolean;
  lDirInfo: Stat;
  {$ENDIF}
  lGUID: TGUID;
begin
  lDest:=nil;
  lDirName:=EmptyStr;
  try
    // The temp directory may be shared with other local users, and the
    // bundle is a trust anchor re-read from its path by the TLS library on
    // every handshake: a predictable name would let a local user pre-plant
    // the path (or a symlink to it) and swap the anchors for their own root,
    // or fail-closed the resolution with a planted directory. The pid prefix
    // keeps concurrent library users apart, a fresh GUID suffix makes the
    // name unpredictable and resolves clashes (and stale leftovers of
    // recycled pids) without opening them - on every platform
    {$IFDEF UNIX}
    // The bundle is built inside a per-process directory created with mode
    // 0700: only this uid can traverse it, so after the creation no foreign
    // process can read, replace or symlink the bundle through its path - the
    // direct path-read window of a shared non-sticky temp dir is closed for
    // the file contents (td-035: the unpredictable name above guards the
    // creation, the private dir guards every later path read). What 0700 does
    // NOT cover: the directory entry itself lives in the parent temp, and a
    // rename(2) needs write access on the parent only - in a shared non-sticky
    // temp a foreign uid can still move the directory aside and replant a
    // same-named one, so a sticky (or foreign-unwritable) temp stays a
    // deployment requirement. A umask can only subtract from the
    // requested directory mode, never add to it. O_CREAT|O_EXCL then opens
    // only a freshly created inode and per POSIX fails with EEXIST on an
    // existing entry even when it is a symlink; mode 0600 keeps the bundle
    // private regardless of the umask
    lDirCreated:=False;
    for Attempt:=1 to 8 do
    begin
      // same check as the Windows branch below: a failed CreateGUID leaves
      // the record uninitialized - eight attempts would format the same stack
      // garbage into the same name and fail on it eight times
      if CreateGUID(lGUID)<>0 then
        raise EMaxConfig.Create('CreateGUID failed');
      lDirName:=IncludeTrailingPathDelimiter(GetTempDir)
        +MergedCADirPattern(Copy(GUIDToString(lGUID), 2, 36));
      if FpMkDir(lDirName, S_IRUSR or S_IWUSR or S_IXUSR)=0 then
      begin
        // fail closed if the filesystem did not honor the requested mode
        // (permission-less mounts like vfat/exfat or mapped CIFS/NFS): a
        // world-readable directory hands the fixed bundle name to every uid,
        // a writable-by-others one lets them swap the bundle in place
        if (FpStat(lDirName, lDirInfo)<>0)
          or (lDirInfo.st_uid<>fpgeteuid)
          or ((lDirInfo.st_mode and &777)<>(S_IRUSR or S_IWUSR or S_IXUSR)) then
        begin
          // not lDirCreated yet - the except above would not clean it up;
          // best-effort removal: a failure here leaves an empty directory
          // behind until the finalization sweep
          RemoveDir(lDirName);
          raise EMaxConfig.Create('The merged CA bundle directory "'
            +lDirName+'" did not come up private (0700, this uid only)');
        end;
        lDirCreated:=True;
        Break;
      end;
      if fpgeterrno<>ESysEEXIST then
        raise EMaxConfig.Create('Cannot create the merged CA bundle directory "'
          +lDirName+'": '+SysErrorMessage(Integer(fpgeterrno)));
    end;
    if not lDirCreated then
      raise EMaxConfig.Create('Cannot create the merged CA bundle directory: '
        +'all name attempts under '+GetTempDir+' are taken');
    // the fixed inner name sits behind the fresh 0700 directory this call
    // just created, so one O_EXCL attempt is enough - a clash would mean a
    // kernel-level violation, fail closed on it
    lDestName:=IncludeTrailingPathDelimiter(lDirName)+s_MergedCABundleName;
    FD:=fpOpen(lDestName, O_WRONLY or O_CREAT or O_EXCL, S_IRUSR or S_IWUSR);
    if FD<0 then
      raise EMaxConfig.Create('Cannot create the merged CA bundle file "'
        +lDestName+'": '+SysErrorMessage(Integer(fpgeterrno)));
    // the RTL stream wraps the already opened fd (it does not own it)
    lDest:=THandleStream.Create(THandle(FD));
    {$ELSE}
    // Windows: %TEMP% is per-user only for interactive sessions - a service
    // running as LocalSystem gets the shared-writable C:\Windows\Temp, so
    // predictability, not the directory, was the risk; with the fresh GUID
    // suffix pre-planting is impossible and the plain RTL stream (fmCreate)
    // is enough - truncating a planted or leftover entry is practically
    // unreachable, nothing but this call knows the name
    // the fresh suffix is drawn per branch: the UNIX retry loop above gets
    // its own GUID on every attempt, this branch needs exactly one (a TGUID
    // is an unmanaged record - left alone it formats stack garbage)
    if CreateGUID(lGUID)<>0 then raise EMaxConfig.Create('CreateGUID failed');
    lDestName:=IncludeTrailingPathDelimiter(GetTempDir)
      +MergedCAFilePattern(Copy(GUIDToString(lGUID), 2, 36));
    lDest:=TFileStream.Create(lDestName, fmCreate);
    {$ENDIF}
    try
      lSource:=TFileStream.Create(AShippedCAFile, fmOpenRead or fmShareDenyWrite);
      try
        lDest.CopyFrom(lSource, lSource.Size);
        // the next BEGIN line needs the previous END line terminated
        if lSource.Size>0 then
        begin
          lSource.Seek(-1, soEnd);
          lSource.ReadBuffer(LastByte, 1);
          if LastByte<>#10 then
          begin
            LF:=#10;
            lDest.WriteBuffer(LF, 1);
          end;
        end;
      finally
        lSource.Free;
      end;
      lSource:=TFileStream.Create(ASystemCAFile, fmOpenRead or fmShareDenyWrite);
      try
        lDest.CopyFrom(lSource, lSource.Size);
      finally
        lSource.Free;
      end;
    finally
      lDest.Free;
      {$IFDEF UNIX}
      fpClose(FD);
      {$ENDIF}
    end;
    Result:=lDestName;
  except
    // a partial bundle is worse than none: the backend would trust a
    // truncated store; delete only what this call created (a failed open
    // must not remove a pre-planted foreign entry)
    {$IFDEF UNIX}
    // lDirCreated is set only after a successful FpMkDir, so the directory is
    // this call's own fresh private one, never a foreign or pre-planted
    // entry - clear it whole (the bundle inside plus the empty shell)
    if lDirCreated then
    begin
      DeleteFile(lDestName);
      RemoveDir(lDirName);
    end;
    {$ELSE}
    if lDest<>nil then
      DeleteFile(lDestName);
    {$ENDIF}
    raise;
  end;
end;

class function TMaxSender.ResolveDefaultCAFile(const AShippedCAFile,
  ASystemCAFile: String): String;
begin
  // Merging one file would be that file: a single source passes through as
  // is, so systems without the system bundle keep the current behavior
  if (AShippedCAFile<>EmptyStr) and (ASystemCAFile<>EmptyStr) then
    Result:=BuildMergedCAFile(AShippedCAFile, ASystemCAFile)
  else if AShippedCAFile<>EmptyStr then
    Result:=AShippedCAFile
  else
    Result:=ASystemCAFile;
end;

class function TMaxSender.MergedDefaultCAFile: String;
var
  lResolved: String;
begin
  EnterCriticalSection(_MergedDefaultCALock);
  try
    if _MergedDefaultCAPath<>EmptyStr then
      Exit(_MergedDefaultCAPath);
    lResolved:=ResolveDefaultCAFile(ShippedCAFile, DefaultSystemCAFile);
    // an empty result is not cached - a source that appears later must be
    // picked up (two FileExists calls next to the handshake are negligible)
    if lResolved<>EmptyStr then
      _MergedDefaultCAPath:=lResolved;
    Result:=lResolved;
  finally
    LeaveCriticalSection(_MergedDefaultCALock);
  end;
end;

class procedure TMaxSender.ResetMergedCACache;
begin
  EnterCriticalSection(_MergedDefaultCALock);
  try
    _MergedDefaultCAPath:=EmptyStr;
  finally
    LeaveCriticalSection(_MergedDefaultCALock);
  end;
end;

function TMaxSender.ResolveTrustAnchor(const ACAFile: String;
  AVerifyCert: Boolean): String;
begin
  // A set SSLCAFile is the ONLY trust anchor, exactly as configured (no
  // FileExists check - the backend reports a missing explicit file); the
  // wire trust beyond this hand-off is per transport - see the SSLCAFile
  // doc comment in maxbasehttpclient.pas
  if ACAFile<>EmptyStr then
    Exit(ACAFile);
  if AVerifyCert then
    Result:=MergedDefaultCAFile
  else
    // Verification is off and no anchor is needed: keep the old fall-through
    // that still hands the system store to the broker when it is found
    Result:=DefaultSystemCAFile;
  if AVerifyCert and (Result=EmptyStr) then
  begin
    // A user callback: see the ErrorMessage contract - this must never run
    // while FClientPoolCS is held. Guarded: the raise below is the contract
    // (EMaxConfig), a throwing log handler must not replace it (td-076)
    SafeErrorMessage('No trusted CA bundle found for TLS verification (looked for the '
      +'bundled certs/russian-trusted-root-ca.pem next to the executable, then '
      +'the system store; either of the two is enough). Copy the bundle next '
      +'to the executable, make the system CA store available, or set '
      +'SSLCAFile');
    raise EMaxConfig.Create('TLS trust anchor not found: set SSLCAFile');
  end;
end;

procedure TMaxSender.AssignHTTProxy(aHTTPClient: TBaseHTTPClient;
  const AConfig: TMaxPoolConfig);
begin
  with aHTTPClient do
  begin
    HTTPProxyHost:=AConfig.ProxyHost;
    HTTPProxyPort:=AConfig.ProxyPort;
    HTTPProxyUsername:=AConfig.ProxyUser;
    HTTPProxyPassword:=AConfig.ProxyPass;
  end;
end;

procedure TMaxSender.ValidateHTTPConfig(const AConfig: TMaxPoolConfig;
  out AResolvedCAFile: String);
var
  lToken: String;
begin
  { MAX Bot API auth: the raw access token in the Authorization header,
    without the Bearer prefix (per dev.max.ru/docs-api) }
  lToken:=Trim(AConfig.Token);
  if (Pos(#13, lToken)>0) or (Pos(#10, lToken)>0) or (Pos(#0, lToken)>0) then
  begin
    // Guarded: the raise below is the contract (EMaxConfig), a throwing log
    // handler must not replace it (td-076)
    SafeErrorMessage('Bot token contains line breaks or NUL - check the configuration');
    raise EMaxConfig.Create('Invalid bot token: control characters');
  end;
  // Resolve the trust anchor before any client is created: the resolution
  // raises (fail-closed) when verification is on and no source is found, and
  // a raise after Create would leak the client
  AResolvedCAFile:=ResolveTrustAnchor(AConfig.CAFile, AConfig.VerifyCert);
end;

function TMaxSender.CreateHTTPClient(AWithAuth: Boolean;
  const AConfig: TMaxPoolConfig; const ACAFile: String;
  ATimeout: Integer): TBaseHTTPClient;
var
  lToken: String;
begin
  // The configuration copy has passed ValidateHTTPConfig (the caller
  // resolves the anchor from the SAME copy, outside the lock): building here
  // reports nothing and runs no user code, so it is safe under FClientPoolCS
  Result:=TBaseHTTPClient.GetClientClass.Create(nil);
  AssignHTTProxy(Result, AConfig);
  Result.IOTimeout:=ATimeout;
  lToken:=Trim(AConfig.Token);
  if AWithAuth then
    Result.AddHeader(s_Authorization, lToken);
  Result.SSLVerifyCert:=AConfig.VerifyCert;
  Result.SSLCAFile:=ACAFile;
end;

procedure TMaxSender.ReadPoolConfig(out AConfig: TMaxPoolConfig);
begin
  // caller holds FClientPoolCS: the setters hold it too, so no field read
  // here races a write (and GetAPIEndPoint is safe to call - it never takes
  // the lock itself)
  AConfig.Token:=Trim(FToken);
  AConfig.EndPoint:=GetAPIEndPoint;
  AConfig.ProxyHost:=FHTTPProxyHost;
  AConfig.ProxyPort:=FHTTPProxyPort;
  AConfig.ProxyUser:=FHTTPProxyUser;
  AConfig.ProxyPass:=FHTTPProxyPassword;
  AConfig.CAFile:=FSSLCAFile;
  AConfig.VerifyCert:=FSSLVerifyCert;
end;

procedure TMaxSender.PoolConfigSnapshot;
begin
  // caller holds FClientPoolCS
  ReadPoolConfig(FPoolConfig);
  FPoolConfigValid:=True;
end;

function TMaxSender.ConfigDrifted(const AConfig: TMaxPoolConfig): Boolean;
begin
  // caller holds FClientPoolCS; the token is normalized the same way
  // CreateHTTPClient normalizes it before the request goes out
  Result:=(AConfig.Token<>Trim(FToken))
    or (AConfig.EndPoint<>GetAPIEndPoint)
    or (AConfig.ProxyHost<>FHTTPProxyHost)
    or (AConfig.ProxyPort<>FHTTPProxyPort)
    or (AConfig.ProxyUser<>FHTTPProxyUser)
    or (AConfig.ProxyPass<>FHTTPProxyPassword)
    or (AConfig.CAFile<>FSSLCAFile)
    or (AConfig.VerifyCert<>FSSLVerifyCert);
end;

function TMaxSender.PoolConfigDrifted: Boolean;
begin
  // caller holds FClientPoolCS
  Result:=not FPoolConfigValid or ConfigDrifted(FPoolConfig);
end;

function TMaxSender.AcquireAPIClient(out AEndPoint: String;
  out ATimeoutMs: Integer): TBaseHTTPClient;
var
  I: Integer;
  NewClient: TBaseHTTPClient;
  lConfig: TMaxPoolConfig;
  lCAFile: String;
  lTimeout: Integer;
  NeedNew: Boolean;

  procedure DropIdleSlot(Index: Integer);
  var
    J: Integer;
  begin
    // caller holds FClientPoolCS; removal keeps the array dense (every slot
    // always owns a client)
    FClientPool[Index].Client.Free;
    FClientPool[Index].Client:=nil;
    for J:=Index to High(FClientPool)-1 do
      FClientPool[J]:=FClientPool[J+1];
    SetLength(FClientPool, High(FClientPool));
  end;

begin
  Result:=nil;
  NeedNew:=False;
  System.EnterCriticalSection(FClientPoolCS);
  try
    // One drift check replaces hooks on every setter: idle clients die now,
    // checked-out ones are marked Stale (they die on release), the snapshot
    // is refreshed so the next client is built from the current configuration.
    // The host switch must drop the pool: FPC 3.2.2 keep-alive does not check
    // a host change on the open connection
    if PoolConfigDrifted then
    begin
      for I:=High(FClientPool) downto 0 do
        if FClientPool[I].InUse then
          FClientPool[I].Stale:=True
        else
          DropIdleSlot(I);
      PoolConfigSnapshot;
    end;
    for I:=0 to High(FClientPool) do
      if not FClientPool[I].InUse then
      begin
        FClientPool[I].InUse:=True;
        FClientPool[I].Stale:=False;
        Result:=FClientPool[I].Client;
        // td-049: paired with the client in the same section - after the
        // drift check above the fields match the snapshot every pooled
        // client was built from, so the URL built from AEndPoint carries
        // the same configuration generation as the client's token
        AEndPoint:=GetAPIEndPoint;
        ATimeoutMs:=FTimeout;
        exit;
      end;
    // Grow. The client is built from a COPY of the configuration taken here
    // (the setters hold this lock, so the copy is race-free), while the
    // validation and the trust-anchor resolution report through the user's
    // ErrorMessage callback and must run OUTSIDE the lock below: a setter
    // (or this Acquire itself) re-entered from the callback would self-
    // deadlock on the non-reentrant section. The connection itself opens
    // later, on the first request of the verb - the network never runs
    // under this lock
    ReadPoolConfig(lConfig);
    lTimeout:=FTimeout;
    // td-049: the caller receives THIS copy, not the later field values -
    // request and client stay one configuration generation even if the
    // fields drift before the client is installed below
    AEndPoint:=lConfig.EndPoint;
    ATimeoutMs:=lTimeout;
    NeedNew:=True;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
  if NeedNew then
  begin
    // Outside the lock: may run the user's log callback and raise (a broken
    // configuration leaves the pool untouched, the caller gets the exception)
    ValidateHTTPConfig(lConfig, lCAFile);
    // Re-enter to build and install: the builder is pure (no validation, no
    // callbacks, no field reads - it works from the copy), so it may run
    // under the lock. Between the two sections the configuration may have
    // drifted: a client born from the outdated copy is marked Stale here and
    // dies on its first release. The caller's endpoint/timeout pair was read
    // from that same copy in the first section (td-049), so this one request
    // is self-consistent old-generation - a coherent pair instead of the old
    // endpoint against the new token
    System.EnterCriticalSection(FClientPoolCS);
    try
      NewClient:=CreateHTTPClient(True, lConfig, lCAFile, lTimeout);
      SetLength(FClientPool, Length(FClientPool)+1);
      FClientPool[High(FClientPool)].Client:=NewClient;
      FClientPool[High(FClientPool)].InUse:=True;
      FClientPool[High(FClientPool)].Stale:=ConfigDrifted(lConfig);
      Result:=NewClient;
    finally
      System.LeaveCriticalSection(FClientPoolCS);
    end;
  end;
end;

procedure TMaxSender.ReleaseAPIClient(AClient: TBaseHTTPClient; AFailed: Boolean);
var
  I, J: Integer;
begin
  if AClient=nil then
    exit;
  System.EnterCriticalSection(FClientPoolCS);
  try
    for I:=0 to High(FClientPool) do
      if FClientPool[I].Client=AClient then
      begin
        // A transport exception leaves the connection state not to be trusted
        // (a zombie socket at worst), so the client dies and the next call
        // starts from a fresh one; a stale client was built from the old
        // configuration and dies for the same reason
        if AFailed or FClientPool[I].Stale then
        begin
          for J:=I to High(FClientPool)-1 do
            FClientPool[J]:=FClientPool[J+1];
          SetLength(FClientPool, High(FClientPool));
          AClient.Free;
        end
        else
          FClientPool[I].InUse:=False;
        exit;
      end;
    // Defensive: no slot owns this client, the caller is its only reference
    AClient.Free;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.RemoveContentTypeHeader(AHTTP: TBaseHTTPClient);
var
  I: Integer;
begin
  // IndexOfName+Delete, not Values['']: the brokers keep the separator ':' in
  // the stored strings, a Values read would rewrite them as 'Name=Value'
  I:=AHTTP.RequestHeaders.IndexOfName(s_ContentType);
  while I>=0 do
  begin
    AHTTP.RequestHeaders.Delete(I);
    I:=AHTTP.RequestHeaders.IndexOfName(s_ContentType);
  end;
end;

constructor TMaxSender.Create(const AToken: String);
begin
  inherited Create;
  FAPIEndPoint:=MaxAPI_URL;
  FToken:=AToken;
  FSSLVerifyCert:=True;
  FTimeout:=30000; // milliseconds; never mutated at request time (td-018)
  FProcessUpdate:=True;
  InitCriticalSection(FClientPoolCS);
  FCommandHandlers:=TCommandHandlersMap.Create;
  FAdminUsers:=TIntegerHashSet.Create;
end;

destructor TMaxSender.Destroy;
var
  I: Integer;
begin
  // Free the pooled clients first (they are not owned by anything else); a
  // client that is still checked out at Destroy is outside the supported
  // scenarios - as it was before the pool (a request running past the
  // owner's Destroy would already have been a use-after-free on the sender)
  System.EnterCriticalSection(FClientPoolCS);
  try
    for I:=0 to High(FClientPool) do
      FClientPool[I].Client.Free;
    FClientPool:=nil;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
  DoneCriticalSection(FClientPoolCS);
  FreeAndNil(FBotInfo);
  FreeAndNil(FChat);
  FCurrentUser:=nil;    // aliases into FUpdate, not owners
  FCurrentMessage:=nil;
  FreeAndNil(FUpdate);
  FreeAndNil(FJSONResponse);
  FreeAndNil(FCommandHandlers);
  FreeAndNil(FAdminUsers);
  inherited Destroy;
end;

procedure TMaxSender.AddAdminUser(aUser: Int64);
begin
  FAdminUsers.insert(aUser);
end;

function TMaxSender.IsAdminUser(aUser: Int64): Boolean;
begin
  Result:=FAdminUsers.contains(aUser);
end;

function TMaxSender.GetAPIEndPoint: String;
begin
  // Caller holds FClientPoolCS (the drift check, ReadPoolConfig, the
  // AcquireAPIClient checkout): this getter must never take the
  // lock itself - the non-reentrant section would self-deadlock its locked
  // callers. Lock-free APIEndPoint reads from a host thread have the same
  // limitation as the other config property readers (see the properties)
  if FAPIEndPoint=EmptyStr then
    Result:=MaxAPI_URL
  else
    Result:=FAPIEndPoint;
end;

{ The pool-config fields (snapshotted and drift-checked by
  PoolConfigSnapshot/PoolConfigDrifted under FClientPoolCS on every
  AcquireAPIClient) are written only under the same lock: an unlocked String
  write races the reader on the managed type's refcount - heap corruption,
  not just a stale value in one request. The lock is memory safety only:
  invalidation stays lazy, on the next Acquire's drift check (the "One drift
  check replaces hooks on every setter" comment), and the unchanged-value
  check under the lock keeps a re-set of the same value a no-op. The scalars
  (Word/Boolean) take the lock for uniformity, not for torn-read risk.
  Timeout (SetTimeout) is not a pool-config field - a change must not
  invalidate pooled clients, it is applied per call - but its writes take the
  same lock: it feeds the same clients, and an unlocked write racing the
  locked readers is exactly the pattern this lock exists to exclude. The
  readers snapshot it under the lock as well (AcquireAPIClient, GetUpdates,
  UploadFile) }

procedure TMaxSender.SetToken(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FToken<>AValue then
      FToken:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetHTTPProxyUser(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FHTTPProxyUser<>AValue then
      FHTTPProxyUser:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetHTTPProxyPassword(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FHTTPProxyPassword<>AValue then
      FHTTPProxyPassword:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetHTTPProxyHost(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FHTTPProxyHost<>AValue then
      FHTTPProxyHost:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetHTTPProxyPort(AValue: Word);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FHTTPProxyPort<>AValue then
      FHTTPProxyPort:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetSSLCAFile(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FSSLCAFile<>AValue then
      FSSLCAFile:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetSSLVerifyCert(AValue: Boolean);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FSSLVerifyCert<>AValue then
      FSSLVerifyCert:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetAPIEndPoint(AValue: String);
begin
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FAPIEndPoint<>AValue then
      FAPIEndPoint:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

procedure TMaxSender.SetTimeout(AValue: Integer);
begin
  // Not a pool-config field (no invalidation - see the group comment above),
  // but the write is serialized with the rest of the configuration
  System.EnterCriticalSection(FClientPoolCS);
  try
    if FTimeout<>AValue then
      FTimeout:=AValue;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
end;

function TMaxSender.ApiCall(const APath, AVerb: String; AQuery: TStrings;
  ABody: TJSONData; ATimeoutMs: Integer): Boolean;
var
  HTTP: TBaseHTTPClient;
  URL, lResp: String;
  I, StatusCode, lTimeout: Integer;
  lEndPoint: String;
  ErrObj: TJSONObject;
  Failed: Boolean;
begin
  // An unsupported verb is a programming error and stays an exception: only
  // the transport execution below is folded into the Boolean contract
  if (AVErb<>'GET') and (AVErb<>'POST') and (AVErb<>'PUT')
    and (AVErb<>'DELETE') then
    raise Exception.Create('Unsupported HTTP verb: '+AVErb);
  Result:=False;
  FLastErrorCode:=EmptyStr;
  FLastErrorMsg:=EmptyStr;
  FreeAndNil(FJSONResponse);
  FResponse:=EmptyStr;
  // The pooled client is reused across calls (keep-alive, td-032): a transport
  // failure drops it (Failed stays True), API errors and parse failures keep
  // it - the transport is healthy, only the answer was bad. The client, the
  // endpoint and the timeout come back from ONE critical section (td-049):
  // the endpoint used to be snapshotted in its own section before
  // AcquireAPIClient, and a reconfiguration between the two snapshots sent
  // the request to the old endpoint with a client carrying the new token -
  // one spurious 401
  HTTP:=AcquireAPIClient(lEndPoint, lTimeout);
  // The try opens at the checkout itself: URL building below can raise
  // (GetClientClass raises on an unregistered transport class), and only the
  // finally underneath returns the pool slot - hence Failed:=True first, an
  // escape before the request is even sent must drop the client
  try
    Failed:=True;
    // A caller-provided window (GetUpdates) is exact for this one request and
    // overrides the configured value; the field itself stays untouched (td-018)
    if ATimeoutMs>0 then
      lTimeout:=ATimeoutMs;
    URL:=lEndPoint+APath;
    if Assigned(AQuery) then
    begin
      for I:=0 to AQuery.Count-1 do
        if AQuery.ValueFromIndex[I]<>EmptyStr then
        begin
          if Pos('?', URL)=0 then
            URL:=URL+'?'
          else
            URL:=URL+'&';
          URL:=URL+AQuery.Names[I]+'='+TBaseHTTPClient.GetClientClass.EncodeUrlElement(
            AQuery.ValueFromIndex[I]);
        end;
    end;
    // Per-call only: the configured timeout paired with the client by
    // AcquireAPIClient (or the caller's one-request window, td-018) is
    // applied, everything else lives on the pooled client from creation
    HTTP.IOTimeout:=lTimeout;
    // Reused-client hygiene: Content-Type exists only while a body travels
    RemoveContentTypeHeader(HTTP);
    if Assigned(ABody) then
    begin
      HTTP.AddHeader(s_ContentType, s_JSONMime);
      // td-048: the body must be the COMPACT serialization - the full
      // padded/400 WHY history lives in the JSONCompact doc comment. Here
      // only the transport contract of the stream matters: the serialized
      // body exists once, the Size is exact before the first Read
      // (Content-Length) and the rewind replays the identical bytes for the
      // keep-alive retry
      HTTP.RequestBody:=TMaxStringBodyStream.Create(JSONCompact(ABody));
    end;
    try
      try
        if AVerb='GET' then
          lResp:=HTTP.Get(URL)
        else if AVerb='POST' then
          lResp:=HTTP.Post(URL)
        else if AVerb='PUT' then
          lResp:=HTTP.Put(URL)
        else
          lResp:=HTTP.Delete(URL);
      except
        // A transport failure (DNS, connect, timeout, reset) must not escape:
        // the public wrappers declare False = connection error with the
        // details in LastErrorCode/LastErrorMsg, an escape would break every
        // host relying on that contract (td-030). 'transport' is a synthetic
        // code, it cannot collide with an API error code
        on E: Exception do
        begin
          FLastErrorCode:='transport';
          FLastErrorMsg:=E.ClassName+': '+E.Message;
          // ErrorMessage is the user's log callback: if it raises, that raise
          // must not replace the folded transport failure and escape ApiCall -
          // swallowing it here is deliberate (the contract fields above are
          // already saved, the log line is best-effort)
          try
            ErrorMessage('[ApiCall] '+AVerb+' '+APath+' transport failure: '
              +FLastErrorMsg);
          except
          end;
          Exit(False);
        end;
      end;
      // From here the request has an answer: whatever goes wrong below is an
      // API/parse problem, not a transport one - the client returns to the pool
      Failed:=False;
      FResponse:=lResp;
      // Copy of a large body is not free: pay for it only in the debug mode
      if FLogDebug then
        DebugMessage('Response: '+Copy(FResponse, 1, 2048));
    finally
      if Assigned(ABody) then
        HTTP.RequestBody.Free;
      HTTP.RequestBody:=nil;
      RemoveContentTypeHeader(HTTP);
    end;
    try
      FJSONResponse:=GetJSON(FResponse);
    except
      on E: Exception do
      begin
        // The cause goes to the contract fields too, not only to the log:
        // False with both LastError* empty leaves the consumer without a
        // diagnosis (td-039). The code stays empty - a parse failure has no
        // API error code. E.Message stays out of the contract and the log:
        // the parser message quotes the offending input, and this same
        // ApiCall serves step 1 of UploadFile (/uploads) - its 2xx body
        // embeds a one-shot upload URL/token, so a malformed answer would
        // leak a piece of that body into LastErrorMsg and the log; the
        // class name alone marks the failure (same fold as UploadFile below)
        FLastErrorMsg:='response is not JSON: '+E.ClassName;
        // the log callback is the user's again: a raise from it must not
        // replace the parse diagnosis (td-039 folds the failure into False
        // with the message above) - swallow deliberately, same as above
        try
          ErrorMessage('[ApiCall] '+AVerb+' '+APath+' '+FLastErrorMsg);
        except
        end;
        FJSONResponse:=nil;
      end;
    end;
    StatusCode:=HTTP.ResponseStatusCode;
    // A failed request (any non-2xx status) carries the details in its body:
    // Error {"code": "chat.denied" (string, required), "error", "message"}
    if (StatusCode<200) or (StatusCode>299) then
    begin
      // 429 means the platform penalized this connection for the earlier
      // request rate: a fresh connection is not penalized (verified live -
      // curl 200 while the persistent keep-alive connection got 429 for
      // minutes), so drop the client and reconnect on the next call
      if StatusCode=429 then
        Failed:=True;
      if FJSONResponse is TJSONObject then
      begin
        ErrObj:=TJSONObject(FJSONResponse);
        FLastErrorCode:=ErrObj.Get('code', EmptyStr);
        FLastErrorMsg:=ErrObj.Get('message', EmptyStr);
        if FLastErrorMsg=EmptyStr then
          FLastErrorMsg:=ErrObj.Get('error', EmptyStr);
      end;
      if FLastErrorMsg=EmptyStr then
        FLastErrorMsg:=HTTP.ResponseStatusText;
      SafeErrorMessage(Format('[ApiCall] %s %s: API error %s %s (HTTP %d)',
        [AVErb, APath, FLastErrorCode, FLastErrorMsg, StatusCode]));
      Exit(False);
    end;
    // SimpleQueryResult {"success": false, "message": ...} means failure
    // even on 2xx (SetWebhook/DeleteWebhook/AnswerCallbackQuery)
    if FJSONResponse is TJSONObject then
    begin
      ErrObj:=TJSONObject(FJSONResponse);
      if (ErrObj.IndexOfName('success')>=0) and (ErrObj.Get('success', True)=False) then
      begin
        FLastErrorMsg:=ErrObj.Get('message', EmptyStr);
        SafeErrorMessage(Format('[ApiCall] %s %s: request failed: %s',
          [AVErb, APath, FLastErrorMsg]));
        Exit(False);
      end;
    end;
    // A 2xx response that is not JSON is not a success either
    Result:=Assigned(FJSONResponse);
  finally
    ReleaseAPIClient(HTTP, Failed);
  end;
end;

function TMaxSender.GetMe: Boolean;
var
  NewInfo: TMaxBotInfoObj;
begin
  Result:=False;
  if not ApiCall(s_PathMe, 'GET', nil, nil) then
    Exit;
  if not (FJSONResponse is TJSONObject) then
    Exit;
  NewInfo:=TMaxBotInfoObj.Create(TJSONObject(TJSONObject(FJSONResponse).Clone));
  FreeAndNil(FBotInfo);
  FBotInfo:=NewInfo;
  Result:=True;
end;

function TMaxSender.GetChat(AChatId: Int64): Boolean;
var
  NewChat: TMaxChatObj;
begin
  Result:=False;
  // ChatId is "\-?\d+" per the schema: dialogs carry negative ids
  if not ApiCall(s_PathChats+IntToStr(AChatId), 'GET', nil, nil) then
    Exit;
  if not (FJSONResponse is TJSONObject) then
    Exit;
  NewChat:=TMaxChatObj.Create(TJSONObject(TJSONObject(FJSONResponse).Clone));
  FreeAndNil(FChat);
  FChat:=NewChat;
  Result:=True;
end;

function TMaxSender.GetUpdates(const AMarker: String; ALimit: Integer;
  ATimeoutSec: Integer): Boolean;
var
  Query: TStringList;
  Updates: TMaxUpdateObjList;
  EffSec, WindowMs: Integer;
  NewMarker: String;
  AnUpdate: TMaxUpdateObj;
begin
  Result:=False;
  Query:=TStringList.Create;
  try
    if AMarker<>EmptyStr then
      Query.Values['marker']:=AMarker;
    // GET /updates: limit 1..1000 (default 100), timeout 0..90 seconds
    // (default 30); the API has no ping/time parameters
    if ALimit>0 then
      Query.Values['limit']:=IntToStr(ALimit);
    if ATimeoutSec>0 then
      Query.Values['timeout']:=IntToStr(ATimeoutSec);
    // The server holds the connection for up to ATimeoutSec seconds (30 when
    // 0 is passed): the HTTP window of this one request must cover the long
    // poll plus slack. The window travels as the ApiCall parameter (td-018),
    // the shared Timeout field is NOT mutated for it: the old widen/restore
    // pair raced a concurrent SetTimeout (the restore wrote back a stale
    // value - a lost update) and made a send running inside the poll window
    // inherit the window instead of the user's Timeout. max() keeps the
    // "never shortens the configured Timeout" guarantee the widen provided;
    // the read-only snapshot takes the pool lock for the same reason the
    // locked setters take it from their readers
    EffSec:=ATimeoutSec;
    if EffSec<=0 then
      EffSec:=30;
    WindowMs:=EffSec*1000+3000;
    System.EnterCriticalSection(FClientPoolCS);
    try
      if FTimeout>WindowMs then
        WindowMs:=FTimeout;
    finally
      System.LeaveCriticalSection(FClientPoolCS);
    end;
    if not ApiCall(s_PathUpdates, 'GET', Query, nil, WindowMs) then
      Exit;
  finally
    Query.Free;
  end;
  if not ParseUpdateList(FJSONResponse, Updates, NewMarker) then
    Exit;
  try
    FMarker:=NewMarker;
    // Updates owns its items (TFPGObjectList, FreeObjects=True): assigning
    // nil to a slot would free the object before it is handled. Extract
    // zeroes the slot before removing, handing the ownership to this loop
    while Updates.Count>0 do
    begin
      AnUpdate:=Updates.Extract(Updates[0]);
      try
        // DoReceiveUpdate takes ownership: it stores AnUpdate in FUpdate
        DoReceiveUpdate(AnUpdate);
      except
        on E: Exception do
        begin
          // one broken update must not drop the rest of the batch
          // ErrorMessage is a user callback: a raising callback must not
          // drop the rest of the batch either
          try
            ErrorMessage('[GetUpdates] update handler failed: '+E.ClassName+': '+E.Message);
          except
          end;
          if FUpdate<>AnUpdate then
            AnUpdate.Free; // the ownership has NOT moved to FUpdate - free it here
        end;
      end;
    end;
    Result:=True;
  finally
    Updates.Free;
  end;
end;

function TMaxSender.GetUpdatesEx(limit: Integer; lp_timeout: Integer): Boolean;
begin
  // limit=0 means the server default (100); lp_timeout is the long-polling
  // window in seconds
  Result:=GetUpdates(FMarker, limit, lp_timeout);
end;

function TMaxSender.SendMessage(chat_id: Int64; const AText: String): Boolean;
begin
  Result:=SendMessageEx(chat_id, AText);
end;

function TMaxSender.SendMessageEx(chat_id: Int64; const AText: String;
  AAttachments: TJSONArray; ANotify: Boolean; AFormat: TMaxTextFormat): Boolean;
var
  Body: TJSONObject;
  Query: TStringList;
begin
  Result:=False;
  Body:=TJSONObject.Create;
  try
    if AText<>EmptyStr then
      Body.Add('text', AText);
    if AFormat<>fmtDefault then
      Body.Add('format', MaxTextFormatToStr(AFormat));
    if Assigned(AAttachments) then
      Body.Add('attachments', TJSONArray(AAttachments.Clone));
    if not ANotify then
      Body.Add('notify', False);
    Query:=TStringList.Create;
    try
      Query.Values['chat_id']:=IntToStr(chat_id);
      Result:=ApiCall(s_PathMessages, 'POST', Query, Body);
    finally
      Query.Free;
    end;
  finally
    Body.Free;
  end;
end;

function TMaxSender.Reply(const AText: String): Boolean;
begin
  Result:=SendMessage(FCurrentChatId, AText);
end;

function TMaxSender.EditText(chat_id: Int64; const AMessageId, AText: String;
  AFormat: TMaxTextFormat): Boolean;
var
  Body: TJSONObject;
  Query: TStringList;
begin
  Result:=False;
  Body:=TJSONObject.Create;
  try
    Body.Add('text', AText);
    if AFormat<>fmtDefault then
      Body.Add('format', MaxTextFormatToStr(AFormat));
    Query:=TStringList.Create;
    try
      Query.Values['chat_id']:=IntToStr(chat_id);
      Query.Values['message_id']:=AMessageId;
      Result:=ApiCall(s_PathMessages, 'PUT', Query, Body);
    finally
      Query.Free;
    end;
  finally
    Body.Free;
  end;
end;

function TMaxSender.DeleteMessage(chat_id: Int64; const AMessageId: String): Boolean;
var
  Query: TStringList;
begin
  Result:=False;
  Query:=TStringList.Create;
  try
    Query.Values['chat_id']:=IntToStr(chat_id);
    Query.Values['message_id']:=AMessageId;
    Result:=ApiCall(s_PathMessages, 'DELETE', Query, nil);
  finally
    Query.Free;
  end;
end;

function TMaxSender.AnswerCallbackQuery(const ACallbackId, AText: String): Boolean;
var
  Body: TJSONObject;
  Query: TStringList;
begin
  Result:=False;
  Body:=TJSONObject.Create;
  try
    // CallbackAnswer {"notification": ...} - there is no "text" field in
    // the answer body
    if AText<>EmptyStr then
      Body.Add('notification', AText);
    Query:=TStringList.Create;
    try
      Query.Values['callback_id']:=ACallbackId;
      Result:=ApiCall(s_PathAnswers, 'POST', Query, Body);
    finally
      Query.Free;
    end;
  finally
    Body.Free;
  end;
end;

function TMaxSender.SetWebhook(const AURL: String;
  const ASecret: String): Boolean;
var
  Body: TJSONObject;
begin
  Result:=False;
  Body:=TJSONObject.Create;
  try
    Body.Add('url', AURL);
    // SubscriptionRequestBody.secret (schema): 5-256 chars of [A-Za-z0-9_-],
    // echoed back in the X-Max-Bot-Api-Secret header of every webhook
    // request; an empty parameter keeps the body back-compatible
    if ASecret<>EmptyStr then
      Body.Add('secret', ASecret);
    Result:=ApiCall(s_PathSubscriptions, 'POST', nil, Body);
  finally
    Body.Free;
  end;
end;

function TMaxSender.DeleteWebhook(const AURL: String): Boolean;
var
  Query: TStringList;
begin
  Result:=False;
  Query:=TStringList.Create;
  try
    Query.Values['url']:=AURL;
    Result:=ApiCall(s_PathSubscriptions, 'DELETE', Query, nil);
  finally
    Query.Free;
  end;
end;

function TMaxSender.UploadFile(AnUploadType: TMaxUploadType; AStream: TStream;
  const AFileName: String): String;
var
  HTTP: TBaseHTTPClient;
  Query, FormData: TStringList;
  UploadURL, lResp, lName, lKeys: String;
  RespStream: TStringStream;
  JD, PhotosData: TJSONData;
  Photos, RespObj: TJSONObject;
  I, StatusCode, lTimeout: Integer;
  lConfig: TMaxPoolConfig;
  lCAFile: String;
begin
  Result:=EmptyStr;
  if not Assigned(AStream) then
    Exit;
  // Step 1: ask the API for a one-shot upload URL
  Query:=TStringList.Create;
  try
    Query.Values['type']:=MaxUploadTypeToStr(AnUploadType);
    if not ApiCall(s_PathUploads, 'POST', Query, nil) then
      Exit;
  finally
    Query.Free;
  end;
  // UploadEndpoint {"url": ..., "token": ...}: for video and audio the
  // token is issued right here, before the file is sent
  UploadURL:=EmptyStr;
  if FJSONResponse is TJSONObject then
  begin
    UploadURL:=TJSONObject(FJSONResponse).Get('url', EmptyStr);
    if AnUploadType in [uptVideo, uptAudio] then
      Result:=TJSONObject(FJSONResponse).Get('token', EmptyStr);
  end;
  // A failure below must not return the token of a file that was never
  // uploaded: EmptyStr is the contract of the consumers
  if UploadURL=EmptyStr then
  begin
    SafeErrorMessage('[UploadFile] no upload URL in response');
    Exit(EmptyStr);
  end;
  // The upload endpoint is pre-authorized by the token it carries: the API
  // expects no Authorization header on step 2, and the one-shot URL must be
  // https so the file cannot leak to a downgraded connection. Control
  // characters and spaces are rejected by the same gate - both brokers build
  // the request-target from this URL verbatim (td-019) - and the value is
  // never logged: it embeds the one-shot token
  if (Copy(UploadURL, 1, 8)<>'https://') or HasControlChars(UploadURL)
    or (Pos(' ', UploadURL)>0) then
  begin
    SafeErrorMessage('[UploadFile] the upload URL is not https or has control '
      +'characters/spaces; the value is not logged: it embeds a one-shot token');
    Exit(EmptyStr);
  end;
  // The file name travels unquoted inside Content-Disposition: ... filename="%s"
  // of both brokers: a quote would terminate the header early, a CR/LF would
  // inject an extra multipart part (td-019). Rejected with the same fold as
  // the URL above; the value is not logged either - a CR/LF in it would
  // inject log lines
  lName:=ExtractFileName(AFileName);
  if HasControlChars(lName) or (Pos('"', lName)>0) then
  begin
    SafeErrorMessage('[UploadFile] the file name has a quote or control '
      +'characters; the value is not logged');
    Exit(EmptyStr);
  end;
  // Step 2: send the file as multipart/form-data, field "data". The client
  // is built from a configuration snapshot taken under the pool lock (the
  // setters hold it - an unlocked read of the token/proxy/anchor strings
  // would race a concurrent reconfiguration), and the validation below runs
  // OUTSIDE the lock: it reports through the user's ErrorMessage callback,
  // and a setter (or AcquireAPIClient) re-entered from that callback would
  // self-deadlock on the non-reentrant section
  System.EnterCriticalSection(FClientPoolCS);
  try
    ReadPoolConfig(lConfig);
    lTimeout:=FTimeout;
  finally
    System.LeaveCriticalSection(FClientPoolCS);
  end;
  ValidateHTTPConfig(lConfig, lCAFile);
  // Construction failures here raise to the caller by design (see the
  // UploadFile doc comment) - EmptyStr below means "the transport failed";
  // the trust anchor is already resolved by ValidateHTTPConfig above
  HTTP:=nil;
  FormData:=nil;
  RespStream:=nil;
  try
    HTTP:=CreateHTTPClient(False, lConfig, lCAFile, lTimeout);
    FormData:=TStringList.Create;
    RespStream:=TStringStream.Create('');
    try
      AStream.Position:=0;
      HTTP.StreamFormPost(UploadURL, FormData, 'data', lName, AStream, RespStream);
      lResp:=RespStream.DataString;
    except
      // a transport failure must not escape: the consumers (SendFileOfType,
      // SendStatLog) expect the EmptyStr contract, the error is already logged
      on E: Exception do
      begin
        SafeErrorMessage('[UploadFile] '+E.ClassName+': '+E.Message);
        Exit(EmptyStr);
      end;
    end;
    StatusCode:=HTTP.ResponseStatusCode;
    // A failed upload (any non-2xx status) carries no token: do not parse
    // the body and never report the step 1 token as a success
    if (StatusCode<200) or (StatusCode>299) then
    begin
      SafeErrorMessage(Format('[UploadFile] upload failed: HTTP %d %s',
        [StatusCode, HTTP.ResponseStatusText]));
      Exit(EmptyStr);
    end;
    JD:=nil;
    try
      try
        JD:=GetJSON(lResp);
      except
        on E: Exception do
          // E.Message stays out of the log: fpjson quotes the offending
          // input token in its message and a malformed upload response may
          // embed a piece of that response (the one-shot token of step 1
          // travels in it) - the class name alone marks the failure
          SafeErrorMessage('[UploadFile] upload response is not JSON: '+E.ClassName);
      end;
      // image: {"photos": {"<size>": {"token": ...}}} - the sizes are
      // interchangeable for sending, take the first one with a token;
      // file: {"token": ...} (video/audio keep the token of step 1)
      if JD is TJSONObject then
      begin
        if AnUploadType=uptImage then
        begin
          PhotosData:=TJSONObject(JD).FindPath('photos');
          if PhotosData is TJSONObject then
          begin
            Photos:=TJSONObject(PhotosData);
            for I:=0 to Photos.Count-1 do
              if Photos.Items[I] is TJSONObject then
              begin
                Result:=TJSONObject(Photos.Items[I]).Get('token', EmptyStr);
                if Result<>EmptyStr then
                  Break;
              end;
          end;
        end
        else if AnUploadType=uptFile then
          Result:=TJSONObject(JD).Get('token', EmptyStr);
      end;
      if Result=EmptyStr then
      begin
        // The response body carries live one-shot tokens (the step 1 token
        // for video/audio, photos/token for image/file): only its FORM is
        // reported - the key names and the size, never the values (td-019).
        // The keys go through JSONEscapeString: a parsed key can carry the
        // same structural characters as a value (see JSONCompact), a raw one
        // would inject log lines
        if JD is TJSONObject then
        begin
          RespObj:=TJSONObject(JD);
          lKeys:=EmptyStr;
          for I:=0 to RespObj.Count-1 do
          begin
            if lKeys<>EmptyStr then
              lKeys+=', ';
            lKeys+=JSONEscapeString(RespObj.Names[I]);
          end;
          SafeErrorMessage(Format('[UploadFile] no token in upload response '
            +'(HTTP %d, body %d bytes, keys: %s)',
            [StatusCode, Length(lResp), Copy(lKeys, 1, 256)]));
        end
        else
          SafeErrorMessage(Format('[UploadFile] no token in upload response '
            +'(HTTP %d, body %d bytes, not a JSON object)',
            [StatusCode, Length(lResp)]));
      end;
    finally
      JD.Free;
    end;
  finally
    FormData.Free;
    RespStream.Free;
    HTTP.Free;
  end;
end;

function TMaxSender.UploadFileByFileName(AnUploadType: TMaxUploadType;
  const AFileName: String): String;
var
  FS: TFileStream;
begin
  Result:=EmptyStr;
  FS:=TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Result:=UploadFile(AnUploadType, FS, ExtractFileName(AFileName));
  finally
    FS.Free;
  end;
end;

function TMaxSender.sendPhoto(chat_id: Int64; const ATokenOrURL: String): Boolean;
var
  Arr: TJSONArray;
begin
  Arr:=TJSONArray.Create;
  try
    Arr.Add(MakeAttachmentJSON(uptImage, ATokenOrURL));
    Result:=SendMessageEx(chat_id, EmptyStr, Arr);
  finally
    Arr.Free;
  end;
end;

function TMaxSender.sendVideo(chat_id: Int64; const ATokenOrURL: String): Boolean;
var
  Arr: TJSONArray;
begin
  Arr:=TJSONArray.Create;
  try
    Arr.Add(MakeAttachmentJSON(uptVideo, ATokenOrURL));
    Result:=SendMessageEx(chat_id, EmptyStr, Arr);
  finally
    Arr.Free;
  end;
end;

function TMaxSender.sendFile(chat_id: Int64; const ATokenOrURL: String): Boolean;
var
  Arr: TJSONArray;
begin
  Arr:=TJSONArray.Create;
  try
    Arr.Add(MakeAttachmentJSON(uptFile, ATokenOrURL));
    Result:=SendMessageEx(chat_id, EmptyStr, Arr);
  finally
    Arr.Free;
  end;
end;

function TMaxSender.sendAudio(chat_id: Int64; const ATokenOrURL: String): Boolean;
var
  Arr: TJSONArray;
begin
  Arr:=TJSONArray.Create;
  try
    Arr.Add(MakeAttachmentJSON(uptAudio, ATokenOrURL));
    Result:=SendMessageEx(chat_id, EmptyStr, Arr);
  finally
    Arr.Free;
  end;
end;

function SendFileOfType(ABot: TMaxSender; chat_id: Int64;
  AnUploadType: TMaxUploadType; const AFileName: String): Boolean;
var
  Token: String;
  Arr: TJSONArray;
begin
  Token:=ABot.UploadFileByFileName(AnUploadType, AFileName);
  if Token=EmptyStr then
    Exit(False);
  Arr:=TJSONArray.Create;
  try
    Arr.Add(MakeAttachmentJSON(AnUploadType, Token));
    Result:=ABot.SendMessageEx(chat_id, EmptyStr, Arr);
  finally
    Arr.Free;
  end;
end;

function TMaxSender.sendPhotoByFileName(chat_id: Int64; const AFileName: String): Boolean;
begin
  Result:=SendFileOfType(Self, chat_id, uptImage, AFileName);
end;

function TMaxSender.sendVideoByFileName(chat_id: Int64; const AFileName: String): Boolean;
begin
  Result:=SendFileOfType(Self, chat_id, uptVideo, AFileName);
end;

function TMaxSender.sendFileByFileName(chat_id: Int64; const AFileName: String): Boolean;
begin
  Result:=SendFileOfType(Self, chat_id, uptFile, AFileName);
end;

function TMaxSender.sendAudioByFileName(chat_id: Int64; const AFileName: String): Boolean;
begin
  Result:=SendFileOfType(Self, chat_id, uptAudio, AFileName);
end;

procedure TMaxSender.DoReceiveCallback(ACallback: TMaxCallbackObj);
begin
  // no-op in the base class: override to intercept callbacks
end;

procedure TMaxSender.DoReceiveMessage(AMessage: TMaxMessageObj);
begin
  FCurrentMessage:=AMessage;
  if Assigned(AMessage) then
  begin
    FCurrentChatId:=AMessage.ChatId;
    FCurrentUser:=AMessage.Sender;
    ProcessCommands(AMessage, FCommandHandlers);
  end;
end;

function TMaxSender.AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean;
begin
  Result:=True; // the base class takes every update
end;

function TMaxSender.ShouldLogUpdate(AnUpdate: TMaxUpdateObj): Boolean;
begin
  // statistics ignore admins
  Result:=not FAdminUsers.Contains(AnUpdate.AuthorId);
end;

{ Ownership contract: the caller hands AnUpdate over - it is stored in
  FUpdate and freed with the sender (or on the next update). Callers must
  not free AnUpdate after calling this. If DoReceiveUpdate raises before
  the assignment, GetUpdates frees AnUpdate itself }
procedure TMaxSender.DoReceiveUpdate(AnUpdate: TMaxUpdateObj);
begin
  FreeAndNil(FUpdate);
  FUpdate:=AnUpdate; // the ownership moves here (see the contract above)
  FCurrentMessage:=nil;
  FCurrentChatId:=0;
  FCurrentUser:=nil;
  // AsString deep-copies the update: pay for it only in the debug mode
  if FLogDebug then
    DebugMessage('Receive the update: '+AnUpdate.AsString);
  // A rejected update is not dispatched at all, but the ownership is
  // already settled: FUpdate frees it, nothing leaks on any path
  if not AcceptUpdate(AnUpdate) then
    Exit;
  if FProcessUpdate then
  begin
    case AnUpdate.UpdateType of
      utMessageCreated:
        begin
          DoReceiveMessage(AnUpdate.Message);
          if Assigned(FOnReceiveMessage) then
            FOnReceiveMessage(Self, AnUpdate.Message);
        end;
      utMessageEdited:
        if Assigned(FOnReceiveEditedMessage) then
          FOnReceiveEditedMessage(Self, AnUpdate.Message);
      utMessageCallback:
        begin
          FCurrentChatId:=AnUpdate.Message.ChatId;
          DoReceiveCallback(AnUpdate.Callback);
          if Assigned(FOnReceiveCallback) then
            FOnReceiveCallback(Self, AnUpdate.Callback);
        end;
      utBotStarted:
        if Assigned(FOnBotStarted) then
          FOnBotStarted(Self, AnUpdate.User);
      utUserAdded:
        if Assigned(FOnUserAdded) then
          FOnUserAdded(Self, AnUpdate.User);
      utUserRemoved:
        if Assigned(FOnUserRemoved) then
          FOnUserRemoved(Self, AnUpdate.User);
      utChatTitleChanged:
        if Assigned(FOnChatTitleChanged) then
          FOnChatTitleChanged(Self, AnUpdate);
    end;
    if Assigned(FOnAnyUpdate) then
      FOnAnyUpdate(Self, AnUpdate);
    if Assigned(FUpdateLogger) then
      if ShouldLogUpdate(AnUpdate) then
        // The aggregate (td-016) instead of the raw AsString: the full JSON
        // carried message texts (unintended PII on a stats file) and its
        // quotes/semicolons shifted the ';' columns of the CSV. No field
        // below is quoted from the payload: the update type is rendered from
        // the enum (MaxUpdateTypeToStr, the same form bot_ex logs; the raw
        // update_type string travels in the payload unvalidated - values
        // outside the vocabulary collapse to utUnknown, so its shape is not
        // ours to trust, the enum form is a fixed vocabulary), the ids are
        // numbers, the text is reduced to its length (MessageBodyTextLength,
        // no Message wrapper or subtree clone) - the record cannot break the
        // CSV shape.
        // AuthorId, not the top-level UserId: message_created has no
        // top-level user_id, the author lives in message.sender.user_id
        FUpdateLogger.Log([MaxUpdateTypeToStr(AnUpdate.UpdateType),
          IntToStr(AnUpdate.AuthorId), IntToStr(AnUpdate.ChatId),
          IntToStr(AnUpdate.MessageBodyTextLength)]);
  end;
  if Assigned(FOnReceiveUpdate) then
    FOnReceiveUpdate(Self, AnUpdate);
end;

procedure TMaxSender.ProcessCommands(AMessage: TMaxMessageObj;
  AHandlers: TCommandHandlersMap);
var
  lCommand, Txt: String;
  H: TCommandEvent;
  AtPos, ColPos: Integer;
begin
  if not Assigned(AMessage) then
    Exit;
  Txt:=Trim(AMessage.Body.Text);
  if Txt='' then
    Exit;
  { The command grammar follows the official MAX SDK (commandReg in
    max-go/model/command.go): an optional @bot mention may precede the
    command (group chats) and ':params' may follow the command name. One
    divergence: the SDK separator between the mention and the command is an
    optional whitespace run ((?:\s+)?), here it is exactly one ASCII space -
    the glued '@bot/cmd' form is deliberately not accepted (fail-closed;
    only the spaced form was ever seen from live clients). A bare
    @mention or a mention followed by a non-command is not a command, and a
    command must START with '/' - plain text never extracts a name. Only
    the mention is stripped here: TCommandEvent carries no params field by
    contract (td-017), the handler reads the FULL original text through
    AMessage.Body.Text, so the lookup simply stops the command name at the
    first ':' and leaves the tail in the message as is.
    In GROUP chats the mention is also a filter (user decision, td-017):
    our bot must not react to commands addressed to another bot, so with a
    known OwnUsername only a leading '@'+OwnUsername passes - a group
    message without the mention names nobody and is dropped the same way.
    Dialogs carry no mentions at all and keep the plain grammar. The chat
    type comes from the message RECIPIENT (the live delivery payload puts
    chat_type there: {"recipient":{"chat_type":"dialog","chat_id":...}}) -
    the lazy accessor never returns nil, a missing node maps to ctUnknown,
    which takes the permissive dialog path like an unknown chat }
  if AMessage.Recipient.ChatType in [ctChat, ctChannel] then
    if FOwnUsername<>'' then
    begin
      AtPos:=Pos(' ', Txt);
      { the mention token runs to the first space; the match ignores the
        case (AnsiCompareText - the name reaches the text in whatever case
        the author or the client renderer typed) but is otherwise exact - a
        token that merely STARTS with our name is still somebody else's }
      if (Txt[1]<>'@') or (AtPos=0)
        or (AnsiCompareText(Copy(Txt, 1, AtPos-1), '@'+FOwnUsername)<>0) then
        Exit;
    end;
  if (Txt<>'') and (Txt[1]='@') then
  begin
    AtPos:=Pos(' ', Txt);
    if AtPos=0 then
      Exit;
    Txt:=Trim(Copy(Txt, AtPos+1, Length(Txt)));
  end;
  { what remains - the tail after the mention or the plain text - must start
    with '/': otherwise 'sup' would extract 'up', 'sstart' - 'start',
    '?up:1' - 'up', and ordinary messages would fire handlers }
  if (Txt='') or (Txt[1]<>'/') then
    Exit;
  { the command name runs from '/' to the FIRST of (space, ':') }
  AtPos:=Pos(' ', Txt);
  ColPos:=Pos(':', Txt);
  if (ColPos>0) and ((AtPos=0) or (ColPos<AtPos)) then
  begin
    { the SDK params group holds no ':' of its own: '/vote:yes:no' matches
      the SDK regex only as cmd='/vote:yes' - a lookup miss - so a second
      ':' inside the command token fails closed instead of firing 'vote' }
    if AtPos=0 then
      AtPos:=Length(Txt)+1;
    if Pos(':', Copy(Txt, ColPos+1, AtPos-ColPos-1))>0 then
      Exit;
    AtPos:=ColPos;
  end;
  if AtPos>0 then
    lCommand:=Copy(Txt, 2, AtPos-2)
  else
    lCommand:=Copy(Txt, 2, Length(Txt));
  lCommand:=LowerCase(lCommand);
  if AHandlers.GetValue(lCommand, H) then
    H(Self, lCommand, AMessage);
end;

function TMaxSender.GetCommandHandlers(const Command: String): TCommandEvent;
begin
  if not FCommandHandlers.GetValue(Command, Result) then
    Result:=nil;
end;

procedure TMaxSender.SetCommandHandlers(const Command: String;
  AValue: TCommandEvent);
begin
  if AValue=nil then
    FCommandHandlers.Delete(Command)
  else
    FCommandHandlers.insert(Command, AValue);
end;

procedure TMaxSender.SetOwnUsername(AValue: String);
begin
  AValue:=Trim(AValue);
  while (AValue<>'') and (AValue[1]='@') do
    AValue:=Copy(AValue, 2, Length(AValue)-1);
  FOwnUsername:=AValue;
end;

{ Best-effort delete of the bundle locations matching this process's pattern;
  bundles built after it runs are left behind }
procedure RemoveMergedBundles;
var
  lSR: TSearchRec;
  lRes: Integer;
  lDir: String;
begin
  {$IFDEF UNIX}
  // the bundle lives in a per-process directory (see BuildMergedCAFile), so
  // the sweep clears it whole: the file under the fixed inner name first,
  // then the directory itself. Only entries matching this process's own
  // GUID-suffixed pattern are touched; a name-colliding entry that is not
  // ours (a foreign file or an alien directory) only makes DeleteFile or
  // RemoveDir fail harmlessly - delete errors are ignored here
  lRes:=FindFirst(IncludeTrailingPathDelimiter(GetTempDir)
    +MergedCADirPattern('*'), faAnyFile, lSR);
  try
    while lRes=0 do
    begin
      lDir:=IncludeTrailingPathDelimiter(GetTempDir)+lSR.Name;
      DeleteFile(IncludeTrailingPathDelimiter(lDir)+s_MergedCABundleName);
      RemoveDir(lDir);
      lRes:=FindNext(lSR);
    end;
  finally
    FindClose(lSR);
  end;
  {$ELSE}
  lRes:=FindFirst(IncludeTrailingPathDelimiter(GetTempDir)
    +MergedCAFilePattern('*'), faAnyFile, lSR);
  try
    while lRes=0 do
    begin
      DeleteFile(IncludeTrailingPathDelimiter(GetTempDir)+lSR.Name);
      lRes:=FindNext(lSR);
    end;
  finally
    FindClose(lSR);
  end;
  {$ENDIF}
end;

initialization
  InitCriticalSection(_MergedDefaultCALock);

finalization
  { Best-effort removal of the merged bundles this process built: without it
    every run leaves its ~200-333 KB temp files behind (a crash-looping
    service piles up ~100 MB/day). Only entries matching this process's own
    bundle pattern are removed (UNIX: the private bundle directories whole) -
    a pass-through cached path (a real CA file) and foreign temp entries
    survive; delete errors are ignored.
    The sweep is not a synchronization point with host threads still alive at
    exit: a thread already past MergedDefaultCAFile with the bundle path has
    its handshake fail closed (the pattern matches only this process's own
    GUID-suffixed entries, no foreign entry is removed), and a thread that
    enters it after the cache reset rebuilds one fresh bundle that nothing
    sweeps - a host must stop its receivers before the process ends.
    WHY the critical section is NOT destroyed here: MergedDefaultCAFile can
    still be entered by a host thread that is resolving the anchor while the
    unit finalizes - using a destroyed section is undefined behavior, while
    one live allocator until process exit is harmless (the OS reclaims it) }
  EnterCriticalSection(_MergedDefaultCALock);
  try
    _MergedDefaultCAPath:=EmptyStr;
    RemoveMergedBundles;
  finally
    LeaveCriticalSection(_MergedDefaultCALock);
  end;

end.
