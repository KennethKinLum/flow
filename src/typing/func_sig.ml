(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
module Flow = Flow_js
open Reason
open Type
open Hint_api
open TypeUtil
include Func_sig_intf

class func_scope_visitor cx ~return_t ~yield_t ~next_t kind exhaust =
  object (this)
    inherit
      [ALoc.t, ALoc.t * Type.t, ALoc.t, ALoc.t * Type.t] Flow_polymorphic_ast_mapper.mapper as super

    method on_type_annot x = x

    method on_loc_annot x = x

    method! function_ fn = fn

    method! switch ({ Ast.Statement.Switch.exhaustive_out = (loc, t); _ } as switch) =
      Base.Option.iter exhaust ~f:(fun (exhaustive_t, exhaust_locs, _) ->
          if Base.List.mem ~equal:ALoc.equal exhaust_locs loc then Flow.flow_t cx (t, exhaustive_t)
      );
      super#switch switch

    method! yield ({ Ast.Expression.Yield.result_out = (_, t); argument; delegate; _ } as yield) =
      let use_op =
        if delegate then
          unknown_use
        else
          Op
            (GeneratorYield
               {
                 value =
                   Base.Option.value_map argument ~default:(reason_of_t t) ~f:(fun expr ->
                       mk_expression_reason (Typed_ast_utils.untyped_ast_mapper#expression expr)
                   );
               }
            )
      in
      Flow.flow cx (t, UseT (use_op, yield_t));
      super#yield yield

    (* Override statement so that we have the loc for return *)
    method! statement (loc, stmt) =
      begin
        match stmt with
        | Ast.Statement.Return return -> this#custom_return loc return
        | _ -> ()
      end;
      super#statement (loc, stmt)

    method custom_return loc { Ast.Statement.Return.return_out = (_, t); argument; _ } =
      let open Func_class_sig_types.Func in
      let t =
        match kind with
        | Async ->
          (* Convert the return expression's type T to Promise<T>. If the
             * expression type is itself a Promise<T>, ensure we still return
             * a Promise<T> via Promise.resolve. *)
          let reason = mk_reason (RCustom "async return") loc in
          let t' =
            Flow.get_builtin_typeapp
              cx
              reason
              (OrdinaryName "Promise")
              [
                Tvar.mk_where cx reason (fun tvar ->
                    let funt = Flow.get_builtin cx (OrdinaryName "$await") reason in
                    let callt = mk_functioncalltype reason None [Arg t] (open_tvar tvar) in
                    let reason = repos_reason (aloc_of_reason (reason_of_t t)) reason in
                    Flow.flow cx (funt, CallT (unknown_use, reason, callt))
                );
              ]
          in
          Flow.reposition cx ~desc:(desc_of_t t) loc t'
        | Generator _ ->
          (* Convert the return expression's type R to Generator<Y,R,N>, where
           * Y and R are internals, installed earlier. *)
          let reason = mk_reason (RCustom "generator return") loc in
          let t' =
            Flow.get_builtin_typeapp
              cx
              reason
              (OrdinaryName "Generator")
              [yield_t; Tvar.mk_where cx reason (fun tvar -> Flow.flow_t cx (t, tvar)); next_t]
          in
          Flow.reposition cx ~desc:(desc_of_t t) loc t'
        | AsyncGenerator _ ->
          let reason = mk_reason (RCustom "async generator return") loc in
          let t' =
            Flow.get_builtin_typeapp
              cx
              reason
              (OrdinaryName "AsyncGenerator")
              [yield_t; Tvar.mk_where cx reason (fun tvar -> Flow.flow_t cx (t, tvar)); next_t]
          in
          Flow.reposition cx ~desc:(desc_of_t t) loc t'
        | _ -> t
      in
      let use_op =
        Op
          (FunReturnStatement
             {
               value =
                 Base.Option.value_map argument ~default:(reason_of_t t) ~f:(fun expr ->
                     mk_expression_reason (Typed_ast_utils.untyped_ast_mapper#expression expr)
                 );
             }
          )
      in
      Flow.flow cx (t, UseT (use_op, return_t))
  end

module Make
    (Env : Env_sig.S)
    (Abnormal : Abnormal_sig.S with module Env := Env)
    (Statement : Statement_sig.S with module Env := Env)
    (CT : Func_class_sig_types.Config.S)
    (C : Func_params.Config with module Types := CT)
    (F : Func_params.S with module Config_types := CT and module Config := C)
    (T : Func_class_sig_types.Func.S with module Config := CT and module Param := F.Types) :
  S with module Config_types := CT and module Config := C and module Param := F and module Types = T =
struct
  module Toplevels = Toplevels.Make (Env) (Abnormal)
  module Types = T
  open Func_class_sig_types.Func

  let this_param = F.this

  let default_constructor reason =
    {
      T.reason;
      kind = Ctor;
      tparams = None;
      tparams_map = Subst_name.Map.empty;
      fparams = F.empty (fun _ _ _ -> None);
      body = None;
      return_t = Annotated (VoidT.why reason |> with_trust bogus_trust);
    }

  let field_initializer tparams_map reason expr return_annot_or_inferred =
    {
      T.reason;
      kind = FieldInit expr;
      tparams = None;
      tparams_map;
      fparams = F.empty (fun _ _ _ -> None);
      body = None;
      return_t = return_annot_or_inferred;
    }

  let functiontype cx this_default { T.reason; kind; tparams; fparams; return_t; _ } =
    let make_trust = Context.trust_constructor cx in
    let static =
      let proto = FunProtoT reason in
      Obj_type.mk_unsealed cx reason ~proto
    in
    let funtype =
      {
        Type.this_t = (F.this fparams |> Base.Option.value ~default:this_default, This_Function);
        params = F.value fparams;
        rest_param = F.rest fparams;
        return_t = TypeUtil.type_t_of_annotated_or_inferred return_t;
        is_predicate = kind = Predicate;
        def_reason = reason;
      }
    in
    let t = DefT (reason, make_trust (), FunT (static, funtype)) in
    poly_type_of_tparams (Type.Poly.generate_id ()) tparams t

  let methodtype this_default { T.reason; tparams; fparams; return_t; _ } =
    let params = F.value fparams in
    let (params_names, params_tlist) = List.split params in
    let rest_param = F.rest fparams in
    let def_reason = reason in
    let param_this_t = F.this fparams |> Base.Option.value ~default:this_default in
    let t =
      DefT
        ( reason,
          bogus_trust (),
          FunT
            ( dummy_static reason,
              mk_boundfunctiontype
                ~this:param_this_t
                ~subtyping:(This_Method { unbound = false })
                params_tlist
                ~rest_param
                ~def_reason
                ~params_names
                (TypeUtil.type_t_of_annotated_or_inferred return_t)
            )
        )
    in
    poly_type_of_tparams (Type.Poly.generate_id ()) tparams t

  let gettertype ({ T.return_t; _ } : T.t) = TypeUtil.type_t_of_annotated_or_inferred return_t

  let settertype { T.fparams; _ } =
    match F.value fparams with
    | [(_, param_t)] -> param_t
    | _ -> failwith "Setter property with unexpected type"

  let toplevels cx default_this super x =
    let { T.reason = reason_fn; kind; tparams_map; fparams; body; return_t; _ } = x in
    let body_loc =
      let open Ast.Function in
      match body with
      | Some (BodyBlock (loc, _)) -> loc
      | Some (BodyExpression (loc, _)) -> loc
      | None -> ALoc.none
    in
    let reason = mk_reason RFunctionBody body_loc in
    let env = Env.peek_env () in
    let new_env = Env.clone_env env in
    Env.update_env body_loc new_env;
    Env.havoc_all ();

    (* create and prepopulate function scope *)
    let function_scope =
      let var_scope_kind =
        match kind with
        | Ordinary
        | FieldInit _ ->
          Scope.Ordinary
        | Predicate -> Scope.Predicate
        | Async -> Scope.Async
        | Generator _ -> Scope.Generator
        | AsyncGenerator _ -> Scope.AsyncGenerator
        | Ctor -> Scope.Ctor
      in
      Scope.fresh ~var_scope_kind ()
    in
    (* push the scope early so default exprs can reference earlier params *)
    let prev_scope_kind = Env.push_var_scope cx function_scope in

    let this_t =
      if Env.new_env then (
        match default_this with
        | Func_class_sig_types.Func.ParentScopeThis -> None
        (* This case correspond to the default constructors that do not appear in the source. *)
        | Func_class_sig_types.Func.ClassThis (None, _) -> None
        | Func_class_sig_types.Func.ClassThis (Some func_loc, default) ->
          (match this_param fparams with
          | None ->
            (* There is no `this` annotation, so we inherit this from class scope. *)
            Some default
          | Some this ->
            (* There is `this` annotation, so we shadow this from class scope. *)
            Env.bind_function_this cx this func_loc;
            Some this)
        | Func_class_sig_types.Func.FunctionThis (func_loc, default) ->
          let this = this_param fparams |> Base.Option.value ~default in
          Env.bind_function_this cx this func_loc;
          Some this
      ) else
        (* add `this` and `super` before looking at parameter bindings as when using
         * `this` in default parameter values it refers to the function scope and
         * `super` should resolve to the method's [[HomeObject]]
         *)
        let (this_t, this) =
          match default_this with
          | Func_class_sig_types.Func.ParentScopeThis -> (None, None)
          | Func_class_sig_types.Func.ClassThis (_, default)
          | Func_class_sig_types.Func.FunctionThis (_, default) ->
            let this = this_param fparams |> annotated_or_inferred_of_option ~default in
            (Some (type_t_of_annotated_or_inferred this), Some this)
        in
        Base.Option.iter this ~f:(fun t ->
            let entry =
              Scope.Entry.new_let
                ~loc:(TypeUtil.loc_of_t (TypeUtil.type_t_of_annotated_or_inferred t))
                ~state:Scope.State.Initialized
                ~provider:(TypeUtil.type_t_of_annotated_or_inferred t)
                t
            in
            Scope.add_entry (internal_name "this") entry function_scope
        );
        Base.Option.iter super ~f:(fun t ->
            let entry =
              Scope.Entry.new_let
                ~loc:(TypeUtil.loc_of_t t)
                ~state:Scope.State.Initialized
                ~provider:t
                (Inferred t)
            in
            Scope.add_entry (internal_name "super") entry function_scope
        );
        this_t
    in

    (* bind type params *)
    Subst_name.Map.iter
      (fun name t ->
        let r = reason_of_t t in
        let loc = aloc_of_reason r in
        if Subst_name.string_of_subst_name name <> "this" then
          Env.bind_type
            cx
            (Subst_name.string_of_subst_name name)
            (DefT (r, bogus_trust (), TypeT (TypeParamKind, t)))
            loc
            ~state:Scope.State.Initialized
        else
          Env.bind_this_tparam
            ~state:Scope.State.Initialized
            cx
            (DefT (r, bogus_trust (), TypeT (TypeParamKind, t)))
            loc)
      tparams_map;

    (* add param bindings *)
    let params_ast = F.eval cx fparams in

    let (yield_t, next_t) =
      match kind with
      | Generator { return_loc }
      | AsyncGenerator { return_loc } ->
        let yield_t = Tvar.mk cx (replace_desc_reason (RCustom "yield") reason) in
        let next_t =
          match return_t with
          | Annotated _ -> Tvar.mk cx (replace_desc_reason (RCustom "next") reason)
          | Inferred _ ->
            VoidT.make (replace_desc_reason RUnannotatedNext reason) |> with_trust bogus_trust
        in
        let (iterable, generator) =
          match kind with
          | Generator _ -> ("$Iterable", "Generator")
          | AsyncGenerator _ -> ("$AsyncIterable", "AsyncGenerator")
          | _ -> failwith "Bad kind"
        in
        let () =
          let t =
            Flow.get_builtin_typeapp
              cx
              reason
              (OrdinaryName iterable)
              [yield_t; Tvar.mk cx reason; Tvar.mk cx reason]
          in
          let t =
            Flow.reposition
              cx
              ~desc:(desc_of_t t)
              (type_t_of_annotated_or_inferred return_t |> reason_of_t |> aloc_of_reason)
              t
          in
          Flow.flow_t cx (type_t_of_annotated_or_inferred return_t, t)
        in
        let () =
          let t =
            Flow.get_builtin_typeapp
              cx
              reason
              (OrdinaryName generator)
              [yield_t; Tvar.mk cx reason; next_t]
          in
          let t =
            Flow.reposition
              cx
              ~desc:(desc_of_t t)
              (type_t_of_annotated_or_inferred return_t |> reason_of_t |> aloc_of_reason)
              t
          in
          Flow.flow_t cx (t, type_t_of_annotated_or_inferred return_t)
        in
        Env.record_expression_type_if_needed cx Env_api.OrdinaryNameLoc return_loc next_t;
        (yield_t, next_t)
      | _ ->
        ( DefT
            ( replace_desc_reason (RCustom "no yield") reason,
              bogus_trust (),
              MixedT Mixed_everything
            ),
          DefT
            (replace_desc_reason (RCustom "no next") reason, bogus_trust (), MixedT Mixed_everything)
        )
    in
    let (yield, next, return) =
      Scope.(
        let new_entry t =
          Entry.(
            let loc = loc_of_t (TypeUtil.type_t_of_annotated_or_inferred t) in
            let state = State.Initialized in
            new_const ~loc ~state t
          )
        in
        (new_entry (Inferred yield_t), new_entry (Inferred next_t), new_entry return_t)
      )
    in
    Scope.add_entry (internal_name "yield") yield function_scope;
    Scope.add_entry (internal_name "next") next function_scope;
    Scope.add_entry (internal_name "return") return function_scope;

    let maybe_exhaustively_checked_t =
      Tvar.mk cx (replace_desc_reason (RCustom "maybe_exhaustively_checked") reason)
    in
    let maybe_exhaustively_checked =
      Scope.Entry.new_let
        ~loc:(loc_of_t maybe_exhaustively_checked_t)
        ~state:Scope.State.Declared
        (Inferred maybe_exhaustively_checked_t)
        ~provider:maybe_exhaustively_checked_t
    in
    Scope.add_entry
      (internal_name "maybe_exhaustively_checked")
      maybe_exhaustively_checked
      function_scope;

    let (statements, reconstruct_body) =
      let open Ast.Statement in
      match body with
      | None -> ([], Fun.const None)
      | Some (Ast.Function.BodyBlock (loc, { Block.body; comments })) ->
        (body, (fun body -> Some (Ast.Function.BodyBlock (loc, { Block.body; comments }))))
      | Some (Ast.Function.BodyExpression expr) ->
        ( [
            ( fst expr,
              Return { Return.argument = Some expr; comments = None; return_out = fst expr }
            );
          ],
          (function
          | [(_, Return { Return.argument = Some expr; comments = _; return_out = _ })]
          | [(_, Expression { Expression.expression = expr; _ })] ->
            Some (Ast.Function.BodyExpression expr)
          | _ -> failwith "expected return body")
        )
    in
    (* NOTE: Predicate functions can currently only be of the form:
       function f(...) { return <exp>; }
    *)
    Ast.Statement.(
      match kind with
      | Predicate ->
        begin
          match statements with
          | [(_, Return { Return.argument = Some _; comments = _; return_out = _ })] -> ()
          | _ ->
            let loc = aloc_of_reason reason in
            Flow_js.add_output cx Error_message.(EUnsupportedSyntax (loc, PredicateInvalidBody))
        end
      | _ -> ()
    );

    let (return_t, return_hint) =
      match (return_t, kind) with
      | (Inferred t, _) -> (t, Hint_None)
      | (Annotated t, (Async | Generator _ | AsyncGenerator _)) ->
        (t, Hint_t (MixedT.why (reason_of_t t) (bogus_trust ()))) (* T122105974 *)
      | (Annotated t, _) -> (t, Hint_t t)
    in

    let ({ Loc_env.return_hint = prev_return_hint; _ } as loc_env) = Context.environment cx in
    Context.set_environment cx { loc_env with Loc_env.return_hint };

    (* decl/type visit pre-pass *)
    Statement.toplevel_decls cx statements;

    (* statement visit pass *)
    let (statements_ast, statements_abnormal) =
      Abnormal.catch_stmts_control_flow_exception (fun () ->
          Toplevels.toplevels Statement.statement cx statements
      )
    in

    let loc_env = Context.environment cx in
    Context.set_environment cx { loc_env with Loc_env.return_hint = prev_return_hint };

    let maybe_void =
      Abnormal.(
        match statements_abnormal with
        | Some Return -> false
        | Some Throw -> false (* NOTE *)
        | Some (Break _)
        | Some (Continue _) ->
          failwith "Illegal toplevel abnormal directive"
        | None -> true
      )
    in
    let body_ast = reconstruct_body statements_ast in
    (* build return type for void funcs *)
    let (init_ast, exhaust) =
      if maybe_void then
        let loc = loc_of_t return_t in
        (* Some branches add an ImplicitTypeParam frame to force our flow_use_op
         * algorithm to pick use_ops outside the provided loc. *)
        let (use_op, void_t, init_ast) =
          match kind with
          | Ordinary
          | Ctor ->
            let t = VoidT.at loc |> with_trust bogus_trust in
            let use_op = Op (FunImplicitReturn { fn = reason_fn; upper = reason_of_t return_t }) in
            (use_op, t, None)
          | Async ->
            let reason = mk_annot_reason (RType (OrdinaryName "Promise")) loc in
            let void_t = VoidT.at loc |> with_trust bogus_trust in
            let t = Flow.get_builtin_typeapp cx reason (OrdinaryName "Promise") [void_t] in
            let use_op = Op (FunImplicitReturn { fn = reason_fn; upper = reason_of_t return_t }) in
            let use_op = Frame (ImplicitTypeParam, use_op) in
            (use_op, t, None)
          | Generator _ ->
            let reason = mk_annot_reason (RType (OrdinaryName "Generator")) loc in
            let void_t = VoidT.at loc |> with_trust bogus_trust in
            let t =
              Flow.get_builtin_typeapp
                cx
                reason
                (OrdinaryName "Generator")
                [yield_t; void_t; next_t]
            in
            let use_op = Op (FunImplicitReturn { fn = reason_fn; upper = reason_of_t return_t }) in
            let use_op = Frame (ImplicitTypeParam, use_op) in
            (use_op, t, None)
          | AsyncGenerator _ ->
            let reason = mk_annot_reason (RType (OrdinaryName "AsyncGenerator")) loc in
            let void_t = VoidT.at loc |> with_trust bogus_trust in
            let t =
              Flow.get_builtin_typeapp
                cx
                reason
                (OrdinaryName "AsyncGenerator")
                [yield_t; void_t; next_t]
            in
            let use_op = Op (FunImplicitReturn { fn = reason_fn; upper = reason_of_t return_t }) in
            let use_op = Frame (ImplicitTypeParam, use_op) in
            (use_op, t, None)
          | FieldInit e ->
            let (((_, t), _) as ast) = Statement.expression ?cond:None cx ~hint:return_hint e in
            let body = mk_expression_reason e in
            let use_op = Op (InitField { op = reason_fn; body }) in
            (use_op, t, Some ast)
          | Predicate ->
            let loc = aloc_of_reason reason in
            Flow_js.add_output cx Error_message.(EUnsupportedSyntax (loc, PredicateVoidReturn));
            let t = VoidT.at loc |> with_trust bogus_trust in
            let use_op = Op (FunImplicitReturn { fn = reason_fn; upper = reason_of_t return_t }) in
            (use_op, t, None)
        in

        let exhaust =
          if Env.new_env then
            match body with
            | None ->
              Flow.flow cx (void_t, UseT (use_op, return_t));
              None
            | Some _ ->
              let (exhaustive, undeclared) = Context.exhaustive_check cx body_loc in
              Some
                ( Tvar.mk_where
                    cx
                    (replace_desc_reason (RCustom "maybe_exhaustively_checked") reason_fn)
                    (fun t ->
                      if undeclared then Flow.flow_t cx (VoidT.at body_loc (bogus_trust ()), t)
                  ),
                  exhaustive,
                  FunImplicitVoidReturnT
                    { use_op; reason = reason_of_t return_t; return = return_t; void_t }
                )
          else
            Some
              ( Env.get_internal_var cx "maybe_exhaustively_checked" loc,
                [],
                FunImplicitVoidReturnT
                  { use_op; reason = reason_of_t return_t; return = return_t; void_t }
              )
        in
        (init_ast, exhaust)
      else
        (None, None)
    in

    let (_ : _ list) =
      (new func_scope_visitor cx ~return_t ~yield_t ~next_t kind exhaust)#statement_list
        statements_ast
    in

    Base.Option.iter exhaust ~f:(fun (maybe_exhaustively_checked, _, implicit_return) ->
        Flow.flow cx (maybe_exhaustively_checked, implicit_return)
    );

    Env.pop_var_scope cx prev_scope_kind;

    Env.update_env body_loc env;

    (* return a tuple of (function body AST option, field initializer AST option).
       - the function body option is Some _ if the Param sig's body was Some, and
         None if the Param sig's body was None.
       - the field initializer is Some expr' if the Param sig's kind was FieldInit expr,
         where expr' is the typed AST translation of expr.
    *)
    (this_t, params_ast, body_ast, init_ast)

  let to_ctor_sig f = { f with T.kind = Ctor }
end

let return_loc = function
  | { Ast.Function.return = Ast.Type.Available (_, (loc, _)); _ }
  | { Ast.Function.body = Ast.Function.BodyExpression (loc, _); _ } ->
    loc
  | { Ast.Function.body = Ast.Function.BodyBlock (loc, _); _ } ->
    loc |> ALoc.to_loc_exn |> Loc.char_before |> ALoc.of_loc
