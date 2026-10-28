//! Async-only napi bindings. Every collection operation goes through
//! `Backend::run_service_method` in `hatto_rslib_bridge`.

use std::sync::Mutex;

use napi::bindgen_prelude::*;
use napi_derive::napi;

#[napi]
pub struct BackendHandle {
    inner: Mutex<Option<hatto_rslib_bridge::BackendHandle>>,
}

#[napi]
impl BackendHandle {
    /// `service` / `method` are the indices rslib generated for this Anki
    /// revision. `input` and the resolved bytes are protobuf messages.
    /// Backend failures reject with `BackendError kind=… bytes_hex=…`.
    #[napi]
    pub async fn run(&self, service: u32, method: u32, input: Buffer) -> Result<Buffer> {
        let backend = {
            let guard = self.inner.lock().unwrap();
            guard
                .as_ref()
                .cloned()
                .ok_or_else(|| Error::from_reason("backend is closed"))?
        };
        let input = input.to_vec();
        let result = tokio::task::spawn_blocking(move || backend.run(service, method, &input))
            .await
            .map_err(|err| Error::from_reason(format!("worker panicked: {err}")))?;
        match result {
            Ok(bytes) => Ok(Buffer::from(bytes)),
            Err(err_bytes) => Err(service_error(err_bytes)),
        }
    }

    #[napi]
    pub async fn close(&self) -> Result<()> {
        self.inner.lock().unwrap().take();
        Ok(())
    }
}

/// `init` is an encoded `anki.backend.BackendInit` message.
#[napi]
pub async fn open(init: Buffer) -> Result<BackendHandle> {
    let init = init.to_vec();
    let handle = tokio::task::spawn_blocking(move || hatto_rslib_bridge::BackendHandle::open(&init))
        .await
        .map_err(|err| Error::from_reason(format!("worker panicked: {err}")))?
        .map_err(Error::from_reason)?;
    Ok(BackendHandle {
        inner: Mutex::new(Some(handle)),
    })
}

fn service_error(bytes: Vec<u8>) -> Error {
    let summary = hatto_rslib_bridge::format_backend_error(&bytes);
    let hex = bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    Error::from_reason(format!("{summary} bytes_hex={hex}"))
}
