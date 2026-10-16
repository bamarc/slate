/// Standalone domain capability traits and compile-time inspection for Slate.
///
/// Defines core capability interfaces (`Paginated`, `Seekable`, `Sortable`,
/// `Filterable`, `Expandable`, `DropReceiver`, `Selectable`), compile-time
/// Design-by-Introspection (DbI) predicates (`isPaginated!T`, etc.), and
/// string casing utilities (`camelToSnake`, `setterToPropertyKey`) with zero
/// dependency on MCP or Slint.
module slate.traits;

import std.traits : Unqual;

// -- Casing Helpers ---------------------------------------------------------

/// Convert a camelCase or PascalCase identifier into snake_case.
/// Leaves already snake_case identifiers unchanged.
string camelToSnake(string name) @safe pure nothrow
{
    if (name.length == 0)
        return "";

    char[] result;
    result.reserve(name.length + 4);

    foreach (i, c; name)
    {
        if (c >= 'A' && c <= 'Z')
        {
            if (i > 0 && name[i - 1] != '_')
                result ~= '_';
            result ~= cast(char)(c + ('a' - 'A'));
        }
        else
        {
            result ~= c;
        }
    }
    return () @trusted { return cast(string) result; }();
}

/// Convert a setter method name (e.g. "setVolume", "setSplitRatio")
/// into its property key (e.g. "volume", "split_ratio").
/// If the method name does not match `set[A-Z]...`, returns `camelToSnake(name)`.
string setterToPropertyKey(string name) @safe pure nothrow
{
    if (name.length > 3 && name[0 .. 3] == "set" && name[3] >= 'A' && name[3] <= 'Z')
        return camelToSnake(name[3 .. $]);
    return camelToSnake(name);
}

// -- Runtime Capability Interfaces ------------------------------------------

/// Pagination capability trait.
interface Paginated
{
    size_t currentPage() const @safe pure nothrow;
    size_t totalPages() const @safe pure nothrow;
    size_t pageSize() const @safe pure nothrow;
    void nextPage() @safe;
    void prevPage() @safe;
    void goToPage(size_t page) @safe;
}

/// Media/timeline seek capability trait.
interface Seekable
{
    void seekTo(double seconds);
    double positionSeconds() const @safe pure nothrow;
    double durationSeconds() const @safe pure nothrow;
}

/// Tabular / list sorting capability trait.
interface Sortable
{
    void sortByColumn(size_t columnIndex, string direction);
}

/// Search / query filtering capability trait.
interface Filterable
{
    void setFilterQuery(string query);
    string filterQuery() const @safe pure nothrow;
}

/// Hierarchical / collapsible expansion capability trait.
interface Expandable
{
    void toggleExpand(size_t index);
    void expandAll();
    void collapseAll();
}

/// File / payload drop receiver capability trait.
interface DropReceiver
{
    bool dropFiles(const(string)[] paths);
}

/// Single/multi item selection capability trait.
interface Selectable
{
    void selectIndex(size_t index);
    ptrdiff_t selectedIndex() const @safe pure nothrow;
}

// -- Compile-Time Design-by-Introspection (DbI) Traits ----------------------

enum bool isPaginated(T) = is(T : Paginated) || __traits(compiles, (T t) {
        size_t c = t.currentPage();
        size_t tot = t.totalPages();
        size_t ps = t.pageSize();
        t.nextPage();
        t.prevPage();
        t.goToPage(size_t(1));
    });

enum bool isSeekable(T) = is(T : Seekable) || __traits(compiles, (T t) {
        t.seekTo(0.0);
        double p = t.positionSeconds();
        double d = t.durationSeconds();
    });

enum bool isSortable(T) = is(T : Sortable) || __traits(compiles, (T t) {
        t.sortByColumn(size_t(0), "asc");
    });

enum bool isFilterable(T) = is(T : Filterable) || __traits(compiles, (T t) {
        t.setFilterQuery("");
        string q = t.filterQuery();
    });

enum bool isExpandable(T) = is(T : Expandable) || __traits(compiles, (T t) {
        t.toggleExpand(size_t(0));
        t.expandAll();
        t.collapseAll();
    });

enum bool isDropReceiver(T) = is(T : DropReceiver) || __traits(compiles, (T t) {
        bool ok = t.dropFiles(["a"]);
    });

enum bool isSelectable(T) = is(T : Selectable) || __traits(compiles, (T t) {
        t.selectIndex(size_t(0));
        ptrdiff_t idx = t.selectedIndex();
    });

enum bool isBindable(T) = __traits(hasMember, T, "bindToSlint");

/// Compile-time capability discovery for any type `T`.
string[] detectCapabilities(T)(bool includeControllable = false) @safe pure nothrow
{
    alias U = Unqual!T;
    string[] caps;
    if (includeControllable)
        caps ~= "controllable";
    static if (isBindable!U)
        caps ~= "bindable";
    static if (isPaginated!U)
        caps ~= "paginated";
    static if (isSeekable!U)
        caps ~= "seekable";
    static if (isSortable!U)
        caps ~= "sortable";
    static if (isFilterable!U)
        caps ~= "filterable";
    static if (isExpandable!U)
        caps ~= "expandable";
    static if (isDropReceiver!U)
        caps ~= "drop-receiver";
    static if (isSelectable!U)
        caps ~= "selectable";
    return caps;
}

// Spec: Scenario T1 & U1: Standalone domain capability traits, casing helpers, and DbI detection
/// Example:
unittest
{
    // Casing conversions
    assert(camelToSnake("positionSeconds") == "position_seconds");
    assert(camelToSnake("currentPage") == "current_page");
    assert(camelToSnake("sortByColumn") == "sort_by_column");
    assert(camelToSnake("split_ratio") == "split_ratio");
    assert(camelToSnake("Volume") == "volume");
    assert(camelToSnake("") == "");

    assert(setterToPropertyKey("setVolume") == "volume");
    assert(setterToPropertyKey("setSplitRatio") == "split_ratio");
    assert(setterToPropertyKey("setFilterQuery") == "filter_query");
    assert(setterToPropertyKey("nonSetter") == "non_setter");

    // Structural duck typing vs interface implementation
    static class MockGrid : Paginated, Sortable, Selectable
    {
        private size_t _page = 1;
        private ptrdiff_t _sel = -1;

        override size_t currentPage() const @safe pure nothrow
        {
            return _page;
        }

        override size_t totalPages() const @safe pure nothrow
        {
            return 10;
        }

        override size_t pageSize() const @safe pure nothrow
        {
            return 25;
        }

        override void nextPage() @safe
        {
            _page++;
        }

        override void prevPage() @safe
        {
            if (_page > 1)
                _page--;
        }

        override void goToPage(size_t page) @safe
        {
            _page = page;
        }

        override void sortByColumn(size_t columnIndex, string direction)
        {
        }

        override void selectIndex(size_t index)
        {
            _sel = cast(ptrdiff_t) index;
        }

        override ptrdiff_t selectedIndex() const @safe pure nothrow
        {
            return _sel;
        }
    }

    static struct DuckSeeker
    {
        double pos = 0.0;
        void seekTo(double seconds)
        {
            pos = seconds;
        }

        double positionSeconds() const @safe pure nothrow
        {
            return pos;
        }

        double durationSeconds() const @safe pure nothrow
        {
            return 100.0;
        }
    }

    static assert(isPaginated!MockGrid);
    static assert(isSortable!MockGrid);
    static assert(isSelectable!MockGrid);
    static assert(!isSeekable!MockGrid);

    static assert(isSeekable!DuckSeeker);
    static assert(!isPaginated!DuckSeeker);

    assert(detectCapabilities!MockGrid() == [
        "paginated", "sortable", "selectable"
    ]);
    assert(detectCapabilities!DuckSeeker(true) == ["controllable", "seekable"]);
}
