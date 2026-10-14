// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! CLI entry point for the shared skill installer.

pub fn run(arguments: &[String]) -> Result<(), String> {
    companion_skills::run(arguments)
}
