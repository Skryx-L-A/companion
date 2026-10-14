// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The keyboard's way into a running shell: `companion-linux --panel-umschalten` finds the
//! running instance over the session bus and asks it to open or close its panel, then exits.
//! No shell of its own, no window, no layer surface — just the one D-Bus round trip.
//!
//! GTK exports every `gio::SimpleAction` a registered `Application` carries over D-Bus, at
//! the well-known name that is the application id, through the `org.gtk.Actions` interface
//! — the same mechanism a desktop's remote "Quit" menu entry uses. `app.beenden` rode on
//! this by accident before this track: launching a second `companion-linux` re-triggered
//! `activate` on the running one instead of opening a second window, because the
//! application was never told it may run more than once. This gives the door a name
//! (`app.panel-umschalten`, `ui::panel::PANEL_TOGGLE_ACTION`) and a contract: fail loudly,
//! with a clear message, when nobody is listening — see `bindings.lua` example in the
//! README for the keyboard side of this.

use gtk4::gio;
use gtk4::gio::prelude::*;
use gtk4::glib;

use crate::ui::APPLICATION_ID;
use crate::ui::panel::PANEL_TOGGLE_ACTION;

/// `"org.example.app"` becomes `"/org/example/app"` — the object path
/// GLib derives from an application id when none is given explicitly, and the one a
/// registered `gtk4::Application` exports its actions at.
fn object_path() -> String {
    format!("/{}", APPLICATION_ID.replace('.', "/"))
}

/// Reicht der laufenden Schale das Umschalten über den Sitzungsbus weiter.
///
/// Kein eigenes `gio::Application` hier: Das würde sich selbst registrieren, und fände es
/// keine laufende Instanz, bliebe es als leere Primärinstanz auf dem Bus stehen, bis der
/// Prozess endet — für einen Befehl, der nur fragen will, die falsche Rolle. Der direkte,
/// synchrone Aufruf über die Verbindung wartet auf die (leere) Antwort, und genau die ist
/// hier der Beweis, dass die Aktion wirklich ankam, statt nur verschickt worden zu sein.
pub fn toggle_panel() -> Result<(), String> {
    let connection = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE)
        .map_err(|error| format!("Kein Sitzungsbus erreichbar: {error}"))?;

    if !name_has_owner(&connection, APPLICATION_ID)? {
        return Err("Keine laufende Instanz von companion-linux.".to_owned());
    }

    // The third element has to be a real (empty) `HashMap`, not a `glib::Variant` built by
    // hand (`VariantDict::end()`): a `Variant` placed straight into a Rust tuple is wrapped
    // as its own `"v"` rather than inlined, which turned this into `"(savv)"` instead of the
    // `"(sava{sv})"` `org.gtk.Actions.Activate` expects, and every call came back rejected.
    let platform_data: std::collections::HashMap<String, glib::Variant> =
        std::collections::HashMap::new();
    let parameters = (
        PANEL_TOGGLE_ACTION,
        Vec::<glib::Variant>::new(),
        platform_data,
    )
        .to_variant();
    connection
        .call_sync(
            Some(APPLICATION_ID),
            &object_path(),
            "org.gtk.Actions",
            "Activate",
            Some(&parameters),
            None,
            gio::DBusCallFlags::NONE,
            5_000,
            gio::Cancellable::NONE,
        )
        .map_err(|error| format!("Das Umschalten kam nicht an: {error}"))?;
    Ok(())
}

/// Ob der genannte wohlbekannte Name gerade jemandem gehört — die Frage an
/// `org.freedesktop.DBus` selbst, bevor überhaupt versucht wird, die laufende Schale
/// anzusprechen. Ohne diesen Schritt wäre die Fehlermeldung bei einer toten Anwendung nur
/// der rohe D-Bus-Fehler eines Aufrufs ins Leere, statt des klaren Satzes, den der Auftrag
/// verlangt.
fn name_has_owner(connection: &gio::DBusConnection, name: &str) -> Result<bool, String> {
    let reply = connection
        .call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            Some(&(name,).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            5_000,
            gio::Cancellable::NONE,
        )
        .map_err(|error| format!("Der Sitzungsbus antwortet nicht: {error}"))?;
    let (owned,): (bool,) = reply
        .get()
        .ok_or_else(|| "Unerwartete Antwort auf NameHasOwner.".to_owned())?;
    Ok(owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_object_path_is_the_application_id_with_slashes() {
        let path = object_path();
        assert!(!path.contains('.'), "{path}");
        assert_eq!(path.replace('/', "."), format!(".{APPLICATION_ID}"));
    }
}
