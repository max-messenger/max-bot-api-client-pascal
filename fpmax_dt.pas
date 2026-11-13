{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit fpmax_dt;

{$warn 5023 off : no warning about unused units}
interface

uses
  maxbot_dt, DTMaxBot, receiverthread, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('DTMaxBot', @DTMaxBot.Register);
end;

initialization
  RegisterPackage('fpmax_dt', @Register);
end.
