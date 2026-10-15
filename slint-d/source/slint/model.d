/// List models feeding dynamic array data into `.slint` views.
///
/// Mirrors the `Model<T>` abstraction both official bindings expose:
/// Node's `Model<T>` / `ArrayModel<T>` in `api/node/typescript/models.ts`
/// (backed by `api/node/rust/types/model.rs`) and Python's `Model` /
/// `ListModel` in `api/python/slint/models.rs` (+ `FilterModel`,
/// `SortModel`, `MapModel`, `ReverseModel` adapters).
///
/// A model is a table of rows. Views subscribe through `ModelNotify`;
/// mutating through the model (not on a detached copy) updates the UI.
/// Native hand-off (`ModelRc<Value>`) is a later bridge phase; this module
/// is pure D so `dub test` stays runtime-free.
module slint.model;

/// Observer notifications a view subscribes to. Mirrors
/// `i_slint_core::model::ModelNotify` as seen by binding authors.
final class ModelNotify
{
    private void delegate(size_t row) @safe[] _rowChanged;
    private void delegate(size_t row, size_t count) @safe[] _rowsAdded;
    private void delegate(size_t row, size_t count) @safe[] _rowsRemoved;
    private void delegate() @safe[] _modelReset;

    void onRowChanged(void delegate(size_t row) @safe cb) @safe pure nothrow
    {
        _rowChanged ~= cb;
    }

    void onRowsAdded(void delegate(size_t row, size_t count) @safe cb) @safe pure nothrow
    {
        _rowsAdded ~= cb;
    }

    void onRowsRemoved(void delegate(size_t row, size_t count) @safe cb) @safe pure nothrow
    {
        _rowsRemoved ~= cb;
    }

    void onModelReset(void delegate() @safe cb) @safe pure nothrow
    {
        _modelReset ~= cb;
    }

    void notifyRowChanged(size_t row) @safe nothrow
    {
        foreach (cb; _rowChanged)
            try
                cb(row);
            catch (Exception)
            {
            }
    }

    void notifyRowsAdded(size_t row, size_t count) @safe nothrow
    {
        foreach (cb; _rowsAdded)
            try
                cb(row, count);
            catch (Exception)
            {
            }
    }

    void notifyRowsRemoved(size_t row, size_t count) @safe nothrow
    {
        foreach (cb; _rowsRemoved)
            try
                cb(row, count);
            catch (Exception)
            {
            }
    }

    void notifyReset() @safe nothrow
    {
        foreach (cb; _modelReset)
            try
                cb();
            catch (Exception)
            {
            }
    }
}

/// Read/write row-oriented data source for Slint array properties.
/// (Node: `abstract class Model<T>`; Python: `class Model`.)
/// All operations are `@safe` so views compose inside safe UI code.
interface Model(T)
{
    size_t rowCount() @safe;
    T rowData(size_t row) @safe;
    void setRowData(size_t row, T data) @safe;
    ModelNotify notify() @safe;
}

/// Array-backed model with `push`/`remove`, mirroring Node's `ArrayModel`
/// and Python's `ListModel`.
version (SlintNative)
{
    import slint.capi : SlintModelRaw, SlintValue, SlintTag;
    import slint.value : Color, Brush, SlintStruct, Value, toSlintValue, fromSlintValue,
        toSlintStruct, fromSlintStruct;

    private T convertFromSlint(T)(const SlintValue outVal) @trusted
    {
        static if (is(T == int))
            return cast(int) outVal.number;
        else static if (is(T == double))
            return outVal.number;
        else static if (is(T == float))
            return cast(float) outVal.number;
        else static if (is(T == long))
            return cast(long) outVal.number;
        else static if (is(T == uint))
            return cast(uint) outVal.number;
        else static if (is(T == ulong))
            return cast(ulong) outVal.number;
        else static if (is(T == string))
        {
            if (outVal.textPtr !is null && outVal.textLen > 0)
                return outVal.textPtr[0 .. outVal.textLen].idup;
            return "";
        }
        else static if (is(T == bool))
            return outVal.boolean != 0;
        else static if (is(T == Color))
            return Color.fromArgbU32(outVal.colorArgb);
        else static if (is(T == Brush))
        {
            if (outVal.brushKind == 0)
                return Brush.transparent();
            return Brush.solid(Color.fromArgbU32(outVal.colorArgb));
        }
        else static if (is(T == SlintStruct))
        {
            auto v = fromSlintValue(outVal);
            return v.structFields;
        }
        else static if (is(T == Value))
            return fromSlintValue(outVal);
        else static if (is(T == struct))
        {
            auto v = fromSlintValue(outVal);
            return fromSlintStruct!T(v.structFields);
        }
        else
            static assert(false, "Unsupported model element type: " ~ T.stringof);
    }

    private SlintValue convertToSlint(T)(T val) @trusted
    {
        SlintValue itemVal;
        static if (is(T == int) || is(T == double) || is(T == float) || is(T == long)
            || is(T == uint) || is(T == ulong))
        {
            itemVal.tag = SlintTag.Number;
            itemVal.number = cast(double) val;
        }
        else static if (is(T == string))
        {
            itemVal.tag = SlintTag.String;
            itemVal.textPtr = val.ptr;
            itemVal.textLen = val.length;
        }
        else static if (is(T == bool))
        {
            itemVal.tag = SlintTag.Bool;
            itemVal.boolean = val ? 1 : 0;
        }
        else static if (is(T == Color) || is(T == Brush) || is(T == SlintStruct) || is(T == Value))
        {
            itemVal = toSlintValue(val);
        }
        else static if (is(T == struct))
        {
            itemVal = toSlintValue(toSlintStruct(val));
        }
        else
            static assert(false, "Unsupported model element type: " ~ T.stringof);
        return itemVal;
    }
}

/// Array-backed model with `push`/`remove`, mirroring Node's `ArrayModel`
/// and Python's `ListModel`.
class ArrayModel(T) : Model!T
{
    private T[] _rows;
    private ModelNotify _notify;

    version (SlintNative)
    {
        private SlintModelRaw* _nativeHandle;
        private bool _ownedHandle;

        this(SlintModelRaw* handle, bool owned = true) @safe pure nothrow
        {
            _nativeHandle = handle;
            _ownedHandle = owned;
            _notify = new ModelNotify();
        }

        ~this() @trusted
        {
            if (_nativeHandle !is null && _ownedHandle)
            {
                import slint.capi : slint_model_free;

                slint_model_free(_nativeHandle);
                _nativeHandle = null;
            }
        }

        SlintModelRaw* nativeHandle() @safe pure nothrow @nogc
        {
            return _nativeHandle;
        }

        private size_t nativeRowCount() const @trusted
        {
            import slint.capi : slint_model_row_count;

            return slint_model_row_count(cast(SlintModelRaw*) _nativeHandle);
        }

        private T nativeRowData(size_t row) const @trusted
        {
            import slint.capi : slint_model_row_data, slint_string_free, SlintValue;
            import slint.value : freeSlint;
            import std.string : fromStringz;

            SlintValue outVal;
            char* err = slint_model_row_data(cast(SlintModelRaw*) _nativeHandle, row, &outVal);
            if (err !is null)
            {
                string msg;
                try
                    msg = fromStringz(err).idup;
                catch (Throwable)
                {
                }
                slint_string_free(err);
                throw new Exception(msg.length ? msg : "row index out of range");
            }
            scope (exit)
                freeSlint(&outVal);
            return convertFromSlint!T(outVal);
        }

        private void nativeSetRowData(size_t row, T data) @trusted
        {
            import slint.capi : slint_model_set_row_data, slint_string_free, SlintValue;
            import slint.value : freeSlint;
            import std.string : fromStringz;

            SlintValue sv = convertToSlint(data);
            scope (exit)
                freeSlint(&sv);
            char* err = slint_model_set_row_data(_nativeHandle, row, &sv);
            if (err !is null)
            {
                string msg;
                try
                    msg = fromStringz(err).idup;
                catch (Throwable)
                {
                }
                slint_string_free(err);
                throw new Exception(msg.length ? msg : "failed to set row data");
            }
        }

        private void nativePush(T val) @trusted
        {
            import slint.capi : slint_model_vec_push, slint_string_free, SlintValue;
            import slint.value : freeSlint;
            import std.string : fromStringz;

            SlintValue sv = convertToSlint(val);
            scope (exit)
                freeSlint(&sv);
            char* err = slint_model_vec_push(_nativeHandle, &sv);
            if (err !is null)
            {
                string msg;
                try
                    msg = fromStringz(err).idup;
                catch (Throwable)
                {
                }
                slint_string_free(err);
                throw new Exception(msg.length ? msg : "failed to push row");
            }
        }

        private void nativeRemove(size_t index) @trusted
        {
            import slint.capi : slint_model_vec_remove, slint_string_free;
            import std.string : fromStringz;

            char* err = slint_model_vec_remove(_nativeHandle, index);
            if (err !is null)
            {
                string msg;
                try
                    msg = fromStringz(err).idup;
                catch (Throwable)
                {
                }
                slint_string_free(err);
                throw new Exception(msg.length ? msg : "failed to remove row");
            }
        }

        private void nativeClear() @trusted
        {
            import slint.capi : slint_model_vec_clear, slint_string_free;
            import std.string : fromStringz;

            char* err = slint_model_vec_clear(_nativeHandle);
            if (err !is null)
            {
                string msg;
                try
                    msg = fromStringz(err).idup;
                catch (Throwable)
                {
                }
                slint_string_free(err);
                throw new Exception(msg.length ? msg : "failed to clear model");
            }
        }
    }

    this(T[] initial = []) @safe
    {
        _notify = new ModelNotify();
        version (SlintNative)
        {
            import slint.capi : slint_model_new_vec;

            _nativeHandle = () @trusted { return slint_model_new_vec(); }();
            _ownedHandle = true;
            foreach (ref v; initial)
                push(v);
        }
        else
        {
            _rows = initial.dup;
        }
    }

    size_t rowCount() const @safe
    {
        version (SlintNative)
        {
            if (_nativeHandle !is null)
                return nativeRowCount();
        }
        return _rows.length;
    }

    T rowData(size_t row) const @safe
    {
        version (SlintNative)
        {
            if (_nativeHandle !is null)
                return nativeRowData(row);
        }
        if (row >= _rows.length)
            throw new Exception("row index out of range");
        return _rows[row];
    }

    void setRowData(size_t row, T data) @safe
    {
        version (SlintNative)
        {
            if (_nativeHandle !is null)
            {
                nativeSetRowData(row, data);
                _notify.notifyRowChanged(row);
                return;
            }
        }
        if (row >= _rows.length)
            throw new Exception("row index out of range");
        _rows[row] = data;
        _notify.notifyRowChanged(row);
    }

    /// Append rows and notify views. (Node: `push`, Python: `append`.)
    void push(T[] values...) @safe
    {
        auto at = rowCount();
        version (SlintNative)
        {
            if (_nativeHandle !is null)
            {
                foreach (ref v; values)
                    nativePush(v);
                _notify.notifyRowsAdded(at, values.length);
                return;
            }
        }
        _rows ~= values;
        _notify.notifyRowsAdded(at, values.length);
    }

    /// Remove `count` rows at `index` and notify views.
    void remove(size_t index, size_t count = 1) @safe
    {
        auto n = rowCount();
        if (index + count > n)
            throw new Exception("row index out of range");
        version (SlintNative)
        {
            if (_nativeHandle !is null)
            {
                foreach (_; 0 .. count)
                    nativeRemove(index);
                _notify.notifyRowsRemoved(index, count);
                return;
            }
        }
        _rows = _rows[0 .. index] ~ _rows[index + count .. $];
        _notify.notifyRowsRemoved(index, count);
    }

    /// Remove all rows and notify views.
    void clear() @safe
    {
        version (SlintNative)
        {
            if (_nativeHandle !is null)
            {
                nativeClear();
                _notify.notifyReset();
                return;
            }
        }
        _rows.length = 0;
        _notify.notifyReset();
    }

    /// Index operator: `m[i]`
    T opIndex(size_t row) const @safe
    {
        return rowData(row);
    }

    /// Index assign operator: `m[i] = val`
    void opIndexAssign(T value, size_t row) @safe
    {
        setRowData(row, value);
    }

    /// Set row data convenience method: `m.set(i, val)`
    void set(size_t row, T value) @safe
    {
        setRowData(row, value);
    }

    /// Number of rows. (Node: `length` getter.)
    size_t length() const @safe
    {
        version (SlintNative)
        {
            if (_nativeHandle !is null)
                return nativeRowCount();
        }
        return _rows.length;
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }

    int opApply(scope int delegate(T) dg) const
    {
        int result;
        size_t n = rowCount();
        foreach (i; 0 .. n)
        {
            result = dg(rowData(i));
            if (result)
                break;
        }
        return result;
    }

    int opApply(scope int delegate(ref T) dg)
    {
        int result;
        size_t n = rowCount();
        foreach (i; 0 .. n)
        {
            T v = rowData(i);
            T orig = v;
            result = dg(v);
            if (v != orig)
                setRowData(i, v);
            if (result)
                break;
        }
        return result;
    }

    static struct Range
    {
        private ArrayModel!T _model;
        private size_t _index;

        bool empty() const @safe
        {
            return _index >= _model.rowCount();
        }

        T front() @safe
        {
            return _model.rowData(_index);
        }

        void popFront() @safe
        {
            ++_index;
        }

        Range save() @safe
        {
            return this;
        }

        size_t length() const @safe
        {
            return _model.rowCount() - _index;
        }

        T opIndex(size_t i) @safe
        {
            return _model.rowData(_index + i);
        }
    }

    Range opSlice() @safe
    {
        return Range(this, 0);
    }
}

/// Read-only view mapping each row of a source model through `fn`.
/// (Python: `MapModel`.) Structural changes in the source surface as a
/// reset; per-row edits forward as row changes.
class MapModel(S, T) : Model!T
{
    private Model!S _source;
    private T delegate(S) @safe _fn;
    private ModelNotify _notify;

    this(Model!S source, T delegate(S) @safe fn) @safe
    {
        _source = source;
        _fn = fn;
        _notify = new ModelNotify();
        _source.notify().onRowChanged((r) { _notify.notifyRowChanged(r); });
        _source.notify().onRowsAdded((r, c) { _notify.notifyReset(); });
        _source.notify().onRowsRemoved((r, c) { _notify.notifyReset(); });
        _source.notify().onModelReset(() { _notify.notifyReset(); });
    }

    size_t rowCount() @safe
    {
        return _source.rowCount();
    }

    T rowData(size_t row) @safe
    {
        return _fn(_source.rowData(row));
    }

    void setRowData(size_t row, T data) @safe
    {
        throw new Exception("MapModel is read-only");
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }
}

/// Read-only view exposing only rows matching `pred`, with a cached index
/// rebuilt whenever the source signals (adapter invalidation is the one
/// place eager work beats laziness). (Python: `FilterModel`.)
class FilterModel(T) : Model!T
{
    private Model!T _source;
    private bool delegate(T) @safe _pred;
    private size_t[] _index;
    private ModelNotify _notify;

    this(Model!T source, bool delegate(T) @safe pred) @safe
    {
        _source = source;
        _pred = pred;
        _notify = new ModelNotify();
        rebuild();
        _source.notify().onRowChanged((r) { rebuild(); _notify.notifyReset(); });
        _source.notify().onRowsAdded((r, c) { rebuild(); _notify.notifyReset(); });
        _source.notify().onRowsRemoved((r, c) { rebuild(); _notify.notifyReset(); });
        _source.notify().onModelReset(() { rebuild(); _notify.notifyReset(); });
    }

    private void rebuild() @safe
    {
        _index.length = 0;
        foreach (i; 0 .. _source.rowCount())
            if (_pred(_source.rowData(i)))
                _index ~= i;
    }

    size_t rowCount() @safe pure nothrow
    {
        return _index.length;
    }

    T rowData(size_t row) @safe
    {
        if (row >= _index.length)
            throw new Exception("row index out of range");
        return _source.rowData(_index[row]);
    }

    void setRowData(size_t row, T data) @safe
    {
        if (row >= _index.length)
            throw new Exception("row index out of range");
        _source.setRowData(_index[row], data);
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }
}

/// Read-only view presenting source rows in sorted order (index cache,
/// same invalidation policy as `FilterModel`). (Python: `SortModel`.)
class SortedModel(T) : Model!T
{
    private Model!T _source;
    private bool delegate(T, T) @safe _less;
    private size_t[] _index;
    private ModelNotify _notify;

    this(Model!T source, bool delegate(T, T) @safe less) @safe
    {
        _source = source;
        _less = less;
        _notify = new ModelNotify();
        rebuild();
        _source.notify().onRowChanged((r) { rebuild(); _notify.notifyReset(); });
        _source.notify().onRowsAdded((r, c) { rebuild(); _notify.notifyReset(); });
        _source.notify().onRowsRemoved((r, c) { rebuild(); _notify.notifyReset(); });
        _source.notify().onModelReset(() { rebuild(); _notify.notifyReset(); });
    }

    private void rebuild() @safe
    {
        import std.algorithm : sort;

        _index.length = _source.rowCount();
        foreach (i, ref slot; _index)
            slot = i;
        sort!((a, b) => _less(_source.rowData(a), _source.rowData(b)))(_index);
    }

    size_t rowCount() @safe pure nothrow
    {
        return _index.length;
    }

    T rowData(size_t row) @safe
    {
        if (row >= _index.length)
            throw new Exception("row index out of range");
        return _source.rowData(_index[row]);
    }

    void setRowData(size_t row, T data) @safe
    {
        if (row >= _index.length)
            throw new Exception("row index out of range");
        _source.setRowData(_index[row], data);
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }
}

/// Live reversed view: index mapping is computed, never cached, so it
/// tracks the source with zero invalidation bookkeeping.
/// (Python: `ReverseModel`.)
class ReverseModel(T) : Model!T
{
    private Model!T _source;
    private ModelNotify _notify;

    this(Model!T source) @safe
    {
        _source = source;
        _notify = new ModelNotify();
        _source.notify().onRowChanged((r) { _notify.notifyRowChanged(flip(r)); });
        _source.notify().onModelReset(() { _notify.notifyReset(); });
        _source.notify().onRowsAdded((r, c) { _notify.notifyReset(); });
        _source.notify().onRowsRemoved((r, c) { _notify.notifyReset(); });
    }

    private size_t flip(size_t row) @safe
    {
        auto n = _source.rowCount();
        return n == 0 ? 0 : n - 1 - row;
    }

    size_t rowCount() @safe
    {
        return _source.rowCount();
    }

    T rowData(size_t row) @safe
    {
        auto n = _source.rowCount();
        if (row >= n)
            throw new Exception("row index out of range");
        return _source.rowData(n - 1 - row);
    }

    void setRowData(size_t row, T data) @safe
    {
        auto n = _source.rowCount();
        if (row >= n)
            throw new Exception("row index out of range");
        _source.setRowData(n - 1 - row, data);
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }
}

/// Pull-based model fed by a fiber: the producer calls `emit` per value and
/// rows materialize on demand as views read them. The producer must be
/// finite — `rowCount` pumps it to completion. Ideal for expensive or lazy
/// sources (directory scans, paged queries) that should not block UI setup.
class GeneratorModel(T) : Model!T
{
    private T[] _cache;
    private Fiber _fiber;
    private bool _exhausted;
    private Throwable _error;
    private ModelNotify _notify;

    /// The producer fiber never escapes this object, so the fiber-based
    /// pumping below is `@trusted` rather than `@safe`.
    this(void delegate(void delegate(T) emit) producer) @trusted
    {
        _notify = new ModelNotify();
        _fiber = new Fiber(() { producer(&emit); });
    }

    private void emit(T value)
    {
        _cache ~= value;
        Fiber.yield();
    }

    private void pump(size_t need)
    {
        while (_cache.length <= need && !_exhausted && _error is null)
        {
            try
            {
                _fiber.call();
            }
            catch (Throwable t)
            {
                _error = t;
                break;
            }
            if (_fiber.state == Fiber.State.TERM)
                _exhausted = true;
        }
        if (_error !is null)
            throw new Exception("generator failed: " ~ _error.msg);
    }

    /// Total rows (pumps the producer to completion).
    size_t rowCount() @trusted
    {
        pump(size_t.max - 1);
        return _cache.length;
    }

    /// Rows produced so far, without pumping further.
    size_t produced() const @safe pure nothrow
    {
        return _cache.length;
    }

    T rowData(size_t row) @trusted
    {
        pump(row);
        if (row >= _cache.length)
            throw new Exception("row index out of range");
        return _cache[row];
    }

    void setRowData(size_t row, T data) @safe
    {
        throw new Exception("GeneratorModel is read-only");
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }
}

private import core.thread.fiber : Fiber;

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
    import std.algorithm : isSorted;

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
    import std.exception : assertThrown;

    assertThrown(gen.rowData(5));

    auto failing = new GeneratorModel!int((void delegate(int) emit) {
        emit(1);
        throw new Exception("source died");
    });
    assert(failing.rowData(0) == 1);
    assertThrown(failing.rowCount());
}

private import std.conv : to;

// Best practice: ArrayModel row mutation, notification callbacks, and iteration
/// Example:
unittest
{
    auto m = new ArrayModel!int([1, 2, 3]);
    assert(m.rowCount() == 3);
    assert(m.rowData(0) == 1);
    size_t changed = size_t.max, addedAt, addedCount, removedAt, removedCount;
    m.notify().onRowChanged((r) { changed = r; });
    m.notify().onRowsAdded((r, c) { addedAt = r; addedCount = c; });
    m.notify().onRowsRemoved((r, c) { removedAt = r; removedCount = c; });

    m.setRowData(1, 20);
    assert(m.rowData(1) == 20 && changed == 1);

    m.push(4, 5);
    assert(m.length == 5 && addedAt == 3 && addedCount == 2);

    m.remove(0);
    assert(m.rowData(0) == 20 && removedAt == 0 && removedCount == 1);

    int sum;
    foreach (ref v; m)
        sum += v;
    assert(sum == 20 + 3 + 4 + 5);

    import std.exception : assertThrown;

    assertThrown(m.rowData(99));
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
    import std.range.primitives : isInputRange, isForwardRange;

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

/// Hierarchical tree node storing payload `T` and arbitrary nested children.
final class TreeNode(T)
{
    string id;
    T data;
    bool expanded;
    TreeNode!T[] children;

    this(string id, T data, TreeNode!T[] children = null, bool expanded = false) @safe pure nothrow
    {
        this.id = id;
        this.data = data;
        this.children = children;
        this.expanded = expanded;
    }

    bool hasChildren() const @safe pure nothrow @nogc
    {
        return children.length > 0;
    }
}

/// Flattened visible-row entry projected by `TreeModel!T`.
struct FlatTreeRow(T)
{
    string id;
    T data;
    int depth;
    bool hasChildren;
    bool expanded;
    TreeNode!T nodeRef;
}

/// Flattened visible-row model over a hierarchical `TreeNode!T` forest.
/// Toggling expansion inserts/removes visible descendant slices in-place and
/// emits granular `notifyRowsAdded` / `notifyRowsRemoved` events (`E5`, `T4`).
class TreeModel(T) : Model!(FlatTreeRow!T)
{
    enum size_t maxTreeDepth = 128;

    private TreeNode!T[] _roots;
    private FlatTreeRow!T[] _visible;
    private ModelNotify _notify;

    this(TreeNode!T[] roots = null) @safe
    {
        _notify = new ModelNotify();
        _roots = roots;
        rebuildVisible();
    }

    private void rebuildVisible() @safe pure
    {
        _visible = null;
        foreach (r; _roots)
            appendSubtree(r, 0, _visible);
    }

    private static void appendSubtree(TreeNode!T node, int depth, ref FlatTreeRow!T[] target) @safe pure
    {
        if (node is null)
            return;
        if (depth > maxTreeDepth)
            throw new Exception("TreeModel maximum depth exceeded");
        target ~= FlatTreeRow!T(node.id, node.data, depth, node.hasChildren(), node.expanded, node);
        if (node.expanded)
        {
            foreach (child; node.children)
                appendSubtree(child, depth + 1, target);
        }
    }

    private static void appendDescendants(TreeNode!T node, int parentDepth, ref FlatTreeRow!T[] target) @safe pure
    {
        if (node is null || !node.expanded)
            return;
        foreach (child; node.children)
            appendSubtree(child, parentDepth + 1, target);
    }

    size_t rowCount() @safe pure nothrow
    {
        return _visible.length;
    }

    FlatTreeRow!T rowData(size_t row) @safe
    {
        if (row >= _visible.length)
            throw new Exception("TreeModel row index out of range");
        return _visible[row];
    }

    void setRowData(size_t row, FlatTreeRow!T data) @safe
    {
        if (row >= _visible.length)
            throw new Exception("TreeModel row index out of range");
        _visible[row].data = data.data;
        if (_visible[row].nodeRef !is null)
            _visible[row].nodeRef.data = data.data;
        _notify.notifyRowChanged(row);
    }

    ModelNotify notify() @safe pure nothrow
    {
        return _notify;
    }

    /// Replace the root nodes and reset the visible projection.
    void setRoots(TreeNode!T[] roots) @safe
    {
        _roots = roots;
        rebuildVisible();
        _notify.notifyReset();
    }

    /// Toggle the expanded state of the node at `flatRow`, firing granular
    /// `notifyRowsAdded` or `notifyRowsRemoved` notifications (`E5`).
    void toggleExpand(size_t flatRow) @safe
    {
        if (flatRow >= _visible.length)
            throw new Exception("TreeModel.toggleExpand: row index out of range");
        auto entry = _visible[flatRow];
        auto node = entry.nodeRef;
        if (node is null || !node.hasChildren())
            return;

        if (!node.expanded)
        {
            node.expanded = true;
            _visible[flatRow].expanded = true;
            _notify.notifyRowChanged(flatRow);

            FlatTreeRow!T[] inserted;
            appendDescendants(node, entry.depth, inserted);
            if (inserted.length > 0)
            {
                size_t insertPos = flatRow + 1;
                _visible = _visible[0 .. insertPos] ~ inserted ~ _visible[insertPos .. $];
                _notify.notifyRowsAdded(insertPos, inserted.length);
            }
        }
        else
        {
            // Count how many following visible rows belong to this node's subtree (depth > entry.depth)
            size_t removeStart = flatRow + 1;
            size_t removeEnd = removeStart;
            while (removeEnd < _visible.length && _visible[removeEnd].depth > entry.depth)
                ++removeEnd;
            size_t removedCount = removeEnd - removeStart;

            node.expanded = false;
            _visible[flatRow].expanded = false;
            _notify.notifyRowChanged(flatRow);

            if (removedCount > 0)
            {
                _visible = _visible[0 .. removeStart] ~ _visible[removeEnd .. $];
                _notify.notifyRowsRemoved(removeStart, removedCount);
            }
        }
    }

    /// Expand every node in the tree.
    void expandAll() @safe
    {
        static void markExpanded(TreeNode!T n, bool state, size_t depth = 0) @safe
        {
            if (n is null)
                return;
            if (depth > maxTreeDepth)
                throw new Exception("TreeModel maximum depth exceeded");
            if (n.hasChildren())
                n.expanded = state;
            foreach (c; n.children)
                markExpanded(c, state, depth + 1);
        }
        foreach (r; _roots)
            markExpanded(r, true, 0);
        rebuildVisible();
        _notify.notifyReset();
    }

    /// Collapse every node in the tree.
    void collapseAll() @safe
    {
        static void markCollapsed(TreeNode!T n, size_t depth = 0) @safe
        {
            if (n is null)
                return;
            if (depth > maxTreeDepth)
                throw new Exception("TreeModel maximum depth exceeded");
            n.expanded = false;
            foreach (c; n.children)
                markCollapsed(c, depth + 1);
        }
        foreach (r; _roots)
            markCollapsed(r, 0);
        rebuildVisible();
        _notify.notifyReset();
    }
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
    auto folder2 = new TreeNode!string("docs", "docs", [
        new TreeNode!string("README.md", "README.md")
    ], false);

    auto tree = new TreeModel!string([folder1, folder2]);
    assert(tree.rowCount() == 2);
    assert(tree.rowData(0).id == "src" && tree.rowData(0).depth == 0 && tree.rowData(0).hasChildren);
    assert(tree.rowData(1).id == "docs" && tree.rowData(1).depth == 0);

    size_t addedIndex = size_t.max, addedCount = 0;
    size_t removedIndex = size_t.max, removedCount = 0;
    tree.notify().onRowsAdded((idx, cnt) { addedIndex = idx; addedCount = cnt; });
    tree.notify().onRowsRemoved((idx, cnt) { removedIndex = idx; removedCount = cnt; });

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
    import std.exception : assertThrown;

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
