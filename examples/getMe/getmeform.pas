unit getMeForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, IniPropStorage;

type

  { TFrmMain }

  TFrmMain = class(TForm)
    BtnGetMe: TButton;
    EdtToken: TLabeledEdit;
    InPrpStrg: TIniPropStorage;
    MmBotInfo: TMemo;
    procedure BtnGetMeClick(Sender: TObject);
  private

  public

  end;

var
  FrmMain: TFrmMain;

implementation

{$R *.lfm}

uses
  maxsendertypes, maxfclhttpclientbroker
  ;

{ TFrmMain }

procedure TFrmMain.BtnGetMeClick(Sender: TObject);
var
  ABot: TMaxSender;
begin
  ABot:=TMaxSender.Create(EdtToken.Text);
  try
    if ABot.GetMe then
      MmBotInfo.Lines.Add(ABot.BotInfo.AsString);
  finally
    ABot.Free;
  end;
end;

end.

