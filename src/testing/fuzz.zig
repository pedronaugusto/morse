//! What the fuzz properties of the parsers share: `shakedown.check` with the
//! generators, and input that reaches past what random bytes do.
//!
//! A parser that wants `ESC [ ? 6 2 c` accepts nothing a run of random bytes
//! produces, so a property that only runs on accepted input would check
//! nothing. `input` starts from an example the parser accepts, or the shape
//! of one, and damages it a little.

const shakedown = @import("shakedown");

pub const check = shakedown.check;
pub const gen = shakedown.gen;
pub const Case = shakedown.Case;
pub const Source = shakedown.Source;

/// Bytes for a parser's property: a run of random bytes up to `out.len`, or,
/// three times in four when there are examples, one of them with a few of its
/// bytes changed, a tail cut off or some random bytes added. Everything it
/// returns is a prefix of `out`.
pub fn input(s: *Source, out: []u8, examples: []const []const u8) []u8 {
    if (examples.len == 0 or gen.weighted(s, &.{ 1, 3 }) == 0) {
        const len = gen.intRange(s, usize, 0, out.len);
        s.bytes(out[0..len]);
        return out[0..len];
    }
    const example = gen.oneOf(s, []const u8, examples);
    const len = @min(example.len, out.len);
    @memcpy(out[0..len], example[0..len]);
    var end = len;
    var edits = gen.intRange(s, u8, 0, 3);
    while (edits > 0) : (edits -= 1) {
        switch (gen.weighted(s, &.{ 4, 1, 1 })) {
            0 => if (end > 0) {
                out[gen.intRange(s, usize, 0, end - 1)] = gen.int(s, u8);
            },
            1 => end = gen.intRange(s, usize, 0, end),
            else => {
                const add = gen.intRange(s, usize, 0, @min(8, out.len - end));
                s.bytes(out[end..][0..add]);
                end += add;
            },
        }
    }
    return out[0..end];
}
