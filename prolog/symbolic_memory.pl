:- module(symbolic_memory,
          [ memory_open/1,
            memory_close/0,
            memory_remember/4,
            memory_get/3
          ]).

:- use_module(library(error)).
:- use_module(symbolic_memory_namespace).
:- use_module(symbolic_memory_policy).
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
    storage_transaction(
        remember_tx(Context, MemoryText, Options, Result)
    ).

memory_get(Context, MemoryId0, Result) :-
    must_be(dict, Context),
    normalize_id(MemoryId0, MemoryId),
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
                lifecycle:Lifecycle
              }.

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

remember_tx(Context, MemoryText, Options, Result) :-
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
    storage_put_audit(EventId, CreatedAt, Principal, memory_remember,
                      Namespace, MemoryId, Provenance, Capability, 0, 1),
    namespace_json(Namespace, NamespaceJson),
    Result = _{ status:stored,
                id:MemoryId,
                source_id:SourceId,
                namespace:NamespaceJson,
                durable:true,
                version:1,
                projection_status:not_attempted
              }.

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
