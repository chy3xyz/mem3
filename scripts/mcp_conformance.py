#!/usr/bin/env python3
"""
mem3 MCP server — protocol conformance check.

Spawns a real `mem3 mcp` process, speaks JSON-RPC 2.0 at it over stdio, and
asserts the things the specification actually requires. It talks to the
binary, not to the source, so it catches wiring mistakes that an in-process
test cannot.

    python3 scripts/mcp_conformance.py [--mem3 <path-to-mem3>]

Exits non-zero if any check fails. No third-party packages: it needs a Python
3 and a built `mem3`, and nothing else — the same rule the project holds
itself to.

WHAT THIS IS NOT
----------------
It is not an interoperability test. Every message below was written by the
same person who wrote the server, so a shared misreading of the spec would
pass here and fail against a real client. What it does buy is the failure
mode that matters most in practice: a response that is malformed, truncated,
mis-shaped, or answered when it should not be. Those are checkable without a
second implementation, and they are what actually breaks a session.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

META_PREFIX = "io.modelcontextprotocol/"
MODERN = "2026-07-28"


def modern_meta(version=MODERN):
    """The `_meta` block a 2026-07-28 request is required to carry."""
    return {
        META_PREFIX + "protocolVersion": version,
        META_PREFIX + "clientCapabilities": {},
        META_PREFIX + "clientInfo": {"name": "conformance-probe", "version": "1"},
    }


class Server:
    """A live `mem3 mcp` process with line-delimited framing on both ends."""

    def __init__(self, binary, data_dir):
        self.proc = subprocess.Popen(
            [binary, "mcp", "--data-dir", data_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.lines = []
        self.batches = []
        self._lock = threading.Lock()
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        time.sleep(0.4)  # let the process come up before the first write

    def _pump(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                with self._lock:
                    self.lines.append({"__unparseable__": line})
                continue
            with self._lock:
                if isinstance(obj, list):
                    self.batches.append(obj)
                    for item in obj:
                        self.lines.append(item)
                else:
                    self.lines.append(obj)

    def send_raw(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def send(self, obj):
        self.send_raw(json.dumps(obj))

    def count(self):
        with self._lock:
            return len(self.lines)

    def wait_for(self, marker_id, timeout=3.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for item in self.all():
                if item.get("id") == marker_id:
                    return item
            time.sleep(0.05)
        return None

    def all(self):
        with self._lock:
            return list(self.lines)

    def batches_seen(self):
        with self._lock:
            return list(self.batches)

    def stderr_text(self):
        # Only safe after stdin is closed; see close().
        return self.proc.stderr.read()

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


class Checks:
    def __init__(self):
        self.results = []

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        mark = "PASS" if ok else "FAIL"
        line = "  %-4s %s" % (mark, name)
        if detail:
            line += "\n         %s" % detail
        print(line)
        return ok

    @property
    def failed(self):
        return [r for r in self.results if not r[1]]

    def summary(self):
        passed = sum(1 for r in self.results if r[1])
        total = len(self.results)
        print("\n%d/%d checks passed" % (passed, total))
        if passed == total:
            print("The server speaks both protocol eras correctly on this run.")
        else:
            print("Failed checks are the defect; pass ones are not evidence of the rest.")
        return passed == total


def run(binary):
    c = Checks()
    tmp = tempfile.mkdtemp(prefix="mem3-mcp-conformance.")
    s = Server(binary, os.path.join(tmp, "store"))

    try:
        # ------------------------------------------------------------------
        print("\n[1] server/discover — the method the spec says a server MUST implement")
        s.send({"jsonrpc": "2.0", "id": "d1", "method": "server/discover",
                "params": {"_meta": modern_meta()}})
        r = s.wait_for("d1")
        if not c.check("server/discover answers at all", r is not None):
            raise SystemExit(1)
        result = r.get("result")
        if not c.check("server/discover returns a result, not an error",
                       result is not None, json.dumps(r)[:200]):
            raise SystemExit(1)
        c.check("result declares resultType=complete",
                result.get("resultType") == "complete", "got %r" % result.get("resultType"))
        versions = result.get("supportedVersions", [])
        c.check("supportedVersions is a non-empty list",
                isinstance(versions, list) and len(versions) > 0, repr(versions))
        c.check("the modern revision is listed first",
                bool(versions) and versions[0] == MODERN, repr(versions[:2]))
        c.check("legacy revisions are listed too, so a modern client can downgrade",
                "2025-11-25" in versions and "2024-11-05" in versions, repr(versions))
        caps = result.get("capabilities", {})
        c.check("capabilities advertise tools",
                "tools" in caps, repr(caps))
        c.check("capabilities do NOT advertise unimplemented namespaces",
                "resources" not in caps and "prompts" not in caps, repr(caps))
        info = result.get("_meta", {}).get(META_PREFIX + "serverInfo")
        c.check("result._meta carries serverInfo",
                isinstance(info, dict) and info.get("name") == "mem3", repr(info))
        c.check("the id came back exactly as sent",
                r.get("id") == "d1", repr(r.get("id")))

        # ------------------------------------------------------------------
        print("\n[2] the stdio backward-compatibility probe")
        n = s.count()
        s.send({"jsonrpc": "2.0", "id": "probe-legacy", "method": "server/discover", "params": {}})
        r = s.wait_for("probe-legacy")
        err = (r or {}).get("error", {})
        # A legacy client sends this first and treats anything that is not a
        # *recognised modern error* as "legacy server, send initialize". -32022
        # means "I am modern, retry with a version I speak", so answering it
        # here would make an unmigrated client never fall back at all.
        c.check("server/discover without _meta is rejected with -32602",
                err.get("code") == -32602, repr(err))
        c.check("it is NOT -32022, which would strand a legacy client",
                err.get("code") != -32022, repr(err.get("code")))

        # ------------------------------------------------------------------
        print("\n[3] version negotiation")
        s.send({"jsonrpc": "2.0", "id": "old", "method": "tools/list",
                "params": {"_meta": modern_meta("1900-01-01")}})
        r = s.wait_for("old")
        err = (r or {}).get("error", {})
        c.check("an unknown version is -32022 UnsupportedProtocolVersion",
                err.get("code") == -32022, repr(err))
        data = err.get("data", {})
        c.check("the error lists versions the client can retry with",
                MODERN in data.get("supported", []), repr(data.get("supported")))
        c.check("the error echoes what was requested",
                data.get("requested") == "1900-01-01", repr(data.get("requested")))

        s.send({"jsonrpc": "2.0", "id": "nocaps", "method": "tools/list",
                "params": {"_meta": {META_PREFIX + "protocolVersion": MODERN}}})
        r = s.wait_for("nocaps")
        c.check("a modern request missing clientCapabilities is -32602",
                (r or {}).get("error", {}).get("code") == -32602, repr((r or {}).get("error")))

        # ------------------------------------------------------------------
        print("\n[4] the legacy handshake still works")
        s.send({"jsonrpc": "2.0", "id": 10, "method": "initialize",
                "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "old-client", "version": "1"}}})
        r = s.wait_for(10)
        res = (r or {}).get("result", {})
        c.check("initialize is answered", bool(res), json.dumps(r)[:160])
        c.check("it negotiates the version the client asked for",
                res.get("protocolVersion") == "2024-11-05", repr(res.get("protocolVersion")))
        c.check("it answers with a serverInfo",
                res.get("serverInfo", {}).get("name") == "mem3", repr(res.get("serverInfo")))
        c.check("it carries no resultType — the handshake era has none",
                "resultType" not in res, repr(res.get("resultType")))

        s.send({"jsonrpc": "2.0", "id": 11, "method": "initialize",
                "params": {"protocolVersion": "2099-01-01", "capabilities": {},
                           "clientInfo": {"name": "old-client", "version": "1"}}})
        r = s.wait_for(11)
        res = (r or {}).get("result", {})
        c.check("an unknown handshake version falls back to one we speak",
                res.get("protocolVersion") in ("2025-11-25", "2025-06-18",
                                               "2025-03-26", "2024-11-05"),
                repr(res.get("protocolVersion")))
        c.check("it never falls back to the modern revision, which has no handshake",
                res.get("protocolVersion") != MODERN, repr(res.get("protocolVersion")))

        # ------------------------------------------------------------------
        print("\n[5] one request, two eras")
        s.send({"jsonrpc": "2.0", "id": 20, "method": "tools/list", "params": {}})
        r = s.wait_for(20)
        legacy_res = (r or {}).get("result", {})
        c.check("a legacy tools/list returns tools", len(legacy_res.get("tools", [])) > 0)
        c.check("a legacy result carries no resultType", "resultType" not in legacy_res)
        c.check("a legacy result carries no serverInfo echo", META_PREFIX + "serverInfo" not in legacy_res.get("_meta", {}))

        s.send({"jsonrpc": "2.0", "id": 21, "method": "tools/list",
                "params": {"_meta": modern_meta()}})
        r = s.wait_for(21)
        modern_res = (r or {}).get("result", {})
        c.check("a modern tools/list returns tools", len(modern_res.get("tools", [])) > 0)
        c.check("a modern result declares resultType=complete",
                modern_res.get("resultType") == "complete")
        c.check("a modern result echoes serverInfo",
                isinstance(modern_res.get("_meta", {}).get(META_PREFIX + "serverInfo"), dict))
        c.check("both eras list the same tools",
                [t["name"] for t in legacy_res.get("tools", [])]
                == [t["name"] for t in modern_res.get("tools", [])])

        # ------------------------------------------------------------------
        print("\n[6] tool calls actually work, in both eras")
        s.send({"jsonrpc": "2.0", "id": 30, "method": "tools/call",
                "params": {"name": "memory_add",
                           "arguments": {"episode": "pour-over ratio is 1:16",
                                         "source": "matter", "goal_ids": [1]},
                           "_meta": modern_meta()}})
        r = s.wait_for(30)
        res = (r or {}).get("result", {})
        c.check("memory_add succeeds under the modern era",
                res.get("resultType") == "complete" and not res.get("isError"),
                json.dumps(r)[:200])

        s.send({"jsonrpc": "2.0", "id": 31, "method": "tools/call",
                "params": {"name": "memory_query",
                           "arguments": {"query": "pour-over", "topk": 3}}})
        r = s.wait_for(31)
        res = (r or {}).get("result", {})
        text = (res.get("content") or [{}])[0].get("text", "")
        try:
            payload = json.loads(text)
        except ValueError:
            payload = {}
        c.check("a legacy memory_query finds the cell written a moment ago",
                payload.get("count", 0) >= 1, text[:160])
        c.check("a legacy tool result still carries no resultType",
                "resultType" not in res, repr(res.get("resultType")))

        s.send({"jsonrpc": "2.0", "id": 32, "method": "tools/call",
                "params": {"name": "memory_stats", "arguments": {}, "_meta": modern_meta()}})
        r = s.wait_for(32)
        res = (r or {}).get("result", {})
        c.check("memory_stats answers under the modern era",
                res.get("resultType") == "complete", json.dumps(r)[:160])
        c.check("every modern result keeps its content block intact",
                isinstance(res.get("content"), list) and len(res["content"]) == 1,
                repr(res.get("content"))[:120])

        # ------------------------------------------------------------------
        print("\n[7] protocol errors use the codes clients branch on")
        for ident, request, want_code, why in [
            (40, {"jsonrpc": "2.0", "id": 40, "method": "tools/call",
                  "params": {"name": "no_such_tool", "arguments": {},
                             "_meta": modern_meta()}}, -32602, "unknown tool"),
            (41, {"jsonrpc": "2.0", "id": 41, "method": "no/such/method",
                  "params": {"_meta": modern_meta()}}, -32601, "unknown method"),
            (42, {"jsonrpc": "2.0", "id": 42, "method": "tools/call",
                  "params": {"name": 7, "_meta": modern_meta()}}, -32602, "non-string tool name"),
        ]:
            s.send(request)
            r = s.wait_for(ident)
            got = (r or {}).get("error", {}).get("code")
            c.check("%s is %d" % (why, want_code), got == want_code, "got %r" % got)

        before = s.count()
        s.send_raw('{"jsonrpc":"2.0", BROKEN')
        time.sleep(0.4)
        malformed = None
        for item in s.all()[before:]:
            if item.get("id") is None:
                malformed = item
        c.check("a truncated line is answered, not silently dropped",
                malformed is not None, "a client left waiting here hangs forever")
        c.check("it is answered with -32700",
                (malformed or {}).get("error", {}).get("code") == -32700,
                repr((malformed or {}).get("error")))

        n = s.count()
        s.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.4)
        c.check("a notification is never answered",
                s.count() == n, "%d unexpected response(s)" % (s.count() - n))

        # ------------------------------------------------------------------
        print("\n[8] JSON-RPC batching — MUST support receiving batches")
        before_batches = len(s.batches_seen())
        s.send([
            {"jsonrpc": "2.0", "id": 50, "method": "ping", "params": {"_meta": modern_meta()}},
            {"jsonrpc": "2.0", "id": 51, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 52, "method": "tools/list", "params": {"_meta": modern_meta()}},
        ])
        time.sleep(0.6)
        batches = s.batches_seen()[before_batches:]
        c.check("a batch is answered as an array", bool(batches),
                "an object answer would leave ids 50-52 unanswered as a set")
        if batches:
            arr = batches[0]
            c.check("every element gets exactly one response", len(arr) == 3, repr(len(arr)))
            ids = sorted(x.get("id") for x in arr)
            c.check("the ids all come back", ids == [50, 51, 52], repr(ids))
            by_id = {x.get("id"): x.get("result", {}) for x in arr}
            c.check("a legacy element inside a modern batch gets no resultType",
                    "resultType" not in by_id.get(51, {}), repr(by_id.get(51, {}).get("resultType")))
            c.check("a modern element inside a legacy batch does",
                    by_id.get(52, {}).get("resultType") == "complete")

        before_batches = len(s.batches_seen())
        n = s.count()
        s.send([
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "method": "notifications/cancelled"},
        ])
        time.sleep(0.4)
        c.check("a batch of only notifications produces no output at all",
                s.count() == n and len(s.batches_seen()) == before_batches,
                "an empty array would be a response to nothing")

        # Read the delta, not a fixed slice of the tail: an earlier check's
        # response can still be settling, and a fixed window either misses
        # this one or picks up a stale one.
        before_n = s.count()
        s.send([])
        time.sleep(0.5)
        empty = None
        for item in s.all()[before_n:]:
            if "error" in item:
                empty = item
        c.check("an empty batch is one error object, not an empty array",
                empty is not None and empty.get("error", {}).get("code") == -32600,
                repr(empty))
        c.check("an empty batch answer is a single object, so it is not a batch",
                isinstance(empty, dict), repr(type(empty).__name__))

        before_batches = len(s.batches_seen())
        s.send([
            {"jsonrpc": "2.0", "id": 60, "method": "ping", "params": {}},
            {"jsonrpc": "2.0", "id": 61},
            {"jsonrpc": "2.0", "id": 62, "method": "ping", "params": {}},
        ])
        time.sleep(0.6)
        batches = s.batches_seen()[before_batches:]
        if c.check("a batch with a bad element still answers as an array", bool(batches)):
            arr = batches[0]
            c.check("three in, three out — aborting would strand ids 60 and 62",
                    len(arr) == 3, repr(len(arr)))
            bad = [x for x in arr if x.get("id") == 61]
            c.check("the bad element is answered in place, keyed by its own id",
                    len(bad) == 1 and "error" in bad[0],
                    "ids seen: %r" % [x.get("id") for x in arr])
            c.check("its id is echoed, not nulled — a null id is only for an "
                    "id we could not read, and three bad elements would then "
                    "be indistinguishable",
                    bool(bad) and bad[0].get("id") == 61, repr(bad))

        # ------------------------------------------------------------------
        print("\n[9] framing and process hygiene")
        big = "x" * 200000
        s.send({"jsonrpc": "2.0", "id": 70, "method": "tools/call",
                "params": {"name": "memory_query",
                           "arguments": {"query": big},
                           "_meta": modern_meta()}})
        r = s.wait_for(70, timeout=5.0)
        c.check("a very large but legal request is answered, not refused",
                r is not None and ("result" in r or "error" in r), repr(r)[:140])

        s.close()
        c.check("stdout carried only protocol: stderr was empty",
                s.stderr_text().strip() == "", repr(s.stderr_text()[:120]))
        c.check("the process exits cleanly when stdin closes",
                s.proc.returncode == 0, "exit %r" % s.proc.returncode)
        c.check("no response was left unparseable",
                not any("__unparseable__" in x for x in s.all()))
    finally:
        if s.proc.poll() is None:
            s.close()

    return c.summary()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mem3", help="path to the mem3 binary (default: zig-out/bin/mem3)")
    args = ap.parse_args()

    binary = args.mem3 or os.path.join("zig-out", "bin", "mem3")
    if not os.path.isabs(binary):
        binary = os.path.abspath(os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), binary))
    if not os.path.exists(binary):
        print("No mem3 binary at %s\nBuild one first:  zig build -Doptimize=ReleaseFast" % binary)
        return 2

    print("Probing %s" % binary)
    print("Each check drives a live process over stdio; nothing is imported.")
    return 0 if run(binary) else 1


if __name__ == "__main__":
    sys.exit(main())
