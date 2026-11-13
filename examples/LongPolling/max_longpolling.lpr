program max_longpolling;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  // cwstring: without the widechar manager string conversions turn every
  // non-ASCII character into '?', corrupting non-Latin echo texts
  cwstring,
  {$ENDIF}
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils, CustApp, ssockets, fpJSON, jsonparser,
  fphttpclient, opensslsockets,
  {$IFDEF UNIX}
  baseunix, // cint/timespec of the monotonic MonoMs clock below
  {$ENDIF}
  maxsendertypes, configuration, eventlog, maxtypes,
  maxfclhttpclientbroker
  ;

const
  // td-013 receiver retry policy: transport failures and HTTP 429 back off
  // exponentially, every other error keeps the historical one-second pause
  BackoffBaseMs = 1000;
  BackoffMaxMs = 30000;

// ladder: 1, 2, 4, 8, 16 s, then the 30 s cap (1000 shl 5 = 32000 is cut
// by the cap); the shift guard keeps shl inside the Integer range
function BackoffMs(AConsecutiveFailures: Integer): Integer;
var
  Shift: Integer;
begin
  Shift:=AConsecutiveFailures;
  if Shift>5 then
    Shift:=5;
  Result:=BackoffBaseMs shl Shift;
  if Result>BackoffMaxMs then
    Result:=BackoffMaxMs;
end;

{$IFDEF DARWIN}
// CLOCK_MONOTONIC is not exposed by the 3.2.2 RTL on darwin (no constant,
// no FpClockGetTime): call libc directly, the id is darwin's time.h value
const
  CLOCK_MONOTONIC = 6;

function clock_gettime(clkId: cint; var tp: timespec): cint; cdecl;
  external 'c' name 'clock_gettime';
{$ENDIF}

// Monotonic milliseconds: the download budget must not jump with NTP
// corrections. GetTickCount64 is monotonic in the RTL on Linux/FreeBSD only;
// on darwin it is the wall clock (HAVECLOCKGETTIME is LINUX/FreeBSD in
// rtl/unix/sysutils.pp) - there it is clock_gettime(CLOCK_MONOTONIC)
function MonoMs: QWord;
var
  ts: timespec;
begin
  {$IFDEF DARWIN}
  ts.tv_sec:=0;
  ts.tv_nsec:=0;
  if clock_gettime(CLOCK_MONOTONIC, ts)<>0 then
    Exit(GetTickCount64); // unreachable in practice: fail open to the wall clock
  Result:=QWord(ts.tv_sec)*1000+QWord(ts.tv_nsec) div 1000000;
  {$ELSE}
  Result:=GetTickCount64;
  {$ENDIF}
end;

type

  { TMaxLPApplication }

  TMaxLPApplication = class(TCustomApplication)
  private
    FBot: TMaxSender;
    FLogger: TEventLog;
    procedure BotReceiveMessage({%H-}ASender: TObject; AMessage: TMaxMessageObj);
    procedure BotLogMessage({%H-}ASender: TObject; EventType: TEventType; const Msg: String);
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

{ TMaxLPApplication }

procedure TMaxLPApplication.BotReceiveMessage(ASender: TObject;
  AMessage: TMaxMessageObj);
const
  MediaTypes = [atImage, atVideo, atAudio, atFile];
  DownloadConnectTimeoutMs = 15000;
  DownloadIOTimeoutMs = 30000;
  // Whole-batch download budget: the per-attachment 15+30 s timeouts stay
  // the upper bound of a single download, this caps their sum
  BatchDownloadBudgetMs = 30000;
var
  I, J, TryN: Integer;
  AnAttachment: TMaxAttachmentObj;
  AnAttachments: TJSONArray;
  AnAttachmentJSON, AnPayload: TJSONObject;
  AURL, AToken, AFileName: String;
  ADownload: TFileStream;
  ADownloadHTTP: TFPHTTPClient;
  Deadline: QWord;
  SkippedByBudget: Integer;
begin
  // Honest media echo: download every received media file and upload it
  // fresh through the full upload cycle, instead of re-sending the received
  // token. Video and audio get their token at the first upload step, images
  // and files - from the upload response; UploadFile returns EmptyStr on an
  // unassigned stream, a transport, upload-URL/file-name/response validation
  // or HTTP status failure, such attachments are skipped with a log line.
  // Construction and configuration failures raise to the caller, as does a
  // failed download: the exception is caught per attachment, the attachment
  // is logged and skipped, the rest of the batch still goes out.
  // Attachments without a downloadable URL fall back to the received token.
  // Downloads share one time budget per batch (td-046): when it runs out the
  // remaining downloads are skipped with a summary log line and what was
  // fetched so far still goes out - N stalled URLs must not freeze the
  // single-threaded polling loop for N per-attachment timeouts
  AnAttachments:=TJSONArray.Create;
  Deadline:=MonoMs+BatchDownloadBudgetMs;
  SkippedByBudget:=0;
  try
    for I:=0 to AMessage.Body.Attachments.Count-1 do
    begin
      AnAttachment:=AMessage.Body.Attachments[I];
      if not (AnAttachment.AttachmentType in MediaTypes) then
        Continue;
      AURL:=AnAttachment.Payload.URL;
      AToken:=EmptyStr;
      AFileName:=EmptyStr;
      if AURL=EmptyStr then
        AToken:=AnAttachment.Payload.Token
      else begin
        AFileName:=AnAttachment.FileName;
        if AFileName=EmptyStr then
          AFileName:='echo-'+MaxAttachmentTypeToStr(AnAttachment.AttachmentType);
        for J:=1 to Length(AFileName) do
          if AFileName[J] in ['/','\'] then
            AFileName[J]:='_';
        // Budget exhausted: skip this and the remaining downloads, the
        // attachments fetched so far still go out with the send below
        if MonoMs>=Deadline then
        begin
          Inc(SkippedByBudget);
          Continue;
        end;
        try
          ADownload:=TFileStream.Create(GetTempDir+AFileName, fmCreate);
          try
            ADownloadHTTP:=TFPHTTPClient.Create(nil);
            try
              // Milliseconds: a stalled download must not freeze the
              // single-threaded polling loop forever
              ADownloadHTTP.ConnectTimeout:=DownloadConnectTimeoutMs;
              ADownloadHTTP.IOTimeout:=DownloadIOTimeoutMs;
              ADownloadHTTP.Get(AURL, ADownload);
            finally
              ADownloadHTTP.Free;
            end;
            AToken:=FBot.UploadFile(
              UploadTypeFromAttachmentType(AnAttachment.AttachmentType),
              ADownload, AFileName);
          finally
            ADownload.Free;
            // The temp copy has served its purpose: without this delete a
            // long-lived bot leaves one file per media message in GetTempDir
            DeleteFile(GetTempDir+AFileName);
          end;
        except
          // One broken attachment (expired URL, network failure) must not
          // tear down the whole batch: log it and go on with the next one
          on E: Exception do
          begin
            FLogger.Error(Format('[LongPolling] media echo: download/upload of %s failed: %s %s',
              [AFileName, E.ClassName, E.Message]));
            Continue;
          end;
        end;
      end;
      if AToken=EmptyStr then
      begin
        FLogger.Error(Format('[LongPolling] media echo: could not fetch or upload %s',
          [AFileName]));
        Continue;
      end;
      AnPayload:=TJSONObject.Create(['token', AToken]);
      AnAttachmentJSON:=TJSONObject.Create([
        'type', MaxAttachmentTypeToStr(AnAttachment.AttachmentType),
        'payload', AnPayload]);
      AnAttachments.Add(AnAttachmentJSON);
    end;
    // One summary line for the whole batch, not one per skipped attachment
    if SkippedByBudget>0 then
      FLogger.Error(Format('[LongPolling] media echo: batch download budget of %d ms exhausted, %d attachment(s) skipped',
        [BatchDownloadBudgetMs, SkippedByBudget]));
    if AnAttachments.Count>0 then
    begin
      // The echo send runs on the polling thread and SendMessage blocks
      // without a timeout - a deliberate compromise of this example (the
      // td-046 budget covers downloads only), not a pattern for production
      // copies. A freshly uploaded attachment is processed by the platform
      // asynchronously: the first send may fail with the
      // attachment.not.ready error for a few seconds - retry with a pause
      for TryN:=1 to 5 do
      begin
        if FBot.SendMessageEx(AMessage.ChatId, EmptyStr, AnAttachments) then
          Break;
        FLogger.Error(Format('[LongPolling] media echo to chat %d try %d failed: %s %s',
          [AMessage.ChatId, TryN, FBot.LastErrorCode, FBot.LastErrorMsg]));
        if FBot.LastErrorCode<>'attachment.not.ready' then
          Break;
        Sleep(3000);
      end;
      Exit;
    end;
  finally
    AnAttachments.Free;
  end;
  // Echo the incoming text back to the same chat
  if AMessage.Body.Text<>EmptyStr then
    if not FBot.SendMessage(AMessage.ChatId, AMessage.Body.Text) then
      FLogger.Error(Format('[LongPolling] echo to chat %d failed: %s %s',
        [AMessage.ChatId, FBot.LastErrorCode, FBot.LastErrorMsg]));
end;

procedure TMaxLPApplication.BotLogMessage(ASender: TObject; EventType: TEventType;
  const Msg: String);
begin
  case EventType of
    etError: FLogger.Error(Msg);
    etDebug: FLogger.Debug(Msg);
  else
    FLogger.Info(Msg);
  end;
end;

procedure TMaxLPApplication.DoRun;
var
  Failures: Integer;
begin
  Failures:=0;
  while not Terminated do
  try
    // A failed request (a bad token, an HTTP error) is not an exception any
    // more: it comes back as False, the pause below keeps the loop from
    // hammering the API and the log
    if FBot.getUpdatesEx(0, 10) then
      Failures:=0
    else begin
      if not Terminated then
      begin
        // one line per transition into the failure state, not one per retry
        if Failures=0 then
          FLogger.Error('[LongPolling] entering failure state: '
            +FBot.LastErrorCode+' '+FBot.LastErrorMsg);
        // transport and 429 back off, the rest keeps the historical 1 s
        if (FBot.LastErrorCode='transport')
          or (FBot.LastErrorCode='too.many.requests') then
          Sleep(BackoffMs(Failures))
        else
          Sleep(BackoffBaseMs);
        Inc(Failures);
      end;
    end;
  except
    // FIRST in the handler chain: EMaxConfig descends from Exception. A
    // configuration error fails every retry, so stop visibly instead of
    // retrying forever (td-013)
    on E: EMaxConfig do
    begin
      FLogger.Error('[LongPolling] configuration error, receiver stopped: '+E.Message);
      Terminate;
    end;
    on E: ESocketError do
    begin
      // td-013: this branch used to pass without a single log line. It is a
      // safety net (td-030 moved the normal transport failure into the False
      // path), rare by construction - one line per occurrence, no dedup
      FLogger.Error('[LongPolling] unexpected socket error: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs); // aligned with the False path
    end;
    // Any other exception must not kill the loop silently: log the cause
    // here and retry
    on E: Exception do
    begin
      FLogger.Error('[LongPolling] getUpdates failed: ['+E.ClassName+'] '+E.Message);
      if not Terminated then
        Sleep(BackoffBaseMs);
    end;
  end;
  Terminate;
end;

constructor TMaxLPApplication.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FLogger:=TEventLog.Create(nil);
  FLogger.LogType:=ltFile;
  FLogger.Active:=True;
  FBot:=TMaxSender.Create(Conf.MaxToken);
  with FBot do
  begin
    // LogDebug stays off by default: the debug log contains message texts
    // and chat ids. Enable it explicitly when troubleshooting.
    OnLogMessage:=@BotLogMessage;
    OnReceiveMessage:=@BotReceiveMessage;
    APIEndPoint:=Conf.MaxEndPoint;
  end;
end;

destructor TMaxLPApplication.Destroy;
begin
  FBot.Free;
  FLogger.Free;
  inherited Destroy;
end;

var
  Application: TMaxLPApplication;
begin
  Application:=TMaxLPApplication.Create(nil);
  Application.Title:='Test Max LongPolling App';
  Application.Run;
  Application.Free;
end.
