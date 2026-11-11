// Injected by 'bcdevenv run-tests --executor altool --permissions-mock off' before every test codeunit:
// resets the session and stops the permissions mock. Never selected as a test itself (the BcDevEnv Test
// Runner removes it from every suite) and left out of the results.
namespace BcDevEnv.TestRunner;

codeunit 50104 "BcDevEnv Reset Mock Stopped"
{
    Subtype = Test;
    TestPermissions = Disabled;

    [Test]
    procedure ResetTestState()
    var
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        TestStateReset.Reset(false);
    end;
}
