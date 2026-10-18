// The AppKit half of the macOS platform: one window whose view draws with
// Core Graphics and forwards the mouse, plus the cursor, frame requests and
// the debug hooks that scripts and snapshots use.
//
// TEMPORARY: this is the Kitchen's copy of the shell in OpenEtcher's GUI
// (zig-openetcher-gui, src/app/platform/macos/shell.m at fcedfa2), with the
// file picker and the quit confirmation taken out. It is laid out as it
// would sit in fabrum, `src/app/platform/macos/shell.m`, and moves there in
// Phase B; see `src/platform.zig`.
//
// Everything app-specific stays on the Zig side behind `fabrum_shell_host`.
#import <AppKit/AppKit.h>
#include <stdatomic.h>

typedef struct {
    void *ctx;
    // Draws a frame into `cg`, whose origin is the bottom left, in points.
    void (*draw)(void *ctx, CGContextRef cg, double width, double height);
    // Pointer position from the top left of the view, in points.
    void (*mouse)(void *ctx, double x, double y, unsigned buttons, double scroll_x, double scroll_y);
    // Called once before the app exits.
    void (*will_terminate)(void *ctx);
} fabrum_shell_host;

typedef struct {
    const char *title;
    double width;
    double height;
    double min_width;
    double min_height;
    // Nonzero for a dark window frame.
    int dark;
} fabrum_shell_options;

static fabrum_shell_host host;
static NSView *shared_view;
static atomic_bool frame_requested;

@interface FabrumView : NSView
@end

@implementation FabrumView {
    NSTrackingArea *_tracking;
    unsigned _buttons;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
                                                     NSTrackingCursorUpdate
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)forward:(NSEvent *)event scrollX:(double)sx scrollY:(double)sy {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    host.mouse(host.ctx, p.x, self.bounds.size.height - p.y, _buttons, sx, sy);
}

- (void)mouseMoved:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }
- (void)mouseDragged:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }
- (void)mouseEntered:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }

- (void)mouseExited:(NSEvent *)event {
    // far outside, so nothing stays hovered
    host.mouse(host.ctx, -1e6, -1e6, _buttons, 0, 0);
    [[NSCursor arrowCursor] set];
}

- (void)mouseDown:(NSEvent *)event {
    _buttons |= 1;
    [self forward:event scrollX:0 scrollY:0];
}

- (void)mouseUp:(NSEvent *)event {
    _buttons &= ~1u;
    [self forward:event scrollX:0 scrollY:0];
}

- (void)scrollWheel:(NSEvent *)event {
    [self forward:event scrollX:-[event scrollingDeltaX] scrollY:-[event scrollingDeltaY]];
}

- (void)cursorUpdate:(NSEvent *)event {
    // the host sets the cursor from its own hover state
    [self forward:event scrollX:0 scrollY:0];
}

- (void)drawRect:(NSRect)dirty {
    atomic_store(&frame_requested, false);
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    host.draw(host.ctx, cg, self.bounds.size.width, self.bounds.size.height);
}
@end

@interface FabrumAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation FabrumAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    host.will_terminate(host.ctx);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];
}
@end

static void buildMenu(NSString *name) {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *app_item = [[NSMenuItem alloc] init];
    [bar addItem:app_item];
    NSMenu *app_menu = [[NSMenu alloc] init];
    [app_menu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hide:) keyEquivalent:@"h"];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
    app_item.submenu = app_menu;

    NSMenuItem *window_item = [[NSMenuItem alloc] init];
    [bar addItem:window_item];
    NSMenu *window_menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [window_menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [window_menu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    window_item.submenu = window_menu;
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window_menu;
}

// Runs the app until it quits. Never returns.
void fabrum_shell_run(fabrum_shell_options options, fabrum_shell_host new_host) {
    host = new_host;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSString *title = [NSString stringWithUTF8String:options.title];
        buildMenu(title);

        FabrumAppDelegate *delegate = [[FabrumAppDelegate alloc] init];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, options.width, options.height)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = title;
        window.appearance = [NSAppearance appearanceNamed:options.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        window.contentMinSize = NSMakeSize(options.min_width, options.min_height);
        window.releasedWhenClosed = NO;

        FabrumView *view = [[FabrumView alloc] initWithFrame:NSMakeRect(0, 0, options.width, options.height)];
        window.contentView = view;
        [window center];
        shared_view = view;
        delegate.window = window;
        app.delegate = delegate;
        [app run];
    }
    exit(0);
}

// Asks for a frame soon. Safe from any thread; requests made before the
// frame is drawn are coalesced.
void fabrum_shell_request_frame(void) {
    if (atomic_exchange(&frame_requested, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [shared_view setNeedsDisplay:YES];
    });
}

// 0: arrow, 1: pointing hand. Main thread only.
void fabrum_shell_set_cursor(int cursor) {
    if (cursor == 1) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

// Runs `callback(ctx)` on the main thread, after the current event. Safe
// from any thread.
void fabrum_shell_run_on_main(void (*callback)(void *ctx), void *ctx) {
    dispatch_async_f(dispatch_get_main_queue(), ctx, callback);
}

// Quits as the Quit menu item does.
void fabrum_shell_quit(void) {
    [NSApp terminate:nil];
}

// Clicks at (x, y), in points from the top left of the content, by sending
// mouse-down and mouse-up events through the window as AppKit would
// deliver them. For tests: nothing is posted to the system's event stream
// and the real pointer doesn't move. Main thread only.
void fabrum_shell_synthesize_click(double x, double y) {
    NSWindow *window = shared_view.window;
    NSPoint point = [shared_view convertPoint:NSMakePoint(x, shared_view.bounds.size.height - y) toView:nil];
    NSEventType types[] = {NSEventTypeMouseMoved, NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp};
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        NSEvent *event = [NSEvent mouseEventWithType:types[i]
                                            location:point
                                       modifierFlags:0
                                           timestamp:[[NSProcessInfo processInfo] systemUptime]
                                        windowNumber:window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:1
                                            pressure:types[i] == NSEventTypeLeftMouseDown ? 1 : 0];
        if (types[i] == NSEventTypeMouseMoved) {
            // moves go to tracking areas, not through sendEvent's hit test
            [shared_view mouseMoved:event];
        } else {
            [window sendEvent:event];
        }
    }
}

// Draws the window's content into a bitmap at `scale` pixels per point, or
// at the screen's scale if `scale` is 0, and saves it as a PNG at `path`.
// Works while the screen is locked, since it draws the view itself rather
// than reading the screen. Main thread only. Returns whether it was written.
bool fabrum_shell_snapshot(const char *path, double scale) {
    NSView *view = shared_view;
    NSBitmapImageRep *bitmap;
    if (scale > 0) {
        NSSize size = view.bounds.size;
        bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                         pixelsWide:(NSInteger)(size.width * scale)
                                                         pixelsHigh:(NSInteger)(size.height * scale)
                                                      bitsPerSample:8
                                                    samplesPerPixel:4
                                                           hasAlpha:YES
                                                           isPlanar:NO
                                                     colorSpaceName:NSDeviceRGBColorSpace
                                                        bytesPerRow:0
                                                       bitsPerPixel:0];
        if (bitmap) bitmap.size = size;
    } else {
        bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    }
    if (!bitmap) return false;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
}
