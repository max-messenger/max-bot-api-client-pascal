unit maxstatlog;

{$mode objfpc}{$H+}

interface

uses SysUtils,Classes;

Type

  { TMaxStatLog }

  TMaxStatLog = Class(TComponent)
  Private
    fAppendContent : Boolean;
    FDirectory: String;
    FFieldDelimiter: String;
    FFilePostfix: String;
    FFilePrefix: String;
    FStream : TFileStream;
    FActive: Boolean;
    FDefaultEventType: TEventType;
    FTimeStampFormat: String;
    FPaused : Boolean;
    function GetFileName: String;
    procedure SetActive(const Value: Boolean);
    procedure ActivateLog;
    procedure DeActivateLog;
    procedure ActivateFileLog;
    procedure SetFieldDelimiter(AValue: String);
    procedure SetFilePostfix(AValue: String);
    procedure SetFilePrefix(AValue: String);
    procedure WriteFileLog(const Msg: String);
    procedure DeActivateFileLog;
  Protected
    Procedure CheckInactive;
    function CheckForNewLogFile: Boolean;
    Procedure EnsureActive;
    procedure CloseAndCreateNewLog;
  Public
    constructor Create(AOwner: TComponent); override;
    Destructor Destroy; override;
    function GetFileNameFromDate(ADate: TDate): String;
    Procedure Pause;
    Procedure Resume;
    Procedure Log (const Msg : String);
    procedure Log(const Fmt: String; Args: array of const);
    procedure Log(AFields: array of String);
  Published
    Property AppendContent : Boolean Read fAppendContent Write fAppendContent;
    Property Active : Boolean Read FActive write SetActive;
    Property DefaultEventType : TEventType Read FDEfaultEventType Write FDefaultEventType;
    property Directory: String read FDirectory write FDirectory;
    property FieldDelimiter: String read FFieldDelimiter write SetFieldDelimiter;
    Property FileName : String Read GetFileName;
    property FilePrefix: String read FFilePrefix write SetFilePrefix;
    property FilePostfix: String read FFilePostfix write SetFilePostfix;
    Property TimeStampFormat : String Read FTimeStampFormat Write FTimeStampFormat;
    Property Paused : Boolean Read FPaused Write FPaused;
  End;

  ELogError = Class(Exception);

implementation

{ TMaxStatLog }

Resourcestring
  SErrOperationNotAllowed = 'Operation not allowed when eventlog is active.';

procedure TMaxStatLog.CheckInactive;
begin
  If Active then
    Raise ELogError.Create(SErrOperationNotAllowed);
end;

function TMaxStatLog.CheckForNewLogFile: Boolean;
begin
  Result:= not SameText(FStream.FileName, GetFileName);
end;

procedure TMaxStatLog.EnsureActive;
begin
  If Not Active then
    Active:=True;
end;

procedure TMaxStatLog.CloseAndCreateNewLog;
begin
  DeActivateLog;
  ActivateLog;
end;

constructor TMaxStatLog.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPaused:=True;
  FDirectory:='';
  FFilePostfix:='.csv';
  FFilePrefix:='~log';
  FFieldDelimiter:='; ';
  FTimeStampFormat:='';
  AppendContent:=True;
end;


procedure TMaxStatLog.Pause;
begin
  Paused:=True;
end;


procedure TMaxStatLog.Resume;
begin
  Paused:=False;
end;

procedure TMaxStatLog.Log(const Msg: String);
begin
  If Paused then
    exit;
  EnsureActive;
  WriteFileLog(Msg);
end;

procedure TMaxStatLog.WriteFileLog(const Msg : String);

Var
  S,TS: String;

begin
  if CheckForNewLogFile then
    CloseAndCreateNewLog;
  If FTimeStampFormat='' then
    FTimeStampFormat:='yyyy-mm-dd hh:nn:ss';
  TS:=FormatDateTime(FTimeStampFormat,Now);
  S:=TS+FieldDelimiter+Msg+LineEnding;
  try
    FStream.WriteBuffer(S[1],Length(S));
    S:='';
  except
    On E : Exception do
      S:=E.Message;
  end;
end;

procedure TMaxStatLog.Log(const Fmt: String; Args: array of const);
begin
  Log(Format(Fmt,Args));
end;

procedure TMaxStatLog.Log(AFields: array of String);
var
  i: Integer;
  S: String;
begin
  S:='';
  for i:=0 to Length(AFields)-1 do
    S+=AFields[i]+FieldDelimiter;
  Log(S);
end;

procedure TMaxStatLog.SetActive(const Value: Boolean);
begin
  If Value<>FActive then
    begin
    If Value then
      ActivateLog
    else
      DeActivateLog;
    FActive:=Value;
    end;
end;

function TMaxStatLog.GetFileName: String;
begin
  Result:=GetFileNameFromDate(Date);
end;

procedure TMaxStatLog.ActivateLog;

begin
  ActivateFileLog;
end;

procedure TMaxStatLog.DeActivateLog;

begin
    DeActivateFileLog;
end;

procedure TMaxStatLog.ActivateFileLog;
var
  fFileFlags : Word;
  AFileName: String;
begin
  AFileName:=GetFileName;
  if fAppendContent and FileExists(AFileName) then
    fFileFlags := fmOpenWrite
  else
    fFileFlags := fmCreate;

  fFileFlags := fFileFlags or fmShareDenyWrite;
  FStream:=TFileStream.Create(AFileName,fFileFlags);
  if fAppendContent then
    FStream.Seek(0,soFromEnd);
end;

procedure TMaxStatLog.SetFieldDelimiter(AValue: String);
begin
  if FFieldDelimiter=AValue then Exit;
  FFieldDelimiter:=AValue;
end;

procedure TMaxStatLog.SetFilePostfix(AValue: String);
begin
  if FFilePostfix=AValue then Exit;
  FFilePostfix:=AValue;
end;

procedure TMaxStatLog.DeActivateFileLog;

begin
  FStream.Free;
  FStream:=Nil;
end;

function TMaxStatLog.GetFileNameFromDate(ADate: TDate): String;
begin
  Result:=Directory+FilePrefix+FormatDateTime('yyyymmdd', ADate)+FilePostfix;
end;

procedure TMaxStatLog.SetFilePrefix(AValue: String);
begin
  if FFilePrefix=AValue then Exit;
  FFilePrefix:=AValue;
end;

destructor TMaxStatLog.Destroy;
begin
  Active:=False;
  inherited;
end;

end.
