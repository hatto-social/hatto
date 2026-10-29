use std::sync::Mutex;

/// Same bytes contract as the napi spike: `init_backend` plus
/// `Backend::run_service_method`. Collection import/export is not called directly.
pub struct BackendHandle {
    inner: Mutex<Option<hatto_rslib_bridge::BackendHandle>>,
}

impl BackendHandle {
    pub async fn run(
        &self,
        service: u32,
        method: u32,
        input: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        let backend = self
            .inner
            .lock()
            .map_err(|err| err.to_string())?
            .as_ref()
            .cloned()
            .ok_or_else(|| "backend is closed".to_string())?;
        let joined = std::thread::spawn(move || backend.run(service, method, &input))
            .join()
            .map_err(|_| "worker panicked".to_string())?;
        joined.map_err(|bytes| hatto_rslib_bridge::format_backend_error(&bytes))
    }

    pub async fn close(&self) -> Result<(), String> {
        self.inner.lock().map_err(|err| err.to_string())?.take();
        Ok(())
    }
}

/// `init` is an encoded `anki.backend.BackendInit` message.
pub async fn open(init: Vec<u8>) -> Result<BackendHandle, String> {
    let handle = std::thread::spawn(move || hatto_rslib_bridge::BackendHandle::open(&init))
        .join()
        .map_err(|_| "worker panicked".to_string())?
        .map_err(|err| err)?;
    Ok(BackendHandle {
        inner: Mutex::new(Some(handle)),
    })
}

/// apkg import/export creates temp files via `std::env::temp_dir()`.
/// On Android that directory is not writable unless `TMPDIR` points at the app cache.
pub fn set_temp_dir(path: String) -> Result<(), String> {
    if path.is_empty() {
        return Err("temp dir is empty".to_string());
    }
    // SAFETY: called once during test startup, before rslib opens a collection.
    unsafe { std::env::set_var("TMPDIR", &path) };
    Ok(())
}
