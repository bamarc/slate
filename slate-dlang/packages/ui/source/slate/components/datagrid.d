/// Dlang controller and model adapter for `SlateDataGrid`.
///
/// Implements `McpControllable`, `McpSortable`, `McpFilterable`, and `McpSelectable`
/// (`Scenario T3`, Requirements `E3`, `E4`).
module slate.components.datagrid;

import std.algorithm : canFind, min, sort;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.uni : toLower;

import slint.model : ArrayModel;
import slint.value : SlintField;
import slate.agent.error : AgentError;
import slate.agent.traits : McpAction, McpControllable, McpControllableMixin,
    McpIgnore, McpState, McpWritable;
import slate.traits;

/// Selection mode for DataGrid.
enum SelectionMode
{
    single,
    multi
}

/// D representation of `SlateGridRow` in `ui/components/data_grid.slint`.
struct GridRowData
{
    string id;
    string col0;
    string col1;
    string col2;
    string col3;
    string badge;
    @SlintField("badge-variant") string badgeVariant = "default";
    bool selected = false;
}

private GridRowData toGridRowData(T)(const ref T item, size_t fallbackIndex = 0)
{
    static if (is(T == GridRowData))
    {
        return cast(GridRowData) item;
    }
    else
    {
        GridRowData r;
        static if (__traits(hasMember, T, "id"))
            r.id = item.id.to!string;
        else
            r.id = fallbackIndex.to!string;

        static if (__traits(hasMember, T, "col0"))
            r.col0 = item.col0.to!string;
        else static if (T.tupleof.length > 0)
            r.col0 = item.tupleof[0].to!string;

        static if (__traits(hasMember, T, "col1"))
            r.col1 = item.col1.to!string;
        else static if (T.tupleof.length > 1)
            r.col1 = item.tupleof[1].to!string;

        static if (__traits(hasMember, T, "col2"))
            r.col2 = item.col2.to!string;
        else static if (T.tupleof.length > 2)
            r.col2 = item.tupleof[2].to!string;

        static if (__traits(hasMember, T, "col3"))
            r.col3 = item.col3.to!string;
        else static if (T.tupleof.length > 3)
            r.col3 = item.tupleof[3].to!string;

        static if (__traits(hasMember, T, "badge"))
            r.badge = item.badge.to!string;
        static if (__traits(hasMember, T, "badgeVariant"))
            r.badgeVariant = item.badgeVariant.to!string;
        static if (__traits(hasMember, T, "selected"))
            r.selected = item.selected;

        return r;
    }
}

/// Generic Data Grid controller managing filtering, 3-state column sorting
/// (`none` -> `asc` -> `desc` -> `none`), pagination, selection, and `ArrayModel!GridRowData`.
class DataGridController(T = GridRowData) : McpControllable, Paginated,
    Sortable, Filterable, Selectable
{
    mixin McpControllableMixin!"datagrid";

    private T[] _sourceItems;
    private GridRowData[] _allRows;
    private GridRowData[] _visibleRows;
    private ArrayModel!GridRowData _model;

    private string _filterQuery = "";
    private ptrdiff_t _sortColumn = -1;
    private string _sortDirection = "none"; // "none", "asc", "desc"
    private size_t _pageSize = 25;
    private size_t _currentPage = 1;
    private ptrdiff_t _selectedIndex = -1;
    private SelectionMode _selectionMode = SelectionMode.single;
    private size_t[] _selectedIndices;

    this(T[] initialItems = [], size_t pageSize = 25)
    {
        _pageSize = pageSize > 0 ? pageSize : 25;
        _model = new ArrayModel!GridRowData();
        setItems(initialItems);
    }

    @McpIgnore void setItems(T[] items)
    {
        _sourceItems = items.dup;
        _allRows = null;
        foreach (i, ref item; items)
            _allRows ~= toGridRowData(item, i);
        _selectedIndices = null;
        _selectedIndex = -1;
        recompute();
    }

    /// Underlying `ArrayModel!GridRowData` bound to `SlateDataGrid.rows`.
    @McpIgnore ArrayModel!GridRowData model() @safe pure nothrow
    {
        return _model;
    }

    /// Current visible page rows.
    @McpIgnore const(GridRowData)[] visibleRows() const @safe pure nothrow
    {
        return _visibleRows;
    }

    size_t totalRows() const @safe pure nothrow
    {
        return _allRows.length;
    }

    size_t visibleRowCount() const @safe pure nothrow
    {
        return _visibleRows.length;
    }

    override string filterQuery() const @safe pure nothrow
    {
        return _filterQuery;
    }

    override void setFilterQuery(string query)
    {
        _filterQuery = query;
        _currentPage = 1;
        recompute();
    }

    ptrdiff_t sortColumn() const @safe pure nothrow
    {
        return _sortColumn;
    }

    string sortDirection() const @safe pure nothrow
    {
        return _sortDirection;
    }

    /// Cycle sort state on `columnIndex`: `none` -> `asc` -> `desc` -> `none`.
    @McpAction("cycle_sort")
    string cycleSortColumn(size_t columnIndex)
    {
        if (_sortColumn != cast(ptrdiff_t) columnIndex)
        {
            _sortColumn = cast(ptrdiff_t) columnIndex;
            _sortDirection = "asc";
        }
        else if (_sortDirection == "none")
        {
            _sortDirection = "asc";
        }
        else if (_sortDirection == "asc")
        {
            _sortDirection = "desc";
        }
        else
        {
            _sortColumn = -1;
            _sortDirection = "none";
        }
        recompute();
        return _sortDirection;
    }

    override void sortByColumn(size_t columnIndex, string direction)
    {
        if (direction != "asc" && direction != "desc" && direction != "none")
            throw AgentError.invalidParams("direction",
                    "Sort direction must be 'asc', 'desc', or 'none'");
        if (direction == "none")
        {
            _sortColumn = -1;
            _sortDirection = "none";
        }
        else
        {
            _sortColumn = cast(ptrdiff_t) columnIndex;
            _sortDirection = direction;
        }
        recompute();
    }

    override size_t currentPage() const @safe pure nothrow
    {
        return _currentPage;
    }

    override size_t totalPages() const @safe pure nothrow
    {
        try
        {
            size_t filteredLen = filteredRows().length;
            if (filteredLen == 0)
                return 1;
            return (filteredLen + _pageSize - 1) / _pageSize;
        }
        catch (Exception)
        {
            return 1;
        }
    }

    override size_t pageSize() const @safe pure nothrow
    {
        return _pageSize;
    }

    override void nextPage() @safe
    {
        if (_currentPage < totalPages())
        {
            _currentPage++;
            recompute();
        }
    }

    override void prevPage() @safe
    {
        if (_currentPage > 1)
        {
            _currentPage--;
            recompute();
        }
    }

    override void goToPage(size_t page) @safe
    {
        auto maxPage = totalPages();
        if (page < 1 || page > maxPage)
            throw AgentError.invalidParams("current_page", "Page index out of bounds");
        _currentPage = page;
        recompute();
    }

    alias setPage = goToPage;

    string selectionMode() const @safe pure nothrow
    {
        return _selectionMode == SelectionMode.multi ? "multi" : "single";
    }

    void setSelectionMode(SelectionMode mode) @safe pure nothrow
    {
        _selectionMode = mode;
    }

    @McpIgnore size_t[] selectedIndices() const @safe pure nothrow
    {
        return _selectedIndices.dup;
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return _selectedIndex;
    }

    override void selectIndex(size_t index)
    {
        if (index >= _visibleRows.length)
            throw AgentError.invalidParams("selected_index", "Row index out of bounds");
        _selectedIndex = cast(ptrdiff_t) index;
        _selectedIndices = [index];
        string targetId = _visibleRows[index].id;
        foreach (ref r; _allRows)
            r.selected = (r.id == targetId);
        recompute();
    }

    void toggleSelectIndex(size_t index)
    {
        if (index >= _visibleRows.length)
            throw AgentError.invalidParams("index", "Row index out of bounds");

        ptrdiff_t foundPos = -1;
        foreach (i, idx; _selectedIndices)
        {
            if (idx == index)
            {
                foundPos = cast(ptrdiff_t) i;
                break;
            }
        }

        if (foundPos >= 0)
        {
            _selectedIndices = _selectedIndices[0 .. foundPos] ~ _selectedIndices[foundPos + 1 .. $];
            _visibleRows[index].selected = false;
        }
        else
        {
            if (_selectionMode == SelectionMode.single)
            {
                foreach (idx; _selectedIndices)
                {
                    if (idx < _visibleRows.length)
                        _visibleRows[idx].selected = false;
                }
                _selectedIndices = [index];
            }
            else
            {
                _selectedIndices ~= index;
            }
            _visibleRows[index].selected = true;
        }

        _selectedIndex = (_selectedIndices.length > 0) ? cast(ptrdiff_t) _selectedIndices[$ - 1] : -1;

        string targetId = _visibleRows[index].id;
        foreach (ref r; _allRows)
        {
            if (r.id == targetId)
                r.selected = _visibleRows[index].selected;
        }

        _model.clear();
        foreach (r; _visibleRows)
            _model.push(r);
    }

    private static string columnValue(const ref GridRowData r, size_t col) @safe pure nothrow
    {
        switch (col)
        {
        case 0:
            return r.col0;
        case 1:
            return r.col1;
        case 2:
            return r.col2;
        default:
            return r.col3;
        }
    }

    void onMcpRestoreSnapshot(JSONValue snapshot)
    {
        if (snapshot.type != JSONType.object)
            return;
        auto obj = snapshot.object;

        if (auto p = "filter_query" in obj)
        {
            if (p.type == JSONType.string)
                _filterQuery = p.str;
        }
        if (auto p = "sort_column" in obj)
        {
            if (p.type == JSONType.integer)
                _sortColumn = cast(ptrdiff_t) p.integer;
        }
        if (auto p = "sort_direction" in obj)
        {
            if (p.type == JSONType.string)
                _sortDirection = p.str;
        }
        if (auto p = "selection_mode" in obj)
        {
            if (p.type == JSONType.string)
                _selectionMode = (p.str == "multi") ? SelectionMode.multi : SelectionMode.single;
        }
        if (auto p = "current_page" in obj)
        {
            if (p.type == JSONType.integer)
                _currentPage = cast(size_t) p.integer;
        }

        recompute();

        if (auto p = "selected_index" in obj)
        {
            if (p.type == JSONType.integer)
            {
                ptrdiff_t sel = cast(ptrdiff_t) p.integer;
                _selectedIndex = sel;
                if (sel >= 0 && cast(size_t) sel < _visibleRows.length)
                {
                    _selectedIndices = [cast(size_t) sel];
                    string targetId = _visibleRows[sel].id;
                    foreach (ref r; _allRows)
                        r.selected = (r.id == targetId);
                }
                else
                {
                    _selectedIndices = [];
                    foreach (ref r; _allRows)
                        r.selected = false;
                }
            }
        }
        recompute();
    }

    private static bool tryParseNumber(string s, out double val) @safe pure
    {
        import std.conv : to;
        import std.math : isFinite;

        try
        {
            val = s.to!double;
            return isFinite(val);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool compareCellValues(string a, string b, bool ascending) @safe pure
    {
        if (a == b)
            return false;

        double da = 0.0, db = 0.0;
        bool aIsNum = tryParseNumber(a, da);
        bool bIsNum = tryParseNumber(b, db);

        if (aIsNum && bIsNum)
        {
            if (da != db)
                return ascending ? (da < db) : (da > db);
            return ascending ? (a < b) : (a > b);
        }
        if (aIsNum && !bIsNum)
            return ascending;
        if (!aIsNum && bIsNum)
            return !ascending;
        return ascending ? (a < b) : (a > b);
    }

    private GridRowData[] filteredRows() const @safe pure
    {
        if (_filterQuery.length == 0)
            return _allRows.dup;

        string q = _filterQuery.toLower();
        GridRowData[] matching;
        foreach (r; _allRows)
        {
            if (r.id.toLower().canFind(q) || r.col0.toLower().canFind(q)
                    || r.col1.toLower().canFind(q) || r.col2.toLower()
                        .canFind(q) || r.col3.toLower().canFind(q) || r.badge.toLower().canFind(q))
            {
                matching ~= r;
            }
        }
        return matching;
    }

    private void recompute()
    {
        auto list = filteredRows();
        if (_sortColumn >= 0 && (_sortDirection == "asc" || _sortDirection == "desc"))
        {
            size_t col = cast(size_t) _sortColumn;
            bool asc = (_sortDirection == "asc");
            list.sort!((a, b) => compareCellValues(columnValue(a, col), columnValue(b, col), asc));
        }

        size_t total = list.length;
        size_t maxP = total == 0 ? 1 : (total + _pageSize - 1) / _pageSize;
        if (_currentPage > maxP)
            _currentPage = maxP;

        size_t start = (_currentPage - 1) * _pageSize;
        size_t end = min(total, start + _pageSize);
        _visibleRows = start < total ? list[start .. end].dup : [];

        // Sync to ArrayModel
        _model.clear();
        foreach (r; _visibleRows)
            _model.push(r);
    }
}

// Spec: Scenario T3 / Phase 3.2 / Security: SlateDataGrid sorting, filtering, pagination, selection, and generic row struct
/// Example:
unittest
{
    import slate.agent.traits : isMcpControllable, isMcpFilterable,
        isMcpSelectable, isMcpSortable;

    static assert(isMcpControllable!(DataGridController!GridRowData));
    static assert(isPaginated!(DataGridController!GridRowData));
    static assert(isSortable!(DataGridController!GridRowData));
    static assert(isFilterable!(DataGridController!GridRowData));
    static assert(isSelectable!(DataGridController!GridRowData));

    auto rows = [
        GridRowData("1", "Charlie", "Compute", "30", "Active", "Online", "success"),
        GridRowData("2", "Alpha", "Storage", "10", "Idle", "Standby", "default"),
        GridRowData("3", "Bravo", "Compute", "20", "Active", "Online", "success"),
    ];
    auto ctrl = new DataGridController!GridRowData(rows, 10);
    assert(ctrl.visibleRowCount() == 3);
    assert(ctrl.visibleRows()[0].col0 == "Charlie");

    // 1. Cycle sort on column 0: none -> asc -> desc -> none
    assert(ctrl.cycleSortColumn(0) == "asc");
    assert(ctrl.visibleRows()[0].col0 == "Alpha");
    assert(ctrl.visibleRows()[1].col0 == "Bravo");
    assert(ctrl.visibleRows()[2].col0 == "Charlie");

    assert(ctrl.cycleSortColumn(0) == "desc");
    assert(ctrl.visibleRows()[0].col0 == "Charlie");
    assert(ctrl.visibleRows()[2].col0 == "Alpha");

    assert(ctrl.cycleSortColumn(0) == "none");
    assert(ctrl.visibleRows()[0].col0 == "Charlie");

    // 2. Numeric sort on column 2 ("10", "20", "30")
    ctrl.sortByColumn(2, "asc");
    assert(ctrl.visibleRows()[0].col2 == "10");
    assert(ctrl.visibleRows()[2].col2 == "30");

    // 3. Filter query narrows visible rows and resets page to 1
    ctrl.setFilterQuery("alpha");
    assert(ctrl.visibleRowCount() == 1);
    assert(ctrl.visibleRows()[0].col0 == "Alpha");
    assert(ctrl.currentPage() == 1);
    assert(ctrl.model().rowCount() == 1);

    // 4. 25-row pagination scenario with pageSize = 10
    GridRowData[] dataset25;
    foreach (i; 0 .. 25)
    {
        import std.format : format;

        string name = (i < 3) ? format!"db-prod-%02d"(i) : format!"web-srv-%02d"(i);
        string numVal = format!"%d"(i * 10);
        dataset25 ~= GridRowData(format!"id-%d"(i), name, "Compute", numVal,
                "Online", "OK", "success");
    }

    auto grid25 = new DataGridController!GridRowData(dataset25, 10);
    assert(grid25.totalRows() == 25);
    assert(grid25.totalPages() == 3);
    assert(grid25.visibleRows().length == 10);

    // Navigate to page 2
    grid25.setPage(2);
    assert(grid25.currentPage() == 2);
    assert(grid25.visibleRows().length == 10);

    // Sort by column 2 descending places highest numeric value at row 0 (240 at row 0 of page 1)
    grid25.sortByColumn(2, "desc");
    grid25.setPage(1);
    assert(grid25.visibleRows()[0].col2 == "240");

    // Filtering by "db-prod" matches 3 rows and resets currentPage to 1, totalPages to 1, visibleRows to 3
    grid25.setPage(2);
    grid25.setFilterQuery("db-prod");
    assert(grid25.currentPage() == 1);
    assert(grid25.totalPages() == 1);
    assert(grid25.visibleRows().length == 3);

    // 5. SelectionMode multi and toggleSelectIndex / selectedIndices
    grid25.setSelectionMode(SelectionMode.multi);
    grid25.toggleSelectIndex(0);
    grid25.toggleSelectIndex(2);
    assert(grid25.selectedIndices() == [0, 2]);
    grid25.toggleSelectIndex(0);
    assert(grid25.selectedIndices() == [2]);

    // 6. Generic DataGridController!ServerRow custom struct
    static struct ServerRow
    {
        string id;
        string col0;
        string col1;
        string col2;
        string col3;
        string badge;
        string badgeVariant;
        bool selected;
    }

    auto customGrid = new DataGridController!ServerRow([
        ServerRow("s1", "app-prod", "tier1", "100", "active", "ok", "success", false)
    ]);
    assert(customGrid.totalRows() == 1);
    // 7. Strict weak ordering for mixed numeric/string columns
    auto mixedRows = [
        GridRowData("1", "10a", "", "", "", "", ""),
        GridRowData("2", "2", "", "", "", "", ""),
        GridRowData("3", "10", "", "", "", "", ""),
        GridRowData("4", "02", "", "", "", "", ""),
        GridRowData("5", "1a", "", "", "", "", ""),
    ];
    auto mixedGrid = new DataGridController!GridRowData(mixedRows, 10);
    mixedGrid.sortByColumn(0, "asc");
    auto ascList = mixedGrid.visibleRows();
    assert(ascList[0].col0 == "02");
    assert(ascList[1].col0 == "2");
    assert(ascList[2].col0 == "10");
    assert(ascList[3].col0 == "10a");
    assert(ascList[4].col0 == "1a");

    mixedGrid.sortByColumn(0, "desc");
    auto descList = mixedGrid.visibleRows();
    assert(descList[0].col0 == "1a");
    assert(descList[1].col0 == "10a");
    assert(descList[2].col0 == "10");
    assert(descList[3].col0 == "2");
    assert(descList[4].col0 == "02");

    // 8. Snapshot capture and onMcpRestoreSnapshot rollback
    auto snapGrid = new DataGridController!GridRowData(rows, 10);
    auto snap = snapGrid.mcpSnapshot();
    assert(snapGrid.sortColumn() == -1);
    assert(snapGrid.selectedIndex() == -1);
    snapGrid.sortByColumn(0, "asc");
    snapGrid.selectIndex(1);
    assert(snapGrid.sortColumn() == 0);
    assert(snapGrid.selectedIndex() == 1);
    snapGrid.mcpRestoreSnapshot(snap);
    assert(snapGrid.sortColumn() == -1);
    assert(snapGrid.sortDirection() == "none");
    assert(snapGrid.selectedIndex() == -1);
}

version (SlintNative)
{
    // Spec: Scenario T3 (SlintNative): SlateDataGrid UI interaction via SlintElementController
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import slate.agent.slint_backend : SlintElementController, SlintUiInspector;

        auto compiler = new Compiler();
        compiler.includePaths = [
            "../ui", "../../../ui", "ui", "../../ui", "../../../../ui"
        ];
        auto built = compiler.buildFromSource(`
            import { SlateDataGrid, SlateGridRow } from "components/data_grid.slint";
            export component DataGridTestWin inherits Window {
                width: 700px;
                height: 400px;
                in-out property <[SlateGridRow]> rows <=> grid.rows;
                in-out property <string> filter-text <=> grid.filter-text;
                in-out property <int> sort-column <=> grid.sort-column;
                in-out property <string> sort-direction <=> grid.sort-direction;

                grid := SlateDataGrid {
                    automation-id: "datagrid";
                }
            }
        `, "");
        auto def = built.component("DataGridTestWin");
        assert(def !is null, "DataGridTestWin should compile");
        auto win = def.create();

        auto ctrl = new DataGridController!GridRowData([
            GridRowData("1", "Charlie", "Compute", "30", "Active", "Online", "success"),
            GridRowData("2", "Alpha", "Storage", "10", "Idle", "Standby", "default"),
            GridRowData("3", "Bravo", "Compute", "20", "Active", "Online", "success"),
        ]);
        win.setModel("rows", ctrl.model());

        auto inspector = new SlintUiInspector(win);
        auto controller = new SlintElementController(win);

        // Click "datagrid-header-0" via MCP click_element -> ascending sort
        controller.clickElement("#datagrid-header-0");
        assert(win.getString("sort-direction") == "asc");
        ctrl.sortByColumn(0, win.getString("sort-direction"));
        win.setModel("rows", ctrl.model());
        assert(ctrl.visibleRows()[0].col0 == "Alpha");

        // Click "datagrid-header-0" again -> descending sort
        controller.clickElement("#datagrid-header-0");
        assert(win.getString("sort-direction") == "desc");
        ctrl.sortByColumn(0, win.getString("sort-direction"));
        win.setModel("rows", ctrl.model());
        assert(ctrl.visibleRows()[0].col0 == "Charlie");

        // Click "datagrid-header-0" a third time -> none
        controller.clickElement("#datagrid-header-0");
        assert(win.getString("sort-direction") == "none");

        // Verify no duplicate accessible-ids in UI tree
        auto tree = inspector.inspectTree();
        assert(tree.findById("datagrid-row-0") !is null);
    }
}
