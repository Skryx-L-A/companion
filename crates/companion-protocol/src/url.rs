// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Cutting an endpoint url down to the part that is safe to show.
//!
//! An endpoint url is not a secret, but the two ends of one can be: `https://user:pass@host`
//! carries a credential in its userinfo, and `https://host/v1?key=AIza…` carries one in its
//! query. [`crate::EndpointConfig::validate`] refuses both, so a url that reaches this module
//! from a checked configuration has neither — but a url reaches an error message and a log
//! line from places that never saw `validate`, and a message is displayed, logged, quoted
//! back over the socket and read out loud.
//!
//! So the rule here is the plain one: whenever a url goes into text a person or a client
//! sees, it goes through [`without_credentials`] first. That is one habit rather than a
//! judgement call per call site, and a habit is what survives the next `reqwest` upgrade —
//! `reqwest::Error` appends ` for url (…)` to its own `Display`, with the query intact,
//! which is how a key ended up on the wire in the first place (audit 2026-09-03).
//!
//! Parsed by hand rather than with a url crate, for the same reason
//! [`crate::is_loopback_url`] is: this is a scheme, an authority and a path, and pulling a
//! parser in for three `split` calls would be a dependency for nothing. Nothing here
//! validates — a string this cannot read comes back shortened as far as it got, never
//! lengthened and never passed through whole.

/// The host of a url, without userinfo and without a port-less guess at anything else.
///
/// For a warning that names *where* something goes and nothing more. A url this cannot read
/// is `(unreadable address)` rather than the original: a string that reached this function
/// is a string somebody is about to show.
pub fn host_of(url: &str) -> &str {
    let authority = authority_of(url);
    // Whatever hides in front of an `@` is userinfo, not a host.
    let authority = match authority.rsplit_once('@') {
        Some((_, host)) => host,
        None => authority,
    };
    if authority.is_empty() {
        return "(unreadable address)";
    }
    authority
}

/// The url with its userinfo, its query and its fragment removed: scheme, host, port, path.
///
/// This is the form an error message names. It says which endpoint failed, down to the path
/// that was called, and it cannot carry a `?key=…` or a `user:pass@` while doing so. A url
/// without a scheme is treated as one that begins at its authority, which is what a
/// hand-written settings entry like `127.0.0.1:8765/v1` is.
pub fn without_credentials(url: &str) -> String {
    let url = url.trim();
    let (scheme, rest) = match url.split_once("://") {
        Some((scheme, rest)) => (Some(scheme), rest),
        None => (None, url),
    };
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let (authority, path) = match rest.find('/') {
        Some(cut) => (&rest[..cut], &rest[cut..]),
        None => (rest, ""),
    };
    let authority = match authority.rsplit_once('@') {
        Some((_, host)) => host,
        None => authority,
    };
    match scheme {
        Some(scheme) => format!("{scheme}://{authority}{path}"),
        None => format!("{authority}{path}"),
    }
}

/// The url with the credential parameters taken out of its query, or `None` when it carried
/// none.
///
/// The counterpart of [`crate::EndpointConfig::validate`]'s refusal: that one says a url like
/// this must not be written, this one repairs one that already is. Only `key`, `api_key`,
/// `token` and `access_token` go — the same four names the check looks for — and the rest of
/// the query stays, because an endpoint url may carry an ordinary parameter next to a key
/// and dropping that would change which endpoint is called. An empty query is removed with
/// its `?`; a fragment survives.
///
/// `None` rather than an unchanged copy, so a caller can tell "nothing to do" from "repaired"
/// without comparing strings.
pub fn url_without_query_credentials(url: &str) -> Option<String> {
    let (before, after) = url.split_once('?')?;
    let (query, fragment) = match after.split_once('#') {
        Some((query, fragment)) => (query, Some(fragment)),
        None => (after, None),
    };

    let mut kept: Vec<&str> = Vec::new();
    let mut dropped = false;
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        if is_credential_parameter(pair) {
            dropped = true;
        } else {
            kept.push(pair);
        }
    }
    if !dropped {
        return None;
    }

    let mut out = String::from(before);
    if !kept.is_empty() {
        out.push('?');
        out.push_str(&kept.join("&"));
    }
    if let Some(fragment) = fragment {
        out.push('#');
        out.push_str(fragment);
    }
    Some(out)
}

/// Whether one `name=value` pair of a query is a credential by its name.
///
/// The list is the one `EndpointConfig::validate` refuses, and the two have to stay in step:
/// a name that is refused there but not repaired here would keep a daemon from starting.
pub(crate) fn is_credential_parameter(pair: &str) -> bool {
    let name = pair.split('=').next().unwrap_or(pair);
    matches!(
        name.to_ascii_lowercase().as_str(),
        "key" | "api_key" | "token" | "access_token"
    )
}

/// The part between `://` and the first `/`, `?` or `#`, userinfo included.
fn authority_of(url: &str) -> &str {
    let after_scheme = match url.split_once("://") {
        Some((_, rest)) => rest,
        None => url,
    };
    after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(after_scheme)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shortened_url_keeps_the_address_and_loses_both_kinds_of_credential() {
        // The one that put a key on the wire: `reqwest` appends the full url to its own
        // error text, query and all.
        assert_eq!(
            without_credentials("https://api.example.com/v1?key=AIzaXYZ"),
            "https://api.example.com/v1"
        );
        assert_eq!(
            without_credentials("https://benutzer:geheim@api.example.com/v1/audio/speech"),
            "https://api.example.com/v1/audio/speech"
        );
        assert_eq!(
            without_credentials("https://api.example.com/v1?key=AIza#abschnitt"),
            "https://api.example.com/v1"
        );

        // What is not a credential stays, because an error that cannot say which endpoint
        // failed is not worth much: scheme, host, port and path all survive.
        assert_eq!(
            without_credentials("http://127.0.0.1:8765/v1/audio/transcriptions"),
            "http://127.0.0.1:8765/v1/audio/transcriptions"
        );
        assert_eq!(
            without_credentials("http://[::1]:8765/inference"),
            "http://[::1]:8765/inference"
        );
        assert_eq!(
            without_credentials("https://api.example.com"),
            "https://api.example.com"
        );

        // A string with no scheme begins at its authority, and one this cannot read comes
        // back shortened rather than whole.
        assert_eq!(
            without_credentials("127.0.0.1:8765/v1?token=abc"),
            "127.0.0.1:8765/v1"
        );
        assert_eq!(without_credentials(""), "");
    }

    #[test]
    fn a_credential_leaves_the_query_and_the_rest_of_it_stays() {
        assert_eq!(
            url_without_query_credentials("https://api.example.com/v1?key=AIzaXYZ").as_deref(),
            Some("https://api.example.com/v1")
        );
        assert_eq!(
            url_without_query_credentials("https://api.example.com/v1?modell=x&api_key=abc&ton=y")
                .as_deref(),
            Some("https://api.example.com/v1?modell=x&ton=y"),
            "an ordinary parameter decides which endpoint is called and has to stay"
        );
        assert_eq!(
            url_without_query_credentials("https://api.example.com/v1?TOKEN=abc#teil").as_deref(),
            Some("https://api.example.com/v1#teil"),
            "the name is compared without case, and a fragment is not a credential"
        );

        // Nothing to repair says so, so a caller can tell it apart from a repair.
        assert_eq!(
            url_without_query_credentials("https://api.example.com/v1"),
            None
        );
        assert_eq!(
            url_without_query_credentials("https://api.example.com/v1?modell=x"),
            None
        );
        assert_eq!(url_without_query_credentials("/usr/bin/say"), None);
    }

    #[test]
    fn the_host_is_the_host_and_never_the_userinfo() {
        assert_eq!(
            host_of("https://api.openai.com/v1?key=AIza"),
            "api.openai.com"
        );
        assert_eq!(
            host_of("https://benutzer:geheim@angreifer.example/v1"),
            "angreifer.example"
        );
        assert_eq!(host_of("http://[::1]:8765/x"), "[::1]:8765");
        assert_eq!(host_of("kaputt"), "kaputt");
        assert_eq!(host_of(""), "(unreadable address)");
    }
}
