:- begin_tests(symbolic_memory_mcp_protocol).

:- use_module('../prolog/symbolic_memory_mcp').

context(_{principal:"protocol-test",
          capabilities:[memory_read],
          source_class:model_inferred,
          session_id:"protocol-session"}).

test(unsupported_protocol_returns_32022) :-
    context(Context),
    Request = _{ jsonrpc:"2.0",
                 id:"bad-version",
                 method:"tools/list",
                 params:_{ '_meta':_{ 'io.modelcontextprotocol/protocolVersion':"2099-01-01",
                                      'io.modelcontextprotocol/clientInfo':_{name:"test", version:"1"},
                                      'io.modelcontextprotocol/clientCapabilities':_{}
                                    }
                         }
               },
    mcp_handle(Context, Request, Response),
    get_dict(error, Response, Error),
    get_dict(code, Error, Code),
    assertion(Code == -32022),
    get_dict(data, Error, Data),
    get_dict(requested, Data, Requested),
    assertion(Requested == "2099-01-01"),
    get_dict(supported, Data, Supported),
    assertion(member("2026-07-28", Supported)).

test(legacy_initialize_remains_available) :-
    context(Context),
    Request = _{jsonrpc:"2.0", id:1, method:"initialize", params:_{}},
    mcp_handle(Context, Request, Response),
    get_dict(result, Response, Result),
    get_dict(protocolVersion, Result, Version),
    assertion(Version == "2025-11-25").

:- end_tests(symbolic_memory_mcp_protocol).
