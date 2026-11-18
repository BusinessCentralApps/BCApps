// The System Application Test Library part of the BcDevEnv Test Runner: the step of the state reset (codeunit 50102
// "BcDevEnv Test State Reset") that resets single-instance state of System Application Test Library that test
// codeunits set and leave behind, and that the AL tool's session keeps for the next test codeunits. It runs after
// the committed "Application Area Setup" restore and before 130301, and sets the state of a new session: the
// testability flags of Environment Info Test Library (SaaS, sandbox, preview, early preview) off, and no secret
// provider in Azure Key Vault Test Library (the key vault client initializes again on its next use). The pipeline
// compiles this folder into the runner, with the dependency on System Application Test Library, only when that
// library is installed.
namespace BcDevEnv.TestRunner;

using System.TestLibraries.Azure.KeyVault;
using System.TestLibraries.Environment;

codeunit 50112 "BcDevEnv Sys. App. Lib. Reset"
{
    Access = Internal;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnResetSingleInstanceState, '', false, false)]
    local procedure ResetSystemApplicationTestLibraries()
    var
        EnvironmentInfoTestLibrary: Codeunit "Environment Info Test Library";
        AzureKeyVaultTestLibrary: Codeunit "Azure Key Vault Test Library";
    begin
        EnvironmentInfoTestLibrary.SetTestabilitySoftwareAsAService(false);
        EnvironmentInfoTestLibrary.SetTestabilitySandbox(false);
        EnvironmentInfoTestLibrary.SetTestabilityPreview(false);
        EnvironmentInfoTestLibrary.SetTestabilityEarlyPreview(false);
        AzureKeyVaultTestLibrary.ClearSecrets();
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnGetCompiledParts, '', false, false)]
    local procedure ReportCompiledPart(var SystemApplicationTestLibraryPart: Boolean)
    begin
        SystemApplicationTestLibraryPart := true;
    end;
}
