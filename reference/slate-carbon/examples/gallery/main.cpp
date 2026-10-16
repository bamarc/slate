#include "gallery_bridge.h"

int main() {
    // 1. Initialize the Slate Showcase Gallery runtime
    slate::gallery::init("Slate Desktop Gallery (Carbon Bridge Host)");

    // 2. Instantiate the Gallery Window
    slate::gallery::GalleryHandle* gallery = slate::gallery::create();

    // 3. Configure initial state
    slate::gallery::set_active_tab(gallery, 1);
    slate::gallery::toggle_theme(gallery);

    // 4. Run the desktop event loop
    slate::gallery::run(gallery);

    // 5. Clean up upon window exit
    slate::gallery::destroy(gallery);
    return 0;
}
