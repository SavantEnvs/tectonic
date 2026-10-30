#![no_main]

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use libfuzzer_sys::{fuzz_target, Corpus};
use tectonic::digest::DigestData;
use tectonic::driver::{OutputFormat, ProcessingSessionBuilder};
use tectonic::io::{InputHandle, IoProvider, OpenResult};
use tectonic::status::{NoopStatusBackend, StatusBackend};
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

fn format_cache() -> &'static Path {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("tectonic-fuzz-fmt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("cannot create the format cache directory");
        dir
    })
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
    sess.run(&mut status).map_err(|_| ())?;
    let mut files = sess.into_file_data();
    files.remove("texput.xdv").map(|f| f.data).ok_or(())
}

fn init() {
    // Warm the format cache so the first fuzz iteration is not the slow one.
    let _ = compile(b"x\\bye\n");
}

// A missing `\input` file (or terminal `\read`) is a fatal XeTeX error: it longjmps out of the
// engine without freeing its ~120 MB of arrays, so a few such inputs exhaust the fuzzer's RSS
// limit. Those inputs are rejected rather than run.
fn aborts_engine(data: &[u8]) -> bool {
    [&b"\\input"[..], b"\\read"].iter().any(|n| data.windows(n.len()).any(|w| w == *n))
}

fuzz_target!(init: init(), |data: &[u8]| -> Corpus {
    if aborts_engine(data) {
        return Corpus::Reject;
    }
    let _ = compile(data);
    Corpus::Keep
});
