// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The tray icon, `org.kde.StatusNotifierItem` over D-Bus — the second access point
//! `DESIGN.md` § Figur und Overlay asks for, for when a click on the figure itself is not
//! an option: the figure hidden, or simply "where did it go". On Omarchy the Quickshell bar
//! renders it; on a compositor with no such host it still registers, quietly, and does
//! nothing visible.
//!
//! Built on `ksni` rather than a hand-rolled `zbus` client — the comparison that led there
//! is in the result file of the track that added this. `ksni`'s background service runs on
//! its own thread; its `Tray` callbacks fire there, never on the GTK thread, so they only
//! ever send a [`TrayCommand`] and return — the same shape `client.rs` already uses to get
//! the daemon's messages onto the GTK main loop.

use async_channel::Sender;
use ksni::blocking::TrayMethods;
use ksni::menu::StandardItem;

use crate::figure::{FigureState, render};

/// What a click in the tray menu asks the shell to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayCommand {
    TogglePanel,
    ToggleFigure,
    Quit,
}

pub struct CompanionTray {
    sender: Sender<TrayCommand>,
}

impl CompanionTray {
    pub fn new(sender: Sender<TrayCommand>) -> Self {
        Self { sender }
    }

    /// `send_blocking` on an unbounded channel never actually waits; the only way it fails
    /// is the shell side having dropped the receiver, and there is nothing left to tell it
    /// then.
    fn send(&self, command: TrayCommand) {
        let _ = self.sender.send_blocking(command);
    }
}

impl ksni::Tray for CompanionTray {
    fn id(&self) -> String {
        crate::ui::APPLICATION_ID.to_owned()
    }

    fn title(&self) -> String {
        "companion".to_owned()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        icon(48).into_iter().collect()
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        vec![
            StandardItem {
                label: "Panel öffnen/schließen".into(),
                activate: Box::new(|this: &mut Self| this.send(TrayCommand::TogglePanel)),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Figur zeigen/verstecken".into(),
                activate: Box::new(|this: &mut Self| this.send(TrayCommand::ToggleFigure)),
                ..Default::default()
            }
            .into(),
            ksni::MenuItem::Separator,
            StandardItem {
                label: "Beenden".into(),
                activate: Box::new(|this: &mut Self| this.send(TrayCommand::Quit)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

/// Startet den Tray-Dienst im Hintergrund und kehrt zurück, sobald die Registrierung auf
/// dem Sitzungsbus durch ist (oder als „offline" vermerkt, siehe unten).
///
/// `assume_sni_available(true)`, weil sonst jeder Start ohne `org.kde.StatusNotifierWatcher`
/// — ein verschachtelter Testcompositor etwa, oder eine Sitzung, die noch hochfährt — den
/// ganzen Tray-Zweig mit einem Fehler abbrechen ließe. Mit der Einstellung bleibt der Dienst
/// stehen, meldet sich beim Watcher erneut, sobald einer erscheint, und der eigene Bus-Name
/// samt dem exportierten Objekt stehen so oder so — das ist, was die verschachtelten Tests
/// nachsehen können, ganz ohne eine Bar, die ihn zeichnet.
pub fn spawn(
    sender: Sender<TrayCommand>,
) -> Result<ksni::blocking::Handle<CompanionTray>, ksni::Error> {
    CompanionTray::new(sender)
        .assume_sni_available(true)
        .spawn()
}

/// Rendert dasselbe gezeichnete Bild wie die Figur selbst, im Ruhezustand, klein genug für
/// eine Kachel in der Leiste. Kein Emoji und keine zweite Zeichnung, die aus dem Ruder
/// laufen könnte, wenn sich die Figur ändert.
fn icon(pixels: i32) -> Option<ksni::Icon> {
    let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, pixels, pixels).ok()?;
    {
        let context = cairo::Context::new(&surface).ok()?;
        render::render(&context, FigureState::Idle, 0, f64::from(pixels));
    }
    surface.flush();
    let stride = surface.stride();
    let data = surface.data().ok()?;
    Some(ksni::Icon {
        width: pixels,
        height: pixels,
        data: to_network_argb(&data, pixels as usize, pixels as usize, stride as usize),
    })
}

/// Cairos `ARgb32` ist pro Bildpunkt ein systemeigenes `0xAARRGGBB`-Wort, mit **prämultipliziertem**
/// Alpha — die Farbkanäle sind schon mit Alpha skaliert. Die StatusNotifierItem-Spezifikation
/// will Netzwerk-Bytereihenfolge (groß-endisch) UND geraden (straight) Alpha, wie jeder übliche
/// Host ihn erwartet. Ohne die Rückrechnung kommen kantengeglättete Ränder — die einzigen
/// teildeckenden Bildpunkte, die diese Zeichnung hat — zu dunkel und entsättigt an, derselbe
/// Fehler wie beim ungeprüften Cairo-zu-GdkPixbuf-Übergang.
fn to_network_argb(data: &[u8], width: usize, height: usize, stride: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(width * height * 4);
    for row in 0..height {
        let row_start = row * stride;
        for col in 0..width {
            let offset = row_start + col * 4;
            let word = u32::from_ne_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]);
            let alpha = (word >> 24) as u8;
            out.push(alpha);
            out.push(straight_channel((word >> 16) as u8, alpha));
            out.push(straight_channel((word >> 8) as u8, alpha));
            out.push(straight_channel(word as u8, alpha));
        }
    }
    out
}

/// Rechnet einen prämultiplizierten Farbkanal auf gerades Alpha zurück. Bei Alpha null ist
/// der Bildpunkt vollständig durchsichtig, jeder Farbwert wäre geraten — null statt einer
/// Division durch null.
fn straight_channel(premultiplied: u8, alpha: u8) -> u8 {
    if alpha == 0 {
        return 0;
    }
    let scaled = u16::from(premultiplied) * 255 + u16::from(alpha) / 2;
    (scaled / u16::from(alpha)).min(255) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Undurchsichtig (Alpha 255): prämultipliziert und gerade fallen hier zusammen, also
    /// bleibt die Bytevertauschung die einzige Umrechnung, die dieser Test sieht.
    #[test]
    fn a_pixel_comes_out_in_network_byte_order() {
        let pixel = 0xFF_11_22_33u32.to_ne_bytes();
        let out = to_network_argb(&pixel, 1, 1, 4);
        assert_eq!(out, vec![0xFF, 0x11, 0x22, 0x33]);
    }

    /// Zwei Zeilen mit Auffüllung dazwischen: Die Auffüllung darf nicht als Bildpunkt
    /// gelesen werden, und die zweite Zeile muss trotzdem am richtigen Versatz anfangen.
    /// Wieder undurchsichtig, aus demselben Grund wie oben — die Umrechnung selbst hat
    /// ihren eigenen Test unten.
    #[test]
    fn stride_padding_is_not_mistaken_for_pixels() {
        let mut data = Vec::new();
        data.extend_from_slice(&0xFF_22_33_44u32.to_ne_bytes());
        data.extend_from_slice(&[0xAA, 0xAA, 0xAA, 0xAA]);
        data.extend_from_slice(&0xFF_66_77_88u32.to_ne_bytes());
        data.extend_from_slice(&[0xAA, 0xAA, 0xAA, 0xAA]);
        let out = to_network_argb(&data, 1, 2, 8);
        assert_eq!(out, vec![0xFF, 0x22, 0x33, 0x44, 0xFF, 0x66, 0x77, 0x88]);
    }

    /// Der Befund aus dem Review: Cairo speichert prämultipliziert, halbtransparentes Weiß
    /// liegt also als (Alpha 128, 128, 128, 128) im Puffer, nicht als (Alpha 128, 255, 255,
    /// 255). Ohne die Rückrechnung käme genau dieser zu dunkle, entsättigte Wert am Rand des
    /// Symbols an.
    #[test]
    fn a_translucent_pixel_is_unpremultiplied() {
        let pixel = 0x80_80_80_80u32.to_ne_bytes();
        let out = to_network_argb(&pixel, 1, 1, 4);
        assert_eq!(out, vec![0x80, 0xFF, 0xFF, 0xFF]);
    }

    /// Der Schutz für Alpha null: eine Division durch null wäre hier sonst die Folge.
    #[test]
    fn fully_transparent_does_not_divide_by_zero() {
        let pixel = 0x00_00_00_00u32.to_ne_bytes();
        let out = to_network_argb(&pixel, 1, 1, 4);
        assert_eq!(out, vec![0x00, 0x00, 0x00, 0x00]);
    }

    /// Drei Einträge und ein Trenner: Panel und Figur je einmal zeigen/verstecken, Beenden
    /// dahinter statt dazwischen — der Auftrag des Menüs, an einer Stelle geprüft, ohne
    /// einen Sitzungsbus zu brauchen.
    #[test]
    fn the_menu_has_the_four_promised_entries() {
        let (sender, _receiver) = async_channel::unbounded();
        let tray = CompanionTray::new(sender);
        let items = ksni::Tray::menu(&tray);
        assert_eq!(items.len(), 4);
    }
}
