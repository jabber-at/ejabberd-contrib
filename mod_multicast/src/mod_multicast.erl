%%%----------------------------------------------------------------------
%%% File    : mod_multicast.erl
%%% Author  : Badlop <badlop@ono.com>
%%% Purpose : Extended Stanza Addressing (XEP-0033) support
%%% Created : 29 May 2007 by Badlop <badlop@ono.com>
%%% Id      : $Id: mod_multicast.erl 440 2007-12-06 22:36:21Z badlop $
%%%----------------------------------------------------------------------

-module(mod_multicast).
-author('badlop@ono.com').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1]).

%% gen_server callbacks
-export([init/1,
	 handle_info/2,
	 handle_call/3,
	 handle_cast/2,
	 terminate/2,
	 code_change/3
	]).

-export([
	 purge_loop/1
	]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-record(state, {lserver, lservice, access, service_limits}).

-record(multicastc, {rserver, response, ts}).
%% ts: timestamp (in seconds) when the cache item was last updated

-record(dest, {jid_string, jid_jid, type, full_xml}).
%% jid_string = string()
%% jid_jid = jid()
%% full_xml = xml()

-record(group, {server, dests, multicast, others, addresses}).
%% server = string()
%% dests = [string()] 
%% multicast = {cached, local_server} | {cached, string()} | {cached, not_supported} | {obsolete, not_supported} | {obsolete, string()} | not_cached
%%  after being updated, possible values are: local | multicast_not_supported | {multicast_supported, string(), limits()}
%% others = [xml()]
%% packet = xml()

-record(waiter, {awaiting, group, renewal=false, sender, packet, aattrs, addresses}).
%% awaiting = {[Remote_service], Local_service, Type_awaiting}
%%  Remote_service = Local_service = string()
%%  Type_awaiting = info | items
%% group = #group
%% renewal = true | false
%% sender = From
%% packet = xml()
%% aattrs = [xml()]

-record(limits, {message, presence}).
%% message = presence = integer() | infinite

-record(service_limits, {local, remote}).
%% local = remote = limits()

%% All the elements are of type value()

-define(VERSION_MULTICAST, "$Revision: 440 $ ").
-define(PROCNAME, ejabberd_mod_multicast).

-define(PURGE_PROCNAME, ejabberd_mod_multicast_purgeloop).

%% TODO: allow configuration instead of hard-coding
%% Time in seconds
-define(MAXTIME_CACHE_POSITIVE, 86400).
-define(MAXTIME_CACHE_NEGATIVE, 86400).

%% Time in miliseconds
-define(CACHE_PURGE_TIMER, 86400000). % Purge the cache every 24 hours
-define(DISCO_QUERY_TIMEOUT, 10000). % After 10 seconds of delay the server is declared dead

%% TODO: Put the correct values once XEP33 is updated
-define(DEFAULT_LIMIT_LOCAL_MESSAGE,  100).
-define(DEFAULT_LIMIT_LOCAL_PRESENCE, 100).
-define(DEFAULT_LIMIT_REMOTE_MESSAGE, 20).
-define(DEFAULT_LIMIT_REMOTE_PRESENCE,20).


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LServerS, Opts) ->
    Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [LServerS, Opts], []).

start(LServerS, Opts) ->
    Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
    ChildSpec =	{
      Proc,
      {?MODULE, start_link, [LServerS, Opts]},
      temporary,
      1000,
      worker,
      [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(LServerS) ->
    Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([LServerS, Opts]) ->
    LServiceS = gen_mod:get_opt(host, Opts, "multicast." ++ LServerS),
    Access = gen_mod:get_opt(access, Opts, all),
    SLimits = build_service_limit_record(gen_mod:get_opt(limits, Opts, [])),
    create_cache(),
    try_start_loop(),
    create_pool(),
    ejabberd_router_multicast:register_route(LServerS),
    ejabberd_router:register_route(LServiceS),
    {ok, #state{lservice = LServiceS,
		lserver = LServerS,
		access = Access,
		service_limits = SLimits}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    try_stop_loop(),
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({route, From, To, {xmlelement, "iq", Attrs, _Els} = Packet}, State) ->
    IQ = jlib:iq_query_info(Packet),
    case catch process_iq(From, IQ, State) of
	Result when is_record(Result, iq) ->
	    ejabberd_router:route(To, From, jlib:iq_to_xml(Result));
	{'EXIT', Reason} ->
	    ?ERROR_MSG("Error when processing IQ stanza: ~p", [Reason]),
	    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR),
	    ejabberd_router:route(To, From, Err);
	reply ->
	    LServiceS = jts(To),
	    case xml:get_attr_s("type", Attrs) of
		"result" -> process_iqreply_result(From, LServiceS, Packet, State);
		"error" -> process_iqreply_error(From, LServiceS, Packet)
	    end
    end,
    {noreply, State};

%% XEP33 allows only 'message' and 'presence' stanza type
handle_info({route, From, To, {xmlelement, Stanza_type, _, _} = Packet},
	    #state{lservice = LServiceS,
		   lserver = LServerS,
		   access = Access,
		   service_limits = SLimits} = State)
  when (Stanza_type == "message") or (Stanza_type == "presence") ->
    %%io:format("Multicast packet: ~nFrom: ~p~nTo: ~p~nPacket: ~p~n", [From, To, Packet]),
    route_untrusted(LServiceS, LServerS, Access, SLimits, From, To, Packet),
    {noreply, State};

%% Handle multicast packets sent by trusted local services
handle_info({route_trusted, From, Destinations, Packet},
	    #state{lservice = LServiceS,
		   lserver = LServerS} = State) ->
    %%io:format("Multicast packet2: ~nFrom: ~p~nDestinations: ~p~nPacket: ~p~n", [From, Destinations, Packet]),
    route_trusted(LServiceS, LServerS, From, Destinations, Packet),
    {noreply, State};

handle_info({get_host, Pid}, State) ->
    Pid ! {my_host, State#state.lservice},
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ejabberd_router_multicast:unregister_route(State#state.lserver),
    ejabberd_router:unregister_route(State#state.lservice),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%%% Internal functions
%%====================================================================


%%%------------------------
%%% IQ Request Processing
%%%------------------------

%% disco#info request
process_iq(From, #iq{type = get, xmlns = ?NS_DISCO_INFO, lang = Lang} = IQ, State) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_DISCO_INFO}], iq_disco_info(From, Lang, State)}]};

%% disco#items request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_DISCO_ITEMS}], []}]};

%% vCard request
process_iq(_, #iq{type = get, xmlns = ?NS_VCARD, lang = Lang} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "vCard", [{"xmlns", ?NS_VCARD}], iq_vcard(Lang)}]};

%% version request
process_iq(_, #iq{type = get, xmlns = ?NS_VERSION} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_VERSION}], iq_version()}]};

%% Unknown "set" or "get" request
process_iq(_, #iq{type=Type, sub_el=SubEl} = IQ, _) when Type==get; Type==set ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};

%% IQ "result" or "error".
process_iq(_, reply, _) ->
    reply;

%% IQ "result" or "error".
process_iq(_, _, _) ->
    ok.

-define(FEATURE(Feat), {xmlelement,"feature",[{"var", Feat}],[]}).

iq_disco_info(From, Lang, State) ->
    [{xmlelement, "identity",
      [{"category", "service"},
       {"type", "multicast"},
       {"name", translate:translate(Lang, "Multicast")}], []},
     ?FEATURE(?NS_DISCO_INFO),
     ?FEATURE(?NS_DISCO_ITEMS),
     ?FEATURE(?NS_VCARD),
     ?FEATURE(?NS_ADDRESS)] ++
	iq_disco_info_extras(From, State).

iq_vcard(Lang) ->
    [{xmlelement, "FN", [],
      [{xmlcdata, "ejabberd/mod_multicast"}]},
     {xmlelement, "URL", [],
      [{xmlcdata, ?EJABBERD_URI}]},
     {xmlelement, "DESC", [],
      [{xmlcdata, translate:translate(Lang, "ejabberd Multicast service\n"
				      "Copyright (c) 2007 Alexey Shchepin")}]}].

iq_version() ->
    [{xmlelement, "name", [],
      [{xmlcdata, "mod_multicast"}]},
     {xmlelement, "version", [],
      [{xmlcdata, ?VERSION_MULTICAST}]}].


%%%-------------------------
%%% Route
%%%-------------------------

%% Destinations = [string()]
route_trusted(LServiceS, LServerS, FromJID, Destinations, Packet) -> 

    %% Strip 'addresses' from packet
    Packet_stripped = Packet,
    AAttrs = [{"xmlns", ?NS_ADDRESS}],
    Delivereds = [],

    Dests2 = lists:map(
	       fun(D) ->
		       DS = jts(D),
		       XML = {xmlelement, "address", 
			      [{"type", "bcc"}, {"jid", DS}], 
			      []},
		       #dest{jid_string = DS,
			     jid_jid = D,
			     type = "bcc",
			     full_xml = XML}
	       end,
	       Destinations),

    %% Group Not_delivered by server
    Groups = group_dests(Dests2),

    route_common(LServerS, LServiceS, FromJID, Groups, Delivereds, Packet_stripped, AAttrs).

route_untrusted(LServiceS, LServerS, Access, SLimits, From, To, Packet) -> 
    try route_untrusted2(LServiceS, LServerS, Access, SLimits, From, Packet)
    catch
	throw:adenied -> route_error(To, From, Packet, forbidden, "Access denied by service policy");
	  throw:eadsele -> route_error(To, From, Packet, bad_request, "No addresses element found");
	  throw:eadeles -> route_error(To, From, Packet, bad_request, "No address elements found");
	  throw:ewxmlns -> route_error(To, From, Packet, bad_request, "Wrong xmlns");
	  throw:etoorec -> route_error(To, From, Packet, not_acceptable, "Too many receiver fields were specified");
	  throw:edrelay -> route_error(To, From, Packet, forbidden, "Packet relay is denied by service policy");
	  EType:EReason -> 
	    ?ERROR_MSG("Multicast unknown error: Type: ~p~nReason: ~p", [EType, EReason]),
	    route_error(To, From, Packet, internal_server_error, "Unknown problem")
    end.

route_untrusted2(LServiceS, LServerS, Access, SLimits, FromJID, Packet) -> 
    ok = check_access(LServerS, Access, FromJID),

    %% Strip 'addresses' from packet
    {ok, Packet_stripped, AAttrs, Addresses} = strip_addresses_element(Packet),

    %% Split Addresses in To_deliver and Delivered
    {To_deliver, Delivereds} = split_addresses_todeliver(Addresses),

    %% Convert XML to record
    Dests = convert_dest_record(To_deliver),

    %% Split the destinations by JID
    {Dests2, Not_jids} = split_dests_jid(Dests),
    report_not_jid(FromJID, Packet, Not_jids),

    %% Check limit
    ok = check_limit_dests(SLimits, FromJID, Packet, Dests2),

    %% Group Not_delivered by server
    Groups = group_dests(Dests2),

    %% Check relay for each Group
    ok = check_relay(FromJID#jid.server, LServerS, Groups),

    route_common(LServerS, LServiceS, FromJID, Groups, Delivereds, Packet_stripped, AAttrs).

route_common(LServerS, LServiceS, FromJID, Groups, Delivereds, Packet_stripped, AAttrs) ->
    %% Gather multicast service for each Group
    Groups2 = look_cached_servers(LServerS, Groups),

    %% Create Delivered XML element for each Group
    Groups3 = build_others_xml(Groups2),

    %% Add preliminary packet for each group
    Groups4 = add_addresses(Delivereds, Groups3),

    %% Decide action for each Group
    AGroups = decide_action_groups(Groups4),

    act_groups(FromJID, Packet_stripped, AAttrs, LServiceS, AGroups).

act_groups(FromJID, Packet_stripped, AAttrs, LServiceS, AGroups) ->
    [perform(FromJID, Packet_stripped, AAttrs, LServiceS, AGroup) || AGroup <- AGroups].

perform(From, Packet, AAttrs, _, {route_single, Group}) ->
    [route_packet(From, ToUser, Packet, AAttrs, Group#group.addresses) || ToUser <- Group#group.dests];

perform(From, Packet, AAttrs, _, {{route_multicast, JID, RLimits}, Group}) ->
    route_packet_multicast(From, JID, Packet, AAttrs, Group#group.dests, Group#group.addresses, RLimits);

perform(From, Packet, AAttrs, LServiceS, {{ask, Old_service, renewal}, Group}) ->
    send_query_info(Old_service, LServiceS),
    add_waiter(#waiter{awaiting = {[Old_service], LServiceS, info},
		       group = Group,
		       renewal = true,
		       sender = From,
		       packet = Packet,
		       aattrs = AAttrs,
		       addresses = Group#group.addresses
		      });

perform(From, Packet, AAttrs, LServiceS, {{ask, Server, not_renewal}, Group}) ->
    send_query_info(Server, LServiceS),
    add_waiter(#waiter{awaiting = {[Server], LServiceS, info},
		       group = Group,
		       renewal = false,
		       sender = From,
		       packet = Packet,
		       aattrs = AAttrs,
		       addresses = Group#group.addresses
		      }).


%%%-------------------------
%%% Check access permission
%%%-------------------------

check_access(LServerS, Access, From) ->
    case acl:match_rule(LServerS, Access, From) of
	allow ->
	    ok;
	_ ->
	    throw(adenied)
    end.


%%%-------------------------
%%% Strip 'addresses' XML element
%%%-------------------------

strip_addresses_element(Packet) ->
    case xml:get_subtag(Packet, "addresses") of
	{xmlelement, "addresses", AAttrs, Addresses} ->
	    case xml:get_attr_s("xmlns", AAttrs) of
		?NS_ADDRESS -> 
		    {xmlelement, Name, Attrs, Els} = Packet,
		    Els_stripped = lists:keydelete("addresses", 2, Els),
		    Packet_stripped = {xmlelement, Name, Attrs, Els_stripped},
		    {ok, Packet_stripped, AAttrs, Addresses};
		_ -> throw(ewxmlns)
	    end;
	_ -> throw(eadsele)
    end.


%%%-------------------------
%%% Split Addresses
%%%-------------------------

split_addresses_todeliver(Addresses) ->
    lists:partition(
      fun(XML) ->
	      case XML of
		  {xmlelement, "address", Attrs, _El} ->
		      case xml:get_attr_s("delivered", Attrs) of
			  "true" -> false;
			  _ ->
			      Type = xml:get_attr_s("type", Attrs),
			      case Type of
				  "to" -> true;
				  "cc" -> true;
				  "bcc" -> true;
				  _ -> false
			      end
		      end;
		  _ -> false
	      end
      end,
      Addresses).


%%%-------------------------
%%% Check does not exceed limit of destinations
%%%-------------------------

check_limit_dests(SLimits, FromJID, Packet, Addresses) ->
    SenderT = sender_type(FromJID),
    Limits = get_slimit_group(SenderT, SLimits),
    Type_of_stanza = type_of_stanza(Packet),
    {_Type, Limit_number} = get_limit_number(Type_of_stanza, Limits),
    case length(Addresses) > Limit_number of
	false -> 
	    ok;
	true ->
	    throw(etoorec)
    end.


%%%-------------------------
%%% Convert Destination XML to record
%%%-------------------------

convert_dest_record(XMLs) ->
    lists:map(
      fun(XML) ->
	      case xml:get_tag_attr_s("jid", XML) of
		  [] -> 
		      #dest{jid_string = none, full_xml = XML};
		  JIDS -> 
		      Type = xml:get_tag_attr_s("type", XML),
		      JIDJ = stj(JIDS),
		      #dest{jid_string = JIDS, 
			    jid_jid = JIDJ,
			    type = Type,
			    full_xml = XML}
	      end
      end,
      XMLs).


%%%-------------------------
%%% Split destinations by existence of JID
%%% and send error messages for other dests
%%%-------------------------

split_dests_jid(Dests) ->
    lists:partition(
      fun(Dest) ->
	      case Dest#dest.jid_string of
		  none -> false;
		  _ -> true
	      end
      end,
      Dests).

%% Sends an error message for each unknown address
%% Currently only 'jid' addresses are acceptable on ejabberd
report_not_jid(From, Packet, Dests) ->
    Dests2 = [xml:element_to_string(Dest#dest.full_xml) || Dest <- Dests],
    [route_error(From, From, Packet, jid_malformed, 
		 "This service can not process the address: " ++ D)
     || D <- Dests2].


%%%-------------------------
%%% Group destinations by their servers 
%%%-------------------------

group_dests(Dests) ->
    D = lists:foldl(
	  fun(Dest, Dict) ->
		  ServerS = (Dest#dest.jid_jid)#jid.server,
		  dict:append(ServerS, Dest, Dict)
	  end,
	  dict:new(),
	  Dests),
    Keys = dict:fetch_keys(D),
    [ #group{server = Key, dests = dict:fetch(Key, D)} || Key <- Keys ].


%%%-------------------------
%%% Look for cached responses
%%%-------------------------

look_cached_servers(LServerS, Groups) ->
    [look_cached(LServerS, Group) || Group <- Groups].

look_cached(LServerS, G) ->
    Maxtime_positive = ?MAXTIME_CACHE_POSITIVE,
    Maxtime_negative = ?MAXTIME_CACHE_NEGATIVE,

    Cached_response = 
	search_server_on_cache(G#group.server, LServerS,
			       {Maxtime_positive, Maxtime_negative}),
    G#group{multicast = Cached_response}.


%%%-------------------------
%%% Build delivered XML element
%%%-------------------------

build_others_xml(Groups) ->
    [Group#group{others = build_other_xml(Group#group.dests)} || Group <- Groups].

%% Add delivered=true
%% and remove addresses which type == bcc
build_other_xml(Dests) ->
    lists:foldl(
      fun(Dest, R) ->
	      XML = Dest#dest.full_xml,
	      case Dest#dest.type of
		  "to" -> [add_delivered(XML) | R];
		  "cc" -> [add_delivered(XML) | R];
		  "bcc" -> R;
		  _ -> [XML | R]
	      end
      end,
      [],
      Dests).

add_delivered({xmlelement, Name, Attrs, Els}) ->
    Attrs2 = [{"delivered", "true"} | Attrs],
    {xmlelement, Name, Attrs2, Els}.


%%%-------------------------
%%% Add preliminary packets
%%%-------------------------

add_addresses(Delivereds, Groups) ->
    Ps = [Group#group.others || Group <- Groups],
    add_addresses2(Delivereds, Groups, [], [], Ps).

add_addresses2(_, [], Res, _, []) ->
    Res;

add_addresses2(Delivereds, [Group | Groups], Res, Pa, [Pi | Pz]) ->
    Addresses = lists:append([Delivereds] ++ Pa ++ Pz),
    Group2 = Group#group{addresses = Addresses},
    add_addresses2(Delivereds, Groups, [Group2 | Res], [Pi | Pa], Pz).


%%%-------------------------
%%% Decide action groups
%%%-------------------------

decide_action_groups(Groups) ->
    [{decide_action_group(Group), Group} || Group <- Groups].

decide_action_group(Group) ->
    Server = Group#group.server,
    case Group#group.multicast of

	{cached, local_server} ->
	    %% Send a copy of the packet to each local user on Dests
	    route_single;

	{cached, not_supported} ->
	    %% Send a copy of the packet to each remote user on Dests
	    route_single;

	{cached, {multicast_supported, JID, RLimits}} ->
	    %% XEP33 is supported by the server, thanks to this service
	    {route_multicast, JID, RLimits};

	{obsolete, {multicast_supported, Old_service, _RLimits}} ->
	    {ask, Old_service, renewal};

	{obsolete, not_supported} ->
	    {ask, Server, not_renewal};

	not_cached ->
	    {ask, Server, not_renewal}

    end.


%%%-------------------------
%%% Route packet
%%%-------------------------

%% Build and send packet to this group of destinations
%% From = jid()
%% ToS = string()
route_packet(From, ToDest, Packet, AAttrs, Addresses) ->
    Dests = case ToDest#dest.type of
		"bcc" -> [];
		_ -> [ToDest]
	    end,
    route_packet2(From, ToDest#dest.jid_string, Dests, Packet, AAttrs, Addresses).

route_packet_multicast(From, ToS, Packet, AAttrs, Dests, Addresses, Limits) ->
    Type_of_stanza = type_of_stanza(Packet),
    {_Type, Limit_number} = get_limit_number(Type_of_stanza, Limits),
    Fragmented_dests = fragment_dests(Dests, Limit_number),
    [route_packet2(From, ToS, DFragment, Packet, AAttrs, Addresses) || DFragment <- Fragmented_dests].

route_packet2(From, ToS, Dests, Packet, AAttrs, Addresses) ->
    {xmlelement, T, A, C} = Packet,
    C2 = case append_dests(Dests, Addresses) of
	     [] ->
		 C;
	     ACs ->
		 [{xmlelement, "addresses", AAttrs, ACs} | C]
	 end,

    Packet2 = {xmlelement, T, A, C2},
    ToJID = stj(ToS),
    ejabberd_router:route(From, ToJID, Packet2).

append_dests([], Addresses) -> 
    Addresses;
append_dests([Dest | Dests], Addresses) ->
    append_dests(Dests, [Dest#dest.full_xml | Addresses]).


%%%-------------------------
%%% Check relay
%%%-------------------------

check_relay(RS, LS, Gs) ->
    case check_relay_required(RS, LS, Gs) of
	false -> ok;
	true -> throw(edrelay)
    end.

%% If the sender is external, and at least one destination is external,
%% then this package requires relaying
check_relay_required(RServer, LServerS, Groups) ->
    case string:str(RServer, LServerS) > 0 of
	true -> false;
	false -> check_relay_required(LServerS, Groups)
    end.

check_relay_required(LServerS, Groups) ->
    lists:any(
      fun(Group) ->
	      Group#group.server /= LServerS
      end,
      Groups).


%%%-------------------------
%%% Check protocol support: Send request
%%%-------------------------

%% Ask the server if it supports XEP33
send_query_info(RServerS, LServiceS) ->
    %% Don't ask a service which JID is "echo.*", 
    case string:str(RServerS, "echo.") of
	1 -> false;
	_ -> send_query(RServerS, LServiceS, ?NS_DISCO_INFO)
    end.

send_query_items(RServerS, LServiceS) ->
    send_query(RServerS, LServiceS, ?NS_DISCO_ITEMS).

send_query(RServerS, LServiceS, XMLNS) ->
    Packet = {xmlelement, "iq",
	      [{"to", RServerS}, {"type", "get"}],
	      [{xmlelement, "query", [{"xmlns", XMLNS}], []}]},

    ejabberd_router:route(stj(LServiceS), stj(RServerS), Packet).


%%%-------------------------
%%% Check protocol support: Receive response: Error
%%%-------------------------

process_iqreply_error(From, LServiceS, _Packet) ->
    %% We don't need to change the TO attribute in the outgoing XMPP packet,
    %% since ejabberd will do it

    %% We do not change the FROM attribute in the outgoing XMPP packet,
    %% this way the user will know what server reported the error

    FromS = jts(From),
    case search_waiter(FromS, LServiceS, info) of
	{found_waiter, Waiter} ->
	    received_awaiter(FromS, Waiter, LServiceS);
	_ -> ok
    end.


%%%-------------------------
%%% Check protocol support: Receive response: Disco
%%%-------------------------

process_iqreply_result(From, LServiceS, Packet, State) ->
    {xmlelement, "query", Attrs2, Els2} = xml:get_subtag(Packet, "query"),
    case xml:get_attr_s("xmlns", Attrs2) of
	?NS_DISCO_INFO ->
	    process_discoinfo_result(From, LServiceS, Els2, State);
	?NS_DISCO_ITEMS ->
	    process_discoitems_result(From, LServiceS, Els2)
    end.


%%%-------------------------
%%% Check protocol support: Receive response: Disco Info
%%%-------------------------

process_discoinfo_result(From, LServiceS, Els, _State) ->
    FromS = jts(From),
    case search_waiter(FromS, LServiceS, info) of
	{found_waiter, Waiter} ->
	    process_discoinfo_result2(From, FromS, LServiceS, Els, Waiter);
	_ -> 
	    ok
    end.

process_discoinfo_result2(From, FromS, LServiceS, Els, Waiter) ->
    %% Check the response, to see if it includes the XEP33 feature. If support ==
    Multicast_support = 
	lists:any(
	  fun(XML) ->
		  case XML of
		      {xmlelement, "feature", Attrs, _} ->
			  ?NS_ADDRESS == xml:get_attr_s("var", Attrs);
		      _ -> false
		  end
	  end,
	  Els),

    Group = Waiter#waiter.group,
    RServer = Group#group.server,

    case Multicast_support of
	true -> 
	    %% Inspect the XML of the disco#info response to get the limits of the remote service
	    SenderT = sender_type(From),
	    RLimits = get_limits_xml(Els, SenderT),

	    %% Store this response on cache
	    add_response(RServer, {multicast_supported, FromS, RLimits}),

	    %% Send XEP33 packet to JID
	    FromM = Waiter#waiter.sender,
	    DestsM =  Group#group.dests,
	    PacketM = Waiter#waiter.packet,
	    AAttrsM = Waiter#waiter.aattrs,
	    AddressesM = Waiter#waiter.addresses,
	    RServiceM = FromS,
	    route_packet_multicast(FromM, RServiceM, PacketM, AAttrsM, DestsM, AddressesM, RLimits),

	    %% Remove from Pool
	    delo_waiter(Waiter);

	false -> 
	    %% So we now know that JID does not support XEP33
	    case FromS of

		RServer ->
		    %% We asked the server, now let's see if any component supports it:

		    %% Send disco#items query to JID
		    send_query_items(FromS, LServiceS),

		    %% Store on Pool
		    delo_waiter(Waiter),
		    add_waiter(Waiter#waiter{
				 awaiting = {[FromS], LServiceS, items},
				 renewal = false
				});

		%% We asked a component, and it does not support XEP33
		_ ->
		    received_awaiter(FromS, Waiter, LServiceS)

	    end
    end.

get_limits_xml(Els, SenderT) ->
    %% Get limits reported by the remote service
    LimitOpts = get_limits_els(Els),

    %% Build the final list of limits
    %% For the ones not reported, put default numbers
    build_remote_limit_record(LimitOpts, SenderT).

%% Look for disco#info extras which may report limits
%% TODO: Check if there are useful functions in xml.erl to clean this code 
get_limits_els(Els) ->
    lists:foldl(
      fun(XML, R) -> 
	      case XML of 
		  {xmlelement, "x", Attrs, SubEls} ->
		      case (?NS_XDATA == xml:get_attr_s("xmlns", Attrs)) and
			  ("result" == xml:get_attr_s("type", Attrs)) of
			  true -> get_limits_fields(SubEls) ++ R;
			  false -> R
		      end;
		  _ -> R
	      end
      end,
      [],
      Els
     ).

get_limits_fields(Fields) ->
    {Head, Tail} = lists:partition(
		     fun(Field) -> 
			     case Field of 
				 {xmlelement, "field", Attrs, _SubEls} ->
				     ("FORM_TYPE" == xml:get_attr_s("var", Attrs)) 
					 and ("hidden" == xml:get_attr_s("type", Attrs));
				 _ -> false
			     end
		     end,
		     Fields
		    ),
    case Head of
	[] -> [];
	_ -> get_limits_values(Tail)
    end.

get_limits_values(Values) ->
    lists:foldl(
      fun(Value, R) -> 
	      case Value of 
		  {xmlelement, "field", Attrs, SubEls} -> 
		      %% TODO: Only one subel is expected here, but there may be several
		      [{xmlelement, "value", _AttrsV, SubElsV}] = SubEls,
		      Number = xml:get_cdata(SubElsV),
		      Name = xml:get_attr_s("var", Attrs),
		      [{list_to_atom(Name), list_to_integer(Number)} | R];
		  _ -> R
	      end
      end,
      [],
      Values
     ).


%%%-------------------------
%%% Check protocol support: Receive response: Disco Items
%%%-------------------------

process_discoitems_result(From, LServiceS, Els) ->
    %% Convert list of xmlelement into list of strings
    List = lists:foldl(
	     fun(XML, Res) ->
		     %% For each one, if it's "item", look for jid
		     case XML of
			 {xmlelement, "item", Attrs, _} ->
			     Res ++ [xml:get_attr_s("jid", Attrs)];
			 _ -> Res
		     end
	     end,
	     [],
	     Els),

    %% Send disco#info queries to each item
    [send_query_info(Item, LServiceS) || Item <- List],

    %% Search who was awaiting a disco#items response from this JID
    FromS = jts(From),
    {found_waiter, Waiter} = search_waiter(FromS, LServiceS, items),

    delo_waiter(Waiter),
    add_waiter(Waiter#waiter{
		 awaiting = {List, LServiceS, info},
		 renewal = false
		}).


%%%-------------------------
%%% Check protocol support: Receive response: Received awaiter
%%%-------------------------

received_awaiter(JID, Waiter, LServiceS) ->
    {JIDs, LServiceS, info} = Waiter#waiter.awaiting,
    delo_waiter(Waiter),
    Group = Waiter#waiter.group,
    RServer = Group#group.server,

    %% Remove this awaiter from the list of awaiting JIDs.
    case lists:delete(JID, JIDs) of

	[] ->
	    %% We couldn't find any service in this server that supports XEP33
	    case Waiter#waiter.renewal of

		false -> 
		    %% Store on cache the response
		    add_response(RServer, not_supported),

		    %% Send a copy of the packet to each remote user on Dests
		    From = Waiter#waiter.sender,
		    Packet = Waiter#waiter.packet,
		    AAttrs = Waiter#waiter.aattrs,
		    Addresses = Waiter#waiter.addresses,
		    [route_packet(From, ToUser, Packet, AAttrs, Addresses) 
		     || ToUser <- Group#group.dests];

		true -> 
		    %% We asked this component because the cache 
		    %% said it would support XEP33, but it doesn't!
		    send_query_info(RServer, LServiceS),
		    add_waiter(Waiter#waiter{
				 awaiting = {[RServer], LServiceS, info},
				 renewal = false
				})
	    end;

	JIDs2 ->
	    %% Maybe other component on the server supports XEP33
	    add_waiter(Waiter#waiter{
			 awaiting = {JIDs2, LServiceS, info},
			 renewal = false
			})
    end.


%%%-------------------------
%%% Cache
%%%-------------------------

create_cache() ->
    mnesia:create_table(multicastc, [{ram_copies, [node()]},
				     {attributes, record_info(fields, multicastc)}]).

%% Add this response to the cache.
%% If a previous response still exists, it's overwritten
add_response(RServer, Response) ->
    Secs = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
    mnesia:dirty_write(#multicastc{rserver = RServer,
				   response = Response,
				   ts = Secs}).

%% Search on the cache if there is a response for the server
%% If there is a response but is obsolete,
%% don't bother removing since it will later be overwritten anyway
search_server_on_cache(RServer, LServerS, _Maxmins)
  when RServer == LServerS ->
    {cached, local_server};

search_server_on_cache(RServer, _LServerS, Maxmins) ->
    case look_server(RServer) of
	not_cached ->
	    not_cached;
	{cached, Response, Ts} ->
	    Now = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
	    case is_obsolete(Response, Ts, Now, Maxmins) of
		false -> {cached, Response};
		true -> {obsolete, Response}
	    end
    end.

look_server(RServer) ->
    case mnesia:dirty_read(multicastc, RServer) of
	[] -> not_cached;
	[M] -> {cached, M#multicastc.response, M#multicastc.ts}
    end.

is_obsolete(Response, Ts, Now, {Max_pos, Max_neg}) ->
    Max = case Response of
	      multicast_not_supported -> Max_neg;
	      _ -> Max_pos
	  end,
    (Now - Ts) > Max.


%%%-------------------------
%%% Purge cache
%%%-------------------------

purge() ->
    Maxmins_positive = ?MAXTIME_CACHE_POSITIVE,
    Maxmins_negative = ?MAXTIME_CACHE_NEGATIVE,
    Now = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
    purge(Now, {Maxmins_positive, Maxmins_negative}).

purge(Now, Maxmins) ->
    F = fun() ->
		mnesia:foldl(
		  fun(R, _) ->
			  #multicastc{response = Response, ts = Ts} = R,
			  %% If this record is obsolete, delete it
			  case is_obsolete(Response, Ts, Now, Maxmins) of
			      true -> mnesia:delete_object(R);
			      false -> ok
			  end
		  end,
		  none,
		  multicastc)
	end,
    mnesia:transaction(F).


%%%-------------------------
%%% Purge cache loop
%%%-------------------------

try_start_loop() ->
    case lists:member(?PURGE_PROCNAME, registered()) of
	true -> ok;
	false -> start_loop()
    end,
    ?PURGE_PROCNAME ! new_module.

start_loop() ->
    register(?PURGE_PROCNAME, spawn(?MODULE, purge_loop, [0])),
    ?PURGE_PROCNAME ! purge_now.

try_stop_loop() ->
    ?PURGE_PROCNAME ! try_stop.

%% NM = number of modules are running on this node
purge_loop(NM) ->
    receive
	purge_now ->
	    purge(),
	    timer:send_after(?CACHE_PURGE_TIMER, ?PURGE_PROCNAME, purge_now),
	    purge_loop(NM);
	new_module ->
	    purge_loop(NM + 1);
	try_stop when NM > 1 ->
	    purge_loop(NM - 1);
	try_stop ->
	    purge_loop_finished
    end.


%%%-------------------------
%%% Pool
%%%-------------------------

create_pool() ->
    catch ets:new(multicastp, [duplicate_bag, public, named_table, {keypos, 2}]).

%% If a Waiter with the same key exists, it overwrites it
add_waiter(Waiter) ->
    true = ets:insert(multicastp, Waiter).

delo_waiter(Waiter) ->
    true = ets:delete_object(multicastp, Waiter).

%% Search on the Pool who is waiting for this result
%% If there are several matches, pick the first one only
search_waiter(JID, LServiceS, Type) ->
    Rs = ets:foldl(
	   fun(W, Res) ->
		   {JIDs, LServiceS1, Type1} = W#waiter.awaiting,
		   case lists:member(JID, JIDs) 
		       and (LServiceS == LServiceS1)
		       and (Type1 == Type) of
		       true -> Res ++ [W];
		       false -> Res
		   end
	   end,
	   [],
	   multicastp
	  ),
    case Rs of
	[R | _] -> {found_waiter, R};
	[] -> waiter_not_found
    end.


%%%-------------------------
%%% Limits: utils
%%%-------------------------

%% Type definitions for data structures related with XEP33 limits
%% limit() = {Name, Value}
%% Name = atom()
%% Value = {Type, Number}
%% Type = default | custom
%% Number = integer() | infinite

list_of_limits(local) ->
    [{message, ?DEFAULT_LIMIT_LOCAL_MESSAGE},
     {presence, ?DEFAULT_LIMIT_LOCAL_PRESENCE}];

list_of_limits(remote) ->
    [{message, ?DEFAULT_LIMIT_REMOTE_MESSAGE},
     {presence, ?DEFAULT_LIMIT_REMOTE_PRESENCE}].

build_service_limit_record(LimitOpts) -> 
    LimitOptsL = get_from_limitopts(LimitOpts, local),
    LimitOptsR = get_from_limitopts(LimitOpts, remote),
    {service_limits,
     build_limit_record(LimitOptsL, local),
     build_limit_record(LimitOptsR, remote)
    }.

get_from_limitopts(LimitOpts, SenderT) ->
    [{StanzaT, Number} 
     || {SenderT2, StanzaT, Number} <- LimitOpts, 
	SenderT =:= SenderT2].

%% Build a record of type #limits{}
%% In fact, it builds a list and then converts to tuple
%% It is important to put the elements in the list in 
%% the same order than the elements in record #limits
build_remote_limit_record(LimitOpts, SenderT) ->
    build_limit_record(LimitOpts, SenderT).

build_limit_record(LimitOpts, SenderT) ->
    Limits = [
	      get_limit_value(Name, Default, LimitOpts) 
	      || {Name, Default} <- list_of_limits(SenderT)],
    list_to_tuple([limits | Limits]).

get_limit_value(Name, Default, LimitOpts) ->
    case lists:keysearch(Name, 1, LimitOpts) of
	{value, {Name, Number}} -> 
	    {custom, Number};
	false -> 
	    {default, Default}
    end.

type_of_stanza({xmlelement, "message", _, _}) -> message;
type_of_stanza({xmlelement, "presence", _, _}) -> presence.

get_limit_number(message, Limits) -> Limits#limits.message;
get_limit_number(presence, Limits) -> Limits#limits.presence.

get_slimit_group(local, SLimits) -> SLimits#service_limits.local;
get_slimit_group(remote, SLimits) -> SLimits#service_limits.remote.

fragment_dests(Dests, Limit_number) ->
    {R, _} = lists:foldl(
	       fun(Dest, {Res, Count}) ->
		       case Count of
			   Limit_number ->
			       Head2 = [Dest],
			       {[Head2 | Res], 0};
			   _ ->
			       [Head | Tail] = Res,
			       Head2 = [Dest | Head],
			       {[Head2 | Tail], Count+1}
		       end
	       end,
	       {[[]], 0},
	       Dests),
    R.


%%%-------------------------
%%% Limits: XEP-0128 Service Discovery Extensions
%%%-------------------------

%% Some parts of code are borrowed from mod_muc_room.erl

-define(RFIELDT(Type, Var, Val),
	{xmlelement, "field", [{"var", Var}, {"type", Type}],
	 [{xmlelement, "value", [], [{xmlcdata, Val}]}]}).

-define(RFIELDV(Var, Val),
	{xmlelement, "field", [{"var", Var}],
	 [{xmlelement, "value", [], [{xmlcdata, Val}]}]}).

iq_disco_info_extras(From, State) ->
    SenderT = sender_type(From),
    Service_limits = State#state.service_limits,
    case iq_disco_info_extras2(SenderT, Service_limits) of
	[] -> [];
	List_limits_xmpp ->
	    [{xmlelement, "x", [{"xmlns", ?NS_XDATA}, {"type", "result"}],
	      [?RFIELDT("hidden", "FORM_TYPE", ?NS_ADDRESS)] ++ List_limits_xmpp
	     }]
    end.

sender_type(From) ->
    Local_hosts = ?MYHOSTS,
    case lists:member(From#jid.lserver, Local_hosts) of
	true -> local;
	false -> remote
    end.

iq_disco_info_extras2(SenderT, SLimits) ->
    %% And report only the limits that are interesting for this sender
    Limits = get_slimit_group(SenderT, SLimits),
    Stanza_types = [message, presence],
    lists:foldl(
      fun(Type_of_stanza, R) ->
	      %% Report only custom limits
	      case get_limit_number(Type_of_stanza, Limits) of
		  {custom, Number} ->
		      [?RFIELDV(to_string(Type_of_stanza), to_string(Number)) | R];
		  {default, _} -> R
	      end
      end,
      [],
      Stanza_types).

to_string(A) ->
    hd(io_lib:format("~p",[A])).


%%%-------------------------
%%% Error report
%%%-------------------------

route_error(From, To, Packet, ErrType, ErrText) ->
    {xmlelement, _Name, Attrs, _Els} = Packet,
    Lang = xml:get_attr_s("xml:lang", Attrs),
    Reply = make_reply(ErrType, Lang, ErrText),
    Err = jlib:make_error_reply(Packet, Reply),
    ejabberd_router:route(From, To, Err).

make_reply(bad_request, Lang, ErrText) ->
    ?ERRT_BAD_REQUEST(Lang, ErrText);
make_reply(jid_malformed, Lang, ErrText) ->
    ?ERRT_JID_MALFORMED(Lang, ErrText);
make_reply(not_acceptable, Lang, ErrText) ->
    ?ERRT_NOT_ACCEPTABLE(Lang, ErrText);
make_reply(internal_server_error, Lang, ErrText) ->
    ?ERRT_INTERNAL_SERVER_ERROR(Lang, ErrText);
make_reply(forbidden, Lang, ErrText) ->
    ?ERRT_FORBIDDEN(Lang, ErrText).

stj(String) -> jlib:string_to_jid(String).
jts(String) -> jlib:jid_to_string(String).
