:- module(symbolic_memory_storage,
          [ storage_open/1,
            storage_close/0,
            storage_transaction/1,
            storage_snapshot/1,
            storage_project_by_id/4,
            storage_project_by_remote/4,
            storage_project_by_path/4,
            storage_put_project/4,
            storage_put_source/6,
            storage_put_memory/8,
            storage_put_projection/8,
            storage_put_projection_event/7,
            storage_put_audit/10,
            storage_get_memory/8,
            storage_get_source/6,
            storage_projection/8,
            storage_projection_event/7,
            storage_audit_for_target/2,
            storage_counts/4
          ]).

:- use_module(library(aggregate)).
:- use_module(library(error)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(uuid)).

:- meta_predicate storage_transaction(0).
:- meta_predicate storage_snapshot(0).

:- dynamic storage_path/1.
:- dynamic stored_project/4.
:- dynamic stored_source/6.
:- dynamic stored_memory/8.
:- dynamic stored_projection/8.
:- dynamic stored_projection_event/7.
:- dynamic stored_audit/10.

storage_format_version(3).

storage_open(Config) :-
    must_be(dict, Config),
    get_dict(path, Config, Path0),
    normalize_path(Path0, Path),
    with_mutex(symbolic_memory_storage,
               open_locked(Path)).

storage_close :-
    with_mutex(symbolic_memory_storage,
               clear_runtime_state).

storage_transaction(Goal) :-
    with_mutex(symbolic_memory_storage,
               ( ensure_open,
                 transaction_locked(Goal)
               )).

storage_snapshot(Goal) :-
    with_mutex(symbolic_memory_storage,
               ( ensure_open,
                 call(Goal)
               )).

storage_project_by_id(Id, Remote, Aliases, CreatedAt) :-
    ensure_open,
    stored_project(Id, Remote, Aliases, CreatedAt).

storage_project_by_remote(Remote, Id, Aliases, CreatedAt) :-
    ensure_open,
    stored_project(Id, Remote, Aliases, CreatedAt).

storage_project_by_path(Path, Id, Remote, CreatedAt) :-
    ensure_open,
    stored_project(Id, Remote, Aliases, CreatedAt),
    memberchk(Path, Aliases).

storage_put_project(Id, Remote, Aliases, CreatedAt) :-
    must_be(atom, Id),
    must_be(list, Aliases),
    assertz(stored_project(Id, Remote, Aliases, CreatedAt)).

storage_put_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt) :-
    must_be(atom, SourceId),
    must_be(string, Text),
    assertz(stored_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt)).

storage_put_memory(MemoryId, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt) :-
    must_be(atom, MemoryId),
    must_be(atom, SourceId),
    assertz(stored_memory(MemoryId, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt)).

storage_put_projection(ProjectionId, MemoryId, Predicate, Arguments,
                       Statement, Quality, Lifecycle, CreatedAt) :-
    must_be(atom, ProjectionId),
    must_be(atom, MemoryId),
    must_be(string, Predicate),
    must_be(list, Arguments),
    must_be(string, Statement),
    assertz(stored_projection(ProjectionId, MemoryId, Predicate, Arguments,
                              Statement, Quality, Lifecycle, CreatedAt)).

storage_put_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At) :-
    must_be(atom, Id),
    must_be(atom, MemoryId),
    must_be(positive_integer, Generation),
    must_be(atom, State),
    must_be(atom, Principal),
    must_be(dict, Payload),
    (memberchk(State, [ready, failed, blocked_untrusted, withdrawn]) -> true
    ; domain_error(projection_event_state, State)),
    (stored_projection_event(Id, _, _, _, _, _, _) ->
        permission_error(replace, projection_event, Id)
    ; true),
    (aggregate_all(max(G), stored_projection_event(_, MemoryId, G, _, _, _, _), Last)
    -> Expected is Last + 1 ; Expected = 1),
    (Generation =:= Expected -> true
    ; domain_error(projection_event_generation(Expected), Generation)),
    (stored_memory(MemoryId, _, _, _, _, _, _, _) -> true
    ; existence_error(memory, MemoryId)),
    (get_dict(projection_ids, Payload, ProjectionIds) -> true
    ; existence_error(projection_event_field, projection_ids)),
    must_be(list, ProjectionIds),
    (((State == ready, ProjectionIds = [_|_]) ; (State \== ready, ProjectionIds == []))
     -> true ; domain_error(projection_event_payload, Payload)),
    sort(ProjectionIds, UniqueIds),
    length(ProjectionIds, Count),
    (length(UniqueIds, Count) -> true ; domain_error(unique_projection_ids, ProjectionIds)),
    maplist(projection_belongs_to(MemoryId), ProjectionIds),
    assertz(stored_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At)).

projection_belongs_to(MemoryId, ProjectionId) :-
    must_be(atom, ProjectionId),
    (stored_projection(ProjectionId, MemoryId, _, _, _, _, _, _) -> true
    ; existence_error(memory_projection, ProjectionId)).

storage_put_audit(EventId, At, Principal, Action, Namespace, TargetId,
                  Provenance, Capability, PreviousVersion, NewVersion) :-
    must_be(atom, EventId),
    assertz(stored_audit(EventId, At, Principal, Action, Namespace, TargetId,
                         Provenance, Capability, PreviousVersion, NewVersion)).

storage_get_memory(MemoryId, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt) :-
    ensure_open,
    stored_memory(MemoryId, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt).

storage_get_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt) :-
    ensure_open,
    stored_source(SourceId, Text, Provenance, Principal, Trust, CreatedAt).

storage_projection(ProjectionId, MemoryId, Predicate, Arguments,
                   Statement, Quality, Lifecycle, CreatedAt) :-
    ensure_open,
    stored_projection(ProjectionId, MemoryId, Predicate, Arguments,
                      Statement, Quality, Lifecycle, CreatedAt).

storage_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At) :-
    ensure_open,
    stored_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At).

storage_audit_for_target(TargetId, Events) :-
    storage_snapshot(
        findall(audit(EventId, At, Principal, Action, Namespace, TargetId,
                      Provenance, Capability, PreviousVersion, NewVersion),
                stored_audit(EventId, At, Principal, Action, Namespace, TargetId,
                             Provenance, Capability, PreviousVersion, NewVersion),
                Events)
    ).

storage_counts(Projects, Sources, Memories, Audits) :-
    storage_snapshot(
        ( aggregate_all(count, stored_project(_, _, _, _), Projects),
          aggregate_all(count, stored_source(_, _, _, _, _, _), Sources),
          aggregate_all(count, stored_memory(_, _, _, _, _, _, _, _), Memories),
          aggregate_all(count, stored_audit(_, _, _, _, _, _, _, _, _, _), Audits)
        )
    ).

open_locked(Path) :-
    (   storage_path(Path)
    ->  true
    ;   clear_runtime_state,
        file_directory_name(Path, Dir),
        make_directory_path(Dir),
        assertz(storage_path(Path)),
        catch((load_snapshot(Path) -> true
              ; throw(error(domain_error(symbolic_memory_snapshot, Path), _))),
              Error,
              ( clear_runtime_state,
                throw(Error)
              ))
    ).

transaction_locked(Goal) :-
    snapshot_state(OldState),
    (   catch(( transaction(once(Goal)), persist_state ),
              Error,
              ( restore_state(OldState), throw(Error) ))
    ->  true
    ;   restore_state(OldState),
        fail
    ).

persist_state :-
    storage_path(Path),
    snapshot_state(State),
    file_directory_name(Path, Dir),
    uuid(UUID),
    atomic_list_concat([Dir, '/.symbolic-memory-', UUID, '.tmp'], Tmp),
    catch(setup_call_cleanup(
              open(Tmp, write, Stream, [encoding(utf8)]),
              ( write_term(Stream, State,
                           [ quoted(true),
                             fullstop(true),
                             nl(true)
                           ]),
                flush_output(Stream)
              ),
              close(Stream)),
          Error,
          ( delete_if_exists(Tmp),
            throw(Error)
          )),
    catch(rename_file(Tmp, Path),
          Error,
          ( delete_if_exists(Tmp),
            throw(Error)
          )).

load_snapshot(Path) :-
    (   exists_file(Path)
    ->  setup_call_cleanup(
            open(Path, read, Stream, [encoding(utf8)]),
            (read_term(Stream, State, []), read_term(Stream, Tail, [])),
            close(Stream)),
        (Tail == end_of_file -> true
        ; throw(error(domain_error(snapshot_trailing_data, Tail), _))),
        load_state_term(State)
    ;   true
    ).

load_state_term(end_of_file) :- !.
load_state_term(snapshot(1, Projects, Sources, Memories, Audits)) :-
    !,
    restore_state(snapshot(3, Projects, Sources, Memories, [], [], Audits)).
load_state_term(snapshot(2, Projects, Sources, Memories, Projections, Audits)) :-
    !,
    restore_state(snapshot(3, Projects, Sources, Memories, Projections, [], Audits)).
load_state_term(snapshot(Version, Projects, Sources, Memories, Projections, Events, Audits)) :-
    !,
    storage_format_version(Expected),
    (   Version == Expected
    ->  restore_state(snapshot(Version, Projects, Sources, Memories, Projections, Events, Audits))
    ;   throw(error(domain_error(storage_format_version, Version),
                    context(expected, Expected)))
    ).
load_state_term(State) :-
    compound(State),
    compound_name_arity(State, snapshot, _),
    arg(1, State, Version),
    !,
    storage_format_version(Expected),
    throw(error(domain_error(storage_format_version, Version),
                context(expected, Expected))).
load_state_term(State) :-
    throw(error(domain_error(symbolic_memory_snapshot, State), _)).

snapshot_state(snapshot(Version, Projects, Sources, Memories, Projections, Events, Audits)) :-
    storage_format_version(Version),
    findall(project(Id, Remote, Aliases, CreatedAt),
            stored_project(Id, Remote, Aliases, CreatedAt),
            Projects),
    findall(source(Id, Text, Provenance, Principal, Trust, CreatedAt),
            stored_source(Id, Text, Provenance, Principal, Trust, CreatedAt),
            Sources),
    findall(memory(Id, SourceId, Namespace, Lifetime, Kind, RecordVersion, Lifecycle, CreatedAt),
            stored_memory(Id, SourceId, Namespace, Lifetime, Kind, RecordVersion, Lifecycle, CreatedAt),
            Memories),
    findall(projection(Id, MemoryId, Predicate, Arguments, Statement,
                       Quality, Lifecycle, CreatedAt),
            stored_projection(Id, MemoryId, Predicate, Arguments, Statement,
                              Quality, Lifecycle, CreatedAt),
            Projections),
    findall(projection_event(Id, MemoryId, Generation, State, Payload, Principal, At),
            stored_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At),
            Events),
    findall(audit(EventId, At, Principal, Action, Namespace, TargetId,
                  Provenance, Capability, PreviousVersion, NewVersion),
            stored_audit(EventId, At, Principal, Action, Namespace, TargetId,
                         Provenance, Capability, PreviousVersion, NewVersion),
            Audits).

restore_state(snapshot(Version, Projects, Sources, Memories, Projections, Events, Audits)) :-
    storage_format_version(Version),
    maplist(must_be(list), [Projects, Sources, Memories, Projections, Events, Audits]),
    retractall(stored_project(_, _, _, _)),
    retractall(stored_source(_, _, _, _, _, _)),
    retractall(stored_memory(_, _, _, _, _, _, _, _)),
    retractall(stored_projection(_, _, _, _, _, _, _, _)),
    retractall(stored_projection_event(_, _, _, _, _, _, _)),
    retractall(stored_audit(_, _, _, _, _, _, _, _, _, _)),
    maplist(assert_project, Projects),
    maplist(assert_source, Sources),
    maplist(assert_memory, Memories),
    maplist(assert_projection, Projections),
    maplist(assert_projection_event, Events),
    maplist(assert_audit, Audits).

assert_project(project(Id, Remote, Aliases, CreatedAt)) :-
    assertz(stored_project(Id, Remote, Aliases, CreatedAt)).

assert_source(source(Id, Text, Provenance, Principal, Trust, CreatedAt)) :-
    assertz(stored_source(Id, Text, Provenance, Principal, Trust, CreatedAt)).

assert_memory(memory(Id, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt)) :-
    assertz(stored_memory(Id, SourceId, Namespace, Lifetime, Kind, Version, Lifecycle, CreatedAt)).

assert_projection(projection(Id, MemoryId, Predicate, Arguments, Statement,
                             Quality, Lifecycle, CreatedAt)) :-
    assertz(stored_projection(Id, MemoryId, Predicate, Arguments, Statement,
                              Quality, Lifecycle, CreatedAt)).

assert_projection_event(projection_event(Id, MemoryId, Generation, State, Payload, Principal, At)) :-
    storage_put_projection_event(Id, MemoryId, Generation, State, Payload, Principal, At).

assert_audit(audit(EventId, At, Principal, Action, Namespace, TargetId,
                   Provenance, Capability, PreviousVersion, NewVersion)) :-
    assertz(stored_audit(EventId, At, Principal, Action, Namespace, TargetId,
                         Provenance, Capability, PreviousVersion, NewVersion)).

clear_runtime_state :-
    retractall(storage_path(_)),
    retractall(stored_project(_, _, _, _)),
    retractall(stored_source(_, _, _, _, _, _)),
    retractall(stored_memory(_, _, _, _, _, _, _, _)),
    retractall(stored_projection(_, _, _, _, _, _, _, _)),
    retractall(stored_projection_event(_, _, _, _, _, _, _)),
    retractall(stored_audit(_, _, _, _, _, _, _, _, _, _)).

ensure_open :-
    (   storage_path(_)
    ->  true
    ;   throw(error(existence_error(storage, symbolic_memory), _))
    ).

normalize_path(Path0, Path) :-
    (   atom(Path0)
    ->  Path = Path0
    ;   string(Path0)
    ->  atom_string(Path, Path0)
    ;   type_error(text, Path0)
    ).

delete_if_exists(Path) :-
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).
