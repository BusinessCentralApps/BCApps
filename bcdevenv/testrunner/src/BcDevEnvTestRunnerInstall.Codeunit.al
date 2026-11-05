// Publishes the "BcDevEnvTestRunner" codeunit web service on install so the
// OData v4 action .../ODataV4/BcDevEnvTestRunner_RunAll is available to
// 'bcdevenv run-tests'. OnPrem only (CreateWebService is OnPrem-scoped), which
// matches the container's target.
namespace BcDevEnv.TestRunner;

using System.Integration;
using System.Reflection;

codeunit 50101 "BcDevEnv TR Install"
{
    Subtype = Install;
    Access = Internal;

    trigger OnInstallAppPerDatabase()
    begin
        PublishRunnerWebService();
    end;

    procedure PublishRunnerWebService()
    var
        AllObj: Record AllObj;
        WebServiceManagement: Codeunit "Web Service Management";
    begin
        WebServiceManagement.CreateWebService(
            AllObj."Object Type"::Codeunit,
            Codeunit::"BcDevEnv Test Runner",
            'BcDevEnvTestRunner',
            true);
    end;
}
