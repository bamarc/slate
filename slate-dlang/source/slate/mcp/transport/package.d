/// MCP line-framed transports: blocking pump plus line endpoints.
///
/// Port of `slate_mcp::transport`. Adaptation: Rust multiplexes a writer
/// task, per-line spawn, and broadcast shutdown over tokio; the D port is a
/// single synchronous pump (`runLineTransport`) over minimal `LineReader` /
/// `LineWriter` seams — identical wire behavior (blank lines skipped,
/// newline-terminated responses, immediate flush, clean EOF) for sequential
/// clients, without an async runtime. `stdio.d` and `memory.d` provide the
/// two endpoints.
module slate.mcp.transport;

public import slate.mcp.transport.io;
public import slate.mcp.transport.stdio;
public import slate.mcp.transport.memory;
