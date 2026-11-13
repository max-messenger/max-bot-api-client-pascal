unit testbase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, maxsendertypes, IniFiles, fpjson, TypInfo;

type

  { TTestMaxBase }

  TTestMaxBase= class(TTestCase)
  private
    FConf: TIniFile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    property Conf: TIniFile read FConf;
    procedure SaveJSONData(AData: TJSONData; const AFileName: String);
    procedure SaveString(const AString, AFileName: String);
  end;

  { TTestMaxClass }

  TTestMaxClass= class(TTestMaxBase)
  private
    FBot: TMaxSender;
    FChatID: Int64;
    FUserID: Int64;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    procedure BotLogMessage({%H-}ASender: TObject; EventType: TEventType; const Msg: String);
    property Bot: TMaxSender read FBot;
    property ChatID: Int64 read FChatID;
    property UserID: Int64 read FUserID;
  end;

implementation

{ TTestMaxClass }

procedure TTestMaxClass.SetUp;
begin
  inherited SetUp;
  FBot:=TMaxSender.Create(FConf.ReadString('Bot', 'Token', EmptyStr));
  FBot.LogDebug:=True;
  FBot.OnLogMessage:=@BotLogMessage;
  if FBot.Token=EmptyStr then
    Fail('Please, specify bot token in testmax.ini! See readme.md');
  FChatID:=Conf.ReadInt64('Chat', 'ID', 0);
  if FChatID=0 then
    Fail('Please, specify chat ID in testmax.ini! See readme.md');
  FUserID:=Conf.ReadInt64('User', 'ID', 0);
end;

procedure TTestMaxClass.TearDown;
begin
  FreeAndNil(FBot);
  inherited TearDown;
end;

procedure TTestMaxClass.BotLogMessage(ASender: TObject; EventType: TEventType;
  const Msg: String);
begin
  WriteLn(StdOut, GetEnumName(TypeInfo(TEventType), Ord(EventType))+': '+Msg);
end;

{ TTestMaxBase }

procedure TTestMaxBase.SetUp;
begin
  FConf:=TMemIniFile.Create('testmax.ini');
  MaxAPI_URL:=FConf.ReadString('API', 'Endpoint', MaxAPI_URL); // For Russian specific case
end;

procedure TTestMaxBase.TearDown;
begin
  FreeAndNil(FConf);
end;

procedure TTestMaxBase.SaveJSONData(AData: TJSONData;
  const AFileName: String);
begin
  if not Assigned(AData) then
  begin
    Fail('JSON data is empty!');
    Exit;
  end;
  SaveString(AData.FormatJSON, AFileName);
end;

procedure TTestMaxBase.SaveString(const AString, AFileName: String);
var
  AStrings: TStringList;
begin
  AStrings:=TStringList.Create;
  try
    AStrings.Text:=AString;
    AStrings.SaveToFile(AFileName);
  finally
    AStrings.Free;
  end;
end;

end.
