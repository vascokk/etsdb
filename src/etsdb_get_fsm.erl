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
-module(etsdb_get_fsm).

-behaviour(gen_fsm).

-export([start_link/5]).


-export([init/1, execute/2,wait_result/2,prepare/2, handle_event/3,
     handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(results,{num_ok=0,num_ok_notempty=0,num_fail=0,ok_quorum=0,fail_quorum=0,read_count=0,errors=[],data=[]}).
-record(state, {caller,preflist,partition,getquery,timeout,bucket,results,req_ref}).

start_link(Caller,Partition,Bucket,Query,Timeout) ->
    gen_fsm:start_link(?MODULE, [Caller,Partition,Bucket,Query,Timeout], []).

init([Caller,Partition,Bucket,Query,Timeout]) ->
    {ok,prepare, #state{caller=Caller,partition=Partition,getquery=Query,bucket=Bucket,timeout=Timeout},0}.


prepare(timeout, #state{caller=Caller,partition=Partition,bucket=Bucket}=StateData) ->
    ReadCount = Bucket:r_val(),
    case preflist(Partition,Bucket:r_val()) of
        {error,Error}->
            reply_to_caller(Caller,{error,Error}),
            {stop,normal,StateData};
        Preflist when length(Preflist)==ReadCount->
            NumOk = Bucket:r_quorum(),
            NumFail = ReadCount-NumOk+1,
            {next_state,execute,StateData#state{preflist=Preflist,results=#results{ok_quorum=NumOk,fail_quorum=NumFail,read_count=ReadCount}},0};
        Preflist->
            lager:error("Insufficient vnodes in preflist ~p must be ~p",[length(Preflist),ReadCount]),
            reply_to_caller(Caller,{error,insufficient_vnodes}),
            {stop,normal,StateData}
    end.
execute(timeout, #state{preflist=Preflist,getquery=Query,bucket=Bucket,timeout=Timeout}=StateData) ->
    Ref = make_ref(),
    etsdb_vnode:get_query(Ref,Preflist,Bucket,Query),
    {next_state,wait_result, StateData#state{req_ref=Ref},Timeout}.

wait_result({r,Index,ReqID,Res},#state{caller=Caller,results=Results,req_ref=ReqID,bucket=Bucket,timeout=Timeout}=StateData) ->
    case add_result(Index,Res,Bucket,Results) of
        #results{}=NewResult->
            {next_state,wait_result, StateData#state{results=NewResult},Timeout};
        ResultToReply->
             reply_to_caller(Caller,ResultToReply),
             {stop,normal,StateData}
    end;
wait_result(timeout,#state{caller=Caller,results=#results{num_ok=C,ok_quorum=C,data=Data}}=StateData) ->
    reply_to_caller(Caller,{ok,Data}),
    {stop,normal,StateData};
wait_result(timeout,#state{caller=Caller}=StateData) ->
    reply_to_caller(Caller,{error,timeout}),
    {stop,normal,StateData}.


handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.


terminate(_Reason, _StateName, _StatData) ->
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

reply_to_caller({raw,Ref,To},Reply)->
    To ! {Ref,Reply}.

preflist(Partition,WVal)->
    etsdb_apl:get_apl(Partition,WVal).


add_result(_,{ok,L},Bucket,#results{read_count=ReadCount,num_ok=Count,num_ok_notempty=NotEmptyCount,ok_quorum=Quorum,data=Acc}=Results)->
    NotEmptyCount1 = case L of
                        []->
                            NotEmptyCount;
                        _->
                            NotEmptyCount+1
                    end,
    Count1 = Count+1,
    L1 = Bucket:unserialize_result(L),
    Acc1 = Bucket:join_scan(L1,Acc),
    if
        NotEmptyCount1==Quorum->
            {ok,Acc1};
        ReadCount==Count1->
            {ok,Acc1};
        true->
            Results#results{num_ok=Count1,num_ok_notempty=NotEmptyCount1,data=Acc1}
    end;
add_result(Index,Res,_Bucket,#results{num_fail=Count,fail_quorum=Quorum,errors=Errs}=Results)->
    lager:error("Filed scan to ~p - ~p",[Index,Res]),
    Count1 = Count+1,
    if
        Count1==Quorum->
            {error,fail};
        true->
            Results#results{num_fail=Count1,errors=[{Index,Res}|Errs]}
    end.
