:- module(symbolic_memory_namespace,
          [ resolve_write_namespace/3,
            context_can_see_namespace/2,
            namespace_json/2,
            normalize_remote/2
          ]).

:- use_module(library(error)).
:- use_module(symbolic_memory_storage).
:- use_module(symbolic_memory_util).

resolve_write_namespace(Context, Options, Namespace) :-
    must_be(dict, Context),
    must_be(dict, Options),
    requested_scope(Options, Scope),
    resolve_scope(Scope, Context, Namespace).

context_can_see_namespace(_, global).
context_can_see_namespace(Context, session(SessionId)) :-
    context_session_id(Context, Current),
    Current == SessionId.
context_can_see_namespace(Context, project(ProjectId)) :-
    resolve_existing_project(Context, CurrentProject),
    CurrentProject == ProjectId.

namespace_json(global, _{type:global}).
namespace_json(session(SessionId), _{type:session, id:SessionId}).
namespace_json(project(ProjectId), _{type:project, id:ProjectId}).

requested_scope(Options, Scope) :-
    (   get_dict(scope, Options, Raw)
    ->  normalize_atom(Raw, Scope)
    ;   Scope = auto
    ).

resolve_scope(global, _, global) :- !.
resolve_scope(session, Context, session(SessionId)) :-
    !,
    context_session_id(Context, SessionId).
resolve_scope(project, Context, project(ProjectId)) :-
    !,
    resolve_project_for_write(Context, ProjectId).
resolve_scope(auto, Context, Namespace) :-
    !,
    (   has_project_hints(Context)
    ->  resolve_project_for_write(Context, ProjectId),
        Namespace = project(ProjectId)
    ;   context_session_id(Context, SessionId)
    ->  Namespace = session(SessionId)
    ;   throw(error(existence_error(memory_namespace, context), _))
    ).
resolve_scope(Scope, _, _) :-
    domain_error(memory_scope, Scope).

resolve_project_for_write(Context, ProjectId) :-
    project_hints(Context, Hints),
    (   get_dict(id, Hints, Explicit0)
    ->  normalize_atom(Explicit0, Explicit),
        (   storage_project_by_id(Explicit, _, _, _)
        ->  ProjectId = Explicit
        ;   throw(error(existence_error(project, Explicit), _))
        )
    ;   get_dict(remote, Hints, Remote0)
    ->  normalize_remote(Remote0, Remote),
        (   storage_project_by_remote(Remote, Existing, _, _)
        ->  ProjectId = Existing
        ;   create_project(Hints, Remote, ProjectId)
        )
    ;   get_dict(path, Hints, Path0)
    ->  normalize_text(Path0, Path),
        (   storage_project_by_path(Path, Existing, _, _)
        ->  ProjectId = Existing
        ;   throw(error(existence_error(project_namespace, Path), _))
        )
    ;   throw(error(existence_error(memory_namespace, project_context), _))
    ).

resolve_existing_project(Context, ProjectId) :-
    project_hints(Context, Hints),
    (   get_dict(id, Hints, Explicit0)
    ->  normalize_atom(Explicit0, Explicit),
        storage_project_by_id(Explicit, _, _, _),
        ProjectId = Explicit
    ;   get_dict(remote, Hints, Remote0)
    ->  normalize_remote(Remote0, Remote),
        storage_project_by_remote(Remote, ProjectId, _, _)
    ;   get_dict(path, Hints, Path0)
    ->  normalize_text(Path0, Path),
        storage_project_by_path(Path, ProjectId, _, _)
    ).

create_project(Hints, Remote, ProjectId) :-
    new_id(project, ProjectId),
    now_iso8601(CreatedAt),
    project_aliases(Hints, Aliases),
    storage_put_project(ProjectId, Remote, Aliases, CreatedAt).

project_aliases(Hints, Aliases) :-
    (   get_dict(path, Hints, Path0)
    ->  normalize_text(Path0, Path),
        Aliases = [Path]
    ;   Aliases = []
    ).

has_project_hints(Context) :-
    project_hints(Context, Hints),
    ( get_dict(id, Hints, _)
    ; get_dict(remote, Hints, _)
    ; get_dict(path, Hints, _)
    ),
    !.

project_hints(Context, Hints) :-
    get_dict(project, Context, Hints),
    must_be(dict, Hints).

context_session_id(Context, SessionId) :-
    get_dict(session_id, Context, Session0),
    normalize_atom(Session0, SessionId).

normalize_remote(Remote0, Normalized) :-
    normalize_text(Remote0, Remote1),
    normalize_git_ssh(Remote1, Remote2),
    strip_trailing_slash(Remote2, Remote3),
    strip_dot_git(Remote3, Normalized).

normalize_git_ssh(Input, Output) :-
    (   sub_string(Input, 0, 4, _, "git@"),
        split_string(Input, "@:", "", ["git", Host, Path])
    ->  format(string(Output), "https://~w/~w", [Host, Path])
    ;   Output = Input
    ).

strip_trailing_slash(Input, Output) :-
    (   string_concat(Core, "/", Input),
        Core \== ""
    ->  strip_trailing_slash(Core, Output)
    ;   Output = Input
    ).

strip_dot_git(Input, Output) :-
    (   string_concat(Core, ".git", Input)
    ->  Output = Core
    ;   Output = Input
    ).

normalize_text(Value, String) :-
    (   string(Value)
    ->  String = Value
    ;   atom(Value)
    ->  atom_string(Value, String)
    ;   type_error(text, Value)
    ).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).
