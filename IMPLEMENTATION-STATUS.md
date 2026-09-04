# RAGE 002 implementation status

The durable `memory_remember` → source/memory/audit → `memory_get` slice remains intact and now has a second narrow vertical slice for structured symbolic projections and symbolic-first recall.

## Implemented

- `memory_remember` accepts optional structured projections while preserving the original source text losslessly.
- Projection records have stable opaque IDs and are persisted separately from source text.
- Projection predicates and arguments are treated as data; model-supplied projections are never executed as arbitrary Prolog goals.
- `memory_get` returns the projections attached to a memory.
- `memory_recall` performs exact predicate matching plus positional argument matching with JSON `null` as a wildcard.
- Recall applies namespace visibility before returning a symbolic match.
- Session matches rank before project matches, which rank before global matches.
- Exact projections return compact symbolic statements by default.
- `lossy` and `context_required` projections automatically include the exact stored source text.
- Callers may explicitly request source expansion for exact projections.
- MCP exposes `memory_recall` and projection input on `memory_remember`.
- Snapshot format v2 persists projections and loads existing v1 snapshots with an empty projection set.

## Verification authored

Existing RAGE 001 tests remain in the suite. RAGE 002 adds PlUnit coverage for:

- projection round-trip and stable projection IDs;
- compact exact symbolic recall;
- wildcard argument matching;
- automatic source fallback for lossy projections;
- project isolation before symbolic matching;
- projection restart durability;
- v1 snapshot migration;
- MCP `memory_recall` readable + structured results.

## Verification state

Tests have **not been executed in the ChatGPT implementation environment** because this environment does not provide `swipl` or `nix`.

Do not treat this branch or its PR as green until a local checkout runs:

```sh
nix flake check
```

or at minimum:

```sh
nix develop --command swipl -q -s test/run_tests.pl
```

The PR should remain draft until that executable verification is green.

## Deliberately not in RAGE 002

- automatic prose → symbolic extraction;
- natural-language corpus search/recall;
- rule execution or generated-rule activation;
- contradiction/supersession reasoning;
- temporal truth intervals;
- embeddings;
- natural-language forgetting.

Those remain later slices. RAGE 002 establishes the durable source ↔ symbolic projection boundary and an inspectable Prolog retrieval path first.
