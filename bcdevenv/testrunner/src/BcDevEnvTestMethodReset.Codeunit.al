// Resets the state of every test method that initializes, for 'bcdevenv run-tests --executor altool'. The Microsoft
// Test Runner does that before every test method: codeunit 130453 "ALTestRunner Reset Environment" clears the last
// error and runs codeunit 130301 "Reset State Before Test Run" (random seed 1, the legacy permission catalog, which
// restarts the permissions mock, and the temporary notification context), plus 130302 "Set State Test Run" when the
// method's TestPermissions is not Disabled; "Test Runner - Mgt" clears the last error again after the method. The AL
// tool's runtests raises no per-method event, so the state reset (codeunit 50102) runs only before every test
// codeunit, and within the codeunit
//   * the last error of one method reached the next: tests that assert an empty GetLastErrorText (in a handler, for
//     example) failed with the previous method's error;
//   * the random sequence of Library - Random (single-instance) went on from the previous method, so the values a
//     method draws depended on the methods that ran before it;
//   * a method that stops the mock (Library - Lower Permissions' StopLoggingNAVPermissions) left it stopped for the
//     later methods, whose Library - Lower Permissions calls then did nothing, so they ran with the real permissions.
//
// Test methods that initialize through "Library - Test Initialize" (Application Test Library) raise OnTestInitialize
// first. While a test run is active (codeunit 50109), this subscriber
//   * clears the last error;
//   * sets the random seed 1 (Library - Random's SetSeed) and clears the temporary notification context (Library -
//     Notification Mgt.), as 130301 does;
//   * with Permissions Mock, when the mock is stopped, restarts it with the base that the state reset recorded for
//     the current codeunit (50102 RestartStoppedPermissionsMock): no assignments, or the D365 Full Access base;
//     nothing when the reset stopped the mock (--permissions-mock off). A started mock is never touched, so
//     assignments that a test made before its Initialize (SetOutsideO365Scope, SetO365BusFull, ...) stay.
// Methods that do not raise OnTestInitialize are not covered, and it runs at Initialize, not before the method.
//
// The restarts are not counted: a count written in the test session is rolled back by the test isolation, and a
// commit there would change the test's transaction.
//
// Compiled only when Application Test Library is installed: the pipeline then adds the dependency and the
// preprocessor symbol BCDEVENV_APPTESTLIB to its copy of app.json. The restart of a stopped mock also needs
// BCDEVENV_PERMISSIONSMOCK (Permissions Mock installed, whatever --permissions-mock says). Without Application Test
// Library this file declares nothing.
#if BCDEVENV_APPTESTLIB
namespace BcDevEnv.TestRunner;

#if BCDEVENV_PERMISSIONSMOCK
using System.TestLibraries.Security.AccessControl;
#endif

codeunit 50110 "BcDevEnv Test Method Reset"
{
    Access = Internal;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Library - Test Initialize", OnTestInitialize, '', false, false)]
    local procedure ResetTestMethodStateOnTestInitialize(CallerCodeunitID: Integer)
    var
        LibraryRandom: Codeunit "Library - Random";
        LibraryNotificationMgt: Codeunit "Library - Notification Mgt.";
        LoginAppArea: Codeunit "BcDevEnv Login App Area";
#if BCDEVENV_PERMISSIONSMOCK
        PermissionsMock: Codeunit "Permissions Mock";
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
#endif
    begin
        if not LoginAppArea.IsRunActive() then
            exit;
        ClearLastError();
        LibraryRandom.SetSeed(1);
        LibraryNotificationMgt.ClearTemporaryNotificationContext();
#if BCDEVENV_PERMISSIONSMOCK
        if PermissionsMock.IsStarted() then
            exit;
        TestStateReset.RestartStoppedPermissionsMock();
#endif
    end;
}
#endif
