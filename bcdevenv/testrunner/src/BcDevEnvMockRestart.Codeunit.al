// Restarts a stopped permissions mock at the start of a test method, for 'bcdevenv run-tests --executor altool'.
// The Microsoft Test Runner restarts the mock before every test method (codeunit 130301 "Reset State Before Test
// Run", plus 130302 "Set State Test Run" when the method's TestPermissions is not Disabled). The AL tool's runtests
// raises no per-method event, so the state reset (codeunit 50102) runs only before every test codeunit: a method that
// stops the mock (Library - Lower Permissions' StopLoggingNAVPermissions) left it stopped for the later methods of
// the codeunit, whose Library - Lower Permissions calls then did nothing, so they ran with the real permissions.
//
// Test methods that initialize through "Library - Test Initialize" (Application Test Library) raise OnTestInitialize
// first. While a test run is active (codeunit 50109) and the mock is stopped, this subscriber restarts it with the
// base that the state reset recorded for the current codeunit (50102 RestartStoppedPermissionsMock): no assignments,
// or the D365 Full Access base; nothing when the reset stopped the mock (--permissions-mock off). A started mock is
// never touched, so assignments that a test made before its Initialize (SetOutsideO365Scope, SetO365BusFull, ...)
// stay. Methods that do not raise OnTestInitialize are not covered.
//
// The restarts are not counted: a count written in the test session is rolled back by the test isolation, and a
// commit there would change the test's transaction.
//
// Compiled only when both Application Test Library and Permissions Mock are installed: the pipeline then adds
// both dependencies and the preprocessor symbols BCDEVENV_APPTESTLIB and BCDEVENV_PERMISSIONSMOCK to its copy of
// app.json. Otherwise this file declares nothing.
#if BCDEVENV_APPTESTLIB
#if BCDEVENV_PERMISSIONSMOCK
namespace BcDevEnv.TestRunner;

using System.TestLibraries.Security.AccessControl;

codeunit 50110 "BcDevEnv Mock Restart"
{
    Access = Internal;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Library - Test Initialize", OnTestInitialize, '', false, false)]
    local procedure RestartStoppedMockOnTestInitialize(CallerCodeunitID: Integer)
    var
        PermissionsMock: Codeunit "Permissions Mock";
        LoginAppArea: Codeunit "BcDevEnv Login App Area";
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        // Most test methods find the mock started: keep this path cheap.
        if PermissionsMock.IsStarted() then
            exit;
        if not LoginAppArea.IsRunActive() then
            exit;
        TestStateReset.RestartStoppedPermissionsMock();
    end;
}
#endif
#endif
