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
%%% eSockd top supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

-export([start_listener/4, stop_listener/2, listeners/0, listener/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%=============================================================================
%%% API 启动两中类型的child,一种是esocketd_server,用于状态统计,一种是esocked_listener_sup,用于监听socket,
%%% 其中listerner对应多个child,每个child根据Listner,Port唯一定位
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start supervisor.
%% @end
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%------------------------------------------------------------------------------
%% @doc Start a listener. 启动一个esocket_listener_sup,并且配置指定的参数
%% @end
%%------------------------------------------------------------------------------
-spec start_listener(Protocol, Port, Options, MFArgs) -> {ok, pid()} when
    Protocol   :: atom(),
    Port       :: inet:port_number(),
    Options    :: [esockd:option()],
    MFArgs     :: esockd:mfargs().
start_listener(Protocol, Port, Options, MFArgs) ->
	MFA = {esockd_listener_sup, start_link,
            [Protocol, Port, Options, MFArgs]},
	ChildSpec = {child_id({Protocol, Port}), MFA,
                    transient, infinity, supervisor, [esockd_listener_sup]},
	supervisor:start_child(?MODULE, ChildSpec).

%%------------------------------------------------------------------------------
%% @doc Stop the listener. 终止一个协议的运行
%% @end
%%------------------------------------------------------------------------------
-spec stop_listener(Protocol, Port) -> ok | {error, any()} when
    Protocol :: atom(),
    Port     :: inet:port_number().
stop_listener(Protocol, Port) ->
    ChildId = child_id({Protocol, Port}),
	case supervisor:terminate_child(?MODULE, ChildId) of
    ok ->
        supervisor:delete_child(?MODULE, ChildId);
    {error, Reason} ->
        {error, Reason}
	end.

%%------------------------------------------------------------------------------
%% @doc Get Listeners.获取所有协议的Id{Protocol,Port}和对应的Pid列表
%% @end
%%------------------------------------------------------------------------------
-spec listeners() -> [{term(), pid()}].
listeners() ->
    [{Id, Pid} || {{listener_sup, Id}, Pid, supervisor, _} <- supervisor:which_children(?MODULE)].

%%------------------------------------------------------------------------------
%% @doc Get listener pid.,在外部看,协议和端口号能够唯一定位一个processId,这个接口获取对应的pid
%% @end
%%------------------------------------------------------------------------------
-spec listener({atom(), inet:port_number()}) -> undefined | pid().
listener({Protocol, Port}) ->
    ChildId = child_id({Protocol, Port}),
    case [Pid || {Id, Pid, supervisor, _} <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> undefined;
        L  -> hd(L)
    end.


%%%=============================================================================
%%% Supervisor callbacks,初始化时,只初始化了esockd_server,通过start_listener增加更多的Protocol和Port
%%%=============================================================================

init([]) ->
    {ok, {{one_for_one, 10, 100}, [?CHILD(esockd_server, worker)]} }.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% @doc Listener Child Id.,child Id是由协议和端口号共同组成的
%% @end
%%------------------------------------------------------------------------------
child_id({Protocol, Port}) ->
    {listener_sup, {Protocol, Port}}.

