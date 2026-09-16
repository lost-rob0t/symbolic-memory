:- module(symbolic_memory_lifecycle,
          [ memory_project/4,
            memory_projection_status/3,
            memory_projection_history/4,
            memory_projection_withdraw/4,
            projection_is_current/2,
            projection_metadata/3
          ]).

/** <module> MACHINE SPIRIT's caller-supplied projection lifecycle

Exact sources are committed before this API runs. This module admits inert,
caller-supplied projections; it is not a semantic compiler or an authority
engine. Every attempt is a new event. Failed attempts do not replace the last
usable generation. Historical retries never reactivate withdrawn knowledge.
*/

:- use_module(library(aggregate)).
:- use_module(library(crypto)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(solution_sequences)).
:- use_module(symbolic_memory_namespace).
:- use_module(symbolic_memory_policy).
:- use_module(symbolic_memory_projection).
:- use_module(symbolic_memory_storage).
:- use_module(symbolic_memory_util).

memory_project(Context, MemoryId0, Options, Result) :-
    validate_call(Context, MemoryId0, Options, MemoryId),
    storage_transaction(project_locked(Context, MemoryId, Options, Result)).

memory_projection_status(Context, MemoryId0, Result) :-
    validate_call(Context, MemoryId0, _{}, MemoryId),
    storage_snapshot((read_source(Context, MemoryId, _, _, _, _, _),
                      status_locked(MemoryId, Result))).

memory_projection_history(Context, MemoryId0, Options, Result) :-
    validate_call(Context, MemoryId0, Options, MemoryId),
    page_options(Options, Limit, After),
    storage_snapshot(history_locked(Context, MemoryId, Limit, After, Result)).

memory_projection_withdraw(Context, MemoryId0, Options, Result) :-
    validate_call(Context, MemoryId0, Options, MemoryId),
    required(Options, reason, Reason0),
    bounded_text(Reason0, 4096, Reason),
    storage_transaction(withdraw_locked(Context, MemoryId, Options, Reason, Result)).

validate_call(Context, MemoryId0, Options, MemoryId) :-
    must_be(dict, Context),
    must_be(dict, Options),
    authorize_read(Context, memory_projection),
    bounded_text(MemoryId0, 256, MemoryIdText),
    atom_string(MemoryId, MemoryIdText).

read_source(Context, MemoryId, Namespace, SourceId, Text, Trust, Principal) :-
    (   storage_get_memory(MemoryId, SourceId, Namespace, _, _, _, active, _),
        context_can_see_namespace(Context, Namespace)
    ->  authorize_read(Context, Namespace)
    ;   % Do not turn guessed IDs into a cross-namespace existence oracle.
        throw(error(permission_error(read, memory, MemoryId),
                    context(reason, unavailable_or_not_visible)))
    ),
    (   storage_get_source(SourceId, Text, _, _, Trust, _)
    ->  true
    ;   throw(error(existence_error(memory_source, SourceId), _))
    ),
    context_principal(Context, Principal).

project_locked(Context, MemoryId, Options, Result) :-
    read_source(Context, MemoryId, Namespace, SourceId, Text, SourceTrust, Principal),
    authorize_write(Context, Namespace, Capability),
    provenance_and_trust(Context, _{}, InterpretationProvenance, InterpretationTrust),
    crypto_data_hash(Text, SourceHash, [algorithm(sha256), encoding(utf8)]),
    Base = projection_metadata{source_id:SourceId, source_hash:SourceHash,
                               schema:"typed_projection_v1", origin:caller_supplied,
                               source_trust:SourceTrust,
                               interpretation_trust:InterpretationTrust,
                               interpretation_provenance:InterpretationProvenance,
                               model_calls:0},
    (   projection_admission(SourceTrust, semantic),
        projection_admission(InterpretationTrust, semantic)
    ->  catch(prepare_request(Options, SourceHash, Specs, Request), Error, true),
        project_attempt(Error, Context, MemoryId, Namespace, Options, Specs,
                        Request, Base, Principal, Capability, Result)
    ;   check_generation(MemoryId, Options),
        put_dict(_{reason:evidence_only, projection_ids:[]}, Base, Payload),
        append_event(MemoryId, blocked_untrusted, Payload, Principal, Namespace,
                     Capability, Result)
    ).

project_attempt(Error, _, MemoryId, Namespace, Options, _, _, Base,
                Principal, Capability, Result) :-
    nonvar(Error),
    !,
    check_generation(MemoryId, Options),
    term_string(Error, FullError),
    clip_text(FullError, 4096, ErrorText),
    put_dict(_{error:ErrorText, projection_ids:[]}, Base, Payload),
    append_event(MemoryId, failed, Payload, Principal, Namespace, Capability, Result).
project_attempt(_, _, MemoryId, Namespace, Options, Specs, Request, Base,
                Principal, Capability, Result) :-
    (   prior_request(MemoryId, Request.request_id, Previous)
    ->  (   Previous.payload.content_hash == Request.content_hash
        ->  receipt(Previous, already_present, Result)
        ;   throw(error(permission_error(reuse, projection_request,
                                          Request.request_id),
                        context(reason, idempotency_conflict)))
        )
    ;   check_generation(MemoryId, Options),
        current_generation(MemoryId, PreviousGeneration, _, _),
        now_iso8601(At),
        store_specs(Specs, MemoryId, At, ProjectionIds),
        put_dict(Request, Base, Requested),
        put_dict(_{projection_ids:ProjectionIds,
                   supersedes_generation:PreviousGeneration}, Requested, Payload),
        append_event(MemoryId, ready, Payload, Principal, Namespace, Capability, Result)
    ).

prepare_request(Options, SourceHash, Specs, Request) :-
    required(Options, projections, Raw),
    must_be(list, Raw),
    length(Raw, Count),
    (between(1, 128, Count) -> true ; domain_error(projection_batch_size, Count)),
    maplist(check_raw_spec, Raw),
    normalize_projection_specs(Options, Specs),
    maplist(check_spec_bounds, Specs),
    option_text(Options, compiler_fingerprint, "caller-supplied-v1", 256, Compiler),
    % Only a closed, ground term is hashed, never a dict's variable tag.
    term_string(projection_request(1, SourceHash, Compiler, Specs), Canonical,
                [quoted(true), ignore_ops(true)]),
    crypto_data_hash(Canonical, ContentHash, [algorithm(sha256), encoding(utf8)]),
    atom_string(ContentHash, DefaultKey),
    option_text(Options, request_id, DefaultKey, 256, RequestId),
    Request = projection_request{request_id:RequestId, content_hash:ContentHash,
                                 compiler_fingerprint:Compiler}.

check_spec_bounds(projection_spec(Predicate, Arguments, Statement, _)) :-
    bounded_text(Predicate, 128, _),
    bounded_text(Statement, 8192, _),
    length(Arguments, Arity),
    (Arity =< 32 -> true ; domain_error(projection_arity, Arity)),
    maplist(check_argument_bound, Arguments).

check_raw_spec(Raw) :-
    must_be(dict, Raw),
    dict_pairs(Raw, _, Pairs),
    forall(member(Key-_, Pairs),
           (memberchk(Key, [predicate, arguments, statement, quality]) -> true
           ; domain_error(projection_field, Key))),
    required(Raw, arguments, Arguments),
    must_be(list, Arguments),
    length(Arguments, Arity),
    (Arity =< 32 -> true ; domain_error(projection_arity, Arity)).

check_argument_bound(Value) :-
    (   string(Value)
    ->  bounded_text(Value, 2048, _)
    ;   integer(Value)
    ->  true
    ;   float(Value)
    ->  float_class(Value, Class),
        (memberchk(Class, [normal, subnormal, zero]) -> true
        ; domain_error(finite_number, Value))
    ;   Value == true
    ->  true
    ;   Value == false
    ->  true
    ;   domain_error(json_projection_scalar, Value)
    ).

store_specs([], _, _, []).
store_specs([projection_spec(Predicate, Arguments, Statement, Quality)|Rest],
            MemoryId, At, [ProjectionId|Ids]) :-
    new_id(proj, ProjectionId),
    storage_put_projection(ProjectionId, MemoryId, Predicate, Arguments,
                           Statement, Quality, active, At),
    store_specs(Rest, MemoryId, At, Ids).

prior_request(MemoryId, RequestId, Event) :-
    storage_projection_event(Id, MemoryId, Generation, ready, Payload, Principal, At),
    get_dict(request_id, Payload, RequestId),
    !,
    event_json(Id, MemoryId, Generation, ready, Payload, Principal, At, Event).

check_generation(MemoryId, Options) :-
    (   get_dict(expected_generation, Options, Expected)
    ->  must_be(nonneg, Expected),
        latest_generation(MemoryId, Actual),
        (Expected =:= Actual -> true
        ; throw(error(projection_generation_conflict(Expected, Actual), _)))
    ;   true
    ).

append_event(MemoryId, State, Payload, Principal, Namespace, Capability, Result) :-
    latest_generation(MemoryId, Previous),
    Generation is Previous + 1,
    new_id(pevt, EventId),
    now_iso8601(At),
    storage_put_projection_event(EventId, MemoryId, Generation, State, Payload,
                                 Principal, At),
    storage_put_audit(EventId, At, Principal, memory_projection, Namespace,
                      MemoryId, Payload, Capability, Previous, Generation),
    event_json(EventId, MemoryId, Generation, State, Payload, Principal, At, Event),
    receipt(Event, State, Result).

receipt(Event, Status, Result) :-
    current_generation(Event.memory_id, Current, CurrentIds, CurrentState),
    (Event.generation =:= Current, CurrentState == ready -> IsCurrent = true
    ; IsCurrent = false),
    Result = _{status:Status, event_id:Event.id, memory_id:Event.memory_id,
               generation:Event.generation, current_generation:Current,
               current_status:CurrentState, is_current:IsCurrent,
               projection_ids:Event.payload.projection_ids,
               current_projection_ids:CurrentIds, payload:Event.payload,
               model_calls:0}.

latest_generation(MemoryId, Generation) :-
    (aggregate_all(max(G), storage_projection_event(_, MemoryId, G, _, _, _, _), Max)
    -> Generation = Max ; Generation = 0).

% Failure/blocked attempts are history, not changes to the current support set.
current_generation(MemoryId, Generation, Ids, State) :-
    (   aggregate_all(max(G),
                      (storage_projection_event(_, MemoryId, G, S, _, _, _),
                       memberchk(S, [ready, withdrawn])), Latest)
    ->  storage_projection_event(_, MemoryId, Latest, State, Payload, _, _),
        Generation = Latest,
        Ids = Payload.projection_ids
    ;   Generation = 0,
        findall(Id, storage_projection(Id, MemoryId, _, _, _, _, active, _), Ids),
        (Ids == [] -> State = absent ; State = ready)
    ).

% Called under the public API's storage snapshot mutex.
projection_is_current(MemoryId, ProjectionId) :-
    current_generation(MemoryId, _, Ids, ready),
    memberchk(ProjectionId, Ids).

projection_metadata(MemoryId, ProjectionId, Metadata) :-
    (   storage_projection_event(_, MemoryId, Generation, ready, Payload, _, _),
        memberchk(ProjectionId, Payload.projection_ids)
    ->  Metadata = _{generation:Generation, schema:Payload.schema,
                      source_hash:Payload.source_hash,
                      source_trust:Payload.source_trust,
                      interpretation_trust:Payload.interpretation_trust,
                      interpretation_provenance:Payload.interpretation_provenance,
                      compiler_fingerprint:Payload.compiler_fingerprint,
                      origin:caller_supplied, model_calls:0}
    ;   Metadata = _{generation:0, schema:"typed_projection_v1",
                      interpretation_trust:unknown, origin:legacy,
                      compiler_fingerprint:"unknown", model_calls:0}
    ).

status_locked(MemoryId, Result) :-
    latest_generation(MemoryId, Latest),
    current_generation(MemoryId, Current, Ids, CurrentState),
    (   Latest > 0
    ->  storage_projection_event(_, MemoryId, Latest, State, _, _, _)
    ;   State = CurrentState
    ),
    (Current =:= 0, Ids \== [] -> Legacy = true ; Legacy = false),
    Result = _{memory_id:MemoryId, status:State, latest_generation:Latest,
               current_generation:Current, current_status:CurrentState,
               projection_ids:Ids, legacy_projection:Legacy, model_calls:0}.

history_locked(Context, MemoryId, Limit, After, Result) :-
    read_source(Context, MemoryId, _, _, _, _, _),
    Probe is Limit + 1,
    once(findnsols(Probe, Event,
                  (storage_projection_event(Id, MemoryId, G, State, Payload, Principal, At),
                   G > After,
                   history_event(Id, MemoryId, G, State, Payload, Principal, At, Event)),
                  Found)),
    bounded_page(Found, Limit, Events, HasMore),
    (Events == [] -> Next = After ; last(Events, Last), Next = Last.generation),
    Result = _{memory_id:MemoryId, events:Events, has_more:HasMore,
               next_after_generation:Next, limit:Limit, model_calls:0}.

history_event(Id, MemoryId, Generation, State, Payload, Principal, At, Result) :-
    event_json(Id, MemoryId, Generation, State, Payload, Principal, At, Event),
    maplist(historical_projection(MemoryId), Payload.projection_ids, Projections),
    put_dict(projections, Event, Projections, Result).

historical_projection(MemoryId, ProjectionId, Json) :-
    (   storage_projection(ProjectionId, MemoryId, Predicate, Arguments,
                          Statement, Quality, Lifecycle, CreatedAt)
    ->  projection_json(ProjectionId, Predicate, Arguments, Statement,
                        Quality, Lifecycle, CreatedAt, Json)
    ;   throw(error(existence_error(memory_projection, ProjectionId), _))
    ).

event_json(Id, MemoryId, Generation, State, Payload, Principal, At,
           projection_event{id:Id, memory_id:MemoryId, generation:Generation,
                            state:State, payload:Payload, principal:Principal,
                            created_at:At}).

withdraw_locked(Context, MemoryId, Options, Reason, Result) :-
    read_source(Context, MemoryId, Namespace, SourceId, Text, SourceTrust, Principal),
    authorize_write(Context, Namespace, Capability),
    check_generation(MemoryId, Options),
    current_generation(MemoryId, Current, Ids, _),
    (   Ids == []
    ->  status_locked(MemoryId, Status),
        put_dict(status, Status, already_absent, Result)
    ;   crypto_data_hash(Text, Hash, [algorithm(sha256), encoding(utf8)]),
        Payload = projection_metadata{source_id:SourceId, source_hash:Hash,
                                      source_trust:SourceTrust, reason:Reason,
                                      withdrawn_generation:Current,
                                      withdrawn_projection_ids:Ids,
                                      projection_ids:[], model_calls:0},
        append_event(MemoryId, withdrawn, Payload, Principal, Namespace, Capability, Result)
    ).

page_options(Options, Limit, After) :-
    (get_dict(limit, Options, Limit) -> true ; Limit = 20),
    must_be(integer, Limit),
    (between(1, 200, Limit) -> true ; domain_error(projection_history_limit, Limit)),
    (get_dict(after_generation, Options, After) -> true ; After = 0),
    must_be(nonneg, After).

bounded_page(Found, Limit, Page, HasMore) :-
    length(Found, Count),
    (Count > Limit -> length(Page, Limit), append(Page, [_], Found), HasMore = true
    ; Page = Found, HasMore = false).

required(Dict, Key, Value) :-
    (get_dict(Key, Dict, Value) -> true
    ; throw(error(existence_error(projection_option, Key), _))).

option_text(Options, Key, Default, Max, Text) :-
    (get_dict(Key, Options, Raw) -> true ; Raw = Default),
    bounded_text(Raw, Max, Text).

bounded_text(Raw, Max, Text) :-
    (string(Raw) -> Text = Raw
    ; atom(Raw) -> atom_string(Raw, Text)
    ; type_error(text, Raw)),
    string_length(Text, Length),
    (between(1, Max, Length) -> true ; domain_error(bounded_text(Max), Length)).

clip_text(Text, Max, Clipped) :-
    string_length(Text, Length),
    (Length =< Max -> Clipped = Text ; sub_string(Text, 0, Max, _, Clipped)).
