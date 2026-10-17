module slate.agent.model_test;

import slate.agent.model;
import slate.agent.geometry;
import slate.utils.json : toJsonValue;
import std.algorithm : canFind;
import std.json : parseJSON, JSONValue, JSONType;
import std.typecons : nullable;
import std.exception : assertThrown;
import core.exception : AssertError;

// Spec: Comprehensive UI tree, selector parsing, traversal, diagnostics, and contract validation
/// Example:
unittest
{
    // Tree search semantics.
    auto leaf = new UiElementNode();
    leaf.id = "ok-btn";
    leaf.typeName = "SlateButton";
    leaf.bounds = Rect(10, 10, 80, 30);
    leaf.label = "OK";
    leaf.role = "Button";
    auto hidden = new UiElementNode();
    hidden.id = "ghost";
    hidden.typeName = "Text";
    hidden.bounds = Rect(10, 10, 80, 30);
    hidden.visible = false;
    auto root = new UiElementNode();
    root.id = "root_window";
    root.typeName = "Window";
    root.bounds = Rect(0, 0, 800, 600);
    root.role = "Window";
    root.children = [leaf, hidden];
    auto tree = UiTree.create(root).withWindowInfo("Demo", 800, 600);

    assert(tree.findById("ok-btn") is leaf);
    assert(tree.findById("") is null);
    assert(tree.findByLabel("OK") is leaf);
    assert(tree.findAtPoint(Point(20, 20)) is leaf); // hidden loses hit-test
    assert(tree.findAtPoint(Point(700, 500)) is root);
    assert(tree.findAtPoint(Point(900, 900)) is null);
    assert(tree.findBySelector("#ok-btn") is leaf);
    assert(tree.findBySelector("OK") is leaf); // id fallback → label
    assert(tree.findBySelector("text:OK") is leaf);
    assert(tree.findBySelector("15,15") is leaf);
    assert(tree.findBySelector("role:button") is leaf); // case-insensitive
    assert(tree.findBySelector("#missing") is null);
    assert(tree.countElements() == 3);
    assert(root.collectElements().length == 3);

    // Tree JSON round-trip preserves searchability.
    auto tree2 = UiTree.create(UiElementNode.fromJson(root.toJson()));
    assert(tree2.findById("ok-btn").label == "OK");

    // Selector wire shape matches serde's externally-tagged enum.
    assert(ElementSelector.byId("x").toJson() == parseJSON(`{"Id":"x"}`));
    assert(ElementSelector.byCoordinate(Point(1, 2))
            .toJson() == parseJSON(`{"Coordinate":{"x":1,"y":2}}`));

    // Screenshots and data URLs.
    auto shot = Screenshot.create(2, 2, "png", [0, 1, 2, 3]);
    assert(shot.byteLen == 4);
    assert(shot.formatName == "png");
    assert(shot.dataUrl().canFind("data:image/png;base64,"));
    assert(shot.toBase64Png() == shot.toBase64());

    // State and results.
    auto st = AppState.create("Compute").withProperty("k", JSONValue(1));
    assert(st.getProperty("k") !is null && st.getProperty("missing") is null);
    assert(st.withDiagnostics(DiagnosticMetrics()).diagnostics.get.toJson().object.length == 0);
    auto ok = ActionResult.succeeded("done").withElementId("b").withDetail("t", JSONValue(1));
    assert(ok.success && ok.targetFound && ok.elementId == "b");
    assert(ActionResult.notFound("zzz").targetFound == false);
    auto j = ActionResult.failure("bad").toJson();
    assert(j["success"].get!bool == false && ("element_id" in j) is null);

    // Range traversal (byElement) matches collectElements order without heap arrays
    UiElementNode[] rangeNodes;
    foreach (e; tree.byElement)
        rangeNodes ~= e;
    assert(rangeNodes == root.collectElements());

    UiElementNode[] rootRangeNodes;
    foreach (e; root.byElement)
        rootRangeNodes ~= e;
    assert(rootRangeNodes == root.collectElements());

    // byElement @nogc pure nothrow check
    void testRangeNogc(UiTree t) @safe pure nothrow @nogc
    {
        auto r = t.byElement;
        size_t count = 0;
        while (!r.empty)
        {
            auto node = r.front;
            count++;
            r.popFront();
        }
        assert(count == 3);
    }

    testRangeNogc(tree);

    // UiFacade dot-syntax element lookup
    auto ui = tree.facade;
    assert(ui.ok_btn is leaf); // snake_case maps to kebab-case id "ok-btn"
    assert(ui.root_window is root); // exact id "root_window"
    assert(ui.OK is leaf); // label match
    assert(ui.missing_element is null); // not found yields null
    assert(ui["#ok-btn"] is leaf); // opIndex selector
    assert(ui["text:OK"] is leaf);
    assert(ui.windowTitle == "Demo"); // field forwarding
    assert(ui.findById("ok-btn") is leaf); // method forwarding

    auto nodeUi = root.facade;
    assert(nodeUi.ok_btn is leaf);

    // DiagnosticMetrics round-trip with @JsonKey remapping and Nullable omissions
    DiagnosticMetrics dm;
    dm.fps = nullable(60.0f);
    dm.memoryBytes = nullable(1048576UL);
    dm.eventLoopLagMs = nullable(1.5);
    dm.activeBackgroundTasks = nullable(cast(size_t) 2);
    dm.extra["gc_pause_ms"] = JSONValue(0.4);

    auto dmj = dm.toJson();
    assert(dmj["fps"].floating == 60.0);
    assert(dmj["memory_bytes"].uinteger == 1048576);
    assert(dmj["event_loop_lag_ms"].floating == 1.5);
    assert(dmj["active_background_tasks"].uinteger == 2);
    assert(dmj["extra"]["gc_pause_ms"].floating == 0.4);

    auto dmRoundTrip = DiagnosticMetrics.fromJson(dmj);
    assert(!dmRoundTrip.fps.isNull && dmRoundTrip.fps.get == 60.0f);
    assert(!dmRoundTrip.memoryBytes.isNull && dmRoundTrip.memoryBytes.get == 1048576);
    assert(!dmRoundTrip.eventLoopLagMs.isNull && dmRoundTrip.eventLoopLagMs.get == 1.5);
    assert(!dmRoundTrip.activeBackgroundTasks.isNull && dmRoundTrip.activeBackgroundTasks.get == 2);
    assert(dmRoundTrip.extra["gc_pause_ms"].floating == 0.4);

    // Edge cases: ElementRange on null root and single-leaf node
    auto nullRange = ElementRange(null);
    assert(nullRange.empty);
    auto soloNode = new UiElementNode();
    soloNode.id = "solo";
    auto soloRange = soloNode.byElement;
    assert(!soloRange.empty && soloRange.front.id == "solo");
    soloRange.popFront();
    assert(soloRange.empty);

    // Edge cases: UiFacade on null root
    auto emptyUi = UiFacade(UiTree(null));
    assert(emptyUi.any_element is null);
    assert(emptyUi["#missing"] is null);

    // Edge cases: Point and Rect round-trip with zero and negative coordinates
    assert(Point.fromJson(Point.zero.toJson()) == Point.zero);
    assert(Point.fromJson(Point(-10.5f, -20.5f).toJson()) == Point(-10.5f, -20.5f));
    assert(Rect.fromJson(Rect.zero.toJson()) == Rect.zero);
    assert(Rect.fromJson(Rect(-5, -5, 10, 10).toJson()) == Rect(-5, -5, 10, 10));

    // Const UiFacade dot-syntax, index, countElements, and byElement lookup
    const constUi = tree.facade;
    assert(constUi.ok_btn is leaf);
    assert(constUi["#ok-btn"] is leaf);
    assert(constUi.OK is leaf);
    assert(constUi.windowTitle == "Demo");
    assert(constUi.countElements() == 3);
    size_t constRangeCount = 0;
    foreach (e; constUi.byElement)
        constRangeCount++;
    assert(constRangeCount == 3);

    // UiTree and UiElementNode findByRole
    assert(tree.findByRole("button") is leaf);
    assert(root.findByRole("button") is leaf);
    assert(tree.findByRole("nonexistent") is null);

    // UiTree(null) toJson does not crash and produces null root
    auto emptyTree = UiTree(null);
    auto emptyTreeJson = emptyTree.toJson();
    assert(emptyTreeJson["root"].type == JSONType.null_);
    auto treeRoundTrip = UiTree.fromJson(tree.toJson());
    assert(treeRoundTrip.findById("ok-btn") !is null);
    assert(treeRoundTrip.findById("ok-btn").label == "OK");

    // UiElementNode fromJson on incomplete JSON recovers safely
    auto partialNodeJson = parseJSON(`{"id":"p1","type_name":"Panel"}`);
    auto partialNode = UiElementNode.fromJson(partialNodeJson);
    assert(partialNode.id == "p1");
    assert(partialNode.typeName == "Panel");
    assert(partialNode.enabled == true && partialNode.visible == true);
    assert(partialNode.bounds == Rect.zero);

    // Default Point and Rect zero initialization and stringify
    Point pDef;
    assert(pDef.x == 0 && pDef.y == 0);
    assert(pDef.toJson().toString().length > 0);
    Rect rDef;
    assert(rDef.x == 0 && rDef.width == 0);
    assert(rDef.toJson().toString().length > 0);

    // Deep tree traversal (> 128 levels) completely traversed without truncation
    auto deepRoot = new UiElementNode();
    deepRoot.id = "deep_0";
    auto currDeep = deepRoot;
    foreach (i; 1 .. 140)
    {
        import std.conv : to;

        auto nextDeep = new UiElementNode();
        nextDeep.id = "deep_" ~ i.to!string;
        currDeep.children = [nextDeep];
        currDeep = nextDeep;
    }
    size_t deepCount = 0;
    string lastDeepId;
    foreach (e; deepRoot.byElement)
    {
        deepCount++;
        lastDeepId = e.id;
    }
    assert(deepCount == 140);
    assert(lastDeepId == "deep_139");

    // ElementRange safely skips null children without crashing or yielding null
    auto nullChildRoot = new UiElementNode();
    nullChildRoot.id = "r";
    auto c1 = new UiElementNode();
    c1.id = "c1";
    auto c2 = new UiElementNode();
    c2.id = "c2";
    nullChildRoot.children = [
        cast(UiElementNode) null, c1, cast(UiElementNode) null, c2
    ];
    string[] visitedIds;
    foreach (e; nullChildRoot.byElement)
        visitedIds ~= e.id;
    assert(visitedIds == ["r", "c1", "c2"]);

    // findByLabel on null or empty search does not match elements with absent label
    auto noLabelNode = new UiElementNode();
    noLabelNode.id = "no_label";
    assert(noLabelNode.findByLabel("") is null);
    assert(noLabelNode.findByLabel(null) is null);

    // UiElementNode fromJson on null/invalid JSON returns null
    assert(UiElementNode.fromJson(JSONValue(null)) is null);
    assert(UiElementNode.fromJson(JSONValue(42)) is null);
    assert(UiElementNode.fromJson("not json") is null);

    // toJsonValue on null UiElementNode returns JSON null
    UiElementNode nullNodeRef = null;
    assert(toJsonValue(nullNodeRef).type == JSONType.null_);

    // Native Design-by-Contract: Point and Rect invariants
    // Point invariants: NaN coordinates rejected on construction
    assertThrown!AssertError(Point(float.nan, 0));
    assertThrown!AssertError(Point(0, float.nan));
    assertThrown!AssertError(Point(float.nan, float.nan));

    // Point invariants: NaN coordinates rejected when calling member functions after mutation
    Point pMut = Point(10, 20);
    pMut.validate(); // valid
    pMut.x = float.nan;
    assertThrown!AssertError(pMut.validate());
    assertThrown!AssertError(pMut.distanceTo(Point(0, 0)));
    assertThrown!AssertError(pMut.toString());

    Point pMutY = Point(10, 20);
    pMutY.y = float.nan;
    assertThrown!AssertError(pMutY.validate());
    assertThrown!AssertError(pMutY.distanceTo(Point(0, 0)));

    // Rect invariants: negative dimensions and NaN rejected on construction
    assertThrown!AssertError(Rect(0, 0, -1, 10));
    assertThrown!AssertError(Rect(0, 0, 10, -1));
    assertThrown!AssertError(Rect(0, 0, -5, -5));
    assertThrown!AssertError(Rect(float.nan, 0, 10, 10));
    assertThrown!AssertError(Rect(0, float.nan, 10, 10));
    assertThrown!AssertError(Rect(0, 0, float.nan, 10));
    assertThrown!AssertError(Rect(0, 0, 10, float.nan));

    // Rect invariants: negative dimensions and NaN rejected when calling member functions after mutation
    Rect rMut = Rect(0, 0, 100, 50);
    rMut.validate(); // valid
    assert(rMut.area() == 5000.0f);

    rMut.width = -1.0f;
    assertThrown!AssertError(rMut.validate());
    assertThrown!AssertError(rMut.area());
    assertThrown!AssertError(rMut.origin());
    assertThrown!AssertError(rMut.center());
    assertThrown!AssertError(rMut.contains(Point(10, 10)));
    assertThrown!AssertError(rMut.intersects(Rect(0, 0, 10, 10)));

    Rect rMutH = Rect(0, 0, 100, 50);
    rMutH.height = -0.5f;
    assertThrown!AssertError(rMutH.validate());
    assertThrown!AssertError(rMutH.area());
    assertThrown!AssertError(rMutH.center());

    Rect rMutNan = Rect(0, 0, 100, 50);
    rMutNan.x = float.nan;
    assertThrown!AssertError(rMutNan.validate());
    assertThrown!AssertError(rMutNan.area());

    // Point and Rect create() factory preconditions
    assertThrown!AssertError(Point.create(float.nan, 0));
    assertThrown!AssertError(Point.create(0, float.nan));
    assertThrown!AssertError(Point.create(float.infinity, 0));
    assertThrown!AssertError(Point.create(0, -float.infinity));
    assertThrown!AssertError(Rect.create(0, 0, -1, 10));
    assertThrown!AssertError(Rect.create(0, 0, 10, -1));
    assertThrown!AssertError(Rect.create(float.nan, 0, 10, 10));
    assertThrown!AssertError(Rect.create(float.infinity, 0, 10, 10));
    assertThrown!AssertError(Rect.create(0, 0, float.infinity, 10));
    assertThrown!AssertError(Rect.create(0, 0, 10, float.infinity));

    // Preconditions on method calls with invalid external parameters
    auto validRect = Rect(0, 0, 100, 50);
    assertThrown!AssertError(validRect.contains(Point(float.nan, 20)));
    assertThrown!AssertError(validRect.contains(Point(20, float.nan)));
    assertThrown!AssertError(validRect.contains(Point(float.infinity, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(0, 0, -10, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(0, 0, 10, -20)));
    assertThrown!AssertError(validRect.intersects(Rect(float.nan, 0, 10, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(float.infinity, 0, 10, 20)));

    auto validPoint = Point(10, 20);
    assertThrown!AssertError(validPoint.distanceTo(Point(float.nan, 0)));
    assertThrown!AssertError(validPoint.distanceTo(Point(0, float.nan)));
    assertThrown!AssertError(validPoint.distanceTo(Point(float.infinity, 0)));

    // Deserialization contract validation: invalid JSON bounds or points actively trigger AssertError
    assertThrown!AssertError(
            Rect.fromJson(parseJSON(`{"x": 0, "y": 0, "width": -5, "height": 10}`)));
    assertThrown!AssertError(
            Rect.fromJson(parseJSON(`{"x": 0, "y": 0, "width": 10, "height": -5}`)));
    assertThrown!AssertError(Rect.fromJson(JSONValue([
        "x": JSONValue(double.nan),
        "y": JSONValue(0.0),
        "width": JSONValue(10.0),
        "height": JSONValue(10.0)
    ])));
    assertThrown!AssertError(Point.fromJson(JSONValue([
        "x": JSONValue(double.nan),
        "y": JSONValue(0.0)
    ])));
    assertThrown!AssertError(Point.fromJson(JSONValue([
        "x": JSONValue(0.0),
        "y": JSONValue(double.nan)
    ])));

    // ElementSelector byCoordinate contract validation
    assertThrown!AssertError(ElementSelector.byCoordinate(Point(float.nan, 0)));
}
