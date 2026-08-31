:- begin_tests(symbolic_memory_storage_recovery).

:- use_module('../prolog/symbolic_memory').

write_term_file(Path, Term) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        write_term(Stream, Term,
                   [quoted(true), fullstop(true), nl(true)]),
        close(Stream)
    ).

cleanup_paths(Paths) :-
    catch(memory_close, _, true),
    maplist(delete_if_exists, Paths).

delete_if_exists(Path) :-
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).

test(unsupported_snapshot_version_fails_and_cleans_open_state,
     [ cleanup(cleanup_paths([BadPath, GoodPath]))
     ]) :-
    tmp_file(symbolic_memory_bad_version, BadPath),
    tmp_file(symbolic_memory_good_after_bad, GoodPath),
    delete_if_exists(BadPath),
    delete_if_exists(GoodPath),
    write_term_file(BadPath, snapshot(999, [], [], [], [])),
    catch(memory_open(_{path:BadPath}), Error, true),
    assertion(nonvar(Error)),
    assertion(Error = error(domain_error(storage_format_version, 999), _)),
    memory_open(_{path:GoodPath}),
    memory_close.

test(malformed_snapshot_fails_and_cleans_open_state,
     [ cleanup(cleanup_paths([BadPath, GoodPath]))
     ]) :-
    tmp_file(symbolic_memory_bad_shape, BadPath),
    tmp_file(symbolic_memory_good_after_shape, GoodPath),
    delete_if_exists(BadPath),
    delete_if_exists(GoodPath),
    write_term_file(BadPath, definitely_not_a_snapshot),
    catch(memory_open(_{path:BadPath}), Error, true),
    assertion(nonvar(Error)),
    assertion(Error = error(domain_error(symbolic_memory_snapshot, definitely_not_a_snapshot), _)),
    memory_open(_{path:GoodPath}),
    memory_close.

:- end_tests(symbolic_memory_storage_recovery).
