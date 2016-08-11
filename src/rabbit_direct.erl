%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_direct).

-export([boot/0, force_event_refresh/1, list/0, connect/5,
         start_channel/9, disconnect/2]).
%% Internal
-export([list_local/0]).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-spec boot() -> 'ok'.
-spec force_event_refresh(reference()) -> 'ok'.
-spec list() -> [pid()].
-spec list_local() -> [pid()].
-spec connect
        (({'none', 'none'} | {rabbit_types:username(), 'none'} |
          {rabbit_types:username(), rabbit_types:password()}),
         rabbit_types:vhost(), rabbit_types:protocol(), pid(),
         rabbit_event:event_props()) ->
            rabbit_types:ok_or_error2(
              {rabbit_types:user(), rabbit_framing:amqp_table()},
              'broker_not_found_on_node' |
              {'auth_failure', string()} | 'access_refused').
-spec start_channel
        (rabbit_channel:channel_number(), pid(), pid(), string(),
         rabbit_types:protocol(), rabbit_types:user(), rabbit_types:vhost(),
         rabbit_framing:amqp_table(), pid()) ->
            {'ok', pid()}.
-spec disconnect(pid(), rabbit_event:event_props()) -> 'ok'.

%%----------------------------------------------------------------------------

boot() -> rabbit_sup:start_supervisor_child(
            rabbit_direct_client_sup, rabbit_client_sup,
            [{local, rabbit_direct_client_sup},
             {rabbit_channel_sup, start_link, []}]).

force_event_refresh(Ref) ->
    [Pid ! {force_event_refresh, Ref} || Pid <- list()],
    ok.

list_local() ->
    pg_local:get_members(rabbit_direct).

list() ->
    rabbit_misc:append_rpc_all_nodes(rabbit_mnesia:cluster_nodes(running),
                                     rabbit_direct, list_local, []).

%%----------------------------------------------------------------------------

connect({none, _}, VHost, Protocol, Pid, Infos) ->
    connect0(fun () -> {ok, rabbit_auth_backend_dummy:user()} end,
             VHost, Protocol, Pid, Infos);

connect({Username, none}, VHost, Protocol, Pid, Infos) ->
    connect0(fun () -> rabbit_access_control:check_user_login(Username, []) end,
             VHost, Protocol, Pid, Infos);

connect({Username, Password}, VHost, Protocol, Pid, Infos) ->
    connect0(fun () -> rabbit_access_control:check_user_login(
                         Username, [{password, Password}, {vhost, VHost}]) end,
             VHost, Protocol, Pid, Infos).

connect0(AuthFun, VHost, Protocol, Pid, Infos) ->
    case rabbit:is_running() of
        true  -> case AuthFun() of
                     {ok, User = #user{username = Username}} ->
                         notify_auth_result(Username,
                           user_authentication_success, []),
                         connect1(User, VHost, Protocol, Pid, Infos);
                     {refused, Username, Msg, Args} ->
                         notify_auth_result(Username,
                           user_authentication_failure,
                           [{error, rabbit_misc:format(Msg, Args)}]),
                         {error, {auth_failure, "Refused"}}
                 end;
        false -> {error, broker_not_found_on_node}
    end.

notify_auth_result(Username, AuthResult, ExtraProps) ->
    EventProps = [{connection_type, direct},
                  {name, case Username of none -> ''; _ -> Username end}] ++
                 ExtraProps,
    rabbit_event:notify(AuthResult, [P || {_, V} = P <- EventProps, V =/= '']).

authz_socket_info_direct(Infos) ->
    #authz_socket_info{sockname={proplists:get_value(host, Infos),
                                 proplists:get_value(port, Infos)},
                       peername={proplists:get_value(peer_host, Infos),
                                 proplists:get_value(peer_port, Infos)}}.

connect1(User, VHost, Protocol, Pid, Infos) ->
    try rabbit_access_control:check_vhost_access(User, VHost, authz_socket_info_direct(Infos)) of
        ok -> ok = pg_local:join(rabbit_direct, Pid),
	      rabbit_core_metrics:connection_created(Pid, Infos),
              rabbit_event:notify(connection_created, Infos),
              {ok, {User, rabbit_reader:server_properties(Protocol)}}
    catch
        exit:#amqp_error{name = Reason = not_allowed} ->
            {error, Reason}
    end.

start_channel(Number, ClientChannelPid, ConnPid, ConnName, Protocol, User,
              VHost, Capabilities, Collector) ->
    {ok, _, {ChannelPid, _}} =
        supervisor2:start_child(
          rabbit_direct_client_sup,
          [{direct, Number, ClientChannelPid, ConnPid, ConnName, Protocol,
            User, VHost, Capabilities, Collector}]),
    {ok, ChannelPid}.

disconnect(Pid, Infos) ->
    pg_local:leave(rabbit_direct, Pid),
    rabbit_core_metrics:connection_closed(Pid),
    rabbit_event:notify(connection_closed, Infos).
