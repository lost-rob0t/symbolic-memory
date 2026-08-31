:- ['test_symbolic_memory.pl'].

:- initialization(main, main).

main :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
