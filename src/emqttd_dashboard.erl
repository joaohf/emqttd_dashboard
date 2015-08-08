%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttd web dashboard.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttd_dashboard).

-author("Feng Lee <feng@emqtt.io>").

-export([handle_request/1]).

-define(SEPARTOR, $\/).

-record(mqtt_admin_user, {username, password, tags}).
 
-include_lib("stdlib/include/qlc.hrl").

handle_request(Req) ->
    case authorized(Req) of
	true ->
		Path = Req:get(path),
    		lager:info("Dashboard file: ~s ~s", [Req:get(method), Path]),
    		handle_request(Path, Req);
	false->
		Req:respond({401, [{"WWW-Authenticate", "Basic Realm=\"emqttd dashboad\""}], []})
    end.
   
handle_request("/api/" ++ Path, Req) when length(Path) > 0 ->
    lager:info("Req: ~s", [Req]),
    api(list_to_atom(Path), Req);

handle_request("/" ++ Rest, Req) ->
    mochiweb_request:serve_file(Rest, docroot(), Req).

docroot() ->
    {file, Here} = code:is_loaded(?MODULE),
    Dir = filename:dirname(filename:dirname(Here)),
    filename:join([Dir, "priv", "www"]).

%%-----------------------------------overview--------------------------------------

%% broker info
api(stats, Req) ->
    Stats = [{Stat, Val} || {Stat, Val} <- emqttd_stats:getstats()],
    api_respond(Req, Stats);
   
api(ptype, Req) ->
    PortTyeps = emqttd_vm:get_port_types(), 
    api_respond(Req, PortTyeps);
   
api(memory, Req) ->
    Memory = emqttd_vm:get_memory(), 
    api_respond(Req, Memory);
    
api(cpu, Req) ->
    Cpu = emqttd_vm:loads(), 
    api_respond(Req, Cpu);

api(node, Req) ->
    Nodes = [node()|nodes()],
    NodeInfo = lists:map(fun(Node)-> 
		Memory = rpc:call(Node, emqttd_vm, mem_info, []),
		CpuInfo = [{K, list_to_binary(V)} || {K, V} <- rpc:call(Node, emqttd_vm, loads, [])],
		ProcessLimit = rpc:call(Node, emqttd_vm, get_process_limit, []),
		ProcessList = rpc:call(Node, emqttd_vm, get_process_list, []),
		UpTime = rpc:call(Node, emqttd_broker, uptime, []),
		Memory ++ [{name, Node}, {process_available, ProcessLimit}, {process_used, length(ProcessList)}, {uptime, list_to_binary(UpTime)}|CpuInfo]
	    end, Nodes),
    api_respond(Req, NodeInfo);
    
api(metrics, Req) ->
    Metrics = [{Metric, Val} || {Metric, Val} <- emqttd_metrics:all()],
    api_respond(Req, Metrics);
   
api(listeners, Req) ->
    Llists = lists:map(fun({{Protocol, Port}, Pid})-> 
		MaxClients = esockd:get_max_clients(Pid),	
	 	CurrentClients = esockd:get_current_clients(Pid),
	 	[{protocol, Protocol},{port, Port},{max_clients, MaxClients},{current_clients, CurrentClients}] 
	      end, esockd:listeners()),
    api_respond(Req, Llists);
    
%%-----------------------------------clients--------------------------------------
%%clients api
api(clients, Req) ->
	Bodys = [[
		{clientId, ClientId}, 
		{username, UserName}, 
		{ipaddress, list_to_binary(emqttd_net:ntoa(Ipaddr))}, 
		{port, Port}, 
		{clean_sess, CleanSession}, 
		{proto_ver, ProtoVer}, 
		{keepalive, KeepAlvie}, 
		{connected_at, list_to_binary(connected_at_format(ConnectedAt))}
		] || {_Tab, ClientId, _ClientPid, UserName, {Ipaddr, Port}, CleanSession, ProtoVer, KeepAlvie, _WillTopic, ConnectedAt}
		<- emqttd_vm:get_ets_object(mqtt_client)],
    api_respond(Req, Bodys);
    
%%-----------------------------------session--------------------------------------
%%sessin check api
api(session, Req) ->
    F = fun() ->
        Q = qlc:q([E || E <- mnesia:table(session)]),
	qlc:e(Q) 
        end,
    {atomic, Sessions} =  mnesia:transaction(F),
    Bodys = [[
	     {clientId, ClientId}, 
	     %{sess_pid, SessPid}, 
	     {persistent, Persistent}, 
	     {on_node, OnNode}] 
     || {_Tab, ClientId, _SessPid, Persistent, OnNode} <- Sessions],
    api_respond(Req, Bodys);
  
   
%%-----------------------------------topic--------------------------------------
%%topic api
api(topic, Req) ->
    F = fun() ->
        Q = qlc:q([E || E <- mnesia:table(topic)]),
	qlc:e(Q) 
        end,
    {atomic, TopicLists} =  mnesia:transaction(F),
    Bodys = [[
	     {topic, Topic}, 
	     {node, Node} 
	     ] || {_Tab, Topic, Node} <- TopicLists],
 
    api_respond(Req, Bodys);
   
%%-----------------------------------subscribe--------------------------------------
%%subscribe api
api(subscriber, Req) ->
    F = fun() ->
        Q = qlc:q([E || E <- mnesia:table(subscriber)]),
	qlc:e(Q) 
        end,
    {atomic, SubLists} =  mnesia:transaction(F),
    Bodys = [[{mqtt_subscriber,  Tab},
             {topic, Topic}, 
             {qos, Qos}] || {Tab, Topic, _Pid, Qos} <- SubLists],

    api_respond(Req, Bodys);
 
%%-----------------------------------Users--------------------------------------
%%subscribe api
api(user, Req) ->
    Bodys = [[
	{name, Username}, 
	{password, Password}, 
	{tag, Tags}] || {_Tab, Username, Password, Tags}
		<- emqttd_vm:get_ets_object(mqtt_admin)],
    api_respond(Req, Bodys).
    
    
api_respond(Req, Bodys) ->
    JsonData = 
    if length(Bodys) == 0 ->
	<<"\[\]">>;
    true ->
        list_to_binary(mochijson2:encode(Bodys) ++ <<10>>)
    end,
    Req:respond({200, [{"Content-Type","application/json"}], JsonData}).

connected_at_format(Timestamp) ->
    Ts = emqttd_util:now_to_secs(Timestamp),
    strftime(datetime(Ts)).

strftime({{Y,M,D}, {H,MM,S}}) ->
    Date = string:join([zeropad(I) || I <- [Y,M,D]], "-"),
    Time = string:join([zeropad(I) || I <- [H, MM, S]], ":"),
    lists:concat([Date, " ", Time]).
	        
datetime(Timestamp) when is_integer(Timestamp) ->
    Universal = calendar:gregorian_seconds_to_datetime(Timestamp +
	calendar:datetime_to_gregorian_seconds({{1970,1,1}, {0,0,0}})),
    calendar:universal_time_to_local_time(Universal).

zeropad(I) when I < 10 ->
    lists:concat(["0", I]);
zeropad(I) ->
    integer_to_list(I).

  
%%------------------------------------------------------------------------------
%% basic authorization
%%------------------------------------------------------------------------------
authorized(Req) ->
    case Req:get_header_value("Authorization") of
	undefined ->
		false;
	"Basic " ++ BasicAuth ->
        {Username, Password} = user_passwd(BasicAuth),
        lager:error("HTTP Auth failure: username=~s, password=~p", [Username, Password]),
        case emqttd_dashboard_users:check(#mqtt_admin_user{username = Username, password = Password}) of
            ok ->
                true;
            {error, Reason} ->
                lager:error("HTTP Auth failure: username=~s, reason=~p", [Username, Reason]),
                false
        end
	end.

user_passwd(BasicAuth) ->
	list_to_tuple(binary:split(base64:decode(BasicAuth), <<":">>)). 


