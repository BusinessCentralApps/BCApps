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
// next. The platform 30.0 server's code agrees (decompiled, not documented): the development test runner
// creates one session per invocation, opens the company once and runs every test codeunit of the batch in
// it; single-instance codeunits live in the session's company and nothing resets them between test
// codeunits (as in the Test Runner's single client session); for every test codeunit the server keeps the
// session's application area from the codeunit's start and sets it back after its test methods and at its
// end, rolls back what a codeunit with RequiredTestIsolation None (the default) or Codeunit wrote, in the
// tenant and the application database (isolated storage too, which is kept in the database), and commits
// what a Disabled codeunit wrote. Not observed: whether a work date set inside a codeunit carries over
// (the server's test codeunit runner has no work date handling; the probes saw one work date per job). The reset
//   * restores "Application Area Setup" to the baseline captured before the first test (codeunit 50108) and
//     commits (the reset codeunits have RequiredTestIsolation = Disabled), so that a row an earlier test
//     committed does not give the following logins its application area;
//   * with System Application Test Library installed (its part, codeunit 50112), resets single-instance state
//     of that library that test codeunits set and leave behind: the testability flags of Environment Info
//     Test Library (SaaS, sandbox, preview, early preview) back to off, and the secret provider and cache of
//     Azure Key Vault Test Library (ClearSecrets). Shpfy Test Shopify, for example, leaves SaaS on and a mock
//     key vault whose API version expiry date makes the later Shopify codeunits of the batch fail with "The
//     Shopify Admin API ... is no longer supported". Single-instance flags of other apps (Subscription
//     Billing's skip flags, for example) cannot be reset without depending on those apps, and the Shopify
//     connector's own API version cache (module isolated storage of the Shopify app) cannot be cleared from
//     here; it stays only when a codeunit with RequiredTestIsolation = Disabled commits it;
//   * with Permissions Mock installed (its part, codeunit 50111), sets up the permissions mock: started without
//     assignments, or with the D365 Full Access base of 130302 (that the base reaches the next codeunit is not
//     verified yet), or stopped;
//   * runs 130301 and 132553 when present; whether their state reaches the next codeunit is not verified;
//   * clears the last error, which otherwise reaches the next test codeunit (tests that assert an empty
//     GetLastErrorText failed with an earlier codeunit's error).
// The reset works per codeunit, not per test method. With the Permissions Mock part, it records the permissions
// mock base it applied (committed, isolated storage): when a test method of the codeunit initializes, codeunit
// 50110 (the Application Test Library part) clears the last error, sets the random seed 1, clears the temporary
// notification context and, when the Permissions Mock part finds the mock stopped (an earlier method stopped
// it), restarts it with that base through RestartStoppedPermissionsMock, as the Test Runner does before every method.
//
// Optional objects are run through AllObj checks, as 130453 does, so this app gains no dependencies
// on test libraries. Only Permissions Mock, Application Test Library and System Application Test Library
// are referenced directly, each by its own part: a folder of bcdevenv/testrunner-optional (PermissionsMock,
// ApplicationTestLibrary, SystemApplicationTestLibrary) that the pipeline copies into its copy of this app's
// source, with the dependency on the library, only when the library is installed. The parts subscribe to
// the internal events below, one event per step, so that no step depends on the order of subscribers; an
// event without its part does nothing. OnGetCompiledParts tells which parts were compiled in.
namespace BcDevEnv.TestRunner;

using System.Reflection;

codeunit 50102 "BcDevEnv Test State Reset"
{
    Access = Public;

    var
        MockBaseKeyTok: Label 'BcDevEnv.TestRun.PermissionsMockBase', Locked = true;
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
    /// Resets the test state before the next test codeunit: restores "Application Area Setup" and commits, resets the single-instance state of System Application Test Library (with its part), sets up the permissions mock (with its part) and clears the last error.
    /// </summary>
    /// <param name="StartPermissionsMock">true: the permissions mock is (re)started, the state the Test Runner gives every test; false: it is stopped.</param>
    /// <param name="FullAccessBase">With StartPermissionsMock: also run codeunit 130302 "Set State Test Run" (when present), which assigns the D365 Full Access base the Test Runner gives every test method whose TestPermissions is not Disabled; otherwise the mock has no assignments.</param>
    procedure Reset(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    var
        AppAreaSetupReset: Codeunit "BcDevEnv App Area Setup Reset";
    begin
        // Permissions Mock part: disposes the previous codeunit's mock and its assignments first (Permissions Mock's
        // Start, also called by 130301 and 130302, replaces the mock without disposing it; the restore below also
        // needs the real permissions), then records the base that a test method of the next codeunit restores when
        // it finds the mock stopped (codeunit 50110).
        OnStopPermissionsMockAndRecordBase(StartPermissionsMock, FullAccessBase);
        AppAreaSetupReset.Restore();
        // Keep the restore (and the recorded base) even when a later step fails.
        Commit();
        // System Application Test Library part: that library's single-instance state.
        OnResetSingleInstanceState();

        // codeunit 130301 "Reset State Before Test Run": random seed 1, the legacy permission catalog
        // (which starts the permissions mock) and the temporary notification context.
        RunIfPresent(130301);
        // Permissions Mock part: started without assignments, with the D365 Full Access base, or stopped.
        OnSetUpPermissionsMock(StartPermissionsMock, FullAccessBase);
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

    /// <summary>
    /// Restarts a stopped permissions mock with the base that the last state reset applied to the current test
    /// codeunit, as the Test Runner does before every test method: no assignments (codeunit 130301 "Reset State
    /// Before Test Run", which also sets the random seed 1 and clears the temporary notification context), or
    /// the D365 Full Access base (130301, then 130302 "Set State Test Run"). Does nothing when the mock is
    /// started (its assignments stay as the test set them), when the reset stopped the mock
    /// (--permissions-mock off), when no reset recorded a base since PrepareTests, or without the Permissions
    /// Mock part (codeunit 50111, which does the restart).
    /// </summary>
    /// <returns>Whether the mock was restarted.</returns>
    procedure RestartStoppedPermissionsMock(): Boolean
    var
        Restarted: Boolean;
    begin
        OnRestartStoppedPermissionsMock(Restarted);
        exit(Restarted);
    end;

    /// <summary>Records the permissions mock base of the current state reset (Permissions Mock part).</summary>
    internal procedure SetPermissionsMockBase(Base: Text)
    begin
        IsolatedStorage.Set(MockBaseKeyTok, Base, DataScope::Module);
    end;

    /// <summary>The permissions mock base that the last state reset recorded, if any (Permissions Mock part).</summary>
    internal procedure GetPermissionsMockBase(var Base: Text): Boolean
    begin
        exit(IsolatedStorage.Get(MockBaseKeyTok, DataScope::Module, Base));
    end;

    /// <summary>Whether the permissions mock is started, for the state probe.</summary>
    /// <returns>false without the Permissions Mock part (Started is then false).</returns>
    internal procedure GetPermissionsMockState(var Started: Boolean): Boolean
    var
        Handled: Boolean;
    begin
        Started := false;
        OnGetPermissionsMockState(Started, Handled);
        exit(Handled);
    end;

    /// <summary>Which optional parts (bcdevenv/testrunner-optional) were compiled into this app, for the state probe.</summary>
    internal procedure GetCompiledParts(var PermissionsMockPart: Boolean; var ApplicationTestLibraryPart: Boolean; var SystemApplicationTestLibraryPart: Boolean)
    begin
        PermissionsMockPart := false;
        ApplicationTestLibraryPart := false;
        SystemApplicationTestLibraryPart := false;
        OnGetCompiledParts(PermissionsMockPart, ApplicationTestLibraryPart, SystemApplicationTestLibraryPart);
    end;

    internal procedure RunIfPresent(CodeunitId: Integer)
    begin
        if IsPresent(CodeunitId) then
            Codeunit.Run(CodeunitId);
    end;

    internal procedure IsPresent(CodeunitId: Integer): Boolean
    var
        AllObj: Record AllObj;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Codeunit);
        AllObj.SetRange("Object ID", CodeunitId);
        exit(not AllObj.IsEmpty());
    end;

    // The steps of Reset that the optional parts implement. Internal: only the parts of this app subscribe.

    // Permissions Mock part: stops the mock and records the base for RestartStoppedPermissionsMock.
    [InternalEvent(false)]
    local procedure OnStopPermissionsMockAndRecordBase(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    begin
    end;

    // System Application Test Library part: resets that library's single-instance state.
    [InternalEvent(false)]
    local procedure OnResetSingleInstanceState()
    begin
    end;

    // Permissions Mock part: starts the mock without assignments or with the D365 Full Access base, or stops it.
    [InternalEvent(false)]
    local procedure OnSetUpPermissionsMock(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    begin
    end;

    // Permissions Mock part: restarts a stopped mock with the recorded base.
    [InternalEvent(false)]
    local procedure OnRestartStoppedPermissionsMock(var Restarted: Boolean)
    begin
    end;

    // Permissions Mock part: whether the mock is started.
    [InternalEvent(false)]
    local procedure OnGetPermissionsMockState(var Started: Boolean; var Handled: Boolean)
    begin
    end;

    // Every part sets its own flag.
    [InternalEvent(false)]
    local procedure OnGetCompiledParts(var PermissionsMockPart: Boolean; var ApplicationTestLibraryPart: Boolean; var SystemApplicationTestLibraryPart: Boolean)
    begin
    end;
}
