-module(erlfmt_scan).

-oncall("whatsapp_erlang").

-typing([dialyzer]).

-include("erlfmt.hrl").

-export([io_form/1, string_form/1, continue/1, last_form_string/1]).
-export([put_anno/3, delete_anno/2, delete_annos/2, get_anno/2, get_anno/3]).

-export_type([state/0, anno/0, token/0, comment/0]).

-define(ERL_SCAN_OPTS, [text, return_white_spaces, return_comments]).

-define(START_LOCATION, {1, 1}).

-type inner() :: term().

-type scan() :: fun((inner(), erl_anno:location()) -> {erl_scan:tokens_result() | {error, term()}, inner()}).

-record(state, {
    scan :: scan(),
    inner :: inner(),
    loc = ?START_LOCATION :: erl_anno:location(),
    original :: [erl_scan:token()],
    buffer :: [erl_scan:token()]
}).

-type comment() :: {comment, anno(), [string()]}.

-type anno() :: #{location := location(), end_location := location(), text => string(), atom() => term()}.

-type location() :: {pos_integer(), pos_integer()}.

-type token() :: {atom(), anno(), term()} | {atom(), anno()}.

-type form_ret() ::
    {ok, [token()], [comment()], state()} |
    {error, {erl_anno:location(), module(), term()}, erl_anno:location()} |
    {eof, erl_anno:location()}.

-opaque state() :: #state{}.

-spec io_form(file:io_device()) -> form_ret().
io_form(IO) -> form(fun io_scan_erl_form/2, IO).

-spec string_form(string()) -> form_ret().
string_form(String) -> form(fun erl_scan_tokens/2, String).

form(Scan, Inner) -> continue(Scan, Inner, ?START_LOCATION, []).

-spec continue(state()) -> form_ret().
continue(#state{scan = Scan, inner = Inner, loc = Loc, buffer = Buffer}) ->
    continue(Scan, Inner, Loc, Buffer).

continue(Scan, Inner0, Loc0, []) ->
    case Scan(Inner0, Loc0) of
        {{ok, Tokens, Loc}, Inner} ->
            continue(Scan, Inner, Loc, Tokens);
        {{error, Reason}, _Inner} ->
            {error, {Loc0, file, Reason}};
        {Other, _Inner} ->
            Other
    end;
continue(Scan, Inner0, Loc0, Buffer0) ->
    case Scan(Inner0, Loc0) of
        {{ok, Tokens0, Loc}, Inner} ->
            {Tokens, FormTokens, Comments, Buffer} = split_tokens(Buffer0, Tokens0),
            State = #state{scan = Scan, inner = Inner, loc = Loc, original = FormTokens, buffer = Buffer},
            {ok, Tokens, Comments, State};
        {{eof, Loc}, _Inner} ->
            {Tokens, FormTokens, Comments, []} = split_tokens(Buffer0, []),
            State = #state{scan = fun eof/2, inner = undefined, loc = Loc, original = FormTokens, buffer = []},
            {ok, Tokens, Comments, State};
        {{error, Reason}, _Inner} ->
            {error, {Loc0, file, Reason}};
        {Other, _Rest} ->
            Other
    end.

io_scan_erl_form(IO, Loc) ->
    {io:scan_erl_form(IO, "", Loc, ?ERL_SCAN_OPTS), IO}.

erl_scan_tokens(String, Loc) ->
    case erl_scan:tokens([], String, Loc, ?ERL_SCAN_OPTS) of
        {more, Cont} ->
            {done, Resp, eof} = erl_scan:tokens(Cont, eof, Loc, ?ERL_SCAN_OPTS),
            {Resp, eof};
        {done, Resp, Rest} ->
            {Resp, Rest}
    end.

eof(undefined, Loc) ->
    {{eof, Loc}, undefined}.

-spec last_form_string(state()) -> unicode:chardata().
last_form_string(#state{original = Tokens}) ->
    [stringify_token(Token) || Token <- Tokens].

%% TODO: make smarter
stringify_token(Token) -> erl_anno:text(element(2, Token)).

-spec split_tokens([erl_scan:token()], [erl_scan:token()]) -> {[token()], [erl_scan:token()], [comment()], [token()]}.
split_tokens(Tokens, ExtraTokens0) ->
    case split_tokens(Tokens, [], []) of
        {[], Comments} ->
            {[], Tokens, Comments, ExtraTokens0};
        {TransformedTokens, Comments} ->
            #{end_location := {LastLine, _}} = element(2, lists:last(TransformedTokens)),
            {ExtraComments, ExtraTokens, ExtraRest} = split_extra(ExtraTokens0, LastLine, [], []),
            {TransformedTokens, Tokens ++ ExtraTokens, Comments ++ ExtraComments, ExtraRest}
    end.

%% TODO: annotate [, {, <<, (, -> with following newline info to control user folding/expanding
split_tokens([{comment, _, _} = Comment0 | Rest0], Acc, CAcc) ->
    {Comment, Rest} = collect_comments(Rest0, Comment0),
    split_tokens(Rest, Acc, [Comment | CAcc]);
split_tokens([{white_space, _, _} | Rest], Acc, CAcc) ->
    split_tokens(Rest, Acc, CAcc);
split_tokens([{Atomic, Meta, Value} | Rest], Acc, CAcc) when ?IS_ATOMIC(Atomic) ->
    split_tokens(Rest, [{Atomic, atomic_anno(erl_anno:to_term(Meta)), Value} | Acc], CAcc);
split_tokens([{Type, Meta, Value} | Rest], Acc, CAcc) ->
    split_tokens(Rest, [{Type, token_anno(erl_anno:to_term(Meta)), Value} | Acc], CAcc);
%% Keep the `text` value for if in case it's used as an attribute
split_tokens([{Type, Meta} | Rest], Acc, CAcc) when Type =:= 'if' ->
    split_tokens(Rest, [{Type, atomic_anno(erl_anno:to_term(Meta))} | Acc], CAcc);
split_tokens([{Type, Meta} | Rest], Acc, CAcc) ->
    split_tokens(Rest, [{Type, token_anno(erl_anno:to_term(Meta))} | Acc], CAcc);
split_tokens([], Acc, CAcc) ->
    {lists:reverse(Acc), lists:reverse(CAcc)}.

split_extra([{comment, Meta, Text} = Token | Rest], Line, Acc, CAcc) ->
    case erl_anno:line(Meta) of
        Line ->
            MetaTerm = erl_anno:to_term(Meta),
            Comment = {comment, comment_anno(MetaTerm, MetaTerm), [Text]},
            split_extra(Rest, Line, Acc, [Comment | CAcc]);
        _ ->
            {lists:reverse(CAcc), lists:reverse(Acc), [Token | Rest]}
    end;
split_extra([{white_space, _, _} = Token | Rest], Line, Acc, CAcc) ->
    split_extra(Rest, Line, [Token | Acc], CAcc);
split_extra(Rest, _Line, Acc, CAcc) ->
    {lists:reverse(CAcc), lists:reverse(Acc), Rest}.

collect_comments(Tokens, {comment, Meta, Text}) ->
    Line = erl_anno:line(Meta),
    {Texts, LastMeta, Rest} = collect_comments(Tokens, Line, Meta, [Text]),
    Anno = comment_anno(erl_anno:to_term(Meta), erl_anno:to_term(LastMeta)),
    {{comment, Anno, Texts}, Rest}.

collect_comments([{white_space, _, _} | Rest], Line, LastMeta, Acc) ->
    collect_comments(Rest, Line, LastMeta, Acc);
collect_comments([{comment, Meta, Text} = Comment | Rest], Line, LastMeta, Acc) ->
    case erl_anno:line(Meta) of
        NextLine when NextLine =:= Line + 1 ->
            collect_comments(Rest, NextLine, Meta, [Text | Acc]);
        _ ->
            {lists:reverse(Acc), LastMeta, [Comment | Rest]}
    end;
collect_comments(Other, _Line, LastMeta, Acc) ->
    {lists:reverse(Acc), LastMeta, Other}.

atomic_anno([{text, Text}, {location, {Line, Col} = Location}]) ->
    #{text => Text, location => Location, end_location => end_location(Text, Line, Col)}.

token_anno([{text, Text}, {location, {Line, Col} = Location}]) ->
    #{location => Location, end_location => end_location(Text, Line, Col)}.

comment_anno([{text, _}, {location, Location}], [{text, Text}, {location, {Line, Col}}]) ->
    #{location => Location, end_location => end_location(Text, Line, Col)}.

put_anno(Key, Value, Anno) when is_map(Anno) ->
    Anno#{Key => Value};
put_anno(Key, Value, Node) when is_tuple(Node) ->
    setelement(2, Node, (element(2, Node))#{Key => Value}).

delete_anno(Key, Anno) when is_map(Anno) ->
    maps:remove(Key, Anno);
delete_anno(Key, Node) when is_tuple(Node) ->
    setelement(2, Node, maps:remove(Key, element(2, Node))).

delete_annos(Keys, Anno) when is_map(Anno) ->
    maps:without(Keys, Anno);
delete_annos(Keys, Node) when is_tuple(Node) ->
    setelement(2, Node, maps:without(Keys, element(2, Node))).

get_anno(Key, Anno) when is_map(Anno) ->
    map_get(Key, Anno);
get_anno(Key, Node) when is_tuple(Node) ->
    map_get(Key, element(2, Node)).

get_anno(Key, Anno, Default) when is_map(Anno) ->
    maps:get(Key, Anno, Default);
get_anno(Key, Node, Default) when is_tuple(Node) ->
    maps:get(Key, element(2, Node), Default).

end_location("", Line, Column) ->
    {Line, Column};
end_location([$\n|String], Line, _Column) ->
    end_location(String, Line+1, 1);
end_location([_|String], Line, Column) ->
    end_location(String, Line, Column+1).
