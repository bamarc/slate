# Slate Carbon (`slate-carbon`)

Google Carbon language bindings and desktop application runtime support for the **Slate** UI framework.

## Architecture

```
[ Carbon Application Code (main.carbon) ]
                   │
                   ▼ (Zero-overhead C++ interop: import Cpp)
[ Slate C++ Bridge (slate/app.h & src/app.cpp) ]
                   │
                   ▼ (Generated C++ headers via slint-compiler)
[ Slint C++ Runtime & Shared UI Components (//ui:index.slint) ]
                   │
                   ▼
[ Slint Native Desktop Window / Renderer ]
```

1. **Shared Declarative UI**: Slate's component library lives at the repository root (`ui/`) and is written in Slint markup. It is shared 1:1 between `slate-rust` and `slate-carbon`.
2. **C++ Bridge (`slate_cpp`)**: Implements Slate's lifecycle and theme resolution (`slate::AppBuilder`, `slate::ThemeMode`, `slate::init()`) on top of Slint's native C++ API (`slint-cpp`).
3. **Carbon Package (`package Slate library "ui"`)**: Idiomatic Carbon abstractions wrapping the C++ bridge via Carbon's first-class Clang AST interop.

## Prerequisites

- **Bazel**: Version 7.x or later.
- **Slint C++ Compiler**: `slint-compiler` installed on PATH (or via `cargo install slint-compiler --version 1.18.1`).
- **Slint C++ library**: `libslint-cpp-dev` (or compiled from source).
- **Carbon Toolchain**: A working build of `carbon-lang` (Clang-based Carbon compiler and toolchain).

## Workspace Layout

```
slate-carbon/
├── .bazelrc                   # Bazel configuration (C++20, Bzlmod)
├── MODULE.bazel               # Bazel module definitions
├── WORKSPACE.bazel            # Legacy workspace fallback
├── BUILD.bazel                # Main build definitions (:slate_cpp, :slint_ui_cpp)
├── slint.bzl                  # Bazel rule compiling .slint markup to C++
├── ui -> ../ui                # Symlink to the root shared Slint component directory
├── include/
│   └── slate/
│       └── app.h              # C++ lifecycle and AppBuilder header
├── src/
│   └── app.cpp                # C++ runtime implementation
├── carbon/
│   ├── slate.carbon           # Package Slate (AppBuilder, ThemeMode, C++ interop)
│   └── theme.carbon           # Color tokens and theme palettes
├── toolchain/
│   ├── BUILD.bazel
│   └── slint_compiler_wrapper.sh
└── examples/
    └── showcase/
        ├── BUILD.bazel
        └── main.carbon        # Example Carbon desktop application
```

## Quick Start (Example Carbon Usage)

```carbon
package Showcase library "main";

import Slate library "ui";
import Slate library "theme";

fn Main() -> i32 {
    // 1. Create and configure Slate application builder
    var builder: Slate.AppBuilder = Slate.AppBuilder.Create("My Carbon App");
    builder.WithThemeMode(Slate.ThemeMode.Dark);
    builder.Init();

    // 2. Verified active mode
    if (builder.IsDark()) {
        // Dark theme active
    }

    return 0;
}
```
