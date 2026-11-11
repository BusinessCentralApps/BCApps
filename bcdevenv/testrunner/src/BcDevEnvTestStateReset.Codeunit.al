// Resets the session state that the Microsoft Test Runner resets around every test method: codeunit
// 130453 "ALTestRunner Reset Environment" (BeforeTestMethod / AfterCodeunitRun, including 130302 "Set
// State Test Run" for methods whose TestPermissions is not Disabled) and the permissions mock that "Test
// Runner - Mgt" starts and stops around each test. The AL tool's runtests runs the tests through the
// server's development test runner, which raises none of those events, so 'bcdevenv run-tests --executor
// altool' runs one of the reset test codeunits (50103 / 50104 / 50106) before every test codeunit. The
// reset therefore works per codeunit, not per test method.
//
// Optional objects are run through AllObj checks, as 130453 does, so this app gains no dependencies
// on test libraries. Only the permissions mock is referenced directly; the pipeline compiles that
// part (preprocessor symbol BCDEVENV_PERMISSIONSMOCK, plus the dependency on "Permissions Mock")
// only when the Permissions Mock app is installed.
namespace BcDevEnv.TestRunner;

using System.Reflection;
#if BCDEVENV_PERMISSIONSMOCK
using System.TestLibraries.Security.AccessControl;
#endif

codeunit 50102 "BcDevEnv Test State Reset"
{
    Access = Public;
    SingleInstance = true;

    var
        InitialWorkDate: Date;
        WorkDateSaved: Boolean;

    /// <summary>
    /// Resets the session before the next test codeunit.
    /// </summary>
    /// <param name="StartPermissionsMock">true: the permissions mock is (re)started without permission set assignments, the state the Test Runner gives every test; false: it is stopped.</param>
    procedure Reset(StartPermissionsMock: Boolean)
    begin
        Reset(StartPermissionsMock, false);
    end;

    /// <summary>
    /// Resets the session before the next test codeunit.
    /// </summary>
    /// <param name="StartPermissionsMock">true: the permissions mock is (re)started, the state the Test Runner gives every test; false: it is stopped.</param>
    /// <param name="FullAccessBase">With StartPermissionsMock: also run codeunit 130302 "Set State Test Run" (when present), which assigns the D365 Full Access base the Test Runner gives every test method whose TestPermissions is not Disabled; otherwise the mock has no assignments.</param>
    procedure Reset(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    begin
        // 130453 BeforeTestMethod / AfterCodeunitRun
        ClearLastError();
        ApplicationArea('');
        RestoreWorkDate();

#if BCDEVENV_PERMISSIONSMOCK
        // Dispose the previous codeunit's mock and its assignments first: Permissions Mock's Start
        // (also called by 130301 and 130302) replaces the mock without disposing it.
        StopPermissionsMock();
#endif
        // codeunit 130301 "Reset State Before Test Run": random seed 1, the legacy permission catalog
        // (which starts the permissions mock) and the temporary notification context.
        RunIfPresent(130301);
#if BCDEVENV_PERMISSIONSMOCK
        if StartPermissionsMock then begin
            if FullAccessBase then
                SetFullAccessBase();
            StartPermissionsMockWithoutAssignments();
        end else
            StopPermissionsMock();
#endif
        // codeunit 132553 "Block Changes to System Tables" (Prevent Metadata Updates Library, which the
        // pipeline does not publish, like the native one).
        RunIfPresent(132553);
        ClearLastError();
    end;

    // The work date of the session when the first codeunit started (130453 saves it when the test run starts).
    local procedure RestoreWorkDate()
    begin
        if not WorkDateSaved then begin
            InitialWorkDate := WorkDate();
            WorkDateSaved := true;
            exit;
        end;
        WorkDate(InitialWorkDate);
    end;

    local procedure RunIfPresent(CodeunitId: Integer)
    begin
        if IsPresent(CodeunitId) then
            Codeunit.Run(CodeunitId);
    end;

    local procedure IsPresent(CodeunitId: Integer): Boolean
    var
        AllObj: Record AllObj;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Codeunit);
        AllObj.SetRange("Object ID", CodeunitId);
        exit(not AllObj.IsEmpty());
    end;

#if BCDEVENV_PERMISSIONSMOCK
    // codeunit 130302 "Set State Test Run" (Tests-TestLibraries): Permission Test Catalog's Restrictive
    // initialization, which starts the permissions mock and assigns D365 Full Access with All Objects, Test
    // Tables, D365 Basic and LOCAL (when present), the base that Library - Lower Permissions lowers from.
    local procedure SetFullAccessBase()
    begin
        if not IsPresent(130302) then
            exit;
        // 130301 has just started a mock; dispose it before 130302 starts the next one.
        StopPermissionsMock();
        Codeunit.Run(130302);
    end;

    local procedure StartPermissionsMockWithoutAssignments()
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        // 130301 (or 130302) has just started a new mock when it is installed.
        if not PermissionsMock.IsStarted() then
            PermissionsMock.Start();
    end;

    local procedure StopPermissionsMock()
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        if PermissionsMock.IsStarted() then
            PermissionsMock.Stop();
    end;
#endif
}
