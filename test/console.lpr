program console;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  // The receiver tests create real threads; on Linux and macOS the build is
  // green without cthreads and the first thread crashes at runtime (error 232)
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, consoletestrunner, testhttpharness, testmax, multipartboundarytests,
  webhookscantests, webhookreceivertests, httpbrokerdefaultsfcltests,
  maxfclhttpclientbroker;

type

  { TMyTestRunner }

  TMyTestRunner = class(TTestRunner)
  protected
  // override the protected methods of TTestRunner to customize its behavior
  end;

var
  Application: TMyTestRunner;

begin
  Application := TMyTestRunner.Create(nil);
  Application.Initialize;
  Application.Title:='console';
  Application.Run;
  Application.Free;
end.
