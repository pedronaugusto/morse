use crossterm::event::{Event, KeyCode, KeyModifiers, MouseButton, MouseEventKind};
use std::hint::black_box;
use std::io::{self, Read, Write};
use std::time::Instant;
use termwiz::input::{InputEvent, InputParser, KeyCode as TwKey, Modifiers as TwMods};

fn ct_mod(m: KeyModifiers) -> u8 {
    [
        (KeyModifiers::SHIFT, 1),
        (KeyModifiers::ALT, 2),
        (KeyModifiers::CONTROL, 4),
        (KeyModifiers::SUPER, 8),
        (KeyModifiers::HYPER, 16),
        (KeyModifiers::META, 32),
    ]
    .iter()
    .fold(0, |n, (flag, bit)| {
        n | if m.contains(*flag) { *bit } else { 0 }
    })
}
fn tw_mod(m: TwMods) -> u8 {
    [
        (TwMods::SHIFT, 1),
        (TwMods::ALT, 2),
        (TwMods::CTRL, 4),
        (TwMods::SUPER, 8),
    ]
    .iter()
    .fold(0, |n, (flag, bit)| {
        n | if m.contains(*flag) { *bit } else { 0 }
    })
}
fn paste(s: &str) {
    println!("paste_start");
    for c in s.chars() {
        println!("key:{}:0:press", c as u32);
    }
    println!("paste_end");
}
fn ct_event(e: &Event) {
    match e {
        Event::Key(k) => {
            let cp = match k.code {
                KeyCode::Char(c) => c as u32,
                KeyCode::Enter => 13,
                KeyCode::Tab | KeyCode::BackTab => 9,
                KeyCode::Esc => 27,
                KeyCode::Backspace => 127,
                KeyCode::Up => 57352,
                KeyCode::Down => 57353,
                KeyCode::Left => 57350,
                KeyCode::Right => 57351,
                _ => 0,
            };
            println!(
                "key:{cp}:{}:{}",
                ct_mod(k.modifiers),
                format!("{:?}", k.kind).to_lowercase()
            );
        }
        Event::Mouse(m) => {
            let (button, kind) = match m.kind {
                MouseEventKind::Down(b) => (b, "press"),
                MouseEventKind::Up(b) => (b, "release"),
                MouseEventKind::Drag(b) => (b, "motion"),
                MouseEventKind::Moved => (MouseButton::Left, "motion"),
                MouseEventKind::ScrollUp => {
                    println!(
                        "mouse:64:{}:{}:{}:press",
                        m.column + 1,
                        m.row + 1,
                        ct_mod(m.modifiers)
                    );
                    return;
                }
                MouseEventKind::ScrollDown => {
                    println!(
                        "mouse:65:{}:{}:{}:press",
                        m.column + 1,
                        m.row + 1,
                        ct_mod(m.modifiers)
                    );
                    return;
                }
                _ => {
                    println!("other:{e:?}");
                    return;
                }
            };
            let b = match button {
                MouseButton::Left => 0,
                MouseButton::Middle => 1,
                MouseButton::Right => 2,
            };
            println!(
                "mouse:{b}:{}:{}:{}:{kind}",
                m.column + 1,
                m.row + 1,
                ct_mod(m.modifiers)
            );
        }
        Event::Paste(s) => paste(s),
        Event::FocusGained => println!("focus_in"),
        Event::FocusLost => println!("focus_out"),
        _ => println!("other:{e:?}"),
    }
}
fn tw_event(e: &InputEvent) {
    match e {
        InputEvent::Key(k) => {
            let cp = match k.key {
                TwKey::Char(c) => c as u32,
                TwKey::Enter => 13,
                TwKey::Tab => 9,
                TwKey::Escape => 27,
                TwKey::Backspace => 127,
                TwKey::UpArrow => 57352,
                TwKey::DownArrow => 57353,
                TwKey::LeftArrow => 57350,
                TwKey::RightArrow => 57351,
                _ => 0,
            };
            println!("key:{cp}:{}:press", tw_mod(k.modifiers));
        }
        InputEvent::Mouse(m) => {
            let bits = m.mouse_buttons.bits();
            let b = if bits & 16 != 0 {
                if bits & 64 != 0 {
                    64
                } else {
                    65
                }
            } else if bits & 2 != 0 {
                0
            } else if bits & 8 != 0 {
                1
            } else if bits & 4 != 0 {
                2
            } else {
                3
            };
            println!("mouse:{b}:{}:{}:{}:press", m.x, m.y, tw_mod(m.modifiers));
        }
        InputEvent::Paste(s) => paste(s),
        _ => println!("other:{e:?}"),
    }
}
fn decode(side: &str, data: &[u8], chunk: usize, check: bool) -> usize {
    let mut count = 0;
    if side == "crossterm" {
        let mut pending = Vec::with_capacity(8192);
        // Same byte-at-a-time accumulation as crossterm's Unix event source.
        for (i, b) in data.iter().enumerate() {
            pending.push(*b);
            match crossterm::event::bench_parse_event(&pending, i + 1 < data.len()) {
                Ok(Some(e)) => {
                    count += 1;
                    if check {
                        ct_event(&e)
                    };
                    black_box(&e);
                    pending.clear()
                }
                Ok(None) => {}
                Err(_) => {
                    count += 1;
                    if check {
                        println!("error")
                    };
                    pending.clear()
                }
            }
        }
        if !pending.is_empty() {
            count += 1;
            if check {
                println!("incomplete")
            }
        }
    } else {
        let mut parser = InputParser::new();
        for (i, bytes) in data.chunks(chunk).enumerate() {
            parser.parse(
                bytes,
                |e| {
                    count += 1;
                    if check {
                        tw_event(&e)
                    };
                    black_box(&e);
                },
                (i + 1) * chunk < data.len(),
            );
        }
        parser.parse(
            &[],
            |e| {
                count += 1;
                if check {
                    tw_event(&e)
                };
                black_box(&e);
            },
            false,
        );
    }
    count
}
fn encode(side: &str, task: &str, data: &[u8], check: bool) -> usize {
    use crossterm::{
        cursor::MoveTo,
        style::Print,
        style::{Attribute, Color, SetAttribute, SetForegroundColor},
        Command,
    };
    use std::fmt::Write as _;
    use termwiz::{
        cell::Intensity,
        color::ColorSpec,
        escape::{
            apc::{KittyImage, KittyImagePlacement, KittyImageVerbosity},
            csi::{Cursor, Sgr, CSI},
            osc::{Hyperlink, OperatingSystemCommand},
            OneBased,
        },
    };
    let mut count = 0;
    let mut out = String::with_capacity(2048);
    for value in data {
        out.clear();
        if side == "crossterm" {
            match task {
                "style" => {
                    SetAttribute(Attribute::Bold).write_ansi(&mut out).unwrap();
                    SetForegroundColor(Color::Rgb {
                        r: *value,
                        g: 100,
                        b: 50,
                    })
                    .write_ansi(&mut out)
                    .unwrap();
                    SetAttribute(Attribute::Reset).write_ansi(&mut out).unwrap()
                }
                "cursor" => MoveTo(11, *value as u16).write_ansi(&mut out).unwrap(),
                // Print emits literal text: crossterm has no typed OSC 8 or kitty encoder.
                "link" | "graphics" => panic!("unavailable encoder"),
                _ => panic!("unknown task"),
            }
        } else {
            match task {
                "style" => write!(
                    out,
                    "{}{}{}",
                    CSI::Sgr(Sgr::Intensity(Intensity::Bold)),
                    CSI::Sgr(Sgr::Foreground(ColorSpec::TrueColor(
                        (*value, 100u8, 50u8).into()
                    ))),
                    CSI::Sgr(Sgr::Reset)
                )
                .unwrap(),
                "cursor" => write!(
                    out,
                    "{}",
                    CSI::Cursor(Cursor::Position {
                        line: OneBased::new(*value as u32 + 1),
                        col: OneBased::new(12)
                    })
                )
                .unwrap(),
                "link" => write!(
                    out,
                    "{}{}",
                    OperatingSystemCommand::SetHyperlink(Some(Hyperlink::new(
                        "https://example.org/bench"
                    ))),
                    OperatingSystemCommand::SetHyperlink(None)
                )
                .unwrap(),
                "graphics" => {
                    write!(
                        out,
                        "{}",
                        KittyImage::Display {
                            image_id: Some(*value as u32 + 1),
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
                                z_index: None
                            }
                        }
                    )
                    .unwrap();
                    out.push_str("\x1b\\")
                }
                _ => panic!("unknown task"),
            }
        }
        black_box(out.as_bytes());
        count += out.len();
        if check {
            for b in out.as_bytes() {
                print!("{b:02x}")
            }
            println!()
        }
    }
    let _ = std::mem::size_of::<Print<&str>>();
    count
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 5);
    let (side, task, mode) = (&args[1], &args[2], &args[3]);
    let chunk: usize = args[4].parse().unwrap();
    assert!(chunk > 0);
    let mut data = Vec::new();
    io::stdin().read_to_end(&mut data).unwrap();
    crossterm::style::force_color_output(true);
    let start = if mode == "full" {
        Some(Instant::now())
    } else {
        None
    };
    let count = if task == "decode" {
        decode(side, &data, chunk, mode == "check")
    } else {
        encode(side, task, &data, mode == "check")
    };
    let ns = start.map(|s| s.elapsed().as_nanos()).unwrap_or(0);
    if mode == "check" {
        println!("count:{count}")
    };
    if mode != "check" {
        println!("{}\t{count}\t{ns}", data.len())
    };
    io::stdout().flush().unwrap();
}
