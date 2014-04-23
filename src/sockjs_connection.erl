-module(sockjs_connection).

-include("sockjs_internal.hrl").

-export([to_normal/1, to_channel/2]).

%% Get the backend connection of a channel.
-spec to_normal(channel()) -> conn().
to_normal({sockjs_multiplex_channel, Conn, _Topic}) ->
    Conn.

%% Create a channel from a connection.
-spec to_channel(conn(), topic()) -> channel().
to_channel(Conn = {sockjs_session, {_Pid, _Info}}, Topic) ->
    {sockjs_multiplex_channel, Conn, Topic}.