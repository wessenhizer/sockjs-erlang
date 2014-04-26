-module(sockjs_multiplex_channel).

-include("sockjs_internal.hrl").

-export([send/2, close/1, close/3, info/1]).

-spec send(iodata(), channel()) -> ok.
send(Data, {?MODULE, Conn, Topic}) ->
    Conn:send(iolist_to_binary(["msg", ",", Topic, ",", Data])).

-spec close(channel()) -> ok.
close(Channel) ->
    close(1000, "Normal closure", Channel).

-spec close(non_neg_integer(), string(), channel()) -> ok.
close(_Code, _Reason, {?MODULE, Conn, Topic}) ->
    Conn:send(iolist_to_binary(["uns", ",", Topic])).

-spec info(channel()) -> [{atom(), any()}].
info({?MODULE, Conn, Topic}) ->
    Conn:info() ++ [{topic, Topic}].

