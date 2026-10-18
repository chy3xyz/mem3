#!/usr/bin/env python3
"""Reference mem3 external embedder adapter: ONNX sentence encoder -> line protocol.

WHAT mem3 SPEAKS
----------------
`--embedder-cmd` starts this program once and keeps it alive for the whole
run. The protocol is one request per line, one response per line:

    mem3 -> program : <hex-encoded UTF-8 text> + "\\n"
    program -> mem3 : <dim space-separated f32 floats> + "\\n"

Two details that are easy to get wrong, and that the store enforces
strictly (`src/retrieval/embedder.zig`):

  * The request is HEX ENCODED, not raw text. `buildRequest` writes two hex
    digits per byte. Reading the line as literal text embeds the hex.
  * The response must contain EXACTLY `--embed-dim` finite floats. One
    token too many is `MalformedResponse`; too few is
    `EmbeddingDimensionMismatch`. mem3 re-normalises to L2 for you, so the
    model output does not need to be normalised here.
  * mem3 ignores SIGPIPE and sends the child's stderr to /dev/null, so
    this program must never write to stdout except the vector lines.
    Diagnostics belong on stderr, or nowhere.

WIDTH IS CHECKED AT STARTUP. mem3 probes the backend with the string
"mem3 embedder probe" inside `Store.init`, before a single cell is
indexed. A wrong `--embed-dim` therefore fails the whole run at startup
with `EmbeddingDimensionMismatch`, not midway through a query.

POINTING THIS AT YOUR OWN MODEL
-------------------------------
    mem3 serve --embedder-cmd=python3 \
               --embedder-arg=scripts/embedder_adapter_example.py \
               --embedder-arg=--model \
               --embedder-arg=/path/to/model.onnx \
               --embed-dim=384

Arguments are passed verbatim with no shell, so give one `--embedder-arg`
per argv entry and do your own quoting. To use Ollama or llama.cpp instead
of a local ONNX file, keep this loop and replace only `encode()`, which
already has an HTTP implementation below (`--backend=ollama`). The rest of
the file is transport and is the part you keep.

DEPENDENCIES (none are mem3's; mem3 stays zero-dependency)
    python3 -m pip install numpy onnxruntime tokenizers
"""

import argparse
import binascii
import json
import sys
import urllib.error
import urllib.request

# --- the model -------------------------------------------------------------


class OnnxEncoder:
    """Mean-pooled, L2-normalised sentence encoder (all-MiniLM-L6-v2 shape)."""

    def __init__(self, model_path, max_length=256):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.np = np
        self.tokenizer = Tokenizer.from_file(model_path + "/tokenizer.json")
        self.tokenizer.enable_truncation(max_length=max_length)
        # Mean pooling over the attention mask is what sentence-transformers
        # does for this checkpoint family. A CLS-pooled model wants
        # `vecs[:, 0]` instead — that is a one-line change, and it is the
        # only place this file knows anything about model architecture.
        self.pooling = "mean"
        opts = ort.SessionOptions()
        # The backend is single-threaded and long-lived; extra intra-op
        # threads only add contention with mem3's own query loop.
        opts.intra_op_num_threads = 1
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(
            model_path + "/model.onnx", sess_options=opts,
            providers=["CPUExecutionProvider"],
        )
        # The batch and sequence axes are dynamic on this export, so the
        # width is read off the output tensor's hidden axis, not an input.
        hidden = self.session.get_outputs()[0].shape[-1]
        if not isinstance(hidden, int):
            raise ValueError(
                "cannot determine model width from output shape %r; "
                "pass --dim explicitly" % (self.session.get_outputs()[0].shape,)
            )
        self.dim = hidden

    def encode(self, text):
        np = self.np
        enc = self.tokenizer.encode(text)
        ids = [enc.ids]
        mask = [enc.attention_mask]
        feed = {
            "input_ids": np.array(ids, dtype=np.int64),
            "attention_mask": np.array(mask, dtype=np.int64),
        }
        names = {i.name for i in self.session.get_inputs()}
        if "token_type_ids" in names:
            feed["token_type_ids"] = np.zeros_like(feed["input_ids"])
        # last_hidden_state -> (batch, seq, hidden)
        hidden = self.session.run(None, feed)[0][0]
        if self.pooling == "cls":
            vec = hidden[0]
        else:
            m = np.array(enc.attention_mask, dtype=np.float32)[:, None]
            vec = (hidden * m).sum(axis=0) / np.clip(m.sum(), 1e-9, None)
        norm = float((vec * vec).sum()) ** 0.5
        if norm <= 0.0:
            raise ValueError("model produced a degenerate (zero) vector")
        return vec / norm


class OllamaEncoder:
    """Same contract, HTTP transport. Useful to prove the loop is transport-only."""

    def __init__(self, url, model):
        self.url = url
        self.model = model
        self.dim = None

    def encode(self, text):
        body = json.dumps({"model": self.model, "prompt": text}).encode()
        req = urllib.request.Request(
            self.url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            vec = json.load(resp)["embedding"]
        if self.dim is None:
            self.dim = len(vec)
        elif len(vec) != self.dim:
            raise ValueError("width changed mid-run: %d != %d" % (len(vec), self.dim))
        return vec


# --- transport -------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=("onnx", "ollama"), default="onnx")
    ap.add_argument("--model", required=True,
                    help="onnx: directory holding model.onnx + tokenizer.json; "
                         "ollama: model name")
    ap.add_argument("--url", default="http://127.0.0.1:11434/api/embeddings")
    ap.add_argument("--max-length", type=int, default=256)
    ap.add_argument("--dim", type=int, default=None,
                    help="assert the width; must equal what mem3 was given "
                         "as --embed-dim")
    args = ap.parse_args()

    enc = (OnnxEncoder(args.model, args.max_length) if args.backend == "onnx"
           else OllamaEncoder(args.url, args.model))

    if args.dim is not None and enc.dim is not None and args.dim != enc.dim:
        sys.stderr.write("model width %d != requested %d\n" % (enc.dim, args.dim))
        return 2

    # One line out per line in, in order, flushed immediately: mem3 blocks
    # on the read, so buffering the response deadlocks the whole run.
    for line in sys.stdin.buffer:
        line = line.strip()
        if not line:
            continue
        try:
            text = binascii.unhexlify(line).decode("utf-8", "replace")
        except (binascii.Error, ValueError) as exc:
            sys.stderr.write("not hex: %s\n" % exc)
            continue
        vec = enc.encode(text)
        sys.stdout.write(" ".join("%.6f" % v for v in vec) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
