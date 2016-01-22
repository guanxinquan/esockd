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
%%% eSockd Server.这实际上是封装了一个使用ets存储统计信息的一个统计,统计使用protocol,port+统计量的名字
%%% 作为key,数值作为value.可以获取指定protocol+port对应的所有统计量的值,也可以获取,增加或者减少某个统计量的值
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_server).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% Start esockd server
-export([start_link/0]).

%% stats API
-export([stats_fun/2,
         get_stats/1,
         inc_stats/3, dec_stats/3,
         init_stats/2, del_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

-define(STATS_TAB, esockd_stats).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start esockd server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% @doc New Stats Fun.创建一个stats函数,这个函数有两种参数,一种是对某种属性增加一定数量,一种是对某种属性减少一定数量,在实际存储中,使用的是ets
%% @end
%%------------------------------------------------------------------------------
-spec stats_fun({atom(), inet:port_number()}, atom()) -> fun().
stats_fun({Protocol, Port}, Metric) ->
    init_stats({Protocol, Port}, Metric),
    fun({inc, Num}) -> esockd_server:inc_stats({Protocol, Port}, Metric, Num);
       ({dec, Num}) -> esockd_server:dec_stats({Protocol, Port}, Metric, Num)
    end.

%%------------------------------------------------------------------------------
%% @doc Get Stats.获取某个portocol和port的所有统计属性
%% @end
%%------------------------------------------------------------------------------
-spec get_stats({atom(), inet:port_number()}) -> [{atom(), non_neg_integer()}].
get_stats({Protocol, Port}) ->
    [{Metric, Val} || [Metric, Val]
                      <- ets:match(?STATS_TAB, {{{Protocol, Port}, '$1'}, '$2'})].

%%------------------------------------------------------------------------------
%% @doc Inc Stats.对某个protocol,port的某项属性增加一定量的值
%% @end
%%------------------------------------------------------------------------------
-spec inc_stats({atom(), inet:port_number()}, atom(), pos_integer()) -> any().
inc_stats({Protocol, Port}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, Port}, Metric}, Num).
    
%%------------------------------------------------------------------------------
%% @doc Dec Stats.对某个protocol,port的某项属性减少一定量的值
%% @end
%%------------------------------------------------------------------------------
-spec dec_stats({atom(), inet:port_number()}, atom(), pos_integer()) -> any().
dec_stats({Protocol, Port}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, Port}, Metric}, -Num).

%%------------------------------------------------------------------------------
%% @private
%% @doc Update stats counter.对value进行一个number的操作
%% @end
%%------------------------------------------------------------------------------
update_counter(Key, Num) ->
    ets:update_counter(?STATS_TAB, Key, {2, Num}).

%%------------------------------------------------------------------------------
%% @doc Init Stats.
%% @end
%%------------------------------------------------------------------------------
-spec init_stats({atom(), inet:port_number()}, atom()) -> ok.
init_stats({Protocol, Port}, Metric) ->
    gen_server:call(?SERVER, {init, {Protocol, Port}, Metric}).

%%------------------------------------------------------------------------------
%% @doc Del Stats.
%% @end
%%------------------------------------------------------------------------------
-spec del_stats({atom(), inet:port_number()}) -> ok.
del_stats({Protocol, Port}) ->
    gen_server:cast(?SERVER, {del, {Protocol, Port}}).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

init([]) ->
    ets:new(?STATS_TAB, [set, public, named_table, {write_concurrency, true}]),
    {ok, #state{}}.

%%将Protocol,Port和Metric三个属性做为key,value实际上是一个计数
handle_call({init, {Protocol, Port}, Metric}, _From, State) ->
    Key = {{Protocol, Port}, Metric},
    ets:insert(?STATS_TAB, {Key, 0}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({del, {Protocol, Port}}, State) ->
    ets:match_delete(?STATS_TAB, {{{Protocol, Port}, '_'}, '_'}),
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

