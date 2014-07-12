#!/usr/bin/env escript
%%! -smp disable +A1 +K true -pa ebin -env ERL_LIBS deps -input
-module(cowboy_multiplex).
-mode(compile).

-export([main/1]).

%% Cowboy callbacks
-export([init/3, handle/2, terminate/3]).

main(_) ->
    Port = 8081,
    ok = application:start(xmerl),
    ok = application:start(sockjs),
    ok = application:start(ranch),
    ok = application:start(crypto),
    ok = application:start(cowlib),
    ok = application:start(cowboy),

    MultiplexState = sockjs_multiplex:init_state(
                       [{"ann",  fun service_ann/3,  []},
                        {"bob",  fun service_bob/3,  []},
                        {"carl", fun service_carl/3, []}],
                       {fun authen/3, [{state, []}]}),

    SockjsState = sockjs_handler:init_state(
                    <<"/multiplex">>, sockjs_multiplex, MultiplexState, []),

    VhostRoutes = [{<<"/multiplex/[...]">>, sockjs_cowboy_handler, SockjsState},
                   {'_', ?MODULE, []}],
    Routes = [{'_',  VhostRoutes}], % any vhost
    Dispatch = cowboy_router:compile(Routes),

    io:format(" [*] Running at http://localhost:~p~n", [Port]),
    cowboy:start_http(http, 100,
                      [{port, Port}],
                      [{env, [{dispatch, Dispatch}]}]),
    receive
        _ -> ok
    end.

%% --------------------------------------------------------------------------

init({_Any, http}, Req, []) ->
    {ok, Req, []}.

handle(Req, State) ->
    {Path, Req1} = cowboy_req:path(Req),
    {ok, Req2} = case Path of
                     <<"/">> ->
                         {ok, Data} = file:read_file("./examples/multiplex/index_authen_callback.html"),
                         cowboy_req:reply(200, [{<<"Content-Type">>, "text/html"}],
                                               Data, Req1);
                     _ ->
                         cowboy_req:reply(404, [],
                                               <<"404 - Nothing here\n">>, Req1)
                 end,
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% --------------------------------------------------------------------------

authen(Conn, init, Extra) ->
    {ok, TRef} = timer:apply_after(5000, sockjs, close, [Conn]),
    {ok, [TRef | Extra]};
authen(Conn, {recv, Data}, [TRef | Extra] = State) ->
    case Data of
        <<"auth">> ->
            sockjs:send(<<"Authenticate successfully!">>, Conn),
            timer:cancel(TRef),
            {success, [{user_id, element(3, erlang:now())} | Extra]};
        _Else ->
            {ok, State}
    end;
authen(_Conn, closed, [TRef | Extra]) ->
    timer:cancel(TRef),
    {ok, Extra}.

service_ann(Conn, init, State) ->
    sockjs:send("Ann says hi!", Conn),
    {ok, State};
service_ann(Conn, {recv, Data}, State) ->
    {user_id, UserId} = lists:keyfind(user_id, 1, State),
    sockjs:send(["Ann nods: ", Data, " from ", erlang:integer_to_binary(UserId)], Conn),
    {ok, State};
service_ann(_Conn, closed, State) ->
    {ok, State}.

service_bob(Conn, init, State) ->
    sockjs:send("Bob doesn't agree.", Conn),
    {ok, State};
service_bob(Conn, {recv, Data}, State) ->
    {user_id, UserId} = lists:keyfind(user_id, 1, State),
    sockjs:send(["Bob says no to: ", Data, " from ", erlang:integer_to_binary(UserId)],
                Conn),
    {ok, State};
service_bob(_Conn, closed, State) ->
    {ok, State}.

service_carl(Conn, init, State) ->
    sockjs:send("Carl says goodbye!", Conn),
    sockjs:close(Conn),
    {ok, State};
service_carl(_Conn, _, State) ->
    {ok, State}.
