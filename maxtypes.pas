unit maxtypes;

{$mode objfpc}{$H+}

{ Data types of the MAX Bot API (https://dev.max.ru/docs-api), mapped from
  the official client SDKs (max-messenger/max-bot-api-client-go). All objects
  are read-only JSON views: they wrap a parsed TJSONObject and expose typed
  accessors. The JSON object is owned by the wrapper and freed on Destroy. }

interface

uses
  Classes, SysUtils, fpJSON, jsonparser, fgl;

type

  { TMaxObj
    Root of the read-only JSON view wrappers. Schema members below were
    checked against the canonical schema (the Go client SDK model, td-015)
    and are consciously NOT mapped - no library use case needs them; add a
    typed accessor here on demand instead of exposing the raw JSON:
    - TMaxChatObj: icon, owner_id, participants, messages_count,
      chat_message_id, pinned_message
    - TMaxMessageObj: stat (views), body.markup
    - TMaxPayloadObj: code, contact_id, vcf_info, max_info, hash
    - TMaxBotInfoObj: is_official, last_activity_time }

  TMaxObj = class
  private
    fJSON: TJSONObject;
  public
    constructor Create(JSONObject: TJSONObject); virtual;  // Takes ownership of JSONObject; freed in Destroy
    destructor Destroy; override;
    class function CreateFromJSONObject(JSONObject: TJSONObject): TMaxObj;
    // Virtual so wrappers that override it keep their human-readable form
    // when dispatched through a TMaxObj reference; the base implementation
    // stays the raw JSON dump - a documented escape hatch for wrappers
    // without a human-readable form
    function AsString: String; virtual;
  end;

  { Enumerations of the MAX Bot API }

  TMaxChatType = (ctUnknown, ctDialog, ctChat, ctChannel);
  TMaxChatStatus = (csUnknown, csActive, csRemoved, csLeft, csClosed, csSuspended);
  TMaxAttachmentType = (atUnknown, atImage, atVideo, atAudio, atFile, atSticker,
    atContact, atInlineKeyboard, atLocation, atShare);
  TMaxUploadType = (uptImage, uptVideo, uptAudio, uptFile);
  TMaxMessageLinkType = (mltUnknown, mltForward, mltReply);
  TMaxTextFormat = (fmtDefault, fmtMarkdown, fmtHTML);

  TMaxUpdateType = (utUnknown,
    utMessageCreated, utMessageCallback, utMessageEdited, utMessageRemoved,
    utBotAdded, utBotRemoved, utUserAdded, utUserRemoved,
    utBotStarted, utBotStopped,
    utDialogCleared, utDialogRemoved, utDialogMuted, utDialogUnmuted,
    utChatTitleChanged,
    utCommentCreated, utCommentEdited, utCommentRemoved);

  function StrToMaxChatType(const S: String): TMaxChatType;
  function MaxChatTypeToStr(V: TMaxChatType): String;
  function StrToMaxChatStatus(const S: String): TMaxChatStatus;
  function MaxChatStatusToStr(V: TMaxChatStatus): String;
  function StrToMaxAttachmentType(const S: String): TMaxAttachmentType;
  function MaxAttachmentTypeToStr(V: TMaxAttachmentType): String;
  function StrToMaxUpdateType(const S: String): TMaxUpdateType;
  function MaxUpdateTypeToStr(V: TMaxUpdateType): String;
  function StrToMaxUploadType(const S: String): TMaxUploadType;
  function MaxUploadTypeToStr(V: TMaxUploadType): String;
  function StrToMaxMessageLinkType(const S: String): TMaxMessageLinkType;
  function MaxMessageLinkTypeToStr(V: TMaxMessageLinkType): String;
  function MaxTextFormatToStr(V: TMaxTextFormat): String;

type
  { Forward declarations }

  TMaxUserObj = class;
  TMaxUpdateObj = class;
  TMaxCommandObj = class;
  TMaxAttachmentObj = class;
  TMaxLinkedMessageObj = class;
  TMaxButtonObj = class;

  { TMaxUserObj  (model.User) }

  TMaxUserObj = class(TMaxObj)
  public
    function UserId: Int64;
    function Name: String;
    function Username: String;
    function FirstName: String;
    function LastName: String;
    function IsBot: Boolean;
    function LastActivityTime: Int64;   // milliseconds since epoch, 0 = unknown
    function AvatarURL: String;
    function FullAvatarURL: String;
    function AsString: String; override; // "Name (user_id)" or "user_id"
  end;

  { TMaxRecipientObj  (model.Recipient) }

  TMaxRecipientObj = class(TMaxObj)
  public
    function ChatId: Int64;
    function ChatType: TMaxChatType;
    function UserId: Int64;
    function PostId: String;
  end;

  { TMaxButtonObj  (model.Button, one cell of an inline keyboard row) }

  TMaxButtonObj = class(TMaxObj)
  public
    // callback | link | request_contact | request_geo_location | chat |
    // message | open_app | clipboard (open set in the schema, kept as string)
    function ButtonType: String;
    function Text: String;
    function Payload: String;           // callback/open_app/clipboard buttons
    function URL: String;               // link buttons
    function Quick: Boolean;            // request_geo_location without confirm
    function WebApp: String;            // mini app name, open_app buttons
  end;

  TMaxButtonObjList = class(specialize TFPGObjectList<TMaxButtonObj>);

  { TMaxPayloadObj  (model.Payload of an attachment) }

  TMaxPayloadObj = class(TMaxObj)
  private
    FButtons: TMaxButtonObjList;
    function GetButtons: TMaxButtonObjList;
  public
    destructor Destroy; override;
    function Token: String;
    function URL: String;
    { Flattened rows of the inline keyboard in wire order; the raw rows of
      'buttons' are folded into one list, ButtonType tells the button kinds }
    property Buttons: TMaxButtonObjList read GetButtons;
  end;

  { TMaxAttachmentObj  (model.Attachment) }

  TMaxAttachmentObj = class(TMaxObj)
  private
    FPayload: TMaxPayloadObj;
    function GetPayload: TMaxPayloadObj;
  public
    destructor Destroy; override;
    function AttachmentType: TMaxAttachmentType;
    function FileName: String;
    function FileSize: Integer;
    function Latitude: Double;
    function Longitude: Double;
    function Duration: Integer;
    property Payload: TMaxPayloadObj read GetPayload;
  end;

  TMaxAttachmentObjList = class(specialize TFPGObjectList<TMaxAttachmentObj>);

  { TMaxMessageBodyObj  (model.MessageBody) }

  TMaxMessageBodyObj = class(TMaxObj)
  private
    FAttachments: TMaxAttachmentObjList;
    function GetAttachments: TMaxAttachmentObjList;
  public
    destructor Destroy; override;
    function Mid: String;               // message id in the MAX API (string)
    function Seq: Int64;
    function Text: String;
    property Attachments: TMaxAttachmentObjList read GetAttachments;
  end;

  { TMaxLinkedMessageObj  (model.LinkedMessage: the origin of a reply/forward) }

  TMaxLinkedMessageObj = class(TMaxObj)
  public
    function LinkType: TMaxMessageLinkType;
    function Mid: String;
  end;

  { TMaxMessageObj  (model.Message) }

  TMaxMessageObj = class(TMaxObj)
  private
    FSender: TMaxUserObj;
    FRecipient: TMaxRecipientObj;
    FBody: TMaxMessageBodyObj;
    FLink: TMaxLinkedMessageObj;
    function GetSender: TMaxUserObj;
    function GetRecipient: TMaxRecipientObj;
    function GetBody: TMaxMessageBodyObj;
    function GetLink: TMaxLinkedMessageObj;
  public
    destructor Destroy; override;
    property Sender: TMaxUserObj read GetSender;
    property Recipient: TMaxRecipientObj read GetRecipient;
    property Body: TMaxMessageBodyObj read GetBody;
    { The reply/forward origin: the only way to tell a reply or a forward
      from a plain message }
    property Link: TMaxLinkedMessageObj read GetLink;
    function Timestamp: Int64;          // milliseconds since epoch
    function URL: String;
    function ChatId: Int64;             // shortcut: Recipient.ChatId
    function AsString: String; override;
  end;

  { TMaxCallbackObj  (model.Callback) }

  TMaxCallbackObj = class(TMaxObj)
  private
    FUser: TMaxUserObj;
    function GetUser: TMaxUserObj;
  public
    destructor Destroy; override;
    function Timestamp: Int64;
    function CallbackId: String;
    function Payload: String;
    property User: TMaxUserObj read GetUser;  // owned by the wrapper, freed in Destroy
  end;

  { TMaxChatObj  (model.Chat) }

  TMaxChatObj = class(TMaxObj)
  private
    FDialogWithUser: TMaxUserObj;
    function GetDialogWithUser: TMaxUserObj;
  public
    destructor Destroy; override;
    function ChatId: Int64;
    function ChatType: TMaxChatType;
    function ChatStatus: TMaxChatStatus;
    function Title: String;
    function Description: String;
    function IsPublic: Boolean;
    function Link: String;
    function ParticipantsCount: Integer;
    function LastEventTime: Int64;
    { The counterpart user of a dialog chat; stays empty for group chats
      and channels }
    property DialogWithUser: TMaxUserObj read GetDialogWithUser;
  end;

  { TMaxCommandObj  (model.BotCommand) }

  TMaxCommandObj = class(TMaxObj)
  public
    function Name: String;
    function Description: String;
  end;

  TMaxCommandObjList = class(specialize TFPGObjectList<TMaxCommandObj>);

  { TMaxBotInfoObj  (model.BotInfo, GET /me) }

  TMaxBotInfoObj = class(TMaxObj)
  private
    FCommands: TMaxCommandObjList;
    function GetCommands: TMaxCommandObjList;
  public
    destructor Destroy; override;
    function UserId: Int64;
    function FirstName: String;
    function Username: String;
    function IsBot: Boolean;
    function Description: String;
    function AvatarURL: String;
    function FullAvatarURL: String;
    property Commands: TMaxCommandObjList read GetCommands;
  end;

  { TMaxUpdateObj  (one element of the GET /updates response) }

  TMaxUpdateObj = class(TMaxObj)
  private
    FUser: TMaxUserObj;
    FMessage: TMaxMessageObj;
    FCallback: TMaxCallbackObj;
    { Memoized AuthorId; the flag covers the legitimate 0 result. Both rely
      on the zero-initialized instance - the lazy wrappers above do the same,
      the class needs no constructor of its own }
    FAuthorId: Int64;
    FAuthorIdValid: Boolean;
    function GetUser: TMaxUserObj;
    function GetMessage: TMaxMessageObj;
    function GetCallback: TMaxCallbackObj;
  public
    destructor Destroy; override;
    function UpdateType: TMaxUpdateType;
    function UpdateTypeStr: String;
    function Timestamp: Int64;
    function ChatId: Int64;
    function UserId: Int64;
    { Author of the update: the top-level user_id when present in the schema
      (only message_removed/comment_removed/bot_admin_permissions_changed have
      one), otherwise derived from callback.user.user_id,
      message.sender.user_id or user.user_id; 0 when none of them is present.
      The derived value is memoized: fJSON is immutable after Create, so
      there is nothing to invalidate (td-023) }
    function AuthorId: Int64;
    { Length of message.body.text, 0 when the update carries no message (or
      no text). WHY not Length(Message.Body.Text): the Message/Body getters
      lazily build wrapper objects and clone the message subtree (body and
      attachments included) - for a plain length read the raw JSON lookup
      via FindPath is enough (the same JStr semantics as
      TMaxMessageBodyObj.Text), nothing is created }
    function MessageBodyTextLength: Integer;
    function UserLocale: String;
    function IsChannel: Boolean;
    function Title: String;
    function MessageId: String;
    function PostId: String;
    function Payload: String;
    // Update-type specific members, flat in the update payload (the Go SDK
    // reads them in updateRaw and serves through ChatProp); 0 when absent
    // or null (inviter_id/admin_id are nullable in the schema)
    function MutedUntil: Int64;  // dialog_muted: Unix time the mute expires at
    function InviterId: Int64;   // user_added: who added the user; 0 = joined by link
    function AdminId: Int64;     // user_removed: who removed the user; 0 = left on their own
    // Payloads present only for the corresponding update types:
    property User: TMaxUserObj read GetUser;          // most updates
    property Message: TMaxMessageObj read GetMessage; // message_created/edited/callback, comment_*
    property Callback: TMaxCallbackObj read GetCallback; // message_callback
    function AsString: String; override;
  end;

  TMaxUpdateObjList = class(specialize TFPGObjectList<TMaxUpdateObj>);

  { Parse the GET /updates response: {"updates":[...], "marker":<int64|null>}.
    Creates Updates (caller frees). Returns True on a valid shape. }
  function ParseUpdateList(aJSON: TJSONData; out Updates: TMaxUpdateObjList;
    out AMarker: String): Boolean;

  { Build an attachment JSON node for a new message body:
    {"type": "<image|video|audio|file>", "payload": {"token" or "url": ...}} }
  function MakeAttachmentJSON(AnUploadType: TMaxUploadType;
    const ATokenOrURL: String): TJSONObject;

  function UploadTypeFromAttachmentType(V: TMaxAttachmentType): TMaxUploadType;

implementation

{ Safe accessors: missing, null or type-mismatched members yield defaults
  instead of raising (EJSONError, EConvertError, EInvalidCast) }

function JStr(AObj: TJSONObject; const AName: String): String;
var
  D: TJSONData;
begin
  Result:='';
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  // Numbers are accepted on purpose: the canonical marker is int64 and read via JStr
  if Assigned(D) and (D.JSONType in [jtString, jtNumber]) then
    Result:=D.AsString;
end;

function JInt(AObj: TJSONObject; const AName: String): Int64;
var
  D: TJSONData;
begin
  Result:=0;
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  if Assigned(D) and (D.JSONType in [jtNumber]) then
    Result:=D.AsInt64;
end;

function JBool(AObj: TJSONObject; const AName: String): Boolean;
var
  D: TJSONData;
begin
  Result:=False;
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  if Assigned(D) and (D.JSONType in [jtBoolean]) then
    Result:=D.AsBoolean;
end;

function JFloat(AObj: TJSONObject; const AName: String): Double;
var
  D: TJSONData;
begin
  Result:=0;
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  if Assigned(D) and (D.JSONType in [jtNumber]) then
    Result:=D.AsFloat;
end;

{ Typed lookups: nil when the member is missing or of another JSON type }
{ JObj: a TJSONObject member; JArr: a TJSONArray member }

function JObj(AObj: TJSONObject; const AName: String): TJSONObject;
var
  D: TJSONData;
begin
  Result:=nil;
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  if D is TJSONObject then
    Result:=TJSONObject(D);
end;

function JArr(AObj: TJSONObject; const AName: String): TJSONArray;
var
  D: TJSONData;
begin
  Result:=nil;
  if AObj=nil then Exit;
  D:=AObj.FindPath(AName);
  if D is TJSONArray then
    Result:=TJSONArray(D);
end;

function StrToMaxChatType(const S: String): TMaxChatType;
begin
  if S='dialog' then Exit(ctDialog);
  if S='chat' then Exit(ctChat);
  if S='channel' then Exit(ctChannel);
  Result:=ctUnknown;
end;

function MaxChatTypeToStr(V: TMaxChatType): String;
begin
  case V of
    ctDialog:  Result:='dialog';
    ctChat:    Result:='chat';
    ctChannel: Result:='channel';
  else
    Result:='';
  end;
end;

function StrToMaxChatStatus(const S: String): TMaxChatStatus;
begin
  if S='active' then Exit(csActive);
  if S='removed' then Exit(csRemoved);
  if S='left' then Exit(csLeft);
  if S='closed' then Exit(csClosed);
  if S='suspended' then Exit(csSuspended);
  Result:=csUnknown;
end;

function MaxChatStatusToStr(V: TMaxChatStatus): String;
begin
  case V of
    csActive:    Result:='active';
    csRemoved:   Result:='removed';
    csLeft:      Result:='left';
    csClosed:    Result:='closed';
    csSuspended: Result:='suspended';
  else
    Result:='';
  end;
end;

function StrToMaxAttachmentType(const S: String): TMaxAttachmentType;
begin
  if S='image' then Exit(atImage);
  if S='video' then Exit(atVideo);
  if S='audio' then Exit(atAudio);
  if S='file' then Exit(atFile);
  if S='sticker' then Exit(atSticker);
  if S='contact' then Exit(atContact);
  if S='inline_keyboard' then Exit(atInlineKeyboard);
  if S='location' then Exit(atLocation);
  if S='share' then Exit(atShare);
  Result:=atUnknown;
end;

function MaxAttachmentTypeToStr(V: TMaxAttachmentType): String;
begin
  case V of
    atImage:          Result:='image';
    atVideo:          Result:='video';
    atAudio:          Result:='audio';
    atFile:           Result:='file';
    atSticker:        Result:='sticker';
    atContact:        Result:='contact';
    atInlineKeyboard: Result:='inline_keyboard';
    atLocation:       Result:='location';
    atShare:          Result:='share';
  else
    Result:='';
  end;
end;

function StrToMaxUpdateType(const S: String): TMaxUpdateType;
begin
  if S='message_created' then Exit(utMessageCreated);
  if S='message_callback' then Exit(utMessageCallback);
  if S='message_edited' then Exit(utMessageEdited);
  if S='message_removed' then Exit(utMessageRemoved);
  if S='bot_added' then Exit(utBotAdded);
  if S='bot_removed' then Exit(utBotRemoved);
  if S='user_added' then Exit(utUserAdded);
  if S='user_removed' then Exit(utUserRemoved);
  if S='bot_started' then Exit(utBotStarted);
  if S='bot_stopped' then Exit(utBotStopped);
  if S='dialog_cleared' then Exit(utDialogCleared);
  if S='dialog_removed' then Exit(utDialogRemoved);
  if S='dialog_muted' then Exit(utDialogMuted);
  if S='dialog_unmuted' then Exit(utDialogUnmuted);
  if S='chat_title_changed' then Exit(utChatTitleChanged);
  if S='comment_created' then Exit(utCommentCreated);
  if S='comment_edited' then Exit(utCommentEdited);
  if S='comment_removed' then Exit(utCommentRemoved);
  Result:=utUnknown;
end;

function MaxUpdateTypeToStr(V: TMaxUpdateType): String;
begin
  case V of
    utMessageCreated:    Result:='message_created';
    utMessageCallback:   Result:='message_callback';
    utMessageEdited:     Result:='message_edited';
    utMessageRemoved:    Result:='message_removed';
    utBotAdded:          Result:='bot_added';
    utBotRemoved:        Result:='bot_removed';
    utUserAdded:         Result:='user_added';
    utUserRemoved:       Result:='user_removed';
    utBotStarted:        Result:='bot_started';
    utBotStopped:        Result:='bot_stopped';
    utDialogCleared:     Result:='dialog_cleared';
    utDialogRemoved:     Result:='dialog_removed';
    utDialogMuted:       Result:='dialog_muted';
    utDialogUnmuted:     Result:='dialog_unmuted';
    utChatTitleChanged:  Result:='chat_title_changed';
    utCommentCreated:    Result:='comment_created';
    utCommentEdited:     Result:='comment_edited';
    utCommentRemoved:    Result:='comment_removed';
  else
    Result:='';
  end;
end;

function StrToMaxUploadType(const S: String): TMaxUploadType;
begin
  if S='image' then Exit(uptImage);
  if S='video' then Exit(uptVideo);
  if S='audio' then Exit(uptAudio);
  if S='file' then Exit(uptFile);
  Result:=uptFile;
end;

function MaxUploadTypeToStr(V: TMaxUploadType): String;
begin
  case V of
    uptImage: Result:='image';
    uptVideo: Result:='video';
    uptAudio: Result:='audio';
    uptFile:  Result:='file';
  else
    Result:='file';
  end;
end;

function StrToMaxMessageLinkType(const S: String): TMaxMessageLinkType;
begin
  if S='forward' then Exit(mltForward);
  if S='reply' then Exit(mltReply);
  Result:=mltUnknown;
end;

function MaxMessageLinkTypeToStr(V: TMaxMessageLinkType): String;
begin
  case V of
    mltForward: Result:='forward';
    mltReply:   Result:='reply';
  else
    Result:='';
  end;
end;

function MaxTextFormatToStr(V: TMaxTextFormat): String;
begin
  case V of
    fmtMarkdown: Result:='markdown';
    fmtHTML:     Result:='html';
  else
    Result:='';
  end;
end;

function UploadTypeFromAttachmentType(V: TMaxAttachmentType): TMaxUploadType;
begin
  case V of
    atImage: Result:=uptImage;
    atVideo: Result:=uptVideo;
    atAudio: Result:=uptAudio;
  else
    Result:=uptFile;
  end;
end;

function MakeAttachmentJSON(AnUploadType: TMaxUploadType;
  const ATokenOrURL: String): TJSONObject;
var
  Payload: TJSONObject;
begin
  Payload:=TJSONObject.Create;
  // An upload returns a token; a URL is used to share an existing media
  if (ATokenOrURL<>'') and (Pos('://', ATokenOrURL)>0) then
    Payload.Add('url', ATokenOrURL)
  else
    Payload.Add('token', ATokenOrURL);
  Result:=TJSONObject.Create;
  Result.Add('type', MaxUploadTypeToStr(AnUploadType));
  Result.Add('payload', Payload);
end;

{ TMaxObj }

constructor TMaxObj.Create(JSONObject: TJSONObject);
begin
  inherited Create;
  if JSONObject=nil then
    raise Exception.Create('TMaxObj: JSON object is required');
  fJSON:=JSONObject;
end;

destructor TMaxObj.Destroy;
begin
  FreeAndNil(fJSON);
  inherited Destroy;
end;

class function TMaxObj.CreateFromJSONObject(JSONObject: TJSONObject): TMaxObj;
begin
  Result:=Self.Create(JSONObject);
end;

function TMaxObj.AsString: String;
begin
  if Assigned(fJSON) then
    Result:=fJSON.AsJSON
  else
    Result:='';
end;

{ TMaxUserObj }

function TMaxUserObj.UserId: Int64;
begin
  Result:=JInt(fJSON, 'user_id');
end;

function TMaxUserObj.Name: String;
begin
  Result:=JStr(fJSON, 'name');
end;

function TMaxUserObj.Username: String;
begin
  Result:=JStr(fJSON, 'username');
end;

function TMaxUserObj.FirstName: String;
begin
  Result:=JStr(fJSON, 'first_name');
end;

function TMaxUserObj.LastName: String;
begin
  Result:=JStr(fJSON, 'last_name');
end;

function TMaxUserObj.IsBot: Boolean;
begin
  Result:=JBool(fJSON, 'is_bot');
end;

function TMaxUserObj.LastActivityTime: Int64;
begin
  Result:=JInt(fJSON, 'last_activity_time');
end;

function TMaxUserObj.AvatarURL: String;
begin
  Result:=JStr(fJSON, 'avatar_url');
end;

function TMaxUserObj.FullAvatarURL: String;
begin
  Result:=JStr(fJSON, 'full_avatar_url');
end;

function TMaxUserObj.AsString: String;
var
  N: String;
begin
  N:=Name;
  if N=EmptyStr then
    N:=Trim(FirstName+' '+LastName);
  if N<>EmptyStr then
    Result:=Format('%s (%d)', [N, UserId])
  else
    Result:=IntToStr(UserId);
end;

{ TMaxRecipientObj }

function TMaxRecipientObj.ChatId: Int64;
begin
  Result:=JInt(fJSON, 'chat_id');
end;

function TMaxRecipientObj.ChatType: TMaxChatType;
begin
  Result:=StrToMaxChatType(JStr(fJSON, 'chat_type'));
end;

function TMaxRecipientObj.UserId: Int64;
begin
  Result:=JInt(fJSON, 'user_id');
end;

function TMaxRecipientObj.PostId: String;
begin
  Result:=JStr(fJSON, 'post_id');
end;

{ TMaxButtonObj }

function TMaxButtonObj.ButtonType: String;
begin
  Result:=JStr(fJSON, 'type');
end;

function TMaxButtonObj.Text: String;
begin
  Result:=JStr(fJSON, 'text');
end;

function TMaxButtonObj.Payload: String;
begin
  Result:=JStr(fJSON, 'payload');
end;

function TMaxButtonObj.URL: String;
begin
  Result:=JStr(fJSON, 'url');
end;

function TMaxButtonObj.Quick: Boolean;
begin
  Result:=JBool(fJSON, 'quick');
end;

function TMaxButtonObj.WebApp: String;
begin
  Result:=JStr(fJSON, 'web_app');
end;

{ TMaxPayloadObj }

function TMaxPayloadObj.Token: String;
begin
  Result:=JStr(fJSON, 'token');
end;

function TMaxPayloadObj.URL: String;
begin
  Result:=JStr(fJSON, 'url');
end;

destructor TMaxPayloadObj.Destroy;
begin
  FreeAndNil(FButtons);
  inherited Destroy;
end;

function TMaxPayloadObj.GetButtons: TMaxButtonObjList;
var
  Rows: TJSONArray;
  Row: TJSONArray;
  I, J: Integer;
begin
  if FButtons=nil then
  begin
    FButtons:=TMaxButtonObjList.Create;
    // 'buttons' is a two-dimensional array (rows of buttons) in the wire
    // format; the typed list flattens it, keeping the wire order
    Rows:=JArr(fJSON, 'buttons');
    if Assigned(Rows) then
      for I:=0 to Rows.Count-1 do
        if Rows.Items[I] is TJSONArray then
        begin
          Row:=TJSONArray(Rows.Items[I]);
          for J:=0 to Row.Count-1 do
            if Row.Items[J] is TJSONObject then
              FButtons.Add(TMaxButtonObj.Create(TJSONObject(Row.Items[J].Clone)));
        end;
  end;
  Result:=FButtons;
end;

{ TMaxAttachmentObj }

destructor TMaxAttachmentObj.Destroy;
begin
  FreeAndNil(FPayload);
  inherited Destroy;
end;

function TMaxAttachmentObj.GetPayload: TMaxPayloadObj;
var
  P: TJSONObject;
begin
  if FPayload=nil then
  begin
    P:=JObj(fJSON, 'payload');
    if P<>nil then
      FPayload:=TMaxPayloadObj.Create(TJSONObject(P.Clone))
    else
      FPayload:=TMaxPayloadObj.Create(TJSONObject.Create);
  end;
  Result:=FPayload;
end;

function TMaxAttachmentObj.AttachmentType: TMaxAttachmentType;
begin
  Result:=StrToMaxAttachmentType(JStr(fJSON, 'type'));
end;

function TMaxAttachmentObj.FileName: String;
begin
  Result:=JStr(fJSON, 'filename');
end;

function TMaxAttachmentObj.FileSize: Integer;
begin
  Result:=JInt(fJSON, 'size');
end;

function TMaxAttachmentObj.Latitude: Double;
begin
  Result:=JFloat(fJSON, 'latitude');
end;

function TMaxAttachmentObj.Longitude: Double;
begin
  Result:=JFloat(fJSON, 'longitude');
end;

function TMaxAttachmentObj.Duration: Integer;
begin
  Result:=JInt(fJSON, 'duration');
end;

{ TMaxMessageBodyObj }

destructor TMaxMessageBodyObj.Destroy;
begin
  FreeAndNil(FAttachments);
  inherited Destroy;
end;

function TMaxMessageBodyObj.GetAttachments: TMaxAttachmentObjList;
var
  Arr: TJSONArray;
  I: Integer;
begin
  if FAttachments=nil then
  begin
    FAttachments:=TMaxAttachmentObjList.Create;
    Arr:=JArr(fJSON, 'attachments');
    if Assigned(Arr) then
      for I:=0 to Arr.Count-1 do
        if Arr.Items[I] is TJSONObject then
          FAttachments.Add(TMaxAttachmentObj.Create(TJSONObject(Arr.Items[I].Clone)));
  end;
  Result:=FAttachments;
end;

function TMaxMessageBodyObj.Mid: String;
begin
  Result:=JStr(fJSON, 'mid');
end;

function TMaxMessageBodyObj.Seq: Int64;
begin
  Result:=JInt(fJSON, 'seq');
end;

function TMaxMessageBodyObj.Text: String;
begin
  Result:=JStr(fJSON, 'text');
end;

{ TMaxLinkedMessageObj }

function TMaxLinkedMessageObj.LinkType: TMaxMessageLinkType;
begin
  Result:=StrToMaxMessageLinkType(JStr(fJSON, 'type'));
end;

function TMaxLinkedMessageObj.Mid: String;
begin
  Result:=JStr(fJSON, 'mid');
end;

{ TMaxMessageObj }

destructor TMaxMessageObj.Destroy;
begin
  FreeAndNil(FSender);
  FreeAndNil(FRecipient);
  FreeAndNil(FBody);
  FreeAndNil(FLink);
  inherited Destroy;
end;

function TMaxMessageObj.GetSender: TMaxUserObj;
var
  O: TJSONObject;
begin
  if FSender=nil then
  begin
    O:=JObj(fJSON, 'sender');
    if O<>nil then
      FSender:=TMaxUserObj.Create(TJSONObject(O.Clone))
    else
      FSender:=TMaxUserObj.Create(TJSONObject.Create);
  end;
  Result:=FSender;
end;

function TMaxMessageObj.GetRecipient: TMaxRecipientObj;
var
  O: TJSONObject;
begin
  if FRecipient=nil then
  begin
    O:=JObj(fJSON, 'recipient');
    if O<>nil then
      FRecipient:=TMaxRecipientObj.Create(TJSONObject(O.Clone))
    else
      FRecipient:=TMaxRecipientObj.Create(TJSONObject.Create);
  end;
  Result:=FRecipient;
end;

function TMaxMessageObj.GetBody: TMaxMessageBodyObj;
var
  O: TJSONObject;
begin
  if FBody=nil then
  begin
    O:=JObj(fJSON, 'body');
    if O<>nil then
      FBody:=TMaxMessageBodyObj.Create(TJSONObject(O.Clone))
    else
      FBody:=TMaxMessageBodyObj.Create(TJSONObject.Create);
  end;
  Result:=FBody;
end;

function TMaxMessageObj.GetLink: TMaxLinkedMessageObj;
var
  O: TJSONObject;
begin
  if FLink=nil then
  begin
    O:=JObj(fJSON, 'link');
    if O<>nil then
      FLink:=TMaxLinkedMessageObj.Create(TJSONObject(O.Clone))
    else
      FLink:=TMaxLinkedMessageObj.Create(TJSONObject.Create);
  end;
  Result:=FLink;
end;

function TMaxMessageObj.Timestamp: Int64;
begin
  Result:=JInt(fJSON, 'timestamp');
end;

function TMaxMessageObj.URL: String;
begin
  Result:=JStr(fJSON, 'url');
end;

function TMaxMessageObj.ChatId: Int64;
begin
  Result:=Recipient.ChatId;
end;

function TMaxMessageObj.AsString: String;
begin
  Result:=Format('message %s: %s', [Body.Mid, Body.Text]);
end;

{ TMaxCallbackObj }

destructor TMaxCallbackObj.Destroy;
begin
  FreeAndNil(FUser);
  inherited Destroy;
end;

function TMaxCallbackObj.Timestamp: Int64;
begin
  Result:=JInt(fJSON, 'timestamp');
end;

function TMaxCallbackObj.CallbackId: String;
begin
  Result:=JStr(fJSON, 'callback_id');
end;

function TMaxCallbackObj.Payload: String;
begin
  Result:=JStr(fJSON, 'payload');
end;

function TMaxCallbackObj.GetUser: TMaxUserObj;
var
  O: TJSONObject;
begin
  if FUser=nil then
  begin
    O:=JObj(fJSON, 'user');
    if O<>nil then
      FUser:=TMaxUserObj.Create(TJSONObject(O.Clone))
    else
      FUser:=TMaxUserObj.Create(TJSONObject.Create);
  end;
  Result:=FUser;
end;

{ TMaxChatObj }

destructor TMaxChatObj.Destroy;
begin
  FreeAndNil(FDialogWithUser);
  inherited Destroy;
end;

function TMaxChatObj.GetDialogWithUser: TMaxUserObj;
var
  O: TJSONObject;
begin
  if FDialogWithUser=nil then
  begin
    O:=JObj(fJSON, 'dialog_with_user');
    if O<>nil then
      FDialogWithUser:=TMaxUserObj.Create(TJSONObject(O.Clone))
    else
      FDialogWithUser:=TMaxUserObj.Create(TJSONObject.Create);
  end;
  Result:=FDialogWithUser;
end;

function TMaxChatObj.ChatId: Int64;
begin
  Result:=JInt(fJSON, 'chat_id');
end;

function TMaxChatObj.ChatType: TMaxChatType;
begin
  Result:=StrToMaxChatType(JStr(fJSON, 'type'));
end;

function TMaxChatObj.ChatStatus: TMaxChatStatus;
begin
  Result:=StrToMaxChatStatus(JStr(fJSON, 'status'));
end;

function TMaxChatObj.Title: String;
begin
  Result:=JStr(fJSON, 'title');
end;

function TMaxChatObj.Description: String;
begin
  Result:=JStr(fJSON, 'description');
end;

function TMaxChatObj.IsPublic: Boolean;
begin
  Result:=JBool(fJSON, 'is_public');
end;

function TMaxChatObj.Link: String;
begin
  Result:=JStr(fJSON, 'link');
end;

function TMaxChatObj.ParticipantsCount: Integer;
begin
  Result:=JInt(fJSON, 'participants_count');
end;

function TMaxChatObj.LastEventTime: Int64;
begin
  Result:=JInt(fJSON, 'last_event_time');
end;

{ TMaxCommandObj }

function TMaxCommandObj.Name: String;
begin
  Result:=JStr(fJSON, 'name');
end;

function TMaxCommandObj.Description: String;
begin
  Result:=JStr(fJSON, 'description');
end;

{ TMaxBotInfoObj }

destructor TMaxBotInfoObj.Destroy;
begin
  FreeAndNil(FCommands);
  inherited Destroy;
end;

function TMaxBotInfoObj.GetCommands: TMaxCommandObjList;
var
  Arr: TJSONArray;
  I: Integer;
begin
  if FCommands=nil then
  begin
    FCommands:=TMaxCommandObjList.Create;
    Arr:=JArr(fJSON, 'commands');
    if Assigned(Arr) then
      for I:=0 to Arr.Count-1 do
        if Arr.Items[I] is TJSONObject then
          FCommands.Add(TMaxCommandObj.Create(TJSONObject(Arr.Items[I].Clone)));
  end;
  Result:=FCommands;
end;

function TMaxBotInfoObj.UserId: Int64;
begin
  Result:=JInt(fJSON, 'user_id');
end;

function TMaxBotInfoObj.FirstName: String;
begin
  Result:=JStr(fJSON, 'first_name');
end;

function TMaxBotInfoObj.Username: String;
begin
  Result:=JStr(fJSON, 'username');
end;

function TMaxBotInfoObj.IsBot: Boolean;
begin
  Result:=JBool(fJSON, 'is_bot');
end;

function TMaxBotInfoObj.Description: String;
begin
  Result:=JStr(fJSON, 'description');
end;

function TMaxBotInfoObj.AvatarURL: String;
begin
  Result:=JStr(fJSON, 'avatar_url');
end;

function TMaxBotInfoObj.FullAvatarURL: String;
begin
  Result:=JStr(fJSON, 'full_avatar_url');
end;

{ TMaxUpdateObj }

destructor TMaxUpdateObj.Destroy;
begin
  FreeAndNil(FUser);
  FreeAndNil(FMessage);
  FreeAndNil(FCallback);
  inherited Destroy;
end;

function TMaxUpdateObj.GetUser: TMaxUserObj;
var
  O: TJSONObject;
begin
  if FUser=nil then
  begin
    O:=JObj(fJSON, 'user');
    if O<>nil then
      FUser:=TMaxUserObj.Create(TJSONObject(O.Clone))
    else
      FUser:=TMaxUserObj.Create(TJSONObject.Create);
  end;
  Result:=FUser;
end;

function TMaxUpdateObj.GetMessage: TMaxMessageObj;
var
  O: TJSONObject;
begin
  if FMessage=nil then
  begin
    O:=JObj(fJSON, 'message');
    if O<>nil then
      FMessage:=TMaxMessageObj.Create(TJSONObject(O.Clone))
    else
      FMessage:=TMaxMessageObj.Create(TJSONObject.Create);
  end;
  Result:=FMessage;
end;

function TMaxUpdateObj.GetCallback: TMaxCallbackObj;
var
  O: TJSONObject;
begin
  if FCallback=nil then
  begin
    O:=JObj(fJSON, 'callback');
    if O<>nil then
      FCallback:=TMaxCallbackObj.Create(TJSONObject(O.Clone))
    else
      FCallback:=TMaxCallbackObj.Create(TJSONObject.Create);
  end;
  Result:=FCallback;
end;

function TMaxUpdateObj.UpdateType: TMaxUpdateType;
begin
  Result:=StrToMaxUpdateType(JStr(fJSON, 'update_type'));
end;

function TMaxUpdateObj.UpdateTypeStr: String;
begin
  Result:=JStr(fJSON, 'update_type');
end;

function TMaxUpdateObj.Timestamp: Int64;
begin
  Result:=JInt(fJSON, 'timestamp');
end;

function TMaxUpdateObj.ChatId: Int64;
begin
  Result:=JInt(fJSON, 'chat_id');
end;

function TMaxUpdateObj.UserId: Int64;
begin
  Result:=JInt(fJSON, 'user_id');
end;

function TMaxUpdateObj.AuthorId: Int64;
begin
  { Derived from the raw JSON (the memoized Message/Callback wrappers clone,
    so they are not read here); a top-level user_id is absent on
    message_created/edited/callback/bot_started. callback.user.user_id
    precedes message.sender.user_id: for message_callback the message is the
    original message with the inline keyboard (its sender is the bot), while
    callback.user is the user who pressed the button }
  if not FAuthorIdValid then
  begin
    FAuthorId:=JInt(fJSON, 'user_id');
    if FAuthorId=0 then
      FAuthorId:=JInt(fJSON, 'callback.user.user_id');
    if FAuthorId=0 then
      FAuthorId:=JInt(fJSON, 'message.sender.user_id');
    if FAuthorId=0 then
      FAuthorId:=JInt(fJSON, 'user.user_id');
    FAuthorIdValid:=True;
  end;
  Result:=FAuthorId;
end;

function TMaxUpdateObj.MessageBodyTextLength: Integer;
begin
  Result:=Length(JStr(fJSON, 'message.body.text'));
end;

function TMaxUpdateObj.UserLocale: String;
begin
  Result:=JStr(fJSON, 'user_locale');
end;

function TMaxUpdateObj.IsChannel: Boolean;
begin
  Result:=JBool(fJSON, 'is_channel');
end;

function TMaxUpdateObj.Title: String;
begin
  Result:=JStr(fJSON, 'title');
end;

function TMaxUpdateObj.MessageId: String;
begin
  Result:=JStr(fJSON, 'message_id');
end;

function TMaxUpdateObj.PostId: String;
begin
  Result:=JStr(fJSON, 'post_id');
end;

function TMaxUpdateObj.Payload: String;
begin
  Result:=JStr(fJSON, 'payload');
end;

function TMaxUpdateObj.MutedUntil: Int64;
begin
  Result:=JInt(fJSON, 'muted_until');
end;

function TMaxUpdateObj.InviterId: Int64;
begin
  Result:=JInt(fJSON, 'inviter_id');
end;

function TMaxUpdateObj.AdminId: Int64;
begin
  Result:=JInt(fJSON, 'admin_id');
end;

function TMaxUpdateObj.AsString: String;
begin
  // The Message property lazily creates an empty wrapper for non-message
  // updates ("bot_started: message : "), so the message tail is added only
  // when the JSON actually carries a message node; the ids every update
  // carries at the top level close the line (td-016)
  if JObj(fJSON, 'message')<>nil then
    Result:=Format('%s: %s', [UpdateTypeStr, Message.AsString])
  else
    Result:=UpdateTypeStr;
  Result:=Format('%s (chat_id=%d, user_id=%d)', [Result, ChatId, UserId]);
end;

{ Update list parsing }

function ParseUpdateList(aJSON: TJSONData; out Updates: TMaxUpdateObjList;
  out AMarker: String): Boolean;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Updates:=nil;
  AMarker:='';
  Result:=False;
  if not (aJSON is TJSONObject) then
    Exit;
  Root:=TJSONObject(aJSON);
  Updates:=TMaxUpdateObjList.Create;
  Arr:=JArr(Root, 'updates');
  if Assigned(Arr) then
    for I:=0 to Arr.Count-1 do
      if Arr.Items[I] is TJSONObject then
        Updates.Add(TMaxUpdateObj.Create(TJSONObject(Arr.Items[I].Clone)));
  // The canonical marker is int64 and nullable: JStr reads both forms and
  // yields the default on a missing or null marker
  AMarker:=JStr(Root, 'marker');
  Result:=True;
end;

end.
