# Security

mem3 is a local store. One person, one machine.

`mem3 serve` binds `127.0.0.1:7777` unless you pass `--bind` and `--port`. There is no authentication and no TLS. Anyone who can open the socket can read and write the store.

`mem3.wal` and `snapshot.bin` are plaintext. They hold the text you stored.

`mem3 mcp` has the same tools as the CLI, including forget.

Report a crash, a log replay that drops or invents a record, or a way to read another user's files through a [private advisory](https://github.com/chy3xyz/mem3/security/advisories/new). Include `mem3 version`, the commit, and the platform. Leave private text out of the transcript.

A missing login on the loopback default is the design above.
