# Contributing

Contributions are licensed under AGPL-3.0-or-later, the same license as this repository. There is no CLA.

## Developer Certificate of Origin

Every commit must include a `Signed-off-by` trailer:

```
Signed-off-by: Your Name <your.email@example.org>
```

`git commit -s` adds it. The trailer means you certify the Developer Certificate of Origin, version 1.1, for that commit.

The certificate below is reproduced verbatim. It is copyright 2004, 2006 The Linux Foundation and its contributors. Changing it is not allowed. The surrounding text of this file is part of the Hatto repository.

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

The canonical copy is <https://developercertificate.org/>.

## Anki code

Do not copy files out of `third_party/anki`. That submodule is Anki 26.09.3 (`29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba`), unmodified, and this repository links it.

If a change ports or translates Anki code into this repository, the file header names Anki first, then Hatto, keeps `AGPL-3.0-or-later`, and says what was derived and when:

```
// SPDX-FileCopyrightText: Ankitects Pty Ltd and contributors
// SPDX-FileCopyrightText: 2026 Hatto Social contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Derived from ankitects/anki 26.09.3 (29bb700), <path in the Anki tree>.
// Translated from TypeScript to Dart and modified by Hatto on YYYY-MM-DD.
```

Adjust the comment marker and the last line to the language and the kind of change. Generated output that is produced from Anki's `.proto` files is covered from [`REUSE.toml`](REUSE.toml) instead of an inline header, because the generator overwrites the files. See [`NOTICE.md`](NOTICE.md).

## License check

`tools/license/check.sh` runs `reuse lint` and checks that `LICENSE` and `LICENSES/AGPL-3.0-or-later.txt` are the same bytes. `reuse lint` skips Git submodules. Do not pass `--include-submodules`.

`tools/license/gen-notices.sh` regenerates `THIRD_PARTY_NOTICES.md` and `apps/mobile/assets/licenses/`. It runs `cargo deny check licenses` first and fails if a crate license is outside the allow list.

New hand-written product and tool sources take an SPDX header:

```
// SPDX-FileCopyrightText: 2026 Hatto Social contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
```

`reuse annotate --copyright "Hatto Social contributors" --year 2026 --license AGPL-3.0-or-later <file>` writes that header. On reuse 6.3.0, passing the year inside `--copyright` together with `--merge-copyrights` repeats the year. Don't do that.

Config, Markdown, JSON, lockfiles, generated code, `spikes/`, and `apps/demo-app/` are covered by `REUSE.toml` rather than inline headers.

## Pull request checklist

- [ ] Every commit has a `Signed-off-by` line.
- [ ] Did this change copy or translate Anki code? If yes, the header above is on those files.
- [ ] `tools/license/check.sh` passes.
