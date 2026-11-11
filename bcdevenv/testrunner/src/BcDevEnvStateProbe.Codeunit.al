// Diagnostic only: 'bcdevenv run-tests --executor altool --state-probe on' runs ProbeState once per AL tool
// batch, right after the first state reset and before the first test codeunit. It always fails on purpose:
// its error message is one line with the session state that test codeunit starts with (application area,
// session, work date, permissions mock, the "Application Area Setup" rows) and whether a TestPage finds
// controls in the Basic and Suite application areas, with the application area it found and after
// ApplicationArea(''). The CLI logs it as "State probe: ..." and never reports it as a test result. The
// probe restores the application area it found, so the next codeunit starts as it would without the probe
// (except for the last error, which is the probe's).
namespace BcDevEnv.TestRunner;

using System.Reflection;
#if BCDEVENV_PERMISSIONSMOCK
using System.TestLibraries.Security.AccessControl;
#endif

codeunit 50105 "BcDevEnv State Probe"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        FoundTok: Label 'BcDevEnv state probe: control found', Locked = true;
        DiagnosticErr: Label '%1', Locked = true;

    [Test]
    procedure ProbeState()
    var
        Diagnostic: TextBuilder;
        OriginalArea: Text;
    begin
        OriginalArea := ApplicationArea();
        Diagnostic.Append(StrSubstNo('ApplicationArea=''%1''; SessionId=%2; ClientType=%3; GuiAllowed=%4', OriginalArea, SessionId(), CurrentClientType(), GuiAllowed()));
        Diagnostic.Append(StrSubstNo('; Company=''%1''; User=''%2''; WorkDate=%3', CompanyName(), UserId(), Format(WorkDate(), 0, 9)));
        Diagnostic.Append(StrSubstNo('; PermissionsMock=%1', PermissionsMockState()));
        Diagnostic.Append(StrSubstNo('; Application Area Setup: %1', ApplicationAreaSetupRows()));
        Diagnostic.Append(StrSubstNo('; TestPage with that area: %1', ProbePage()));
        Diagnostic.Append(StrSubstNo('; ApplicationArea after the TestPage=''%1''', ApplicationArea()));
        ApplicationArea('');
        Diagnostic.Append(StrSubstNo('; after ApplicationArea(''''): ApplicationArea=''%1''', ApplicationArea()));
        Diagnostic.Append(StrSubstNo(', TestPage: %1', ProbePage()));
        ApplicationArea(OriginalArea);
        Error(DiagnosticErr, SingleLine(Diagnostic.ToText()));
    end;

    local procedure ProbePage(): Text
    begin
        exit(StrSubstNo('BasicSuiteField %1, BasicSuiteAction %2, AllField %3, AllAction %4',
            ProbeControl(1), ProbeControl(2), ProbeControl(3), ProbeControl(4)));
    end;

    // Opens the probe page and accesses one control; the error that asserterror catches tells whether it was found.
    local procedure ProbeControl(Control: Integer): Text
    begin
        ClearLastError();
        asserterror OpenAndAccess(Control);
        if GetLastErrorText() = FoundTok then
            exit('found');
        exit(StrSubstNo('not found (%1)', CopyStr(SingleLine(GetLastErrorText()), 1, 200)));
    end;

    local procedure OpenAndAccess(Control: Integer)
    var
        StateProbe: TestPage "BcDevEnv State Probe";
        Value: Text;
    begin
        StateProbe.OpenView();
        case Control of
            1:
                Value := StateProbe.BasicSuiteField.Value();
            2:
                StateProbe.BasicSuiteAction.Invoke();
            3:
                Value := StateProbe.AllField.Value();
            4:
                StateProbe.AllAction.Invoke();
        end;
        StateProbe.Close();
        Error(FoundTok);
    end;

    // Table 9178 "Application Area Setup" (Base Application) through RecordRef, so this app has no dependency
    // on it: the primary key (company, profile, user) and the Boolean fields that are set, of the first 10 rows.
    local procedure ApplicationAreaSetupRows(): Text
    var
        AllObj: Record AllObj;
        SetupRef: RecordRef;
        PrimaryKey: KeyRef;
        SetupField: FieldRef;
        Rows: TextBuilder;
        Flags: TextBuilder;
        IsSet: Boolean;
        RowCount: Integer;
        Index: Integer;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
        AllObj.SetRange("Object ID", 9178);
        if AllObj.IsEmpty() then
            exit('table 9178 does not exist');
        SetupRef.Open(9178);
        if not SetupRef.ReadPermission() then
            exit('no read permission');
        if not SetupRef.FindSet() then
            exit('no rows');
        repeat
            RowCount += 1;
            if RowCount <= 10 then begin
                Rows.Append(StrSubstNo(' [%1]', RowCount));
                PrimaryKey := SetupRef.KeyIndex(1);
                for Index := 1 to PrimaryKey.FieldCount() do begin
                    SetupField := PrimaryKey.FieldIndex(Index);
                    Rows.Append(StrSubstNo(' %1=''%2''', SetupField.Name(), SetupField.Value()));
                end;
                Clear(Flags);
                for Index := 1 to SetupRef.FieldCount() do begin
                    SetupField := SetupRef.FieldIndex(Index);
                    if (SetupField.Type() = FieldType::Boolean) and (SetupField.Class() = FieldClass::Normal) then begin
                        IsSet := SetupField.Value();
                        if IsSet then begin
                            if Flags.Length() > 0 then
                                Flags.Append(',');
                            Flags.Append(SetupField.Name());
                        end;
                    end;
                end;
                Rows.Append(StrSubstNo(' set: %1', Flags.ToText()));
            end;
        until SetupRef.Next() = 0;
        if RowCount > 10 then
            Rows.Append(StrSubstNo(' (+%1 more)', RowCount - 10));
        exit(StrSubstNo('%1 row(s)%2', RowCount, Rows.ToText()));
    end;

#if BCDEVENV_PERMISSIONSMOCK
    local procedure PermissionsMockState(): Text
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        if PermissionsMock.IsStarted() then
            exit('started');
        exit('stopped');
    end;
#else
    local procedure PermissionsMockState(): Text
    begin
        exit('n/a (Permissions Mock not installed)');
    end;
#endif

    local procedure SingleLine(Value: Text): Text
    var
        Cr: Text[1];
        Lf: Text[1];
    begin
        Cr[1] := 13;
        Lf[1] := 10;
        exit(Value.Replace(Cr, ' ').Replace(Lf, ' '));
    end;
}
