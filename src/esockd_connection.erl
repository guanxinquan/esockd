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
%%% eSockd tcp/ssl connection that wraps transport and socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_connection).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([new/3, start_link/2, go/2, wait/1, upgrade/1]).

-export([transport/1, sock/1, opts/1, type/1, getopts/2, setopts/2, getstat/2,
         controlling_process/2, peername/1, sockname/1]).

-export([send/2, async_send/2, recv/2, recv/3, async_recv/2, async_recv/3,
         shutdown/2, close/1, fast_close/1]).

-type parameter() :: any().

-type connection() :: {?MODULE, list(parameter())}.

-export_type([connection/0]).

-define(CONN_MOD, {?MODULE, [_Sock, _SockFun, _Opts]}).

-define(CONN_MOD(Sock), {?MODULE, [Sock, _SockFun, _Opts]}).

-define(Transport, esockd_transport).

%%------------------------------------------------------------------------------
%% @doc Create a connection
%% @end
%%------------------------------------------------------------------------------
-spec new(Sock, SockFun, Opts) -> connection() when
    Sock    :: inet:socket(),
    SockFun :: esockd:sock_fun(),
    Opts    :: list(atom()|tuple()).
new(Sock, SockFun, Opts) ->
    {?MODULE, [Sock, SockFun, parse_opt(Opts)]}.


%%parse_opt主要处理rate_limit参数,rate_limit参数在配置时,应当有两个前面一个是capcity,后面一个是rate中间用逗号隔开
%%分析结束之后,rate_limit参数就变成了{esocket_ratelimit,Bucket}
parse_opt(Opts) ->
    parse_opt(Opts, []).
parse_opt([], Acc) ->
    Acc;
parse_opt([{rate_limit, Str} | Opts], Acc) ->
    parse_opt(Opts, [{rate_limit, parse_rl(Str)}|Acc]);
parse_opt([Opt | Opts], Acc) ->
    parse_opt(Opts, [Opt | Acc]).
parse_rl(Str) ->
    Bps = fun(S) -> list_to_integer(string:strip(S)) * 1024 end,
    [Burst, Rate] = [Bps(S) || S <- string:tokens(Str, ",")],
    esockd_ratelimit:new(Burst, Rate).

%%------------------------------------------------------------------------------
%% @doc Start the connection process. 执行用户自定义的Moudule和Function
%% @end
%%------------------------------------------------------------------------------
-spec start_link(esockd:mfargs(), connection()) -> {ok, pid()}
                                                 | {error, any()}
                                                 | ignore.
start_link(M, Conn = ?CONN_MOD) when is_atom(M) ->
    M:start_link(Conn);

start_link({M, F}, Conn = ?CONN_MOD) when is_atom(M), is_atom(F) ->
    M:F(Conn);

start_link({M, F, Args}, Conn = ?CONN_MOD)
    when is_atom(M), is_atom(F), is_list(Args) ->
    erlang:apply(M, F, [Conn|Args]).

%%------------------------------------------------------------------------------
%% @doc Tell the connection proccess that socket is ready.
%%      Called by acceptor.
%% 将socket的控制权交给用户进程后,调用这个接口,通知用户,socket准备好了,可以处理数据
%% @end
%%------------------------------------------------------------------------------
-spec go(pid(), connection()) -> any().
go(Pid, Conn = ?CONN_MOD) ->
    Pid ! {go, Conn}.

%%------------------------------------------------------------------------------
%% @doc Connection process wait for 'go' and upgrade self.
%%      Called by connection process.
%% 用户在process创建成功之后,调用这个wait,将等待连接处理成功,这个连接处理主要是等待sup进程将socket的控制权交给用户进程
%% @end
%%------------------------------------------------------------------------------
-spec wait(connection()) -> {ok, connection()}.
wait(Conn = ?CONN_MOD) ->
	receive {go, Conn} -> upgrade(Conn) end.

%%------------------------------------------------------------------------------
%% @doc Upgrade Socket.
%%      Called by connection proccess.
%%      调用socketFun获取新的socket
%% @end
%%------------------------------------------------------------------------------
-spec upgrade(connection()) -> {ok, connection()}.
upgrade({?MODULE, [Sock, SockFun, Opts]}) ->
    case SockFun(Sock) of %sockFun实际用于解决ssl配置ssl_upgrade_fun下面的ssl_upgrade_fun
        {ok, NewSock} ->
            {ok, {?MODULE, [NewSock, SockFun, Opts]}};
        {error, Error} ->
            erlang:error(Error)
    end.

%%------------------------------------------------------------------------------
%% @doc Transport of the connection.
%% @end
%%------------------------------------------------------------------------------
-spec transport(connection()) -> atom().
transport({?MODULE, [_Sock, _SockFun, _Opts]}) ->
    ?Transport.

%%------------------------------------------------------------------------------
%% @doc Socket of the connection. 
%% @end
%%------------------------------------------------------------------------------
-spec sock(connection()) -> inet:socket() | esockd:ssl_socket().
sock({?MODULE, [Sock, _SockFun, _Opts]}) ->
    Sock.

%%------------------------------------------------------------------------------
%% @doc Connection options
%% @end
%%------------------------------------------------------------------------------
-spec opts(connection()) -> list(atom() | tuple()).
opts({?MODULE, [_Sock, _SockFun, Opts]}) ->
    Opts.

%%------------------------------------------------------------------------------
%% @doc Socket type of the connection.
%% @end
%%------------------------------------------------------------------------------
-spec type(connection()) -> tcp | ssl.
type(?CONN_MOD(Sock)) ->
    ?Transport:type(Sock).

%%------------------------------------------------------------------------------
%% @doc Sockname of the connection.
%% @end
%%------------------------------------------------------------------------------
-spec sockname(connection()) -> {ok, {Address, Port}} | {error, any()} when
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
sockname(?CONN_MOD(Sock)) ->
    ?Transport:sockname(Sock).

%%------------------------------------------------------------------------------
%% @doc Peername of the connection.
%% @end
%%------------------------------------------------------------------------------
-spec peername(connection()) -> {ok, {Address, Port}} | {error, any()} when
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
peername(?CONN_MOD(Sock)) ->
    ?Transport:peername(Sock).

%%------------------------------------------------------------------------------
%% @doc Get socket options
%% @end
%%------------------------------------------------------------------------------
getopts(Keys, ?CONN_MOD(Sock)) ->
    ?Transport:getopts(Sock, Keys).

%%------------------------------------------------------------------------------
%% @doc Set socket options
%% @end
%%------------------------------------------------------------------------------
setopts(Options, ?CONN_MOD(Sock)) ->
    ?Transport:setopts(Sock, Options).

%%------------------------------------------------------------------------------
%% @doc Get socket stats
%% @end
%%------------------------------------------------------------------------------
getstat(Stats, ?CONN_MOD(Sock)) ->
    ?Transport:getstat(Sock, Stats).

%%------------------------------------------------------------------------------
%% @doc Controlling Process of Connection
%% @end
%%------------------------------------------------------------------------------
-spec controlling_process(pid(), connection()) -> any().
controlling_process(Owner, ?CONN_MOD(Sock)) ->
    ?Transport:controlling_process(Sock, Owner).

%%------------------------------------------------------------------------------
%% @doc Send data
%% @end
%%------------------------------------------------------------------------------
-spec send(iodata(), connection()) -> ok.
send(Data, ?CONN_MOD(Sock)) ->
    ?Transport:send(Sock, Data).

%%------------------------------------------------------------------------------
%% @doc Send data asynchronously by port_command/2
%% @end
%%------------------------------------------------------------------------------
-spec async_send(iodata(), connection()) -> ok.
async_send(Data, ?CONN_MOD(Sock)) ->
    ?Transport:port_command(Sock, Data).

%%------------------------------------------------------------------------------
%% @doc Receive data
%% @end
%%------------------------------------------------------------------------------
recv(Length, ?CONN_MOD(Sock)) ->
    ?Transport:recv(Sock, Length).

recv(Length, Timeout, ?CONN_MOD(Sock)) ->
    ?Transport:recv(Sock, Length, Timeout).

%%------------------------------------------------------------------------------
%% @doc Receive data asynchronously
%% @end
%%------------------------------------------------------------------------------
async_recv(Length, ?CONN_MOD(Sock)) ->
    ?Transport:async_recv(Sock, Length, infinity).

async_recv(Length, Timeout, ?CONN_MOD(Sock)) ->
    ?Transport:async_recv(Sock, Length, Timeout).

%%------------------------------------------------------------------------------
%% @doc Shutdown connection
%% @end
%%------------------------------------------------------------------------------
-spec shutdown(How, connection()) -> ok | {error, Reason :: any()} when
    How :: read | write | read_write.
shutdown(How, ?CONN_MOD(Sock)) ->
    ?Transport:shutdown(Sock, How).

%%------------------------------------------------------------------------------
%% @doc Close socket
%% @end
%%------------------------------------------------------------------------------
-spec close(connection()) -> ok.
close(?CONN_MOD(Sock)) ->
    ?Transport:close(Sock).

%%------------------------------------------------------------------------------
%% @doc Close socket by port_close
%% @end
%%------------------------------------------------------------------------------
-spec fast_close(connection()) -> ok.
fast_close(?CONN_MOD(Sock)) ->
    ?Transport:fast_close(Sock).

