unit maxplugin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, maxtypes, maxsendertypes, maxbot
  ;

type

  { TCustomMaxBotPlugin }

  TCustomMaxBotPlugin = class
  private
    FBot: TMaxBot;
    FDirectory: String;
  protected
    property Bot: TMaxBot read FBot;
    procedure Register; virtual; abstract;
  public
    constructor Create(aOwner: TMaxBot); virtual;
    property Directory: String read FDirectory write FDirectory;
  end;

implementation

uses
  DateUtils
  ;

{ TCustomMaxBotPlugin }

constructor TCustomMaxBotPlugin.Create(aOwner: TMaxBot);
begin
  FBot:=aOwner;
  Register;
end;

end.

