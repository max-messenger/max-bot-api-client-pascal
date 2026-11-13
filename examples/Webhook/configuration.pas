unit configuration;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TAppConfig = record
    MaxToken: String;
    MaxEndPoint: String;
    WebhookURL: String;
    WebhookPort: Integer;
    WebhookCertFile: String;
    WebhookKeyFile: String;
    WebhookSecret: String;
    WebhookDebug: Boolean;
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
  aConf.WebhookURL:=aIni.ReadString('Webhook', 'URL', aConf.WebhookURL); // Empty = do not register the subscription
  aConf.WebhookPort:=aIni.ReadInteger('Webhook', 'Port', 443);
  aConf.WebhookCertFile:=aIni.ReadString('Webhook', 'CertFile', EmptyStr);
  aConf.WebhookKeyFile:=aIni.ReadString('Webhook', 'KeyFile', EmptyStr);
  aConf.WebhookSecret:=aIni.ReadString('Webhook', 'Secret', EmptyStr); // Empty = do not check the X-Max-Bot-Api-Secret header
  aConf.WebhookDebug:=aIni.ReadBool('Webhook', 'Debug', False); // Off by default: debug logging stores message texts (PII)
  aIni.Free;
end;

initialization
  LoadConfig(Conf);

end.

