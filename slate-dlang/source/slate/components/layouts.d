/// Dlang controllers and MCP bindings for Slate Default Layouts:
/// - `WorkspaceDockController` (`SlateDockLayout`)
/// - `WizardController` (`SlateWizardLayout`)
/// - `MasterDetailController` (`SlateMasterDetailLayout` & `SlateSplitView`)
///
/// Covers Scenario `T9` (Requirements `E2`, `S1`, `U3`, `U5`).
module slate.components.layouts;

import std.algorithm : clamp;
import std.json : JSONValue;

import slint.instance : ComponentInstance;
import slate.agent.bridge : SlintUiBridge;
import slate.agent.error : AgentError;
import slate.agent.traits : McpAction, McpBindable, McpControllable,
    McpControllableMixin, McpFilterable, McpSelectable, McpState, McpWritable;

/// Controller for `SlateDockLayout` managing left, right, and bottom tool docks.
class WorkspaceDockController : McpControllable, McpBindable
{
    mixin McpControllableMixin!"workspace";

    @McpState("left_open") @McpWritable("left_open")
    bool leftOpen = true;

    @McpState("right_open") @McpWritable("right_open")
    bool rightOpen = true;

    @McpState("bottom_open") @McpWritable("bottom_open")
    bool bottomOpen = true;

    @McpState("left_width") @McpWritable("left_width")
    double leftWidth = 220.0;

    @McpState("right_width") @McpWritable("right_width")
    double rightWidth = 240.0;

    @McpState("bottom_height") @McpWritable("bottom_height")
    double bottomHeight = 160.0;

    private ComponentInstance _instance;

    @McpAction("toggle_panel")
    bool togglePanel(string panel)
    {
        switch (panel)
        {
        case "left":
            leftOpen = !leftOpen;
            syncToSlint();
            return leftOpen;
        case "right":
            rightOpen = !rightOpen;
            syncToSlint();
            return rightOpen;
        case "bottom":
            bottomOpen = !bottomOpen;
            syncToSlint();
            return bottomOpen;
        default:
            throw AgentError.invalidParams("panel", "Unknown dock panel: " ~ panel);
        }
    }

    @McpAction("reset_layout")
    void resetLayout()
    {
        leftOpen = true;
        rightOpen = true;
        bottomOpen = true;
        leftWidth = 220.0;
        rightWidth = 240.0;
        bottomHeight = 160.0;
        syncToSlint();
    }

    void onMcpPropertyChanged(string prop)
    {
        import std.math : isFinite;

        if (!isFinite(leftWidth) || leftWidth <= 0.0)
            throw AgentError.invalidParams("left_width", "Width must be a positive finite number");
        if (!isFinite(rightWidth) || rightWidth <= 0.0)
            throw AgentError.invalidParams("right_width", "Width must be a positive finite number");
        if (!isFinite(bottomHeight) || bottomHeight <= 0.0)
            throw AgentError.invalidParams("bottom_height", "Height must be a positive finite number");
        syncToSlint();
    }

    override void bindToSlint(ComponentInstance instance, SlintUiBridge bridge = null)
    {
        _instance = instance;
        syncToSlint();
    }

    void syncToSlint()
    {
        version (SlintNative)
        {
            if (_instance is null)
                return;
            try
            {
                _instance.setBool("left-open", leftOpen);
                _instance.setBool("right-open", rightOpen);
                _instance.setBool("bottom-open", bottomOpen);
            }
            catch (Exception)
            {
            }
        }
    }
}

/// Controller for `SlateWizardLayout` managing multi-step progression and validation gates.
class WizardController : McpControllable, McpSelectable
{
    mixin McpControllableMixin!"wizard";

    private size_t _currentStep = 0;
    private size_t _totalSteps = 1;

    @McpState("can_advance") @McpWritable("can_advance")
    bool canAdvance = true;

    @McpState("completed")
    bool completed = false;

    this(size_t totalSteps = 3) @safe pure nothrow
    {
        _totalSteps = totalSteps > 0 ? totalSteps : 1;
    }

    @McpState("current_step")
    size_t currentStep() const @safe pure nothrow
    {
        return _currentStep;
    }

    @McpState("total_steps")
    size_t totalSteps() const @safe pure nothrow
    {
        return _totalSteps;
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return cast(ptrdiff_t) _currentStep;
    }

    @McpWritable("current_step") @McpAction("select_step")
    override void selectIndex(size_t index)
    {
        if (index >= _totalSteps)
            throw AgentError.invalidParams("current_step", "Step index out of range");
        _currentStep = index;
    }

    @McpAction("next")
    size_t nextStep()
    {
        if (!canAdvance)
            throw AgentError.actionFailed("next", "Current wizard step validation gate is false");
        if (_currentStep + 1 < _totalSteps)
            _currentStep++;
        return _currentStep;
    }

    @McpAction("back")
    size_t prevStep()
    {
        if (_currentStep > 0)
            _currentStep--;
        return _currentStep;
    }

    @McpAction("finish")
    bool finish()
    {
        if (!canAdvance)
            throw AgentError.actionFailed("finish", "Cannot finish wizard while canAdvance is false");
        completed = true;
        return completed;
    }
}

/// Controller for `SlateMasterDetailLayout` and `SlateSplitView`.
class MasterDetailController : McpControllable, McpFilterable, McpSelectable
{
    mixin McpControllableMixin!"master_detail";

    @McpState("selected_id") @McpWritable("selected_id")
    string selectedId = "";

    private string _filterQuery = "";
    private double _splitRatio = 0.35;
    private string[] _itemIds;

    this(string[] itemIds = []) @safe pure nothrow
    {
        _itemIds = itemIds.dup;
    }

    @McpState("has_selection")
    bool hasSelection() const @safe pure nothrow
    {
        return selectedId.length > 0;
    }

    @McpState("split_ratio")
    double splitRatio() const @safe pure nothrow
    {
        return _splitRatio;
    }

    @McpWritable("split_ratio") @McpAction("set_split_ratio")
    void setSplitRatio(double ratio)
    {
        import std.math : isFinite;

        if (!isFinite(ratio) || ratio < 0.1 || ratio > 0.9)
            throw AgentError.invalidParams("split_ratio", "Split ratio must be a finite number in [0.1, 0.9]");
        _splitRatio = clamp(ratio, 0.15, 0.85);
    }

    @McpState("filter_query")
    override string filterQuery() const @safe pure nothrow
    {
        return _filterQuery;
    }

    @McpWritable("filter_query") @McpAction("set_filter")
    override void setFilterQuery(string query)
    {
        _filterQuery = query;
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        foreach (i, id; _itemIds)
            if (id == selectedId)
                return cast(ptrdiff_t) i;
        return -1;
    }

    @McpAction("select_index")
    override void selectIndex(size_t index)
    {
        if (index >= _itemIds.length)
            throw AgentError.invalidParams("index", "Master item index out of bounds");
        selectedId = _itemIds[index];
    }

    @McpAction("clear_selection")
    void clearSelection() @safe pure nothrow
    {
        selectedId = "";
    }
}

// Spec: Scenario T9 / Security: Unit tests for WorkspaceDockController, WizardController, and MasterDetailController
/// Example:
unittest
{
    import std.exception : assertThrown;
    import slate.agent.traits : isMcpControllable, isMcpFilterable, isMcpSelectable;

    static assert(isMcpControllable!WorkspaceDockController);
    static assert(isMcpControllable!WizardController);
    static assert(isMcpSelectable!WizardController);
    static assert(isMcpControllable!MasterDetailController);
    static assert(isMcpFilterable!MasterDetailController);
    static assert(isMcpSelectable!MasterDetailController);

    // 1. WorkspaceDockController
    auto dock = new WorkspaceDockController();
    assert(dock.leftOpen && dock.rightOpen && dock.bottomOpen);
    assert(!dock.togglePanel("left"));
    assert(!dock.leftOpen);
    assert(!dock.togglePanel("bottom"));
    assert(!dock.bottomOpen);
    dock.resetLayout();
    assert(dock.leftOpen && dock.rightOpen && dock.bottomOpen);
    assertThrown!AgentError(dock.togglePanel("invalid"));

    // Guard negative, NaN, infinity dock dimensions
    double initialLeft = dock.leftWidth;
    assertThrown!AgentError(dock.mcpSetProperty("left_width", JSONValue(-10.0)));
    assert(dock.leftWidth == initialLeft);
    assert(dock.mcpSetProperty("left_width", JSONValue(280.0)));
    assert(dock.leftWidth == 280.0);
    assertThrown!AgentError(dock.mcpSetProperty("right_width", JSONValue(double.nan)));
    assertThrown!AgentError(dock.mcpSetProperty("bottom_height", JSONValue(double.infinity)));

    // 2. WizardController
    auto wiz = new WizardController(3);
    assert(wiz.currentStep() == 0);
    assert(wiz.nextStep() == 1);
    wiz.canAdvance = false;
    assertThrown!AgentError(wiz.nextStep());
    wiz.canAdvance = true;
    assert(wiz.nextStep() == 2);
    assert(wiz.finish() == true);
    assert(wiz.completed);

    // 3. MasterDetailController (S1 empty state vs selected state)
    auto md = new MasterDetailController(["item-1", "item-2"]);
    assert(!md.hasSelection());
    assert(md.selectedIndex() == -1);
    md.selectIndex(0);
    assert(md.selectedId == "item-1");
    assert(md.hasSelection());
    md.setSplitRatio(0.45);
    assert(md.splitRatio() == 0.45);
    md.clearSelection();
    assert(!md.hasSelection());

    // Guard ratio NaN and bounds [0.1, 0.9]
    assertThrown!AgentError(md.setSplitRatio(double.nan));
    assertThrown!AgentError(md.setSplitRatio(0.05));
    assertThrown!AgentError(md.setSplitRatio(0.95));
}

version (SlintNative)
{
    // Spec: Scenario T9 (SlintNative): SlateSplitView, SlateMasterDetailLayout, and SlateDockLayout via MCP
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import slate.agent.slint_backend : SlintElementController, SlintUiInspector;

        auto compiler = new Compiler();
        compiler.includePaths = ["../ui"];
        auto built = compiler.buildFromSource(`
            import { SlateSplitView } from "layouts/resizable_panel_group.slint";
            import { SlateMasterDetailLayout, SlateMasterItem } from "layouts/master_detail_layout.slint";
            import { SlateDockLayout } from "layouts/dock_layout.slint";

            export component LayoutsTestWindow inherits Window {
                width: 800px;
                height: 600px;

                in-out property <float> ratio <=> split.split-ratio;
                in-out property <string> selected-id <=> md.selected-id;
                in-out property <bool> left-open <=> dock.left-open;
                in-out property <bool> right-open <=> dock.right-open;
                in-out property <bool> bottom-open <=> dock.bottom-open;

                VerticalLayout {
                    split := SlateSplitView {
                        automation-id: "main-split";
                        height: 150px;
                        split-ratio: 0.4;
                    }
                    md := SlateMasterDetailLayout {
                        automation-id: "md-view";
                        height: 200px;
                        items: [
                            { id: "item-1", title: "Alpha Node", subtitle: "Primary", badge: "Active", badge-variant: "success" },
                            { id: "item-2", title: "Beta Node", subtitle: "Secondary", badge: "Idle", badge-variant: "default" }
                        ];
                        Text { text: "Detail Content Body"; }
                    }
                    dock := SlateDockLayout {
                        automation-id: "studio-dock";
                        height: 250px;
                    }
                }
            }
        `, "");
        auto def = built.component("LayoutsTestWindow");
        assert(def !is null, "LayoutsTestWindow must compile cleanly");
        auto win = def.create();

        auto inspector = new SlintUiInspector(win);
        auto controller = new SlintElementController(win);

        // 1. SlateMasterDetailLayout starts with empty selection -> empty-state visible
        auto tree1 = inspector.inspectTree();
        assert(tree1.findById("md-view-empty-state") !is null);
        assert(tree1.findById("md-view-detail") is null);

        // Select "item-1" via MCP click_element -> detail content slot becomes visible
        controller.clickElement("#md-view-item-item-1");
        assert(win.getString("selected-id") == "item-1");
        auto tree2 = inspector.inspectTree();
        assert(tree2.findById("md-view-detail") !is null);
        assert(tree2.findById("md-view-empty-state") is null);

        // 2. SlateSplitView ratio control via MCP setValue / increment
        controller.setValue("#main-split-handle", "0.60");
        import std.math : isClose;
        assert(isClose(win.getNumber("ratio"), 0.60, 1e-3));

        // 3. SlateDockLayout toggles left, right, and bottom panels via MCP click_element
        assert(win.getBool("left-open") == true);
        controller.clickElement("#studio-dock-toggle-left");
        assert(win.getBool("left-open") == false);

        assert(win.getBool("bottom-open") == true);
        controller.clickElement("#studio-dock-toggle-bottom");
        assert(win.getBool("bottom-open") == false);

        assert(win.getBool("right-open") == true);
        controller.clickElement("#studio-dock-toggle-right");
        assert(win.getBool("right-open") == false);
    }
}
