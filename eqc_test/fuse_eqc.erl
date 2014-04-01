%%% The fuse_eqc module implements a Quickcheck model for the Fuse main gen_server.
-module(fuse_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include_lib("pulse/include/pulse.hrl").
-include_lib("pulse_otp/include/pulse_otp.hrl").

-compile(export_all).

%%% Model state.
-record(state, {
	time = {0, 0, 0},  % Current time in the model. We track time to handle melting time points.
	melts = [], % History of current melts issued to the SUT
	blown = [], % List of currently blown fuses
	installed = [] % List of installed fuses, with their configuration.
}).

-define(PERIOD, 1000).

%% API Generators

%% fuses/0 is the list of fuses we support in the model for testing purposes.
fuses() -> [phineas, ferb, candace, isabella, vanessa, perry, heinz].

%% g_atom/0 generates a simple atom from a short list.
g_atom() ->
	oneof([a,b,c,d,e,f]).

%% g_name/0 generates one of the valid fuses at random
g_name() ->
	  elements(fuses()).

%% Thomas says this is a bad idea, since we can rule out the name by a precondition (_pre/3)
%% As a result we stopped using functions like these.
%% g_installed(S) ->
%%	fault(g_name(), oneof(installed_names(S))).

%% g_neg_int/0 Generates a negative integer, or 0
g_neg_int() ->
	?LET(N, nat(),
		-N).

%% g_strategy/0 generates a random fuse configuration.
%% At times, this will generate a faulty strategy to make sure we correctly
%% reject incorrect strategies.
g_strategy() ->
	fault(
		{frequency([
			{1, {g_atom(), int(), int()}},
			{1, {standard, g_neg_int(), int()}},
			{1, {standard, int(), g_neg_int()}},
			{1, {standard, int(), int()}}
		])},
		{standard, choose(1, 3), ?PERIOD}
	).

%% g_refresh()/0 generates a refresh setting.
g_refresh() ->
	{reset, 60000}.
	
%% g_options() generates install options
g_options() ->
	{g_strategy(), g_refresh()}.

%% g_initial_state/0 generates the initial system state
g_initial_state() -> #state {}.

%% g_time_inc/0 generates a time increment.
g_time_inc() ->
	choose(1, 1000-1).

%% elapse_time
%% ---------------------------------------------------------------
%% Let time pass in the model. This increases time by an amount so calls will happen
%% at a later point than normally.
elapse_time(N) ->
	fuse_time:elapse_time(N).
	
elapse_time_args(_S) ->
	[g_time_inc()].

elapse_time_next(#state { time = T } = State, _V, [N]) ->
	State#state { time = fuse_time:inc(T, N) }.

elapse_time_post(#state { time = T }, [N], NewTime) ->
	eq(fuse_time:inc(T, N), NewTime).

%% fuse_reset/2 sends timer messages into the SUT
%% ---------------------------------------------------------------
%% Heal a fuse which has been blown in the system.
fuse_reset(Name) ->
    fuse_srv ! {reset, Name},
    fuse_srv:sync(), %% synchronize to avoid a race condition.
    ok.

%% You can reset a fuse if there is a blown fuse in the system.
fuse_reset_pre(#state { blown = [] }) -> false;
fuse_reset_pre(#state {}) -> true.

fuse_reset_args(#state { blown = Names }) ->
	[elements(Names)].

%% Fuses will only be reset if their state is among the installed and are blown.
%% Precondition checking is effective at shrinking down failing models.
fuse_reset_pre(#state { blown = Blown } = S, [Name]) ->
	is_installed(Name, S) andalso lists:member(Name, Blown).

%% Note: when a fuse heals, the internal state is reset.
fuse_reset_next(#state { blown = RPs } = S, _V, [Name]) ->
    case lists:member(Name, RPs) of
        false -> S;
        true ->
            clear_melts(Name, S#state { blown = lists:delete(Name, RPs) })
    end.

fuse_reset_post(_S, [_Name], R) ->
	eq(R, ok).

%% install/2 puts a new fuse into the system
%% ---------------------------------------------------------------
install(Name, Opts) ->
	try fuse:install(Name, Opts) of
		ok -> ok
	catch
		error:badarg ->
			badarg
	end.

install_args(_S) ->
	[g_name(), g_options()].

%% When installing new fuses, the internal state is reset for the fuse.
%% Also, consider if the installed is valid at all.
install_next(#state{ installed = Is } = S, _V, [Name, Opts]) ->
	case valid_opts(Opts) of
	    false ->
	        S;
	    true ->
	        {{_, Count, _}, _} = Opts,
	        T = {Name, Count},
	        clear_melts(Name,
	          clear_blown(Name,
	            S#state { installed = lists:keystore(Name, 1, Is, T) }))
	end.

install_post(_S, [_Name, Opts], R) ->
	case valid_opts(Opts) of
	    true -> eq(R, ok);
	    false -> eq(R, badarg)
	end.

%% reset/1 resets a fuse back to its initial state
%% ---------------------------------------------------------------
reset(Name) ->
	fuse:reset(Name).

reset_pre(S) ->
	has_fuses_installed(S).

reset_args(_S) ->
	[g_name()].

reset_post(S, [Name], Ret) ->
    case is_installed(Name, S) of
        true -> eq(Ret, ok);
        false -> eq(Ret, {error, not_found})
    end.

%% Resetting a fuse resets its internal state
reset_next(S, _V, [Name]) ->
    case is_installed(Name, S) of
        false -> S;
        true ->
        		clear_blown(Name,
        		  clear_melts(Name,
        		    S))
    end.

%%% ask/1 asks about the state of a fuse that exists
%% ---------------------------------------------------------------
ask(Name) ->
	fuse:ask(Name, [sync]).
	
ask_pre(S) ->
	has_fuses_installed(S).

ask_pre(S, [Fuse]) ->
	is_installed(Fuse, S).

ask_args(_S) ->
	[g_name()].
	
ask_post(S, [Name], Ret) ->
	case is_installed(Name, S) of
	    true ->
	    	eq(Ret, case is_blown(Name, S) of true -> blown; false -> ok end);
	    false ->
	        eq(Ret, {error, not_found})
	end.

%%% run/1 runs a function (thunk) on the circuit breaker
%% ---------------------------------------------------------------
run(Name, _Result, _Return, Fun) ->
	fuse:run(Name, Fun, [sync]).
	
run_pre(S) ->
	has_fuses_installed(S).

run_pre(S, [Fuse, _Result, _Return, _Fun]) ->
	is_installed(Fuse, S).

run_args(_S) ->
    ?LET({N, Result, Return}, {g_name(), elements([ok, melt]), int()},
        [N, Result, Return, function0({Result, Return})] ).

run_next(S, _V, [_Name, ok, _, _]) -> S;
run_next(#state { time = Ts } = S, _V, [Name, melt, _, _]) ->
	case is_installed(Name, S) of
		true ->
		    record_melt_history(Name,
		      expire_melts(?PERIOD,
		        record_melt(Name, Ts,
		          S#state {  })));
		false -> S#state {  }
	end.

run_post(S, [Name, _Result, Return, _], Ret) ->
	case is_installed(Name, S) of
	    true ->
		case is_blown(Name, S) of
		    false -> eq(Ret, {ok, Return});
		    true -> true
		end;
	    false ->
	        eq(Ret, {error, not_found})
	end.


%%% melt/1 melts the fuse a little bit
%% ---------------------------------------------------------------
melt(Name) ->
	fuse:melt(Name).

melt_pre(S) ->
    has_fuses_installed(S).

melt_pre(S, [Fuse]) ->
	is_installed(Fuse, S).

melt_args(_S) ->
	[g_name()].

melt_next(#state { time = Ts } = S, _V, [Name]) ->
	case is_installed(Name, S) of
		true ->
		    record_melt_history(Name,
		      expire_melts(?PERIOD,
		        record_melt(Name, Ts,
		          S)));
		false -> S
	end.

melt_post(_S, _, Ret) ->
	eq(Ret, ok).

weight(_, _) -> 1.

%%% PROPERTIES
%% ---------------------------------------------------------------

%% Test the stateful system against a random sequential command sequence.
prop_model_seq() ->
    fault_rate(1, 40,
    	?FORALL(St, g_initial_state(),
	?FORALL(Cmds, commands(?MODULE, St),
	  begin
	  	fuse_time:start(),
	  	cleanup(),
	  	{H, S, R} = run_commands(?MODULE, Cmds),
	        pretty_commands(?MODULE, Cmds, {H, S, R},
	  		aggregate(command_names(Cmds), R == ok))
	  end))).

%% Test the stateful system against a random parallel command sequence with a sequential prefix.
prop_model_par() ->
    fault_rate(1, 40,
     ?LET(Shrinking, parameter(shrinking, false), 
     ?FORALL(St, g_initial_state(),
	?FORALL(ParCmds, parallel_commands(?MODULE, St),
	  ?ALWAYS(if not Shrinking -> 1;
                     Shrinking -> 20
		  end,
	  begin
	  	fuse_time:start(),
	  	cleanup(),
	  	{H, S, R} = run_parallel_commands(?MODULE, ParCmds),
	        pretty_commands(?MODULE, ParCmds, {H, S, R},
	  		aggregate(command_names(ParCmds), R == ok))
	  end))))).

%% Run a test under PULSE to randomize the process schedule as well.
x_prop_model_pulse() ->
  ?SETUP(fun() -> N = erlang:system_flag(schedulers_online, 1),
         	fun() -> erlang:system_flag(schedulers_online, N) end end,
  ?FORALL(St, g_initial_state(),
  ?FORALL(Cmds, parallel_commands(?MODULE, St),
  ?PULSE(HSR={_, _, R},
    begin
      fuse_time:start(),
      cleanup(),
      run_parallel_commands(?MODULE, Cmds)
    end,
    aggregate(command_names(Cmds),
    pretty_commands(?MODULE, Cmds, HSR,
      R == ok)))))).

cleanup() ->
  error_logger:tty(false),
  (catch application:stop(fuse)),
  application:load(sasl),
  application:set_env(sasl, sasl_error_logger, false),
  application:set_env(sasl, errlog_type, error),
  application:start(sasl),
  application:start(folsom),
  ok = application:start(fuse).

%%% INTERNALS
%%% ---------------------

%% is_installed/2 determines if a given fuse is installed
is_installed(N, #state { installed = Is }) -> lists:keymember(N, 1, Is).

%% valid_opts/1 determines if the given options are valid
valid_opts({{standard, K, R}, {reset, T}})
    when K > 0, R >= 0, T >= 0 ->
	true;
valid_opts(_) ->
	false.
	
melt_state(Name, S) ->
	count_state(fuse_intensity(Name, S) - count_melts(Name, S)).

is_blown(Name, #state { blown = BlownFuses }) ->
	lists:member(Name, BlownFuses).
	
fuse_intensity(Name, #state { installed = Inst }) ->
	{Name, Count} = lists:keyfind(Name, 1, Inst),
	Count.

count_state(N) when N < 0 -> blown;
count_state(_N) -> ok.

count_melts(Name, #state { melts = Ms }) ->
	length([N || {N, _} <- Ms, N == Name]).

has_fuses_installed(#state { installed = [] }) -> false;
has_fuses_installed(#state { installed = [_|_]}) -> true.

record_melt(Name, Ts, #state { melts = Ms } = S) ->
	S#state { melts = [{Name, Ts} | Ms] }.

record_melt_history(Name, #state { blown = OldRPs } = S) ->
	case melt_state(Name, S) of
	    ok -> S;
	    blown ->
	        case lists:member(Name, OldRPs) of
	            true -> S; %% Can have at most 1 RP for a name
	            false ->
	            	S#state { blown = OldRPs ++ [Name] }
	        	end
	end.

clear_blown(Name, #state { blown = Rs } = S) ->
	S#state { blown = [N || N <- Rs, N /= Name] }.
	
clear_melts(Name, #state { melts = Ms } = S) ->
	S#state { melts = [{N, Ts} || {N, Ts} <- Ms, N /= Name] }.

expire_melts(Period, #state { time = Now, melts = Ms } = S) ->
	S#state { melts = [{Name, Ts} || {Name, Ts} <- Ms, in_period(Ts, Now, Period)] }.

%% Alternative implementation of being inside the period, based on microsecond conversion.
in_period(Ts, Now, _) when Now < Ts -> false;
in_period(Ts, Now, Period) when Now >= Ts ->
	STs = model_time:micros(Ts) div (1000 * 1000),
	SNow = model_time:micros(Now) div (1000 * 1000),
	
	%% Difference in Seconds, by subtraction and then eradication of the microsecond parts.
	Secs = SNow - STs,
	Secs =< Period.

%% PULSE instrumentation,
the_prop() -> x_prop_model_pulse().

%% test/1 is a helper which makes it easy to PULSE test the code
test({N, h})   -> test({N * 60, min});
test({N, min}) -> test({N * 60, sec});
test({N, s})   -> test({N, sec});
test({N, sec}) ->
  quickcheck(eqc:testing_time(N, the_prop()));
test(N) when is_integer(N) ->
  quickcheck(numtests(N, the_prop())).

test() -> test(100).

recheck() -> eqc:recheck(the_prop()).
check()   -> eqc:check(the_prop()).
check(CE) -> eqc:check(the_prop(), CE).

verbose()   -> eqc:check(eqc_statem:show_states(the_prop())).
verbose(CE) -> eqc:check(eqc_statem:show_states(the_prop(), CE)).

pulse_instrument() ->
  [ pulse_instrument(File) || File <- filelib:wildcard("../src/*.erl") ++ filelib:wildcard("../eqc_test/*.erl") ].

pulse_instrument(File) ->
  {ok, Mod} = compile:file(File, [{d, 'PULSE', true},
                                  {parse_transform, pulse_instrument},
                                  {pulse_side_effect, [{ets, '_', '_'}]}]),
  code:purge(Mod),
  code:load_file(Mod),
  Mod.
