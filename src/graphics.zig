//! The kitty graphics protocol, on the writing side: putting an image on the
//! screen, moving it, and taking it off again.
//!
//! One command is one `APC G key=value,... ; payload ST` sequence. The keys
//! are the whole of the protocol -- what to do, which image, where, how
//! quiet to be -- and this file turns a typed command into them, in a fixed
//! order, with every key at its documented default left out. The payload is
//! base64, written three source bytes at a time, and split into chunks by
//! the rule the protocol gives: at most 4096 base64 characters each, every
//! chunk but the last a multiple of four, `m=1` on all but the last.
//!
//! Read against the protocol text of 2026-09-14.
//!
//! What this file will never hold: the lifecycle above these bytes. Which
//! image ids are free, whether a placement has been acknowledged, what is on
//! screen now, which z-layer a picture belongs to, and when to swap one
//! picture for another are all decisions that need state across frames, and
//! nothing in `morse` keeps state across frames. The terminal's answer to a
//! command is `parseGraphicsResponse`, further down, because a reply is a
//! reply wherever it came from.
//!
//! Animation is here, as a family of its own rather than as more keys on
//! the writers above: `a=f`, `a=a` and `a=c` give `c`, `r`, `z`, `X` and
//! `Y` meanings of their own, so a shared encoder would not be shared, it
//! would be shadowed.

const std = @import("std");
const aegis = @import("aegis");

/// A terminal image identity; zero retains the protocol sentinel.
pub const ImageId = aegis.id.Id(enum { image }, u32);
/// A nonzero image identity used to correlate a graphics probe.
pub const QueryImageId = aegis.id.NonZero(ImageId.Domain, u32);
/// A client image number, distinct from the terminal image identity.
pub const ImageNumber = aegis.id.Id(enum { image_number }, u32);
/// A placement within an image; zero means no named placement or parent.
pub const PlacementId = aegis.id.Id(enum { placement }, u32);
/// Byte sizes and offsets in graphics files or shared memory objects.
pub const GraphicsBytes = aegis.units.Bytes(u32);
/// Pixel coordinates and dimensions, distinct from terminal cells.
pub const Pixels = aegis.units.Count(enum { pixels }, u32);
/// Terminal cell dimensions, distinct from image pixels.
pub const Cells = aegis.units.Count(enum { cells }, u32);
/// Signed offsets from a parent placement, in terminal cells.
pub const CellOffset = aegis.units.Count(Cells.Domain, i32);
/// A placeholder underline colour can carry only 24 placement bits.
pub const PlaceholderPlacement = aegis.int.Ranged(u32, 0, 0xffffff);
/// The placeholder without an underline colour, which the protocol leaves unwritten.
const no_placement = PlaceholderPlacement.init(0) catch unreachable; // unreachable: zero is inside the range
const base64 = @import("base64.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

//=========================================================================
// What a command says.
//=========================================================================

/// The shape of the pixels being sent, as the `f` key spells it.
pub const GraphicsFormat = enum(u8) {
    /// Three bytes a pixel, `f=24`. The dimensions must be given.
    rgb = 24,
    /// Four bytes a pixel, `f=32`, and the protocol's default.
    rgba = 32,
    /// A whole PNG, `f=100`. The terminal reads the dimensions out of it.
    png = 100,
};

/// Where the terminal reads the pixels from, as the `t` key spells it.
///
/// Everything but `.direct` sends a path or a name as the payload instead of
/// the pixels, which is the difference between a kilobyte on the wire and a
/// megabyte -- and is only open to a program on the same machine as the
/// terminal. A program that does not know whether it is asks: send one small
/// image by each medium with an id and see which is acknowledged.
pub const GraphicsMedium = enum(u8) {
    /// `t=d`: the pixels are in the escape code.
    direct = 'd',
    /// `t=f`: the payload is the path of a regular file to read.
    file = 'f',
    /// `t=t`: the payload is the path of a file to read and then delete. The
    /// terminal deletes it only from a temporary directory and only when the
    /// path contains `tty-graphics-protocol`.
    temporary_file = 't',
    /// `t=s`: the payload is the name of a shared memory object, which the
    /// terminal reads and then unlinks.
    shared_memory = 's',
};

/// How much the terminal may say back, as the `q` key spells it.
///
/// A program that asks for nothing cannot tell a landed image from a lost
/// one; a program that asks for everything must read the replies, because
/// they arrive on the input stream in among the keys. `KeyParser` reads them
/// into `Event.reply` holding `Reply.graphics`; `parseGraphicsResponse` is
/// for a sequence the caller framed itself.
pub const GraphicsQuiet = enum(u8) {
    /// `q=0`, the default: the terminal answers, whether it worked or not.
    answers = 0,
    /// `q=1`: only failures come back.
    failures = 1,
    /// `q=2`: nothing comes back.
    silent = 2,
};

/// Which image a command is about.
///
/// A union rather than two fields because naming both is an error the
/// protocol answers with `EINVAL`: an image is addressed by the id the
/// program chose or by the number it left the terminal to resolve, never by
/// both.
pub const GraphicsImage = union(enum) {
    /// No image named, which is image id zero.
    none,
    /// The `i` key: an id the program picked, from 1 to 4294967295.
    id: ImageId,
    /// The `I` key: a number the program picked, which the terminal answers
    /// with the id it assigned. Two images may share a number; a command
    /// naming one acts on the newest.
    number: ImageNumber,
};

/// An image an animation command must name.
///
/// Animation cannot use image id zero as "assign an id for me", so unlike
/// `GraphicsImage` this has no `.none`: every command carries `i` or `I`.
pub const AnimationImage = union(enum) {
    /// The `i` key: an id the program picked.
    id: ImageId,
    /// The `I` key: the newest image carrying this number.
    number: ImageNumber,
};

/// A rectangle of the source image, in pixels: the `x`, `y`, `w` and `h`
/// keys. All zero shows the whole image.
pub const GraphicsRect = extern struct {
    /// The left edge.
    x: Pixels = Pixels.fromRaw(0),
    /// The top edge.
    y: Pixels = Pixels.fromRaw(0),
    /// The width, or zero for the rest of the image.
    width: Pixels = Pixels.fromRaw(0),
    /// The height, or zero for the rest of the image.
    height: Pixels = Pixels.fromRaw(0),
};

/// Where a placement goes and how much of the image it shows.
///
/// A placement is drawn from the cursor's cell, so the caller writes a
/// `cursorTo` before the command; nothing here says where the cursor is.
pub const Placement = extern struct {
    /// The `p` key, from 1 to 4294967295. A placement id makes the placement
    /// addressable: sending the same image id and placement id again
    /// replaces it, which is how a picture moves without flickering. Zero is
    /// no id, and then every command makes another placement.
    id: PlacementId = PlacementId.fromRaw(0),
    /// The part of the image to show: the `x`, `y`, `w` and `h` keys.
    source: GraphicsRect = .{},
    /// The `X` key: how far into the first cell, in pixels, the image starts
    /// horizontally. Must be smaller than a cell.
    x_offset: Pixels = Pixels.fromRaw(0),
    /// The `Y` key: the same vertically.
    y_offset: Pixels = Pixels.fromRaw(0),
    /// The `c` key: how many columns to draw the image across. Zero lets the
    /// terminal work it out from the pixels and the cell size.
    columns: Cells = Cells.fromRaw(0),
    /// The `r` key: how many rows.
    rows: Cells = Cells.fromRaw(0),
    /// The `z` key: where the image sits in the stack. Below zero is under
    /// the text, which is where a background belongs; at or above zero is
    /// over it.
    z: i32 = 0,
    /// The `C` key. False is the protocol's default, which moves the cursor
    /// to after the image; true (`C=1`) leaves it exactly where it was,
    /// which is what a program drawing its own screen wants.
    keep_cursor: bool = false,
    /// The `U` key: make this a virtual placement, the prototype a Unicode
    /// placeholder refers to rather than a picture on the screen. See
    /// `placeholderRow`.
    virtual: bool = false,
    /// The `P` key: the id of an image to place this one relative to. Zero
    /// is no parent.
    parent: ImageId = ImageId.fromRaw(0),
    /// The `Q` key: which placement of the parent.
    parent_placement: PlacementId = PlacementId.fromRaw(0),
    /// The `H` key: the offset in cells from the parent, horizontally.
    parent_x: CellOffset = CellOffset.fromRaw(0),
    /// The `V` key: the same vertically.
    parent_y: CellOffset = CellOffset.fromRaw(0),
};

/// What a transmit command does with the image once it has it.
pub const GraphicsAction = union(enum) {
    /// `a=t`, the default: keep it, show nothing. A later `place` shows it.
    store,
    /// `a=T`: keep it and show it here, in one command.
    display: Placement,
    /// `a=q`: try to load it, answer, and keep nothing. The way to find out
    /// whether the terminal implements the protocol at all -- see
    /// `queryGraphics`.
    query,
};

/// One image on its way to the terminal.
pub const Transmit = struct {
    /// What to do with it once it lands.
    action: GraphicsAction = .store,
    /// Which image this is, for the reply and for a later `place`.
    image: GraphicsImage = .none,
    /// The `f` key.
    format: GraphicsFormat = .rgba,
    /// The `t` key.
    medium: GraphicsMedium = .direct,
    /// The `s` key: the image's width in pixels. Required for `.rgb` and
    /// `.rgba`, read from the file for `.png`.
    width: Pixels = Pixels.fromRaw(0),
    /// The `v` key: the image's height in pixels.
    height: Pixels = Pixels.fromRaw(0),
    /// The `S` key: how many bytes to read. Required for a compressed PNG,
    /// and the way to read part of a file or a shared memory object.
    size: GraphicsBytes = GraphicsBytes.fromRaw(0),
    /// The `O` key: where in the file or object to start reading.
    offset: GraphicsBytes = GraphicsBytes.fromRaw(0),
    /// The `o` key: the payload is zlib-deflated before it is base64 encoded.
    /// Deflate the pixels first and hand the result to `transmit`.
    compressed: bool = false,
    /// The `N` key: this image is wanted briefly, so the terminal may throw
    /// its data away before other images when it is short of room.
    transient: bool = false,
    /// The `q` key.
    quiet: GraphicsQuiet = .answers,
};

/// A command that shows an image already sent: `a=p`.
pub const Place = struct {
    /// Which image to show.
    image: GraphicsImage = .none,
    /// Where it goes and how much of it is drawn.
    placement: Placement = .{},
    /// The `q` key.
    quiet: GraphicsQuiet = .answers,
};

/// What a delete command names, as the `d` key spells it.
///
/// Every one of these has a lowercase and an uppercase spelling: the
/// lowercase removes the placement and keeps the pixels, so the image can be
/// shown again without being sent again; the uppercase frees the pixels too,
/// if nothing else still refers to them. `Delete.free` chooses.
pub const DeleteTarget = union(enum) {
    /// `d=a`: every placement on the screen.
    all,
    /// `d=i`: one image, or one placement of it when `placement` is not
    /// zero.
    image: struct { id: ImageId, placement: PlacementId = PlacementId.fromRaw(0) },
    /// `d=n`: the newest image carrying a number, or one placement of it.
    number: struct { number: ImageNumber, placement: PlacementId = PlacementId.fromRaw(0) },
    /// `d=c`: every placement the cursor's cell is inside.
    at_cursor,
    /// `d=f`: the animation frames of an image. The only animation this file
    /// reaches, because deleting frames needs none of the frame keys.
    frames: GraphicsImage,
    /// `d=p`: every placement over one cell, counting from one.
    cell: struct { col: u32, row: u32 },
    /// `d=q`: every placement over one cell at one z-index.
    cell_at_z: struct { col: u32, row: u32, z: i32 },
    /// `d=r`: every image whose id falls in a range, both ends included.
    id_range: struct { first: ImageId, last: ImageId },
    /// `d=x`: every placement over one column.
    column: u32,
    /// `d=y`: every placement over one row.
    row: u32,
    /// `d=z`: every placement at one z-index.
    z: i32,
};

/// A command that takes images or placements off the screen: `a=d`.
pub const Delete = struct {
    /// What to delete. The default is every placement on screen.
    target: DeleteTarget = .all,
    /// Free the image data as well as the placement -- the uppercase
    /// spelling of the target letter.
    free: bool = false,
    /// The `q` key. A program tidying up on the way out wants `.silent`:
    /// there is nobody left to read the answer.
    quiet: GraphicsQuiet = .answers,
};

//=========================================================================
// What an animation command says.
//
// Three more actions -- `a=f`, `a=a` and `a=c` -- and a command struct each,
// because the letters they share with a placement do not mean there what
// they mean here: `c` and `r` are frame numbers rather than columns and
// rows, `z` is a gap in milliseconds rather than a layer, and `X` and `Y`
// are a composition mode and a colour rather than offsets inside a cell. A
// type each is what keeps the two readings apart.
//=========================================================================

/// How arriving pixels land on the pixels already there, as the `X` key of a
/// frame and the `C` key of a composition spell it.
pub const GraphicsCompose = enum(u8) {
    /// The protocol's default: the arriving pixels are alpha blended onto
    /// what is under them.
    blend = 0,
    /// `X=1` or `C=1`: the arriving pixels replace what is under them,
    /// alpha and all.
    overwrite = 1,
};

/// A colour with an alpha channel: the `Y` key of a frame, which fills the
/// pixels that frame's own data does not cover.
pub const GraphicsColor = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    /// Zero is transparent and 255 is opaque, so the default here is a
    /// transparent black pixel -- the protocol's own default canvas.
    a: u8 = 0,

    /// The one number the protocol carries the colour as, `0xRRGGBBAA`:
    /// red in the most significant byte and alpha in the least.
    pub fn rgba(color: GraphicsColor) u32 {
        return @as(u32, color.r) << 24 |
            @as(u32, color.g) << 16 |
            @as(u32, color.b) << 8 |
            @as(u32, color.a);
    }
};

/// Whether the terminal is playing an animation, as the `s` key spells it.
pub const AnimationState = enum(u8) {
    /// No `s` key at all, which is what a command that only sets a gap or
    /// names a frame wants: playback is left as it was.
    unchanged = 0,
    /// `s=1`: stop. The loop counter resets with it.
    stopped = 1,
    /// `s=2`: play, but wait on the last frame for more frames rather than
    /// going back to the first. What to ask for while frames are still on
    /// their way.
    loading = 2,
    /// `s=3`: play, looping back to the first frame after the last.
    running = 3,
};

/// One animation frame on its way to the terminal: `a=f`.
///
/// A frame belongs to an image, so the image must already be there and
/// `image` must name it -- the protocol answers a frame command carrying
/// neither `i` nor `I` with `EINVAL`. Frames count from one, and frame one
/// is the image's own pixels rather than anything sent here.
pub const Frame = struct {
    /// Which image this is a frame of. Not optional.
    image: AnimationImage,
    /// The `r` key: which frame to edit, counting from one. Zero makes a
    /// new frame, which is how an animation is built up.
    edit: u32 = 0,
    /// The `c` key: the frame whose pixels are the canvas this one is
    /// composed onto, counting from one. Zero fills the canvas with
    /// `background` instead.
    base: u32 = 0,
    /// The `x` key: where in the frame, in pixels, the rectangle being sent
    /// starts horizontally. The rest of the frame comes from the canvas.
    x: Pixels = Pixels.fromRaw(0),
    /// The `y` key: the same vertically.
    y: Pixels = Pixels.fromRaw(0),
    /// The `X` key.
    compose: GraphicsCompose = .blend,
    /// The `Y` key: what the canvas is filled with when `base` is zero.
    background: GraphicsColor = .{},
    /// The `z` key: how many milliseconds this frame is shown before the
    /// next one. Zero takes the terminal's own default, and a negative gap
    /// makes the frame *gapless* -- never shown, and useful only as the
    /// canvas another frame is built on.
    gap: i32 = 0,
    /// The `f` key.
    format: GraphicsFormat = .rgba,
    /// The `t` key.
    medium: GraphicsMedium = .direct,
    /// The `s` key: the width in pixels of the rectangle being sent, which
    /// is the image's own width when the frame covers all of it.
    width: Pixels = Pixels.fromRaw(0),
    /// The `v` key: its height.
    height: Pixels = Pixels.fromRaw(0),
    /// The `S` key: how many bytes to read.
    size: GraphicsBytes = GraphicsBytes.fromRaw(0),
    /// The `O` key: where in the file or object to start reading.
    offset: GraphicsBytes = GraphicsBytes.fromRaw(0),
    /// The `o` key: the payload is zlib-deflated before it is base64
    /// encoded.
    compressed: bool = false,
    /// The `q` key.
    quiet: GraphicsQuiet = .answers,
};

/// A command that plays, stops or steps an image's animation: `a=a`.
///
/// The keys are independent, so one command can set a frame's gap, name the
/// frame to show and start playback at once. `image` is not optional.
pub const Animate = struct {
    /// Which image's animation this is about.
    image: AnimationImage,
    /// The `s` key.
    state: AnimationState = .unchanged,
    /// The `c` key: which frame to show now, counting from one. Zero leaves
    /// the current frame alone. This is the whole of a client-driven
    /// animation -- send the frames, then name one per tick -- and it costs
    /// a round trip per frame, which is what the gaps below are for.
    current: u32 = 0,
    /// The `r` key: which frame `gap` is about, counting from one. The root
    /// frame is made with no gap, so this is the only way to give it one.
    frame: u32 = 0,
    /// The `z` key: the gap in milliseconds for `frame`. Zero leaves it as
    /// it was, and a negative gap makes that frame gapless.
    gap: i32 = 0,
    /// The `v` key: how many times to play. Zero leaves the count as it
    /// was, one plays for ever, and anything larger plays that many times
    /// less one. Stopping resets the count.
    loops: u32 = 0,
    /// The `q` key.
    quiet: GraphicsQuiet = .answers,
};

/// A command that copies a rectangle of pixels from one frame of an image
/// onto another frame of it: `a=c`.
///
/// Both frames count from one and both belong to `image`, which is not
/// optional. The two rectangles are the same size, `width` by `height`, and
/// each has a corner of its own. A rectangle that leaves the image is
/// `EINVAL`, and so is composing a frame onto itself through rectangles
/// that overlap.
pub const Compose = struct {
    /// Which image's frames these are.
    image: AnimationImage,
    /// The `r` key: the frame the pixels come from.
    source: u32 = 0,
    /// The `c` key: the frame they land on.
    destination: u32 = 0,
    /// The `X` key: the left edge, in pixels, of the rectangle in the
    /// source frame.
    source_x: Pixels = Pixels.fromRaw(0),
    /// The `Y` key: its top edge.
    source_y: Pixels = Pixels.fromRaw(0),
    /// The `x` key: the left edge of where it lands in the destination
    /// frame.
    destination_x: Pixels = Pixels.fromRaw(0),
    /// The `y` key: its top edge.
    destination_y: Pixels = Pixels.fromRaw(0),
    /// The `w` key: the width of both rectangles. Zero is the whole image.
    width: Pixels = Pixels.fromRaw(0),
    /// The `h` key: their height.
    height: Pixels = Pixels.fromRaw(0),
    /// The `C` key.
    compose: GraphicsCompose = .blend,
    /// The `q` key.
    quiet: GraphicsQuiet = .answers,
};

//=========================================================================
// The chunk rule.
//=========================================================================

/// The most base64 characters one transmit sequence may carry.
pub const chunk_base64_max: usize = 4096;

/// The image bytes one chunk carries: 3072, which encodes to exactly
/// `chunk_base64_max` characters.
///
/// Three source bytes become four base64 characters, so a chunk of 3072 is
/// both the largest that fits and a multiple of four once encoded -- which
/// the protocol requires of every chunk but the last.
pub const chunk_bytes: usize = chunk_base64_max / 4 * 3;

comptime {
    std.debug.assert(base64.encodedLen(chunk_bytes) == chunk_base64_max);
    std.debug.assert(chunk_base64_max % 4 == 0);
}

//=========================================================================
// Writing a command.
//=========================================================================

/// One command's `key=value` list being built up.
///
/// The comma goes before each key but the first, so a command with no keys
/// at all writes none -- which `\x1b_Ga=d\x1b\\` needs and a default-valued
/// command relies on.
/// Whether an identity or a count is not zero, which the protocol spells by
/// leaving its key out.
fn present(value: anytype) bool {
    return value != @TypeOf(value).fromRaw(0);
}

const Keys = struct {
    w: *Writer,
    any: bool = false,

    fn open(k: *Keys, name: u8) Writer.Error!void {
        if (k.any) try k.w.writeByte(',');
        k.any = true;
        try k.w.writeByte(name);
        try k.w.writeByte('=');
    }

    fn int(k: *Keys, name: u8, value: u64) Writer.Error!void {
        try k.open(name);
        try seq.writeInt(k.w, value);
    }

    fn signed(k: *Keys, name: u8, value: i32) Writer.Error!void {
        try k.open(name);
        try seq.writeSigned(k.w, value);
    }

    fn char(k: *Keys, name: u8, value: u8) Writer.Error!void {
        try k.open(name);
        try k.w.writeByte(value);
    }
};

/// Writes the keys of a placement, in the order this file always writes
/// them: `p x y w h X Y c r z C U P Q H V`.
///
/// Shared by `place` and by a transmit whose action is `.display`, so the
/// placement grammar is spelled once.
fn writePlacement(k: *Keys, p: Placement) Writer.Error!void {
    if (present(p.id)) try k.int('p', p.id.raw());
    if (present(p.source.x)) try k.int('x', p.source.x.raw());
    if (present(p.source.y)) try k.int('y', p.source.y.raw());
    if (present(p.source.width)) try k.int('w', p.source.width.raw());
    if (present(p.source.height)) try k.int('h', p.source.height.raw());
    if (present(p.x_offset)) try k.int('X', p.x_offset.raw());
    if (present(p.y_offset)) try k.int('Y', p.y_offset.raw());
    if (present(p.columns)) try k.int('c', p.columns.raw());
    if (present(p.rows)) try k.int('r', p.rows.raw());
    if (p.z != 0) try k.signed('z', p.z);
    if (p.keep_cursor) try k.int('C', 1);
    if (p.virtual) try k.int('U', 1);
    if (present(p.parent)) try k.int('P', p.parent.raw());
    if (present(p.parent_placement)) try k.int('Q', p.parent_placement.raw());
    if (present(p.parent_x)) try k.signed('H', p.parent_x.raw());
    if (present(p.parent_y)) try k.signed('V', p.parent_y.raw());
}

/// Writes which image a command names: `i` or `I`, or neither.
fn writeImage(k: *Keys, image: GraphicsImage) Writer.Error!void {
    switch (image) {
        .none => {},
        .id => |v| try k.int('i', v.raw()),
        .number => |v| try k.int('I', v.raw()),
    }
}

/// Writes the required image of an animation command: `i` or `I`.
fn writeAnimationImage(k: *Keys, image: AnimationImage) Writer.Error!void {
    switch (image) {
        .id => |v| try k.int('i', v.raw()),
        .number => |v| try k.int('I', v.raw()),
    }
}

/// Writes the keys that say where the payload comes from and what shape it
/// is: `f t s v S O o`.
///
/// `cmd` is a `Transmit` or a `Frame`. An animation frame travels by the
/// same seven keys under the same names, so they are spelled once here
/// rather than twice.
fn writeMedia(k: *Keys, cmd: anytype) Writer.Error!void {
    if (cmd.format != .rgba) try k.int('f', @backingInt(cmd.format));
    if (cmd.medium != .direct) try k.char('t', @backingInt(cmd.medium));
    if (present(cmd.width)) try k.int('s', cmd.width.raw());
    if (present(cmd.height)) try k.int('v', cmd.height.raw());
    if (present(cmd.size)) try k.int('S', cmd.size.raw());
    if (present(cmd.offset)) try k.int('O', cmd.offset.raw());
    if (cmd.compressed) try k.char('o', 'z');
}

/// Writes the keys of the first sequence of a transmit.
fn writeTransmit(k: *Keys, cmd: Transmit) Writer.Error!void {
    switch (cmd.action) {
        .store => {},
        .display => try k.char('a', 'T'),
        .query => try k.char('a', 'q'),
    }
    if (cmd.quiet != .answers) try k.int('q', @backingInt(cmd.quiet));
    try writeImage(k, cmd.image);
    try writeMedia(k, cmd);
    if (cmd.transient) try k.int('N', 1);
    if (cmd.action == .display) try writePlacement(k, cmd.action.display);
}

/// Sends an image: one `APC G ... ; <base64> ST` sequence, or several when
/// the payload does not fit in one.
///
/// `data` is the pixels for `Medium.direct`, and the path or the shared
/// memory name for every other medium -- both travel base64 encoded, and
/// both are encoded straight into the writer, so a megabyte of pixels needs
/// no megabyte of buffer here.
///
/// Chunking is automatic and is the protocol's rule rather than a choice:
/// `chunk_bytes` of source per sequence, `m=1` on every sequence but the
/// last and `m=0` on that one, and no `m` key at all when the whole payload
/// fitted in one. After the first sequence only `m` and `q` are written,
/// which is what the protocol allows there.
///
/// Nothing is flushed and nothing else may be written in between: the
/// protocol requires the chunks of one image to be consecutive.
pub fn transmitImage(w: *Writer, cmd: Transmit, data: []const u8) Writer.Error!void {
    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(offset + chunk_bytes, data.len);
        const last = end == data.len;

        try w.writeAll(seq.apc ++ "G");
        var keys: Keys = .{ .w = w };
        if (first) {
            try writeTransmit(&keys, cmd);
        } else if (cmd.quiet != .answers) {
            try keys.int('q', @backingInt(cmd.quiet));
        }
        if (!first or !last) try keys.int('m', if (last) 0 else 1);
        try w.writeByte(';');
        try base64.write(w, data[offset..end]);
        try w.writeAll(seq.st);

        if (last) return;
        offset = end;
        first = false;
    }
}

/// Shows an image the terminal already has: `APC G a=p,... ST`.
///
/// The placement lands at the cursor, so move the cursor first. There is no
/// payload and so no `;`.
pub fn placeImage(w: *Writer, cmd: Place) Writer.Error!void {
    try w.writeAll(seq.apc ++ "G");
    var keys: Keys = .{ .w = w };
    try keys.char('a', 'p');
    if (cmd.quiet != .answers) try keys.int('q', @backingInt(cmd.quiet));
    try writeImage(&keys, cmd.image);
    try writePlacement(&keys, cmd.placement);
    try w.writeAll(seq.st);
}

/// Takes images or placements off the screen: `APC G a=d,... ST`.
pub fn deleteImage(w: *Writer, cmd: Delete) Writer.Error!void {
    try w.writeAll(seq.apc ++ "G");
    var keys: Keys = .{ .w = w };
    try keys.char('a', 'd');
    if (cmd.quiet != .answers) try keys.int('q', @backingInt(cmd.quiet));
    try writeDeleteTarget(&keys, cmd.target, cmd.free);
    try w.writeAll(seq.st);
}

/// Writes the `d` key and whichever other keys that target needs.
///
/// `free` picks the uppercase spelling, which frees the image data as well
/// as the placement.
fn writeDeleteTarget(k: *Keys, target: DeleteTarget, free: bool) Writer.Error!void {
    const letter: u8 = switch (target) {
        .all => 'a',
        .image => 'i',
        .number => 'n',
        .at_cursor => 'c',
        .frames => 'f',
        .cell => 'p',
        .cell_at_z => 'q',
        .id_range => 'r',
        .column => 'x',
        .row => 'y',
        .z => 'z',
    };
    try k.char('d', if (free) letter - ('a' - 'A') else letter);

    switch (target) {
        .all, .at_cursor => {},
        .image => |v| {
            try k.int('i', v.id.raw());
            if (present(v.placement)) try k.int('p', v.placement.raw());
        },
        .number => |v| {
            try k.int('I', v.number.raw());
            if (present(v.placement)) try k.int('p', v.placement.raw());
        },
        .frames => |image| try writeImage(k, image),
        .cell => |v| {
            try k.int('x', v.col);
            try k.int('y', v.row);
        },
        .cell_at_z => |v| {
            try k.int('x', v.col);
            try k.int('y', v.row);
            try k.signed('z', v.z);
        },
        .id_range => |v| {
            try k.int('x', v.first.raw());
            try k.int('y', v.last.raw());
        },
        .column => |v| try k.int('x', v),
        .row => |v| try k.int('y', v),
        .z => |v| try k.signed('z', v),
    }
}

/// Asks whether the terminal implements the protocol at all: a one-pixel
/// image sent with the query action, which is loaded, answered and thrown
/// away.
///
/// `id` comes back in the answer, so it is how this reply is told from every
/// other graphics reply; it must not be zero. Pair it with
/// `queryDeviceAttributes`, as with every other question here: a terminal
/// without the protocol says nothing at all. DA1 proves the input path works,
/// but only the caller's timeout or quiescence period says this went unanswered.
pub fn queryGraphics(w: *Writer, id: QueryImageId) Writer.Error!void {
    try transmitImage(w, .{
        .action = .query,
        .image = .{ .id = ImageId.fromRaw(id.raw()) },
        .format = .rgb,
        .width = Pixels.fromRaw(1),
        .height = Pixels.fromRaw(1),
    }, &.{ 0, 0, 0 });
}

//=========================================================================
// Writing an animation command.
//
// Beside the writers above rather than inside them: an animation command
// reuses the transmission keys and nothing else, so `writeMedia` is shared
// and every other key is written here, under its own meaning.
//=========================================================================

/// Writes the keys of the first sequence of a frame, after its `a=f`.
fn writeFrame(k: *Keys, cmd: Frame) Writer.Error!void {
    if (cmd.quiet != .answers) try k.int('q', @backingInt(cmd.quiet));
    try writeAnimationImage(k, cmd.image);
    try writeMedia(k, cmd);
    if (present(cmd.x)) try k.int('x', cmd.x.raw());
    if (present(cmd.y)) try k.int('y', cmd.y.raw());
    if (cmd.base != 0) try k.int('c', cmd.base);
    if (cmd.edit != 0) try k.int('r', cmd.edit);
    if (cmd.gap != 0) try k.signed('z', cmd.gap);
    if (cmd.compose != .blend) try k.int('X', @backingInt(cmd.compose));
    if (cmd.background.rgba() != 0) try k.int('Y', cmd.background.rgba());
}

/// Sends one animation frame: `APC G a=f,... ; <base64> ST`, chunked by the
/// same rule as `transmitImage`.
///
/// The one difference from an image is on the wire rather than in the call:
/// the protocol requires `a=f` on every chunk of a frame, not only on the
/// first, so the continuation sequences here carry `a=f,m=...` where an
/// image's carry `m=...` alone.
///
/// Nothing is flushed and nothing else may be written in between, as with
/// any chunked payload.
pub fn transmitFrame(w: *Writer, cmd: Frame, data: []const u8) Writer.Error!void {
    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(offset + chunk_bytes, data.len);
        const last = end == data.len;

        try w.writeAll(seq.apc ++ "G");
        var keys: Keys = .{ .w = w };
        try keys.char('a', 'f');
        if (first) {
            try writeFrame(&keys, cmd);
        } else if (cmd.quiet != .answers) {
            try keys.int('q', @backingInt(cmd.quiet));
        }
        if (!first or !last) try keys.int('m', if (last) 0 else 1);
        try w.writeByte(';');
        try base64.write(w, data[offset..end]);
        try w.writeAll(seq.st);

        if (last) return;
        offset = end;
        first = false;
    }
}

/// Plays, stops or steps an image's animation: `APC G a=a,... ST`.
///
/// There is no payload and so no `;`. A command the terminal accepts is
/// answered with nothing at all, whatever `quiet` says; a refusal comes
/// back as `parseGraphicsResponse` reads it.
pub fn animateImage(w: *Writer, cmd: Animate) Writer.Error!void {
    try w.writeAll(seq.apc ++ "G");
    var keys: Keys = .{ .w = w };
    try keys.char('a', 'a');
    if (cmd.quiet != .answers) try keys.int('q', @backingInt(cmd.quiet));
    try writeAnimationImage(&keys, cmd.image);
    if (cmd.state != .unchanged) try keys.int('s', @backingInt(cmd.state));
    if (cmd.frame != 0) try keys.int('r', cmd.frame);
    if (cmd.gap != 0) try keys.signed('z', cmd.gap);
    if (cmd.current != 0) try keys.int('c', cmd.current);
    if (cmd.loops != 0) try keys.int('v', cmd.loops);
    try w.writeAll(seq.st);
}

/// Copies a rectangle from one frame of an image onto another:
/// `APC G a=c,... ST`.
///
/// The cheap way to change part of a frame, because the pixels are already
/// in the terminal: no payload, and so no `;`.
pub fn composeFrames(w: *Writer, cmd: Compose) Writer.Error!void {
    try w.writeAll(seq.apc ++ "G");
    var keys: Keys = .{ .w = w };
    try keys.char('a', 'c');
    if (cmd.quiet != .answers) try keys.int('q', @backingInt(cmd.quiet));
    try writeAnimationImage(&keys, cmd.image);
    if (cmd.destination != 0) try keys.int('c', cmd.destination);
    if (cmd.source != 0) try keys.int('r', cmd.source);
    if (present(cmd.destination_x)) try keys.int('x', cmd.destination_x.raw());
    if (present(cmd.destination_y)) try keys.int('y', cmd.destination_y.raw());
    if (present(cmd.width)) try keys.int('w', cmd.width.raw());
    if (present(cmd.height)) try keys.int('h', cmd.height.raw());
    if (present(cmd.source_x)) try keys.int('X', cmd.source_x.raw());
    if (present(cmd.source_y)) try keys.int('Y', cmd.source_y.raw());
    if (cmd.compose != .blend) try keys.int('C', @backingInt(cmd.compose));
    try w.writeAll(seq.st);
}

//=========================================================================
// Unicode placeholders.
//=========================================================================

/// The character that stands in for an image cell: U+10EEEE.
///
/// The point of it is that it is ordinary text. A program that cannot send
/// escape codes through to the terminal -- because a multiplexer or an
/// editor is between them -- can still print these, and whatever moves the
/// text around moves the image with it.
pub const placeholder: u21 = 0x10EEEE;

/// How many rows or columns a placeholder grid can address.
///
/// One per diacritic the protocol lists, which is 297. A grid larger than
/// that cannot be spelled; a terminal can be wider or taller than that, and
/// a row or column past it is refused with `error.PlaceholderOutOfRange`.
pub const placeholder_max: u16 = diacritics.len;

/// A placeholder writer can fail to write, or refuse a row or column past
/// `placeholder_max`.
pub const PlaceholderError = Writer.Error || error{PlaceholderOutOfRange};

/// One row of a placeholder grid.
pub const Placeholder = struct {
    /// The image to show. Its low 24 bits travel in the foreground colour
    /// and its top byte in a third diacritic, so the whole 32-bit id is
    /// carried.
    id: ImageId,
    /// The placement, carried in the underline colour. Zero writes no
    /// underline colour, and the terminal picks any virtual placement of the
    /// image. Construction rejects values above the colour's 24-bit range.
    placement: PlaceholderPlacement = PlaceholderPlacement.init(0) catch unreachable, // unreachable: zero is in the comptime range.
    /// Which row of the grid, counting from zero.
    row: u16,
    /// How many cells wide the row is, counting from column zero.
    columns: u16,
};

/// Writes one row of a Unicode placeholder: the colours that carry the ids,
/// `row.columns` placeholder cells, and the codes that put both colours
/// back.
///
/// First transmit the image quietly and make a virtual placement for it --
/// `place` with `Placement.virtual` set, or `transmit` with an `.display`
/// action whose placement has it -- then print one of these rows per row of
/// the grid. The rows are plain text and a `\n` between them is the caller's.
///
/// The foreground colour is written in its direct form, `CSI 38 ; 2 ; ... m`,
/// because that is what carries 24 bits of id; a terminal drawing images is
/// a terminal with direct colour. Every diacritic is written explicitly --
/// the protocol lets a cell inherit its row and column from the cell to its
/// left, and this does not use that, because it breaks the moment two
/// placeholders overlap or the host scrolls one sideways.
///
/// A `row.row` of `placeholder_max` or more, or `row.columns` past it, is
/// refused with `error.PlaceholderOutOfRange` before anything is written.
pub fn placeholderRow(w: *Writer, row: Placeholder) PlaceholderError!void {
    if (row.row >= placeholder_max or row.columns > placeholder_max) return error.PlaceholderOutOfRange;

    try w.writeAll(seq.csi ++ "38;2;");
    try seq.writeInt(w, (row.id.raw() >> 16) & 0xff);
    try w.writeByte(';');
    try seq.writeInt(w, (row.id.raw() >> 8) & 0xff);
    try w.writeByte(';');
    try seq.writeInt(w, row.id.raw() & 0xff);
    try w.writeByte('m');

    if (row.placement != no_placement) {
        try w.writeAll(seq.csi ++ "58:2::");
        try seq.writeInt(w, (row.placement.raw() >> 16) & 0xff);
        try w.writeByte(':');
        try seq.writeInt(w, (row.placement.raw() >> 8) & 0xff);
        try w.writeByte(':');
        try seq.writeInt(w, row.placement.raw() & 0xff);
        try w.writeByte('m');
    }

    var col: u16 = 0;
    while (col < row.columns) : (col += 1) {
        try placeholderCell(w, row.row, col, @truncate(row.id.raw() >> 24));
    }

    try w.writeAll(seq.csi ++ "39m");
    if (row.placement != no_placement) try w.writeAll(seq.csi ++ "59m");
}

/// Writes one placeholder cell: the placeholder character, the diacritic for
/// `row`, the diacritic for `col`, and the diacritic for `id_top` when that
/// byte is not zero.
///
/// No colour: `placeholderRow` writes that once for a whole row, because the
/// colour is what carries the image id and repeating it per cell would
/// quadruple the bytes.
///
/// A `row` or `col` of `placeholder_max` or more is refused with
/// `error.PlaceholderOutOfRange` before anything is written.
pub fn placeholderCell(w: *Writer, row: u16, col: u16, id_top: u8) PlaceholderError!void {
    if (row >= placeholder_max or col >= placeholder_max) return error.PlaceholderOutOfRange;
    comptime std.debug.assert(std.math.maxInt(u8) < placeholder_max);

    try writeCodepoint(w, placeholder);
    try writeCodepoint(w, diacritics[row]);
    try writeCodepoint(w, diacritics[col]);
    if (id_top != 0) try writeCodepoint(w, diacritics[id_top]);
}

/// Writes one codepoint as UTF-8.
fn writeCodepoint(w: *Writer, cp: u21) Writer.Error!void {
    std.debug.assert(std.unicode.utf8ValidCodepoint(cp));
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch unreachable; // unreachable: all callers pass the scalar placeholder or entries of the validated diacritic table
    try w.writeAll(buffer[0..len]);
}

/// The combining characters the protocol numbers, in its order: the one at
/// index `n` spells the number `n`.
///
/// They are the class-230 combining marks of Unicode 6.0.0 that have no
/// decomposition, minus the ones that normalisation would fuse into the
/// character they sit on. The list is the protocol's, not this package's, so
/// it is transcribed rather than derived.
const diacritics = [_]u21{
    0x0305,  0x030d,  0x030e,  0x0310,  0x0312,  0x033d,  0x033e,  0x033f,
    0x0346,  0x034a,  0x034b,  0x034c,  0x0350,  0x0351,  0x0352,  0x0357,
    0x035b,  0x0363,  0x0364,  0x0365,  0x0366,  0x0367,  0x0368,  0x0369,
    0x036a,  0x036b,  0x036c,  0x036d,  0x036e,  0x036f,  0x0483,  0x0484,
    0x0485,  0x0486,  0x0487,  0x0592,  0x0593,  0x0594,  0x0595,  0x0597,
    0x0598,  0x0599,  0x059c,  0x059d,  0x059e,  0x059f,  0x05a0,  0x05a1,
    0x05a8,  0x05a9,  0x05ab,  0x05ac,  0x05af,  0x05c4,  0x0610,  0x0611,
    0x0612,  0x0613,  0x0614,  0x0615,  0x0616,  0x0617,  0x0657,  0x0658,
    0x0659,  0x065a,  0x065b,  0x065d,  0x065e,  0x06d6,  0x06d7,  0x06d8,
    0x06d9,  0x06da,  0x06db,  0x06dc,  0x06df,  0x06e0,  0x06e1,  0x06e2,
    0x06e4,  0x06e7,  0x06e8,  0x06eb,  0x06ec,  0x0730,  0x0732,  0x0733,
    0x0735,  0x0736,  0x073a,  0x073d,  0x073f,  0x0740,  0x0741,  0x0743,
    0x0745,  0x0747,  0x0749,  0x074a,  0x07eb,  0x07ec,  0x07ed,  0x07ee,
    0x07ef,  0x07f0,  0x07f1,  0x07f3,  0x0816,  0x0817,  0x0818,  0x0819,
    0x081b,  0x081c,  0x081d,  0x081e,  0x081f,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082a,  0x082b,  0x082c,
    0x082d,  0x0951,  0x0953,  0x0954,  0x0f82,  0x0f83,  0x0f86,  0x0f87,
    0x135d,  0x135e,  0x135f,  0x17dd,  0x193a,  0x1a17,  0x1a75,  0x1a76,
    0x1a77,  0x1a78,  0x1a79,  0x1a7a,  0x1a7b,  0x1a7c,  0x1b6b,  0x1b6d,
    0x1b6e,  0x1b6f,  0x1b70,  0x1b71,  0x1b72,  0x1b73,  0x1cd0,  0x1cd1,
    0x1cd2,  0x1cda,  0x1cdb,  0x1ce0,  0x1dc0,  0x1dc1,  0x1dc3,  0x1dc4,
    0x1dc5,  0x1dc6,  0x1dc7,  0x1dc8,  0x1dc9,  0x1dcb,  0x1dcc,  0x1dd1,
    0x1dd2,  0x1dd3,  0x1dd4,  0x1dd5,  0x1dd6,  0x1dd7,  0x1dd8,  0x1dd9,
    0x1dda,  0x1ddb,  0x1ddc,  0x1ddd,  0x1dde,  0x1ddf,  0x1de0,  0x1de1,
    0x1de2,  0x1de3,  0x1de4,  0x1de5,  0x1de6,  0x1dfe,  0x20d0,  0x20d1,
    0x20d4,  0x20d5,  0x20d6,  0x20d7,  0x20db,  0x20dc,  0x20e1,  0x20e7,
    0x20e9,  0x20f0,  0x2cef,  0x2cf0,  0x2cf1,  0x2de0,  0x2de1,  0x2de2,
    0x2de3,  0x2de4,  0x2de5,  0x2de6,  0x2de7,  0x2de8,  0x2de9,  0x2dea,
    0x2deb,  0x2dec,  0x2ded,  0x2dee,  0x2def,  0x2df0,  0x2df1,  0x2df2,
    0x2df3,  0x2df4,  0x2df5,  0x2df6,  0x2df7,  0x2df8,  0x2df9,  0x2dfa,
    0x2dfb,  0x2dfc,  0x2dfd,  0x2dfe,  0x2dff,  0xa66f,  0xa67c,  0xa67d,
    0xa6f0,  0xa6f1,  0xa8e0,  0xa8e1,  0xa8e2,  0xa8e3,  0xa8e4,  0xa8e5,
    0xa8e6,  0xa8e7,  0xa8e8,  0xa8e9,  0xa8ea,  0xa8eb,  0xa8ec,  0xa8ed,
    0xa8ee,  0xa8ef,  0xa8f0,  0xa8f1,  0xaab0,  0xaab2,  0xaab3,  0xaab7,
    0xaab8,  0xaabe,  0xaabf,  0xaac1,  0xfe20,  0xfe21,  0xfe22,  0xfe23,
    0xfe24,  0xfe25,  0xfe26,  0x10a0f, 0x10a38, 0x1d185, 0x1d186, 0x1d187,
    0x1d188, 0x1d189, 0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad, 0x1d242, 0x1d243,
    0x1d244,
};

comptime {
    std.debug.assert(diacritics[0] == 0x305);
    std.debug.assert(diacritics[1] == 0x30d);
    std.debug.assert(diacritics[2] == 0x30e);
    std.debug.assert(diacritics.len == 297);
}

//=========================================================================
// The kitty graphics response.
//=========================================================================

/// What a terminal says about a kitty graphics command it was sent.
pub const GraphicsResponse = struct {
    /// The image id the response is about, the `i=` key, as the command that
    /// prompted it gave. Null when the command carried none.
    id: ?ImageId = null,
    /// The client-chosen image number, the `I=` key, which a program uses
    /// when it wants the terminal to assign the id. Null when absent.
    number: ?ImageNumber = null,
    /// The placement id, the `p=` key, naming which of an image's placements
    /// the response is about. Null when absent.
    placement: ?PlacementId = null,
    /// What the terminal said: `OK`, or an error beginning with its name,
    /// such as `ENOENT:` or `EBADF:`. A sub-slice of the bytes handed to the
    /// parser, borrowed rather than owned: valid for exactly as long as they
    /// are.
    message: []const u8,

    /// Whether the terminal accepted the command. Anything other than exactly
    /// `OK` is a refusal, and `message` says which.
    pub fn ok(response: GraphicsResponse) bool {
        return std.mem.eql(u8, response.message, "OK");
    }
};

/// Reads a kitty graphics response: `APC G key=value,... ; message ST`.
///
/// A program that sends an image asking for an answer needs to know whether
/// it worked, and a response arriving on the input stream has to be told
/// apart from a key; this reads it for both.
///
/// Keys other than `i`, `I` and `p` are read past rather than refused, since
/// the protocol adds them; a key repeated within one response is refused,
/// because there is no sensible rule for which of two values wins. A response
/// with no keys at all is valid, and so is an empty message. Returns null for
/// anything else. `bytes` must be exactly the sequence, with nothing before
/// or after it.
pub inline fn parseGraphicsResponse(bytes: []const u8) ?GraphicsResponse {
    if (!std.mem.startsWith(u8, bytes, seq.apc)) return null;
    var rest: []const u8 = bytes[seq.apc.len..];
    if (rest.len == 0 or rest[0] != 'G') return null;
    rest = rest[1..];

    var response: GraphicsResponse = .{ .message = "" };
    var seen: u64 = 0;
    while (rest.len != 0 and rest[0] != ';') {
        const bit = letterBit(rest[0]) orelse return null;
        if (seen & bit != 0) return null;
        seen |= bit;
        const key = rest[0];
        rest = rest[1..];

        if (rest.len == 0 or rest[0] != '=') return null;
        rest = rest[1..];
        const value = seq.scanInt(u32, rest) orelse return null;
        rest = rest[value.len..];

        switch (key) {
            'i' => response.id = ImageId.fromRaw(value.value),
            'I' => response.number = ImageNumber.fromRaw(value.value),
            'p' => response.placement = PlacementId.fromRaw(value.value),
            else => {},
        }

        if (rest.len == 0 or rest[0] != ',') break;
        rest = rest[1..];
        // A comma promises another key. Ending the list on one is malformed
        // rather than a list with an empty tail, and the loop condition alone
        // would let it through.
        if (rest.len == 0 or rest[0] == ';') return null;
    }

    if (rest.len == 0 or rest[0] != ';') return null;
    response.message = seq.stripStringTerminator(rest[1..]) orelse return null;
    return response;
}

//=========================================================================
// Reading a command back.
//
// Test support. Nothing here is re-exported: a program does not read the
// commands it wrote, and a terminal emulator needs far more of the protocol
// than this. It exists so that every command this file writes is parsed back
// by something that knows only the grammar -- `APC G key=value,... ; payload
// ST` -- and so the round trip proves the bytes rather than repeating them.
//=========================================================================

/// One command, read back off the wire.
const Command = struct {
    /// The `key=value` list, still as bytes and still in order.
    keys: []const u8,
    /// The payload, still base64 and verified well-formed.
    payload: []const u8,
    /// Whether the sequence carried a `;` at all. A command with no payload
    /// writes none.
    has_payload: bool,

    /// How many keys the list holds.
    fn count(c: Command) usize {
        if (c.keys.len == 0) return 0;
        var n: usize = 1;
        for (c.keys) |b| {
            if (b == ',') n += 1;
        }
        return n;
    }

    /// The value of one key, as bytes, or null when the command has no such
    /// key.
    fn get(c: Command, name: u8) ?[]const u8 {
        var rest = c.keys;
        while (rest.len != 0) {
            const end = std.mem.findScalar(u8, rest, ',') orelse rest.len;
            const pair = rest[0..end];
            if (pair[0] == name) return pair[2..];
            rest = if (end == rest.len) rest[end..] else rest[end + 1 ..];
        }
        return null;
    }
};

/// Reads one `APC G key=value,... ; payload ST` sequence, or null.
///
/// Every key must be one ASCII letter, every value either one ASCII letter
/// or an optionally negative run of digits, and no letter may appear twice.
/// The payload must be well-formed base64. `bytes` must be exactly the
/// sequence.
fn readCommand(bytes: []const u8) ?Command {
    if (!std.mem.startsWith(u8, bytes, seq.apc)) return null;
    var rest: []const u8 = bytes[seq.apc.len..];
    if (rest.len == 0 or rest[0] != 'G') return null;
    rest = rest[1..];

    const body = seq.stripStringTerminator(rest) orelse return null;
    const separator = std.mem.findScalar(u8, body, ';');
    const keys = if (separator) |i| body[0..i] else body;
    const payload = if (separator) |i| body[i + 1 ..] else body[body.len..];

    if (!validKeys(keys)) return null;
    if (!base64.isValid(payload)) return null;
    return .{ .keys = keys, .payload = payload, .has_payload = separator != null };
}

/// Whether `keys` is a well-formed, repetition-free `key=value` list.
fn validKeys(keys: []const u8) bool {
    if (keys.len == 0) return true;
    var seen: u64 = 0;
    var rest = keys;
    while (true) {
        const end = std.mem.findScalar(u8, rest, ',') orelse rest.len;
        const pair = rest[0..end];
        if (pair.len < 3 or pair[1] != '=') return false;

        const bit = letterBit(pair[0]) orelse return false;
        if (seen & bit != 0) return false;
        seen |= bit;

        const value = pair[2..];
        if (value.len == 1 and letterBit(value[0]) != null) {
            // A single-letter value, as `a`, `t`, `o` and `d` take.
        } else {
            const digits = if (value[0] == '-') value[1..] else value;
            if (digits.len == 0) return false;
            for (digits) |b| {
                if (b < '0' or b > '9') return false;
            }
        }

        if (end == rest.len) return true;
        rest = rest[end + 1 ..];
        if (rest.len == 0) return false;
    }
}

/// The bit standing for a one-letter key, used to refuse a repeated one.
fn letterBit(key: u8) ?u64 {
    const i: u6 = switch (key) {
        'a'...'z' => @intCast(key - 'a'),
        'A'...'Z' => @intCast(key - 'A' + 26),
        else => return null,
    };
    return @as(u64, 1) << i;
}

/// The commands in a run of them, one at a time. What a chunked transmit is
/// read back through.
const Commands = struct {
    rest: []const u8,

    fn next(it: *Commands) ?Command {
        if (it.rest.len == 0) return null;
        const end = std.mem.findPos(u8, it.rest, 0, seq.st) orelse return null;
        const one = it.rest[0 .. end + seq.st.len];
        it.rest = it.rest[end + seq.st.len ..];
        return readCommand(one);
    }
};

/// One animation command read back off the wire, as the command struct that
/// would write it again.
///
/// This is where the round trip for `a=f`, `a=a` and `a=c` is made: the
/// three share letters and mean different things by them, so reading each
/// one back through its own action is what proves the writers above are not
/// quietly spelling one command's keys with another's meaning.
const Animation = union(enum) {
    frame: Frame,
    animate: Animate,
    compose: Compose,
};

/// The value of a key as a `u32`, zero when the command does not carry it,
/// and null when it carries something that is not a whole number.
fn keyInt(c: Command, name: u8) ?u32 {
    const value = c.get(name) orelse return 0;
    const scan = seq.scanInt(u32, value) orelse return null;
    if (scan.len != value.len) return null;
    return scan.value;
}

/// The same for a key the protocol lets go negative.
fn keySigned(c: Command, name: u8) ?i32 {
    const value = c.get(name) orelse return 0;
    const negative = value.len != 0 and value[0] == '-';
    const digits = if (negative) value[1..] else value;
    const scan = seq.scanInt(i64, digits) orelse return null;
    if (scan.len != digits.len) return null;
    return std.math.cast(i32, if (negative) -scan.value else scan.value);
}

/// Which required animation image the command names.
fn keyAnimationImage(c: Command) ?AnimationImage {
    if (c.get('i') != null) {
        if (c.get('I') != null) return null;
        return .{ .id = ImageId.fromRaw(keyInt(c, 'i') orelse return null) };
    }
    if (c.get('I') != null) return .{ .number = ImageNumber.fromRaw(keyInt(c, 'I') orelse return null) };
    return null;
}

fn keyQuiet(c: Command) ?GraphicsQuiet {
    return switch (keyInt(c, 'q') orelse return null) {
        0 => .answers,
        1 => .failures,
        2 => .silent,
        else => null,
    };
}

fn keyFormat(c: Command) ?GraphicsFormat {
    if (c.get('f') == null) return .rgba;
    return switch (keyInt(c, 'f') orelse return null) {
        24 => .rgb,
        32 => .rgba,
        100 => .png,
        else => null,
    };
}

fn keyMedium(c: Command) ?GraphicsMedium {
    const value = c.get('t') orelse return .direct;
    if (value.len != 1) return null;
    return switch (value[0]) {
        'd' => .direct,
        'f' => .file,
        't' => .temporary_file,
        's' => .shared_memory,
        else => null,
    };
}

fn keyCompose(c: Command, name: u8) ?GraphicsCompose {
    return switch (keyInt(c, name) orelse return null) {
        0 => .blend,
        1 => .overwrite,
        else => null,
    };
}

fn keyColor(c: Command, name: u8) ?GraphicsColor {
    const value = keyInt(c, name) orelse return null;
    return .{
        .r = @truncate(value >> 24),
        .g = @truncate(value >> 16),
        .b = @truncate(value >> 8),
        .a = @truncate(value),
    };
}

/// Reads one animation command back into the command that wrote it, or
/// null when the bytes are not one.
fn readAnimation(bytes: []const u8) ?Animation {
    const c = readCommand(bytes) orelse return null;
    const action = c.get('a') orelse return null;
    if (action.len != 1) return null;

    const image = keyAnimationImage(c) orelse return null;
    const quiet = keyQuiet(c) orelse return null;

    return switch (action[0]) {
        'f' => .{ .frame = .{
            .image = image,
            .edit = keyInt(c, 'r') orelse return null,
            .base = keyInt(c, 'c') orelse return null,
            .x = Pixels.fromRaw(keyInt(c, 'x') orelse return null),
            .y = Pixels.fromRaw(keyInt(c, 'y') orelse return null),
            .compose = keyCompose(c, 'X') orelse return null,
            .background = keyColor(c, 'Y') orelse return null,
            .gap = keySigned(c, 'z') orelse return null,
            .format = keyFormat(c) orelse return null,
            .medium = keyMedium(c) orelse return null,
            .width = Pixels.fromRaw(keyInt(c, 's') orelse return null),
            .height = Pixels.fromRaw(keyInt(c, 'v') orelse return null),
            .size = GraphicsBytes.fromRaw(keyInt(c, 'S') orelse return null),
            .offset = GraphicsBytes.fromRaw(keyInt(c, 'O') orelse return null),
            .compressed = std.mem.eql(u8, c.get('o') orelse "", "z"),
            .quiet = quiet,
        } },
        'a' => .{ .animate = .{
            .image = image,
            .state = switch (keyInt(c, 's') orelse return null) {
                0 => .unchanged,
                1 => .stopped,
                2 => .loading,
                3 => .running,
                else => return null,
            },
            .current = keyInt(c, 'c') orelse return null,
            .frame = keyInt(c, 'r') orelse return null,
            .gap = keySigned(c, 'z') orelse return null,
            .loops = keyInt(c, 'v') orelse return null,
            .quiet = quiet,
        } },
        'c' => .{ .compose = .{
            .image = image,
            .source = keyInt(c, 'r') orelse return null,
            .destination = keyInt(c, 'c') orelse return null,
            .source_x = Pixels.fromRaw(keyInt(c, 'X') orelse return null),
            .source_y = Pixels.fromRaw(keyInt(c, 'Y') orelse return null),
            .destination_x = Pixels.fromRaw(keyInt(c, 'x') orelse return null),
            .destination_y = Pixels.fromRaw(keyInt(c, 'y') orelse return null),
            .width = Pixels.fromRaw(keyInt(c, 'w') orelse return null),
            .height = Pixels.fromRaw(keyInt(c, 'h') orelse return null),
            .compose = keyCompose(c, 'C') orelse return null,
            .quiet = quiet,
        } },
        else => null,
    };
}

//=========================================================================
// Tests.
//=========================================================================

/// Asserts that `bytes` is one command whose keys are exactly `keys`, in
/// order, and whose payload decodes to `data`.
fn expectCommand(bytes: []const u8, keys: []const []const u8, data: []const u8) !void {
    const command = readCommand(bytes) orelse return error.NotACommand;
    try std.testing.expectEqual(keys.len, command.count());
    for (keys) |pair| {
        const value = command.get(pair[0]) orelse return error.MissingKey;
        try std.testing.expectEqualStrings(pair[2..], value);
    }

    var decoded: [64]u8 = undefined;
    try std.testing.expectEqualStrings(data, try base64.decode(command.payload, &decoded));
}

test "a plain transmit writes only the keys that are not at their default" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(31) }, .width = Pixels.fromRaw(1), .height = Pixels.fromRaw(1) }, "abc");
    try std.testing.expectEqualStrings("\x1b_Gi=31,s=1,v=1;YWJj\x1b\\", out.written());
    try expectCommand(out.written(), &.{ "i=31", "s=1", "v=1" }, "abc");
}

test "a transmit with every key writes them in the documented order" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitImage(&out.writer, .{
        .image = .{ .number = ImageNumber.fromRaw(13) },
        .format = .png,
        .medium = .shared_memory,
        .width = Pixels.fromRaw(10),
        .height = Pixels.fromRaw(20),
        .size = GraphicsBytes.fromRaw(80),
        .offset = GraphicsBytes.fromRaw(10),
        .compressed = true,
        .transient = true,
        .quiet = .silent,
    }, "/name");
    try std.testing.expectEqualStrings(
        "\x1b_Gq=2,I=13,f=100,t=s,s=10,v=20,S=80,O=10,o=z,N=1;L25hbWU=\x1b\\",
        out.written(),
    );
    try expectCommand(out.written(), &.{
        "q=2", "I=13", "f=100", "t=s", "s=10", "v=20", "S=80", "O=10", "o=z", "N=1",
    }, "/name");
}

test "every format and every medium writes its own value" {
    const formats = [_]struct { f: GraphicsFormat, bytes: []const u8 }{
        .{ .f = .rgb, .bytes = "\x1b_Gf=24;\x1b\\" },
        .{ .f = .rgba, .bytes = "\x1b_G;\x1b\\" },
        .{ .f = .png, .bytes = "\x1b_Gf=100;\x1b\\" },
    };
    for (formats) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try transmitImage(&out.writer, .{ .format = case.f }, "");
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }

    const media = [_]struct { m: GraphicsMedium, bytes: []const u8 }{
        .{ .m = .direct, .bytes = "\x1b_G;\x1b\\" },
        .{ .m = .file, .bytes = "\x1b_Gt=f;\x1b\\" },
        .{ .m = .temporary_file, .bytes = "\x1b_Gt=t;\x1b\\" },
        .{ .m = .shared_memory, .bytes = "\x1b_Gt=s;\x1b\\" },
    };
    for (media) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try transmitImage(&out.writer, .{ .medium = case.m }, "");
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "every quiet level writes its own value, and the default writes none" {
    const cases = [_]struct { q: GraphicsQuiet, bytes: []const u8 }{
        .{ .q = .answers, .bytes = "\x1b_Ga=p\x1b\\" },
        .{ .q = .failures, .bytes = "\x1b_Ga=p,q=1\x1b\\" },
        .{ .q = .silent, .bytes = "\x1b_Ga=p,q=2\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try placeImage(&out.writer, .{ .quiet = case.q });
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "a transmit that displays writes a=T and the placement keys" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitImage(&out.writer, .{
        .action = .{ .display = .{ .id = PlacementId.fromRaw(1), .columns = Cells.fromRaw(78), .rows = Cells.fromRaw(26), .z = -3, .keep_cursor = true } },
        .image = .{ .id = ImageId.fromRaw(6) },
        .width = Pixels.fromRaw(4),
        .height = Pixels.fromRaw(4),
    }, "");
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,i=6,s=4,v=4,p=1,c=78,r=26,z=-3,C=1;\x1b\\",
        out.written(),
    );
}

test "a payload that fits writes one sequence and no m key" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const data: [chunk_bytes]u8 = @splat(0xab);
    try transmitImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) } }, &data);

    var commands: Commands = .{ .rest = out.written() };
    const only = commands.next().?;
    try std.testing.expect(only.get('m') == null);
    try std.testing.expectEqual(chunk_base64_max, only.payload.len);
    try std.testing.expect(commands.next() == null);
}

test "a payload one byte too long is split, and the chunks obey the rule" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const data: [chunk_bytes + 1]u8 = @splat(0xcd);
    try transmitImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .quiet = .silent }, &data);

    var commands: Commands = .{ .rest = out.written() };
    const first = commands.next().?;
    try std.testing.expectEqualStrings("1", first.get('m').?);
    try std.testing.expectEqualStrings("1", first.get('i').?);
    try std.testing.expectEqual(chunk_base64_max, first.payload.len);
    try std.testing.expectEqual(@as(usize, 0), first.payload.len % 4);

    const last = commands.next().?;
    try std.testing.expectEqualStrings("0", last.get('m').?);
    // After the first sequence, only m and q.
    try std.testing.expectEqual(@as(usize, 2), last.count());
    try std.testing.expectEqualStrings("2", last.get('q').?);
    try std.testing.expect(last.get('i') == null);
    try std.testing.expect(commands.next() == null);
}

test "a chunked transmit carries the image back byte for byte" {
    var data: [chunk_bytes * 3 + 7]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try transmitImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(9) }, .width = Pixels.fromRaw(32), .height = Pixels.fromRaw(32) }, &data);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);

    var commands: Commands = .{ .rest = out.written() };
    var count: usize = 0;
    while (commands.next()) |command| : (count += 1) {
        try std.testing.expect(command.has_payload);
        try joined.appendSlice(std.testing.allocator, command.payload);
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    const decoded = try std.testing.allocator.alloc(u8, base64.decodedLen(joined.items));
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &data, try base64.decode(joined.items, decoded));
}

test "an empty payload still writes one sequence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitImage(&out.writer, .{}, "");
    try std.testing.expectEqualStrings("\x1b_G;\x1b\\", out.written());
    try expectCommand(out.written(), &.{}, "");
}

test "place writes a=p and the placement, and no payload at all" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeImage(&out.writer, .{
        .image = .{ .id = ImageId.fromRaw(6) },
        .placement = .{ .id = PlacementId.fromRaw(1), .columns = Cells.fromRaw(78), .rows = Cells.fromRaw(26), .z = -3, .keep_cursor = true },
        .quiet = .silent,
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=p,q=2,i=6,p=1,c=78,r=26,z=-3,C=1\x1b\\",
        out.written(),
    );
    const command = readCommand(out.written()).?;
    try std.testing.expect(!command.has_payload);
}

test "every placement key is written, in the documented order" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeImage(&out.writer, .{
        .image = .{ .number = ImageNumber.fromRaw(3) },
        .placement = .{
            .id = PlacementId.fromRaw(1),
            .source = .{ .x = Pixels.fromRaw(2), .y = Pixels.fromRaw(3), .width = Pixels.fromRaw(4), .height = Pixels.fromRaw(5) },
            .x_offset = Pixels.fromRaw(6),
            .y_offset = Pixels.fromRaw(7),
            .columns = Cells.fromRaw(8),
            .rows = Cells.fromRaw(9),
            .z = -10,
            .keep_cursor = true,
            .virtual = true,
            .parent = ImageId.fromRaw(11),
            .parent_placement = PlacementId.fromRaw(12),
            .parent_x = CellOffset.fromRaw(-13),
            .parent_y = CellOffset.fromRaw(14),
        },
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=p,I=3,p=1,x=2,y=3,w=4,h=5,X=6,Y=7,c=8,r=9,z=-10,C=1,U=1,P=11,Q=12,H=-13,V=14\x1b\\",
        out.written(),
    );
    try expectCommand(out.written(), &.{
        "a=p", "I=3", "p=1",   "x=2", "y=3", "w=4",  "h=5",  "X=6",   "Y=7",
        "c=8", "r=9", "z=-10", "C=1", "U=1", "P=11", "Q=12", "H=-13", "V=14",
    }, "");
}

test "a virtual placement is the Unicode placeholder's prototype" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeImage(&out.writer, .{
        .image = .{ .id = ImageId.fromRaw(42) },
        .placement = .{ .virtual = true, .columns = Cells.fromRaw(2), .rows = Cells.fromRaw(2) },
        .quiet = .silent,
    });
    try std.testing.expectEqualStrings("\x1b_Ga=p,q=2,i=42,c=2,r=2,U=1\x1b\\", out.written());
}

test "the same image id and placement id twice is a move, not a second image" {
    // How a picture moves without flickering, and the reason `Placement.id`
    // exists: the terminal replaces a placement addressed by the same pair
    // rather than adding one beside it. Nothing here waits for a reply to
    // find that out — the two commands are identical but for the cell the
    // cursor was on.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const at: Place = .{
        .image = .{ .id = ImageId.fromRaw(6) },
        .placement = .{ .id = PlacementId.fromRaw(1), .columns = Cells.fromRaw(20), .rows = Cells.fromRaw(6), .z = -1, .keep_cursor = true },
        .quiet = .silent,
    };
    try placeImage(&out.writer, at);
    try placeImage(&out.writer, at);

    const one = "\x1b_Ga=p,q=2,i=6,p=1,c=20,r=6,z=-1,C=1\x1b\\";
    try std.testing.expectEqualStrings(one ++ one, out.written());

    // And by image number rather than id, for a program that let the
    // terminal choose.
    var numbered: Writer.Allocating = .init(std.testing.allocator);
    defer numbered.deinit();
    try placeImage(&numbered.writer, .{
        .image = .{ .number = ImageNumber.fromRaw(13) },
        .placement = .{ .id = PlacementId.fromRaw(1), .keep_cursor = true },
    });
    try std.testing.expectEqualStrings("\x1b_Ga=p,I=13,p=1,C=1\x1b\\", numbered.written());
}

test "the z-index is written on both sides of zero, and not at zero" {
    const cases = [_]struct { z: i32, bytes: []const u8 }{
        .{ .z = -2147483648, .bytes = "\x1b_Ga=p,i=1,z=-2147483648\x1b\\" },
        .{ .z = -4, .bytes = "\x1b_Ga=p,i=1,z=-4\x1b\\" },
        .{ .z = -1, .bytes = "\x1b_Ga=p,i=1,z=-1\x1b\\" },
        .{ .z = 0, .bytes = "\x1b_Ga=p,i=1\x1b\\" },
        .{ .z = 1, .bytes = "\x1b_Ga=p,i=1,z=1\x1b\\" },
        .{ .z = 2147483647, .bytes = "\x1b_Ga=p,i=1,z=2147483647\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try placeImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .placement = .{ .z = case.z } });
        try std.testing.expectEqualStrings(case.bytes, out.written());

        const command = readCommand(out.written()).?;
        try std.testing.expectEqual(case.z != 0, command.get('z') != null);
    }
}

test "the cursor policy is written only when it is not the protocol's own" {
    // `C=0` is the default — the cursor moves to after the image — so it is
    // left out; `C=1`, which is what a program drawing its own screen wants,
    // is written.
    var moves: Writer.Allocating = .init(std.testing.allocator);
    defer moves.deinit();
    try placeImage(&moves.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .placement = .{ .keep_cursor = false } });
    try std.testing.expectEqualStrings("\x1b_Ga=p,i=1\x1b\\", moves.written());
    try std.testing.expect(readCommand(moves.written()).?.get('C') == null);

    var stays: Writer.Allocating = .init(std.testing.allocator);
    defer stays.deinit();
    try placeImage(&stays.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .placement = .{ .keep_cursor = true } });
    try std.testing.expectEqualStrings("\x1b_Ga=p,i=1,C=1\x1b\\", stays.written());
    try std.testing.expectEqualStrings("1", readCommand(stays.written()).?.get('C').?);
}

test "a file and a shared memory object send a path, a size and an offset" {
    var file: Writer.Allocating = .init(std.testing.allocator);
    defer file.deinit();
    try transmitImage(&file.writer, .{
        .image = .{ .id = ImageId.fromRaw(2) },
        .format = .png,
        .medium = .file,
        .size = GraphicsBytes.fromRaw(4096),
        .offset = GraphicsBytes.fromRaw(128),
    }, "/tmp/tty-graphics-protocol-1.png");
    try std.testing.expectEqualStrings(
        "\x1b_Gi=2,f=100,t=f,S=4096,O=128;L3RtcC90dHktZ3JhcGhpY3MtcHJvdG9jb2wtMS5wbmc=\x1b\\",
        file.written(),
    );
    try expectCommand(
        file.written(),
        &.{ "i=2", "f=100", "t=f", "S=4096", "O=128" },
        "/tmp/tty-graphics-protocol-1.png",
    );

    var shm: Writer.Allocating = .init(std.testing.allocator);
    defer shm.deinit();
    try transmitImage(&shm.writer, .{
        .image = .{ .id = ImageId.fromRaw(3) },
        .medium = .shared_memory,
        .width = Pixels.fromRaw(10),
        .height = Pixels.fromRaw(2),
        .size = GraphicsBytes.fromRaw(80),
        .offset = GraphicsBytes.fromRaw(10),
        .compressed = true,
    }, "/morse-1");
    try expectCommand(
        shm.written(),
        &.{ "i=3", "t=s", "s=10", "v=2", "S=80", "O=10", "o=z" },
        "/morse-1",
    );

    var temp: Writer.Allocating = .init(std.testing.allocator);
    defer temp.deinit();
    try transmitImage(&temp.writer, .{
        .medium = .temporary_file,
        .quiet = .failures,
    }, "/tmp/tty-graphics-protocol-2");
    try expectCommand(temp.written(), &.{ "q=1", "t=t" }, "/tmp/tty-graphics-protocol-2");
}

test "delete writes every target the protocol names" {
    const cases = [_]struct { target: DeleteTarget, bytes: []const u8 }{
        .{ .target = .all, .bytes = "\x1b_Ga=d,d=a\x1b\\" },
        .{ .target = .at_cursor, .bytes = "\x1b_Ga=d,d=c\x1b\\" },
        .{ .target = .{ .image = .{ .id = ImageId.fromRaw(10) } }, .bytes = "\x1b_Ga=d,d=i,i=10\x1b\\" },
        .{ .target = .{ .image = .{ .id = ImageId.fromRaw(10), .placement = PlacementId.fromRaw(7) } }, .bytes = "\x1b_Ga=d,d=i,i=10,p=7\x1b\\" },
        .{ .target = .{ .number = .{ .number = ImageNumber.fromRaw(13) } }, .bytes = "\x1b_Ga=d,d=n,I=13\x1b\\" },
        .{ .target = .{ .number = .{ .number = ImageNumber.fromRaw(13), .placement = PlacementId.fromRaw(2) } }, .bytes = "\x1b_Ga=d,d=n,I=13,p=2\x1b\\" },
        .{ .target = .{ .frames = .{ .id = ImageId.fromRaw(4) } }, .bytes = "\x1b_Ga=d,d=f,i=4\x1b\\" },
        .{ .target = .{ .cell = .{ .col = 3, .row = 4 } }, .bytes = "\x1b_Ga=d,d=p,x=3,y=4\x1b\\" },
        .{ .target = .{ .cell_at_z = .{ .col = 3, .row = 4, .z = -1 } }, .bytes = "\x1b_Ga=d,d=q,x=3,y=4,z=-1\x1b\\" },
        .{ .target = .{ .id_range = .{ .first = ImageId.fromRaw(2), .last = ImageId.fromRaw(9) } }, .bytes = "\x1b_Ga=d,d=r,x=2,y=9\x1b\\" },
        .{ .target = .{ .column = 5 }, .bytes = "\x1b_Ga=d,d=x,x=5\x1b\\" },
        .{ .target = .{ .row = 6 }, .bytes = "\x1b_Ga=d,d=y,y=6\x1b\\" },
        .{ .target = .{ .z = -1 }, .bytes = "\x1b_Ga=d,d=z,z=-1\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try deleteImage(&out.writer, .{ .target = case.target });
        try std.testing.expectEqualStrings(case.bytes, out.written());
        try std.testing.expect(readCommand(out.written()) != null);
    }
}

test "freeing the data is the same target in its capital spelling" {
    const cases = [_]struct { target: DeleteTarget, letter: []const u8 }{
        .{ .target = .all, .letter = "A" },
        .{ .target = .at_cursor, .letter = "C" },
        .{ .target = .{ .image = .{ .id = ImageId.fromRaw(1) } }, .letter = "I" },
        .{ .target = .{ .number = .{ .number = ImageNumber.fromRaw(1) } }, .letter = "N" },
        .{ .target = .{ .frames = .{ .id = ImageId.fromRaw(1) } }, .letter = "F" },
        .{ .target = .{ .cell = .{ .col = 1, .row = 1 } }, .letter = "P" },
        .{ .target = .{ .cell_at_z = .{ .col = 1, .row = 1, .z = 0 } }, .letter = "Q" },
        .{ .target = .{ .id_range = .{ .first = ImageId.fromRaw(1), .last = ImageId.fromRaw(2) } }, .letter = "R" },
        .{ .target = .{ .column = 1 }, .letter = "X" },
        .{ .target = .{ .row = 1 }, .letter = "Y" },
        .{ .target = .{ .z = 0 }, .letter = "Z" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try deleteImage(&out.writer, .{ .target = case.target, .free = true });
        const command = readCommand(out.written()).?;
        try std.testing.expectEqualStrings(case.letter, command.get('d').?);
    }
}

test "the delete a renderer runs on the way out says nothing back" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try deleteImage(&out.writer, .{ .target = .{ .image = .{ .id = ImageId.fromRaw(6), .placement = PlacementId.fromRaw(1) } }, .quiet = .silent });
    try std.testing.expectEqualStrings("\x1b_Ga=d,q=2,d=i,i=6,p=1\x1b\\", out.written());
}

test "queryGraphics is a one-pixel image the terminal answers and forgets" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryGraphics(&out.writer, try QueryImageId.fromRaw(31));
    try std.testing.expectEqualStrings("\x1b_Ga=q,i=31,f=24,s=1,v=1;AAAA\x1b\\", out.written());
    try expectCommand(out.written(), &.{ "a=q", "i=31", "f=24", "s=1", "v=1" }, &.{ 0, 0, 0 });
}

test "a frame writes a=f and only the keys that are not at their default" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitFrame(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(7) } }, "abc");
    try std.testing.expectEqualStrings("\x1b_Ga=f,i=7;YWJj\x1b\\", out.written());
    try expectCommand(out.written(), &.{ "a=f", "i=7" }, "abc");
}

test "a frame with every key writes them in the documented order" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try transmitFrame(&out.writer, .{
        .image = .{ .number = ImageNumber.fromRaw(13) },
        .edit = 3,
        .base = 2,
        .x = Pixels.fromRaw(10),
        .y = Pixels.fromRaw(5),
        .compose = .overwrite,
        .background = .{ .r = 0xff, .a = 0xff },
        .gap = 48,
        .format = .rgb,
        .medium = .shared_memory,
        .width = Pixels.fromRaw(100),
        .height = Pixels.fromRaw(200),
        .size = GraphicsBytes.fromRaw(60000),
        .offset = GraphicsBytes.fromRaw(16),
        .compressed = true,
        .quiet = .silent,
    }, "/name");
    try std.testing.expectEqualStrings(
        "\x1b_Ga=f,q=2,I=13,f=24,t=s,s=100,v=200,S=60000,O=16,o=z," ++
            "x=10,y=5,c=2,r=3,z=48,X=1,Y=4278190335;L25hbWU=\x1b\\",
        out.written(),
    );
    try expectCommand(out.written(), &.{
        "a=f", "q=2",  "I=13", "f=24", "t=s", "s=100", "v=200", "S=60000",      "O=16",
        "o=z", "x=10", "y=5",  "c=2",  "r=3", "z=48",  "X=1",   "Y=4278190335",
    }, "/name");
}

test "an animation command image cannot represent no image" {
    inline for (.{ Frame, Animate, Compose }) |CommandType| {
        const image_type = @FieldType(CommandType, "image");
        try std.testing.expectEqual(@as(usize, 2), @typeInfo(image_type).@"union".field_names.len);
    }
}

test "the gap of a frame is written on both sides of zero, and not at zero" {
    // A positive gap is milliseconds; a negative one makes the frame
    // gapless, which is a frame that exists only to be another frame's
    // canvas; zero means the terminal's own default and is left out.
    const cases = [_]struct { gap: i32, bytes: []const u8 }{
        .{ .gap = -1, .bytes = "\x1b_Ga=f,i=1,z=-1;\x1b\\" },
        .{ .gap = 0, .bytes = "\x1b_Ga=f,i=1;\x1b\\" },
        .{ .gap = 48, .bytes = "\x1b_Ga=f,i=1,z=48;\x1b\\" },
        .{ .gap = 2147483647, .bytes = "\x1b_Ga=f,i=1,z=2147483647;\x1b\\" },
        .{ .gap = -2147483648, .bytes = "\x1b_Ga=f,i=1,z=-2147483648;\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try transmitFrame(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .gap = case.gap }, "");
        try std.testing.expectEqualStrings(case.bytes, out.written());
        try std.testing.expectEqual(case.gap, readAnimation(out.written()).?.frame.gap);
    }
}

test "the background colour is the protocol's own 32-bit RGBA" {
    // Both numbers are the protocol's worked examples: opaque red, and a
    // green that is a little over half transparent.
    try std.testing.expectEqual(@as(u32, 4278190335), (GraphicsColor{ .r = 0xff, .a = 0xff }).rgba());
    try std.testing.expectEqual(@as(u32, 16711816), (GraphicsColor{ .g = 0xff, .a = 0x88 }).rgba());
    try std.testing.expectEqual(@as(u32, 0), (GraphicsColor{}).rgba());

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try transmitFrame(&out.writer, .{
        .image = .{ .id = ImageId.fromRaw(1) },
        .background = .{ .g = 0xff, .a = 0x88 },
    }, "");
    try std.testing.expectEqualStrings("\x1b_Ga=f,i=1,Y=16711816;\x1b\\", out.written());

    // A transparent black canvas is the protocol's default, so it is the
    // one colour that writes no key at all.
    var none: Writer.Allocating = .init(std.testing.allocator);
    defer none.deinit();
    try transmitFrame(&none.writer, .{ .image = .{ .id = ImageId.fromRaw(1) } }, "");
    try std.testing.expect(readCommand(none.written()).?.get('Y') == null);
}

test "a chunked frame carries a=f on every sequence" {
    // The one place a frame's bytes differ from an image's: the protocol
    // requires the action on the continuation chunks too, where an image
    // sends only `m` and `q`.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const data: [chunk_bytes + 1]u8 = @splat(0xcd);
    try transmitFrame(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .quiet = .silent }, &data);

    var commands: Commands = .{ .rest = out.written() };
    const first = commands.next().?;
    try std.testing.expectEqualStrings("f", first.get('a').?);
    try std.testing.expectEqualStrings("1", first.get('m').?);
    try std.testing.expectEqual(chunk_base64_max, first.payload.len);

    const last = commands.next().?;
    try std.testing.expectEqualStrings("f", last.get('a').?);
    try std.testing.expectEqualStrings("0", last.get('m').?);
    try std.testing.expectEqualStrings("2", last.get('q').?);
    // After the first sequence, only a, q and m.
    try std.testing.expectEqual(@as(usize, 3), last.count());
    try std.testing.expect(last.get('i') == null);
    try std.testing.expect(commands.next() == null);
}

test "a frame that fits writes one sequence and no m key" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const data: [chunk_bytes]u8 = @splat(0xab);
    try transmitFrame(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) } }, &data);

    var commands: Commands = .{ .rest = out.written() };
    const only = commands.next().?;
    try std.testing.expect(only.get('m') == null);
    try std.testing.expectEqual(chunk_base64_max, only.payload.len);
    try std.testing.expect(commands.next() == null);
}

test "animation control writes the state, the frame, the gap, the current frame and the loops" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try animateImage(&out.writer, .{
        .image = .{ .id = ImageId.fromRaw(7) },
        .state = .running,
        .frame = 3,
        .gap = 48,
        .current = 2,
        .loops = 5,
        .quiet = .silent,
    });
    try std.testing.expectEqualStrings("\x1b_Ga=a,q=2,i=7,s=3,r=3,z=48,c=2,v=5\x1b\\", out.written());
    try expectCommand(out.written(), &.{
        "a=a", "q=2", "i=7", "s=3", "r=3", "z=48", "c=2", "v=5",
    }, "");
    try std.testing.expect(!readCommand(out.written()).?.has_payload);

    // The protocol's own example: the gap of the third frame of image
    // seven, which is the only way the root frame ever gets one.
    var gap: Writer.Allocating = .init(std.testing.allocator);
    defer gap.deinit();
    try animateImage(&gap.writer, .{ .image = .{ .id = ImageId.fromRaw(7) }, .frame = 3, .gap = 48 });
    try std.testing.expectEqualStrings("\x1b_Ga=a,i=7,r=3,z=48\x1b\\", gap.written());

    // And the one a client-driven animation sends per tick.
    var step: Writer.Allocating = .init(std.testing.allocator);
    defer step.deinit();
    try animateImage(&step.writer, .{ .image = .{ .id = ImageId.fromRaw(3) }, .current = 7 });
    try std.testing.expectEqualStrings("\x1b_Ga=a,i=3,c=7\x1b\\", step.written());
}

test "every animation state writes its own value, and the default writes none" {
    const cases = [_]struct { state: AnimationState, bytes: []const u8 }{
        .{ .state = .unchanged, .bytes = "\x1b_Ga=a,i=1\x1b\\" },
        .{ .state = .stopped, .bytes = "\x1b_Ga=a,i=1,s=1\x1b\\" },
        .{ .state = .loading, .bytes = "\x1b_Ga=a,i=1,s=2\x1b\\" },
        .{ .state = .running, .bytes = "\x1b_Ga=a,i=1,s=3\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try animateImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .state = case.state });
        try std.testing.expectEqualStrings(case.bytes, out.written());
        try std.testing.expectEqual(case.state, readAnimation(out.written()).?.animate.state);
    }
}

test "composing frames writes both frames, both rectangles and the mode" {
    // The protocol's own example: a 23 by 27 rectangle at (4, 8) in frame
    // seven, onto (1, 3) in frame nine, both frames of image one.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try composeFrames(&out.writer, .{
        .image = .{ .id = ImageId.fromRaw(1) },
        .source = 7,
        .destination = 9,
        .width = Pixels.fromRaw(23),
        .height = Pixels.fromRaw(27),
        .source_x = Pixels.fromRaw(4),
        .source_y = Pixels.fromRaw(8),
        .destination_x = Pixels.fromRaw(1),
        .destination_y = Pixels.fromRaw(3),
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=c,i=1,c=9,r=7,x=1,y=3,w=23,h=27,X=4,Y=8\x1b\\",
        out.written(),
    );
    try expectCommand(out.written(), &.{
        "a=c", "i=1", "c=9", "r=7", "x=1", "y=3", "w=23", "h=27", "X=4", "Y=8",
    }, "");
    try std.testing.expect(!readCommand(out.written()).?.has_payload);

    // The whole image, replaced rather than blended, quietly.
    var whole: Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    try composeFrames(&whole.writer, .{
        .image = .{ .number = ImageNumber.fromRaw(4) },
        .source = 1,
        .destination = 2,
        .compose = .overwrite,
        .quiet = .silent,
    });
    try std.testing.expectEqualStrings("\x1b_Ga=c,q=2,I=4,c=2,r=1,C=1\x1b\\", whole.written());
}

test "every animation command reads back as the command that wrote it" {
    const commands = [_]Animation{
        .{ .frame = .{ .image = .{ .id = ImageId.fromRaw(1) } } },
        .{ .frame = .{
            .image = .{ .number = ImageNumber.fromRaw(2) },
            .edit = 4,
            .base = 3,
            .x = Pixels.fromRaw(10),
            .y = Pixels.fromRaw(5),
            .compose = .overwrite,
            .background = .{ .r = 1, .g = 2, .b = 3, .a = 4 },
            .gap = -40,
            .format = .png,
            .medium = .file,
            .width = Pixels.fromRaw(7),
            .height = Pixels.fromRaw(8),
            .size = GraphicsBytes.fromRaw(9),
            .offset = GraphicsBytes.fromRaw(11),
            .compressed = true,
            .quiet = .failures,
        } },
        .{ .animate = .{ .image = .{ .id = ImageId.fromRaw(1) } } },
        .{ .animate = .{
            .image = .{ .number = ImageNumber.fromRaw(5) },
            .state = .loading,
            .current = 6,
            .frame = 7,
            .gap = -1,
            .loops = 8,
            .quiet = .silent,
        } },
        .{ .compose = .{ .image = .{ .id = ImageId.fromRaw(1) } } },
        .{ .compose = .{
            .image = .{ .number = ImageNumber.fromRaw(9) },
            .source = 1,
            .destination = 2,
            .source_x = Pixels.fromRaw(3),
            .source_y = Pixels.fromRaw(4),
            .destination_x = Pixels.fromRaw(5),
            .destination_y = Pixels.fromRaw(6),
            .width = Pixels.fromRaw(7),
            .height = Pixels.fromRaw(8),
            .compose = .overwrite,
            .quiet = .failures,
        } },
    };

    for (commands) |command| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        switch (command) {
            .frame => |cmd| try transmitFrame(&out.writer, cmd, ""),
            .animate => |cmd| try animateImage(&out.writer, cmd),
            .compose => |cmd| try composeFrames(&out.writer, cmd),
        }
        try std.testing.expectEqualDeep(command, readAnimation(out.written()).?);
    }
}

test "readAnimation refuses what is not an animation command" {
    const rejected = [_][]const u8{
        "\x1b_Gi=1;\x1b\\", // no action at all
        "\x1b_Ga=p,i=1\x1b\\", // a placement, whose keys mean other things
        "\x1b_Ga=d,d=a\x1b\\", // a delete
        "\x1b_Ga=T,i=1;\x1b\\", // a transmit that displays
        "\x1b_Ga=x,i=1\x1b\\", // an action the protocol does not name
        "\x1b_Ga=f;\x1b\\", // every animation action requires an image
        "\x1b_Ga=a\x1b\\",
        "\x1b_Ga=c\x1b\\",
    };
    for (rejected) |bytes| try std.testing.expect(readAnimation(bytes) == null);
}

test "fuzz the animation round trip" {
    // The property: whatever the field values, each of the three commands
    // writes a sequence the reader accepts, and reading it back gives the
    // command that was written -- which is what says the three are not
    // sharing a meaning for the letters they share.
    const fuzz = @import("testing/fuzz.zig");
    const property = struct {
        fn holds(a: u32, b: u32, c: u32, d: u32, e: u32) !void {
            const image: AnimationImage = if (a & 1 == 0)
                .{ .id = ImageId.fromRaw(b) }
            else
                .{ .number = ImageNumber.fromRaw(c) };
            const quiet: GraphicsQuiet = @fromBackingInt(@intCast(@as(u8, @truncate(a >> 2)) % 3));
            const mode: GraphicsCompose = if (a & 0x10 != 0) .overwrite else .blend;

            const commands = [_]Animation{
                .{ .frame = .{
                    .image = image,
                    .edit = b,
                    .base = c,
                    .x = Pixels.fromRaw(d),
                    .y = Pixels.fromRaw(e),
                    .compose = mode,
                    .background = .{
                        .r = @truncate(d >> 24),
                        .g = @truncate(d >> 16),
                        .b = @truncate(d >> 8),
                        .a = @truncate(d),
                    },
                    .gap = @bitCast(e),
                    .format = switch (@as(u2, @truncate(a >> 5))) {
                        0 => .rgb,
                        1 => .png,
                        else => .rgba,
                    },
                    .medium = switch (@as(u2, @truncate(a >> 7))) {
                        0 => .direct,
                        1 => .file,
                        2 => .temporary_file,
                        else => .shared_memory,
                    },
                    .width = Pixels.fromRaw(c),
                    .height = Pixels.fromRaw(d),
                    .size = GraphicsBytes.fromRaw(e),
                    .offset = GraphicsBytes.fromRaw(b),
                    .compressed = a & 0x200 != 0,
                    .quiet = quiet,
                } },
                .{ .animate = .{
                    .image = image,
                    .state = @fromBackingInt(@intCast(@as(u8, @truncate(a >> 10)) % 4)),
                    .current = b,
                    .frame = c,
                    .gap = @bitCast(d),
                    .loops = e,
                    .quiet = quiet,
                } },
                .{ .compose = .{
                    .image = image,
                    .source = b,
                    .destination = c,
                    .source_x = Pixels.fromRaw(d),
                    .source_y = Pixels.fromRaw(e),
                    .destination_x = Pixels.fromRaw(b),
                    .destination_y = Pixels.fromRaw(c),
                    .width = Pixels.fromRaw(d),
                    .height = Pixels.fromRaw(e),
                    .compose = mode,
                    .quiet = quiet,
                } },
            };

            var buffer: [256]u8 = undefined;
            for (commands) |command| {
                var w: Writer = .fixed(&buffer);
                switch (command) {
                    .frame => |cmd| try transmitFrame(&w, cmd, ""),
                    .animate => |cmd| try animateImage(&w, cmd),
                    .compose => |cmd| try composeFrames(&w, cmd),
                }
                try std.testing.expectEqualDeep(command, readAnimation(w.buffered()).?);
            }
        }

        fn body(_: void, case: *fuzz.Case) !void {
            const s = case.source;
            try holds(fuzz.gen.int(s, u32), fuzz.gen.int(s, u32), fuzz.gen.int(s, u32), fuzz.gen.int(s, u32), fuzz.gen.int(s, u32));
        }
    };
    // The values the old corpus held: a mixed set, all zeros, all ones.
    try property.holds(1, 7, 2, 3, 0x30);
    try property.holds(0, 0, 0, 0, 0);
    try property.holds(0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff);
    try fuzz.check(std.testing.allocator, {}, property.body, .{});
}

test "a placeholder row carries the image id in the foreground colour" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(42), .row = 0, .columns = 2 });
    try std.testing.expectEqualStrings(
        "\x1b[38;2;0;0;42m\u{10EEEE}\u{305}\u{305}\u{10EEEE}\u{305}\u{30d}\x1b[39m",
        out.written(),
    );

    var second: Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try placeholderRow(&second.writer, .{ .id = ImageId.fromRaw(42), .row = 1, .columns = 2 });
    try std.testing.expectEqualStrings(
        "\x1b[38;2;0;0;42m\u{10EEEE}\u{30d}\u{305}\u{10EEEE}\u{30d}\u{30d}\x1b[39m",
        second.written(),
    );
}

test "an image id past three bytes puts its top byte in a third diacritic" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // 33554474 = 42 + (2 << 24), the protocol's own example.
    try placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(42 + (2 << 24)), .row = 0, .columns = 2 });
    try std.testing.expectEqualStrings(
        "\x1b[38;2;0;0;42m" ++
            "\u{10EEEE}\u{305}\u{305}\u{30e}" ++
            "\u{10EEEE}\u{305}\u{30d}\u{30e}" ++
            "\x1b[39m",
        out.written(),
    );
}

test "a placement id travels in the underline colour" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(1), .placement = try PlaceholderPlacement.init(7), .row = 0, .columns = 1 });
    try std.testing.expectEqualStrings(
        "\x1b[38;2;0;0;1m\x1b[58:2::0:0:7m\u{10EEEE}\u{305}\u{305}\x1b[39m\x1b[59m",
        out.written(),
    );
}

test "a placeholder placement has exactly the bits its colour carries" {
    try std.testing.expectEqual(@as(u32, 0xffffff), (try PlaceholderPlacement.init(0xffffff)).raw());
    try std.testing.expectError(error.OutOfRange, PlaceholderPlacement.init(0x1000000));
}

test "a placeholder cell writes the character and its diacritics and no colour" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try placeholderCell(&out.writer, 0, 0, 0);
    try std.testing.expectEqualStrings("\u{10EEEE}\u{305}\u{305}", out.written());
}

test "the diacritics are the protocol's own, at the numbers it gives them" {
    try std.testing.expectEqual(@as(u21, 0x305), diacritics[0]);
    try std.testing.expectEqual(@as(u21, 0x30d), diacritics[1]);
    try std.testing.expectEqual(@as(u21, 0x30e), diacritics[2]);
    try std.testing.expectEqual(@as(u16, 297), placeholder_max);
    try std.testing.expectEqual(@as(u21, 0x10EEEE), placeholder);

    // Every one of them is a codepoint that can be written, and no two of
    // them are the same, or two numbers would spell the same cell.
    for (diacritics, 0..) |cp, i| {
        try std.testing.expect(std.unicode.utf8ValidCodepoint(cp));
        for (diacritics[i + 1 ..]) |other| try std.testing.expect(cp != other);
    }
}

test "every row and column the table can address writes a cell" {
    var buffer: [16]u8 = undefined;
    for (0..placeholder_max) |i| {
        var w: Writer = .fixed(&buffer);
        try placeholderCell(&w, @intCast(i), @intCast(placeholder_max - 1 - i), 0);
        try std.testing.expect(w.buffered().len >= 4 + 2 + 2);
    }
}

test "a row or column past the diacritic table is refused, with nothing written" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const last = placeholder_max - 1;
    try std.testing.expectError(error.PlaceholderOutOfRange, placeholderCell(&out.writer, placeholder_max, 0, 0));
    try std.testing.expectError(error.PlaceholderOutOfRange, placeholderCell(&out.writer, 0, placeholder_max, 0));
    try std.testing.expectError(error.PlaceholderOutOfRange, placeholderCell(&out.writer, 0, std.math.maxInt(u16), 0));
    try std.testing.expectError(
        error.PlaceholderOutOfRange,
        placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(1), .row = placeholder_max, .columns = 1 }),
    );
    try std.testing.expectError(
        error.PlaceholderOutOfRange,
        placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(1), .row = 0, .columns = placeholder_max + 1 }),
    );
    try std.testing.expectEqualStrings("", out.written());

    // The last row and the widest row still go through.
    try placeholderRow(&out.writer, .{ .id = ImageId.fromRaw(1), .row = last, .columns = placeholder_max });
    try std.testing.expect(out.written().len != 0);
}

test "readCommand returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b_G", // no terminator
        "\x1b_Gi=1;OK", // no terminator
        "\x1b[Gi=1;\x1b\\", // CSI, not APC
        "\x1b_Xi=1;\x1b\\", // not the graphics command
        "\x1b_Gi=;\x1b\\", // a key with no value
        "\x1b_G=1;\x1b\\", // a value with no key
        "\x1b_Gii=1;\x1b\\", // a key of two letters
        "\x1b_Gi=1,;\x1b\\", // a comma with nothing after it
        "\x1b_Gi=1,i=2;\x1b\\", // the same key twice
        "\x1b_Gi=1;a\x1b\\", // a payload that is not base64
        "\x1b_Gi=1;YWJ\x1b\\", // a payload that is not base64
        "\x1b_Gi=-\x1b\\", // a minus with no digits
        "\x1b_Gi=1x\x1b\\", // digits with a letter after them
    };
    for (rejected) |bytes| try std.testing.expect(readCommand(bytes) == null);
}

test "readCommand accepts BEL where a terminal uses it instead of ST" {
    const command = readCommand("\x1b_Ga=d,d=i,i=10\x07").?;
    try std.testing.expectEqualStrings("10", command.get('i').?);
    try std.testing.expect(!command.has_payload);
}

test "fuzz readCommand" {
    // The property: no input panics or overflows, what it returns borrows
    // from the bytes it was given, and the same bytes read the same way
    // twice.
    const fuzz = @import("testing/fuzz.zig");
    const examples = [_][]const u8{
        "\x1b_Gi=31,s=1,v=1;YWJj\x1b\\",
        "\x1b_Ga=p,q=2,i=6,p=1,c=78,r=26,z=-3,C=1\x1b\\",
        "\x1b_Ga=d,d=i,i=10,p=7\x1b\\",
        "\x1b_Gm=0;\x1b\\",
        "\x1b_G;\x1b\\",
        "\x1b_Gi=1,i=2;\x1b\\",
        "\x1b_Gi=1;a\x1b\\",
        "\x1b_Ga=d,d=i,i=10\x07",
    };
    const property = struct {
        fn holds(bytes: []const u8) !void {
            const command = readCommand(bytes) orelse return;
            try std.testing.expect(borrows(bytes, command.keys));
            try std.testing.expect(borrows(bytes, command.payload));
            try std.testing.expect(base64.isValid(command.payload));

            const again = readCommand(bytes).?;
            try std.testing.expectEqualStrings(command.keys, again.keys);
            try std.testing.expectEqualStrings(command.payload, again.payload);
            try std.testing.expectEqual(command.count(), again.count());
        }

        fn body(_: void, case: *fuzz.Case) !void {
            var input: [96]u8 = undefined;
            try holds(fuzz.input(case.source, &input, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try fuzz.check(std.testing.allocator, {}, property.body, .{});
}

test "fuzz the transmit round trip" {
    // The property: whatever the payload, every sequence written parses back
    // as a command, the chunk rule holds on each of them, and the payloads
    // joined and decoded are the bytes that went in.
    const fuzz = @import("testing/fuzz.zig");
    const examples = [_][]const u8{
        "",
        "a",
        "ab",
        "abc",
        "the quick brown fox",
    };
    const property = struct {
        fn holds(data: []const u8) !void {
            var out: Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try transmitImage(&out.writer, .{ .image = .{ .id = ImageId.fromRaw(1) }, .quiet = .silent }, data);

            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(std.testing.allocator);

            var commands: Commands = .{ .rest = out.written() };
            var seen: usize = 0;
            var last_seen = false;
            while (commands.next()) |command| : (seen += 1) {
                try std.testing.expect(command.has_payload);
                try std.testing.expect(command.payload.len <= chunk_base64_max);
                if (command.get('m')) |m| {
                    if (std.mem.eql(u8, m, "1")) {
                        try std.testing.expectEqual(@as(usize, 0), command.payload.len % 4);
                        try std.testing.expectEqual(chunk_base64_max, command.payload.len);
                    } else {
                        try std.testing.expectEqualStrings("0", m);
                        last_seen = true;
                    }
                }
                try joined.appendSlice(std.testing.allocator, command.payload);
            }
            try std.testing.expect(seen >= 1);
            try std.testing.expectEqual(data.len > chunk_bytes, last_seen);

            const decoded = try std.testing.allocator.alloc(u8, base64.decodedLen(joined.items));
            defer std.testing.allocator.free(decoded);
            try std.testing.expectEqualSlices(u8, data, try base64.decode(joined.items, decoded));
        }

        fn body(_: void, case: *fuzz.Case) !void {
            var input: [chunk_bytes * 2 + 16]u8 = undefined;
            try holds(fuzz.input(case.source, &input, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try fuzz.check(std.testing.allocator, {}, property.body, .{});
}

/// Whether `inner` points into `outer`. Test support, as in `device.zig`.
fn borrows(outer: []const u8, inner: []const u8) bool {
    const start = @intFromPtr(outer.ptr); // safe: an address compared, never read through
    const at = @intFromPtr(inner.ptr); // safe: an address compared, never read through
    return at >= start and at + inner.len <= start + outer.len;
}

test "parseGraphicsResponse reads an acknowledgement and a refusal" {
    const accepted = parseGraphicsResponse("\x1b_Gi=31;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?ImageId, ImageId.fromRaw(31)), accepted.id);
    try std.testing.expectEqual(@as(?ImageNumber, null), accepted.number);
    try std.testing.expectEqual(@as(?PlacementId, null), accepted.placement);
    try std.testing.expectEqualStrings("OK", accepted.message);
    try std.testing.expect(accepted.ok());

    const refused = parseGraphicsResponse("\x1b_Gi=31;ENOENT:No such file\x1b\\").?;
    try std.testing.expectEqual(@as(?ImageId, ImageId.fromRaw(31)), refused.id);
    try std.testing.expectEqualStrings("ENOENT:No such file", refused.message);
    try std.testing.expect(!refused.ok());
}

test "parseGraphicsResponse reads every key it names" {
    const response = parseGraphicsResponse("\x1b_Gi=1,I=2,p=3;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?ImageId, ImageId.fromRaw(1)), response.id);
    try std.testing.expectEqual(@as(?ImageNumber, ImageNumber.fromRaw(2)), response.number);
    try std.testing.expectEqual(@as(?PlacementId, PlacementId.fromRaw(3)), response.placement);
}

test "parseGraphicsResponse reads past keys it does not name" {
    // The protocol adds keys; a response carrying one is still a response.
    const response = parseGraphicsResponse("\x1b_Gi=31,q=2,z=0,p=7;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?ImageId, ImageId.fromRaw(31)), response.id);
    try std.testing.expectEqual(@as(?PlacementId, PlacementId.fromRaw(7)), response.placement);
    try std.testing.expectEqual(@as(?ImageNumber, null), response.number);
}

test "parseGraphicsResponse reads a response with no keys and one with no message" {
    const keyless = parseGraphicsResponse("\x1b_G;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?ImageId, null), keyless.id);
    try std.testing.expectEqualStrings("OK", keyless.message);
    try std.testing.expect(keyless.ok());

    const silent = parseGraphicsResponse("\x1b_Gi=31;\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 0), silent.message.len);
    try std.testing.expect(!silent.ok());
}

test "parseGraphicsResponse accepts BEL where a terminal uses it instead of ST" {
    const response = parseGraphicsResponse("\x1b_GI=99;EBADF:bad file descriptor\x07").?;
    try std.testing.expectEqual(@as(?ImageNumber, ImageNumber.fromRaw(99)), response.number);
    try std.testing.expectEqualStrings("EBADF:bad file descriptor", response.message);
}

test "parseGraphicsResponse borrows the message from the bytes it was given" {
    const bytes = "\x1b_Gi=31;OK\x1b\\";
    const response = parseGraphicsResponse(bytes).?;
    try std.testing.expect(borrows(bytes, response.message));
    try std.testing.expectEqual(bytes.ptr + 8, response.message.ptr);
}

test "parseGraphicsResponse returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b_Gi=31;OK", // no terminator
        "\x1b_Gi=31;OK\x1b", // a terminator cut in half
        "\x1b_G", // the introducer alone
        "\x1b_Gi=31", // no message and no terminator
        "\x1b_i=31;OK\x1b\\", // no `G`
        "\x1bPGi=31;OK\x1b\\", // DCS, not APC
        "\x1b[Gi=31;OK\x1b\\", // CSI, not APC
        "\x1b]Gi=31;OK\x1b\\", // OSC, not APC
        " \x1b_Gi=31;OK\x1b\\", // leading rubbish
        "\x1b_Gi=31;OK\x1b\\x", // trailing rubbish
        "\x1b_Gi=31OK\x1b\\", // no `;` before the message
        "\x1b_Gii=31;OK\x1b\\", // a key of more than one letter
        "\x1b_G1=31;OK\x1b\\", // a key that is not a letter
        "\x1b_Gi31;OK\x1b\\", // no `=`
        "\x1b_Gi=;OK\x1b\\", // no value
        "\x1b_Gi=x;OK\x1b\\", // a value that is not digits
        "\x1b_Gi=1,;OK\x1b\\", // a trailing comma with no key after it
        "\x1b_Gi=1,,p=2;OK\x1b\\", // an empty key
        "\x1b_Gi=1,i=2;OK\x1b\\", // a duplicated key
        "\x1b_Gq=1,q=2;OK\x1b\\", // a duplicated key this package does not name
        "\x1b_Gi=4294967296;OK\x1b\\", // an id too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseGraphicsResponse(bytes) == null);
    }
}

test "parseGraphicsResponse survives a number long enough to overflow" {
    try std.testing.expect(parseGraphicsResponse("\x1b_Gi=99999999999999999999;OK\x1b\\") == null);
    try std.testing.expect(parseGraphicsResponse("\x1b_GI=99999999999999999999;OK\x1b\\") == null);
    try std.testing.expect(parseGraphicsResponse("\x1b_Gp=99999999999999999999;OK\x1b\\") == null);
}

test "fuzz parseGraphicsResponse" {
    // The property: no input panics or overflows, the message is always a
    // sub-slice of the bytes it was read from, and the same bytes parse the
    // same way twice. The message is free-form and this package writes no
    // graphics commands, so there is no renderer to round trip through.
    const fuzz = @import("testing/fuzz.zig");
    const examples = [_][]const u8{
        "\x1b_Gi=31;OK\x1b\\",
        "\x1b_Gi=1,I=2,p=3;OK\x1b\\",
        "\x1b_Gi=31;ENOENT:No such file\x1b\\",
        "\x1b_GI=99;EBADF:bad\x07",
        "\x1b_G;OK\x1b\\",
        "\x1b_Gi=31;\x1b\\",
        "\x1b_Gi=31,q=2,z=0,p=7;OK\x1b\\",
        "\x1b_Gi=1,i=2;OK\x1b\\",
        "\x1b_Gi=4294967296;OK\x1b\\",
        "\x1b_Gii=31;OK\x1b\\",
        "\x1b_Gi=1,;OK\x1b\\",
        "\x1b_Gi=31;OK",
    };
    const property = struct {
        fn holds(bytes: []const u8) !void {
            const response = parseGraphicsResponse(bytes) orelse return;
            try std.testing.expect(borrows(bytes, response.message));
            try std.testing.expect(response.message.len <= bytes.len);

            const again = parseGraphicsResponse(bytes).?;
            try std.testing.expectEqual(response.id, again.id);
            try std.testing.expectEqual(response.number, again.number);
            try std.testing.expectEqual(response.placement, again.placement);
            try std.testing.expectEqualStrings(response.message, again.message);
            try std.testing.expectEqual(response.ok(), again.ok());
        }

        fn body(_: void, case: *fuzz.Case) !void {
            var input: [64]u8 = undefined;
            try holds(fuzz.input(case.source, &input, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try fuzz.check(std.testing.allocator, {}, property.body, .{});
}

comptime {
    std.debug.assert(diacritics.len >= 256);
    std.debug.assert(std.unicode.utf8ValidCodepoint(placeholder));
    for (diacritics) |cp| std.debug.assert(std.unicode.utf8ValidCodepoint(cp));
}

test "graphics domains retain scalar layout and nonzero probe bounds" {
    comptime {
        std.debug.assert(ImageId != ImageNumber);
        std.debug.assert(ImageId != PlacementId);
        std.debug.assert(ImageId != QueryImageId);
        std.debug.assert(GraphicsBytes != ImageId);
        std.debug.assert(Pixels != Cells);
        std.debug.assert(Pixels != GraphicsBytes);
        std.debug.assert(@sizeOf(ImageId) == @sizeOf(u32));
        std.debug.assert(@alignOf(ImageId) == @alignOf(u32));
        std.debug.assert(@sizeOf(Placement) == 60);
        std.debug.assert(@sizeOf(GraphicsBytes) == @sizeOf(u32));
    }
    try std.testing.expectError(error.InvalidId, QueryImageId.fromRaw(0));
    try std.testing.expectEqual(std.math.maxInt(u32), (try QueryImageId.fromRaw(std.math.maxInt(u32))).raw());
    const reply = parseGraphicsResponse("\x1b_Gi=4294967295,I=0,p=0;OK\x1b\\").?;
    try std.testing.expectEqual(ImageId.fromRaw(std.math.maxInt(u32)), reply.id.?);
    try std.testing.expectEqual(ImageNumber.fromRaw(0), reply.number.?);
    try std.testing.expectEqual(PlacementId.fromRaw(0), reply.placement.?);
}
