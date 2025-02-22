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
-module(etsdb_socket_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_socket/0]).

start_socket() ->
    supervisor:start_child(?MODULE, []).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
    {ok,
     {{simple_one_for_one, 10, 10},
      [{undefined,
        {etsdb_socket_server, start_link, []},
        temporary, brutal_kill, worker, [etsdb_socket_server]}]}}.
