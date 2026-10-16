#pragma once

#include <string_view>
#include <cstdint>

// Non-templated C++ bridge interface tailored for Carbon's Clang-based FFI
namespace slate::gallery {

/// Opaque handle to the Slint showcase gallery window
struct GalleryHandle;

/// Initializes the gallery application runtime and logger.
void init(std::string_view title);

/// Creates an instance of the Slate Showcase Gallery window.
GalleryHandle* create();

/// Toggles the gallery theme between dark and light modes.
void toggle_theme(GalleryHandle* handle);

/// Sets the active gallery navigation tab (0: Overview, 1: Components, etc.)
void set_active_tab(GalleryHandle* handle, int32_t tab_index);

/// Increments the demo counter widget in the gallery.
void increment_counter(GalleryHandle* handle);

/// Runs the Slint desktop event loop, showing the gallery window.
void run(GalleryHandle* handle);

/// Destroys the gallery instance and releases its resources.
void destroy(GalleryHandle* handle);

} // namespace slate::gallery
