#!/usr/bin/env bash
# usage: job.sh PHASE NAME_A NAME_B PAIRS LOG2 THREADS SEED0 BUDGET DIAG   (PHASE: prep build probe verify pair all)
# cwd holds A/ B/ (checkouts), rig/ (this dir), optionally q/{a,b}.enc (encrypted patches).
set -uo pipefail
phase="$1"; shift
name_a="$1"; name_b="$2"; pairs="$3"; log2="$4"; threads="$5"; seed0="$6"; budget="$7"; diag="${8:-0}"
root="$PWD"; out="$root/out"; mkdir -p "$out"
now() { python3 -c 'import time;print("%.1f"%time.time())'; }
enc() { # encrypt a private log into the artifact dir; public log never shows it
  [[ -n "${RIG_KEY:-}" && -f "$1" ]] && openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:RIG_KEY -in "$1" -out "$out/$(basename "$1").enc" || true
}
fail() { echo "RIGFAIL $*"; echo "RIGFAIL $*" >> "$out/summary.txt"; exit 1; }
private=0; [[ -f "$root/q/a.enc" || -f "$root/q/b.enc" ]] && private=1
export RUSTUP_TOOLCHAIN=1.97.0 FLOCK_REQUIRE_SANDBOX=1
# setup.sh exports CC, benchmark.sh does not: the cc build script (sha2-asm) then sees a changed
# env and cargo rebuilds the whole worker inside benchmark.sh. Pin CC so both see the same value
# (RIG_KEEP_CC_SKEW=1 reproduces the scorer's double build).
[[ "${RIG_KEEP_CC_SKEW:-0}" == 1 ]] || export CC="$(xcrun --find clang 2>/dev/null)"
[[ -f "$out/rustflags" ]] && export RUSTFLAGS="$(cat "$out/rustflags")"
wa="$root/A/target/challenge-candidate/challenge/flock-benchmark-worker"
wb="$root/B/target/challenge-candidate/challenge/flock-benchmark-worker"
th="$threads"; [[ "$th" == auto ]] && th=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)

phase_prep() {
echo "== preflight"
{
  sw_vers | tr '\n' ' '; echo
  echo "cpu=$(sysctl -n machdep.cpu.brand_string) ncpu=$(sysctl -n hw.ncpu) p=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null) e=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null) mem=$(( $(sysctl -n hw.memsize) / 1048576 ))MB"
  echo "l1d=$(sysctl -n hw.perflevel0.l1dcachesize 2>/dev/null) l2=$(sysctl -n hw.perflevel0.l2cachesize 2>/dev/null) model=$(sysctl -n hw.model)"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Metal|Vendor|Type|VRAM" | tr -s ' ' | tr '\n' ';'; echo
  cat > "$root/metal.swift" <<'SWIFT'
import Metal
if let d = MTLCreateSystemDefaultDevice() {
  print("metal=\(d.name) unified=\(d.hasUnifiedMemory) lowpower=\(d.isLowPower) maxbuf=\(d.maxBufferLength >> 20)MB rec_ws=\(d.recommendedMaxWorkingSetSize >> 20)MB")
} else { print("metal=none") }
SWIFT
  swift "$root/metal.swift" 2>/dev/null || echo "metal=probe-failed"
  /usr/bin/time -l ls / 2>&1 | grep -E "instructions|cycles" | tr -s ' ' | tr '\n' ';'; echo
  vm_stat | grep -E "Pages free|Pages active|Pages wired" | tr -s ' ' | tr '\n' ';'; echo
} | tee "$out/runner.txt"

for x in a b; do
  if [[ -f "$root/q/$x.enc" ]]; then
    X=$(echo "$x" | tr a-z A-Z)
    [[ -n "${RIG_KEY:-}" ]] || fail "patch for $X but no key"
    openssl enc -d -aes-256-cbc -pbkdf2 -pass env:RIG_KEY -in "$root/q/$x.enc" -out "$root/$x.patch" || fail "decrypt $X"
    ( cd "$root/$X" && git apply --whitespace=nowarn "$root/$x.patch" ) > "$root/apply-$X.log" 2>&1 || { enc "$root/apply-$X.log"; fail "patch $X does not apply"; }
    ( cd "$root/$X" && git diff --stat | tail -1 | sed 's/^/patched '"$X"':/' ) | sed 's/[a-zA-Z_\/.-]*\.rs//g'
    rm -f "$root/$x.patch"
  fi
done

echo "== toolchain"
rustup toolchain install 1.97.0 --profile minimal >/dev/null 2>&1 || fail "toolchain"
# Virtualized runners hide the CPU family from LLVM: "native" then lacks aes/sha3 and the
# NEON kernels do not compile. Name the real core instead (M1 = the scorer's set minus bf16/i8mm/bti).
cpu=native
rustc --print cfg -C target-cpu=native | grep -q '"sha3"' || cpu="${RIG_CPU:-apple-m1}"
export RUSTFLAGS="-C target-cpu=$cpu"
echo "$RUSTFLAGS" > "$out/rustflags"
echo "RUSTFLAGS=$RUSTFLAGS" | tee -a "$out/summary.txt"
cargo fetch --locked --manifest-path "$root/A/Cargo.toml" >/dev/null 2>&1 || true
rustc --version
}

phase_build() {
echo "== build (setup.sh, challenge profile)"
for X in A B; do
  t0=$(now)
  ( cd "$root/$X" && ./setup.sh ) > "$root/build-$X.log" 2>&1; rc=$?
  t1=$(now)
  secs=$(python3 -c "print('%.1f'%($t1-$t0))")
  eval "build_$X=$secs"
  if [[ $rc != 0 ]]; then
    if [[ $private == 1 ]]; then enc "$root/build-$X.log"; else grep -A12 "^error" "$root/build-$X.log" | head -80; fi
    fail "build $X rc=$rc after ${secs}s"
  fi
  grep -c "warning" "$root/build-$X.log" | sed "s/^/build $X warnings=/"
  echo "build $X wall=${secs}s"
done
echo "build A=${build_A}s B=${build_B}s" | tee -a "$out/summary.txt"
ls -l "$wa" "$wb" | awk '{print "worker bytes", $5}'
}

phase_probe() {
echo "== peak memory of one proof (/usr/bin/time -l, log2=$log2)"
mkdir -p "$root/mem" && rm -f "$root/mem/"*
( while [[ ! -f "$root/mem/ready" ]]; do sleep 0.05; done; echo 12345 ) | \
  env -i RAYON_NUM_THREADS="$th" TMPDIR="$root/mem" /usr/bin/time -l "$wa" "$log2" "$root/mem/ready" "$root/mem/proof" 2> "$root/mem/time.txt" || fail "direct worker run"
grep -E "real|maximum resident|peak memory" "$root/mem/time.txt" | tr -s ' ' | tr '\n' ';' | tee -a "$out/summary.txt"; echo | tee -a "$out/summary.txt"

if [[ "$diag" == 3 ]]; then
  echo "== diag3: 2^18 under env toggles (direct launch, A): wall, cpu, instructions, footprint"
  i=0
  for cfg in "T=$th" "T=$th FLOCK_NO_GPU_COMMIT=1" "T=$th FLOCK_NO_GPU_COMMIT=1 FLOCK_NO_PREFAULT=1" \
             "T=10 FLOCK_EPOOL_FORCE_THREADS=4" "T=$th" "T=$th FLOCK_NO_GPU_COMMIT=1" "T=10 FLOCK_EPOOL_FORCE_THREADS=4" "T=1"; do
    i=$((i+1)); rm -f "$root/mem/ready" "$root/mem/proof"
    t="${cfg%% *}"; t="${t#T=}"; extra="${cfg#T=$t}"
    ( while [[ ! -f "$root/mem/ready" ]]; do sleep 0.02; done; echo 12345 ) | \
      env -i RAYON_NUM_THREADS="$t" TMPDIR="$root/mem" FLOCK_PHASE_TIMING=1 $extra \
      /usr/bin/time -l "$wa" "$log2" "$root/mem/ready" "$root/mem/proof" 2> "$root/mem/tog-$i.txt"
    echo "toggle[$cfg]: $(grep -E " real|peak memory footprint|maximum resident|instructions retired|cycles elapsed" "$root/mem/tog-$i.txt" | tr -s ' ' | tr '\n' ';') proof=$(shasum -a 256 "$root/mem/proof" | cut -c1-12)" | tee -a "$out/summary.txt"
  done
  echo "-- stderr of run 1 (default)"; cut -c1-220 "$root/mem/tog-1.txt" | tail -80
  echo "-- stderr of run 2 (nogpu)"; cut -c1-220 "$root/mem/tog-2.txt" | tail -80
fi
if [[ "$diag" == 2 ]]; then
  echo "== diag2: size sweep (direct launch, A): wall, footprint, proof phases, GPU on/off"
  for l in 14 15 16 17; do
    for mode in gpu nogpu; do
      rm -f "$root/mem/"*
      extra=""; [[ $mode == nogpu ]] && extra="FLOCK_NO_GPU_COMMIT=1"
      ( while [[ ! -f "$root/mem/ready" ]]; do sleep 0.02; done; echo 12345 ) | \
        env -i RAYON_NUM_THREADS="$th" TMPDIR="$root/mem" FLOCK_COMMIT_TIMING=1 FLOCK_OPEN_TIMING=1 $extra \
        /usr/bin/time -l "$wa" "$l" "$root/mem/ready" "$root/mem/proof" 2> "$root/mem/sweep-$l-$mode.txt"
      echo "sweep log2=$l $mode: $(grep -E " real|peak memory footprint|maximum resident" "$root/mem/sweep-$l-$mode.txt" | tr -s ' ' | tr '\n' ';') lig-prove: $(grep -E "lig-prove. total" "$root/mem/sweep-$l-$mode.txt" | awk '{print $(NF-1)}' | tr '\n' ' ') commit: $(grep -E "commit-timing" "$root/mem/sweep-$l-$mode.txt" | awk '{print $2 $3}' | tr '\n' ' ')" | tee -a "$out/summary.txt"
    done
  done
  echo "-- full stderr log2=17 gpu"; cat "$root/mem/sweep-17-gpu.txt" | cut -c1-200 | head -120
fi
if [[ "$diag" == 1 ]]; then
  echo "== diag: commit/open timing, GPU on vs off (direct launch, A)"
  for mode in gpu nogpu; do
    rm -f "$root/mem/"*
    extra=""; [[ $mode == nogpu ]] && extra="FLOCK_NO_GPU_COMMIT=1"
    ( while [[ ! -f "$root/mem/ready" ]]; do sleep 0.05; done; echo 12345 ) | \
      env -i RAYON_NUM_THREADS="$th" TMPDIR="$root/mem" FLOCK_COMMIT_TIMING=1 FLOCK_OPEN_TIMING=1 $extra \
      "$wa" "$log2" "$root/mem/ready" "$root/mem/proof" 2> "$root/mem/diag-$mode.txt"
    echo "-- $mode ($(wc -l < "$root/mem/diag-$mode.txt") stderr lines; last 60)"
    tail -60 "$root/mem/diag-$mode.txt"
  done
fi

}

phase_verify() {
[[ "$pairs" == 0 ]] && return 0
echo "== trusted verifier (benchmark.sh; private seeds) at log2=10 and log2=$log2"
for X in A B; do
  for l in 10 "$log2"; do
    ( cd "$root/$X" && BLAKE3_LOG2="$l" BLAKE3_THREADS="$threads" BLAKE3_WARMUP_RUNS=0 BLAKE3_RUNS=2 \
        BENCHMARK_OUTPUT_DIR="$root/bench-$X" ./benchmark.sh ) > "$root/verify-$X-$l.log" 2>&1; rc=$?
    if [[ $rc != 0 ]]; then
      if [[ $private == 1 ]]; then enc "$root/verify-$X-$l.log"; else tail -30 "$root/verify-$X-$l.log"; fi
      echo "verify $X log2=$l REJECTED" | tee -a "$out/summary.txt"
      fail "trusted verifier rejected $X at log2=$l"
    fi
    echo "verify $X log2=$l OK $(grep -E 'Median latency|Threads' "$root/verify-$X-$l.log" | tr -d '\n') recompiled=$(grep -c '^ *Compiling' "$root/verify-$X-$l.log")" | tee -a "$out/summary.txt"
  done
done

}

phase_pair() {
[[ "$pairs" == 0 ]] && return 0
echo "== paired interleaved timing"
python3 "$root/rig/pair.py" --a "$wa" --b "$wb" --name-a "$name_a" --name-b "$name_b" \
  --pairs "$pairs" --log2 "$log2" --threads "$threads" --seed0 "$seed0" --budget "$budget" \
  --scratch "$root/pair-scratch" --out "$out/pair.json" | tee "$root/pair.log"
rc=${PIPESTATUS[0]}
grep -E "^(pair|identical|detail|env) " "$root/pair.log" >> "$out/summary.txt"
[[ $rc == 0 ]] || fail "pair driver rc=$rc"
echo "== summary"; cat "$out/summary.txt"
}

case "$phase" in
  all) phase_prep; phase_build; phase_probe; phase_verify; phase_pair ;;
  *) "phase_$phase" ;;
esac
