program sendmessage;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  // cwstring: without the widechar manager string conversions turn every
  // non-ASCII character into '?', corrupting non-Latin message texts
  cwstring,
  {$ENDIF}
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils,
  maxsendertypes, maxfclhttpclientbroker
  ;

type

  { TMyBot }
  { You do not have to create a chilf to class MaxSender.
    This is only necessary for logging in our sample }
  TMyBot = class(TMaxSender)
  protected
    procedure BotLogMessage({%H-}ASender: TObject; EventType: TEventType; const Msg: String);
  end;

var
  ABot: TMyBot;
  AToken, AMsg: String;
  Q: AnsiChar;
  AChatID: Int64;

{ TMyBot }

procedure TMyBot.BotLogMessage(ASender: TObject; EventType: TEventType;
  const Msg: String);
begin
  case EventType of
    etDebug: WriteLn('Debug: '+Msg);
    etError: WriteLn('Error: '+Msg);
  else
    WriteLn('Information: '+Msg);
  end;
end;

begin
  Writeln('This is simple console app without getting updates from bot API');
  Writeln('Sample of using sendMessage from Max bot. fp-max lib is using');
  Write('Please enter bot token: ');
  Readln(AToken);
  ABot:=TMyBot.Create(AToken);
  try
    // LogDebug is left off on purpose: with it on, the library log records
    // full API request and response bodies - message texts and chat ids
    ABot.OnLogMessage:=@ABot.BotLogMessage;
    Write('Now found out your (or other known to the bot user) user private or group ID');
    Write('And after please enter this user/chat ID (it is integer value [Int64]): ');
    Readln(AChatID);
    //ABot.APIEndPoint:='https://platform-api2.max.ru';
    repeat
      Write('Please enter message string: ');
      Readln(AMsg);
      ABot.SendMessage(AChatID, AMsg);
      Write('Do you want to send another message [Y/N]?: ');
      Readln(Q);
    until lowercase(Q)<>'y';
  finally
    ABot.Free;
  end;
end.
