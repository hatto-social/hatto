// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` — build and check a provisional deck file.
//!
//! Collections are temporary directories created by the tool. The process
//! never opens a user collection.

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use hatto_card::{export_path, failure_json, validate_path, write_skeleton, ToolFailure};
use serde_json::Value;

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let mut json = false;
    let mut words = Vec::new();
    for arg in args.by_ref() {
        if arg == "--json" {
            json = true;
        } else {
            words.push(arg);
        }
    }
    match dispatch(&words) {
        Ok(value) => {
            emit(json, &value);
            ExitCode::SUCCESS
        }
        Err(Usage(message)) => {
            if json {
                emit(
                    true,
                    &failure_json(&ToolFailure {
                        message: Some(message),
                        errors: Vec::new(),
                    }),
                );
            } else {
                eprintln!("hatto-card: {message}");
                eprintln!(
                    "usage: hatto-card [--json] new [--output FILE] | validate --deck FILE | export --deck FILE --output FILE"
                );
            }
            ExitCode::from(2)
        }
        Err(Failed(failure)) => {
            if json {
                emit(true, &failure_json(&failure));
            } else if let Some(message) = &failure.message {
                eprintln!("hatto-card: {message}");
            } else {
                for problem in &failure.errors {
                    if problem.code.is_empty() {
                        eprintln!("hatto-card: {} {}", problem.location, problem.message);
                    } else {
                        eprintln!(
                            "hatto-card: {} {} {}",
                            problem.code, problem.location, problem.message
                        );
                    }
                }
            }
            ExitCode::from(1)
        }
    }
}

enum CliError {
    Usage(String),
    Failed(ToolFailure),
}

use CliError::{Failed, Usage};

fn dispatch(words: &[String]) -> Result<Value, CliError> {
    let command = words.first().map(String::as_str).unwrap_or("");
    let pairs = pairs(words)?;
    match command {
        "new" => {
            only(&pairs, &["--output"])?;
            let output = optional(&pairs, "--output")?;
            write_skeleton(output.map(PathBuf::from).as_deref()).map_err(Failed)
        }
        "validate" => {
            only(&pairs, &["--deck"])?;
            let deck = required(&pairs, "--deck")?;
            validate_path(PathBuf::from(deck).as_path()).map_err(Failed)
        }
        "export" => {
            only(&pairs, &["--deck", "--output"])?;
            let deck = required(&pairs, "--deck")?;
            let output = required(&pairs, "--output")?;
            export_path(
                PathBuf::from(deck).as_path(),
                PathBuf::from(output).as_path(),
            )
            .map_err(Failed)
        }
        "" => Err(Usage("missing command".into())),
        other => Err(Usage(format!("unknown command {other}"))),
    }
}

fn pairs(words: &[String]) -> Result<Vec<(&str, &str)>, CliError> {
    let mut index = 1;
    let mut out = Vec::new();
    while index < words.len() {
        let name = words[index].as_str();
        if !name.starts_with("--") {
            return Err(Usage(format!("unexpected argument {name}")));
        }
        let value = words
            .get(index + 1)
            .map(String::as_str)
            .filter(|value| !value.starts_with("--"))
            .ok_or_else(|| Usage(format!("missing value for {name}")))?;
        out.push((name, value));
        index += 2;
    }
    Ok(out)
}

fn only(pairs: &[(&str, &str)], allowed: &[&str]) -> Result<(), CliError> {
    for (name, _) in pairs {
        if !allowed.contains(name) {
            return Err(Usage(format!("unexpected argument {name}")));
        }
    }
    Ok(())
}

fn required<'a>(pairs: &[(&'a str, &'a str)], name: &str) -> Result<&'a str, CliError> {
    optional(pairs, name)?.ok_or_else(|| Usage(format!("missing {name}")))
}

fn optional<'a>(pairs: &[(&'a str, &'a str)], name: &str) -> Result<Option<&'a str>, CliError> {
    let mut found = None;
    for (key, value) in pairs {
        if *key == name {
            if found.is_some() {
                return Err(Usage(format!("{name} repeated")));
            }
            found = Some(*value);
        }
    }
    Ok(found)
}

fn emit(json: bool, value: &Value) {
    if json {
        println!("{}", serde_json::to_string(value).expect("json"));
    } else {
        println!("{}", serde_json::to_string_pretty(value).expect("json"));
    }
}
