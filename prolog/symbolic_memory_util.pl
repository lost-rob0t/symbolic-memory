:- module(symbolic_memory_util,
          [ new_id/2,
            now_iso8601/1,
            text_atom/2
          ]).

:- use_module(library(date)).
:- use_module(library(error)).
:- use_module(library(uuid)).

new_id(Prefix, Id) :-
    must_be(atom, Prefix),
    uuid(UUID, [version(4)]),
    atomic_list_concat([Prefix, UUID], '_', Id).

now_iso8601(Timestamp) :-
    get_time(Now),
    stamp_date_time(Now, UTCDateTime, 'UTC'),
    format_time(string(Timestamp), '%FT%TZ', UTCDateTime, posix).

text_atom(Text, Atom) :-
    (   atom(Text)
    ->  Atom = Text
    ;   string(Text)
    ->  atom_string(Atom, Text)
    ;   type_error(text, Text)
    ).
