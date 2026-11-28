// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `hatto-card` — build, extend, and check a provisional deck file, and
//! inspect an apkg through Stage E.
//!
//! Collections are temporary directories created by the tool. The process
//! never opens a user collection.

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use hatto_card::{
    add_note_path, add_notes_path, export_path, export_text, failure_json, inspect_path,
    parse_notes_input, validate_path, validate_text, write_new_deck, AddNoteGuid, AddNoteRequest,
    AddNotesRequest, NewDeck, ToolFailure,
};
use serde_json::Value;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    // Values are consumed before `--json` and help are recognized, so
    // `--field --json` and `--field -h` are field text.
    let (json, help, words) = split_args(&args);
    if help {
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
                    "usage: hatto-card [--json] [-h|--help] new [--empty] [--output FILE] [--deck-name NAME] [--notetype NAME] | validate --deck FILE|- | export --deck FILE|- --output FILE | add-note --deck FILE --notetype NAME --field TEXT [--field TEXT ...] [--tag TEXT ...] [--deck-name NAME] [--output FILE] [--op-id UUID] [--k N] | [--job-id UUID --source-guid TEXT] | add-notes --deck FILE --input FILE|- [--output FILE] [--op-id UUID] [--start-k N] [--notetype NAME] | inspect FILE"
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
    // `inspect` takes a positional path. Other commands take `--flag value`.
    if command == "inspect" {
        return inspect_command(words);
    }
    let pairs = pairs(words)?;
    match command {
        "new" => {
            only(
                &pairs,
                &["--output", "--deck-name", "--notetype", "--empty"],
            )?;
            let output = optional(&pairs, "--output")?;
            let deck_name = optional(&pairs, "--deck-name")?;
            if deck_name.is_some_and(|name| name.is_empty()) {
                return Err(Usage("--deck-name is empty".into()));
            }
            let notetype = optional(&pairs, "--notetype")?;
            if notetype.is_some_and(|name| name.is_empty()) {
                return Err(Usage("--notetype is empty".into()));
            }
            let empty = flag(&pairs, "--empty")?;
            write_new_deck(
                output.map(PathBuf::from).as_deref(),
                NewDeck {
                    deck_name,
                    notetype,
                    empty,
                },
            )
            .map_err(Failed)
        }
        "validate" => {
            only(&pairs, &["--deck"])?;
            let deck = required(&pairs, "--deck")?;
            if deck == "-" {
                let text = read_stdin()?;
                validate_text(&text, Path::new(".")).map_err(Failed)
            } else {
                validate_path(PathBuf::from(deck).as_path()).map_err(Failed)
            }
        }
        "export" => {
            only(&pairs, &["--deck", "--output"])?;
            let deck = required(&pairs, "--deck")?;
            let output = required(&pairs, "--output")?;
            let out = PathBuf::from(output);
            if deck == "-" {
                let text = read_stdin()?;
                export_text(&text, Path::new("."), out.as_path()).map_err(Failed)
            } else {
                export_path(PathBuf::from(deck).as_path(), out.as_path()).map_err(Failed)
            }
        }
        "add-note" => add_note(&pairs),
        "add-notes" => add_notes(&pairs),
        "" => Err(Usage("missing command".into())),
        other => Err(Usage(format!("unknown command {other}"))),
    }
}

/// `inspect FILE`. The path is positional. `--json` is already stripped.
fn inspect_command(words: &[String]) -> Result<Value, CliError> {
    if words.len() < 2 {
        return Err(Usage("missing apkg".into()));
    }
    if words.len() > 2 {
        return Err(Usage(format!("unexpected argument {}", words[2])));
    }
    let path = words[1].as_str();
    if path.starts_with('-') {
        return Err(Usage(format!("unexpected argument {path}")));
    }
    inspect_path(Path::new(path)).map_err(Failed)
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
            "--deck-name",
        ],
    )?;
    let deck = required(pairs, "--deck")?;
    let notetype = required(pairs, "--notetype")?;
    let fields = repeated(pairs, "--field");
    if fields.is_empty() {
        return Err(Usage("missing --field".into()));
    }
    let output = optional(pairs, "--output")?;
    let deck_name = optional(pairs, "--deck-name")?;
    if deck_name.is_some_and(|name| name.is_empty()) {
        return Err(Usage("--deck-name is empty".into()));
    }
    let request = AddNoteRequest {
        notetype: notetype.to_string(),
        fields: fields.into_iter().map(str::to_string).collect(),
        tags: repeated(pairs, "--tag")
            .into_iter()
            .map(str::to_string)
            .collect(),
        guid: guid_mode(pairs)?,
        deck_name: deck_name.map(str::to_string),
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

fn add_notes(pairs: &[(&str, &str)]) -> Result<Value, CliError> {
    only(
        pairs,
        &[
            "--deck",
            "--input",
            "--output",
            "--op-id",
            "--start-k",
            "--notetype",
        ],
    )?;
    let deck = required(pairs, "--deck")?;
    let input = required(pairs, "--input")?;
    let output = optional(pairs, "--output")?;
    let notetype = optional(pairs, "--notetype")?;
    if notetype.is_some_and(|name| name.is_empty()) {
        return Err(Usage("--notetype is empty".into()));
    }
    let op_id = optional(pairs, "--op-id")?;
    let start_k = match optional(pairs, "--start-k")? {
        Some(text) => text
            .parse::<u32>()
            .map_err(|_| Usage(format!("--start-k is not a u32: {text}")))?,
        None => 0,
    };
    let text = if input == "-" {
        read_stdin()?
    } else {
        fs::read_to_string(input).map_err(|err| {
            Failed(ToolFailure {
                message: Some(format!("read {input}: {err}")),
                errors: Vec::new(),
            })
        })?
    };
    let notes = parse_notes_input(&text).map_err(Failed)?;
    let request = AddNotesRequest {
        notetype: notetype.map(str::to_string),
        op_id: op_id.map(str::to_string),
        start_k,
        notes,
    };
    add_notes_path(
        PathBuf::from(deck).as_path(),
        output.map(PathBuf::from).as_deref(),
        &request,
    )
    .map_err(Failed)
}

fn read_stdin() -> Result<String, CliError> {
    let mut buf = String::new();
    io::stdin().read_to_string(&mut buf).map_err(|err| {
        Failed(ToolFailure {
            message: Some(format!("read stdin: {err}")),
            errors: Vec::new(),
        })
    })?;
    Ok(buf)
}

fn repeated<'a>(pairs: &[(&'a str, &'a str)], name: &str) -> Vec<&'a str> {
    pairs
        .iter()
        .filter(|(key, _)| *key == name)
        .map(|(_, value)| *value)
        .collect()
}

/// Flags that do not take a value. A following token is the next argument,
/// even when that token starts with `-`.
const BOOLEAN_FLAGS: &[&str] = &["--empty"];

/// `--flag value` and `--flag=value`.
///
/// The value may start with `-` or `--` (`--field "--foo"`, `--field=--bar`,
/// `--tag "-v"`). `--flag=value` keeps everything after the first `=`.
fn pairs(words: &[String]) -> Result<Vec<(&str, &str)>, CliError> {
    let mut index = 1;
    let mut out = Vec::new();
    while index < words.len() {
        let token = words[index].as_str();
        if !token.starts_with("--") || token == "--" {
            return Err(Usage(format!("unexpected argument {token}")));
        }
        if let Some((name, value)) = token.split_once('=') {
            if name == "--" || !name.starts_with("--") {
                return Err(Usage(format!("unexpected argument {token}")));
            }
            if BOOLEAN_FLAGS.contains(&name) {
                return Err(Usage(format!("{name} does not take a value")));
            }
            out.push((name, value));
            index += 1;
            continue;
        }
        if BOOLEAN_FLAGS.contains(&token) {
            out.push((token, ""));
            index += 1;
            continue;
        }
        let value = words
            .get(index + 1)
            .map(String::as_str)
            .ok_or_else(|| Usage(format!("missing value for {token}")))?;
        out.push((token, value));
        index += 2;
    }
    Ok(out)
}

fn flag(pairs: &[(&str, &str)], name: &str) -> Result<bool, CliError> {
    Ok(optional(pairs, name)?.is_some())
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

/// Splits argv into the json flag, a help request, and the words `dispatch` parses.
///
/// A token that belongs to a value flag is not `--json` and not help, even when
/// the text is `--json`, `--help`, `-h`, or `help`.
fn split_args(args: &[String]) -> (bool, bool, Vec<String>) {
    let mut json = false;
    let mut help = false;
    let mut words = Vec::new();
    let mut expect_value = false;
    for arg in args {
        if expect_value {
            words.push(arg.clone());
            expect_value = false;
            continue;
        }
        if arg == "--json" {
            json = true;
            continue;
        }
        if arg == "--help" || arg == "-h" || arg == "help" {
            help = true;
            if arg == "help" {
                words.push(arg.clone());
            }
            continue;
        }
        words.push(arg.clone());
        expect_value = takes_separate_value(arg);
    }
    (json, help, words)
}

fn takes_separate_value(arg: &str) -> bool {
    arg.starts_with("--") && arg != "--" && !arg.contains('=') && !BOOLEAN_FLAGS.contains(&arg)
}

fn help_topic(words: &[String]) -> Option<&str> {
    words.iter().find_map(|word| match word.as_str() {
        "new" | "validate" | "export" | "add-note" | "add-notes" | "inspect" => Some(word.as_str()),
        _ => None,
    })
}

fn print_help(topic: Option<&str>) {
    let text = match topic {
        Some("new") => NEW_HELP,
        Some("validate") => VALIDATE_HELP,
        Some("export") => EXPORT_HELP,
        Some("add-note") => ADD_NOTE_HELP,
        Some("add-notes") => ADD_NOTES_HELP,
        Some("inspect") => INSPECT_HELP,
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
  new        write a deck with a fresh job_id and op_id
  validate   check a deck file
  export     write an apkg for one deck and its subdecks
  add-note   append one note to a deck file
  add-notes  append notes from a JSON array or JSONL
  inspect    print Stage E note facts for an apkg

global flags:
  --json     print one JSON object on stdout
  -h, --help show this help and exit 0

Collections are temporary. inspect reads one apkg through Stage E and does
not open a user collection. The other commands do not import a package.
";

const NEW_HELP: &str = "\
hatto-card new — write an example deck

usage:
  hatto-card [--json] new [--empty] [--output FILE] [--deck-name NAME]
      [--notetype NAME]

flags:
  --output FILE     write the deck JSON here
  --deck-name NAME  set deck_name (default: Example)
  --notetype NAME   seed notetype (stock or Hatto name)
  --empty           write notes: [] instead of the 3 example notes
  -h, --help        show this help and exit 0

job_id and op_id are new UUIDv4 values on every run. Without --empty the
deck has three notes. Local note guids are uuid5 values from op_id. The
source_guid note uses normalize_import_guid and does not use job_id.
Without --notetype the 3-note deck keeps notetype Basic. --empty without
--notetype writes notetype Hatto Basic. --notetype must be a seed notetype.

With --output, media/dot.png is created beside the file when it is missing,
so validate and export can run next. An existing dot.png is left unchanged.
";

const VALIDATE_HELP: &str = "\
hatto-card validate — check a deck file

usage:
  hatto-card [--json] validate --deck FILE
  hatto-card [--json] validate --deck -

flags:
  --deck FILE  deck JSON to check, or - to read stdin
  -h, --help   show this help and exit 0

Exit status is 0 when the deck JSON, note guids, seed notetype, field
counts, cloze syntax, and media references pass. An empty notes array is
rejected. --deck - resolves a relative media_dir from the current directory.
";

const EXPORT_HELP: &str = "\
hatto-card export — write an apkg for one deck and its subdecks

usage:
  hatto-card [--json] export --deck FILE --output FILE
  hatto-card [--json] export --deck - --output FILE

flags:
  --deck FILE    deck JSON to read, or - to read stdin
  --output FILE  apkg to write
  -h, --help     show this help and exit 0

The package is the root deck_name and every note deck under it
(Root::Sub). --deck - resolves a relative media_dir from the current
directory.
";

const ADD_NOTE_HELP: &str = "\
hatto-card add-note — append one note

usage:
  hatto-card [--json] add-note --deck FILE --notetype NAME --field TEXT
      [--field TEXT ...] [--tag TEXT ...] [--deck-name NAME] [--output FILE]
      [--op-id UUID] [--k N]
  hatto-card [--json] add-note --deck FILE --notetype NAME --field TEXT
      [--field TEXT ...] [--job-id UUID] --source-guid TEXT

flags:
  --deck FILE          deck JSON to update
  --output FILE        write this path instead of --deck
  --notetype NAME      must match the deck notetype
  --deck-name NAME     this note's deck; the root, or root::child
  --field TEXT         one field, repeatable, in notetype order
  --tag TEXT           tag, repeatable; the value may start with -
  --op-id UUID         local note op_id (default: new UUIDv4)
  --k N                local note index; requires --op-id
  --job-id UUID        imported note job_id
  --source-guid TEXT   imported note source bytes
  -h, --help           show this help and exit 0

--job-id and --source-guid cannot be combined with --op-id or --k.
--job-id is stored on the note and is not used to derive the guid.
With no guid flags, add-note makes a UUIDv4 op_id and sets k to 0.
--k without --op-id is rejected. The guid would change on every run.
--field and --tag values may start with - or --, and may be the words
help, -h, --help, or --json. Those are field or tag text, not help and
not the json flag. --field=--bar is the same as two arguments. The file
is written only after the same checks as validate. A failure leaves the
deck file unchanged.
";

const ADD_NOTES_HELP: &str = "\
hatto-card add-notes — append notes from JSON or JSONL

usage:
  hatto-card [--json] add-notes --deck FILE --input FILE|-
      [--output FILE] [--op-id UUID] [--start-k N] [--notetype NAME]

flags:
  --deck FILE       deck JSON to update
  --input FILE      a JSON array, JSONL, or - for stdin
  --output FILE     write this path instead of --deck
  --notetype NAME   default notetype for items that omit it
  --op-id UUID      op_id for items that omit local and import ids
  --start-k N       first k for those items (default: 0)
  -h, --help        show this help and exit 0

Each item has fields, and may set tags, notetype, deck_name, op_id and k,
or job_id and source_guid. Unknown keys are rejected. An item that sets
none of op_id, k, and source_guid uses this command's op_id (one new
UUIDv4 when --op-id is omitted) and k starting at --start-k, increasing
by 1. An item with k and no op_id uses --op-id, and is rejected when
that flag is omitted. Errors for the notes in this call use input[N].
The file is written only after every note passes the same checks as
validate.
";

const INSPECT_HELP: &str = "\
hatto-card inspect — print Stage E note facts for one apkg

usage:
  hatto-card [--json] inspect FILE

flags:
  --json     print one JSON object on stdout
  -h, --help show this help and exit 0

FILE is read only. inspect copies it into a new temporary data directory
and reads it with Stage E. It does not open a user collection. The
temporary directory is removed before exit, including when Stage E fails.

Default size limits are the v0 desktop product ceilings: 512 MiB
compressed, and 2 GiB for the sum of uncompressed zip entries.

Notes are printed in note-id order. Each note includes guid,
content_hash (lowercase hex), notetype_id, and mod. Without --json the
object is pretty-printed. inspect outputs the same Stage E facts used
by import.
";

fn emit(json: bool, value: &Value) {
    if json {
        println!("{}", serde_json::to_string(value).expect("json"));
    } else {
        println!("{}", serde_json::to_string_pretty(value).expect("json"));
    }
}
