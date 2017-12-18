%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_gw_router).
-behaviour(gen_server).

-define(PING_INTERVAL, 1000).
-define(PING_REPEAT, 3).

-export([start_link/0]).
-export([register/3, status/2, uplinks/1, downlink/5, downlink_error/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

-record(state, {pulladdr, recent, beacon_timer, ping_timer, ping_counter, ping_frames}).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

register(MAC, Process, Target) ->
    gen_server:cast({global, ?MODULE}, {register, MAC, Process, Target}).

status(MAC, S) ->
    gen_server:cast({global, ?MODULE}, {status, MAC, S}).

uplinks(PkList) ->
    gen_server:cast({global, ?MODULE}, {uplinks, PkList}).

downlink(Req, MAC, DevAddr, TxQ, PHYPayload) ->
    {atomic, ok} = mnesia:transaction(
        fun() ->
            [Gateway] = mnesia:read(gateways, MAC, read),
            Stats =
                case mnesia:read(gateway_stats, MAC, write) of
                    [S] -> S;
                    [] -> #gateway_stats{mac=MAC, dwell=[], delays=[]}
                end,
            downlink0(Req, Gateway, Stats, DevAddr, TxQ, PHYPayload)
        end),
    ok.

downlink0(Req, Gateway, Stats, DevAddr, TxQ, PHYPayload) ->
    Power = limit_power(Gateway, lorawan_mac_region:eirp_limits(TxQ#txq.region)),
    Time = lorawan_mac_region:tx_time(byte_size(PHYPayload), TxQ),
    Dwell0 =
        case Stats#gateway_stats.dwell of
            undefined -> [];
            List -> List
        end,
    % summarize transmissions in the past hour
    Now = lorawan_utils:precise_universal_time(),
    HourAgo = lorawan_utils:apply_offset(Now, {-1,0,0}),
    Relevant = lists:filter(fun({ITime, _}) -> ITime > HourAgo end, Dwell0),
    Sum =
        lists:foldl(
            fun({_, {_, Duration, _}}, Acc) ->
                Acc + Duration
            end, 0, Relevant),
    Dwell =
        if
            length(HourAgo) >= 20 -> HourAgo;
            true -> lists:sublist(Dwell0, 20)
        end,
    ok = mnesia:write(gateway_stats,
        Stats#gateway_stats{dwell=[{Now, {TxQ#txq.freq, Time, Sum+Time}} | Dwell]}, write),
    gen_server:cast({global, ?MODULE}, {downlink, Req, Gateway#gateway.mac, DevAddr,
        TxQ#txq{powe=Power}, Gateway#gateway.tx_rfch, PHYPayload}).

limit_power(Gateway, {EIRPdef, EIRPmax}) ->
    Power = value_or_default(Gateway#gateway.tx_powe, EIRPdef),
    Gain = value_or_default(Gateway#gateway.ant_gain, 0),
    erlang:min(Power, EIRPmax-Gain).

downlink_error(MAC, Opaque, Error) ->
    gen_server:cast({global, ?MODULE}, {downlink_error, MAC, Opaque, Error}).

value_or_default(Num, _Def) when is_number(Num) -> Num;
value_or_default(_Num, Def) -> Def.

init([]) ->
    BeaconTimer = erlang:send_after(1, self(), beacon),
    {ok, #state{pulladdr=dict:new(), recent=dict:new(), beacon_timer = BeaconTimer}}.

handle_call(_Request, _From, State) ->
    {stop, {error, unknownmsg}, State}.

handle_cast({register, MAC, Process, {Host, Port, _}=Target}, #state{pulladdr=Dict}=State) ->
    case dict:find(MAC, Dict) of
        {ok, {Process, Target}} ->
            {noreply, State};
        _Else ->
            lorawan_utils:throw_info({gateway, MAC}, {connected, {Host, Port}}),
            Dict2 = dict:store(MAC, {Process, Target}, Dict),
            {noreply, State#state{pulladdr=Dict2}}
    end;

handle_cast({status, MAC, S}, State) ->
    case lorawan_mac:process_status(MAC, S) of
        ok ->
            ok;
        {error, {Object, Error}} ->
            lorawan_utils:throw_error(Object, Error)
    end,
    {noreply, State};

handle_cast({uplinks, PkList}, #state{recent=Recent}=State) ->
    % due to reflections the gateways may have received the same frame twice
    % reflected frames received by the same gateway are ignored
    Unique = remove_duplicates(PkList, []),
    % wait for packet receptions from other gateways
    Recent2 =
        lists:foldl(
            fun(Frame, Dict) -> store_frame(Frame, Dict) end,
            Recent, Unique),
    {noreply, State#state{recent=Recent2}};

handle_cast({downlink, Req, MAC, DevAddr, TxQ, RFCh, PHYPayload}, #state{pulladdr=Dict}=State) ->
    % lager:debug("<-- datr ~s, codr ~s, tmst ~B, size ~B", [TxQ#txq.datr, TxQ#txq.codr, TxQ#txq.tmst, byte_size(PHYPayload)]),
    case dict:find(MAC, Dict) of
        {ok, {Process, Target}} ->
            % send data to the gateway interface handler
            gen_server:cast(Process, {send, Target, Req, DevAddr, TxQ, RFCh, PHYPayload});
        error ->
            lager:warning("Downlink request ignored. Gateway ~w not connected.", [MAC])
    end,
    {noreply, State};

handle_cast({downlink_error, MAC, undefined, Error}, State) ->
    lorawan_utils:throw_error({gateway, MAC}, Error),
    {noreply, State};
handle_cast({downlink_error, _MAC, DevAddr, Error}, State) ->
    lorawan_utils:throw_error({node, DevAddr}, Error),
    {noreply, State}.


handle_info({process, PHYPayload}, #state{recent=Recent}=State) ->
    % find the best (for now)
    [{Req, MAC, RxQ}|_Rest] = lists:sort(
        fun({_R1, _M1, Q1}, {_R2, _M2, Q2}) ->
            Q1#rxq.rssi >= Q2#rxq.rssi
        end,
        dict:fetch(PHYPayload, Recent)),
    % lager:debug("--> datr ~s, codr ~s, tmst ~B, size ~B", [RxQ#rxq.datr, RxQ#rxq.codr, RxQ#rxq.tmst, byte_size(PHYPayload)]),
    wpool:cast(handler_pool, {Req, MAC, RxQ, PHYPayload}, available_worker),
    Recent2 = dict:erase(PHYPayload, Recent),
    {noreply, State#state{recent=Recent2}};

handle_info(beacon, #state{pulladdr = MACDict, beacon_timer = BeaconTimer}=State) ->
    PingTimer = erlang:send_after(?PING_INTERVAL, self(), ping),
    erlang:cancel_timer(BeaconTimer),
    lager:debug("[beacon] system_time = ~p", [erlang:system_time(millisecond)]),

    % TODO dummy frames
    lorawan_handler:store_frame(<<16#FE000000:32>>, #txdata{port=2, data= <<16#EC>>}),
    lorawan_handler:store_frame(<<16#FE000000:32>>, #txdata{port=2, data= <<16#EC>>}),
    lorawan_handler:store_frame(<<16#FE000001:32>>, #txdata{port=2, data= <<16#EC>>}),

    {atomic, TxFrames} = mnesia:transaction(
        fun() ->
            mnesia:write_lock_table(txframes),
            TxFrames = mnesia:match_object(txframes, #txframe{_='_'}, read),
            lists:foreach(
                fun(TxFrame) ->
                    mnesia:delete_object(txframes, TxFrame, write)
                end, TxFrames),
            TxFrames
        end),
    lager:debug("[beacon] TxFrames = ~p", [TxFrames]),

    CPD = lists:foldl(
        fun(#txframe{devaddr = DevAddr}, CPD) -> 
            case dict:find(DevAddr, CPD) of
                {ok, Count}  ->
                    dict:store(DevAddr, Count + 1, CPD);
                error ->
                    dict:store(DevAddr, 1, CPD)
            end
        end, dict:new(), TxFrames),

    TxData = dict:fold(
        fun(Key, Value, AccIn) ->
            <<Key/binary, Value, AccIn/binary>>
        end, <<>>, CPD),

    % send beacon
    {TxQ, PHYPayload} = lorawan_mac:handle_beacon(TxData),
    lager:debug("[beacon] TxQ = ~p", [TxQ]),
    lager:debug("[beacon] PHYPayload = ~p", [PHYPayload]),
    lists:foreach(
        fun(MAC) ->
            lager:debug("[beacon] MAC = ~p", [MAC]),
            lorawan_gw_router:downlink(#request{}, MAC, <<0:32>>, TxQ, PHYPayload)
        end,
        dict:fetch_keys(MACDict)),

    % let's ping
    {noreply, State#state{ping_timer = PingTimer, ping_counter = ?PING_REPEAT, ping_frames = TxFrames}};

handle_info(ping, #state{ping_timer = PingTimer, ping_counter = PingCounter, ping_frames = PingFrames}=State) ->
    State0 = State#state{ping_counter = PingCounter - 1},
    State1 = case State0#state.ping_counter of
        0 ->
            State0#state{beacon_timer = erlang:send_after(?PING_INTERVAL, self(), beacon)};
        _ ->
            State0#state{ping_timer = erlang:send_after(?PING_INTERVAL, self(), ping)}
    end,
    erlang:cancel_timer(PingTimer),
    lager:debug("[ping] system_time = ~p", [erlang:system_time(millisecond)]),

    case PingFrames of
        [PingFrame | NewPingFrames] ->
            DevAddr = PingFrame#txframe.devaddr,
            case mnesia:dirty_read(links, DevAddr) of
                [] ->
                    lager:debug("[ping] Link not found (DevAddr : ~p)", [DevAddr]);
                [Link] ->
                    lorawan_handler:downlink(Link, immediately, PingFrame#txframe.txdata)
            end;
        _ ->
            NewPingFrames = []
    end,

    {noreply, State1#state{ping_frames = NewPingFrames}}.

terminate(Reason, _State) ->
    % record graceful shutdown in the log
    lager:info("gateway router terminated: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


remove_duplicates([{Req, MAC, RxQ, PHYPayload} | Tail], Unique) ->
    % check if the first element is duplicate
    case lists:keytake(PHYPayload, 4, Tail) of
        {value, {Req2, MAC2, RxQ2, PHYPayload}, Tail2} ->
            % select element of a better quality and re-check for other duplicates
            if
                RxQ#rxq.rssi >= RxQ2#rxq.rssi ->
                    remove_duplicates([{Req, MAC, RxQ, PHYPayload} | Tail2], Unique);
                true -> % else
                    remove_duplicates([{Req2, MAC2, RxQ2, PHYPayload} | Tail2], Unique)
            end;
        false ->
            remove_duplicates(Tail, [{Req, MAC, RxQ, PHYPayload} | Unique])
    end;
remove_duplicates([], Unique) ->
    Unique.

store_frame({Req, MAC, RxQ, PHYPayload}, Dict) ->
    case dict:find(PHYPayload, Dict) of
        {ok, Frames} ->
            dict:store(PHYPayload, [{Req, MAC, RxQ}|Frames], Dict);
        error ->
            {ok, Delay} = application:get_env(lorawan_server, deduplication_delay),
            {ok, _} = timer:send_after(Delay, {process, PHYPayload}),
            dict:store(PHYPayload, [{Req, MAC, RxQ}], Dict)
    end.

% end of file
