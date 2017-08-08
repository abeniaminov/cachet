%%%-------------------------------------------------------------------
%%% @author abeniaminov
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Авг. 2017 14:14
%%%-------------------------------------------------------------------
-module(cachet).
-author("abeniaminov").

-behaviour(gen_server).

%% API
-export([start_link/2, get_info/1, get/4, refresh/4, get/5]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS_NAME(CacheName), list_to_atom(atom_to_list(CacheName) ++ "_ets" )).
-define(SIZE_KEY(CacheName), list_to_atom("SIZE_" ++ atom_to_list(CacheName))).


-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

get(CacheName, Key, FunGet, LifeTime) ->
    get(CacheName, Key, FunGet, LifeTime, false).

refresh(CacheName, Key, FunGet, LifeTime) ->
    get(CacheName, Key, FunGet, LifeTime, true).

get(CacheName, Key, FunGet, LifeTime, false = _Refresh) ->
    Ets = ?ETS_NAME(CacheName),
    case ets:lookup(Ets, Key) of
        [] ->
            V = FunGet(),
            Size = erlang:byte_size(V),
            {_K, MaxSize, OldSize, _Cnt} = ets:lookup(Ets, ?SIZE_KEY(CacheName)),
            case OldSize + Size <  MaxSize of
                true ->
                    TRef = erlang:send_after(milliseconds(LifeTime), CacheName, {expire, CacheName, Key}),
                    case ets:insert_new(Ets, {Key, V, TRef}) of
                        true -> ets:update_counter(Ets, ?SIZE_KEY(CacheName), [{3, Size}, {4, 1}]);
                        false -> nothing
                    end;
                false ->
                    nothing
            end,
            V;

        [{Key, Value, _TRef}] ->
            Value
    end;

get(CacheName, Key, FunGet, LifeTime, true = _Refresh) ->
    Ets = ?ETS_NAME(CacheName),
    ok = flush(CacheName, Key),
    V = FunGet(),
    Size = erlang:byte_size(V),
    {_K, MaxSize, OldSize, _Cnt} = ets:lookup(Ets, ?SIZE_KEY(CacheName)),
    case OldSize + Size <  MaxSize of
        true ->
            TRef = erlang:send_after(milliseconds(LifeTime), CacheName, {expire, CacheName, Key}),
            case ets:insert_new(Ets, {Key, V, TRef}) of
                true -> ets:update_counter(Ets, ?SIZE_KEY(CacheName), [{3, Size}, {4, 1}]);
                false -> nothing
            end;
        false ->
            nothing
    end,
    V.

get_info(CacheName) ->
    ets:lookup(?ETS_NAME(CacheName), ?SIZE_KEY(CacheName)).

%% CacheSize {Value, R} where R in [b, kb, mb, gb]
start_link(CacheName, CacheSize) ->
    gen_server:start_link({local, CacheName}, ?MODULE, [CacheName, CacheSize], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([CacheName, CacheSize]) ->
    ets:new(?ETS_NAME(CacheName),
    [
        ordered_set,
        named_table,
        {read_concurrency, true},
        public
    ]),
    ets:insert(?ETS_NAME(CacheName), {?SIZE_KEY(CacheName), bytes(CacheSize), 0, 0} ),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({expire, CacheName, Key}, State) ->
    ok = flush(CacheName, Key),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

flush(CacheName, Key) ->
    Ets = ?ETS_NAME(CacheName),
    case ets:take(Ets, Key) of
        [] ->
            continue;
        [{Key, V, TRef}] ->
            erlang:cancel_timer(TRef),
            ets:update_counter(Ets, ?SIZE_KEY(CacheName), [{3, - erlang:byte_size(V)}, {4, -1}])
    end,
    ok.


bytes(Value) when is_integer(Value) ->
    bytes({Value, mb});
bytes({Value, b }) -> Value;
bytes({Value, kb }) -> Value * 1024;
bytes({Value, mb }) -> Value * 1024 * 1024;
bytes({Value, gb }) -> Value * 1024 * 1024 *1024.

milliseconds(Value) when is_integer(Value) ->
    milliseconds({Value, min });
milliseconds({Value, hour }) -> Value * 3600 * 1000;
milliseconds({Value, min }) -> Value * 60 * 1000;
milliseconds({Value, sec }) -> Value * 1000.
