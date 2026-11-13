unit maxutils;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, strutils, maxtypes, maxsendertypes
  ;

const
  mdCode='`';

function MarkdownEscape(const S: String): String;
function MarkdownEscapeV2(const S: String): String;
function CaptionFromUser(AUser: TMaxUserObj): String;
function CaptionFromChat(aChat: TMaxChatObj): String;
function BuildLink(const aCaption, aLink: String; aFormat: TMaxTextFormat = fmtDefault): String;
function ValidateUTF8(const S: String): String;

{ Kept for API compatibility: MAX Bot API defines no per-user URL scheme -
  the published docs (dev.max.ru/docs-api, static payload checked 2026-10-23)
  contain no tg:// or max:// user deep link, deep linking is documented via
  the bot_started update payload instead - so the stored value stays the
  legacy Telegram scheme on purpose: documented as legacy, not rewritten
  (td-004) }
function UserLink(aUserID: Int64): String;

implementation

const
  MarkdownSpChars: array[0..3] of AnsiChar = ('\', '_', '*', '`');
  MarkdownSpCharsV2: array[0..17] of AnsiChar = ('_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|',
    '{', '}', '.', '!');

  // legacy tg:// scheme kept on purpose: the MAX Bot API docs define no
  // per-user URL scheme to migrate to (dev.max.ru/docs-api, static payload
  // checked 2026-10-23 - neither tg:// nor max:// exists), so the value
  // stays as the documented legacy (td-004)
  _maxuserLink='tg://user?id=%d';

function MarkdownEscape(const S: String): String;
var
  a: AnsiChar;
begin
  Result:=S;
  for a in MarkdownSpChars do
    Result:=StringReplace(Result, a, '\'+a, [rfReplaceAll]);
end;

function MarkdownEscapeV2(const S: String): String;
var
  a: AnsiChar;
begin
  Result:=S;
  for a in MarkdownSpCharsV2 do
    Result:=StringReplace(Result, a, '\'+a, [rfReplaceAll]);
end;

function CaptionFromUser(AUser: TMaxUserObj): String;
begin
  Result:=EmptyStr;
  if AUser=nil then
    Exit;
  if AUser.FirstName<>EmptyStr then
    Result+=AUser.FirstName+' ';
  if AUser.LastName<>EmptyStr then
    Result+=AUser.LastName+' ';
  if AUser.Username<>EmptyStr then
    Result+='@'+AUser.Username;
  Result:=ValidateUTF8(Trim(Result));
end;

function CaptionFromChat(aChat: TMaxChatObj): String;
begin
  Result:=EmptyStr;
  if aChat=nil then
    Exit;
  if aChat.Title<>EmptyStr then
    Result+=aChat.Title+' ';
  Result:=ValidateUTF8(Trim(Result));
end;

function BuildLink(const aCaption, aLink: String; aFormat: TMaxTextFormat): String;
begin
  case aFormat of
    fmtMarkdown: Result:=Format('[%s](%s)', [aCaption, aLink]);
    fmtHTML:     Result:=Format('<a href="%s">%s</a>', [aLink, aCaption]);
  else
    Result:=aLink;
  end;
end;

{ Hack function due of problem some utf8 entities }
function ValidateUTF8(const S: String): String;
begin
  Result:=UTF8Encode(UTF8Decode(S));
end;

function UserLink(aUserID: Int64): String;
begin
  Result:=Format(_maxuserLink, [aUserID]);
end;

end.
