# RAGE 001 implementation status

The `memory_remember` → durable source/memory/audit → `memory_get` vertical slice is implemented on this branch.

## Verification authored

- PlUnit domain tests for ID stability, exact text round-trip, restart durability, project isolation, global-write denial, read authority, audit emission, transactional rollback, duplicate IDs, provenance/trust, remote normalization, and session scope.
- MCP tests for stateless `2026-07-28` discovery/tool calls, legacy `2025-11-25` compatibility, and unsupported-version error `-32022`.
- Nix flake check runs the complete PlUnit suite with SWI-Prolog.

## Verification state

Tests have **not been executed in the ChatGPT implementation environment** because that environment does not provide `swipl` or `nix`.

Do not treat this branch or its PR as green until a local checkout runs:

```sh
nix flake check
```

or at minimum:

```sh
nix develop --command swipl -q -s test/run_tests.pl
```

The issue must remain open and the PR must remain draft until that executable verification is green.
