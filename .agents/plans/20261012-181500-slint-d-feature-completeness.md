# Plan: Slint-D Feature Completeness — Rich Values, Structs, Models, Window Controls & Introspection

- **Owning Project**: `slint-d` (`source/slint/*`, `bridge/src/lib.rs`), with consumers in `slate-dlang`
- **Status**: `draft`
- **Revision**: 1
- **Timestamp**: 2026-10-12T18:15:00Z
- **Author**: Antigravity Architect & Core Systems Engineer

---

## 1. Goal and Scope

### Goal
Elevate `slint-d` (and its native Rust C-ABI bridge `slint-d-bridge`) from an early scalar-only prototype into a **production-grade, feature-complete** binding for **Slint 1.18.1**, on par with official Node.js (`slint-ui`) and Python (`slint`) bindings. Enable full two-way exchange of rich types (Structs, Colors, Brushes, Images, Enums, Models/Arrays), live reactive array synchronization, window controls, and element accessibility introspection, written in modern, idiomatic, safety-focused D.

### Scope

1. **Rich Value & Struct FFI Support**:
   - Bridge: Full conversion in `value_to_c` and `c_to_value` for `Color`, `Brush`, `Struct` (`slint_interpreter::Struct`), and `EnumerationValue`.
   - C-ABI: Opaque `SlintStruct` manipulation handles (`slint_struct_new`, `set_field`, `get_field`, `iter`, `free`).
   - D Layer: Complete conversion between D `Color`, `Brush`, `EnumValue`, and `SlintStruct` (`Value[string]`) across `SlintValue`.
   - ComponentInstance: `getProperty` / `setProperty` accepting arbitrary `Value`s, plus typed convenience getters `getColor`, `setColor`, `getBrush`, `setBrush`, `getStruct`, `setStruct`.
   - Codegen: Support `Color`, `Brush`, `SlintStruct` in `Prop!` compile-time mixins.

2. **Dynamic Array / Model FFI Support (`ModelRc<Value>`)**:
   - Bridge: Implement a native `VecModel<Value>` bridge handle (`SlintModel`) supporting `new`, `push`, `set`, `remove`, `clear`, `count`, and `get`.
   - D Layer: Connect D's `ArrayModel!T` with native Slint arrays so models passed to `.slint` components dynamically update the UI upon mutation.
   - ComponentInstance: `getModel` / `setModel`.

3. **Window Management & Input Event Dispatching**:
   - Bridge: Wrap `ComponentInstance::window()` to expose:
     - Window size (`size()`, `set_size()`)
     - Window visibility (`is_visible()`)
     - Low-level event dispatching (`dispatch_event`) for `PointerPressed`, `PointerReleased`, `PointerMoved`, `KeyPressed`, `KeyReleased`.
   - D Layer: `instance.window` facade returning a typed `WindowHandle` with `.size`, `.setSize(width, height)`, `.dispatchPointer(...)`, `.dispatchKey(...)`.

4. **Component-Native Element & Accessibility Introspection**:
   - Bridge: Query live elements by ID / accessible role / accessible action using Slint's accessibility API or `ElementHandle` pipeline.
   - Expose native tree inspection via JSON tree dump for headless automation.
   - D Layer: Foundation for `slate-dlang` to implement its `slint_backend` automation engine without mock fallbacks.

5. **Test-Driven Development (TDD) & Modern D Idioms**:
   - Tests written **before** implementations for every phase (Red → Green → Iterate).
   - High safety: `@safe` / `@trusted` boundaries, RAII cleanup via `scope(exit)`, template metaprogramming, strong type safety, zero stubbing.

---

## 2. Architecture & FFI Boundary Design

### Data Flow Overview

```
[ D Application / slate-dlang ]
             │
             │ Idiomatic D: Color, Brush, SlintStruct, ArrayModel!T, WindowHandle
             ▼
[ slint-d D Layer (`source/slint/*`) ]
   • Value: Rich tagged union (Number, String, Bool, Color, Brush, Struct, Model, Image, Enum)
   • instance.d: getProperty, setProperty, window handle, model binding
   • codegen.d: Prop!("user", SlintStruct), Prop!("accent", Color)
             │
             │ C ABI: SlintValue (tag, number, text, color_argb, handle, owned)
             │        Opaque handles: SlintStruct*, SlintModel*, SlintWindow*
             ▼
[ slint-d-bridge Rust Layer (`bridge/src/lib.rs`) ]
   • slint_interpreter::Value conversion (all variants)
   • VecModel<Value> wrapper with notification callbacks
   • ComponentInstance::window() event dispatching
             │
             ▼
[ Slint 1.18.1 Runtime & Native Desktop Engine ]
```

### Extended `SlintValue` (C ABI Layout)

```c
typedef struct {
    int tag;              // 0=Void, 1=Number, 2=String, 3=Bool, 4=Model, 5=Struct, 6=Brush, 7=Image, 8=Enum
    double number;        // Number value
    const char* text_ptr; // String / Enum variant text
    size_t text_len;      // String length
    int boolean;          // Boolean flag
    uint32_t color_argb;  // 0xAARRGGBB for Color and Solid Brush
    int brush_kind;       // 0=Transparent, 1=Solid
    void* handle;         // Opaque pointer for Struct, Model, Image
    int owned;            // 1 if text/handle is heap-allocated and must be released
} SlintValue;
```

---

## 3. Implementation Phases & EARS Requirements

### Phase 1: Rich Values & Structs (Color, Brush, Struct, Enum)
- **EARS-1.1**: When a Slint component has a `property <color>` or `property <brush>`, the D layer SHALL be able to read and write it using `slint.value.Color` and `slint.value.Brush`.
- **EARS-1.2**: When a Slint component has an anonymous or named `struct` property, the D layer SHALL be able to get and set fields via `slint.value.SlintStruct` (`Value[string]`) or typed D structs.
- **EARS-1.3**: When an enum property is declared, the D layer SHALL get and set its variant via `EnumValue` or `string`.

### Phase 2: Live Dynamic Models (`ModelRc<Value>` & `ArrayModel!T`)
- **EARS-2.1**: When a D application creates an `ArrayModel!T` and passes it to a Slint property, the component SHALL render all elements in the array.
- **EARS-2.2**: When items are appended, inserted, or removed in D, the bridge SHALL notify Slint via `ModelNotify` so the UI reactively updates.

### Phase 3: Window Management & Input Event Dispatching
- **EARS-3.1**: When a component is instantiated, calling `instance.window.size` SHALL return the logical dimensions of the window.
- **EARS-3.2**: When `instance.window.setSize(w, h)` is invoked, the Slint window SHALL resize accordingly.
- **EARS-3.3**: When `instance.window.dispatchPointer(event, x, y, button)` or `dispatchKey(event, text)` is called, the Slint event loop SHALL process and dispatch the event to the targeted child element.

### Phase 4: Element & Accessibility Introspection
- **EARS-4.1**: The bridge SHALL provide an `inspect_tree` C-ABI function returning the hierarchical UI tree (IDs, roles, labels, bounds) in JSON format.
- **EARS-4.2**: The bridge SHALL support executing accessibility default actions by element ID.

---

## 4. Verification Plan

### Test Suites to Author (TDD - Red First)

1. **`slint-d/tests/rich_value_tests.d`**:
   - Test color conversions (RGB, ARGB, hex).
   - Test solid and transparent brushes.
   - Test struct creation, nested structs, field access, and roundtrip through `.slint` component instances.
   - Test enum variants.

2. **`slint-d/tests/native_model_tests.d`**:
   - Test `ArrayModel` passed to a `.slint` `ListView`.
   - Test insertion, removal, and mutation, verifying row counts and offscreen snapshot renders.

3. **`slint-d/tests/window_tests.d`**:
   - Test window size get/set.
   - Test pointer click event dispatching to a button component and assert callback fires.

4. **`slate-dlang/dub test`**:
   - Verify that `slate-dlang` unit tests pass with zero regressions.

---

## 5. User Review Gate

This plan introduces substantial new capabilities to `slint-d` and `slint-d-bridge`. Please review the architecture, FFI boundaries, and phased scope above.
