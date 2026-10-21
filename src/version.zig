//! mem3 version constants and banner.
//!
//! Keep VERSION in sync with `build.zig.zon` `version` field.

pub const VERSION: []const u8 = "0.1.0-alpha";

pub const VERSION_MAJOR: u16 = 0;
pub const VERSION_MINOR: u16 = 1;
pub const VERSION_PATCH: u16 = 0;
pub const VERSION_PRE: []const u8 = "alpha";

/// Build SHA (injected at build time, defaults to "dev" for local builds).
pub const BUILD_SHA: []const u8 = "dev";

/// Codename follows the Tri-Source Coherence + GHW tradition.
pub const CODENAME: []const u8 = "Tri-Source Coherence · GHW-Alpha";

/// Compose the human-readable banner.
pub fn banner() []const u8 {
    return VERSION ++ " (" ++ CODENAME ++ ", build " ++ BUILD_SHA ++ ")\n";
}
