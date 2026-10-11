# 03 — Shared Contracts (single source of truth)

> **Every work package (WP) MUST use exactly the names, paths, types, and signatures below.**
> If a WP needs something that is not here, or something here does not compile, **STOP and
> escalate** to the orchestrator (see `00-meta-implementation-plan.md` §Escalation). Do not invent
> alternatives or rename anything.

Plan: [`../../20261011-162725-dynamic-mcp-capabilities.md`](../../20261011-162725-dynamic-mcp-capabilities.md) (revision 3).
All paths below are relative to the repository root `/home/marc/Entwicklung/slate`.

---

## 0. Global rules (apply to every WP)

| # | Rule |
|---|---|
| G1 | **No mocks, fakes, stubs, or simulated engines** in production code or tests. Every test drives a real Slint window (testing backend with an event loop, see WP-01) or real MCP/JSON-RPC over a real transport. |
| G2 | **No hardcoded element lists, ids, labels, or tool lists** in the agent or MCP code. Every capability comes from the live item tree or from the action registry. (Fixture `.slint` code in tests is fine: it is the app under test, not a fake.) |
| G3 | **Exactly one semantic action per request.** Never send pointer events and an accessibility action for the same request. Pointer input happens only when the caller passes `fallback: "pointer"`. |
| G4 | **Red → Green → Iterate.** Write the failing test first, run it, and paste the failing output into the WP report. Then implement. |
| G5 | Forbidden in delivered code: `todo!()`, `unimplemented!()`, `#[ignore]`, `panic!("not implemented")`, `unwrap()`/`expect()` inside closures that run on the UI thread (return `AgentError` instead), commented-out tests, `#[allow(dead_code)]` on new items, `println!` in library crates (use `log::` macros; stdout belongs to JSON-RPC). |
| G6 | All `i_slint_core` access lives **only** in `slate-rust/agent/src/semantic/` and `slate-rust/agent/src/slint_backend.rs`. No other crate imports `i_slint_core`. |
| G7 | UI-thread objects (`ItemRc`, `ItemWeak`, `slint::Window`, component handles) are `!Send`. They never leave the UI thread. Cross-thread code passes only the `Send` types from §2. |
| G8 | Run every command from `slate-rust/` unless stated otherwise. Use `just` recipes for full gates (`just check`, `just test`, `just fmt`). For a single test file, use `cargo test -p <crate> --test <file_stem>`. |

---

## 1. Crate and module layout (final state)

```
slate-rust/agent/src/
  lib.rs                    # re-exports (MODIFY: add `pub mod semantic; pub mod actions;` and re-exports in §2.6)
  error.rs                  # AgentError (MODIFY in WP-02: new variants §3)
  traits.rs                 # MODIFY in WP-05 (add new traits §4); WP-15 deletes old UiInspector/ElementController
  engine.rs                 # MODIFY in WP-05 (compose new traits); WP-15 deletes Default* mocks
  builder.rs                # MODIFY in WP-05 (wiring) and WP-09 (with_action)
  slint_backend.rs          # MODIFY in WP-05 (delegate to semantic/); WP-15 deletes the old raw tree builder
  semantic/
    mod.rs                  # WP-02: `pub mod types; pub mod roles;` WP-03 adds `pub mod tree; pub mod refs; pub mod snapshot;` WP-04 adds `pub mod resolve; pub mod execute;`
    types.rs                # WP-02: all Send data types (§2)
    roles.rs                # WP-02: role and action name mapping (§2.4)
    tree.rs                 # WP-03: raw ItemRc traversal incl. popups (UI-thread only)
    refs.rs                 # WP-03: thread_local ref registry (UI-thread only)
    snapshot.rs             # WP-03: SemanticSnapshot builder (UI-thread only)
    resolve.rs              # WP-04: Target -> ItemRc resolution, ancestor walk
    execute.rs              # WP-04: single-dispatch executor
    discovery.rs            # WP-09: Tier-2 SlateAgentAction discovery (UI-thread only)
  actions/
    mod.rs                  # WP-09: ActionSpec, ActionRegistry, ActionHandler, ActionContext
    schema.rs               # WP-09: minimal JSON-schema validator
slate-rust/agent/tests/support/mod.rs   # WP-01: real-window harness (shared by all real-window test files)

slate-rust/mcp/src/
  server.rs                 # WP-11 (dynamic tools/list, list_changed, negotiation); WP-13 per-connection sessions
  schema.rs                 # WP-10 (generic tool schemas); WP-11 (annotations, outputSchema)
  tools/mod.rs              # WP-10: registry-driven dispatch
  tools/ui.rs               # WP-10: ui_snapshot, ui_find, ui_act, ui_wait_for
  tools/screenshot.rs       # WP-10: tool renamed to `screenshot`
  tools/capabilities.rs     # WP-11: list_capabilities, invoke_action, action_<name>
  tools/render.rs           # WP-10: snapshot text rendering (§6.3)
  transport/socket.rs       # WP-13
  bin/slate_mcp.rs          # WP-12
ui/components/agent_action.slint        # WP-08
```

Deleted by the end: `mcp/src/tools/{click,keys,tree,state}.rs` (WP-10), `Default*` mocks in
`agent/src/engine.rs` (WP-15), the simulated `TestEngine` in `test/src/harness.rs` (WP-16).

---

## 2. Data types (`slate_agent::semantic::types`, owner WP-02)

All types: `#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]` (add `Eq`/`Hash` where
noted), `#[serde(rename_all = "snake_case")]` on enums. They are all `Send + Sync`.

### 2.1 Identity and targeting

```rust
/// Short element reference handed to agents, format "e<N>" (N = u64, starts at 1, never reused
/// within a process). Valid until the next `ui_snapshot` call (see §5.2).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ElementRef(pub String);

impl ElementRef {
    pub fn from_index(n: u64) -> Self;          // ElementRef(format!("e{n}"))
    pub fn parse(s: &str) -> Option<Self>;      // accepts "e<digits>" only; anything else -> None
    pub fn as_str(&self) -> &str;
}
impl std::fmt::Display for ElementRef { /* writes the inner string */ }

/// Selector fields are ANDed. At least one field must be Some (else AgentError::InvalidParams).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Selector {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,            // exact match on accessible-id
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,          // exact match on role name (§2.4)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,          // exact match on accessible-label (trimmed)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_contains: Option<String>, // case-insensitive substring of accessible-label
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Target {
    Ref(ElementRef),
    Selector(Selector),
}
```

### 2.2 Nodes and snapshots

```rust
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct NodeStates {
    pub enabled: bool,                 // accessible-enabled, default true when unset
    pub visible: bool,                 // ItemRc::is_visible()
    pub focused: bool,                 // item == window focus item
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,         // Some only when checkable
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expanded: Option<bool>,        // Some only when expandable
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<bool>,        // Some only when item-selectable
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ValueRange { pub min: f32, pub max: f32, pub step: f32 } // step = 1.0 when unset

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DebugInfo { pub element_id: String, pub type_name: String } // O1, debug builds only

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SemanticNode {
    #[serde(rename = "ref")]
    pub reference: ElementRef,
    pub role: String,                                  // §2.4 role name
    pub name: String,                                  // accessible-label, "" if unset
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,                         // accessible-value
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,                   // accessible-description
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,                            // accessible-id
    pub states: NodeStates,
    pub actions: Vec<ActionKind>,                      // §2.4 derivation, sorted by enum order
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<ValueRange>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds: Option<crate::model::Rect>,            // logical px, window coords; only if include_bounds
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug: Option<DebugInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<SemanticNode>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotMode { #[default] Semantic, Full }

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SnapshotOptions {
    #[serde(default)] pub mode: SnapshotMode,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub root: Option<ElementRef>,
    #[serde(default)] pub include_bounds: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub max_depth: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowInfo {
    pub title: String,
    pub width: f32,          // LOGICAL px = physical / scale_factor (fixes E-11)
    pub height: f32,
    pub scale_factor: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SemanticSnapshot {
    pub generation: u64,              // increments on every ui_snapshot call
    pub window: WindowInfo,
    pub root: SemanticNode,           // role "window", name = window title
    pub node_count: usize,            // number of SemanticNodes in `root` incl. root
    pub debug_info_available: bool,
}
```

### 2.3 Actions and outcomes

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind { Activate, Toggle, SetValue, Increment, Decrement, Expand, Focus, Type }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Fallback { #[default] None, Pointer }

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ActOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")] pub value: Option<String>, // set_value
    #[serde(default, skip_serializing_if = "Option::is_none")] pub text: Option<String>,  // type
    #[serde(default)] pub replace: bool,                                                  // type: replace instead of append
    #[serde(default)] pub fallback: Fallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionMethod { Accessibility, Focus, KeyEvents, Pointer }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActionOutcome {
    pub action: ActionKind,
    pub method: ActionMethod,
    pub steps: u32,                    // 1, or the number of increment/decrement steps for stepped set_value
    pub target: SemanticNode,          // state RE-READ after the action, children always empty
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaitCondition {
    pub target: Target,
    #[serde(default = "default_true")] pub exists: bool,       // false = wait until gone
    #[serde(default, skip_serializing_if = "Option::is_none")] pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub checked: Option<bool>,
}
fn default_true() -> bool { true }
```

### 2.4 Role and action derivation (`slate_agent::semantic::roles`, owner WP-02)

```rust
pub fn role_name(role: i_slint_core::items::AccessibleRole) -> &'static str;
```
Mapping: snake_case of the Slint variant, with these exact strings:
`None→"none"`, `Button→"button"`, `Checkbox→"checkbox"`, `Combobox→"combobox"`,
`Groupbox→"groupbox"`, `Image→"image"`, `List→"list"`, `Slider→"slider"`, `Spinbox→"spinbox"`,
`Tab→"tab"`, `TabList→"tab_list"`, `TabPanel→"tab_panel"`, `Text→"text"`, `Table→"table"`,
`Tree→"tree"`, `ProgressIndicator→"progress_indicator"`, `TextInput→"text_input"`,
`Switch→"switch"`, `ListItem→"list_item"`, `RadioButton→"radio_button"`,
`RadioGroup→"radio_group"`, `WindowTitleBar→"window_title_bar"`, `Banner→"banner"`,
`Complementary→"complementary"`, `ContentInfo→"content_info"`, `Form→"form"`, `Main→"main"`,
`Navigation→"navigation"`, `Region→"region"`, `Search→"search"`, any future variant → `"unknown"`
(the enum is `#[non_exhaustive]`, so add a `_ =>` arm). The snapshot root uses the literal role `"window"`.

```rust
/// `supported` = ItemRc::supported_accessibility_actions(); flags from accessible string properties.
pub fn derive_actions(
    role: &str,
    supported: i_slint_core::accessibility::SupportedAccessibilityAction,
    checkable: bool,
    focusable: bool,
) -> Vec<ActionKind>;
```
Rules, in this order (the result is sorted and deduplicated):
- `Default` supported → `Activate`; additionally `Toggle` if `checkable`.
- `Increment` → `Increment`; `Decrement` → `Decrement`; `Expand` → `Expand`.
- `SetValue` → `SetValue`; additionally `Type` if `role == "text_input"`.
- `focusable` → `Focus`. `focusable` is true when `role == "text_input"` or the item has the
  `DelegateFocus` property set (`accessible_string_property(DelegateFocus).is_some()`).
- A role of `"slider"` or `"spinbox"` that supports both `Increment` and `Decrement` also gets
  `SetValue` (it is executed by stepping, §5.4).

```rust
/// Parse Slint's stringified accessible properties. Slint encodes booleans as "true"/"false"
/// (verify in 02-api-cheatsheet.md; if different, follow the cheat sheet and note it in the WP report).
pub fn parse_bool(s: &str) -> Option<bool>;
pub fn parse_f32(s: &str) -> Option<f32>;
```

### 2.5 Custom actions (`slate_agent::actions`, owner WP-09)

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionTier { Ui, App }        // Ui = Tier 2 (SlateAgentAction in Slint), App = Tier 3 (Rust)

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActionDescriptor {
    pub name: String,                  // ^[a-z][a-z0-9_]{0,47}$
    pub tier: ActionTier,
    pub description: String,
    pub input_schema: serde_json::Value, // JSON object schema; default {"type":"object"}
    pub enabled: bool,                 // Ui: accessible-enabled; App: always true
    pub read_only: bool,               // MCP readOnlyHint
    pub destructive: bool,             // MCP destructiveHint
}

pub struct ActionSpec { /* private fields; builder: */ }
impl ActionSpec {
    pub fn new(name: impl Into<String>) -> Self;                 // validates lazily in register()
    pub fn description(self, d: impl Into<String>) -> Self;
    pub fn input_schema(self, schema: serde_json::Value) -> Self;
    pub fn read_only(self, v: bool) -> Self;
    pub fn destructive(self, v: bool) -> Self;
    pub fn descriptor(&self) -> ActionDescriptor;                // tier App, enabled true
}

pub type ActionFuture = std::pin::Pin<Box<dyn std::future::Future<Output = Result<serde_json::Value, crate::error::AgentError>> + Send>>;
pub type ActionHandler = std::sync::Arc<dyn Fn(serde_json::Value) -> ActionFuture + Send + Sync>;

#[derive(Default)]
pub struct ActionRegistry { /* RwLock<BTreeMap<String, (ActionSpec, ActionHandler)>> */ }
impl ActionRegistry {
    pub fn new() -> Self;
    /// Errors: InvalidParams{path:"/name"} for a bad name or schema; InvalidOperation for a duplicate name.
    pub fn register(&self, spec: ActionSpec, handler: ActionHandler) -> Result<(), crate::error::AgentError>;
    pub fn descriptors(&self) -> Vec<ActionDescriptor>;          // sorted by name
    pub fn handler(&self, name: &str) -> Option<(ActionDescriptor, ActionHandler)>;
}

/// Minimal validator (actions/schema.rs). Supported keywords: type (object|string|number|integer|
/// boolean|array|null or an array of those), properties, required, enum, items,
/// additionalProperties (bool only), minimum, maximum, minLength, maxLength. Unknown keywords are
/// ignored. The error path uses JSON-Pointer style, e.g. "/path" or "/items/0/name".
pub fn validate(schema: &serde_json::Value, value: &serde_json::Value) -> Result<(), crate::error::AgentError>; // InvalidParams{path,message}
pub fn check_schema(schema: &serde_json::Value) -> Result<(), crate::error::AgentError>; // the root must be {"type":"object",...}
```

**Tier-2 Slint encoding** (contract between WP-08 and WP-09; must match exactly):

| `SlateAgentAction` property | Built-in accessible property it is bound to | Read by discovery as |
|---|---|---|
| `name` | `accessible-id: "slate.action:" + root.name` | name = id without the prefix |
| `description` | `accessible-description` | description |
| `params-schema` (string, default `"{\"type\":\"object\"}"`) | `accessible-placeholder-text` | input_schema (JSON-parsed; parse error → descriptor skipped + `log::warn!`) |
| `enabled` (bool, default true) | `accessible-enabled` | enabled |
| `destructive` (bool, default false) | `accessible-value-maximum: destructive ? 1 : 0` | destructive (`ValueMaximum == 1`) |
| `read-only` (bool, default false) | `accessible-read-only` | read_only |
| `result` (in-out string) | `accessible-value` | result read after invocation |
| `callback invoked(string)` | `accessible-action-set-value(args) => { root.invoked(args); }` | invocation = `AccessibilityAction::SetValue(args_json)` |
| — | `accessible-role: none` | hidden from platform assistive tech (spike A1) |

The `ui_snapshot` semantic mode **excludes** nodes whose `id` starts with `slate.action:`. They
appear only through `list_capabilities`. Discovery skips invisible subtrees, so an action inside a
closed dialog is not listed (U4).

### 2.6 Re-exports from `slate_agent` (lib.rs; owners WP-02, WP-03, WP-04, WP-09)

```rust
pub use semantic::types::*;
pub use actions::{ActionDescriptor, ActionHandler, ActionFuture, ActionRegistry, ActionSpec, ActionTier};
pub use traits::{SemanticInspector, SemanticController, CapabilityProvider};
```
`slate-rust/lib/src/agent.rs` re-exports the same names (WP-05).

---

## 3. Errors (`AgentError` in `slate-rust/agent/src/error.rs`, owner WP-02)

Add these variants. Keep every existing variant and constructor.

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate { pub reference: String, pub role: String, pub name: String }

#[error("Stale element ref '{reference}': {reason}")]
StaleRef { reference: String, reason: String },
#[error("Selector matched {count} elements")]
AmbiguousTarget { count: usize, candidates: Vec<Candidate> },   // candidates capped at 10
#[error("Element '{reference}' is not interactable: {reason}")]
NotInteractable { reference: String, reason: String },          // reason: "disabled" | "not_visible"
#[error("Action '{action}' unsupported on '{reference}'; supported: {supported:?}")]
UnsupportedAction { reference: String, action: String, supported: Vec<String> },
#[error("Invalid params at '{path}': {message}")]
InvalidParams { path: String, message: String },
#[error("Action not found: {name}")]
ActionNotFound { name: String },
#[error("Action '{name}' failed: {reason}")]
ActionFailed { name: String, reason: String },
```

And add this method:

```rust
impl AgentError {
    /// Stable machine-readable code (snake_case). Exhaustive match, no `_` arm.
    pub fn code(&self) -> &'static str;
}
```
Codes: `element_not_found`, `timeout`, `window_unavailable`, `window_closed`,
`event_loop_unavailable`, `ui_channel_closed`, `ui_panic`, `dispatch_failed`, `render_error`,
`state_error`, `invalid_operation`, `serialization_error`, `protocol_error`, `internal`,
`stale_ref`, `ambiguous_target`, `not_interactable`, `unsupported_action`, `invalid_params`,
`action_not_found`, `action_failed`.

```rust
/// JSON payload used by MCP tool error results (§6.4).
pub fn to_error_json(&self) -> serde_json::Value; // {"code": .., "message": self.to_string(), "details": <variant fields or null>}
```

---

## 4. Traits (`slate-rust/agent/src/traits.rs`, owner WP-05)

These are **added** next to the existing traits. The old `UiInspector`/`ElementController` traits
are removed later, in WP-15, after WP-10 has switched the MCP tools over.

```rust
#[async_trait::async_trait]
pub trait SemanticInspector: Send + Sync {
    async fn snapshot(&self, opts: SnapshotOptions) -> Result<SemanticSnapshot, AgentError>;
    /// Adds refs for the matches to the current generation; does NOT start a new generation.
    async fn find(&self, selector: Selector) -> Result<Vec<SemanticNode>, AgentError>;
}

#[async_trait::async_trait]
pub trait SemanticController: Send + Sync {
    async fn act(&self, target: Target, action: ActionKind, opts: ActOptions) -> Result<ActionOutcome, AgentError>;
    /// Polls every 50 ms on the UI thread until the condition holds or the timeout passes (AgentError::Timeout).
    async fn wait_for(&self, cond: WaitCondition, timeout: std::time::Duration) -> Result<Option<SemanticNode>, AgentError>;
}

#[async_trait::async_trait]
pub trait CapabilityProvider: Send + Sync {
    /// Tier 2 (discovered now) + Tier 3 (registered), merged, sorted by name. On a name clash Tier 3 wins (log::warn!).
    async fn list_actions(&self) -> Result<Vec<ActionDescriptor>, AgentError>;
    /// Validates args against input_schema BEFORE calling. Disabled Tier-2 action -> NotInteractable.
    async fn invoke_action(&self, name: &str, args: serde_json::Value) -> Result<serde_json::Value, AgentError>;
    /// Stable u64 hash of the sorted (name, tier, enabled, input_schema.to_string()) tuples.
    async fn fingerprint(&self) -> Result<u64, AgentError>;
}
```

`AutomationEngine` gains these methods (WP-05). Keep the existing ones until WP-15:

```rust
fn semantic(&self) -> &dyn SemanticInspector;
fn actor(&self) -> &dyn SemanticController;
fn capabilities(&self) -> &dyn CapabilityProvider;
```

Concrete implementations, all in `slint_backend.rs` (WP-05), each holding `Arc<SlintUiBridge>`
plus a `slint::Weak<T>` type-erased behind `Arc<dyn Fn() -> Option<slint::Window> + Send + Sync>`
or the existing erasure in `slint_backend.rs`:
`SlintSemanticInspector`, `SlintSemanticController`, `SlintCapabilityProvider` (the last also holds
`Arc<ActionRegistry>`).

---

## 5. Behavioral contracts (semantic core)

### 5.1 Traversal (`semantic/tree.rs`, WP-03)
- Start at the window root `ItemRc`. Then visit every active popup from
  `WindowInner::active_popups()`, mirroring `i-slint-backend-testing` `search_api.rs` ~L340-415.
- Skip an item **and its whole subtree** when `!item.is_visible()`.
- Visit children in tree order (stable and deterministic).

### 5.2 Ref registry (`semantic/refs.rs`, WP-03)

The registry is UI-thread only:

```rust
thread_local! { static REGISTRY: RefCell<RefRegistry> = RefCell::new(RefRegistry::default()); }
pub struct RefEntry { pub weak: ItemWeak, pub role: String, pub generation: u64 }
pub fn begin_generation() -> u64;                 // clears the map, generation += 1, returns new gen
pub fn register(item: &ItemRc, role: &str) -> ElementRef;  // next index (global counter, never reset)
pub fn lookup(r: &ElementRef) -> Result<ItemRc, AgentError>;
pub fn current_generation() -> u64;
```

`lookup` returns errors in this order:
1. Not in the map → `StaleRef{reason:"ref is not from the current snapshot"}`.
2. `weak.upgrade()` is `None` → `StaleRef{reason:"element was destroyed"}`.
3. The role now differs → `StaleRef{reason:"element changed"}`.

### 5.3 Snapshot shape (`semantic/snapshot.rs`, WP-03)
- **Semantic mode** includes an item when `role != "none"`, OR it has a non-empty label and at
  least one action, OR it has an `accessible-id`. Excluded items are dropped; their included
  descendants are attached to the nearest included ancestor. Also drop a `text` child whose name
  equals its parent's name. Exclude `slate.action:` ids (§2.5).
- **Full mode** includes every visible item; role `"none"` is allowed; the `name` falls back to
  the debug element id when it is available.
- `max_depth` counts SemanticNode levels below the root (root = depth 0).
- `include_bounds`: `item.geometry()` mapped with `map_to_window`, in logical px.
- `debug`: filled only when `item.element_type_names_and_ids(0)` is `Some`.

### 5.4 Resolution and execution (`semantic/resolve.rs`, `semantic/execute.rs`, WP-04)

Steps, in order. Every check happens **before** any side effect.

1. **Resolve the target.**
   - `Target::Ref` → `refs::lookup`.
   - `Target::Selector` → traverse (§5.1) and collect the items that match all set fields.
   - 0 matches → `ElementNotFound`.
   - More than 1 match → `AmbiguousTarget` (each candidate is registered so it gets a ref).
   - 1 match → that item.
2. **Find the actionable element.** Walk from the item upwards with `parent_item(...)` and pick
   the nearest inclusive ancestor whose `derive_actions` contains the requested `ActionKind`.
   If there is none:
   - with `fallback == Pointer` → go to step 5;
   - otherwise → `UnsupportedAction{supported: actions of the ORIGINAL item}`.
3. **Check interactability** of the chosen element:
   - `enabled == false` → `NotInteractable{reason:"disabled"}`;
   - not visible → `NotInteractable{reason:"not_visible"}`.
4. **Dispatch exactly once:**

| ActionKind | Dispatch | method |
|---|---|---|
| Activate, Toggle | `accessible_action(&AccessibilityAction::Default)` | accessibility |
| Increment / Decrement / Expand | the matching `AccessibilityAction` | accessibility |
| SetValue (SetValue supported) | `AccessibilityAction::SetValue(opts.value)` (missing value → InvalidParams `/value`) | accessibility |
| SetValue (only Inc/Dec) | parse the current and target values as f32; step toward the target, re-reading after each step; stop when `abs(cur-target) <= step/2`, when there is no progress (value unchanged after a step → `ActionFailed`), or after 10 000 steps | accessibility, `steps` = n |
| Focus | `WindowInner::set_focus_item(&item, true, FocusReason::Programmatic)` (exact variant per cheat sheet) | focus |
| Type (SetValue supported) | focus, then `SetValue(if replace {text} else {current_value + text})` | accessibility |
| Type (no SetValue) | focus, then one `WindowEvent::KeyPressed`+`KeyReleased` per char via `window.dispatch_event` | key_events |

5. **Pointer fallback** (only when `fallback == Pointer`): exactly one
   `PointerPressed` + `PointerReleased` (left button) at the logical center of the ORIGINAL
   item's window bounds. method `pointer`.
6. Re-read the dispatched element into a `SemanticNode` (registering a ref if it has none) and
   return an `ActionOutcome`.

### 5.5 Tier-2 discovery and invocation (`semantic/discovery.rs`, WP-09)
- **Discovery** traverses (§5.1) and keeps items whose `accessible-id` starts with
  `slate.action:`. It builds an `ActionDescriptor` (tier `Ui`) from the §2.5 table.
- **Invocation:**
  1. Find the action by id. Not found → `ActionNotFound`.
  2. Disabled → `NotInteractable{reason:"disabled"}`.
  3. Validate the args against the schema.
  4. Call `accessible_action(&SetValue(args.to_string()))` exactly once.
  5. Read `accessible-value` and return it as a result: parse it as JSON, or fall back to a JSON
     string, or `{"invoked": name}` when it is empty.
- **Tier-3 invocation:**
  1. Validate the args.
  2. Run `handler(args)` inside `tokio::spawn`. A `JoinError` that is a panic → `ActionFailed{reason:"handler panicked: <msg>"}`.
  3. Pass `Err` results through unchanged.

---

## 6. MCP surface (owners WP-10, WP-11)

### 6.1 Tools (fixed generic set, exact names)

| Tool | inputSchema (JSON) | Result |
|---|---|---|
| `ui_snapshot` | `{"type":"object","properties":{"mode":{"type":"string","enum":["semantic","full"]},"root":{"type":"string"},"include_bounds":{"type":"boolean"},"max_depth":{"type":"integer","minimum":0}},"additionalProperties":false}` | text = §6.3 rendering; structuredContent = `SemanticSnapshot` |
| `ui_find` | `{"type":"object","properties":{"id":{"type":"string"},"role":{"type":"string"},"name":{"type":"string"},"name_contains":{"type":"string"}},"additionalProperties":false}` | text = one §6.3 line per match; structuredContent = `{"matches":[SemanticNode]}` |
| `ui_act` | `{"type":"object","properties":{"ref":{"type":"string"},"id":{"type":"string"},"role":{"type":"string"},"name":{"type":"string"},"name_contains":{"type":"string"},"action":{"type":"string","enum":["activate","toggle","set_value","increment","decrement","expand","focus","type"]},"value":{"type":"string"},"text":{"type":"string"},"replace":{"type":"boolean"},"fallback":{"type":"string","enum":["none","pointer"]}},"required":["action"],"additionalProperties":false}` | text = `"<action> on <role> \"<name>\" [ref=<ref>] via <method>; now: <states/value>"`; structuredContent = `ActionOutcome` |
| `ui_wait_for` | `{"type":"object","properties":{"ref":{"type":"string"},"id":{"type":"string"},"role":{"type":"string"},"name":{"type":"string"},"name_contains":{"type":"string"},"exists":{"type":"boolean"},"value":{"type":"string"},"checked":{"type":"boolean"},"timeout_ms":{"type":"integer","minimum":0,"maximum":30000}},"additionalProperties":false}` | default timeout 5000 ms; structuredContent = `{"node": SemanticNode or null}` |
| `screenshot` | `{"type":"object","properties":{},"additionalProperties":false}` | image content (`image/png`, base64) |
| `list_capabilities` | `{"type":"object","properties":{},"additionalProperties":false}` | structuredContent = `{"generic_tools":[names],"actions":[ActionDescriptor]}` |
| `invoke_action` | `{"type":"object","properties":{"name":{"type":"string"},"args":{"type":"object"}},"required":["name"],"additionalProperties":false}` | structuredContent = `{"result": <handler JSON>}` |

Target rule for `ui_act` and `ui_wait_for`: if `ref` is present, it is used and the selector fields
are ignored. Otherwise at least one selector field is required (`invalid_params` path `/ref`).

### 6.2 Dynamic tools
- Each enabled `ActionDescriptor` is listed as tool `action_<name>`:
  - `inputSchema` = its `input_schema`;
  - `description` = its description;
  - `annotations` = `{"title": name, "readOnlyHint": read_only, "destructiveHint": destructive}`.
- Calling `action_<name>` with `arguments` is identical to calling `invoke_action {name, args: arguments}`.
- Disabled actions appear in `list_capabilities` (with `enabled:false`) but NOT in `tools/list`.

### 6.3 Snapshot text rendering (`tools/render.rs`)
- One line per node, indented 2 spaces per depth:
  `- <role> "<name>" [ref=<ref>]{ id=<id>}{ value="<value>"}{ <state flags>}{ actions=[a,b]}`
- State flags, in this order, only when they apply: `disabled`, `checked`, `unchecked`,
  `expanded`, `collapsed`, `selected`, `focused`, `readonly`.
- Line 1 is the header: `window "<title>" <w>x<h> @<scale>x generation=<g> nodes=<n>`.

### 6.4 Errors in MCP
- Unknown tool name → JSON-RPC error `-32602`, message `"Unknown tool: <name>"`.
- Malformed `tools/call` params (no name) → `-32602`.
- **Every `AgentError` from a tool** (including schema `invalid_params`) → a successful JSON-RPC
  response with `ToolCallResult { isError: true }`:
  - content = one text item holding `serde_json::to_string(&err.to_error_json())`;
  - `structuredContent` = the same JSON, when negotiated (§6.5).

### 6.5 Protocol version and capabilities (WP-11)
- Supported versions, newest first: verify the latest revision at
  https://modelcontextprotocol.io/specification at implementation time (assumption A3). The minimum
  list is `["2025-06-18", "2025-03-26", "2024-11-05"]`.
- If the client's `protocolVersion` is in the list, echo it; otherwise answer with the newest.
- `structuredContent`/`outputSchema` only when negotiated ≥ `2025-06-18`. `annotations` only when ≥ `2025-03-26`.
- `capabilities.tools.listChanged = true`.
- **list_changed:**
  - After every handled request and on a poll timer, compute `CapabilityProvider::fingerprint()`.
    The poll interval is `SLATE_MCP_POLL_MS`, default `1000`, and `0` disables polling. The timer
    runs only while the session is initialized.
  - If the fingerprint differs from the last value **sent to this session**, write exactly one
    `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}` frame and store the new value.
  - The first `tools/list` response sets the baseline.
- Remove the fake seeded log lines in `McpServer::with_info`. The log buffer starts empty and only
  real events are appended.

### 6.6 Outbound frames
`McpServer` writes all frames (responses and notifications) through one
`tokio::sync::mpsc::UnboundedSender<String>` per session, drained by the transport writer task.
`handle_line` keeps returning `Option<String>` for the response. Notifications go through the
session sender (WP-11 owns this refactor).

---

## 7. Transports and CLI (owners WP-12, WP-13, WP-14)

| Item | Contract |
|---|---|
| Env var | `SLATE_MCP` = `stdio` (default when unset) \| `socket` \| `off` |
| Socket path | `$XDG_RUNTIME_DIR/slate-mcp/<app>-<pid>.sock`. Dir mode `0700`, socket mode `0600`. `<app>` = builder name sanitised to `[a-z0-9-]`. If `XDG_RUNTIME_DIR` is unset, use `std::env::temp_dir()/slate-mcp-<uid>/` (create it with 0700; refuse if it exists and is not owned by the uid) |
| Metadata | `<app>-<pid>.json` next to the socket: `{"app","pid","version","socket","started_at_ms"}` |
| Lifecycle | Remove socket and metadata on `AgentHandle::stop()`/`Drop`. Before binding, remove a stale socket whose pid no longer exists (`/proc/<pid>` missing) |
| Sessions | Each accepted connection gets its own `McpServer` session (own `initialized` flag and list_changed baseline) sharing the same `Arc<dyn AutomationEngine>`. Up to 8 concurrent connections; reject more by closing the stream |
| Builder | `AgentBuilderMcpExt::with_mcp_socket(self) -> Self`; `slate::agent::init` reads `SLATE_MCP` |
| Platform | socket code is `#[cfg(unix)]`; on other platforms `SLATE_MCP=socket` logs an error and falls back to `off` |
| CLI | `slate-mcp ps [--json]`, `slate-mcp attach <app\|pid>` (stdio↔socket byte proxy), `slate-mcp snapshot`, `slate-mcp find`, `slate-mcp act`, `slate-mcp wait`, `slate-mcp screenshot`, `slate-mcp actions`, `slate-mcp call <action> [json]`, `slate-mcp tools`, `slate-mcp serve` (existing). Removed: `inspect`, `click`, `type`/`send-keys`, `state` |
| Stdout hygiene | While the stdio transport is active, nothing but JSON-RPC frames goes to stdout (W8). All library logging goes through `log` → stderr |

---

## 8. Test harness contract (owner WP-01; used by every real-window test)

The Slint testing backend's event-loop init can be called **once per process**. So every
real-window test file is a `harness = false` test target:

```toml
# slate-rust/agent/Cargo.toml (same pattern in mcp/ and lib/)
[[test]]
name = "semantic_actions_tests"
harness = false
```

```rust
// slate-rust/agent/tests/support/mod.rs  (shared via `#[path = "support/mod.rs"] mod support;`)
pub type ScenarioFn = fn() -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send>>;
pub struct Scenario { pub name: &'static str, pub run: ScenarioFn }

/// Initialises i_slint_backend_testing::init_integration_test_with_system_time(), runs the Slint
/// event loop on the main thread, and runs the scenarios sequentially on a worker thread with a
/// tokio multi-thread runtime. Honors `cargo test -- <filter>` (substring on name). Prints
/// "test <name> ... ok|FAILED" lines and exits the process with code 1 if any scenario failed.
pub fn run_scenarios(scenarios: &[Scenario]) -> !;

/// Creates the component ON THE UI THREAD, shows it, keeps the strong handle alive in a
/// thread_local until `Fixture::close`, builds the real agent engine for it, and returns Send handles.
pub struct Fixture<T: slint::ComponentHandle + 'static> {
    pub weak: slint::Weak<T>,
    pub engine: std::sync::Arc<dyn slate_agent::traits::AutomationEngine>,
    pub bridge: std::sync::Arc<slate_agent::bridge::SlintUiBridge>,
}
impl<T: slint::ComponentHandle + 'static> Fixture<T> {
    pub async fn create(make: fn() -> T) -> Result<Self, String>;
    /// Runs `f` on the UI thread with the live component (for asserting real properties).
    pub async fn with_ui<R: Send + 'static>(&self, f: impl FnOnce(&T) -> R + Send + 'static) -> Result<R, String>;
    pub async fn close(self) -> Result<(), String>;
}
```

If spike A2 shows this exact shape cannot work, WP-01 **stops**, documents the working
alternative in its report, and the orchestrator updates this section before any other WP uses it.

---

## 9. File ownership matrix (prevents parallel edit conflicts)

A WP may edit only the files it owns. Changes anywhere else need orchestrator approval.

| WP | Owns (create/modify/delete) |
|---|---|
| WP-00 | `slate-rust/Cargo.toml`, `slate-rust/*/Cargo.toml` (dependency lines only), `.agents/plans/.../reviews/WP-00-dependency-review.md` |
| WP-01 | `slate-rust/agent/tests/support/**`, `slate-rust/agent/tests/harness_spike_tests.rs`, `[[test]]` entries in `slate-rust/agent/Cargo.toml` |
| WP-02 | `agent/src/semantic/{mod,types,roles}.rs`, `agent/src/error.rs`, `agent/src/lib.rs` (semantic re-exports), `agent/tests/semantic_types_tests.rs` |
| WP-03 | `agent/src/semantic/{tree,refs,snapshot}.rs`, `agent/tests/semantic_snapshot_tests.rs` (+ `[[test]]` entry) |
| WP-04 | `agent/src/semantic/{resolve,execute}.rs`, `agent/tests/semantic_actions_tests.rs` (+ `[[test]]`) |
| WP-05 | `agent/src/{traits,engine,builder,slint_backend}.rs`, `lib/src/agent.rs`, `agent/tests/builder_tests.rs` |
| WP-06 | `slate-rust/lib/tests/component_contract_tests.rs`, `slate-rust/lib/tests/fixtures/contract_window.slint`, `[[test]]` in `lib/Cargo.toml` |
| WP-07a | `ui/layouts/{navigation_split_view,collapsible,resizable_panel_group}.slint` |
| WP-07b | `ui/components/{action_row,card,alert_dialog,popover,sheet,table,tooltip,slider,textarea}.slint` |
| WP-08 | `ui/components/agent_action.slint`, `ui/index.slint` (one export line), `slate-rust/lib/build.rs` ENTRY only if required, `agent/tests/agent_action_tests.rs` |
| WP-09 | `agent/src/actions/**`, `agent/src/semantic/discovery.rs`, `agent/src/builder.rs` (`with_action` only — coordinate with WP-05: WP-09 starts after WP-05 is merged), `agent/tests/action_registry_tests.rs` |
| WP-10 | `mcp/src/tools/**` except `capabilities.rs`, `mcp/src/schema.rs` (generic tools), `mcp/tests/ui_tools_tests.rs` |
| WP-11 | `mcp/src/server.rs`, `mcp/src/tools/capabilities.rs`, `mcp/src/schema.rs` (annotations/outputSchema), `mcp/src/transport/{mod,stdio,in_memory}.rs`, `mcp/tests/dynamic_tools_tests.rs` |
| WP-12 | `mcp/src/bin/slate_mcp.rs`, `mcp/src/client.rs`, `mcp/tests/cli_tests.rs` |
| WP-13 | `mcp/src/transport/socket.rs`, `mcp/src/adapter.rs`, `mcp/tests/socket_transport_tests.rs` |
| WP-14 | `slate-carbon/examples/gallery/main.carbon`, `slate-rust/examples/showcase/src/{main,lib}.rs` (logging/stdout lines only), `slate-rust/test/tests/stdout_hygiene.rs` |
| WP-15 | `agent/src/{engine,traits,slint_backend,lib}.rs` (deletions), the 10 test files that used `Default*` mocks, `lib/src/agent.rs` (re-export cleanup) |
| WP-16 | `slate-rust/test/**` |
| WP-17 | `slate-rust/examples/showcase/**` (except lines owned by WP-14), `slate-rust/examples/showcase/ui/**` |
| WP-18 | `.agents/skills/slate-agent-control/**`, `README.md`, `CLAUDE.md`, `slate-rust/**/README.md` |

---

## Changelog

| Date | Section | Change | Reason | Affected WPs |
|---|---|---|---|---|
| 2026-10-11 | all | initial version (contracts v1) | handover preparation | all |
