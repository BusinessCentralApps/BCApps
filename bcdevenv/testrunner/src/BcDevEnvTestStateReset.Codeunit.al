// The state reset that 'bcdevenv run-tests --executor altool' runs before every test codeunit (through the
// reset test codeunits 50103 / 50104 / 50106), in place of what the Microsoft Test Runner does around every
// test method: codeunit 130453 "ALTestRunner Reset Environment" (BeforeTestMethod / AfterCodeunitRun,
// including 130302 "Set State Test Run" for methods whose TestPermissions is not Disabled) and the
// permissions mock that "Test Runner - Mgt" starts and stops around each test. The AL tool's runtests runs
// the tests through the server's development test runner, which raises none of those events.
//
// Observed in CI (state probe, login hook counters, test failures): every AL tool invocation (one batch of
// one isolation pass) logs in once (one OnCompanyOpenCompleted, codeunit 50109). Within an invocation the
// last error, single-instance state and the permissions mock with its assignments carry over from one test
// codeunit to the next, and from one test method to the next. SessionId() differs in every test codeunit,
// and an application area set inside one codeunit (by an earlier version of this reset) was not seen in the
// next. Not observed yet: whether the ApplicationArea('') that 50109 sets at login reaches every codeunit of
// the invocation (W1 logins had no application area to clear) and whether a work date set inside a codeunit
// carries over. The reset
//   * restores "Application Area Setup" to the baseline captured before the first test (codeunit 50108) and
//     commits (the reset codeunits have RequiredTestIsolation = Disabled), so that a row an earlier test
//     committed does not give the following logins its application area;
//   * sets up the permissions mock: started without assignments, or with the D365 Full Access base of 130302
//     (that the base reaches the next codeunit is not verified yet), or stopped;
//   * runs 130301 and 132553 when present; whether their state reaches the next codeunit is not verified;
//   * clears the last error, which otherwise reaches the next test codeunit (tests that assert an empty
//     GetLastErrorText failed with an earlier codeunit's error).
// The reset works per codeunit, not per test method. It records the permissions mock base it applied
// (committed, isolated storage): when a test method of the codeunit initializes, codeunit 50110 clears the
// last error and, when it finds the mock stopped (an earlier method stopped it), restarts it with that base
// through RestartStoppedPermissionsMock, as the Test Runner does before every method.
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

    var
        MockBaseKeyTok: Label 'BcDevEnv.TestRun.PermissionsMockBase', Locked = true;
        NoAssignmentsBaseTok: Label 'no assignments', Locked = true;
        FullAccessBaseTok: Label 'D365 Full Access', Locked = true;
        StoppedBaseTok: Label 'stopped', Locked = true;
        NoBaseTxt: Label 'none recorded', Locked = true;

    /// <summary>
    /// Resets the test state before the next test codeunit.
    /// </summary>
    /// <param name="StartPermissionsMock">true: the permissions mock is (re)started without permission set assignments, the state the Test Runner gives every test; false: it is stopped.</param>
    procedure Reset(StartPermissionsMock: Boolean)
    begin
        Reset(StartPermissionsMock, false);
    end;

    /// <summary>
    /// Resets the test state before the next test codeunit: restores "Application Area Setup" and commits, sets up the permissions mock and clears the last error.
    /// </summary>
    /// <param name="StartPermissionsMock">true: the permissions mock is (re)started, the state the Test Runner gives every test; false: it is stopped.</param>
    /// <param name="FullAccessBase">With StartPermissionsMock: also run codeunit 130302 "Set State Test Run" (when present), which assigns the D365 Full Access base the Test Runner gives every test method whose TestPermissions is not Disabled; otherwise the mock has no assignments.</param>
    procedure Reset(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    var
        AppAreaSetupReset: Codeunit "BcDevEnv App Area Setup Reset";
    begin
#if BCDEVENV_PERMISSIONSMOCK
        // Dispose the previous codeunit's mock and its assignments first: Permissions Mock's Start
        // (also called by 130301 and 130302) replaces the mock without disposing it. The restore below
        // also needs the real permissions.
        StopPermissionsMock();
        // The base that a test method of the next codeunit restores when it finds the mock stopped (codeunit 50110).
        SetPermissionsMockBase(StartPermissionsMock, FullAccessBase);
#endif
        AppAreaSetupReset.Restore();
        // Keep the restore (and the recorded base) even when a later step fails.
        Commit();

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
        // pipeline does not publish, like the native one). It binds its subscribers in this session.
        RunIfPresent(132553);
        // Last: also drops errors that the steps above caught. The last error carries over to the next test
        // codeunit of the AL tool invocation; 130453 clears it before every test method, Test Runner - Mgt after.
        ClearLastError();
    end;

    /// <summary>
    /// Forgets the permissions mock base that the last state reset recorded (PrepareTests and EndTestRun), so that
    /// RestartStoppedPermissionsMock does nothing until the next state reset.
    /// </summary>
    procedure ClearPermissionsMockBase()
    begin
        if IsolatedStorage.Contains(MockBaseKeyTok, DataScope::Module) then
            IsolatedStorage.Delete(MockBaseKeyTok, DataScope::Module);
    end;

    /// <summary>The permissions mock base that the last state reset recorded, for the state probe.</summary>
    procedure GetPermissionsMockBaseText(): Text
    var
        Base: Text;
    begin
        if IsolatedStorage.Get(MockBaseKeyTok, DataScope::Module, Base) then
            exit(Base);
        exit(NoBaseTxt);
    end;

#if BCDEVENV_PERMISSIONSMOCK
    /// <summary>
    /// Restarts a stopped permissions mock with the base that the last state reset applied to the current test
    /// codeunit, as the Test Runner does before every test method: no assignments (codeunit 130301 "Reset State
    /// Before Test Run", which also sets the random seed 1 and clears the temporary notification context), or
    /// the D365 Full Access base (130301, then 130302 "Set State Test Run"). Does nothing when the mock is
    /// started (its assignments stay as the test set them), when the reset stopped the mock
    /// (--permissions-mock off), or when no reset recorded a base since PrepareTests.
    /// </summary>
    /// <returns>Whether the mock was restarted.</returns>
    procedure RestartStoppedPermissionsMock(): Boolean
    var
        PermissionsMock: Codeunit "Permissions Mock";
        Base: Text;
    begin
        if PermissionsMock.IsStarted() then
            exit(false);
        if not IsolatedStorage.Get(MockBaseKeyTok, DataScope::Module, Base) then
            exit(false);
        case Base of
            NoAssignmentsBaseTok:
                RunIfPresent(130301);
            FullAccessBaseTok:
                begin
                    RunIfPresent(130301);
                    SetFullAccessBase();
                end;
            else
                exit(false);
        end;
        StartPermissionsMockWithoutAssignments();
        exit(true);
    end;

    local procedure SetPermissionsMockBase(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    var
        Base: Text;
    begin
        Base := StoppedBaseTok;
        if StartPermissionsMock then
            if FullAccessBase then
                Base := FullAccessBaseTok
            else
                Base := NoAssignmentsBaseTok;
        IsolatedStorage.Set(MockBaseKeyTok, Base, DataScope::Module);
    end;
#endif

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
