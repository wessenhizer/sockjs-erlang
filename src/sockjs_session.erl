-module(sockjs_session).

-behaviour(gen_server).

-export([init/0, start_link/3]).
-export([maybe_create/3, reply/1, reply/2, received/2]).
-export([send/2, close/3, info/1]).


-export([init/1, handle_call/3, handle_info/2, terminate/2, code_change/3,
         handle_cast/2]).

-include("sockjs_internal.hrl").

-type(handle() :: {?MODULE, {pid(), info()}}).
-type(conn()   :: {?MODULE, any()}).

-export_type([conn/0]).


-record(session, {id                           :: session(),
                  outbound_queue = queue:new() :: queue(),
                  response_pid                 :: pid(),
                  disconnect_tref              :: reference(),
                  disconnect_delay = 5000      :: non_neg_integer(),
                  heartbeat_tref               :: reference() | triggered,
                  heartbeat_delay = 25000      :: non_neg_integer(),
                  ready_state = connecting     :: connecting | open | closed,
                  close_msg                    :: {non_neg_integer(), string()},
                  authen_callback,
                  callback,
                  state,
                  handle                       :: handle()
                 }).
-define(ETS, sockjs_table).


-type(session_or_undefined() :: session() | undefined).
-type(session_or_pid() :: session() | pid()).

%% --------------------------------------------------------------------------

-spec init() -> ok.
init() ->
    _ = ets:new(?ETS, [public, named_table]),
    ok.

-spec start_link(session_or_undefined(), service(), info()) -> {ok, pid()}.
start_link(SessionId, Service, Info) ->
    gen_server:start_link(?MODULE, {SessionId, Service, Info}, []).

-spec maybe_create(session_or_undefined(), service(), info()) -> pid().
maybe_create(SessionId, Service, Info) ->
    case ets:lookup(?ETS, SessionId) of
        []          -> {ok, SPid} = sockjs_session_sup:start_child(
                                      SessionId, Service, Info),
                       SPid;
        [{_, SPid}] -> SPid
    end.


-spec received(list(iodata()), session_or_pid()) -> ok.
received(Messages, SessionPid) when is_pid(SessionPid) ->
    case gen_server:call(SessionPid, {received, Messages}, infinity) of
        ok    -> ok;
        error -> throw(no_session)
                 %% TODO: should we respond 404 when session is closed?
    end;
received(Messages, SessionId) ->
    received(Messages, spid(SessionId)).

-spec send(iodata(), handle()) -> ok.
send(Data, {?MODULE, {SPid, _}}) ->
    gen_server:cast(SPid, {send, Data}),
    ok.

-spec close(non_neg_integer(), string(), handle()) -> ok.
close(Code, Reason, {?MODULE, {SPid, _}}) ->
    gen_server:cast(SPid, {close, Code, Reason}),
    ok.

-spec info(handle()) -> info().
info({?MODULE, {_SPid, Info}}) ->
    Info.

-spec reply(session_or_pid()) ->
                   wait | session_in_use | {ok | close, frame()}.
reply(Session) ->
    reply(Session, true).

-spec reply(session_or_pid(), boolean()) ->
                   wait | session_in_use | {ok | close, frame()}.
reply(SessionPid, Multiple) when is_pid(SessionPid) ->
    gen_server:call(SessionPid, {reply, self(), Multiple}, infinity);
reply(SessionId, Multiple) ->
    reply(spid(SessionId), Multiple).

%% --------------------------------------------------------------------------

cancel_timer_safe(Timer, Atom) ->
    case erlang:cancel_timer(Timer) of
        false ->
             receive Atom -> ok
             after 0 -> ok end;
        _ -> ok
    end.

spid(SessionId) ->
    case ets:lookup(?ETS, SessionId) of
        []          -> throw(no_session);
        [{_, SPid}] -> SPid
    end.

%% Mark a process as waiting for data.
%% 1) The same process may ask for messages multiple times.
mark_waiting(Pid, State = #session{response_pid    = Pid,
                                   disconnect_tref = undefined}) ->
    State;
%% 2) Noone else waiting - link and start heartbeat timeout.
mark_waiting(Pid, State = #session{response_pid    = undefined,
                                   disconnect_tref = DisconnectTRef,
                                   heartbeat_delay = HeartbeatDelay})
  when DisconnectTRef =/= undefined ->
    link(Pid),
    cancel_timer_safe(DisconnectTRef, session_timeout),
    TRef = erlang:send_after(HeartbeatDelay, self(), heartbeat_triggered),
    State#session{response_pid    = Pid,
                  disconnect_tref = undefined,
                  heartbeat_tref  = TRef}.

%% Prolong session lifetime.
%% 1) Maybe clear up response_pid if already awaiting.
unmark_waiting(RPid, State = #session{response_pid     = RPid,
                                      heartbeat_tref   = HeartbeatTRef,
                                      disconnect_tref  = undefined,
                                      disconnect_delay = DisconnectDelay}) ->
    unlink(RPid),
    _ = case HeartbeatTRef of
            undefined -> ok;
            triggered -> ok;
            _Else     -> cancel_timer_safe(HeartbeatTRef, heartbeat_triggered)
        end,
    TRef = erlang:send_after(DisconnectDelay, self(), session_timeout),
    State#session{response_pid    = undefined,
                  heartbeat_tref  = undefined,
                  disconnect_tref = TRef};

%% 2) prolong disconnect timer if no connection is waiting
unmark_waiting(_Pid, State = #session{response_pid     = undefined,
                                      disconnect_tref  = DisconnectTRef,
                                      disconnect_delay = DisconnectDelay})
  when DisconnectTRef =/= undefined ->
    cancel_timer_safe(DisconnectTRef, session_timeout),
    TRef = erlang:send_after(DisconnectDelay, self(), session_timeout),
    State#session{disconnect_tref = TRef};

%% 3) Event from someone else? Ignore.
unmark_waiting(RPid, State = #session{response_pid    = Pid,
                                      disconnect_tref = undefined})
  when Pid =/= undefined andalso Pid =/= RPid ->
    State.

%% Get result of authentication callback if it exists.
%% Otherwise return ``authen_callback_not_found``.
get_authen_callback_result(AuthenCallback, Handle, What, UserState) ->
    case erlang:is_function(AuthenCallback) of
        true ->
            AuthenCallback(Handle, What, UserState);
        false ->
            authen_callback_not_found
    end.

-spec emit(emittable(), #session{}) -> #session{}.
emit(What, State = #session{authen_callback = AuthenCallback,
                            callback        = Callback,
                            state           = UserState,
                            handle          = Handle}) ->
    R = case Callback of
            _ when is_function(Callback) ->
                % try to evaluate state using authentication callback
                case get_authen_callback_result(AuthenCallback, Handle, What, UserState) of
                    authen_callback_not_found ->
                        State1 = State#session{authen_callback = undefined},
                        % do normal action with main service
                        Callback(Handle, What, UserState);
                    {success, UserState1} ->
                        % authenticate successfully
                        State1 = State#session{authen_callback = undefined},
                        {ok, UserState1};
                    Else ->
                        State1 = State,
                        Else
                end;
            _ when is_atom(Callback) ->
                case What of
                    init ->
                        State1 = State,
                        % init first
                        {ok, UserState1} = Callback:sockjs_init(Handle, UserState),
                        % then try to evaluate state using authentication callback
                        case get_authen_callback_result(AuthenCallback, Handle, What, UserState1) of
                            authen_callback_not_found ->
                                {ok, UserState1};
                            Else ->
                                Else
                        end;
                    {recv, Data} ->
                        % try to evaluate state using authentication callback
                        case get_authen_callback_result(AuthenCallback, Handle, What, UserState) of
                            authen_callback_not_found ->
                                State1 = State,
                                % do normal action with channel service
                                Callback:sockjs_handle(Handle, Data, UserState);
                            {success, UserState1} ->
                                % authenticate successfully
                                State1 = State#session{authen_callback = undefined},
                                {ok, UserState1};
                            Else ->
                                State1 = State,
                                Else
                        end;
                    closed ->
                        State1 = State,
                        % try to evaluate state using authentication callback first
                        case get_authen_callback_result(AuthenCallback, Handle, What, UserState) of
                            {Status, UserState1} when Status =:= success orelse Status =:= ok ->
                                ok;
                            _Else ->
                                UserState1 = UserState
                        end,
                        % terminate channel
                        Callback:sockjs_terminate(Handle, UserState1)
                end
        end,
    case R of
        {ok, UserState2} -> State1#session{state = UserState2};
        ok               -> State1
    end.

%% --------------------------------------------------------------------------

-spec init({session_or_undefined(), service(), info()}) -> {ok, #session{}}.
init({SessionId, #service{authen_callback  = AuthenCallback,
                          callback         = Callback,
                          state            = UserState,
                          disconnect_delay = DisconnectDelay,
                          heartbeat_delay  = HeartbeatDelay}, Info}) ->
    case SessionId of
        undefined -> ok;
        _Else     -> ets:insert(?ETS, {SessionId, self()})
    end,
    process_flag(trap_exit, true),
    TRef = erlang:send_after(DisconnectDelay, self(), session_timeout),
    {ok, #session{id               = SessionId,
                  authen_callback  = AuthenCallback,
                  callback         = Callback,
                  state            = UserState,
                  response_pid     = undefined,
                  disconnect_tref  = TRef,
                  disconnect_delay = DisconnectDelay,
                  heartbeat_tref   = undefined,
                  heartbeat_delay  = HeartbeatDelay,
                  handle           = {?MODULE, {self(), Info}}}}.


handle_call({reply, Pid, _Multiple}, _From, State = #session{
                                               response_pid = undefined,
                                               ready_state  = connecting}) ->
    State0 = emit(init, State),
    State1 = unmark_waiting(Pid, State0),
    {reply, {ok, {open, nil}},
     State1#session{ready_state = open}};

handle_call({reply, Pid, _Multiple}, _From, State = #session{
                                              ready_state = closed,
                                              close_msg   = CloseMsg}) ->
    State1 = unmark_waiting(Pid, State),
    {reply, {close, {close, CloseMsg}}, State1};


handle_call({reply, Pid, _Multiple}, _From, State = #session{
                                             response_pid = RPid})
  when RPid =/= Pid andalso RPid =/= undefined ->
    %% don't use unmark_waiting(), this shouldn't touch the session lifetime
    {reply, session_in_use, State};

handle_call({reply, Pid, Multiple}, _From, State = #session{
                                             ready_state    = open,
                                             response_pid   = RPid,
                                             heartbeat_tref = HeartbeatTRef,
                                             outbound_queue = Q})
  when RPid == undefined orelse RPid == Pid ->
    {Messages, Q1} = case Multiple of
                         true  -> {queue:to_list(Q), queue:new()};
                         false -> case queue:out(Q) of
                                      {{value, Msg}, Q2} -> {[Msg], Q2};
                                      {empty, Q2}        -> {[], Q2}
                                  end
                     end,
    case {Messages, HeartbeatTRef} of
        {[], triggered} -> State1 = unmark_waiting(Pid, State),
                           {reply, {ok, {heartbeat, nil}}, State1};
        {[], _TRef}     -> State1 = mark_waiting(Pid, State),
                           {reply, wait, State1};
        _More           -> State1 = unmark_waiting(Pid, State),
                           {reply, {ok, {data, Messages}},
                            State1#session{outbound_queue = Q1}}
    end;

handle_call({received, Messages}, _From, State = #session{ready_state = open}) ->
    State2 = lists:foldl(fun(Msg, State1) ->
                                 emit({recv, iolist_to_binary(Msg)}, State1)
                         end, State, Messages),
    {reply, ok, State2};

handle_call({received, _Data}, _From, State = #session{ready_state = _Any}) ->
    {reply, error, State};

handle_call(Request, _From, State) ->
    {stop, {odd_request, Request}, State}.


handle_cast({send, Data}, State = #session{outbound_queue = Q,
                                           response_pid   = RPid}) ->
    case RPid of
        undefined -> ok;
        _Else     -> RPid ! go
    end,
    {noreply, State#session{outbound_queue = queue:in(Data, Q)}};

handle_cast({close, Status, Reason},  State = #session{response_pid = RPid}) ->
    case RPid of
        undefined -> ok;
        _Else     -> RPid ! go
    end,
    {noreply, State#session{ready_state = closed,
                            close_msg = {Status, Reason}}};

handle_cast(Cast, State) ->
    {stop, {odd_cast, Cast}, State}.


handle_info({'EXIT', Pid, _Reason},
            State = #session{response_pid = Pid}) ->
    %% It is illegal for a connection to go away when receiving, we
    %% may lose some messages that are in transit. Kill current
    %% session.
    {stop, normal, State#session{response_pid = undefined}};

handle_info(force_shutdown, State) ->
    %% Websockets may want to force closure sometimes
    {stop, normal, State};

handle_info(session_timeout, State = #session{response_pid = undefined}) ->
    {stop, normal, State};

handle_info(heartbeat_triggered, State = #session{response_pid = RPid}) when RPid =/= undefined ->
    RPid ! go,
    {noreply, State#session{heartbeat_tref = triggered}};

handle_info(Info, State) ->
    {stop, {odd_info, Info}, State}.


terminate(_, State = #session{id = SessionId}) ->
    ets:delete(?ETS, SessionId),
    _ = emit(closed, State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

