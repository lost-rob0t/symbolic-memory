:- module(symbolic_memory_preferences,
          [ preference_observe/4,
            preference_patterns/3
          ]).

:- use_module(library(error)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(symbolic_memory_namespace).
:- use_module(symbolic_memory_policy).
:- use_module(symbolic_memory_storage).

preference_observe(Context, Observation0, Options0, Result) :-
    must_be(dict, Context),
    must_be(dict, Observation0),
    must_be(dict, Options0),
    normalize_observation(Observation0, Observation),
    preference_json(Observation, SourceText),
    put_dict(kind, Options0, preference, Options),
    symbolic_memory:memory_remember(Context, SourceText, Options, Stored),
    put_dict(observation, Stored, Observation, Result).

preference_patterns(Context, Query0, Result) :-
    must_be(dict, Context),
    must_be(dict, Query0),
    authorize_read(Context, global),
    normalize_query(Query0, Query),
    storage_preference_records(Records),
    findall(Observation,
            visible_matching_observation(Context, Query, Records, Observation),
            Observations),
    length(Observations, Matched),
    aggregate_items(Observations, Stats0),
    get_dict(min_observations, Query, MinObservations),
    include(minimum_support(MinObservations), Stats0, Stats),
    total_positive(Stats0, TotalPositive),
    maplist(stat_pattern(TotalPositive), Stats, Patterns0),
    order_patterns(Patterns0, Ordered),
    get_dict(limit, Query, Limit),
    take(Limit, Ordered, Patterns),
    Result = _{ status:ok,
                matched_observations:Matched,
                patterns:Patterns
              }.

normalize_observation(Input, Observation) :-
    required_bounded_text(Input, domain, 64, Domain),
    required_bounded_text(Input, item, 256, Item),
    (   get_dict(signal, Input, Signal0)
    ->  normalize_signal(Signal0, Signal)
    ;   Signal = selected
    ),
    optional_bounded_text(Input, provider, 128, Provider),
    optional_bounded_text(Input, merchant, 256, Merchant),
    (   get_dict(context, Input, Context0)
    ->  normalize_context(Context0, Context)
    ;   Context = _{}
    ),
    Observation = _{ schema:"preference-observation/1",
                     domain:Domain,
                     item:Item,
                     signal:Signal,
                     provider:Provider,
                     merchant:Merchant,
                     context:Context
                   }.

normalize_query(Input, Query) :-
    (   get_dict(domain, Input, Domain0)
    ->  bounded_text(Domain0, domain, 64, Domain)
    ;   Domain = ""
    ),
    (   get_dict(provider, Input, Provider0)
    ->  bounded_text(Provider0, provider, 128, Provider)
    ;   Provider = ""
    ),
    (   get_dict(context, Input, Context0)
    ->  normalize_context(Context0, Context)
    ;   Context = _{}
    ),
    bounded_integer_option(Input, min_observations, 2, 1, 1000, MinObservations),
    bounded_integer_option(Input, limit, 10, 1, 100, Limit),
    Query = _{ domain:Domain,
               provider:Provider,
               context:Context,
               min_observations:MinObservations,
               limit:Limit
             }.

visible_matching_observation(Context, Query, Records, Observation) :-
    member(preference(_MemoryId, _SourceId, Namespace, _CreatedAt, SourceText), Records),
    context_can_see_namespace(Context, Namespace),
    catch(preference_from_json(SourceText, Observation), _, fail),
    observation_matches(Query, Observation).

observation_matches(Query, Observation) :-
    get_dict(domain, Query, DomainFilter),
    ( DomainFilter == "" ; get_dict(domain, Observation, DomainFilter) ),
    get_dict(provider, Query, ProviderFilter),
    ( ProviderFilter == "" ; get_dict(provider, Observation, ProviderFilter) ),
    get_dict(context, Query, ContextFilter),
    get_dict(context, Observation, ObservationContext),
    context_subset(ContextFilter, ObservationContext).

context_subset(Filter, Context) :-
    dict_pairs(Filter, _, Pairs),
    forall(member(Key-Expected, Pairs),
           ( get_dict(Key, Context, Actual),
             Actual == Expected
           )).

aggregate_items(Observations, Stats) :-
    foldl(accumulate_observation, Observations, [], Stats).

accumulate_observation(Observation, In, Out) :-
    get_dict(domain, Observation, Domain),
    get_dict(item, Observation, Item),
    get_dict(signal, Observation, Signal),
    signal_counts(Signal, PositiveDelta, NegativeDelta),
    update_stat(Domain, Item, PositiveDelta, NegativeDelta, In, Out).

update_stat(Domain, Item, PositiveDelta, NegativeDelta, [], 
            [stat(Domain, Item, PositiveDelta, NegativeDelta)]).
update_stat(Domain, Item, PositiveDelta, NegativeDelta,
            [stat(Domain, Item, Positive, Negative)|Rest],
            [stat(Domain, Item, NewPositive, NewNegative)|Rest]) :-
    !,
    NewPositive is Positive + PositiveDelta,
    NewNegative is Negative + NegativeDelta.
update_stat(Domain, Item, PositiveDelta, NegativeDelta, [Head|Rest], [Head|Updated]) :-
    update_stat(Domain, Item, PositiveDelta, NegativeDelta, Rest, Updated).

signal_counts(selected, 1, 0).
signal_counts(ordered, 1, 0).
signal_counts(purchased, 1, 0).
signal_counts(liked, 1, 0).
signal_counts(repeated, 1, 0).
signal_counts(chosen, 1, 0).
signal_counts(disliked, 0, 1).
signal_counts(rejected, 0, 1).
signal_counts(avoided, 0, 1).

minimum_support(Minimum, stat(_, _, Positive, Negative)) :-
    Support is Positive + Negative,
    Support >= Minimum.

total_positive(Stats, Total) :-
    foldl(add_positive, Stats, 0, Total).

add_positive(stat(_, _, Positive, _), In, Out) :-
    Out is In + Positive.

stat_pattern(TotalPositive, stat(Domain, Item, Positive, Negative), Pattern) :-
    Observations is Positive + Negative,
    (   Observations =:= 0
    ->  PreferenceRatio = 0.0
    ;   PreferenceRatio is Positive / Observations
    ),
    (   TotalPositive =:= 0
    ->  PositiveShare = 0.0
    ;   PositiveShare is Positive / TotalPositive
    ),
    Pattern = _{ domain:Domain,
                 item:Item,
                 observations:Observations,
                 positive_count:Positive,
                 negative_count:Negative,
                 preference_ratio:PreferenceRatio,
                 confidence:PreferenceRatio,
                 positive_share:PositiveShare
               }.

order_patterns(Patterns, Ordered) :-
    map_list_to_pairs(pattern_sort_key, Patterns, Keyed),
    keysort(Keyed, Sorted),
    pairs_values(Sorted, Ordered).

pattern_sort_key(Pattern, Key) :-
    get_dict(positive_count, Pattern, Positive),
    get_dict(observations, Pattern, Observations),
    get_dict(item, Pattern, Item),
    NegativePositive is -Positive,
    NegativeObservations is -Observations,
    Key = NegativePositive-NegativeObservations-Item.

take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [Head|Rest], [Head|Taken]) :-
    N > 0,
    Next is N - 1,
    take(Next, Rest, Taken).

preference_json(Observation, Text) :-
    with_output_to(string(Text),
                   json_write_dict(current_output, Observation, [width(0)])).

preference_from_json(Text, Observation) :-
    atom_json_dict(Text, Raw, [value_string_as(string)]),
    get_dict(schema, Raw, "preference-observation/1"),
    normalize_observation(Raw, Observation).

required_bounded_text(Dict, Key, Limit, Text) :-
    (   get_dict(Key, Dict, Value)
    ->  bounded_text(Value, Key, Limit, Text)
    ;   throw(error(existence_error(preference_field, Key), _))
    ).

optional_bounded_text(Dict, Key, Limit, Text) :-
    (   get_dict(Key, Dict, Value)
    ->  bounded_text(Value, Key, Limit, Text)
    ;   Text = ""
    ).

bounded_text(Value, Name, Limit, Text) :-
    normalize_text(Value, Text),
    string_length(Text, Length),
    (   Length > 0,
        Length =< Limit
    ->  true
    ;   domain_error(preference_text(Name, Limit), Value)
    ).

normalize_signal(Value, Signal) :-
    normalize_atom(Value, Signal0),
    (   signal_counts(Signal0, _, _)
    ->  Signal = Signal0
    ;   domain_error(preference_signal, Signal0)
    ).

normalize_context(Value, Context) :-
    must_be(dict, Value),
    dict_pairs(Value, _, Pairs),
    length(Pairs, Count),
    ( Count =< 16 -> true ; domain_error(preference_context_size, Count) ),
    maplist(normalize_context_pair, Pairs, Normalized),
    dict_pairs(Context, _, Normalized).

normalize_context_pair(Key-Value, Key-Text) :-
    atom(Key),
    atom_length(Key, KeyLength),
    ( KeyLength > 0, KeyLength =< 64 -> true ; domain_error(preference_context_key, Key) ),
    bounded_text(Value, Key, 256, Text).

bounded_integer_option(Dict, Key, Default, Minimum, Maximum, Value) :-
    ( get_dict(Key, Dict, Raw) -> true ; Raw = Default ),
    (   integer(Raw),
        Raw >= Minimum,
        Raw =< Maximum
    ->  Value = Raw
    ;   domain_error(preference_integer(Key, Minimum, Maximum), Raw)
    ).

normalize_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   type_error(text, Value)
    ).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).
