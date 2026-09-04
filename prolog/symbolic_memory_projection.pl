:- module(symbolic_memory_projection,
          [ normalize_projection_specs/2,
            normalize_projection_query/2,
            projection_query_match/3,
            projection_source_required/2,
            projection_json/8
          ]).

:- use_module(library(error)).

normalize_projection_specs(Options, Specs) :-
    must_be(dict, Options),
    (   get_dict(projections, Options, Raw)
    ->  must_be(list, Raw),
        maplist(normalize_projection_spec, Raw, Specs)
    ;   Specs = []
    ).

normalize_projection_query(Query, projection_query(Predicate, Arguments)) :-
    must_be(dict, Query),
    (   get_dict(predicate, Query, Predicate0)
    ->  normalize_string(Predicate0, Predicate)
    ;   throw(error(existence_error(recall_query_field, predicate), _))
    ),
    (   get_dict(arguments, Query, Arguments0)
    ->  must_be(list, Arguments0),
        maplist(normalize_query_argument, Arguments0, Arguments)
    ;   Arguments = any
    ).

projection_query_match(projection_query(Predicate, Pattern), Predicate, Arguments) :-
    query_arguments_match(Pattern, Arguments).

projection_source_required(Quality, Options) :-
    (   memberchk(Quality, [lossy, context_required])
    ->  true
    ;   get_dict(include_source, Options, Value),
        truthy(Value)
    ).

projection_json(ProjectionId, Predicate, Arguments, Statement, Quality,
                Lifecycle, CreatedAt, Json) :-
    Json = _{ id:ProjectionId,
              predicate:Predicate,
              arguments:Arguments,
              statement:Statement,
              quality:Quality,
              lifecycle:Lifecycle,
              created_at:CreatedAt
            }.

normalize_projection_spec(Raw,
                          projection_spec(Predicate, Arguments, Statement, Quality)) :-
    must_be(dict, Raw),
    require_field(Raw, predicate, Predicate0),
    require_field(Raw, arguments, Arguments0),
    require_field(Raw, statement, Statement0),
    normalize_string(Predicate0, Predicate),
    must_be(list, Arguments0),
    maplist(normalize_projection_argument, Arguments0, Arguments),
    normalize_string(Statement0, Statement),
    projection_quality(Raw, Quality).

projection_quality(Raw, Quality) :-
    (   get_dict(quality, Raw, Quality0)
    ->  normalize_atom(Quality0, Quality1),
        valid_quality(Quality1),
        Quality = Quality1
    ;   Quality = exact
    ).

valid_quality(exact) :- !.
valid_quality(lossy) :- !.
valid_quality(context_required) :- !.
valid_quality(Value) :-
    domain_error(projection_quality, Value).

query_arguments_match(any, _).
query_arguments_match(Pattern, Arguments) :-
    same_length(Pattern, Arguments),
    maplist(query_argument_match, Pattern, Arguments).

query_argument_match(wildcard, _) :- !.
query_argument_match(Expected, Actual) :-
    Expected == Actual.

normalize_query_argument(null, wildcard) :- !.
normalize_query_argument(@(null), wildcard) :- !.
normalize_query_argument(Value, Normalized) :-
    normalize_projection_argument(Value, Normalized).

normalize_projection_argument(null, _) :-
    !,
    throw(error(domain_error(symbolic_projection_argument, null),
                context(reason, null_reserved_for_recall_wildcard))).
normalize_projection_argument(@(null), _) :-
    !,
    throw(error(domain_error(symbolic_projection_argument, @(null)),
                context(reason, null_reserved_for_recall_wildcard))).
normalize_projection_argument(true, true) :- !.
normalize_projection_argument(false, false) :- !.
normalize_projection_argument(@(true), true) :- !.
normalize_projection_argument(@(false), false) :- !.
normalize_projection_argument(Value, Value) :-
    (   string(Value)
    ;   number(Value)
    ),
    !.
normalize_projection_argument(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).
normalize_projection_argument(Value, _) :-
    throw(error(type_error(symbolic_projection_scalar, Value), _)).

require_field(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(error(existence_error(projection_field, Key), _))
    ).

truthy(true).
truthy(@(true)).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).

normalize_string(Value, String) :-
    (   string(Value)
    ->  String = Value
    ;   atom(Value)
    ->  atom_string(Value, String)
    ;   type_error(text, Value)
    ).
