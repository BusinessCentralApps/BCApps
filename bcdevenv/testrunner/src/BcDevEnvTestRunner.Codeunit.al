// Runs the installed Business Central test codeunits via the Microsoft test
// framework toolkit and returns the results as an xUnit document, which
// 'bcdevenv run-tests' converts to JUnit. Published as the "BcDevEnvTestRunner"
// web service (see BcDevEnvTestRunnerInstall), so each procedure below is an
// OData v4 unbound action named BcDevEnvTestRunner_<Procedure>.
//
// Two protocols are exposed:
//   * RunAll                         - legacy single call: build a suite and run it all.
//   * PrepareTests / RunCodeunit /   - per-codeunit protocol used by the pipeline: build the
//     GetCodeunitResults               suite once (applying test categorization, the test runner
//                                      and the disabled tests BEFORE anything runs), then run one
//                                      codeunit per call so a hung/failed call only loses that
//                                      codeunit and progress can be reported.
//
// All action parameters are Text (the type proven to round-trip over OData); numeric values are
// parsed inside the procedures.
namespace BcDevEnv.TestRunner;

using System.TestTools.TestRunner;
using System.Reflection;

codeunit 50100 "BcDevEnv Test Runner"
{
    Access = Public;

    var
        DisabledReasonTxt: Label 'Disabled by DisabledTests', Locked = true;
        RunnerSkippedReasonTxt: Label 'Skipped by the test runner', Locked = true;
        NotExecutedTxt: Label 'The test was selected but not executed (the codeunit most likely failed before or during OnRun).', Locked = true;
        InvalidIntegerErr: Label 'Parameter %1 must be an integer, but was ''%2''.', Comment = '%1 = parameter name, %2 = value', Locked = true;
        InvalidExtensionIdErr: Label 'extensionId ''%1'' is not a valid GUID.', Comment = '%1 = value', Locked = true;
        CodeunitLineNotFoundErr: Label 'Test suite %1 has no codeunit line %2. Call PrepareTests first.', Comment = '%1 = suite, %2 = line no.', Locked = true;
        InvalidDisabledTestsErr: Label 'disabledTestsJson must be a JSON array of {"codeunitName": text, "methods": [text]} objects.', Locked = true;

    /// <summary>
    /// Runs the selected tests and returns an xUnit result document (legacy single-call protocol).
    /// </summary>
    /// <param name="testSuite">Suite code to (re)build and run; blank = DEFAULT.</param>
    /// <param name="extensionId">When set, only run tests from this app (GUID); blank = all test codeunits.</param>
    /// <param name="testCodeunitFilter">Optional codeunit-id filter applied when extensionId is blank.</param>
    procedure RunAll(testSuite: Text; extensionId: Text; testCodeunitFilter: Text): Text
    var
        ALTestSuite: Record "AL Test Suite";
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        SuiteName: Code[10];
    begin
        SuiteName := GetSuiteName(testSuite);
        RecreateSuite(SuiteName, ALTestSuite);

        // Select the tests to run.
        if extensionId <> '' then
            TestSuiteMgt.SelectTestMethodsByExtension(ALTestSuite, extensionId)
        else
            TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, testCodeunitFilter);
        ExcludeStateResetCodeunits(SuiteName);

        // Run everything in the suite.
        TestMethodLine."Test Suite" := SuiteName;
        TestSuiteMgt.RunAllTests(TestMethodLine);

        exit(BuildXUnit(SuiteName));
    end;

    /// <summary>
    /// (Re)builds a test suite without running anything and returns a JSON description of its codeunits.
    /// Disabled tests are applied here, so they are excluded before execution.
    /// </summary>
    /// <param name="testSuite">Suite code to (re)build; blank = DEFAULT.</param>
    /// <param name="extensionId">When set, only select tests from this app (GUID).</param>
    /// <param name="testCodeunitFilter">Optional codeunit-id filter.</param>
    /// <param name="testType">0 = no categorization filter; 1 = UnitTest, 2 = IntegrationTest, 3 = Uncategorized.</param>
    /// <param name="requiredTestIsolation">0 = None|Codeunit, 1 = Disabled, 2 = Codeunit, 3 = Function. Used only when testType > 0.</param>
    /// <param name="testRunnerCodeunitId">Test runner codeunit (e.g. 130450 Isol. Codeunit, 130451 Isol. Disabled); 0/blank = suite default.</param>
    /// <param name="disabledTestsJson">JSON array [{"codeunitName": "...", "methods": ["Method", "*"]}]; blank = none.</param>
    procedure PrepareTests(testSuite: Text; extensionId: Text; testCodeunitFilter: Text; testType: Text; requiredTestIsolation: Text; testRunnerCodeunitId: Text; disabledTestsJson: Text): Text
    var
        ALTestSuite: Record "AL Test Suite";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        DisabledMethods: Dictionary of [Text, List of [Text]];
        SuiteName: Code[10];
        TestTypeValue: Integer;
        IsolationValue: Integer;
        RunnerId: Integer;
    begin
        SuiteName := GetSuiteName(testSuite);
        TestTypeValue := ParseInteger(testType, 'testType');
        IsolationValue := ParseInteger(requiredTestIsolation, 'requiredTestIsolation');
        RunnerId := ParseInteger(testRunnerCodeunitId, 'testRunnerCodeunitId');
        ParseDisabledTests(disabledTestsJson, DisabledMethods);

        RecreateSuite(SuiteName, ALTestSuite);
        if RunnerId > 0 then
            TestSuiteMgt.ChangeTestRunner(ALTestSuite, RunnerId);

        if TestTypeValue > 0 then
            SelectByCategorization(ALTestSuite, extensionId, testCodeunitFilter, TestTypeValue, IsolationValue)
        else
            if extensionId <> '' then
                TestSuiteMgt.SelectTestMethodsByExtension(ALTestSuite, extensionId)
            else
                TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, testCodeunitFilter);

        ExcludeStateResetCodeunits(SuiteName);
        ApplyDisabledTests(SuiteName, DisabledMethods);
        Commit();

        ALTestSuite.Get(SuiteName);
        exit(BuildSuiteJson(ALTestSuite));
    end;

    /// <summary>
    /// Runs one prepared codeunit line (when it still has enabled tests) and returns its xUnit result.
    /// </summary>
    procedure RunCodeunit(testSuite: Text; codeunitLineNo: Text): Text
    var
        CodeunitLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        SuiteName: Code[10];
        LineNo: Integer;
        RunError: Text;
    begin
        SuiteName := GetSuiteName(testSuite);
        LineNo := ParseInteger(codeunitLineNo, 'codeunitLineNo');
        GetCodeunitLine(SuiteName, LineNo, CodeunitLine);

        if CodeunitLine.Run then begin
            ClearLastError();
            CodeunitLine.SetRange("Test Suite", SuiteName);
            CodeunitLine.SetRange("Line No.", LineNo);
            TestSuiteMgt.RunSelectedTests(CodeunitLine);
            // The test runner clears the last error after every test method, so anything left here
            // comes from the codeunit's OnRun / setup and explains tests that never started.
            RunError := GetLastErrorText();
        end;

        exit(BuildCodeunitXUnit(SuiteName, LineNo, RunError));
    end;

    /// <summary>
    /// Returns the xUnit result of one prepared codeunit line without running anything. Used for
    /// fully disabled codeunits and to recover the committed per-test results after a failed RunCodeunit call.
    /// </summary>
    procedure GetCodeunitResults(testSuite: Text; codeunitLineNo: Text): Text
    var
        SuiteName: Code[10];
        LineNo: Integer;
    begin
        SuiteName := GetSuiteName(testSuite);
        LineNo := ParseInteger(codeunitLineNo, 'codeunitLineNo');
        exit(BuildCodeunitXUnit(SuiteName, LineNo, ''));
    end;

    local procedure GetSuiteName(TestSuite: Text): Code[10]
    var
        SuiteName: Code[10];
    begin
        SuiteName := CopyStr(TestSuite, 1, MaxStrLen(SuiteName));
        if SuiteName = '' then
            SuiteName := 'DEFAULT';
        exit(SuiteName);
    end;

    local procedure RecreateSuite(var SuiteName: Code[10]; var ALTestSuite: Record "AL Test Suite")
    var
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
    begin
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        TestSuiteMgt.CreateTestSuite(SuiteName);
        ALTestSuite.Get(SuiteName);
    end;

    local procedure ParseInteger(Value: Text; ParameterName: Text): Integer
    var
        ParsedValue: Integer;
    begin
        if Value.Trim() = '' then
            exit(0);
        if not Evaluate(ParsedValue, Value.Trim()) then
            Error(InvalidIntegerErr, ParameterName, Value);
        exit(ParsedValue);
    end;

    // Mirrors the toolkit's SelectTestMethodsByExtensionAndTestCategorization (internal to the Test
    // Runner app) and additionally honours the codeunit-id filter.
    local procedure SelectByCategorization(var ALTestSuite: Record "AL Test Suite"; ExtensionId: Text; TestCodeunitFilter: Text; TestTypeValue: Integer; IsolationValue: Integer)
    var
        CodeunitMetadata: Record "CodeUnit Metadata";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        AppExtensionId: Guid;
    begin
        if ExtensionId <> '' then begin
            if not Evaluate(AppExtensionId, ExtensionId) then
                Error(InvalidExtensionIdErr, ExtensionId);
            CodeunitMetadata.SetRange("App ID", AppExtensionId);
        end;

        CodeunitMetadata.SetRange(SubType, CodeunitMetadata.SubType::Test);
        // implicit conversion from Integer to Option, as in the toolkit
        CodeunitMetadata.SetRange(TestType, TestTypeValue);
        if IsolationValue = 0 then
            // codeunits with RequiredTestIsolation None run together with the Codeunit ones
            CodeunitMetadata.SetFilter(RequiredTestIsolation, '%1|%2', CodeunitMetadata.RequiredTestIsolation::None, CodeunitMetadata.RequiredTestIsolation::Codeunit)
        else
            CodeunitMetadata.SetRange(RequiredTestIsolation, IsolationValue);

        if TestCodeunitFilter <> '' then
            CodeunitMetadata.SetFilter(ID, TestCodeunitFilter);

        TestSuiteMgt.GetTestMethods(ALTestSuite, CodeunitMetadata);
    end;

    // The state reset codeunits (and the diagnostic state probe) of this app are injected by 'bcdevenv run-tests
    // --executor altool'; they are never selected as tests (only matters without an extension filter).
    local procedure ExcludeStateResetCodeunits(SuiteName: Code[10])
    var
        TestMethodLine: Record "Test Method Line";
    begin
        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestMethodLine.SetFilter("Test Codeunit", '%1|%2|%3', Codeunit::"BcDevEnv Reset Mock Started", Codeunit::"BcDevEnv Reset Mock Stopped",
            Codeunit::"BcDevEnv State Probe");
        TestMethodLine.DeleteAll();
    end;

    // Disabled tests: [{"codeunitName": "...", "methods": ["...", "*"]}], keyed by lower-case codeunit name.
    local procedure ParseDisabledTests(DisabledTestsJson: Text; var DisabledMethods: Dictionary of [Text, List of [Text]])
    var
        Entries: JsonArray;
        Entry: JsonToken;
    begin
        if DisabledTestsJson.Trim() = '' then
            exit;
        if not Entries.ReadFrom(DisabledTestsJson) then
            Error(InvalidDisabledTestsErr);

        foreach Entry in Entries do begin
            if not Entry.IsObject() then
                Error(InvalidDisabledTestsErr);
            AddDisabledEntry(Entry.AsObject(), DisabledMethods);
        end;
    end;

    // Separate procedure so every entry starts from a fresh local list (List is a reference type).
    local procedure AddDisabledEntry(Entry: JsonObject; var DisabledMethods: Dictionary of [Text, List of [Text]])
    var
        FieldToken: JsonToken;
        MethodToken: JsonToken;
        Methods: List of [Text];
        CodeunitKey: Text;
        MethodPattern: Text;
    begin
        if not Entry.Get('codeunitName', FieldToken) then
            Error(InvalidDisabledTestsErr);
        CodeunitKey := LowerCase(FieldToken.AsValue().AsText().Trim());
        if CodeunitKey = '' then
            exit;
        if not Entry.Get('methods', FieldToken) then
            Error(InvalidDisabledTestsErr);
        if not FieldToken.IsArray() then
            Error(InvalidDisabledTestsErr);

        if DisabledMethods.ContainsKey(CodeunitKey) then
            DisabledMethods.Get(CodeunitKey, Methods);
        foreach MethodToken in FieldToken.AsArray() do begin
            MethodPattern := LowerCase(MethodToken.AsValue().AsText().Trim());
            if (MethodPattern <> '') and not Methods.Contains(MethodPattern) then
                Methods.Add(MethodPattern);
        end;
        DisabledMethods.Set(CodeunitKey, Methods);
    end;

    // Same effect as the Command Line Test Tool's DisableTestMethod: matching function lines get
    // Run = false (the test runner then never starts them), and a codeunit with no enabled function
    // left is itself set to Run = false so it is not executed at all. Codeunit names match exactly
    // (case-insensitive); method names match case-insensitively with '*'/'?' wildcards.
    local procedure ApplyDisabledTests(SuiteName: Code[10]; var DisabledMethods: Dictionary of [Text, List of [Text]])
    var
        CodeunitLine: Record "Test Method Line";
        CodeunitLineToUpdate: Record "Test Method Line";
        FunctionLine: Record "Test Method Line";
        Patterns: List of [Text];
    begin
        if DisabledMethods.Count() = 0 then
            exit;

        CodeunitLine.SetRange("Test Suite", SuiteName);
        CodeunitLine.SetRange("Line Type", CodeunitLine."Line Type"::Codeunit);
        if CodeunitLine.FindSet() then
            repeat
                if DisabledMethods.Get(LowerCase(CodeunitLine.Name), Patterns) then begin
                    FunctionLine.Reset();
                    FunctionLine.SetRange("Test Suite", SuiteName);
                    FunctionLine.SetRange("Test Codeunit", CodeunitLine."Test Codeunit");
                    FunctionLine.SetRange("Line Type", FunctionLine."Line Type"::Function);
                    if FunctionLine.FindSet(true) then
                        repeat
                            if FunctionLine.Run and IsMethodDisabled(LowerCase(FunctionLine.Name), Patterns) then begin
                                FunctionLine.Run := false;
                                FunctionLine.Modify();
                            end;
                        until FunctionLine.Next() = 0;

                    FunctionLine.SetRange(Run, true);
                    if FunctionLine.IsEmpty() then begin
                        CodeunitLineToUpdate.Get(CodeunitLine."Test Suite", CodeunitLine."Line No.");
                        CodeunitLineToUpdate.Run := false;
                        CodeunitLineToUpdate.Modify();
                    end;
                end;
            until CodeunitLine.Next() = 0;
    end;

    local procedure IsMethodDisabled(MethodName: Text; var Patterns: List of [Text]): Boolean
    var
        Pattern: Text;
    begin
        foreach Pattern in Patterns do begin
            if Pattern = '*' then
                exit(true);
            if (StrPos(Pattern, '*') > 0) or (StrPos(Pattern, '?') > 0) then begin
                if WildcardMatch(MethodName, Pattern) then
                    exit(true);
            end else
                if MethodName = Pattern then
                    exit(true);
        end;
        exit(false);
    end;

    // Iterative glob match supporting '*' (any sequence) and '?' (any single character).
    local procedure WildcardMatch(Value: Text; Pattern: Text): Boolean
    var
        ValuePos: Integer;
        PatternPos: Integer;
        StarPos: Integer;
        MatchPos: Integer;
    begin
        ValuePos := 1;
        PatternPos := 1;
        StarPos := 0;
        MatchPos := 0;
        while ValuePos <= StrLen(Value) do
            if (PatternPos <= StrLen(Pattern)) and ((Pattern[PatternPos] = '?') or (Pattern[PatternPos] = Value[ValuePos])) then begin
                ValuePos += 1;
                PatternPos += 1;
            end else
                if (PatternPos <= StrLen(Pattern)) and (Pattern[PatternPos] = '*') then begin
                    StarPos := PatternPos;
                    MatchPos := ValuePos;
                    PatternPos += 1;
                end else
                    if StarPos > 0 then begin
                        PatternPos := StarPos + 1;
                        MatchPos += 1;
                        ValuePos := MatchPos;
                    end else
                        exit(false);

        while (PatternPos <= StrLen(Pattern)) and (Pattern[PatternPos] = '*') do
            PatternPos += 1;
        exit(PatternPos > StrLen(Pattern));
    end;

    local procedure BuildSuiteJson(var ALTestSuite: Record "AL Test Suite"): Text
    var
        CodeunitLine: Record "Test Method Line";
        FunctionLine: Record "Test Method Line";
        SuiteJson: JsonObject;
        Codeunits: JsonArray;
        CodeunitJson: JsonObject;
        ResultText: Text;
        FunctionCount: Integer;
        DisabledCount: Integer;
        TotalFunctions: Integer;
        TotalDisabled: Integer;
    begin
        CodeunitLine.SetRange("Test Suite", ALTestSuite.Name);
        CodeunitLine.SetRange("Line Type", CodeunitLine."Line Type"::Codeunit);
        if CodeunitLine.FindSet() then
            repeat
                FunctionLine.Reset();
                FunctionLine.SetRange("Test Suite", ALTestSuite.Name);
                FunctionLine.SetRange("Test Codeunit", CodeunitLine."Test Codeunit");
                FunctionLine.SetRange("Line Type", FunctionLine."Line Type"::Function);
                FunctionCount := FunctionLine.Count();
                FunctionLine.SetRange(Run, false);
                DisabledCount := FunctionLine.Count();

                Clear(CodeunitJson);
                CodeunitJson.Add('lineNo', CodeunitLine."Line No.");
                CodeunitJson.Add('codeunitId', CodeunitLine."Test Codeunit");
                CodeunitJson.Add('name', CodeunitLine.Name);
                CodeunitJson.Add('run', CodeunitLine.Run);
                CodeunitJson.Add('functions', FunctionCount);
                CodeunitJson.Add('disabledFunctions', DisabledCount);
                Codeunits.Add(CodeunitJson);

                TotalFunctions += FunctionCount;
                TotalDisabled += DisabledCount;
            until CodeunitLine.Next() = 0;

        SuiteJson.Add('testSuite', Format(ALTestSuite.Name));
        SuiteJson.Add('testRunnerId', ALTestSuite."Test Runner Id");
        SuiteJson.Add('functions', TotalFunctions);
        SuiteJson.Add('disabledFunctions', TotalDisabled);
        SuiteJson.Add('codeunits', Codeunits);
        SuiteJson.WriteTo(ResultText);
        exit(ResultText);
    end;

    local procedure GetCodeunitLine(SuiteName: Code[10]; LineNo: Integer; var CodeunitLine: Record "Test Method Line")
    begin
        if not CodeunitLine.Get(SuiteName, LineNo) then
            Error(CodeunitLineNotFoundErr, SuiteName, LineNo);
        if CodeunitLine."Line Type" <> CodeunitLine."Line Type"::Codeunit then
            Error(CodeunitLineNotFoundErr, SuiteName, LineNo);
    end;

    local procedure BuildCodeunitXUnit(SuiteName: Code[10]; LineNo: Integer; RunError: Text): Text
    var
        CodeunitLine: Record "Test Method Line";
        Builder: TextBuilder;
    begin
        GetCodeunitLine(SuiteName, LineNo, CodeunitLine);
        Builder.Append('<?xml version="1.0" encoding="utf-8"?>');
        Builder.Append('<assemblies>');
        Builder.Append(StrSubstNo('<assembly name="%1">', XmlEncode(Format(SuiteName))));
        AppendCollection(Builder, SuiteName, CodeunitLine, true, RunError);
        Builder.Append('</assembly>');
        Builder.Append('</assemblies>');
        exit(Builder.ToText());
    end;

    local procedure BuildXUnit(SuiteName: Code[10]): Text
    var
        CodeunitLine: Record "Test Method Line";
        Builder: TextBuilder;
    begin
        Builder.Append('<?xml version="1.0" encoding="utf-8"?>');
        Builder.Append('<assemblies>');
        Builder.Append(StrSubstNo('<assembly name="%1">', XmlEncode(Format(SuiteName))));

        CodeunitLine.SetRange("Test Suite", SuiteName);
        CodeunitLine.SetRange("Line Type", CodeunitLine."Line Type"::Codeunit);
        if CodeunitLine.FindSet() then
            repeat
                AppendCollection(Builder, SuiteName, CodeunitLine, false, '');
            until CodeunitLine.Next() = 0;

        Builder.Append('</assembly>');
        Builder.Append('</assemblies>');
        exit(Builder.ToText());
    end;

    local procedure AppendCollection(var Builder: TextBuilder; SuiteName: Code[10]; var CodeunitLine: Record "Test Method Line"; StrictResults: Boolean; RunError: Text)
    var
        FunctionLine: Record "Test Method Line";
        CodeunitMetadata: Record "CodeUnit Metadata";
        AppInfo: ModuleInfo;
    begin
        CodeunitMetadata.Get(CodeunitLine."Test Codeunit");
        NavApp.GetModuleInfo(CodeunitMetadata."App ID", AppInfo);
        Builder.Append(StrSubstNo('<collection name="%1" codeunitId="%2" codeunitName="%3" appName="%4" extensionId="%5">',
            XmlEncode(StrSubstNo('Codeunit %1 %2', CodeunitLine."Test Codeunit", CodeunitLine.Name)),
            Format(CodeunitLine."Test Codeunit", 0, 9),
            XmlEncode(CodeunitLine.Name),
            XmlEncode(AppInfo.Name), Format(CodeunitMetadata."App ID")));

        FunctionLine.SetRange("Test Suite", SuiteName);
        FunctionLine.SetRange("Line Type", FunctionLine."Line Type"::Function);
        FunctionLine.SetRange("Test Codeunit", CodeunitLine."Test Codeunit");
        if FunctionLine.FindSet() then
            repeat
                AppendTest(Builder, CodeunitLine, FunctionLine, StrictResults, RunError);
            until FunctionLine.Next() = 0;

        Builder.Append('</collection>');
    end;

    // StrictResults (per-codeunit protocol): Run = false -> Skip "Disabled by DisabledTests" (a fresh
    // suite selects every method, so only ApplyDisabledTests clears Run); a selected method with no
    // result never started -> Failure, so a codeunit that dies in OnRun cannot pass silently.
    local procedure AppendTest(var Builder: TextBuilder; var CodeunitLine: Record "Test Method Line"; var FunctionLine: Record "Test Method Line"; StrictResults: Boolean; RunError: Text)
    var
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        ResultText: Text;
        TimeText: Text;
        Reason: Text;
        FailureMessage: Text;
        FailureStack: Text;
        IsFailure: Boolean;
        DurationSec: Decimal;
    begin
        case true of
            StrictResults and not FunctionLine.Run:
                begin
                    ResultText := 'Skipped';
                    Reason := DisabledReasonTxt;
                end;
            FunctionLine.Result = FunctionLine.Result::Success:
                ResultText := 'Success';
            FunctionLine.Result = FunctionLine.Result::Failure:
                begin
                    ResultText := 'Failure';
                    IsFailure := true;
                    FailureMessage := TestSuiteMgt.GetFullErrorMessage(FunctionLine);
                    FailureStack := TestSuiteMgt.GetErrorCallStack(FunctionLine);
                end;
            StrictResults and (FunctionLine.Result = FunctionLine.Result::" "):
                begin
                    ResultText := 'Failure';
                    IsFailure := true;
                    FailureMessage := NotExecutedTxt;
                    if RunError <> '' then
                        FailureMessage += ' Last error: ' + RunError;
                end;
            else begin
                ResultText := 'Skipped';
                if StrictResults then
                    Reason := RunnerSkippedReasonTxt;
            end;
        end;

        if (FunctionLine."Finish Time" <> 0DT) and (FunctionLine."Start Time" <> 0DT) then
            DurationSec := (FunctionLine."Finish Time" - FunctionLine."Start Time") / 1000;
        TimeText := Format(DurationSec, 0, 9);

        Builder.Append(StrSubstNo('<test name="%1" method="%2" result="%3" time="%4"',
            XmlEncode(StrSubstNo('%1:%2', CodeunitLine.Name, FunctionLine.Name)),
            XmlEncode(FunctionLine.Name),
            ResultText,
            TimeText));

        if IsFailure then begin
            Builder.Append('>');
            Builder.Append('<failure>');
            Builder.Append(StrSubstNo('<message>%1</message>', XmlEncode(FailureMessage)));
            Builder.Append(StrSubstNo('<stack-trace>%1</stack-trace>', XmlEncode(FailureStack)));
            Builder.Append('</failure>');
            Builder.Append('</test>');
        end else
            if Reason <> '' then
                Builder.Append(StrSubstNo('><reason>%1</reason></test>', XmlEncode(Reason)))
            else
                Builder.Append(' />');
    end;

    local procedure XmlEncode(Value: Text): Text
    begin
        Value := Value.Replace('&', '&amp;');
        Value := Value.Replace('<', '&lt;');
        Value := Value.Replace('>', '&gt;');
        Value := Value.Replace('"', '&quot;');
        Value := Value.Replace('''', '&apos;');
        exit(Value);
    end;
}