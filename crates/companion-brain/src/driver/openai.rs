// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The API profile: `/v1/chat/completions` with `stream: true` and function calling.
//!
//! `DESIGN.md` § Endpoints calls this the recommended way for the chat role, because it is
//! the one that streams token by token and can therefore speak sentence by sentence while
//! the model is still writing.

use async_trait::async_trait;
use companion_core::EndpointProfile;
use serde_json::{Value, json};
use tokio_stream::StreamExt;

use super::{ChatDriver, Conversation, DeltaSink, DriverError, Message, Turn, status_error};
use crate::tools::{ToolCall, ToolSpec};

/// One tool call while it is still arriving in pieces.
#[derive(Debug, Default, Clone)]
struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

pub struct OpenAiChat {
    profile: EndpointProfile,
    key: Option<String>,
    http: reqwest::Client,
}

impl OpenAiChat {
    pub fn new(profile: EndpointProfile, key: Option<String>, http: reqwest::Client) -> Self {
        Self { profile, key, http }
    }

    fn url(&self) -> String {
        format!(
            "{}/{}",
            self.profile.url.trim_end_matches('/'),
            "v1/chat/completions"
        )
    }
}

#[async_trait]
impl ChatDriver for OpenAiChat {
    async fn turn(
        &self,
        conversation: &Conversation,
        tools: &[ToolSpec],
        sink: DeltaSink<'_>,
    ) -> Result<Turn, DriverError> {
        // A chat endpoint without a model would be a guess about somebody's server. The
        // settings page shows the model of every profile (DESIGN.md § Endpoints), so a
        // missing one is a configuration gap and is reported as one.
        let Some(model) = self.profile.model.clone() else {
            return Err(DriverError::Malformed {
                profile: self.profile.id.clone(),
                detail: "das Profil nennt kein Modell; die Rolle chat_llm braucht eines".to_owned(),
            });
        };

        let body = json!({
            "model": model,
            "stream": true,
            "messages": messages_for(conversation),
            "tools": tools.iter().map(tool_json).collect::<Vec<_>>(),
            "tool_choice": "auto",
        });

        let mut request = self.http.post(self.url()).json(&body);
        if let Some(key) = &self.key {
            request = request.bearer_auth(key);
        }
        let response = request
            .send()
            .await
            .map_err(|source| DriverError::Transport {
                profile: self.profile.id.clone(),
                source,
            })?;
        if !response.status().is_success() {
            return Err(status_error(&self.profile.id, response).await);
        }

        let mut turn = Turn::default();
        let mut calls: Vec<PartialCall> = Vec::new();
        let mut stream = Box::pin(response.bytes_stream());
        let mut pending = Vec::new();

        while let Some(piece) = stream.next().await {
            let piece = piece.map_err(|source| DriverError::Transport {
                profile: self.profile.id.clone(),
                source,
            })?;
            pending.extend_from_slice(&piece);

            // Server-sent events are separated by newlines, and a network packet cuts
            // wherever it likes, so a line is only complete once its newline arrived.
            while let Some(at) = pending.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = pending.drain(..=at).collect();
                let line = String::from_utf8_lossy(&line);
                let Some(payload) = event_payload(line.trim_end()) else {
                    continue;
                };
                if payload == "[DONE]" {
                    pending.clear();
                    break;
                }
                let chunk: Value =
                    serde_json::from_str(payload).map_err(|error| DriverError::Malformed {
                        profile: self.profile.id.clone(),
                        detail: format!("ein Stueck des Streams ist kein JSON: {error}"),
                    })?;
                apply_chunk(&chunk, &mut turn, &mut calls, sink);
            }
        }

        turn.tool_calls = calls
            .into_iter()
            .enumerate()
            .filter(|(_, call)| !call.name.is_empty())
            .map(|(index, call)| ToolCall {
                id: if call.id.is_empty() {
                    format!("call-{index}")
                } else {
                    call.id
                },
                name: call.name,
                arguments: call.arguments,
            })
            .collect();
        Ok(turn)
    }
}

/// The payload of one `data:` line, or nothing for a comment or a field this driver ignores.
fn event_payload(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("data:")?;
    let rest = rest.trim();
    (!rest.is_empty()).then_some(rest)
}

/// Folds one streamed chunk into the answer so far.
fn apply_chunk(
    chunk: &Value,
    turn: &mut Turn,
    calls: &mut Vec<PartialCall>,
    sink: &mut (dyn FnMut(&str) + Send),
) {
    let Some(delta) = chunk
        .get("choices")
        .and_then(|choices| choices.get(0))
        .and_then(|choice| choice.get("delta"))
    else {
        return;
    };

    if let Some(text) = delta.get("content").and_then(Value::as_str)
        && !text.is_empty()
    {
        turn.text.push_str(text);
        sink(text);
    }

    let Some(pieces) = delta.get("tool_calls").and_then(Value::as_array) else {
        return;
    };
    for piece in pieces {
        // The index is what ties the pieces of one call together: name and arguments
        // arrive in separate chunks, and a model may build several calls at once.
        let index = piece.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        if calls.len() <= index {
            calls.resize(index + 1, PartialCall::default());
        }
        let call = &mut calls[index];
        if let Some(id) = piece.get("id").and_then(Value::as_str) {
            call.id = id.to_owned();
        }
        if let Some(function) = piece.get("function") {
            if let Some(name) = function.get("name").and_then(Value::as_str) {
                call.name.push_str(name);
            }
            if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                call.arguments.push_str(arguments);
            }
        }
    }
}

fn tool_json(spec: &ToolSpec) -> Value {
    json!({
        "type": "function",
        "function": {
            "name": spec.name,
            "description": spec.description,
            "parameters": spec.parameters,
        }
    })
}

/// The conversation in the shape the API wants.
///
/// Tool calls that the model made in one turn belong into one assistant message, so a run
/// of them is folded together rather than sent as several messages the endpoint would
/// reject.
fn messages_for(conversation: &Conversation) -> Vec<Value> {
    let mut out = vec![json!({"role": "system", "content": conversation.system})];
    let mut pending_calls: Vec<Value> = Vec::new();

    let flush = |pending: &mut Vec<Value>, out: &mut Vec<Value>| {
        if pending.is_empty() {
            return;
        }
        out.push(json!({
            "role": "assistant",
            "content": Value::Null,
            "tool_calls": std::mem::take(pending),
        }));
    };

    for message in &conversation.messages {
        match message {
            Message::ToolCall {
                id,
                name,
                arguments,
            } => pending_calls.push(json!({
                "id": id,
                "type": "function",
                "function": {"name": name, "arguments": arguments},
            })),
            Message::User { text } => {
                flush(&mut pending_calls, &mut out);
                out.push(json!({"role": "user", "content": text}));
            }
            Message::Assistant { text } => {
                flush(&mut pending_calls, &mut out);
                out.push(json!({"role": "assistant", "content": text}));
            }
            Message::ToolResult { id, name, content } => {
                flush(&mut pending_calls, &mut out);
                out.push(json!({
                    "role": "tool",
                    "tool_call_id": id,
                    "name": name,
                    "content": content,
                }));
            }
        }
    }
    flush(&mut pending_calls, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sink_into(collected: &mut String) -> impl FnMut(&str) + Send + '_ {
        move |piece: &str| collected.push_str(piece)
    }

    #[test]
    fn only_data_lines_carry_a_payload() {
        assert_eq!(event_payload("data: {\"a\":1}"), Some("{\"a\":1}"));
        assert_eq!(event_payload("data:[DONE]"), Some("[DONE]"));
        assert_eq!(event_payload(": keep-alive"), None);
        assert_eq!(event_payload(""), None);
        assert_eq!(event_payload("event: message"), None);
    }

    #[test]
    fn prose_arrives_piece_by_piece_and_in_order() {
        let mut turn = Turn::default();
        let mut calls = Vec::new();
        let mut collected = String::new();
        {
            let mut sink = sink_into(&mut collected);
            for text in ["Guten ", "Morgen", "."] {
                let chunk = json!({"choices": [{"delta": {"content": text}}]});
                apply_chunk(&chunk, &mut turn, &mut calls, &mut sink);
            }
        }
        assert_eq!(turn.text, "Guten Morgen.");
        assert_eq!(collected, "Guten Morgen.");
    }

    #[test]
    fn a_tool_call_that_arrives_in_pieces_is_put_back_together() {
        let mut turn = Turn::default();
        let mut calls = Vec::new();
        let mut collected = String::new();
        {
            let mut sink = sink_into(&mut collected);
            for chunk in [
                json!({"choices": [{"delta": {"tool_calls": [
                    {"index": 0, "id": "call_abc", "function": {"name": "read_ses"}}]}}]}),
                json!({"choices": [{"delta": {"tool_calls": [
                    {"index": 0, "function": {"name": "sion", "arguments": "{\"session_id\":"}}]}}]}),
                json!({"choices": [{"delta": {"tool_calls": [
                    {"index": 0, "function": {"arguments": "\"a\",\"lines\":20}"}}]}}]}),
            ] {
                apply_chunk(&chunk, &mut turn, &mut calls, &mut sink);
            }
        }
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id, "call_abc");
        assert_eq!(calls[0].name, "read_session");
        assert_eq!(calls[0].arguments, r#"{"session_id":"a","lines":20}"#);
        assert!(
            collected.is_empty(),
            "a tool call is not prose and never reaches the panel as one"
        );
    }

    #[test]
    fn two_calls_in_one_turn_stay_apart() {
        let mut turn = Turn::default();
        let mut calls = Vec::new();
        let mut collected = String::new();
        {
            let mut sink = sink_into(&mut collected);
            let chunk = json!({"choices": [{"delta": {"tool_calls": [
                {"index": 0, "id": "a", "function": {"name": "list_sessions", "arguments": "{}"}},
                {"index": 1, "id": "b", "function": {"name": "session_details", "arguments": "{}"}}]}}]});
            apply_chunk(&chunk, &mut turn, &mut calls, &mut sink);
        }
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[1].name, "session_details");
    }

    #[test]
    fn the_tool_results_of_one_turn_hang_on_one_assistant_message() {
        let conversation = Conversation {
            system: "System".to_owned(),
            messages: vec![
                Message::User {
                    text: "was laeuft".to_owned(),
                },
                Message::ToolCall {
                    id: "a".to_owned(),
                    name: "list_sessions".to_owned(),
                    arguments: "{}".to_owned(),
                },
                Message::ToolCall {
                    id: "b".to_owned(),
                    name: "session_details".to_owned(),
                    arguments: "{}".to_owned(),
                },
                Message::ToolResult {
                    id: "a".to_owned(),
                    name: "list_sessions".to_owned(),
                    content: "eine".to_owned(),
                },
            ],
        };
        let messages = messages_for(&conversation);
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[2]["role"], "assistant");
        assert_eq!(
            messages[2]["tool_calls"].as_array().unwrap().len(),
            2,
            "both calls of one turn belong to one message: {messages:?}"
        );
        assert_eq!(messages[3]["role"], "tool");
        assert_eq!(messages[3]["tool_call_id"], "a");
    }

    #[test]
    fn a_tool_reaches_the_endpoint_as_a_function_declaration() {
        let spec = &crate::tools::ToolBox::specs()[0];
        let json = tool_json(spec);
        assert_eq!(json["type"], "function");
        assert_eq!(json["function"]["name"], "list_sessions");
        assert_eq!(json["function"]["parameters"]["type"], "object");
    }
}
