//! One workload per morse operation, spelled with crossterm or termwiz.
//! Records are `u32 LE length, bytes`; the first byte of a writer's record
//! seeds its arguments exactly as bench/src/ops.zig does. termwiz takes owned
//! values (`String`, `Vec`), so its values are built before the clock, as a
//! caller holding them would; the clock covers spelling them.
use std::fmt::{self, Display, Write as _};
use std::hint::black_box;
use std::time::Instant;
use termwiz::escape::{
    apc::{
        KittyFrameCompositionMode, KittyImage, KittyImageCompression, KittyImageData, KittyImageDelete,
        KittyImageFormat, KittyImageFrame, KittyImageFrameCompose, KittyImagePlacement, KittyImageTransmit,
        KittyImageVerbosity,
    },
    csi::{
        Cursor, DecPrivateMode, Device, Edit, EraseInDisplay, EraseInLine, Keyboard, KittyKeyboardMode, Mode,
        MouseButton as TwButton, MouseReport, Window, XtermKeyModifierResource, CSI,
    },
    esc::{Esc, EscCode},
    osc::{ChangeColorPair, ColorOrQuery, DynamicColorNumber, FinalTermSemanticPrompt, OperatingSystemCommand, Progress, Selection},
    parser::Parser,
    Action, OneBased,
};

const URI: &str = "https://example.org/bench";
const QUERY_MODES: [u16; 4] = [1004, 2026, 2027, 2031];
const SET_MODES: [u16; 5] = [25, 1049, 2004, 2026, 1004];
const CAP_NAMES: [&str; 8] = ["RGB", "Smulx", "Setulc", "Tc", "Ms", "Ss", "Se", "colors"];

pub fn records(data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let len = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
        out.push(&data[pos + 4..pos + 4 + len]);
        pos += 4 + len;
    }
    out
}

fn n(r: &[u8]) -> u32 {
    r[0] as u32 + 1
}
fn body(r: &[u8]) -> &str {
    std::str::from_utf8(&r[1..]).unwrap()
}

// ---------------------------------------------------------------- crossterm

fn ct_write(name: &str, r: &[u8], out: &mut String) -> Option<fmt::Result> {
    use crossterm::{cursor::*, event::*, terminal::*, Command};
    let v = r[0];
    let c = n(r) as u16;
    Some(match name {
        "cursorUp" => MoveUp(c).write_ansi(out),
        "cursorDown" => MoveDown(c).write_ansi(out),
        "cursorRight" => MoveRight(c).write_ansi(out),
        "cursorLeft" => MoveLeft(c).write_ansi(out),
        "cursorNextLine" => MoveToNextLine(c).write_ansi(out),
        "cursorPrevLine" => MoveToPreviousLine(c).write_ansi(out),
        "cursorColumn" => MoveToColumn(c - 1).write_ansi(out),
        "cursorRow" => MoveToRow(c - 1).write_ansi(out),
        "cursorSave" => SavePosition.write_ansi(out),
        "cursorRestore" => RestorePosition.write_ansi(out),
        "clearLine" => Clear(ClearType::UntilNewLine).write_ansi(out),
        "clearScreen" => Clear(ClearType::FromCursorDown).write_ansi(out),
        "scrollUp" => ScrollUp(c).write_ansi(out),
        "scrollDown" => ScrollDown(c).write_ansi(out),
        "resetStyle" => crossterm::style::SetAttribute(crossterm::style::Attribute::Reset).write_ansi(out),
        "altScreen" if v & 1 != 0 => EnterAlternateScreen.write_ansi(out),
        "altScreen" => LeaveAlternateScreen.write_ansi(out),
        "bracketedPaste" if v & 1 != 0 => EnableBracketedPaste.write_ansi(out),
        "bracketedPaste" => DisableBracketedPaste.write_ansi(out),
        "syncOutput" if v & 1 != 0 => BeginSynchronizedUpdate.write_ansi(out),
        "syncOutput" => EndSynchronizedUpdate.write_ansi(out),
        "focusEvents" if v & 1 != 0 => EnableFocusChange.write_ansi(out),
        "focusEvents" => DisableFocusChange.write_ansi(out),
        "cursorVisible" if v & 1 != 0 => Show.write_ansi(out),
        "cursorVisible" => Hide.write_ansi(out),
        "autoWrap" if v & 1 != 0 => EnableLineWrap.write_ansi(out),
        "autoWrap" => DisableLineWrap.write_ansi(out),
        "kittyKeyboardPush" => {
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::from_bits_truncate((v | 1) & 15)).write_ansi(out)
        }
        "kittyKeyboardPop" => PopKeyboardEnhancementFlags.write_ansi(out),
        "cursorShape" => [
            SetCursorStyle::BlinkingBlock,
            SetCursorStyle::SteadyBlock,
            SetCursorStyle::BlinkingUnderScore,
            SetCursorStyle::SteadyUnderScore,
            SetCursorStyle::BlinkingBar,
            SetCursorStyle::SteadyBar,
        ][v as usize % 6]
            .write_ansi(out),
        "resizeTextArea" => SetSize(80 + v as u16, 24 + v as u16).write_ansi(out),
        _ => return None,
    })
}

// ------------------------------------------------------------------ termwiz

struct Cat(Vec<Box<dyn Display>>);
impl Display for Cat {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        for part in &self.0 {
            part.fmt(f)?;
        }
        Ok(())
    }
}
/// termwiz's kitty Display leaves the terminator to the caller.
struct Apc(KittyImage);
impl Display for Apc {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.0.fmt(f)?;
        f.write_str("\x1b\\")
    }
}

fn dec(code: u16, on: bool) -> CSI {
    let mode = DecPrivateMode::Unspecified(code);
    CSI::Mode(if on { Mode::SetDecPrivateMode(mode) } else { Mode::ResetDecPrivateMode(mode) })
}
fn ob(v: u32) -> OneBased {
    OneBased::new(v)
}
fn dynamic(v: u8) -> DynamicColorNumber {
    [DynamicColorNumber::TextForegroundColor, DynamicColorNumber::TextBackgroundColor, DynamicColorNumber::TextCursorColor]
        [v as usize % 3]
}
fn rgb(v: u8) -> ColorOrQuery {
    ColorOrQuery::Color((v, 0x64u8, 0x32u8).into())
}
fn transmit(r: &[u8], frame: bool) -> KittyImage {
    let t = KittyImageTransmit {
        format: Some(KittyImageFormat::Rgba),
        data: KittyImageData::DirectBin(r[1..].to_vec()),
        width: Some(1),
        height: Some(((r.len() - 1) / 4) as u32),
        image_id: Some(n(r)),
        image_number: None,
        compression: KittyImageCompression::None,
        more_data_follows: false,
    };
    if frame {
        KittyImage::TransmitFrame {
            transmit: t,
            frame: KittyImageFrame {
                x: None,
                y: None,
                base_frame: None,
                frame_number: None,
                duration_ms: None,
                composition_mode: KittyFrameCompositionMode::AlphaBlending,
                background_pixel: None,
            },
            verbosity: KittyImageVerbosity::Verbose,
        }
    } else {
        KittyImage::TransmitData { transmit: t, verbosity: KittyImageVerbosity::OnlyErrors }
    }
}

fn tw_value(name: &str, r: &[u8]) -> Option<Box<dyn Display>> {
    let v = r[0];
    let c = n(r);
    let csi = |x: CSI| -> Option<Box<dyn Display>> { Some(Box::new(x)) };
    let osc = |x: OperatingSystemCommand| -> Option<Box<dyn Display>> { Some(Box::new(x)) };
    match name {
        "cursorUp" => csi(CSI::Cursor(Cursor::Up(c))),
        "cursorDown" => csi(CSI::Cursor(Cursor::Down(c))),
        "cursorRight" => csi(CSI::Cursor(Cursor::Right(c))),
        "cursorLeft" => csi(CSI::Cursor(Cursor::Left(c))),
        "cursorNextLine" => csi(CSI::Cursor(Cursor::NextLine(c))),
        "cursorPrevLine" => csi(CSI::Cursor(Cursor::PrecedingLine(c))),
        "cursorColumn" => csi(CSI::Cursor(Cursor::CharacterAbsolute(ob(c)))),
        "cursorRow" => csi(CSI::Cursor(Cursor::LinePositionAbsolute(c))),
        "cursorSave" => Some(Box::new(Esc::Code(EscCode::DecSaveCursorPosition))),
        "cursorRestore" => Some(Box::new(Esc::Code(EscCode::DecRestoreCursorPosition))),
        "clearLine" => csi(CSI::Edit(Edit::EraseInLine(EraseInLine::EraseToEndOfLine))),
        "clearScreen" => csi(CSI::Edit(Edit::EraseInDisplay(EraseInDisplay::EraseToEndOfDisplay))),
        "scrollRegion" => csi(CSI::Cursor(Cursor::SetTopAndBottomMargins { top: ob(1 + v as u32 % 8), bottom: ob(20 + v as u32) })),
        "scrollUp" => csi(CSI::Edit(Edit::ScrollUp(c))),
        "scrollDown" => csi(CSI::Edit(Edit::ScrollDown(c))),
        "insertLines" => csi(CSI::Edit(Edit::InsertLine(c))),
        "deleteLines" => csi(CSI::Edit(Edit::DeleteLine(c))),
        "insertChars" => csi(CSI::Edit(Edit::InsertCharacter(c))),
        "deleteChars" => csi(CSI::Edit(Edit::DeleteCharacter(c))),
        "eraseChars" => csi(CSI::Edit(Edit::EraseCharacter(c))),
        "repeatChar" => csi(CSI::Edit(Edit::Repeat(c))),
        "resetStyle" => csi(CSI::Sgr(termwiz::escape::csi::Sgr::Reset)),
        "setMode" => csi(dec(SET_MODES[v as usize % 5], v & 1 != 0)),
        "altScreen" => csi(dec(1049, v & 1 != 0)),
        "bracketedPaste" => csi(dec(2004, v & 1 != 0)),
        "syncOutput" => csi(dec(2026, v & 1 != 0)),
        "focusEvents" => csi(dec(1004, v & 1 != 0)),
        "cursorVisible" => csi(dec(25, v & 1 != 0)),
        "unicodeCore" => csi(dec(2027, v & 1 != 0)),
        "inBandResize" => csi(dec(2048, v & 1 != 0)),
        "win32Input" => csi(dec(9001, v & 1 != 0)),
        "autoWrap" => csi(dec(7, v & 1 != 0)),
        "colorScheme" => csi(dec(2031, v & 1 != 0)),
        // The same mode list morse writes: other tracking and encodings off, then any-motion SGR on.
        "mouse" => Some(Box::new(Cat(
            [(9, false), (1000, false), (1002, false), (1005, false), (1015, false), (1016, false), (1003, true), (1006, true)]
                .iter()
                .map(|&(m, on)| Box::new(dec(m, on)) as Box<dyn Display>)
                .collect(),
        ))),
        "mouseOff" => Some(Box::new(Cat(
            [9, 1000, 1002, 1003, 1005, 1006, 1015, 1016].iter().map(|&m| Box::new(dec(m, false)) as Box<dyn Display>).collect(),
        ))),
        "kittyKeyboardPush" => csi(CSI::Keyboard(Keyboard::PushKittyState {
            flags: termwiz::escape::csi::KittyKeyboardFlags::from_bits_truncate(((v | 1) & 15) as u16),
            mode: KittyKeyboardMode::AssignAll,
        })),
        "kittyKeyboardPop" => csi(CSI::Keyboard(Keyboard::PopKittyState(1))),
        "kittyKeyboardQuery" => csi(CSI::Keyboard(Keyboard::QueryKittySupport)),
        "kittyKeyboardSet" => csi(CSI::Keyboard(Keyboard::SetKittyState {
            flags: termwiz::escape::csi::KittyKeyboardFlags::from_bits_truncate(((v | 1) & 15) as u16),
            mode: [KittyKeyboardMode::AssignAll, KittyKeyboardMode::SetSpecified, KittyKeyboardMode::ClearSpecified][v as usize % 3],
        })),
        "modifyKeys" => csi(CSI::Mode(Mode::XtermKeyMode { resource: XtermKeyModifierResource::OtherKeys, value: Some((v % 3) as i64) })),
        "cursorShape" => csi(CSI::Cursor(Cursor::CursorStyle(
            [
                termwiz::escape::csi::CursorStyle::BlinkingBlock,
                termwiz::escape::csi::CursorStyle::SteadyBlock,
                termwiz::escape::csi::CursorStyle::BlinkingUnderline,
                termwiz::escape::csi::CursorStyle::SteadyUnderline,
                termwiz::escape::csi::CursorStyle::BlinkingBar,
                termwiz::escape::csi::CursorStyle::SteadyBar,
            ][v as usize % 6],
        ))),
        "queryMode" => csi(CSI::Mode(Mode::QueryDecPrivateMode(DecPrivateMode::Unspecified(QUERY_MODES[v as usize % 4])))),
        "requestCursorPosition" => csi(CSI::Cursor(Cursor::RequestActivePositionReport)),
        "queryDeviceAttributes" => csi(CSI::Device(Box::new(Device::RequestPrimaryDeviceAttributes))),
        "querySecondaryDeviceAttributes" => csi(CSI::Device(Box::new(Device::RequestSecondaryDeviceAttributes))),
        "queryVersion" => csi(CSI::Device(Box::new(Device::RequestTerminalNameAndVersion))),
        "queryColor" => osc(OperatingSystemCommand::ChangeDynamicColors(dynamic(v), vec![ColorOrQuery::Query])),
        "setColor" => osc(OperatingSystemCommand::ChangeDynamicColors(dynamic(v), vec![rgb(v)])),
        "resetColor" => osc(OperatingSystemCommand::ResetDynamicColor(dynamic(v))),
        "queryPaletteColor" => osc(OperatingSystemCommand::ChangeColorNumber(vec![ChangeColorPair { palette_index: v, color: ColorOrQuery::Query }])),
        "setPaletteColor" => osc(OperatingSystemCommand::ChangeColorNumber(vec![ChangeColorPair { palette_index: v, color: rgb(v) }])),
        "resetPaletteColor" => osc(OperatingSystemCommand::ResetColors(vec![v])),
        "resetPalette" => osc(OperatingSystemCommand::ResetColors(vec![])),
        "queryWindowSize" => csi(CSI::Window(Box::new(
            [Window::ReportTextAreaSizePixels, Window::ReportCellSizePixels, Window::ReportTextAreaSizeCells][v as usize % 3].clone(),
        ))),
        "resizeTextArea" => csi(CSI::Window(Box::new(Window::ResizeWindowCells { width: Some(80 + v as i64), height: Some(24 + v as i64) }))),
        "queryCapability" => Some(Box::new(Cat(vec![
            Box::new(Action::XtGetTcap(vec![(if v & 1 != 0 { "RGB" } else { "Smulx" }).to_string()])),
            Box::new("\x1b\\"),
        ]))),
        "queryCapabilities" => Some(Box::new(Cat(vec![
            Box::new(Action::XtGetTcap((0..r.len() - 1).map(|i| CAP_NAMES[i % 8].to_string()).collect())),
            Box::new("\x1b\\"),
        ]))),
        "transmitImage" => Some(Box::new(Apc(transmit(r, false)))),
        "transmitFrame" => Some(Box::new(Apc(transmit(r, true)))),
        "placeImage" => Some(Box::new(Apc(KittyImage::Display {
            image_id: Some(c),
            image_number: None,
            verbosity: KittyImageVerbosity::Verbose,
            placement: KittyImagePlacement {
                x: None,
                y: None,
                w: None,
                h: None,
                x_offset: None,
                y_offset: None,
                columns: None,
                rows: None,
                do_not_move_cursor: true,
                placement_id: None,
                z_index: None,
            },
        }))),
        "deleteImage" => Some(Box::new(Apc(KittyImage::Delete {
            what: KittyImageDelete::ByImageId { image_id: c, placement_id: None, delete: false },
            verbosity: KittyImageVerbosity::Verbose,
        }))),
        "queryGraphics" => Some(Box::new(Apc(KittyImage::Query {
            transmit: KittyImageTransmit {
                format: Some(KittyImageFormat::Rgb),
                data: KittyImageData::DirectBin(vec![0, 0, 0]),
                width: Some(1),
                height: Some(1),
                image_id: Some(c),
                image_number: None,
                compression: KittyImageCompression::None,
                more_data_follows: false,
            },
        }))),
        "composeFrames" => Some(Box::new(Apc(KittyImage::ComposeFrame {
            frame: KittyImageFrameCompose {
                image_id: Some(c),
                image_number: None,
                target_frame: Some(2),
                source_frame: Some(1),
                x: None,
                y: None,
                w: Some(8 + v as u32),
                h: Some(8),
                src_x: None,
                src_y: None,
                composition_mode: KittyFrameCompositionMode::AlphaBlending,
            },
            verbosity: KittyImageVerbosity::Verbose,
        }))),
        "title" => osc(OperatingSystemCommand::SetWindowTitle(body(r).to_string())),
        "iconName" => osc(OperatingSystemCommand::SetIconName(body(r).to_string())),
        "titlePush" => csi(CSI::Window(Box::new(Window::PushWindowTitle))),
        "titlePop" => csi(CSI::Window(Box::new(Window::PopWindowTitle))),
        "workingDirectory" => osc(OperatingSystemCommand::CurrentWorkingDirectory(body(r).to_string())),
        "hyperlink" => Some(Box::new(Cat(vec![
            Box::new(OperatingSystemCommand::SetHyperlink(Some(termwiz::hyperlink::Hyperlink::new(URI)))),
            Box::new(body(r).to_string()),
            Box::new(OperatingSystemCommand::SetHyperlink(None)),
        ]))),
        "promptStart" => osc(OperatingSystemCommand::FinalTermSemanticPrompt(FinalTermSemanticPrompt::FreshLineAndStartPrompt { aid: None, cl: None })),
        "promptEnd" => osc(OperatingSystemCommand::FinalTermSemanticPrompt(FinalTermSemanticPrompt::MarkEndOfPromptAndStartOfInputUntilNextMarker)),
        "commandStart" => osc(OperatingSystemCommand::FinalTermSemanticPrompt(FinalTermSemanticPrompt::MarkEndOfInputAndStartOfOutput { aid: None })),
        "commandEnd" => osc(OperatingSystemCommand::FinalTermSemanticPrompt(FinalTermSemanticPrompt::CommandStatus { status: v as i32, aid: None })),
        "progress" => osc(OperatingSystemCommand::ConEmuProgress(Progress::SetPercentage(v % 101))),
        "clipboardWrite" => osc(OperatingSystemCommand::SetSelection(Selection::CLIPBOARD, body(r).to_string())),
        "clipboardRequest" => osc(OperatingSystemCommand::QuerySelection(Selection::CLIPBOARD)),
        "notify" => osc(OperatingSystemCommand::RxvtExtension(vec!["notify".into(), "bench".into(), body(r).to_string()])),
        "notify9" => osc(OperatingSystemCommand::SystemNotification(body(r).to_string())),
        "itermImage" => osc(OperatingSystemCommand::ITermProprietary(termwiz::escape::osc::ITermProprietary::File(Box::new(
            termwiz::escape::osc::ITermFileData {
                name: Some("bench.png".into()),
                size: Some(r.len() - 1),
                width: termwiz::escape::osc::ITermDimension::Cells(40),
                height: termwiz::escape::osc::ITermDimension::Automatic,
                preserve_aspect_ratio: true,
                inline: true,
                do_not_move_cursor: false,
                data: r[1..].to_vec(),
            },
        )))),
        "encodeMouse" => csi(CSI::Mouse(MouseReport::SGR1006 {
            x: c as u16,
            y: 12,
            button: if r[0] & 1 == 0 { TwButton::Button1Press } else { TwButton::Button1Release },
            modifiers: termwiz::input::Modifiers::NONE,
        })),
        _ => None,
    }
}

// The key workload: the same sixteen keys and eight modifier sets as
// bench/src/ops.zig `benchKey`, seeded by the record's first byte.
fn bench_key(v: u8) -> (termwiz::input::KeyCode, termwiz::input::Modifiers) {
    use termwiz::input::{KeyCode as K, Modifiers as Mo};
    let key = [
        K::Char('a'), K::Char('z'), K::Char('1'), K::Char('/'), K::Char(' '), K::Enter, K::Tab, K::Backspace,
        K::Escape, K::UpArrow, K::LeftArrow, K::Home, K::PageUp, K::Delete, K::Function(1), K::Function(5),
    ][v as usize % 16]
    .clone();
    let mods = [Mo::NONE, Mo::SHIFT, Mo::CTRL, Mo::ALT, Mo::CTRL | Mo::SHIFT, Mo::CTRL | Mo::ALT, Mo::ALT | Mo::SHIFT, Mo::NONE]
        [(v as usize + v as usize / 16) % 8];
    // A terminal hands its encoder the character shift typed.
    let key = match key {
        K::Char(c) if mods.contains(Mo::SHIFT) => K::Char(match c {
            'a'..='z' => c.to_ascii_uppercase(),
            '1' => '!',
            '/' => '?',
            _ => c,
        }),
        k => k,
    };
    (key, mods)
}

fn tw_encode(name: &str, r: &[u8], out: &mut String) -> Option<termwiz::Result<()>> {
    use termwiz::escape::csi::KittyKeyboardFlags as F;
    use termwiz::input::{KeyCodeEncodeModes, KeyboardEncoding};
    if name != "encodeKey" {
        return None;
    }
    let (key, mods) = bench_key(r[0]);
    let encoding = if r[1] == 0 {
        KeyboardEncoding::Xterm
    } else {
        KeyboardEncoding::Kitty(F::DISAMBIGUATE_ESCAPE_CODES | F::REPORT_ALTERNATE_KEYS)
    };
    let modes = KeyCodeEncodeModes { encoding, application_cursor_keys: false, newline_mode: false, modify_other_keys: None };
    Some(key.encode(mods, modes, true).map(|s| out.push_str(&s)))
}

// ------------------------------------------------------------------ readers

fn mouse_line(button: u32, x: u32, y: u32, mods: u8, kind: &str) -> String {
    format!("mouse:{button}:{x}:{y}:{mods}:{kind}")
}

fn ct_read(name: &str, r: &[u8], check: bool) -> Option<Option<String>> {
    use crossterm::event::{Event, MouseButton, MouseEventKind};
    Some(match name {
        "parseMouse" | "parseMouseX10" | "parseMouseRxvt" => match crossterm::event::bench_parse_event(r, false) {
            Ok(Some(Event::Mouse(m))) => {
                black_box(&m);
                if !check {
                    return Some(Some(String::new()));
                }
                let mods = crate::ct_mod(m.modifiers);
                let (b, kind) = match m.kind {
                    MouseEventKind::Down(b) => (b, "press"),
                    MouseEventKind::Up(b) => (b, "release"),
                    MouseEventKind::Drag(b) => (b, "motion"),
                    MouseEventKind::Moved => (MouseButton::Left, "motion"),
                    MouseEventKind::ScrollUp => {
                        return Some(Some(mouse_line(64, m.column as u32 + 1, m.row as u32 + 1, mods, "press")))
                    }
                    MouseEventKind::ScrollDown => {
                        return Some(Some(mouse_line(65, m.column as u32 + 1, m.row as u32 + 1, mods, "press")))
                    }
                    _ => return Some(Some(format!("other:{:?}", m.kind))),
                };
                let b = match b {
                    MouseButton::Left => 0,
                    MouseButton::Middle => 1,
                    MouseButton::Right => 2,
                };
                Some(mouse_line(b, m.column as u32 + 1, m.row as u32 + 1, mods, kind))
            }
            _ => None,
        },
        "parseCursorPosition" | "parseKittyKeyboardReply" | "parseDeviceAttributes" => {
            match crossterm::event::bench_parse_reply(r) {
                Some((kind, a, b)) => {
                    black_box((kind, a, b));
                    Some(match kind {
                        0 => format!("{};{}", b + 1, a + 1),
                        1 => format!("flags:{a}"),
                        _ => "present".into(),
                    })
                }
                None => None,
            }
        }
        _ => return None,
    })
}

struct TwReader {
    parser: Parser,
    input: termwiz::input::InputParser,
}

fn tw_read(st: &mut TwReader, name: &str, r: &[u8], check: bool) -> Option<Option<String>> {
    use termwiz::escape::csi::Sgr;
    use termwiz::input::InputEvent;
    if name == "parseMouse" {
        let mut line = None;
        st.input.parse(
            r,
            |e| {
                if let InputEvent::Mouse(m) = &e {
                    black_box(m);
                    line = Some(if check { format!("{}:{}:{}", m.x, m.y, crate::tw_mod(m.modifiers)) } else { String::new() });
                }
            },
            false,
        );
        return Some(line);
    }
    if name == "strip" {
        // termwiz types every sequence into an Action; the text left is
        // what it prints and the C0 controls it carries.
        let mut text = String::with_capacity(r.len());
        st.parser.parse(r, |a| match a {
            Action::Print(c) => text.push(c),
            Action::PrintString(s) => text.push_str(&s),
            Action::Control(c) => text.push(c as u8 as char),
            _ => {}
        });
        black_box(&text);
        return Some(Some(if check { text } else { String::new() }));
    }
    if name == "sixelDraw" {
        return Some(sixel_draw(st, r));
    }
    let mut actions = Vec::with_capacity(2);
    let known = matches!(
        name,
        "applySgr" | "parseCursorPosition" | "parseDeviceAttributes" | "parseKittyKeyboardReply" | "parseColorReply"
            | "parsePaletteReply" | "parseWindowSize" | "clipboardReplyDecoded" | "parseHyperlink" | "parseCsi"
            | "parseControlString"
    );
    if !known {
        return None;
    }
    st.parser.parse(r, |a| actions.push(a));
    black_box(&actions);
    if !check {
        return Some(if actions.is_empty() { None } else { Some(String::new()) });
    }
    let line = match (name, actions.first()) {
        ("applySgr", _) => {
            let (mut bold, mut italic, mut underline) = (false, false, false);
            let (mut fg, mut bg) = (spec(&termwiz::color::ColorSpec::Default), spec(&termwiz::color::ColorSpec::Default));
            for a in &actions {
                if let Action::CSI(CSI::Sgr(s)) = a {
                    match s {
                        Sgr::Intensity(termwiz::cell::Intensity::Bold) => bold = true,
                        Sgr::Italic(true) => italic = true,
                        Sgr::Underline(u) => underline = *u != termwiz::cell::Underline::None,
                        Sgr::Foreground(c) => fg = spec(c),
                        Sgr::Background(c) => bg = spec(c),
                        _ => {}
                    }
                }
            }
            format!("bold={bold} italic={italic} underline={underline} fg={fg} bg={bg}")
        }
        ("parseCursorPosition", Some(Action::CSI(CSI::Cursor(Cursor::ActivePositionReport { line, col })))) => {
            format!("{};{}", line.as_one_based(), col.as_one_based())
        }
        // Spelled back and stripped of the class, the attribute codes it typed.
        ("parseDeviceAttributes", Some(Action::CSI(CSI::Device(d)))) => {
            let s = d.to_string();
            s.trim_end_matches('c').splitn(2, ';').nth(1).unwrap_or("").to_string()
        }
        ("parseKittyKeyboardReply", Some(Action::CSI(CSI::Keyboard(Keyboard::ReportKittyState(f))))) => {
            format!("flags:{}", f.bits())
        }
        ("parseColorReply", Some(Action::OperatingSystemCommand(o))) => match &**o {
            OperatingSystemCommand::ChangeDynamicColors(which, colors) => match colors.first() {
                Some(ColorOrQuery::Color(c)) => {
                    let (r8, g8, b8, _) = c.to_srgb_u8();
                    format!("{}:{r8}:{g8}:{b8}", *which as u8)
                }
                _ => format!("{o:?}"),
            },
            _ => format!("{o:?}"),
        },
        ("parsePaletteReply", Some(Action::OperatingSystemCommand(o))) => match &**o {
            OperatingSystemCommand::ChangeColorNumber(pairs) => match pairs.first() {
                Some(ChangeColorPair { palette_index, color: ColorOrQuery::Color(c) }) => {
                    let (r8, g8, b8, _) = c.to_srgb_u8();
                    format!("{palette_index}:{r8}:{g8}:{b8}")
                }
                _ => format!("{o:?}"),
            },
            _ => format!("{o:?}"),
        },
        ("parseWindowSize", Some(Action::CSI(CSI::Window(w)))) => match &**w {
            Window::ResizeWindowCells { width: Some(wd), height: Some(h) } => format!("8:{h}:{wd}"),
            other => format!("{other:?}"),
        },
        ("clipboardReplyDecoded", Some(Action::OperatingSystemCommand(o))) => match &**o {
            OperatingSystemCommand::SetSelection(_, text) => text.as_bytes().iter().map(|b| format!("{b:02x}")).collect(),
            _ => format!("{o:?}"),
        },
        ("parseHyperlink", Some(Action::OperatingSystemCommand(o))) => match &**o {
            OperatingSystemCommand::SetHyperlink(Some(link)) => {
                let mut params: Vec<_> = link.params().iter().map(|(k, v)| format!("{k}={v}")).collect();
                params.sort();
                format!("{}|{}", params.join(":"), link.uri())
            }
            _ => format!("{o:?}"),
        },
        ("parseCsi", Some(Action::CSI(_))) => "csi".into(),
        ("parseControlString", Some(Action::OperatingSystemCommand(_))) => "]".into(),
        ("parseControlString", Some(Action::KittyImage(_))) => "_".into(),
        ("parseControlString", Some(Action::DeviceControl(_))) => "P".into(),
        (_, Some(a)) => format!("{a:?}"),
        (_, None) => return Some(None),
    };
    Some(Some(line))
}

/// Draws a sixel string with termwiz's reader: the register of every pixel
/// as two hex digits, `ff` where nothing was drawn. The reference the bench
/// holds morse's sixel writer to.
fn sixel_draw(st: &mut TwReader, r: &[u8]) -> Option<String> {
    use termwiz::escape::SixelData;
    let mut actions = Vec::new();
    st.parser.parse(r, |a| actions.push(a));
    let sixel = actions.into_iter().find_map(|a| if let Action::Sixel(s) = a { Some(s) } else { None })?;
    let (w, h) = (sixel.pixel_width? as usize, sixel.pixel_height? as usize);
    let mut grid = vec![0xffu8; w * h];
    let (mut x, mut band, mut colour) = (0usize, 0usize, 0u16);
    let put = |x: usize, band: usize, colour: u16, bits: u8, grid: &mut Vec<u8>| {
        for row in 0..6 {
            if bits & (1 << row) != 0 && x < w && band * 6 + row < h {
                grid[(band * 6 + row) * w + x] = colour as u8;
            }
        }
    };
    for d in &sixel.data {
        match d {
            SixelData::Data(v) => {
                put(x, band, colour, *v, &mut grid);
                x += 1;
            }
            SixelData::Repeat { repeat_count, data } => {
                for _ in 0..*repeat_count {
                    put(x, band, colour, *data, &mut grid);
                    x += 1;
                }
            }
            SixelData::SelectColorMapEntry(c) => colour = *c,
            SixelData::CarriageReturn => x = 0,
            SixelData::NewLine => {
                x = 0;
                band += 1;
            }
            _ => {}
        }
    }
    Some(grid.iter().map(|b| format!("{b:02x}")).collect())
}

fn spec(c: &termwiz::color::ColorSpec) -> String {
    match c {
        termwiz::color::ColorSpec::TrueColor(t) => {
            let (r, g, b, _) = t.to_srgb_u8();
            format!("rgb:{r},{g},{b}")
        }
        termwiz::color::ColorSpec::PaletteIndex(i) => format!("palette:{i},0,0"),
        termwiz::color::ColorSpec::Default => "default:0,0,0".into(),
    }
}

/// Returns false when this side has no call for the operation.
pub fn run(side: &str, name: &str, data: &[u8], check: bool, timed: bool) -> bool {
    let recs = records(data);
    let mut out = String::with_capacity(2 * recs.iter().map(|r| r.len()).max().unwrap_or(0) + 65536);
    let mut count = 0usize;
    let probe = recs.first().copied().unwrap_or(&[0]);
    let available = match side {
        "crossterm" => ct_write(name, probe, &mut String::new()).is_some() || ct_read(name, probe, false).is_some(),
        _ => {
            tw_value(name, probe).is_some()
                || tw_encode(name, probe, &mut String::new()).is_some()
                || tw_read(&mut TwReader { parser: Parser::new(), input: termwiz::input::InputParser::new() }, name, probe, false).is_some()
        }
    };
    if !available {
        println!("unavailable");
        return false;
    }
    let mut lines = Vec::new();
    let emit = |out: &str, lines: &mut Vec<String>| {
        if check {
            lines.push(out.as_bytes().iter().map(|b| format!("{b:02x}")).collect());
        }
    };
    let elapsed;
    if side == "crossterm" && ct_write(name, probe, &mut String::new()).is_some() {
        let start = timed.then(Instant::now);
        for r in &recs {
            out.clear();
            ct_write(name, r, &mut out).unwrap().unwrap();
            black_box(out.as_bytes());
            count += out.len();
            emit(&out, &mut lines);
        }
        elapsed = start.map(|s| s.elapsed().as_nanos()).unwrap_or(0);
    } else if side == "termwiz" && tw_encode(name, probe, &mut String::new()).is_some() {
        let start = timed.then(Instant::now);
        for r in &recs {
            out.clear();
            tw_encode(name, r, &mut out).unwrap().unwrap();
            black_box(out.as_bytes());
            count += out.len();
            emit(&out, &mut lines);
        }
        elapsed = start.map(|s| s.elapsed().as_nanos()).unwrap_or(0);
    } else if side == "termwiz" && tw_value(name, probe).is_some() {
        let values: Vec<_> = recs.iter().map(|r| tw_value(name, r).unwrap()).collect();
        let start = timed.then(Instant::now);
        for value in &values {
            out.clear();
            write!(out, "{value}").unwrap();
            black_box(out.as_bytes());
            count += out.len();
            emit(&out, &mut lines);
        }
        elapsed = start.map(|s| s.elapsed().as_nanos()).unwrap_or(0);
    } else {
        let mut st = TwReader { parser: Parser::new(), input: termwiz::input::InputParser::new() };
        let start = timed.then(Instant::now);
        for r in &recs {
            let line = if side == "crossterm" { ct_read(name, r, check) } else { tw_read(&mut st, name, r, check) };
            let line = line.unwrap().unwrap_or_else(|| panic!("{side} rejected {name} record {r:?}"));
            count += 1;
            emit(&line, &mut lines);
        }
        elapsed = start.map(|s| s.elapsed().as_nanos()).unwrap_or(0);
    }
    if check {
        for l in &lines {
            println!("{l}");
        }
        println!("count:{count}");
    } else {
        println!("{}\t{count}\t{elapsed}", data.len());
    }
    true
}
