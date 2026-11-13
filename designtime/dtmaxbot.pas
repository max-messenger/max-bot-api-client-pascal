unit DTMaxBot;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Dialogs, maxbot_dt, ComponentEditors
  ;

type

  { TLPMaxBotEditor }

  TLPMaxBotEditor = class(TComponentEditor)
  private
    procedure getMe;
  public
    procedure ExecuteVerb(Index: Integer); override;
    function GetVerb(Index: Integer): string; override;
    function GetVerbCount: Integer; override;
  end;

procedure Register;

implementation

uses
  LResources
  ;

procedure Register;
begin
  {$I dtmaxbot_icon.lrs}
  RegisterComponentEditor(TDTMaxLongPollBot, TLPMaxBotEditor);
  RegisterComponents('Misc', [TDTMaxLongPollBot]);
end;

{ TLPMaxBotEditor }

procedure TLPMaxBotEditor.getMe;
begin
  (Component as TDTMaxLongPollBot).BotgetMe;
  // The runtime unit is LCL-free (td-025): the result surfaces through
  // LastGetMeInfo and the dialog lives here, in the design-time package
  MessageDlg('Max response for getMe',
    (Component as TDTMaxLongPollBot).LastGetMeInfo, mtInformation, [mbOK], '');
end;

procedure TLPMaxBotEditor.ExecuteVerb(Index: Integer);
begin
  case Index of
    0: getMe;
  else
    inherited;
  end;
end;

function TLPMaxBotEditor.GetVerb(Index: Integer): string;
begin
  case Index of
    0: Result:='getMe for the bot';
  else
    inherited;
  end;
end;

function TLPMaxBotEditor.GetVerbCount: Integer;
begin
  Result:=1;
end;

end.
