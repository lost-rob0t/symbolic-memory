# symbolic-memory

Prolog-first durable memory for LLM/agent clients.

Preserve exact source text, attach inert caller-supplied symbolic projections, and
recall authorized current projections without running model-generated Prolog.
Lossy/context-dependent projections retain exact source context in recall.

**This branch is draft and has not passed executable Prolog verification.** It implements
MACHINE SPIRIT's projection-lifecycle foundation, not its full semantic compiler,
reasoning system, or learning machinery. See [implementation status](IMPLEMENTATION-STATUS.md)
and [the lifecycle guide](docs/MACHINE-SPIRIT-LIFECYCLE.org).

## Native and MCP operations

| Operation | Purpose |
|---|---|
| `memory_remember` | Commit exact source text, optionally followed by a separate projection attempt. |
| `memory_get` | Read a known source and its current projections after namespace/authority checks. |
| `memory_recall` | Match current predicates and positional arguments; JSON `null` is a wildcard. |
| `memory_project` | Admit a caller-supplied projection set for an already-durable source. |
| `memory_projection_status` | Inspect the latest attempt separately from the current usable set. |
| `memory_projection_history` | Page immutable attempt records and prior projection contents. |
| `memory_projection_withdraw` | Withdraw a current set without deleting source or inventing negation. |

The library exports `memory_open/1`, `memory_close/0`, `memory_remember/4`,
`memory_get/3`, `memory_recall/4`, `memory_project/4`, `memory_projection_status/3`,
`memory_projection_history/4`, and `memory_projection_withdraw/4`.

## Example

Arguments to `memory_remember`:

```json
{
  "memory": "The user prefers Prolog for constraint solving.",
  "kind": "preference",
  "projections": [{
    "predicate": "prefers",
    "arguments": ["user", "prolog", "constraint_solving"],
    "statement": "User prefers Prolog for constraint solving.",
    "quality": "exact"
  }]
}
```

Arguments to `memory_recall`:

```json
{"predicate":"prefers","arguments":["user",null,"constraint_solving"],"limit":20}
```

Predicates and arguments are data, never executable clauses. Native atoms and JSON
strings normalize to the same representation. Null is reserved for query wildcards.
Recall returns structured records plus readable statements, showing **source trust
and interpretation trust separately**. `lossy` or `context_required` projections include
exact source text; `include_source: true` explicitly expands exact projections too.

For an already remembered source, use `memory_project` with its `id` and `projections`.
Optional `request_id` provides idempotency and `expected_generation` rejects stale
writes. A successful generation replaces the whole projection set for that memory;
old contents remain available through history. Retrying an old request cannot reactivate
it after replacement or withdrawal. Intentional republication needs a new request ID.

## Source and projection lifecycles

**A projection failure cannot roll back an already committed source.**

The convenience remember result preserves `projection_status` values `not_attempted`,
`stored`, `blocked_untrusted`, and `projection_error`. A persisted projection attempt
has its own generation and `ready`, `failed`, `blocked_untrusted`, or `withdrawn` status.
A failed attempt can coexist with an earlier usable current generation. Failure to
persist the attempt is reported as `projection_attempt_durable: false`.

Source trust and interpretation trust are independently checked against a closed
host policy. `external_untrusted`, `unknown`, and unrecognized trust labels remain
evidence-only. Remembered information never grants host capabilities. A compiler
fingerprint is caller-reported provenance, not proof of a compiler execution.

This local typed path reports `model_calls: 0`; that does not count any external
model usage that produced the submitted interpretation.

## Recall, bounds, and namespaces

Recall requires `memory_read`, visible namespace, active parent memory, and a current
projection. Matches are enumerated session → project → global. Recall and history
limits are 1–200 records/events, default 20, with explicit `truncated`/`has_more` flags.
History pages use `after_generation` and return `next_after_generation`.

These are count bounds, not byte or execution-time budgets. Exact source expansion can
be large, and the bootstrap backend loads the complete store into memory. General
relevance ranking, temporal truth, contradiction handling, and natural-language
retrieval are not implemented.

Scope (`session`, `project`, `global`) and retention (short/long-term) remain independent.
Host configuration establishes identity and capabilities; model-facing arguments cannot
grant authority. Source writes need the appropriate write capability. Projection of an
existing source additionally requires read permission.

Default MCP capabilities:

```text
memory_read,memory_write_session,memory_write_project
```

Global write is not granted by default. Host variables are `SYMBOLIC_MEMORY_DB`,
`SYMBOLIC_MEMORY_PRINCIPAL`, `SYMBOLIC_MEMORY_SESSION_ID`,
`SYMBOLIC_MEMORY_PROJECT_REMOTE`, `SYMBOLIC_MEMORY_SOURCE_CLASS`, and
`SYMBOLIC_MEMORY_CAPABILITIES`.

## Development

```sh
nix flake check
```

Or run both suites inside `nix develop`:

```sh
swipl -q -s test/run_tests.pl
python3 test/test_machine_spirit_stdio.py
```

The test runner treats consult errors as failures. The subprocess test checks the
actual MCP server across four restarts, not a mocked transport. Missing SWI-Prolog
is an error, never a skipped-green result.

## MCP stdio server

```sh
SYMBOLIC_MEMORY_DB="$PWD/.symbolic-memory.db" \
SYMBOLIC_MEMORY_PRINCIPAL="local-agent" \
SYMBOLIC_MEMORY_PROJECT_REMOTE="https://github.com/lost-rob0t/symbolic-memory" \
nix run
```

The adapter preserves its existing stateless MCP `2026-07-28` and legacy
`2025-11-25` initialization paths. A stateless discovery request:

```json
{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

Stateless tool requests carry the same metadata in `params._meta`. Standard legacy
clients initialize before calling the tools. Normal stdin EOF exits the process.

## Storage boundaries

The exact source/memory/audit transaction and projection transaction are independent.
Snapshot v3 preserves immutable projection rows and lifecycle events. Existing v1/v2
snapshots migrate on load and persist as v3 on a subsequent successful transaction.
Legacy compiler provenance remains unknown rather than being invented.

Writes serialize in one process, flush a complete temporary snapshot, and rename it
into place. This is **logical append-only history**, not an append-only disk log.
It does not provide multi-process writer coordination, an fsync/power-loss guarantee,
federation, or a demonstrated large-scale performance envelope.

## Remaining MACHINE SPIRIT work

Prolog-RLM owns general semantic compilation, IR, reasoning, and promotion decisions.
Symbolic Memory will persist their results through its library boundary; it must not
become a competing compiler or authority engine.

General full-IR persistence, source-span provenance, semantic support/counterevidence,
bitemporal queries, dependency-complete projections, learning/promotion history,
corpus backfill, federation/redaction, and north-star conformance remain later slices.
