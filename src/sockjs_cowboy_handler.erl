-module(sockjs_cowboy_handler).
-behaviour(cowboy_http_handler).
-behaviour(cowboy_websocket_handler).

%% Cowboy http callbacks
-export([init/2, handle/2, terminate/3]).

%% Cowboy ws callbacks
-export([websocket_init/1, websocket_handle/2,
         websocket_info/2, websocket_terminate/3]).

-include("sockjs_internal.hrl").

%% --------------------------------------------------------------------------

init(Req, Service) ->
    case sockjs_handler:is_valid_ws(Service, {cowboy, Req}) of
        {true, {cowboy, Req1}, _Reason} ->
            Req2 = ws_init(Req1, Service),
            {cowboy_websocket, Req2, Service};

        {false, {cowboy, Req1}, _Reason} ->
            Ans = jsone:encode(#{<<"websocket">> => true,
                                 <<"cookie_needed">> => true,
                                 <<"origins">> => [<<"*:*">>]}),
            Headers = #{<<"content-type">> => <<"application/json">>},
            Req2 = cowboy_req:reply(200, Headers, Ans, Req1),
            {ok, Req1, Service}
    end.

handle(Req, Service) ->
    {cowboy, Req3} = sockjs_handler:handle_req(Service, {cowboy, Req}),
    {ok, Req3, Service}.

terminate(_Reason, _Req, _Service) ->
    ok.

%% --------------------------------------------------------------------------

websocket_init(Service = #service{logger        = Logger,
                                  subproto_pref = SubProtocolPref}) ->
    io:fwrite("websocket_init Service: ~p", [Service]),
    self() ! go,
    {ok, Service}.
 
% websocket_handle({text, Data}, Req, {RawWebsocket, SessionPid} = S) ->
websocket_handle(Req, S) ->
    io:fwrite("websocket_handle req: ~p, s: ~p", [Req, S]);
    % case sockjs_ws_handler:received(RawWebsocket, SessionPid, Data) of
    %     ok       -> {ok, Req, S};
    %     shutdown -> {shutdown, Req, S}
    % end;
websocket_handle(Req, S) ->
    {shutdown, Req, S}.

websocket_info(go, {RawWebsocket, SessionPid} = S) ->
    case sockjs_ws_handler:reply(RawWebsocket, SessionPid) of
        wait          -> {ok, S};
        {ok, Data}    -> self() ! go,
                         {reply, {text, Data}, S};
        {close, <<>>} -> {shutdown, S};
        {close, Data} -> self() ! shutdown,
                         {reply, {text, Data}, S}
    end;
websocket_info(shutdown, S) ->
    {shutdown, S}.

websocket_terminate(_Reason, _Req, {RawWebsocket, SessionPid}) ->
    sockjs_ws_handler:close(RawWebsocket, SessionPid),
    ok.

%% --------------------------------------------------------------------------

choose_subprotocol_bin(SubProtocols, Pref) ->
    choose_subprotocol(re:split(SubProtocols, ", *"), Pref).
choose_subprotocol(SubProtocols, undefined) ->
    erlang:hd(lists:reverse(lists:sort(SubProtocols)));
choose_subprotocol(SubProtocols, Pref) ->
    case lists:filter(fun (E) -> lists:member(E, SubProtocols) end, Pref) of
        [Hd | _] -> Hd;
        []       -> choose_subprotocol(SubProtocols, undefined)
    end.


ws_init(Req, #service{subproto_pref = Pref} = Service) ->
    Req1 = case cowboy_req:header(<<"sec-websocket-protocol">>, Req) of
               undefined -> Req;
               SubProtocols ->
                   SelectedSubProtocol =
                     choose_subprotocol_bin(SubProtocols, Pref),
                   cowboy_req:set_resp_header(
                     <<"sec-websocket-protocol">>,
                     SelectedSubProtocol, Req)
           end.

    % Req4 = Logger(Service, {cowboy, Req3}, websocket),

    % Service1 = Service#service{disconnect_delay = 5*60*1000},

    % {Info, Req5} = sockjs_handler:extract_info(Req4),
    % SessionPid = sockjs_session:maybe_create(undefined, Service1, Info),
    % {RawWebsocket, {cowboy, Req7}} =
    %     case sockjs_handler:get_action(Service, Req5) of
    %         {{match, WS}, Req6} when WS =:= websocket orelse
    %                                  WS =:= rawwebsocket ->
    %             {WS, Req6}
    %     end,
    %
    % {ok, Req7, {RawWebsocket, SessionPid}}.
