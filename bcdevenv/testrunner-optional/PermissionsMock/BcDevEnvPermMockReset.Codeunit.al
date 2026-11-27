// The Permissions Mock part of the BcDevEnv Test Runner: the permissions mock steps of the state reset (codeunit
// 50102 "BcDevEnv Test State Reset"), which subscribe to its internal events. The pipeline compiles this folder into
// the runner, with the dependency on Permissions Mock, only when Permissions Mock is installed (whatever
// --permissions-mock says); without it, the state reset does not control the permissions mock and the state probe
// reports it as n/a.
//   * Before the "Application Area Setup" restore and its commit: stops the previous codeunit's mock (Permissions
//     Mock's Start, also called by 130301 and 130302, replaces the mock without disposing it; the restore also needs
//     the real permissions) and records the base of this reset, for a test method that finds the mock stopped.
//   * After 130301: starts the mock without assignments, or with the D365 Full Access base of 130302, or stops it.
//   * On a test method's Initialize (codeunit 50110, the Application Test Library part, through
//     RestartStoppedPermissionsMock): restarts a stopped mock with the recorded base, as the Test Runner does before
//     every test method. A started mock is never touched.
namespace BcDevEnv.TestRunner;

using System.TestLibraries.Security.AccessControl;

codeunit 50111 "BcDevEnv Perm. Mock Reset"
{
    Access = Internal;

    var
        NoAssignmentsBaseTok: Label 'no assignments', Locked = true;
        FullAccessBaseTok: Label 'D365 Full Access', Locked = true;
        StoppedBaseTok: Label 'stopped', Locked = true;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnStopPermissionsMockAndRecordBase, '', false, false)]
    local procedure StopPermissionsMockAndRecordBase(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    var
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
        Base: Text;
    begin
        StopPermissionsMock();
        Base := StoppedBaseTok;
        if StartPermissionsMock then
            if FullAccessBase then
                Base := FullAccessBaseTok
            else
                Base := NoAssignmentsBaseTok;
        TestStateReset.SetPermissionsMockBase(Base);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnSetUpPermissionsMock, '', false, false)]
    local procedure SetUpPermissionsMock(StartPermissionsMock: Boolean; FullAccessBase: Boolean)
    begin
        if StartPermissionsMock then begin
            if FullAccessBase then
                SetFullAccessBase();
            StartPermissionsMockWithoutAssignments();
        end else
            StopPermissionsMock();
    end;

    // Only a stopped mock, and only with a base that a state reset recorded since PrepareTests: no assignments
    // (130301, which also sets the random seed 1 and clears the temporary notification context) or the D365 Full
    // Access base (130301, then 130302); nothing when the reset stopped the mock (--permissions-mock off).
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnRestartStoppedPermissionsMock, '', false, false)]
    local procedure RestartStoppedPermissionsMock(var Restarted: Boolean)
    var
        PermissionsMock: Codeunit "Permissions Mock";
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
        Base: Text;
    begin
        if PermissionsMock.IsStarted() then
            exit;
        if not TestStateReset.GetPermissionsMockBase(Base) then
            exit;
        case Base of
            NoAssignmentsBaseTok:
                TestStateReset.RunIfPresent(130301);
            FullAccessBaseTok:
                begin
                    TestStateReset.RunIfPresent(130301);
                    SetFullAccessBase();
                end;
            else
                exit;
        end;
        StartPermissionsMockWithoutAssignments();
        Restarted := true;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnGetPermissionsMockState, '', false, false)]
    local procedure GetPermissionsMockState(var Started: Boolean; var Handled: Boolean)
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        Started := PermissionsMock.IsStarted();
        Handled := true;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"BcDevEnv Test State Reset", OnGetCompiledParts, '', false, false)]
    local procedure ReportCompiledPart(var PermissionsMockPart: Boolean)
    begin
        PermissionsMockPart := true;
    end;

    // codeunit 130302 "Set State Test Run" (Tests-TestLibraries): Permission Test Catalog's Restrictive
    // initialization, which starts the permissions mock and assigns D365 Full Access with All Objects, Test
    // Tables, D365 Basic and LOCAL (when present), the base that Library - Lower Permissions lowers from.
    local procedure SetFullAccessBase()
    var
        TestStateReset: Codeunit "BcDevEnv Test State Reset";
    begin
        if not TestStateReset.IsPresent(130302) then
            exit;
        // 130301 has just started a mock; dispose it before 130302 starts the next one.
        StopPermissionsMock();
        Codeunit.Run(130302);
    end;

    local procedure StartPermissionsMockWithoutAssignments()
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        // 130301 (or 130302) has just started a new mock when it is installed.
        if not PermissionsMock.IsStarted() then
            PermissionsMock.Start();
    end;

    local procedure StopPermissionsMock()
    var
        PermissionsMock: Codeunit "Permissions Mock";
    begin
        if PermissionsMock.IsStarted() then
            PermissionsMock.Stop();
    end;
}
