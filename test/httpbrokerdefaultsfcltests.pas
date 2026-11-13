unit httpbrokerdefaultsfcltests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, maxfclhttpclientbroker;

type

  { TTestFCLBrokerDefaults }

  { td-111 tripwire: the constructor defaults of the FCL broker, pinned by a
    DIRECT TFCLHTTPClient.Create(nil) - the registration constructor is not
    needed, and the TMaxSender path is deliberately avoided: its private
    CreateHTTPClient overwrites the fresh client with the configuration copy
    (Result.SSLVerifyCert:=AConfig.VerifyCert), so through a Sender the test
    would observe the configured value, never the constructor True. A broker
    unit without FSSLVerifyCert:=True in its constructor silently turns
    server-certificate verification off for every direct consumer of the
    broker class (code that instantiates the client itself); Senders are
    immune (CreateHTTPClient overwrites the constructor default with the
    configuration copy and the TMaxSender default keeps verification on).
    One tripwire per runner: the TBaseHTTPClient registry is single-slot and two
    linked broker units displace each other last-wins, so a per-broker
    constructor default is only observable by instantiating the class itself.
    No network - the asserts run right after Create }
  TTestFCLBrokerDefaults=class(TTestCase)
  published
    procedure ConstructorDefaults;
  end;

implementation

procedure TTestFCLBrokerDefaults.ConstructorDefaults;
var
  Client: TFCLHTTPClient;
begin
  Client:=TFCLHTTPClient.Create(nil);
  try
    AssertTrue('the FCL broker constructor must default SSLVerifyCert to True',
      Client.SSLVerifyCert);
    AssertEquals('the FCL broker constructor must default SSLCAFile to empty',
      '', Client.SSLCAFile);
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTests([TTestFCLBrokerDefaults]);

end.
