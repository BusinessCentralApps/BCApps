// Resets the state of every test method that initializes, for 'bcdevenv run-tests --executor altool'. The Microsoft
// Test Runner does that before every test method: codeunit 130453 "ALTestRunner Reset Environment" clears the last
// error and restarts the permissions mock (codeunit 130301 "Reset State Before Test Run", plus 130302 "Set State Test
// Run" when the method's TestPermissions is not Disabled), and "Test Runner - Mgt" clears the last error again after
// the method. The AL tool's runtests raises no per-method event, so the state reset (codeunit 50102) runs only before
// every test codeunit, and within the codeunit
//   * the last error of one method reached the next: tests that assert an empty GetLastErrorText (in a handler, for
//     example) failed with the previous method's error;
//   * a method that stops the mock (Library - Lower Permissions' StopLoggingNAVPermissions) left it stopped for the
//     later methods, whose Library - Lower Permissions calls then did nothing, so they ran with the real permissions.
//
// Test methods that initialize through "Library - Test Initialize" (Application Test Library) raise OnTestInitialize
// first. While a test run is active (codeunit 50109), this subscriber clears the last error and, when the mock is
// stopped, restarts it with the base that the state reset recorded for the current codeunit (50102
// RestartStoppedPermissionsMock): no assignments, or the D365 Full Access base; nothing when the reset stopped the
// mock (--permissions-mock off). A started mock is never touched, so assignments that a test made before its
// Initialize (SetOutsideO365Scope, SetO365BusFull, ...) stay. Methods that do not raise OnTestInitialize are not
// covered, and it runs at Initialize, not before the method.
//
// The restarts are not counted: a count written in the test session is rolled back by the test isolation, and a
// commit there would change the test's transaction.
//
// Compiled only when both Application Test Library and Permissions Mock are installed (whatever --permissions-mock
// says): the pipeline then adds both dependencies and the preprocessor symbols BCDEVENV_APPTESTLIB and
// BCDEVENV_PERMISSIONSMOCK to its copy of app.json. Otherwise this file declares nothing.
#if BCDEVENV_APPTESTLIB
#if BCDEVENV_PERMISSIONSMOCK
namespace BcDevEnv.TestRunner;

using System.TestLibraries.Security.AccessControl;

codeunit 50110 "BcDevEnv Mock Restart"
{
    Access = Internal;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Library - Test Initialize", OnTestInitialize, '', false, false)]
    local procedure ResetTestMethodStateOnTestInitialize(CallerCodeunitID: Integer)
    var
        PermissionsMock: Codeunit "Permissions Mock";
        LoginAppArea: Codeunit "BcDevEnv Login App Area";
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        if not LoginAppArea.IsRunActive() then
            exit;
        ClearLastError();
        if PermissionsMock.IsStarted() then
            exit;
        TestStateReset.RestartStoppedPermissionsMock();
    end;
}
#endif
#endif
