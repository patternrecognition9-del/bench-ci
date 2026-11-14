#!/usr/bin/env python3
"""Paired, interleaved, same-seed timing of two benchmark workers.

Each trial mirrors the trusted harness: fresh sandboxed worker process, env cleared
except RAYON_NUM_THREADS/TMPDIR, untimed fixed-seed warm-up inside the worker, then the
seed goes to stdin and the clock runs until the published proof has been read back.

Blocks alternate between X (A vs B) and N (A vs A', a byte copy of A: the null).
Inside a block all four proofs use one seed, order ABBA / BAAB alternating, which
gives two adjacent pairs per block. delta% = (tA/tB - 1) * 100 (positive: B faster,
the same sign as a hosted score delta of B over A).
"""
import argparse, hashlib, json, os, random, select, shutil, statistics, subprocess, sys, time

MAX_PROOF_BYTES = 500000


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def auto_threads():
    v = sh(["sysctl", "-n", "hw.perflevel0.physicalcpu"])
    if not v.isdigit():
        v = sh(["getconf", "_NPROCESSORS_ONLN"])
    return int(v) if v.isdigit() else 1


class Runner:
    def __init__(self, scratch, log2, threads, sandbox, timeout, extra_env=None, stderr_dir=None):
        self.extra_env = dict(extra_env or {})
        self.stderr_dir, self.n = stderr_dir, 0
        if stderr_dir:
            os.makedirs(stderr_dir, exist_ok=True)
        self.scratch = os.path.realpath(scratch)
        self.log2 = str(log2)
        self.threads = str(threads)
        self.timeout = timeout
        self.profile = None
        os.makedirs(self.scratch, exist_ok=True)
        if sandbox and os.path.exists("/usr/bin/sandbox-exec"):
            self.profile = self.scratch + ".sb"
            with open(self.profile, "w") as f:
                f.write("\n".join([
                    "(version 1)", "(allow default)", "(deny network*)",
                    "(deny process-fork)", "(deny file-write*)",
                    '(allow file-write* (subpath "%s"))' % self.scratch, ""]))

    def trial(self, worker, seed):
        sc = self.scratch
        shutil.rmtree(sc, ignore_errors=True)
        os.makedirs(sc)
        ready = os.path.join(sc, "run.ready")
        proof = os.path.join(sc, "run.proof")
        argv = [worker, self.log2, ready, proof]
        if self.profile:
            argv = ["/usr/bin/sandbox-exec", "-f", self.profile] + argv
        env = {"RAYON_NUM_THREADS": self.threads, "TMPDIR": sc}
        env.update(self.extra_env)
        self.n += 1
        err = open(os.path.join(self.stderr_dir, "trial-%04d.err" % self.n), "wb") if self.stderr_dir else subprocess.DEVNULL
        t_spawn = time.perf_counter()
        p = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=err)
        dfd = os.open(sc, os.O_RDONLY)
        kq = select.kqueue()
        ev = select.kevent(dfd, filter=select.KQ_FILTER_VNODE,
                           flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                           fflags=select.KQ_NOTE_WRITE)
        kq.control([ev], 0, 0)
        try:
            deadline = t_spawn + self.timeout
            while not os.path.isfile(ready):
                if p.poll() is not None:
                    raise RuntimeError("worker exited before readiness rc=%s" % p.returncode)
                if time.perf_counter() > deadline:
                    raise RuntimeError("ready timeout")
                kq.control(None, 4, 0.002)
            t0 = time.perf_counter()
            p.stdin.write(("%d\n" % seed).encode())
            p.stdin.flush()
            data = None
            deadline = t0 + self.timeout
            while True:
                try:
                    with open(proof, "rb") as f:
                        data = f.read(MAX_PROOF_BYTES + 1)
                    break
                except FileNotFoundError:
                    pass
                if p.poll() is not None:
                    if os.path.isfile(proof):
                        continue
                    raise RuntimeError("worker exited before proof rc=%s" % p.returncode)
                if time.perf_counter() > deadline:
                    raise RuntimeError("proof timeout")
                kq.control(None, 4, 0.001)
            t1 = time.perf_counter()
        finally:
            try:
                p.kill()
            except Exception:
                pass
            try:
                _, _, ru = os.wait4(p.pid, 0)
                rss = ru.ru_maxrss
            except Exception:
                rss = 0
            p.returncode = p.returncode if p.returncode is not None else -9
            kq.close()
            os.close(dfd)
        if not (0 < len(data) <= MAX_PROOF_BYTES):
            raise RuntimeError("proof size %d out of range" % len(data))
        return {"secs": t1 - t0, "ready": t0 - t_spawn, "rss": rss,
                "sha": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def iqr(xs):
    if len(xs) < 4:
        return float("nan")
    q = statistics.quantiles(xs, n=4, method="inclusive")
    return q[2] - q[0]


def boot_ci(xs, fn=med, n=2000, seed=7):
    if len(xs) < 4:
        return (float("nan"), float("nan"))
    r = random.Random(seed)
    k = len(xs)
    vals = sorted(fn([xs[r.randrange(k)] for _ in range(k)]) for _ in range(n))
    return (vals[int(0.025 * n)], vals[int(0.975 * n)])


def summarize(blocks, kind):
    """Return paired deltas (%) for blocks of a kind, plus block-level and pooled views."""
    pair, block, ta, tb = [], [], [], []
    for b in blocks:
        if b["kind"] != kind:
            continue
        t = b["t"]  # list of (label, secs) in run order, labels P (ref) / Q (other)
        for i in range(0, len(t) - 1, 2):
            (l0, s0), (l1, s1) = t[i], t[i + 1]
            p, q = (s0, s1) if l0 == "P" else (s1, s0)
            pair.append((p / q - 1.0) * 100.0)
        ps = [s for l, s in t if l == "P"]
        qs = [s for l, s in t if l == "Q"]
        if ps and qs:
            block.append((sum(ps) / sum(qs) - 1.0) * 100.0)
        ta += ps
        tb += qs
    return pair, block, ta, tb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--name-a", default="A")
    ap.add_argument("--name-b", default="B")
    ap.add_argument("--pairs", type=int, default=60)
    ap.add_argument("--log2", type=int, default=18)
    ap.add_argument("--threads", default="auto")
    ap.add_argument("--scratch", default=os.path.join(os.getcwd(), "pair-scratch"))
    ap.add_argument("--out", default="pair.json")
    ap.add_argument("--seed0", type=int, default=20261114)
    ap.add_argument("--no-sandbox", action="store_true")
    ap.add_argument("--no-aa", action="store_true")
    ap.add_argument("--warm", type=int, default=2, help="discarded trials per binary first")
    ap.add_argument("--budget", type=float, default=0, help="stop adding blocks after N seconds")
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--stderr-dir", help="keep each worker's stderr here (the harness discards it)")
    ap.add_argument("--expect", help="json {seed: sha} of A's proofs: run B only and compare")
    ap.add_argument("--save-expect", help="write A's {seed: sha} here")
    ap.add_argument("--half", action="store_true", help="identity mode: one A and one B proof per seed")
    ap.add_argument("--env", action="append", default=[], help="K=V passed to both workers (the harness passes none)")
    a = ap.parse_args()

    threads = auto_threads() if a.threads == "auto" else int(a.threads)
    wa, wb = os.path.realpath(a.a), os.path.realpath(a.b)
    # The copy keeps the real file name: trees key their ranked path on argv[0] ("flock-benchmark-worker" + 3 args).
    cdir = os.path.join(os.path.dirname(os.path.realpath(a.out)) or ".", "Acopy")
    os.makedirs(cdir, exist_ok=True)
    wa2 = os.path.join(cdir, os.path.basename(wa))
    shutil.copy2(wa, wa2)
    extra = dict(kv.split("=", 1) for kv in a.env if "=" in kv)
    run = Runner(a.scratch, a.log2, threads, not a.no_sandbox, a.timeout, extra, a.stderr_dir)
    rng = random.Random(a.seed0)
    t_start = time.time()

    for w in (wa, wb) * a.warm:
        r = run.trial(w, rng.getrandbits(63))
        print("warm %s secs=%.4f ready=%.2f rss=%.0fMB" % (
            "A" if w == wa else "B", r["secs"], r["ready"], r["rss"] / 1e6), flush=True)

    n_blocks = a.pairs if a.half else (a.pairs + 1) // 2
    expect = json.load(open(a.expect)) if a.expect else None
    saved = {}
    blocks, ident, rss_a, rss_b, sizes = [], True, 0, 0, set()
    done_pairs = 0
    for k in range(n_blocks):
        if a.budget and time.time() - t_start > a.budget and k >= 2:
            print("budget reached after %d blocks" % k, flush=True)
            break
        seed = rng.getrandbits(63)
        for kind in (("X",) if a.no_aa else ("X", "N")):
            other = wb if kind == "X" else wa2
            order = "PQQP" if k % 2 == 0 else "QPPQ"
            if a.half:
                order = "PQ" if k % 2 == 0 else "QP"
            if expect is not None and kind == "X" and str(seed) in expect:
                order = "Q"
            t, shas, rd = [], {}, []
            for lab in order:
                r = run.trial(wa if lab == "P" else other, seed)
                t.append((lab, r["secs"]))
                rd.append((lab, r["ready"]))
                shas.setdefault(lab, set()).add(r["sha"])
                if kind == "X":
                    sizes.add(r["bytes"])
                    if lab == "P":
                        rss_a = max(rss_a, r["rss"])
                    else:
                        rss_b = max(rss_b, r["rss"])
            if order == "Q":
                shas["P"] = {expect[str(seed)]}
            elif kind == "X" and len(shas.get("P", ())) == 1:
                saved[str(seed)] = next(iter(shas["P"]))
            same = len(shas["P"] | shas["Q"]) == 1
            if kind == "X" and not same:
                ident = False
            blocks.append({"kind": kind, "seed": seed, "order": order, "t": t, "same": same, "ready": rd})
            print("blk %3d %s %s %s same=%s" % (
                k, kind, order, " ".join("%.4f" % s for _, s in t), same), flush=True)
        done_pairs += 2

    if a.save_expect and saved:
        with open(a.save_expect, "w") as f:
            json.dump(saved, f)
    px, bx, ta, tb = summarize(blocks, "X")
    pn, bn, na, nb = summarize(blocks, "N")
    lo, hi = boot_ci(px)
    res = {
        "a": a.name_a, "b": a.name_b, "log2": a.log2, "threads": threads,
        "pairs": len(px), "delta": med(px), "spread": iqr(px), "ci95": [lo, hi],
        "aa": med(pn), "aa_spread": iqr(pn), "aa_ci95": list(boot_ci(pn)),
        "block_delta": med(bx), "block_aa": med(bn),
        "mean_delta": statistics.fmean(px) if px else None,
        "pooled_median_delta": (med(ta) / med(tb) - 1) * 100 if (ta and tb) else None,
        "pooled_min_delta": (min(ta) / min(tb) - 1) * 100 if (ta and tb) else None,
        "pooled_p25_delta": ((statistics.quantiles(ta, n=4)[0] / statistics.quantiles(tb, n=4)[0] - 1) * 100
                             if (len(ta) >= 4 and len(tb) >= 4) else None),
        "median_secs_a": med(ta), "median_secs_b": med(tb),
        "identical": ident, "proof_bytes": sorted(sizes),
        "peak_rss_a": rss_a, "peak_rss_b": rss_b,
        "wall": time.time() - t_start, "blocks": blocks,
    }
    for k, v in list(res.items()):
        if v is None:
            res[k] = float("nan")
    with open(a.out, "w") as f:
        json.dump(res, f)
    print("pair A=%s B=%s delta=%+.3f%% spread=%.3f%% n=%d aa=%+.3f%%" % (
        a.name_a, a.name_b, res["delta"], res["spread"], res["pairs"], res["aa"]))
    print("identical=%s (same-seed proof bytes A vs B, %d seeds%s) proof_bytes=%s" % (
        "yes" if ident else "no", sum(1 for b in blocks if b["kind"] == "X"),
        ", A from the cached record hashes" if expect is not None else "", sorted(sizes)))
    print("detail ci95=[%+.3f,%+.3f] aa_ci95=[%+.3f,%+.3f] aa_spread=%.3f%% block_delta=%+.3f%% "
          "pooled_median=%+.3f%% pooled_p25=%+.3f%% pooled_min=%+.3f%% mean=%+.3f%%" % (
              lo, hi, res["aa_ci95"][0], res["aa_ci95"][1], res["aa_spread"], res["block_delta"],
              res["pooled_median_delta"], res["pooled_p25_delta"], res["pooled_min_delta"],
              res["mean_delta"]))
    ra = [x for b in blocks for l, x in b["ready"] if l == "P"]
    rb = [x for b in blocks if b["kind"] == "X" for l, x in b["ready"] if l == "Q"]
    res["ready_a"], res["ready_b"] = med(ra), med(rb)
    with open(a.out, "w") as f:
        json.dump(res, f)
    print("ready (untimed worker start + warm-up proof, median secs) A=%.2f B=%.2f" % (med(ra), med(rb)))
    print("env log2=%d threads=%d extra=%s median_secs A=%.4f B=%.4f peak_rss A=%.0fMB B=%.0fMB wall=%.0fs" % (
        a.log2, threads, ",".join(a.env) or "-", res["median_secs_a"], res["median_secs_b"],
        rss_a / 1e6, rss_b / 1e6, res["wall"]))


if __name__ == "__main__":
    main()
