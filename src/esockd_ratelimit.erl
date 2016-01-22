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
%%%
%%% eSockd Rate Limiter.
%%%
%%% [Token Bucket](https://en.wikipedia.org/wiki/Token_bucket).
%%%
%%% [Leaky Bucket](https://en.wikipedia.org/wiki/Leaky_bucket#The_Leaky_Bucket_Algorithm_as_a_Meter)
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_ratelimit).

-export([new/2, check/2]).

-record(bucket, {capacity   :: pos_integer(),     %% tokens capacity
                 remaining  :: non_neg_integer(), %% available tokens
                 limitrate  :: float(),           %% bytes/millsec
                 lastime    :: pos_integer()      %% millseconds
                }).

-type bucket() :: #bucket{}.

-type ratelimit() :: {?MODULE, [bucket()]}.

-export_type([ratelimit/0]).

%%------------------------------------------------------------------------------
%% @doc Create rate limiter bucket. 限速,如果太快了,就pause一段时间
%% @end
%%------------------------------------------------------------------------------
-spec new(pos_integer(), pos_integer()) -> ratelimit().
new(Capacity, Rate) when Capacity > Rate andalso Rate > 0 ->
    Bucket = #bucket{capacity = Capacity, remaining = Capacity,
                     limitrate = Rate/1000, lastime = now_ms()},
    {?MODULE, [Bucket]}.

%%------------------------------------------------------------------------------
%% @doc Check inflow bytes.
%% @end
%%------------------------------------------------------------------------------
-spec check(bucket(), pos_integer()) -> {non_neg_integegitr(), ratelimit()}.
check(Bytes, {?MODULE, [Bucket = #bucket{capacity = Capacity, remaining = Remaining,
                                         limitrate = Rate, lastime = Lastime}]}) ->
    Tokens = lists:min([Capacity, Remaining + round(Rate * (now_ms() - Lastime))]),
    {Pause1, NewBucket} =
    case Tokens >= Bytes of
        true  -> %% Tokens available
            {0, Bucket#bucket{remaining = Tokens - Bytes, lastime = now_ms()}};
        false -> %% Tokens not enough
            Pause = round((Bytes - Tokens)/Rate),
            {Pause, Bucket#bucket{remaining = 0, lastime = now_ms() + Pause}}
    end,
    {Pause1, {?MODULE, [NewBucket]}}.%返回的结果包含一个等待时间和一个回调

now_ms() ->
    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
    (MegaSecs * 1000000 + Secs) * 1000 + round(MicroSecs/1000).

