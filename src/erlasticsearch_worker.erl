% TODO: Add periodic, off-line connection ping and repair attempt.
-module(erlasticsearch_worker).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([is_200/1]).
-export([is_200_or_201/1]).

-include("erlasticsearch.hrl").

-record(state, {
        binary_response = false :: boolean(),
        connection              :: connection(),
        connection_options = [] :: params(),
        pool_name               :: pool_name()
        }).

-type state() :: #state{}.

-type connection_error() ::
      closed
    | econnrefused
    .

-type thrift_call_error() ::
      {no_function, atom()}
    | {bad_args   , atom(), list()}
    | {bad_seq_id , integer()}
    % TODO: What else? Does it even matter? Would we ever handle these individualy?
    .

start_link(ConnectionOptions) ->
    gen_server:start_link(?MODULE, [?DEFAULT_POOL_NAME, ConnectionOptions], []).

init([PoolName, ConnectionOptions1]) ->
    process_flag(trap_exit, true),
    {DecodeResponse, ConnectionOptions2} =
        case lists:keytake(binary_response, 1, ConnectionOptions1) of
            {value, {binary_response, Decode}, Options1} ->
                {Decode, Options1};
            false ->
                {true, ConnectionOptions1}
        end,
    Connection = connection(ConnectionOptions2),
    {ok, #state{pool_name = PoolName,
                binary_response = DecodeResponse,
                connection_options = ConnectionOptions2,
                connection = Connection}}.

handle_call({stop}, _From, State) ->
    thrift_client:close(State#state.connection),
    {stop, normal, ok, State};

handle_call(Call, _From, #state{connection=Conn1, binary_response=IsBinResp}=State1) ->
    case rest_request_of_call(Call) of
        {error, {unknown_call, _}} ->
            thrift_client:close(Conn1),
            {stop, unhandled_call, State1};
        {ok, RestRequest} ->
            {RequestResult1, State2} = do_request(Conn1, RestRequest, State1),
            RequestResult2 =
                case RequestResult1 of
                    {error, _}=Error ->
                        Error;
                    {ok, Resp1} ->
                        Resp2 = process_response(IsBinResp, Resp1),
                        Resp3 = maybe_make_boolean_response(Call, Resp2, IsBinResp),
                        {ok, Resp3}
                end,
            {reply, RequestResult2, State2}
    end.

handle_cast(_, #state{connection=Conn}=State) ->
    thrift_client:close(Conn),
    {stop, unhandled_info, State}.

handle_info(_, #state{connection=Conn}=State) ->
    thrift_client:close(Conn),
    {stop, unhandled_info, State}.

terminate(_Reason, State) ->
    thrift_client:close(State#state.connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


rest_request_of_call(Call) ->
    case Call of
        {health} ->
            {ok, rest_request_health()};
        {state, Params} ->
            {ok, rest_request_state(Params)};
        {nodes_info , NodeNames, Params} ->
            {ok, rest_request_nodes_info(NodeNames, Params)};
        {nodes_stats, NodeNames, Params} ->
            {ok, rest_request_nodes_stats(NodeNames, Params)};
        {status, Index} ->
            {ok, rest_request_status(Index)};
        {indices_stats, Index} ->
            {ok, rest_request_indices_stats(Index)};
        {create_index, Index, Doc} ->
            {ok, rest_request_create_index(Index, Doc)};
        {delete_index, Index} ->
            {ok, rest_request_delete_index(Index)};
        {open_index, Index} ->
            {ok, rest_request_open_index(Index)};
        {close_index, Index} ->
            {ok, rest_request_close_index(Index)};
        {count, Index, Type, Doc, Params} ->
            {ok, rest_request_count(Index, Type, Doc, Params)};
        {delete_by_query, Index, Type, Doc, Params} ->
            {ok, rest_request_delete_by_query(Index, Type, Doc, Params)};
        {is_index, Index} ->
            {ok, rest_request_is_index(Index)};
        {is_type, Index, Type} ->
            {ok, rest_request_is_type(Index, Type)};
        {insert_doc, Index, Type, Id, Doc, Params} ->
            {ok, rest_request_insert_doc(Index, Type, Id, Doc, Params)};
        {update_doc, Index, Type, Id, Doc, Params} ->
            {ok, rest_request_update_doc(Index, Type, Id, Doc, Params)};
        {get_doc, Index, Type, Id, Params} ->
            {ok, rest_request_get_doc(Index, Type, Id, Params)};
        {mget_doc, Index, Type, Doc} ->
            {ok, rest_request_mget_doc(Index, Type, Doc)};
        {is_doc, Index, Type, Id} ->
            {ok, rest_request_is_doc(Index, Type, Id)};
        {delete_doc, Index, Type, Id, Params} ->
            {ok, rest_request_delete_doc(Index, Type, Id, Params)};
        {search, Index, Type, Doc, Params} ->
            {ok, rest_request_search(Index, Type, Doc, Params)};
        {bulk, Index, Type, Doc} ->
            {ok, rest_request_bulk(Index, Type, Doc)};
        {refresh, Index} ->
            {ok, rest_request_refresh(Index)};
        {flush, Index} ->
            {ok, rest_request_flush(Index)};
        {optimize, Index} ->
            {ok, rest_request_optimize(Index)};
        {segments, Index} ->
            {ok, rest_request_segments(Index)};
        {clear_cache, Index, Params} ->
            {ok, rest_request_clear_cache(Index, Params)};
        {put_mapping, Indices, Type, Doc} ->
            {ok, rest_request_put_mapping(Indices, Type, Doc)};
        {get_mapping, Indices, Type} ->
            {ok, rest_request_get_mapping(Indices, Type)};
        {delete_mapping, Indices, Type} ->
            {ok, rest_request_delete_mapping(Indices, Type)};
        {aliases, Doc} ->
            {ok, rest_request_aliases(Doc)};
        {insert_alias, Index, Alias} ->
            {ok, rest_request_insert_alias(Index, Alias)};
        {insert_alias, Index, Alias, Doc} ->
            {ok, rest_request_insert_alias(Index, Alias, Doc)};
        {delete_alias, Index, Alias} ->
            {ok, rest_request_delete_alias(Index, Alias)};
        {is_alias, Index, Alias} ->
            {ok, rest_request_is_alias(Index, Alias)};
        {get_alias, Index, Alias} ->
            {ok, rest_request_get_alias(Index, Alias)};
        _ ->
            {error, {unknown_call, Call}}
    end.



-spec connection(params()) -> connection().
connection(ConnectionOptions) ->
    ThriftHost = proplists:get_value(thrift_host, ConnectionOptions, ?DEFAULT_THRIFT_HOST),
    ThriftPort = proplists:get_value(thrift_port, ConnectionOptions, ?DEFAULT_THRIFT_PORT),
    ThriftOptions = case lists:keyfind(thrift_options, 1, ConnectionOptions) of
        {thrift_options, Options} -> Options;
        false -> []
    end,
    {ok, Connection} = thrift_client_util:new(ThriftHost, ThriftPort, elasticsearch_thrift, ThriftOptions),
    Connection.

-spec do_request(connection(), rest_request(), #state{}) ->
    {RequestResult, state()}
    when RequestResult ::
           {ok   , rest_response()}
         | {error, Reason}
       , Reason ::
           {connection_error , connection_error()}
         | {call_error       , thrift_call_error()}
         | {call_exception   , {java, any()} | {erlang, badarg}}
       .
do_request(Connection1, #restRequest{body=Body}=RestRequest, State1) ->
    %TODO: Connection should come from State
    BodyBin =
        case Body of
            <<_/binary>>            -> Body;
            Body when is_list(Body) -> jsx:encode(Body, [repeat_keys])
        end,
    Function = execute,
    Arguments = [RestRequest#restRequest{body=BodyBin}],
    try thrift_client:call(Connection1, Function, Arguments) of
        {Connection2, {ok, RestResponse}} ->
            State2 = State1#state{connection=Connection2},
            {{ok, RestResponse}, State2};
        {Connection2, {error, Reason}} ->
            State2 = State1#state{connection=Connection2},
            {{error, {call_error, Reason}}, State2}
    catch
        throw:{Connection2, {exception, ExceptionDetails}} ->
            State2 = State1#state{connection=Connection2},
            {{error, {call_exception, {java, ExceptionDetails}}}, State2};
        error:badarg ->
            % TODO: What does badarg mean here? Why are we catching it?
            {{error, {call_exception, {erlang, badarg}}}, State1};
        error:{case_clause, {error, closed}} ->
            {{error, {connection_error, closed}}, State1};
        error:{case_clause, {error, econnrefused}} ->
            {{error, {connection_error, econnrefused}}, State1}
    end.

-spec process_response(boolean(), rest_response()) ->
    response().
process_response(true, #restResponse{status = Status, body = undefined}) ->
    [{status, erlang:integer_to_binary(Status)}];
process_response(false, #restResponse{status = Status, body = undefined}) ->
    [{status, Status}];
process_response(true, #restResponse{status = Status, body = Body}) ->
    [{status, erlang:integer_to_binary(Status)}, {body, Body}];
process_response(false, #restResponse{status = Status, body = Body}) ->
    % TODO: What does this try/catch block mean?
    try
        [{status, Status}, {body, jsx:decode(Body)}]
    catch
        error:badarg ->
            [{status, Status}, {body, Body}]
    end.

rest_request_health() ->
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = ?HEALTH}.

rest_request_state(Params) when is_list(Params) ->
    Uri = make_uri([?STATE], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_nodes_info(NodeNames, Params) when is_list(NodeNames),
                                                is_list(Params) ->
    NodeNameList = erlasticsearch:join(NodeNames, <<",">>),
    Uri = make_uri([?NODES, NodeNameList], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_nodes_stats(NodeNames, Params) when is_list(NodeNames),
                                                is_list(Params) ->
    NodeNameList = erlasticsearch:join(NodeNames, <<",">>),
    Uri = make_uri([?NODES, NodeNameList, ?STATS], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_status(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?STATUS], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_indices_stats(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?INDICES_STATS], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_create_index(Index, Doc) when is_binary(Index) andalso
                                              (is_binary(Doc) orelse is_list(Doc)) ->
    #restRequest{method = ?elasticsearch_Method_PUT,
                 uri = Index,
                 body = Doc}.

rest_request_delete_index(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    #restRequest{method = ?elasticsearch_Method_DELETE,
                 uri = IndexList}.

rest_request_open_index(Index) when is_binary(Index) ->
    Uri = erlasticsearch:join([Index, ?OPEN], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_close_index(Index) when is_binary(Index) ->
    Uri = erlasticsearch:join([Index, ?CLOSE], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_count(Index, Type, Doc, Params) when is_list(Index) andalso
                                        is_list(Type) andalso
                                        (is_binary(Doc) orelse is_list(Doc)) andalso
                                        is_list(Params) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    TypeList = erlasticsearch:join(Type, <<",">>),
    Uri = make_uri([IndexList, TypeList, ?COUNT], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri,
                 body = Doc}.

rest_request_delete_by_query(Index, Type, Doc, Params) when is_list(Index) andalso
                                        is_list(Type) andalso
                                        (is_binary(Doc) orelse is_list(Doc)) andalso
                                        is_list(Params) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    TypeList = erlasticsearch:join(Type, <<",">>),
    Uri = make_uri([IndexList, TypeList, ?QUERY], Params),
    #restRequest{method = ?elasticsearch_Method_DELETE,
                 uri = Uri,
                 body = Doc}.

rest_request_is_index(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    #restRequest{method = ?elasticsearch_Method_HEAD,
                 uri = IndexList}.

rest_request_is_type(Index, Type) when is_list(Index),
                                        is_list(Type) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    TypeList = erlasticsearch:join(Type, <<",">>),
    Uri = erlasticsearch:join([IndexList, TypeList], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_HEAD,
                 uri = Uri}.

rest_request_insert_doc(Index, Type, undefined, Doc, Params) when is_binary(Index) andalso
                                                      is_binary(Type) andalso
                                                      (is_binary(Doc) orelse is_list(Doc)) andalso
                                                      is_list(Params) ->
    Uri = make_uri([Index, Type], Params),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc};

rest_request_insert_doc(Index, Type, Id, Doc, Params) when is_binary(Index) andalso
                                                      is_binary(Type) andalso
                                                      is_binary(Id) andalso
                                                      (is_binary(Doc) orelse is_list(Doc)) andalso
                                                      is_list(Params) ->
    Uri = make_uri([Index, Type, Id], Params),
    #restRequest{method = ?elasticsearch_Method_PUT,
                 uri = Uri,
                 body = Doc}.

rest_request_update_doc(Index, Type, Id, Doc, Params) when is_binary(Index) andalso
                                                      is_binary(Type) andalso
                                                      is_binary(Id) andalso
                                                      (is_binary(Doc) orelse is_list(Doc)) andalso
                                                      is_list(Params) ->
    Uri = make_uri([Index, Type, Id, ?UPDATE], Params),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc}.

rest_request_is_doc(Index, Type, Id) when is_binary(Index),
                                                   is_binary(Type),
                                                   is_binary(Id) ->
    Uri = make_uri([Index, Type, Id], []),
    #restRequest{method = ?elasticsearch_Method_HEAD,
                 uri = Uri}.

rest_request_get_doc(Index, Type, Id, Params) when is_binary(Index),
                                                   is_binary(Type),
                                                   is_binary(Id),
                                                   is_list(Params) ->
    Uri = make_uri([Index, Type, Id], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_mget_doc(Index, Type, Doc) when is_binary(Index) andalso
                                                   is_binary(Type) andalso
                                                   (is_binary(Doc) orelse is_list(Doc)) ->
    Uri = make_uri([Index, Type, ?MGET], []),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri,
                 body = Doc}.

rest_request_delete_doc(Index, Type, Id, Params) when is_binary(Index),
                                                   is_binary(Type),
                                                   is_binary(Id),
                                                   is_list(Params) ->
    Uri = make_uri([Index, Type, Id], Params),
    #restRequest{method = ?elasticsearch_Method_DELETE,
                 uri = Uri}.

rest_request_search(Index, Type, Doc, Params) when is_binary(Index) andalso
                                                   is_binary(Type) andalso
                                                   (is_binary(Doc) orelse is_list(Doc)) andalso
                                                   is_list(Params) ->
    Uri = make_uri([Index, Type, ?SEARCH], Params),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri,
                 body = Doc}.

rest_request_bulk(<<>>, <<>>, Doc) when (is_binary(Doc) orelse is_list(Doc)) ->
    Uri = make_uri([?BULK], []),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc};

rest_request_bulk(Index, <<>>, Doc) when is_binary(Index) andalso
                                        (is_binary(Doc) orelse is_list(Doc)) ->
    Uri = make_uri([Index, ?BULK], []),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc};

rest_request_bulk(Index, Type, Doc) when is_binary(Index) andalso
                                         is_binary(Type) andalso
                                         (is_binary(Doc) orelse is_list(Doc)) ->
    Uri = make_uri([Index, Type, ?BULK], []),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc}.

rest_request_refresh(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?REFRESH], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_flush(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?FLUSH], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_optimize(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?OPTIMIZE], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_segments(Index) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?SEGMENTS], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_clear_cache(Index, Params) when is_list(Index) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = make_uri([IndexList, ?CLEAR_CACHE], Params),
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri}.

rest_request_put_mapping(Index, Type, Doc) when is_list(Index),
                                                is_binary(Type),
                                                (is_binary(Doc) orelse is_list(Doc)) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?MAPPING, Type], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_PUT,
                 uri = Uri,
                 body = Doc}.

rest_request_get_mapping(Index, Type) when is_list(Index),
                                           is_binary(Type) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?MAPPING, Type], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

rest_request_delete_mapping(Index, Type) when is_list(Index),
                                              is_binary(Type) ->
    IndexList = erlasticsearch:join(Index, <<",">>),
    Uri = erlasticsearch:join([IndexList, ?MAPPING, Type], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_DELETE,
                 uri = Uri}.

rest_request_aliases(Doc) when is_binary(Doc) orelse is_list(Doc) ->
    Uri = ?ALIASES,
    #restRequest{method = ?elasticsearch_Method_POST,
                 uri = Uri,
                 body = Doc}.

rest_request_insert_alias(Index, Alias) when is_binary(Index),
                                             is_binary(Alias) ->
    Uri = erlasticsearch:join([Index, ?ALIAS, Alias], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_PUT,
                 uri = Uri}.

rest_request_insert_alias(Index, Alias, Doc) when is_binary(Index),
                                                  is_binary(Alias),
                                                  (is_binary(Doc) orelse is_list(Doc)) ->
    Uri = erlasticsearch:join([Index, ?ALIAS, Alias], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_PUT,
                 uri = Uri,
                 body = Doc}.

rest_request_delete_alias(Index, Alias) when is_binary(Index),
                                             is_binary(Alias) ->
    Uri = erlasticsearch:join([Index, ?ALIAS, Alias], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_DELETE,
                 uri = Uri}.

rest_request_is_alias(Index, Alias) when is_binary(Index),
                                         is_binary(Alias) ->
    Uri = erlasticsearch:join([Index, ?ALIAS, Alias], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_HEAD,
                 uri = Uri}.

rest_request_get_alias(Index, Alias) when is_binary(Index),
                                          is_binary(Alias) ->
    Uri = erlasticsearch:join([Index, ?ALIAS, Alias], <<"/">>),
    #restRequest{method = ?elasticsearch_Method_GET,
                 uri = Uri}.

make_uri(BaseList, PropList) ->
    Base = erlasticsearch:join(BaseList, <<"/">>),
    case PropList of
        [] ->
            Base;
        PropList ->
            Props = uri_params_encode(PropList),
            erlasticsearch:join([Base, Props], <<"?">>)
    end.

-spec uri_params_encode([tuple()]) -> string().
uri_params_encode(Params) ->
  intercalate("&", [uri_join([K, V], "=") || {K, V} <- Params]).

uri_join(Values, Separator) ->
  string:join([uri_encode(Value) || Value <- Values], Separator).

intercalate(Sep, Xs) ->
  lists:concat(intersperse(Sep, Xs)).

intersperse(_, []) ->
  [];
intersperse(_, [X]) ->
  [X];
intersperse(Sep, [X | Xs]) ->
  [X, Sep | intersperse(Sep, Xs)].

uri_encode(Term) when is_binary(Term) ->
    uri_encode(binary_to_list(Term));
uri_encode(Term) when is_integer(Term) ->
    uri_encode(integer_to_list(Term));
uri_encode(Term) when is_atom(Term) ->
  uri_encode(atom_to_list(Term));
uri_encode(Term) when is_list(Term) ->
  uri_encode(lists:reverse(Term, []), []).

-define(is_alphanum(C), C >= $A, C =< $Z; C >= $a, C =< $z; C >= $0, C =< $9).

uri_encode([X | T], Acc) when ?is_alphanum(X); X =:= $-; X =:= $_; X =:= $.; X =:= $~ ->
  uri_encode(T, [X | Acc]);
uri_encode([X | T], Acc) ->
  NewAcc = [$%, dec2hex(X bsr 4), dec2hex(X band 16#0f) | Acc],
  uri_encode(T, NewAcc);
uri_encode([], Acc) ->
  Acc.

-compile({inline, [{dec2hex, 1}]}).

dec2hex(N) when N >= 10 andalso N =< 15 ->
  N + $A - 10;
dec2hex(N) when N >= 0 andalso N =< 9 ->
  N + $0.

-spec maybe_make_boolean_response(Call :: any(), response(), boolean()) ->
    response().
maybe_make_boolean_response(Call, Response, IsBinResp) ->
    MakeBool =
        fun () ->
            Is200 = is_200(Response),
            Is200MaybeBin =
                case IsBinResp of
                    true  -> boolean_to_bin(Is200);
                    false ->                Is200
                end,
            [{result, Is200MaybeBin} | Response]
        end,
    case Call of
        {is_index, _}     -> MakeBool();
        {is_type, _, _}   -> MakeBool();
        {is_doc, _, _, _} -> MakeBool();
        {is_alias, _, _}  -> MakeBool();
        _                 -> Response
    end.

boolean_to_bin(true)  -> <<"true">>;
boolean_to_bin(false) -> <<"false">>.

-spec is_200(response()) -> boolean().
is_200(Response) ->
    case lists:keyfind(status, 1, Response) of
        {status, 200} -> true;
        {status, <<"200">>} -> true;
        _ -> false
    end.

-spec is_200_or_201(response()) -> boolean().
is_200_or_201({error, _} = Response) -> Response;
is_200_or_201(Response) ->
    case lists:keyfind(status, 1, Response) of
        {status, 200} -> true;
        {status, <<"200">>} -> true;
        {status, 201} -> true;
        {status, <<"201">>} -> true;
        _ -> false
    end.
