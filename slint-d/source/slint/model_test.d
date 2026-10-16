module slint.model_test;

import slint.model;
import slint.value;
import core.thread.fiber : Fiber;
import std.algorithm : isSorted;
import std.conv : to;
import std.exception : assertThrown;
import std.range.primitives : isInputRange, isForwardRange;

// Best practice: Derived models (MapModel, FilterModel, SortedModel, ReverseModel, GeneratorModel)
/// Example:
unittest
{
    // Map: lazy projection, row edits forward, structural edits reset.
    auto src = new ArrayModel!int([3, 1, 2]);
    auto mapped = new MapModel!(int, string)(src, (x) => "n" ~ x.to!string);
    assert(mapped.rowCount() == 3);
    assert(mapped.rowData(0) == "n3");
    bool mappedReset;
    mapped.notify().onModelReset(() { mappedReset = true; });
    src.push(0);
    assert(mappedReset && mapped.rowCount() == 4 && mapped.rowData(3) == "n0");

    // Filter: cached index over matching rows.
    auto evens = new FilterModel!int(src, (x) => x % 2 == 0);
    assert(evens.rowCount() == 2); // [2, 0]
    assert(evens.rowData(0) == 2 && evens.rowData(1) == 0);
    evens.setRowData(0, 20);
    assert(src.rowData(2) == 20); // writes through to the source row
    src.push(5);
    assert(evens.rowCount() == 2); // 5 does not match

    // Sorted: ordered view tracking the source.
    auto sorted = new SortedModel!int(src, (a, b) => a < b);
    int[] ordered;
    foreach (i; 0 .. sorted.rowCount())
        ordered ~= sorted.rowData(i);

    assert(ordered.isSorted);

    // Reverse: computed index mapping, no cache.
    auto rsrc = new ArrayModel!int([1, 2, 3]);
    auto rev = new ReverseModel!int(rsrc);
    assert(rev.rowData(0) == 3 && rev.rowData(2) == 1);
    bool revChanged;
    size_t revRow = size_t.max;
    rev.notify().onRowChanged((r) { revChanged = true; revRow = r; });
    rsrc.setRowData(0, 10); // source row 0 shows as reversed row 2
    assert(revChanged && revRow == 2 && rev.rowData(2) == 10);
    rev.setRowData(0, 30); // writes through to source row 2
    assert(rsrc.rowData(2) == 30);

    // Generator: fiber-fed lazy rows materialize on demand.
    auto gen = new GeneratorModel!int((void delegate(int) emit) {
        foreach (i; 0 .. 5)
            emit(i * i);
    });
    assert(gen.produced() == 0);
    assert(gen.rowData(0) == 0);
    assert(gen.produced() == 1);
    assert(gen.rowCount() == 5);
    assert(gen.rowData(4) == 16);

    assertThrown(gen.rowData(5));

    auto failing = new GeneratorModel!int((void delegate(int) emit) {
        emit(1);
        throw new Exception("source died");
    });
    assert(failing.rowData(0) == 1);
    assertThrown(failing.rowCount());
}

// Best practice: ArrayModel index operators, set convenience alias, clear, and native operations
/// Example:
unittest
{
    auto m = new ArrayModel!int([10, 20, 30]);
    assert(m.rowCount() == 3);
    assert(m[0] == 10);
    assert(m[1] == 20);
    assert(m[2] == 30);

    // opIndexAssign
    m[1] = 25;
    assert(m[1] == 25);
    assert(m.rowData(1) == 25);

    // set convenience method
    m.set(2, 35);
    assert(m[2] == 35);
    assert(m.rowData(2) == 35);

    // push
    m.push(40);
    assert(m.rowCount() == 4);
    assert(m[3] == 40);

    // remove
    m.remove(0);
    assert(m.rowCount() == 3);
    assert(m[0] == 25);

    // clear
    m.clear();
    assert(m.rowCount() == 0);
    assert(m.length == 0);

    version (SlintNative)
    {
        import slint.capi : slint_model_new_vec, slint_model_free, slint_model_row_count;

        auto raw = slint_model_new_vec();
        assert(raw !is null);
        assert(slint_model_row_count(raw) == 0);

        // Native-backed ArrayModel takes ownership of raw
        auto nativeModel = new ArrayModel!int(raw, true);
        assert(nativeModel.rowCount() == 0);
        nativeModel.push(100);
        nativeModel.push(200);
        assert(nativeModel.rowCount() == 2);
        assert(nativeModel[0] == 100);
        assert(nativeModel[1] == 200);
        nativeModel[0] = 150;
        assert(nativeModel[0] == 150);
        nativeModel.remove(0);
        assert(nativeModel.rowCount() == 1);
        assert(nativeModel[0] == 200);
        nativeModel.clear();
        assert(nativeModel.rowCount() == 0);
    }

    // Range support (DEFECT P2.3)
    static assert(isInputRange!(typeof((new ArrayModel!int())[])));
    static assert(isForwardRange!(typeof((new ArrayModel!int())[])));

    auto rangeModel = new ArrayModel!int([10, 20, 30]);
    auto rng = rangeModel[];
    assert(!rng.empty);
    assert(rng.length == 3);
    assert(rng.front == 10);
    assert(rng[1] == 20);
    rng.popFront();
    assert(rng.front == 20);
    assert(rng.length == 2);
    auto saved = rng.save();
    rng.popFront();
    assert(saved.front == 20);
    assert(rng.front == 30);

    // Read-only opApply (DEFECT P2.2)
    int roSum = 0;
    foreach (v; rangeModel)
        roSum += v;
    assert(roSum == 60);

    // Mutating opApply without changes should not trigger spurious setRowData
    size_t changedCount = 0;
    rangeModel.notify().onRowChanged((r) { ++changedCount; });
    foreach (ref v; rangeModel)
    {
        // read without mutating v
    }
    assert(changedCount == 0);

    // Mutating opApply with actual modification writes through and triggers notify
    foreach (ref v; rangeModel)
    {
        if (v == 20)
            v = 25;
    }
    assert(changedCount == 1);
    assert(rangeModel[1] == 25);
}

// Spec: Scenario T4: TreeModel hierarchical expand and collapse
/// Example:
unittest
{
    auto folder1 = new TreeNode!string("src", "src", [
        new TreeNode!string("main.d", "main.d"),
        new TreeNode!string("utils.d", "utils.d"),
        new TreeNode!string("sub", "sub", [
            new TreeNode!string("inner.d", "inner.d")
        ], false)
    ], false);
    auto folder2 = new TreeNode!string("docs", "docs",
            [new TreeNode!string("README.md", "README.md")], false);

    auto tree = new TreeModel!string([folder1, folder2]);
    assert(tree.rowCount() == 2);
    assert(tree.rowData(0).id == "src" && tree.rowData(0).depth == 0 && tree.rowData(0).hasChildren);
    assert(tree.rowData(1).id == "docs" && tree.rowData(1).depth == 0);

    size_t addedIndex = size_t.max, addedCount = 0;
    size_t removedIndex = size_t.max, removedCount = 0;
    tree.notify().onRowsAdded((idx, cnt) { addedIndex = idx; addedCount = cnt; });
    tree.notify().onRowsRemoved((idx, cnt) {
        removedIndex = idx;
        removedCount = cnt;
    });

    // Expand root 0 ("src") -> inserts 3 direct children at index 1
    tree.toggleExpand(0);
    assert(addedIndex == 1 && addedCount == 3);
    assert(tree.rowCount() == 5);
    assert(tree.rowData(1).id == "main.d" && tree.rowData(1).depth == 1);
    assert(tree.rowData(2).id == "utils.d" && tree.rowData(2).depth == 1);
    assert(tree.rowData(3).id == "sub" && tree.rowData(3).depth == 1 && tree.rowData(3).hasChildren);
    assert(tree.rowData(4).id == "docs" && tree.rowData(4).depth == 0);

    // Expand nested child "sub" at flatRow 3 -> inserts 1 grandchild at index 4
    tree.toggleExpand(3);
    assert(addedIndex == 4 && addedCount == 1);
    assert(tree.rowCount() == 6);
    assert(tree.rowData(4).id == "inner.d" && tree.rowData(4).depth == 2);

    // Collapse root 0 ("src") -> removes all 4 visible descendants (3 children + 1 grandchild)
    tree.toggleExpand(0);
    assert(removedIndex == 1 && removedCount == 4);
    assert(tree.rowCount() == 2);

    // ExpandAll and CollapseAll
    tree.expandAll();
    assert(tree.rowCount() == 7);
    tree.collapseAll();
    assert(tree.rowCount() == 2);
}

// Spec: E5 / Security: TreeModel maxTreeDepth limit enforcement against unbounded recursion
/// Example:
unittest
{
    // Create a chain of nodes with depth exceeding maxTreeDepth (128)
    TreeNode!string root = new TreeNode!string("node_0", "val_0", null, true);
    TreeNode!string cur = root;
    foreach (i; 1 .. 135)
    {
        auto next = new TreeNode!string("node", "val", null, true);
        cur.children = [next];
        cur = next;
    }

    // Creating TreeModel with root expanded past 128 depth should throw Exception
    assertThrown!Exception(new TreeModel!string([root]));

    // Unexpanded deep chain throws on expandAll and collapseAll
    TreeNode!string root2 = new TreeNode!string("node_0", "val_0", null, false);
    TreeNode!string cur2 = root2;
    foreach (i; 1 .. 135)
    {
        auto next = new TreeNode!string("node", "val", null, false);
        cur2.children = [next];
        cur2 = next;
    }
    auto tree2 = new TreeModel!string([root2]);
    assertThrown!Exception(tree2.expandAll());
    assertThrown!Exception(tree2.collapseAll());
}
