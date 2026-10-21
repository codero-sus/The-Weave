//! The bundled samples as bytes.
//!
//! Tests compile exactly what ships, so a change to a sample that breaks the
//! engine is caught by `zig build test` rather than by a human reading a page.
//! This lives beside the samples because `@embedFile` cannot reach outside the
//! package directory of its own root source file.

pub const components = @embedFile("components.weave");
pub const counter = @embedFile("counter.weave");
pub const effects = @embedFile("effects.weave");
pub const theme = @embedFile("theme.weave");
pub const todo = @embedFile("todo.weave");
