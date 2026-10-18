//! Platform shells: the native window, input and event loop around a
//! `fabrum.app.Runtime`.
//!
//! TEMPORARY: this tree is laid out as `fabrum.app.platform` will be, and
//! moves into fabrum in Phase B (`src/platform.zig` becomes fabrum's
//! `src/app/platform.zig`, `src/platform/` becomes `src/app/platform/`).
//! It lives here only because fabrum couldn't be changed while this app
//! was started. See `docs/input-design.md`, "fabrum.app.platform".
//!
//! Each target has one native platform, so `native` picks it by OS. Its
//! Objective-C half and the frameworks it needs are added to the build by
//! `addMacosPlatform` in `build.zig`, so only apps that open a window pay for them.
const builtin = @import("builtin");

pub const macos = @import("platform/macos.zig");

/// The platform of the target OS, or `void` where fabrum has none yet.
pub const native = switch (builtin.os.tag) {
    .macos => macos,
    else => void,
};
