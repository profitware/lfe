%% Copyright (c) 2016 Eric Bailey
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : lfe_doc.erl
%% Author  : Eric Bailey
%% Purpose : Lisp Flavoured Erlang documentation parser.

%% The functions herein are used internally by the compiler.
%% There is no guarantee the API will not change dramatically in future.

-module(lfe_doc).

-export([format_error/1]).

-export([module/1,patterns/1,add_docs_module/1]).

-import(beam_lib, [chunks/2]).
-import(lfe_lib, [is_symb_list/1,is_proper_list/1]).
-import(lists, [reverse/1,foldl/3]).
-import(ordsets, [is_element/2]).
-import(proplists, [get_value/3]).

-include("lfe_comp.hrl").
-include("lfe_doc.hrl").

%% Skip if exclude/1 is true, otherwise check for bad patterns.
-define(DO_MOD(Docs,Type,Name,Body,DocStr,Line,Defs),
        ?IF(exclude(Name), do_module(Docs, Defs),
            case patterns(Body) of
                no ->
                    Error = {Line,?MODULE,{bad_lambda,Name,Body}},
                    do_module([Error|Docs], Defs);
                {yes,Arity,Patterns} ->
                    ?IF(exclude({Name,Arity}), do_module(Docs, Defs),
                        begin
                            Doc = make_doc(Type, Name, Arity, Patterns, DocStr),
                            do_module([Doc|Docs], Defs)
                        end)
            end)).

%% Errors
format_error({bad_lambda,Name,Lambda}) ->
    lfe_io:format1("bad lambda: ~p\n    ~P", [Name,Lambda,10]).

-spec module(#module{code::Defs}) -> #module{docs::Docs} | {error,Reason} when
      Defs   :: [{[_],Line}],
      Line   :: non_neg_integer(),
      Docs   :: [doc()],
      Reason :: term().
module(#module{code=[]}=Mod)   -> Mod#module{docs=[]};
module(#module{code=Defs}=Mod) ->
    Docs = do_module([], Defs),
    Errors = lists:filter(fun (#doc{}) -> false; (_) -> true end, Docs),
    ?IF([] =:= Errors,
        Mod#module{docs=Docs},
        {error,Errors,[]}).

-spec do_module(Docs, Defs) -> Docs | {error,Line,Error} when
      Docs :: [doc()],
      Defs :: [{[_],Line}],
      Line :: non_neg_integer(),
      Error :: {bad_lambda,[_]}.
do_module(Docs, [{['define-function',Name,Body,DocStr],Line}|Defs]) ->
    ?DO_MOD(Docs,function,Name,Body,DocStr,Line,Defs);
do_module(Docs, [{['define-macro',Name,Body,DocStr],Line}|Defs]) ->
    ?DO_MOD(Docs,macro,Name,Body,DocStr,Line,Defs);
do_module(Docs, [_|Defs]) -> do_module(Docs, Defs);
do_module(Docs, [])       -> Docs.

%% exclude(Name | {Name,Arity}) -> boolean().
%%  Return true if a function should be excluded from the docs chunk.

-spec exclude(Name | {Name,Arity}) -> boolean() when
      Name  :: atom(),
      Arity :: non_neg_integer().
exclude({'LFE-EXPAND-EXPORTED-MACRO',3}) -> true;
exclude('MODULE')                        -> true;
exclude(_)                               -> false.

%% patterns(LambdaForm) -> no | {yes,Arity,Patterns}.
%%  Given a {match-,}lambda form, attempt to return its patterns (or arglist).
%%  N.B. Guards are appended to patterns and Patterns is always a list of lists.

-spec patterns(LambdaForm) -> 'no' | {'yes',Arity,Patterns} when
      LambdaForm :: nonempty_list(),
      Arity      :: non_neg_integer(),
      Patterns   :: nonempty_list(pattern()).
patterns([lambda,Args|_]) ->
    ?IF(is_symb_list(Args), {yes,length(Args),[Args]}, no);
patterns(['match-lambda',[[[list|Pat],'$ENV'],['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(length(Pat), [Pat++[Guard]], Cls),
        do_patterns(255, [Pat], Cls));
patterns(['match-lambda',[[Pat,'$ENV'],['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(length(Pat), [Pat++[Guard]], Cls),
        do_patterns(255, [Pat], Cls));
patterns(['match-lambda',[[[list|Pat],'$ENV']|_]|Cls]) ->
    ?IF(is_proper_list(Pat), do_patterns(length(Pat), [Pat], Cls), no);
patterns(['match-lambda',[[Pat,'$ENV']|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(length(Pat), [Pat], Cls),
        do_patterns(255, [Pat], Cls));
patterns(['match-lambda',[Pat,['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat), do_patterns(length(Pat), [Pat++[Guard]], Cls), no);
patterns(['match-lambda',[Pat|_]|Cls]) ->
    ?IF(is_proper_list(Pat), do_patterns(length(Pat), [Pat], Cls), no);
patterns(_) -> no.

do_patterns(N, Acc, [[[[list|Pat],'$ENV'],['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat++[Guard]|Acc], Cls),
        do_patterns(255, [Pat++[Guard]|Acc], Cls));
do_patterns(N, Acc, [[[Pat,'$ENV'],['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat++[Guard]|Acc], Cls),
        do_patterns(255, [Pat++[Guard]|Acc], Cls));
do_patterns(N, Acc, [[[[list|Pat],'$ENV']|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat|Acc], Cls),
        do_patterns(255, [Pat|Acc], Cls));
do_patterns(N, Acc, [[[Pat,'$ENV']|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat|Acc], Cls),
        do_patterns(255, [Pat|Acc], Cls));
do_patterns(N, Acc, [[Pat,['when'|_]=Guard|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat++[Guard]|Acc], Cls),
        no);
do_patterns(N, Acc, [[Pat|_]|Cls]) ->
    ?IF(is_proper_list(Pat),
        do_patterns(?IF(N =:= length(Pat), N, 255), [Pat|Acc], Cls),
        no);
do_patterns(N, Acc, []) -> {yes,N,reverse(Acc)};
do_patterns(_, _, _) -> no.

%% make_doc(Type, Name, Arity, Patterns, Doc) -> doc().
%%  Convenience constructor for #doc{}, which is defined in src/lfe_doc.hrl.

-spec make_doc(Type, Name, Arity, Patterns, Doc) -> doc() when
      Type     :: 'function' | 'macro',
      Name     :: atom(),
      Arity    :: non_neg_integer(),
      Patterns :: [[]],
      Doc      :: binary().
make_doc(Type, Name, Arity, Patterns, Doc0) when is_list(Doc0) ->
    Doc1 = unicode:characters_to_binary(Doc0, utf8, utf8),
    make_doc(Type, Name, Arity, Patterns, Doc1);
make_doc(Type, Name, Arity, Patterns, Doc) when is_binary(Doc) ->
    #doc{type=Type,name=Name,arity=Arity,patterns=Patterns,doc=Doc}.

add_docs_module(#module{}=Mod0) ->
    {ModDoc,#module{code=Bin,docs=Docs}=Mod1} = exports_attributes(Mod0),
    %% Modified from elixir_module
    LDoc = term_to_binary(#lfe_docs_v1{
                             docs=Docs,
                             moduledoc=ModDoc
                             %% callback_docs=CallbackDocs,
                             %% type_docs=TypeDocs
                            }),
    Mod1#module{code=add_beam_chunk(Bin, "LDoc", LDoc)};
add_docs_module(_) -> error.

%% exports_attributes(Mod) -> Mod.
%%  Iterate over Mod's 'docs' and set their 'exported' values appropriately.

-spec exports_attributes(Mod) -> Mod when
      Mod :: #module{}.
exports_attributes(#module{name=Name,code=Beam0,docs=Docs0}=Mod) ->
    ChunkRefs = [exports,attributes],
    {ok,{Name,[{exports,Expt},{attributes,Attr0}]}} = chunks(Beam0, ChunkRefs),
    Expm = get_value('export-macro', Attr0, []),
    {ModDoc,Attr1} = moduledoc(Attr0),
    Beam1 = add_beam_chunk(Beam0, "Attr", term_to_binary(Attr1)),
    Docs1 = foldl(do_exports(Expt, Expm), [], Docs0),
    {ModDoc,Mod#module{docs=Docs1,code=Beam1}}.

moduledoc(Attr0) ->
    ModDoc = iolist_to_binary(get_value(doc, Attr0, "")),
    {ModDoc,proplists:delete(doc, Attr0)}.

%% do_exports(Expt, Expm) -> Fun.
%%  Close over Expt and Expm then return the folding function for exports/1.

-spec do_exports(Expt, Expm) -> Fun when
      Expt :: [{atom(),non_neg_integer()}],
      Expm :: [atom()],
      Fun  :: fun((doc(), [doc()]) -> [doc()]).
do_exports(Expt, Expm) ->
    fun (#doc{type=function,name=F,arity=A}=Doc, Docs) ->
            [Doc#doc{exported=is_element({F,A}, Expt)}|Docs];
        (#doc{type=macro,name=M}=Doc, Docs) ->
            [Doc#doc{exported=is_element(M, Expm)}|Docs]
    end.

%% Modified from elixir_module: Upserts a custom chunk into a beam module.
add_beam_chunk(Bin, Id, ChunkData)
  when is_binary(Bin), is_list(Id), is_binary(ChunkData) ->
    {ok, _, Chunks0} = beam_lib:all_chunks(Bin),
    NewChunk = {Id, ChunkData},
    Chunks = [NewChunk|proplists:delete(Id, Chunks0)],
    {ok, NewBin} = beam_lib:build_module(Chunks),
    NewBin.