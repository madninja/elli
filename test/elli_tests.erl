-module(elli_tests).
-include_lib("eunit/include/eunit.hrl").
-include("elli.hrl").


-define(i2b(I), list_to_binary(integer_to_list(I))).

elli_test_() ->
    {setup,
     fun setup/0, fun teardown/1,
     [
      ?_test(hello_world()),
      ?_test(not_found()),
      ?_test(crash()),
      ?_test(no_compress()),
      ?_test(exception_flow()),
      ?_test(user_connection()),
      ?_test(get_args()),
      ?_test(shorthand()),
      ?_test(bad_request()),
      ?_test(content_length()),
      ?_test(chunked()),
      ?_test(sendfile()),
      ?_test(slow_client()),
      ?_test(pipeline()),
      ?_test(head()),
      ?_test(no_body())
     ]}.



setup() ->
    application:start(crypto),
    application:start(public_key),
    application:start(ssl),
    inets:start(),
    {ok, P} = elli:start_link([{callback, elli_example_callback}, {port, 3001}]),
    unlink(P),
    [P].

teardown(Pids) ->
    [elli:stop(P) || P <- Pids].


%%
%% INTEGRATION TESTS
%% Uses inets httpc to actually call Elli over the network
%%

hello_world() ->
    URL = "http://localhost:3001/hello/world",
    {ok, Response} = httpc:request(URL),
    ?assertEqual(200, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "12"}], headers(Response)),
    ?assertEqual("Hello World!", body(Response)).



not_found() ->
    {ok, Response} = httpc:request("http://localhost:3001/foobarbaz"),
    ?assertEqual(404, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "9"}], headers(Response)),
    ?assertEqual("Not Found", body(Response)).

crash() ->
    {ok, Response} = httpc:request("http://localhost:3001/crash"),
    ?assertEqual(500, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "21"}], headers(Response)),
    ?assertEqual("Internal server error", body(Response)).


no_compress() ->
    {ok, Response} = httpc:request(get, {"http://localhost:3001/compressed",
                                         [{"Accept-Encoding", "gzip"}]}, [], []),
    ?assertEqual(200, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "1032"}], headers(Response)),
    ?assertEqual(binary:copy(<<"Hello World!">>, 86),
                 list_to_binary(body(Response))).

exception_flow() ->
    {ok, Response} = httpc:request("http://localhost:3001/403"),
    ?assertEqual(403, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "9"}], headers(Response)),
    ?assertEqual("Forbidden", body(Response)).

user_connection() ->
    {ok, Response} = httpc:request("http://localhost:3001/user/defined/behaviour"),
    ?assertEqual(304, status(Response)),
    ?assertEqual([{"connection", "close"},
                  {"content-length", "123"}], headers(Response)),
    ?assertEqual([], body(Response)).


get_args() ->
    {ok, Response} = httpc:request("http://localhost:3001/hello?name=knut"),
    ?assertEqual("Hello knut", body(Response)).

shorthand() ->
    {ok, Response} = httpc:request("http://localhost:3001/shorthand"),
    ?assertEqual(200, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "5"}], headers(Response)),
    ?assertEqual("hello", body(Response)).


bad_request() ->
    Headers = lists:duplicate(100, {"X-Foo", "Bar"}),
    ?assertEqual({error, socket_closed_remotely},
                 httpc:request(get, {"http://localhost:3001/foo", Headers},
                               [], [])),

    Body = binary:copy(<<"x">>, 1024 * 1000),
    ?assertEqual({error, socket_closed_remotely},
                 httpc:request(post,
                               {"http://localhost:3001/foo", [], "foo", Body},
                               [], [])).



content_length() ->
    {ok, Response} = httpc:request("http://localhost:3001/304"),

    ?assertEqual(304, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "7"},
                  {"etag", "foobar"}], headers(Response)),
    ?assertEqual([], body(Response)).


chunked() ->
    Expected = "chunk10chunk9chunk8chunk7chunk6chunk5chunk4chunk3chunk2chunk1",

    {ok, Response} = httpc:request("http://localhost:3001/chunked"),
    ?assertEqual(200, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  %% httpc adds a content-length, even though elli
                  %% does not send any for chunked trasnfers
                  {"content-length", integer_to_list(length(Expected))},
                  {"content-type", "text/event-stream"}], headers(Response)),
    ?assertEqual(Expected, body(Response)).

sendfile() ->
    {ok, Response} = httpc:request("http://localhost:3001/sendfile"),

    F = "../src/elli_example_callback.erl",
    {ok, Expected} = file:read_file(F),

    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", integer_to_list(size(Expected))}],
                 headers(Response)),
    ?assertEqual(binary_to_list(Expected), body(Response)).


slow_client() ->
    Body = <<"name=foobarbaz">>,
    Headers = <<"Content-Length: ",(?i2b(size(Body)))/binary, "\r\n\r\n">>,
    Client = start_slow_client(3001, "/hello"),

    send(Client, Headers, 1),
    send(Client, Body, size(Body)),

    ?assertEqual({ok, <<"HTTP/1.1 200 OK\r\n"
                        "Connection: Keep-Alive\r\n"
                        "Content-Length: 15\r\n"
                        "\r\n"
                        "Hello undefined">>},
                 gen_tcp:recv(Client, 0)).


pipeline() ->
    Body = <<"name=quux">>,
    Headers = <<"Content-Length: ",(?i2b(size(Body)))/binary, "\r\n\r\n">>,

    {ok, Socket} = gen_tcp:connect("127.0.0.1", 3001, [{active, false}, binary]),

    Req = <<"GET /hello?name=elli HTTP/1.1\r\n",
            Headers/binary,
            Body/binary>>,

    gen_tcp:send(Socket, <<Req/binary, Req/binary>>),

    {ok, Res} = gen_tcp:recv(Socket, 0),
    ?assertEqual(binary:copy(<<"HTTP/1.1 200 OK\r\n"
                               "Connection: Keep-Alive\r\n"
                               "Content-Length: 10\r\n"
                               "\r\n"
                               "Hello elli">>, 2),
                 Res).

head() ->
    {ok, Response} = httpc:request(head, {"http://localhost:3001/head", []},
                                   [], []),
    ?assertEqual(200, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "20"}], headers(Response)),
    ?assertEqual([], body(Response)).


no_body() ->
    {ok, Response} = httpc:request("http://localhost:3001/304"),
    ?assertEqual(304, status(Response)),
    ?assertEqual([{"connection", "Keep-Alive"},
                  {"content-length", "7"},
                  {"etag", "foobar"}], headers(Response)),
    ?assertEqual([], body(Response)).




%%
%% Slow client, sending only the specified byte size every millisecond
%%

start_slow_client(Port, Url) ->
    case gen_tcp:connect("127.0.0.1", Port, [{active, false}, binary]) of
        {ok, Socket} ->
            gen_tcp:send(Socket, "GET " ++ Url ++ " HTTP/1.1\r\n"),
            Socket;
        {error, Reason} ->
            throw({slow_client_error, Reason})
    end.

send(_Socket, <<>>, _) ->
    ok;
send(Socket, B, ChunkSize) ->
    {Part, Rest} = case B of
                       <<P:ChunkSize/binary, R/binary>> -> {P, R};
                       P -> {P, <<>>}
           end,
    %%error_logger:info_msg("~p~n", [Part]),
    gen_tcp:send(Socket, Part),
    timer:sleep(1),
    send(Socket, Rest, ChunkSize).


%%
%% UNIT TESTS
%%


body_qs_test() ->
    ?assertEqual([{<<"foo">>, <<"bar">>}, {<<"baz">>, <<"bang">>}, {<<"found">>, true}],
                 elli_request:body_qs(#req{body = <<"foo=bar&baz=bang&found">>})).

to_proplist_test() ->
    Req = #req{method = 'GET',
               path = [<<"crash">>],
               args = [],
               version = {1,1},
               raw_path = <<"/crash">>,
               headers = [{<<"Host">>,<<"localhost:3001">>}],
               body = <<>>,
               pid = self(),
               socket = socket},

    Prop = [{method,'GET'},
            {path,[<<"crash">>]},
            {args,[]},
            {raw_path,<<"/crash">>},
            {version,{1,1}},
            {headers,[{<<"Host">>,<<"localhost:3001">>}]},
            {body,<<>>},
            {pid,self()},
            {socket,socket}],
    ?assertEqual(Prop, elli_request:to_proplist(Req)).


query_str_test_() ->
    MakeReq = fun(Path) -> #req{raw_path = Path} end,
    [
        % For empty query strings, expect `query_str` to return an empty binary.
        ?_assertEqual(<<>>, elli_request:query_str(MakeReq(<<"/foo">>))),
        ?_assertEqual(<<>>, elli_request:query_str(MakeReq(<<"/foo?">>))),
        % Otherwise it should return everything to the right hand side of `?`.
        ?_assertEqual(<<"bar=baz&baz=bang">>,
                      elli_request:query_str(MakeReq(<<"/foo?bar=baz&baz=bang">>)))
    ].


register_test() ->
    ?assertEqual(undefined, whereis(elli)),
    {ok, Pid} = elli:start_link([{name, {local, elli}}, {callback, elli_example_callback}]),
    ?assertEqual(Pid, whereis(elli)),
    ok.

invalid_callback_test() ->
    case catch elli:start_link([{callback, elli}]) of
        E ->
            ?assertEqual(invalid_callback, E)
    end.


%%
%% HELPERS
%%

status({{_, Status, _}, _, _}) ->
    Status.

body({_, _, Body}) ->
    Body.

headers({_, Headers, _}) ->
    lists:sort(Headers).
