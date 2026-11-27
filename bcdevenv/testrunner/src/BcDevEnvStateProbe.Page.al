// Diagnostic only: codeunit 50105 "BcDevEnv State Probe" opens this page as a TestPage to show whether
// controls in the Basic and Suite application areas are found in the test session ('bcdevenv run-tests
// --executor altool --state-probe on').
namespace BcDevEnv.TestRunner;

page 50105 "BcDevEnv State Probe"
{
    Caption = 'BcDevEnv State Probe';
    PageType = Card;
    Editable = false;

    layout
    {
        area(Content)
        {
            group(Probe)
            {
                Caption = 'Probe';

                field(BasicSuiteField; BasicSuiteValue)
                {
                    ApplicationArea = Basic, Suite;
                    Caption = 'Basic, Suite';
                    ToolTip = 'Specifies a value in the Basic and Suite application areas.';
                }
                field(AllField; AllValue)
                {
                    ApplicationArea = All;
                    Caption = 'All';
                    ToolTip = 'Specifies a value in all application areas.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(BasicSuiteAction)
            {
                ApplicationArea = Basic, Suite;
                Caption = 'Basic, Suite';
                ToolTip = 'An action in the Basic and Suite application areas.';

                trigger OnAction()
                begin
                    BasicSuiteValue := 'Invoked';
                end;
            }
            action(AllAction)
            {
                ApplicationArea = All;
                Caption = 'All';
                ToolTip = 'An action in all application areas.';

                trigger OnAction()
                begin
                    AllValue := 'Invoked';
                end;
            }
        }
    }

    var
        BasicSuiteValue: Text[30];
        AllValue: Text[30];
}
