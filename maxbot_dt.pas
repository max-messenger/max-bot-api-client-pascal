unit maxbot_dt;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, receiverthread, maxsendertypes, maxtypes, fpjson
  ;

type

  { TInlineButtonItem }
  { A button of the MAX inline keyboard: either CallbackData (a callback
    button) or Url (a link button) must be filled }

  TInlineButtonItem = class(TCollectionItem)
  private
    FCallbackData: String;
    FText: String;
    FUrl: String;
  public
    procedure AssignTo(Dest: TPersistent); override;
  published
    property Text: String read FText write FText;
    property Url: String read FUrl write FUrl;
    property CallbackData: String read FCallbackData write FCallbackData;
  end;

  TInlineButtonRowItem = class;

  { TInlineButtonCollection }

  TInlineButtonCollection = class(TOwnedCollection)
  public
    constructor Create(aOwner: TInlineButtonRowItem);
  end;

  { TInlineButtonRowItem }

  TInlineButtonRowItem = class(TCollectionItem)
  private
    FButtonRows: TInlineButtonCollection;
    procedure SetButtonRows(AValue: TInlineButtonCollection);
  public
    constructor Create(ACollection: TCollection); override;
    destructor Destroy; override;
    procedure AssignTo(Dest: TPersistent); override;
  published
    property ButtonRows: TInlineButtonCollection read FButtonRows write SetButtonRows;
  end;

  TReplyMarkupItem = class;

  { TInlineKeyboardCollection }

  TInlineKeyboardCollection = class(TOwnedCollection)
  public
    constructor Create(aOwner: TReplyMarkupItem);
  end;

  { TReplyMarkupItem }
  { MAX Bot API has only inline keyboards: the reply keyboard, ForceReply and
    RemoveKeyboard collections of the Telegram version have no MAX analog }

  TReplyMarkupItem = class(TCollectionItem)
  private
    FInlineKeyboard: TInlineKeyboardCollection;
    procedure SetInlineKeyBoard(AValue: TInlineKeyboardCollection);
  public
    constructor Create(ACollection: TCollection); override;
    destructor Destroy; override;
    procedure AssignTo(Dest: TPersistent); override;
    { Builds the inline_keyboard attachment JSON to be passed to
      TMaxSender.SendMessageEx in the attachments array.
      Returns nil when no buttons are defined (MAX requires at least one row) }
    function GetJSONReplyMarkup: TJSONObject;
  published
    property InlineKeyboard: TInlineKeyboardCollection read FInlineKeyBoard write SetInlineKeyBoard;
  end;

  TReplyMarkupItemClass = class of TReplyMarkupItem;

  TCustomDTMaxBot = class;

  { TReplyMarkupCollection }

  TReplyMarkupCollection = class(TOwnedCollection)
  private
    function GetReplyMarkup(aIndex: Integer): TReplyMarkupItem;
  public
    constructor Create(aOwner: TCustomDTMaxBot);
    property ReplyMarkups[aIndex: Integer]: TReplyMarkupItem read GetReplyMarkup;
  end;

  TDTLongPollingThread = class;

  { TMaxBotEvent is declared in maxsendertypes }

  { TCustomDTMaxBot }

  TCustomDTMaxBot = class(TComponent)
  private
    FActive: Boolean;
    FBotUsername: String;
    FLastGetMeInfo: String;
    FHelpStrings: TStringList;
    FLongPollingTime: Integer;
    FOnReceiveCallback: TCallbackEvent;
    FOnReceiveEditedMessage: TMessageEvent;
    FOnReceiveMessageUpdate: TMessageEvent;
    FOnReceiveUpdate: TOnUpdateEvent;
    FOnDisconnectReceiver: TMaxBotEvent;
    FReceiver: TDTLongPollingThread;
    FReceiverLogActive: Boolean;
    FReceiverLogDebug: Boolean;
    FReceiverLogFilename: String;
    FReplyMarkup: TReplyMarkupCollection;
    FSenderBot: TMaxSender;
    FStartStrings: TStringList;
    FSynchronizeEvents: Boolean;
    FToken: String;
    function GetHelpText: TStrings;
    function GetSenderBot: TMaxSender;
    function GetStartText: TStrings;
    procedure RaiseIfNoToken;
    procedure SetToken(AValue: String);
    procedure SetHelpText(AValue: TStrings);
    procedure SetReplyMarkups(AValue: TReplyMarkupCollection);
    procedure SetStartText(AValue: TStrings);
    procedure SetActive(AValue: Boolean);
  protected
    { The single delivery point of OnDisconnectReceiver: called from
      TDTLongPollingThread.DoTerminate (through DeliverEvent) when the
      receiver thread stops - Sender is always the component }
    procedure DoDisconnectReceiver;
  public
    procedure BotgetMe;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure StartReceiver;
    { Raises EDTMaxBot while an event delivery is still in flight: when
      called from a delivered event handler (either delivery mode), or
      concurrently from the host thread; the receiver is told to stop -
      deliveries still unwinding (the rest of the batch, the disconnect
      event) may refuse the follow-up call too. The restart must begin
      with StopReceiver: retry from the host thread until it returns
      without an exception, then StartReceiver - a lone StartReceiver is
      a silent no-op while Active stays True after a disconnect or a
      refusal }
    procedure StopReceiver;
    property SenderBot: TMaxSender read GetSenderBot;
    property Active: Boolean read FActive write SetActive;
    { It can be arrived with getMe command for example or specified manually.
      Required for some commands }
    property BotUsername: String read FBotUsername write FBotUsername;
    { Filled by BotgetMe: username, user id and first name of the bot from
      the last successful getMe. The design-time editor shows it in a dialog;
      headless hosts read it directly. LCL-free by design (td-025) }
    property LastGetMeInfo: String read FLastGetMeInfo;
    { Propagated to the lazily created SenderBot as well; a running receiver
      keeps the token it got at StartReceiver - it is applied to the receiver
      only after StopReceiver/StartReceiver }
    property Token: String read FToken write SetToken;
    property StartText: TStrings read GetStartText write SetStartText;
    property HelpText: TStrings read GetHelpText write SetHelpText;
    property LongPollingTime: Integer read FLongPollingTime write FLongPollingTime;
    { See TLongPollingThread.SynchronizeEvents for the delivery contract.
      Read at StartReceiver: changing it while Active=True requires a receiver
      restart (StopReceiver/StartReceiver) }
    property SynchronizeEvents: Boolean read FSynchronizeEvents write FSynchronizeEvents default True;
    { Unlike the receive events, which are snapshotted at StartReceiver,
      the handler is read live when the receiver thread stops - assigning
      it after StartReceiver takes effect. Assigning it from another thread
      while the receiver is stopping is not supported (no synchronization) }
    property OnDisconnectReceiver: TMaxBotEvent read FOnDisconnectReceiver write FOnDisconnectReceiver;
    property OnReceiveCallback: TCallbackEvent read FOnReceiveCallback write FOnReceiveCallback;
    property OnReceiveMessageUpdate: TMessageEvent read FOnReceiveMessageUpdate write FOnReceiveMessageUpdate;
    property OnReceiveEditedMessage: TMessageEvent read FOnReceiveEditedMessage write FOnReceiveEditedMessage;
    { This event will be triggered for every received update from the bot API
      server, after the specific events }
    property OnReceiveUpdate: TOnUpdateEvent read FOnReceiveUpdate write FOnReceiveUpdate;
    property ReceiverLogFilename: String read FReceiverLogFilename write FReceiverLogFilename;
    property ReceiverLogActive: Boolean read FReceiverLogActive write FReceiverLogActive;
    property ReceiverLogDebug: Boolean read FReceiverLogDebug write FReceiverLogDebug;
    property ReplyMarkups: TReplyMarkupCollection read FReplyMarkup write SetReplyMarkups;
  end;

  { TDTLongPollingThread }

  TDTLongPollingThread = class(TLongPollingThread)
  private
    FDTBot: TCustomDTMaxBot;
  protected
    procedure DoTerminate; override;
  public
    constructor Create(aDTMaxBot: TCustomDTMaxBot);
  end;

  { TDTMaxLongPollBot }

  TDTMaxLongPollBot = class(TCustomDTMaxBot)
  published
    property BotUsername;
    { The token is deliberately not persisted: stored False keeps it out of
      the .lfm form file and out of the binary resource the .lfm is compiled
      into, so a committed .lfm or a shipped binary never carries a working
      bot token (td-026). Enter the token at run time, as the examples do -
      a value typed in the Object Inspector lives only in the IDE session }
    property Token stored False;
    property StartText;
    property HelpText;
    property LongPollingTime;
    property SynchronizeEvents;
    property OnReceiveMessageUpdate;
    property OnReceiveCallback;
    property OnReceiveUpdate;
    property OnDisconnectReceiver;
    property ReplyMarkups;
  end;

  EDTMaxBot = class(Exception);

implementation

const
  _StartText = 'Welcome! This is start text for `/start` command.'+LineEnding+
    'You can change this text by the property `TDTMaxLongPollBot.StartText`.'+LineEnding+
    'Caution: it is markdown markup';
  _HelpText = 'This is help text for `/help` command.'+LineEnding+
    'You can change this text by the property `TDTMaxLongPollBot.HelpText`.'+LineEnding+
    'Caution: it is markdown markup';

{ TInlineButtonItem }

procedure TInlineButtonItem.AssignTo(Dest: TPersistent);
begin
  if Dest is TInlineButtonItem then
  begin
    TInlineButtonItem(Dest).Text:=Text;
    TInlineButtonItem(Dest).CallbackData:=CallbackData;
    TInlineButtonItem(Dest).Url:=Url;
  end
  else
    inherited AssignTO(Dest);
end;

{ TInlineButtonRowItem }

procedure TInlineButtonRowItem.SetButtonRows(AValue: TInlineButtonCollection);
begin
  FButtonRows.Assign(AValue);
end;

constructor TInlineButtonRowItem.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FButtonRows:=TInlineButtonCollection.Create(Self);
end;

destructor TInlineButtonRowItem.Destroy;
begin
  FButtonRows.Free;
  inherited Destroy;
end;

procedure TInlineButtonRowItem.AssignTo(Dest: TPersistent);
begin
  if Dest is TInlineButtonRowItem then
    TInlineButtonRowItem(Dest).FButtonRows.Assign(FButtonRows)
  else
    inherited AssignTO(Dest);
end;

{ TInlineButtonCollection }

constructor TInlineButtonCollection.Create(aOwner: TInlineButtonRowItem);
begin
  inherited Create(aOwner, TInlineButtonItem);
end;

{ TInlineKeyboardCollection }

constructor TInlineKeyboardCollection.Create(aOwner: TReplyMarkupItem);
begin
  inherited Create(aOwner, TInlineButtonRowItem);
end;

{ TReplyMarkupItem }

function TReplyMarkupItem.GetJSONReplyMarkup: TJSONObject;
var
  aRowItem, aButtonItem: TCollectionItem;
  aRows, aRow: TJSONArray;
  aButton, aPayload: TJSONObject;
  AnInlineButtonItem: TInlineButtonItem;
begin
  Result:=nil;
  aRows:=TJSONArray.Create;
  try
    for aRowItem in FInlineKeyBoard do
    begin
      aRow:=TJSONArray.Create;
      for aButtonItem in (aRowItem as TInlineButtonRowItem).ButtonRows do
      begin
        AnInlineButtonItem:=TInlineButtonItem(aButtonItem);
        aButton:=TJSONObject.Create;
        if AnInlineButtonItem.CallbackData<>EmptyStr then
        begin
          aButton.Add('type', 'callback');
          aButton.Add('text', AnInlineButtonItem.Text);
          aButton.Add('payload', AnInlineButtonItem.CallbackData);
        end
        else begin
          aButton.Add('type', 'link');
          aButton.Add('text', AnInlineButtonItem.Text);
          aButton.Add('url', AnInlineButtonItem.Url);
        end;
        aRow.Add(aButton);
      end;
      aRows.Add(aRow);
    end;
    if aRows.Count=0 then
      Exit; // MAX requires at least one row of buttons
    aPayload:=TJSONObject.Create;
    try
      aPayload.Add('buttons', aRows);
      aRows:=nil; // the rows are owned by the payload now
      Result:=TJSONObject.Create;
      try
        Result.Add('type', 'inline_keyboard');
        Result.Add('payload', aPayload);
        aPayload:=nil; // the payload is owned by the attachment now
      except
        Result.Free;
        raise;
      end;
    finally
      aPayload.Free;
    end;
  finally
    aRows.Free;
  end;
end;

procedure TReplyMarkupItem.SetInlineKeyBoard(AValue: TInlineKeyboardCollection);
begin
  FInlineKeyBoard.Assign(AValue);
end;

constructor TReplyMarkupItem.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FInlineKeyBoard:=TInlineKeyboardCollection.Create(Self);
end;

destructor TReplyMarkupItem.Destroy;
begin
  FInlineKeyBoard.Free;
  inherited Destroy;
end;

procedure TReplyMarkupItem.AssignTo(Dest: TPersistent);
begin
  if Dest is TReplyMarkupItem then
  begin
    TReplyMarkupItem(Dest).FInlineKeyBoard.Assign(FInlineKeyBoard);
  end
  else
    inherited AssignTO(Dest);
end;

{ TReplyMarkupCollection }

function TReplyMarkupCollection.GetReplyMarkup(aIndex: Integer): TReplyMarkupItem;
begin
  Result:=TReplyMarkupItem(Items[aIndex]);
end;

constructor TReplyMarkupCollection.Create(aOwner: TCustomDTMaxBot);
begin
  inherited Create(aOwner, TReplyMarkupItem);
end;

{ TCustomDTMaxBot }

procedure TCustomDTMaxBot.StartReceiver;
begin
  if FActive then
    Exit;
  RaiseIfNoToken;
  FReceiver:=TDTLongPollingThread.Create(Self);
  try
    FReceiver.FreeOnTerminate:=False;
    FReceiver.LongpollingTimeout:=LongPollingTime;
    FReceiver.SynchronizeEvents:=FSynchronizeEvents;
    FReceiver.Logger.FileName:=FReceiverLogFilename;
    FReceiver.Logger.Active:=FReceiverLogActive;
    FReceiver.Bot.LogDebug:=FReceiverLogDebug;
    FReceiver.Bot.Token:=FToken;
    FReceiver.Bot.StartText:=FStartStrings.Text;
    FReceiver.Bot.HelpText:=FHelpStrings.Text;
    FReceiver.OnReceiveMessageUpdate:=FOnReceiveMessageUpdate;
    FReceiver.OnReceiveEditedMessage:=FOnReceiveEditedMessage;
    FReceiver.OnReceiveCallack:=FOnReceiveCallback;
    FReceiver.OnReceiveUpdate:=FOnReceiveUpdate;
  except
    FreeAndNil(FReceiver);
    raise;
  end;
  // Only when the receiver is really about to run: a failure above (the
  // thread Create, a setting) must not leave Active=True - and the except
  // above frees the orphaned receiver, so the next attempt starts clean
  FActive:=True;
  FReceiver.Start;
end;

procedure TCustomDTMaxBot.RaiseIfNoToken;
begin
  if FToken.IsEmpty then
    raise EDTMaxBot.Create('Token for bot is not specified!');
end;

function TCustomDTMaxBot.GetHelpText: TStrings;
begin
  Result:=FHelpStrings;
end;

function TCustomDTMaxBot.GetSenderBot: TMaxSender;
begin
  if not Assigned(FSenderBot) then
    FSenderBot:=TMaxSender.Create(FToken);
  Result:=FSenderBot;
end;

function TCustomDTMaxBot.GetStartText: TStrings;
begin
  Result:=FStartStrings;
end;

procedure TCustomDTMaxBot.SetHelpText(AValue: TStrings);
begin
  FHelpStrings.Assign(AValue);
end;

procedure TCustomDTMaxBot.SetToken(AValue: String);
begin
  if FToken=AValue then Exit;
  FToken:=AValue;
  // The lazily created SenderBot must not keep a stale token
  if Assigned(FSenderBot) then
    FSenderBot.Token:=AValue;
end;

procedure TCustomDTMaxBot.SetReplyMarkups(AValue: TReplyMarkupCollection);
begin
  FReplyMarkup.Assign(AValue);
end;

procedure TCustomDTMaxBot.SetStartText(AValue: TStrings);
begin
  FStartStrings.Assign(AValue);
end;

procedure TCustomDTMaxBot.StopReceiver;
begin
  if not FActive then
    Exit;
  if FReceiver=nil then
  begin
    // Defensive: never keep FActive=True without a receiver
    FActive:=False;
    Exit;
  end;
  // A StopReceiver (or Free) call from a delivered event handler deadlocks
  // in either mode: with SynchronizeEvents=False the handler runs in the
  // receiver thread itself, so the WaitFor here would wait for it from
  // inside it; with True it runs in the main thread inside a Synchronize
  // round-trip the receiver is blocked in - the WaitFor pumps the
  // synchronize queue from then on in vain and never returns. A concurrent
  // StopReceiver (or Free) from the host thread while a delivery is still
  // unwinding triggers the same guard. Fail fast with a visible exception,
  // but tell the receiver to stop first: the follow-up StopReceiver from
  // the host thread finishes the shutdown; while a delivery is still
  // unwinding it is refused again - retry, then restart with StartReceiver
  // (a lone StartReceiver is a silent no-op while Active stays True)
  if (FReceiver=TThread.CurrentThread) or FReceiver.Delivering then
  begin
    FReceiver.Terminate;
    raise EDTMaxBot.Create('StopReceiver must not be called while an event delivery is still in flight - retry StopReceiver once the delivery has returned, then StartReceiver');
  end;
  FReceiver.Terminate;
  // See TLongPollingThread.Execute: the wait is bounded by the broker HTTP
  // timeout, not by the polling window alone
  FReceiver.WaitFor;
  FActive:=False;
  FreeAndNil(FReceiver);
end;

procedure TCustomDTMaxBot.SetActive(AValue: Boolean);
begin
  if FActive=AValue then Exit;
  if AValue then
    StartReceiver
  else
    StopReceiver;
end;

procedure TCustomDTMaxBot.DoDisconnectReceiver;
begin
  if Assigned(FOnDisconnectReceiver) then
    FOnDisconnectReceiver(Self);
end;

constructor TCustomDTMaxBot.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FStartStrings:=TStringList.Create;
  FHelpStrings:=TStringList.Create;
  FLongPollingTime:=4; // secs! 0 is not recommended
  FSynchronizeEvents:=True;
  FStartStrings.Text:=_StartText;
  FHelpStrings.Text:= _HelpText;
  FReplyMarkup:=TReplyMarkupCollection.Create(Self);
end;

destructor TCustomDTMaxBot.Destroy;
begin
  // First of all: WaitFor pumps the synchronize queue, so any still queued
  // event must fire while this component and its fields are still intact
  StopReceiver;
  FReplyMarkup.Free;
  FSenderBot.Free;
  FHelpStrings.Free;
  FStartStrings.Free;
  inherited Destroy;
end;

procedure TCustomDTMaxBot.BotgetMe;
begin
  RaiseIfNoToken;
  if SenderBot.GetMe then
  begin
    BotUsername:=FSenderBot.BotInfo.Username;
    // The design-time editor surfaces this through a dialog (dtmaxbot.pas,
    // Dialogs are LCL and stay out of this runtime unit - td-025); headless
    // hosts read the LastGetMeInfo property directly
    FLastGetMeInfo:=Format('Bot username: %s. User_id: %d. First_Name: %s', [FSenderBot.BotInfo.Username,
      FSenderBot.BotInfo.UserId, FSenderBot.BotInfo.FirstName]);
  end
  else
    raise EDTMaxBot.Create('Unsuccessful request!');
end;

{ TDTLongPollingThread }

procedure TDTLongPollingThread.DoTerminate;
begin
  inherited DoTerminate;
  if Assigned(FDTBot.FOnDisconnectReceiver) then
    // Unlike the receive events, the disconnect handler is not covered by
    // the per-update except of TMaxSender.GetUpdates: an exception out of it
    // escapes ThreadProc (DoTerminate runs outside the try..except there)
    // and kills the process - in either delivery mode. CheckSynchronize does
    // not swallow a Synchronize entry's exception, it hands it back and
    // TThread.Synchronize re-raises it right here in the receiver thread, so
    // the guard must cover both branches
    try
      DeliverEvent(@FDTBot.DoDisconnectReceiver);
    except
      on E: Exception do
        Logger.Error('[Disconnect] handler failed: '+E.ClassName+': '+E.Message);
    end;
end;

constructor TDTLongPollingThread.Create(aDTMaxBot: TCustomDTMaxBot);
begin
  FDTBot:=aDTMaxBot;
  inherited Create;
end;

end.
