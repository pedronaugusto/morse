//! Telling the terminal what the program is doing, rather than what to draw.
//!
//! The sequences here change nothing on the screen. They say where a prompt
//! ended and a command's output began, so the terminal can scroll by command,
//! select one, or fold its output -- things a terminal cannot work out from
//! the bytes, because nothing in a stream of characters says which of them
//! the user typed.
//!
//! The same goes for progress: a long build knows what fraction of the work
//! is done, and only it knows, so a terminal that draws progress in the tab
//! or on the taskbar has to be told.
//!
//! None of it is acknowledged and none of it is standardised: a terminal that
//! does not implement a mark ignores it, and there is no reply to read. Write
//! these if the program has the information, and expect nothing back.

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

//=========================================================================
// Progress, OSC 9 ; 4.
//=========================================================================

/// What a program is telling the terminal about how far along it is.
///
/// The percentage-carrying states take 0 to 100; anything larger is written
/// as 100, because the protocol defines no value above it and a taskbar given
/// one draws something arbitrary.
pub const Progress = union(enum) {
    /// No indicator at all. What a program writes when it is done, and what
    /// it must write on every exit path -- an indicator left behind outlives
    /// the program that set it.
    none,
    /// A fraction of the work finished, 0 to 100.
    percent: u8,
    /// Stopped on an error, at the fraction it had reached. The terminal
    /// draws the same bar in a colour that says so.
    failed: u8,
    /// Working, with no way to say how much is left. A terminal draws this as
    /// motion rather than as a fraction, so it carries no number.
    indeterminate,
    /// Working, with something worth warning about, at the fraction reached.
    warning: u8,
};

/// Tells the terminal how far along the program is:
/// `OSC 9 ; 4 ; state ; percentage ST`.
///
/// The state and the percentage are always both written, because that is the
/// form terminals implementing this accept; the percentage is zero for the
/// two states that carry none.
///
/// This shares OSC 9 with `notify9`, which a terminal tells apart by the `4`
/// and the second `;`. A notification whose body begins `4;` is therefore
/// ambiguous on the wire -- the one case where the two collide, and a reason
/// to prefer `notify` for text a program did not write itself.
pub fn progress(w: *Writer, state: Progress) Writer.Error!void {
    const code: u8, const value: u8 = switch (state) {
        .none => .{ 0, 0 },
        .percent => |v| .{ 1, @min(v, 100) },
        .failed => |v| .{ 2, @min(v, 100) },
        .indeterminate => .{ 3, 0 },
        .warning => |v| .{ 4, @min(v, 100) },
    };

    try w.writeAll(seq.osc ++ "9;4;");
    try w.print("{d};{d}", .{ code, value });
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

test "progress writes a state and a percentage for every form it has" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try progress(&out.writer, .{ .percent = 40 });
    try progress(&out.writer, .{ .failed = 40 });
    try progress(&out.writer, .indeterminate);
    try progress(&out.writer, .{ .warning = 40 });
    try progress(&out.writer, .none);
    try std.testing.expectEqualStrings(
        "\x1b]9;4;1;40\x1b\\" ++
            "\x1b]9;4;2;40\x1b\\" ++
            "\x1b]9;4;3;0\x1b\\" ++
            "\x1b]9;4;4;40\x1b\\" ++
            "\x1b]9;4;0;0\x1b\\",
        out.written(),
    );
}

test "progress writes both ends of the range it accepts" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try progress(&out.writer, .{ .percent = 0 });
    try progress(&out.writer, .{ .percent = 100 });
    try std.testing.expectEqualStrings("\x1b]9;4;1;0\x1b\\\x1b]9;4;1;100\x1b\\", out.written());
}

test "progress writes a percentage above a hundred as a hundred" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // The protocol defines no value above 100, and a bar handed 255 draws
    // whatever the terminal happens to do with it.
    try progress(&out.writer, .{ .percent = 101 });
    try progress(&out.writer, .{ .failed = 255 });
    try progress(&out.writer, .{ .warning = 255 });
    try std.testing.expectEqualStrings(
        "\x1b]9;4;1;100\x1b\\\x1b]9;4;2;100\x1b\\\x1b]9;4;4;100\x1b\\",
        out.written(),
    );
}
