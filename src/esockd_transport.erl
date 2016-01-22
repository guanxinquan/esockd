%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% eSockd TCP/SSL Transport
%%% 抽象了一个TCP和SSL的通用接口
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_transport).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([type/1]).

-export([listen/2, send/2, port_command/2,
         recv/2, recv/3,
         async_recv/2, async_recv/3,
         controlling_process/2,
         close/1, fast_close/1]).

-export([getopts/2, setopts/2, getstat/2]).

-export([sockname/1, peername/1, shutdown/2]).

%% tcp -> sslsocket
-export([ssl_upgrade_fun/1]).

-define(SSL_CLOSE_TIMEOUT, 5000).

-define(SSL_HANDSHAKE_TIMEOUT, 5000).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc socket type: tcp | ssl
%% @end
%%------------------------------------------------------------------------------
-spec type(inet:socket() | esockd:ssl_socket()) -> tcp | ssl.
type(Sock) when is_port(Sock) ->
    tcp;
type(#ssl_socket{ssl = _SslSock})  ->
    ssl.

%%------------------------------------------------------------------------------
%% @doc Listen
%% @end
%%------------------------------------------------------------------------------
-spec listen(Port, SockOpts) -> {ok, Sock} | {error, Reason :: any()} when
    Port        :: inet:port_number(),
    SockOpts    :: [gen_tcp:listen_option()],
    Sock      :: inet:socket().
listen(Port, SockOpts) ->
    gen_tcp:listen(Port, SockOpts).

%%------------------------------------------------------------------------------
%% @doc Set Controlling Process of Socket
%% @end
%%------------------------------------------------------------------------------
-spec controlling_process(Sock, NewOwener) -> ok | {error, Reason :: any()} when
    Sock        :: inet:socket() | esockd:ssl_socket(),
    NewOwener   :: pid().
controlling_process(Sock, NewOwner) when is_port(Sock) ->
    inet:tcp_controlling_process(Sock, NewOwner);
controlling_process(#ssl_socket{ssl = SslSock}, NewOwner) ->
    ssl:controlling_process(SslSock, NewOwner).

%%------------------------------------------------------------------------------
%% @doc Close Sock
%% @end
%%------------------------------------------------------------------------------
-spec close(Sock :: inet:socket() | esockd:ssl_socket()) -> ok.
close(Sock) when is_port(Sock) ->
    gen_tcp:close(Sock);
close(#ssl_socket{ssl = SslSock}) ->
    ssl:close(SslSock).

fast_close(Sock) when is_port(Sock) ->
    catch port_close(Sock), ok;
%% From rabbit_net.erl
fast_close(#ssl_socket{tcp = Sock, ssl = SslSock}) ->
    %% We cannot simply port_close the underlying tcp socket since the
    %% TLS protocol is quite insistent that a proper closing handshake
    %% should take place (see RFC 5245 s7.2.1). So we call ssl:close
    %% instead, but that can block for a very long time, e.g. when
    %% there is lots of pending output and there is tcp backpressure,
    %% or the ssl_connection process has entered the the
    %% workaround_transport_delivery_problems function during
    %% termination, which, inexplicably, does a gen_tcp:recv(Socket,
    %% 0), which may never return if the client doesn't send a FIN or
    %% that gets swallowed by the network. Since there is no timeout
    %% variant of ssl:close, we construct our own.
    {Pid, MRef} = spawn_monitor(fun() -> ssl:close(SslSock) end),
    erlang:send_after(?SSL_CLOSE_TIMEOUT, self(), {Pid, ssl_close_timeout}),
    receive
        {Pid, ssl_close_timeout} ->
            erlang:demonitor(MRef, [flush]),
            exit(Pid, kill);
        {'DOWN', MRef, process, Pid, _Reason} ->
            ok
    end,
    catch port_close(Sock), ok.

%%------------------------------------------------------------------------------
%% @doc Send data
%% @end
%%------------------------------------------------------------------------------
-spec send(Sock, Data) -> ok when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Data    :: iolist().
send(Sock, Data) when is_port(Sock) ->
    gen_tcp:send(Sock, Data);
send(#ssl_socket{ssl = SslSock}, Data) ->
    ssl:send(SslSock, Data).

%%------------------------------------------------------------------------------
%% @doc Port command to write data
%% @end
%%------------------------------------------------------------------------------
port_command(Sock, Data) when is_port(Sock) ->
    erlang:port_command(Sock, Data);
port_command(Sock = #ssl_socket{ssl = SslSock}, Data) ->
    case ssl:send(SslSock, Data) of
        ok -> self() ! {inet_reply, Sock, ok}, true;
        {error, Reason} -> erlang:error(Reason)
    end.

%%------------------------------------------------------------------------------
%% @doc Receive Data
%% @end
%%------------------------------------------------------------------------------
-spec recv(Sock, Length) -> {ok, Data} | {error, Reason :: any()} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Length  :: non_neg_integer(),
    Data    :: [char()] | binary().
recv(Sock, Length) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length);
recv(#ssl_socket{ssl = SslSock}, Length)  ->
    ssl:recv(SslSock, Length).

-spec recv(Sock, Length, Timout) -> {ok, Data} | {error, closed | atom()} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Length  :: non_neg_integer(),
    Timout  :: timeout(),
    Data    :: [char()] | binary().
recv(Sock, Length, Timeout) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length, Timeout);
recv(#ssl_socket{ssl = SslSock}, Length, Timeout)  ->
    ssl:recv(SslSock, Length, Timeout).

%%------------------------------------------------------------------------------
%% @doc Async Receive data
%% @end
%%------------------------------------------------------------------------------
-spec async_recv(Sock, Length) -> {ok, Ref} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Length  :: non_neg_integer(),
    Ref     :: reference().
async_recv(Sock, Length) ->
    async_recv(Sock, Length, infinity).

-spec async_recv(Sock, Length, Timeout) -> {ok, Ref} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Length  :: non_neg_integer(),
    Timeout :: non_neg_integer() | infinity,
    Ref     :: reference().
async_recv(Sock = #ssl_socket{ssl = SslSock}, Length, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    spawn(fun () -> Self ! {inet_async, Sock, Ref,
        ssl:recv(SslSock, Length, Timeout)}
    end),
    {ok, Ref};
async_recv(Sock, Length, infinity) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, -1);
async_recv(Sock, Length, Timeout) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, Timeout).

%%------------------------------------------------------------------------------
%% @doc Get socket options
%% @end
%%------------------------------------------------------------------------------
getopts(Sock, OptionNames) when is_port(Sock) ->
    inet:getopts(Sock, OptionNames);
getopts(#ssl_socket{ssl = SslSock}, OptionNames) ->
    ssl:getopts(SslSock, OptionNames).

%%------------------------------------------------------------------------------
%% @doc Set socket options
%% @end
%%------------------------------------------------------------------------------
setopts(Sock, Options) when is_port(Sock) ->
    inet:setopts(Sock, Options);
setopts(#ssl_socket{ssl = SslSock}, Options) ->
    ssl:setopts(SslSock, Options).

%%------------------------------------------------------------------------------
%% @doc Get socket stats
%% @end
%%------------------------------------------------------------------------------
-spec getstat(Sock, Stats) -> {ok, Values} | {error, any()} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Stats   :: list(),
    Values  :: list().
getstat(Sock, Stats) when is_port(Sock) ->
    inet:getstat(Sock, Stats);
getstat(#ssl_socket{tcp = Sock}, Stats) ->
    inet:getstat(Sock, Stats).

%%------------------------------------------------------------------------------
%% @doc Sock name
%% @end
%%------------------------------------------------------------------------------
-spec sockname(Sock) -> {ok, {Address, Port}} | {error, any()} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
sockname(Sock) when is_port(Sock) ->
    inet:sockname(Sock);
sockname(#ssl_socket{ssl = SslSock}) ->
    ssl:sockname(SslSock).

%%------------------------------------------------------------------------------
%% @doc Socket peername
%% @end
%%------------------------------------------------------------------------------
-spec peername(Sock) -> {ok, {Address, Port}} | {error, any()} when
    Sock  :: inet:socket() | esockd:ssl_socket(),
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
peername(Sock) when is_port(Sock) ->
    inet:peername(Sock);
peername(#ssl_socket{ssl = SslSock}) ->
    ssl:peername(SslSock).

%%------------------------------------------------------------------------------
%% @doc Shutdown socket
%% @end
%%------------------------------------------------------------------------------
-spec shutdown(Sock, How) -> ok | {error, Reason :: any()} when
    Sock    :: inet:socket() | esockd:ssl_socket(),
    How     :: read | write | read_write.
shutdown(Sock, How) when is_port(Sock) ->
    gen_tcp:shutdown(Sock, How);
shutdown(#ssl_socket{ssl = SslSock}, How) ->
    ssl:shutdown(SslSock, How).

%%------------------------------------------------------------------------------
%% @doc Function that upgrade socket to sslsocket
%% @end
%%------------------------------------------------------------------------------
ssl_upgrade_fun(undefined) ->
    fun(Sock) when is_port(Sock) -> {ok, Sock} end;

ssl_upgrade_fun(SslOpts) ->
    Timeout = proplists:get_value(handshake_timeout, SslOpts, ?SSL_HANDSHAKE_TIMEOUT),
    SslOpts1 = proplists:delete(handshake_timeout, SslOpts),
    fun(Sock) when is_port(Sock) ->
        case catch ssl:ssl_accept(Sock, SslOpts1, Timeout) of
            {ok, SslSock} ->
                {ok, #ssl_socket{tcp = Sock, ssl = SslSock}};
            {error, Reason} ->
                {error, {ssl_error, Reason}};
            {'EXIT', Reason} -> 
                {error, {ssl_failure, Reason}}
        end
    end.

