// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Exports the JSON Schema of the wire types to `app/protocol/schema/` so the Swift shell
//! can build against them.
//!
//! By default the test only compares: a change to a protocol type that was not exported
//! fails here. Regenerate with
//!
//! ```text
//! COMPANION_UPDATE_SCHEMAS=1 cargo test -p companion-protocol
//! ```

use std::fs;
use std::path::PathBuf;

use companion_protocol::{
    AdapterCapabilities, Auftrag, ClientMessage, RegistryEntry, ServerMessage, SessionStatus,
};
use schemars::schema_for;

fn schema_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../protocol/schema")
        .canonicalize()
        .expect("app/protocol/schema must exist")
}

fn exports() -> Vec<(&'static str, String)> {
    let render = |schema: schemars::Schema| {
        let mut text = serde_json::to_string_pretty(&schema).expect("schema serialises");
        text.push('\n');
        text
    };
    vec![
        ("client_message.json", render(schema_for!(ClientMessage))),
        ("server_message.json", render(schema_for!(ServerMessage))),
        ("session_status.json", render(schema_for!(SessionStatus))),
        ("auftrag.json", render(schema_for!(Auftrag))),
        ("registry_entry.json", render(schema_for!(RegistryEntry))),
        (
            "adapter_capabilities.json",
            render(schema_for!(AdapterCapabilities)),
        ),
    ]
}

#[test]
fn exported_schemas_match_the_types() {
    let dir = schema_dir();
    let update = std::env::var_os("COMPANION_UPDATE_SCHEMAS").is_some();
    let mut stale = Vec::new();

    for (name, expected) in exports() {
        let path = dir.join(name);
        let current = fs::read_to_string(&path).unwrap_or_default();
        if current == expected {
            continue;
        }
        if update {
            fs::write(&path, &expected).expect("schema directory is writable");
        } else {
            stale.push(name);
        }
    }

    assert!(
        stale.is_empty(),
        "exported schemas are out of date: {}. Regenerate with COMPANION_UPDATE_SCHEMAS=1 cargo test -p companion-protocol",
        stale.join(", ")
    );
}
