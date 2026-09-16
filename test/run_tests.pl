% A syntax/import error must not leave a smaller, falsely green test suite.
:- dynamic test_load_error/1.
:- multifile user:message_hook/3.
user:message_hook(Term, error, _) :-
    assertz(user:test_load_error(Term)),
    fail.

:- ['test_symbolic_memory.pl'].
:- ['test_symbolic_recall.pl'].
:- ['test_projection_lifecycle.pl'].
:- ['test_mcp_protocol.pl'].
:- ['test_storage_recovery.pl'].
:- ['test_util.pl'].

:- initialization(main, main).

main :-
    (   \+ test_load_error(_), run_tests, \+ test_load_error(_)
    ->  halt(0)
    ;   halt(1)
    ).
