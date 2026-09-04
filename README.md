# symbolic-memory

Prolog-first durable memory for LLM/agent clients.

The current implementation preserves exact natural-language source memory and can attach durable, structured symbolic projections to that source. Recall is symbolic-first: Prolog matches predicates and argument patterns, then the model receives concise Markdown-like statements instead of executable Prolog. Exact source prose is included only when a projection is marked lossy/context-dependent or the caller explicitly asks for it.

## Native operations

- `memory_remember` — durably preserve exact source text in an authorized session/project/global namespace and optionally attach structured symbolic projections.
- `memory_get` — retrieve one known memory by stable ID, including its projections, after re-checking read authority and namespace visibility.
- `memory_recall` — query authorized projections by predicate and argument pattern. JSON `null` is a wildcard.

The source text and symbolic interpretation remain separate. **Projection failure or rejection never discards the source memory.**

## Example

Remember exact source text plus compact symbolic projections:

```json
{
  "memory": "The user prefers Prolog for constraint solving and wants important work verified with Prolog.",
  "kind": "preference",
  "projections": [
    {
      "predicate": "prefers",
      "arguments": ["user", "prolog", "constraint_solving"],
      "statement": "User prefers Prolog for constraint solving.",
      "quality": "exact"
    },
    {
      "predicate": "preferred_verifier",
      "arguments": ["user", "prolog"],
      "statement": "The user's preferred verifier is Prolog.",
      "quality": "exact"
    }
  ]
}
```

Internally those projections are data, not arbitrary executable clauses. Recall performs symbolic matching without evaluating model-supplied Prolog:

```json
{
  "predicate": "prefers",
  "arguments": ["user", null, "constraint_solving"]
}
```

Conceptual model-facing result:

```text
# Recalled memory

- **preference · Current · user_explicit** — User prefers Prolog for constraint solving. [mem_<opaque-id>]
```

The trust label stays visible in the compiled recall packet. A symbolic statement therefore does not silently acquire user-level authority merely because it is compact.

If a projection is marked `lossy` or `context_required`, recall adds the exact stored source under `## Source context`. Callers can also request exact source expansion explicitly with `include_source: true`.

## Projection admission

Projection is derived state. Source capture is authoritative and independent of whether projection succeeds.

A remember result reports one of these projection states:

- `not_attempted` — no projection was supplied;
- `stored` — projection passed structural and trust admission and was persisted;
- `blocked_untrusted` — source was retained as evidence, but semantic projection was blocked because trust is `external_untrusted` or `unknown`;
- `projection_error` — malformed projection was rejected while the exact source memory still committed.

This implements a narrow default: **capture broadly, promote semantic memory conservatively**.

Projection arguments are canonicalized so native Prolog atoms and MCP JSON strings share one stored representation. JSON `null` is reserved for query wildcards and cannot be stored as a projection argument.

## Projection shape

A projection contains:

- a stable projection ID;
- its parent memory ID;
- a predicate name;
- canonical scalar arguments;
- a concise model-facing statement;
- quality: `exact`, `lossy`, or `context_required`;
- lifecycle state;
- creation time.

Predicate names and arguments are matched as structured data. They are not invoked as Prolog goals.

## Recall behavior

`memory_recall` applies deterministic admissibility before returning candidates:

1. caller must have `memory_read`;
2. the parent memory and projection must be active;
3. namespace visibility must hold;
4. symbolic predicate/argument matching is applied;
5. results rank session before project before global;
6. source prose is attached only when required or explicitly requested.

This slice does not claim full relevance ranking, temporal truth, contradiction handling, or natural-language retrieval yet.

## Scope and authority

Memory scope and lifetime remain independent dimensions.

Scopes:

- `session`
- `project`
- `global`

Retention classes currently map to short-term or long-term lifetime.

Host-bound environment values establish caller identity and capability. Model-facing tool arguments do not grant themselves authority.

Default MCP capabilities are:

```text
memory_read,memory_write_session,memory_write_project
```

Global write remains separate and is not granted by default.

Useful host variables:

- `SYMBOLIC_MEMORY_DB`
- `SYMBOLIC_MEMORY_PRINCIPAL`
- `SYMBOLIC_MEMORY_SESSION_ID`
- `SYMBOLIC_MEMORY_PROJECT_REMOTE`
- `SYMBOLIC_MEMORY_SOURCE_CLASS`
- `SYMBOLIC_MEMORY_CAPABILITIES`

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

The stdio adapter supports current stateless MCP `2026-07-28` and retains legacy `2025-11-25` initialization compatibility.

A modern client can discover the server without creating a session:

```json
{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

Modern `tools/call` requests carry the same protocol/client metadata in `params._meta`.

## Storage guarantees

The domain layer writes one Prolog snapshot through a backend-neutral storage adapter. A logical remember transaction contains project-namespace creation when required, the exact source record, the memory/version record, zero or more admitted symbolic projection records, and its append-only audit event. The new snapshot is written to a temporary file in the same directory and renamed into place only after the complete term is flushed.

Snapshot format v2 adds projections. Existing v1 snapshots are migrated in memory on load with an empty projection set and are persisted as v2 on the next successful transaction.

This remains intentionally a **single-process** durability design. It does not claim database-grade multi-process concurrency. The public memory API does not depend on this backend, so SQLite/PostgreSQL/etc. can replace it later without changing the tool contract.

## Deliberately deferred

This slice does **not** yet implement:

- automatic prose → symbolic extraction;
- full-corpus natural-language `memory_search`;
- natural-language `memory_recall` candidate generation;
- contradiction/supersession reasoning;
- temporal valid-time/system-time state;
- generated-rule activation/self-optimization;
- natural-language forgetting and dependency repair;
- embeddings/vector retrieval.

Those build on the durable source + projection + authority boundary rather than bypassing it.
