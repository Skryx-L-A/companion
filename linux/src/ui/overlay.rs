// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The figure: a layer-shell surface with no border, no background and no taskbar entry.
//!
//! `DESIGN.md` § Figur und Overlay asks for a window that is "randlos, transparent, immer
//! oben, ohne Eintrag in Dock oder Taskbar", in a corner of the person's choosing, and that
//! lets a click outside the figure through. On Wayland the first four come from the
//! wlr-layer-shell protocol, which a layer surface gets by construction — it is not a
//! toplevel, so no taskbar and no window list ever sees it. The fifth is the input region
//! below.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{gdk, glib};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use crate::figure::{AlphaMask, FigureEvent, FigureState, FigureStateMachine, mask, render};
use crate::options::{Corner, Options};

/// Resolution of the alpha mask, in pixels per side.
///
/// Independent of the figure's on-screen size: the hit test asks about a point in a box, and
/// 256 is fine enough that the answer never differs from what the eye sees, while still
/// being one small allocation per state.
const MASK_PIXELS: usize = 256;

/// Wie oft die Ruhe-Uhr die Zeit weiterreicht, damit die Figur einschlafen kann.
///
/// Dieselbe Minute wie auf dem Mac (`OverlayController.startIdleClock`). Sie ist grob genug,
/// dass sie in der Ruhelast nicht auffällt, und fein genug für eine Einschlafzeit, die in
/// Minuten gemessen wird.
pub const IDLE_TICK: std::time::Duration = std::time::Duration::from_secs(60);

pub struct Overlay {
    window: gtk4::ApplicationWindow,
    area: gtk4::DrawingArea,
    machine: Rc<RefCell<FigureStateMachine>>,
    frame: Rc<RefCell<usize>>,
    /// Läuft nur, solange der gezeigte Zustand sich bewegt. `None` heißt: kein Zeitgeber im
    /// Umlauf, also auch keine fünfundzwanzig Weckvorgänge je Sekunde gegen das
    /// Ruhelast-Budget aus `DESIGN.md` § Figur und Overlay.
    frame_timer: RefCell<Option<glib::SourceId>>,
    shape: Shape,
    size: i32,
}

impl Overlay {
    pub fn new(
        application: &gtk4::Application,
        options: &Options,
        monitor: Option<&gdk::Monitor>,
    ) -> Self {
        let window = gtk4::ApplicationWindow::builder()
            .application(application)
            .decorated(false)
            .resizable(false)
            .build();
        window.add_css_class("companion-figure");

        window.init_layer_shell();
        // `top`, nicht `overlay`: Innerhalb einer Ebene ist die Reihenfolge im Protokoll
        // ausdrücklich undefiniert, und auf `overlay` liegt alles, was im Notfall sichtbar
        // sein muss — die Bildschirmsperre voran. Eine Figur, die dort liegt, kann über der
        // Sperre landen und liegt in jedem Fall über der Systemleiste, in die sie sich
        // einfügen soll. Gemessen auf peer benutzt Omarchy selbst nur `background` für das
        // Hintergrundbild und `top` für seine Bar; `overlay` ist leer.
        window.set_layer(Layer::Top);
        // A name the compositor and its rules can address the surface by. Hyprland matches
        // layer rules on it, which is how a person pins the figure to one workspace.
        window.set_namespace(Some("companion-figure"));
        // The figure never takes the keyboard: the shell must not take focus away from what
        // the person is typing in.
        window.set_keyboard_mode(KeyboardMode::None);
        // Zero, not automatic: the figure floats over the desktop and must not push a bar or
        // a maximised window out of its way.
        window.set_exclusive_zone(0);
        place_on_monitor(&window, monitor);
        anchor_to_corner(&window, options.corner, options.margin);

        let area = gtk4::DrawingArea::builder()
            .content_width(options.size)
            .content_height(options.size)
            // Die Figur ist eine Fläche, die angeklickt wird, also meldet sie sich auch als
            // eine: Die GNOME HIG verlangt für jedes Bedienelement einen zugänglichen
            // Namen, ausdrücklich auch für das, was nur eine Zeichnung ist.
            .accessible_role(gtk4::AccessibleRole::Button)
            .build();
        area.update_property(&[gtk4::accessible::Property::Label(
            "Companion-Figur. Öffnet und schließt das Panel.",
        )]);
        window.set_child(Some(&area));

        let machine = Rc::new(RefCell::new(FigureStateMachine::default()));
        let shape = Shape {
            window: window.clone(),
            machine: Rc::clone(&machine),
            mask: Rc::new(RefCell::new(
                AlphaMask::render(FigureState::Idle, 0, MASK_PIXELS)
                    .unwrap_or_else(|| AlphaMask::new(1, 1, vec![255])),
            )),
            shaped_for: Rc::new(RefCell::new(None)),
            size: options.size,
        };

        let overlay = Self {
            window,
            area,
            machine,
            frame: Rc::new(RefCell::new(0)),
            frame_timer: RefCell::new(None),
            shape,
            size: options.size,
        };
        overlay.connect_draw();
        overlay.connect_shaping();
        overlay
    }

    fn connect_draw(&self) {
        let machine = Rc::clone(&self.machine);
        let frame = Rc::clone(&self.frame);
        self.area.set_draw_func(move |_, context, width, height| {
            let size = f64::from(width.min(height));
            render::render(context, machine.borrow().state(), *frame.borrow(), size);
        });
    }

    /// Hands the compositor the shape of the figure once the surface exists.
    ///
    /// It has to happen after the surface is mapped — before that there is no `GdkSurface` to
    /// set a region on.
    fn connect_shaping(&self) {
        let shape = self.shape.clone();
        self.window.connect_map(move |_| shape.reshape());
    }

    pub fn window(&self) -> &gtk4::ApplicationWindow {
        &self.window
    }

    /// Blendet die Figur aus oder wieder ein — der Zweitzugang aus dem Tray-Menü für den
    /// Fall, dass sie gerade im Weg ist. `present()` statt `set_visible(true)`, damit das
    /// erneute Erscheinen denselben Weg nimmt wie der allererste Start (`Shell::start`),
    /// statt einen zweiten, ungeprüften Pfad zu haben.
    pub fn toggle_visible(&self) {
        if self.window.is_visible() {
            self.window.set_visible(false);
        } else {
            self.window.present();
        }
    }

    pub fn state(&self) -> FigureState {
        self.machine.borrow().state()
    }

    /// Wendet ein Ereignis an und zeichnet neu, wenn sich der Zustand geändert hat.
    pub fn apply(self: &Rc<Self>, event: FigureEvent) {
        let before = self.machine.borrow().state();
        let after = self.machine.borrow_mut().apply(event);
        if after == before {
            return;
        }
        *self.frame.borrow_mut() = 0;
        self.shape.reshape();
        self.restart_frame_timer(after);
        self.area.queue_draw();
    }

    /// Startet den Zeitgeber für den Zustand, der jetzt gezeigt wird, und hält ihn an, wenn
    /// dieser Zustand sich nicht bewegt.
    ///
    /// Vorher lief ein Zeitgeber im 40-Millisekunden-Takt über die ganze Lebensdauer des
    /// Prozesses und stieg bei `Idle` und `Sleeping` sofort wieder aus. Das waren
    /// fünfundzwanzig Weckvorgänge je Sekunde für nichts. Der Mac hält den Zeitgeber an,
    /// sobald ein Zustand nicht animiert (`OverlayController.restartFrameTimer`).
    pub fn restart_frame_timer(self: &Rc<Self>, state: FigureState) {
        if let Some(source) = self.frame_timer.borrow_mut().take() {
            source.remove();
        }
        let Some(interval) = state.frame_interval() else {
            return;
        };
        let this = Rc::downgrade(self);
        let source = glib::timeout_add_local(interval, move || {
            let Some(this) = this.upgrade() else {
                return glib::ControlFlow::Break;
            };
            *this.frame.borrow_mut() = this.frame.borrow().wrapping_add(1);
            this.area.queue_draw();
            glib::ControlFlow::Continue
        });
        *self.frame_timer.borrow_mut() = Some(source);
    }

    /// Reicht der Zustandsmaschine im Minutentakt die vergangene Zeit, damit die Figur
    /// überhaupt einschlafen kann.
    ///
    /// Ohne diese Uhr bliebe `idle_for` für immer null und der Zustand `schläft` wäre zur
    /// Laufzeit unerreichbar, obwohl er gezeichnet, benannt und getestet ist. Der Mac hat
    /// dafür `OverlayController.startIdleClock` mit derselben Minute.
    pub fn start_idle_clock(self: &Rc<Self>) {
        let this = Rc::downgrade(self);
        glib::timeout_add_local(IDLE_TICK, move || {
            let Some(this) = this.upgrade() else {
                return glib::ControlFlow::Break;
            };
            this.apply(FigureEvent::IdleElapsed(IDLE_TICK));
            glib::ControlFlow::Continue
        });
    }

    /// Attaches a click handler that only fires on the figure itself.
    ///
    /// The compositor already drops what the input region does not cover, so this is the
    /// second of two lines of defence: it is what decides the answer where the region could
    /// not be set at all.
    pub fn on_click<F: Fn() + 'static>(&self, action: F) {
        let gesture = gtk4::GestureClick::new();
        let shape = self.shape.clone();
        let size = f64::from(self.size);
        gesture.connect_pressed(move |gesture, _, x, y| {
            if shape
                .mask
                .borrow()
                .is_opaque(x, y, size, size, mask::DEFAULT_THRESHOLD)
            {
                action();
            } else {
                // Nothing on this pixel belongs to the figure, so the event is not ours.
                gesture.set_state(gtk4::EventSequenceState::Denied);
            }
        });
        self.area.add_controller(gesture);
    }
}

/// The mask and the input region, kept apart from the overlay so a callback can hold them.
#[derive(Clone)]
struct Shape {
    window: gtk4::ApplicationWindow,
    machine: Rc<RefCell<FigureStateMachine>>,
    mask: Rc<RefCell<AlphaMask>>,
    shaped_for: Rc<RefCell<Option<FigureState>>>,
    size: i32,
}

impl Shape {
    /// Recomputed per state, not per frame.
    ///
    /// Every state draws the same body, and every ornament sits inside the visor, which is
    /// inside the body — so the silhouette does not move between the frames of one state.
    /// Handing the compositor an identical region twelve times a second would be twelve
    /// round trips a second for nothing.
    fn reshape(&self) {
        let state = self.machine.borrow().state();
        if *self.shaped_for.borrow() == Some(state) {
            return;
        }
        let Some(rendered) = AlphaMask::render(state, 0, MASK_PIXELS) else {
            return;
        };
        let region = rendered.input_region(self.size, self.size);
        *self.mask.borrow_mut() = rendered;

        // Der Merker steht erst, wenn die Region wirklich draußen ist. Gibt es noch keine
        // `GdkSurface`, hätte er den späteren Aufruf aus `connect_map` vorzeitig aussteigen
        // lassen — und das Fenster nähme auf ganzer Fläche Klicks an.
        if let Some(surface) = self.window.surface() {
            surface.set_input_region(Some(&region));
            *self.shaped_for.borrow_mut() = Some(state);
        }
    }
}

/// Names the screen the surface belongs on, if the person named one.
///
/// Without it the layer surface carries no output and the compositor picks. On sway that is
/// the focused output; on Hyprland it is whichever monitor was last active, which on a desk
/// with two screens is wherever the mouse happened to be. `--bildschirm` is how the person
/// says it out loud instead.
pub fn place_on_monitor<W: IsA<gtk4::Window>>(window: &W, monitor: Option<&gdk::Monitor>) {
    if let Some(monitor) = monitor {
        window.set_monitor(Some(monitor));
    }
}

/// Der Bildschirm mit diesem Anschlussnamen, etwa `DP-1`.
pub fn monitor_named(display: &gdk::Display, name: &str) -> Option<gdk::Monitor> {
    monitors(display).find(|monitor| monitor.connector().as_deref() == Some(name))
}

/// Die Anschlussnamen aller Bildschirme, für die Meldung, wenn einer nicht dabei war.
pub fn monitor_names(display: &gdk::Display) -> Vec<String> {
    monitors(display)
        .filter_map(|monitor| monitor.connector().map(|name| name.to_string()))
        .collect()
}

fn monitors(display: &gdk::Display) -> impl Iterator<Item = gdk::Monitor> {
    let list = display.monitors();
    (0..list.n_items())
        .filter_map(move |index| list.item(index))
        .filter_map(|object| object.downcast::<gdk::Monitor>().ok())
}

/// Anchors a layer surface to two perpendicular edges, which puts it in that corner.
pub fn anchor_to_corner<W: IsA<gtk4::Window>>(window: &W, corner: Corner, margin: i32) {
    let vertical = if corner.is_top() {
        Edge::Top
    } else {
        Edge::Bottom
    };
    let horizontal = if corner.is_left() {
        Edge::Left
    } else {
        Edge::Right
    };
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, edge == vertical || edge == horizontal);
    }
    window.set_margin(vertical, margin);
    window.set_margin(horizontal, margin);
}
