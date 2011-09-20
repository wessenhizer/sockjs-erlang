-module(sockjs_filters).

-export([handle_req/3, dispatch/2]).
-export([xhr_polling/5, xhr_streaming/5, xhr_send/5, jsonp/5, jsonp_send/5,
         iframe/5, eventsource/5, htmlfile/5, chunking_test/5,
         welcome_screen/5]).
-export([cache_for/4, h_sid/4, h_no_cache/4, xhr_cors/4, expect_xhr/4,
         expect_form/4]).
-export([chunking_loop/2]).

-define(IFRAME, "<!DOCTYPE html>
<html>
<head>
  <meta http-equiv=\"X-UA-Compatible\" content=\"IE=edge\" />
  <meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />
  <script>
    document.domain = document.domain;
    _sockjs_onload = function(){SockJS.bootstrap_iframe();};
  </script>
  <script src=\"~s\"></script>
</head>
<body>
  <h2>Don't panic!</h2>
  <p>This is a SockJS hidden iframe. It's used for cross domain magic.</p>
</body>
</html>").

-define(IFRAME_HTMLFILE, "<!doctype html>
<html><head>
  <meta http-equiv=\"X-UA-Compatible\" content=\"IE=edge\" />
  <meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />
</head><body><h2>Don't panic!</h2>
  <script>
    document.domain = document.domain;
    var c = parent.~s;
    c.start();
    function p(d) {c.message(d);};
    window.onload = function() {c.stop();};
  </script>").

handle_req(Req, Path, Dispatcher) ->
    case dispatch(Path, Dispatcher) of
        {Fun, Server, SessionId, {Action, Filters}} ->
            io:format("~s ~s~n", [Req:get(method), Path]),
            sockjs_session:maybe_create(SessionId, Fun),
            Headers = lists:foldl(
                        fun (F, Headers0) ->
                                sockjs_filters:F(Req, Headers0,
                                                 Server, SessionId)
                        end, [], Filters),
            sockjs_filters:Action(Req, Headers, Server, SessionId, Fun);
        nomatch ->
            nomatch
    end.

dispatch(Path, Dispatcher) ->
    case lists:foldl(
           fun ({Match, Filters}, nomatch) -> case Match(Path) of
                                                  nomatch -> nomatch;
                                                  Rest    -> [Filters | Rest]
                                              end;
               (_,         A)              -> A
           end, nomatch, filters()) of
        nomatch ->
            nomatch;
        [Filters, FunS, Server, Session] ->
            case proplists:get_value(list_to_atom(FunS), Dispatcher) of
                undefined -> nomatch;
                Fun       -> {Fun, Server, Session, Filters}
            end
    end.

filters() ->
    %% websocket does not actually go via handle_req/3 but we need
    %% something in dispatch/2
    [{t("/websocket"),               {dummy,          []}},
     {t("/xhr_send"),                {xhr_send,       [h_sid, xhr_cors, expect_xhr]}},
     {t("/xhr"),                     {xhr_polling,    [h_sid, xhr_cors]}},
     {t("/xhr_streaming"),           {xhr_streaming,  [h_sid, xhr_cors]}},
     {t("/jsonp_send"),              {jsonp_send,     [h_sid, expect_form]}},
     {t("/jsonp"),                   {jsonp,          [h_sid, h_no_cache]}},
     {t("/eventsource"),             {eventsource,    [h_sid, h_no_cache]}},
     {t("/htmlfile"),                {htmlfile,       [h_sid, h_no_cache]}},
     {p(""),                         {welcome_screen, []}},
     {p("/iframe[0-9-.a-z_]*.html"), {iframe,         [cache_for]}},
     {p("/chunking_test"),           {chunking_test,  [h_sid, xhr_cors, expect_xhr]}}
    ].

%% TODO make relocatable (here?)
p(S) -> fun (Path) -> re(Path, "^([^/.]+)" ++ S ++ "[/]?\$") end.
t(S) -> fun (Path) -> re(Path, "^([^/.]+)/([^/.]+)/([^/.]+)" ++ S ++ "\$") end.

re(Path, S) ->
    case re:run(Path, S, [{capture, all_but_first, list}]) of
        nomatch                          -> nomatch;
        {match, [FunS]}                  -> [FunS, dummy, dummy];
        {match, [FunS, Server, Session]} -> [FunS, Server, Session]
    end.

%% --------------------------------------------------------------------------

%% This is send but it receives - "send" from the client POV, receive
%% from ours.
xhr_send(Req, Headers, _Server, SessionId, Receive) ->
    receive_body(Req:get(body), SessionId, Receive),
    %% FF assumes that the response is XML.
    Req:respond(204, [{"content-type", "text/plain"}] ++ Headers, "").

xhr_polling(Req, Headers, _Server, SessionId, _Receive) ->
    headers(Req, Headers),
    reply_loop(Req, SessionId, true, fun fmt_xhr/1).

%% TODO Do something sensible with client closing timeouts
xhr_streaming(Req, Headers, _Server, SessionId, _Receive) ->
    headers(Req, Headers),
    %% IE requires 2KB prefix:
    %% http://blogs.msdn.com/b/ieinternals/archive/2010/04/06/comet-streaming-in-internet-explorer-with-xmlhttprequest-and-xdomainrequest.aspx
    chunk(Req, list_to_binary(string:copies("h", 2048)), fun fmt_xhr/1),
    reply_loop(Req, SessionId, false, fun fmt_xhr/1).

jsonp_send(Req, Headers, _Server, SessionId, Receive) ->
    Body = proplists:get_value("d", Req:parse_post()),
    receive_body(Body, SessionId, Receive),
    Req:respond(200, Headers, "").

jsonp(Req, Headers, _Server, SessionId, _Receive) ->
    headers(Req, Headers),
    CB = callback(Req),
    reply_loop(Req, SessionId, true, fun (Body) -> fmt_jsonp(Body, CB) end).

iframe(Req, Headers, _Server, _SessionId, _Receive) ->
    {ok, URL} = application:get_env(sockjs, sockjs_url),
    IFrame = fmt(?IFRAME, [URL]),
    MD5 = "\"" ++ binary_to_list(base64:encode(erlang:md5(IFrame))) ++ "\"",
    case header(Req, 'If-None-Match') of
        MD5 -> Req:respond(304, "");
        _   -> Req:ok([{"Content-Type", "text/html; charset=UTF-8"},
                       {"ETag",         MD5}] ++ Headers, IFrame)
    end.

eventsource(Req, Headers, _Server, SessionId, _Receive) ->
    headers(Req, Headers, "text/event-stream; charset=UTF-8"),
    chunk(Req, <<$\r, $\n, $\r, $\n>>),
    reply_loop(Req, SessionId, true, fun fmt_eventsource/1).

htmlfile(Req, Headers, _Server, SessionId, _Receive) ->
    headers(Req, Headers, "text/html; charset=UTF-8"),
    IFrame0 = fmt(?IFRAME_HTMLFILE, [callback(Req)]),
    %% Safari needs at least 1024 bytes to parse the website. Relevant:
    %%   http://code.google.com/p/browsersec/wiki/Part2#Survey_of_content_sniffing_behaviors
    Padding = list_to_binary(string:copies(" ", 1024 - size(IFrame0))),
    IFrame = <<IFrame0/binary, Padding/binary, $\r, $\n, $\r, $\n>>,
    chunk(Req, IFrame),
    reply_loop(Req, SessionId, false, fun fmt_htmlfile/1).

chunking_test(Req, Headers, _Server, _SessionId, _Receive) ->
    headers(Req, Headers),
    Write = fun(P) -> chunk(Req, P, fun fmt_xhr/1) end,
    %% IE requires 2KB prelude
    Prelude = list_to_binary(string:copies(" ", 2048)),
    chunking_loop(Req, [{0,    Write, <<Prelude/binary, "h">>},
                        {5,    Write, <<"h">>},
                        {25,   Write, <<"h">>},
                        {125,  Write, <<"h">>},
                        {625,  Write, <<"h">>},
                        {3125, Write, <<"h">>}]).

chunking_loop(Req,  []) -> Req:chunk(done);
chunking_loop(Req, [{Timeout, Write, Payload} | Rest]) ->
    Write(Payload),
    timer:apply_after(Timeout, ?MODULE, chunking_loop, [Req, Rest]).

welcome_screen(Req, Headers, _Server, _SessionId, _Receive) ->
    Req:ok([{"Content-Type", "text/plain; charset=UTF-8"}] ++ Headers,
           "Welcome to SockJS!\n").

%% --------------------------------------------------------------------------

cache_for(_Req, Headers, _Server, _SessionId) ->
    Year = 365 * 24 * 60 * 60,
    Expires = calendar:gregorian_seconds_to_datetime(
                calendar:datetime_to_gregorian_seconds(
                  calendar:now_to_datetime(now())) + Year),
    [{"Cache-Control", "public, max-age=" ++ integer_to_list(Year)},
     {"Expires",       httpd_util:rfc1123_date(Expires)}] ++ Headers.

h_sid(Req, Headers, _Server, _SessionId) ->
    %% Some load balancers do sticky sessions, but only if there is
    %% a JSESSIONID cookie. If this cookie isn't yet set, we shall
    %% set it to a dumb value. It doesn't really matter what, as
    %% session information is usually added by the load balancer.
    case Req:get_cookie_value('JSESSIONID', Req:get_cookies()) of
        undefined -> [Req:set_cookie('JSESSIONID', "a") | Headers];
        _         -> Headers
    end.

h_no_cache(_Req, Headers, _Server, _SessionId) ->
    [{"Cache-Control", "no-store, no-cache, must-revalidate, max-age=0"}] ++
        Headers.

xhr_cors(Req, Headers, _Server, _SessionId) ->
    Origin = case header(Req, origin) of
                 undefined -> "*";
                 O         -> O
             end,
    AllowHeaders = case header(Req, 'access-control-request-headers') of
                       undefined -> [];
                       V         -> [{"Access-Control-Allow-Headers", V}]
                   end,
    [{"Access-Control-Allow-Origin",      Origin},
     {"Access-Control-Allow-Credentials", "true"}] ++ AllowHeaders ++ Headers.

expect_xhr(_Req, Headers, _Server, _SessionId) ->
    Headers. %% TODO

expect_form(_Req, Headers, _Server, _SessionId) ->
    Headers. %% TODO

%% --------------------------------------------------------------------------

receive_body(Body, SessionId, Receive) ->
    Decoded = mochijson2:decode(Body),
    Sender = sockjs_session:sender(SessionId),
    [Receive(Sender, {recv, Msg}) || Msg <- Decoded].

header(Req, Name) ->
    proplists:get_value(Name, Req:get(headers)).

headers(Req, Headers) ->
    headers(Req, Headers, "application/javascript; charset=UTF-8").

headers(Req, Headers, ContentType) ->
    Req:chunk(head, [{"Content-Type", ContentType}] ++ Headers).

reply_loop(Req, SessionId, Once, Fmt) ->
    case sockjs_session:reply(SessionId) of
        wait  -> receive
                     go -> reply_loop(Req, SessionId, Once, Fmt)
                 after 5000 ->
                         chunk(Req, <<"h">>, Fmt),
                         reply_loop0(Req, SessionId, Once, Fmt)
                 end;
        Reply -> chunk(Req, Reply, Fmt),
                 reply_loop0(Req, SessionId, Once, Fmt)
    end.

reply_loop0(Req, _SessionId, true, _Fmt) ->
    Req:chunk(done);
reply_loop0(Req, SessionId, false, Fmt) ->
    reply_loop(Req, SessionId, false, Fmt).

chunk(Req, Body)      -> Req:chunk(Body).
chunk(Req, Body, Fmt) -> chunk(Req, Fmt(Body)).

callback(Req) ->
    list_to_binary(proplists:get_value("c", Req:parse_qs())).

fmt_xhr(Body) -> <<Body/binary, $\n>>.

fmt_jsonp(Body, Callback) ->
    %% Yes, JSONed twice, there isn't a a better way, we must pass
    %% a string back, and the script, will be evaled() by the
    %% browser.
    Double = iolist_to_binary(mochijson2:encode(Body)),
    <<Callback/binary, "(", Double/binary, ");", $\r, $\n>>.

fmt_eventsource(Body) ->
    Escaped = iolist_to_binary(
                url_escape(binary_to_list(Body),
                           [$%, $\r, $\n, 0])), %% $% must be first!
    <<"data: ", Escaped/binary, $\r, $\n, $\r, $\n>>.

fmt_htmlfile(Body) ->
    Double = iolist_to_binary(mochijson2:encode(Body)),
    <<"<script>", $\n, "p(", Double/binary, ");", $\n, "</script>", $\r, $\n>>.

fmt(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).

url_escape("", _Chars) ->
    "";
url_escape([Char | Rest], Chars) ->
    case lists:member(Char, Chars) of
        true  -> [hex(Char) | url_escape(Rest, Chars)];
        false -> [Char | url_escape(Rest, Chars)]
    end.

hex(C) ->
    <<High0:4, Low0:4>> = <<C>>,
    High = integer_to_list(High0),
    Low = integer_to_list(Low0),
    "%" ++ High ++ Low.
