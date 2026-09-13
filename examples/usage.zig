//! What a full-screen program does on the way in, on the way out, and with
//! the bytes that arrive in between.
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
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const w = &out;

    // Take the screen: alternate buffer, no cursor, synchronised repaints.
    try zosc.altScreen.set(w, true);
    try zosc.cursorVisible.set(w, false);
    try zosc.syncOutput.set(w, true);

    // Ask for mouse press and wheel reports in SGR form -- and, by saying so
    // in one call, for no report per cell the pointer crosses.
    try zosc.mouse(w, .{ .press = true, .sgr = true });

    // Keys in the kitty protocol, pushed so exiting restores what was there,
    // and pasted text bracketed so it can be told from typing.
    try zosc.kittyKeyboardPush(w, .{
        .disambiguate_escape_codes = true,
        .report_event_types = true,
        .report_associated_text = true,
    });
    try zosc.bracketedPaste.set(w, true);

    // A frame: clear, go to the top-left, write a heading in a style. The
    // second style call writes only what changed -- four bytes rather than a
    // reset and a repaint of attributes that were already right.
    const heading: zosc.Style = .{ .bold = true, .fg = .{ .ansi = .cyan } };
    const body: zosc.Style = .{ .fg = .{ .ansi = .cyan } };
    try zosc.clearScreen(w, .all);
    try zosc.cursorTo(w, 1, 1);
    try zosc.setStyle(w, heading);
    try w.writeAll("zosc");
    try zosc.diffStyle(w, heading, body);
    try w.writeAll(" -- terminal control sequences");
    try zosc.resetStyle(w);

    // A title, a clickable link, and a desktop notification.
    try zosc.title(w, "zosc");
    try zosc.hyperlink(w, "ziglang.org", "https://ziglang.org");
    try zosc.notify(w, "Build finished", "0 errors");

    // Put text on the clipboard of whichever machine the terminal runs on,
    // base64 encoded on the fly -- no allocation, no buffer sized to the text.
    try zosc.clipboardWrite(w, .clipboard, "copied by zosc");

    // Ask the terminal what it is. None of these is guaranteed an answer, so
    // none of them may be waited on without a timeout of your own.
    try zosc.queryMode(w, zosc.syncOutput.number);
    try zosc.queryDeviceAttributes(w);
    try zosc.queryColor(w, .background);

    // Input is one byte stream carrying keys, mouse reports and replies all
    // at once, so one parser frames it. The buffer is yours, nothing here
    // allocates, and a sequence split across two reads is held until the rest
    // of it arrives.
    var input: [1024]u8 = undefined;
    var keys: zosc.KeyParser = .init(&input);

    // Control and a in the kitty protocol, then an SGR mouse click.
    var events = keys.feed("\x1b[97;5u\x1b[<0;40;12M");
    while (events.next()) |event| switch (event) {
        // A key, and whatever text the terminal said it produced.
        .key => |key| std.debug.print("key:        {s}{t} {s}\n", .{
            if (key.mods.ctrl) "ctrl+" else "",
            key.key,
            key.text(),
        }),
        // Anything framed but not a key: a mouse report, a reply, an OSC.
        .unhandled => |bytes| if (zosc.parseMouse(bytes)) |click| std.debug.print(
            "click:      {s} at {d},{d}\n",
            .{ @tagName(click.button), click.x, click.y },
        ),
        .paste_start, .paste_end, .focus_in, .focus_out => {},
    };

    // A lone ESC is both the Escape key and the first byte of every sequence.
    // This parser never guesses: it holds the byte, and `flush` is what a
    // caller whose own timeout has expired calls to settle it.
    var held = keys.feed("\x1b");
    std.debug.assert(held.next() == null);
    std.debug.assert(keys.pending().len == 1);
    const escape = keys.flush().?;

    // A reply parses on its own too, for a program that framed it some other
    // way. Every parser takes a whole sequence and returns null for anything
    // it does not recognise.
    const mode = zosc.parseModeReply("\x1b[?2026;1$y").?;
    const position = zosc.parseCursorPosition("\x1b[12;40R").?;
    const background = zosc.parseColorReply("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\").?;

    // A pixel report (mode 1016) is byte-identical to a cell report, so the
    // program that asked for pixels is the one that says so.
    var pixel = zosc.parseMouse("\x1b[<0;321;97M").?;
    pixel.pixels = true;
    const cell = zosc.toCells(pixel, 8, 16);

    // On the way out, in reverse.
    try zosc.bracketedPaste.set(w, false);
    try zosc.kittyKeyboardPop(w);
    try zosc.mouseOff(w);
    try zosc.syncOutput.set(w, false);
    try zosc.cursorVisible.set(w, true);
    try zosc.altScreen.set(w, false);
    // --- README:usage ---

    std.debug.print("escape:     {t}\n", .{escape.key.key});
    std.debug.print("mode 2026:  {s}\n", .{@tagName(mode.state)});
    std.debug.print("cursor:     row {d}, col {d}\n", .{ position.row, position.col });
    std.debug.print("background: {any}\n", .{background.color.to8()});
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
