//! Asset bundle.
//!
//! This file exists so `@embedFile` paths resolve *inside* `assets/`: a Zig
//! module's embeds must stay within its own package path, and the executable's
//! root lives in `src/`. build.zig registers this directory as the `assets`
//! module, and server.zig re-exports the three blobs it serves.

pub const index_html = @embedFile("index.html");
pub const client_js = @embedFile("client.js");
pub const client_css = @embedFile("client.css");
