#![no_main]

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use libfuzzer_sys::fuzz_target;
use tectonic::digest::DigestData;
use tectonic::errors::Error;
use tectonic::driver::{OutputFormat, ProcessingSessionBuilder};
use tectonic::io::{InputHandle, IoProvider, OpenResult};
use tectonic::status::{NoopStatusBackend, StatusBackend};
use tectonic_bridge_core::EngineAbortedError;
use tectonic_bundles::{dir::DirBundle, Bundle};

// Offline stand-in for upstream's `latex_to_pdf` harness: the same driver (XeTeX passes) over
// the test-suite support files instead of the network bundle. The plain format is generated
// once per process. Output stops at XDV: xdvipdfmx's `skip_modifier` (dpx-agl.c) calls
// `memcmp(p, modifier, len)` with the wrong length, which ASan aborts on during every PDF
// startup (`agl_init_map`), so a PDF run would never reach the fuzzed input.
const ASSETS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tests/assets");

// DirBundle insists on a SHA256SUM file; the support-file directory has none, and a constant
// digest is enough because the format cache lives in a per-process directory.
struct AssetBundle(DirBundle);

impl IoProvider for AssetBundle {
    fn input_open_name(
        &mut self,
        name: &str,
        status: &mut dyn StatusBackend,
    ) -> OpenResult<InputHandle> {
        self.0.input_open_name(name, status)
    }
}

impl Bundle for AssetBundle {
    fn get_digest(&mut self) -> tectonic::Result<DigestData> {
        Ok(DigestData::zeros())
    }

    fn all_files(&self) -> Vec<String> {
        self.0.all_files()
    }
}

// Format caches of earlier fuzzer processes whose pid is gone (a libFuzzer exit on a crash skips
// every destructor, so the directory cannot be removed by the process that made it).
fn remove_stale_format_caches() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else { return };
    for e in entries.flatten() {
        let name = e.file_name();
        let Some(pid) = name.to_str().and_then(|n| n.strip_prefix("tectonic-fuzz-fmt-")) else {
            continue;
        };
        if pid.parse::<u32>().is_ok() && !Path::new("/proc").join(pid).exists() {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

fn format_cache() -> &'static Path {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        remove_stale_format_caches();
        let dir = std::env::temp_dir().join(format!("tectonic-fuzz-fmt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("cannot create the format cache directory");
        dir
    })
}

// Engine arrays, as freed by the engine's own `tt_cleanup()` at the end of every run.
macro_rules! engine_arrays {
    ($($name:ident),* $(,)?) => {
        extern "C" {
            fn free(p: *mut c_void);
            static mut hash: *mut c_void;
            $(static mut $name: *mut c_void;)*
        }
        unsafe fn free_engine_arrays() {
            $(free($name); $name = std::ptr::null_mut();)*
            // `yhash` is file-static in xetex-ini.c; the engine sets `hash = yhash - hash_offset`.
            free(hash.cast::<u8>().add(HASH_OFFSET * HASH_ENTRY_SIZE).cast());
            hash = std::ptr::null_mut();
        }
    };
}
// `hash_offset` (xetex-ini.c) and sizeof(b32x2).
const HASH_OFFSET: usize = 514;
const HASH_ENTRY_SIZE: usize = 8;

engine_arrays!(
    mem, eqtb, str_pool, str_start, font_info, buffer, nest, save_stack, input_stack,
    param_stack, hyph_word, hyph_list, hyph_link, trie_trl, trie_tro, trie_trc,
);

// An abort raised by a bare `_tt_abort()` skips `tt_cleanup()` (fatal_error()/overflow()/confusion()
// run it first), so the ~260 MB of arrays stay allocated: upstream's CLI exits right after and never
// noticed. They are freed here so the next input does not start with the memory of earlier ones.
// Only these messages (document-reachable bare sites) are matched: freeing after an abort that
// already ran `tt_cleanup()` would free twice, and `tt_cleanup()` itself cannot be called from here
// because it closes files through the bridge state that no longer exists.
const BARE_ABORTS: [&str; 7] = [
    "failed to open input file",
    "terminal input forbidden",
    "string pool overflow",
    "unable to read an entire line",
    "could not read mapping file",
    "not enough memory to load another font",
    "cannot open log file output",
];

fn free_engine_after_bare_abort(e: &Error) {
    let bare = e.chain().any(|c| {
        c.downcast_ref::<EngineAbortedError>()
            .is_some_and(|a| BARE_ABORTS.iter().any(|p| a.to_string().starts_with(p)))
    });
    if bare {
        // SAFETY: the engine run has returned and the harness is single-threaded.
        unsafe { free_engine_arrays() };
    }
}

fn compile(data: &[u8]) -> Result<Vec<u8>, ()> {
    let mut status = NoopStatusBackend::default();
    let mut sb = ProcessingSessionBuilder::default();
    sb.bundle(Box::new(AssetBundle(DirBundle::new(ASSETS))))
        .primary_input_buffer(data)
        .tex_input_name("texput.tex")
        .format_name("plain")
        .format_cache_path(format_cache())
        .keep_logs(false)
        .keep_intermediates(false)
        .print_stdout(false)
        .output_format(OutputFormat::Xdv)
        .do_not_write_output_files();
    let mut sess = sb.create(&mut status).map_err(|_| ())?;
    if let Err(e) = sess.run(&mut status) {
        free_engine_after_bare_abort(&e);
        return Err(());
    }
    let mut files = sess.into_file_data();
    files.remove("texput.xdv").map(|f| f.data).ok_or(())
}

fn init() {
    // Warm the format cache so the first fuzz iteration is not the slow one.
    let _ = compile(b"x\\bye\n");
}

fuzz_target!(init: init(), |data: &[u8]| {
    let _ = compile(data);
});
