:- begin_tests(symbolic_memory_util).

:- use_module('../prolog/symbolic_memory_util').

test(new_id_uses_uuid_v4) :-
    new_id(mem, Id),
    atom_length(Id, 40),
    sub_atom(Id, 0, 4, _, 'mem_'),
    sub_atom(Id, 18, 1, _, VersionNibble),
    assertion(VersionNibble == '4').

:- end_tests(symbolic_memory_util).
