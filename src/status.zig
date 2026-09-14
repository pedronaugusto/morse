//! Telling the terminal what the program is doing, rather than what to draw.
//!
//! The sequences here change nothing on the screen. They say where a prompt
//! ended and a command's output began, so the terminal can scroll by command,
//! select one, or fold its output -- things a terminal cannot work out from
//! the bytes, because nothing in a stream of characters says which of them
//! the user typed.
//!
//! None of it is acknowledged and none of it is standardised: a terminal that
//! does not implement a mark ignores it, and there is no reply to read. Write
//! the marks if the program has the information, and expect nothing back.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Marks the start of a prompt: `OSC 133 ; A ST`.
///
/// Everything from here to `promptEnd` is the prompt itself -- what the
/// program printed to ask for input, not what the user typed. A terminal uses
/// it to find the top of a command when the user scrolls by command, and to
/// leave the prompt out of a copied command line.
pub fn promptStart(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.osc ++ "133;A" ++ seq.st);
}

/// Marks the end of the prompt and the start of what the user typed:
/// `OSC 133 ; B ST`.
pub fn promptEnd(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.osc ++ "133;B" ++ seq.st);
}

/// Marks the start of a command's output: `OSC 133 ; C ST`.
///
/// Written after the user's line has been read and before the command's first
/// byte of output. Everything from here to `commandEnd` is the command's, so
/// this is the mark a terminal folds or copies on.
pub fn commandStart(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.osc ++ "133;C" ++ seq.st);
}

/// Marks the end of a command's output, with the status it exited on:
/// `OSC 133 ; D ; code ST`, or `OSC 133 ; D ST` for `null`.
///
/// The exit code is what lets a terminal mark a failed command in the margin
/// without parsing anything. Pass null when there is no status to report --
/// a command that was never run, or one whose status the program does not
/// have -- rather than inventing a zero, which is a claim that it succeeded.
///
/// A `u8` because that is what a process exits with: a status is eight bits
/// on every system that has one, and a shell reporting a signal reports it as
/// 128 plus the signal number, which fits too.
pub fn commandEnd(w: *Writer, exit_code: ?u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "133;D");
    if (exit_code) |code| try w.print(";{d}", .{code});
    try w.writeAll(seq.st);
}

test "each prompt mark writes its own letter" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try promptStart(&out.writer);
    try promptEnd(&out.writer);
    try commandStart(&out.writer);
    try std.testing.expectEqualStrings(
        "\x1b]133;A\x1b\\\x1b]133;B\x1b\\\x1b]133;C\x1b\\",
        out.written(),
    );
}

test "commandEnd carries the exit code, and leaves it out when there is none" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try commandEnd(&out.writer, 0);
    try commandEnd(&out.writer, 1);
    try commandEnd(&out.writer, 130);
    try commandEnd(&out.writer, 255);
    try commandEnd(&out.writer, null);
    try std.testing.expectEqualStrings(
        "\x1b]133;D;0\x1b\\" ++
            "\x1b]133;D;1\x1b\\" ++
            "\x1b]133;D;130\x1b\\" ++
            "\x1b]133;D;255\x1b\\" ++
            "\x1b]133;D\x1b\\",
        out.written(),
    );
}

test "one command, marked from the prompt to the status it exited on" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try promptStart(&out.writer);
    try out.writer.writeAll("$ ");
    try promptEnd(&out.writer);
    try out.writer.writeAll("false\n");
    try commandStart(&out.writer);
    try commandEnd(&out.writer, 1);

    try std.testing.expectEqualStrings(
        "\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\false\n\x1b]133;C\x1b\\\x1b]133;D;1\x1b\\",
        out.written(),
    );
}

test "a writer with no room left reports the failure" {
    var buffer: [4]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, promptStart(&w));
}
