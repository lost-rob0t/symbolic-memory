:- begin_tests(preference_patterns).

:- use_module('../prolog/symbolic_memory').

preference_context(Capabilities, Context) :-
    Context = _{ principal:"tester",
                 capabilities:Capabilities,
                 source_class:tool_verified,
                 session_id:"session-pref",
                 project:_{remote:"https://example.test/preferences.git"}
               }.

new_preference_store(Path) :-
    tmp_file(symbolic_memory_preferences, Path),
    ( exists_file(Path) -> delete_file(Path) ; true ),
    memory_open(_{path:Path}).

cleanup_preference_store(Path) :-
    catch(memory_close, _, true),
    ( exists_file(Path) -> delete_file(Path) ; true ).

test(repeated_contextual_choices_become_ranked_patterns,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path))
     ]) :-
    preference_context([memory_read, memory_write_project], Context),
    Friday = _{weekday:"friday", daypart:"late_night"},
    memory_preference_observe(
        Context,
        _{domain:"food", item:"spicy chicken sandwich", signal:"selected",
          provider:"doordash", merchant:"Wendys", context:Friday},
        _{},
        _),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"spicy chicken sandwich", signal:"ordered",
          provider:"doordash", merchant:"Wendys", context:Friday},
        _{},
        _),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"pizza", signal:"selected",
          provider:"doordash", merchant:"Pizza Shop", context:Friday},
        _{},
        _),
    memory_preference_patterns(
        Context,
        _{domain:"food", provider:"doordash",
          context:_{daypart:"late_night"}, min_observations:2, limit:5},
        Result),
    get_dict(matched_observations, Result, 3),
    get_dict(patterns, Result, [Pattern]),
    get_dict(item, Pattern, "spicy chicken sandwich"),
    get_dict(positive_count, Pattern, 2),
    get_dict(negative_count, Pattern, 0),
    get_dict(preference_ratio, Pattern, 1.0),
    get_dict(positive_share, Pattern, Share),
    assertion(Share > 0.66),
    assertion(Share < 0.67).

test(patterns_are_domain_and_provider_scoped,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path))
     ]) :-
    preference_context([memory_read, memory_write_project], Context),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"tacos", signal:"selected", provider:"doordash"},
        _{},
        _),
    memory_preference_observe(
        Context,
        _{domain:"shopping", item:"usb-c cable", signal:"purchased", provider:"store"},
        _{},
        _),
    memory_preference_patterns(
        Context,
        _{domain:"food", provider:"doordash", min_observations:1},
        Result),
    get_dict(matched_observations, Result, 1),
    get_dict(patterns, Result, [Pattern]),
    get_dict(item, Pattern, "tacos").

test(negative_feedback_reduces_preference_ratio,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path))
     ]) :-
    preference_context([memory_read, memory_write_project], Context),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"ramen", signal:"selected"},
        _{},
        _),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"ramen", signal:"disliked"},
        _{},
        _),
    memory_preference_patterns(
        Context,
        _{domain:"food", min_observations:2},
        Result),
    get_dict(patterns, Result, [Pattern]),
    get_dict(positive_count, Pattern, 1),
    get_dict(negative_count, Pattern, 1),
    get_dict(preference_ratio, Pattern, 0.5).

test(preference_observe_preserves_authority_boundary,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path)),
       throws(error(permission_error(write, memory, project(_)), _))
     ]) :-
    preference_context([memory_read], Context),
    memory_preference_observe(
        Context,
        _{domain:"food", item:"nope", signal:"selected"},
        _{},
        _).

test(preference_patterns_require_read_authority,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path)),
       throws(error(permission_error(read, memory, _), _))
     ]) :-
    preference_context([memory_write_project], Writer),
    memory_preference_observe(
        Writer,
        _{domain:"food", item:"tacos", signal:"selected"},
        _{},
        _),
    preference_context([], Reader),
    memory_preference_patterns(Reader, _{domain:"food"}, _).

test(invalid_observation_fails_closed_without_partial_write,
     [ setup(new_preference_store(Path)),
       cleanup(cleanup_preference_store(Path))
     ]) :-
    preference_context([memory_read, memory_write_project], Context),
    catch(
        memory_preference_observe(
            Context,
            _{domain:"food", item:"x", signal:"maybe"},
            _{},
            _),
        Error,
        true),
    assertion(nonvar(Error)),
    memory_preference_patterns(
        Context,
        _{domain:"food", min_observations:1},
        Result),
    get_dict(matched_observations, Result, 0),
    get_dict(patterns, Result, []).

:- end_tests(preference_patterns).
