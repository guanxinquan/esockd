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
%%% eSockd Listener Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_listener_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-export([start_link/4, connection_sup/1, acceptor_sup/1]).

-export([init/1]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start listener supervisor 这个sup一共管理三个child,分别是
%%      esocked_connection_sup 过滤连接,控制连接数量,统计连接关闭量等,如果连接创建成功,那么封装连接要访问的接口(实际上调用的是Transport)
%%      esockd_acceptor_sup,
%%      esockd_listener
%%      并且这三个child的启动有一定的次序
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Protocol, Port, Options, MFArgs) -> {ok, pid()} when
    Protocol  :: atom(),
    Port      :: inet:port_number(),
    Options	  :: [esockd:option()],
    MFArgs    :: esockd:mfargs().
start_link(Protocol, Port, Options, MFArgs) ->
    Logger = logger(Options),
    {ok, Sup} = supervisor:start_link(?MODULE, []),%启动sup
    %启动Connction sup
	{ok, ConnSup} = supervisor:start_child(Sup,
		{connection_sup,
			{esockd_connection_sup, start_link, [Options, MFArgs, Logger]},
				transient, infinity, supervisor, [esockd_connection_sup]}),
    AcceptStatsFun = esockd_server:stats_fun({Protocol, Port}, accepted),%初始化了一个accepted的统计
    BufferTuneFun = buffer_tune_fun(proplists:get_value(buffer, Options),%如果buf相应的参数没有配置,那么默认将buffer,设置为发送buf,接收buf和buf三者的最大值
                              proplists:get_value(tune_buffer, Options, false)),
	{ok, AcceptorSup} = supervisor:start_child(Sup,
		{acceptor_sup,
			{esockd_acceptor_sup, start_link, [ConnSup, AcceptStatsFun, BufferTuneFun, Logger]},
				transient, infinity, supervisor, [esockd_acceptor_sup]}),%%acceptor 用于异步监听
	{ok, _Listener} = supervisor:start_child(Sup,
		{listener,
			{esockd_listener, start_link, [Protocol, Port, Options, AcceptorSup, Logger]},
				transient, 16#ffffffff, worker, [esockd_listener]}),
	{ok, Sup}.

%%------------------------------------------------------------------------------
%% @doc Get connection supervisor.
%% @end
%%------------------------------------------------------------------------------
connection_sup(Sup) ->
    child_pid(Sup, connection_sup).

%%------------------------------------------------------------------------------
%% @doc Get acceptor supervisor.
%% @end
%%------------------------------------------------------------------------------
acceptor_sup(Sup) ->
    child_pid(Sup, acceptor_sup).

%%------------------------------------------------------------------------------
%% @doc Get child pid with id.
%% @private
%% @end
%%------------------------------------------------------------------------------
child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _} <- supervisor:which_children(Sup), Id =:= ChildId]).
    
%%%=============================================================================
%%% Supervisor callbacks,这里使用的是rest_for_one,就是所某个child挂了,它之后启动的所有child都要重新启动
%%%=============================================================================
init([]) ->
    {ok, {{rest_for_one, 10, 100}, []}}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
%%默认的这个buffer_tune_fun,就是将发送buf,接受buf和buffer的值中最大值赋值到buffer中
%% when 'buffer' is undefined, and 'tune_buffer' is true... 
buffer_tune_fun(undefined, true) ->
    fun(Sock) -> 
        case inet:getopts(Sock, [sndbuf, recbuf, buffer]) of
            {ok, BufSizes} -> 
                BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
                inet:setopts(Sock, [{buffer, BufSz}]);
            Error -> 
                Error
        end
    end;

buffer_tune_fun(_, _) ->
    fun(_Sock) -> ok end.

logger(Options) ->
    {ok, Default} = application:get_env(esockd, logger),
    gen_logger:new(proplists:get_value(logger, Options, Default)).

