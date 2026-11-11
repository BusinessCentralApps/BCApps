// Records the effective TestPermissions of every test method while PrepareTests selects the tests:
// "Test Runner - Get Methods" (130452) raises OnGetTestMethods for every method it discovers, with the
// value the platform also passes to the Test Runner when the method runs. The Test Runner runs codeunit
// 130302 "Set State Test Run" (the D365 Full Access permission base) before every method whose value is
// not Disabled (130453 "ALTestRunner Reset Environment"); 'bcdevenv run-tests --executor altool' uses the
// values (testPermissions in the PrepareTests response) to choose the state reset of each codeunit.
namespace BcDevEnv.TestRunner;

using System.TestTools.TestRunner;

codeunit 50107 "BcDevEnv Test Perm. Capture"
{
    Access = Internal;
    EventSubscriberInstance = Manual;

    var
        MethodTestPermissions: Dictionary of [Text, Text];

    /// <summary>
    /// The TestPermissions value (Disabled, Restrictive, NonRestrictive) recorded for a test method; false when none was recorded.
    /// </summary>
    procedure GetTestPermissions(CodeunitId: Integer; FunctionName: Text; var Value: Text): Boolean
    begin
        exit(MethodTestPermissions.Get(MethodKey(CodeunitId, FunctionName), Value));
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Get Methods", 'OnGetTestMethods', '', false, false)]
    local procedure RecordTestPermissions(CodeunitID: Integer; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions)
    begin
        MethodTestPermissions.Set(MethodKey(CodeunitID, FunctionName), TestPermissionsName(FunctionTestPermissions));
    end;

    local procedure MethodKey(CodeunitId: Integer; FunctionName: Text): Text
    begin
        exit(Format(CodeunitId, 0, 9) + '|' + LowerCase(FunctionName));
    end;

    local procedure TestPermissionsName(Value: TestPermissions): Text
    begin
        case Value of
            TestPermissions::Disabled:
                exit('Disabled');
            TestPermissions::Restrictive:
                exit('Restrictive');
            TestPermissions::NonRestrictive:
                exit('NonRestrictive');
        end;
        exit(Format(Value));
    end;
}
