%% Those macros are local and can be partially applied.
%% In the future, they may even be overriden by imports.
-module(elixir_macros).
-export([translate_macro/2]).
-import(elixir_translator, [translate_each/2, translate/2, translate_args/2, translate_apply/7]).
-import(elixir_tree_helpers, [umergec/2]).
-import(elixir_errors, [syntax_error/4]).
-include("elixir.hrl").

%% Operators

translate_macro({ '+', _Line, [Expr] }, S) when is_number(Expr) ->
  record('+', S),
  translate_each(Expr, S);

translate_macro({ '-', _Line, [Expr] }, S) when is_number(Expr) ->
  record('-', S),
  translate_each(-1 * Expr, S);

translate_macro({ Op, Line, Exprs }, S) when is_list(Exprs),
  Op == '+'; Op == '-'; Op == '*'; Op == '/'; Op == '<-';
  Op == '++'; Op == '--'; Op == 'andalso'; Op == 'orelse';
  Op == 'not'; Op == 'and'; Op == 'or'; Op == 'xor';
  Op == '<'; Op == '>'; Op == '<='; Op == '>=';
  Op == '=='; Op == '!='; Op == '==='; Op == '!==' ->
  record(Op, S),
  translate_macro({ erlang_op, Line, [Op|Exprs] }, S);

%% Erlang Operators

translate_macro({ erlang_op, Line, [Op, Expr] }, S) when is_atom(Op) ->
  record(erlang_op, S),
  { TExpr, NS } = translate_each(Expr, S),
  { { op, Line, convert_op(Op), TExpr }, NS };

translate_macro({ erlang_op, Line, [Op|Args] }, S) when is_atom(Op) ->
  record(erlang_op, S),
  { [TLeft, TRight], NS }  = translate_args(Args, S),
  { { op, Line, convert_op(Op), TLeft, TRight }, NS };

%% Case

translate_macro({'case', Line, [Expr, RawClauses]}, S) ->
  record('case', S),
  Clauses = orddict:erase(do, RawClauses),
  { TExpr, NS } = translate_each(Expr, S),
  { TClauses, TS } = elixir_clauses:match(Line, Clauses, NS),
  { { 'case', Line, TExpr, TClauses }, TS };

%% Try

translate_macro({'try', Line, [Clauses]}, RawS) ->
  record('try', RawS),
  Do    = proplists:get_value('do',    Clauses, []),
  Catch = proplists:get_value('catch', Clauses, []),
  After = proplists:get_value('after', Clauses, []),

  S = RawS#elixir_scope{noname=true},

  { TDo, SB }    = translate([Do], S),
  { TCatch, SC } = elixir_clauses:try_catch(Line, [{'catch',Catch}], umergec(S, SB)),
  { TAfter, SA } = translate([After], umergec(S, SC)),
  { { 'try', Line, unpack_try(do, TDo), [], TCatch, unpack_try('after', TAfter) }, umergec(RawS, SA) };

%% Receive

translate_macro({'receive', Line, [RawClauses] }, S) ->
  record('receive', S),
  Clauses = orddict:erase(do, RawClauses),
  case orddict:find('after', Clauses) of
    { ok, After } ->
      AClauses = orddict:erase('after', Clauses),
      { TClauses, SC } = elixir_clauses:match(Line, AClauses ++ [{'after',After}], S),
      { FClauses, [TAfter] } = lists:split(length(TClauses) - 1, TClauses),
      { _, _, [FExpr], _, FAfter } = TAfter,
      { { 'receive', Line, FClauses, FExpr, FAfter }, SC };
    error ->
      { TClauses, SC } = elixir_clauses:match(Line, Clauses, S),
      { { 'receive', Line, TClauses }, SC }
  end;

%% Definitions

translate_macro({defmodule, Line, [Ref, [{do,Block}]]}, S) ->
  record(defmodule, S),
  { TRef, _ } = translate_each(Ref, S#elixir_scope{noref=true}),

  NS = case TRef of
    { atom, _, Module } ->
      S#elixir_scope{scheduled=[Module|S#elixir_scope.scheduled]};
    _ -> S
  end,

  { elixir_module:transform(Line, TRef, Block, S), NS };

translate_macro({Kind, Line, [Call,[{do, Expr}]]}, S) when Kind == def; Kind == defp; Kind == defmacro ->
  record(Kind, S),
  case S#elixir_scope.function /= [] of
    true ->
      syntax_error(Line, S#elixir_scope.filename, "invalid function scope for: ", atom_to_list(Kind));
    _ ->
      { elixir_def:wrap_definition(Kind, Line, Call, Expr, S), S }
  end;

translate_macro({Kind, Line, [Call]}, S) when Kind == def; Kind == defmacro; Kind == defp ->
  record(Kind, S),
  { Name, Args } = elixir_clauses:extract_args(Call),
  { { tuple, Line, [{ atom, Line, Name }, { integer, Line, length(Args) }] }, S };

translate_macro({Kind, Line, Args}, S) when is_list(Args), Kind == def; Kind == defmacro; Kind == defp ->
  syntax_error(Line, S#elixir_scope.filename, "invalid args for: ", atom_to_list(Kind));

%% Functions

translate_macro({fn, Line, RawArgs}, S) when is_list(RawArgs) ->
  record(fn, S),
  Clauses = case lists:split(length(RawArgs) - 1, RawArgs) of
    { Args, [[{do,Expr}]] } ->
      [{match,Args,Expr}];
    { [], [KV] } when is_list(KV) ->
      elixir_kv_block:decouple(orddict:erase(do, KV));
    _ ->
      syntax_error(Line, S#elixir_scope.filename, "no block given for: ", "fn")
  end,

  Transformer = fun({ match, ArgsWithGuards, Expr }, Acc) ->
    { FinalArgs, Guards } = elixir_clauses:extract_last_guards(ArgsWithGuards),
    elixir_clauses:assigns_block(Line, fun elixir_translator:translate/2, FinalArgs, [Expr], Guards, umergec(S, Acc))
  end,

  { TClauses, NS } = lists:mapfoldl(Transformer, S, Clauses),
  { { 'fun', Line, {clauses, TClauses} }, umergec(S, NS) };

%% Modules directives

translate_macro({use, Line, [Ref|Args]}, S) ->
  record(use, S),
  case S#elixir_scope.module of
    {0,nil} ->
      syntax_error(Line, S#elixir_scope.filename, "cannot invoke use outside module. invalid scope for: ", "use");
    {_,Module} ->
      Call = { block, Line, [
        { require, Line, [Ref] },
        { { '.', Line, [Ref, '__using__'] }, Line, [Module|Args] }
      ] },
      translate_each(Call, S)
  end;

translate_macro({import, Line, [Arg]}, S) ->
  translate_macro({import, Line, [Arg, []]}, S);

translate_macro({import, Line, [_,_] = Args}, S) ->
  record(import, S),
  Module = S#elixir_scope.module,
  case (Module == {0,nil}) or (S#elixir_scope.function /= []) of
    true  ->
      syntax_error(Line, S#elixir_scope.filename, "cannot invoke import outside module. invalid scope for: ", "import");
    false ->
      NewArgs = [Line, S#elixir_scope.filename, element(2, Module)|Args],
      translate_each({{'.', Line, [elixir_import, handle_import]}, Line, NewArgs}, S)
  end;

%% Loop and recur

translate_macro({loop, Line, RawArgs}, S) when is_list(RawArgs) ->
  record(loop, S),
  case lists:split(length(RawArgs) - 1, RawArgs) of
    { Args, [KV] } when is_list(KV) ->
      %% Generate a variable that will store the function
      { FunVar, VS }  = elixir_tree_helpers:build_ex_var(Line, S),

      %% Add this new variable to all match clauses
      [{match, KVBlock}] = elixir_kv_block:normalize(orddict:erase(do, KV)),
      Values = [{ [FunVar|Conds], Expr } || { Conds, Expr } <- element(3, KVBlock)],
      NewKVBlock = setelement(3, KVBlock, Values),

      %% Generate a function with the match blocks
      Function = { fn, Line, [[{match,NewKVBlock}]] },

      %% Finally, assign the function to a variable and
      %% invoke it passing the function itself as first arg
      Block = { block, Line, [
        { '=', Line, [FunVar, Function] },
        { { '.', Line, [FunVar] }, Line, [FunVar|Args] }
      ] },

      { TBlock, TS } = translate_each(Block, VS#elixir_scope{recur=element(1,FunVar)}),
      { TBlock, TS#elixir_scope{recur=[]} };
    _ ->
      syntax_error(Line, S#elixir_scope.filename, "invalid args for: ", "loop")
  end;

translate_macro({recur, Line, Args}, S) when is_list(Args) ->
  record(recur, S),
  case S#elixir_scope.recur of
    [] ->
      syntax_error(Line, S#elixir_scope.filename, "cannot invoke recur outside of a loop. invalid scope for: ", "recur");
    Recur ->
      ExVar = { Recur, Line, false },
      Call = { { '.', Line, [ExVar] }, Line, [ExVar|Args] },
      translate_each(Call, S)
  end;

%% Comprehensions

translate_macro({ for, Line, Args }, S) when is_list(Args) ->
  translate_comprehension(Line, lc, Args, S);

translate_macro({ bitfor, Line, Args }, S) when is_list(Args) ->
  translate_comprehension(Line, bc, Args, S);

%% Apply - Optimize apply by checking what doesn't need to be dispatched dynamically

translate_macro({apply, Line, [Left, Right, Args]}, S) when is_list(Args) ->
  record(apply, S),
  { TLeft,  SL } = translate_each(Left, S),
  { TRight, SR } = translate_each(Right, umergec(S, SL)),
  translate_apply(Line, TLeft, TRight, Args, S, SL, SR);

%% Else

translate_macro({ Atom, Line, Args }, S) ->
  Callback = fun() ->
    { TArgs, NS } = translate_args(Args, S),
    { { call, Line, { atom, Line, Atom }, TArgs }, NS }
  end,
  elixir_dispatch:dispatch_imports(Line, Atom, Args, S, Callback).

%% Helpers

translate_comprehension(Line, Kind, Args, S) ->
  case lists:split(length(Args) - 1, Args) of
    { Cases, [[{do,Expr}]] } ->
      { TCases, SC } = lists:mapfoldl(fun translate_each_comprehension/2, S, Cases),
      { TExpr, SE } = translate_each(Expr, SC),
      { { Kind, Line, TExpr, TCases }, umergec(S, SE) };
    _ ->
      syntax_error(Line, S#elixir_scope.filename, "no block given for comprehension: ", atom_to_list(Kind))
  end.

translate_each_comprehension({ in, Line, [{'<<>>', _, _} = Left, Right] }, S) ->
  translate_each_comprehension({ inbin, Line, [Left, Right]}, S);

translate_each_comprehension({inbin, Line, [Left, Right]}, S) ->
  { TRight, SR } = translate_each(Right, S),
  { TLeft, SL  } = elixir_clauses:assigns(fun elixir_translator:translate_each/2, Left, SR),
  { { b_generate, Line, TLeft, TRight }, SL };

translate_each_comprehension({Kind, Line, [Left, Right]}, S) when Kind == in; Kind == inlist ->
  { TRight, SR } = translate_each(Right, S),
  { TLeft, SL  } = elixir_clauses:assigns(fun elixir_translator:translate_each/2, Left, SR),
  { { generate, Line, TLeft, TRight }, SL };

translate_each_comprehension(X, S) ->
  { TX, TS } = translate_each(X, S),
  Line = case X of
    { _, L, _ } -> L;
    _ -> 0
  end,
  { elixir_tree_helpers:convert_to_boolean(Line, TX, true), TS }.

% Unpack a list of expressions from a block.
% Return an empty list in case it is an empty expression on after.
unpack_try(_, [{ block, _, Exprs }]) -> Exprs;
unpack_try('after', [{ nil, _ }])    -> [];
unpack_try(_, Exprs)                 -> Exprs.

% We need to record macros invoked so we raise users
% a nice error in case they define a local that overrides
% an invoked macro instead of silently failing.
%
% Some macros are not recorded because they will always
% raise an error to users if they define something similar
% regardless if they invoked it or not.
record(Atom, S) ->
  elixir_import:record(internal, { Atom, nil }, in_erlang_macros, S).

convert_op('!==') -> '=/=';
convert_op('===') -> '=:=';
convert_op('!=')  ->  '/=';
convert_op('<=')  ->  '=<';
convert_op('<-')  ->  '!';
convert_op(Else)  ->  Else.