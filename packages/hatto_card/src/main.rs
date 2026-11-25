// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` — build, extend, and check a provisional deck file.
//!
//! Collections are temporary directories created by the tool. The process
//! never opens a user collection.

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use hatto_card::{
    add_note_path, export_path, failure_json, validate_path, write_skeleton, AddNoteGuid,
    AddNoteRequest, ToolFailure,
};
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
    if help_requested(&words) {
        print_help(help_topic(&words));
        return ExitCode::SUCCESS;
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
                    "usage: hatto-card [--json] [-h|--help] new [--output FILE] [--deck-name NAME] | validate --deck FILE | export --deck FILE --output FILE | add-note --deck FILE --notetype NAME --field TEXT [--field TEXT ...] [--tag TEXT ...] [--output FILE] [--op-id UUID] [--k N] | [--job-id UUID --source-guid TEXT]"
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
            only(&pairs, &["--output", "--deck-name"])?;
            let output = optional(&pairs, "--output")?;
            let deck_name = optional(&pairs, "--deck-name")?;
            if deck_name.is_some_and(|name| name.is_empty()) {
                return Err(Usage("--deck-name is empty".into()));
            }
            write_skeleton(output.map(PathBuf::from).as_deref(), deck_name).map_err(Failed)
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
        "add-note" => add_note(&pairs),
        "" => Err(Usage("missing command".into())),
        other => Err(Usage(format!("unknown command {other}"))),
    }
}

fn add_note(pairs: &[(&str, &str)]) -> Result<Value, CliError> {
    only(
        pairs,
        &[
            "--deck",
            "--output",
            "--notetype",
            "--field",
            "--tag",
            "--op-id",
            "--k",
            "--job-id",
            "--source-guid",
        ],
    )?;
    let deck = required(pairs, "--deck")?;
    let notetype = required(pairs, "--notetype")?;
    let fields = repeated(pairs, "--field");
    if fields.is_empty() {
        return Err(Usage("missing --field".into()));
    }
    let output = optional(pairs, "--output")?;
    let request = AddNoteRequest {
        notetype: notetype.to_string(),
        fields: fields.into_iter().map(str::to_string).collect(),
        tags: repeated(pairs, "--tag")
            .into_iter()
            .map(str::to_string)
            .collect(),
        guid: guid_mode(pairs)?,
    };
    add_note_path(
        PathBuf::from(deck).as_path(),
        output.map(PathBuf::from).as_deref(),
        &request,
    )
    .map_err(Failed)
}

/// Local is the default. `--source-guid` selects an import. `--job-id` is
/// accepted with it, stored, and ignored when the guid is derived. Those
/// flags cannot be combined with `--op-id` or `--k`.
fn guid_mode(pairs: &[(&str, &str)]) -> Result<AddNoteGuid, CliError> {
    let op_id = optional(pairs, "--op-id")?;
    let k_text = optional(pairs, "--k")?;
    let job_id = optional(pairs, "--job-id")?;
    let source_guid = optional(pairs, "--source-guid")?;
    let local = op_id.is_some() || k_text.is_some();
    let imported = job_id.is_some() || source_guid.is_some();
    if local && imported {
        return Err(Usage(
            "--job-id and --source-guid cannot be combined with --op-id or --k".into(),
        ));
    }
    if imported {
        let job_id = job_id.ok_or_else(|| Usage("missing --job-id".into()))?;
        let source_guid = source_guid.ok_or_else(|| Usage("missing --source-guid".into()))?;
        return Ok(AddNoteGuid::Imported {
            job_id: job_id.to_string(),
            source_guid: source_guid.to_string(),
        });
    }
    let k = match k_text {
        Some(text) => Some(
            text.parse::<u32>()
                .map_err(|_| Usage(format!("--k is not a u32: {text}")))?,
        ),
        None => None,
    };
    Ok(AddNoteGuid::Local {
        op_id: op_id.map(str::to_string),
        k,
    })
}

fn repeated<'a>(pairs: &[(&'a str, &'a str)], name: &str) -> Vec<&'a str> {
    pairs
        .iter()
        .filter(|(key, _)| *key == name)
        .map(|(_, value)| *value)
        .collect()
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

fn help_requested(words: &[String]) -> bool {
    words
        .iter()
        .any(|word| word == "--help" || word == "-h" || word == "help")
}

fn help_topic(words: &[String]) -> Option<&str> {
    words.iter().find_map(|word| match word.as_str() {
        "new" | "validate" | "export" | "add-note" => Some(word.as_str()),
        _ => None,
    })
}

fn print_help(topic: Option<&str>) {
    let text = match topic {
        Some("new") => NEW_HELP,
        Some("validate") => VALIDATE_HELP,
        Some("export") => EXPORT_HELP,
        Some("add-note") => ADD_NOTE_HELP,
        _ => TOP_HELP,
    };
    print!("{text}");
}

const TOP_HELP: &str = "\
hatto-card — build, extend, and check a provisional deck file

usage:
  hatto-card [--json] <command> [flags]
  hatto-card [--json] <command> --help

commands:
  new        write a 3-note deck with a fresh job_id and op_id
  validate   check a deck file
  export     write an apkg for one deck
  add-note   append one note to a deck file

global flags:
  --json     print one JSON object on stdout
  -h, --help show this help and exit 0

Collections are temporary. This tool does not import a package and does not
open a user collection.
";

const NEW_HELP: &str = "\
hatto-card new — write a 3-note example deck

usage:
  hatto-card [--json] new [--output FILE] [--deck-name NAME]

flags:
  --output FILE     write the deck JSON here
  --deck-name NAME  set deck_name (default: Example)
  -h, --help        show this help and exit 0

job_id and op_id are new UUIDv4 values on every run. Note guids stay uuid5
values derived from those ids. The deck has three notes. An empty deck is
not written.

With --output, media/dot.png is created beside the file when it is missing,
so validate and export can run next. An existing dot.png is left unchanged.
";

const VALIDATE_HELP: &str = "\
hatto-card validate — check a deck file

usage:
  hatto-card [--json] validate --deck FILE

flags:
  --deck FILE  deck JSON to check
  -h, --help   show this help and exit 0

Exit status is 0 when the deck JSON, note guids, and media directory check
pass. An empty notes array is rejected.
";

const EXPORT_HELP: &str = "\
hatto-card export — write an apkg for one deck

usage:
  hatto-card [--json] export --deck FILE --output FILE

flags:
  --deck FILE    deck JSON to read
  --output FILE  apkg to write
  -h, --help     show this help and exit 0
";

const ADD_NOTE_HELP: &str = "\
hatto-card add-note — append one note

usage:
  hatto-card [--json] add-note --deck FILE --notetype NAME --field TEXT
      [--field TEXT ...] [--tag TEXT ...] [--output FILE]
      [--op-id UUID] [--k N]
  hatto-card [--json] add-note --deck FILE --notetype NAME --field TEXT
      [--field TEXT ...] [--job-id UUID] --source-guid TEXT

flags:
  --deck FILE          deck JSON to update
  --output FILE        write this path instead of --deck
  --notetype NAME      must match the deck notetype
  --field TEXT         one field, repeatable, in notetype order
  --tag TEXT           tag, repeatable
  --op-id UUID         local note op_id (default: new UUIDv4)
  --k N                local note index (default: 0)
  --job-id UUID        imported note job_id
  --source-guid TEXT   imported note source bytes
  -h, --help           show this help and exit 0

--job-id and --source-guid cannot be combined with --op-id or --k.
With no guid flags, add-note makes a UUIDv4 op_id and sets k to 0.
The file is written only after the same checks as validate.
";

fn emit(json: bool, value: &Value) {
    if json {
        println!("{}", serde_json::to_string(value).expect("json"));
    } else {
        println!("{}", serde_json::to_string_pretty(value).expect("json"));
    }
}
