#!/usr/bin/env bash
set -euo pipefail

# usage: prints help text.
usage() {
  cat <<'EOF'
Usage:
  tarball_test.sh <algo> <directory>

Algos:
  zstd        -> zstd -T0
  zstd-fast   -> zstd -T0 --fast=3
  pzstd       -> pzstd -p <threads>
  pigz        -> pigz -p <threads>

Examples:
  tarball_test.sh zstd BA40x
  tarball_test.sh zstd-fast BA40x
  tarball_test.sh pzstd BA40x
  tarball_test.sh pigz BA40x
EOF
}

# err: prints an error and exits.
err() {
  echo "tarball_test: $*" >&2
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

algo="$1"
dir="$2"

[[ -d "$dir" ]] || err "Directory not found: $dir"

if command -v nproc >/dev/null 2>&1; then
  threads="$(nproc)"
else
  threads="4"
fi

case "$algo" in
  zstd)
    comp_cmd="zstd -T0"
    decomp_cmd="zstd -d -T0"
    archive_ext="tar.zst"
    ;;
  zstd-fast)
    comp_cmd="zstd -T0 --fast=3"
    decomp_cmd="zstd -d -T0"
    archive_ext="tar.zst"
    ;;
  pzstd)
    comp_cmd="pzstd -p ${threads}"
    decomp_cmd="pzstd -d -p ${threads}"
    archive_ext="tar.zst"
    ;;
  pigz)
    comp_cmd="pigz -p ${threads}"
    decomp_cmd="pigz -d -p ${threads}"
    archive_ext="tar.gz"
    ;;
  *)
    err "Unknown algo: $algo"
    ;;
esac

result_dir="$(pwd)/tarball_test_result"
mkdir -p "$result_dir"

base="$(basename "$dir")"
parent="$(cd "$(dirname "$dir")" && pwd -P)"

ts="$(date +%Y%m%d_%H%M%S)"
log="${result_dir}/${algo}_${base}_${ts}.txt"

echo "Tarball Benchmark" > "$log"
echo "Algorithm: $algo" >> "$log"
echo "Source: $parent/$base" >> "$log"
echo "Threads: $threads" >> "$log"
echo "Compression command: $comp_cmd" >> "$log"
echo "Decompression command: $decomp_cmd" >> "$log"
echo "Runs: 2" >> "$log"
echo "Result dir: $result_dir" >> "$log"
echo "" >> "$log"

# drop_caches: try to clear page cache between runs.
drop_caches() {
  sync
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 3 > /proc/sys/vm/drop_caches
  elif command -v sudo >/dev/null 2>&1; then
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || true
  else
    echo "WARN: cannot drop caches" >> "$log"
  fi
}

# source_size_bytes: returns apparent size in bytes.
source_size_bytes() {
  if command -v gdu >/dev/null 2>&1; then
    gdu -n -p --no-prefix --show-apparent-size "$dir" | awk 'NR==1 {print $1}'
  else
    du -sb "$dir" | awk '{print $1}'
  fi
}

# time_to_seconds: converts h:mm:ss or m:ss to seconds.
time_to_seconds() {
  awk -v t="$1" 'BEGIN{
    n=split(t,a,":");
    if(n==2){print a[1]*60+a[2];}
    else if(n==3){print a[1]*3600+a[2]*60+a[3];}
    else{print t;}
  }'
}

# extract_value: extracts a time(1) value by key.
extract_value() {
  local key="$1"
  local file="$2"
  awk -v k="$key" '{
    line=$0
    sub(/^[[:space:]]+/, "", line)
    if(index(line,k)==1){sub(/^[^:]*: /,"", line); print line; exit}
  }' "$file"
}

# run_time: executes a command with /usr/bin/time and logs key metrics.
run_time() {
  local label="$1"
  shift
  local tmp
  tmp="$(mktemp "${result_dir}/time_${label// /_}_XXXX.txt")"
  /usr/bin/time -v -o "$tmp" "$@"

  local elapsed cpu inputs outputs
  elapsed="$(extract_value "Elapsed (wall clock) time (h:mm:ss or m:ss)" "$tmp")"
  cpu="$(extract_value "Percent of CPU this job got" "$tmp")"
  inputs="$(extract_value "File system inputs" "$tmp")"
  outputs="$(extract_value "File system outputs" "$tmp")"

  echo "### $label" >> "$log"
  echo "Elapsed: $elapsed" >> "$log"
  echo "CPU: $cpu" >> "$log"
  echo "FS inputs: $inputs" >> "$log"
  echo "FS outputs: $outputs" >> "$log"
  echo "" >> "$log"

  rm -f "$tmp"
  echo "$elapsed|$cpu|$inputs|$outputs"
}

archive="${result_dir}/${base}_${algo}.${archive_ext}"
extract_dir="${result_dir}/tmp_extract_${algo}"

comp_elapsed=()
comp_cpu=()
comp_in=()
comp_out=()
comp_ratio=()

decomp_elapsed=()
decomp_cpu=()
decomp_in=()
decomp_out=()

src_bytes="$(source_size_bytes)"
echo "Source size (bytes): $src_bytes" >> "$log"
echo "" >> "$log"

for i in 1 2; do
  rm -f "$archive"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  drop_caches
  result="$(run_time "compress run $i" tar -I "$comp_cmd" -C "$parent" -cf "$archive" "$base")"
  IFS="|" read -r elapsed cpu inputs outputs <<< "$result"
  comp_elapsed+=("$(time_to_seconds "$elapsed")")
  comp_cpu+=("${cpu%\%}")
  comp_in+=("$inputs")
  comp_out+=("$outputs")

  archive_bytes="$(stat -c %s "$archive")"
  ratio="$(awk -v a="$archive_bytes" -v s="$src_bytes" 'BEGIN{printf "%.6f", a/s}')"
  comp_ratio+=("$ratio")
  echo "Archive size (bytes) run $i: $archive_bytes" >> "$log"
  echo "Compression ratio run $i (archive/source): $ratio" >> "$log"
  echo "" >> "$log"

  drop_caches
  result="$(run_time "decompress run $i" tar -I "$decomp_cmd" -xf "$archive" -C "$extract_dir")"
  IFS="|" read -r elapsed cpu inputs outputs <<< "$result"
  decomp_elapsed+=("$(time_to_seconds "$elapsed")")
  decomp_cpu+=("${cpu%\%}")
  decomp_in+=("$inputs")
  decomp_out+=("$outputs")

  rm -rf "$extract_dir"
  rm -f "$archive"
done

avg() {
  local arr=("$@")
  local sum=0
  local n="${#arr[@]}"
  for v in "${arr[@]}"; do
    sum="$(awk -v s="$sum" -v v="$v" 'BEGIN{printf "%.6f", s+v}')"
  done
  awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.2f", s/n}'
}

avg_int() {
  local arr=("$@")
  local sum=0
  local n="${#arr[@]}"
  for v in "${arr[@]}"; do
    sum=$((sum + v))
  done
  echo $((sum / n))
}

echo "## Summary (averages)" >> "$log"
echo "Compression time (s): $(avg "${comp_elapsed[@]}")" >> "$log"
echo "Decompression time (s): $(avg "${decomp_elapsed[@]}")" >> "$log"
echo "Compression ratio (avg): $(avg "${comp_ratio[@]}")" >> "$log"
echo "Compression CPU avg (%): $(avg "${comp_cpu[@]}")" >> "$log"
echo "Decompression CPU avg (%): $(avg "${decomp_cpu[@]}")" >> "$log"
echo "Compression FS inputs avg: $(avg_int "${comp_in[@]}")" >> "$log"
echo "Compression FS outputs avg: $(avg_int "${comp_out[@]}")" >> "$log"
echo "Decompression FS inputs avg: $(avg_int "${decomp_in[@]}")" >> "$log"
echo "Decompression FS outputs avg: $(avg_int "${decomp_out[@]}")" >> "$log"

echo ""
echo "Done. Log saved to: $log"
