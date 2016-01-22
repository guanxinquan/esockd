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
%%% eSockd main api.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

%% Start Application.
-export([start/0]).

%% Core API
-export([open/4, close/2, close/1]).

%% Management API
-export([listeners/0, listener/1,
         get_stats/1,
         get_acceptors/1,
         get_max_clients/1,
         set_max_clients/2,
         get_current_clients/1,
         get_shutdown_count/1]).

%% Allow, Deny API
-export([get_access_rules/1, allow/2, deny/2]).

%% Utility functions...
-export([ulimit/0]).

-type ssl_socket() :: #ssl_socket{}. %ssl_socket是由tcp和ssl两个socket组成

-type tune_fun() :: fun((inet:socket()) -> ok | {error, any()}).

-type sock_fun() :: fun((inet:socket()) -> {ok, inet:socket() | ssl_socket()} | {error, any()}).

-type sock_args()  :: {atom(), inet:socket(), sock_fun()}.

-type mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}.

-type option() ::
		{acceptors, pos_integer()} | %acceptors的数量
		{max_clients, pos_integer()} |%最大的客户端连结数
        {access, [esockd_access:rule()]} |%ip地址白名单
        {shutdown, brutal_kill | infinity | pos_integer()} |
        {tune_buffer, false | true} |%是否需要对buffer进行调整,主要是根据sendBuf,recvBuf和buffer的大小,确定buffer的大小
        {logger, atom() | {atom(), atom()}} |%logger配置
        {ssl, list()} | %%TODO: [ssl:ssloption()]
        {sockopts, [gen_tcp:listen_option()]}.%sockopts 正常的tcp配置

-export_type([ssl_socket/0, sock_fun/0, sock_args/0, tune_fun/0, mfargs/0, option/0]).

%%------------------------------------------------------------------------------
%% @doc Start esockd application.
%% @end
%%------------------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(esockd).

%%------------------------------------------------------------------------------
%% @doc Open a listener. socketd的实例是与protocol加port保证唯一性的
%% @end
%%------------------------------------------------------------------------------
-spec open(Protocol, Port, Options, MFArgs) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(), %协议名称
    Port         :: inet:port_number(),%端口号
    Options		 :: [option()], 
    MFArgs       :: mfargs().%mfa 回调的方法
open(Protocol, Port, Options, MFArgs) ->
	esockd_sup:start_listener(Protocol, Port, Options, MFArgs).

%%------------------------------------------------------------------------------
%% @doc Close the listener
%% @end
%%------------------------------------------------------------------------------
-spec close({Protocol, Port}) -> ok when
    Protocol    :: atom(),
    Port        :: inet:port_number().
close({Protocol, Port}) when is_atom(Protocol) and is_integer(Port) ->
    close(Protocol, Port).

-spec close(Protocol, Port) -> ok when 
    Protocol    :: atom(),
    Port        :: inet:port_number().
close(Protocol, Port) when is_atom(Protocol) and is_integer(Port) ->
	esockd_sup:stop_listener(Protocol, Port).

%%------------------------------------------------------------------------------
%% @doc Get listeners 返回所有listeners [{{protocol,port},pid}]
%% @end
%%------------------------------------------------------------------------------
-spec listeners() -> [{{atom(), inet:port_number()}, pid()}].
listeners() ->
    esockd_sup:listeners().

%%------------------------------------------------------------------------------
%% @doc Get one listener 返回指定的pid
%% @end
%%------------------------------------------------------------------------------
-spec listener({atom(), inet:port_number()}) -> pid() | undefined.
listener({Protocol, Port}) ->
    esockd_sup:listener({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc Get stats 获取统计信息
%% @end
%%------------------------------------------------------------------------------
-spec get_stats({atom(), inet:port_number()}) -> [{atom(), non_neg_integer()}].
get_stats({Protocol, Port}) ->
    esockd_server:get_stats({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc Get acceptors number,获取acceptor的数量
%% @end
%%------------------------------------------------------------------------------
-spec get_acceptors({atom(), inet:port_number()}) -> undefined | pos_integer().
get_acceptors({Protocol, Port}) ->
    with_listener({Protocol, Port}, fun get_acceptors/1);%with_listener是用于获取LSup,之后通过LSup获取到对应的信息
get_acceptors(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),%获取acceptor_sup
    esockd_acceptor_sup:count_acceptors(AcceptorSup).%通过acceptor_sup获取到acceptor的实例数量

%%------------------------------------------------------------------------------
%% @doc Get max clients 获取配置的Max Client
%% @end
%%------------------------------------------------------------------------------
-spec get_max_clients({atom(), inet:port_number()} | pid()) -> undefined | pos_integer().
get_max_clients({Protocol, Port}) ->
    with_listener({Protocol, Port}, fun get_max_clients/1);
get_max_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_max_clients(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Set max clients
%% @end
%%------------------------------------------------------------------------------
-spec set_max_clients({atom(), inet:port_number()} | pid(), pos_integer()) -> undefined | pos_integer().
set_max_clients({Protocol, Port}, MaxClients) ->
    with_listener({Protocol, Port}, fun set_max_clients/2, [MaxClients]);
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:set_max_clients(ConnSup, MaxClients).

%%------------------------------------------------------------------------------
%% @doc Get current clients 获取当前已经连接的客户端数量
%% @end
%%------------------------------------------------------------------------------
-spec get_current_clients({atom(), inet:port_number()}) -> undefined | pos_integer().
get_current_clients({Protocol, Port}) ->
    with_listener({Protocol, Port}, fun get_current_clients/1);
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connections(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Get shutdown count 获取已经关闭的连接数量
%% @end
%%------------------------------------------------------------------------------
-spec get_shutdown_count({atom(), inet:port_number()}) -> undefined | pos_integer().
get_shutdown_count({Protocol, Port}) ->
    with_listener({Protocol, Port}, fun get_shutdown_count/1);
get_shutdown_count(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_shutdown_count(ConnSup).%% 这个数量存放在对应的conn sup的进程字典中

%%------------------------------------------------------------------------------
%% @doc Get access rules 获取ip白名单,过滤规则
%% @end
%%------------------------------------------------------------------------------
-spec get_access_rules({atom(), inet:port_number()}) -> [esockd_access:rule()] | undefined.
get_access_rules({Protocol, Port}) ->
    with_listener({Protocol, Port}, fun get_access_rules/1);
get_access_rules(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:access_rules(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Allow access address 白名单
%% @end
%%------------------------------------------------------------------------------
-spec allow({atom(), inet:port_number()}, all | esockd_access:cidr()) -> ok | {error, any()}.
allow({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:allow(ConnSup, CIDR).

%%------------------------------------------------------------------------------
%% @doc Deny access address 黑名单
%% @end
%%------------------------------------------------------------------------------
-spec deny({atom(), inet:port_number()}, all | esockd_access:cidr()) -> ok | {error, any()}.
deny({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:deny(ConnSup, CIDR).

%%------------------------------------------------------------------------------
%% @doc System 'ulimit -n'
%% @end
%%------------------------------------------------------------------------------
-spec ulimit() -> pos_integer().
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

%%------------------------------------------------------------------------------
%% @doc With Listener. 通过Protocol和port获取到对应的ListenerSup,之后将ListenerSup做为fun的第一个参数传入,并调用对应的fun
%% @end
%%------------------------------------------------------------------------------
with_listener({Protocol, Port}, Fun) ->
    with_listener({Protocol, Port}, Fun, []).

with_listener({Protocol, Port}, Fun, Args) ->
    LSup = listener({Protocol, Port}),
    with_listener(LSup, Fun, Args);
with_listener(undefined, _Fun, _Args) ->
    undefined;
with_listener(LSup, Fun, Args) when is_pid(LSup) ->
    apply(Fun, [LSup|Args]).

