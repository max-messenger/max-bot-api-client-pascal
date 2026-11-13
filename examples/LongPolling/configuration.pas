unit configuration;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TAppConfig = record
    MaxToken: String;
    MaxEndPoint: String;
  end;


var
  Conf: TAppConfig;

implementation

uses
  IniFiles
  ;

function ConfigFile: String;
begin
  Result:=ChangeFileExt(ParamStr(0), '.ini');
end;

procedure LoadConfig(var aConf: TAppConfig);
var
  aIni: TMemIniFile;
begin
  aIni:=TMemIniFile.Create(ConfigFile);
  aConf.MaxToken:=aIni.ReadString('Max', 'Token', EmptyStr);
  aConf.MaxEndPoint:=aIni.ReadString('Max', 'EndPoint', aConf.MaxEndPoint); // Optional line and config. Can be default
  aIni.Free;
end;

initialization
  LoadConfig(Conf);

end.

