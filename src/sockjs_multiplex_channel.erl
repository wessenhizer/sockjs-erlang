-module(sockjs_multiplex_channel).

-export([send/2, close/1, close/3, info/1]).

-include("sockjs_internal.hrl").

-spec send(iodata(), channel()) -> ok.
send(Data, {?MODULE, Conn = {sockjs_session, _}, Topic}) ->
	sockjs_session:send(iolist_to_binary(["msg", ",", Topic, ",", Data]), Conn).

-spec close(channel()) -> ok.
close(Channel) ->
    close(1000, "Normal closure", Channel).

-spec close(non_neg_integer(), string(), channel()) -> ok.
close(_Code, _Reason, {?MODULE, Conn, Topic}) ->
	sockjs_session:send(iolist_to_binary(["uns", ",", Topic]), Conn).

-spec info(channel()) -> [{atom(), any()}].
info({?MODULE, Conn = {sockjs_session, _}, Topic}) ->
    sockjs_session:info(Conn) ++ [{topic, Topic}].