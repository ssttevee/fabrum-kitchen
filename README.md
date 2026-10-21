# fabrum-kitchen

The Kitchen is a demo app for [fabrum](https://github.com/ssttevee/fabrum):
one page with one of every kind of widget. It's a port of the Kitchen demo
from [Gio](https://gioui.org), another Go UI library, and the same screen
runs on all three of fabrum's platforms.

![The Kitchen on the none platform, drawn as an overlay over a background image](docs/images/overlay-initial.png)

It's useful in two ways:

- **To see what fabrum can do.** Buttons, checkboxes, switches, sliders,
  text editors, dropdowns, dialogs, menus, a file chooser, the clipboard,
  scrolling, dragging and animation are all on one screen. It's a good
  place to look for working code.
- **To test fabrum.** The Kitchen was written to push fabrum into building
  what it lacked, like scrolling, keyboard focus, text editing and dialogs.
  It also checks that fabrum's design holds up for a very different kind of
  app. [`docs/input-design.md`](docs/input-design.md) records that design
  work: what each Gio widget needed from fabrum, and what got built.

## Run it

You need **Zig 0.17.0**. `zig build` downloads fabrum and the renderers from
GitHub.

| Platform | Command | What you get |
|---|---|---|
| macOS (AppKit) | `zig build run` | A window with real macOS controls, laid out by fabrum |
| GTK 4 | `zig build run-gtk -Dplatform=gtk` | A window with GTK's controls. Needs GTK 4 and `pkg-config`. With Homebrew on macOS, put `/opt/homebrew/bin` first on your `PATH`. |
| No toolkit | `zig build run-none` | No window. A program plays a scripted session, draws each frame into memory, and saves PNGs. |

`zig build` puts the programs in `zig-out/bin`: `kitchen` on macOS,
`kitchen-gtk` with `-Dplatform=gtk`, and `kitchen-none`, which is always
built.

Both windowed versions take two flags after `--`:

- `--drawn` shows the version of the screen where fabrum draws every widget
  itself, instead of using native controls.
- `--disable` shows that drawn screen with every widget disabled, like Gio's
  `-disable` flag.

For example: `zig build run -- --drawn`.

## What's on the screen

The interface is in [`src/kitchen.zig`](src/kitchen.zig). It's written only
with fabrum's components and widgets, and knows nothing about windows or
renderers. That's why the same code runs everywhere. It comes in two
versions:

| File | What it is |
|---|---|
| `src/kitchen/Hybrid.zig` | The main screen, in fabrum's **hybrid** style. Standard controls are the platform's own: buttons, the progress bar, checkbox, switch, slider, text editors, dropdown, stepper, spinner, search and password fields, and a wrapping label. Between and on top of them sits content that fabrum draws: the heading, the "Flat" button, the radio buttons, clickable rows, and a modal dialog drawn over a native text field. A row of buttons uses the platform's services: a file chooser, the clipboard, a question dialog and a popup menu. The window also asks before closing while the line editor has text in it. On a platform with no native controls, fabrum draws every widget and the same screen is entirely drawn. |
| `src/kitchen/Kitchen.zig` | The same screen drawn entirely by fabrum, for comparison (`--drawn`). |
| `src/kitchen/theme.zig`, `src/kitchen/widgets.zig` | Gio's Material look (colors, fonts, icons, the disabled state) and the drawn widgets, modelled on Gio's. |

## The no-toolkit version: `kitchen-none`

Some places have no windows and no UI toolkit: an e-reader, a game drawing
an overlay, a remote desktop proxy. There, your own program has to run the
main loop, read the input and put pixels on the screen. fabrum calls that
program the **host**, and its `none` platform is the interface a host uses.

[`src/none.zig`](src/none.zig) is a host. It runs the Kitchen in two
modes:

- **Overlay**: full-color pixels drawn over a background image, the way a
  remote desktop proxy draws over the remote screen. The scripted input
  arrives the way a VNC client sends it: pointer moves, clicks, drags,
  scroll wheel and keys. Each step reports whether the app used the event
  or let it pass through to whatever is underneath.
- **E-ink** (`--eink`): an opaque 8-bit grayscale panel that behaves like
  an e-reader. It has a touch screen, no hover, no animation, 16 shades of
  gray, and an on-screen keyboard. Simple stand-ins answer the keyboard and
  dialogs. Each step reports which kind of screen refresh fabrum asked
  for. An e-ink screen has several (`interactive`, `content`, `page`),
  trading speed against quality.

`zig build run-none` plays the same script in both modes: hovering,
clicking, checking the checkbox, flipping the switch, typing and pressing
Enter, Tab and Space, writing notes, dragging the slider, scrolling the
page, clicking through to the background, and the dialog.

For each step it runs the frames that are due, collects the regions of the
screen that changed (fabrum calls these the **damage**), redraws only
those, and prints a row:

```
kitchen-none (overlay): z2d renderer, 800x700 rgba8_premultiplied, writing to /tmp/kitchen-snapshots/p2
step             taken regions    pixels    frame    render composite  refresh     next frame
initial              -       1    560000  14789us  115678us   16377us  content     when input comes
hover-green        yes       2      4680   1186us    2801us     182us  content     when input comes
...
drag-slider        yes      19     65489  20541us   14020us    1941us  interactive now
click-through       no       2     47631   3275us   18204us    1423us  content     now
every step: the redrawn damage matched a full redraw
```

How to read it: `taken` says whether the app used the event. `regions`
and `pixels` show how much was redrawn. `frame`, `render` and `composite`
are how long each stage took. `refresh` is the kind of screen update
requested, and `next frame` is when fabrum wants to draw again.

**It checks itself as it goes.** After every step, it also redraws the
whole screen from scratch and compares the pixels. If redrawing only the
damage gave a different picture, it fails with `error.DamageMissed`. That
tests fabrum's change tracking and the renderer together.

| | |
|---|---|
| ![Dragging the slider, with the damage outlined](docs/images/overlay-drag-slider-damage.png) | ![The e-ink panel after typing into the notes](docs/images/eink-type-notes.png) |
| Dragging the slider in overlay mode, with the redrawn regions outlined. Only the slider, its value, the progress bar and the spinner are redrawn. | The e-ink panel (grayscale, high-contrast theme) after the on-screen keyboard typed into the notes. |

### Options

Arguments go after `--`, for example
`zig build run-none -- --eink --out /tmp/eink`.

| Option | What it does |
|---|---|
| `--overlay`, `--eink` | Play only one mode. |
| `--out DIR` | Where to save snapshots (default `/tmp/kitchen-snapshots/p2`). |
| `--quiet` | Hide the per-step table. Everything still runs and is checked, and errors and benchmark output still print. |
| `--bench` | Time full redraws against partial ones. |

Snapshots: `NN-step.png` is the final frame, `NN-step-overlay.png` the
overlay alone, and `NN-step-damage.png` the frame with that step's redrawn
regions outlined. E-ink frames are saved as `eink-NN-step.png`.

### Choosing a renderer

A **renderer** turns fabrum's drawing commands into pixels. Pick one with
`-Drenderer`:

- **`z2d`** (default):
  [fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d).
  Pure Zig, and supports both modes.
- **`thorvg`**:
  [fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg).
  It can't draw grayscale, so use overlay mode:
  `zig build run-none -Drenderer=thorvg -- --overlay`.

The build passes the chosen renderer the Kitchen's own copy of fabrum,
because the renderer packages are designed to share the app's fabrum
instead of fetching their own.

### Cross-compiling

`kitchen-none` always uses fabrum's `none` platform, whatever `-Dplatform`
says, and links no OS UI library. So it builds for other systems from any
machine:

```sh
zig build -Dplatform=none -Dtarget=x86_64-linux-musl
zig build -Dplatform=none -Dtarget=x86_64-windows-gnu
zig build -Dplatform=none -Dtarget=arm-linux-gnueabi.2.38 -Dcpu=cortex_a7
```

The last one builds an ARM binary, not an app for an e-reader. To run
fabrum apps on a PocketBook, see
[fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview).

## Scripting the windowed versions

Debug builds of the windowed versions read a script from the
`KITCHEN_SCRIPT` environment variable and run it once the window is up.
That lets you check a screen without anyone at the keyboard. On macOS most
steps work even while the Mac is locked, because they talk to the app
directly instead of sending system input events.

Steps are separated by `;`. Native controls are named by their key, such as
`line` for the line editor:

```sh
KITCHEN_SCRIPT='type=line:Hello;tab;dump;snapshot=/tmp/a.png;quit' zig build run
```

Common steps:

| Step | What it does |
|---|---|
| `click=<text>` | Clicks the drawn text |
| `type=<key>:<text>` | Types text into a native field |
| `press=<key>` | Presses a native button |
| `slide=<key>:<value>` | Moves a native slider |
| `select=<key>:<index>` | Picks an item from a dropdown or radio group |
| `tab` | Moves focus with Tab |
| `menu=<menu>/<item>` | Chooses a menu bar item |
| `answer=<index>` | Answers the alert that's showing |
| `choose=<path>` | Answers the file chooser with a path |
| `resize=<w>x<h>` | Resizes the window |
| `dump` | Prints the theme, the focus, the native views and the drawn text |
| `snapshot=<path>` | Saves the window as a PNG |
| `wait=<ms>` | Pauses |
| `quit` | Quits |

[`src/script.zig`](src/script.zig) documents every step. GTK supports the
subset listed in [`src/main_gtk.zig`](src/main_gtk.zig). A few steps, such
as `nsclick`, `mark`, `commit`, `key`, `privateclipboard`, `clipboard` and
`close`, are macOS-only. Pointer and keyboard steps work on either screen,
but steps that name a native control need the hybrid screen.

On macOS, `KITCHEN_LAYOUT_FILE` makes the app write out where each element
of the hybrid screen is, for tools that click them with real input.

On GTK, the plus and check icons are drawn as font glyphs, because fabrum's
Cairo renderer can't draw SVG pictures yet.

## Tests

The tests run the interface and its logic without a window, using fabrum's
test harness (`fabrum.app.testing.Harness`). Native widgets are replaced by
fakes, so the tests run on any OS.

| Command | What runs |
|---|---|
| `zig build test` | The interface with fake native widgets, the macOS program's tests (the interface, the icons, the script), and `kitchen-none`'s tests |
| `zig build test -Dplatform=none` | The interface with drawn widgets, and `kitchen-none`'s tests |
| `zig build test -Dplatform=gtk` | The interface with GTK's fake widgets, the GTK program's tests, and `kitchen-none`'s tests. With Homebrew on macOS, put `/opt/homebrew/bin` first on your `PATH`. |

`kitchen-none`'s tests cover the interface with drawn widgets, the script
in both modes with z2d, and the PNG encoder. Every step checks that the
redrawn damage matches a full redraw. Add `-Drenderer=thorvg` to play the
overlay script with ThorVG instead. These tests are the same binary
whatever `-Dplatform` says, so after one run the others may report them as
cached.

## Files

| File | What it is |
|---|---|
| `build.zig`, `build.zig.zon` | Build steps and options, and the pinned GitHub dependencies |
| `src/kitchen.zig` | The interface and its tests, and `window_size` (Gio's 800×700) |
| `src/kitchen/Hybrid.zig` | The hybrid screen |
| `src/kitchen/Kitchen.zig` | The all-drawn screen |
| `src/kitchen/theme.zig`, `src/kitchen/widgets.zig` | Gio's Material look, and the drawn widgets |
| `src/main.zig` | The macOS program. `src/icons.zig` loads the Bootstrap SVG icons as Quartz pictures. |
| `src/main_gtk.zig` | The GTK 4 program and its script runner |
| `src/gui_options.zig` | The `--drawn` and `--disable` flags, shared by both windowed programs |
| `src/none.zig` | The no-toolkit host: overlay and e-ink modes, the script, the damage check, snapshots, `--bench` |
| `src/script.zig` | `KITCHEN_SCRIPT` and `KITCHEN_LAYOUT_FILE` on macOS |
| `src/png.zig` | A small PNG encoder for the snapshots (8-bit RGBA, compressed with `std.compress.flate`) |
| `docs/input-design.md` | The design work the Kitchen drove, and what was built |
| `src/fonts/Go-Regular.ttf`, `src/icons/` | The Go font (BSD license) and two Bootstrap icons (MIT license) |
