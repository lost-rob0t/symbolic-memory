:- module(symbolic_memory_lifecycle_mcp,
          [ lifecycle_tool/1, lifecycle_call_tool/4, lifecycle_tool_definitions/1 ]).

:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(symbolic_memory_lifecycle).

lifecycle_tool(memory_project).
lifecycle_tool(memory_projection_status).
lifecycle_tool(memory_projection_history).
lifecycle_tool(memory_projection_withdraw).

lifecycle_call_tool(Context, Name, Arguments, ToolResult) :-
    allowed_arguments(Name, Allowed),
    must_be(dict, Arguments),
    dict_pairs(Arguments, _, Pairs),
    maplist(allowed_pair(Allowed), Pairs),
    required_argument(Arguments, id, MemoryId),
    del_dict(id, Arguments, _, Options),
    invoke(Context, Name, MemoryId, Options, Result),
    (get_dict(status, Result, Status) -> true ; Status = complete),
    (Name == memory_project, memberchk(Status, [failed, blocked_untrusted])
    -> IsError = true ; IsError = false),
    format(string(Text), "~w: ~w", [Name, Status]),
    ToolResult = _{content:[_{type:"text", text:Text}],
                   structuredContent:Result, isError:IsError}.

invoke(Context, memory_project, Id, Options, Result) :-
    memory_project(Context, Id, Options, Result).
invoke(Context, memory_projection_status, Id, _, Result) :-
    memory_projection_status(Context, Id, Result).
invoke(Context, memory_projection_history, Id, Options, Result) :-
    memory_projection_history(Context, Id, Options, Result).
invoke(Context, memory_projection_withdraw, Id, Options, Result) :-
    memory_projection_withdraw(Context, Id, Options, Result).

allowed_arguments(memory_project,
                  [id, projections, compiler_fingerprint, request_id, expected_generation]).
allowed_arguments(memory_projection_status, [id]).
allowed_arguments(memory_projection_history, [id, limit, after_generation]).
allowed_arguments(memory_projection_withdraw, [id, reason, expected_generation]).

allowed_pair(Allowed, Key-_) :-
    (memberchk(Key, Allowed) -> true
    ; throw(error(domain_error(projection_tool_argument, Key), _))).

required_argument(Arguments, Key, Value) :-
    (get_dict(Key, Arguments, Value) -> true
    ; throw(error(existence_error(tool_argument, Key), _))).

lifecycle_tool_definitions(Tools) :-
    Id = _{type:"string", minLength:1, maxLength:256},
    Generation = _{type:"integer", minimum:0},
    Projection = _{type:"object",
                    properties:_{predicate:_{type:"string", minLength:1, maxLength:128},
                                 arguments:_{type:"array", maxItems:32,
                                             items:_{type:["string", "number", "boolean"]}},
                                 statement:_{type:"string", minLength:1, maxLength:8192},
                                 quality:_{type:"string", enum:["exact", "lossy", "context_required"]}},
                    required:["predicate", "arguments", "statement"],
                    additionalProperties:false},
    Tools = [
      _{name:"memory_project",
        description:"Admit caller-supplied inert projections for an already-durable source. Append an atomic generation with source hash, independent interpretation provenance, and idempotency receipt. This tool does not compile prose or execute Prolog.",
        inputSchema:_{type:"object",
                      properties:_{id:Id,
                                   projections:_{type:"array", minItems:1, maxItems:128, items:Projection},
                                   compiler_fingerprint:Id, request_id:Id,
                                   expected_generation:Generation},
                      required:["id", "projections"], additionalProperties:false}},
      _{name:"memory_projection_status",
        description:"Read the latest attempt and the independently current projection generation. Failed reprojection does not hide an earlier usable generation.",
        inputSchema:_{type:"object", properties:_{id:Id},
                      required:["id"], additionalProperties:false}},
      _{name:"memory_projection_history",
        description:"Page immutable projection attempts and withdrawals in generation order. Returns a cursor and explicit has_more; never returns another namespace's history.",
        inputSchema:_{type:"object",
                      properties:_{id:Id, limit:_{type:"integer", minimum:1, maximum:200},
                                   after_generation:Generation},
                      required:["id"], additionalProperties:false}},
      _{name:"memory_projection_withdraw",
        description:"Withdraw the current projection set with a reason, preserving exact source and history. Withdrawal is not negative evidence, deletion, or host authority.",
        inputSchema:_{type:"object",
                      properties:_{id:Id, reason:_{type:"string", minLength:1, maxLength:4096},
                                   expected_generation:Generation},
                      required:["id", "reason"], additionalProperties:false}}
    ].
