# tarball

Fast, multi-threaded tarball wrapper with optional progress/ETA and a small benchmark tool.

## Features
- Compress or extract directories with `zstd` or `pigz` (fallback to `gzip`).
- Multi-threaded compression/decompression when supported.
- Progress bar with ETA when `pv` is installed.
- Simple benchmark runner for comparing algorithms and settings.

## Requirements
- `tar` (GNU tar recommended)
- One of: `zstd`, `pigz` (optional fallback: `gzip`)
- Optional: `pv` for progress/ETA
- Optional: `gdu` for accurate size measurement in tests (fallback: `du -sb`)

## Usage
### tarball
Compress a directory:
```
tarball [--zstd|--pigz] DIRECTORY
```

Extract an archive:
```
tarball -d [--zstd|--pigz] ARCHIVE
```

Defaults:
- If `zstd` exists, it is used by default (`zstd -T0`).
- If not, `pigz` is used; otherwise fallback to `gzip`.
- If `pv` is available, progress/ETA is shown automatically.

### tarball_test.sh
Benchmark a directory (2 runs, compress + decompress):
```
tarball_test.sh zstd BA40x
tarball_test.sh zstd-fast BA40x
tarball_test.sh pzstd BA40x
tarball_test.sh pigz BA40x
```

Outputs:
- Creates `tarball_test_result/`
- Writes a log with elapsed time, CPU %, FS I/O, and compression ratio
- Cleans up archives and temporary extraction directories after each run

## Files
- `tarball` — main compression/extraction script
- `tarball_test.sh` — benchmark script

## License
MIT
