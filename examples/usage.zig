//! What a full-screen program does on the way in, on the way out, and with
//! the replies that arrive in between.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.
//!
//! The writer here is a buffer rather than the terminal, for two reasons: the
//! example can then show you the bytes each call produced, and running it in
//! CI does not leave a build machine's terminal on the alternate screen.

const std = @import("std");
const zosc = @import("zosc");

pub fn main() !void {
    // --- README:usage ---

    // Any `*std.Io.Writer` will do -- a buffered writer over stdout is the
    // real one. Nothing below allocates or flushes: batching is yours.
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const w = &out;

    // Take the screen: alternate buffer, no cursor, synchronised repaints.
    try zosc.altScreen.set(w, true);
    try zosc.cursorVisible.set(w, false);
    try zosc.syncOutput.set(w, true);

    // Ask for mouse press and wheel reports in SGR form -- and, by saying so
    // in one call, for no report per cell the pointer crosses.
    try zosc.mouse(w, .{ .press = true, .sgr = true });

    // Keys in the kitty protocol, pushed so exiting restores what was there.
    try zosc.kittyKeyboardPush(w, .{
        .disambiguate_escape_codes = true,
        .report_event_types = true,
    });

    // A title, a clickable link, and a desktop notification.
    try zosc.title(w, "zosc");
    try zosc.hyperlink(w, "ziglang.org", "https://ziglang.org");
    try zosc.notify(w, "Build finished", "0 errors");

    // Put text on the clipboard of whichever machine the terminal runs on,
    // base64 encoded on the fly -- no allocation, no buffer sized to the text.
    try zosc.clipboardWrite(w, .clipboard, "copied by zosc");

    // Ask whether synchronised output is really supported.
    try zosc.queryMode(w, zosc.syncOutput.number);

    // Replies arrive as bytes on the terminal's input. Every parser takes a
    // whole sequence and returns null for anything it does not recognise.
    const mode = zosc.parseModeReply("\x1b[?2026;1$y").?;
    const position = zosc.parseCursorPosition("\x1b[12;40R").?;
    const click = zosc.parseMouse("\x1b[<0;40;12M").?;

    // A pixel report (mode 1016) is byte-identical to a cell report, so the
    // program that asked for pixels is the one that says so.
    var pixel = zosc.parseMouse("\x1b[<0;321;97M").?;
    pixel.pixels = true;
    const cell = zosc.toCells(pixel, 8, 16);

    // On the way out, in reverse.
    try zosc.kittyKeyboardPop(w);
    try zosc.mouseOff(w);
    try zosc.syncOutput.set(w, false);
    try zosc.cursorVisible.set(w, true);
    try zosc.altScreen.set(w, false);
    // --- README:usage ---

    std.debug.print("mode 2026:  {s}\n", .{@tagName(mode.state)});
    std.debug.print("cursor:     row {d}, col {d}\n", .{ position.row, position.col });
    std.debug.print("click:      {s} at {d},{d}\n", .{ @tagName(click.button), click.x, click.y });
    std.debug.print("pixel 321,97 in 8x16 cells: {d},{d}\n", .{ cell.x, cell.y });
    std.debug.print("wrote {d} bytes:\n  ", .{out.end});
    printEscaped(out.buffered());
}

/// The bytes of a sequence, with the controls spelled out, so the example's
/// output is readable in a CI log.
fn printEscaped(bytes: []const u8) void {
    for (bytes) |byte| {
        switch (byte) {
            0x1b => std.debug.print("<ESC>", .{}),
            0x07 => std.debug.print("<BEL>", .{}),
            else => std.debug.print("{c}", .{byte}),
        }
    }
    std.debug.print("\n", .{});
}
