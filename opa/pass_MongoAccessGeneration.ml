(* shorthands *)
module Q = QmlAst
module C = QmlAstCons.TypedExpr

module Api = Opacapi

module DbAst = QmlAst.Db
module DbSchema = QmlDbGen.Schema
module List = BaseList

type db_access = {
  engines : Ident.t StringMap.t
}

let label = Annot.nolabel "MongoAccessGeneration"


module Generator = struct

  let ty_is_const gamma ty =
    match QmlTypesUtils.Inspect.follow_alias_noopt_private gamma ty with
    | Q.TypeConst _ -> true
    | _ -> false

  let ty_database = Q.TypeVar (QmlTypeVars.TypeVar.next ())

  let open_database gamma annotmap name host port =
    let (annotmap, name) = C.string annotmap name in
    let (annotmap, host) = C.string annotmap host in
    let (annotmap, port) = C.int annotmap port in
    let (annotmap, open_) = OpaMapToIdent.typed_val ~label Opacapi.Db.open_ annotmap gamma in
    let (annotmap, open_) = C.apply gamma annotmap open_ [name; host; port] in
    (annotmap, open_)

  let node_to_dbexpr _gamma annotmap node =
    C.ident annotmap node.DbSchema.database.DbSchema.ident ty_database

  let add_to_document gamma annotmap name expr
      ?(ty=QmlAnnotMap.find_ty (Annot.annot (QmlAst.Label.expr expr)) annotmap)
      doc =
    let (annotmap, add_to_document) =
      OpaMapToIdent.typed_val ~label ~ty:[ty] Api.DbSet.add_to_document annotmap gamma
    in
    let (annotmap, name) = C.string annotmap name in
    let (annotmap, opaty) =
      Pass_ExplicitInstantiation.ty_to_opaty
        ~memoize:false
        ~val_:OpaMapToIdent.val_ ~side:`server
        annotmap gamma ty in
    C.apply gamma annotmap add_to_document [doc; name; expr; opaty]

  let expr_of_strpath gamma annotmap strpath =
    let annotmap, path = List.fold_left
      (fun (annotmap, acc) key ->
         let annotmap, e = C.string annotmap key in
         annotmap, e::acc
      ) (annotmap, []) strpath
    in
    C.rev_list (annotmap, gamma) path

  let rec prepare_query query =
    match query with
    | DbAst.QEq  _
    | DbAst.QGt  _
    | DbAst.QLt  _
    | DbAst.QGte _
    | DbAst.QLte _
    | DbAst.QNe  _
    | DbAst.QMod _
    | DbAst.QIn  _ -> query
    | DbAst.QFlds flds -> DbAst.QFlds (List.map (fun (f, q) -> (f, prepare_query q)) flds)
    | DbAst.QAnd (q1, q2) -> DbAst.QAnd (prepare_query q1, prepare_query q2)
    | DbAst.QOr (q1, q2)  -> DbAst.QOr  (prepare_query q1, prepare_query q2)
    | DbAst.QNot DbAst.QEq  e -> DbAst.QNe  e
    | DbAst.QNot DbAst.QGt  e -> DbAst.QLte e
    | DbAst.QNot DbAst.QLt  e -> DbAst.QGte e
    | DbAst.QNot DbAst.QGte e -> DbAst.QLt  e
    | DbAst.QNot DbAst.QLte e -> DbAst.QGt  e
    | DbAst.QNot DbAst.QNe  e -> DbAst.QEq  e
    | DbAst.QNot (DbAst.QIn _ | DbAst.QMod _) -> query
    | DbAst.QNot (DbAst.QNot query) -> query
    | DbAst.QNot (DbAst.QFlds flds) ->
        DbAst.QFlds (List.map (fun (f, q) -> (f, prepare_query (DbAst.QNot q))) flds)
    | DbAst.QNot (DbAst.QOr (q1, q2)) ->
        DbAst.QAnd (prepare_query (DbAst.QNot q1), prepare_query (DbAst.QNot q2))
    | DbAst.QNot (DbAst.QAnd (q1, q2)) ->
        DbAst.QOr (prepare_query (DbAst.QNot q1), prepare_query (DbAst.QNot q2))

  let query_to_expr gamma annotmap query =
    let empty_query annotmap = C.list (annotmap, gamma) [] in
    match query with
    | None -> empty_query annotmap
    | Some (_todo, query) ->
        let query = prepare_query query in
        let rec aux annotmap query =
          match query with
          | DbAst.QEq e ->
              let a = Annot.annot (QmlAst.Label.expr e) in
              let ty = QmlAnnotMap.find_ty a annotmap in
              let (annotmap, opa2doc) =
                OpaMapToIdent.typed_val ~label ~ty:[ty] Api.DbSet.opa2doc annotmap gamma
              in
              let (annotmap, e) = C.shallow_copy annotmap e in
              C.apply gamma annotmap opa2doc [e]
          | DbAst.QMod _ -> assert false
          | DbAst.QGt e | DbAst.QLt e | DbAst.QGte e | DbAst.QLte e | DbAst.QNe e | DbAst.QIn e ->
              let name =
                match query with
                | DbAst.QGt _  -> "$gt"
                | DbAst.QLt _  -> "$lt"
                | DbAst.QGte _ -> "$gte"
                | DbAst.QLte _ -> "$lte"
                | DbAst.QNe _  -> "$ne"
                | DbAst.QIn _  -> "$in"
                | _ -> assert false
              in
              let annotmap, query = empty_query annotmap in
              add_to_document gamma annotmap name e query
          | DbAst.QFlds flds ->
              List.fold_left
                (fun (annotmap, acc) (fld, query) ->
                   let name = BaseFormat.sprintf "%a" QmlAst.Db.pp_field fld in
                   match query with
                   | DbAst.QEq e -> add_to_document gamma annotmap name e acc
                   | _ ->
                       let annotmap, query = aux annotmap query in
                       add_to_document gamma annotmap name query acc
                )
                (empty_query annotmap)
                flds
          | DbAst.QNot query ->
              let annotmap, query = aux annotmap query in
              let annotmap, empty = empty_query annotmap in
              add_to_document gamma annotmap "$not" query empty
          | DbAst.QAnd (q1, q2)
          | DbAst.QOr  (q1, q2) ->
              let name =
                match query with
                | DbAst.QAnd _ -> "$and"
                | DbAst.QOr  _ -> "$or"
                | _ -> assert false
              in
              let annotmap, q1 = aux annotmap q1 in
              let annotmap, q2 = aux annotmap q2 in
              let ty =
                QmlAnnotMap.find_ty (Annot.annot (QmlAst.Label.expr q1)) annotmap
              in
              let annotmap, query = C.list ~ty (annotmap, gamma) [q1; q2] in
              let annotmap, empty = empty_query annotmap in
              add_to_document gamma annotmap name query empty
        in aux annotmap query

  let update_to_expr gamma annotmap update =
    let rec collect fld (inc, set, other, annotmap) update =
      let rfld = if fld = "" then "value" else fld in
      match update with
      | DbAst.UExpr e -> (inc, (rfld, e)::set, other, annotmap)
      | DbAst.UIncr i -> ((rfld, i)::inc, set, other, annotmap)
      | DbAst.UFlds fields ->
          List.fold_left
            (fun (inc, set, other, annotmap) (f, u) ->
               let fld =
                 let dot = match fld with | "" -> "" | _ -> "." in
                 BaseFormat.sprintf "%s%s%a" fld dot QmlAst.Db.pp_field f in
               collect fld (inc, set, other, annotmap) u)
            (inc, set, other, annotmap) fields
      | DbAst.UAppend     e -> (inc, set, (rfld, "$push", e)::other, annotmap)
      | DbAst.UAppendAll  e -> (inc, set, (rfld, "$pushAll", e)::other, annotmap)
      | DbAst.UPrepend    _e -> assert false
      | DbAst.UPrependAll _e -> assert false
      | DbAst.UPop   ->
          let annotmap, e = C.int annotmap (-1) in
          (inc, set, (rfld, "$pop", e)::other, annotmap)
      | DbAst.UShift ->
          let annotmap, e = C.int annotmap 1 in
          (inc, set, (rfld, "$pop", e)::other, annotmap)
    in let (inc, set, other, annotmap) = collect "" ([], [], [], annotmap) update in
    let annotmap, uexpr = C.list (annotmap, gamma) [] in
    let annotmap, uexpr =
      match inc with
      | [] -> annotmap, uexpr
      | _ ->
          let ty = Q.TypeConst Q.TyInt in
          let rec aux ((annotmap, doc) as acc) inc =
            match inc with
            | [] -> acc
            | (field, value)::q ->
                let (annotmap, value) = C.int annotmap value in
                aux (add_to_document gamma annotmap field value ~ty doc) q
          in
          let annotmap, iexpr = aux (C.list (annotmap, gamma) []) inc in
          add_to_document gamma annotmap "$inc" iexpr uexpr
    in
    let annotmap, uexpr =
      match set with
      | [] -> annotmap, uexpr
      | ["", e] -> add_to_document gamma annotmap "value" e uexpr
      | _ ->
          let rec aux ((annotmap, doc) as acc) set =
            match set with
            | [] -> acc
            | (field, value)::q ->
                aux (add_to_document gamma annotmap field value doc) q
          in
          let annotmap, sexpr = aux (C.list (annotmap, gamma) []) set in
          add_to_document gamma annotmap "$set" sexpr uexpr
    in
    let annotmap, uexpr =
      List.fold_left
        (fun (annotmap, uexpr) (fld, name, request) ->
           let annotmap, empty = C.list (annotmap, gamma) [] in
           let annotmap, request = add_to_document gamma annotmap fld request empty in
           add_to_document gamma annotmap name request uexpr
        ) (annotmap, uexpr) other
    in annotmap, uexpr

  let dot_update gamma annotmap field update =
    match update with
    | DbAst.UExpr e ->
        let annotmap, e = C.dot gamma annotmap e field in
        Some (annotmap, DbAst.UExpr e)
    | DbAst.UFlds fields ->
        List.find_map
          (fun (fields, u) -> match fields with
           | t::q when t = field -> Some (annotmap, DbAst.UFlds [q, u])
           | _ -> None)
          fields
    | _ -> None


  let rec compose_path ~context gamma annotmap schema kind subs =
    let subkind =
      match kind with
      | DbAst.Update _
      | DbAst.Ref -> DbAst.Ref
      | _ -> DbAst.Valpath
    in
    let annotmap, elements =
      C.list_map
        (fun annotmap (field, sub) ->
           let (annotmap, path) = string_path ~context gamma annotmap schema (subkind, sub) in
           let (annotmap, field) = C.string annotmap field in
           C.opa_tuple_2 (annotmap, gamma) (field, path)
        ) (annotmap, gamma) subs
    in
    let builder, pathty =
      match subkind with
      | DbAst.Ref -> Api.Db.build_rpath_compose, Api.Types.ref_path
      | DbAst.Valpath -> Api.Db.build_vpath_compose, Api.Types.val_path
      | _ -> assert false
    in
    (annotmap, [elements], builder, pathty)

    and string_path ~context gamma annotmap schema (kind, strpath) =
    (* vv FIXME !?!?! vv *)
    let node =
      let strpath = List.map (fun k -> DbAst.FldKey k) strpath in
      DbSchema.get_node schema strpath in
    (* ^^ FIXME !?!?! ^^ *)

    match kind with
    | DbAst.Update u ->
        begin match node.DbSchema.kind with
        | DbSchema.Plain ->
            let annotmap, path = expr_of_strpath gamma annotmap strpath in
            let annotmap, uexpr = update_to_expr gamma annotmap u in
            let annotmap, database = node_to_dbexpr gamma annotmap node in
            let annotmap, update =
              OpaMapToIdent.typed_val ~label Api.Db.update_path annotmap gamma in
            C.apply gamma annotmap update [database; path; uexpr]
        | DbSchema.Partial (sum, rpath, partial) ->
            if sum then QmlError.serror context "Update inside a sum path is forbidden";
            let annotmap, path = expr_of_strpath gamma annotmap rpath in
            let annotmap, uexpr = update_to_expr gamma annotmap (DbAst.UFlds [partial, u]) in
            let annotmap, database = node_to_dbexpr gamma annotmap node in
            let annotmap, update =
              OpaMapToIdent.typed_val ~label Api.Db.update_path annotmap gamma in
            C.apply gamma annotmap update [database; path; uexpr]
        | DbSchema.Compose c ->
            Format.eprintf "compose %a\n" DbSchema.pp_node node;
            (* TODO - Warning non atocmic update *)
            let annotmap, sub =
              List.fold_left_filter_map
                (fun annotmap (field, subpath) ->
                   match dot_update gamma annotmap field u with
                   | Some (annotmap, subu) ->
                       let annotmap, sube =
                         string_path ~context gamma annotmap schema (DbAst.Update subu, subpath)
                       in (annotmap, Some (Ident.next "_", sube))
                   | None -> annotmap, None
                ) annotmap c
            in
            let annotmap, unit = C.unit annotmap in
            C.letin annotmap sub unit
        | _ -> assert false
        end
    | _ ->
        (* All other kind access are factorized bellow *)
        let annotmap, path = expr_of_strpath gamma annotmap strpath in
        let (annotmap, args, builder, pathty) =
          match node.DbSchema.kind with
          | DbSchema.Compose subs ->
              compose_path ~context gamma annotmap schema kind subs

          | DbSchema.Partial (sum, rpath, partial) ->
              let annotmap, partial = C.list_map
            (fun annotmap fragment -> C.string annotmap fragment)
            (annotmap, gamma) partial
          in let annotmap, rpath = C.list_map
            (fun annotmap fragment -> C.string annotmap fragment)
            (annotmap, gamma) rpath
          in begin match kind with
          | DbAst.Ref ->
              if sum then QmlError.serror context "Update inside a sum path is forbidden";
              annotmap, [rpath; partial], Api.Db.build_rpath_sub, Api.Types.ref_path
          | _ ->
              annotmap, [rpath; partial], Api.Db.build_vpath_sub, Api.Types.val_path
              end
          | DbSchema.Plain ->
              (match kind with
               | DbAst.Update _
               | DbAst.Ref -> (annotmap, [], Api.Db.build_rpath, Api.Types.ref_path)
               | _ -> (annotmap, [], Api.Db.build_vpath, Api.Types.val_path))
          | _ -> assert false
        in
        let dataty = node.DbSchema.ty in
        let (annotmap, build) =
          OpaMapToIdent.typed_val ~label ~ty:[dataty] builder annotmap gamma in
        let (annotmap, database) = node_to_dbexpr gamma annotmap node in
        let ty = OpaMapToIdent.specialized_typ ~ty:[dataty] pathty gamma in
        let (annotmap, default) = node.DbSchema.default annotmap in
        let (annotmap, path) = C.apply ~ty gamma annotmap build
          ([database; path; default] @ args) in
        let again =
          match kind with
          | DbAst.Default -> Some Api.Db.read
          | DbAst.Option -> Some Api.Db.option
          | _ -> None
        in
        let (annotmap, path) =
          match again with
          | None -> (annotmap, path)
          | Some again ->
              let (annotmap, again) =
                OpaMapToIdent.typed_val ~label ~ty:[QmlAstCons.Type.next_var (); dataty]
                  again annotmap gamma in
              C.apply gamma annotmap again [path]
        in annotmap, path
          (* let *)

    (* assert false *)

  let dbset_path ~context gamma annotmap (kind, path) setkind node query0 =
    (* Restriction, we can't erase a database set *)
    let () =
      match kind, query0 with
      | DbAst.Update _, None ->
          QmlError.error context "Update on a full collection is forbidden"
      | _ -> ()
    in
    let ty = node.DbSchema.ty in
    let uniq, nb, query =
      match query0 with
      | None -> false, 0, None
      | Some ((uniq, query) as x) ->
          uniq,
          (if uniq then 1 else 5000),
          Some (
            match setkind with
            | DbSchema.Map _ -> uniq, DbAst.QFlds [(["_id"], query)]
            | _ -> x)
    in
    (* DbSet.build *)
    let (annotmap, build, query, args) =
      (match kind with
       | DbAst.Default
       | DbAst.Option ->
           let dataty =
             match setkind with
             | DbSchema.DbSet ty -> ty
             | DbSchema.Map _ -> QmlAstCons.Type.next_var () (* Dummy type variable, should never use*)
           in
           let (annotmap, build) =
             OpaMapToIdent.typed_val ~label ~ty:[dataty] Api.DbSet.build annotmap gamma in
           (* query *)
           let (annotmap, query) = query_to_expr gamma annotmap query in
           let (annotmap, nb) = C.int annotmap nb in
           let (annotmap, default) = node.DbSchema.default annotmap in
           (annotmap, build, query, [default; nb])
       | DbAst.Update u ->
           let (annotmap, query) = query_to_expr gamma annotmap query in
           let (annotmap, update) =
             let u =
               (* Hack : When map value is simple, adding the "value" field *)
               match setkind with
               | DbSchema.Map (_, tyval) when ty_is_const gamma tyval -> DbAst.UFlds [["value"], u]
               | _ -> u
             in
             update_to_expr gamma annotmap u
           in
           let (annotmap, build) =
             OpaMapToIdent.typed_val ~label Api.DbSet.update annotmap gamma
           in
           (annotmap, build, query, [update])
       | _ -> assert false)
    in
    (* database *)
    let (annotmap, database) = node_to_dbexpr gamma annotmap node in
    (* path : list(string) *)
    let (annotmap, path) =
      let (annotmap, path) = List.fold_left
        (fun (annotmap, acc) key ->
           let annotmap, e = C.string annotmap key in
           annotmap, e::acc
        ) (annotmap, []) path
      in
      C.rev_list (annotmap, gamma) path in
    (* dbset = DbSet.build(database, path, query, ...) *)
    let (annotmap, set) =
      C.apply ~ty gamma annotmap build
        ([database; path; query] @ args) in
    (* Final convert *)
    let (annotmap, set) =
      match kind with
      | DbAst.Default | DbAst.Option ->
          (match setkind, uniq with
           | DbSchema.DbSet _, false -> (annotmap, set)
           | DbSchema.Map (keyty, dataty), false ->
               let (annotmap, to_map) =
                 OpaMapToIdent.typed_val ~label
                   ~ty:[QmlAstCons.Type.next_var (); keyty; dataty]
                   Api.DbSet.to_map annotmap gamma in
               let (annotmap, map) =
                 C.apply ~ty gamma annotmap to_map [set] in
               begin match kind with
               | DbAst.Option ->
                   (* TODO - Actually we consider map already exists *)
                   C.some annotmap gamma map
               | _ -> (annotmap, map)
               end
           | DbSchema.DbSet dataty, true ->
               let (annotmap, set_to_uniq) =
                 let set_to_uniq = match kind with
                 | DbAst.Default -> Api.DbSet.set_to_uniq_def
                 | DbAst.Option -> Api.DbSet.set_to_uniq
                 | _ -> assert false
                 in
                 OpaMapToIdent.typed_val ~label ~ty:[dataty] set_to_uniq annotmap gamma in
               C.apply ~ty gamma annotmap set_to_uniq [set]
           | DbSchema.Map (_keyty, dataty), true ->
               let (annotmap, map_to_uniq) =
                 let map_to_uniq = match kind with
                 | DbAst.Default -> Api.DbSet.map_to_uniq_def
                 | DbAst.Option -> Api.DbSet.map_to_uniq
                 | _ -> assert false
                 in
                 OpaMapToIdent.typed_val ~label ~ty:[QmlAstCons.Type.next_var (); dataty]
                   map_to_uniq annotmap gamma in
               C.apply ~ty gamma annotmap map_to_uniq [set])
      | _ -> (annotmap, set)
    in
    (annotmap, set)


  let path ~context gamma annotmap schema (kind, dbpath) =
    (* Format.eprintf "Path %a" QmlPrint.pp#path (dbpath, kind); *)
    let node = DbSchema.get_node schema dbpath in
    match node.DbSchema.kind with
    | DbSchema.SetAccess (setkind, path, query) ->
        dbset_path ~context gamma annotmap (kind, path) setkind node query
    | _ ->
        let strpath = List.map
          (function
             | DbAst.FldKey k -> k
             | _ -> assert false
          ) dbpath in
        string_path ~context gamma annotmap schema (kind, strpath)

  let indexes gamma annotmap _schema node rpath lidx =
    let (annotmap, database) =
      node_to_dbexpr gamma annotmap node in
    let (annotmap, build) =
      OpaMapToIdent.typed_val ~label Api.DbSet.indexes annotmap gamma in
    let (annotmap, path) =
      C.rev_list_map
        (fun annotmap fragment -> C.string annotmap fragment)
        (annotmap, gamma) rpath
    in
    let (annotmap, lidx) =
      List.fold_left_map
        (fun annotmap idx ->
           C.list_map
             (fun annotmap fragment -> C.string annotmap fragment)
             (annotmap, gamma) idx)
        annotmap lidx
    in
    let (annotmap, lidx) = C.list (annotmap, gamma) lidx
    in C.apply gamma annotmap build [database; path; lidx]



end

let init_database gamma annotmap schema =
  List.fold_left
    (fun (annotmap, newvals) (ident, name, opts) ->
       match opts with
       | [`engine (`client (Some host, Some port))] ->
           let (annotmap, open_) = Generator.open_database gamma annotmap name host port in
           (annotmap, (Q.NewVal (label, [ident, open_]))::newvals)
       | _ ->
           let (annotmap, open_) = Generator.open_database gamma annotmap name "localhost" 27017 in
           (annotmap, (Q.NewVal (label, [ident, open_]))::newvals)
    )
    (annotmap, []) (QmlDbGen.Schema.get_db_declaration schema)

let clean_code gamma annotmap schema code =
  List.fold_left_filter_map
    (fun annotmap -> function
       | Q.Database _ -> annotmap, None
       | Q.NewDbValue (_label, DbAst.Db_TypeDecl (p, _ty)) ->
           let fake_path =
             match p with
             | DbAst.Decl_fld k::_ -> [DbAst.FldKey k]
             | _ -> []
           in
           begin match p with
           | (DbAst.Decl_fld _)::p ->
               let rec aux rpath p =
                 match p with
                 | (DbAst.Decl_set lidx)::[] ->
                     let (annotmap, init) =
                       let fake_node = DbSchema.get_node schema fake_path in
                       Generator.indexes gamma annotmap schema fake_node rpath lidx
                     in
                     let id = Ident.next "_index_setup" in
                     annotmap, Some (Q.NewVal (label, [id, init]))
                 | (DbAst.Decl_set _lidx)::_ -> assert false
                 | (DbAst.Decl_fld str)::p -> aux (str::rpath) p
                 | [] -> annotmap, None
                 | _ -> assert false
               in aux [] p
           | _ -> annotmap, None
           end
       | Q.NewDbValue _ -> annotmap, None
       | elt -> annotmap, Some elt)
    annotmap code

let process_path gamma annotmap schema code =
  let fmap tra annotmap = function
    | Q.Path (_label, path, kind) as expr ->
        let context = QmlError.Context.annoted_expr annotmap expr in
        let annotmap, result = Generator.path ~context gamma annotmap schema (kind, path) in
        tra annotmap result
    | e -> tra annotmap e
  in
  QmlAstWalk.CodeExpr.fold_map
    (fun annotmap expr ->
       let annotmap, expr = QmlAstWalk.Expr.traverse_foldmap fmap annotmap expr in
       fmap (fun a e -> a,e) annotmap expr)
    annotmap code


let process_code ~stdlib_gamma gamma annotmap schema code =
  match ObjectFiles.compilation_mode () with
  | `init -> (annotmap, code)
  | _ ->
      let gamma = QmlTypes.Env.unsafe_append stdlib_gamma gamma in
      let (annotmap, code) = clean_code gamma annotmap schema code in
      let (annotmap, code) =
        let (annotmap, vals) = init_database stdlib_gamma annotmap schema in
        (annotmap, vals@code)
      in
      let (annotmap, code) = process_path gamma annotmap schema code in
      (annotmap, code)

