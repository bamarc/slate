#include "gallery_bridge.h"
#include <iostream>
#include <memory>

#if __has_include("app.h")
#include "app.h"
#define HAS_SLINT_APP 1
#endif

namespace slate::gallery {

struct GalleryHandle {
#if HAS_SLINT_APP
    slint::ComponentHandle<MainWindow> window;
#else
    void* dummy{nullptr};
#endif
    bool is_dark{true};
    int32_t counter{0};
};

void init(std::string_view title) {
    std::cout << "[INFO] Initializing Slate Gallery (Carbon / C++ Bridge): '" << title << "'" << std::endl;
}

GalleryHandle* create() {
    auto* handle = new GalleryHandle();
#if HAS_SLINT_APP
    handle->window = MainWindow::create();
    handle->window->on_toggle_theme([handle]() {
        toggle_theme(handle);
    });
    handle->window->on_increment_counter([handle]() {
        increment_counter(handle);
    });
#endif
    return handle;
}

void toggle_theme(GalleryHandle* handle) {
    if (!handle) return;
    handle->is_dark = !handle->is_dark;
    std::cout << "[INFO] Theme toggled: dark=" << (handle->is_dark ? "true" : "false") << std::endl;
#if HAS_SLINT_APP
    // Slint global theme toggle
#endif
}

void set_active_tab(GalleryHandle* handle, int32_t tab_index) {
    if (!handle) return;
#if HAS_SLINT_APP
    handle->window->set_active_tab(tab_index);
#endif
}

void increment_counter(GalleryHandle* handle) {
    if (!handle) return;
    handle->counter++;
    std::cout << "[INFO] Counter incremented to: " << handle->counter << std::endl;
}

void run(GalleryHandle* handle) {
    if (!handle) return;
    std::cout << "[INFO] Running Slate Gallery window via Slint desktop event loop..." << std::endl;
#if HAS_SLINT_APP
    handle->window->run();
#endif
}

void destroy(GalleryHandle* handle) {
    delete handle;
}

} // namespace slate::gallery
