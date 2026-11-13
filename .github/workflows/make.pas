//castle-engine.io/modern_pascal

program Make;
{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  StrUtils,
  FileUtil,
  LazFileUtils,
  RegExpr,
  LazUTF8,
  eventlog,
  Process;

  function OutLog(const Knd: TEventType; const Msg: string): string; cdecl;
  begin
    case Knd of
      etError: OutLog := #27'[31m%s'#27'[0m';
      etInfo:  OutLog := #27'[32m%s'#27'[0m';
      etDebug: OutLog := #27'[33m%s'#27'[0m';
    end;
    if Knd = etError then
        ExitCode += 1;
    Writeln(stderr, UTF8ToConsole(OutLog.Format([Msg])));
  end;

  function SelectString(const Input, Reg: string): string; cdecl;
  var
    Line: string;
  begin
    SelectString := EmptyStr;
    with TRegExpr.Create do
    begin
      Expression := Reg;
      for Line in Input.Split(LineEnding) do
        if Exec(Line) then
          SelectString += Line + LineEnding;
      Free;
    end;
  end;

  function AddPackage(const Path: string): string; cdecl;
  begin
    // Skip widgetset-specific packages (cocoa, x11) and the IDE _template when linking packages
    AddPackage := '(cocoa|x11|_template)';
    if SelectString(Path, AddPackage) = EmptyStr then
      if RunCommand('lazbuild', ['--add-package-link', Path], AddPackage, [poStderrToOutPut]) then
        OutLog(etDebug, 'Add package:'#9 + Path)
      else
        OutLog(etError, AddPackage);
  end;

  function BuildProject(const Path: string): string; cdecl;
  begin
    OutLog(etDebug, 'Build from:'#9 + Path);
    if RunCommand('lazbuild',
      ['--build-all', '--recursive', '--no-write-project', Path], BuildProject, [poStderrToOutPut, poWaitOnExit]) then
    begin
      BuildProject := SelectString(BuildProject, 'Linking').Split(' ')[2].Replace(LineEnding, EmptyStr);
      OutLog(etInfo, #9'to:'#9 + BuildProject);
    end
    else
      OutLog(etError, SelectString(BuildProject, '(Fatal|Error):'));
  end;

  function BuildAll: string;
  var
    List: TStringList;
    DT: TDateTime;
  begin
    DT := Time;
    // INSTALL-PACKAGES
    List := FindAllFiles(GetCurrentDir, '*.lpk');
    try
      List.Sort;
      for BuildAll in List do
        AddPackage(BuildAll);
// BUILD-PROJECTS
      List := FindAllFiles(GetCurrentDir, '*.lpi');
      List.Sort;
      for BuildAll in List do
      begin
{$IFDEF DARWIN}
        if BuildAll.Contains('maxpclocker') then Continue;
{$ENDIF}
        BuildProject(BuildAll);
      end;
    finally
      List.Free;
    end;
    OutLog(etDebug, 'Duration:'#9'%s'#10'Errors:'#9'%s'.Format(
      [FormatDateTime('hh:nn:ss', Time - DT), ExitCode.ToString]
    ));
  end;

const
  // The offline suites of the console runner: the live-token suites stay out
  // (their red is environmental - no testmax.ini - not a regression), so
  // --all is not an option. The list is the offline set of test/readme.md
  // verbatim. The runner exits 0 on an unknown --suite ("No tests selected.") -
  // RunSuite turns that into an error, so a renamed suite cannot quietly
  // stop running.
  FCLSuites: array of string = (
    'TTestSenderTypes', 'TTestMaxBot', 'TTestDesignTime',
    'TTestDaemonStartFailure', 'TTestTLSTrust', 'TTestWebhookScan',
    'TTestMultipartBody', 'TTestMultipartBoundary', 'TTestStringBody',
    'TTestWebhookReceiver', 'TTestFCLBrokerDefaults');

  function RunSuite(const Runner, Suite: string): string; cdecl;
  begin
    OutLog(etDebug, #9'Suite:'#9 + Suite);
    if not RunCommand(Runner, ['--format=plain', '--suite=' + Suite], RunSuite, [poStderrToOutPut]) then
      OutLog(etError, Runner + #9 + Suite + LineEnding
        + SelectString(RunSuite, '(Failed|Failure|Error|Exception)'))
    else if SelectString(RunSuite, 'No tests selected') <> EmptyStr then
      OutLog(etError, Runner + #9 + Suite + #9'No tests selected');
  end;

  function TestAll: string;
  var
    DT: TDateTime;
    Suite: string;
  begin
    DT := Time;
    // RUNNER-BINARY: the runner comes from the build action
    if not FileExists('test/console') then
      OutLog(etError, 'Missing binary:'#9'test/console');
    // OFFLINE-SUITES
    for Suite in FCLSuites do
      RunSuite('test/console', Suite);
    OutLog(etDebug, 'Duration:'#9'%s'#10'Errors:'#9'%s'.Format(
      [FormatDateTime('hh:nn:ss', Time - DT), ExitCode.ToString]
    ));
  end;

//-------------------------------------------------------------------------------
// MAIN ENDPOINT
//-------------------------------------------------------------------------------

begin
  try
    if ParamCount > 0 then
      case ParamStr(1) of
        'build': BuildAll;
        'test': TestAll;
        else
          OutLog(etError, ParamStr(1));
      end;
  except
    on E: Exception do
      OutLog(etError, E.ClassName + #9 + E.Message);
  end;
end.
