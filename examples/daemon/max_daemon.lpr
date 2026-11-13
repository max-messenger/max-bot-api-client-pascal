program max_daemon;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  // cwstring: without the widechar manager string conversions turn every
  // non-ASCII character into '?', corrupting non-Latin log texts
  cwstring,
  {$ENDIF}
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  // The receiver is a thread: on UNIX the build is green without cthreads
  // and the first thread crashes at runtime (error 232) - build with
  // -dUseCThreads
  cthreads,
  {$ENDIF}{$ENDIF}
  {$IFDEF UNIX}
  baseunix, // fpumask of the main block below
  {$ENDIF}
  // The daemon class and its whole logic live in the daemonapp unit (it is
  // also how the offline suite of td-091 tests the failed-start contract) -
  // this program is only the thin host shell of it
  daemonapp,
  // A broker unit must be in the program's uses: without it CreateHTTPClient
  // raises "No HTTP client class registered" (the library registers no
  // default)
  maxfclhttpclientbroker
  ;

var
  Application: TDaemonApplication;
begin
  {$IFDEF UNIX}
  // The very first line, before anything can create a file: the log holds
  // chat ids, and with an empty [Daemon] LogFile it activates in the system
  // temp directory (see the LogFile comment in the unit constructor, td-085).
  // The unit templates' UMask=0077 does not cover nohup or any other manager
  // without a umask setting (the shipped launchd template sets Umask as
  // well) - this mask is a safety net so the log file is created private
  // (0600) everywhere
  fpumask(&0077);
  {$ENDIF}
  Application:=TDaemonApplication.Create(nil);
  Application.Title:='Test Max Daemon App';
  Application.Run;
  Application.Free;
end.
