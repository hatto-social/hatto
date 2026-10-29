//! Bytes-only handle around `anki::backend::init_backend` and
//! `Backend::run_service_method`. This crate does not call `Collection`
//! import/export methods.

use anki::backend::init_backend;
use anki::backend::Backend;
use prost::Message;

/// One Anki backend. Cloning is cheap (`Backend` is an `Arc`).
/// Dropping the last clone closes the collection if one is open.
#[derive(Clone)]
pub struct BackendHandle {
    backend: Backend,
}

impl BackendHandle {
    /// `init` is an encoded `anki.backend.BackendInit` protobuf message.
    pub fn open(init: &[u8]) -> Result<Self, String> {
        let backend = init_backend(init)?;
        Ok(Self { backend })
    }

    /// Protobuf service call. `Err` bytes are an encoded `anki.backend.BackendError`.
    pub fn run(&self, service: u32, method: u32, input: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
        self.backend.run_service_method(service, method, input)
    }
}

/// Human-readable form of a `BackendError` protobuf payload.
pub fn format_backend_error(bytes: &[u8]) -> String {
    match anki_proto::backend::BackendError::decode(bytes) {
        Ok(err) => format!(
            "BackendError kind={} message={} context={}",
            err.kind, err.message, err.context
        ),
        Err(err) => format!("BackendError undecodable ({err})"),
    }
}
