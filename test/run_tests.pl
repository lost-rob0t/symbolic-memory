:- ['test_symbolic_memory.pl'].
:- ['test_symbolic_recall.pl'].
:- ['test_mcp_protocol.pl'].
:- ['test_storage_recovery.pl'].
:- ['test_util.pl'].

:- initialization(main, main).

main :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
