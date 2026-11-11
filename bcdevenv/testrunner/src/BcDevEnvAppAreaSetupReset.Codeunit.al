// Restores table 9178 "Application Area Setup" (Base Application) to the rows it had before the first test ran.
// 'bcdevenv run-tests --executor altool' runs every test codeunit in a new session, whose application area is
// computed at login from this table: a row that a test commits (a codeunit with RequiredTestIsolation = Disabled,
// e.g. "APIV1 - Employees E2E" enabling the Basic HR experience) would otherwise hide the Basic and Suite controls
// from every later test codeunit, and code that reads the table would see it. The login hook (codeunit 50109) clears
// the session's application area since, but not the table. The state reset (codeunit 50102) restores it before every
// test codeunit and commits.
//
// The baseline is captured once per database (PrepareTests, or the first state reset when PrepareTests did not
// run) and stored in isolated storage (module scope, so every session, company and user sees it). It has all
// rows of the table (it is not per company) and every normal field, including table extension fields; the table
// is read through RecordRef, so this app has no dependency on the Base Application. Without the table there is
// nothing to restore. The restore deletes rows that are not in the baseline, modifies rows whose values differ
// and re-creates missing rows, without triggers; the table's database events still clear the Base Application's
// application area cache. Every reset is counted (GetStateResetSummary of the BcDevEnv Test Runner), so the
// counters also show that the resets were committed.
namespace BcDevEnv.TestRunner;

using System.Reflection;

codeunit 50108 "BcDevEnv App Area Setup Reset"
{
    Access = Internal;

    var
        BaselineKeyTok: Label 'BcDevEnv.ApplicationAreaSetup.Baseline', Locked = true;
        CountersKeyTok: Label 'BcDevEnv.ApplicationAreaSetup.Counters', Locked = true;
        RowsTok: Label 'rows', Locked = true;
        ResetsTok: Label 'resets', Locked = true;
        RestoresTok: Label 'restores', Locked = true;
        RemovedTok: Label 'removed', Locked = true;
        RecreatedTok: Label 'recreated', Locked = true;
        ModifiedTok: Label 'modified', Locked = true;
        InvalidBaselineErr: Label 'The stored "Application Area Setup" baseline (isolated storage key %1) is not valid. Delete the key or recreate the container.', Comment = '%1 = key', Locked = true;
        NoPermissionErr: Label 'The state reset cannot %1 table %2 "Application Area Setup": user %3 lacks the permission.', Comment = '%1 = read or write, %2 = table id, %3 = user', Locked = true;
        RowNotFoundErr: Label 'The state reset cannot find the "Application Area Setup" row at %1 that it just read.', Comment = '%1 = position', Locked = true;
        InvalidValueErr: Label 'The state reset cannot restore field %1 "%2" of table %3 "Application Area Setup" to ''%4''.', Comment = '%1 = field no., %2 = field name, %3 = table id, %4 = value', Locked = true;
        SummaryTxt: Label '%1 of %2 reset(s) since PrepareTests restored it (%3 row(s) removed, %4 re-created, %5 modified); baseline %6 row(s)', Comment = '%1 = restores, %2 = resets, %3 = removed, %4 = re-created, %5 = modified, %6 = baseline rows', Locked = true;
        NoBaselineTxt: Label 'no baseline', Locked = true;
        NoTableTxt: Label 'table %1 does not exist; %2 reset(s) since PrepareTests', Comment = '%1 = table id, %2 = resets', Locked = true;

    /// <summary>
    /// Starts a test run (PrepareTests): captures the baseline when none is stored yet and clears the reset counters.
    /// </summary>
    procedure StartRun()
    begin
        CaptureBaselineIfAbsent();
        if IsolatedStorage.Contains(CountersKeyTok, DataScope::Module) then
            IsolatedStorage.Delete(CountersKeyTok, DataScope::Module);
    end;

    /// <summary>
    /// Restores the table to the baseline (captured first when none is stored yet) and counts the reset. Run it while
    /// the permissions mock is stopped: it needs write permission to the table.
    /// </summary>
    procedure Restore()
    var
        Counters: JsonObject;
        Removed: Integer;
        Recreated: Integer;
        Modified: Integer;
    begin
        if IsTablePresent() then begin
            CaptureBaselineIfAbsent();
            RestoreRows(Removed, Recreated, Modified);
        end;

        ReadCounters(Counters);
        AddToCounter(Counters, ResetsTok, 1);
        if Removed + Recreated + Modified > 0 then
            AddToCounter(Counters, RestoresTok, 1);
        AddToCounter(Counters, RemovedTok, Removed);
        AddToCounter(Counters, RecreatedTok, Recreated);
        AddToCounter(Counters, ModifiedTok, Modified);
        WriteCounters(Counters);
    end;

    /// <summary>
    /// Adds the resets since the last PrepareTests to the state reset summary: tablePresent, baselineRows (-1 without a
    /// baseline), resets, restores (resets that changed the table), removed, recreated and modified (rows).
    /// </summary>
    procedure AddSummary(var Summary: JsonObject)
    var
        Counters: JsonObject;
    begin
        ReadCounters(Counters);
        Summary.Add('tablePresent', IsTablePresent());
        Summary.Add('baselineRows', BaselineRowCount());
        Summary.Add(ResetsTok, GetCounter(Counters, ResetsTok));
        Summary.Add(RestoresTok, GetCounter(Counters, RestoresTok));
        Summary.Add(RemovedTok, GetCounter(Counters, RemovedTok));
        Summary.Add(RecreatedTok, GetCounter(Counters, RecreatedTok));
        Summary.Add(ModifiedTok, GetCounter(Counters, ModifiedTok));
    end;

    /// <summary>One line for the state probe.</summary>
    procedure GetSummaryText(): Text
    var
        Counters: JsonObject;
        BaselineRows: Integer;
    begin
        ReadCounters(Counters);
        if not IsTablePresent() then
            exit(StrSubstNo(NoTableTxt, SetupTableId(), GetCounter(Counters, ResetsTok)));
        BaselineRows := BaselineRowCount();
        exit(StrSubstNo(SummaryTxt, GetCounter(Counters, RestoresTok), GetCounter(Counters, ResetsTok), GetCounter(Counters, RemovedTok),
            GetCounter(Counters, RecreatedTok), GetCounter(Counters, ModifiedTok), BaselineRowsText(BaselineRows)));
    end;

    local procedure CaptureBaselineIfAbsent()
    var
        SetupRef: RecordRef;
        Baseline: JsonObject;
        Rows: JsonObject;
        BaselineText: Text;
    begin
        if not IsTablePresent() then
            exit;
        if IsolatedStorage.Contains(BaselineKeyTok, DataScope::Module) then
            exit;
        SetupRef.Open(SetupTableId());
        CheckPermission(SetupRef, false);
        if SetupRef.FindSet() then
            repeat
                AddRow(Rows, SetupRef);
            until SetupRef.Next() = 0;
        Baseline.Add(RowsTok, Rows);
        Baseline.WriteTo(BaselineText);
        IsolatedStorage.Set(BaselineKeyTok, BaselineText, DataScope::Module);
    end;

    // The rows are keyed by their position (the primary key values), the values by field number (XML format).
    local procedure AddRow(var Rows: JsonObject; var SetupRef: RecordRef)
    var
        SetupField: FieldRef;
        Values: JsonObject;
        Index: Integer;
    begin
        for Index := 1 to SetupRef.FieldCount() do begin
            SetupField := SetupRef.FieldIndex(Index);
            if IsRestorable(SetupField) then
                Values.Add(Format(SetupField.Number(), 0, 9), Format(SetupField.Value(), 0, 9));
        end;
        Rows.Add(SetupRef.GetPosition(false), Values);
    end;

    local procedure RestoreRows(var Removed: Integer; var Recreated: Integer; var Modified: Integer)
    var
        SetupRef: RecordRef;
        BaselineRows: JsonObject;
        BaselineRow: JsonToken;
        CurrentRows: Dictionary of [Text, Boolean];
        ToRemove: List of [Text];
        ToModify: List of [Text];
        Position: Text;
    begin
        if not ReadBaselineRows(BaselineRows) then
            exit;
        SetupRef.Open(SetupTableId());
        CheckPermission(SetupRef, true);
        if SetupRef.FindSet() then
            repeat
                Position := SetupRef.GetPosition(false);
                CurrentRows.Set(Position, true);
                if not BaselineRows.Get(Position, BaselineRow) then
                    ToRemove.Add(Position)
                else
                    if not Matches(SetupRef, BaselineRow.AsObject()) then
                        ToModify.Add(Position);
            until SetupRef.Next() = 0;

        foreach Position in ToRemove do begin
            FindRow(SetupRef, Position);
            SetupRef.Delete(false);
            Removed += 1;
        end;
        foreach Position in ToModify do begin
            FindRow(SetupRef, Position);
            BaselineRows.Get(Position, BaselineRow);
            ApplyValues(SetupRef, BaselineRow.AsObject());
            SetupRef.Modify(false);
            Modified += 1;
        end;
        foreach Position in BaselineRows.Keys() do
            if not CurrentRows.ContainsKey(Position) then begin
                BaselineRows.Get(Position, BaselineRow);
                SetupRef.Init();
                ApplyValues(SetupRef, BaselineRow.AsObject());
                SetupRef.Insert(false);
                Recreated += 1;
            end;
    end;

    local procedure FindRow(var SetupRef: RecordRef; Position: Text)
    begin
        SetupRef.SetPosition(Position);
        if not SetupRef.Find('=') then
            Error(RowNotFoundErr, Position);
    end;

    // Fields of the baseline that no longer exist (or are no longer restorable) are ignored, and so are fields
    // that the baseline does not have (a table extension installed after it was captured).
    local procedure Matches(var SetupRef: RecordRef; BaselineValues: JsonObject): Boolean
    var
        SetupField: FieldRef;
        Value: JsonToken;
        FieldNoText: Text;
    begin
        foreach FieldNoText in BaselineValues.Keys() do
            if GetRestorableField(SetupRef, FieldNoText, SetupField) then begin
                BaselineValues.Get(FieldNoText, Value);
                if Format(SetupField.Value(), 0, 9) <> Value.AsValue().AsText() then
                    exit(false);
            end;
        exit(true);
    end;

    local procedure ApplyValues(var SetupRef: RecordRef; BaselineValues: JsonObject)
    var
        SetupField: FieldRef;
        Value: JsonToken;
        FieldNoText: Text;
    begin
        foreach FieldNoText in BaselineValues.Keys() do
            if GetRestorableField(SetupRef, FieldNoText, SetupField) then begin
                BaselineValues.Get(FieldNoText, Value);
                SetFieldValue(SetupField, Value.AsValue().AsText());
            end;
    end;

    local procedure GetRestorableField(var SetupRef: RecordRef; FieldNoText: Text; var SetupField: FieldRef): Boolean
    var
        FieldNo: Integer;
    begin
        if not Evaluate(FieldNo, FieldNoText, 9) then
            exit(false);
        if not SetupRef.FieldExist(FieldNo) then
            exit(false);
        SetupField := SetupRef.Field(FieldNo);
        exit(IsRestorable(SetupField));
    end;

    local procedure SetFieldValue(var SetupField: FieldRef; Value: Text)
    begin
        case SetupField.Type() of
            FieldType::Text, FieldType::Code:
                begin
                    SetupField.Value := Value;
                    exit;
                end;
            FieldType::Date:
                if Value = '' then begin
                    SetupField.Value := 0D;
                    exit;
                end;
            FieldType::Time:
                if Value = '' then begin
                    SetupField.Value := 0T;
                    exit;
                end;
            FieldType::DateTime:
                if Value = '' then begin
                    SetupField.Value := 0DT;
                    exit;
                end;
        end;
        if not Evaluate(SetupField, Value, 9) then
            Error(InvalidValueErr, SetupField.Number(), SetupField.Name(), SetupTableId(), Value);
    end;

    // Normal, enabled fields, without system fields (SystemId, SystemCreatedAt, ...) and values that do not
    // round-trip as text.
    local procedure IsRestorable(SetupField: FieldRef): Boolean
    begin
        if SetupField.Class() <> FieldClass::Normal then
            exit(false);
        if not SetupField.Active() then
            exit(false);
        if SetupField.Number() >= 2000000000 then
            exit(false);
        case SetupField.Type() of
            FieldType::Blob, FieldType::Media, FieldType::MediaSet, FieldType::TableFilter:
                exit(false);
        end;
        exit(true);
    end;

    local procedure CheckPermission(var SetupRef: RecordRef; Write: Boolean)
    begin
        if not SetupRef.ReadPermission() then
            Error(NoPermissionErr, 'read', SetupTableId(), UserId());
        if Write and not SetupRef.WritePermission() then
            Error(NoPermissionErr, 'write', SetupTableId(), UserId());
    end;

    local procedure ReadBaselineRows(var Rows: JsonObject): Boolean
    var
        Baseline: JsonObject;
        RowsToken: JsonToken;
        BaselineText: Text;
    begin
        if not IsolatedStorage.Get(BaselineKeyTok, DataScope::Module, BaselineText) then
            exit(false);
        if not Baseline.ReadFrom(BaselineText) then
            Error(InvalidBaselineErr, BaselineKeyTok);
        if not Baseline.Get(RowsTok, RowsToken) then
            Error(InvalidBaselineErr, BaselineKeyTok);
        if not RowsToken.IsObject() then
            Error(InvalidBaselineErr, BaselineKeyTok);
        Rows := RowsToken.AsObject();
        exit(true);
    end;

    local procedure BaselineRowCount(): Integer
    var
        Rows: JsonObject;
    begin
        if not ReadBaselineRows(Rows) then
            exit(-1);
        exit(Rows.Keys().Count());
    end;

    local procedure BaselineRowsText(BaselineRows: Integer): Text
    begin
        if BaselineRows < 0 then
            exit(NoBaselineTxt);
        exit(Format(BaselineRows, 0, 9));
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

    local procedure WriteCounters(Counters: JsonObject)
    var
        CountersText: Text;
    begin
        Counters.WriteTo(CountersText);
        IsolatedStorage.Set(CountersKeyTok, CountersText, DataScope::Module);
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

    local procedure IsTablePresent(): Boolean
    var
        AllObj: Record AllObj;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
        AllObj.SetRange("Object ID", SetupTableId());
        exit(not AllObj.IsEmpty());
    end;

    local procedure SetupTableId(): Integer
    begin
        exit(9178);
    end;
}
