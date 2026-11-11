// Injected by 'bcdevenv run-tests --executor altool' before every test codeunit (--permissions-mock on,
// the default): resets the session and starts the permissions mock without assignments. Never selected
// as a test itself (the BcDevEnv Test Runner removes it from every suite) and left out of the results.
namespace BcDevEnv.TestRunner;

codeunit 50103 "BcDevEnv Reset Mock Started"
{
    Subtype = Test;
    TestPermissions = Disabled;

    [Test]
    procedure ResetTestState()
    var
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        TestStateReset.Reset(true);
    end;
}
