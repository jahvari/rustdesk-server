# Issue 186: Windows idle CPU investigation

This branch contains diagnostic tooling, not a claimed fix for
https://github.com/rustdesk/rustdesk-server/issues/186.

The workflow compares the original upstream base with the combined audit fixes
on separate disposable Windows Server 2022 runners. Both are built with the same
current stable Rust toolchain and sampled for twelve minutes with the foreground
server, self-test enabled, normal process priority and information-level logging.
The sampler binds loopback and uses fresh server keys and database files.

Measurements include process CPU, per-thread CPU and priority, working set,
Windows version, binary hash, source commits and compiler version. A continuous
thirty seconds at 80% of one logical processor flags sustained CPU usage; a short
startup burst alone does not. Artifacts contain only measurements and logs, not
the generated private keys or test database.

The shared library's existing update checker can access the runner account's
separate RustDesk client configuration through Windows known folders. This is
why each test uses a disposable runner. APPDATA overrides alone do not guarantee
profile isolation. No runtime priority changes or CPU-throttling patches are used.

An unsuccessful reproduction on these current builds does not establish that
the older report is resolved. Server 2019/2016 and historical release builds
remain unverified. A positive reproduction needs a busy-thread stack before
selecting a minimal code fix.
