-module(qdate).

-export([
	to_string/1,
	to_string/2,
	to_string/3,
	to_date/1,
	to_date/2,
	to_now/1,
	to_unixtime/1,
	unixtime/0
]).

-export([
 	register_parser/2,
 	register_parser/1,
	deregister_parser/1,
	deregister_parsers/0,

 	register_format/2,
 	deregister_format/1,

	set_timezone/1,
	set_timezone/2,
	get_timezone/0,
	get_timezone/1,
	clear_timezone/0,
	clear_timezone/1
]).


%% Exported for API compatibility with ec_date
-export([
	format/1,format/2,
	nparse/1,
	parse/1
]).

%% This the value in gregorian seconds for jan 1st 1970, 12am
%% It's used to convert to and from unixtime, since unixtime starts 
%% 1970-01-01 12:00am
-define(UNIXTIME_BASE,62167219200).

%% This is the timezone only if the qdate application variable 
%% "default_timezone" isn't set or is set to undefined.
%% It's recommended that your app sets the var in a config, or at least using
%%
%% 		application:set_env(qdate, default_timezone, "GMT").
%%
-define(DEFAULT_TZ, case application:get_env(qdate, default_timezone) of 
						undefined -> "GMT";
						TZ -> TZ 
					end).

-define(DETERMINE_TZ, determine_timezone()).


to_string(Format) ->
	to_string(Format, now()).

to_string(Format, Date) ->
	to_string(Format, ?DETERMINE_TZ, Date).

to_string(FormatKey, ToTZ, Date) when is_atom(FormatKey) orelse is_tuple(FormatKey) ->
	Format = case qdate_srv:get_format(FormatKey) of
		undefined -> throw({undefined_format_key,FormatKey});
		F -> F
	end,
	to_string(Format, ToTZ, Date);
to_string(Format, ToTZ, Date) when is_binary(Format) ->
	list_to_binary(to_string(binary_to_list(Format), ToTZ, Date));
to_string(Format, ToTZ, Date) when is_list(Format) ->
	to_string_worker(Format, ToTZ, to_date(Date,ToTZ)).

to_string_worker([], _, _) ->
	"";
to_string_worker([$e|RestFormat], ToTZ, Date) ->
	ToTZ ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([$I|RestFormat], ToTZ, Date) ->
	I = case localtime_dst:check(Date, ToTZ) of
		is_in_dst 		-> "1";
		is_not_in_dst 	-> "0";
		ambiguous_time 	-> "?"
	end,
	I ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([H | RestFormat], ToTZ, Date) when H==$O orelse H==$P ->
	Shift = get_timezone_shift(Date, ToTZ),
	Separator = case H of
		$O -> "";
		$P -> ":"
	end,
	format_shift(Shift,Separator) ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([$T | RestFormat], ToTZ, Date) ->
	{ShortName,_} = localtime:tz_name(Date, ToTZ),
	ShortName ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([$Z | RestFormat], ToTZ, Date) ->
	{Sign, Hours, Mins} = get_timezone_shift(Date, ToTZ),
	Seconds = (Hours * 3600) + (Mins * 60),
	atom_to_list(Sign)  ++ integer_to_list(Seconds) ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([$r | RestFormat], ToTZ, Date) ->
	NewFormat = "D, d M Y H:i:s O",
	to_string_worker(NewFormat, ToTZ, Date) ++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([$c | RestFormat], ToTZ, Date) ->
	Format1 = "Y-m-d",
	Format2 = "H:i:sP",
	to_string_worker(Format1, ToTZ, Date) 
			++ "T" 
			++ to_string_worker(Format2, ToTZ, Date) 
			++ to_string_worker(RestFormat, ToTZ, Date);
to_string_worker([H | RestFormat], ToTZ, Date) ->
	ec_date:format([H], Date) ++ to_string_worker(RestFormat, ToTZ, Date).

		
format_shift({Sign,Hours,Mins},Separator) ->
	SignStr = atom_to_list(Sign),
	MinStr = leading_zero(Mins),
	HourStr = leading_zero(Hours),
	SignStr ++ HourStr ++ Separator ++ MinStr.

leading_zero(I) when I < 10 ->
	"0" ++ integer_to_list(I);
leading_zero(I) ->
	integer_to_list(I).

get_timezone_shift(Date, TZ) ->
	case localtime:tz_shift(Date, TZ) of
		unable_to_detect -> {error,unable_to_detect};
		{error,T} -> {error,T};
		{Sh, _DstSh} -> Sh;
		Sh -> Sh
	end.


format(Format) ->
	to_string(Format).

format(Format, Date) ->
	to_string(Format, Date).

parse(String) ->
	to_date(String).

nparse(String) ->
	to_now(String).


to_date(RawDate) ->
	to_date(RawDate, ?DETERMINE_TZ).

to_date(RawDate, ToTZKey) when is_atom(ToTZKey) orelse is_tuple(ToTZKey) ->
	case get_timezone(ToTZKey) of
		undefined -> throw({timezone_key_not_found,ToTZKey});
		ToTZ -> to_date(RawDate, ToTZ)
	end;
to_date(RawDate, ToTZ)  ->
	{ExtractedDate, ExtractedTZ} = extract_timezone(RawDate),
	{RawDate3, FromTZ} = case try_registered_parsers(RawDate) of
		undefined ->
			{ExtractedDate, ExtractedTZ};
		{ParsedDate,undefined} ->
			{ParsedDate,ExtractedTZ};
		{ParsedDate,ParsedTZ} ->
			{ParsedDate,ParsedTZ}
	end,	
	Date = raw_to_date(RawDate3),

	date_tz_to_tz(Date, FromTZ, ToTZ).

extract_timezone(Unixtime) when is_integer(Unixtime) ->
	{Unixtime, "GMT"};
extract_timezone(DateString) when is_list(DateString) ->
	case extract_gmt_relative_timezone(DateString) of
		undefined -> 
			AllTimezones = localtime:list_timezones(),
			RevDate = lists:reverse(DateString),
			extract_timezone_helper(RevDate, AllTimezones);
		{Date, GMTRel} ->
			{Date, GMTRel}
	end;
extract_timezone(Date={{_,_,_},{_,_,_}}) ->
	{Date, ?DETERMINE_TZ};
extract_timezone(Now={_,_,_}) ->
	{Now, "GMT"};
extract_timezone({MiscDate,TZ}) ->
	{MiscDate,TZ}.
	
extract_gmt_relative_timezone(DateString) ->
	RE = "^(.*?)(?:GMT|UTC)?([+-])(\\d{1,2}):?(\\d{2})?$",
	case re:run(DateString,RE,[{capture,all_but_first,list},caseless]) of
		{match, [NewDateStr, Sign, HourStr, MinStr]} ->
			{NewDateStr, minutes_from_gmt_relative_timezone(Sign, HourStr, MinStr)};
		{match, [NewDateStr, Sign, HourStr]} ->
			{NewDateStr, minutes_from_gmt_relative_timezone(Sign, HourStr, "0")};
		nomatch ->
			undefined
	end.

%% The number of minutes a the timezone is behind gmt
minutes_from_gmt_relative_timezone("+", HourStr, MinStr) ->
	-minutes_from_gmt_relative_timezone("-", HourStr, MinStr);
minutes_from_gmt_relative_timezone("-", HourStr, MinStr) ->
	list_to_integer(HourStr)*60 + list_to_integer(MinStr).

extract_timezone_helper(RevDate, []) ->
	{lists:reverse(RevDate), ?DETERMINE_TZ};
extract_timezone_helper(RevDate, [TZ | TZs]) ->
	RevTZ = lists:reverse(TZ),
	case lists:split(length(TZ),RevDate) of
		{RevTZ," " ++ Remainder} ->
			{lists:reverse(Remainder), TZ};
		_ ->
			extract_timezone_helper(RevDate, TZs)
	end.

determine_timezone() ->
	case qdate_srv:get_timezone() of
		undefined -> ?DEFAULT_TZ;
		TZ -> TZ
	end.

%% This converts dates without regard to timezone.
%% Unixtime just goes to UTC
raw_to_date(Unixtime) when is_integer(Unixtime) ->
	unixtime_to_date(Unixtime);
raw_to_date(DateString) when is_list(DateString) ->
	ec_date:parse(DateString);
raw_to_date(Now = {_,_,_}) ->
	calendar:now_to_datetime(Now);
raw_to_date(Date = {{_,_,_},{_,_,_}}) ->
	Date.

%% If FromTZ is an integer, then it's an integer that represents the number of minutes
%% relative to GMT. So we convert the date to GMT based on that number, then we can
%% do the other timezone conversion.
date_tz_to_tz(Date, FromTZ, ToTZ) when is_integer(FromTZ) ->
	NewDate = localtime:adjust_datetime(Date, FromTZ),
	date_tz_to_tz(NewDate, "GMT", ToTZ);
date_tz_to_tz(Date, FromTZ, ToTZ) ->
	localtime:local_to_local(Date,FromTZ,ToTZ).

try_registered_parsers(RawDate) ->
	Parsers = qdate_srv:get_parsers(),
	try_parsers(RawDate,Parsers).
	
try_parsers(_RawDate,[]) ->
	undefined;
try_parsers(RawDate,[{ParserKey,Parser}|Parsers]) ->
	try Parser(RawDate) of
		{{_,_,_},{_,_,_}} = DateTime ->
			{DateTime,undefined};
		{DateTime={{_,_,_},{_,_,_}},Timezone} ->
			{DateTime,Timezone};
		undefined ->
			try_parsers(RawDate, Parsers);
		Other ->
			throw({invalid_parser_return_value,[{parser_key,ParserKey},{return,Other}]})
	catch
		Error:Reason -> 
			throw({error_in_parser,[{error,{Error,Reason}},{parser_key,ParserKey}]})
	end.

set_timezone(TZ) ->
	qdate_srv:set_timezone(TZ).

set_timezone(Key,TZ) ->
	qdate_srv:set_timezone(Key, TZ).

get_timezone() ->
	qdate_srv:get_timezone().

get_timezone(Key) ->
	qdate_srv:get_timezone(Key).

clear_timezone() ->
	qdate_srv:clear_timezone().

clear_timezone(Key) ->
	qdate_srv:clear_timezone(Key).


to_unixtime(Unixtime) when is_integer(Unixtime) ->
	Unixtime;
to_unixtime({MegaSecs,Secs,_}) ->
	MegaSecs*1000000 + Secs;
to_unixtime(ToParse) ->
	%% We want to treat all unixtimes as GMT
	Date = to_date(ToParse, "GMT"),
	calendar:datetime_to_gregorian_seconds(Date) - ?UNIXTIME_BASE.

unixtime() ->
	to_unixtime(now()).

to_now(Now = {_,_,_}) ->
	Now;
to_now(ToParse) ->
	Unixtime = to_unixtime(ToParse),
	unixtime_to_now(Unixtime).


register_parser(Key, Parser) when is_function(Parser,1) ->
	qdate_srv:register_parser(Key,Parser).

register_parser(Parser) when is_function(Parser,1) ->
	qdate_srv:register_parser(Parser).

deregister_parser(Key) ->
	qdate_srv:deregister_parser(Key).

deregister_parsers() ->
	qdate_srv:deregister_parsers().

register_format(Key, Format) ->
	qdate_srv:register_format(Key, Format).

deregister_format(Key) ->
	qdate_srv:deregister_format(Key).



unixtime_to_now(T) when is_integer(T) ->
	MegaSec = floor(T/1000000),
	Secs = T - MegaSec*1000000,
	{MegaSec,Secs,0}.

unixtime_to_date(T) ->
	Now = unixtime_to_now(T),
	calendar:now_to_datetime(Now).

floor(N) when N >= 0 ->
	trunc(N);
floor(N) when N < 0 ->
	Int = trunc(N),
	if
		Int==N -> Int;
		true -> Int-1
	end.


%% TESTS
-include_lib("eunit/include/eunit.hrl").

%% emulates as if a forum-type website has a Site tz, and a user-specified tz
-define(SITE_TZ,"PST").
-define(USER_TZ,"CST").
-define(SELF_TZ,"EST"). %% Self will be the pid of the current running process
-define(SITE_KEY,test_site_key).
-define(USER_KEY,test_user_key).

tz_test_() ->
	{
		setup,
		fun start_test/0,
		fun stop_test/1,
		fun(SetupData) ->
			{inorder,[
				simple_test(SetupData),
				tz_tests(SetupData),
				test_process_die(SetupData),
				parser_format_test(SetupData)
			]}
		end
	}.

tz_tests(_) ->
	{inorder,[
		?_assertEqual(ok,set_timezone(?SELF_TZ)),
		?_assertEqual(?SELF_TZ,get_timezone()),
		?_assertEqual(?USER_TZ,get_timezone(?USER_KEY)),
		?_assertEqual(?SITE_TZ,get_timezone(?SITE_KEY)),
		?_assertEqual({{2013,3,7},{0,0,0}}, to_date("3/7/2013 1:00am EST",?USER_KEY)),
		?_assertEqual({{2013,3,7},{0,0,0}}, to_date("3/7/2013 3:00am EST",?SITE_KEY)),
		?_assertEqual({{2013,3,7},{2,0,0}}, to_date("3/7/2013 1:00am CST")), %% will use the current pid's setting
		?_assertEqual("America/Chicago",to_string("e","America/Chicago","3/7/2013 1:00am")),
		?_assertEqual("-0500",to_string("O","EST","3/7/2013 1:00am CST")),
		?_assertEqual("-05:00",to_string("P","EST","3/7/2013 1:00am CST")),
		?_assertEqual("EST",to_string("T","America/New York","3/7/2013 1:00am CST")),
		?_assertEqual(integer_to_list(-5 * 3600), to_string("Z","EST","3/7/2013 1:00am CST")),
		?_assertEqual("Thu, 07 Mar 2013 13:15:00 -0500", to_string("r","EST", "3/7/2013 1:15:00pm")),
		?_assertEqual("2013-03-07T13:15:00-05:00", to_string("c", "EST", "3/7/2013 1:15:00pm")),

		?_assertEqual({{2013,3,7},{6,0,0}}, to_date("3/7/2013 12:00am -0600","GMT")),
		?_assertEqual({{2013,3,7},{6,0,0}}, to_date("3/7/2013 12:00am -600","GMT")),
		?_assertEqual({{2013,3,7},{6,0,0}}, to_date("3/7/2013 12:00am GMT-0600","GMT")),
		?_assertEqual({{2013,3,7},{6,0,0}}, to_date("3/7/2013 12:00am utc-0600","GMT")),
		?_assertEqual({{2013,3,7},{1,0,0}}, to_date("3/7/2013 12:00am utc-0600","EST")),
		?_assertEqual({{2013,3,6},{18,0,0}}, to_date("3/7/2013 12:00am +0600","GMT")),
		?_assertEqual({{2013,3,6},{12,0,0}}, to_date("3/7/2013 12:00am +0600","CST")),

		%% parsing, then reformatting the same time with a different timezone using the php "r" (rfc2822)
		?_assertEqual("Thu, 07 Mar 2013 12:15:00 -0600",
			to_string("r","CST",to_string("r","EST",{{2013,3,7},{13,15,0}}))),

		%% A bunch of unixtime and now tests with timezones
		?_assertEqual("1987-08-10 00:59:15 GMT",to_string("Y-m-d H:i:s T","GMT",555555555)),
		?_assertEqual("1987-08-09 19:59:15 CDT",to_string("Y-m-d H:i:s T","CDT",555555555)),
		?_assertEqual("1987-08-09 20:59:15 EDT",to_string("Y-m-d H:i:s T","America/New York",555555555)),
		?_assertEqual(ok, set_timezone("GMT")),
		?_assertEqual(555555555,to_unixtime("1987-08-10 00:59:15 GMT")),
        ?_assertEqual({555,555555,0},to_now("1987-08-10 00:59:15 GMT")),
		?_assertEqual(ok, set_timezone("EST")),
		?_assertEqual(555555555,to_unixtime("1987-08-10 00:59:15 GMT")),
        ?_assertEqual({555,555555,0},to_now("1987-08-10 00:59:15 GMT")),
		?_assertEqual(ok, set_timezone("GMT"))
	]}.


simple_test(_) ->
	{inorder,[
		?_assertEqual(ok,clear_timezone()),
		?_assertEqual(0,to_unixtime({0,0,0})),
		?_assertEqual({0,0,0},to_now(0)),
		?_assertEqual(0,to_unixtime("1970-01-01 12:00am GMT")),
		?_assertEqual(21600,to_unixtime("1970-01-01 12:00am CST")),
		?_assertEqual(0,to_unixtime({{1970,1,1},{0,0,0}})),
		?_assertEqual({{1970,1,1},{0,0,0}},to_date(0)),
		?_assertEqual({{2013,3,7},{0,0,0}},to_date(to_unixtime("2013-03-07 12am"))),
		?_assertEqual("2013-12-21 12:24pm",to_string("Y-m-d g:ia",{{2013,12,21},{12,24,21}})),
		?_assertEqual("2012-12-01 1:00pm", to_string("Y-m-d g:ia","EST","2012-12-01 12:00pm CST")),
		?_assertEqual(to_unixtime("2012-01-01 12:00pm CST"), to_unixtime("2012-01-01 10:00am PST")),
		?_assertEqual({{2012,12,31},{18,15,15}},to_date("Dec 31, 2012 6:15:15pm")),
		?_assertEqual({{2013,1,1},{0,15,15}},to_date("December 31, 2012 6:15:15pm CST","GMT"))
	]}.

parser_format_test(_) ->
	{inorder,[
		?_assertEqual({{2008,2,8},{0,0,0}},to_date("20080208")),
		?_assertThrow({ec_date,{bad_date,_}},to_date("20111232")),	%% invalid_date with custom format
		?_assertEqual("2/8/2008",to_string(shortdate,{{2008,2,8},{0,0,0}})),
		?_assertEqual("2/8/2008",to_string(shortdate,"20080208")), %% both regged format and parser
		?_assertEqual("2/8/2008 12:00am",to_string(longdate,"2008-02-08 12:00am")),
		?_assertEqual("2/8/2008 12:00am",to_string(longdate,"20080208"))
	]}.

test_process_die(_) ->
	TZ = "MST",
	Caller = self(),
	Pid = spawn(fun() -> 
						set_timezone(TZ),
						Caller ! tz_set,
						receive tz_set_ack -> ok end,
						Caller ! get_timezone()
				end),

	PidTZFromOtherProc = receive 
							tz_set ->
								T = get_timezone(Pid),
								Pid ! tz_set_ack,
								T
							after 1000 -> fail 
						 end,
	ReceivedTZ = receive 
					TZ -> TZ 
				 after 2000 ->
					fail 
				 end,

	[
		%% Verify we can read the spawned process's TZ from another proc
		?_assertEqual(TZ,PidTZFromOtherProc),
		%% Verify the spawned process properly set the TZ
		?_assertEqual(TZ,ReceivedTZ),
		%% Verify the now-dead spawned process's TZ is cleared
		?_assertEqual(undefined,get_timezone(Pid))
	].
	
		
start_test() ->
	application:start(qdate),
	set_timezone(?SELF_TZ),
	set_timezone(?SITE_KEY,?SITE_TZ),
	set_timezone(?USER_KEY,?USER_TZ),
	register_parser(compressed,fun compressed_parser/1),
	register_parser(microsoft_date,fun microsoft_parser/1),
	register_format(shortdate,"n/j/Y"),
	register_format(longdate,"n/j/Y g:ia").

compressed_parser(List) when length(List)==8 ->
	try re:run(List,"^(\\d{4})(\\d{2})(\\d{2})$",[{capture,all_but_first,list}]) of
		nomatch -> undefined;
		{match, [Y,M,D]} -> 
			Date = {list_to_integer(Y),list_to_integer(M),list_to_integer(D)},
			case calendar:valid_date(Date) of
				true ->
					{Date,{0,0,0}};
				false -> undefined
			end
	catch
		_:_ -> undefined
	end;
compressed_parser(_) -> 
	undefined.

microsoft_parser(FloatDate) when is_float(FloatDate) ->
	try
		DaysSince1900 = floor(FloatDate),
		Days0to1900 = calendar:date_to_gregorian_days(1900,1,1),
		GregorianDays = Days0to1900 + DaysSince1900,
		Date = calendar:gregorian_days_to_date(GregorianDays),
		Seconds = round(86400 * (FloatDate - DaysSince1900)),
		Time = calendar:seconds_to_time(Seconds),
		{Date,Time}
	catch
		_:_ -> undefined
	end;
microsoft_parser(_) ->
	undefined.

	

stop_test(_) ->
	ok.
