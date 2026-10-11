import Core library "io";

import Cpp inline '''
#include <iostream>

extern "C" {
    int slate_gallery_run_native(const char* title, int initial_tab, bool force_dark, bool enable_mcp);
}

inline int LaunchSlateGallery(const char* title, int tab, bool dark, bool mcp) {
    std::cout << "[Carbon Bridge] Calling native Slate Gallery from Carbon via C++ interop (MCP: "
              << (mcp ? "enabled" : "auto") << ")..." << std::endl;
    return slate_gallery_run_native(title, tab, dark, mcp);
}
''';

fn Run() -> i32 {
    Core.PrintStr("===================================================\n");
    Core.PrintStr("  Slate Desktop Component Gallery (Carbon Runner) \n");
    Core.PrintStr("===================================================\n");
    Core.PrintStr("[Carbon] Launching Slate Gallery (Tab: Components, Mode: Dark, MCP: Enabled)...\n");

    let status: i32 = Cpp.LaunchSlateGallery(
        Cpp.std.data("Slate Showcase Gallery (Carbon)\0"),
        1,
        true,
        true
    );

    Core.PrintStr("[Carbon] Gallery window closed. Exit status: ");
    Core.Print(status);
    return status;
}
