# symbolic-memory

Prolog-first durable memory for LLM/agent clients.

The current implementation slice provides two native operations:

- `memory_remember` — durably preserve exact source text in an authorized session/project/global namespace and return a stable opaque memory ID.
- `memory_get` — retrieve one known memory by ID after re-checking read authority and namespace visibility.

The source text and symbolic interpretation are intentionally separate. This slice preserves the source losslessly and does **not** require an LLM or symbolic projection to succeed.

## Development

```sh
nix develop
swipl -q -s test/run_tests.pl
```

Or run the full flake check:

```sh
nix flake check
```

## MCP stdio server

```sh
SYMBOLIC_MEMORY_DB="$PWD/.symbolic-memory.db" \
SYMBOLIC_MEMORY_PRINCIPAL="local-agent" \
SYMBOLIC_MEMORY_PROJECT_REMOTE="https://github.com/lost-rob0t/symbolic-memory" \
nix run
```

Host-bound environment values establish caller context. The model-facing tool arguments do not grant themselves capabilities.

Default capabilities are:

```text
memory_read,memory_write_session,memory_write_project
```

Override them explicitly with `SYMBOLIC_MEMORY_CAPABILITIES`. Global write is separate and is not granted by default.

Useful host variables:

- `SYMBOLIC_MEMORY_DB`
- `SYMBOLIC_MEMORY_PRINCIPAL`
- `SYMBOLIC_MEMORY_SESSION_ID`
- `SYMBOLIC_MEMORY_PROJECT_REMOTE`
- `SYMBOLIC_MEMORY_SOURCE_CLASS`
- `SYMBOLIC_MEMORY_CAPABILITIES`

## MCP protocol

The stdio adapter supports current stateless MCP `2026-07-28` and retains legacy `2025-11-25` initialization compatibility.

A modern client can discover the server without creating a session:

```json
{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

For modern requests, carry protocol/client metadata on each request. For example, remember:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_remember","arguments":{"memory":"Use Prolog as the authority for this project."},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

Then get the returned stable ID:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_get","arguments":{"id":"mem_<opaque-id>"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

Unsupported modern protocol versions return JSON-RPC error `-32022` together with the requested and supported versions.

## Storage guarantees in this slice

The domain layer writes one Prolog snapshot through a backend-neutral storage adapter. A logical remember transaction contains project-namespace creation when required, the exact source record, the memory/version record, and its append-only audit event. The new snapshot is written to a temporary file in the same directory and renamed into place only after the complete term is flushed.

This bootstrap is intentionally a **single-process** durability design. It does not claim database-grade multi-process concurrency. The public memory API does not depend on this backend, so SQLite/PostgreSQL/etc. can replace it later without changing the tool contract.

## Deliberately deferred

This branch does not yet implement:

- full-corpus `memory_search`;
- symbolic-first `memory_recall`;
- natural-language forgetting;
- embeddings/vector retrieval;
- contradiction/supersession reasoning;
- generated-rule activation/self-optimization.

Those build on the remember/get durability and authority contract rather than bypassing it.
