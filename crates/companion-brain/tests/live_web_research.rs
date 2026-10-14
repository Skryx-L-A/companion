// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The `web_research` tool against a real `claude` with live web search.
//!
//! Ignored by default, and pointed at a binary on purpose:
//!
//! ```text
//! COMPANION_CLAUDE_BIN=$(which claude) \
//!   cargo test -p companion-brain --test live_web_research -- --ignored --nocapture
//! ```
//!
//! It costs one subscription turn per run, which is why it is not part of the suite. What it
//! proves is the one thing no stub can: that the hardened invocation this program builds —
//! `--restricted --permission-mode plan --tools WebSearch` in a throwaway directory with a
//! cleared environment — really does come back with an answer and real URLs, rather than
//! with a model apologising that it has no tools.
//!
//! Run on 2026-09-05 against claude 2.0.76: 39 s, the right date, three URLs.

use std::sync::Arc;
use std::time::{Duration, Instant};

use companion_brain::{ResearchScope, SubagentWebResearch, WebResearch};
use companion_core::{EndpointConfig, EndpointProfile, RoleBinding, Shared};
use companion_protocol::{EndpointProtocol, EndpointRole};

#[tokio::test]
#[ignore = "spends a real claude turn; see the module comment"]
async fn a_real_research_run_answers_with_real_sources() {
    let Some(binary) = std::env::var_os("COMPANION_CLAUDE_BIN") else {
        panic!("set COMPANION_CLAUDE_BIN to the claude binary to use");
    };
    let profile = EndpointProfile::local(
        "live-claude",
        EndpointProtocol::Cli,
        binary.to_str().expect("the path is utf-8"),
    );
    let endpoints = EndpointConfig::empty()
        .with_profile(profile)
        .with_role(EndpointRole::SubagentLlm, RoleBinding::new("live-claude"));

    let research = SubagentWebResearch::new(
        Arc::new(Shared::new(endpoints)),
        reqwest::Client::new(),
        Duration::from_secs(180),
        Arc::new(companion_brain::SubagentGate::new(1)),
    );

    let started = Instant::now();
    let report = research
        .research("Wann erschien Rust 1.0?", ResearchScope::Kurz)
        .await
        .expect("a configured, reachable claude answers");
    let took = started.elapsed();

    println!("{:.1} s\n{report}", took.as_secs_f64());
    assert!(
        report.contains("2015"),
        "the answer names the year: {report}"
    );
    assert!(
        report.contains("https://"),
        "a research report names its sources: {report}"
    );
}
