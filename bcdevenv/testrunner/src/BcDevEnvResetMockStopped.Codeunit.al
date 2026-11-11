// Injected by 'bcdevenv run-tests --executor altool --permissions-mock off' before every test codeunit:
// resets the test state that carries over between test codeunits (codeunit 50102: "Application Area Setup",
// the last error) and stops the permissions mock. Never selected as a test itself (the BcDevEnv Test Runner
// removes it from every suite) and left out of the results.
//
// RequiredTestIsolation = Disabled so that the server commits the restore; the server applies it to this
// codeunit only, the next test codeunit runs with its own RequiredTestIsolation.
//
// The server rejects a test method that occurs twice in one runtests call ("Test case name ... is not
// unique"), so the n-th reset of a batch runs method ResetTestState<nn> (01..50, all identical). The
// count is AlToolTestRunner.ResetMethodCount, which also caps --altool-batch-size.
namespace BcDevEnv.TestRunner;

codeunit 50104 "BcDevEnv Reset Mock Stopped"
{
    Subtype = Test;
    TestPermissions = Disabled;
    RequiredTestIsolation = Disabled;

    [Test]
    procedure ResetTestState01()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState02()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState03()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState04()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState05()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState06()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState07()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState08()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState09()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState10()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState11()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState12()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState13()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState14()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState15()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState16()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState17()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState18()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState19()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState20()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState21()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState22()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState23()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState24()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState25()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState26()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState27()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState28()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState29()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState30()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState31()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState32()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState33()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState34()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState35()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState36()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState37()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState38()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState39()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState40()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState41()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState42()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState43()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState44()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState45()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState46()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState47()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState48()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState49()
    begin
        RunStateReset();
    end;

    [Test]
    procedure ResetTestState50()
    begin
        RunStateReset();
    end;

    local procedure RunStateReset()
    var
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        TestStateReset.Reset(false);
    end;
}
