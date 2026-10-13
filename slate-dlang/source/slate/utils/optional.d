/// Monadic combinators for `std.typecons.Nullable!T`.
///
/// Implements UFCS-enabled functional combinators (`map`, `andThen`,
/// `unwrapOr`, `match`) providing ergonomic value transformation and
/// error handling matching Rust's `Option<T>` / `?` without GC churn.
module slate.utils.optional;

import std.traits : isCallable;
import std.typecons : Nullable, nullable;

/// Transforms the value inside `opt` with `fn` if populated, returning a new `Nullable`.
/// If `opt` is empty, returns an empty `Nullable`.
template map(alias fn)
{
    auto map(Opt)(auto ref Opt opt) if (is(Opt : Nullable!T, T))
    {
        alias R = typeof(fn(opt.get));
        static if (is(R == void))
        {
            if (!opt.isNull)
                fn(opt.get);
        }
        else
        {
            if (opt.isNull)
                return Nullable!R.init;
            return nullable(fn(opt.get));
        }
    }
}

/// Overload of `map` accepting a callable delegate or function pointer.
auto map(Opt, F)(auto ref Opt opt, F fn) if (is(Opt : Nullable!T, T))
{
    alias R = typeof(fn(opt.get));
    static if (is(R == void))
    {
        if (!opt.isNull)
            fn(opt.get);
    }
    else
    {
        if (opt.isNull)
            return Nullable!R.init;
        return nullable(fn(opt.get));
    }
}

/// Chains another optional-producing operation `fn` if `opt` is populated.
/// If `opt` is empty, returns an empty `Nullable` of the result type.
template andThen(alias fn)
{
    auto andThen(Opt)(auto ref Opt opt) if (is(Opt : Nullable!T, T))
    {
        alias R = typeof(fn(opt.get));
        static assert(is(R : Nullable!U, U), "andThen function must return a Nullable!U, but returned " ~ R.stringof);
        if (opt.isNull)
            return R.init;
        return fn(opt.get);
    }
}

/// Overload of `andThen` accepting a callable delegate or function pointer.
auto andThen(Opt, F)(auto ref Opt opt, F fn) if (is(Opt : Nullable!T, T))
{
    alias R = typeof(fn(opt.get));
    static assert(is(R : Nullable!U, U), "andThen function must return a Nullable!U, but returned " ~ R.stringof);
    if (opt.isNull)
        return R.init;
    return fn(opt.get);
}

/// Returns the contained value if populated, or `defaultValue` if empty.
/// If `defaultValue` is a callable (lambda/delegate) generating `T`, it is lazily invoked only when empty.
auto unwrapOr(Opt, U)(auto ref Opt opt, auto ref U defaultValue) if (is(Opt : Nullable!T, T))
{
    alias T = typeof(opt.get);
    if (opt.isNull)
    {
        static if (!is(U : T) && isCallable!U && is(typeof(defaultValue()) : T))
            return defaultValue();
        else
            return defaultValue;
    }
    return opt.get;
}

/// Template overload of `unwrapOr` allowing compile-time value or function aliases.
template unwrapOr(alias def)
{
    auto unwrapOr(Opt)(auto ref Opt opt) if (is(Opt : Nullable!T, T))
    {
        alias T = typeof(opt.get);
        if (opt.isNull)
        {
            static if (!is(typeof(def) : T) && isCallable!def && is(typeof(def()) : T))
                return def();
            else
                return def;
        }
        return opt.get;
    }
}

/// Pattern matches on `opt`, calling `onSome(val)` if populated or `onNone()` if empty.
template match(alias onSome, alias onNone)
{
    auto match(Opt)(auto ref Opt opt) if (is(Opt : Nullable!T, T))
    {
        if (opt.isNull)
        {
            static if (isCallable!onNone)
                return onNone();
            else
                return onNone;
        }
        else
        {
            return onSome(opt.get);
        }
    }
}

/// Overload of `match` accepting runtime delegates or functions.
auto match(Opt, FSome, FNone)(auto ref Opt opt, FSome onSome, FNone onNone) if (is(Opt : Nullable!T, T))
{
    if (opt.isNull)
    {
        static if (isCallable!FNone)
            return onNone();
        else
            return onNone;
    }
    else
    {
        return onSome(opt.get);
    }
}

/// Returns `opt` if populated and `pred(val)` evaluates to true.
/// Returns an empty `Nullable` if `opt` is empty or `pred(val)` evaluates to false.
template filter(alias pred)
{
    auto filter(Opt)(auto ref Opt opt) if (is(Opt : Nullable!T, T))
    {
        if (opt.isNull || !pred(opt.get))
            return Opt.init;
        return opt;
    }
}

/// Overload of `filter` accepting a callable delegate or function pointer.
auto filter(Opt, Pred)(auto ref Opt opt, Pred pred) if (is(Opt : Nullable!T, T))
{
    if (opt.isNull || !pred(opt.get))
        return Opt.init;
    return opt;
}

/// Unit tests verifying map, andThen, unwrapOr, match, and filter on populated and empty Nullable!T.
unittest
{
    import std.conv : to;

    // 1. map
    Nullable!int popInt = nullable(5);
    Nullable!int emptyInt;

    auto m1 = popInt.map!(x => x * 2);
    assert(!m1.isNull && m1.get == 10);

    auto mType = popInt.map!(x => x.to!string);
    assert(!mType.isNull && mType.get == "5");

    auto mEmpty = emptyInt.map!(x => x * 2);
    assert(mEmpty.isNull);

    // map with delegate
    auto mDel = popInt.map((int x) => x + 3);
    assert(!mDel.isNull && mDel.get == 8);

    // 2. andThen
    auto at1 = popInt.andThen!(x => nullable(x * 10));
    assert(!at1.isNull && at1.get == 50);

    auto atNone = popInt.andThen!(x => x > 100 ? nullable(x) : Nullable!int.init);
    assert(atNone.isNull);

    auto atEmpty = emptyInt.andThen!(x => nullable(x * 10));
    assert(atEmpty.isNull);

    // andThen with delegate
    auto atDel = popInt.andThen((int x) => nullable(x + 20));
    assert(!atDel.isNull && atDel.get == 25);

    // 3. unwrapOr
    assert(popInt.unwrapOr(99) == 5);
    assert(emptyInt.unwrapOr(99) == 99);
    assert(emptyInt.unwrapOr!99 == 99);

    // Lazy callable evaluation
    int calls = 0;
    int lazyFallback() { calls++; return 42; }
    assert(popInt.unwrapOr(() => lazyFallback()) == 5);
    assert(calls == 0); // Not called when populated
    assert(emptyInt.unwrapOr(() => lazyFallback()) == 42);
    assert(calls == 1); // Called when empty

    // 4. match
    auto mat1 = popInt.match!(x => x * 2, () => 0);
    assert(mat1 == 10);

    auto matEmpty = emptyInt.match!(x => x * 2, () => 0);
    assert(matEmpty == 0);

    auto matVal = emptyInt.match!(x => x * 2, 77);
    assert(matVal == 77);

    // 5. Monadic chaining
    auto chainVal = nullable(10)
        .map!(x => x + 5)
        .andThen!(x => nullable(x * 2))
        .unwrapOr(0);
    assert(chainVal == 30);

    auto chainEmpty = Nullable!int.init
        .map!(x => x + 5)
        .andThen!(x => nullable(x * 2))
        .unwrapOr(999);
    assert(chainEmpty == 999);

    // 6. Zero GC / nogc pure nothrow verification
    void testNogc() @safe pure nothrow @nogc
    {
        Nullable!int n = nullable(10);
        auto m = n.map!(x => x + 1);
        auto a = m.andThen!(x => nullable(x * 2));
        int res = a.unwrapOr(0);
        assert(res == 22);

        Nullable!int empty;
        assert(empty.unwrapOr(50) == 50);
    }
    testNogc();

    // 7. Edge cases: void-returning map for side effects
    int sideEffect = 0;
    popInt.map!((int x) { sideEffect += x; });
    assert(sideEffect == 5);
    emptyInt.map!((int x) { sideEffect += x; });
    assert(sideEffect == 5); // Unchanged when empty

    // 8. Runtime delegate match
    auto matchDel = popInt.match((int x) => x + 10, () => -1);
    assert(matchDel == 15);
    auto matchDelEmpty = emptyInt.match((int x) => x + 10, () => -1);
    assert(matchDelEmpty == -1);

    // 9. const Nullable!T unwrapOr
    const Nullable!string constPop = nullable("hello");
    assert(constPop.unwrapOr("fallback") == "hello");
    const Nullable!string constEmp;
    assert(constEmp.unwrapOr("fallback") == "fallback");

    // 10. Nullable of callable type unwrapOr (returns default callable, does not call it)
    alias Handler = int delegate();
    Handler defHandler = () => 123;
    Nullable!Handler emptyHandler;
    auto resolved = emptyHandler.unwrapOr(defHandler);
    assert(resolved !is null && resolved() == 123);

    Handler popHandler = () => 456;
    Nullable!Handler hasHandler = nullable(popHandler);
    assert(hasHandler.unwrapOr(defHandler)() == 456);

    // 11. filter combinator
    Nullable!int numPop = nullable(42);
    Nullable!int numEmpty;
    assert(!numPop.filter!(x => x > 20).isNull && numPop.filter!(x => x > 20).get == 42);
    assert(numPop.filter!(x => x > 100).isNull);
    assert(numEmpty.filter!(x => x > 20).isNull);
    assert(!numPop.filter((int x) => x % 2 == 0).isNull && numPop.filter((int x) => x % 2 == 0).get == 42);
    assert(numPop.filter((int x) => x % 2 != 0).isNull);

    // 12. const Nullable!T filter
    const Nullable!int constNum = nullable(100);
    assert(!constNum.filter!(x => x > 50).isNull && constNum.filter!(x => x > 50).get == 100);
    assert(constNum.filter!(x => x > 200).isNull);
    assert(!constNum.filter((const int x) => x == 100).isNull);
    assert(constNum.filter((const int x) => x != 100).isNull);
}
