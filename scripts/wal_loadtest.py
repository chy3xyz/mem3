#!/usr/bin/env python3
"""Concurrent HTTP write load against a real `mem3 serve`, A/B interleaved.

Why this exists: `mem3-bench throughput` is single-threaded, and group commit
only has something to amortise when several writers wait at once. This drives
the real daemon over real sockets with N client threads.

    scripts/wal_loadtest.py --variant base=/tmp/mem3_wal_base/zig-out/bin/mem3 \
        --variant always=zig-out/bin/mem3 \
        --variant group=zig-out/bin/mem3:--wal-sync=group \
        --rounds 3 --threads 16 --writes 2400 --window 200

A variant is NAME=BINARY[:EXTRA_ARG...]. Rounds interleave the variants
(base, always, group, base, always, group, ...) because the host is noisy and
a back-to-back run per variant would measure the load average, not the code.
Per run it reports the overall rate and the *worst window*: the slowest
`--window` consecutive acknowledgements, ordered by completion time. That is
the same statistic `mem3-bench throughput` judges `met_target` on. Every run
also counts acknowledged-but-unreadable ids after a clean restart, so a
speedup that costs durability shows up as a nonzero `lost`.
"""
import argparse, http.client, json, os, shutil, signal, socket, statistics, subprocess, sys, tempfile, threading, time


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_up(port, proc, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            raise RuntimeError("daemon exited early")
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/healthz")
            if c.getresponse().status == 200:
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("daemon did not come up")


def start(binary, extra, port, data_dir):
    p = subprocess.Popen([binary, "serve", "--bind", "127.0.0.1", "--port", str(port),
                          "--data-dir", data_dir, "--maint-interval", "0", "--forget-interval", "0"] + extra,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_up(port, p)
    return p


def post(port, i, tag):
    # One sendall for head+body: the daemon parses a request from a single
    # read(2), and http.client sends head and body as two writes, which the
    # server answers with 400 whenever they do not coalesce. That is a
    # pre-existing daemon limitation (measured here, same on the base build);
    # the client works around it rather than the benchmark measuring it.
    body = json.dumps({"source": "matter", "episode": f"loadtest {tag} cell {i} the quick brown fox",
                       "facts": "", "goalId": 1, "relevance": 0.5}).encode()
    req = (b"POST /api/memcells HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
           b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)) + body
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    try:
        s.sendall(req)
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        s.close()
    head, _, data = buf.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1])
    if status != 201:
        raise RuntimeError(f"status {status}")
    return json.loads(data)["id"]


def run_once(binary, extra, threads, writes, window, tag):
    data_dir = tempfile.mkdtemp(prefix=f"mem3_wlt_{os.getpid()}_")
    port = free_port()
    proc = start(binary, extra, port, data_dir)
    stamps, ids, errors, lock = [], [], [0], threading.Lock()
    counter = [0]
    kinds = {}

    def worker():
        while True:
            with lock:
                i = counter[0]
                if i >= writes:
                    return
                counter[0] += 1
            try:
                id_ = post(port, i, tag)
            except Exception as e:
                with lock:
                    errors[0] += 1
                    kinds[type(e).__name__ + ":" + str(e)[:40]] = kinds.get(type(e).__name__ + ":" + str(e)[:40], 0) + 1
                continue
            t = time.perf_counter()
            with lock:
                stamps.append(t)
                ids.append(id_)

    t0 = time.perf_counter()
    ts = [threading.Thread(target=worker) for _ in range(threads)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    wall = time.perf_counter() - t0
    stamps.sort()
    worst = None
    if len(stamps) > window:
        rates = []
        for k in range(0, len(stamps) - window, window):
            dt = stamps[k + window] - stamps[k]
            rates.append(window / dt if dt > 0 else float("inf"))
        worst = min(rates)
    # clean stop, restart the *same* build without the flag, count lost ids
    proc.send_signal(signal.SIGTERM)
    code = proc.wait(timeout=30)
    port2 = free_port()
    proc2 = start(binary, [], port2, data_dir)
    lost = 0
    for id_ in ids:
        c = http.client.HTTPConnection("127.0.0.1", port2, timeout=10)
        c.request("GET", f"/api/memcells/{id_}")
        if c.getresponse().status != 200:
            lost += 1
        c.close()
    proc2.send_signal(signal.SIGTERM)
    proc2.wait(timeout=30)
    shutil.rmtree(data_dir, ignore_errors=True)
    return {"acked": len(ids), "errors": errors[0], "wall_s": round(wall, 3),
            "overall_rate": round(len(ids) / wall, 1),
            "worst_window_rate": round(worst, 1) if worst else None,
            "lost": lost, "exit_code": code, "error_kinds": kinds}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", action="append", required=True)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--writes", type=int, default=2400)
    ap.add_argument("--window", type=int, default=200)
    a = ap.parse_args()
    variants = []
    for v in a.variant:
        name, rest = v.split("=", 1)
        parts = rest.split(":")
        # NAME=BIN[:ARG...]; interval specs contain a colon, so re-join "--wal-sync=interval" "N"
        binary, extra = parts[0], []
        for p in parts[1:]:
            if extra and extra[-1].endswith("=interval"):
                extra[-1] += ":" + p
            else:
                extra.append(p)
        variants.append((name, binary, extra))
    results = {n: [] for n, _, _ in variants}
    for r in range(a.rounds):
        for name, binary, extra in variants:
            res = run_once(binary, extra, a.threads, a.writes, a.window, f"{name}{r}")
            res["round"] = r + 1
            results[name].append(res)
            print(json.dumps({"variant": name, **res}), flush=True)
    print("\n%-10s %12s %14s %14s %6s" % ("variant", "median/s", "worst-win med", "worst-win min", "lost"))
    for name, runs in results.items():
        ov = [x["overall_rate"] for x in runs]
        ww = [x["worst_window_rate"] for x in runs if x["worst_window_rate"]]
        print("%-10s %12.1f %14.1f %14.1f %6d" % (name, statistics.median(ov), statistics.median(ww),
                                                 min(ww), sum(x["lost"] for x in runs)))


if __name__ == "__main__":
    main()
