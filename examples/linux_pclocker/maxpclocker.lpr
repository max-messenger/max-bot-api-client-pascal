program maxpclocker;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, Unix, xlib, x, CairoXlib,
  {$ENDIF}
  Classes, SysUtils, CustApp, process, maxsendertypes, maxtypes, Cairo;

type

  { TMyApplication }

  TMyApplication = class(TCustomApplication)
  protected
    fbot:TMaxSender;
    procedure DoRun; override;
    procedure MaxLockCmd(ASender: TObject; const ACommand: String; AMessage: TMaxMessageObj);
    procedure MaxUnlockCmd(ASender: TObject; const ACommand: String; AMessage: TMaxMessageObj);
    procedure MaxScreenshotCmd(ASender: TObject; const ACommand: String; AMessage: TMaxMessageObj);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  API_TOKEN = 'BotToken'; //TODO: fill with your bot API
  AuthorizedSender = 1234567890; //PC owner ID; TODO: fill with the ID of the user allower do lock/unlock PC remotely

{ TMyApplication }

procedure TMyApplication.DoRun;
begin
  while not Terminated do begin
    fbot.getUpdatesEx(0,0);
  end;
end;

procedure TMyApplication.MaxLockCmd(ASender: TObject; const ACommand: String;
  AMessage: TMaxMessageObj);
var
  ec: Integer;
begin
  if AMessage.Sender.UserId = AuthorizedSender then begin
    ec:=ExecuteProcess('/usr/bin/cinnamon-screensaver-command', ['--lock']);
    fbot.SendMessage(AMessage.ChatId,'Lock command exited with code '+ec.ToString);
  end;
end;

procedure TMyApplication.MaxUnlockCmd(ASender: TObject; const ACommand: String;
  AMessage: TMaxMessageObj);
var
  ec: Integer;
begin
  if AMessage.Sender.UserId = AuthorizedSender then begin
    ec:=ExecuteProcess('/usr/bin/loginctl', ['unlock-session']);
    fbot.SendMessage(AMessage.ChatId,'Lock command exited with code '+ec.ToString);
  end;
end;

procedure TMyApplication.MaxScreenshotCmd(ASender: TObject;
  const ACommand: String; AMessage: TMaxMessageObj);
var
  display: PDisplay;
  root: TWindow;
  scr: cint;
  surface: Pcairo_surface_t;
  fn: String;
begin
  fn:='/tmp/maxpclocker_'+GetProcessID.ToString+'.png';
  display := XOpenDisplay(nil);
  try
    root := DefaultRootWindow(display);
    scr := DefaultScreen(display);

    surface := cairo_xlib_surface_create(display,
                                         root,
                                         DefaultVisual(display, scr),
                                         DisplayWidth(display, scr),
                                         DisplayHeight(display, scr));


      cairo_surface_write_to_png(surface, pchar(fn));
      cairo_surface_destroy(surface);

      fbot.sendPhotoByFileName(AMessage.ChatId, fn);
  finally
    XCloseDisplay(display);
  end;
end;

constructor TMyApplication.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  fbot:=TMaxSender.Create(API_TOKEN);
  fbot.Timeout:=2000;
  fbot.CommandHandlers['/lock']       := @MaxLockCmd;
  fbot.CommandHandlers['/unlock']     := @MaxUnlockCmd;
  fbot.CommandHandlers['/screenshot'] := @MaxScreenshotCmd;
  StopOnException:=True;
end;

destructor TMyApplication.Destroy;
begin
  inherited Destroy;
end;

var
  Application: TMyApplication;
begin
  Application:=TMyApplication.Create(nil);
  Application.Title:='My Application';
  Application.Run;
  Application.Free;
end.

