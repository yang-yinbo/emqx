%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_license).

-include("emqx_license.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("typerefl/include/types.hrl").

-behaviour(emqx_config_handler).

-export([
    pre_config_update/3,
    post_config_update/5
]).

-export([
    load/0,
    check/2,
    unload/0,
    read_license/0,
    read_license/1,
    update_file/1,
    update_file_contents/1,
    update_key/1,
    license_dir/0,
    save_and_backup_license/1
]).

-define(CONF_KEY_PATH, [license]).

%% Give the license app the highest priority.
%% We don't define it in the emqx_hooks.hrl becasue that is an opensource code
%% and can be changed by the communitiy.
-define(HP_LICENSE, 2000).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

-spec read_license() -> {ok, emqx_license_parser:license()} | {error, term()}.
read_license() ->
    read_license(emqx:get_config(?CONF_KEY_PATH)).

-spec load() -> ok.
load() ->
    emqx_license_cli:load(),
    emqx_conf:add_handler(?CONF_KEY_PATH, ?MODULE),
    add_license_hook().

-spec unload() -> ok.
unload() ->
    %% Delete the hook. This means that if the user calls
    %% `application:stop(emqx_license).` from the shell, then here should no limitations!
    del_license_hook(),
    emqx_conf:remove_handler(?CONF_KEY_PATH),
    emqx_license_cli:unload().

-spec license_dir() -> file:filename().
license_dir() ->
    filename:join([emqx:data_dir(), licenses]).

%% Subdirectory relative to data dir.
-spec relative_license_path() -> file:filename().
relative_license_path() ->
    filename:join([licenses, "emqx.lic"]).

-spec update_file(binary() | string()) ->
    {ok, emqx_config:update_result()} | {error, emqx_config:update_error()}.
update_file(Filename) when is_binary(Filename); is_list(Filename) ->
    case file:read_file(Filename) of
        {ok, Contents} ->
            update_file_contents(Contents);
        {error, Error} ->
            {error, Error}
    end.

-spec update_file_contents(binary() | string()) ->
    {ok, emqx_config:update_result()} | {error, emqx_config:update_error()}.
update_file_contents(Contents) when is_binary(Contents) ->
    Result = emqx_conf:update(
        ?CONF_KEY_PATH,
        {file, Contents},
        #{rawconf_with_defaults => true, override_to => local}
    ),
    handle_config_update_result(Result).

-spec update_key(binary() | string()) ->
    {ok, emqx_config:update_result()} | {error, emqx_config:update_error()}.
update_key(Value) when is_binary(Value); is_list(Value) ->
    Result = emqx_conf:update(
        ?CONF_KEY_PATH,
        {key, Value},
        #{rawconf_with_defaults => true, override_to => cluster}
    ),
    handle_config_update_result(Result).

%%------------------------------------------------------------------------------
%% emqx_hooks
%%------------------------------------------------------------------------------

check(_ConnInfo, AckProps) ->
    case emqx_license_checker:limits() of
        {ok, #{max_connections := ?ERR_EXPIRED}} ->
            ?SLOG(error, #{msg => "connection_rejected_due_to_license_expired"}),
            {stop, {error, ?RC_QUOTA_EXCEEDED}};
        {ok, #{max_connections := MaxClients}} ->
            case check_max_clients_exceeded(MaxClients) of
                true ->
                    ?SLOG(error, #{msg => "connection_rejected_due_to_license_limit_reached"}),
                    {stop, {error, ?RC_QUOTA_EXCEEDED}};
                false ->
                    {ok, AckProps}
            end;
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "connection_rejected_due_to_license_not_loaded",
                reason => Reason
            }),
            {stop, {error, ?RC_QUOTA_EXCEEDED}}
    end.

%%------------------------------------------------------------------------------
%% emqx_config_handler callbacks
%%------------------------------------------------------------------------------

pre_config_update(_, Cmd, Conf) ->
    {ok, do_update(Cmd, Conf)}.

post_config_update(_Path, _Cmd, NewConf, _Old, _AppEnvs) ->
    case read_license(NewConf) of
        {ok, License} ->
            {ok, emqx_license_checker:update(License)};
        {error, _} = Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% Private functions
%%------------------------------------------------------------------------------

add_license_hook() ->
    ok = emqx_hooks:put('client.connect', {?MODULE, check, []}, ?HP_LICENSE).

del_license_hook() ->
    _ = emqx_hooks:del('client.connect', {?MODULE, check, []}),
    ok.

do_update({file, NewContents}, Conf) ->
    Res = emqx_license_proto_v2:save_and_backup_license(mria_mnesia:running_nodes(), NewContents),
    %% assert
    true = lists:all(fun(X) -> X =:= {ok, ok} end, Res),
    %% Must be relative to the data dir, since different nodes might
    %% have different data directories configured...
    LicensePath = relative_license_path(),
    maps:remove(<<"key">>, Conf#{<<"type">> => file, <<"file">> => LicensePath});
do_update({key, Content}, Conf) when is_binary(Content); is_list(Content) ->
    case emqx_license_parser:parse(Content) of
        {ok, _License} ->
            maps:remove(<<"file">>, Conf#{<<"type">> => key, <<"key">> => Content});
        {error, Reason} ->
            erlang:throw(Reason)
    end;
%% We don't do extra action when update license's watermark.
do_update(_Other, Conf) ->
    Conf.

save_and_backup_license(NewLicenseKey) ->
    %% Must be relative to the data dir, since different nodes might
    %% have different data directories configured...
    CurrentLicensePath = filename:join(emqx:data_dir(), relative_license_path()),
    LicenseDir = filename:dirname(CurrentLicensePath),
    case filelib:ensure_dir(CurrentLicensePath) of
        ok -> ok;
        {error, EnsureError} -> throw({error_creating_license_dir, EnsureError})
    end,
    case file:read_file(CurrentLicensePath) of
        {ok, NewLicenseKey} ->
            %% same contents; nothing to do.
            ok;
        {ok, _OldContents} ->
            Time = calendar:system_time_to_rfc3339(erlang:system_time(second)),
            BackupPath = filename:join([
                LicenseDir,
                "emqx.lic." ++ Time ++ ".backup"
            ]),
            case file:copy(CurrentLicensePath, BackupPath) of
                {ok, _} -> ok;
                {error, CopyError} -> throw({error_backing_up_license, CopyError})
            end,
            ok;
        {error, enoent} ->
            ok;
        {error, Error} ->
            throw({error_reading_existing_license, Error})
    end,
    case file:write_file(CurrentLicensePath, NewLicenseKey) of
        ok -> ok;
        {error, WriteError} -> throw({error_writing_license, WriteError})
    end,
    ok.

check_max_clients_exceeded(MaxClients) ->
    emqx_license_resources:connection_count() > MaxClients * 1.1.

read_license(#{type := file, file := Filename}) ->
    case file:read_file(Filename) of
        {ok, Content} ->
            emqx_license_parser:parse(Content);
        {error, _} = Error ->
            %% Could be a relative path in data folder after update.
            FilenameDataDir = filename:join(emqx:data_dir(), Filename),
            case file:read_file(FilenameDataDir) of
                {ok, Content} -> emqx_license_parser:parse(Content);
                _Error -> Error
            end
    end;
read_license(#{type := key, key := Content}) ->
    emqx_license_parser:parse(Content).

handle_config_update_result({error, {post_config_update, ?MODULE, Error}}) ->
    {error, Error};
handle_config_update_result({error, _} = Error) ->
    Error;
handle_config_update_result({ok, #{post_config_update := #{emqx_license := Result}}}) ->
    {ok, Result}.
