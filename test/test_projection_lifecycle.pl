:- begin_tests(symbolic_memory_projection_lifecycle).

:- use_module('../prolog/symbolic_memory').
:- use_module('../prolog/symbolic_memory_mcp').
:- use_module('../prolog/symbolic_memory_storage').
:- use_module(library(crypto)).
:- use_module(library(filesex)).
:- use_module(library(http/json)).

context(Context) :-
    Context = _{principal:tester, session_id:"machine-spirit-test",
                source_class:user_explicit,
                capabilities:[memory_read, memory_write_session]}.

new_store(Path) :-
    tmp_file(machine_spirit, Path),
    memory_open(_{path:Path}).

cleanup_store(Path) :-
    catch(memory_close, _, true),
    (exists_file(Path) -> delete_file(Path) ; true).

source(Context, Id) :-
    context(Context),
    memory_remember(Context, "N545PY uses Prolog.\nExact source: λ.\n", _{}, Stored),
    Id = Stored.id.

spec(Value, _{predicate:"uses", arguments:["N545PY", Value],
              statement:"Remembered language preference.", quality:"exact"}).

project(Context, Id, Value, Result) :-
    spec(Value, Spec),
    memory_project(Context, Id, _{projections:[Spec]}, Result).

history(Context, Id, Events) :-
    memory_projection_history(Context, Id, _{limit:200}, Result),
    Events = Result.events.

recall(Context, Memories) :-
    memory_recall(Context, _{predicate:"uses"}, _{}, Result),
    Memories = Result.memories.

test(late_projection_binds_exact_unicode_source,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id),
    memory_projection_status(C, Id, Before),
    assertion(Before.status == absent),
    project(C, Id, "prolog", Projected),
    assertion(Projected.status == ready),
    assertion(Projected.generation == 1),
    memory_get(C, Id, Memory),
    crypto_data_hash(Memory.source_text, Hash, [algorithm(sha256), encoding(utf8)]),
    assertion(Projected.payload.source_hash == Hash),
    assertion(Projected.model_calls == 0),
    recall(C, [Recalled]),
    assertion(Recalled.projection_metadata.generation == 1).

test(idempotent_native_atom_and_string_retry,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id),
    project(C, Id, prolog, First),
    project(C, Id, "prolog", Again),
    assertion(Again.status == already_present),
    assertion(Again.event_id == First.event_id),
    assertion(Again.projection_ids == First.projection_ids),
    history(C, Id, [_]).

test(replacement_retains_old_records_and_history,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id),
    project(C, Id, "prolog", First),
    project(C, Id, "common_lisp", Second),
    assertion(Second.generation == 2),
    assertion(Second.payload.supersedes_generation == 1),
    First.projection_ids = [OldId],
    storage_projection(OldId, Id, _, _, _, _, _, _),
    memory_get(C, Id, Memory),
    Memory.projections = [Current],
    assertion(Current.arguments == ["N545PY", "common_lisp"]),
    history(C, Id, [OldEvent, NewEvent]),
    assertion(OldEvent.generation == 1),
    assertion(NewEvent.generation == 2).

test(old_retry_does_not_replace_current_generation,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id),
    project(C, Id, "prolog", _),
    project(C, Id, "common_lisp", _),
    project(C, Id, "prolog", Retry),
    assertion(Retry.status == already_present),
    assertion(Retry.is_current == false),
    assertion(Retry.current_generation == 2),
    recall(C, [Current]),
    assertion(Current.arguments == ["N545PY", "common_lisp"]).

test(changed_payload_cannot_reuse_request_key,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), spec("prolog", A), spec("lisp", B),
    memory_project(C, Id, _{request_id:"same", projections:[A]}, _),
    catch(memory_project(C, Id, _{request_id:"same", projections:[B]}, _), Error, true),
    assertion(nonvar(Error)),
    assertion(Error = error(permission_error(reuse, projection_request, "same"), _)),
    history(C, Id, [_]).

test(failure_keeps_last_usable_generation_after_restart,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    Bad = _{predicate:"uses", arguments:[null], statement:"Invalid."},
    memory_project(C, Id, _{projections:[Bad]}, Failed),
    assertion(Failed.status == failed),
    assertion(Failed.generation == 2),
    memory_close, memory_open(_{path:Path}),
    memory_projection_status(C, Id, Status),
    assertion(Status.status == failed),
    assertion(Status.current_status == ready),
    assertion(Status.current_generation == 1),
    recall(C, [_]), history(C, Id, [_, Failure]),
    assertion(Failure.state == failed).

test(convenience_remember_preserves_source_on_validation_failure,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    context(C),
    memory_remember(C, "Source survives.", _{projections:not_a_list}, Stored),
    assertion(Stored.durable == true),
    assertion(Stored.projection_status == projection_error),
    assertion(Stored.projection_attempt_durable == true),
    memory_close, memory_open(_{path:Path}),
    memory_get(C, Stored.id, Memory),
    assertion(Memory.source_text == "Source survives.").

test(withdrawal_is_not_negative_evidence_or_source_deletion,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    memory_projection_withdraw(C, Id, _{reason:"Interpretation withdrawn."}, Withdrawn),
    assertion(Withdrawn.status == withdrawn),
    recall(C, []),
    memory_close, memory_open(_{path:Path}),
    recall(C, []), memory_get(C, Id, Memory),
    assertion(Memory.source_text == "N545PY uses Prolog.\nExact source: λ.\n"),
    history(C, Id, [Positive, Withdrawal]),
    assertion(Positive.state == ready),
    assertion(Withdrawal.state == withdrawn),
    assertion(Withdrawal.payload.projection_ids == []).

test(historical_retry_cannot_resurrect_withdrawn_projection,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    memory_projection_withdraw(C, Id, _{reason:"Withdraw."}, _),
    project(C, Id, "prolog", Retry),
    assertion(Retry.status == already_present),
    assertion(Retry.is_current == false),
    assertion(Retry.current_status == withdrawn),
    recall(C, []), history(C, Id, [_, _]).

test(explicit_new_request_can_republish_after_withdrawal,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    memory_projection_withdraw(C, Id, _{reason:"Withdraw."}, _),
    spec("prolog", Spec),
    memory_project(C, Id, _{projections:[Spec], request_id:"new-review",
                           expected_generation:2}, New),
    assertion(New.generation == 3), recall(C, [_]).

test(repeated_withdrawal_is_a_noop,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    memory_projection_withdraw(C, Id, _{reason:"Withdraw."}, _),
    memory_projection_withdraw(C, Id, _{reason:"Withdraw again."}, Again),
    assertion(Again.status == already_absent),
    history(C, Id, [_, _]).

test(stale_generation_cannot_publish,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _), spec("lisp", Spec),
    catch(memory_project(C, Id, _{projections:[Spec], expected_generation:0}, _), E, true),
    assertion(nonvar(E)),
    assertion(E = error(projection_generation_conflict(0, 1), _)),
    history(C, Id, [_]), recall(C, [Current]),
    assertion(Current.arguments == ["N545PY", "prolog"]).

test(read_only_context_cannot_project,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(capabilities, C, [memory_read], ReadOnly),
    catch(project(ReadOnly, Id, "prolog", _), E, true),
    assertion(nonvar(E)),
    assertion(E = error(permission_error(write, memory, _), _)),
    history(C, Id, []).

test(write_only_context_cannot_read_or_project_an_existing_source,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(capabilities, C, [memory_write_session], WriteOnly),
    catch(project(WriteOnly, Id, "prolog", _), E, true),
    assertion(nonvar(E)),
    assertion(E = error(permission_error(read, memory, _), _)),
    history(C, Id, []).

test(other_namespace_history_and_guessed_id_are_both_denied,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(session_id, C, "other-session", Other),
    catch(memory_projection_history(Other, Id, _{}, _), A, true),
    catch(memory_projection_history(Other, nonexistent_memory, _{}, _), B, true),
    assertion(nonvar(A)), assertion(nonvar(B)),
    assertion(A = error(permission_error(read, memory, _), _)),
    assertion(B = error(permission_error(read, memory, _), _)).

test(untrusted_source_cannot_be_upgraded_by_trusted_interpreter,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    context(C), put_dict(source_class, C, external_untrusted, Untrusted),
    memory_remember(Untrusted, "Untrusted evidence", _{}, Stored),
    project(C, Stored.id, "prolog", Result),
    assertion(Result.status == blocked_untrusted), recall(C, []).

test(untrusted_interpreter_cannot_use_trusted_source_authority,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(source_class, C, external_untrusted, Untrusted),
    project(Untrusted, Id, "prolog", Result),
    assertion(Result.status == blocked_untrusted), recall(C, []).

test(unknown_host_trust_class_is_evidence_only,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(trust, C, typo_in_trust_class, Unknown),
    project(Unknown, Id, "prolog", Result),
    assertion(Result.status == blocked_untrusted), recall(C, []).

test(model_interpretation_does_not_inherit_source_trust,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), put_dict(source_class, C, model_inferred, Model),
    project(Model, Id, "prolog", _), recall(C, [Memory]),
    assertion(Memory.trust == user_explicit),
    assertion(Memory.projection_metadata.interpretation_trust == model_inferred).

test(history_cursor_is_bounded_and_nonduplicating,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _), project(C, Id, "lisp", _),
    memory_projection_history(C, Id, _{limit:1}, First),
    assertion(First.has_more == true), assertion(First.next_after_generation == 1),
    memory_projection_history(C, Id, _{limit:1, after_generation:1}, Second),
    assertion(Second.has_more == false), assertion(Second.next_after_generation == 2),
    First.events = [A], Second.events = [B], assertion(A.id \== B.id).

test(recall_limit_and_truncation_are_explicit,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), spec("prolog", A), spec("lisp", B),
    memory_project(C, Id, _{projections:[A, B]}, _),
    memory_recall(C, _{predicate:"uses"}, _{limit:1}, Result),
    Result.memories = [_], assertion(Result.truncated == true),
    assertion(Result.model_calls == 0),
    catch(memory_recall(C, _{predicate:"uses"}, _{limit:201}, _), E, true),
    assertion(nonvar(E)),
    assertion(E = error(domain_error(recall_limit, 201), _)).

test(executable_looking_terms_remain_inert,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id),
    Evil = _{predicate:"assertz", arguments:["user:machine_spirit_pwned"],
             statement:"Not executable."},
    memory_project(C, Id, _{projections:[Evil]}, Result),
    assertion(Result.status == ready),
    assertion(\+ current_predicate(user:machine_spirit_pwned/0)),
    Bad = _{predicate:"assertz", arguments:[assertz(user:machine_spirit_pwned)],
            statement:"Reject compound arguments."},
    memory_project(C, Id, _{projections:[Bad]}, Rejected),
    assertion(Rejected.status == failed),
    assertion(\+ current_predicate(user:machine_spirit_pwned/0)).

test(mcp_and_native_status_are_equivalent_and_json_serializable,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _),
    memory_projection_status(C, Id, Native),
    mcp_handle(C, _{jsonrpc:"2.0", id:1, method:"tools/call",
                   params:_{name:"memory_projection_status", arguments:_{id:Id}}}, Rpc),
    assertion(Rpc.result.isError == false),
    assertion(Rpc.result.structuredContent =@= Native),
    atom_json_dict(_, Rpc, []).

test(mcp_rejects_caller_supplied_authority_fields,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), spec("prolog", Spec),
    mcp_handle(C, _{jsonrpc:"2.0", id:1, method:"tools/call",
                   params:_{name:"memory_project",
                            arguments:_{id:Id, projections:[Spec], trust:"system_verified"}}}, Rpc),
    assertion(Rpc.result.isError == true), history(C, Id, []).

test(mcp_advertises_all_lifecycle_tools,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    context(C),
    mcp_handle(C, _{jsonrpc:"2.0", id:1, method:"tools/list"}, Rpc),
    Tools = Rpc.result.tools,
    forall(member(Name, ["memory_project", "memory_projection_status",
                         "memory_projection_history", "memory_projection_withdraw"]),
           (member(Tool, Tools), Tool.name == Name)).

test(concurrent_stale_writers_cannot_both_publish,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), spec("prolog", A), spec("lisp", B),
    thread_create(memory_project(C, Id, _{projections:[A], expected_generation:0}, _), T1, []),
    thread_create(memory_project(C, Id, _{projections:[B], expected_generation:0}, _), T2, []),
    thread_join(T1, S1), thread_join(T2, S2),
    msort([S1, S2], States),
    assertion(States = [true, exception(error(projection_generation_conflict(0, 1), _))]),
    history(C, Id, [_]).

set_store_path(Path) :-
    retractall(symbolic_memory_storage:storage_path(_)),
    assertz(symbolic_memory_storage:storage_path(Path)).

test(projection_disk_error_preserves_previously_committed_source,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), tmp_file(machine_spirit_bad_destination, Bad),
    setup_call_cleanup(make_directory(Bad),
      setup_call_cleanup(set_store_path(Bad),
                         catch(project(C, Id, "prolog", _), Error, true),
                         set_store_path(Path)),
      delete_directory(Bad)),
    assertion(nonvar(Error)), history(C, Id, []),
    memory_close, memory_open(_{path:Path}), memory_get(C, Id, Memory),
    assertion(Memory.source_text == "N545PY uses Prolog.\nExact source: λ.\n"),
    assertion(Memory.projections == []).

test(v2_legacy_projection_migrates_without_invented_compiler_provenance,
     [cleanup(cleanup_store(Path))]) :-
    tmp_file(machine_spirit_v2, Path), context(C),
    At = "2026-09-01T00:00:00Z", P = _{source_class:user_explicit, metadata:_{}},
    Snapshot = snapshot(2, [],
      [source(src_old, "Legacy source", P, tester, user_explicit, At)],
      [memory(mem_old, src_old, session('machine-spirit-test'), long_term, text, 1, active, At)],
      [projection(proj_old, mem_old, "uses", ["N545PY", "prolog"], "Legacy.", exact, active, At)], []),
    setup_call_cleanup(open(Path, write, S, [encoding(utf8)]),
      write_term(S, Snapshot, [quoted(true), fullstop(true), nl(true)]), close(S)),
    memory_open(_{path:Path}), memory_projection_status(C, mem_old, Status),
    assertion(Status.legacy_projection == true), recall(C, [Legacy]),
    assertion(Legacy.projection_metadata.interpretation_trust == unknown),
    memory_projection_withdraw(C, mem_old, _{reason:"Retire legacy interpretation."}, _),
    memory_close, memory_open(_{path:Path}), recall(C, []).

test(history_exposes_immutable_prior_projection_contents,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), project(C, Id, "prolog", _), project(C, Id, "lisp", _),
    memory_close, memory_open(_{path:Path}),
    history(C, Id, [First, Second]),
    get_dict(projections, First, [Old]), get_dict(projections, Second, [New]),
    assertion(Old.arguments == ["N545PY", "prolog"]),
    assertion(New.arguments == ["N545PY", "lisp"]).

test(status_read_is_not_a_tool_failure_after_failed_attempt,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), memory_project(C, Id, _{projections:[]}, Failed),
    assertion(Failed.status == failed),
    mcp_handle(C, _{jsonrpc:"2.0", id:1, method:"tools/call",
                   params:_{name:"memory_projection_status", arguments:_{id:Id}}}, Rpc),
    assertion(Rpc.result.isError == false),
    assertion(Rpc.result.structuredContent.status == failed).

test(rational_numbers_are_not_silently_rounded_for_json,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), Rational is 1 rdiv 3, spec(Rational, Spec),
    memory_project(C, Id, _{projections:[Spec]}, Failed),
    assertion(Failed.status == failed), recall(C, []).

test(unknown_semantic_fields_are_not_silently_discarded,
     [setup(new_store(Path)), cleanup(cleanup_store(Path))]) :-
    source(C, Id), spec("prolog", Spec), put_dict(rule_body, Spec, "do not discard me", Extended),
    memory_project(C, Id, _{projections:[Extended]}, Failed),
    assertion(Failed.status == failed), recall(C, []).

:- end_tests(symbolic_memory_projection_lifecycle).
