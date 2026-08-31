:- module(symbolic_memory_mcp,
          [ main/0,
            mcp_handle/3
          ]).

:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(symbolic_memory).

:- initialization(main, main).

main :-
    host_config(Context, DatabasePath),
    setup_call_cleanup(
        memory_open(_{path:DatabasePath}),
        mcp_loop(Context),
        memory_close
    ).

mcp_loop(Context) :-
    json_read_dict(user_input, Request, [value_string_as(string)]),
    (   Request == end_of_file
    ->  true
    ;   catch(mcp_handle(Context, Request, Response),
              Error,
              rpc_exception_response(Request, Error, Response)),
        emit_response(Response),
        mcp_loop(Context)
    ).

mcp_handle(_, Request, Response) :-
    get_dict(method, Request, Method0),
    normalize_atom(Method0, initialize),
    !,
    request_id(Request, Id),
    Response = _{ jsonrpc:"2.0",
                  id:Id,
                  result:_{ protocolVersion:"2026-07-28",
                            capabilities:_{tools:_{}},
                            serverInfo:_{name:"symbolic-memory", version:"0.1.0"}
                          }
                }.
mcp_handle(_, Request, none) :-
    get_dict(method, Request, Method0),
    normalize_atom(Method0, 'notifications/initialized'),
    !.
mcp_handle(_, Request, Response) :-
    get_dict(method, Request, Method0),
    normalize_atom(Method0, 'tools/list'),
    !,
    request_id(Request, Id),
    tool_definitions(Tools),
    Response = _{jsonrpc:"2.0", id:Id, result:_{tools:Tools}}.
mcp_handle(Context, Request, Response) :-
    get_dict(method, Request, Method0),
    normalize_atom(Method0, 'tools/call'),
    !,
    request_id(Request, Id),
    get_dict(params, Request, Params),
    get_dict(name, Params, Name0),
    normalize_atom(Name0, Name),
    (   get_dict(arguments, Params, Arguments)
    ->  true
    ;   Arguments = _{}
    ),
    catch(call_tool(Context, Name, Arguments, ToolResult),
          Error,
          tool_error_result(Error, ToolResult)),
    Response = _{jsonrpc:"2.0", id:Id, result:ToolResult}.
mcp_handle(_, Request, Response) :-
    request_id(Request, Id),
    Response = _{ jsonrpc:"2.0",
                  id:Id,
                  error:_{code:(-32601), message:"Method not found"}
                }.

call_tool(Context, memory_remember, Arguments, ToolResult) :-
    get_dict(memory, Arguments, Memory),
    tool_options(Arguments, Options),
    memory_remember(Context, Memory, Options, Result),
    get_dict(id, Result, MemoryId),
    format(string(Text), "Stored memory ~w", [MemoryId]),
    ToolResult = _{ content:[_{type:"text", text:Text}],
                    structuredContent:Result,
                    isError:false
                  }.
call_tool(Context, memory_get, Arguments, ToolResult) :-
    get_dict(id, Arguments, MemoryId),
    memory_get(Context, MemoryId, Result),
    get_dict(source_text, Result, SourceText),
    ToolResult = _{ content:[_{type:"text", text:SourceText}],
                    structuredContent:Result,
                    isError:false
                  }.
call_tool(_, Name, _, _) :-
    throw(error(existence_error(memory_tool, Name), _)).

tool_options(Arguments, Options) :-
    copy_known_option(scope, Arguments, _{}, O1),
    copy_known_option(retention, Arguments, O1, O2),
    copy_known_option(kind, Arguments, O2, Options).

copy_known_option(Key, From, In, Out) :-
    (   get_dict(Key, From, Value)
    ->  put_dict(Key, In, Value, Out)
    ;   Out = In
    ).

tool_definitions([
    _{ name:"memory_remember",
       description:"Durably preserve exact source memory in the caller's authorized namespace.",
       inputSchema:_{ type:"object",
                      properties:_{ memory:_{type:"string"},
                                    scope:_{type:"string", enum:["project", "session", "global"]},
                                    retention:_{type:"string", enum:["long_term", "short_term", "session", "durable"]},
                                    kind:_{type:"string", enum:["auto", "text", "fact", "episode", "preference", "procedure"]}
                                  },
                      required:["memory"],
                      additionalProperties:false
                    }
     },
    _{ name:"memory_get",
       description:"Fetch one known memory by stable ID when the caller is authorized to read its namespace.",
       inputSchema:_{ type:"object",
                      properties:_{id:_{type:"string"}},
                      required:["id"],
                      additionalProperties:false
                    }
     }
]).

tool_error_result(Error, Result) :-
    term_string(Error, Message),
    Result = _{ content:[_{type:"text", text:Message}],
                isError:true
              }.

rpc_exception_response(Request, Error, Response) :-
    request_id(Request, Id),
    term_string(Error, Message),
    Response = _{ jsonrpc:"2.0",
                  id:Id,
                  error:_{code:(-32603), message:Message}
                }.

emit_response(none) :- !.
emit_response(Response) :-
    json_write_dict(current_output, Response, [width(0)]),
    nl,
    flush_output.

request_id(Request, Id) :-
    (   get_dict(id, Request, Id)
    ->  true
    ;   Id = @(null)
    ).

host_config(Context, DatabasePath) :-
    env_or_default('SYMBOLIC_MEMORY_DB', ".symbolic-memory.db", DatabasePath),
    env_or_default('SYMBOLIC_MEMORY_PRINCIPAL', "local_mcp", Principal),
    env_or_default('SYMBOLIC_MEMORY_SESSION_ID', "mcp-local", SessionId),
    env_or_default('SYMBOLIC_MEMORY_SOURCE_CLASS', "model_inferred", SourceClass),
    env_or_default('SYMBOLIC_MEMORY_CAPABILITIES',
                   "memory_read,memory_write_session,memory_write_project",
                   CapabilitiesText),
    split_string(CapabilitiesText, ",", " \t", CapabilityStrings),
    maplist(atom_string, Capabilities, CapabilityStrings),
    Base = _{ principal:Principal,
              session_id:SessionId,
              source_class:SourceClass,
              capabilities:Capabilities
            },
    (   getenv('SYMBOLIC_MEMORY_PROJECT_REMOTE', Remote),
        Remote \== ''
    ->  put_dict(project, Base, _{remote:Remote}, Context)
    ;   Context = Base
    ).

env_or_default(Name, Default, Value) :-
    (   getenv(Name, Found),
        Found \== ''
    ->  Value = Found
    ;   Value = Default
    ).

normalize_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ).
