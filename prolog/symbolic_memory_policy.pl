:- module(symbolic_memory_policy,
          [ authorize_write/3,
            authorize_read/2,
            context_principal/2,
            provenance_and_trust/4,
            projection_admission/2
          ]).

:- use_module(library(error)).

context_principal(Context, Principal) :-
    must_be(dict, Context),
    (   get_dict(principal, Context, Principal0)
    ->  normalize_atom(Principal0, Principal)
    ;   throw(error(existence_error(context_field, principal), _))
    ).

authorize_write(Context, Namespace, Capability) :-
    write_capability(Namespace, Capability),
    require_capability(Context, Capability, write, Namespace).

authorize_read(Context, Namespace) :-
    require_capability(Context, memory_read, read, Namespace).

provenance_and_trust(Context, Options, Provenance, Trust) :-
    must_be(dict, Context),
    must_be(dict, Options),
    context_source_class(Context, SourceClass),
    source_trust(Context, SourceClass, Trust),
    (   get_dict(source_metadata, Context, Metadata)
    ->  true
    ;   Metadata = _{}
    ),
    Provenance = _{source_class:SourceClass, metadata:Metadata}.

projection_admission(external_untrusted, evidence_only) :- !.
projection_admission(unknown, evidence_only) :- !.
projection_admission(_, semantic).

write_capability(global, memory_write_global).
write_capability(project(_), memory_write_project).
write_capability(session(_), memory_write_session).

require_capability(Context, Capability, Operation, Namespace) :-
    (   get_dict(capabilities, Context, Capabilities0)
    ->  must_be(list, Capabilities0),
        maplist(normalize_atom, Capabilities0, Capabilities)
    ;   Capabilities = []
    ),
    (   memberchk(Capability, Capabilities)
    ->  true
    ;   throw(error(permission_error(Operation, memory, Namespace),
                    context(required_capability, Capability)))
    ).

context_source_class(Context, SourceClass) :-
    (   get_dict(source_class, Context, Source0)
    ->  normalize_atom(Source0, SourceClass)
    ;   SourceClass = model_inferred
    ).

source_trust(Context, _, Trust) :-
    get_dict(trust, Context, Trust0),
    !,
    normalize_atom(Trust0, Trust).
source_trust(_, user_explicit, user_explicit) :- !.
source_trust(_, system_verified, system_verified) :- !.
source_trust(_, project_verified, project_verified) :- !.
source_trust(_, tool_verified, tool_verified) :- !.
source_trust(_, external_untrusted, external_untrusted) :- !.
source_trust(_, model_inferred, model_inferred) :- !.
source_trust(_, _, unknown).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).
