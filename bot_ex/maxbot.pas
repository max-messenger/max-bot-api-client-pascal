unit maxbot;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpJSON, maxsendertypes, maxstatlog, maxtypes
  ;

type
  TCallbackHandlersMap = specialize TStringHashMap<TCallbackEvent>;
  TReceiveDeepLinkEvent = procedure (const AParameter: String) of object;
  TUserStatus = (usAdmin, usModerator, usDefault, usBanned);

  { TMaxBot }
  TMaxBot = class(TMaxSender)
  private
    FCallbackHandlers: TCallbackHandlersMap;
    FCallbackMessageId: String; // id of the message under the last pressed inline button
    FCurrentUpdateUserId: Int64; // author of the update being processed (message or callback)
    FHelpText: String;

    FFeedbackText: String;
    FFeedbackThanks: String;
    FOnReceiveDeepLinking: TReceiveDeepLinkEvent;

    FPublicStat: Boolean;
    FStartText: String;
    FStatLogger: TMaxStatLog;
    FUserPermissions: TStringList;
    procedure BrowseStatFile(aDate: TDate; var Msg: String; AAttachments: TJSONArray;
      Offset: Integer);
    class procedure CalculateStat4Strings(aStatFile: TStrings; IDs: TIntegerHashSet;
      var aEvents: Integer);
    procedure DoCallbackQueryStat(ACallback: TMaxCallbackObj; AAsFile: Boolean = False);
    procedure DoCallbackQueryGetUsers(ACallback: TMaxCallbackObj);
    procedure DoGetStat(aFromDate: TDate = 0; aToDate: TDate = 0; Scroll: Boolean = False; Offset: Integer = 0);
    procedure DoGetUsers(aFromDate: TDate = 0; aToDate: TDate = 0);
    procedure DoGetStatMonth(aYear, aMonth: Word);
    procedure DoGetStatFile(ADate: TDate = 0);
    procedure DoStat(const SDate: String; const SOffset: String = ''; AAsFile: Boolean = false);
    procedure DoUsers(const SDate: String);
    function GetCallbackHandlers(const Command: String): TCallbackEvent;
    function GetUserStatus(ID: Int64): TUserStatus;
    procedure SendStatLog(ADate: TDate = 0; AAttachments: TJSONArray = nil);
    procedure SetCallbackHandlers(const Command: String; AValue: TCallbackEvent
      );
    procedure SetCommandReply({%H-}ASender: TObject; const ACommand: String;
      AMessage: TMaxMessageObj);
    procedure SetOnReceiveDeepLinking(AValue: TReceiveDeepLinkEvent);
    procedure SetPublicStat(AValue: Boolean);
    procedure SetUserStatus(ID: Int64; AValue: TUserStatus);
    procedure MaxStartHandler({%H-}ASender: TObject; const ACommand: String;
      {%H-}AMessage: TMaxMessageObj);
    procedure MaxHelpHandler({%H-}ASender: TObject; const {%H-}ACommand: String;
      {%H-}AMessage: TMaxMessageObj);
    procedure MaxFeedback({%H-}ASender: TObject; const {%H-}ACommand: String;
      {%H-}AMessage: TMaxMessageObj);
    procedure MaxStatHandler({%H-}ASender: TObject;
      const {%H-}ACommand: String; AMessage: TMaxMessageObj);
    procedure MaxStatFHandler({%H-}ASender: TObject;
      const {%H-}ACommand: String; AMessage: TMaxMessageObj);
    procedure SendStatInlineKeyboard(AAsFile: Boolean = False);
    procedure StatLog(const AMessage: String; UpdateType: TMaxUpdateType);
  protected
    { Builders of the rows of a MAX inline_keyboard attachment (an array of
      rows, each row is an array of callback/link buttons) }
    function CreateInlineKeyboardStat(aFromDate, aToDate: TDate): TJSONArray;
    function CreateInlineKeyboardStat(ADate: TDate; AAsFile: Boolean): TJSONArray; overload;
    function CreateInlineKeyboardStatFile: TJSONArray;
    function CreateInlineKeyboardStatMonth(ADate: TDate): TJSONArray;
    function CreateInlineKeyboardStat(ADate: TDate; Len: Integer; Offset: Integer = 0;
      Step: Integer = 20): TJSONArray; overload;
    procedure DoReceiveUpdate(AnUpdate: TMaxUpdateObj); override;
    { The base hooks: banned users do not reach the command handlers, the
      callbacks, the statistics or the events; the admins and the moderators
      of UserStatus do not affect the statistics either }
    function AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean; override;
    function ShouldLogUpdate(AnUpdate: TMaxUpdateObj): Boolean; override;
    procedure DoReceiveMessage(AMessage: TMaxMessageObj); override;
    procedure DoReceiveCallback(ACallback: TMaxCallbackObj); override;
    procedure SaveFeedback({%H-}AFrom: TMaxUserObj; {%H-}AMessage: String); virtual;
  public
    function IsAdminUser(ChatID: Int64): Boolean; reintroduce;
    function IsBanned(ChatID: Int64): Boolean;
    function IsBotUser(ChatID: Int64): Boolean;
    function IsSimpleUser(ChatID: Int64): Boolean;
    function CurrentIsAdminUser: Boolean;
    procedure CalculateStat(aFromDate, aToDate: TDate; out aUsers, aEvents: Integer;
      aIDs: TStrings = nil);
    constructor Create(const AToken: String);
    destructor Destroy; override;
    procedure DoReceiveDeepLinking(const AParameter: String);
    { Sends AMessage to the current chat in AFormat. If TryEdit is set and the
      update is a callback on the bot message - the message is edited instead }
    procedure EditOrSendMessage(const AMessage: String; AFormat: TMaxTextFormat = fmtDefault;
      AAttachments: TJSONArray = nil; TryEdit: Boolean = False);
    procedure LangTranslate(const {%H-}ALang: String);
    procedure LoadUserStatusValues(AStrings: TStrings);
    property CallbackHandlers [const Command: String]: TCallbackEvent read GetCallbackHandlers
      write SetCallbackHandlers;  // It can create command handlers by assigning their to array elements
    property StartText: String read FStartText write FStartText; // Text for /start command reply
    property HelpText: String read FHelpText write FHelpText;  // Text for /help command reply
    property FeedbackText: String read FFeedbackText write FFeedbackText;
    property FeedbackThanks: String read FFeedbackThanks write FFeedbackThanks;
    property UserStatus [ID: Int64]: TUserStatus read GetUserStatus write SetUserStatus;
    property OnReceiveDeepLinking: TReceiveDeepLinkEvent read FOnReceiveDeepLinking write SetOnReceiveDeepLinking;
    property PublicStat: Boolean read FPublicStat write SetPublicStat;
    property StatLogger: TMaxStatLog read FStatLogger write FStatLogger;
  end;

function ExtractArgPart(const ASource, ACommand: String): String;
function FormatStatRec(const S: String): String;
{ The user-controlled stat fields (username, names, message text) travel in a
  ';' CSV: quote them by doubling the inner quotes, or a crafted value shifts
  the columns (td-016). The pair is the one contract of the field quoting -
  the writer (StatLog) and the reader (FormatStatRec) must use it together;
  the record shape outside the fields is not part of it: TMaxStatLog owns the
  timestamp prefix and the configurable FieldDelimiter (default '; '), so a
  host reconfiguring that property changes the file format too }
function EscapeStatField(const S: String): String;
function UnescapeStatField(const S: String): String;

{ MAX inline keyboard helpers. A MAX keyboard is an inline_keyboard attachment:
  {"type":"inline_keyboard","payload":{"buttons":[[{"type":"callback","text":..,
  "payload":..}],...]}}. The button and the attachment shells are the core's
  own wire form: the helpers delegate their assembly to
  MakeInlineKeyboardAttachment (maxsendertypes), so the shape has a single
  author and a core-side change cannot desync bot_ex (td-071); the multi-row
  assembly stays row-based here, and link buttons stay hand-built - the core
  serves callback pairs only, which makes MaxLinkButton the one helper without
  a delegated assembly (see its body).
  These helpers are bot_ex internals and implementation-only historically;
  they sit in the interface solely for the offline wire-parity test
  (test/testmax.pas, KeyboardWireMatchesCore) - this unit ships in the public
  fpmaxbot_ex.lpk, and the contract of the wire form remains the core's
  MakeInlineKeyboardAttachment }
function MaxKeyboardRow: TJSONArray;
procedure MaxCallbackButton(ARow: TJSONArray; const AText, APayload: String);
procedure MaxLinkButton(ARow: TJSONArray; const AText, AURL: String);
{ APairs: Text1, Payload1, Text2, Payload2, ... - an odd trailing pair is
  silently skipped, unlike the core MakeInlineKeyboardAttachment, which
  raises (its documented misuse contract: an odd pair count or an empty
  list is a caller bug). The loop bound is the stub filter that keeps the
  dangling half-pair away from the delegated assembly: every complete pair
  goes to MaxCallbackButton, which hands it to the core, and the core would
  raise on an odd count }
procedure MaxCallbackButtons(ARow: TJSONArray; const APairs: array of String);
{ Wraps the keyboard rows into the inline_keyboard attachment JSON.
  Takes ownership of ARows, the result is owned by the caller.
  The shell is the core's own: a single-pair MakeInlineKeyboardAttachment
  call builds it with a throw-away dummy row, which is swapped for ARows -
  the type/payload/buttons shape never gets a second author (td-071) }
function MaxInlineKeyboardAttachment(ARows: TJSONArray): TJSONObject;
{ Wraps the keyboard rows into a one-element attachments array ready for
  TMaxSender.SendMessageEx. Takes ownership of ARows; the single attachment
  is the core's wire form (see MaxInlineKeyboardAttachment) }
function MaxKeyboardAttachments(ARows: TJSONArray): TJSONArray;

implementation

uses
  maxutils, StrUtils, DateUtils
{ Please define ni18n for excluding translate unit to uses and exclude standard po i18n support }
  {$IFNDEF ni18n} , Translations{$ENDIF}
  ;

resourcestring
  str_FeedbackThanks='Thanks! %s Your message will be considered!'; // Спасибо, %s! Ваш сообщение будет обязательно рассмотрено!;
  str_FeedbackText='Send us your suggestions or bug reports please';  // Отправьте разработчику бота пожелание, рекомендацию, информацию об ошибке
  str_TxtRplyIsScsChngd='Text reply for command is succesfully changed!'; // Текст сообщения для команды успешно изменен
  str_SttstcsNtFnd='Statistics for this date not found'; // Статистика не найдено за указанный день
//  str_ErrFldTLdSttstcsFl='Error: failed to load statistics file';
  str_EntrDtInFrmt='Please enter the date in format: dd-mm-yyyy';
  str_SttstcsFr='Statistics for ';
  str_SlctSttstcs_line1='Select statistics by pressing the button. In addition, the available commands:';
  str_SlctSttstcs_line2='/stat <i>day</i> - the last records for a specified <i>date</i>, ';
  str_SlctSttstcs_line3= '/statf <i>date</i> - statistics file for the <i>date</i>,';
  str_SlctSttstcs_line4='where <i>date</i> is <i>today</i> or <i>yesterday</i> or in format <i>dd-mm-yyyy</i>';
  str_Today='Today';
  str_Yesterday='Yesterday';
  str_Monthly='Monthly';
  str_PrevDay='Prev day';
  str_NextDay='Next day';
  str_Users='Users';
  str_Prev='<';
  str_Next='>';
  str_Browse='Browse';
  str_StatParseError='Stat line parser error';

const
  StatDateFormat = 'dd-mm-yyyy';
  StatMonthFormat = 'mm-yyyy';
  UserStatusChars: array [TUserStatus] of AnsiChar = ('a', 'm', '_', 'b');
  cmd_Start = '/start';
  cmd_Help = '/help';
  cmd_Stat = '/stat';
  cmd_StatF = '/statf';
  cmd_Feedback = '/feedback';
  cmd_SetStart = '/setstart';
  cmd_SetHelp = '/sethelp';
  s_Today = 'today';
  s_Yesterday = 'yesterday';
  s_GetStat='GetStat';
  s_GetUsers='GetUsers';
  s_File='File';

{ MAX inline keyboard helpers - the contracts live with the interface
  declarations, the bodies carry only the delegation mechanics }

function MaxKeyboardRow: TJSONArray;
begin
  Result:=TJSONArray.Create;
end;

procedure MaxCallbackButton(ARow: TJSONArray; const AText, APayload: String);
var
  Core: TJSONArray;
  CoreRow: TJSONArray;
begin
  // A single-pair core call builds exactly one callback button - the JSON
  // the row receives is the core's own output, not a bot_ex copy of it.
  // The core's buttons array holds rows, so the single button sits at
  // buttons[0][0]
  Core:=MakeInlineKeyboardAttachment([AText, APayload]);
  try
    CoreRow:=TJSONArray(Core.Items[0].FindPath('payload.buttons').Items[0]);
    ARow.Add(CoreRow.Extract(0)); // the single core-built button changes owner
  finally
    Core.Free;
  end;
end;

procedure MaxLinkButton(ARow: TJSONArray; const AText, AURL: String);
var
  Btn: TJSONObject;
begin
  // Hand-built: the core serves callback pairs only (link buttons are out of
  // MakeInlineKeyboardAttachment's scope), there is nothing to delegate to
  Btn:=TJSONObject.Create;
  Btn.Add('type', 'link');
  Btn.Add('text', AText);
  Btn.Add('url', AURL);
  ARow.Add(Btn);
end;

procedure MaxCallbackButtons(ARow: TJSONArray; const APairs: array of String);
var
  I: Integer;
begin
  I:=0;
  while I+1<=High(APairs) do // the stub filter of the misuse contract above
  begin
    MaxCallbackButton(ARow, APairs[I], APairs[I+1]);
    Inc(I, 2);
  end;
end;

function MaxInlineKeyboardAttachment(ARows: TJSONArray): TJSONObject;
var
  Core: TJSONArray;
  Payload: TJSONObject;
begin
  Result:=nil;
  Core:=MakeInlineKeyboardAttachment(['', '']);
  try
    Result:=TJSONObject(Core.Extract(0)); // the shell, the wrapper is done
  finally
    Core.Free;
  end;
  try
    Payload:=TJSONObject(Result.Objects['payload']);
    // The dummy single row is the only core-built content a multi-row
    // keyboard cannot reuse: 'buttons' is detached with its row and the
    // slot is handed to ARows, owned by the payload now (the old contract)
    Payload.Extract('buttons').Free;
    Payload.Add('buttons', ARows);
  except
    Result.Free;
    raise;
  end;
end;

function MaxKeyboardAttachments(ARows: TJSONArray): TJSONArray;
begin
  Result:=TJSONArray.Create;
  Result.Add(MaxInlineKeyboardAttachment(ARows));
end;

function ExtractArgPart(const ASource, ACommand: String): String;
begin
  Result:=Trim(RightStr(ASource, Length(ASource)-Length(ACommand)));
end;

{ The CSV quoting fits the reader: ExtractStrings keeps ';' literal inside a
  quoted region and retains the quotes in the parsed field, so the doubling
  survives the split - the JSON escape (a backslash before the quote) would
  close the region mid-field instead and let the following ';' split it
  (verified on FPC 3.2.2, td-016). Control chars (< #32) are neutralized to
  spaces one-way: TMaxStatLog writes a record as one LineEnding-terminated
  line and the reader loads it line by line, so a raw CR/LF inside the field
  would cut the record in half - UnescapeStatField restores no line breaks }
function EscapeStatField(const S: String): String;
var
  I: Integer;
begin
  Result:=S;
  for I:=1 to Length(Result) do
    if Result[I]<#32 then
      Result[I]:=' ';
  Result:='"'+StringReplace(Result, '"', '""', [rfReplaceAll])+'"';
end;

function UnescapeStatField(const S: String): String;
begin
  Result:=S;
  if (Length(Result)>=2) and (Result[1]='"') and (Result[Length(Result)]='"') then
    Result:=Copy(Result, 2, Length(Result)-2);
  Result:=StringReplace(Result, '""', '"', [rfReplaceAll]);
end;

function FormatStatRec(const S: String): String;
var
  Ss: TStringList;
  l: Integer;
begin
  Ss:=TStringList.Create;
  try
    l:=ExtractStrings([';'], [' '], PChar(S), Ss, True);
    if l<>8 then
      Result:=str_StatParseError
    else
      Result:=Ss[0]+'; '+BuildLink(Ss[1], UserLink(StrToInt64Def(Ss[1], 0)), fmtMarkdown)+' '+
        MarkdownEscape(UnescapeStatField(Ss[2])+' {'+UnescapeStatField(Ss[3])+
          ' '+UnescapeStatField(Ss[4])+'}')+ ' '+
        MarkdownEscape(Ss[5])+' <'+MarkdownEscape(Ss[6])+'> '+
        MarkdownEscape(UnescapeStatField(Ss[7]));
  except
    Result:=str_StatParseError
  end;
  Ss.Free;
end;

function TryStrToMonth(const S: String; out aYear, aMonth: Word): Boolean;
var
  i: SizeInt;
  wMonth, wYear: DWord;
begin
  i:=Pos('-', S);
  if (i<2) or (i>3) then
    Exit(False);
  if TryStrToDWord(LeftStr(S, i-1), wMonth) then
  begin
    aMonth:=wMonth;
    if not TryStrToDWord(RightStr(S, Length(S)-i), wYear) then
      aYear:=CurrentYear
    else
      aYear:=wYear;
  end
  else
    Exit(False);
  Result:=True;
end;

function AnsiCharToUserStatus(const StatusChar: String): TUserStatus;
var
  a: AnsiChar;
begin
  if StatusChar=EmptyStr then
    a:=UserStatusChars[usDefault]
  else
    a:=PAnsiChar(StatusChar)[0];
  case a of
    'a': Result:=usAdmin;
    'm': Result:=usModerator;
    'b': Result:=usBanned;
  else
    Result:=usDefault;
  end;
end;

{ TMaxBot }

procedure TMaxBot.SetCallbackHandlers(const Command: String;
  AValue: TCallbackEvent);
begin
  FCallbackHandlers.Items[Command]:=AValue;
end;


{ Caution! You must save this values in db or in configuration file! }
procedure TMaxBot.SetCommandReply(ASender: TObject; const ACommand: String;
  AMessage: TMaxMessageObj);
var
  S: String;
begin
  if not CurrentIsAdminUser then
    Exit;
  S:=ExtractArgPart(AMessage.Body.Text, ACommand);
  if ACommand=cmd_SetStart then
    StartText:=S
  else
    if ACommand=cmd_SetHelp then
      HelpText:=S;
  SendMessage(CurrentChatId, str_TxtRplyIsScsChngd);
end;

procedure TMaxBot.SetOnReceiveDeepLinking(AValue: TReceiveDeepLinkEvent);
begin
  if FOnReceiveDeepLinking=AValue then Exit;
  FOnReceiveDeepLinking:=AValue;
end;

procedure TMaxBot.SetPublicStat(AValue: Boolean);
begin
  if FPublicStat=AValue then Exit;
  FPublicStat:=AValue;
end;

procedure TMaxBot.BrowseStatFile(aDate: TDate; var Msg: String;
  AAttachments: TJSONArray; Offset: Integer);
var
  StatFile: TStringList;
  aFileName: String;
  i: Integer;
const
  Step=20;
begin
  aFileName:=FStatLogger.GetFileNameFromDate(aDate);
  if FileExists(aFileName) then
  begin
    StatFile:=TStringList.Create;
    try
      StatFile.LoadFromFile(AFileName);
      // MAX inline keyboards require at least one row of buttons
      if Assigned(AAttachments) and (StatFile.Count>0) then
        AAttachments.Add(MaxInlineKeyboardAttachment(
          CreateInlineKeyboardStat(aDate, StatFile.Count, Offset, Step)));
      for i:=Offset to Offset+Step-1 do
      begin
        if i>=StatFile.Count then
          Break;
        Msg+=FormatStatRec(StatFile[i])+LineEnding;
      end;
    finally
      StatFile.Free;
    end;
  end;
end;

class procedure TMaxBot.CalculateStat4Strings(aStatFile: TStrings; IDs: TIntegerHashSet; var aEvents: Integer);
var
  i: Integer;
  AnID: Int64;
begin
  for i:=aStatFile.Count-1 downto 0 do
  begin
    AnID:=StrToInt64Def(ExtractDelimited(2, aStatFile[i], [';']), 0);
    if AnID>0 then
    begin
      Inc(aEvents);
      IDs.insert(AnID);
    end;
  end;
end;

procedure TMaxBot.CalculateStat(aFromDate, aToDate: TDate; out aUsers, aEvents: Integer; aIDs: TStrings);
var
  StatFile: TStringList;
  aDate: TDate;
  aFileName: String;
  IDs: TIntegerHashSet;
  aIterator: TIntegerHashSet.TIterator;
begin
  StatFile:=TStringList.Create;
  IDs:=TIntegerHashSet.create;
  aDate:=aFromDate;
  aEvents:=0;
  try
    repeat
      aFileName:=StatLogger.GetFileNameFromDate(aDate);
      if FileExists(aFileName) then
      begin
        StatFile.LoadFromFile(AFileName);
        { Simple calculation of statistics: the number of unique users per day and
          the number of received events from users (private chats) }
        CalculateStat4Strings(StatFile, IDs, aEvents);
      end;
      aDate+=1;
    until aDate>aToDate;
    aUsers:=IDs.size;
    if Assigned(aIDs) then
    begin
      aIDs.Clear;
      aIterator:=IDs.Iterator;
      try
        if IDs.IsEmpty then
          Exit;
        repeat
          aIDs.Add(aIterator.Data.ToString);
        until not aIterator.Next;
      finally
        aIterator.Free;
      end;
    end;
  finally
    StatFile.Free;
    IDs.Free;
  end;
end;

procedure TMaxBot.DoCallbackQueryStat(ACallback: TMaxCallbackObj;
  AAsFile: Boolean);
begin
  DoStat(ExtractDelimited(2, ACallback.Payload, [' ']),
    ExtractDelimited(3, ACallback.Payload, [' ']), AAsFile);
end;

procedure TMaxBot.DoCallbackQueryGetUsers(ACallback: TMaxCallbackObj
  );
begin
  DoUsers(ExtractDelimited(2, ACallback.Payload, [' ']));
end;

procedure TMaxBot.DoGetStat(aFromDate: TDate; aToDate: TDate;
  Scroll: Boolean; Offset: Integer);
var
  Msg, SDate: String;
  SDate1: String;
  aEvents, aUsers: Integer;
  AAttachments: TJSONArray;
begin
  if not CurrentIsAdminUser then
    if not PublicStat or Scroll then
      Exit;
  if not Assigned(FStatLogger) then
    Exit;
  AAttachments:=TJSONArray.Create;
  try
    try
      if aToDate<=aFromDate then
      begin
        DateTimeToString(SDate, 'dd-mm-yyyy', aFromDate);
        Msg:='*Statistics for '+SDate+'*'+LineEnding;
      end
      else begin
        DateTimeToString(SDate, 'dd-mm-yyyy', aFromDate);
        DateTimeToString(SDate1, 'dd-mm-yyyy', aToDate);
        Msg:='*Statistics from '+SDate+' to '+SDate1+'*'+LineEnding;
      end;
      if not Scroll then
      begin
        AAttachments.Add(MaxInlineKeyboardAttachment(CreateInlineKeyboardStat(aFromDate, aToDate)));
        aUsers:=0;
        aEvents:=0;
        CalculateStat(aFromDate, aToDate, aUsers, aEvents);
        Msg+=LineEnding+'Unique users: '+IntToStr(aUsers)+', user events: '+IntToStr(aEvents);
      end
      else
        BrowseStatFile(aFromDate, Msg, AAttachments, Offset);
      EditOrSendMessage(Msg, fmtMarkdown, AAttachments, True);
    except
      on E: Exception do
        SafeErrorMessage('Error while get statistics: ['+E.ClassName+'] '+E.Message);
    end;
  finally
    AAttachments.Free;
  end;
end;

procedure TMaxBot.DoGetUsers(aFromDate: TDate; aToDate: TDate);
var
  Msg: String;
  aEvents, aUsers: Integer;
  aIDs: TStringList;
  aStream: TStringStream;
  AnUploadToken: String;
  AAttachments: TJSONArray;
begin
  if not CurrentIsAdminUser then
    Exit;
  try
    aUsers:=0;
    aEvents:=0;
    Msg:=EmptyStr;
    aIDs:=TStringList.Create;
    aStream:=nil;
    try
      CalculateStat(aFromDate, aToDate, aUsers, aEvents, aIDs);
      Msg+=LineEnding+'Unique users: '+IntToStr(aUsers)+', user events: '+IntToStr(aEvents);
      aStream:=TStringStream.Create(aIDs.Text);
      { MAX has no caption parameter for a file: the text and the file
        attachment are sent as one message }
      AnUploadToken:=UploadFile(uptFile, aStream, 'users.txt');
      if AnUploadToken<>EmptyStr then
      begin
        AAttachments:=TJSONArray.Create;
        try
          AAttachments.Add(MakeAttachmentJSON(uptFile, AnUploadToken));
          SendMessageEx(CurrentChatId, Msg, AAttachments);
        finally
          AAttachments.Free;
        end;
      end;
    finally
      aStream.Free;
      aIDs.Free;
    end;
  except
    on E: Exception do
      SafeErrorMessage('Error while get statistics: ['+E.ClassName+'] '+E.Message);
  end;
end;

procedure TMaxBot.DoGetStatMonth(aYear, aMonth: Word);
var
  Msg, SDate: String;
  aEvents, aUsers, sEvents, sUsers: Integer;
  AAttachments: TJSONArray;
  aDate: TDate;
  aToDate, aFromDate: TDate;
begin
  if not CurrentIsAdminUser then
    if not PublicStat then
      Exit;
  if not Assigned(FStatLogger) then
    Exit;
  AAttachments:=TJSONArray.Create;
  try
    try
      SDate:=aMonth.ToString+'-'+aYear.ToString;
      aToDate:=EndOfAMonth(aYear, aMonth);
      aFromDate:=StartOfAMonth(aYear, aMonth);
      Msg:='*Statistics for '+SDate+'*'+LineEnding;
      AAttachments.Add(MaxInlineKeyboardAttachment(CreateInlineKeyboardStatMonth(aFromDate)));
      aUsers:=0;
      aEvents:=0;
      CalculateStat(aFromDate, aToDate, aUsers, aEvents);
      Msg+=LineEnding+'Unique users: '+IntToStr(aUsers)+', user events: '+IntToStr(aEvents);
      aDate:=aFromDate;
      sUsers:=0;
      sEvents:=0;
      repeat
        aUsers:=0;
        aEvents:=0;
        CalculateStat(aDate, aDate,  aUsers, aEvents);
        DateTimeToString(SDate, 'dd-mm-yyyy', aDate);
        Msg+=LineEnding+mdCode+SDate+mdCode+' - _users:_ '+IntToStr(aUsers)+'_, events:_ '+IntToStr(aEvents);
        sEvents+=aEvents;
        sUsers+=aUsers;
        aDate+=1;
      until (aDate>aToDate) or (aDate>Date);
      Msg+=LineEnding+mdCode+'Summary'+mdCode+' - _users:_ '+
        IntToStr(sUsers div DaysBetween(aFromDate, aToDate))+'_, events:_ '+IntToStr(sEvents);
      EditOrSendMessage(Msg, fmtMarkdown, AAttachments, True);
    except
      on E: Exception do
        SafeErrorMessage('Error while get month statistics: ['+E.ClassName+'] '+E.Message);
    end;
  finally
    AAttachments.Free;
  end;
end;

procedure TMaxBot.DoGetStatFile(ADate: TDate);
var
  AAttachments: TJSONArray;
begin
  if not CurrentIsAdminUser then
    Exit;
  AAttachments:=MaxKeyboardAttachments(CreateInlineKeyboardStatFile);
  try
    SendStatLog(ADate, AAttachments)
  finally
    AAttachments.Free;
  end;
end;

procedure TMaxBot.DoStat(const SDate: String; const SOffset: String;
  AAsFile: Boolean);
var
  S: String;
  i: SizeInt;
  aToDate, aFromDate: TDate;
  aMonth, aYear: Word;
begin
  if not Assigned(FStatLogger) then
    Exit;
  aToDate:=0;
  S:=Trim(SDate);
  if (S=s_Today) or (S=EmptyStr) then
    aFromDate:=Date
  else
    if S=s_Yesterday then
      aFromDate:=Date-1
    else begin
      i:=Pos('/', S);
      if i>0 then
      begin
        if not (TryStrToDate(LeftStr(S, i-1), aFromDate, StatDateFormat, '-') and
          TryStrToDate(RightStr(S, Length(S)-i), aToDate, StatDateFormat, '-')) then
        begin
          SendMessage(CurrentChatId, str_EntrDtInFrmt);
          Exit;
        end
      end
      else
        if Length(S)>7 then
        begin
          if not TryStrToDate(S, aFromDate, StatDateFormat, '-') then
          begin
            SendMessage(CurrentChatId, str_EntrDtInFrmt);
            Exit;
          end
        end
        else begin
          if TryStrToMonth(S, aYear, aMonth) then
            DoGetStatMonth(aYear, aMonth)
          else begin
            SendMessage(CurrentChatId, str_EntrDtInFrmt);
          end;
          Exit;
        end;
     end;
  if SOffset=EmptyStr then
    if not AAsFile then
      DoGetStat(aFromDate, aToDate)
    else
      DoGetStatFile(aFromDate)
  else
    DoGetStat(aFromDate, aToDate, True, StrToIntDef(SOffset, 0));
end;

procedure TMaxBot.DoUsers(const SDate: String);
var
  S: String;
  i: SizeInt;
  aToDate, aFromDate: TDate;
begin
  if not Assigned(FStatLogger) then
    Exit;
  aToDate:=0;
  S:=Trim(SDate);
  if (S=s_Today) or (S=EmptyStr) then
    aFromDate:=Date
  else
    if S=s_Yesterday then
      aFromDate:=Date-1
    else begin
      i:=Pos('/', S);
      if i>0 then
      begin
        if not (TryStrToDate(LeftStr(S, i-1), aFromDate, StatDateFormat, '-') and
          TryStrToDate(RightStr(S, Length(S)-i), aToDate)) then
        begin
          SendMessage(CurrentChatId, str_EntrDtInFrmt);
          Exit;
        end
      end
      else
        if not TryStrToDate(S, aFromDate, StatDateFormat, '-') then
        begin
          SendMessage(CurrentChatId, str_EntrDtInFrmt);
          Exit;
        end
     end;
  DoGetUsers(aFromDate, aToDate)
end;

function TMaxBot.GetCallbackHandlers(const Command: String): TCallbackEvent;
begin
    Result:=FCallbackHandlers.Items[Command];
end;

function TMaxBot.GetUserStatus(ID: Int64): TUserStatus;
begin
  Result:=AnsiCharToUserStatus(FUserPermissions.Values[IntToStr(ID)]);
end;

procedure TMaxBot.SendStatLog(ADate: TDate; AAttachments: TJSONArray);
var
  AFileName: String;
  AnUploadToken: String;
  FileAttachments: TJSONArray;
begin
  if not Assigned(FStatLogger) then
    Exit;
  if ADate=0 then
    ADate:=sysutils.Date;
  AFileName:=FStatLogger.GetFileNameFromDate(ADate);
  if FileExists(AFileName) then
  begin
    AnUploadToken:=UploadFileByFileName(uptFile, AFileName);
    if AnUploadToken=EmptyStr then
      Exit; // the error is already logged
    FileAttachments:=TJSONArray.Create;
    try
      FileAttachments.Add(MakeAttachmentJSON(uptFile, AnUploadToken));
      SendMessageEx(CurrentChatId, str_SttstcsFr+DateToStr(ADate), FileAttachments);
    finally
      FileAttachments.Free;
    end;
  end
  else
    EditOrSendMessage(str_SttstcsNtFnd, fmtDefault, AAttachments, True);
end;

procedure TMaxBot.SetUserStatus(ID: Int64; AValue: TUserStatus);
var
  i: Integer;
begin
  if AValue=usDefault then
  begin
    i:= FUserPermissions.IndexOf(IntToStr(ID));
    if i >-1 then
      FUserPermissions.Delete(i)
    else
      Exit;
  end;
  FUserPermissions.Values[IntToStr(ID)]:=UserStatusChars[AValue];
end;

procedure TMaxBot.MaxStartHandler(ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
begin
  if not AMessage.Body.Text.Contains(' ') then
    SendMessage(CurrentChatId, FStartText)
  else
    DoReceiveDeepLinking(ExtractArgPart(AMessage.Body.Text, ACommand));
end;

procedure TMaxBot.MaxHelpHandler(ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
begin
  SendMessage(CurrentChatId, FHelpText);
end;

procedure TMaxBot.MaxFeedback(ASender: TObject; const ACommand: String;
  AMessage: TMaxMessageObj);
begin
  { MAX Bot API has no ForceReply: the command just sends the request text }
  SendMessage(CurrentChatId, cmd_Feedback+LineEnding+FFeedbackText);
end;

procedure TMaxBot.MaxStatHandler(ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
var
  S, O: String;
begin
  if not (PublicStat or CurrentIsAdminUser) then
    Exit;
  S:=ExtractDelimited(2, AMessage.Body.Text, [' ']);
  O:=ExtractDelimited(3, AMessage.Body.Text, [' ']);
  if S<>EmptyStr then
    DoStat(S, O)
  else
    SendStatInlineKeyboard();
end;

procedure TMaxBot.MaxStatFHandler(ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
var
  S: String;
begin
  if not CurrentIsAdminUser then
    Exit;
  S:=ExtractDelimited(2, AMessage.Body.Text, [' ']);
  if S<>EmptyStr then
     DoStat(S, '', True)
  else
    SendStatInlineKeyboard(True);
end;

{ Please define ni18n for excluding translate unit to uses and exclude standard po i18n support }
procedure TMaxBot.LangTranslate(const ALang: String);{$IFNDEF ni18n}
var
  L, F, aExeName: String;  {$ENDIF}
begin{$IFNDEF ni18n}
  if ALang=EmptyStr then
    Exit;
  if Length(ALang)>2 then
    L:=LeftStr(ALang, 2)
  else
    L:=ALang;
  aExeName:=ChangeFileExt(ExtractFileName(ParamStr(0)), '');
  F:='languages'+PathDelim+aExeName+'.%s.po';
  TranslateResourceStrings(F, L, '');{$ENDIF}
end;

procedure TMaxBot.SendStatInlineKeyboard(AAsFile: Boolean);
var
  AAttachments: TJSONArray;
begin
  AAttachments:=MaxKeyboardAttachments(CreateInlineKeyboardStat(Date, AAsFile));
  try
    SendMessageEx(CurrentChatId, str_SlctSttstcs_line1+LineEnding+str_SlctSttstcs_line2+LineEnding+
      str_SlctSttstcs_line3+LineEnding+str_SlctSttstcs_line4, AAttachments);
  finally
    AAttachments.Free;
  end;
end;

procedure TMaxBot.StatLog(const AMessage: String; UpdateType: TMaxUpdateType);
var
  EscMsg: String;
begin
  if CurrentIsAdminUser or IsBotUser(FCurrentUpdateUserId) then
    Exit;
  if AMessage=EmptyStr then
    Exit;
  if AMessage.Length>150 then
    EscMsg:='... to big text...'{ #todo : Truncate UTF8 text }
  else
    EscMsg:=AMessage;
  try
    // MAX chat ids are always positive, so there is no private chat filter here
    if Assigned(CurrentMessage) then
      StatLogger.Log([IntToStr(CurrentChatId),
        EscapeStatField('@'+CurrentMessage.Sender.Username),
        EscapeStatField(CurrentMessage.Sender.FirstName),
        EscapeStatField(CurrentMessage.Sender.LastName), '-',
        MaxUpdateTypeToStr(UpdateType), EscapeStatField(EscMsg)])
  except
    on E: Exception do
      SafeErrorMessage('Can''t write to log StatLogger. '+E.ClassName+': '+E.Message);
  end;
end;

function TMaxBot.CreateInlineKeyboardStat(aFromDate, aToDate: TDate): TJSONArray;
var
  S, PrevDate, NextDate, FromDate, ToDate, SMonth: String;
  Row: TJSONArray;
begin
  DateTimeToString(PrevDate, StatDateFormat, aFromDate-1);
  DateTimeToString(NextDate, StatDateFormat, aFromDate+1);
  DateTimeToString(FromDate, StatDateFormat, aFromDate);
  DateTimeToString(ToDate, StatDateFormat, aToDate);
  Result:=TJSONArray.Create;
  Row:=TJSONArray.Create;
  DateTimeToString(S, StatDateFormat, aFromDate);
  DateTimeToString(SMonth, StatMonthFormat, aFromDate);
  if CurrentIsAdminUser then
  begin
    MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+' '+s_Today, str_Monthly,
      s_GetStat+' '+SMonth, str_Browse, s_GetStat+' '+S+' '+'0']);
    Result.Add(Row);
    Row:=TJSONArray.Create;
    MaxCallbackButtons(Row, [str_PrevDay, s_GetStat+' '+PrevDate, str_NextDay, s_GetStat+' '+NextDate,
      str_Users, s_GetUsers+' '+FromDate+'/'+ToDate]);
    Result.Add(Row);
  end
  else begin
    MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+' '+s_Today,
      str_PrevDay, s_GetStat+' '+PrevDate, str_NextDay, s_GetStat+' '+NextDate]);
    Result.Add(Row);
  end;
end;

function TMaxBot.CreateInlineKeyboardStat(ADate: TDate; AAsFile: Boolean
  ): TJSONArray;
begin
  if AAsFile then
    Result:=CreateInlineKeyboardStatFile
  else
    Result:=CreateInlineKeyboardStat(ADate, ADate);
end;

function TMaxBot.CreateInlineKeyboardStatFile: TJSONArray;
var
  Row: TJSONArray;
begin
  Result:=TJSONArray.Create;
  Row:=TJSONArray.Create;
  MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+s_File+' '+s_Today, str_Yesterday,
    s_GetStat+s_File+' '+s_Yesterday]);
  Result.Add(Row);
end;

function TMaxBot.CreateInlineKeyboardStatMonth(ADate: TDate
  ): TJSONArray;
var
  S, PrevDate, NextDate: String;
  Row: TJSONArray;
begin
  DateTimeToString(PrevDate, StatMonthFormat, IncMonth(ADate, -1));
  DateTimeToString(NextDate, StatMonthFormat, IncMonth(ADate, 1));
  Result:=TJSONArray.Create;
  Row:=TJSONArray.Create;
  DateTimeToString(S, StatDateFormat, ADate);
  if CurrentIsAdminUser then
  begin
    MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+' '+s_Yesterday, str_Browse+' '+S, s_GetStat+' '+S+' '+'0']);
    Result.Add(Row);
    Row:=TJSONArray.Create;
    MaxCallbackButtons(Row, [str_Prev, s_GetStat+' '+PrevDate, str_Next, s_GetStat+' '+NextDate]);
    Result.Add(Row);
  end
  else begin
    MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+' '+s_Today,
      str_Prev, s_GetStat+' '+PrevDate, str_Next, s_GetStat+' '+NextDate]);
    Result.Add(Row);
  end;
end;

function TMaxBot.CreateInlineKeyboardStat(ADate: TDate; Len: Integer;
  Offset: Integer; Step: Integer): TJSONArray;
var
  PrevDate, NextDate, SDate: String;
  Row: TJSONArray;
  i: Integer;
begin
  Result:=TJSONArray.Create;
  if Len=0 then
    Exit;
  DateTimeToString(PrevDate, StatDateFormat, ADate-1);
  DateTimeToString(NextDate, StatDateFormat, ADate+1);
  Row:=TJSONArray.Create;
  DateTimeToString(SDate, StatDateFormat, ADate);
  if Offset>0 then
  begin
    MaxCallbackButton(Row, '<<', s_GetStat+' '+ SDate+' '+IntToStr(0));
    i:=Offset-Step;
    if i<0 then
      i:=0;
    MaxCallbackButton(Row, '<', s_GetStat+' '+SDate+' '+IntToStr(i));
  end;
  if Offset+Step<Len then
  begin
    MaxCallbackButton(Row, '>', s_GetStat+' '+SDate+' '+IntToStr(Offset+Step));
    MaxCallbackButton(Row, '>>', s_GetStat+' '+SDate+' '+IntToStr(Len-Step));
  end;
  Result.Add(Row);
  Row:=TJSONArray.Create;
  MaxCallbackButtons(Row, [str_Today+' 🔃', s_GetStat+' '+s_Today,
    str_PrevDay, s_GetStat+' '+PrevDate+' '+'0', str_NextDay, s_GetStat+' '+NextDate+' '+'0']);
  Result.Add(Row);
end;

procedure TMaxBot.DoReceiveDeepLinking(const AParameter: String);
begin
  if Assigned(FOnReceiveDeepLinking) then
    FOnReceiveDeepLinking(AParameter);
end;

constructor TMaxBot.Create(const AToken: String);
begin
  inherited Create(AToken);
  FStatLogger:=TMaxStatLog.Create(nil);
  FStatLogger.Active:=False;
  FStatLogger.TimeStampFormat:='hh:nn:ss';
  FUserPermissions:=TStringList.Create;
  FUserPermissions.Sorted:=True;
  FUserPermissions.Duplicates:=dupIgnore;
  FFeedbackThanks:=str_FeedbackThanks;
  FFeedbackText:=str_FeedbackText;
  CommandHandlers[cmd_Start]:=   @MaxStartHandler;
  CommandHandlers[cmd_Help]:=    @MaxHelpHandler;
  CommandHandlers[cmd_Feedback]:=@MaxFeedback;
  CommandHandlers[cmd_Stat]:=    @MaxStatHandler;
  CommandHandlers[cmd_StatF]:=   @MaxStatFHandler;
  CommandHandlers[cmd_SetStart]:= @SetCommandReply;
  CommandHandlers[cmd_SetHelp]:=  @SetCommandReply;
  FCallbackHandlers:=TCallbackHandlersMap.create;
  FPublicStat:=False;
end;

destructor TMaxBot.Destroy;
begin
  FCallbackHandlers.Free;
  FUserPermissions.Free;
  FStatLogger.Free;
  inherited Destroy;
end;

function TMaxBot.AcceptUpdate(AnUpdate: TMaxUpdateObj): Boolean;
begin
  // the hook may be called more than once per update: it reads the author
  // from AnUpdate itself, so every call sees the same id (0 - the author
  // could not be derived - passes)
  Result:=inherited AcceptUpdate(AnUpdate) and ((AnUpdate.AuthorId=0) or
    not IsBanned(AnUpdate.AuthorId));
end;

function TMaxBot.ShouldLogUpdate(AnUpdate: TMaxUpdateObj): Boolean;
begin
  Result:=inherited ShouldLogUpdate(AnUpdate) and IsSimpleUser(AnUpdate.AuthorId);
end;

procedure TMaxBot.DoReceiveUpdate(AnUpdate: TMaxUpdateObj);
begin
  if AnUpdate.UpdateType=utMessageCallback then
  begin
    // the id of the message the pressed button belongs to (for EditOrSendMessage)
    FCallbackMessageId:=AnUpdate.MessageId;
    if FCallbackMessageId=EmptyStr then
      FCallbackMessageId:=AnUpdate.Message.Body.Mid;
  end
  else
    FCallbackMessageId:=EmptyStr;
  FCurrentUpdateUserId:=AnUpdate.AuthorId;
  // the banned users and the statistics are handled by the AcceptUpdate/
  // ShouldLogUpdate hooks of the base class
  inherited DoReceiveUpdate(AnUpdate);
  // the same gate for the post-inherited work: a rejected update (a banned
  // author) must not trigger the deep linking either
  if not AcceptUpdate(AnUpdate) then
    Exit;
  if (AnUpdate.UpdateType=utBotStarted) and (AnUpdate.Payload<>EmptyStr) then
    // MAX deep linking: the start payload arrives with the bot_started update
    DoReceiveDeepLinking(AnUpdate.Payload);
end;

procedure TMaxBot.DoReceiveMessage(AMessage: TMaxMessageObj);
begin
  inherited DoReceiveMessage(AMessage);
  { MAX messages do not expose the message they reply to, so the feedback
    reply detection of the Telegram version is not available: the feedback
    text is sent by the /feedback command, SaveFeedback remains a hook for
    the descendants }
  StatLog(AMessage.Body.Text, utMessageCreated);
end;

procedure TMaxBot.DoReceiveCallback(ACallback: TMaxCallbackObj);
var
  AHandled: Boolean;
  ACommand: String;
  H: TCallbackEvent;
begin
  AHandled:=False;
  try
    if Assigned(ACallback) and (ACallback.User.UserId<>0) then
      FCurrentUpdateUserId:=ACallback.User.UserId;
    inherited DoReceiveCallback(ACallback);
    if CurrentIsAdminUser or PublicStat then
    begin
      if AnsiStartsStr(s_GetStat+' ', ACallback.Payload) then
      begin
        AHandled:=True;
        DoCallbackQueryStat(ACallback);
      end;
      if AnsiStartsStr(s_GetStat+s_File+' ', ACallback.Payload) then
      begin
        AHandled:=True;
        DoCallbackQueryStat(ACallback, True);
      end;
    end;
    if CurrentIsAdminUser and AnsiStartsStr(s_GetUsers+' ', ACallback.Payload) then
    begin
      AHandled:=True;
      DoCallbackQueryGetUsers(ACallback);
    end;
    StatLog(ACallback.Payload, utMessageCallback);
    if not AHandled then
    begin
      ACommand:=ExtractWord(1, ACallback.Payload, [' ']);
      if FCallbackHandlers.contains(ACommand) then
      begin
        H:=FCallbackHandlers.Items[ACommand];
        H(Self, ACallback);
      end;
    end;
    { MAX clients show a progress indicator until the bot answers the callback,
      so answer once here - the callback handlers do not need to do it
      themselves }
    AnswerCallbackQuery(ACallback.CallbackId, EmptyStr);
  except
    on E:Exception do
      SafeErrorMessage('Error TMaxBot.DoReceiveCallback ('+E.ClassName+': '+E.Message+')');
  end;
end;

function TMaxBot.IsAdminUser(ChatID: Int64): Boolean;
begin
  { The users from the UserStatus map plus the users registered in the base
    class by AddAdminUser }
  Result:=inherited IsAdminUser(ChatID) or
    (FUserPermissions.Values[IntToStr(ChatID)]='a') or
    (FUserPermissions.Values[IntToStr(ChatID)]='m');
end;

procedure TMaxBot.EditOrSendMessage(const AMessage: String;
  AFormat: TMaxTextFormat; AAttachments: TJSONArray; TryEdit: Boolean);
begin
  if TryEdit and (FCallbackMessageId<>EmptyStr) then
    // the keyboard can not be attached to an edited message
    EditText(CurrentChatId, FCallbackMessageId, AMessage, AFormat)
  else
    SendMessageEx(CurrentChatId, AMessage, AAttachments, True, AFormat);
end;

function TMaxBot.IsBanned(ChatID: Int64): Boolean;
begin
  Result:=FUserPermissions.Values[IntToStr(ChatID)]='b'
end;

function TMaxBot.IsBotUser(ChatID: Int64): Boolean;
begin
  Result:=FUserPermissions.Values[IntToStr(ChatID)]='r'; // robot
end;

function TMaxBot.IsSimpleUser(ChatID: Int64): Boolean;
begin
  Result:=(FUserPermissions.Values[IntToStr(ChatID)]<>'a') and
    (FUserPermissions.Values[IntToStr(ChatID)]<>'m');
end;

function TMaxBot.CurrentIsAdminUser: Boolean;
begin
  if FCurrentUpdateUserId<>0 then
    Result:=IsAdminUser(FCurrentUpdateUserId)
  else
    if Assigned(CurrentUser) then
      Result:=IsAdminUser(CurrentUser.UserId)
    else
      Result:=IsAdminUser(CurrentChatId);
end;

procedure TMaxBot.SaveFeedback(AFrom: TMaxUserObj; AMessage: String);
begin
  // to-do
end;

procedure TMaxBot.LoadUserStatusValues(AStrings: TStrings);
begin
  FUserPermissions.AddStrings(AStrings);
end;

end.
