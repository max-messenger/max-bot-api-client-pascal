unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, maxtypes, maxsendertypes, maxbot_dt
  ;

type

  { TForm1 }

  TForm1 = class(TForm)
    BtnStart: TButton;
    BtnStop: TButton;
    DTLongPolBot1: TDTMaxLongPollBot;
    GroupBox1: TGroupBox;
    Label1: TLabel;
    Label2: TLabel;
    Memo1: TMemo;
    procedure BtnStartClick({%H-}Sender: TObject);
    procedure BtnStopClick({%H-}Sender: TObject);
    procedure DTLongPolBot1DisconnectReceiver({%H-}aSender: TCustomDTMaxBot);
    procedure DTLongPollBot1ReceiveMessageUpdate(ASender: TObject; AMessage: TMaxMessageObj);
  private

  public

  end;

var
  Form1: TForm1;

implementation

uses
  maxutils, fpjson
  ;

{$R *.lfm}

{ TForm1 }

procedure TForm1.BtnStartClick(Sender: TObject);
begin
  BtnStart.Enabled:=False;
  try
    // After a disconnect Active stays True, StartReceiver alone is a
    // silent no-op; StopReceiver is a no-op when already idle
    DTLongPolBot1.StopReceiver;
    DTLongPolBot1.StartReceiver;
  except
    on E: EDTMaxBot do
    begin
      BtnStart.Enabled:=True;
      BtnStop.Enabled:=False;
      raise;
    end;
  end;
  BtnStop.Enabled:=True;
end;

procedure TForm1.BtnStopClick(Sender: TObject);
begin
  BtnStop.Enabled:=False;
  DTLongPolBot1.StopReceiver;
end;

procedure TForm1.DTLongPolBot1DisconnectReceiver(aSender: TCustomDTMaxBot);
begin
  BtnStart.Enabled:=True;
end;

procedure TForm1.DTLongPollBot1ReceiveMessageUpdate(ASender: TObject; AMessage: TMaxMessageObj);
var
  aMsg: String;
  AKeyboard: TJSONObject;
  AAttachments: TJSONArray;
begin
  aMsg:=EmptyStr;
  AAttachments:=TJSONArray.Create;
  try
    { MAX Bot API has only inline keyboards: the /replykeyboard, /forcereply
      and /removekeyboard commands of the Telegram demo have no MAX analog }
    if AMessage.Body.Text='/inlinekeyboard' then
    begin
      if DTLongPolBot1.ReplyMarkups.Count>=1 then
      begin
        AKeyboard:=DTLongPolBot1.ReplyMarkups.ReplyMarkups[0].GetJSONReplyMarkup;
        if Assigned(AKeyboard) then
        begin
          AAttachments.Add(AKeyboard); // the array owns the attachment now
          aMsg:=Format('Hi, %s', [CaptionFromUser(AMessage.Sender)])+'!'+LineEnding+
            'This message with inline keyboard';
        end;
      end;
    end;
    if aMsg=EmptyStr then
      aMsg:=Format('You sent the text: %s', [AMessage.Body.Text]);
    TMaxBotSendMessage(DTLongPolBot1.Token, TMaxSender(ASender).CurrentChatId, aMsg, AAttachments);
  finally
    AAttachments.Free;
    Memo1.Lines.Add(aMsg);
  end;
end;

end.
