# Symbolic Memory implementation status

## Implemented on this branch

The original RAGE 001 exact-source slice and RAGE 002 typed projection/recall
slice are retained. MACHINE SPIRIT's next foundation slice adds:

- Independent source and projection commits, including honest failure receipts.
- `memory_project/4`, `memory_projection_status/3`, `memory_projection_history/4`,
  and `memory_projection_withdraw/4`, all exposed through thin MCP tools.
- Immutable whole-set projection generations, request idempotency, expected-generation
  checks, failed-attempt history, and withdrawal without negative evidence or deletion.
- Historical projection contents, source SHA-256 binding, and separate source versus
  interpretation trust/provenance. Unknown trust classes fail closed.
- Current-generation-only `memory_get` and symbolic recall, retaining namespace
  isolation, session → project → global precedence, and exact-source fallback.
- Record-count bounds and explicit truncation/cursors. No total-byte or scale claim.
- Snapshot v3 with v1/v2 migration; migrated compiler provenance stays unknown.
- A fail-closed PlUnit loader and real subprocess stdio restart regression, both
  wired into the Nix check. Existing tests remain included.

See [the lifecycle guide](docs/MACHINE-SPIRIT-LIFECYCLE.org) for the library example,
MCP contract, idempotency semantics, bounds, and limitations.

## Verification state

**Draft; executable Prolog verification has not run.** This implementation environment
has neither `swipl` nor `nix`; package retrieval failed. Python syntax checks and
lightweight static inspection do not establish Prolog correctness.

Required checks:

```sh
nix flake check
```

Or, with SWI-Prolog and Python 3 installed:

```sh
swipl -q -s test/run_tests.pl
python3 test/test_machine_spirit_stdio.py
```

Do not merge based only on authored tests or a missing/empty CI status.

## Boundaries and remaining work

This slice accepts **caller-supplied typed projections**, not natural-language semantic
compilation. It does not complete #5, #6, #9, or the #11 Machine Spirit umbrella.
Prolog-RLM remains the owner of general semantic IR, compiler/reasoner semantics,
and learned-rule promotion decisions.

Still unimplemented: general full-IR storage, epistemic support/counterevidence and
profile-relative acceptance, bitemporal reasoning, general semantic queries,
dependency-complete attention projections, learning/promotion lineage, corpus backfill,
federation/redaction, and north-star conformance. The snapshot backend is single-process,
logically append-only, and lacks an fsync/power-loss guarantee or measured scale envelope.
