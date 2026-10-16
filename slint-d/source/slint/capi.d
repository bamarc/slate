/// Raw `extern(C)` declarations for the Rust bridge (`bridge/`).
///
/// This is the D half of the FFI boundary. The Rust half implements these
/// symbols in `bridge/src/lib.rs` on top of `slint-interpreter` (and
/// `i-slint-core` for timers), playing the same role as `api/node/rust/*`
/// (napi) and `api/python/slint/*.rs` (pyo3) do for their languages.
///
/// ABI conventions (kept deliberately C-simple, as with Slint's own C++
/// API in `api/cpp`):
/// - Opaque heap objects cross as pointers; ownership transfers to the
///   caller and is released with the matching `_free` function.
/// - Strings cross as NUL-terminated UTF-8. Borrowed strings (returned
///   getters) are valid until the owning object is freed or the next
///   bridge call on the same thread. Owned out-strings must be released
///   with `slint_string_free` (D callers: `scope(exit)`).
/// - Errors surface as a nullable NUL-terminated message: null means
///   success. Owned; release with `slint_string_free`.
/// - `SlintValue` is the dynamically-typed callback/invoke payload. Strings
///   in it are `(pointer, length)` pairs, not NUL-terminated: `owned == 0`
///   borrows (valid for the duration of the call; copy with `idup`), while
///   `owned == 1` transfers ownership to the receiver, which must release
///   the pointer with `slint_string_free`.
/// - All functions are thread-hostile like the interpreter itself: call
///   them from the thread running the Slint event loop.
module slint.capi;

/// Tag discriminant for `SlintValue`. Ordinals intentionally match
/// `slint.value.ValueType` (Void..Image) so the bridge maps 1:1.
enum SlintTag : int
{
    Void = 0,
    Number = 1,
    String = 2,
    Bool = 3,
    Model = 4,
    Struct = 5,
    Brush = 6,
    Image = 7,
    Enumeration = 8,
}

/// Dynamically-typed value crossing the FFI boundary (callback arguments,
/// callback returns, variadic invoke, property read/write).
struct SlintValue
{
    SlintTag tag = SlintTag.Void;
    double number = 0;
    const(char)* textPtr = null;
    size_t textLen = 0;
    int boolean = 0;
    uint colorArgb = 0;
    int brushKind = 0;
    void* handle = null;
    int owned = 0;

    static SlintValue voidValue() @safe pure nothrow @nogc
    {
        SlintValue r;
        r.tag = SlintTag.Void;
        return r;
    }

    static SlintValue ofNumber(double v) @safe pure nothrow @nogc
    {
        SlintValue r;
        r.tag = SlintTag.Number;
        r.number = v;
        return r;
    }
}

/// D-side callback entry point, invoked by the bridge. Registered once per
/// process: D passes `&slintDCallbackShim` (see `slint.callback`) with each
/// handler registration, so no dynamic symbol export is required.
alias SlintShim = extern (C) SlintValue function(size_t id, const(SlintValue)* args, size_t nargs);

extern (C):

/// Opaque compiler. See `slint.compiler.Compiler`.
struct SlintCompiler;

/// Opaque compilation result. See `slint.compiler.CompilationResult`.
struct SlintResult;

/// Opaque component definition. See `slint.definition.ComponentDefinition`.
struct SlintDefinition;

/// Opaque component instance. See `slint.instance.ComponentInstance`.
struct SlintInstance;

/// Opaque timer. See `slint.timer.Timer`.
struct SlintTimer;

/// Opaque struct handle. Wraps `slint_interpreter::Struct`.
struct SlintStructRaw;

/// Opaque model handle. Wraps `i_slint_core::model::ModelRc<slint_interpreter::Value>`.
struct SlintModelRaw;

// -- compiler -----------------------------------------------------------

SlintCompiler* slint_compiler_new();
void slint_compiler_free(SlintCompiler* compiler);

void slint_compiler_set_style(SlintCompiler* compiler, const char* style);
void slint_compiler_add_include_path(SlintCompiler* compiler, const char* path);
void slint_compiler_set_library_path(SlintCompiler* compiler, const char* name, const char* path);
void slint_compiler_set_translation_domain(SlintCompiler* compiler, const char* domain);

/// Compile `.slint` markup from memory. On success `*outResult` is set and
/// the return is null; on failure the return is an owned error string.
char* slint_compiler_build_from_source(SlintCompiler* compiler,
        const char* source, const char* path, SlintResult** outResult);

/// Compile a `.slint` file from disk. Same ownership rules as above.
char* slint_compiler_build_from_path(SlintCompiler* compiler, const char* path,
        SlintResult** outResult);

// -- compilation result -------------------------------------------------

void slint_result_free(SlintResult* result);
size_t slint_result_diagnostic_count(const SlintResult* result);
int slint_result_diagnostic_level(const SlintResult* result, size_t index);
const(char)* slint_result_diagnostic_message(const SlintResult* result, size_t index);
size_t slint_result_diagnostic_line(const SlintResult* result, size_t index);
size_t slint_result_diagnostic_column(const SlintResult* result, size_t index);
size_t slint_result_component_count(const SlintResult* result);
const(char)* slint_result_component_name(const SlintResult* result, size_t index);
SlintDefinition* slint_result_component_get(SlintResult* result, const char* name);

// -- component definition -----------------------------------------------

void slint_definition_free(SlintDefinition* definition);

/// Owned out-string with the exported component name.
char* slint_definition_get_name(SlintDefinition* definition, char** outName);

size_t slint_definition_property_count(SlintDefinition* definition);
char* slint_definition_property_name(SlintDefinition* definition, size_t index, char** outName);
int slint_definition_property_type(SlintDefinition* definition, size_t index);

size_t slint_definition_callback_count(SlintDefinition* definition);
char* slint_definition_callback_name(SlintDefinition* definition, size_t index, char** outName);

size_t slint_definition_function_count(SlintDefinition* definition);
char* slint_definition_function_name(SlintDefinition* definition, size_t index, char** outName);

size_t slint_definition_global_count(SlintDefinition* definition);
char* slint_definition_global_name(SlintDefinition* definition, size_t index, char** outName);

size_t slint_definition_global_property_count(SlintDefinition* definition, const char* global);
char* slint_definition_global_property_name(SlintDefinition* definition,
        const char* global, size_t index, char** outName);
int slint_definition_global_property_type(SlintDefinition* definition,
        const char* global, size_t index);

size_t slint_definition_global_callback_count(SlintDefinition* definition, const char* global);
char* slint_definition_global_callback_name(SlintDefinition* definition,
        const char* global, size_t index, char** outName);

size_t slint_definition_global_function_count(SlintDefinition* definition, const char* global);
char* slint_definition_global_function_name(SlintDefinition* definition,
        const char* global, size_t index, char** outName);

SlintInstance* slint_definition_create(SlintDefinition* definition);

// -- component instance -------------------------------------------------

void slint_instance_free(SlintInstance* instance);

/// Returns null on success, else an owned error string.
char* slint_instance_set_number(SlintInstance* instance, const char* name, double value);
char* slint_instance_set_string(SlintInstance* instance, const char* name, const char* value);
char* slint_instance_set_bool(SlintInstance* instance, const char* name, int value);

char* slint_instance_get_number(SlintInstance* instance, const char* name, double* outValue);
char* slint_instance_get_string(SlintInstance* instance, const char* name, char** outValue);
char* slint_instance_get_bool(SlintInstance* instance, const char* name, int* outValue);

char* slint_instance_get_property(SlintInstance* instance, const char* name, SlintValue* outValue);
char* slint_instance_set_property(SlintInstance* instance, const char* name,
        const SlintValue* value);

/// Invoke a callback with no arguments. Variadic invoke is a later phase.
char* slint_instance_invoke(SlintInstance* instance, const char* name);

/// Invoke a callback with `SlintValue` arguments; the return payload is
/// written to `outReturn` (string payloads owned; see `SlintValue`).
char* slint_instance_invoke_values(SlintInstance* instance, const char* name,
        const SlintValue* args, size_t nargs, SlintValue* outReturn);

/// Register a D callback handler. `shim` is invoked as
/// `shim(ctx, args, nargs)`; `ctx` is the `slint.callback` registry id.
/// Re-registering a name replaces the previous handler.
char* slint_instance_set_callback(SlintInstance* instance, const char* name,
        SlintShim shim, size_t ctx);

char* slint_instance_get_global_number(SlintInstance* instance,
        const char* global, const char* name, double* outValue);
char* slint_instance_set_global_number(SlintInstance* instance,
        const char* global, const char* name, double value);
char* slint_instance_get_global_string(SlintInstance* instance,
        const char* global, const char* name, char** outValue);
char* slint_instance_set_global_string(SlintInstance* instance,
        const char* global, const char* name, const char* value);
char* slint_instance_get_global_bool(SlintInstance* instance,
        const char* global, const char* name, int* outValue);
char* slint_instance_set_global_bool(SlintInstance* instance,
        const char* global, const char* name, int value);
char* slint_instance_invoke_global(SlintInstance* instance, const char* global,
        const char* name, const SlintValue* args, size_t nargs, SlintValue* outReturn);
char* slint_instance_set_global_callback(SlintInstance* instance,
        const char* global, const char* name, SlintShim shim, size_t ctx);

void slint_instance_show(SlintInstance* instance);
void slint_instance_hide(SlintInstance* instance);
/// Shows the window and spins the event loop until `quit_event_loop`.
char* slint_instance_run(SlintInstance* instance);

/// Offscreen snapshot (Slate screenshot-tool technique): RGBA8 pixels of
/// the current window content. No display or event loop required (use the
/// software backend headless). `*outPixels` is owned (`*outLen` bytes);
/// release with `slint_bytes_free`.
char* slint_instance_snapshot(SlintInstance* instance, ubyte** outPixels,
        size_t* outLen, uint* outWidth, uint* outHeight);
void slint_bytes_free(ubyte* ptr, size_t len);

// -- timers -------------------------------------------------------------

SlintTimer* slint_timer_new();
void slint_timer_free(SlintTimer* timer);

/// Arm the timer; `shim(ctx, null, 0)` fires on the event-loop thread.
/// `singleShot != 0` fires once, otherwise repeatedly.
char* slint_timer_start(SlintTimer* timer, int singleShot, ulong intervalMs,
        SlintShim shim, size_t ctx);
void slint_timer_stop(SlintTimer* timer);

// -- event loop ---------------------------------------------------------

char* slint_run_event_loop();
char* slint_quit_event_loop();

/// Queue a D delegate for the event-loop thread (one-shot or persistent
/// per the registry entry behind `ctx`).
char* slint_invoke_from_event_loop(SlintShim shim, size_t ctx);

char* slint_set_xdg_app_id(const char* appId);

// -- struct -------------------------------------------------------------

SlintStructRaw* slint_struct_new();
void slint_struct_free(SlintStructRaw* s);
char* slint_struct_set_field(SlintStructRaw* s, const char* name, const SlintValue* value);
char* slint_struct_get_field(SlintStructRaw* s, const char* name, SlintValue* outValue);
size_t slint_struct_field_count(SlintStructRaw* s);
char* slint_struct_field_name(SlintStructRaw* s, size_t index, char** outName);

// -- model --------------------------------------------------------------

SlintModelRaw* slint_model_new_vec();
void slint_model_free(SlintModelRaw* model);
size_t slint_model_row_count(SlintModelRaw* model);
char* slint_model_row_data(SlintModelRaw* model, size_t row, SlintValue* outValue);
char* slint_model_set_row_data(SlintModelRaw* model, size_t row, const SlintValue* value);
char* slint_model_vec_push(SlintModelRaw* model, const SlintValue* value);
char* slint_model_vec_remove(SlintModelRaw* model, size_t index);
char* slint_model_vec_clear(SlintModelRaw* model);

// -- window controls & event dispatching -------------------------------

char* slint_window_get_size(SlintInstance* instance, double* outWidth, double* outHeight);
char* slint_window_set_size(SlintInstance* instance, double width, double height);
char* slint_window_is_visible(SlintInstance* instance, int* outVisible);
char* slint_window_dispatch_pointer(SlintInstance* instance, int eventType,
        double x, double y, int button);
char* slint_window_dispatch_key(SlintInstance* instance, int eventType, const char* text);

// -- element & accessibility introspection -----------------------------

char* slint_instance_dump_ui_tree(SlintInstance* instance, char** outJson);
char* slint_instance_find_element(SlintInstance* instance, const char* target,
        char** outId, char** outRole, char** outLabel, char** outValue,
        double* outX, double* outY, double* outWidth, double* outHeight,
        int* outEnabled, int* outVisible);
char* slint_instance_invoke_element_action(SlintInstance* instance, const char* target);
char* slint_instance_invoke_element_accessibility_action(SlintInstance* instance,
        const char* target, int actionKind, const char* valueStr);

// -- strings ------------------------------------------------------------

void slint_string_free(char* s);

/// Release an owned string payload inside a `SlintValue` (no-op unless
/// `owned != 0`). D callers pair this with `scope(exit)`.
void slint_value_free(SlintValue* value);
