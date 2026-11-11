// While a test run of 'bcdevenv run-tests' is active (from PrepareTests until the CLI calls EndTestRun), clears the
// application area of every client session that opens a company: ApplicationArea(''), as codeunit 130453
// "ALTestRunner Reset Environment" of the Test Runner does before every test method. The AL tool runs every test
// codeunit in a new client session, whose application area the Base Application sets at login from
// "Application Area Setup" (LogInManagement, on System Initialization's OnAfterInitialization, which is raised on
// Company Triggers' OnCompanyOpen). OnCompanyOpenCompleted is raised after all OnCompanyOpen subscribers, so this
// runs after that and before the test codeunit, in the test session itself. Only the session is changed, never the
// table: tests that read "Application Area Setup" keep the standard semantics.
//
// Every client session that opens a company while the run is active gets the empty application area (all controls
// visible), whoever the user is, interactive web client sessions included. A run that ends without EndTestRun (an
// aborted or killed CLI) leaves it active until a later run ends. The sessions are counted in isolated storage and
// reported by GetStateResetSummary of the BcDevEnv Test Runner.
namespace BcDevEnv.TestRunner;

using System.Environment;

codeunit 50109 "BcDevEnv Login App Area"
{
    Access = Internal;
    SingleInstance = true;

    var
        AreaAtLogin: Text;
        AppliedInSession: Boolean;
        ActiveKeyTok: Label 'BcDevEnv.TestRun.Active', Locked = true;
        CountersKeyTok: Label 'BcDevEnv.LoginApplicationArea.Counters', Locked = true;
        SessionsTok: Label 'loginSessions', Locked = true;
        SessionsWithAreaTok: Label 'loginSessionsWithArea', Locked = true;
        AppliedTxt: Label 'cleared ''%1'' at login; %2', Comment = '%1 = application area at login, %2 = counters', Locked = true;
        NotAppliedTxt: Label 'not applied in this session (test run active: %1); %2', Comment = '%1 = Yes/No, %2 = counters', Locked = true;
        CountersTxt: Label '%1 client session(s) since PrepareTests, %2 with an application area at login', Comment = '%1 = sessions, %2 = sessions with an application area', Locked = true;

    // Runs at every company open, so it must stay cheap and never fail: the isolated storage calls use their Boolean
    // return value instead of raising an error.
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Company Triggers", OnCompanyOpenCompleted, '', false, false)]
    local procedure ClearApplicationAreaOnCompanyOpenCompleted()
    begin
        if not GuiAllowed() then
            exit;
        if not IsRunActive() then
            exit;
        AreaAtLogin := ApplicationArea();
        ApplicationArea('');
        AppliedInSession := true;
        CountSession(AreaAtLogin <> '');
    end;

    /// <summary>
    /// Starts a test run (PrepareTests): from now on every client session that opens a company gets ApplicationArea('').
    /// Clears the session counters.
    /// </summary>
    procedure StartRun()
    begin
        IsolatedStorage.Set(ActiveKeyTok, Format(CurrentDateTime(), 0, 9), DataScope::Module);
        if IsolatedStorage.Contains(CountersKeyTok, DataScope::Module) then
            IsolatedStorage.Delete(CountersKeyTok, DataScope::Module);
    end;

    /// <summary>
    /// Ends the test run: new client sessions keep the application area they get at login again. Returns whether a
    /// run was active. The counters stay until the next StartRun.
    /// </summary>
    procedure EndRun(): Boolean
    begin
        if not IsolatedStorage.Contains(ActiveKeyTok, DataScope::Module) then
            exit(false);
        IsolatedStorage.Delete(ActiveKeyTok, DataScope::Module);
        exit(true);
    end;

    /// <summary>
    /// Adds the session counters since the last PrepareTests to the state reset summary: loginSessions (client
    /// sessions that got ApplicationArea('') at login) and loginSessionsWithArea (those that had one set at login).
    /// </summary>
    procedure AddSummary(var Summary: JsonObject)
    var
        Counters: JsonObject;
    begin
        ReadCounters(Counters);
        Summary.Add(SessionsTok, GetCounter(Counters, SessionsTok));
        Summary.Add(SessionsWithAreaTok, GetCounter(Counters, SessionsWithAreaTok));
    end;

    /// <summary>One segment for the state probe: what the hook did in the current session, and the counters.</summary>
    procedure GetSessionText(): Text
    var
        Counters: JsonObject;
        CountersText: Text;
    begin
        ReadCounters(Counters);
        CountersText := StrSubstNo(CountersTxt, GetCounter(Counters, SessionsTok), GetCounter(Counters, SessionsWithAreaTok));
        if AppliedInSession then
            exit(StrSubstNo(AppliedTxt, AreaAtLogin, CountersText));
        exit(StrSubstNo(NotAppliedTxt, IsRunActive(), CountersText));
    end;

    local procedure IsRunActive(): Boolean
    begin
        exit(IsolatedStorage.Contains(ActiveKeyTok, DataScope::Module));
    end;

    // Committed right away, so that the test isolation of the test codeunit that runs in this session cannot roll the
    // count back. The AL tool opens its sessions one after the other; concurrent logins may lose a count.
    local procedure CountSession(HadArea: Boolean)
    var
        Counters: JsonObject;
        CountersText: Text;
    begin
        ReadCounters(Counters);
        AddToCounter(Counters, SessionsTok, 1);
        if HadArea then
            AddToCounter(Counters, SessionsWithAreaTok, 1);
        Counters.WriteTo(CountersText);
        if IsolatedStorage.Set(CountersKeyTok, CountersText, DataScope::Module) then
            Commit();
    end;

    local procedure ReadCounters(var Counters: JsonObject)
    var
        CountersText: Text;
    begin
        Clear(Counters);
        if IsolatedStorage.Get(CountersKeyTok, DataScope::Module, CountersText) then
            if Counters.ReadFrom(CountersText) then
                exit;
        Clear(Counters);
    end;

    local procedure GetCounter(Counters: JsonObject; Name: Text): Integer
    var
        Value: JsonToken;
    begin
        if Counters.Get(Name, Value) then
            if Value.IsValue() then
                exit(Value.AsValue().AsInteger());
        exit(0);
    end;

    local procedure AddToCounter(var Counters: JsonObject; Name: Text; Increment: Integer)
    var
        NewValue: Integer;
    begin
        NewValue := GetCounter(Counters, Name) + Increment;
        if Counters.Contains(Name) then
            Counters.Replace(Name, NewValue)
        else
            Counters.Add(Name, NewValue);
    end;
}
