#!/usr/bin/env bash
# usage: job.sh PHASE NAME_A NAME_B PAIRS LOG2 THREADS SEED0 BUDGET DIAG PENV   (PHASE: prep build probe cmd verify ident pair all)
# cwd holds A/ B/ (checkouts), rig/ (this dir), optionally q/{a,b}.enc (encrypted patches).
set -uo pipefail
phase="$1"; shift
name_a="$1"; name_b="$2"; pairs="$3"; log2="$4"; threads="$5"; seed0="$6"; budget="$7"; diag="${8:-0}"; penv="${9:-}"; big="${10:-0}"; need="${11:-}"
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
memmb=$(( $(sysctl -n hw.memsize) / 1048576 ))
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
echo "runner $(sysctl -n machdep.cpu.brand_string) ncpu=$(sysctl -n hw.ncpu) mem=$(( $(sysctl -n hw.memsize) / 1048576 ))MB" >> "$out/summary.txt"

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
[[ -f "$root/q/nobuild" ]] && return 0
echo "== build (setup.sh, challenge profile)"
# Full tier: A (cold, warms the toolchain and the disk cache) -> B -> A again from scratch; the gate number is B vs the SECOND A.
# Lite tier (q/lite + the record's worker in the Actions cache): build B only; A's worker, build seconds and proof hashes come
# from the job that first built this base.
ac="$root/acache"; lite=0
[[ -f "$root/q/lite" && ! -f "$root/q/a.enc" && -f "$ac/flock-benchmark-worker" && -f "$ac/meta" ]] && lite=1
seq="A B A2 B2"; [[ $lite == 1 ]] && seq="B"
for X in $seq; do
  D=${X%2}
  [[ $X == A2 ]] && rm -rf "$root/A/target/challenge-candidate"
  [[ $X == B2 ]] && rm -rf "$root/B/target/challenge-candidate"
  t0=$(now)
  ( cd "$root/$D" && /usr/bin/time -p ./setup.sh ) > "$root/build-$X.log" 2>&1; rc=$?
  t1=$(now)
  secs=$(python3 -c "print('%.1f'%($t1-$t0))")
  cpu=$(tail -3 "$root/build-$X.log" | awk '$1=="user"||$1=="sys"{s+=$2} END{printf "%.1f", s}')
  eval "build_$X=$secs; cpu_$X=$cpu"
  if [[ $rc != 0 ]]; then
    if [[ $private == 1 ]]; then enc "$root/build-$X.log"; else grep -A12 "^error" "$root/build-$X.log" | head -80; fi
    fail "build $X rc=$rc after ${secs}s"
  fi
  echo "build $X wall=${secs}s cpu=${cpu}s warnings=$(grep -c "^warning" "$root/build-$X.log")"
done
hw="$(sysctl -n machdep.cpu.brand_string | tr -d ' ()')-${memmb}"
if [[ $lite == 1 ]]; then
  mkdir -p "$(dirname "$wa")" && cp "$ac/flock-benchmark-worker" "$wa" && chmod +x "$wa"
  echo "build lite hw=$hw B(cold)=${build_B}s cpu B=${cpu_B}s | cached record build: $(cat "$ac/meta")" | tee -a "$out/summary.txt"
else
  echo "build A1(cold)=${build_A}s B=${build_B}s A2=${build_A2}s B2=${build_B2}s cpu A1=${cpu_A}s B=${cpu_B}s A2=${cpu_A2}s B2=${cpu_B2}s $(python3 -c "
a=[${cpu_A},${cpu_A2}]; b=[${cpu_B},${cpu_B2}]
print('cpu_ratio_minB/minA=%.3f cpu_ratio_B/A2=%.3f spread_A=%.3f spread_B=%.3f' % (min(b)/min(a), b[0]/a[1], max(a)/min(a), max(b)/min(b)))") hw=$hw" | tee -a "$out/summary.txt"
  if [[ ! -f "$root/q/a.enc" && ! -f "$ac/meta" ]]; then
    mkdir -p "$ac" && cp "$wa" "$ac/flock-benchmark-worker" && echo "hw=$hw cpu A1(cold)=${cpu_A}s A2=${cpu_A2}s wall A1=${build_A}s A2=${build_A2}s" > "$ac/meta"
  fi
fi
ls -l "$wa" "$wb" | awk '{print "worker bytes", $5}'
}

phase_probe() {
[[ "$diag" == 0 ]] && return 0
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

phase_cmd() {
# Lane-supplied command(s), run inside the tree(s); output leaves the runner only encrypted.
[[ -f "$root/q/cmd.enc" ]] || return 0
[[ -n "${RIG_KEY:-}" ]] || fail "cmd but no key"
openssl enc -d -aes-256-cbc -pbkdf2 -pass env:RIG_KEY -in "$root/q/cmd.enc" -out "$root/cmd.sh" || fail "decrypt cmd"
sides="B"; [[ -f "$root/q/cmd-both" ]] && sides="A B"
export RIG_ROOT="$root" RIG_A="$root/A" RIG_B="$root/B" RIG_OUT="$out" RIG_THREADS="$th" CARGO_INCREMENTAL=0
for X in $sides; do
  t0=$(now)
  ( cd "$root/$X" && RIG_SIDE=$X bash "$root/cmd.sh" ) > "$root/cmd-$X.log" 2>&1; rc=$?
  t1=$(now)
  echo "cmd $X rc=$rc secs=$(python3 -c "print('%.0f'%($t1-$t0))") lines=$(wc -l < "$root/cmd-$X.log" | tr -d ' ')" | tee -a "$out/summary.txt"
  enc "$root/cmd-$X.log"
done
rm -f "$root/cmd.sh"
}

phase_verify() {
[[ "$pairs" == 0 ]] && return 0
echo "== trusted verifier (benchmark.sh; private seeds) at log2=10 and log2=$log2"
sides="A B"; [[ -f "$root/q/lite" && ! -f "$root/q/a.enc" && ! -d "$root/A/target/challenge-candidate/challenge/build" ]] && sides="B"
for X in $sides; do
  sizes="10"; [[ $X == B ]] && sizes="10 18"
  for l in $sizes; do
    runs=2; [[ $l == 18 ]] && runs=1
    ( cd "$root/$X" && BLAKE3_LOG2="$l" BLAKE3_THREADS=auto BLAKE3_WARMUP_RUNS=0 BLAKE3_RUNS=$runs \
        BENCHMARK_OUTPUT_DIR="$root/bench-$X" ./benchmark.sh ) > "$root/verify-$X-$l.log" 2>&1; rc=$?
    if [[ $rc != 0 ]]; then
      if [[ $private == 1 ]]; then enc "$root/verify-$X-$l.log"; else tail -30 "$root/verify-$X-$l.log"; fi
      why=$(tail -1 "$root/verify-$X-$l.log" | cut -c1-160 | tr -d '"')
      if grep -q "timed out" <<<"$why"; then
        echo "verify $X log2=$l TIMEOUT ($why; runner ${memmb}MB: under 12 GB the 2^18 worker swaps, so this is not a rejection)" | tee -a "$out/summary.txt"
        fail "harness timeout for $X at log2=$l (not a rejection)"
      fi
      echo "verify $X log2=$l REJECTED ($why)" | tee -a "$out/summary.txt"
      fail "trusted verifier rejected $X at log2=$l"
    fi
    echo "verify $X log2=$l OK (trusted verifier, private seed) recompiled=$(grep -c '^ *Compiling' "$root/verify-$X-$l.log")" | tee -a "$out/summary.txt"
  done
done
}

phase_ident() {
[[ "$pairs" == 0 ]] && return 0
echo "== same-seed proof bytes A vs B (log2 12, 16: 4 seeds each; log2 18: 1 seed, 4 on a 14 GB runner)"
ok=yes; ac="$root/acache"
for l in 12 16 18; do
  n=4; [[ $l == 18 ]] && n=1; [[ $l == 18 && $memmb -ge 12000 ]] && n=4
  ex="$ac/ident-$l-$((seed0 + l)).json"; exargs=()
  if [[ ! -f "$root/q/a.enc" ]]; then
    if [[ -f "$root/q/lite" && -f "$ex" ]]; then exargs=(--expect "$ex"); elif [[ -d "$ac" && ! -f "$ex" ]]; then exargs=(--save-expect "$ex"); fi
  fi
  python3 "$root/rig/pair.py" --a "$wa" --b "$wb" --pairs $n --log2 $l --threads "$threads" --seed0 $((seed0 + l)) \
    --no-aa --warm 0 --half ${exargs[@]+"${exargs[@]}"} --scratch "$root/ident-scratch" --out "$out/ident-$l.json" > "$root/ident-$l.log" 2>&1 || { tail -5 "$root/ident-$l.log"; fail "ident driver log2=$l"; }
  line=$(grep "^identical=" "$root/ident-$l.log")
  echo "ident log2=$l $line"
  [[ "$line" == identical=yes* ]] || ok=no
done
echo "identical=$ok (same-seed proof bytes A vs B at log2 12,16,18)" | tee -a "$out/summary.txt"
}

phase_pair() {
# The ranked 2^18 proof needs 8.2 GB: it is only timed when the job landed on a >= 12 GB runner (M2 Pro, 5 vCPU, 14 GB).
plog2="$log2"; pp="$pairs"; noaa=""
if (( big > 0 )); then
  if (( memmb >= 12000 )); then plog2=18; pp="$big"; noaa="--no-aa"; else pp=0; echo "no 2^18 timing: small runner (${memmb}MB)" | tee -a "$out/summary.txt"; fi
fi
(( pp < 8 )) && { echo "== summary"; cat "$out/summary.txt"; return 0; }
echo "== paired interleaved timing (log2=$plog2 threads=$threads env=${penv:-none})"
envargs=(); for kv in $penv; do envargs+=(--env "$kv"); done
python3 "$root/rig/pair.py" --a "$wa" --b "$wb" --name-a "$name_a" --name-b "$name_b" \
  --pairs "$pp" --log2 "$plog2" --threads "$threads" --seed0 "$seed0" --budget "$budget" $noaa \
  ${envargs[@]+"${envargs[@]}"} --scratch "$root/pair-scratch" --out "$out/pair.json" | tee "$root/pair.log"
rc=${PIPESTATUS[0]}
grep -E "^(pair|detail|env|ready) " "$root/pair.log" >> "$out/summary.txt"
[[ $rc == 0 ]] || fail "pair driver rc=$rc"
echo "== summary"; cat "$out/summary.txt"
}

if [[ "$phase" == prep && "$need" == big && $memmb -lt 12000 ]]; then
  echo "RIGSKIP small runner (${memmb}MB) but the request needs >= 12 GB" | tee -a "$out/summary.txt"; touch "$out/skip"; exit 0
fi
[[ -f "$out/skip" ]] && { echo "skipped (small runner)"; exit 0; }
case "$phase" in
  all) phase_prep; phase_build; phase_probe; phase_verify; phase_ident; phase_pair ;;
  *) "phase_$phase" ;;
esac
