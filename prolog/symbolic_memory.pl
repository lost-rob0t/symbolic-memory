:- module(symbolic_memory,
          [ memory_open/1,
            memory_close/0,
            memory_remember/4,
            memory_get/3,
            memory_recall/4
          ]).

:- use_module(library(error)).
:- use_module(symbolic_memory_namespace).
:- use_module(symbolic_memory_policy).
:- use_module(symbolic_memory_projection).
:- use_module(symbolic_memory_storage).
:- use_module(symbolic_memory_util).

memory_open(Config) :-
    storage_open(Config).

memory_close :-
    storage_close.

memory_remember(Context, MemoryText, Options, Result) :-
    must_be(dict, Context),
    must_be(string, MemoryText),
    must_be(dict, Options),
    normalize_projection_specs(Options, ProjectionSpecs),
    storage_transaction(
        remember_tx(Context, MemoryText, Options, ProjectionSpecs, Result)
    ).

memory_get(Context, MemoryId0, Result) :-
    must_be(dict, Context),
    normalize_id(MemoryId0, MemoryId),
    storage_snapshot(
        memory_get_snapshot(Context, MemoryId, Result)
    ).

memory_recall(Context, Query, Options, Result) :-
    must_be(dict, Context),
    must_be(dict, Query),
    must_be(dict, Options),
    authorize_read(Context, memory_recall),
    normalize_projection_query(Query, ProjectionQuery),
    recall_limit(Options, Limit),
    storage_snapshot(
        recall_snapshot(Context, ProjectionQuery, Options, Limit, Result)
    ).

memory_get_snapshot(Context, MemoryId, Result) :-
    require_memory(MemoryId, SourceId, Namespace, Lifetime, Kind,
                   Version, Lifecycle, CreatedAt),
    (   context_can_see_namespace(Context, Namespace)
    ->  true
    ;   throw(error(permission_error(read, memory, Namespace),
                    context(reason, namespace_not_visible)))
    ),
    authorize_read(Context, Namespace),
    require_source(SourceId, Text, Provenance, Principal, Trust, SourceCreatedAt),
    namespace_json(Namespace, NamespaceJson),
    findall(Projection,
            memory_projection_json(MemoryId, Projection),
            Projections),
    Result = _{ id:MemoryId,
                source_id:SourceId,
                source_text:Text,
                namespace:NamespaceJson,
                lifetime:Lifetime,
                kind:Kind,
                provenance:Provenance,
                principal:Principal,
                trust:Trust,
                created_at:CreatedAt,
                source_created_at:SourceCreatedAt,
                version:Version,
                lifecycle:Lifecycle,
                projections:Projections
              }.

memory_projection_json(MemoryId, Json) :-
    storage_projection(ProjectionId, MemoryId, Predicate, Arguments,
                       Statement, Quality, Lifecycle, _),
    projection_json(ProjectionId, Predicate, Arguments, Statement,
                    Quality, Lifecycle, Json).

recall_snapshot(Context, ProjectionQuery, Options, Limit, Result) :-
    findall(Rank-Candidate,
            recall_candidate(Context, ProjectionQuery, Options, Rank, Candidate),
            Ranked0),
    keysort(Ranked0, Ranked),
    strip_keys(Ranked, Candidates),
    take_n(Limit, Candidates, Selected),
    render_recall(Selected, Content),
    Result = _{content:Content, memories:Selected}.

recall_candidate(Context, ProjectionQuery, Options, Rank, Candidate) :-
    storage_projection(ProjectionId, MemoryId, Predicate, Arguments,
                       Statement, Quality, active, ProjectionCreatedAt),
    projection_query_match(ProjectionQuery, Predicate, Arguments),
    storage_get_memory(MemoryId, SourceId, Namespace, Lifetime, Kind,
                       Version, active, MemoryCreatedAt),
    context_can_see_namespace(Context, Namespace),
    require_source(SourceId, SourceText, Provenance, Principal, Trust, SourceCreatedAt),
    namespace_json(Namespace, NamespaceJson),
    recall_scope_rank(Namespace, Rank),
    projection_source_flag(Quality, Options, IncludeSource),
    Base = _{ id:MemoryId,
              projection_id:ProjectionId,
              scope:NamespaceJson,
              status:current,
              lifetime:Lifetime,
              kind:Kind,
              predicate:Predicate,
              arguments:Arguments,
              statement:Statement,
              quality:Quality,
              provenance:Provenance,
              principal:Principal,
              trust:Trust,
              version:Version,
              created_at:MemoryCreatedAt,
              projection_created_at:ProjectionCreatedAt,
              source_created_at:SourceCreatedAt,
              source_context_included:IncludeSource
            },
    recall_source_fields(IncludeSource, SourceId, SourceText, Base, Candidate).

projection_source_flag(Quality, Options, true) :-
    projection_source_required(Quality, Options),
    !.
projection_source_flag(_, _, false).

recall_source_fields(true, SourceId, SourceText, Base, Candidate) :-
    !,
    put_dict(_{source_id:SourceId, source_text:SourceText}, Base, Candidate).
recall_source_fields(false, _, _, Candidate, Candidate).

recall_scope_rank(session(_), 1).
recall_scope_rank(project(_), 2).
recall_scope_rank(global, 3).

recall_limit(Options, Limit) :-
    (   get_dict(limit, Options, Limit0)
    ->  must_be(integer, Limit0),
        (   Limit0 > 0
        ->  Limit = Limit0
        ;   domain_error(positive_integer, Limit0)
        )
    ;   Limit = 20
    ).

strip_keys([], []).
strip_keys([_-Value|Rest], [Value|Values]) :-
    strip_keys(Rest, Values).

take_n(0, _, []) :- !.
take_n(_, [], []) :- !.
take_n(N, [Head|Tail], [Head|Rest]) :-
    N1 is N - 1,
    take_n(N1, Tail, Rest).

render_recall([], "# Recalled memory\n\n_No matching symbolic memory._") :- !.
render_recall(Memories, Content) :-
    maplist(render_memory_line, Memories, Lines),
    atomics_to_string(Lines, "\n", MemoryBody),
    render_source_section(Memories, SourceSection),
    format(string(Content), "# Recalled memory\n\n~s~s", [MemoryBody, SourceSection]).

render_memory_line(Memory, Line) :-
    get_dict(kind, Memory, Kind),
    get_dict(statement, Memory, Statement),
    get_dict(id, Memory, MemoryId),
    format(string(Line), "- **~w · Current** — ~s [~w]", [Kind, Statement, MemoryId]).

render_source_section(Memories, Section) :-
    findall(Block,
            ( member(Memory, Memories),
              get_dict(source_context_included, Memory, true),
              source_context_block(Memory, Block)
            ),
            Blocks),
    (   Blocks == []
    ->  Section = ""
    ;   atomics_to_string(Blocks, "\n\n", Body),
        format(string(Section), "\n\n## Source context\n\n~s", [Body])
    ).

source_context_block(Memory, Block) :-
    get_dict(id, Memory, MemoryId),
    get_dict(source_text, Memory, SourceText),
    split_string(SourceText, "\n", "", Lines),
    atomics_to_string(Lines, "\n> ", Quoted),
    format(string(Block), "> [~w] ~s", [MemoryId, Quoted]).

require_memory(MemoryId, SourceId, Namespace, Lifetime, Kind,
               Version, Lifecycle, CreatedAt) :-
    (   storage_get_memory(MemoryId, SourceId, Namespace, Lifetime, Kind,
                           Version, Lifecycle, CreatedAt)
    ->  true
    ;   throw(error(existence_error(memory, MemoryId), _))
    ).

require_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt) :-
    (   storage_get_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt)
    ->  true
    ;   throw(error(existence_error(memory_source, SourceId),
                    context(reason, corrupt_memory_record)))
    ).

remember_tx(Context, MemoryText, Options, ProjectionSpecs, Result) :-
    resolve_write_namespace(Context, Options, Namespace),
    authorize_write(Context, Namespace, Capability),
    context_principal(Context, Principal),
    provenance_and_trust(Context, Options, Provenance, Trust),
    remember_lifetime(Options, Lifetime),
    remember_kind(Options, Kind),
    new_id(src, SourceId),
    new_id(mem, MemoryId),
    new_id(evt, EventId),
    now_iso8601(CreatedAt),
    storage_put_source(SourceId, MemoryText, Provenance, Principal, Trust, CreatedAt),
    storage_put_memory(MemoryId, SourceId, Namespace, Lifetime, Kind,
                       1, active, CreatedAt),
    store_projections(MemoryId, ProjectionSpecs, CreatedAt, ProjectionIds),
    storage_put_audit(EventId, CreatedAt, Principal, memory_remember,
                      Namespace, MemoryId, Provenance, Capability, 0, 1),
    namespace_json(Namespace, NamespaceJson),
    projection_status(ProjectionIds, ProjectionStatus),
    Result = _{ status:stored,
                id:MemoryId,
                source_id:SourceId,
                namespace:NamespaceJson,
                durable:true,
                version:1,
                projection_status:ProjectionStatus,
                projection_ids:ProjectionIds
              }.

store_projections(_, [], _, []).
store_projections(MemoryId,
                  [projection_spec(Predicate, Arguments, Statement, Quality)|Rest],
                  CreatedAt,
                  [ProjectionId|Ids]) :-
    new_id(proj, ProjectionId),
    storage_put_projection(ProjectionId, MemoryId, Predicate, Arguments,
                           Statement, Quality, active, CreatedAt),
    store_projections(MemoryId, Rest, CreatedAt, Ids).

projection_status([], not_attempted).
projection_status([_|_], stored).

remember_lifetime(Options, Lifetime) :-
    (   get_dict(retention, Options, Retention0)
    ->  normalize_atom(Retention0, Retention),
        retention_lifetime(Retention, Lifetime)
    ;   Lifetime = long_term
    ).

retention_lifetime(session, short_term).
retention_lifetime(short_term, short_term).
retention_lifetime(long_term, long_term).
retention_lifetime(durable, long_term).
retention_lifetime(Value, _) :-
    domain_error(memory_retention, Value).

remember_kind(Options, Kind) :-
    (   get_dict(kind, Options, Kind0)
    ->  normalize_atom(Kind0, Requested),
        normalize_kind(Requested, Kind)
    ;   Kind = text
    ).

normalize_kind(auto, text).
normalize_kind(text, text).
normalize_kind(fact, fact).
normalize_kind(episode, episode).
normalize_kind(preference, preference).
normalize_kind(procedure, procedure).
normalize_kind(Value, _) :-
    domain_error(memory_kind, Value).

normalize_id(Value, Id) :-
    normalize_atom(Value, Id).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).
