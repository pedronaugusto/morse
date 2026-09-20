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
const morse = @import("morse");

pub fn main() !void {
    // --- README:usage ---

    // Any `*std.Io.Writer` will do -- a buffered writer over stdout is the
    // real one. Nothing below allocates or flushes: batching is yours.
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const w = &out;

    // Take the screen: alternate buffer, no cursor. Synchronised output is
    // not here -- it is a bracket around each frame, further down.
    try morse.altScreen.set(w, true);
    try morse.cursorVisible.set(w, false);

    // Ask for mouse press and wheel reports in SGR form -- and, by saying so
    // in one call, for no report per cell the pointer crosses.
    try morse.mouse(w, .{ .press = true, .sgr = true });

    // Keys in the kitty protocol, pushed so exiting restores what was there,
    // and pasted text bracketed so it can be told from typing.
    try morse.kittyKeyboardPush(w, .{
        .disambiguate_escape_codes = true,
        .report_event_types = true,
        .report_associated_text = true,
    });
    try morse.bracketedPaste.set(w, true);
    try morse.inBandResize.set(w, true);

    // And ask to be told when the user's theme turns light or dark, so a
    // program that chose its colours on startup hears that they no longer
    // suit the background.
    try morse.colorScheme.set(w, true);

    // On Windows, keys as sequences rather than as bytes: mode 9001 says
    // which physical key it was and whether it went down or came up, and
    // `KeyParser` reads it into the same `Key` as everything else.
    try morse.win32Input.set(w, true);

    // A frame, bracketed by mode 2026 so the terminal shows all of it or
    // none of it. The bracket is per frame, it does not nest, and each half
    // is its own sequence -- never batched with another mode.
    try morse.syncOutput.set(w, true);

    // Clear, go to the top-left, write a heading in a style. The second style
    // call writes only what changed -- five bytes rather than a reset and a
    // repaint of attributes that were already right.
    const heading: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const body: morse.Style = .{ .fg = .ansi(.cyan) };
    try morse.clearScreen(w, .all);
    try morse.cursorTo(w, 1, 1);
    try morse.setStyle(w, heading);
    try w.writeAll("morse");
    try morse.diffStyle(w, heading, body);
    try w.writeAll(" -- terminal control sequences");
    try morse.resetStyle(w);

    // A rule under it, written as one glyph and a repeat count rather than
    // as thirty glyphs.
    try morse.cursorTo(w, 2, 1);
    try w.writeAll("\u{2500}");
    try morse.repeatChar(w, 29);

    // A heading drawn two cells tall, and a footnote marker drawn half size
    // at the top of its cell. Terminals without the protocol draw both at
    // the usual size, which still reads correctly.
    try morse.cursorTo(w, 4, 1);
    try morse.textSize(w, .{ .scale = 2 }, "morse");
    try morse.textSize(w, .{ .numerator = 1, .denominator = 2 }, "1");

    // An image, under the text. Send the pixels, then place them: the two are
    // separate so the picture can be moved, replaced or taken away without
    // sending it again. `q=2` because nothing here reads the reply.
    const pixels = [_]u8{ 0xff, 0x00, 0x00, 0xff }; // one red pixel, RGBA
    try morse.transmitImage(w, .{
        .image = .{ .id = 7 },
        .width = 1,
        .height = 1,
        .quiet = .silent,
    }, &pixels);
    try morse.cursorTo(w, 6, 1);
    try morse.placeImage(w, .{
        .image = .{ .id = 7 },
        .placement = .{ .id = 1, .columns = 20, .rows = 6, .z = -1, .keep_cursor = true },
        .quiet = .silent,
    });

    // Cursors the terminal draws, at the three places an edit is happening.
    try morse.extraCursors(w, .main, &.{.{ .cells = &.{
        .{ .row = 8, .col = 4 },
        .{ .row = 9, .col = 4 },
        .{ .row = 10, .col = 4 },
    } }});

    // The frame ends here.
    try morse.syncOutput.set(w, false);

    // A title, a clickable link, and a desktop notification.
    try morse.title(w, "morse");
    try morse.hyperlink(w, "ziglang.org", "https://ziglang.org");
    try morse.notify(w, "Build finished", "0 errors");

    // Put text on the clipboard of whichever machine the terminal runs on,
    // base64 encoded on the fly -- no allocation, no buffer sized to the text.
    try morse.clipboardWrite(w, .clipboard, "copied by morse");

    // Ask the terminal what it is: seventeen questions in one write, with
    // slow forwarded questions first and DA1 last. DA1 proves the input path
    // works, but a multiplexer may answer it before a forwarded OSC reply.
    // Keep the timeout armed, or finish after an explicit quiet period.
    try (morse.Probe{}).write(w);

    // A question the probe does not ask, because it needs a name. None of
    // these is guaranteed an answer either.
    try morse.queryCapability(w, "Co");

    // Input is one byte stream carrying keys, mouse reports and replies all
    // at once, so one parser frames it. The buffer is yours, nothing here
    // allocates, and a sequence split across two reads is held until the rest
    // of it arrives.
    var input: [1024]u8 = undefined;
    var keys: morse.KeyParser = .init(&input);

    // Control and a in the kitty protocol, then an SGR mouse click.
    var events = keys.feed(
        "\x1b[97;5u\x1b[<0;40;12M\x1b[48;24;80;384;640t\x1b[?997;1n\x1b[?62;52;c",
    );
    while (events.next()) |event| switch (event) {
        // A key, and whatever text the terminal said it produced.
        .key => |key| std.debug.print("key:        {s}{t} {s}\n", .{
            if (key.mods.ctrl) "ctrl+" else "",
            key.key,
            key.text(),
        }),
        // A run of printable text -- pasted, or typed faster than a read.
        // One event and a borrowed slice, not one `KeyEvent` per character.
        .text => |text| std.debug.print("text:       {s}\n", .{text}),
        // Anything framed but not a key: a mouse report, a reply, an OSC.
        // `probeMatches` says which question a reply answers, so the
        // routing is a lookup rather than a table of shapes in here.
        .unhandled => |bytes| if (morse.probeMatches(bytes, .device_attributes)) {
            std.debug.print("terminal:   class {d}\n", .{
                morse.parseDeviceAttributes(bytes).?.class,
            });
        } else if (morse.parseMouse(bytes)) |click| std.debug.print(
            "click:      {s} at {d},{d}\n",
            .{ @tagName(click.button), click.x, click.y },
        ),
        // A terminal asked for in-band resize says so here rather than
        // through a signal.
        .resize => |size| std.debug.print("resize:     {d}x{d}\n", .{ size.cols, size.rows }),
        // A terminal in mode 2031 says so when the user's theme flips.
        .color_scheme => |scheme| std.debug.print("scheme:     {t}\n", .{scheme}),
        // A reply longer than the buffer: said, never turned into the keys
        // its bytes look like. Size the buffer for the answers you ask for.
        .overflow => |bytes| std.debug.print("dropped:    {d} bytes\n", .{bytes}),
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
    const mode = morse.parseModeReply("\x1b[?2026;1$y").?;
    const position = morse.parseCursorPosition("\x1b[12;40R").?;
    const background = morse.parseColorReply("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\").?;

    // A capability the terminal answered for. Names and values travel as
    // hex, because a value is often itself an escape sequence, and they are
    // decoded into a buffer you size from the reply.
    const caps = morse.parseCapabilityReply("\x1bP1+r436f=323536\x1b\\").?;
    var entries = caps.iterator();
    const colors = entries.next().?;
    var capability: [8]u8 = undefined;
    const color_count = try colors.decodeValue(&capability);

    // A pixel report (mode 1016) is byte-identical to a cell report, so the
    // program that asked for pixels is the one that says so.
    var pixel = morse.parseMouse("\x1b[<0;321;97M").?;
    pixel.pixels = true;
    const cell = morse.toCells(pixel, 8, 16);

    // On the way out, in reverse. The image and the extra cursors are taken
    // away explicitly: they outlive the program that drew them.
    try morse.extraCursorsClear(w);
    try morse.deleteImage(w, .{
        .target = .{ .image = .{ .id = 7 } },
        .free = true,
        .quiet = .silent,
    });
    try morse.colorScheme.set(w, false);
    try morse.win32Input.set(w, false);
    try morse.inBandResize.set(w, false);
    try morse.bracketedPaste.set(w, false);
    try morse.kittyKeyboardPop(w);
    try morse.mouseOff(w);
    try morse.cursorVisible.set(w, true);
    try morse.altScreen.set(w, false);
    // --- README:usage ---

    std.debug.print("escape:     {t}\n", .{escape.key.key});
    std.debug.print("mode 2026:  {s}\n", .{@tagName(mode.state)});
    std.debug.print("cursor:     row {d}, col {d}\n", .{ position.row, position.col });
    std.debug.print("background: {any}\n", .{background.color.to8()});
    std.debug.print("colours:    {s}\n", .{color_count});
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
