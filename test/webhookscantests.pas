unit webhookscantests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, maxwebhook;

type

  { TTestWebhookScan }

  { Offline tests of the webhook body depth scanner (JSONBodyTooDeep in the
  maxwebhook unit; the scanner moved here from the webhookutils unit of the
  examples/Webhook example): the escape handling of string literals and the
  exact boundary of the MaxJSONDepth limit }
  TTestWebhookScan=class(TTestCase)
  published
    procedure EmptyBodyIsAccepted;
    procedure UpdateBodyIsAccepted;
    procedure ExactlyAtDepthLimitIsAccepted;
    procedure OneOverDepthLimitIsRejected;
    procedure EscapedQuoteKeepsStringOpen;
    procedure DoubleBackslashThenQuoteClosesString;
    procedure BracketsInStringAreData;
    procedure UnclosedStringIsData;
    procedure ClosersBeforeOpenersStillCount;
    procedure ClosersDoNotDiscountOpeners;
  end;

implementation

// AN opening brackets alternating shapes: the scanner treats [ and { alike,
// the alternation just keeps both kinds exercised in the counting tests
function AltBrackets(AN: Integer): String;
begin
  Result:=StringOfChar('[', AN)+StringOfChar('{', AN);
end;

procedure TTestWebhookScan.EmptyBodyIsAccepted;
begin
  // The caller filters empty bodies out before the scanner; the scanner
  // itself must not reject one either
  AssertFalse('an empty body has no depth', JSONBodyTooDeep(EmptyStr));
end;

procedure TTestWebhookScan.UpdateBodyIsAccepted;
begin
  AssertFalse('a real update stays far under the limit',
    JSONBodyTooDeep('{"update_type":"message_created","message":'+
      '{"recipient":{"chat_id":123},"body":{"text":"ping"}}}'));
end;

procedure TTestWebhookScan.ExactlyAtDepthLimitIsAccepted;
begin
  // The limit itself must pass: MaxJSONDepth opens (64), not 65
  AssertFalse('exactly MaxJSONDepth levels pass',
    JSONBodyTooDeep(AltBrackets(MaxJSONDepth div 2)));
end;

procedure TTestWebhookScan.OneOverDepthLimitIsRejected;
begin
  AssertTrue('one level over the limit is rejected',
    JSONBodyTooDeep(AltBrackets(MaxJSONDepth div 2)+'{'));
end;

procedure TTestWebhookScan.EscapedQuoteKeepsStringOpen;
begin
  // \" is an escaped quote: the string stays open, so the depth-exceeding
  // brackets after it are data, not structure
  AssertFalse('a \-escaped quote does not close the string',
    JSONBodyTooDeep('{"k":"say \"'+StringOfChar('[', MaxJSONDepth+1)+'"}'));
end;

procedure TTestWebhookScan.DoubleBackslashThenQuoteClosesString;
begin
  // \\ consumes itself, so the quote after it really closes the string and
  // the brackets that follow are structure: a backslash must skip exactly
  // one character, not shelter the closing quote too
  AssertTrue('after \\ the string is closable, the brackets count',
    JSONBodyTooDeep('{"k":"ends\\"'+StringOfChar('[', MaxJSONDepth+1)));
end;

procedure TTestWebhookScan.BracketsInStringAreData;
begin
  AssertFalse('brackets inside a string literal are data',
    JSONBodyTooDeep('{"k":"'+StringOfChar('[', MaxJSONDepth+1)+'"}'));
end;

procedure TTestWebhookScan.UnclosedStringIsData;
begin
  // A body cut off inside a literal never leaves string mode: everything
  // after the opening quote stays data (this shape came up in the original
  // ad hoc check of the scanner)
  AssertFalse('an unterminated string hides the brackets',
    JSONBodyTooDeep('{"k":"'+StringOfChar('[', MaxJSONDepth+1)));
end;

procedure TTestWebhookScan.ClosersBeforeOpenersStillCount;
begin
  // Malformed closers floor the depth at zero and must not hand the
  // following openers a discount
  AssertTrue('openers after closers still reach the limit',
    JSONBodyTooDeep(StringOfChar(']', MaxJSONDepth)+
      AltBrackets(MaxJSONDepth div 2)+'{'));
end;

procedure TTestWebhookScan.ClosersDoNotDiscountOpeners;
begin
  AssertFalse('closers below zero do not offset openers',
    JSONBodyTooDeep(StringOfChar(']', MaxJSONDepth)+
      AltBrackets(MaxJSONDepth div 2)));
end;

initialization
  RegisterTests([TTestWebhookScan]);

end.
