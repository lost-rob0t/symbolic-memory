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
            storage_put_audit/10,
            storage_get_memory/8,
            storage_get_source/6,
            storage_projection/8,
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
:- dynamic stored_audit/10.

storage_format_version(2).

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
    must_be(atom, Predicate),
    must_be(list, Arguments),
    must_be(string, Statement),
    assertz(stored_projection(ProjectionId, MemoryId, Predicate, Arguments,
                              Statement, Quality, Lifecycle, CreatedAt)).

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
        catch(load_snapshot(Path),
              Error,
              ( clear_runtime_state,
                throw(Error)
              ))
    ).

transaction_locked(Goal) :-
    snapshot_state(OldState),
    catch(( transaction(Goal),
            persist_state
          ),
          Error,
          ( restore_state(OldState),
            throw(Error)
          )).

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
            read_term(Stream, State, []),
            close(Stream)),
        load_state_term(State)
    ;   true
    ).

load_state_term(end_of_file) :- !.
load_state_term(snapshot(1, Projects, Sources, Memories, Audits)) :-
    !,
    restore_state(snapshot(2, Projects, Sources, Memories, [], Audits)).
load_state_term(snapshot(Version, Projects, Sources, Memories, Projections, Audits)) :-
    !,
    storage_format_version(Expected),
    (   Version == Expected
    ->  restore_state(snapshot(Version, Projects, Sources, Memories, Projections, Audits))
    ;   throw(error(domain_error(storage_format_version, Version),
                    context(expected, Expected)))
    ).
load_state_term(snapshot(Version, _, _, _, _)) :-
    !,
    storage_format_version(Expected),
    throw(error(domain_error(storage_format_version, Version),
                context(expected, Expected))).
load_state_term(State) :-
    throw(error(domain_error(symbolic_memory_snapshot, State), _)).

snapshot_state(snapshot(Version, Projects, Sources, Memories, Projections, Audits)) :-
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
    findall(audit(EventId, At, Principal, Action, Namespace, TargetId,
                  Provenance, Capability, PreviousVersion, NewVersion),
            stored_audit(EventId, At, Principal, Action, Namespace, TargetId,
                         Provenance, Capability, PreviousVersion, NewVersion),
            Audits).

restore_state(snapshot(Version, Projects, Sources, Memories, Projections, Audits)) :-
    storage_format_version(Version),
    retractall(stored_project(_, _, _, _)),
    retractall(stored_source(_, _, _, _, _, _)),
    retractall(stored_memory(_, _, _, _, _, _, _, _)),
    retractall(stored_projection(_, _, _, _, _, _, _, _)),
    retractall(stored_audit(_, _, _, _, _, _, _, _, _, _)),
    maplist(assert_project, Projects),
    maplist(assert_source, Sources),
    maplist(assert_memory, Memories),
    maplist(assert_projection, Projections),
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
