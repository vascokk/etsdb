%% -------------------------------------------------------------------
%%
%%
%% Copyright (c) Dreyk.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
-module(etsdb_get).

-export([scan/3,scan/4,scan_acc/4,scan_acc/5]).

-define(DEFAULT_TIMEOUT,60000).

-include("etsdb_request.hrl").

scan_acc(Bucket,From,To,Acc)->
    scan_acc(Bucket,From,To,Acc,?DEFAULT_TIMEOUT).
scan_acc(Bucket,From,To,Acc,Timeout)->
    {From1,To1,Partitions} = Bucket:scan_partiotions(From,To),
    scan_partiotions(Bucket,From1,To1,Acc,Partitions,[],Timeout).

scan(Bucket,From,To)->
    scan(Bucket,From,To,?DEFAULT_TIMEOUT).
scan(Bucket,From,To,Timeout)->
    case Bucket:scan_partiotions(From,To) of
        {From1,To1,Partitions}->
            scan_partiotions(Bucket,From1,To1,[],Partitions,[],Timeout);
        emty->
            {ok,[]};
        #scan_it{rgn_count=I} when I<0->
            {ok,[]};
        #scan_it{}=It->
            macan(Bucket,It,Timeout)
    end.
macan(Bucket,#scan_it{partition=all,from=From,to=To},Timeout)->
    ReqRef = make_ref(),
    Me = self(),
    etsdb_mscan_all_fsm:start_link({raw,ReqRef,Me},Bucket, {scan,From,To,[]},Timeout),
    case wait_for_results(ReqRef,client_wait_timeout(Timeout)) of
        {ok,Res} when is_list(Res)->
            {ok,Res};
        Else->
            lager:error("Bad scan responce for range (~p - ~p) ~p used timeout ~p",[From,To,Else,Timeout]),
            etsdb_util:make_error_response(Else)
    end;
macan(Bucket,#scan_it{from=From,to=To}=It,Timeout)->
    ReqRef = make_ref(),
    Me = self(),
    etsdb_mscan_fsm:start_link({raw,ReqRef,Me},Bucket,It, {scan,From,To,[]},Timeout),
    case wait_for_results(ReqRef,client_wait_timeout(Timeout)) of
        {ok,Res} when is_list(Res)->
            {ok,Res};
        Else->
            lager:error("Bad scan responce for range (~p - ~p) ~p used timeout ~p",[From,To,Else,Timeout]),
            etsdb_util:make_error_response(Else)
    end.
scan_partiotions(_Bucket,_From,_To,_InitaialAcc,[],Acc,_Timeout)->
    {ok,Acc};
scan_partiotions(Bucket,From,To,InitaialAcc,[Partition|T],Acc,Timeout)->
    ReqRef = make_ref(),
    Me = self(),
    PartionIdx = crypto:hash(sha,Partition),
    etsdb_get_fsm:start_link({raw,ReqRef,Me},PartionIdx, Bucket, {scan,From,To,InitaialAcc},Timeout),
    case wait_for_results(ReqRef,client_wait_timeout(Timeout)) of
        {ok,Res} when is_list(Res)->
            scan_partiotions(Bucket,From,To,InitaialAcc,T,Bucket:join_scan(Res,Acc),Timeout);
        Else->
            lager:error("Bad scan responce for ~p - ~p",[Partition,Else]),
            etsdb_util:make_error_response(Else)
    end.

wait_for_results(ReqRef,Timeout)->
    receive 
        {ReqRef,Res}->
            Res
    after Timeout->
            {error,timeout}
    end.

%%Add 50ms to operation timeout
client_wait_timeout(Timeout)->
    Timeout + 50.