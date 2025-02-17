-module(fsm_eqc_util).
-compile([export_all, nowarn_export_all]).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-define(RING_KEY, riak_ring).

not_empty(G) ->
    ?SUCHTHAT(X, G, X /= [] andalso X /= <<>>).

longer_list(K, G) ->
    ?SIZED(Size, resize(trunc(K*Size), list(resize(Size, G)))).

node_status() ->
    frequency([{1, ?SHRINK(down, [up])},
               {9, up}]).

%% Make sure at least one node is up - code in riak_kv_util makes
%% some assumptions that the node the get FSM is running on is
%% in the cluster causing problems if it isn't.
at_least_one_up(G) ->
    ?SUCHTHAT(X, G, lists:member(up, X)).

num_partitions() ->
    %% TODO: use some unfortunate partition counts (1, 50, etc.)
    % elements([4, 16, 64]).
    ?LET(N, choose(0, 6), pow(2, N)).

largenat() ->
    ?LET(X, largeint(), abs(X)).

bkey() ->
    %%TODO: "make this nastier"
    %%TODO: once json encoding of bkeys as binaries rather than utf8 strings
    %%      start creating general binaries instead
    {non_blank_string(),  %% bucket
     non_blank_string()}. %% key

non_blank_string() ->
    ?LET(X,not_empty(list(lower_char())), list_to_binary(X)).

%% Generate a lower 7-bit ACSII character that should not cause any problems
%% with utf8 conversion.
lower_char() ->
    choose(16#20, 16#7f).


vclock() ->
    ?LET(VclockSym, vclock_sym(), eval(VclockSym)).

vclock_sym() ->
    ?LAZY(
       oneof([
              {call, vclock, fresh, []},
              ?LETSHRINK([Clock], [vclock_sym()],
                         {call, ?MODULE, increment,
                          [noshrink(binary(4)), nat(), Clock]})
              ])).

increment(Actor, Count, Vclock) ->
    lists:foldl(
      fun vclock:increment/2,
      Vclock,
      lists:duplicate(Count, Actor)).

riak_object() ->
    ?LET({{Bucket, Key}, Vclock, Value, Meta},
        {bkey(), vclock(), object_value(), oneof([[], [{binary(), object_value()}]])},
        %% TODO: The above oneof() should really be the below list(), but
        %% because dicts don't serialize/deserialize deterministically,
        %% riak_object_eqc:prop_roundtrip will fail if we put the list in now.
        %% related to riak_object
        %%{bkey(), vclock(), binary(), list({binary(), binary()})},
         riak_object:set_vclock(
           riak_object:new(Bucket, Key, Value, dict:from_list(Meta)),
           Vclock)).

object_value() ->
    oneof([binary(), erlang_term()]).

erlang_term() ->
    oneof([gen_atom(), nat(), binary(), {?LAZY(erlang_term()), ?LAZY(erlang_term())}]).

gen_atom() -> % a,q seems to be the minimum provoking example for atoms
    elements([a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z]).

maybe_tombstone() ->
    weighted_default({2, notombstone}, {1, tombstone}).

%%
%%         ancestor
%%       /     |    \
%%  brother   sister otherbrother
%%       \     |    /
%%         current
%%
lineage() ->
    elements([current, ancestor, brother, sister, otherbrother]).

merge(ancestor, Lineage) -> Lineage;  % order should match Clocks list in riak_objects
merge(Lineage, ancestor) -> Lineage;  % as last modified is used as tie breaker with
merge(_, current)        -> current;  % allow_mult=false
merge(current, _)        -> current;
merge(otherbrother, _)   -> otherbrother;
merge(_, otherbrother)   -> otherbrother;
merge(sister, _)         -> sister;
merge(_, sister)         -> sister;
merge(brother, _)        -> brother;
merge(_, brother)        -> brother.

merge([Lin]) ->
    Lin;
merge([Lin|Lins]) ->
    merge(Lin, merge(Lins)).

partval() ->
    Shrink = fun(G) -> ?SHRINK(G, [{ok, current}]) end,
    frequency([{2,{ok, lineage()}},
               {1,Shrink(notfound)},
               {1,Shrink(timeout)},
               {1,Shrink(error)}]).

partvals() ->
    not_empty(fsm_eqc_util:longer_list(2, partval())).

%% Generate 5 riak objects with the same bkey
%%
riak_objects() ->
    ?LET({{Bucket,Key},AncestorVclock0,Tombstones},
         {noshrink(bkey()),vclock(),vector(5, maybe_tombstone())},
    begin
        AncestorVclock = vclock:increment(<<"dad">>, AncestorVclock0),
        BrotherVclock  = vclock:increment(<<"bro!">>, AncestorVclock),
        OtherBroVclock = vclock:increment(<<"bro2">>, AncestorVclock),
        SisterVclock   = vclock:increment(<<"sis!">>, AncestorVclock),
        CurrentVclock  = vclock:merge([BrotherVclock,SisterVclock,OtherBroVclock]),
        Clocks = [{ancestor, AncestorVclock, <<"ancestor">>},
                  {brother,  BrotherVclock, <<"brother">>},
                  {sister,   SisterVclock, <<"sister">>},
                  {otherbrother, OtherBroVclock, <<"otherbrother">>},
                  {current,  CurrentVclock, <<"current">>}],
        [ {Lineage, build_riak_obj(Bucket, Key, Vclock, Value, Tombstone)}
            || {{Lineage, Vclock, Value}, Tombstone} <- lists:zip(Clocks, Tombstones) ]
    end).

build_riak_obj(B,K,Vc,Val,notombstone) ->
    riak_object:set_contents(
        riak_object:set_vclock(
            riak_object:new(B,K,Val),
                Vc),
        [{dict:from_list([{<<"X-Riak-Last-Modified">>, os:timestamp()}]), Val}]);
build_riak_obj(B,K,Vc,Val,tombstone) ->
    Obj = build_riak_obj(B,K,Vc,Val,notombstone),
    add_tombstone(Obj).

add_tombstone(Obj) ->
    [{M,V}] = riak_object:get_contents(Obj),
    NewM = dict:store(<<"X-Riak-Deleted">>, true, M),
    riak_object:set_contents(Obj, [{NewM, V}]).


some_up_node_status(NumNodes) ->
    at_least_one_up(nodes_status(NumNodes)).

nodes_status(NumNodes) ->
    non_empty(longer_list(NumNodes, node_status())).

pow(_, 0) -> 1;
pow(A, N) -> A * pow(A, N - 1).

make_power_of_two(Q) -> make_power_of_two(Q, 1).

make_power_of_two(Q, P) when P >= Q -> P;
make_power_of_two(Q, P) -> make_power_of_two(Q, P*2).

cycle(N, Xs=[_|_]) when N >= 0 ->
    cycle(Xs, N, Xs).

cycle(_Zs, 0, _Xs) ->
    [];
cycle(Zs, N, [X|Xs]) ->
    [X|cycle(Zs, N - 1, Xs)];
cycle(Zs, N, []) ->
    cycle(Zs, N, Zs).

start_mock_servers() ->
    Path = riak_kv_test_util:get_test_dir("fsm_util"),
    %% Start new core_vnode based EQC FSM test mock
    case whereis(fsm_eqc_vnode) of
        undefined -> ok;
        Pid2      ->
            unlink(Pid2),
            exit(Pid2, shutdown),
            riak_kv_test_util:wait_for_pid(Pid2)
    end,
    {ok, _Pid3} = fsm_eqc_vnode:start_link(),
    application:load(riak_core),
    application:start(crypto),
    exometer:start(),
    riak_kv_stat:register_stats(),
    riak_core_metadata_manager:start_link([{data_dir, Path ++ "/fsm_eqc_test_data"}]),
    riak_core_ring_events:start_link(),
    riak_core_ring_manager:start_link(test),
    riak_core_node_watcher_events:start_link(),
    riak_core_node_watcher:start_link(),
    riak_core_node_watcher:service_up(riak_kv, self()),
    ok.

cleanup_mock_servers() ->
    riak_kv_test_util:stop_process(riak_core_metadata_manager),
    riak_kv_test_util:stop_process(riak_core_ring_manager),
    application:stop(folsom),
    application:stop(riak_core),
    exometer:stop().

make_options([], Options) ->
    Options;
make_options([{_Name, missing} | Rest], Options) ->
    make_options(Rest, Options);
make_options([Option | Rest], Options) ->
    make_options(Rest, [Option | Options]).

mock_ring(Q0, NodeStatus0) ->
    %% Round up to next power of two
    Q = fsm_eqc_util:make_power_of_two(Q0),

    %% Expand the node status to match the size of the ring
    NodeStatus = cycle(Q, NodeStatus0),

    %% Assign the node owners and store the ring.
    Ring = reassign_nodes(NodeStatus, riak_core_ring:fresh(Q, node())),
    mochiglobal:put(?RING_KEY, Ring),

    %% Return details - useful for ?WHENFAILs
    {Q, Ring, NodeStatus}.

reassign_nodes(Status, Ring) ->
    Ids = [ I || {I, _} <- riak_core_ring:all_owners(Ring) ],
    lists:foldl(
        fun({down, Id}, R) ->
                riak_core_ring:transfer_node(Id, 'notanode@localhost', R);
           (_, R) -> R
        end, Ring, lists:zip(Status, Ids)).


wait_for_req_id(ReqId, Pid) ->
    receive
        {'EXIT', Pid, _Reason} ->
            io:format(user, "FSM died:\n~p\n", [_Reason]),
            %{exit, _Reason};
            %% Mark as timeout for now - no reply is coming, so why wait
            timeout;
        {'EXIT', _OtherPid, _Reason} ->
            %% Probably from previous test death
            wait_for_req_id(ReqId, Pid);
        {ReqId, Response} ->
            Response;
        Anything1 ->
            {anything, Anything1}
    after 400 ->
            timeout
    end.

%% Just get the last `XXX_fsm_spawned/1' from the list
%% of meck history calls.
%% Expects a reversed meck:history()
last_spawn([]) ->
    undefined;
last_spawn([{_MPid, {_Mod, TypeFun, [Pid]}, ok}|_Rest]) ->
    {TypeFun, Pid};
last_spawn([_Hist|Rest]) ->
    last_spawn(Rest).



start_fake_rng(ProcessName) ->
    Pid = spawn_link(?MODULE, fake_rng, [1]),
    register(ProcessName, Pid),
    {ok, Pid}.

set_fake_rng(ProcessName, Val) ->
    gen_server:cast(ProcessName, {set, Val}).

get_fake_rng(ProcessName) ->
    gen_server:call(ProcessName, get).

fake_rng(N) ->
    receive
        {'$gen_call', From, get} ->
            gen_server:reply(From, N),
            fake_rng(N);
        {'$gen_cast', {set, NewN}} ->
            fake_rng(NewN)
    end.

-endif. % EQC
