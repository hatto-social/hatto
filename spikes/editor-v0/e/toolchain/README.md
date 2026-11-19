# Rust toolchain shims for spike e

cargokit 0.9.1 runs `rustup run stable` and looks for `$HOME/.cargo/bin/rustup` before `PATH`. `RUSTUP_TOOLCHAIN` does not change that call.

- `rustup_shim_home` is the wrapper to install as `.cargo/bin/rustup` under a **separate** `HOME` (`$HOME/spike-pinhome`). It does not replace the real rustup. Runbook section A0.
- `rustup_shim_path` is the PATH-only variant. cargokit does not call it. Do not use it for the Mac build.

`PIN_TOOLCHAIN=1.97.1` rewrites only `rustup run stable`. Other rustup commands pass through. `REAL_HOME` must be the home that contains `.cargo/bin/rustup` and `.rustup`.
