//! Pairs iSH+ with the iPhone or iPad it runs on (iOS 27+), so its built-in
//! JIT enabler can use the device's developer services without a computer.
//!
//! iSH+ acts as a "pairable host": it listens on a TCP port, iSH+ advertises
//! it over Bonjour (`_remotepairing-pairable-host._tcp`, with the TXT records
//! given to `ready`), the user picks it in Settings > Privacy & Security >
//! Developer Mode and types the PIN given to `pin`. The result is a
//! RemotePairing pairing file (XML plist), as StikJIT reads it.
//!
//! Adapted from idevice's own FFI (ffi/src/pairable_host.rs, MIT), except that
//! advertising is left to the app: iOS only allows raw multicast with a
//! special entitlement, while Bonjour (NetService) needs Local Network access.

use std::ffi::{c_char, c_void, CStr, CString};
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};

/// Called once listening: the Bonjour service name, port and TXT records to advertise.
pub type ReadyCallback = extern "C" fn(
    ctx: *mut c_void,
    service_name: *const c_char,
    port: u16,
    txt_keys: *const *const c_char,
    txt_values: *const *const c_char,
    txt_count: usize,
);
/// Called with the 6-digit PIN the user types on the device.
pub type PinCallback = extern "C" fn(ctx: *mut c_void, pin: *const c_char);

struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// Set by `ishplus_pairing_cancel` to end a running `ishplus_pairing_run`.
static CANCELLED: AtomicBool = AtomicBool::new(false);

/// Ends the running pairing (it returns "Cancelled."). Safe from any thread.
#[no_mangle]
pub extern "C" fn ishplus_pairing_cancel() {
    CANCELLED.store(true, Ordering::SeqCst);
}

fn error(out: *mut *mut c_char, message: String) -> i32 {
    if !out.is_null() {
        unsafe { *out = CString::new(message).unwrap_or_default().into_raw() };
    }
    -1
}

/// Waits for this device to pair with iSH+. Blocks until it has, it fails,
/// or `ishplus_pairing_cancel` is called. On success returns 0 and the pairing
/// file in `out_file`/`out_len` (free with `ishplus_pairing_free`) and the
/// device's name in `out_device` (free with `ishplus_pairing_free_string`);
/// otherwise -1 and a message in `out_error` (free with
/// `ishplus_pairing_free_string`).
///
/// # Safety
/// `name` and `model` are valid C strings; the out pointers are valid or NULL.
#[no_mangle]
pub unsafe extern "C" fn ishplus_pairing_run(
    name: *const c_char,
    model: *const c_char,
    ready: ReadyCallback,
    pin: PinCallback,
    ctx: *mut c_void,
    out_file: *mut *mut u8,
    out_len: *mut usize,
    out_device: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    CANCELLED.store(false, Ordering::SeqCst);
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned();
    let model = unsafe { CStr::from_ptr(model) }.to_string_lossy().into_owned();
    let ctx = Ctx(ctx);
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => return error(out_error, format!("Could not start: {e}")),
    };
    let result = runtime.block_on(async move {
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
            .await
            .map_err(|e| format!("Could not listen for the device: {e}"))?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();

        let mut pairing_file = RpPairingFile::generate(&name);
        let host_info = PairableHostInfo::generate(&name, &model);
        let service_name = pairing_file.identifier.clone();

        // The app advertises the service
        let txt = host_info.mdns_txt_records(&service_name);
        let keys: Vec<CString> = txt.iter().map(|(k, _)| CString::new(k.as_str()).unwrap_or_default()).collect();
        let values: Vec<CString> = txt.iter().map(|(_, v)| CString::new(v.as_str()).unwrap_or_default()).collect();
        let key_ptrs: Vec<*const c_char> = keys.iter().map(|k| k.as_ptr()).collect();
        let value_ptrs: Vec<*const c_char> = values.iter().map(|v| v.as_ptr()).collect();
        let cname = CString::new(service_name.as_str()).unwrap_or_default();
        ready(ctx.0, cname.as_ptr(), port, key_ptrs.as_ptr(), value_ptrs.as_ptr(), txt.len());

        let pair = async {
            let (stream, _) = listener.accept().await.map_err(|e| format!("The device could not connect: {e}"))?;
            let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
            let peer = host
                .accept(&mut pairing_file, |code| async move {
                    if let Ok(code) = CString::new(code) {
                        pin(ctx.0, code.as_ptr());
                    }
                })
                .await
                .map_err(|e| format!("Pairing failed: {e}"))?;
            Ok::<_, String>(peer)
        };
        let cancelled = async {
            while !CANCELLED.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        };
        let peer = tokio::select! {
            biased;
            _ = cancelled => return Err("Cancelled.".to_string()),
            r = pair => r?,
        };
        Ok((pairing_file.to_bytes(), peer.name))
    });
    match result {
        Ok((bytes, device)) => {
            let mut bytes = bytes.into_boxed_slice();
            unsafe {
                *out_len = bytes.len();
                *out_file = bytes.as_mut_ptr();
                std::mem::forget(bytes);
                if !out_device.is_null() {
                    *out_device = CString::new(device).unwrap_or_default().into_raw();
                }
            }
            0
        }
        Err(message) => error(out_error, message),
    }
}

/// Frees a pairing file returned by `ishplus_pairing_run`.
///
/// # Safety
/// `data`/`len` come from `ishplus_pairing_run`.
#[no_mangle]
pub unsafe extern "C" fn ishplus_pairing_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)) });
    }
}

/// Frees a string returned by `ishplus_pairing_run`.
///
/// # Safety
/// `s` comes from `ishplus_pairing_run`, or is NULL.
#[no_mangle]
pub unsafe extern "C" fn ishplus_pairing_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
