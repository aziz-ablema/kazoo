%%%-------------------------------------------------------------------
%%% @copyright (C) 2012 VoIP Inc
%%% @doc
%%% Conference participant process
%%% @end
%%% Created : 20 Feb 2012 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(conf_participant).

-behaviour(gen_listener).

-include("conference.hrl").

%% API
-export([start_link/1]).
-export([relay_amqp/2]).
-export([handle_participants_resp/2]).
-export([handle_authn_req/2]).
-export([handle_route_req/2, handle_route_win/2]).

-export([consume_call_events/1]).
-export([conference/1, set_conference/2]).
-export([discovery_event/1, set_discovery_event/2]).
-export([call/1]).

-export([join_local/1]).
-export([join_remote/2]).

-export([mute/1, unmute/1, toggle_mute/1]).
-export([deaf/1, undeaf/1, toggle_deaf/1]).
-export([hangup/1]).

%% gen_server callbacks
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-define(SERVER, ?MODULE).

-define(RESPONDERS, [{{?MODULE, relay_amqp}, [{<<"call_event">>, <<"*">>}]}
                     ,{{?MODULE, handle_participants_resp}, [{<<"conference">>, <<"participants_resp">>}]}
                     ,{{?MODULE, handle_authn_req}, [{<<"directory">>, <<"authn_req">>}]}
                     ,{{?MODULE, handle_route_req}, [{<<"dialplan">>, <<"route_req">>}]}
                     ,{{?MODULE, handle_route_win}, [{<<"dialplan">>, <<"route_win">>}]}
                    ]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-record(participant, {participant_id = 0
                      ,call = undefined
                      ,bridge = undefined
                      ,bridge_request = undefined
                      ,moderator = false
                      ,muted = false
                      ,deaf = false
                      ,waiting_for_mod = false
                      ,call_event_consumers = []
                      ,self = self()
                      ,in_conference = false
                      ,conference = #conference{}
                      ,discovery_event = wh_json:new()
                     }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Call) ->    
    CallId = whapps_call:call_id(Call),
    Bindings = [{call, [{callid, CallId}]}
                ,{self, []}
               ],
    gen_listener:start_link(?MODULE, [{responders, ?RESPONDERS}
                                      ,{bindings, Bindings}
                                      ,{queue_name, ?QUEUE_NAME}
                                      ,{queue_options, ?QUEUE_OPTIONS}
                                      ,{consume_options, ?CONSUME_OPTIONS}
                                     ], [Call]).

-spec conference/1 :: (pid()) -> {ok, #conference{}}.
conference(Srv) ->
    gen_server:call(Srv, {get_conference}, 500).

-spec set_conference/2 :: (#conference{}, pid()) -> 'ok'.
set_conference(Conference, Srv) ->
    gen_server:cast(Srv, {set_conference, Conference}).

-spec discovery_event/1 :: (pid()) -> {ok, wh_json:json_object()}.
discovery_event(Srv) ->
    gen_server:call(Srv, {get_discovery_event}, 500).

-spec set_discovery_event/2 :: (wh_json:json_object(), pid()) -> 'ok'.
set_discovery_event(DiscoveryEvent, Srv) ->
    gen_server:cast(Srv, {set_discovery_event, DiscoveryEvent}).

-spec call/1 :: (pid()) -> {ok, whapps_call:call()}.
call(Srv) ->
    gen_server:call(Srv, {get_call}, 500).

-spec join_local/1 :: (pid()) -> 'ok'.
join_local(Srv) ->
    gen_server:cast(Srv, join_local).

-spec join_remote/2 :: (pid(), wh_json:json_object()) -> 'ok'.
join_remote(Srv, JObj) ->
    gen_server:cast(Srv, {join_remote, JObj}).
        
-spec mute/1 :: (pid()) -> ok.
mute(Srv) ->
    gen_server:cast(Srv, mute).

-spec unmute/1 :: (pid()) -> ok.
unmute(Srv) ->
    gen_server:cast(Srv, unmute).

-spec toggle_mute/1 :: (pid()) -> ok.
toggle_mute(Srv) ->
    gen_server:cast(Srv, toggle_mute).

-spec deaf/1 :: (pid()) -> ok.
deaf(Srv) ->
    gen_server:cast(Srv, deaf).

-spec undeaf/1 :: (pid()) -> ok.
undeaf(Srv) ->
    gen_server:cast(Srv, undeaf).

-spec toggle_deaf/1 :: (pid()) -> ok.
toggle_deaf(Srv) ->
    gen_server:cast(Srv, toggle_deaf).

-spec hangup/1 :: (pid()) -> ok.
hangup(Srv) ->
    gen_server:cast(Srv, hangup).

-spec consume_call_events/1 :: (pid()) -> ok.
consume_call_events(Srv) ->
    gen_server:cast(Srv, {add_consumer, self()}).    

-spec relay_amqp/2 :: (wh_json:json_object(), proplist()) -> ok.
relay_amqp(JObj, Props) ->
    [Pid ! {amqp_msg, JObj}
     || Pid <- props:get_value(call_event_consumers, Props, [])
            ,is_pid(Pid)
    ],
    Digit = wh_json:get_value(<<"DTMF-Digit">>, JObj),
    case is_binary(Digit) andalso props:get_value(in_conference, Props, false) of
        false -> ok;
        true ->
            Srv = props:get_value(server, Props),
            case Digit of
                <<"1">> -> mute(Srv);
                <<"2">> -> unmute(Srv);
                <<"0">> -> toggle_mute(Srv);
                <<"3">> -> deaf(Srv);
                <<"4">> -> undeaf(Srv);
                <<"*">> -> toggle_deaf(Srv);
                <<"#">> -> hangup(Srv);
                _Else -> ok
            end
    end.

-spec handle_participants_resp/2 :: (wh_json:json_object(), proplist()) -> ok.
handle_participants_resp(JObj, Props) ->
    true = wapi_conference:participants_resp_v(JObj),
    Srv = props:get_value(server, Props),
    Participants = wh_json:get_value(<<"Participants">>, JObj, wh_json:new()),
    gen_server:cast(Srv, {sync_participant, Participants}).

-spec handle_authn_req/2 :: (wh_json:json_object(), proplist()) -> ok.
handle_authn_req(JObj, Props) ->
    true = wapi_authn:req_v(JObj),
    BridgeRequest = props:get_value(bridge_request, Props),
    case wh_json:get_value(<<"Method">>, JObj) =:= <<"INVITE">>
        andalso binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>) of
        [BridgeRequest, _] ->
            Srv = props:get_value(server, Props),
            gen_server:cast(Srv, {authn_req, JObj});
        _Else -> ok
    end,
    ok.

-spec handle_route_req/2 :: (wh_json:json_object(), proplist()) -> ok.
handle_route_req(JObj, Props) ->
    true = wapi_route:req_v(JObj),
    BridgeRequest = props:get_value(bridge_request, Props),
    case binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>) of
        [BridgeRequest, _] ->
            Srv = props:get_value(server, Props),    
            gen_server:cast(Srv, {route_req, JObj});
        _Else -> ok
    end,
    ok.

-spec handle_route_win/2 :: (wh_json:json_object(), proplist()) -> ok.
handle_route_win(JObj, Props) ->
    true = wapi_route:win_v(JObj),
    Srv = props:get_value(server, Props),    
    gen_server:cast(Srv, {route_win, JObj}),
    ok.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Call]) ->
    process_flag(trap_exit, true),
    put(callid, whapps_call:call_id(Call)),
    Self = self(),
    spawn(fun() ->
                  ControllerQ = gen_listener:queue_name(Self),
                  gen_server:cast(Self, {controller_queue, ControllerQ})
          end),
    {ok, #participant{call=Call}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({get_conference}, _From, #participant{conference=Conference}=Participant) ->
    {reply, {ok, Conference}, Participant};
handle_call({get_discovery_event}, _From, #participant{discovery_event=DiscoveryEvent}=Participant) ->
    {reply, {ok, DiscoveryEvent}, Participant};
handle_call({get_call}, _From, #participant{call=Call}=Participant) ->
    {reply, {ok, Call}, Participant};
handle_call(_Request, _From, Participant) ->
    Reply = {error, unimplemented},
    {reply, Reply, Participant}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(hungup, Participant) ->
    {stop, {shutdown, hungup}, Participant};
handle_cast({controller_queue, ControllerQ}, #participant{call=Call}=Participant) ->
    {noreply, Participant#participant{call=whapps_call:set_controller_queue(ControllerQ, Call)}};
handle_cast({add_consumer, Consumer}, #participant{call_event_consumers=Consumers}=Participant) ->
    ?LOG("adding call event consumer ~p", [Consumer]),
    link(Consumer),
    {noreply, Participant#participant{call_event_consumers=[Consumer|Consumers]}};
handle_cast({remove_consumer, Consumer}, #participant{call_event_consumers=Consumers}=Participant) ->
    ?LOG("removing call event consumer ~p", [Consumer]),
    {noreply, Participant#participant{call_event_consumers=lists:filter(fun(C) -> C =/= Consumer end, Consumers)}};
handle_cast({set_conference, #conference{id=ConferenceId}=Conference}, #participant{call=Call}=Participant) ->
    ?LOG("received conference record for conference ~s", [ConferenceId]),
    {noreply, Participant#participant{conference=Conference#conference{controller_q=whapps_call:controller_queue(Call)}}};
handle_cast({set_discovery_event, DiscoveryEvent}, Participant) ->
    {noreply, Participant#participant{discovery_event=DiscoveryEvent}};
handle_cast(join_local, #participant{call=Call, conference=Conference}=Participant) ->
    join_conference(Call, Conference),
    {noreply, Participant};
handle_cast({join_remote, JObj}, #participant{call=Call, conference=Conference}=Participant) ->
    gen_listener:add_binding(self(), route, []),
    gen_listener:add_binding(self(), authn, []),
    BridgeRequest = couch_mgr:get_uuid(),
    Route = binary:replace(wh_json:get_value(<<"Switch-URL">>, JObj), <<"mod_sofia">>, BridgeRequest),
    bridge_to_conference(Route, Conference, Call),
    {noreply, Participant#participant{bridge_request=BridgeRequest}};
handle_cast({route_req, JObj}, #participant{call=Call}=Participant) ->
    Bridge = whapps_call:from_route_req(JObj),
    ControllerQ = whapps_call:controller_queue(Call),
    publish_route_response(ControllerQ
                           ,wh_json:get_value(<<"Msg-ID">>, JObj)
                           ,wh_json:get_value(<<"Server-ID">>, JObj)),
    {noreply, Participant#participant{bridge=whapps_call:set_controller_queue(ControllerQ, Bridge)}};
handle_cast({authn_req, JObj}, #participant{conference=Conference,  call=Call}=Participant) ->
    send_authn_response(wh_json:get_value(<<"Msg-ID">>, JObj)
                        ,wh_json:get_value(<<"Server-ID">>, JObj)
                        ,Conference
                        ,Call),
    {noreply, Participant};
handle_cast({route_win, JObj}, #participant{conference=Conference, bridge=Bridge}=Participant) ->
    ?LOG("won route for participant invite from local server"),
    gen_listener:rm_binding(self(), route, []),
    gen_listener:rm_binding(self(), authn, []),
    B = whapps_call:from_route_win(JObj, Bridge),
    join_conference(B, Conference),
    {noreply, Participant#participant{bridge=B}};
handle_cast({sync_participant, Participants}, Participant) ->
    {noreply, sync_participant(Participants, Participant)};
handle_cast(play_member_entry, #participant{call=Call, conference=#conference{id=ConferenceId}}=Participant) ->
    ControllerQ = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Media-Name">>, <<"tone_stream://%(200,0,500,600,700)">>}
               | wh_api:default_headers(ControllerQ, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant};
handle_cast(play_moderator_entry, #participant{call=Call, conference=#conference{id=ConferenceId}}=Participant) ->
    ControllerQ = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Media-Name">>, <<"tone_stream://%(200,0,500,600,700)">>}
               | wh_api:default_headers(ControllerQ, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant};
handle_cast(mute, #participant{call=Call, participant_id=ParticipantId
                               ,conference=#conference{id=ConferenceId}}=Participant) ->
    Q = whapps_call:controller_queue(Call),
    ?LOG("received in-conference command, muting participant ~s", [ParticipantId]),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_mute_participant(ConferenceId, Command),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               ,{<<"Media-Name">>, <<"/system_media/conf-muted">>}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant#participant{muted=true}};
handle_cast(unmute, #participant{call=Call, participant_id=ParticipantId
                                 ,conference=#conference{id=ConferenceId}}=Participant) ->
    ?LOG("received in-conference command, unmuting participant ~s", [ParticipantId]),
    Q = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_unmute_participant(ConferenceId, Command),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               ,{<<"Media-Name">>, <<"/system_media/conf-unmuted">>}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant#participant{muted=false}};
handle_cast(toggle_mute, #participant{muted=true}=Participant) ->
    unmute(self()),
    {noreply, Participant};
handle_cast(toggle_mute, #participant{muted=false}=Participant) ->
    mute(self()),
    {noreply, Participant};
handle_cast(deaf, #participant{call=Call, participant_id=ParticipantId
                               ,conference=#conference{id=ConferenceId}}=Participant) ->
    ?LOG("received in-conference command, making participant ~s deaf", [ParticipantId]),
    Q = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_deaf_participant(ConferenceId, Command),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               ,{<<"Media-Name">>, <<"/system_media/conf-deaf">>}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant#participant{deaf=true}};
handle_cast(undeaf, #participant{call=Call, participant_id=ParticipantId
                                 ,conference=#conference{id=ConferenceId}}=Participant) ->
    ?LOG("received in-conference command, making participant ~s undeaf", [ParticipantId]),
    Q = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_undeaf_participant(ConferenceId, Command),
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Participant">>, ParticipantId}
               ,{<<"Media-Name">>, <<"/system_media/conf-undeaf">>}
               | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),
    {noreply, Participant#participant{deaf=false}};
handle_cast(toggle_deaf, #participant{deaf=true}=Participant) ->
    undeaf(self()),
    {noreply, Participant};
handle_cast(toggle_deaf, #participant{deaf=false}=Participant) ->
    deaf(self()),
    {noreply, Participant};
handle_cast(hangup, Participant) ->
    ?LOG("received in-conference command, hangup participant"),
    {noreply, Participant};
handle_cast(_, Participant) ->
    {noreply, Participant}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', Consumer, _R}, #participant{call_event_consumers=Consumers}=Participant) ->
    ?LOG("call event consumer ~p died: ~p", [Consumer, _R]),
    {noreply, Participant#participant{call_event_consumers=lists:filter(fun(C) -> C =/= Consumer end, Consumers)}};
handle_info(_, Participant) ->
    {noreply, Participant}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_event(JObj, #participant{call_event_consumers=Consumers, call=Call, self=Self
                                ,in_conference=InConf, bridge_request=BridgeRequest}) ->
    CallId = whapps_call:call_id_direct(Call),
    case {whapps_util:get_event_type(JObj), wh_json:get_value(<<"Call-ID">>, JObj)} of
        {{<<"call_event">>, <<"CHANNEL_HANGUP">>}, CallId} ->
            ?LOG("received channel hangup event, terminate"),
            gen_server:cast(Self, hungup),
            {reply, [{call_event_consumers, Consumers}]};
        {{<<"call_detail">>, <<"cdr">>}, CallId} ->
            ?LOG("received channel cdr event, terminate"),
            gen_server:cast(Self, hungup),
            ignore;
        {{<<"call_event">>, <<"CHANNEL_DESTROY">>}, CallId} ->
            ?LOG("received channel destry, terminate"),
            gen_server:cast(Self, hungup),
            {reply, [{call_event_consumers, Consumers}]};
        {{<<"call_event">>, _}, EventCallId} when EventCallId =/= CallId ->
            ?LOG("received event from call ~s while relaying for ~s, dropping", [EventCallId, CallId]),
            ignore;
        {_Else, _} ->
            {reply, [{call_event_consumers, Consumers}
                     ,{in_conference, InConf}
                     ,{bridge_request, BridgeRequest}
                    ]}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #participant{conference=#conference{id=ConferenceId}}) ->
    Command = [{<<"Conference-ID">>, ConferenceId}
               ,{<<"Media-Name">>, <<"tone_stream://%(500,0,300,200,100,50,25)">>}
               | wh_api:default_headers(<<>>, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_play(ConferenceId, Command),            
    ?LOG_END("conference participant execution has been stopped: ~p", [_Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, Participant, _Extra) ->
    {ok, Participant}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec find_participant/2 :: (proplist(), ne_binary()) -> {ok, wh_json:json_object()} |
                                                         {error, not_found}.
find_participant([], _) ->
    {error, not_found};
find_participant([{_, Participant}|Participants], CallId) ->
    case wh_json:get_value(<<"Call-ID">>, Participant) of
        CallId -> {ok, Participant};
        _Else -> find_participant(Participants, CallId)
    end.
        
-spec join_conference/2 :: (whapps_call:call(), #conference{}) -> #conference{}.
join_conference(Call, #conference{id=ConferenceId, member_play_name=true, join_as_moderator=true})->
    ?LOG("moderator is joining conference ~s", [ConferenceId]),
    whapps_call_command:answer(Call),
    whapps_call_command:conference(ConferenceId, <<"true">>, <<"true">>, <<"true">>, Call),
    conference_command_participants(ConferenceId, Call);
join_conference(Call, #conference{id=ConferenceId, member_play_name=true, join_as_moderator=false})->
    ?LOG("member is joining conference ~s", [ConferenceId]),
    whapps_call_command:answer(Call),
    whapps_call_command:conference(ConferenceId, <<"true">>, <<"true">>, <<"false">>, Call),
    conference_command_participants(ConferenceId, Call);
join_conference(Call, #conference{id=ConferenceId, member_play_name=false, join_as_moderator=true})->
    ?LOG("moderator is joining conference ~s", [ConferenceId]),
    whapps_call_command:answer(Call),
    whapps_call_command:conference(ConferenceId, <<"false">>, <<"false">>, <<"true">>, Call),
    conference_command_participants(ConferenceId, Call);
join_conference(Call, #conference{id=ConferenceId, member_play_name=false, join_as_moderator=false})->
    ?LOG("member is joining conference ~s", [ConferenceId]),
    whapps_call_command:answer(Call),
    whapps_call_command:conference(ConferenceId, <<"false">>, <<"false">>, <<"false">>, Call),
    conference_command_participants(ConferenceId, Call).

-spec conference_command_participants/2 :: (ne_binary(), whapps_call:call()) -> ok.
conference_command_participants(ConferenceId, Call) ->
    ControllerQ = whapps_call:controller_queue(Call),
    Command = [{<<"Conference-ID">>, ConferenceId}
               | wh_api:default_headers(ControllerQ, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_conference:publish_participants_req(ConferenceId, Command).

-spec sync_participant/2 :: (wh_json:json_object(), #participant{}) -> #participant{}.
sync_participant(Participants, #participant{in_conference=false, bridge=Bridge, call=Caller
                                            ,conference=#conference{id=ConferenceId, join_as_moderator=false, member_join_muted=Muted
                                                                    ,member_join_deaf=Deaf}}=Participant) ->
    Call = case whapps_call:is_call(Participant#participant.bridge) of
               true -> Bridge;
               false -> Caller
           end,
    case find_participant(wh_json:to_proplist(Participants), whapps_call:call_id(Call)) of
        {ok, JObj} ->
            ParticipantId = wh_json:get_value(<<"Participant-ID">>, JObj),
            ?LOG("caller has joined the local conference as member ~s", [ParticipantId]),
            Deaf = not wh_json:is_true([<<"Flags">>, <<"Can-Hear">>], JObj),
            Muted = not wh_json:is_true([<<"Flags">>, <<"Can-Speak">>], JObj),
            gen_server:cast(self(), play_member_entry),
            Muted andalso gen_server:cast(self(), muted),
            Deaf andalso gen_server:cast(self(), deaf),     
            Participant#participant{in_conference=true, muted=Muted
                                    ,deaf=Deaf, participant_id=ParticipantId};
        {error, not_found} ->
            timer:sleep(500),
            conference_command_participants(ConferenceId, Call),
            Participant
    end;
sync_participant(Participants, #participant{in_conference=false, bridge=Bridge, call=Caller
                                            ,conference=#conference{id=ConferenceId, join_as_moderator=true, moderator_join_muted=Muted
                                                                    ,moderator_join_deaf=Deaf}}=Participant) ->
    Call = case whapps_call:is_call(Participant#participant.bridge) of
               true -> Bridge;
               false -> Caller
           end,
    case find_participant(wh_json:to_proplist(Participants), whapps_call:call_id(Call)) of
        {ok, JObj} ->
            ParticipantId = wh_json:get_value(<<"Participant-ID">>, JObj),
            ?LOG("caller has joined the local conference as moderator ~s", [ParticipantId]),
            Deaf = not wh_json:is_true([<<"Flags">>, <<"Can-Hear">>], JObj),
            Muted = not wh_json:is_true([<<"Flags">>, <<"Can-Speak">>], JObj),
            gen_server:cast(self(), play_moderator_entry),
            Muted andalso gen_server:cast(self(), muted),
            Deaf andalso gen_server:cast(self(), deaf),     
            Participant#participant{in_conference=true, muted=Muted
                                    ,deaf=Deaf, participant_id=ParticipantId};
        {error, not_found} ->
            timer:sleep(500),
            conference_command_participants(ConferenceId, Call),
            Participant
    end;
sync_participant(Participants, #participant{in_conference=true, bridge=Bridge, call=Caller}=Participant) ->
    Call = case whapps_call:is_call(Participant#participant.bridge) of
               true -> Bridge;
               false -> Caller
           end,
    case find_participant(wh_json:to_proplist(Participants), whapps_call:call_id(Call)) of
        {ok, JObj} ->
            ParticipantId = wh_json:get_value(<<"Participant-ID">>, JObj),
            ?LOG("caller has is still in the conference as participant ~s", [ParticipantId]),
            Deaf = not wh_json:is_true([<<"Flags">>, <<"Can-Hear">>], JObj),
            Muted = not wh_json:is_true([<<"Flags">>, <<"Can-Speak">>], JObj),
            Participant#participant{in_conference=true, muted=Muted
                                    ,deaf=Deaf, participant_id=ParticipantId};
        {error, not_found} ->
            ?LOG("participant is not present in conference anymore, terminating"),
            gen_server:cast(self(), hungup),
            Participant#participant{in_conference=false}
    end.

-spec bridge_to_conference/3 :: (ne_binary(), #conference{}, whapps_call:call()) -> ok.
bridge_to_conference(Route, #conference{bridge_username=Username, bridge_password=Password}, Call) ->
    ?LOG("briding to conference running at '~s'", [Route]),
    Endpoint = wh_json:from_list([{<<"Invite-Format">>, <<"route">>}
                                  ,{<<"Route">>, Route}
                                  ,{<<"Auth-User">>, Username}
                                  ,{<<"Auth-Password">>, Password}
                                  ,{<<"Outgoing-Caller-ID-Number">>, whapps_call:caller_id_number(Call)}
                                  ,{<<"Outgoing-Caller-ID-Name">>, whapps_call:caller_id_name(Call)}
                                  ,{<<"Ignore-Early-Media">>, <<"true">>}
                                  ,{<<"Bypass-Media">>, <<"true">>}
                                 ]),
    whapps_call_command:bridge([Endpoint], Call).

-spec publish_route_response/3 :: (ne_binary(), undefined | ne_binary(), ne_binary()) -> ok.
publish_route_response(ControllerQ, MsgId, ServerId) ->
    ?LOG("sending route response for participant invite from local server"),
    Resp = [{<<"Msg-ID">>, MsgId}
            ,{<<"Routes">>, []}
            ,{<<"Method">>, <<"park">>}
            | wh_api:default_headers(ControllerQ, ?APP_NAME, ?APP_VERSION)],
    wapi_route:publish_resp(ServerId, Resp).    

-spec send_authn_response/4 :: (undefined | ne_binary(), ne_binary(), #conference{}, whapps_call:call()) -> ok.
send_authn_response(MsgId, ServerId, #conference{bridge_username=Username, bridge_password=Password, id=ConferenceId}, Call) ->
    ?LOG("sending authn response for participant invite from local server"),
    CCVs = [{<<"Username">>, Username}
            ,{<<"Account-ID">>, whapps_call:account_db(Call)}
            ,{<<"Authorizing-Type">>, <<"conference">>}
            ,{<<"Inception">>, <<"on-net">>}
            ,{<<"Authorizing-ID">>, ConferenceId}
           ],
    Resp = [{<<"Msg-ID">>, MsgId}
            ,{<<"Auth-Password">>, Password}
            ,{<<"Auth-Method">>, <<"password">>}
            ,{<<"Custom-Channel-Vars">>, wh_json:from_list([CCV || {_, V}=CCV <- CCVs, V =/= undefined ])}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)],
    wapi_authn:publish_resp(ServerId, Resp).
