# Security

mem3 keeps a memory log on local disk and serves it over HTTP and stdio. It is a single-user tool on a machine you control.

## What the daemon does not do

- **No authentication and no TLS.** `mem3 serve` binds `127.0.0.1:7777` unless you pass `--bind` and `--port`. Anything that can open that socket can read and write the store.
- **The files are plaintext.** `mem3.wal` and `snapshot.bin` hold episode text, facts, and foresight. Disk encryption is the operating system's job.
- **MCP has no extra sandbox.** A host that can spawn `mem3 mcp` can call every tool, including forget and unsupersede.

Binding a non-loopback address, or putting the data directory on a shared disk, is an operator decision. The program will not refuse it.

## Reporting

Use a [private security advisory](https://github.com/chy3xyz/mem3/security/advisories/new) on `chy3xyz/mem3`. Include the version (`mem3 version`), the commit, the platform, and a transcript that does not contain data you care about.

A missing auth check on the loopback default is the design above, not a vulnerability report. A crash, a WAL replay that drops or invents a record, or a way to read another user's files without their credentials, is.
