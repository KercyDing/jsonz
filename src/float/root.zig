//! JSON numbers that are floating point: reading them in, and writing them out.
//!
//! Both directions go straight to the decimal representation they need instead
//! of routing through `std.fmt` twice:
//!
//! - `parseNumber` scans a number once, accumulating its significant digits and
//!   decimal exponent, and converts those with Eisel-Lemire.
//! - `formatNumber` writes the shortest decimal that round-trips, with
//!   Schubfach.
//!
//! Neither changes the result: `parseNumber` falls back to
//! `std.fmt.parseFloat`, `formatNumber` to `std.fmt`'s `{d}`, and the tests
//! check both against those references.

const parse = @import("parse.zig");
const format = @import("format.zig");

/// Scans the JSON number starting at `start` and converts it to the float type
/// `T`, returning the value and the offset just past the number.
pub const parseNumber = parse.parse;

/// The value and the offset just past the number `parseNumber` scanned.
pub const Result = parse.Result;

/// Scans a JSON number once, reporting both its exact integer value (when it
/// has one) and the digits a double conversion needs.
pub const scanNumber = parse.scan;

/// The state `scanNumber` reports.
pub const Scanned = parse.Scanned;

/// Converts the digits `scanNumber` returned to `T`, or `null` when the caller
/// should fall back to `std.fmt.parseFloat`.
pub const convertScanned = parse.convertScanned;

/// Writes the shortest decimal form of `value` into `buf` and returns it.
///
/// The layout matches `std.fmt`'s `{d}`: never an exponent, never a trailing
/// `.0`, and negative zero keeps its sign.
pub const formatNumber = format.write;

/// Like `formatNumber`, but also reports the decimal exponent of the most
/// significant digit, which callers need to pick fixed or scientific notation.
pub const formatNumberExponent = format.writeShortest;

/// The text and decimal exponent `formatNumberExponent` returns.
pub const Shortest = format.Shortest;

/// The longest text `formatNumber` can produce for `T`, or zero when `T` has no
/// fused formatter and the caller should fall back to `std.fmt`.
pub const maxNumberLength = format.maxLength;

test {
    _ = parse;
    _ = format;
}
