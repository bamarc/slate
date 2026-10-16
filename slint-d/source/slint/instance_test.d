module slint.instance_test;

import slint.instance;
import slint.compiler;
import slint.value;

version (SlintNative)
{
    // Best practice: Native integration test for rich properties on ComponentInstance
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;

        auto c = new Compiler();
        auto res = c.buildFromSource("export struct UserData {\n" ~ "    name: string,\n"
                ~ "    age: int,\n" ~ "}\n" ~ "export component RichInstanceTest inherits Window {\n"
                ~ "    in-out property <color> bg: #ff0000;\n" ~ "    in-out property <brush> fill: #00000000;\n"
                ~ "    in-out property <UserData> user: { name: \"init\", age: 20 };\n"
                ~ "    callback add(int, int) -> int;\n" ~ "}\n");
        auto comp = res.component("RichInstanceTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // Color property
        auto col = inst.getColor("bg");
        assert(col.red == 255 && col.green == 0 && col.blue == 0 && col.alpha == 255);
        inst.setColor("bg", Color.fromRgb(0, 255, 0));
        assert(inst.getColor("bg") == Color.fromRgb(0, 255, 0));
        assert(inst.getProperty("bg").color == Color.fromRgb(0, 255, 0));

        // Brush property (transparent and solid)
        auto b = inst.getBrush("fill");
        assert(b.isTransparent());
        inst.setBrush("fill", Brush.solid(Color.fromRgb(0, 0, 255)));
        assert(!inst.getBrush("fill").isTransparent());
        assert(inst.getBrush("fill").color == Color.fromRgb(0, 0, 255));

        // Struct property
        auto u = inst.getStruct("user");
        assert(u["name"].text == "init");
        assert(u["age"].number == 20);

        SlintStruct updated;
        updated["name"] = Value.of("alice");
        updated["age"] = Value.of(35.0);
        inst.setStruct("user", updated);

        auto u2 = inst.getStruct("user");
        assert(u2["name"].text == "alice");
        assert(u2["age"].number == 35);

        // Generic getProperty / setProperty
        auto propVal = inst.getProperty("user");
        assert(propVal.type == ValueType.Struct);
        assert(propVal.structFields["name"].text == "alice");

        inst.setProperty("bg", Value.of(Color.fromArgb(128, 10, 20, 30)));
        assert(inst.getColor("bg") == Color.fromArgb(128, 10, 20, 30));

        // Callback with arguments and return value
        inst.setCallback("add", (const(Value)[] args) {
            assert(args.length == 2);
            return Value.of(args[0].number + args[1].number);
        });
        auto addRet = inst.invoke("add", [Value.of(15.0), Value.of(27.0)]);
        assert(addRet.number == 42.0);

        // Invalid property access raises SlintCallError
        import std.exception : assertThrown;

        assertThrown!SlintCallError(inst.getProperty("non_existent_property"));
        assertThrown!SlintCallError(inst.setProperty("non_existent_property", Value.of(1.0)));
    }

    // Best practice: Native integration test for model properties and array synchronization
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import slint.model : Model, ArrayModel;

        auto compiler = new Compiler();
        auto res = compiler.buildFromSource("export component ModelInstanceTest inherits Window {\n"
                ~ "    in-out property <[int]> numbers: [1, 2, 3];\n"
                ~ "    in-out property <[string]> names: [\"alice\", \"bob\"];\n" ~ "}\n");
        auto comp = res.component("ModelInstanceTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // getModel for integers
        auto numModel = inst.getModel!int("numbers");
        assert(numModel !is null);
        assert(numModel.rowCount() == 3);
        assert(numModel.rowData(0) == 1);
        assert(numModel.rowData(1) == 2);
        assert(numModel.rowData(2) == 3);

        // live mutation via model pushes to native Slint model
        numModel.push(42);
        assert(numModel.rowCount() == 4);
        assert(numModel.rowData(3) == 42);

        // re-fetching model reflects mutation
        auto numModel2 = inst.getModel!int("numbers");
        assert(numModel2.rowCount() == 4);
        assert(numModel2.rowData(3) == 42);

        // setModel with ArrayModel
        auto newNums = new ArrayModel!int([10, 20, 30, 40]);
        inst.setModel!int("numbers", newNums);
        auto numModel3 = inst.getModel!int("numbers");
        assert(numModel3.rowCount() == 4);
        assert(numModel3.rowData(0) == 10);
        assert(numModel3.rowData(3) == 40);

        // string model roundtrip & setModel with array
        inst.setModel("names", ["charlie", "david", "eve"]);
        auto nameModel = inst.getModel!string("names");
        assert(nameModel.rowCount() == 3);
        assert(nameModel.rowData(0) == "charlie");
        assert(nameModel.rowData(1) == "david");
        assert(nameModel.rowData(2) == "eve");

        // mutation via setRowData and remove
        nameModel.setRowData(1, "dan");
        assert(nameModel.rowData(1) == "dan");
        nameModel.remove(0);
        assert(nameModel.rowCount() == 2);
        assert(nameModel.rowData(0) == "dan");
        assert(nameModel.rowData(1) == "eve");
    }

    // Best practice: Native integration test for Window controls, input dispatch, and Element Introspection
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import slint.window : WindowHandle, PointerEvent, PointerButton, KeyEvent;
        import std.string : indexOf;
        import std.exception : assertThrown;

        auto c = new Compiler();
        auto res = c.buildFromSource("export component WindowAndIntroTest inherits Window {\n" ~ "    width: 300px;\n" ~ "    height: 200px;\n" ~ "    in-out property <int> clicks: 0;\n" ~ "    in-out property <int> action_count: 0;\n" ~ "    in-out property <float> slider_val: 10.0;\n" ~ "    in-out property <bool> node_expanded: false;\n" ~ "    touch := TouchArea {\n" ~ "        x: 10px; y: 10px; width: 100px; height: 50px;\n" ~ "        clicked => { root.clicks += 1; }\n" ~ "    }\n" ~ "    btn := TouchArea {\n" ~ "        x: 10px; y: 70px; width: 100px; height: 50px;\n" ~ "        accessible-role: button;\n" ~ "        accessible-id: \"btn_submit\";\n" ~ "        accessible-label: \"SubmitButton\";\n" ~ "        accessible-description: \"mcp:controllable\";\n" ~ "        accessible-action-default => { root.action_count += 1; }\n" ~ "        clicked => { root.action_count += 1; }\n" ~ "    }\n" ~ "    scrubber := Rectangle {\n" ~ "        x: 10px; y: 130px; width: 100px; height: 20px;\n" ~ "        accessible-role: slider;\n" ~ "        accessible-id: \"player_scrubber\";\n" ~ "        accessible-value: \"\\{root.slider_val}\";\n" ~ "        accessible-action-set-value(v) => { if (v.is-float()) { root.slider_val = v.to-float(); } }\n" ~ "        accessible-action-increment => { root.slider_val += 5.0; }\n" ~ "        accessible-action-decrement => { root.slider_val -= 5.0; }\n" ~ "    }\n" ~ "    tree_node := Rectangle {\n" ~ "        x: 10px; y: 160px; width: 100px; height: 20px;\n" ~ "        accessible-role: list-item;\n" ~ "        accessible-id: \"tree_node_0\";\n" ~ "        accessible-expandable: true;\n" ~ "        accessible-expanded: root.node_expanded;\n" ~ "        accessible-action-expand => { root.node_expanded = !root.node_expanded; }\n" ~ "    }\n" ~ "}\n");
        auto comp = res.component("WindowAndIntroTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // Window size get / set
        auto win = inst.window;
        auto sz = win.size;
        assert(sz.width == 300.0);
        assert(sz.height == 200.0);

        win.setSize(400, 250);
        auto sz2 = win.size;
        assert(sz2.width == 400.0);
        assert(sz2.height == 250.0);

        // Event dispatching via window.click
        assert(inst.getNumber("clicks") == 0);
        win.click(50, 30);
        assert(inst.getNumber("clicks") == 1);

        // Element Introspection: dumpUiTree includes id_stable and description
        string json = inst.dumpUiTree();
        assert(json.length > 0);
        assert(json.indexOf("button") != -1);
        assert(json.indexOf("SubmitButton") != -1);
        assert(json.indexOf("\"id_stable\":true") != -1);
        assert(json.indexOf("mcp:controllable") != -1);

        // Element Introspection: findElement
        ElementInfo info;
        bool found = inst.findElement("SubmitButton", info);
        assert(found);
        assert(info.role == "button");
        assert(info.label == "SubmitButton");
        assert(info.width == 100.0);
        assert(info.height == 50.0);

        // Accessibility action execution: default, setValue, increment, decrement, expand
        assert(inst.getNumber("action_count") == 0);
        inst.invokeElementAction("SubmitButton");
        assert(inst.getNumber("action_count") == 1);

        inst.setElementValue("player_scrubber", "42.5");
        assert(inst.getNumber("slider_val") == 42.5);
        inst.incrementElement("player_scrubber");
        assert(inst.getNumber("slider_val") == 47.5);
        inst.decrementElement("player_scrubber");
        assert(inst.getNumber("slider_val") == 42.5);

        assert(!inst.getBool("node_expanded"));
        inst.expandElement("tree_node_0");
        assert(inst.getBool("node_expanded"));

        // W2 duplicate explicit accessible-id rejection
        auto dupRes = c.buildFromSource("export component DupTreeTest inherits Window {\n"
                ~ "    Rectangle { accessible-role: button; accessible-id: \"dup_id\"; }\n"
                ~ "    Rectangle { accessible-role: button; accessible-id: \"dup_id\"; }\n" ~ "}\n");
        auto dupInst = dupRes.component("DupTreeTest").create();
        assertThrown!SlintCallError(dupInst.dumpUiTree());
    }
}
