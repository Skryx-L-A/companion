// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Starts the shell, or draws its frames to a directory and stops.

use std::path::Path;

use companion_linux::figure::{self, AlphaMask, FigureState};
use companion_linux::options::{self, Parsed};
use companion_linux::ui;
use gtk4::glib;

fn main() -> glib::ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match options::parse(&arguments) {
        Parsed::Help => {
            print!("{}", options::USAGE);
            glib::ExitCode::SUCCESS
        }
        Parsed::Error(message) => {
            eprintln!("{message}\n\n{}", options::USAGE);
            glib::ExitCode::FAILURE
        }
        Parsed::Run(options) => {
            if options.toggle_panel {
                toggle_panel()
            } else {
                match &options.render_to {
                    Some(directory) => render_frames(directory, options.size),
                    None => ui::run(*options),
                }
            }
        }
    }
}

/// `--panel-umschalten`: no window of its own, just the one message to the running shell.
fn toggle_panel() -> glib::ExitCode {
    match companion_linux::remote::toggle_panel() {
        Ok(()) => glib::ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            glib::ExitCode::FAILURE
        }
    }
}

/// Writes every frame of every state as a PNG and reports what it drew.
///
/// This is the figure's acceptance path on a machine with no compositor to show it on: the
/// same drawing code the widget uses, into a file instead of onto a surface.
fn render_frames(directory: &Path, size: i32) -> glib::ExitCode {
    let Ok(pixels) = usize::try_from(size) else {
        return glib::ExitCode::FAILURE;
    };
    if let Err(error) = std::fs::create_dir_all(directory) {
        eprintln!("{} lässt sich nicht anlegen: {error}", directory.display());
        return glib::ExitCode::FAILURE;
    }

    for state in FigureState::ALL {
        for frame in 0..state.frame_count() {
            let path = directory.join(format!("{}-{frame:03}.png", state.as_str()));
            match write_frame(&path, state, frame, pixels) {
                Ok(coverage) => println!(
                    "{} — {}, Bild {frame}, {:.1} Prozent der Fläche",
                    path.display(),
                    state.label(),
                    coverage * 100.0
                ),
                Err(error) => {
                    eprintln!("{} ließ sich nicht schreiben: {error}", path.display());
                    return glib::ExitCode::FAILURE;
                }
            }
        }
    }
    glib::ExitCode::SUCCESS
}

fn write_frame(
    path: &Path,
    state: FigureState,
    frame: usize,
    pixels: usize,
) -> Result<f64, Box<dyn std::error::Error>> {
    let size = i32::try_from(pixels)?;
    let surface = cairo::ImageSurface::create(cairo::Format::ARgb32, size, size)?;
    {
        let context = cairo::Context::new(&surface)?;
        figure::render::render(&context, state, frame, pixels as f64);
    }
    let mut file = std::fs::File::create(path)?;
    surface.write_to_png(&mut file)?;

    let coverage = AlphaMask::render(state, frame, pixels)
        .map(|mask| mask.coverage())
        .unwrap_or_default();
    Ok(coverage)
}
