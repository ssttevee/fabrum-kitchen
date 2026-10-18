# Input, scrolling, text and animation in fabrum: a design driven by the Kitchen

Status: proposal for review (Phase A). Nothing here is implemented in fabrum yet.
Written against fabrum trunk `54fcb56`: `ui.messages(C)`, `app.Action = app.Handler(void)`,
`ui.one`, `app.testing.Harness`.

The Kitchen is a port of Gio's Kitchen demo (`gio-example/kitchen/kitchen.go`). It has two jobs:

- drive the design of what fabrum lacks: scrolling, keyboard input and focus, text editing,
  dragging and animation;
- keep fabrum from fitting only OpenEtcher, the disk flasher it grew up with.

Contents:

1. [Kitchen inventory](#1-kitchen-inventory)
2. [Principles and layering](#2-principles-and-layering)
3. [Element events: the shared foundation](#3-element-events-the-shared-foundation)
4. [Scrolling](#4-scrolling)
5. [Dragging and pointer capture](#5-dragging-and-pointer-capture)
6. [Keyboard input and focus](#6-keyboard-input-and-focus)
7. [Text editing](#7-text-editing)
8. [Animation and timed frames](#8-animation-and-timed-frames)
9. [Drawing gaps: gradients, transforms, arcs, italics](#9-drawing-gaps-gradients-transforms-arcs-italics)
10. [Disabled state](#10-disabled-state)
11. [fabrum.app.platform](#11-fabrumappplatform)
12. [Testing without a window](#12-testing-without-a-window)
13. [Over-fitting: what OpenEtcher taught fabrum, revisited](#13-over-fitting-what-openetcher-taught-fabrum-revisited)
14. [Risks and open questions](#14-risks-and-open-questions)
15. [Phase B plan](#15-phase-b-plan)

---

## 1. Kitchen inventory

The whole Kitchen page is a vertical `material.List`: eleven items, each inset by 16 dp, with a
scrollbar. A background goroutine adds 0.1 to `progress` every second, wrapping past 1, and calls
`w.Invalidate()`. `-disable` runs the whole page under `gtx.Disabled()`.

Key: **yes** means it works in fabrum today, **partial** means some of it does, **no** means none of it does.
The last column says what the Kitchen's first screen (this repo) does with the widget now.

| # | Widget / behaviour | fabrum features it needs | Today | First screen |
|---|---|---|---|---|
| 1 | Heading `H3` ("Hello, Gio"), selectable text, replaced by the line editor's text on Enter | Text (yes). Read-only text selection by pointer drag, double/triple click (no). Copy with Cmd-C (no: keys, clipboard). Focus (no) | partial | Static heading, "Hello, fabrum" |
| 2 | Multi-line editor, max 200 dp tall, scrolls inside; pre-filled with a long text; "Hint" placeholder | Focus; key and text input; IME; caret and selection drawing; caret blink (timed frames); pointer-to-offset and offset-to-rect text geometry; clipboard; undo; internal vertical scrolling with the wheel; scrolling to the caret; max-height sizing (`fit` with `max`, yes) | no | Not yet |
| 3 | Single-line editor, italic, 2 dp border with 8 dp radius, 8 dp inset; Enter submits | All of 2, single-line horizontal scrolling, a submit event, italic text style (no: `text.Style` has no slant), border (yes) | no | Not yet |
| 4 | Linear gradient strip, 50 dp tall, green to blue corner to corner | Gradient fill (no: rectangles are one color) | no | Not yet |
| 5a | Icon button (round, "add" icon) | Clicks (yes), hover and press styling (yes), SVG icon picture (yes, Quartz) | yes | Done |
| 5b | Icon and text button | Same as 5a | yes | Done |
| 5c | "Click me!" toggles the next button's label and color | Clicks and messages (yes) | yes | Done |
| 5d | "Green" / "Blue" button, colored by state | Yes | yes | Done |
| 5e | Flat button: text that shows a hover overlay; dimmed when disabled | Yes; disabled (app context today) | yes | Done |
| 5f | Progress circle: an arc for `progress` | Arc stroking (no); progress ticking every second from a timer (no timers; `Poster` from a thread works today) | partial | A static ring (full track, no arc) |
| 6 | Progress bar, animated by the ticking `progress` | Percent width (yes, **but buggy**: see below); timer messages (no) | partial | Static at 0.3 |
| 7a | "Transform" checkbox: rotates, shrinks and slides the whole UI over time, animated | Clicks (yes); time in views and update (no); continuous frames (no); paint-time affine transforms, and hit-testing through them (no) | partial | Toggles state, no transform |
| 7b | Switch: enables the next button, and shows a spinner while on | Clicks (yes); scoped disabled state (app context works) | yes | Done, with a visible label (Gio's is only an accessibility description) |
| 7c | "enabled" / "disabled" button | Disabled subtree (app context today) | yes | Done |
| 7d | Loader spinner | Arc stroking (no); continuous frames and time (no) | no | A static ring |
| 8 | Three radio buttons (`widget.Enum`): each is focusable, the click selects | Clicks (yes); focus and Space/Enter activation (no) | partial | Clicks done |
| 9 | Slider (`widget.Float`), value shown as `%.2f` | Pointer press and drag with capture, local coordinates and the element's width (no); keyboard optional (Gio has none) | no | Not yet |
| 10 | Whole page as a scrolling list with a draggable scrollbar | Scroll offsets, wheel and trackpad routing, content-size measurement, clamping, scrollbar drawing, thumb drag (no; `clip.child_offset` and scissors exist) | partial | The page fits 800×700 without scrolling |
| 11 | `-disable`: every widget disabled | Disabled subtree | yes | `--disable`, through a provided `theme.Disabled` |
| 12 | Window: 800×700 dp, light theme, Retina | Shell (yes) | yes | Done |

**fabrum bug found while building the first screen.** A `percent` child of a `grow` parent gets
its percentage applied twice. A 0.3 fill in a 768-point track comes out 69 points wide, which is
0.09 of the track. A probe against trunk measured `track.w=800 fill.w=72`. The Kitchen's progress
bar shows it; the fix belongs in `fabrum.layout` and is the first step of Phase B.

## 2. Principles and layering

The existing rules stay:

- One component shape: `Props`, `view`, and optionally `State`, `Msg` and `update`.
- Views get a `*app.Ui`, are pure, and allocate from the frame arena.
- Errors stay explicit, with `try` everywhere.
- Contexts are looked up by type.
- Callbacks are values (`Handler(P)` / `Action`).

The Kitchen adds these rules:

1. **`layout` never imports `app`.** `layout` stays a pure function from declarations to boxes
   and render commands. It takes everything that changes over time as input (scroll offsets,
   caret position, transforms) and gives back the geometry the app needs (content size, text
   positions). It owns no state between frames.
2. **`app` owns interaction state keyed by element ID.** Element IDs are already stable per
   (instance, key). The runtime keeps hover, press and capture by element ID, and this design
   adds focus, scroll offsets and read-only text selection. That state belongs to the user's
   *interaction* with an element, not to the app's model, which mirrors the DOM: Elm leaves
   scroll position and focus to the browser and offers commands to change them. Apps observe it
   through handlers and change it through commands.
3. **The app's model lives in component `State`** and changes only in `update`. That includes
   editable text and its selection, slider values, toggles, and anything the app must read or
   reset.
4. **Events arrive as messages with everything `update` needs**: local coordinates, the
   element's size, and the text offset under the pointer. `update` never touches the layout.
5. **Platforms translate; they don't decide.** The shell turns OS events into platform-neutral
   input (`MouseEvent`, `ScrollEvent`, `KeyEvent`, `TextInput`) and answers the OS's synchronous
   questions, such as the IME's caret rectangle, from state the runtime publishes after each
   frame.
6. **Renderers stay separate.** The shell gives the host an opaque drawing surface. The
   renderer interprets it. fabrum never imports a renderer.

| Concern | `fabrum.layout` | `fabrum.app` | `fabrum.app.platform` | renderer |
|---|---|---|---|---|
| Scrolling | applies `child_offset`; measures content size; clamps; culls offscreen units; keeps clipped children's min size from propagating up | offsets by element ID; wheel and trackpad routing, chaining and latching; momentum; scroll-into-view; scrollbar | delivers deltas with phase and momentum phase, in points | nested scissors (Quartz intersects already) |
| Dragging | — | pointer capture; local coordinates; drag slop; cancellation | button state and window focus loss | — |
| Keys and focus | — | focus by element ID; tab order from the last frame; key routing and bubbling; shortcuts | key codes, modifiers and repeat in, mapped to `Key` | — |
| Text editing | caret rectangle and selection rectangles from text and offset; offset at a point; selection and caret draw as rectangle commands | editor model; edits as messages; IME mirror; caret blink; clipboard commands | NSTextInputClient and the other platforms' IMEs; clipboard; UTF-16 conversion | draws plain rectangles and text |
| Animation | — | `now`; frame requests; timers as subscriptions | display link; one-shot wakeups | — |
| Transforms and gradients | render commands carry them | hit-testing through inverse transforms | — | draws them |

## 3. Element events: the shared foundation

Today `Ui.Container` is `layout.ContainerDeclaration` (without `id`) plus `on_click: ?Action`. This
section generalises that into a small set of handler fields, all optional and all ordinary
`Handler`s:

```zig
pub const Container = struct {
    // ... every layout.ContainerDeclaration field except `id` ...
    on_click: ?app.Action = null,            // today
    on_pointer: ?app.Handler(app.Pointer) = null, // press, drag, release, cancel: captures the pointer (§5)
    scroll: ?app.Scroll = null,              // makes the element a scroll container (§4)
    focus: ?app.Focus = null,                // makes it focusable, with key and text handlers (§6, §7)
};
```

The runtime fires these the way it fires `on_click` today:

- It hit-tests against the last frame and finds the element.
- It builds the payload. It owns that payload, so the payload lives in the message, unlike a
  bound action's.
- It queues the message for the handler's instance.

Payloads are small structs that fit `inline_size`.

The runtime keeps the hit chain it already computes (the hit element and its keyed ancestors).
Every kind of event uses it the same way: the nearest element in the chain that has the
relevant handler gets the event. Clicks already work like this.

## 4. Scrolling

### Proposal

A scroll container is any container declared with `scroll`:

```zig
pub const Scroll = struct {
    x: bool = false,
    y: bool = true,
    /// Draw the runtime's overlay scrollbar, styled by a provided `app.ScrollbarStyle`.
    scrollbar: bool = true,
    /// Keep the end in view as content grows, until the user scrolls back (Gio's ScrollToEnd).
    stick_to_end: bool = false,
    /// Told whenever the offset changes, e.g. to load more.
    on_scroll: ?app.Handler(app.ScrollInfo) = null,
};

pub const ScrollInfo = struct {
    offset: Vec2,   // ≥ 0, from the top left of the content
    viewport: Vec2, // the container's inner size
    content: Vec2,  // the children's extent
};
```

The offset is **owned by the runtime, keyed by the container's element ID**. It is dropped after
the first frame that doesn't render the container, the same way stateful instances are swept.

- `ui.open` turns it into `clip = .{ .horizontal = x, .vertical = y, .child_offset = -offset }`.
  The layout already applies `child_offset` and emits scissors.
- Views read the last frame's numbers with `ui.scrollInfo(key) ?ScrollInfo`, for a custom
  scrollbar or a "back to top" button.
- `update` changes the offset with commands, keyed in its own instance:

```zig
ctx.scrollTo("log", .end);                       // .start, .end, .{ .offset = v }, .{ .by = v }
ctx.scrollIntoView("log", ctx.element("row-42")); // nearest scroll ancestor(s) reveal it
```

Commands queue like messages and apply before the next frame's views run.

**Kitchen usage.** The page:

```zig
try ui.open("page", .{
    .layout = .{ .sizing = .grow(.{}), .axis = .y },
    .scroll = .{ .y = true },
});
defer ui.close();
```

The 200-point editor is a scroll container that the editor widget makes itself (§7). It reveals
the caret with `scrollIntoView` after each edit.

### Layout responsibilities

- **`Unit.content_size`**: the children's extent plus padding, recorded during layout for every
  container. Clay does this per scroll container.
- **Clamping.** The runtime clamps against the last frame's `content_size - viewport` and
  clamps again after layout, because content can shrink in the frame that renders it. If the
  clamp changes the offset, the frame is marked dirty, so the next frame shows the clamped
  position. That is one frame of lag, and only when content shrinks under a scrolled view.
- **Sizing on a clipped axis.** Children's minimum sizes stop propagating up, so the container
  can be smaller than its content. Overflowing children are not compressed along that axis.
  Clay does both, and fabrum needs to check its own shrink pass.
- **Culling.** Units entirely outside their clip rectangle emit no render commands. Clay culls
  only against the window. Culling against the clip matters for the long text in the 200-point
  editor.
- Hit-testing already rejects points outside *every* clipping ancestor (`clippedAway`). That is
  better than Clay, which only checks the nearest one. Keep it.

### Routing wheel and trackpad input

- **A new entry point.** `Runtime.scroll(ScrollEvent)` replaces `MouseEvent.scroll_delta`,
  which nothing reads today:

```zig
pub const ScrollEvent = struct {
    position: Vec2,
    delta: Vec2,                 // points; +y scrolls content up (towards the end)
    precise: bool,               // trackpad / Magic Mouse vs line-stepped wheel
    phase: Phase = .none,        // .began, .changed, .ended, .cancelled, .none (plain wheel)
    momentum: Phase = .none,     // OS-generated inertia (macOS), same values
};
```

- **Chaining.** Candidates are the scroll containers in the hit chain, innermost first. Each one
  takes the part of the delta it can still absorb on its axes, and passes the rest outwards.
  This is Gio's `clampSplit`. An inner list at its end therefore hands the scroll to the page.
  Clay has no chaining.
- **Latching.** A gesture (`phase` from `.began` to `.ended`, then its momentum) stays latched
  to the container it started in, as AppKit's scroll views do. Content moving under the pointer
  mid-gesture therefore doesn't steal the scroll.
- **Momentum.**
  - **macOS:** the OS generates trackpad momentum (`momentumPhase`), and fabrum just applies it.
  - **Wayland:** sends `axis_source=finger` and `axis_stop`, and generates no momentum.
  - **Touch drag-to-scroll:** generates none either.
  - For those cases, the runtime runs its own fling: an exponential decay over time, as in Gio.
    It is not a per-frame factor like Clay's `*= 0.95`, which runs faster at 120 Hz than at
    60 Hz.
  - It runs only when the platform says it generates no momentum.
  - While it runs, the runtime requests frames (§8).
- **Line steps.** Wheels that step in lines are converted to points by the platform, at a line
  height the runtime is configured with (default 3 lines of 16 points).

### Scrollbar

- With `scrollbar = true`, `ui.close()` of a scroll container appends a floating thumb. Its
  element ID is derived from the container's, and it is sized and positioned from the last
  frame's `ScrollInfo`.
- The runtime handles the thumb's drag itself (§5):
  - dragging maps pointer delta to offset by `content / viewport`;
  - pressing the track pages towards the pointer.
- Its look comes from a provided `app.ScrollbarStyle`, the context pattern OpenEtcher uses for
  its theme. The default is a macOS-style overlay: thin, and wider on hover.

### Virtualised lists

Gio's `layout.List` lays out only the visible children, and its persistent state is a
(first index, pixel offset) anchor. The Kitchen has eleven items and doesn't need it. A list
widget can come later on top of `ScrollInfo` and commands. It isn't part of Phase B.

## 5. Dragging and pointer capture

Today:

- Press and release resolve to clickable elements.
- Hover keeps following the pointer while a button is held.
- `ui.pressed(key)` reflects the hovered chain at press time.

Nothing gets the pointer's movement.

### Proposal

```zig
pub const Pointer = struct {
    kind: enum { press, drag, release, cancel },
    position: Vec2,   // window points
    local: Vec2,      // relative to the element's last-frame box; may lie outside it while captured
    size: Vec2,       // the element's last-frame box size
    buttons: MouseEvent.Buttons,
    modifiers: Modifiers,
    clicks: u8,       // 1, 2, 3: double and triple clicks, for text selection
};
```

- **Implicit capture.** A primary press on the nearest element in the hit chain with
  `on_pointer` captures the pointer. Until release, every move goes to that element as `.drag`,
  wherever the pointer is. AppKit already sends `mouseDragged` outside the view while a button
  is held. This is Gio's press-time handler freeze.
- **Clicks still work.**
  - If the captured element also has `on_click`, or bubbles to one, the click fires on release
    as today.
  - An element can ask for a **slop**: `on_pointer` with `.drag_after = 4` points. Moving past
    the slop turns the press into a drag and cancels the pending click.
- **Cancellation.** `.cancel` is sent:
  - when the window loses key status;
  - when the captured element disappears;
  - when a runtime-owned gesture takes over the pointer (touch drag-to-scroll, the scrollbar).

  Every gesture state machine must handle it. This is Gio's grab.
- **No geometry in `update`.** `local` and `size` come from the last frame, so a slider needs
  nothing else.

**Kitchen slider:**

```zig
// view
try ui.open("slider", .{
    .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(32) } },
    .on_pointer = on.handler(.slide),
});
// update
.slide => |p| if (p.kind != .cancel) {
    state.value = std.math.clamp(p.local.x / p.size.x, 0, 1);
},
```

- **Messages per move.** Every move already causes a frame, so one message per move adds little.
  The runtime can coalesce consecutive `.drag` messages to one instance before delivering them,
  and should if profiling says so.
- **Cursor.** `Cursor` grows `text` (I-beam), `grab` and `grabbing`. The cursor is chosen per
  element (`cursor: ?Cursor` on `Container`), with today's `pointer` over clickables as the
  default.

## 6. Keyboard input and focus

### Focus

- **Where it lives.** Focus is **one element ID owned by the runtime**: `?u32`, plus whether it
  was reached by keyboard (for focus rings).
- **Focusable elements** declare `focus`:

```zig
pub const Focus = struct {
    on_key: ?app.Handler(app.KeyEvent) = null,
    /// Keys `on_key` wants. Others bubble on (see below). Default: all except Tab/Shift-Tab and Escape.
    keys: KeyFilter = .typing,
    on_focus: ?app.Handler(bool) = null,      // gained / lost
    on_text: ?app.Handler(app.TextInput) = null, // §7: makes the element a text input client
    /// Whether a pointer press focuses it. Text fields and radio items: yes. Buttons: no, as on macOS.
    focus_on_press: bool = true,
};
```

- **Tab order** is the paint order of the focusable elements in the last frame. Tab and Shift-Tab
  move focus unless the focused element's `keys` include them; a code editor might want Tab.
  There's no explicit tab index for now.
- **Clicking elsewhere.** A press that lands on no focusable element clears focus, as browsers
  do.
- **Losing the element.** If the focused element isn't rendered in a frame, focus is cleared and
  its `on_focus(false)` is queued, if its instance still exists.
- **Commands from `update`:**
  - `ctx.focus("name")`, keyed in the instance;
  - `ctx.blur()`;
  - `ctx.focusNext()` and `ctx.focusPrevious()`.
- **Queries for views:**
  - `ui.focused(key) bool`;
  - `ui.focusVisible(key) bool`, for rings only after keyboard navigation (CSS `:focus-visible`).
- **Revealing.** Focus moved by the keyboard calls `scrollIntoView` on the newly focused element
  (§4), as Gio's `RevealFocus` does.

### Keys

```zig
pub const KeyEvent = struct {
    key: Key,                 // logical key: .a ... .z, .digit_0 ..., .enter, .tab, .escape, .backspace,
                              // .delete, .left, .right, .up, .down, .home, .end, .page_up, .page_down, .f1 ...
    action: enum { press, repeat, release },
    modifiers: Modifiers,     // shift, control, alt (Option), super (Command), plus `shortcut` = Command on macOS, Ctrl elsewhere
};
```

**Routing order:**

1. The focused element's `on_key`, if its `keys` match.
2. Its keyed ancestors with `focus.on_key` that match, bubbling up like DOM events.
3. **Shortcuts.** These are declared by views while rendered, so they disappear with them:

   ```zig
   try ui.shortcut(.{ .key = .s, .modifiers = .shortcut }, on.bind(.save));
   ```

4. **Runtime defaults:**
   - Tab and Shift-Tab move focus;
   - Space and Enter activate a focused element that has `on_click`, on *release*, as Gio does;
   - Escape clears focus if nothing took it.
5. **Unhandled.** The runtime returns `false` to the platform, which passes the key on (on macOS,
   `super keyDown:` for menu key equivalents, then the beep).

**Handled or not, synchronously.** `Runtime.key(event) bool` must answer before the message is
delivered, because AppKit needs it inside `keyDown:`. The answer comes from the *declarations*
made in the last frame (filters, shortcuts), not from running `update`. This is why `keys` is a
declared filter, not a check inside `update`, and it is Gio's reason for filters too.

**Kitchen usage.**

- Radio buttons are focusable. Space activates them through the runtime default.
- Optional arrow-key roving inside the group is the widget's own `on_key`.

## 7. Text editing

### Model: controlled text, in the app's State

Editable text is part of the app's model. The Kitchen sets the heading from the line editor and
then clears it, which Gio does with `lineEditor.SetText("")`. In an Elm-style runtime the parent
can't reach into a child component's state, so the editor's state lives in the parent's `State`.
fabrum ships it as a library type, the "nested TEA" pattern:

```zig
pub const TextEditor = struct {              // fabrum.app.TextEditor
    text: std.ArrayList(u8) = .empty,        // UTF-8
    selection: Selection = .{},              // byte offsets: anchor and head, head is the caret
    composition: ?Range = null,              // IME marked text, within `text`
    preferred_x: ?f32 = null,                // column kept by up/down
    history: History = .{},                  // undo/redo, coalescing typing runs

    pub fn apply(self: *TextEditor, gpa: Allocator, input: TextInput, options: Options) Allocator.Error!Outcome;
    pub fn setText(self: *TextEditor, gpa: Allocator, text: []const u8) Allocator.Error!void;
    pub fn deinit(self: *TextEditor, gpa: Allocator) void;

    pub const Outcome = struct { changed: bool, submitted: bool, selection_changed: bool };
};
```

- **Offsets** are UTF-8 byte offsets on grapheme boundaries. UTF-16 appears only at the macOS
  IME edge, converted by the platform. Gio uses rune offsets plus an index, which fabrum doesn't
  need, because it stores UTF-8.
- **Two kinds of text input.** Edits arrive as `TextInput` messages, separate from `KeyEvent`, as
  Gio separates `EditEvent` from `key.Event`:

```zig
pub const TextInput = union(enum) {
    insert: []const u8,                                    // typed or committed by the IME
    set_marked: struct { text: []const u8, selected: Range, replace: ?Range },
    unmark,
    replace: struct { range: Range, text: []const u8 },   // IME reconversion, autocorrect
    select: struct { range: Range, granularity: enum { char, word, line } }, // pointer and IME
    command: TextCommand,                                  // move, delete, newline, select_all, ...
    paste: []const u8,
    copy, cut,
};

pub const TextCommand = union(enum) {
    move: struct { by: Unit, direction: Direction, extend: bool },   // Unit: char, word, line, line_edge, page, document
    delete: struct { by: Unit, direction: Direction },
    insert_newline, insert_tab, select_all, cancel,
};
```

**Who turns keys into commands?**

- **macOS:** the platform does. `interpretKeyEvents:` calls `doCommandBySelector:` with
  `moveWordLeft:`, `deleteBackward:`, `moveToBeginningOfLine:` and so on, which honours the
  user's key bindings. The shell maps those selectors to `TextCommand`.
- **Other platforms:** a default keymap in `fabrum.app` does the same from `KeyEvent`s.
- **Either way,** `update` only ever sees `TextCommand`s.

**Pointer selection.** Pointer presses and drags on an editor become `.select` inputs:

- The runtime computes the text offset under the pointer from the last frame's text content and
  box (see Layout below).
- It honours the click count: double-click selects a word, triple-click a line.
- `update` therefore never needs geometry.

**Kitchen line editor:**

```zig
pub const State = struct {
    heading: std.ArrayList(u8),          // owned; was a literal in the first screen
    line: app.TextEditor = .{},
    notes: app.TextEditor = .{},
    pub fn deinit(...) ...
};
pub const Msg = union(enum) { line: app.TextInput, notes: app.TextInput, ... };

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Kitchen)) !void {
    switch (msg) {
        .line => |input| {
            const outcome = try state.line.apply(ctx.gpa, input, .{ .single_line = true, .submit = true });
            if (outcome.submitted) {
                state.heading.clearRetainingCapacity();
                try state.heading.appendSlice(ctx.gpa, state.line.text.items);
                try state.line.setText(ctx.gpa, "");
            }
        },
        .notes => |input| _ = try state.notes.apply(ctx.gpa, input, .{}),
        ...
    }
}

// view
try app.widgets.textField(ui, "line", &state.line, .{
    .on_input = on.handler(.line),
    .style = theme.font(.body, theme.foreground).with(.{ .slant = .italic }),
    .hint = "Hint",
    .single_line = true,
});
try app.widgets.textArea(ui, "notes", &state.notes, .{ .on_input = on.handler(.notes), .max_height = 200, .hint = "Hint" });
```

**`update` would return `!void`.** `apply` allocates, and the user wants errors explicit, so
`update` should be allowed to return `!void`. The runtime would return the error from the
`frame`/`mouse`/`key` call that delivered the message, as `Update.emit` does today with its
deferred error. This changes the component contract: a `void` `update` stays valid, and `!void`
becomes allowed. It is an open question (§14).

**A convenience wrapper.** An uncontrolled wrapper component with `on_submit` and
`clear_on_submit` can come later on top of this. It isn't the primitive.

### Read-only selection

The heading is selectable text. Its selection is interaction state, so it lives in the runtime,
keyed by element ID, like focus:

```zig
try ui.selectableText("heading", state.heading.items, theme.font(.h3, theme.foreground));
```

- Drag and multi-click select, through §5.
- Cmd-C copies through the clipboard command.
- Nothing reaches `update`. An optional `on_select` handler can be added if an app ever needs it.

### Layout: text geometry and decorations

Plain functions on `layout.text.Content`, using the same line breaking as drawing:

```zig
pub fn caretRect(self: *const Self, width: f32, offset: usize) !Rect;     // relative to the content box
pub fn offsetAt(self: *const Self, width: f32, point: Vec2) !usize;       // nearest grapheme boundary
pub fn selectionRects(self: *const Self, width: f32, range: Range, out: []Rect) ![]Rect; // one per line
```

They measure prefixes of a line with the text context, so they work with any renderer's
measurement. Each line's prefix widths are cached for the frame.

Text content gets optional **decorations**:

- `selection: ?Range` and `selection_color`;
- `caret: ?usize` and `caret_color`, null while the caret blinks off;
- `composition: ?Range`, drawn underlined.

The render command iterator emits them as **plain rectangle commands**:

- selection rectangles *before* the text;
- the caret and the composition underline *after* it.

Renderers therefore need no change. They are emitted after layout, when the width is known.

### IME (macOS: `NSTextInputClient` in the shell's view)

- **Why a mirror.** The IME asks questions synchronously: `markedRange`, `selectedRange`,
  `attributedSubstringForProposedRange:`, `firstRectForCharacterRange:` and
  `characterIndexForPoint:`. The app's state only changes a message later. So the runtime keeps
  a **mirror** of the focused text input.
- **What the view publishes.** `textField`/`textArea` publish this every frame through the
  element's `focus.on_text`:
  - the text, or for big documents a window around the selection;
  - the selection and the composition;
  - the caret rectangle in window coordinates, transform included.
- **Answering and applying.** The platform answers the IME from the mirror. It applies each
  `TextInput` to the mirror optimistically while queueing it as a message, as Gio's
  `editorState.Replace` does. The next frame then overwrites the mirror with the real state.
- **Cancelling composition.** The runtime calls the platform's "discard marked text" when the
  app changes the text or selection itself, for example `setText("")` on submit.
- **`keyDown:`** goes to `interpretKeyEvents:`. That results in:
  - `insertText:` → `.insert`;
  - `setMarkedText:` → `.set_marked`;
  - `doCommandBySelector:` → `.command` when a text input is focused, else a `KeyEvent`.

  `Runtime.key` still sees the raw `KeyEvent` first, for shortcuts and the `keys` filter.
- **Unimplemented queries.** Unlike Gio, which returns `NSNotFound` for
  `characterIndexForPoint:`, fabrum can implement it with `offsetAt`.

### Clipboard

`update` uses commands:

- `ctx.clipboard.write(text)` copies;
- `ctx.clipboard.read(on.handler(.pasted))` reads asynchronously, which Wayland requires. On
  macOS the platform answers at once.

The editor handles copy, cut and paste itself: it asks the runtime to write its selection, and a
paste arrives as `.paste`. So editors need no app code for the clipboard.

### Caret blink

The runtime owns the blink phase of the focused editor:

- The caret is visible for 0.5 s and hidden for 0.5 s, restarted by any input.
- It stops after 10 s idle, as Gio's does, which saves frames.
- It sets the content's `caret` decoration and schedules a wake at the next flip (§8).

No messages are involved.

### Gaps

- **Grapheme segmentation.** `std` has none. Options:
  - start with code points plus combining marks;
  - or generate a compact table from Unicode's `GraphemeBreakProperty`.

  This is an open question.
- **Bidi** and ligature-aware caret positions are out of scope. Lines are measured as left to
  right runs.

## 8. Animation and timed frames

- **Time.** `Runtime.frame` takes the frame time, so that tests control it:
  `frame(Root, props, viewport, now: Io.Timestamp)`. Alternatively the runtime reads the clock
  from its `Io` and the harness substitutes it. Views and updates read it with `ui.now()` and
  `ctx.now()`. Animation is a function of `now`, never of frame counts.
- **Visual animation needs no messages.** A view that animates calls `ui.animate()` to get
  another frame as soon as the display can show one. Requests are reset every frame, so a view
  that stops calling it stops animating. This is Gio's `InvalidateCmd{}`.

```zig
// spinner
const turn = @mod(ui.seconds(), 1.0);
try widgets.spinner(ui, "spinner", turn);
ui.animate();
```

- **Timers are subscriptions.** Logical time, such as the Kitchen's progress tick, uses
  subscriptions declared by views. They last while they are rendered, like Elm's
  `subscriptions`:

```zig
try ui.every("progress", .fromSeconds(1), on.bind(.tick));   // keyed: re-declaring keeps the phase
try ui.after("toast", .fromSeconds(3), on.bind(.hide_toast)); // one-shot, cancelled if not re-declared
```

- **Scheduling the next frame.** After each frame the runtime computes `nextFrame(): ?Timestamp`,
  the earliest of:
  - now, if something called `animate()` or a fling or caret is moving;
  - the timer deadlines;
  - the caret blink flip.

  The platform turns that into display-link frames or a one-shot timer (§11).
- **Kitchen "Transform".** The checkbox sets `state.transform_since = ctx.now()`. The view
  computes the rotation, scale and offset from `ui.now() - since`, applies them as a container
  transform (§9), and calls `ui.animate()` while it moves.
- **Testing** advances a fake clock (§12).

## 9. Drawing gaps: gradients, transforms, arcs, italics

These are mostly renderer and layout work, needed to finish the Kitchen.

- **Gradients.** Change `background_color: Color` to a `background: Fill`, with `.color`,
  `.linear` (two points in unit coordinates, two or more stops) and later `.radial`. Keep
  `background_color` as shorthand. The rectangle command carries the `Fill`. Quartz draws it with
  `CGContextDrawLinearGradient`, clipped to the rounded rectangle.
- **Transforms.** Add `ContainerDeclaration.transform: ?Affine` (`fabrum.Affine`: 2×3, with
  `rotate`, `scale`, `translate` and `invert`).
  - It is applied at paint time and doesn't affect layout, like CSS transforms.
  - The iterator wraps the subtree in `transform_push` and `transform_pop` commands. Quartz uses
    save, `CGContextConcatCTM` and restore.
  - The app's hit-testing maps the pointer through the inverse of each ancestor's transform
    before testing that ancestor's box, as Gio does.
  - `Pointer.local` is delivered in the element's own, untransformed, space.
  - The IME caret rectangle includes the transform.
- **Arcs.** The progress circle and spinner need a stroked arc. Options:
  - a small vector content in `layout`, `layout.Path`, built from move, line, arc and close, with
    fill and stroke, which every renderer draws;
  - or an `arc` render command.

  `Path` also covers the switch's shadow and future charts. Quartz's SVG `Picture` already
  builds `CGPath`s, so the work is mostly plumbing.
- **Italic.** Add `text.Style.slant: enum { normal, italic }`, part of the measurement cache key.
  Quartz asks Core Text for the italic trait.

## 10. Disabled state

The Kitchen does this today with an app-level context (`theme.Disabled`). It works for the
whole page and for one button. Each widget has to check it itself, though, and it can't stop
the runtime routing keys or focus to a disabled element.

Proposal: a built-in, inherited disabled scope.

```zig
try ui.open(null, .{ .disabled = !state.switched });   // or ui.disable() inside an open container
```

Inside it, the runtime:

- drops `on_click`, `on_pointer`, `focus` and `scroll` handlers from the event tables;
- removes the elements from tab order;
- clears focus if the focused element becomes disabled.

The elements still paint, and still occlude hits so a disabled button doesn't click what's
under it. `ui.enabled()` tells widgets to draw greyed out. Unlike Gio, a disabled subtree can
still call `ui.animate()`; the spinner next to a disabled button shouldn't freeze.

## 11. fabrum.app.platform

**Decision (user):** the platform shells live in fabrum as `fabrum.app.platform`, not in a
separate package. Most targets have exactly one native platform, so there is nothing to choose.
Renderers stay in separate packages, because their dependencies vary widely, while shells use
only the OS SDK.

### Level: the lowest window-and-input layer guaranteed to be present

| Target | Layer used | Not used |
|---|---|---|
| macOS | AppKit's `NSApplication`, `NSWindow`, `NSView` (+ `NSTextInputClient`), Core Graphics surface, `CADisplayLink`/`CVDisplayLink` | AppKit widgets |
| Windows | Win32 `HWND`, the message loop, IMM32/TSF, `WM_*` input | WinUI, WPF |
| Browser (later) | a `<canvas>` and DOM events, a hidden `<textarea>` for IME | a DOM widget tree |
| Linux | the **X11 and Wayland protocols** themselves | GTK, Qt |

fabrum draws its own widgets. A toolkit underneath would mean a second event loop and a second
widget tree, plus a dependency that an app must pick at build time. On macOS and Windows the
windowing layer also gives IME, clipboard, file dialogs, decorations and accessibility. On
Linux some of those sit outside X11 and Wayland, so the Linux backends use the desktop standards
for them:

| Service | macOS | Windows | Linux |
|---|---|---|---|
| IME | `NSTextInputClient` | IMM32 / TSF | `zwp_text_input_v3` (Wayland); XIM or IBus (X11) |
| Key to text | `interpretKeyEvents:` | `WM_CHAR` / `ToUnicode` | `libxkbcommon`, both backends |
| Clipboard, drag and drop | `NSPasteboard` | OLE clipboard | `wl_data_device` (async fds); X11 selections (`CLIPBOARD`, INCR) |
| Decorations | the window's | the window's | client-side on GNOME/Wayland, drawn by fabrum or through `libdecor`; server-side via `xdg-decoration` where offered; X11: the window manager |
| File dialogs, open URI, notifications | `NSOpenPanel` etc. | common dialogs | `xdg-desktop-portal` over D-Bus, with no toolkit needed |
| Accessibility (later) | `NSAccessibility` | UI Automation | AT-SPI over D-Bus |
| Frame pacing | `CADisplayLink` | DWM / `DwmFlush` or a timer | `wl_surface.frame` callbacks; X11: a timer, or Present |

**Accessibility isn't in scope, but the contract mustn't rule it out.** Element IDs are already
stable per (instance, key). Those are exactly the node identities that AT-SPI,
`NSAccessibility` and UIA need. A later accessibility tree is the last frame's units plus roles
and labels, which could be new `Container` fields.

### Namespace shape

```
fabrum.app.platform
├── native        // the target's platform: macos on macOS, linux on Linux, windows on Windows;
│                 // a struct of @compileError decls on targets without one (wasm, freestanding)
├── macos         // AppKit (shell.m today; see "Objective-C" below)
├── linux         // X11 and Wayland, chosen at run time
├── windows       // later
├── Options, Host, Surface, Automation   // the platform-neutral contract below
└── run           // the high-level entry point
```

### The platform-neutral contract

Every shell implements the same contract. The Kitchen's `src/platform/macos.zig` is its first
draft.

**Window**

- `Options{ title, size, min_size, resizable, appearance }`.
- `run(options, host) noreturn`: owns the event loop, which `[NSApp run]` requires on macOS, and
  calls `host.will_terminate` before exiting. One window for now. Multiple windows mean a host
  per window, and the contract keeps `Host` per window so as not to rule that out.

**Drawing surface**

- `host.draw(surface: Surface, size: Vec2 (points), scale: f32)`, where `Surface` is a tagged
  union of opaque handles:

```zig
pub const Surface = union(enum) {
    core_graphics: *anyopaque,                          // CGContextRef, origin bottom-left
    metal_layer: *anyopaque,                            // CAMetalLayer
    win32: struct { hwnd: *anyopaque, hdc: ?*anyopaque },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    x11: struct { display: *anyopaque, window: u64 },
    pixels: struct { data: []u8, stride: usize, size: [2]u32 }, // software fallback, e.g. wl_shm
};
```

- Renderers depend on fabrum already, so a renderer adds
  `fn draw(self, commands, surface: fabrum.app.platform.Surface) !void` and takes the tags it
  supports. For example Quartz takes `.core_graphics`, ThorVG takes `.pixels`. fabrum never
  imports a renderer.

**Input in**

- `Runtime.mouse(MouseEvent)` (today).
- `Runtime.scroll(ScrollEvent)`.
- `Runtime.key(KeyEvent) bool`, which returns whether it was handled.
- `Runtime.text(TextInput)`.
- `Runtime.windowFocus(bool)`, which cancels pointer gestures and hides the caret.

**Answers out**

- `Runtime.cursor()` (today).
- `Runtime.textInputState() ?TextInputState`: the IME mirror (§7).
- `Runtime.nextFrame() ?Timestamp`.

**Services the shell provides to the runtime, through `app.Platform`'s vtable** (today only
`requestFrame`):

- `requestFrame` (thread-safe);
- `setAnimating(bool)`, which turns the display link on and off;
- `wakeAt(?Timestamp)`;
- `setCursor`;
- `clipboardWrite(text)` and `clipboardRead(callback)`;
- `imeDiscardMarkedText`, `imeCaretMoved`;
- `runOnMain`.

**Automation, for debug scripts and tests**

- `snapshot(path, scale)`;
- `synthesizeClick(point)`, already used for `nsclick=`;
- later `synthesizeKey` and `synthesizeText` through the same native paths
  (`[NSWindow sendEvent:]`, `interpretKeyEvents:`).

None of these posts system input.

**Out of the neutral contract, deliberately**

- File dialogs and alerts. OpenEtcher's `chooseFile` and quit confirmation become per-OS
  extras, `platform.macos.chooseFile` and `platform.macos.confirm`, until a portal-based Linux
  version justifies a neutral `platform.dialogs`.
- Menus. Same as dialogs.

### Starting an app

There are two levels. The **low-level** one is what OpenEtcher and the Kitchen do today: the app
owns its `Runtime` and renderer, and hands the shell a `Host` of callbacks. The **high-level**
one is generic over the renderer type, which the app passes in, so fabrum doesn't import it:

```zig
pub fn main(init: std.process.Init) !void {
    var icons: Icons = try .init(init.gpa);
    defer icons.deinit();
    const interface = icons.interface();
    try fabrum.app.platform.run(Kitchen, .{}, Quartz, init, .{
        .title = "Kitchen",
        .size = .init(800, 700),
        .provide = &.{.of(&interface)},
    });
}
```

`Renderer` is duck-typed:

- `Renderer.Text` is the `Runtime`'s `Config.Text`;
- `Renderer.init(gpa)` and `deinit`;
- `renderer.text_context`;
- `renderer.draw(*RenderCommand.Iterator, Surface)`.

`platform.run`:

- builds `Runtime(.{ .Text = Renderer.Text })` with `.platform` set to the shell;
- feeds input, cursor and frame scheduling as the Kitchen's `main.zig` does by hand;
- runs a debug script from an environment variable, which moves from the Kitchen into fabrum and
  is named in options.

### Build: a `platform` dependency option, on by default (user decision)

```zig
// fabrum/build.zig
const platform = b.option(bool, "platform", "Include fabrum.app.platform, the native window shell (default: true)") orelse true;
const linux_x11 = b.option(bool, "platform-x11", "Linux: include the X11 backend (default: true)") orelse true;
const linux_wayland = b.option(bool, "platform-wayland", "Linux: include the Wayland backend (default: true)") orelse true;
```

| Target | `platform = true` adds to the `fabrum` module | `platform = false` |
|---|---|---|
| macOS | `src/app/platform/macos/shell.m` (`-fobjc-arc`), frameworks AppKit, QuartzCore (display link, layers) | nothing |
| Linux | `link_libc = true` for `dlopen`; nothing linked: libwayland-client, libxkbcommon, libX11/libXi/libXcursor and libdecor are opened at run time with `std.DynLib` | nothing |
| Windows | system libraries user32, gdi32, imm32, dwmapi (always present) | nothing |
| others | nothing; `platform.native` is the error stub | nothing |

**When the option is off,** `fabrum.app.platform` still exists, but every declaration is a
`@compileError`:

> fabrum.app.platform is off: this fabrum dependency was added with `.platform = false`. Remove
> that option (it defaults to true) to open windows.

Zig analyses declarations lazily, so a layout-only program that never mentions it compiles
cleanly. A missing namespace would give a vaguer error.

**How dependents declare it**

- **Kitchen and OpenEtcher's GUI:** they take the default, and pass nothing:

  ```zig
  const fabrum_dep = b.dependency("fabrum", .{ .target = target, .optimize = optimize });
  ```

  OpenEtcher already requests fabrum only when building its macOS GUI, so its cross-platform CLI
  never instantiates it.
- **A layout-only user:**

  ```zig
  b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = false })
  ```

**Hazard, verified on 0.17 with a prototype.** Zig keys a dependency's instance on the arguments
*as passed*, not on the resulting option values. If the app passes `.platform = false`, or even
`.platform = true` explicitly, while a renderer it also depends on asks for fabrum with only
`.{ .target, .optimize }`, the build gets two fabrum module instances and fails:

```
error: file exists in modules 'lib' and 'lib0'
```

Mitigations:

- **(a) Renderers forward the option, but only when it is set:**

  ```zig
  if (b.option(bool, "platform", "...")) |p| b.dependency("fabrum", .{ ..., .platform = p })
  else b.dependency("fabrum", .{ ... })
  ```

  A layout-only app then passes `.platform = false` to both fabrum and the renderer.
- **(b) Apps never pass `.platform = true` explicitly.**

(a) and (b) are cheap, but every package between the app and fabrum must follow them.

The alternative that avoids the hazard entirely is a single fabrum instance that exports a
second module, or an `addPlatform(module)` helper from fabrum's `build.zig`. That keeps one
instance whatever the app wants. It's listed in §14 in case the hazard proves annoying.

**Two findings from prototyping the Phase A "pay only when used" question, now dropped, kept
for the record:**

- On 0.17, `extern "AppKit"` / `extern "objc"` library names do **not** link anything on macOS.
  The symbols stay undefined unless the build links them.
- `dlopen`ing libobjc and AppKit from Zig works, and leaves no load commands in programs that
  don't use them.

### Objective-C: keep `shell.m`

Writing the AppKit shell in Zig against the Objective-C runtime is possible: `objc_msgSend`,
`objc_allocateClassPair` and `class_addMethod`, as zig-objc does. On its own merits it isn't
worth it now:

- `NSTextInputClient` alone is about a dozen methods with struct arguments and returns (`NSRange`,
  `NSRect`), which are error-prone through `objc_msgSend`. x86_64 needs `objc_msgSend_stret` too.
- ARC and blocks (`dispatch_async`) come free in `.m`.

Recommendation: keep `shell.m` with a narrow C ABI, as today, and revisit if a pure-Zig build
(no clang for Objective-C) becomes a goal.

### Linux: X11 and Wayland in one binary, chosen at run time (user decision)

Follow SDL, GLFW 3.4 and winit:

- **Both backends in `platform.linux`.** Their client libraries are opened at run time with
  `std.DynLib`, so one binary runs on either kind of session and needs only the libraries of the
  session it runs in. A missing library fails `run` with a clear error naming it.
- **Selection.**
  - `FABRUM_PLATFORM=x11|wayland` overrides everything.
  - Otherwise it is Wayland if `WAYLAND_DISPLAY` is set (and the connection succeeds).
  - Otherwise X11 through `DISPLAY`.
  - Otherwise an error.
- **Build options** `platform-x11` and `platform-wayland` exclude either backend.
- **Wayland notes.**
  - `xdg-shell`. GNOME has no server-side decorations, so fabrum draws a title bar, or uses
    `libdecor` when present. `xdg-decoration` is used where the compositor offers it.
  - Keys through `libxkbcommon`, with the keymap from `wl_keyboard`.
  - IME through `zwp_text_input_v3`.
  - The clipboard is async: `wl_data_offer.receive` into a pipe. That is why the contract's read
    takes a callback.
  - Frames paced by `wl_surface.frame`.
  - Fractional scaling through `wp_fractional_scale_v1`.
- **X11 notes.**
  - XInput2 for smooth scrolling.
  - XIM, or IBus over D-Bus, for IME.
  - `libxkbcommon-x11` for keys.
  - Selections for the clipboard, including INCR for large data.
  - No compositor-paced frames, so a timer or the Present extension.
- **Out of scope.** Qt and GTK are not part of `fabrum.app.platform`. If Linux IME or
  accessibility coverage becomes urgent, a GTK-*hosted* backend, like Flutter's Linux embedding,
  can be added behind the same contract. Nothing in the contract assumes it owns the event loop
  beyond `run`, or a raw protocol beyond what `Surface` names.

### Moving the Kitchen's copy into fabrum (Phase B)

1. `git mv` the files:
   - `src/platform.zig` → `src/app/platform.zig`;
   - `src/platform/macos.zig` → `src/app/platform/macos.zig`;
   - `src/platform/macos/shell.m` → `src/app/platform/macos/shell.m`.

   Change one import, `@import("fabrum").app` → `@import("../../app.zig")`. Add
   `pub const platform = ...` to `app.zig`, behind the option.
2. In fabrum's `build.zig`, add the option and, on macOS, the `.m` and frameworks to the `fabrum`
   module, as the Kitchen's `addMacosPlatform` does.
3. In the Kitchen:
   - delete `src/platform*` and the `fabrum-platform` module;
   - import `fabrum.app.platform.macos`;
   - move `script.zig`'s generic parts (the step parser, `findText`, `snapshot`) into the
     platform's `Automation` as they settle.
4. In OpenEtcher's GUI:
   - delete `src/app/platform/macos/`;
   - use `fabrum.app.platform.macos`;
   - keep its file picker and quit confirmation as app code, or as `platform.macos.chooseFile` /
     `confirm` extras. The shell then needs two generic hooks it lacks today: `should_close`, so
     the app can veto a close or quit, and a way to show a sheet or alert.
   - Its renderer and Quartz dependency are unchanged.

## 12. Testing without a window

`app.testing.Harness` drives the runtime's own entry points: `click`, `hover`, `clickAt`, `moveTo`
and `leave`, plus element lookups through `root().one(C).element(key)`. Each new input gets the
same treatment: one helper per platform-neutral entry point, then a frame.

```zig
// keys and text
pub fn press(self: *Self, key: Key, modifiers: Modifiers) !void;   // press + release through Runtime.key
pub fn type_(self: *Self, text: []const u8) !void;                 // one .insert per grapheme, as a keyboard would
pub fn compose(self: *Self, marked: []const u8, commit: ?[]const u8) !void; // IME: set_marked ..., then insert
pub fn command(self: *Self, cmd: app.TextCommand) !void;           // what macOS's selectors produce
pub fn focusedElement(self: *Self) ?layout.Unit.Id;
pub fn expectFocused(self: *Self, id: layout.Unit.Id) !void;

// scrolling
pub fn scroll(self: *Self, at: []const u8, delta: Vec2) !void;     // wheel over a text
pub fn scrollElement(self: *Self, id: layout.Unit.Id, delta: Vec2) !void;
pub fn scrollInfo(self: *Self, id: layout.Unit.Id) ?app.ScrollInfo;
pub fn scrollIntoViewOf(self: *Self, string: []const u8) !void;   // scrolls until the text is inside every clip, or fails

// dragging
pub fn drag(self: *Self, from: Vec2, to: Vec2, steps: usize) !void;    // press, `steps` moves, release
pub fn dragElement(self: *Self, id: layout.Unit.Id, to: Vec2) !void;

// time
pub fn advance(self: *Self, by: std.Io.Duration) !void;   // moves the fake clock, fires due timers, runs a frame
pub fn animating(self: *Self) bool;                        // whether the last frame asked for another

// clipboard
pub var clipboard: []const u8;                             // a fake platform clipboard the harness owns
```

Visibility needs care with scrolling. "Clicking a text" has to mean clicking where it is
*visible*. `click` should fail with a clear message when the text is entirely clipped away,
instead of clicking a point that hit-tests elsewhere.

**Kitchen tests for Phase B, one per feature:**

- **Scrolling.**
  - `scroll("RadioButton1", .init(0, 400))` moves the page, and `scrollInfo` clamps at the end.
  - Scrolling over the 200-point editor scrolls the editor first, then chains to the page at its
    end.
  - A `.began` gesture stays latched.
  - Dragging the scrollbar thumb by half the track scrolls half the content.
- **Keys and focus.**
  - Clicking the line editor focuses it.
  - `type_("Hi")` and `press(.enter, .{})` change the heading to "Hi" and clear the editor.
  - Tab moves focus from editor to editor, and Shift-Tab back.
  - Space on a focused radio selects it.
- **Text.**
  - Double-clicking a word selects it.
  - `Cmd-C` puts the selection in the fake clipboard.
  - `compose("に", "日本")` leaves "日本" and no composition.
  - `command(.{ .move = .{ .by = .word, ... } })` lands on word boundaries.
  - Undo restores the text.
- **Dragging.**
  - Dragging the slider from its left edge to 3/4 of its width shows "0.75".
  - Dragging past the end clamps at "1.00".
  - Losing window focus mid-drag sends `.cancel`.
- **Animation.**
  - `advance(1s)` ×3 moves the progress from 0 to 0.3.
  - With the switch on, `animating()` is true and the spinner's angle changes with `advance`.
  - The caret is hidden after `advance(500ms)` and stops blinking after 10 s.
- **Transforms.** With Transform on and the clock advanced, clicking the *transformed* position
  of "Click me!" toggles it, and its untransformed position doesn't.

The GUI keeps `KITCHEN_SCRIPT` for real-window checks while the Mac is locked:

- `key=`, `type=` and `scroll=` steps go through the shell's native paths (`sendEvent:` with
  synthesized `NSEvent`s, and `interpretKeyEvents:`), never through system input posting;
- `snapshot=` captures the result.

Shell-level unit tests for the UTF-16 ↔ UTF-8 range conversion run without a window.

## 13. Over-fitting: what OpenEtcher taught fabrum, revisited

| OpenEtcher-driven choice | Holds for the Kitchen? |
|---|---|
| **Hit-testing**: topmost unit in paint order; every clipping ancestor checked | **Holds**, and is better than Clay, which only checks the nearest clip. Needs: inverse transforms (§9); scroll thumbs and floating overlays already work as later siblings. `FloatingConfig.pointer_passthrough` (declared, unimplemented) becomes needed for decorative overlays such as the editor's hint text over its field |
| **Hover** = the hit element plus its keyed ancestors | **Holds.** Read-only selection and focus rings reuse the same chain |
| **Clicks**: press and release on the same clickable; bubbling to the nearest `on_click` | **Holds for mouse buttons.** Needs: capture for drags (§5), cancellation, click counts (double-click selects a word), and keyboard activation (Space/Enter on release). Today a press that leaves and comes back still clicks on release; with capture it stays the same, which matches AppKit buttons |
| **Element keys** scoped per instance, hashed to 32 bits | **Holds** and becomes more important: focus, scroll offsets and read-only selection are keyed by element ID. A 32-bit collision now swaps focus or scroll between two elements in one frame, which is rare but worse than a misdirected hover. Consider widening `Unit.id` to 64 bits when layout IDs next change |
| **`DuplicateKey` errors** | **Holds.** Interaction state keyed by element makes duplicate keys worse, so the error is right |
| **Contexts** looked up by type; values scoped to the open container | **Holds.** The Kitchen's `Disabled` scope is exactly this rule: provided inside a container, it ends with it. The same goes for a scrollbar style, a text-selection color and an editor theme. A rule to revisit: "values given to `ui.provide` must live until the next frame". A `*const` to a decl works (`&theme.Disabled.on`), but a computed value needs `ui.arena()`. A `ui.provideValue(T, value)` that copies into the arena would remove a footgun |
| **Components can't take children**: no slot or content props | **Doesn't hold.** Gio passes widgets as closures; the Kitchen's list and borders wrap arbitrary content. View helpers that `open` and return (as `item(ui)` / `row(ui)` do here) cover it today, and runtime-owned scroll avoids needing a `Scroll` component that wraps children. A stateful wrapper with children, such as a collapsible section, would need a `content: app.View` prop (a pointer and function pair rendered inside). An open question |
| **`update` returns `void`**; errors deferred through `emit` | **Strained** by editors that allocate. See §7 and §14 |
| **Messages only from clicks and `Poster`** | **Generalises** to `on_pointer`, `focus.on_key`, `focus.on_text`, `on_scroll`, timers, the clipboard, and runtime-generated payloads. Today's ownership rule, that a payload passed to the runtime belongs to the message, already covers them |
| **`Runtime.mouse` + `needsFrame`**, pull-based frames | **Holds**, extended with `nextFrame()` for timed frames. "Dirty after any delivered message" stays |
| **Cursor**: `default` or `pointer` from clickability | **Too narrow.** Needs `text`, `grab`, `grabbing` and per-element override |
| **Dark window and transparent title bar in the shell** | Belonged to OpenEtcher. Now `Options.dark`; the title bar style is a per-app option |
| **Text style**: weight, size, overflow, no slant | Needs `slant` (§9) |
| **`percent` sizing** | Bug, as shown in §1 |

## 14. Risks and open questions

**Decisions for the user**

1. **Scroll offsets owned by the runtime (proposed), or by component State?** Runtime-owned is
   uncontrolled, like the DOM:
   - no boilerplate;
   - synchronous chaining and latching;
   - momentum without a message per frame.

   Apps change it through `ctx.scrollTo`. The alternative, a `Scroll` state in the app's model,
   is more "pure" but needs a message per wheel tick and per momentum frame, and needs components
   that take children.
2. **Editable text controlled, in the parent's State through `app.TextEditor` (proposed), or a
   self-contained editor component?** Controlled text lets the parent set and clear text and
   validate input. It costs one `Msg` tag and one `apply` call per field.
3. **May `update` return `!void`?** Editors allocate in `update`. The alternative keeps `void`
   and defers errors, as `emit` does now, which hides them, against the user's stated rule.
4. **Built-in disabled scope (§10), or keep it an app context as the Kitchen does now?**
5. **Default focus on click for buttons:** off, as on macOS, or on, as on Windows and the web?
6. **Built-in scrollbar** drawn by the runtime, styled by context (proposed), or scrollbars
   always app-drawn from `ui.scrollInfo`?
7. **Grapheme segmentation:** code points plus combining marks first, or a generated Unicode
   table now?
8. **Timers as view subscriptions (`ui.every`) (proposed), or commands from `update`
   (`ctx.after`)?** Subscriptions vanish with the view that declared them. Commands survive
   until they fire.
9. **Build-option hazard (§11):** accept the "forward only when set" rule for renderers, or
   switch to an `addPlatform` helper or a second module, keeping one fabrum instance?
10. **Children for components:** add an `app.View` content prop now, or wait until a widget
    needs one?

**Where Gio and Clay don't translate**

- **Gio** drains events *during* layout, through `gtx.Event`, using widget-state pointers as
  tags.
  - fabrum's views are pure and its state moves on messages, so events are routed by element ID
    *before* views run, from the last frame's declarations. That leaves one frame of staleness:
    a filter or a scroll range declared this frame applies to the next input. Gio has the same
    lag.
  - Focus changes and keystrokes in one input batch need Gio's "deferred replay": process the
    focus change, then route the following keys to the new focus. fabrum gets this by handling
    each event to completion, including messages, before the next.
- **Gio's `Editor`** mutates itself during layout (`Update` loops). fabrum splits it: geometry
  queries in `layout`, the model in `app.TextEditor`, and the IME mirror in the runtime.
- **Clay** keeps scroll data in a global array and matches containers by element *pointer* from
  the previous frame, which breaks when siblings are inserted. It decays momentum per frame
  rather than per second, and doesn't chain scrolls. fabrum keys by hashed element ID, decays
  over time, and chains.
- **Clay's `onHover` callbacks** fire during `SetPointerState`. In fabrum, hover stays a query
  (`ui.hovered`) and events become messages.

**Risks**

- **The IME mirror** is the riskiest piece. AppKit's expectations are underspecified:
  - ranges in UTF-16;
  - `replacementRange` relative to the marked text;
  - `firstRect` in screen coordinates.

  Mitigation: implement it against Japanese (Kotoeri) and Pinyin early in Phase B, with shell
  unit tests for the range conversion.
- **Text geometry by prefix measurement** costs O(n) measurements per line. Mitigations: cache
  prefix widths per line per frame, and let Quartz measure a whole line once with `CTLine` and
  return every glyph's offset. That would be a renderer-provided fast path behind
  `Context.measureOffsets`, if available.
- **One-frame staleness** of `ScrollInfo` and the scrollbar when content changes. It converges
  on the next frame, which the runtime requests. It is visible only as a one-frame thumb jump.
- **The renderer contract grows** with fills, transforms, paths and decorations. Each needs a
  Quartz implementation and a ThorVG one, or a documented fallback.
- **Dependency arguments** must stay identical across packages (§11). Zig fails the build
  otherwise.

## 15. Phase B plan

Each step lands in fabrum with its own tests, then unlocks Kitchen widgets with tests in this
repo. The order puts the layout-only and runtime-only work before the platform work, so most of
it is testable without a window.

| Step | fabrum (layout / app / platform), renderers | Kitchen unlocked | Tests |
|---|---|---|---|
| 0 | Fix `percent` under `grow` (layout) | Progress bar shows 0.3 correctly | layout unit test; Kitchen fill width = 0.3 × track |
| 1 | Move the shell into `fabrum.app.platform` (git mv, `platform` option, `@compileError` stub); port the Kitchen and OpenEtcher | — | fabrum `zig build test` with `-Dplatform=false`; both apps build; scripted snapshots unchanged |
| 2 | **Time and frames:** `now` in `frame`, `ui.now`/`ctx.now`, `ui.animate`, `ui.every`/`ui.after`, `Runtime.nextFrame`; `Platform.setAnimating`/`wakeAt`; macOS `CADisplayLink` + timer; harness `advance`/`animating` | Progress ticks every second; spinner and Transform can animate once drawn | Harness: timers fire on `advance`; `animating()` only while requested; tick wraps at 1 |
| 3 | **Drawing:** `layout.Path` (arcs) + Quartz; `Fill.linear` + Quartz; `text.Style.slant` + Quartz; `transform` push/pop + Quartz; hit-testing through transforms | Progress circle, spinner, gradient strip, italic text, Transform rotating the page | layout: command order and fills; app: clicking through a rotated container; snapshots |
| 4 | **Dragging:** `on_pointer`, capture, slop, cancel, click counts; `Runtime.windowFocus`; cursors | Slider and its value | Harness `drag`: 0.75, clamping, cancel on focus loss |
| 5 | **Scrolling:** `Unit.content_size`, clipped-axis sizing, culling (layout); `scroll` option, offsets by ID, `Runtime.scroll` with chaining, latching and fling, `ScrollInfo`, `ctx.scrollTo`/`scrollIntoView`, built-in scrollbar (app); macOS phases and momentum (shell) | The page scrolls, with a scrollbar and a draggable thumb | Harness `scroll`/`scrollInfo`: clamping, chaining, latching, thumb drag; layout content-size tests |
| 6 | **Keys and focus:** `focus`, `KeyEvent`, `Runtime.key` returning handled, Tab order, shortcuts, Space/Enter activation, focus rings; macOS `keyDown:`/`flagsChanged:` | Radio buttons and buttons by keyboard; focus rings | Harness `press`, `expectFocused`: Tab cycle, activation on release, unhandled keys return false |
| 7 | **Text geometry:** `caretRect`, `offsetAt`, `selectionRects`, text decorations as rectangle commands (layout) | — | layout unit tests over `HeuristicContent` and Quartz text |
| 8 | **Text editing:** `app.TextEditor`, `TextInput`/`TextCommand`, default keymap, `textField`/`textArea` widgets, blink, clipboard commands, `update` returning `!void` (if agreed) | Line editor sets the heading on Enter; the 200-point notes editor scrolls to the caret | Harness `type_`, `press`, `command`, fake clipboard: submit, word moves, undo, copy and paste, caret blink |
| 9 | **IME:** runtime mirror, `textInputState`, macOS `NSTextInputClient` | Japanese and Chinese input in both editors | Harness `compose`; shell UTF-16 conversion tests; a scripted `type=` through `interpretKeyEvents:` |
| 10 | **Read-only selection:** `ui.selectableText` | Selectable heading, Cmd-C | Harness drag-select and double-click, fake clipboard |
| 11 | **Disabled scope** (if agreed) | `--disable` and the switch through fabrum instead of the app's context | Harness: no focus, keys, scroll or click inside disabled subtrees |

Linux (X11 and Wayland) and Windows shells come after Phase B, against the same contract.
