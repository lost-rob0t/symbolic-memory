:- begin_tests(symbolic_memory_recall).

:- use_module('../prolog/symbolic_memory').
:- use_module('../prolog/symbolic_memory_mcp').

project_context(Remote, Context) :-
    Context = _{ principal:"tester",
                 capabilities:[memory_read, memory_write_project],
                 source_class:user_explicit,
                 session_id:"session-a",
                 project:_{remote:Remote}
               }.

session_context(Context) :-
    Context = _{ principal:"tester",
                 capabilities:[memory_read, memory_write_session],
                 source_class:user_explicit,
                 session_id:"session-a"
               }.

modern_meta(_{'io.modelcontextprotocol/protocolVersion':"2026-07-28",
              'io.modelcontextprotocol/clientInfo':_{name:"test-client", version:"1.0.0"},
              'io.modelcontextprotocol/clientCapabilities':_{}}).

new_store(Path) :-
    tmp_file(symbolic_memory_recall, Path),
    delete_if_exists(Path),
    memory_open(_{path:Path}).

cleanup_store(Path) :-
    catch(memory_close, _, true),
    delete_if_exists(Path).

delete_if_exists(Path) :-
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).

write_term_file(Path, Term) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        write_term(Stream, Term, [quoted(true), fullstop(true), nl(true)]),
        close(Stream)
    ).

test(projection_roundtrip_and_compact_recall,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    session_context(Context),
    Projection = _{ predicate:"prefers",
                    arguments:["user", "prolog", "constraint_solving"],
                    statement:"User prefers Prolog for constraint solving.",
                    quality:"exact"
                  },
    memory_remember(Context,
                    "The user prefers Prolog for constraint solving.",
                    _{kind:preference, projections:[Projection]},
                    Stored),
    get_dict(projection_status, Stored, stored),
    get_dict(projection_ids, Stored, [ProjectionId]),
    sub_atom(ProjectionId, 0, 5, _, 'proj_'),
    get_dict(id, Stored, MemoryId),
    memory_get(Context, MemoryId, Memory),
    get_dict(projections, Memory, [StoredProjection]),
    get_dict(predicate, StoredProjection, prefers),
    memory_recall(Context,
                  _{ predicate:"prefers",
                     arguments:["user", "prolog", "constraint_solving"]
                   },
                  _{},
                  Recall),
    get_dict(memories, Recall, [Recalled]),
    get_dict(id, Recalled, MemoryId),
    get_dict(statement, Recalled, "User prefers Prolog for constraint solving."),
    get_dict(source_context_included, Recalled, false),
    assertion(\+ get_dict(source_text, Recalled, _)).

test(null_argument_is_symbolic_wildcard,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    session_context(Context),
    Prolog = _{ predicate:"prefers",
                arguments:["user", "prolog"],
                statement:"User prefers Prolog.",
                quality:"exact"
              },
    Lisp = _{ predicate:"prefers",
              arguments:["user", "common_lisp"],
              statement:"User prefers Common Lisp.",
              quality:"exact"
            },
    memory_remember(Context, "Prolog preference", _{kind:preference, projections:[Prolog]}, _),
    memory_remember(Context, "Lisp preference", _{kind:preference, projections:[Lisp]}, _),
    memory_recall(Context,
                  _{predicate:"prefers", arguments:["user", @(null)]},
                  _{},
                  Recall),
    get_dict(memories, Recall, Memories),
    length(Memories, 2).

test(lossy_projection_includes_exact_source,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    session_context(Context),
    Source = "Use Prolog for verification, except for purely cosmetic edits where no semantic invariant is involved.",
    Projection = _{ predicate:"verification_policy",
                    arguments:["prolog"],
                    statement:"Use Prolog for verification.",
                    quality:"lossy"
                  },
    memory_remember(Context, Source, _{kind:procedure, projections:[Projection]}, Stored),
    get_dict(id, Stored, MemoryId),
    memory_recall(Context,
                  _{predicate:"verification_policy", arguments:["prolog"]},
                  _{},
                  Recall),
    get_dict(memories, Recall, [Recalled]),
    get_dict(id, Recalled, MemoryId),
    get_dict(source_context_included, Recalled, true),
    get_dict(source_text, Recalled, Source),
    get_dict(content, Recall, Content),
    sub_string(Content, _, _, _, "## Source context").

test(project_scope_isolation_applies_before_symbolic_match,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    project_context("https://example.test/project-a.git", ContextA),
    project_context("https://example.test/project-b.git", ContextB),
    ProjectionA = _{ predicate:"backend",
                     arguments:["postgresql"],
                     statement:"Project A uses PostgreSQL."
                   },
    ProjectionB = _{ predicate:"backend",
                     arguments:["sqlite"],
                     statement:"Project B uses SQLite."
                   },
    memory_remember(ContextA, "A backend", _{projections:[ProjectionA]}, StoredA),
    memory_remember(ContextB, "B backend", _{projections:[ProjectionB]}, _),
    get_dict(id, StoredA, MemoryA),
    memory_recall(ContextA, _{predicate:"backend"}, _{}, Recall),
    get_dict(memories, Recall, [Only]),
    get_dict(id, Only, MemoryA).

test(projections_survive_restart,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    session_context(Context),
    Projection = _{ predicate:"known_failure",
                    arguments:["context_compiler", "nondeterministic_order"],
                    statement:"The context compiler previously emitted nondeterministic ordering."
                  },
    memory_remember(Context, "Known failure: nondeterministic ordering.",
                    _{kind:episode, projections:[Projection]}, _),
    memory_close,
    memory_open(_{path:Path}),
    memory_recall(Context,
                  _{predicate:"known_failure", arguments:["context_compiler", "nondeterministic_order"]},
                  _{},
                  Recall),
    get_dict(memories, Recall, [_]).

test(v1_snapshot_migrates_without_projections,
     [ cleanup(cleanup_store(Path))
     ]) :-
    tmp_file(symbolic_memory_v1, Path),
    delete_if_exists(Path),
    Provenance = _{source_class:user_explicit, metadata:_{}},
    At = "2026-08-31T00:00:00Z",
    Snapshot = snapshot(1,
                        [],
                        [source(src_old, "old memory", Provenance, tester, user_explicit, At)],
                        [memory(mem_old, src_old, session('session-a'), long_term, text, 1, active, At)],
                        []),
    write_term_file(Path, Snapshot),
    memory_open(_{path:Path}),
    session_context(Context),
    memory_get(Context, mem_old, Memory),
    get_dict(source_text, Memory, "old memory"),
    get_dict(projections, Memory, []).

test(mcp_memory_recall_returns_markdown_and_structured_content,
     [ setup(new_store(Path)),
       cleanup(cleanup_store(Path))
     ]) :-
    session_context(Context),
    Projection = _{ predicate:"preferred_verifier",
                    arguments:["user", "prolog"],
                    statement:"The user's preferred verifier is Prolog."
                  },
    memory_remember(Context, "Use Prolog to verify important work.",
                    _{kind:preference, projections:[Projection]}, _),
    modern_meta(Meta),
    Request = _{ jsonrpc:"2.0",
                 id:42,
                 method:"tools/call",
                 params:_{ name:"memory_recall",
                           arguments:_{ predicate:"preferred_verifier",
                                       arguments:["user", "prolog"]
                                     },
                           '_meta':Meta
                         }
               },
    mcp_handle(Context, Request, Response),
    get_dict(result, Response, ToolResult),
    get_dict(isError, ToolResult, false),
    get_dict(content, ToolResult, [TextBlock]),
    get_dict(text, TextBlock, Text),
    sub_string(Text, 0, _, _, "# Recalled memory"),
    get_dict(structuredContent, ToolResult, Structured),
    get_dict(memories, Structured, [_]).

:- end_tests(symbolic_memory_recall).
