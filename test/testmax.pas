unit testmax;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, eventlog,
  maxsendertypes, maxstatlog, testbase, maxtypes,
  maxbasehttpclient, configuration;

type

  { TTestSender }
  { Test sending messages and receiving updates from the test bot. Object style }
  TTestSender= class(TTestMaxClass)
  private
    FPhotoFile: String;
    FPhotoUrl: String;
    FUrl: String;
    FReceived: Boolean;
    procedure BotReceiveUpdate({%H-}ASender: TObject; AnUpdate: TMaxUpdateObj);
  protected
    procedure SetUp; override;
  public
    property Url: String read FUrl;
    property PhotoUrl: String read FPhotoUrl;
    property PhotoFile: String read FPhotoFile;
  published
    procedure getMe;
    procedure sendMessage;
    procedure sendMessageWithInlineKeyboard;
    procedure sendPhoto;             // by the URL of an already uploaded media
    procedure sendPhotoByFileName;   // two-step upload, then send
    procedure uploadFile;            // upload the token and send it as a file
    procedure setWebhook;
    procedure deleteWebhook;
    procedure ReceiveUpdate;         // long polling: send a message to the test bot first!
  end;

  { TTestSenderProcedure }
  { Test sending messages. Simple procedure style}
  TTestSenderProcedure=class(TTestMaxBase)
  published
    procedure sendMessage;
  end;

  { TTestSenderTypes }
  { Offline tests of the MAX data types and the ApiCall Boolean contract
    (no connection to the bot API server: the HTTP broker is swapped for a
    mock serving canned responses) }
  TTestSenderTypes=class(TTestCase)
  private
    FSavedClientClass: TBaseClientClass;
    FHandlerRan: Boolean;
    FLastCommand: String;
    FLastText: String;
    procedure InstallMock;
    procedure UninstallMock;
    { td-017: the command handler under test - it remembers the matched
      command name and the message text it was handed }
    procedure CommandHandler(ASender: TObject; const ACommand: String;
      AMessage: TMaxMessageObj);
    { td-017: feeds AText to ProcessCommands offline with the test commands
      registered ('start', 'vote', 'stat', 'upper'); FLastCommand/FLastText
      are reset before the run }
    procedure RunProcessCommands(const AText: String);
    { td-017 (the mention filter): the same run over a synthetic message
      whose recipient carries ARecipientJSON verbatim (the raw fields - put
      the chat_type there) and whose body.text is AText; AOwnUsername sets
      Sender.OwnUsername ('' leaves the property unset) }
    procedure RunCommandJSON(const ARecipientJSON, AText,
      AOwnUsername: String);
    { The handler the configuration error texts suggest: it reconfigures the
      sender from inside the log callback }
    procedure ReconfiguringLogHandler(ASender: TObject;
      {%H-}AEventType: TEventType; const {%H-}AMsg: String);
    { td-072: the host log handler is broken - it raises on every report,
      every diagnostic path of the reporting code must absorb it }
    procedure RaisingLogHandler(ASender: TObject;
      {%H-}AEventType: TEventType; const {%H-}AMsg: String);
    { AssertException needs a TTestMethod (a procedure of object): the broken
      pair lists of InlineKeyboardAttachmentRejectsBrokenPairs go through
      these wrappers }
    procedure MakeKeyboardWithOddPairs;
    procedure MakeKeyboardWithoutPairs;
  published
    procedure ParseUpdateList;
    procedure ParseUpdateListEdgeCases;
    procedure ParseMessageUpdate;
    procedure TypeMismatchDefaults;
    procedure UpdateSpecificMembers;      // td-015: muted_until/inviter_id/admin_id
    procedure MessageLinkAccessor;        // td-015: lazy Link (reply/forward origin)
    procedure ChatDialogWithUserAccessor; // td-015: lazy DialogWithUser
    procedure PayloadButtonsTyped;        // td-015: typed inline keyboard buttons
    procedure AsStringVirtualDispatch;    // td-015: polymorphic AsString
    procedure MakeAttachmentJSONTest;
    procedure InlineKeyboardAttachmentShape2D;
    procedure InlineKeyboardAttachmentMultipleButtonsOneRow;
    procedure InlineKeyboardAttachmentEscapesTextAndPayload;
    procedure InlineKeyboardAttachmentRejectsBrokenPairs;
    procedure UpdateTypeConverters;
    procedure AcceptUpdateDropsBannedAuthor;   // the AcceptUpdate hook
    procedure UpdateLoggerSurvivesSimpleUser;  // UpdateLogger ownership
    procedure ApiCallTransportFailureContract; // td-030
    procedure ApiCallNonJSONFillsLastError;    // td-039
    procedure GetChatParsesChatCard;           // td-031
    procedure SetWebhookSendsSecret;           // td-041
    procedure KeepAliveReusesClientAcrossCalls;         // td-032
    procedure TransportFailureReplacesPooledClient;     // td-032
    procedure ApiErrorKeepsPooledClient;                // td-032
    procedure ConfigChangeReplacesPooledClient;         // td-032
    procedure ContentTypeStrippedForBodylessRequests;   // td-032
    procedure LogCallbackMayReconfigureSender; // the callback deadlock guard
    procedure GetUpdatesWindowOverridesSmallTimeout;   // td-018
    procedure GetUpdatesNeverShortensLargeTimeout;     // td-018
    procedure NonPollCallUsesConfiguredTimeout;        // td-018
    procedure InvalidTokenRaisesEMaxConfig;            // td-013
    procedure UploadConfigErrorRaisesEMaxConfig;       // td-073
    procedure UploadRaisingLogCallbackKeepsEmptyStr;   // td-072/td-076
    procedure CommandFiresOnBareSlash;                 // td-017
    procedure CommandAfterBotMentionFires;             // td-017
    procedure BareMentionDoesNotFire;                  // td-017
    procedure ColonParamsCutFromCommand;               // td-017
    procedure MentionWithColonParamsFires;             // td-017
    procedure DoubleColonDoesNotFire;                  // td-017
    procedure PlainTextDoesNotFire;                    // td-017
    procedure CommandNameLowercased;                   // td-017
    procedure GroupMentionForOwnBotFires;              // td-017
    procedure GroupForeignMentionSkipped;              // td-017
    procedure NoOwnUsernameAcceptsAnyMention;          // td-017
    procedure DialogHasNoMentionFilter;                // td-017
    procedure GroupBareCommandSkipped;                 // td-017
    procedure ChannelMentionForOwnBotFires;            // td-017
    procedure GroupMentionCaseInsensitiveFires;        // td-017
    procedure OwnUsernameLeadingAtNormalized;          // td-017
    procedure UnknownChatTypeHasNoMentionFilter;       // td-017
  end;

  { TTestMaxBot }
  { Offline tests of the real TMaxBot (no connection to the bot API server):
    the user status map and the ban gate of the bot hooks }
  TTestMaxBot=class(TTestCase)
  published
    procedure UserStatusRoundTrip;
    procedure BanGateDropsBannedCallback;
    procedure BanGateDropsBannedMessage;
    procedure AuthorIdChainPrecedence;
    procedure StatFieldEscapeRoundTrip;
    procedure KeyboardWireMatchesCore;
  end;

  { TTestTLSTrust }
  { Offline tests of the TLS trust anchor resolution (no connection to the
    bot API server) }
  TTestTLSTrust=class(TTestCase)
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    procedure WriteFixture(const APath, AContent: String);
    { AssertException needs a TTestMethod (a procedure of object), so the
      raising call of ResolveTrustAnchor goes through this wrapper }
    procedure ResolveAnchorWithoutSources;
  published
    procedure ExplicitCAFileIsUsedAsIs;
    procedure DefaultResolutionMergesBothSources;
    procedure MergeInsertsMissingNewline;
    procedure SingleSourceShippedPassthrough;
    procedure SingleSourceSystemPassthrough;
    procedure NoSourcesResolverIsEmpty;
    procedure MergedCACacheStablePerProcess;
    procedure NoSourcesFailsClosed;
    procedure VerifyOffUsesSystemStore;
    procedure MergedBundleNameFitsCleanupMask;
  end;

  { TTestMultipartBody }
  { Offline tests of the TMaxMultipartStream composite (td-048): the UploadFile
    body is streamed from the source file instead of being buffered whole -
    the byte layout must stay identical to the stock multipart format, the
    Size must be exact before the first Read (Content-Length), the rewind
    must be stable (the keep-alive loop seeks the body back before every send
    attempt) and chunked reads must concatenate into the same body. A source
    serving short reads must still assemble the exact body, and one that stops
    short of its promised Size must fail loudly instead of truncating }
  TTestMultipartBody=class(TTestCase)
  private
    FDrainee: TMaxMultipartStream;
    { One fixed boundary shared by the whole suite: the composite does not
      validate the caller's format, the tests pin the stock byte layout }
    function BodyOf(const AFormData: TStrings): String;
  protected
    { AssertException needs a TTestMethod (a procedure of object): the drain
      of TruncatedSourceRaises goes through this wrapper }
    procedure DrainBody;
  published
    procedure CompositeBytesMatchStockLayout;
    procedure SizeIsPrecomputed;
    procedure RewindIsStable;
    procedure ChunkedReadsConcatenate;
    procedure EmptyFormDataSupported;
    procedure ShortReadsConcatenate;
    procedure TruncatedSourceRaises;
  end;

  { TTestStringBody }
  { Offline tests of the td-048 request-body path. The TMaxStringBodyStream
    wrapper serves the ApiCall JSON body straight from the referenced string
    buffer instead of copying it into a TStringStream - the Size must be
    exact before the first Read (Content-Length), the rewind must replay the
    identical bytes (the keep-alive loop seeks the body back before every
    send attempt), chunked reads must concatenate into the same body, the
    illegal seeks must fail loudly, and the empty body must serve nothing
    without faulting. The same suite pins JSONCompact, the compact
    serialization the stream now serves: fpjson's AsJSON is padded in
    FPC 3.2.2 and the API rejects a padded body carrying non-empty
    attachments (verified live) }
  TTestStringBody=class(TTestCase)
  private
    FDrainee: TMaxStringBodyStream;
    { Compares two trees by node class and value: the round-trip of the
      compact body must not change the nature of any node }
    function SameJSONTree(AExpected, AActual: TJSONData): Boolean;
  protected
    { AssertException needs a TTestMethod (a procedure of object): the
      raising seeks of IllegalSeeksRaise go through these wrappers }
    procedure SeekBeforeBody;
    procedure SeekPastBody;
    procedure SeekUnsupportedOrigin;
    { The same wrapper trick for the JSONCompact float guard: the
      non-number floats of ScalarsKeepTheirAsJSONForm go through these.
      Deliberately not published - registered test count stays as is }
    procedure CompactNaNFloatBody;
    procedure CompactInfinityFloatBody;
    procedure CompactNegInfinityFloatBody;
  published
    procedure SizeFeedsContentLength;
    procedure RewindReplaysIdenticalBytes;
    procedure ChunkedReadsConcatenate;
    procedure IllegalSeeksRaise;
    procedure EmptyStringServesNothing;
    procedure NilTreeSerializesEmpty;
    procedure CompactFormHasNoPadding;
    procedure StringEscaping;
    procedure UnicodeStaysRawUTF8;
    procedure ScalarsKeepTheirAsJSONForm;
    procedure CompactBodyRoundTripsSemantically;
  end;

  { TTestDaemonStartFailure }
  { td-091: the offline failed-start contract of the daemon example (its
    logic lives in examples/daemon/daemonapp.pas): a start that keeps
    failing must end the Run loop after exactly one DoRun pass with the
    non-zero exit code, and a failure of the best-effort cleanup drain
    (td-086) must not cancel that exit }
  TTestDaemonStartFailure=class(TTestCase)
  private
    // The daemon constructor reads the ini-derived Conf of the examples
    // configuration unit, the Run loop reads gStop and the failed-start pass
    // writes the SYSTEM exit code global: all three are process globals -
    // saved here, restored in TearDown
    FSavedConf: TAppConfig;
    FSavedStop: Boolean;
    FSavedExitCode: Integer;
    // The log file of SetUp, removed in TearDown (the log path cannot be
    // read back through Conf - it is restored first)
    FTestLogFile: String;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FailedStartExitsNonZero;
    procedure StopBeforeStartFailingDrainExitsNonZero;
  end;

  { TTestDesignTime }
  { td-026 regression pin: the published re-declaration of Token on
    TDTMaxLongPollBot (maxbot_dt.pas) must keep its stored False. A plain
    published re-declaration would stream the token back into the .lfm form
    file and the binary resource compiled from it; dropping the property
    from the published block instead would hide it from the Object
    Inspector entirely. Both ends are pinned here through RTTI }
  TTestDesignTime=class(TTestCase)
  published
    procedure TokenIsNotStreamedToFormFile;
  end;

implementation

uses
  jsonparser, maxbot, ssockets, Math, receiverthread, daemonapp,
  // typinfo+maxbot_dt: the td-026 regression pin of the TTestDesignTime
  // suite (Token stored False in the published re-declaration)
  maxbot_dt, typinfo,
  // testhttpharness: the mkstemp-style private temp fixture of TTestTLSTrust
  testhttpharness
  {$IFDEF UNIX}
  , baseunix // the private-dir mode check of the merged CA bundle (FpStat)
  {$ENDIF}
  ;

type
  { Opens the protected update path of TMaxSender and imitates the ban gate
    of TMaxBot offline: the updates of one known author are rejected }
  TTestGateBot=class(TMaxSender)
  private
    FBannedUser: Int64;
    FDispatched: Integer;
  public
    procedure CountDispatch({%H-}ASender: TObject; {%H-}AnUpdate: TMaxUpdateObj);
    procedure DeliverUpdate(AnUpdate: TMaxUpdateObj);
    function AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean; override;
    property BannedUser: Int64 read FBannedUser write FBannedUser;
    property Dispatched: Integer read FDispatched;
  end;

procedure TTestGateBot.CountDispatch(ASender: TObject; AnUpdate: TMaxUpdateObj);
begin
  Inc(FDispatched);
end;

procedure TTestGateBot.DeliverUpdate(AnUpdate: TMaxUpdateObj);
begin
  DoReceiveUpdate(AnUpdate); // the ownership moves to the sender
end;

function TTestGateBot.AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean;
begin
  Result:=inherited AcceptUpdate(AnUpdate) and (AnUpdate.AuthorId<>FBannedUser);
end;

type
  { Overrides the two leaf CA lookups with fixture paths (they are virtual for
    exactly this) and opens the protected resolution chain of TMaxSender to
    the offline tests }
  TTestTrustBot=class(TMaxSender)
  protected
    class function ShippedCAFile: String; override;
    class function DefaultSystemCAFile: String; override;
  public
    class var FixShipped: String;
    class var FixSystem: String;
    class function MergedBundle: String;      // -> MergedDefaultCAFile
    class function DefaultResolution: String; // -> ResolveDefaultCAFile
    class procedure DropMergedCACache;        // -> ResetMergedCACache
    function ResolveAnchor: String;           // -> ResolveTrustAnchor
  end;

class function TTestTrustBot.ShippedCAFile: String;
begin
  Result:=FixShipped;
end;

class function TTestTrustBot.DefaultSystemCAFile: String;
begin
  Result:=FixSystem;
end;

class function TTestTrustBot.MergedBundle: String;
begin
  Result:=MergedDefaultCAFile;
end;

class function TTestTrustBot.DefaultResolution: String;
begin
  Result:=ResolveDefaultCAFile(FixShipped, FixSystem);
end;

class procedure TTestTrustBot.DropMergedCACache;
begin
  ResetMergedCACache;
end;

function TTestTrustBot.ResolveAnchor: String;
begin
  // The resolution works from the configured values: the production callers
  // pass a configuration copy taken under the pool lock
  Result:=ResolveTrustAnchor(SSLCAFile, SSLVerifyCert);
end;

type
  TExceptionClass = class of Exception;

  { Offline stand-in for the registered HTTP broker: serves a canned body and
    status code without touching the network and records the last request.
    The canned state is class-level (set per test through Serve/FailWith),
    the instance fields mimic the broker state the library sets per request.
    RequestBody is NOT owned: ApiCall assigns and frees the stream itself }
  TMockHTTPClient=class(TBaseHTTPClient)
  private
    FAllowRedirect: Boolean;
    FCookies: TStringList;
    FProxyHost: String;
    FProxyPort: Word;
    FProxyUser: String;
    FProxyPass: String;
    FRequestBody: TStream;
    FRequestHeaders: TStringList;
    FResponseHeaders: TStringList;
    FIOTimeout: Integer;
    FSSLCAFile: String;
    FSSLVerifyCert: Boolean;
  private
    procedure CheckFail;
    procedure CaptureBody;
  public
    class var ResponseBody: String;
    class var ResponseCode: Integer;
    class var FailWith: TExceptionClass;
    class var LastURL: String;
    class var LastRequestBody: String;
    { How many mock instances were created since ResetState: the pool tests
      count constructions instead of connections - one client per pool slot }
    class var InstanceCount: Integer;
    { Snapshot of the request headers of the last served verb, in the broker
      format (the mock Create sets the same ':' separator as both brokers) }
    class var LastRequestHeaders: String;
    { The IO timeout last APPLIED through SetIOTimeout (td-018): the
      long-polling window travels per request, the tests assert the value that
      reached the transport, not the one left in the configuration property }
    class var LastIOTimeoutMs: Integer;
  protected
    function GetAllowRedirect: Boolean; override;
    function GetCookies: TStrings; override;
    function GetHTTPProxyHost: String; override;
    function GetHTTPProxyPassword: String; override;
    function GetHTTPProxyPort: Word; override;
    function GetHTTPProxyUsername: String; override;
    function GetInternalHTTPClient: TObject; override;
    function GetRequestBody: TStream; override;
    function GetRequestHeaders: TStrings; override;
    function GetResponseHeaders: TStrings; override;
    function GetResponseStatusCode: Integer; override;
    function GetResponseStatusText: String; override;
    function GetIOTimeout: Integer; override;
    function GetSSLCAFile: String; override;
    function GetSSLVerifyCert: Boolean; override;
    procedure SetAllowRedirect(AValue: Boolean); override;
    procedure SetCookies(AValue: TStrings); override;
    procedure SetHTTPProxyHost(AValue: String); override;
    procedure SetHTTPProxyPassword(AValue: String); override;
    procedure SetHTTPProxyPort(AValue: Word); override;
    procedure SetHTTPProxyUsername(AValue: String); override;
    procedure SetRequestBody(AValue: TStream); override;
    procedure SetRequestHeaders(AValue: TStrings); override;
    procedure SetIOTimeout(AValue: Integer); override;
    procedure SetSSLCAFile(AValue: String); override;
    procedure SetSSLVerifyCert(AValue: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class procedure Serve(const ABody: String; AStatusCode: Integer);
    class procedure ResetState;
    procedure AddHeader(const AHeader, AValue: String); override;
    class function EncodeUrlElement(S: String): String; override;
    function Get(const AUrl: String): String; override;
    function Post(const URL: string): String; override;
    function Put(const URL: string): String; override;
    function Delete(const URL: string): String; override;
    function FormPost(const URL: string; FormData: TStrings): String; override;
    function FilesFormPost(const AURL: string; FormData: TStrings;
      const AFiles: TStrings): String; override;
    function StreamsFormPost(const AURL: string; FormData: TStrings;
      const AFiles: TStrings): String; override;
    procedure FileFormPost(const AURL: string; FormData: TStrings;
      AFieldName, AFileName: string; const Response: TStream); override;
    procedure StreamFormPost(const AURL: string; FormData: TStrings;
      const AFieldName, AFileName: string; const AStream: TStream;
      const Response: TStream); override;
  end;

  { td-073: the second upload step fails while the first one succeeds - the
    upload transport branch is reachable offline only when the two steps fail
    independently (FailWith of the base mock fires on the step 1 verb too).
    The canned state and the counters are the SHARED class vars of
    TMockHTTPClient: Serve/ResetState keep working unchanged }
  TUploadFailHTTPClient=class(TMockHTTPClient)
  public
    procedure StreamFormPost(const AURL: string; FormData: TStrings;
      const AFieldName, AFileName: string; const AStream: TStream;
      const Response: TStream); override;
  end;

class procedure TMockHTTPClient.ResetState;
begin
  // every class variable in one place: the canned state must not survive a
  // test (a transport-failure test sets FailWith without ever calling Serve)
  // into the next one - UninstallMock clears it, Serve re-seeds it
  ResponseBody:='';
  ResponseCode:=0;
  FailWith:=nil;
  LastURL:='';
  LastRequestBody:='';
  InstanceCount:=0;
  LastRequestHeaders:='';
  LastIOTimeoutMs:=0;
end;

class procedure TMockHTTPClient.Serve(const ABody: String; AStatusCode: Integer);
begin
  // Re-seeds the canned answer only: a pool test swaps the answer mid-series
  // (Serve after the first call) and asserts the instance count right after -
  // wiping the counters here would erase what the test is about to check.
  // FailWith must go (a leftover would fail every following call); the Last*
  // fields are rewritten by the next served request, and ResetState (from
  // UninstallMock) still clears the full state after every test
  FailWith:=nil;
  ResponseBody:=ABody;
  ResponseCode:=AStatusCode;
end;

procedure TMockHTTPClient.CheckFail;
begin
  if Assigned(FailWith) then
    raise FailWith.Create('mock transport failure');
end;

function TMockHTTPClient.GetAllowRedirect: Boolean;
begin
  Result:=FAllowRedirect;
end;

function TMockHTTPClient.GetCookies: TStrings;
begin
  Result:=FCookies;
end;

function TMockHTTPClient.GetHTTPProxyHost: String;
begin
  Result:=FProxyHost;
end;

function TMockHTTPClient.GetHTTPProxyPassword: String;
begin
  Result:=FProxyPass;
end;

function TMockHTTPClient.GetHTTPProxyPort: Word;
begin
  Result:=FProxyPort;
end;

function TMockHTTPClient.GetHTTPProxyUsername: String;
begin
  Result:=FProxyUser;
end;

function TMockHTTPClient.GetInternalHTTPClient: TObject;
begin
  Result:=nil;
end;

function TMockHTTPClient.GetRequestBody: TStream;
begin
  Result:=FRequestBody;
end;

function TMockHTTPClient.GetRequestHeaders: TStrings;
begin
  Result:=FRequestHeaders;
end;

function TMockHTTPClient.GetResponseHeaders: TStrings;
begin
  Result:=FResponseHeaders;
end;

function TMockHTTPClient.GetResponseStatusCode: Integer;
begin
  Result:=ResponseCode;
end;

function TMockHTTPClient.GetResponseStatusText: String;
begin
  Result:='Mock';
end;

function TMockHTTPClient.GetIOTimeout: Integer;
begin
  Result:=FIOTimeout;
end;

function TMockHTTPClient.GetSSLCAFile: String;
begin
  Result:=FSSLCAFile;
end;

function TMockHTTPClient.GetSSLVerifyCert: Boolean;
begin
  Result:=FSSLVerifyCert;
end;

procedure TMockHTTPClient.SetAllowRedirect(AValue: Boolean);
begin
  FAllowRedirect:=AValue;
end;

procedure TMockHTTPClient.SetCookies(AValue: TStrings);
begin
  FCookies.Assign(AValue);
end;

procedure TMockHTTPClient.SetHTTPProxyHost(AValue: String);
begin
  FProxyHost:=AValue;
end;

procedure TMockHTTPClient.SetHTTPProxyPassword(AValue: String);
begin
  FProxyPass:=AValue;
end;

procedure TMockHTTPClient.SetHTTPProxyPort(AValue: Word);
begin
  FProxyPort:=AValue;
end;

procedure TMockHTTPClient.SetHTTPProxyUsername(AValue: String);
begin
  FProxyUser:=AValue;
end;

procedure TMockHTTPClient.SetRequestBody(AValue: TStream);
begin
  FRequestBody:=AValue;
end;

procedure TMockHTTPClient.SetRequestHeaders(AValue: TStrings);
begin
  FRequestHeaders.Assign(AValue);
end;

procedure TMockHTTPClient.SetIOTimeout(AValue: Integer);
begin
  FIOTimeout:=AValue;
  LastIOTimeoutMs:=AValue;
end;

procedure TMockHTTPClient.SetSSLCAFile(AValue: String);
begin
  FSSLCAFile:=AValue;
end;

procedure TMockHTTPClient.SetSSLVerifyCert(AValue: Boolean);
begin
  FSSLVerifyCert:=AValue;
end;

constructor TMockHTTPClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCookies:=TStringList.Create;
  FRequestHeaders:=TStringList.Create;
  // Same separator as both real brokers (and as fphttpclient itself): the
  // pool's Content-Type hygiene works through IndexOfName+Delete, and the
  // LastRequestHeaders snapshot gets the format a real broker keeps
  FRequestHeaders.NameValueSeparator:=':';
  FResponseHeaders:=TStringList.Create;
  FResponseHeaders.NameValueSeparator:=':';
  FSSLVerifyCert:=True;
  Inc(InstanceCount);
end;

destructor TMockHTTPClient.Destroy;
begin
  FreeAndNil(FResponseHeaders);
  FreeAndNil(FRequestHeaders);
  FreeAndNil(FCookies);
  inherited Destroy;
end;

procedure TMockHTTPClient.AddHeader(const AHeader, AValue: String);
begin
  FRequestHeaders.Values[AHeader]:=AValue;
end;

class function TMockHTTPClient.EncodeUrlElement(S: String): String;
begin
  Result:=S; // the mock never hits a real URL
end;

procedure TMockHTTPClient.CaptureBody;
var
  SS: TStringStream;
begin
  LastRequestBody:='';
  if not Assigned(FRequestBody) then
    Exit;
  FRequestBody.Position:=0;
  SS:=TStringStream.Create('');
  try
    SS.CopyFrom(FRequestBody, FRequestBody.Size);
    LastRequestBody:=SS.DataString;
  finally
    SS.Free;
  end;
end;

function TMockHTTPClient.Get(const AUrl: String): String;
begin
  CheckFail;
  LastURL:=AUrl;
  LastRequestHeaders:=FRequestHeaders.Text;
  Result:=ResponseBody;
end;

function TMockHTTPClient.Post(const URL: string): String;
begin
  CheckFail;
  LastURL:=URL;
  LastRequestHeaders:=FRequestHeaders.Text;
  CaptureBody;
  Result:=ResponseBody;
end;

function TMockHTTPClient.Put(const URL: string): String;
begin
  CheckFail;
  LastURL:=URL;
  LastRequestHeaders:=FRequestHeaders.Text;
  CaptureBody;
  Result:=ResponseBody;
end;

function TMockHTTPClient.Delete(const URL: string): String;
begin
  CheckFail;
  LastURL:=URL;
  LastRequestHeaders:=FRequestHeaders.Text;
  Result:=ResponseBody;
end;

function TMockHTTPClient.FormPost(const URL: string; FormData: TStrings): String;
begin
  CheckFail;
  LastURL:=URL;
  Result:=ResponseBody;
end;

function TMockHTTPClient.FilesFormPost(const AURL: string; FormData: TStrings;
  const AFiles: TStrings): String;
begin
  CheckFail;
  LastURL:=AURL;
  Result:=ResponseBody;
end;

function TMockHTTPClient.StreamsFormPost(const AURL: string; FormData: TStrings;
  const AFiles: TStrings): String;
begin
  CheckFail;
  LastURL:=AURL;
  Result:=ResponseBody;
end;

procedure TMockHTTPClient.FileFormPost(const AURL: string; FormData: TStrings;
  AFieldName, AFileName: string; const Response: TStream);
begin
  CheckFail;
  LastURL:=AURL;
end;

procedure TMockHTTPClient.StreamFormPost(const AURL: string; FormData: TStrings;
  const AFieldName, AFileName: string; const AStream: TStream;
  const Response: TStream);
begin
  CheckFail;
  LastURL:=AURL;
end;

procedure TUploadFailHTTPClient.StreamFormPost(const AURL: string;
  FormData: TStrings; const AFieldName, AFileName: string;
  const AStream: TStream; const Response: TStream);
begin
  raise ESocketError.Create('mock upload transport failure');
end;

type
  { A real TMaxBot offline: the callbacks are cut off at the override - the
    inherited TMaxBot.DoReceiveCallback answers the callback over HTTP, so the
    counter replaces it and a banned presser must never reach it }
  TTestGateMaxBot=class(TMaxBot)
  private
    FCallbackReached: Integer;
    FDispatched: Integer;
  public
    procedure CountDispatch({%H-}ASender: TObject; {%H-}AnUpdate: TMaxUpdateObj);
    procedure DeliverUpdate(AnUpdate: TMaxUpdateObj);
    procedure DoReceiveCallback(ACallback: TMaxCallbackObj); override;
    property CallbackReached: Integer read FCallbackReached;
    property Dispatched: Integer read FDispatched;
  end;

procedure TTestGateMaxBot.CountDispatch(ASender: TObject; AnUpdate: TMaxUpdateObj);
begin
  Inc(FDispatched);
end;

procedure TTestGateMaxBot.DeliverUpdate(AnUpdate: TMaxUpdateObj);
begin
  DoReceiveUpdate(AnUpdate); // the ownership moves to the sender
end;

procedure TTestGateMaxBot.DoReceiveCallback(ACallback: TMaxCallbackObj);
begin
  // no inherited: it ends with AnswerCallbackQuery, an HTTP request
  Inc(FCallbackReached);
end;

{ Points the own statistics log of the bot to a scratch file }
procedure SetUpBotStatLog(Bot: TMaxBot);
begin
  Bot.StatLogger.Directory:=IncludeTrailingPathDelimiter(GetTempDir);
  Bot.StatLogger.FilePrefix:='~fpmaxbotgate';
  Bot.StatLogger.Resume;
  DeleteFile(Bot.StatLogger.FileName);
end;

function StatLinesOf(AStatLog: TMaxStatLog): Integer;
var
  S: TStringList;
begin
  S:=TStringList.Create;
  try
    if FileExists(AStatLog.FileName) then
      S.LoadFromFile(AStatLog.FileName);
    Result:=S.Count;
  finally
    S.Free;
  end;
end;

{ Reads a whole file byte-exact: the fixtures and the merged bundle are
  compared as raw bytes, not as text lines }
function FileBytes(const APath: String): String;
var
  FS: TFileStream;
begin
  FS:=TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size);
    if Length(Result)>0 then
      FS.ReadBuffer(Result[1], Length(Result));
  finally
    FS.Free;
  end;
end;

const
  Msg='Test message sent from %s. Test procedure: %s';
  pht_cptn='Test photo sent from %s. Test procedure: %s';
  { Byte-exact PEM-like fixture bodies: no valid certificates, but the merge
    only moves bytes; all end with a line break. The Alt body rewrites a
    fixture mid-test to prove that the per-process cache does not re-read it }
  FixtureShippedPEM='-----BEGIN CERTIFICATE-----'#10'FIXTURE-1'#10'-----END CERTIFICATE-----'#10;
  FixtureSystemPEM='-----BEGIN CERTIFICATE-----'#10'FIXTURE-2'#10'-----END CERTIFICATE-----'#10;
  FixtureShippedAltPEM='-----BEGIN CERTIFICATE-----'#10'FIXTURE-1-ALT'#10'-----END CERTIFICATE-----'#10;

{ TTestSender }

procedure TTestSender.SetUp;
begin
  inherited SetUp;
  FUrl:=Conf.ReadString('Send', 'Url', EmptyStr);
  FPhotoUrl:=Conf.ReadString('Send', 'photourl', EmptyStr);
  FPhotoFile:=Conf.ReadString('Send', 'PhotoFile', EmptyStr);
  Bot.OnReceiveUpdate:=@BotReceiveUpdate;
  FReceived:=False;
end;

procedure TTestSender.BotReceiveUpdate(ASender: TObject; AnUpdate: TMaxUpdateObj);
begin
  SaveJSONData(Bot.JSONResponse, '~responce.json');
  SaveString(AnUpdate.AsString, '~update.json');
  FReceived:=True;
end;

procedure TTestSender.getMe;
begin
  if not Bot.GetMe then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
  if not Assigned(Bot.BotInfo) or (Bot.BotInfo.UserId=0) then
    Fail('getMe returned no bot info');
  SaveJSONData(Bot.JSONResponse, '~responce.json');
end;

procedure TTestSender.sendMessage;
begin
  if not Bot.SendMessage(ChatID, Format(Msg, [Self.ClassName, TestName])) then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.sendMessageWithInlineKeyboard;
var
  AAttachments: TJSONArray;
  AButtons: TJSONArray;
  ARow: TJSONArray;
  AButton: TJSONObject;
  APayload: TJSONObject;
begin
  { The MAX inline keyboard is an attachment:
    {"type":"inline_keyboard","payload":{"buttons":[[...]]}} - buttons is a
    two-dimensional array (rows of buttons), per the MAX Bot API schema }
  AButton:=TJSONObject.Create;
  AButton.Add('type', 'callback');
  AButton.Add('text', 'Test button');
  AButton.Add('payload', 'test_callback');
  ARow:=TJSONArray.Create;
  ARow.Add(AButton);
  AButtons:=TJSONArray.Create;
  AButtons.Add(ARow);
  APayload:=TJSONObject.Create;
  APayload.Add('buttons', AButtons);
  AButton:=TJSONObject.Create;
  AButton.Add('type', 'inline_keyboard');
  AButton.Add('payload', APayload);
  AAttachments:=TJSONArray.Create;
  try
    AAttachments.Add(AButton);
    if not Bot.SendMessageEx(ChatID, Format(Msg, [Self.ClassName, TestName]), AAttachments) then
      Fail('Connection error. See log');
  finally
    AAttachments.Free;
  end;
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.sendPhoto;
begin
  if PhotoUrl=EmptyStr then
    Fail('Please, specify the URL of a photo in testmax.ini ([Send] photourl)!');
  if not Bot.sendPhoto(ChatID, PhotoUrl) then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.sendPhotoByFileName;
var
  Token: String;
begin
  if (PhotoFile=EmptyStr) or not FileExists(PhotoFile) then
    Fail('Please, specify an existing image file in testmax.ini ([Send] PhotoFile)!');
  Token:=Bot.UploadFileByFileName(uptImage, PhotoFile);
  if Token=EmptyStr then
    Fail('Failed to upload the file. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
  if not Bot.sendPhoto(ChatID, Token) then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.uploadFile;
var
  aStream: TFileStream;
  Token: String;
begin
  if (PhotoFile=EmptyStr) or not FileExists(PhotoFile) then
    Fail('Please, specify an existing image file in testmax.ini ([Send] PhotoFile)!');
  aStream:=TFileStream.Create(PhotoFile, fmOpenRead or fmShareDenyWrite);
  try
    Token:=Bot.UploadFile(uptFile, aStream, ExtractFileName(PhotoFile));
  finally
    aStream.Free;
  end;
  if Token=EmptyStr then
    Fail('Failed to upload the file. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
  if not Bot.sendFile(ChatID, Token) then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.setWebhook;
begin
  if Url=EmptyStr then
    Fail('Please, specify the https URL for the subscription in testmax.ini ([Send] Url)!');
  if not Bot.SetWebhook(Url) then
    Fail('Connection error. See log');
  SaveJSONData(Bot.JSONResponse, '~responce.json');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.deleteWebhook;
begin
  if not Bot.DeleteWebhook(Url) then
    Fail('Connection error. See log');
  SaveJSONData(Bot.JSONResponse, '~responce.json');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
end;

procedure TTestSender.ReceiveUpdate;
begin
  { Please send a message to the test bot immediately before running the test }
  if not Bot.GetUpdates(EmptyStr, 0, 10) then
    Fail('Connection error. See log');
  if Bot.LastErrorCode<>EmptyStr then
    Fail('Error from bot API server. Error code: '+Bot.LastErrorCode+
      '. Description: '+Bot.LastErrorMsg);
  if not FReceived then
    Fail('No updates were received. Send, for example, a message to the test bot')
  else
    Bot.GetUpdatesEx(100, 1); // move the marker forward
end;

{ TTestSenderProcedure }

procedure TTestSenderProcedure.sendMessage;
var
  AToken: String;
  AChatID: Int64;
begin
  AToken:=Conf.ReadString('Bot', 'Token', EmptyStr);
  AChatID:=Conf.ReadInt64('Chat', 'ID', 0);
  if not TMaxBotSendMessage(AToken, AChatID, Format(Msg, [Self.ClassName, TestName])) then
    Fail('Fail to send message from bot!');
end;

{ TTestSenderTypes }

procedure TTestSenderTypes.ParseUpdateList;
const
  UpdatesJSON='{"updates":[' +
      '{"update_type":"message_created","timestamp":1700000000000,' +
        '"message":{"sender":{"user_id":99,"is_bot":false,"first_name":"Alice"},' +
        '"recipient":{"chat_id":42,"chat_type":"dialog"},' +
        '"timestamp":1700000000000,' +
        '"body":{"mid":"mid.1","seq":1,"text":"Hello"}}},' +
      '{"update_type":"bot_started","chat_id":42,"user_id":99,' +
        '"user":{"user_id":99,"first_name":"Alice"},"payload":"start_payload"}' +
    '],"marker":"42"}';
var
  Updates: TMaxUpdateObjList;
  AMarker: String;
  JSONData: TJSONData;
begin
  JSONData:=GetJSON(UpdatesJSON);
  try
    AssertTrue('A valid update list should be parsed',
      maxtypes.ParseUpdateList(JSONData, Updates, AMarker));
  finally
    JSONData.Free;
  end;
  try
    AssertEquals('Two updates should be parsed', 2, Updates.Count);
    AssertEquals('42', AMarker);
    AssertEquals(Ord(utMessageCreated), Ord(Updates[0].UpdateType));
    AssertEquals(99, Updates[0].Message.Sender.UserId);
    AssertEquals(42, Updates[0].Message.ChatId);
    AssertEquals('Hello', Updates[0].Message.Body.Text);
    AssertEquals(Ord(utBotStarted), Ord(Updates[1].UpdateType));
    AssertEquals('start_payload', Updates[1].Payload);
    AssertEquals('Alice (99)', Updates[1].User.AsString);
  finally
    Updates.Free;
  end;
end;

procedure TTestSenderTypes.ParseUpdateListEdgeCases;
const
  NullMarkerJSON='{"updates":[],"marker":null}';
  IntMarkerJSON='{"updates":[],"marker":123456789012345}';
  NoMarkerJSON='{"updates":[]}';
  NotArrayJSON='{"updates":{"bad":1},"marker":1}';
  DirtyElementsJSON='{"updates":[42,"x",{}],"marker":7}';

  procedure CheckParsed(const AJSON: String; ACount: Integer; const AMarker: String);
  var
    Updates: TMaxUpdateObjList;
    Marker: String;
    Data: TJSONData;
  begin
    Data:=GetJSON(AJSON);
    try
      AssertTrue('A parseable response should return True',
        maxtypes.ParseUpdateList(Data, Updates, Marker));
      try
        AssertEquals(ACount, Updates.Count);
        AssertEquals(AMarker, Marker);
      finally
        Updates.Free;
      end;
    finally
      Data.Free;
    end;
  end;

var
  Updates: TMaxUpdateObjList;
  Marker: String;
  Data: TJSONData;
begin
  { The canonical marker is int64 and nullable: both forms and the absence
    of the key are read without an exception }
  CheckParsed(NullMarkerJSON, 0, '');
  CheckParsed(IntMarkerJSON, 0, '123456789012345');
  CheckParsed(NoMarkerJSON, 0, '');
  { 'updates' of a wrong type yields no updates instead of an exception }
  CheckParsed(NotArrayJSON, 0, '1');
  { Non-object elements are skipped, the object ones are taken }
  CheckParsed(DirtyElementsJSON, 1, '7');
  { A root that is not an object is rejected without an exception }
  Data:=GetJSON('"not an object"');
  try
    Updates:=nil;
    Marker:='';
    AssertFalse('A root that is not an object should be rejected',
      maxtypes.ParseUpdateList(Data, Updates, Marker));
    AssertNull('No list should be created for a wrong root', Updates);
  finally
    Data.Free;
  end;
end;

procedure TTestSenderTypes.ParseMessageUpdate;
const
  MessageJSON='{"update_type":"message_callback","chat_id":42,"message_id":"mid.7",' +
    '"callback":{"timestamp":1700000000000,"callback_id":"cb.1","payload":"GetStat today",' +
      '"user":{"user_id":99,"first_name":"Alice"}},' +
    '"message":{"recipient":{"chat_id":42},"body":{"mid":"mid.6","seq":6,"text":"With keyboard"}}}';
var
  UpdateObj: TMaxUpdateObj;
  JSONData: TJSONData;
begin
  { TMaxObj.Create takes ownership of the passed JSON object }
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(MessageJSON)));
  try
    AssertEquals(Ord(utMessageCallback), Ord(UpdateObj.UpdateType));
    AssertEquals('mid.7', UpdateObj.MessageId);
    AssertEquals(42, UpdateObj.ChatId);
    AssertNotNull('Callback should be assigned', UpdateObj.Callback);
    AssertEquals('GetStat today', UpdateObj.Callback.Payload);
    AssertEquals('cb.1', UpdateObj.Callback.CallbackId);
    AssertEquals(99, UpdateObj.Callback.User.UserId);
    AssertSame('Callback.User should be memoized (owned by the wrapper)',
      UpdateObj.Callback.User, UpdateObj.Callback.User);
    AssertEquals('mid.6', UpdateObj.Message.Body.Mid);
  finally
    UpdateObj.Free;
  end;
end;

procedure TTestSenderTypes.TypeMismatchDefaults;
const
  MismatchJSON='{"update_type":"bot_started","chat_id":"not-a-number",' +
    '"user":{"user_id":"abc","first_name":"Alice","is_bot":"yes"},' +
    '"user_locale":{"bad":1},"payload":true,' +
    '"message":{"sender":{"user_id":"42"},' +
      '"recipient":{"chat_id":"not-a-number","chat_type":42},' +
      '"body":{"mid":"mid.9","seq":"x","text":123,"attachments":{"bad":1}}},' +
    '"callback":{"user":{"user_id":[]}}}';
var
  UpdateObj: TMaxUpdateObj;
  BotInfo: TMaxBotInfoObj;
  Attachment: TMaxAttachmentObj;
begin
  { A type mismatch in any member yields a default instead of raising }
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(MismatchJSON)));
  try
    AssertEquals(Ord(utBotStarted), Ord(UpdateObj.UpdateType));
    AssertEquals(0, UpdateObj.ChatId);                 // string chat_id
    AssertEquals(0, UpdateObj.User.UserId);            // string user_id
    AssertEquals('Alice', UpdateObj.User.FirstName);
    AssertFalse(UpdateObj.User.IsBot);                 // string is_bot
    AssertEquals('', UpdateObj.UserLocale);            // object user_locale
    AssertEquals('', UpdateObj.Payload);               // boolean payload
    AssertEquals(0, UpdateObj.Message.Sender.UserId);  // string user_id
    AssertEquals(0, UpdateObj.Message.ChatId);         // string chat_id
    AssertEquals(Ord(ctUnknown), Ord(UpdateObj.Message.Recipient.ChatType));
    AssertEquals(0, UpdateObj.Message.Body.Seq);       // string seq
    AssertEquals('123', UpdateObj.Message.Body.Text);  // numbers are read as strings
    AssertEquals(0, UpdateObj.Message.Body.Attachments.Count); // not an array
    AssertEquals(0, UpdateObj.Callback.User.UserId);   // array user_id
  finally
    UpdateObj.Free;
  end;
  { 'commands' of a wrong type yields no commands }
  BotInfo:=TMaxBotInfoObj.Create(TJSONObject(GetJSON('{"commands":{"bad":1}}')));
  try
    AssertEquals(0, BotInfo.Commands.Count);
  finally
    BotInfo.Free;
  end;
  { 'buttons' of a wrong type yields an empty typed list (td-015) }
  Attachment:=TMaxAttachmentObj.Create(TJSONObject(GetJSON(
    '{"type":"inline_keyboard","payload":{"buttons":{"bad":1}}}')));
  try
    AssertEquals('a non-array buttons member yields no buttons', 0,
      Attachment.Payload.Buttons.Count);
  finally
    Attachment.Free;
  end;
end;

procedure TTestSenderTypes.UpdateSpecificMembers;
const
  DialogMutedJSON='{"update_type":"dialog_muted","chat_id":42,' +
    '"user":{"user_id":99,"first_name":"Alice"},"muted_until":1700000000}';
  UserAddedJSON='{"update_type":"user_added","chat_id":43,' +
    '"user":{"user_id":100,"first_name":"Bob"},"inviter_id":99,"is_channel":false}';
  UserAddedByLinkJSON='{"update_type":"user_added","chat_id":43,' +
    '"user":{"user_id":101,"first_name":"Cid"},"inviter_id":null}';
  UserRemovedJSON='{"update_type":"user_removed","chat_id":43,' +
    '"user":{"user_id":100,"first_name":"Bob"},"admin_id":7}';
  MessageCreatedJSON='{"update_type":"message_created","timestamp":1700000000000,' +
    '"message":{"sender":{"user_id":99},"recipient":{"chat_id":42},' +
    '"body":{"mid":"mid.1","seq":1,"text":"Hi"}}}';
var
  UpdateObj: TMaxUpdateObj;
begin
  // td-015: the user-event members are required by the schema and read flat
  // from the update payload (the Go SDK serves them through ChatProp)
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(DialogMutedJSON)));
  try
    AssertEquals('muted_until is read from dialog_muted', 1700000000,
      UpdateObj.MutedUntil);
  finally
    UpdateObj.Free;
  end;
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(UserAddedJSON)));
  try
    AssertEquals('inviter_id is read from user_added', 99, UpdateObj.InviterId);
  finally
    UpdateObj.Free;
  end;
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(UserAddedByLinkJSON)));
  try
    AssertEquals('a null inviter_id (joined by link) reads as 0', 0,
      UpdateObj.InviterId);
  finally
    UpdateObj.Free;
  end;
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(UserRemovedJSON)));
  try
    AssertEquals('admin_id is read from user_removed', 7, UpdateObj.AdminId);
  finally
    UpdateObj.Free;
  end;
  { The members belong to their update types only: elsewhere the default }
  UpdateObj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(MessageCreatedJSON)));
  try
    AssertEquals('no muted_until without dialog_muted', 0, UpdateObj.MutedUntil);
    AssertEquals('no inviter_id without user_added', 0, UpdateObj.InviterId);
    AssertEquals('no admin_id without user_removed', 0, UpdateObj.AdminId);
  finally
    UpdateObj.Free;
  end;
end;

procedure TTestSenderTypes.MessageLinkAccessor;
const
  ReplyJSON='{"sender":{"user_id":99,"first_name":"Alice"},' +
    '"recipient":{"chat_id":42,"chat_type":"dialog"},"timestamp":1700000000000,' +
    '"link":{"type":"reply","mid":"mid.0"},' +
    '"body":{"mid":"mid.1","seq":1,"text":"Answer"}}';
  NoLinkJSON='{"sender":{"user_id":99},"recipient":{"chat_id":42},' +
    '"body":{"mid":"mid.2","seq":2,"text":"Plain"}}';
var
  MessageObj: TMaxMessageObj;
begin
  // td-015: link (the reply/forward origin) is the only way to tell a reply
  // or a forward from a plain message
  MessageObj:=TMaxMessageObj.Create(TJSONObject(GetJSON(ReplyJSON)));
  try
    AssertEquals('a reply link is typed', Ord(mltReply),
      Ord(MessageObj.Link.LinkType));
    AssertEquals('the link points at the origin message', 'mid.0',
      MessageObj.Link.Mid);
    AssertSame('Link should be memoized (owned by the wrapper)',
      MessageObj.Link, MessageObj.Link);
  finally
    MessageObj.Free;
  end;
  { A message without link yields an empty wrapper, not an exception }
  MessageObj:=TMaxMessageObj.Create(TJSONObject(GetJSON(NoLinkJSON)));
  try
    AssertEquals('no link member reads as mltUnknown', Ord(mltUnknown),
      Ord(MessageObj.Link.LinkType));
    AssertEquals('no link member has no mid', '', MessageObj.Link.Mid);
  finally
    MessageObj.Free;
  end;
end;

procedure TTestSenderTypes.ChatDialogWithUserAccessor;
const
  DialogChatJSON='{"chat_id":123,"type":"dialog","status":"active",' +
    '"dialog_with_user":{"user_id":55,"first_name":"Carol","username":"carol"}}';
  ChannelJSON='{"chat_id":124,"type":"channel","status":"active"}';
var
  ChatObj: TMaxChatObj;
begin
  // td-015: dialog_with_user carries the counterpart user of a dialog chat
  ChatObj:=TMaxChatObj.Create(TJSONObject(GetJSON(DialogChatJSON)));
  try
    AssertEquals('the dialog counterpart is parsed', 55,
      ChatObj.DialogWithUser.UserId);
    AssertEquals('Carol', ChatObj.DialogWithUser.FirstName);
    AssertEquals('carol', ChatObj.DialogWithUser.Username);
    AssertSame('DialogWithUser should be memoized (owned by the wrapper)',
      ChatObj.DialogWithUser, ChatObj.DialogWithUser);
  finally
    ChatObj.Free;
  end;
  { A group chat/channel has no dialog_with_user: an empty wrapper }
  ChatObj:=TMaxChatObj.Create(TJSONObject(GetJSON(ChannelJSON)));
  try
    AssertEquals('no dialog_with_user reads as user 0', 0,
      ChatObj.DialogWithUser.UserId);
    AssertEquals('', ChatObj.DialogWithUser.FirstName);
  finally
    ChatObj.Free;
  end;
end;

procedure TTestSenderTypes.PayloadButtonsTyped;
const
  KeyboardJSON='{"type":"inline_keyboard","payload":{"buttons":[[' +
      '{"type":"callback","text":"Press","payload":"do_it"},' +
      '{"type":"link","text":"Open","url":"https://example.com"}],' +
    '[{"type":"request_geo_location","text":"Geo","quick":true},' +
      '{"type":"open_app","text":"App","web_app":"mybot"}]]}}';
var
  Attachment: TMaxAttachmentObj;
begin
  // td-015: the inline keyboard of an incoming message is readable typed,
  // no raw JSON array rides out of the wrapper any more
  Attachment:=TMaxAttachmentObj.Create(TJSONObject(GetJSON(KeyboardJSON)));
  try
    AssertEquals('all rows are flattened in wire order', 4,
      Attachment.Payload.Buttons.Count);
    AssertEquals('callback', Attachment.Payload.Buttons[0].ButtonType);
    AssertEquals('Press', Attachment.Payload.Buttons[0].Text);
    AssertEquals('do_it', Attachment.Payload.Buttons[0].Payload);
    AssertEquals('link', Attachment.Payload.Buttons[1].ButtonType);
    AssertEquals('https://example.com', Attachment.Payload.Buttons[1].URL);
    AssertTrue('quick is read as a boolean', Attachment.Payload.Buttons[2].Quick);
    AssertEquals('open_app', Attachment.Payload.Buttons[3].ButtonType);
    AssertEquals('mybot', Attachment.Payload.Buttons[3].WebApp);
    AssertSame('Buttons should be memoized (owned by the wrapper)',
      Attachment.Payload.Buttons, Attachment.Payload.Buttons);
  finally
    Attachment.Free;
  end;
  { A payload without buttons yields an empty list, not an exception }
  Attachment:=TMaxAttachmentObj.Create(TJSONObject(GetJSON(
    '{"type":"inline_keyboard","payload":{"token":"t"}}')));
  try
    AssertEquals('payload without buttons yields an empty list', 0,
      Attachment.Payload.Buttons.Count);
  finally
    Attachment.Free;
  end;
end;

procedure TTestSenderTypes.AsStringVirtualDispatch;
const
  MessageJSON='{"sender":{"user_id":99,"first_name":"Alice"},' +
    '"recipient":{"chat_id":42},"body":{"mid":"mid.1","seq":1,"text":"Hello"}}';
  UpdateJSON='{"update_type":"message_created","message":' + MessageJSON + '}';
  UserJSON='{"user_id":99,"first_name":"Alice"}';
var
  Obj: TMaxObj;
begin
  // td-015: AsString is virtual - a call through a TMaxObj reference must
  // run the human-readable override, not fall back to the raw JSON dump
  Obj:=TMaxMessageObj.Create(TJSONObject(GetJSON(MessageJSON)));
  try
    AssertEquals('the message form through the base reference',
      'message mid.1: Hello', Obj.AsString);
    AssertTrue('the raw JSON does not leak through the base reference',
      Pos('"sender"', Obj.AsString)=0);
  finally
    Obj.Free;
  end;
  Obj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(UpdateJSON)));
  try
    AssertTrue('the update form starts with the update type',
      Pos('message_created:', Obj.AsString)=1);
    AssertTrue('the update form ends with the ids (td-016)',
      Pos('(chat_id=0, user_id=0)', Obj.AsString)>0);
  finally
    Obj.Free;
  end;
  // td-016: a non-message update has no message node - the lazy Message
  // wrapper must not leak the old "bot_started: message : " garbage
  Obj:=TMaxUpdateObj.Create(TJSONObject(GetJSON(
    '{"update_type":"bot_started","timestamp":1700000000000,"user":{"user_id":77}}')));
  try
    AssertEquals('a non-message update carries no message stub',
      'bot_started (chat_id=0, user_id=0)', Obj.AsString);
  finally
    Obj.Free;
  end;
  Obj:=TMaxUserObj.Create(TJSONObject(GetJSON(UserJSON)));
  try
    AssertEquals('the user form through the base reference', 'Alice (99)',
      Obj.AsString);
  finally
    Obj.Free;
  end;
end;

procedure TTestSenderTypes.MakeAttachmentJSONTest;
var
  Attachment: TJSONObject;
begin
  Attachment:=MakeAttachmentJSON(uptImage, 'token123');
  try
    AssertEquals('image', Attachment.Strings['type']);
    AssertEquals('token123', Attachment.FindPath('payload.token').AsString);
  finally
    Attachment.Free;
  end;
  Attachment:=MakeAttachmentJSON(uptVideo, 'https://example.com/video.mp4');
  try
    AssertEquals('video', Attachment.Strings['type']);
    AssertEquals('https://example.com/video.mp4', Attachment.FindPath('payload.url').AsString);
  finally
    Attachment.Free;
  end;
end;

procedure TTestSenderTypes.InlineKeyboardAttachmentShape2D;
var
  Arr: TJSONArray;
begin
  Arr:=MakeInlineKeyboardAttachment(['Press', 'do_it']);
  try
    // one assert pins both the shape (buttons must stay two-dimensional - a
    // 1D buttons array is rejected by the API with HTTP 400 proto.payload)
    // and the compact serialization the API accepts
    AssertEquals('the 2D one-row shape pinned exactly',
      '[{"type":"inline_keyboard","payload":{"buttons":[[' +
      '{"type":"callback","text":"Press","payload":"do_it"}]]}}]',
      JSONCompact(Arr));
  finally
    Arr.Free;
  end;
end;

procedure TTestSenderTypes.InlineKeyboardAttachmentMultipleButtonsOneRow;
var
  Arr: TJSONArray;
  Buttons, Row: TJSONArray;
begin
  Arr:=MakeInlineKeyboardAttachment(['Yes', 'y', 'No', 'n']);
  try
    AssertEquals('one attachment', 1, Arr.Count);
    // the shape is pinned by InlineKeyboardAttachmentShape2D: the payload
    // sits at Items[1] of the attachment, the buttons path is the only one
    Buttons:=TJSONArray(TJSONObject(Arr.Items[0]).Items[1].FindPath('buttons'));
    AssertEquals('a single row holds all the buttons', 1, Buttons.Count);
    Row:=TJSONArray(Buttons.Items[0]);
    AssertEquals('the row holds both buttons', 2, Row.Count);
    AssertEquals('the first button text', 'Yes',
      TJSONObject(Row.Items[0]).Strings['text']);
    AssertEquals('the last button payload', 'n',
      TJSONObject(Row.Items[1]).Strings['payload']);
  finally
    Arr.Free;
  end;
end;

procedure TTestSenderTypes.InlineKeyboardAttachmentEscapesTextAndPayload;
var
  Arr: TJSONArray;
  RoundTrip: TJSONData;
  Payload: TJSONObject;
  Rows, Row: TJSONArray;
begin
  // a quote and a backslash in the text, a backslash in the payload: the
  // escaping is the compact serializer's job (JSONCompact's own
  // JSONEscapeString), never manual - the body must parse back into the
  // byte-identical strings
  Arr:=MakeInlineKeyboardAttachment(['He said "hi"\today', 'pay\load']);
  try
    RoundTrip:=GetJSON(JSONCompact(Arr));
    try
      // the shape is pinned by InlineKeyboardAttachmentShape2D: the payload
      // at Items[1] of the attachment, buttons holds the single row
      Payload:=TJSONObject(TJSONObject(TJSONArray(RoundTrip).Items[0]).Items[1]);
      Rows:=TJSONArray(Payload.Items[0]);
      Row:=TJSONArray(Rows.Items[0]);
      AssertEquals('the text survives the round-trip', 'He said "hi"\today',
        TJSONObject(Row.Items[0]).Strings['text']);
      AssertEquals('the payload survives the round-trip', 'pay\load',
        TJSONObject(Row.Items[0]).Strings['payload']);
    finally
      RoundTrip.Free;
    end;
  finally
    Arr.Free;
  end;
end;

procedure TTestSenderTypes.MakeKeyboardWithOddPairs;
begin
  MakeInlineKeyboardAttachment(['OnlyText']);
end;

procedure TTestSenderTypes.MakeKeyboardWithoutPairs;
begin
  MakeInlineKeyboardAttachment([]);
end;

procedure TTestSenderTypes.InlineKeyboardAttachmentRejectsBrokenPairs;
begin
  // a dangling Text without a Payload or a keyboard with nothing on it are
  // caller bugs: they must fail loudly, not ship a body the API rejects
  AssertException('an odd pair count fails loudly', Exception,
    @MakeKeyboardWithOddPairs);
  AssertException('an empty pair list fails loudly', Exception,
    @MakeKeyboardWithoutPairs);
end;

procedure TTestSenderTypes.UpdateTypeConverters;
begin
  AssertEquals(Ord(utMessageCallback), Ord(StrToMaxUpdateType('message_callback')));
  AssertEquals('bot_started', MaxUpdateTypeToStr(utBotStarted));
  AssertEquals(Ord(uptAudio), Ord(StrToMaxUploadType('audio')));
  AssertEquals('file', MaxUploadTypeToStr(uptFile));
  AssertEquals(Ord(mltForward), Ord(StrToMaxMessageLinkType('forward')));
  AssertEquals('reply', MaxMessageLinkTypeToStr(mltReply));
  AssertEquals(Ord(atInlineKeyboard), Ord(StrToMaxAttachmentType('inline_keyboard')));
  AssertEquals(Ord(ctChannel), Ord(StrToMaxChatType('channel')));
end;

procedure TTestSenderTypes.AcceptUpdateDropsBannedAuthor;
const
  // no top-level user_id: the author of message_created lives only in
  // message.sender.user_id (schema v0.0.33)
  SenderAuthorJSON='{"update_type":"message_created","timestamp":1700000000000,' +
    '"message":{"sender":{"user_id":%d,"is_bot":false,"first_name":"Alice"},' +
    '"recipient":{"chat_id":42,"chat_type":"dialog"},' +
    '"timestamp":1700000000000,' +
    '"body":{"mid":"mid.1","seq":1,"text":"Hello"}}}';
var
  Bot: TTestGateBot;
  StatLog: TMaxStatLog;
  AnUpdate: TMaxUpdateObj;

  function StatLines: Integer;
  var
    S: TStringList;
  begin
    S:=TStringList.Create;
    try
      if FileExists(StatLog.FileName) then
        S.LoadFromFile(StatLog.FileName);
      Result:=S.Count;
    finally
      S.Free;
    end;
  end;

begin
  AnUpdate:=TMaxUpdateObj.Create(TJSONObject(GetJSON(Format(SenderAuthorJSON, [99]))));
  try
    AssertEquals('message_created has no top-level user_id', 0, AnUpdate.UserId);
    AssertEquals('the author is derived from message.sender.user_id',
      99, AnUpdate.AuthorId);
  finally
    AnUpdate.Free;
  end;
  Bot:=TTestGateBot.Create(EmptyStr);
  try
    Bot.BannedUser:=99;
    Bot.OnAnyUpdate:=@Bot.CountDispatch;
    StatLog:=TMaxStatLog.Create(nil);
    try
      StatLog.Directory:=IncludeTrailingPathDelimiter(GetTempDir);
      StatLog.FilePrefix:='~fpmaxgatetest';
      StatLog.Resume;
      DeleteFile(StatLog.FileName);
      Bot.UpdateLogger:=StatLog;
      // both updates are owned (and freed) by the bot after DeliverUpdate
      Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
        Format(SenderAuthorJSON, [99])))));
      AssertEquals('a banned author is not dispatched', 0, Bot.Dispatched);
      AssertEquals('a banned author is not logged', 0, StatLines);
      Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
        Format(SenderAuthorJSON, [100])))));
      AssertEquals('an allowed author is dispatched', 1, Bot.Dispatched);
      AssertEquals('an allowed author is logged', 1, StatLines);
    finally
      StatLog.Free;
    end;
  finally
    Bot.Free;
  end;
end;

procedure TTestSenderTypes.UpdateLoggerSurvivesSimpleUser;
const
  SimpleUserJSON='{"update_type":"message_created","timestamp":1700000000000,' +
    '"message":{"sender":{"user_id":100,"is_bot":false,"first_name":"Bob"},' +
    '"recipient":{"chat_id":42,"chat_type":"dialog"},' +
    '"timestamp":1700000000000,' +
    '"body":{"mid":"mid.2","seq":2,"text":"Hi"}}}';
var
  Bot: TTestGateBot;
  StatLog: TMaxStatLog;

  function StatLines: Integer;
  var
    S: TStringList;
  begin
    S:=TStringList.Create;
    try
      if FileExists(StatLog.FileName) then
        S.LoadFromFile(StatLog.FileName);
      Result:=S.Count;
    finally
      S.Free;
    end;
  end;

begin
  Bot:=TTestGateBot.Create(EmptyStr);
  try
    Bot.OnAnyUpdate:=@Bot.CountDispatch;
    StatLog:=TMaxStatLog.Create(nil);
    try
      StatLog.Directory:=IncludeTrailingPathDelimiter(GetTempDir);
      StatLog.FilePrefix:='~fpmaxgatetest';
      StatLog.Resume;
      DeleteFile(StatLog.FileName);
      Bot.UpdateLogger:=StatLog;
      Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(SimpleUserJSON))));
      Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(SimpleUserJSON))));
      AssertEquals('both updates of a simple user are dispatched', 2, Bot.Dispatched);
      AssertTrue('UpdateLogger survives the updates of a simple user',
        Bot.UpdateLogger<>nil);
      AssertEquals('UpdateLogger received both updates', 2, StatLines);
      // the admins are dispatched, but stay out of the statistics
      Bot.AddAdminUser(100);
      Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(SimpleUserJSON))));
      AssertEquals('an admin is dispatched too', 3, Bot.Dispatched);
      AssertEquals('an admin is not logged', 2, StatLines);
    finally
      StatLog.Free;
    end;
  finally
    Bot.Free;
  end;
end;

{ TTestSenderTypes mock broker swap }

procedure TTestSenderTypes.InstallMock;
begin
  // swap the registered broker for the mock; the suites run in one process,
  // so the finally of every mock test must call UninstallMock
  FSavedClientClass:=TBaseHTTPClient.GetClientClass;
  TBaseHTTPClient.UnregisterClientClass;
  TMockHTTPClient.RegisterClientClass;
end;

procedure TTestSenderTypes.UninstallMock;
begin
  // the canned state is class-level: left alone it survives the test and
  // leaks into the next one (order-dependent failure for any test that skips
  // Serve) - clear it before the broker registration is restored
  TMockHTTPClient.ResetState;
  TBaseHTTPClient.UnregisterClientClass;
  if Assigned(FSavedClientClass) then
    FSavedClientClass.RegisterClientClass;
end;

procedure TTestSenderTypes.ApiCallTransportFailureContract;
var
  Bot: TMaxSender;
begin
  // td-030: a transport failure must not escape as an exception - the
  // Boolean contract folds it into False with the synthetic 'transport'
  // code and the exception class in the message
  InstallMock;
  try
    TMockHTTPClient.FailWith:=ESocketError;
    Bot:=TMaxSender.Create('test-token');
    try
      // a set SSLCAFile passes the trust resolution without file access
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertFalse('a transport failure returns False, no raise', Bot.GetMe);
      AssertEquals('the synthetic code does not collide with API codes',
        'transport', Bot.LastErrorCode);
      AssertTrue('the message names the exception class',
        Pos('ESocketError', Bot.LastErrorMsg)>0);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.ApiCallNonJSONFillsLastError;
var
  Bot: TMaxSender;
begin
  // td-039: a 2xx body that fails to parse is not a success, and the cause
  // must reach the contract fields, not only the log
  InstallMock;
  try
    TMockHTTPClient.Serve('<html>gateway garbage</html>', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertFalse('a 2xx non-JSON body is not a success', Bot.GetMe);
      AssertTrue('LastErrorMsg is filled (td-039)', Bot.LastErrorMsg<>'');
      AssertTrue('the message says the body is not JSON',
        Pos('response is not JSON', Bot.LastErrorMsg)>0);
      AssertEquals('a parse failure has no API code', '', Bot.LastErrorCode);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.GetChatParsesChatCard;
const
  ChatJSON='{"chat_id":123,"type":"channel","status":"active",' +
    '"title":"Test channel","description":"d","is_public":true,' +
    '"participants_count":7}';
var
  Bot: TMaxSender;
begin
  // td-031: GET /chats/{chat_id} wrapped, the card parsed into TMaxChatObj
  InstallMock;
  try
    TMockHTTPClient.Serve(ChatJSON, 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertTrue('GetChat returns True on a chat card', Bot.GetChat(123));
      AssertTrue('the request goes to /chats/{chat_id}',
        Pos('/chats/123', TMockHTTPClient.LastURL)>0);
      AssertNotNull('the parsed chat is exposed', Bot.Chat);
      AssertEquals(123, Bot.Chat.ChatId);
      AssertEquals('Test channel', Bot.Chat.Title);
      AssertEquals(Ord(ctChannel), Ord(Bot.Chat.ChatType));
      AssertEquals(Ord(csActive), Ord(Bot.Chat.ChatStatus));
      AssertEquals(7, Bot.Chat.ParticipantsCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.SetWebhookSendsSecret;
var
  Bot: TMaxSender;
begin
  // td-041: the optional secret travels in the POST /subscriptions JSON body
  InstallMock;
  try
    TMockHTTPClient.Serve('{"success":true}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertTrue('SetWebhook with a secret succeeds',
        Bot.SetWebhook('https://example.com/hook', 'top-secret-1'));
      // AsJSON formats with spaces around ':' - match by key and value
      AssertTrue('the secret travels in the subscription body',
        (Pos('"secret"', TMockHTTPClient.LastRequestBody)>0)
        and (Pos('top-secret-1', TMockHTTPClient.LastRequestBody)>0));
      AssertTrue('the URL is still in the body',
        Pos('https://example.com/hook', TMockHTTPClient.LastRequestBody)>0);
      // the empty parameter keeps the old body shape (back compatibility)
      AssertTrue('SetWebhook without a secret succeeds',
        Bot.SetWebhook('https://example.com/hook'));
      AssertTrue('no secret key in the body when the parameter is empty',
        Pos('"secret"', TMockHTTPClient.LastRequestBody)=0);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.KeepAliveReusesClientAcrossCalls;
var
  Bot: TMaxSender;
begin
  // td-032: consecutive calls reuse one pooled client - the throttle hits new
  // connections, so a series must not build one
  InstallMock;
  try
    TMockHTTPClient.Serve('{"name":"bot"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertTrue('the first GetMe succeeds', Bot.GetMe);
      AssertTrue('the first call reaches /me', Pos('/me', TMockHTTPClient.LastURL)>0);
      AssertTrue('the second GetMe succeeds', Bot.GetMe);
      AssertTrue('the second call reaches /me', Pos('/me', TMockHTTPClient.LastURL)>0);
      AssertEquals('one client serves the whole series', 1,
        TMockHTTPClient.InstanceCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.TransportFailureReplacesPooledClient;
var
  Bot: TMaxSender;
begin
  // td-032: after a transport failure the pooled client must not survive -
  // its connection state is not to be trusted, the next call starts fresh
  InstallMock;
  try
    TMockHTTPClient.FailWith:=ESocketError;
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertFalse('the failed call returns False', Bot.GetMe);
      AssertEquals('the failure is folded into the transport code',
        'transport', Bot.LastErrorCode);
      TMockHTTPClient.Serve('{"name":"bot"}', 200);
      AssertTrue('the next call succeeds without a new sender', Bot.GetMe);
      AssertEquals('the failed client was replaced', 2,
        TMockHTTPClient.InstanceCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.ApiErrorKeepsPooledClient;
var
  Bot: TMaxSender;
begin
  // td-032: an API error (non-2xx) is not a transport failure - the pooled
  // client must survive it, only a broken connection costs a reconnect
  InstallMock;
  try
    TMockHTTPClient.Serve('{"code":"verify.token","message":"bad token"}', 400);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertFalse('a 400 answer is False', Bot.GetMe);
      AssertEquals('the API error code reaches the contract',
        'verify.token', Bot.LastErrorCode);
      TMockHTTPClient.Serve('{"name":"bot"}', 200);
      AssertTrue('the next call succeeds', Bot.GetMe);
      AssertEquals('the API error kept the pooled client', 1,
        TMockHTTPClient.InstanceCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.ConfigChangeReplacesPooledClient;
var
  Bot: TMaxSender;
begin
  // td-032: a client built from the old configuration (here: the old token in
  // the Authorization header) must not serve requests after the change
  InstallMock;
  try
    TMockHTTPClient.Serve('{"name":"bot"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertTrue('the first GetMe succeeds', Bot.GetMe);
      Bot.Token:='other-token';
      AssertTrue('the next GetMe after the token change succeeds', Bot.GetMe);
      AssertEquals('the config change replaced the client', 2,
        TMockHTTPClient.InstanceCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.ContentTypeStrippedForBodylessRequests;
var
  Bot: TMaxSender;
begin
  // td-032: Content-Type belongs to the request that carries a body only -
  // on a reused client a leftover would ride every following bodyless request
  InstallMock;
  try
    TMockHTTPClient.Serve('{"message":{}}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      AssertTrue('SendMessage (a bodied POST) succeeds', Bot.SendMessage(1, 'hi'));
      TMockHTTPClient.Serve('{"name":"bot"}', 200);
      AssertTrue('the following GetMe succeeds', Bot.GetMe);
      AssertTrue('the GET still carries the Authorization header',
        Pos('Authorization', TMockHTTPClient.LastRequestHeaders)>0);
      AssertTrue('the GET carries no Content-Type from the POST',
        Pos('Content-Type', TMockHTTPClient.LastRequestHeaders)=0);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.ReconfiguringLogHandler(ASender: TObject;
  {%H-}AEventType: TEventType; const {%H-}AMsg: String);
begin
  // The exact reaction the configuration error texts suggest ("check the
  // configuration", "set SSLCAFile"): a handler that sets a property of the
  // same sender. Under the one-way serialization the callback ran with
  // FClientPoolCS held and the locked setter deadlocked the calling thread
  FHandlerRan:=True;
  TMaxSender(ASender).SSLCAFile:='/nonexistent/reacted.pem';
end;

procedure TTestSenderTypes.LogCallbackMayReconfigureSender;
var
  Bot: TMaxSender;
  lRaised: Boolean;
begin
  // The pool's grow path validates the token and resolves the trust anchor
  // OUTSIDE FClientPoolCS: the validation reports through OnLogMessage, so a
  // handler reconfiguring the sender (a locked setter, another Acquire) must
  // not self-deadlock on the non-reentrant section. A token with a line
  // break forces the validation error deterministically and offline; the
  // raise leaves the pool untouched and escapes the call as EMaxConfig (a
  // configuration error is an exception by contract, td-013 - the explicit
  // class pins it, a wrong class would leave the test red)
  InstallMock;
  try
    TMockHTTPClient.Serve('{"name":"bot"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      FHandlerRan:=False;
      Bot.OnLogMessage:=@ReconfiguringLogHandler;
      Bot.Token:='broken'#10'token';
      lRaised:=False;
      try
        Bot.GetMe;
      except
        on EMaxConfig do
          lRaised:=True;
      end;
      AssertTrue('the invalid token raises EMaxConfig out of the call', lRaised);
      AssertTrue('the log callback ran before the raise', FHandlerRan);
      AssertEquals('no client is built from a broken configuration', 0,
        TMockHTTPClient.InstanceCount);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.GetUpdatesWindowOverridesSmallTimeout;
var
  Bot: TMaxSender;
begin
  // td-018: the long-polling window travels as the per-request parameter -
  // max(configured Timeout, window + 3 s) reaches the transport, and the
  // Timeout property survives the call unchanged (no widen/restore mutation)
  InstallMock;
  try
    TMockHTTPClient.Serve('{"updates":[],"marker":"m"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      Bot.Timeout:=5000;
      AssertTrue('GetUpdates succeeds against the mock', Bot.GetUpdates(EmptyStr, 0, 30));
      AssertEquals('the transport got the long-poll window, not the small Timeout',
        33000, TMockHTTPClient.LastIOTimeoutMs);
      AssertEquals('Timeout is not mutated by the poll', 5000, Bot.Timeout);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.GetUpdatesNeverShortensLargeTimeout;
var
  Bot: TMaxSender;
begin
  // td-018 keeps the max() semantics of the old widen: a configured Timeout
  // larger than the polling window must never be shortened for the poll
  InstallMock;
  try
    TMockHTTPClient.Serve('{"updates":[],"marker":"m"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      Bot.Timeout:=60000;
      AssertTrue('GetUpdates succeeds against the mock', Bot.GetUpdates(EmptyStr, 0, 30));
      AssertEquals('the window never shortens the configured Timeout',
        60000, TMockHTTPClient.LastIOTimeoutMs);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.NonPollCallUsesConfiguredTimeout;
var
  Bot: TMaxSender;
begin
  // td-018: without the window parameter (ATimeoutMs=0, the default every
  // non-polling wrapper goes through) the configured Timeout applies as is
  InstallMock;
  try
    TMockHTTPClient.Serve('{"name":"bot"}', 200);
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      Bot.Timeout:=60000;
      AssertTrue('GetMe succeeds against the mock', Bot.GetMe);
      AssertEquals('a non-polling call uses the configured Timeout',
        60000, TMockHTTPClient.LastIOTimeoutMs);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.InvalidTokenRaisesEMaxConfig;
var
  Bot: TMaxSender;
  lRaised: Boolean;
begin
  // td-013: the configuration error class is public - hosts catch EMaxConfig
  // before the generic Exception handler to stop visibly instead of retrying.
  // The broken-token path is forced deterministically and offline
  InstallMock;
  try
    TMockHTTPClient.Serve('{"name":"bot"}', 200);
    Bot:=TMaxSender.Create('broken'#10'token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      lRaised:=False;
      try
        Bot.GetMe;
      except
        on EMaxConfig do
          lRaised:=True;
      end;
      AssertTrue('an invalid token raises exactly EMaxConfig', lRaised);
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.RaisingLogHandler(ASender: TObject;
  AEventType: TEventType; const AMsg: String);
begin
  raise Exception.Create('broken host log handler: '+AMsg);
end;

procedure TTestSenderTypes.UploadConfigErrorRaisesEMaxConfig;
var
  Bot: TMaxSender;
  Data: TStringStream;
  lRaised: Boolean;
begin
  // td-073: the public boundary of UploadFile - construction and
  // configuration failures raise (EMaxConfig), transport and validation
  // failures fold into EmptyStr. The broken-token path is forced offline
  // through the mock broker (the precedent: InvalidTokenRaisesEMaxConfig);
  // the transport branch of the same boundary stays pinned by
  // ApiCallTransportFailureContract. The log handler raises (td-076): the
  // configuration error must still come out as EMaxConfig, not as the
  // callback's exception
  InstallMock;
  try
    TMockHTTPClient.Serve('{"url":"https://up.example.com/one-shot","token":"t1"}', 200);
    Bot:=TMaxSender.Create('broken'#10'token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      Bot.OnLogMessage:=@RaisingLogHandler;
      Data:=TStringStream.Create('upload payload');
      try
        lRaised:=False;
        try
          Bot.UploadFile(uptFile, Data, 'report.txt');
        except
          on EMaxConfig do
            lRaised:=True;
        end;
        AssertTrue('a configuration error raises exactly EMaxConfig out of UploadFile',
          lRaised);
      finally
        Data.Free;
      end;
    finally
      Bot.Free;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.UploadRaisingLogCallbackKeepsEmptyStr;
var
  Bot, FailBot: TMaxSender;
  Data: TStringStream;
begin
  // td-072/td-076: every diagnostic path of UploadFile reports through the
  // guarded wrapper - a throwing host log handler is absorbed and the
  // EmptyStr contract survives it (the step 2 transport failure of the same
  // contract is exercised by ApiCallTransportFailureContract, the
  // configuration raise by UploadConfigErrorRaisesEMaxConfig)
  InstallMock;
  try
    Bot:=TMaxSender.Create('test-token');
    try
      Bot.SSLCAFile:='/nonexistent/mock.pem';
      Bot.OnLogMessage:=@RaisingLogHandler;
      Data:=TStringStream.Create('upload payload');
      try
        // "no upload URL in response" (td-072)
        TMockHTTPClient.Serve('{"token":"t1"}', 200);
        AssertEquals('a missing upload URL folds into EmptyStr',
          EmptyStr, Bot.UploadFile(uptFile, Data, 'report.txt'));
        // "the upload URL is not https" (td-072; the gate now also rejects
        // control characters and spaces - td-019)
        TMockHTTPClient.Serve('{"url":"http://up.example.com/one-shot"}', 200);
        AssertEquals('a non-https upload URL folds into EmptyStr',
          EmptyStr, Bot.UploadFile(uptFile, Data, 'report.txt'));
        // an upload body that is not JSON (td-072: the wrapped parse branch;
        // an empty body takes the same road into the "no token" fold)
        TMockHTTPClient.Serve('{"url":"https://up.example.com/one-shot"}', 200);
        AssertEquals('a not-JSON upload body folds into EmptyStr',
          EmptyStr, Bot.UploadFile(uptFile, Data, 'report.txt'));
      finally
        Data.Free;
      end;
    finally
      Bot.Free;
    end;
    // td-073: the step 2 transport failure - the first step must succeed,
    // so the broker is swapped for a stub whose StreamFormPost raises while
    // the inherited verbs serve the canned step 1 answer; UninstallMock
    // below restores the registration
    TBaseHTTPClient.UnregisterClientClass;
    TUploadFailHTTPClient.RegisterClientClass;
    try
      TMockHTTPClient.Serve('{"url":"https://up.example.com/one-shot"}', 200);
      FailBot:=TMaxSender.Create('test-token');
      try
        FailBot.SSLCAFile:='/nonexistent/mock.pem';
        FailBot.OnLogMessage:=@RaisingLogHandler;
        Data:=TStringStream.Create('upload payload');
        try
          AssertEquals('a step 2 transport failure folds into EmptyStr',
            EmptyStr, FailBot.UploadFile(uptFile, Data, 'report.txt'));
        finally
          Data.Free;
        end;
      finally
        FailBot.Free;
      end;
    finally
      TMockHTTPClient.ResetState;
    end;
  finally
    UninstallMock;
  end;
end;

procedure TTestSenderTypes.CommandHandler({%H-}ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
begin
  FLastCommand:=ACommand;
  FLastText:=AMessage.Body.Text;
end;

procedure TTestSenderTypes.RunCommandJSON(const ARecipientJSON, AText,
  AOwnUsername: String);
var
  Bot: TMaxSender;
  Body, Json, Sender: TJSONObject;
  Msg: TMaxMessageObj;
  Handlers: TCommandHandlersMap;
begin
  // td-017: ProcessCommands is public, so the tests drive it directly (no
  // network, no mock): the handlers map is built locally the same way the
  // production FCommandHandlers would hold them
  Handlers:=TCommandHandlersMap.Create;
  try
    Handlers.insert('start', @CommandHandler);
    Handlers.insert('vote', @CommandHandler);
    Handlers.insert('stat', @CommandHandler);
    Handlers.insert('upper', @CommandHandler);
    Bot:=TMaxSender.Create('test-token');
    try
      if AOwnUsername<>'' then
        Bot.OwnUsername:=AOwnUsername;
      { a minimal offline message: ProcessCommands reads body.text and, since
        the mention filter, recipient.chat_type - the same shape the live
        delivery carries ({"recipient":{"chat_type":"dialog","chat_id":...}}).
        The object is built through Add, not a Format template: ANY text must
        reach ProcessCommands verbatim ('%' breaks Format, '"' and '\' break
        the JSON literal) }
      Sender:=TJSONObject.Create;
      Sender.Add('user_id', 99);
      Body:=TJSONObject.Create;
      Body.Add('mid', 'mid.1');
      Body.Add('seq', 1);
      Body.Add('text', AText);
      Json:=TJSONObject.Create;
      Json.Add('sender', Sender);
      Json.Add('recipient', TJSONObject(GetJSON('{'+ARecipientJSON+'}')));
      Json.Add('body', Body);
      Msg:=TMaxMessageObj.Create(Json);
      try
        FLastCommand:='';
        FLastText:='';
        Bot.ProcessCommands(Msg, Handlers);
      finally
        Msg.Free;
      end;
    finally
      Bot.Free;
    end;
  finally
    Handlers.Free;
  end;
end;

procedure TTestSenderTypes.RunProcessCommands(const AText: String);
begin
  // td-017: no chat_type in the recipient -> ctUnknown -> the same
  // permissive (dialog-like) grammar an unknown chat gets
  RunCommandJSON('"chat_id":42', AText, '');
end;

procedure TTestSenderTypes.CommandFiresOnBareSlash;
begin
  // td-017: the baseline - a plain /start still reaches its handler
  RunProcessCommands('/start');
  AssertEquals('the /start handler fires', 'start', FLastCommand);
end;

procedure TTestSenderTypes.CommandAfterBotMentionFires;
begin
  // td-017: the SDK grammar allows a @bot mention before the command
  // (group chats) - the mention is skipped, the command matches
  RunProcessCommands('@mybot /start');
  AssertEquals('the command after the @mention fires', 'start', FLastCommand);
end;

procedure TTestSenderTypes.BareMentionDoesNotFire;
begin
  // td-017: a bare @mention carries no command - neither fires nor crashes
  RunProcessCommands('@mybot');
  AssertEquals('a bare @mention fires no handler', '', FLastCommand);
end;

procedure TTestSenderTypes.ColonParamsCutFromCommand;
begin
  // td-017: ':params' end the command name; the handler still receives the
  // FULL original text through the message (the params are its job)
  RunProcessCommands('/vote:yes,no');
  AssertEquals('the command name stops at the colon', 'vote', FLastCommand);
  AssertEquals('the handler sees the full message text', '/vote:yes,no',
    FLastText);
end;

procedure TTestSenderTypes.MentionWithColonParamsFires;
begin
  // td-017: a mention and ':params' in one message - both grammar parts
  RunProcessCommands('@other /stat:full');
  AssertEquals('the mention is skipped and the command stops at the colon',
    'stat', FLastCommand);
end;

procedure TTestSenderTypes.DoubleColonDoesNotFire;
begin
  // td-017: the SDK params group holds no ':' itself - '/vote:yes:no'
  // matches the SDK regex only as cmd='/vote:yes' (a lookup miss), so it
  // must not degrade into 'vote'; a single ':' group still fires
  RunProcessCommands('/vote:yes');
  AssertEquals('one colon params group fires the command', 'vote',
    FLastCommand);
  RunProcessCommands('/vote:yes:no');
  AssertEquals('a second colon inside the command token fires no handler',
    '', FLastCommand);
  RunProcessCommands('/vote:yes:no more');
  AssertEquals('a second colon before a space fires no handler too', '',
    FLastCommand);
  RunProcessCommands('/vote:yes tail:more');
  AssertEquals('a colon in the free text after the command keeps firing',
    'vote', FLastCommand);
end;

procedure TTestSenderTypes.PlainTextDoesNotFire;
begin
  // td-017: the text must START with '/' - 'sup' ends with 'up',
  // 'sstart' contains 'start', '?up:1' carries the ':' params shape, and
  // none of them may extract a registered command name
  RunProcessCommands('hello');
  AssertEquals('plain text fires no handler', '', FLastCommand);
  RunProcessCommands('sup');
  AssertEquals('text ending in a command name fires no handler', '',
    FLastCommand);
  RunProcessCommands('sstart');
  AssertEquals('text containing a command name fires no handler', '',
    FLastCommand);
  RunProcessCommands('?up:1');
  AssertEquals('text with a colon-params shape fires no handler', '',
    FLastCommand);
  RunProcessCommands('@mybot sup');
  AssertEquals('the mention tail must also start with a slash', '',
    FLastCommand);
end;

procedure TTestSenderTypes.CommandNameLowercased;
begin
  // td-017: the lookup stays case-insensitive (the name is lowercased
  // before the map hit)
  RunProcessCommands('/UPPER');
  AssertEquals('the command name is lowercased before the lookup', 'upper',
    FLastCommand);
end;

procedure TTestSenderTypes.GroupMentionForOwnBotFires;
begin
  // td-017: in a group ('chat' is the wire chat_type of a group chat) the
  // command addressed to OUR bot passes the filter and fires
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@qNBt5oW_bot /start',
    'qNBt5oW_bot');
  AssertEquals('the own-bot mention fires the command in a group', 'start',
    FLastCommand);
end;

procedure TTestSenderTypes.GroupForeignMentionSkipped;
begin
  // td-017: a group command addressed to another bot is none of our
  // business - with OwnUsername known the message is dropped whole
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@other /start',
    'qNBt5oW_bot');
  AssertEquals('a foreign bot mention fires no handler', '', FLastCommand);
end;

procedure TTestSenderTypes.NoOwnUsernameAcceptsAnyMention;
begin
  // td-017: an empty OwnUsername keeps the permissive pre-filter grammar -
  // any mention is accepted (backward compatibility)
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@other /start', '');
  AssertEquals('an unknown own username accepts a foreign mention', 'start',
    FLastCommand);
end;

procedure TTestSenderTypes.DialogHasNoMentionFilter;
begin
  // td-017: dialogs carry no mentions - the plain grammar stays, even with
  // OwnUsername set
  RunCommandJSON('"chat_id":42,"chat_type":"dialog"', '/start',
    'qNBt5oW_bot');
  AssertEquals('a dialog /start fires without any mention', 'start',
    FLastCommand);
end;

procedure TTestSenderTypes.GroupBareCommandSkipped;
begin
  // td-017: a group message without a mention addresses nobody - with
  // OwnUsername known it must not fire (only '@ourbot /cmd' does)
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '/start',
    'qNBt5oW_bot');
  AssertEquals('a group command without a mention fires no handler', '',
    FLastCommand);
end;

procedure TTestSenderTypes.ChannelMentionForOwnBotFires;
begin
  // td-017: channels follow the same group filter - the own-bot mention
  // passes
  RunCommandJSON('"chat_id":42,"chat_type":"channel"', '@qNBt5oW_bot /start',
    'qNBt5oW_bot');
  AssertEquals('the own-bot mention fires the command in a channel', 'start',
    FLastCommand);
end;

procedure TTestSenderTypes.GroupMentionCaseInsensitiveFires;
begin
  // td-017: the mention match ignores the case - the name reaches the text
  // in whatever case the author or the client renderer typed
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@QNBt5OW_BOT /start',
    'qNBt5oW_bot');
  AssertEquals('a mention differing only in case fires the command', 'start',
    FLastCommand);
end;

procedure TTestSenderTypes.OwnUsernameLeadingAtNormalized;
var
  Bot: TMaxSender;
begin
  // td-017: the setter strips ALL leading '@' - a value pasted as a full
  // mention must not come back as '@bot' (it would compare as '@@bot' and
  // match nothing); '@'-only values normalize to empty (the permissive path)
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@qNBt5oW_bot /start',
    '@qNBt5oW_bot');
  AssertEquals('a leading @ in OwnUsername is normalized away', 'start',
    FLastCommand);
  // the double-@ pin: on the old single-if setter the stored value came back
  // as '@qNBt5oW_bot', the filter compared '@@qNBt5oW_bot' against the token
  // and the command silently dropped
  RunCommandJSON('"chat_id":42,"chat_type":"chat"', '@qNBt5oW_bot /start',
    '@@qNBt5oW_bot');
  AssertEquals('a value pasted as a full mention fires on the real mention',
    'start', FLastCommand);
  { direct setter asserts: RunCommandJSON skips the assignment when the value
    is empty, so the '@'-only normalization is not expressible through it }
  Bot:=TMaxSender.Create('test-token');
  try
    Bot.OwnUsername:='@@@';
    AssertEquals('only @-characters normalize to empty (permissive)', '',
      Bot.OwnUsername);
    Bot.OwnUsername:='@';
    AssertEquals('a lone @ normalizes to empty', '', Bot.OwnUsername);
  finally
    Bot.Free;
  end;
end;

procedure TTestSenderTypes.UnknownChatTypeHasNoMentionFilter;
begin
  // td-017: a recipient without chat_type maps to ctUnknown - the
  // permissive dialog path, no filter even with OwnUsername set (worth
  // pinning: the RunProcessCommands helper passes no chat_type at all)
  RunCommandJSON('"chat_id":42', '@qNBt5oW_bot /start', 'qNBt5oW_bot');
  AssertEquals('an unknown chat type fires the mention without the filter',
    'start', FLastCommand);
end;

{ TTestMaxBot }

procedure TTestMaxBot.UserStatusRoundTrip;
const
  // one status per id: SetUserStatus keeps the first written status of an id
  // (a rewrite raises on the sorted map), the mapping itself is what is
  // tested here
  IDs: array [TUserStatus] of Int64=(7001001, 7001002, 7001003, 7001004);
var
  Bot: TTestGateMaxBot;
  St: TUserStatus;
begin
  Bot:=TTestGateMaxBot.Create(EmptyStr);
  try
    { SetUserStatus stores UserStatusChars[St] and GetUserStatus reads it
      back through AnsiCharToUserStatus: the round trip must be exact for
      every status }
    for St:=Low(TUserStatus) to High(TUserStatus) do
    begin
      Bot.UserStatus[IDs[St]]:=St;
      AssertEquals('UserStatus round trip fails', Ord(St),
        Ord(Bot.UserStatus[IDs[St]]));
    end;
    AssertTrue('usBanned must ban', Bot.IsBanned(IDs[usBanned]));
    // an absent id reads as usDefault and is not banned ('' -> '_')
    AssertFalse('usDefault must not ban', Bot.IsBanned(IDs[usDefault]));
    AssertFalse('an absent id must not ban', Bot.IsBanned(7001005));
  finally
    Bot.Free;
  end;
end;

procedure TTestMaxBot.BanGateDropsBannedCallback;
const
  // the message of message_callback is the original message with the inline
  // keyboard: its sender is the bot itself (1000), the presser is %d
  CallbackJSON='{"update_type":"message_callback","timestamp":1700000000000,' +
    '"message":{"sender":{"user_id":1000,"is_bot":true,"first_name":"TheBot"},' +
    '"recipient":{"user_id":%0:d,"chat_id":%0:d,"chat_type":"dialog"},' +
    '"body":{"mid":"mid.1","seq":1,"text":""}},' +
    '"callback":{"callback_id":"cbid1","payload":"stat today",'+
    '"user":{"user_id":%0:d,"is_bot":false,"first_name":"Alice"}}}';
var
  Bot: TTestGateMaxBot;
begin
  { The author of a callback is the user who pressed the button, not the
    sender of the message under the keyboard }
  with TMaxUpdateObj.Create(TJSONObject(GetJSON(Format(CallbackJSON, [99])))) do
    try
      AssertEquals('the presser is the author of the callback',
        99, AuthorId);
    finally
      Free;
    end;
  Bot:=TTestGateMaxBot.Create(EmptyStr);
  try
    Bot.OnAnyUpdate:=@Bot.CountDispatch;
    Bot.UserStatus[99]:=usBanned; // the public property writes the map
    AssertTrue('the ban must stick', Bot.IsBanned(99));
    // both updates are owned (and freed) by the bot after DeliverUpdate
    Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
      Format(CallbackJSON, [99])))));
    AssertEquals('a banned presser does not reach the callback dispatcher',
      0, Bot.CallbackReached);
    AssertEquals('a banned presser is not dispatched', 0, Bot.Dispatched);
    // the presser 100 is not in the status map: not a ban
    Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
      Format(CallbackJSON, [100])))));
    AssertEquals('an allowed presser reaches the callback dispatcher',
      1, Bot.CallbackReached);
    AssertEquals('an allowed presser is dispatched', 1, Bot.Dispatched);
  finally
    Bot.Free;
  end;
end;

procedure TTestMaxBot.BanGateDropsBannedMessage;
const
  MessageJSON='{"update_type":"message_created","timestamp":1700000000000,' +
    '"message":{"sender":{"user_id":%d,"is_bot":false,"first_name":"Alice"},' +
    '"recipient":{"chat_id":42,"chat_type":"dialog"},' +
    '"timestamp":1700000000000,' +
    '"body":{"mid":"mid.3","seq":3,"text":"Hello"}}}';
var
  Bot: TTestGateMaxBot;
begin
  Bot:=TTestGateMaxBot.Create(EmptyStr);
  try
    Bot.OnAnyUpdate:=@Bot.CountDispatch;
    SetUpBotStatLog(Bot);
    Bot.UserStatus[99]:=usBanned;
    // 'Hello' is not a command: the allowed path stays offline
    Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
      Format(MessageJSON, [99])))));
    AssertEquals('a banned author is not dispatched', 0, Bot.Dispatched);
    AssertEquals('a banned author writes no statistics',
      0, StatLinesOf(Bot.StatLogger));
    Bot.DeliverUpdate(TMaxUpdateObj.Create(TJSONObject(GetJSON(
      Format(MessageJSON, [100])))));
    AssertEquals('an allowed author is dispatched', 1, Bot.Dispatched);
    AssertEquals('an allowed author writes one statistics line',
      1, StatLinesOf(Bot.StatLogger));
  finally
    Bot.Free;
  end;
end;

procedure TTestMaxBot.AuthorIdChainPrecedence;
const
  // the schema has no top-level user_id on message_created: the combination
  // pins the precedence of the chain, not a real payload
  TopLevelJSON='{"update_type":"message_created","timestamp":1700000000000,' +
    '"user_id":7,' +
    '"message":{"sender":{"user_id":99,"is_bot":false,"first_name":"Alice"},' +
    '"recipient":{"chat_id":42,"chat_type":"dialog"},' +
    '"body":{"mid":"mid.4","seq":4,"text":"Hello"}}}';
  // no message.sender: the author lives in callback.user
  CallbackOnlyJSON='{"update_type":"message_callback","chat_id":42,' +
    '"message_id":"mid.5",' +
    '"callback":{"callback_id":"cb.2","payload":"x","user":{"user_id":88}},' +
    '"message":{"recipient":{"chat_id":42},"body":{"mid":"mid.6","seq":6,"text":"kb"}}}';
  // no user_id and no message: the author lives in user (bot_started)
  UserOnlyJSON='{"update_type":"bot_started","timestamp":1700000000000,' +
    '"user":{"user_id":77},"payload":"ref"}';

  procedure CheckAuthor(const AJSON: String; AExpected: Int64; const AMsg: String);
  begin
    with TMaxUpdateObj.Create(TJSONObject(GetJSON(AJSON))) do
      try
        AssertEquals(AMsg, AExpected, AuthorId);
      finally
        Free;
      end;
  end;

begin
  CheckAuthor(TopLevelJSON, 7, 'the top-level user_id wins');
  CheckAuthor(CallbackOnlyJSON, 88, 'callback.user.user_id is a fallback');
  CheckAuthor(UserOnlyJSON, 77, 'user.user_id is a fallback');
end;

procedure TTestMaxBot.StatFieldEscapeRoundTrip;
const
  // a display name crafted to shift the ';' columns of the stat CSV (td-016)
  Nasty='He said "hi"; ok';
var
  Rec: String;
begin
  AssertEquals('escape wraps the field and doubles the inner quotes',
    '"a;b""c"', EscapeStatField('a;b"c'));
  AssertEquals('a value with quotes and semicolons survives the round trip',
    Nasty, UnescapeStatField(EscapeStatField(Nasty)));
  AssertEquals('a plain value survives the round trip unchanged', 'Alice',
    UnescapeStatField(EscapeStatField('Alice')));
  // a multiline value would inject a raw CR/LF into the one-line record
  // (TMaxStatLog writes a record per LineEnding-terminated line and the
  // reader loads it line by line) - the escape neutralizes the control chars
  // into spaces, so the round trip comes back as a single line (td-016)
  AssertEquals('escape neutralizes the CR/LF control chars', '"a b c"',
    EscapeStatField('a'#13'b'#10'c'));
  AssertEquals('a multiline value survives the round trip as one line',
    'a b c', UnescapeStatField(EscapeStatField('a'#13'b'#10'c')));
  // the full record shape: timestamp + 7 fields, the crafted name and text
  // must keep the line at 8 columns and come back unescaped
  Rec:='2026-10-27 10:00:00; 42; '+EscapeStatField('@ali;ce')+'; '+
    EscapeStatField('Ali')+'; '+EscapeStatField(Nasty)+'; -; message_created; '+
    EscapeStatField(Nasty);
  AssertTrue('the crafted record still parses as 8 columns',
    Pos('Stat line parser error', FormatStatRec(Rec))=0);
  AssertTrue('the crafted name comes back unescaped',
    Pos(Nasty, FormatStatRec(Rec))>0);
  // the regression shape itself: a multiline message text used to put a raw
  // #10 inside the record, and the line-per-record file split it in half
  Rec:='2026-10-27 10:00:00; 42; '+EscapeStatField('@ali')+'; '+
    EscapeStatField('Ali')+'; -; -; message_created; '+
    EscapeStatField('first'#13#10'second'#10'third');
  AssertTrue('the escaped field carries no raw CR/LF into the record',
    (Pos(#13, Rec)=0) and (Pos(#10, Rec)=0));
  AssertTrue('the multiline record still parses as 8 columns',
    Pos('Stat line parser error', FormatStatRec(Rec))=0);
end;

procedure TTestMaxBot.KeyboardWireMatchesCore;
var
  Rows, Row: TJSONArray;
  BotArr, CoreArr: TJSONArray;
begin
  // td-071: the bot_ex helpers delegate the button/attachment assembly to
  // the core MakeInlineKeyboardAttachment, so both layers ship the same wire
  // form - pinned here byte-for-byte through JSONCompact. First the
  // documented misuse divergence: a dangling half-pair is silently skipped
  // where the core itself raises (the stub filter in front of the delegated
  // assembly must survive)
  Row:=MaxKeyboardRow;
  try
    MaxCallbackButtons(Row, ['Yes', 'y', 'No', 'n']);
    MaxCallbackButtons(Row, ['Dangling']);
    AssertEquals('the dangling half-pair is silently skipped, not raised',
      2, Row.Count);
  finally
    Row.Free;
  end;
  // the whole bot_ex chain (MaxCallbackButtons -> MaxCallbackButton ->
  // MaxKeyboardRow/MaxKeyboardAttachments -> MaxInlineKeyboardAttachment)
  // against a direct core call on the same pairs
  Rows:=MaxKeyboardRow;
  Row:=MaxKeyboardRow;
  MaxCallbackButtons(Row, ['Yes', 'y', 'No', 'n']);
  Rows.Add(Row); // MaxInlineKeyboardAttachment takes the array OF rows
  BotArr:=MaxKeyboardAttachments(Rows);
  try
    CoreArr:=MakeInlineKeyboardAttachment(['Yes', 'y', 'No', 'n']);
    try
      AssertEquals('one-row keyboard: bot_ex == core byte for byte',
        JSONCompact(CoreArr), JSONCompact(BotArr));
    finally
      CoreArr.Free;
    end;
  finally
    BotArr.Free;
  end;
  // multi-row stays row-based (the core builds a single row only): the rows
  // are appended into the buttons slot of the core-built shell
  Rows:=MaxKeyboardRow;
  Row:=MaxKeyboardRow;
  MaxCallbackButton(Row, 'Yes', 'y');
  MaxCallbackButton(Row, 'No', 'n');
  Rows.Add(Row);
  Row:=MaxKeyboardRow;
  MaxCallbackButton(Row, 'Maybe', 'm');
  Rows.Add(Row);
  BotArr:=MaxKeyboardAttachments(Rows);
  try
    AssertEquals('multi-row keyboard keeps the row-based 2D form',
      '[{"type":"inline_keyboard","payload":{"buttons":[' +
      '[{"type":"callback","text":"Yes","payload":"y"},' +
      '{"type":"callback","text":"No","payload":"n"}],' +
      '[{"type":"callback","text":"Maybe","payload":"m"}]]}}]',
      JSONCompact(BotArr));
  finally
    BotArr.Free;
  end;
  // the link button is the one hand-built helper left: the core serves
  // callback pairs only, so its assembly has no delegate - the wire form
  // (type, text, url in this order) is pinned by the literal below,
  // byte for byte - an edit or a typo would otherwise desync it silently
  Rows:=MaxKeyboardRow;
  Row:=MaxKeyboardRow;
  MaxLinkButton(Row, 'Docs', 'https://example.com/docs');
  Rows.Add(Row);
  BotArr:=MaxKeyboardAttachments(Rows);
  try
    AssertEquals('the hand-built link button keeps the type/text/url wire form',
      '[{"type":"inline_keyboard","payload":{"buttons":[' +
      '[{"type":"link","text":"Docs","url":"https://example.com/docs"}]]}}]',
      JSONCompact(BotArr));
  finally
    BotArr.Free;
  end;
end;

{ TTestTLSTrust }

procedure TTestTLSTrust.SetUp;
begin
  inherited SetUp;
  // the fixtures go up through the harness helper mkstemp-style (td-100):
  // the shared temp dir is not trusted, the fresh GUID suffix keeps the
  // names unpredictable and the exclusive open never follows a planted
  // symlink - the pid-suffixed SaveToFile pair these fields replaced argued
  // the opposite (td-107)
  TTestTrustBot.FixShipped:=MakePrivateTempFile(
    IncludeTrailingPathDelimiter(GetTempDir)+'fpmax-test-shipped-ca-', '.pem',
    FixtureShippedPEM);
  TTestTrustBot.FixSystem:=MakePrivateTempFile(
    IncludeTrailingPathDelimiter(GetTempDir)+'fpmax-test-system-ca-', '.pem',
    FixtureSystemPEM);
  // the suite runs in one process: every test starts with a clean cache, so
  // the test order must not matter
  TTestTrustBot.DropMergedCACache;
end;

procedure TTestTLSTrust.TearDown;
begin
  DeleteFile(TTestTrustBot.FixShipped);
  DeleteFile(TTestTrustBot.FixSystem);
  // symmetric to SetUp: the cache holds the path of a bundle built from the
  // fixtures above, the network suites registered after this one must never
  // be served that path
  TTestTrustBot.DropMergedCACache;
  inherited TearDown;
end;

procedure TTestTLSTrust.WriteFixture(const APath, AContent: String);
var
  S: TStringStream;
begin
  // TStringStream keeps the content byte-exact (a TStringList.SaveToFile
  // appends a line break of its own)
  S:=TStringStream.Create(AContent);
  try
    S.SaveToFile(APath);
  finally
    S.Free;
  end;
end;

procedure TTestTLSTrust.ResolveAnchorWithoutSources;
var
  Bot: TTestTrustBot;
begin
  Bot:=TTestTrustBot.Create(EmptyStr);
  try
    Bot.ResolveAnchor; // must raise: verification on, no source exists
  finally
    Bot.Free;
  end;
end;

procedure TTestTLSTrust.ExplicitCAFileIsUsedAsIs;
var
  Bot: TTestTrustBot;
begin
  Bot:=TTestTrustBot.Create(EmptyStr);
  try
    Bot.SSLVerifyCert:=True;
    Bot.SSLCAFile:='/fixture/explicit.pem';
    // a set SSLCAFile is the ONLY trust anchor, even a non-existing path
    AssertEquals('a set SSLCAFile passes through as is',
      '/fixture/explicit.pem', Bot.ResolveAnchor);
  finally
    Bot.Free;
  end;
end;

procedure TTestTLSTrust.DefaultResolutionMergesBothSources;
var
  Merged: String;
begin
  Merged:=TTestTrustBot.DefaultResolution;
  AssertTrue('both sources merge into a new bundle file',
    (Merged<>TTestTrustBot.FixShipped) and (Merged<>TTestTrustBot.FixSystem));
  AssertTrue('the merged bundle file should exist', FileExists(Merged));
  AssertEquals('the merged bundle holds both fixtures byte-exact',
    FixtureShippedPEM+FixtureSystemPEM, FileBytes(Merged));
end;

procedure TTestTLSTrust.MergeInsertsMissingNewline;
var
  ShippedNoEOL, Merged: String;
begin
  // rewrite the shipped fixture without the trailing line break
  ShippedNoEOL:=Copy(FixtureShippedPEM, 1, Length(FixtureShippedPEM)-1);
  WriteFixture(TTestTrustBot.FixShipped, ShippedNoEOL);
  Merged:=TTestTrustBot.DefaultResolution;
  AssertTrue('the merged bundle file should exist', FileExists(Merged));
  AssertEquals('exactly one line break is inserted between the sources',
    ShippedNoEOL+#10+FixtureSystemPEM, FileBytes(Merged));
end;

procedure TTestTLSTrust.SingleSourceShippedPassthrough;
begin
  TTestTrustBot.FixSystem:=EmptyStr;
  // the passthrough of the path itself proves that no temp file is built
  AssertEquals('a single shipped source passes through as is',
    TTestTrustBot.FixShipped, TTestTrustBot.DefaultResolution);
end;

procedure TTestTLSTrust.SingleSourceSystemPassthrough;
begin
  TTestTrustBot.FixShipped:=EmptyStr;
  AssertEquals('a single system source passes through as is',
    TTestTrustBot.FixSystem, TTestTrustBot.DefaultResolution);
end;

procedure TTestTLSTrust.NoSourcesResolverIsEmpty;
begin
  TTestTrustBot.FixShipped:=EmptyStr;
  TTestTrustBot.FixSystem:=EmptyStr;
  // the pure resolver never raises and never caches: repeated calls stay empty
  AssertEquals('no source resolves to an empty path', EmptyStr,
    TTestTrustBot.DefaultResolution);
  AssertEquals('the empty resolution is stable', EmptyStr,
    TTestTrustBot.DefaultResolution);
end;

procedure TTestTLSTrust.MergedCACacheStablePerProcess;
var
  First, Second, Rebuilt: String;
begin
  First:=TTestTrustBot.MergedBundle;
  AssertTrue('the resolved bundle path must be non-empty', First<>EmptyStr);
  AssertTrue('the merged bundle file should exist', FileExists(First));
  // rewrite a source AFTER the first call: a cache hit must keep serving the
  // bundle built from the old content
  WriteFixture(TTestTrustBot.FixShipped, FixtureShippedAltPEM);
  Second:=TTestTrustBot.MergedBundle;
  AssertEquals('the second call is served from the per-process cache',
    First, Second);
  AssertEquals('the cache hit keeps the content of the first build',
    FixtureShippedPEM+FixtureSystemPEM, FileBytes(First));
  // the resolver without the cache does pick the new source up: the pass
  // above proves the cache, not a merge that is blind to the fixtures
  Rebuilt:=TTestTrustBot.DefaultResolution;
  AssertEquals('a fresh resolution rebuilds from the changed source',
    FixtureShippedAltPEM+FixtureSystemPEM, FileBytes(Rebuilt));
end;

procedure TTestTLSTrust.NoSourcesFailsClosed;
begin
  TTestTrustBot.FixShipped:=EmptyStr;
  TTestTrustBot.FixSystem:=EmptyStr;
  // the cache is clean (SetUp drops it) and an empty result is never cached.
  // EMaxConfig exactly: AssertException matches the raised class precisely
  // (not via is), the same class the raise uses after td-013
  AssertException('verification on with no source fails closed',
    EMaxConfig, @ResolveAnchorWithoutSources);
end;

procedure TTestTLSTrust.VerifyOffUsesSystemStore;
var
  Bot: TTestTrustBot;
begin
  Bot:=TTestTrustBot.Create(EmptyStr);
  try
    Bot.SSLVerifyCert:=False;
    Bot.SSLCAFile:=EmptyStr;
    // the verification-off fall-through is preserved: no merge, no raise,
    // the system store still goes to the broker when it is found
    AssertEquals('verification off keeps the system fall-through',
      TTestTrustBot.FixSystem, Bot.ResolveAnchor);
  finally
    Bot.Free;
  end;
end;

procedure TTestTLSTrust.MergedBundleNameFitsCleanupMask;
const
  { Replica of the merged-bundle naming contract of maxsendertypes.pas (the
    template consts and the mask helper live in that unit's implementation and
    cannot be reached from here): the build formats this pid and a fresh GUID
    tail into cDirFmt - since td-035 a per-process private directory the
    bundle lives in - and the finalization sweep matches the same shape; the
    bundle file itself sits inside under the unit's fixed inner name. If
    either string drifts from the unit, the real bundle location below stops
    fitting the replica and this test goes red - the "cleanup finds what
    build creates" contract is loud again. Windows keeps the flat cNameFmt
    file shape (its %TEMP% is per-user, no directory is needed) }
  {$IFDEF UNIX}
  cDirFmt = 'fpmax-ca-%d-%s.d';
  cBundleName = 'bundle.pem';
  {$ELSE}
  cNameFmt = 'fpmax-ca-%d-%s.pem';
  {$ENDIF}
  cMaskPrefixFmt = 'fpmax-ca-%d-';
var
  Merged, Rebuilt, Prefix: String;
  {$IFDEF UNIX}
  DirPath, DirName: String;
  Info: Stat;
  {$ELSE}
  Name: String;
  {$ENDIF}

  function FitsCleanupMask(const AName, APrefix, AExt: String): Boolean;
  begin
    // the string form of the replicated mask: this pid prefix + * + AExt
    Result:=(Copy(AName, 1, Length(APrefix))=APrefix)
      and (ExtractFileExt(AName)=AExt);
  end;

begin
  Prefix:=Format(cMaskPrefixFmt, [GetProcessID]);
  Merged:=TTestTrustBot.DefaultResolution;
  AssertTrue('the default resolution builds a real bundle file',
    FileExists(Merged));
  {$IFDEF UNIX}
  DirPath:=ExcludeTrailingPathDelimiter(ExtractFilePath(Merged));
  DirName:=ExtractFileName(DirPath);
  // positive side: the built bundle lives in a directory that fits the mask
  // the sweep will use on exit
  AssertTrue('the built bundle directory fits the cleanup mask',
    FitsCleanupMask(DirName, Prefix, '.d'));
  AssertEquals('the tail after the pid prefix is a 36-char GUID (no braces)',
    36, Length(Copy(DirName, Length(Prefix)+1,
      Length(DirName)-Length(Prefix)-Length('.d'))));
  AssertEquals('the bundle sits under the fixed inner name',
    cBundleName, ExtractFileName(Merged));
  // td-035: the private directory is what guards the later path reads of the
  // trust anchor - only this uid may traverse it, so the bundle file cannot
  // be read, replaced or symlinked through its path; the directory entry in
  // the parent temp is still governed by the temp permissions (a shared
  // non-sticky temp allows a foreign rename-and-replant of the directory)
  AssertTrue('the bundle directory should stat', FpStat(DirPath, Info)=0);
  AssertEquals('the bundle directory is private to this uid (mode 0700)',
    S_IRUSR or S_IWUSR or S_IXUSR, Info.st_mode and &777);
  // freshness: each build draws its own GUID - a masked-shape tail alone is
  // also produced by an uninitialized record formatted through GUIDToString
  // (36 hex chars either way), so both regressions that slipped past the
  // mask check are caught here: the same stale tail across builds, or the
  // all-zero tail of an untouched stack record. The first bundle is removed
  // whole so a stale tail cannot surface earlier as an EEXIST clash of the
  // mkdir loop - the second build goes through and the asserts below are
  // what fails (DefaultResolution holds no cache, it really rebuilds; the
  // sweep removes the one directory left over)
  AssertTrue('the built bundle is removable by its owner', DeleteFile(Merged));
  AssertTrue('the emptied bundle directory is removable by its owner',
    RemoveDir(DirPath));
  Rebuilt:=TTestTrustBot.DefaultResolution;
  AssertTrue('a second build draws a fresh GUID tail',
    ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Rebuilt)))
      <>DirName);
  AssertTrue('the GUID tail is not a string of zeros',
    StringReplace(Copy(DirName, Length(Prefix)+1, 36), '-', '', [rfReplaceAll])
      <>StringOfChar('0', 32));
  // negative side: the shapes the mask must never touch (a foreign entry
  // must survive the finalization sweep)
  AssertFalse('the old flat bundle name does not fit the mask',
    FitsCleanupMask(Format('fpmax-ca-%d.pem', [GetProcessID]), Prefix, '.d'));
  AssertFalse('a foreign pid does not fit the mask',
    FitsCleanupMask(Format(cDirFmt, [GetProcessID+1,
      '0123456789ABCDEF0123456789ABCDEF0123']), Prefix, '.d'));
  AssertFalse('a foreign extension does not fit the mask',
    FitsCleanupMask(Format('fpmax-ca-%d-%s.txt', [GetProcessID,
      '0123456789ABCDEF0123456789ABCDEF0123']), Prefix, '.d'));
  {$ELSE}
  Name:=ExtractFileName(Merged);
  // positive side: the built bundle fits the mask the sweep will use on exit
  AssertTrue('the built bundle name fits the cleanup mask',
    FitsCleanupMask(Name, Prefix, '.pem'));
  AssertEquals('the tail after the pid prefix is a 36-char GUID (no braces)',
    36, Length(Copy(Name, Length(Prefix)+1,
      Length(Name)-Length(Prefix)-Length('.pem'))));
  // freshness: each build draws its own GUID - see the UNIX branch above for
  // what this catches. The first bundle is removed so a stale tail cannot
  // surface earlier as a clash of the create - the second build goes through
  // and the asserts below are what fails (DefaultResolution holds no cache,
  // it really rebuilds; the sweep removes the one file left over)
  AssertTrue('the built bundle is removable by its owner', DeleteFile(Merged));
  Rebuilt:=TTestTrustBot.DefaultResolution;
  AssertTrue('a second build draws a fresh GUID tail',
    ExtractFileName(Rebuilt)<>Name);
  AssertTrue('the GUID tail is not a string of zeros',
    StringReplace(Copy(Name, Length(Prefix)+1, 36), '-', '', [rfReplaceAll])
      <>StringOfChar('0', 32));
  // negative side: the shapes the mask must never touch (a foreign file must
  // survive the finalization sweep)
  AssertFalse('the old unsuffixed name does not fit the mask',
    FitsCleanupMask(Format('fpmax-ca-%d.pem', [GetProcessID]), Prefix, '.pem'));
  AssertFalse('a foreign pid does not fit the mask',
    FitsCleanupMask(Format(cNameFmt, [GetProcessID+1,
      '0123456789ABCDEF0123456789ABCDEF0123']), Prefix, '.pem'));
  AssertFalse('a foreign extension does not fit the mask',
    FitsCleanupMask(Format('fpmax-ca-%d-%s.txt', [GetProcessID,
      '0123456789ABCDEF0123456789ABCDEF0123']), Prefix, '.pem'));
  {$ENDIF}
end;

{ TTestMultipartBody }

const
  { One fixed boundary shared by the whole suite: the composite does not
    validate the caller's boundary format, the tests pin the stock byte
    layout. The content is pure ASCII - the bodies are compared as bytes }
  cBoundary='deadbeef_multipart_boundary';
  cFileContent='hello';
  { Same literal the composite and the stock builders assemble with (the
    maxbasehttpclient one is implementation-local, not visible here) }
  CRLF=#13#10;

{ Serves at most APortion bytes per Read call, and nothing at all once
  AStopAfter total bytes are served (-1 = never stop short): TStringStream
  never returns short reads, real sources (pipes, sockets, a truncated file)
  do - the composite must survive the former and fail loudly on the latter }
type
  TShortReadStream=class(TStream)
  private
    FSource: TStream;   // NOT owned
    FPortion: Integer;
    FStopAfter: Int64;
    FServed: Int64;
  public
    constructor Create(ASource: TStream; APortion: Integer;
      AStopAfter: Int64 = -1);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TShortReadStream.Create(ASource: TStream; APortion: Integer;
  AStopAfter: Int64);
begin
  inherited Create;
  if not Assigned(ASource) then
    raise EStreamError.Create('TShortReadStream: the source stream is required');
  FSource:=ASource;
  FPortion:=APortion;
  FStopAfter:=AStopAfter;
  FServed:=0;
end;

function TShortReadStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result:=0;
  if Count<=0 then
    Exit;
  // the promised bytes are exhausted: this is the spot where the consumer
  // must stop silently accepting data
  if (FStopAfter>=0) and (FServed>=FStopAfter) then
    Exit;
  if Count>FPortion then
    Count:=FPortion;
  if (FStopAfter>=0) and (FServed+Count>FStopAfter) then
    Count:=FStopAfter-FServed;
  Result:=FSource.Read(Buffer, Count);
  Inc(FServed, Result);
end;

function TShortReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // the composite repositions the source lazily (PositionSource): forward
  // the seek, the served-bytes counter IS the source position
  Result:=FSource.Seek(Offset, Origin);
  FServed:=Result;
end;

{ The body the test composites must byte-match: the exact layout the stock
  TFPCustomHTTPClient.StreamFormPost produces (and TMaxMultipartStream
  replaces one-to-one) - per form field the boundary line, the
  Content-Disposition header and the value, then the file part with its
  Content-Type header and raw bytes, then the closing boundary; every line
  ends CRLF }
function TTestMultipartBody.BodyOf(const AFormData: TStrings): String;
var
  I: Integer;
begin
  Result:='';
  if Assigned(AFormData) then
    for I:=0 to AFormData.Count-1 do
      Result:=Result+'--'+cBoundary+CRLF
        +'Content-Disposition: form-data; name="'+AFormData.Names[I]+'"'
        +CRLF+CRLF+AFormData.ValueFromIndex[I]+CRLF;
  Result:=Result+'--'+cBoundary+CRLF
    +'Content-Disposition: form-data; name="data"; filename="hello.txt"'+CRLF
    +'Content-Type: application/octet-string'+CRLF+CRLF
    +cFileContent
    +CRLF+'--'+cBoundary+'--'+CRLF;
end;

{ The chunked-read helper shared by the body suites (the keep-alive send
  loop and the composite's own literal/file/tail sequencing): arbitrary Read
  sizes must concatenate into the same body }
function ReadInChunks(AStream: TStream; AChunk: Integer): String;
var
  Buf: TBytes;
  N: Integer;
  SS: TStringStream;
begin
  SS:=TStringStream.Create('');
  try
    SetLength(Buf, AChunk);
    repeat
      N:=AStream.Read(Buf[0], AChunk);
      if N>0 then
        SS.WriteBuffer(Buf[0], N);
    until N<AChunk;
    Result:=SS.DataString;
  finally
    SS.Free;
  end;
end;

{ The drain of TruncatedSourceRaises: retries through the short reads (each
  is legal), ends on the composite's EStreamError or on a plain 0 }
procedure TTestMultipartBody.DrainBody;
var
  Buf: TBytes;
  N: Integer;
begin
  SetLength(Buf, 3);
  repeat
    N:=FDrainee.Read(Buf[0], 3);
  until N=0;
end;

procedure TTestMultipartBody.CompositeBytesMatchStockLayout;
var
  Fields: TStringList;
  Src: TStringStream;
  MP: TMaxMultipartStream;
begin
  // td-048: the streamed composite must produce the same bytes the stock
  // buffered path produced - Content-Length boundaries and the server-side
  // parser see no difference
  Fields:=TStringList.Create;
  try
    Fields.Values['field']:='value';
    Src:=TStringStream.Create(cFileContent);
    try
      MP:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', Src);
      try
        AssertEquals('the composite bytes match the stock multipart layout',
          BodyOf(Fields), ReadInChunks(MP, 1 shl 16));
      finally
        MP.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Fields.Free;
  end;
end;

procedure TTestMultipartBody.SizeIsPrecomputed;
var
  Fields: TStringList;
  Src: TStringStream;
  MP: TMaxMultipartStream;
begin
  // fphttpclient takes Content-Length from RequestBody.Size BEFORE the first
  // Read: the size must be exact without reading the file (a wrong Size
  // truncates the upload or hangs the server side)
  Fields:=TStringList.Create;
  try
    Fields.Values['field']:='value';
    Src:=TStringStream.Create(cFileContent);
    try
      MP:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', Src);
      try
        AssertEquals('Size is exact before the first Read',
          Length(BodyOf(Fields)), MP.Size);
      finally
        MP.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Fields.Free;
  end;
end;

procedure TTestMultipartBody.RewindIsStable;
var
  Src: TStringStream;
  MP: TMaxMultipartStream;
  First, Second: String;
begin
  // the keep-alive loop rewinds RequestBody (Position:=0) before every send
  // attempt: the composite must rewind its cursor AND the source stream, and
  // the second body must be byte-identical to the first
  Src:=TStringStream.Create(cFileContent);
  try
    MP:=TMaxMultipartStream.Create(cBoundary, nil, 'data', 'hello.txt', Src);
    try
      First:=ReadInChunks(MP, 7);
      MP.Seek(0, soBeginning);
      Second:=ReadInChunks(MP, 1 shl 16);
      AssertEquals('the rewound composite rereads the same body', First, Second);
    finally
      MP.Free;
    end;
  finally
    Src.Free;
  end;
end;

procedure TTestMultipartBody.ChunkedReadsConcatenate;
var
  Fields: TStringList;
  Src: TStringStream;
  MP: TMaxMultipartStream;
begin
  // reads of 3 bytes walk the literal/file/tail sequencing byte by byte
  Fields:=TStringList.Create;
  try
    Fields.Values['field']:='value';
    Src:=TStringStream.Create(cFileContent);
    try
      MP:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', Src);
      try
        AssertEquals('small chunked reads concatenate into the same body',
          BodyOf(Fields), ReadInChunks(MP, 3));
      finally
        MP.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Fields.Free;
  end;
end;

procedure TTestMultipartBody.EmptyFormDataSupported;
var
  Fields: TStringList;
  Src: TStringStream;
  MP, MP2: TMaxMultipartStream;
  NoFields, Expected: String;
begin
  // the UploadFile path creates an EMPTY TStringList for the form fields:
  // nil and a zero-count list are both valid, the body is the file part only
  Src:=TStringStream.Create(cFileContent);
  try
    Expected:='--'+cBoundary+CRLF
      +'Content-Disposition: form-data; name="data"; filename="hello.txt"'+CRLF
      +'Content-Type: application/octet-string'+CRLF+CRLF
      +cFileContent
      +CRLF+'--'+cBoundary+'--'+CRLF;
    MP:=TMaxMultipartStream.Create(cBoundary, nil, 'data', 'hello.txt', Src);
    try
      NoFields:=ReadInChunks(MP, 1 shl 16);
      AssertEquals('a nil FormData yields the file part only', Expected, NoFields);
      MP.Seek(0, soBeginning);
      Fields:=TStringList.Create;
      try
        MP2:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', Src);
        try
          AssertEquals('a zero-count FormData yields the file part only',
            NoFields, ReadInChunks(MP2, 1 shl 16));
        finally
          MP2.Free;
        end;
      finally
        Fields.Free;
      end;
    finally
      MP.Free;
    end;
  finally
    Src.Free;
  end;
end;

procedure TTestMultipartBody.ShortReadsConcatenate;
var
  Fields: TStringList;
  Src: TStringStream;
  AShort: TShortReadStream;
  MP: TMaxMultipartStream;
  Got: TStringStream;
  Buf: TBytes;
  N: Integer;
begin
  // a source serving ONE byte per Read is the extreme of the legal short
  // reads: the composite must retry the file part across calls, assemble the
  // exact body and never pull the closing boundary over the file bytes (a
  // regression here read before the start of the tail buffer)
  Fields:=TStringList.Create;
  try
    Fields.Values['field']:='value';
    Src:=TStringStream.Create(cFileContent);
    try
      AShort:=TShortReadStream.Create(Src, 1);
      try
        MP:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', AShort);
        try
          // a drain that keeps going through short reads: ReadInChunks stops
          // at the first one, here the reader must tolerate less than asked
          Got:=TStringStream.Create('');
          try
            SetLength(Buf, 3);
            repeat
              N:=MP.Read(Buf[0], 3);
              if N>0 then
                Got.WriteBuffer(Buf[0], N);
            until N=0;
            AssertEquals('short source reads still assemble the exact body',
              BodyOf(Fields), Got.DataString);
          finally
            Got.Free;
          end;
        finally
          MP.Free;
        end;
      finally
        AShort.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Fields.Free;
  end;
end;

procedure TTestMultipartBody.TruncatedSourceRaises;
var
  Fields: TStringList;
  Src: TStringStream;
  AShort: TShortReadStream;
  MP: TMaxMultipartStream;
begin
  // the source Size promised 5 file bytes, the wrapper stops serving after 2:
  // the Content-Length is already built on the promise and the head may be on
  // the wire - the composite must raise, a silently shortened body would hang
  // the server side waiting for the missing tail
  Fields:=TStringList.Create;
  try
    Fields.Values['field']:='value';
    Src:=TStringStream.Create(cFileContent);
    try
      AShort:=TShortReadStream.Create(Src, 2, 2);
      try
        MP:=TMaxMultipartStream.Create(cBoundary, Fields, 'data', 'hello.txt', AShort);
        try
          FDrainee:=MP;
          AssertException('a source stopping short of its promised Size fails loudly',
            EStreamError, @DrainBody);
        finally
          FDrainee:=nil;
          MP.Free;
        end;
      finally
        AShort.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Fields.Free;
  end;
end;

{ TTestStringBody }

const
  { The body the stream serves: pure ASCII JSON, long enough for the chunked
    reads to walk it in several calls }
  cStringBody='{"update_type":"message_created","message":'+
    '{"sender":{"user_id":99},"body":{"mid":"mid.1","text":"Hi"}}}';

procedure TTestStringBody.SeekBeforeBody;
begin
  FDrainee.Seek(-1, soBeginning);
end;

procedure TTestStringBody.SeekPastBody;
begin
  FDrainee.Seek(Length(cStringBody)+1, soBeginning);
end;

procedure TTestStringBody.SeekUnsupportedOrigin;
var
  Raw: Integer;
  Bad: TSeekOrigin;
begin
  // an origin value outside TSeekOrigin takes the else branch of the Seek
  // case: the enum itself has no illegal member, the wire of the call is
  // built from this raw value (a constant cast would trip the compile-time
  // range check)
  Raw:=Ord(soEnd)+1;
  Bad:=TSeekOrigin(Raw);
  FDrainee.Seek(0, Bad);
end;

procedure TTestStringBody.CompactNaNFloatBody;
var
  F: TJSONFloatNumber;
begin
  F:=TJSONFloatNumber.Create(NaN);
  try
    JSONCompact(F);
  finally
    F.Free;
  end;
end;

procedure TTestStringBody.CompactInfinityFloatBody;
var
  F: TJSONFloatNumber;
begin
  F:=TJSONFloatNumber.Create(Infinity);
  try
    JSONCompact(F);
  finally
    F.Free;
  end;
end;

procedure TTestStringBody.CompactNegInfinityFloatBody;
var
  F: TJSONFloatNumber;
begin
  F:=TJSONFloatNumber.Create(NegInfinity);
  try
    JSONCompact(F);
  finally
    F.Free;
  end;
end;

procedure TTestStringBody.SizeFeedsContentLength;
var
  S: TMaxStringBodyStream;
begin
  // fphttpclient takes Content-Length from RequestBody.Size BEFORE the first
  // Read: the wrapper reports the length of the referenced buffer without
  // reading it
  S:=TMaxStringBodyStream.Create(cStringBody);
  try
    AssertEquals('Size is exact before the first Read',
      Length(cStringBody), S.Size);
    AssertEquals('the position starts at the body start', 0, S.Position);
  finally
    S.Free;
  end;
end;

procedure TTestStringBody.RewindReplaysIdenticalBytes;
var
  S: TMaxStringBodyStream;
  First, Second: String;
begin
  // the keep-alive loop rewinds RequestBody (Position:=0) before every send
  // attempt: a retry must replay the identical bytes (td-048)
  S:=TMaxStringBodyStream.Create(cStringBody);
  try
    First:=ReadInChunks(S, 7);
    S.Seek(0, soBeginning);
    Second:=ReadInChunks(S, 1 shl 16);
    AssertEquals('the rewound stream rereads the same body', First, Second);
  finally
    S.Free;
  end;
end;

procedure TTestStringBody.ChunkedReadsConcatenate;
var
  S: TMaxStringBodyStream;
begin
  // reads shorter than the remaining body walk the referenced buffer byte by
  // byte and must concatenate into the exact string
  S:=TMaxStringBodyStream.Create(cStringBody);
  try
    AssertEquals('small chunked reads concatenate into the same body',
      cStringBody, ReadInChunks(S, 3));
  finally
    S.Free;
  end;
end;

procedure TTestStringBody.IllegalSeeksRaise;
var
  S: TMaxStringBodyStream;
begin
  // a rejected seek must fail loudly: a silently clamped position would send
  // a shifted body on the wire
  S:=TMaxStringBodyStream.Create(cStringBody);
  try
    FDrainee:=S;
    try
      AssertException('a seek before the body fails loudly', EStreamError,
        @SeekBeforeBody);
      AssertException('a seek past the body fails loudly', EStreamError,
        @SeekPastBody);
      AssertException('an unsupported seek origin fails loudly', EStreamError,
        @SeekUnsupportedOrigin);
      AssertEquals('the position survives the rejected seeks', 0, S.Position);
    finally
      FDrainee:=nil;
    end;
  finally
    S.Free;
  end;
end;

procedure TTestStringBody.EmptyStringServesNothing;
var
  Buf: TBytes;
  S: TMaxStringBodyStream;
begin
  // an empty serialization is a legal body: the wrapper must report Size=0
  // and serve no bytes without faulting
  S:=TMaxStringBodyStream.Create('');
  try
    AssertEquals('the empty body has Size 0', 0, S.Size);
    SetLength(Buf, 8);
    AssertEquals('the empty body serves no bytes', 0, S.Read(Buf[0], 8));
  finally
    S.Free;
  end;
end;

function TTestStringBody.SameJSONTree(AExpected, AActual: TJSONData): Boolean;
var
  I: Integer;
begin
  Result:=False;
  if (AExpected=nil) or (AActual=nil) then
    Exit(AExpected=AActual);
  // the node class must survive too: a compact body re-parsed into a
  // different node type would mean the wire form changed the value's nature
  if AExpected.ClassType<>AActual.ClassType then
    Exit;
  if AExpected is TJSONObject then
  begin
    if TJSONObject(AExpected).Count<>TJSONObject(AActual).Count then
      Exit;
    for I:=0 to TJSONObject(AExpected).Count-1 do
    begin
      if TJSONObject(AExpected).Names[I]<>TJSONObject(AActual).Names[I] then
        Exit;
      if not SameJSONTree(TJSONObject(AExpected).Items[I],
        TJSONObject(AActual).Items[I]) then
        Exit;
    end;
  end
  else if AExpected is TJSONArray then
  begin
    if TJSONArray(AExpected).Count<>TJSONArray(AActual).Count then
      Exit;
    for I:=0 to TJSONArray(AExpected).Count-1 do
      if not SameJSONTree(TJSONArray(AExpected).Items[I],
        TJSONArray(AActual).Items[I]) then
        Exit;
  end
  else
    // scalars of the same class: the serialization is an exact value match
    // (floats included - the compact form re-parses to the same double)
    if AExpected.AsJSON<>AActual.AsJSON then
      Exit;
  Result:=True;
end;

procedure TTestStringBody.NilTreeSerializesEmpty;
begin
  // ApiCall only serializes an Assigned tree, but the helper itself must not
  // fault on nil - the empty string is a servable body (see
  // EmptyStringServesNothing)
  AssertEquals('a nil tree serializes to the empty string',
    EmptyStr, JSONCompact(nil));
end;

procedure TTestStringBody.CompactFormHasNoPadding;
var
  A, Deep, EA: TJSONArray;
  E, Inner, DeepObj, O: TJSONObject;
begin
  // byte for byte, no whitespace outside strings - objects and arrays
  // nested recursively
  O:=TJSONObject.Create;
  try
    Inner:=TJSONObject.Create;
    Inner.Add('k', 'v');
    A:=TJSONArray.Create;
    A.Add(1);
    A.Add('two');
    A.Add(TJSONBoolean.Create(False));
    A.Add(Inner);
    DeepObj:=TJSONObject.Create;
    Deep:=TJSONArray.Create;
    Deep.Add(TJSONNull.Create);
    DeepObj.Add('deep', Deep);
    O.Add('key', 'value');
    O.Add('n', TJSONIntegerNumber.Create(1));
    O.Add('b', TJSONBoolean.Create(True));
    O.Add('z', TJSONNull.Create);
    O.Add('arr', A);
    O.Add('obj', DeepObj);
    AssertEquals('objects, arrays and scalars serialize with no padding',
      '{"key":"value","n":1,"b":true,"z":null,'+
      '"arr":[1,"two",false,{"k":"v"}],"obj":{"deep":[null]}}', JSONCompact(O));
  finally
    O.Free;
  end;
  E:=TJSONObject.Create;
  try
    AssertEquals('the empty object stays empty', '{}', JSONCompact(E));
  finally
    E.Free;
  end;
  EA:=TJSONArray.Create;
  try
    AssertEquals('the empty array stays empty', '[]', JSONCompact(EA));
  finally
    EA.Free;
  end;
  // the float form is fpjson's own too: compact, not the padded AsJSON
  O:=TJSONObject.Create;
  try
    O.Add('f', TJSONFloatNumber.Create(1.5));
    AssertEquals('the float keeps its compact fpjson form',
      '{"f":1.5000000000000000E+000}', JSONCompact(O));
  finally
    O.Free;
  end;
  // a finite double far beyond MaxSingle passes the guard too: it pins the
  // typed read of the float value (the Variant Value property crashes on it)
  O:=TJSONObject.Create;
  try
    O.Add('f', TJSONFloatNumber.Create(1e308));
    AssertEquals('the large finite float keeps its compact fpjson form',
      '{"f":1.0000000000000000E+308}', JSONCompact(O));
  finally
    O.Free;
  end;
end;

procedure TTestStringBody.StringEscaping;
const
  { The backslash every JSON escape starts with: spelled by character code so
    no literal below ever carries a backslash next to a quote character }
  cBS=#92;
var
  O: TJSONObject;
begin
  // a raw quote would terminate the string, a raw backslash would swap the
  // meaning of the next byte, a raw control byte breaks the deserializer:
  // each of them must travel as its JSON escape
  AssertEquals('structural and control characters escape inside strings',
    '"a'+cBS+'"b'+cBS+cBS+'c'+cBS+'n'+cBS+'r'+cBS+'t'+cBS+'b'+cBS+'f"',
    JSONCompact(TJSONString.Create('a"b\c'#10#13#9#8#12)));
  AssertEquals('control characters without a named escape use the unicode form',
    '"'+cBS+'u0001"', JSONCompact(TJSONString.Create(#1)));
  // names are strings on the wire too: a parsed key can carry the same
  // structural characters as a value
  O:=TJSONObject.Create;
  try
    O.Add('a"b\c'#10, 'v');
    AssertEquals('structural and control characters escape inside keys',
      '{"a'+cBS+'"b'+cBS+cBS+'c'+cBS+'n":"v"}', JSONCompact(O));
  finally
    O.Free;
  end;
end;

procedure TTestStringBody.UnicodeStaysRawUTF8;
const
  { A Cyrillic word (U+0442 U+0435 U+0441 U+0442) spelled by its UTF-8
    bytes: the assertions stay codepage-independent }
  cUtf8Word=#$D1#$82#$D0#$B5#$D1#$81#$D1#$82;
begin
  // the API accepts raw UTF-8; escaping or re-encoding the payload would
  // only inflate the body and risk corrupting valid text - the bytes must
  // pass through the quotes untouched
  AssertEquals('non-ASCII travels as raw UTF-8 inside the quotes',
    '"'+cUtf8Word+'"', JSONCompact(TJSONString.Create(cUtf8Word)));
end;

procedure TTestStringBody.ScalarsKeepTheirAsJSONForm;

  procedure Check(AData: TJSONData);
  begin
    // the compact writer delegates every scalar to its own AsJSON: the
    // number formatting (integer, int64, float) stays fpjson's own
    try
      AssertEquals('the scalar keeps its own compact AsJSON',
        AData.AsJSON, JSONCompact(AData));
    finally
      AData.Free;
    end;
  end;

begin
  Check(TJSONNull.Create);
  Check(TJSONBoolean.Create(True));
  Check(TJSONBoolean.Create(False));
  Check(TJSONIntegerNumber.Create(42));
  Check(TJSONInt64Number.Create(9007199254740993));
  Check(TJSONFloatNumber.Create(1.5));
  // the delegation covers finite values only: a non-number float comes out
  // of fpjson as a padded invalid token ("Nan", "+Inf") - the guard raises
  AssertException('a NaN float does not serialize', EJSON,
    @CompactNaNFloatBody);
  AssertException('an Infinity float does not serialize', EJSON,
    @CompactInfinityFloatBody);
  AssertException('a negative Infinity float does not serialize', EJSON,
    @CompactNegInfinityFloatBody);
end;

procedure TTestStringBody.CompactBodyRoundTripsSemantically;
var
  A: TJSONArray;
  Inner: TJSONObject;
  Parsed: TJSONData;
  Source: TJSONObject;
begin
  // the bytes go on the wire compact and the platform parses them back: the
  // re-parsed tree must equal the source by classes and values
  Source:=TJSONObject.Create;
  Parsed:=nil;
  try
    Inner:=TJSONObject.Create;
    Inner.Add('i64', TJSONInt64Number.Create(9007199254740993));
    A:=TJSONArray.Create;
    A.Add(1);
    A.Add('two');
    A.Add(TJSONBoolean.Create(False));
    A.Add(TJSONFloatNumber.Create(1.5));
    Source.Add('text', 'hi there');
    Source.Add('nested', A);
    Source.Add('obj', Inner);
    Source.Add('z', TJSONNull.Create);
    try
      Parsed:=GetJSON(JSONCompact(Source));
      AssertTrue('the re-parsed compact body equals the source tree',
        SameJSONTree(Source, Parsed));
    finally
      Parsed.Free;
    end;
  finally
    Source.Free;
  end;
end;

{ TTestDaemonStartFailure }

type
  { The raised start failure of the stub, named for a readable line in the
    ShowException output the Run loop prints for the re-raised DoRun
    exception }
  EFailingStartStub=class(Exception);

  { TStubDaemonReceiver }
  { td-091: the receiver of the failed-start suite: never polls. The stop
    path only needs a thread that becomes runnable and finishes at once -
    Execute begins and ends immediately, the way the real one exits when it
    finds Terminate already set }
  TStubDaemonReceiver=class(TLongPollingThread)
  public
    procedure Execute; override;
  end;

  { TFailingStartDaemon }
  { td-091: the real TDaemonApplication with a stub receiver and a start
    seam that raises for the first RaisingStarts attempts - the persistent
    start failure of td-086/td-091 modelled at the daemon level (TThread.Start
    is not virtual in FPC 3.2.2, so the daemon-side StartReceiver funnel is
    the seam). Past the cap the stub models the pressure easing and really
    starts the receiver: the destructor drain then completes and no receiver
    thread survives the test }
  TFailingStartDaemon=class(TDaemonApplication)
  private
    FStartCalls: Integer;
    FRaisingStarts: Integer;
  protected
    function CreateReceiver: TLongPollingThread; override;
    procedure StartReceiver; override;
  public
    { The stub raises for the first RaisingStarts start attempts }
    property RaisingStarts: Integer read FRaisingStarts write FRaisingStarts;
    { Every StartReceiver call of the run: under the contract exactly two -
      the raising failed-start attempt and the raising drain the best-effort
      cleanup absorbs (a second DoRun pass would push the count past that) }
    property StartCalls: Integer read FStartCalls;
  end;

procedure TStubDaemonReceiver.Execute;
begin
  // deliberately empty: a stub that finishes at once keeps every join of
  // the stop path bounded without ever polling
end;

function TFailingStartDaemon.CreateReceiver: TLongPollingThread;
begin
  Result:=TStubDaemonReceiver.Create;
end;

procedure TFailingStartDaemon.StartReceiver;
begin
  Inc(FStartCalls);
  if FStartCalls<=FRaisingStarts then
    raise EFailingStartStub.Create('stub receiver start failure');
  inherited StartReceiver;
end;

procedure TTestDaemonStartFailure.SetUp;
begin
  FSavedConf:=Conf;
  FSavedStop:=gStop;
  FSavedExitCode:=ExitCode;
  // A configured token passes the constructor fail-fast; the log goes to a
  // named temp file instead of the binary-named temp default (td-085) so
  // TearDown removes exactly what this test created
  FTestLogFile:=IncludeTrailingPathDelimiter(GetTempDir)
    +'max-daemon-startfail-test.log';
  Conf.MaxToken:='stub-token';
  Conf.LogFile:=FTestLogFile;
  gStop:=False;
end;

procedure TTestDaemonStartFailure.TearDown;
begin
  // The failed-start pass writes the SYSTEM exit code global - leaving it
  // set would poison the exit code of the whole runner process
  ExitCode:=FSavedExitCode;
  Conf:=FSavedConf;
  gStop:=FSavedStop;
  DeleteFile(FTestLogFile);
end;

procedure TTestDaemonStartFailure.FailedStartExitsNonZero;
var
  Daemon: TFailingStartDaemon;
begin
  Daemon:=TFailingStartDaemon.Create(nil);
  try
    // Two raising starts: the failed-start attempt of the single DoRun pass
    // and the best-effort cleanup drain - exactly the td-086 shape, where a
    // persistent start failure raises on the drain too. The count of two
    // below is the load-bearing assertion: a second DoRun pass (the
    // infinite loop the td-086 order fix removes) would really start the
    // receiver on its attempt and end with three calls
    Daemon.RaisingStarts:=2;
    Daemon.Run;
    // td-091: the failed-start contract - one pass, non-zero exit
    AssertEquals('the failed start must exit with code 1', 1, ExitCode);
    AssertEquals('the Run loop must end after one DoRun pass: the raising '
      +'start plus the drain its cleanup swallowed', 2, Daemon.StartCalls);
  finally
    // The cleanup skipped on the failed pass is repeated here: with
    // RaisingStarts=2 the destructor drain is the third start - a healthy
    // one, so the free completes (join and release of the stub receiver)
    Daemon.Free;
  end;
end;

procedure TTestDaemonStartFailure.StopBeforeStartFailingDrainExitsNonZero;
var
  Daemon: TFailingStartDaemon;
begin
  Daemon:=TFailingStartDaemon.Create(nil);
  try
    // The stop flag raised BEFORE Run: the guarded start of DoRun is
    // skipped, the loop exits at once and the finally drain of the
    // never-started suspended receiver is the pass's first Start attempt.
    // One raising start models that attempt failing - the second door of
    // the td-086 loop: unguarded, the drain exception escapes the finally
    // before ExitCode and Terminate, Run re-calls DoRun and the pass-two
    // drain succeeds under the same cap - the loop ends with exit 0 and
    // two calls already before the free, exactly what the two asserts
    // below pin
    gStop:=True;
    Daemon.RaisingStarts:=1;
    Daemon.Run;
    // td-091: the one-pass non-zero-exit contract holds through the finally
    // door as well
    AssertEquals('a raising finally drain must still exit with code 1',
      1, ExitCode);
    AssertEquals('the Run loop must end after one DoRun pass: its only '
      +'Start attempt is the raising finally drain', 1, Daemon.StartCalls);
  finally
    // The destructor repeats the drain the finally could not finish: with
    // RaisingStarts=1 that second start is a healthy one, so the free
    // completes (join and release of the stub receiver)
    Daemon.Free;
  end;
  // Counted after the free: exactly two - the raising finally drain plus
  // the destructor's healthy one (the whole test returning also proves the
  // free did not deadlock on the never-started receiver)
  AssertEquals('the destructor must repeat the failed drain: the raising '
    +'finally drain plus its own healthy one', 2, Daemon.StartCalls);
end;

{ TTestDesignTime }

procedure TTestDesignTime.TokenIsNotStreamedToFormFile;
var
  Comp: TDTMaxLongPollBot;
  PropInfo: PPropInfo;
begin
  // The constructor is offline (two string lists and the reply-markup
  // collection only): no HTTP broker, no receiver thread - safe to build
  // in the offline runner
  Comp:=TDTMaxLongPollBot.Create(nil);
  try
    // The property must remain published: the form designer discovers the
    // properties it shows through RTTI, so dropping Token from the
    // published block would hide it from the Object Inspector entirely -
    // that door stays open on purpose
    PropInfo:=GetPropInfo(TDTMaxLongPollBot, 'Token');
    AssertTrue('Token must stay a published property of TDTMaxLongPollBot '
      +'(the Object Inspector finds it through RTTI)', PropInfo<>nil);
    // td-026: stored False keeps the token out of the .lfm form file and
    // out of the binary resource compiled from it - a committed .lfm or a
    // shipped binary never carries a working bot token; enter the token at
    // run time (removing the stored False fails this assert)
    AssertFalse('td-026: Token must not stream into the form file - the '
      +'published re-declaration in maxbot_dt.pas must keep its stored False',
      IsStoredProp(Comp, PropInfo));
  finally
    Comp.Free;
  end;
end;

initialization
  RegisterTests([TTestSenderTypes, TTestMaxBot, TTestTLSTrust, TTestSender,
    TTestSenderProcedure, TTestMultipartBody,
    TTestStringBody, TTestDaemonStartFailure, TTestDesignTime]);

end.
