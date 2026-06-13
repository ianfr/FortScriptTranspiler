open Ast
open Codegen_state
open Codegen_types
open Codegen_expr

(* CartesianMesh statement codegen helpers. *)

(* Resolve a mesh argument to its TGeneric type-parameter struct fields.
   Expects the mesh expression to be a bare Var whose type is
   TGeneric("CartesianMesh", [TStruct field_set]). Returns (mono_name, fields). *)
let resolve_cartesian_template mesh_e =
  let mesh_var = match mesh_e with
    | Var n -> n
    | _ -> failwith "geom_cartesian_* mesh argument must be a bare variable"
  in
  let mesh_type =
    match Hashtbl.find_opt current_var_types mesh_var with
    | Some t -> t
    | None ->
      (match Hashtbl.find_opt global_var_types mesh_var with
       | Some t -> t
       | None -> failwith ("Cannot resolve type of mesh variable " ^ mesh_var))
  in
  match mesh_type with
  | TGeneric (base, args) ->
    let mono = monomorphized_type_name base args in
    (match args with
     | [TStruct field_set_name] ->
       (match Hashtbl.find_opt user_structs field_set_name with
        | Some fields -> (mono, fields)
        | None -> failwith ("Unknown field-set struct: " ^ field_set_name))
     | _ -> failwith "CartesianMesh requires a single struct type parameter")
  | _ -> failwith ("Variable " ^ mesh_var ^ " is not a CartesianMesh[T]")

(* Lower geom_cartesian_uniform(mesh, dim_min, dim_max, spacing) to metadata
   assignments, cell-list geometry, uniform neighbors, and one allocation per
   FieldSet field. Field arrays use cell-id indexing. *)
let gen_geom_cartesian_uniform_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; dim_min_e; dim_max_e; spacing_e] ->
    let _mono, fields = resolve_cartesian_template mesh_e in
    let m = gen_expr mesh_e in
    let dmin = gen_expr dim_min_e in
    let dmax = gen_expr dim_max_e in
    let sp = gen_expr spacing_e in
    let buf = Buffer.create 512 in
    Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_i__, fs_j__, fs_k__, fs_c__, fs_face__, fs_sub__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_dx__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s%s%%dom_min = %s\n" ind m dmin);
    Buffer.add_string buf (Printf.sprintf "%s%s%%dom_max = %s\n" ind m dmax);
    Buffer.add_string buf (Printf.sprintf "%s%s%%spacing = %s\n" ind m sp);
    Buffer.add_string buf (Printf.sprintf "%s%s%%nx = max(1, int((%s%%dom_max(1) - %s%%dom_min(1)) / (%s)))\n" ind m m m sp);
    Buffer.add_string buf (Printf.sprintf "%s%s%%ny = max(1, int((%s%%dom_max(2) - %s%%dom_min(2)) / (%s)))\n" ind m m m sp);
    Buffer.add_string buf (Printf.sprintf "%s%s%%nz = max(1, int((%s%%dom_max(3) - %s%%dom_min(3)) / (%s)))\n" ind m m m sp);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%num_cells = %s%%nx * %s%%ny * %s%%nz\n" ind m m m m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%cell_capacity = %s%%num_cells\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%num_leaves = %s%%num_cells\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%leaf_ids(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%level(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%center(%s%%cell_capacity, 3))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%dx(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%volume(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%face_area(%s%%cell_capacity, 6))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%parent(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%children(%s%%cell_capacity, 8))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%is_leaf(%s%%cell_capacity))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  allocate(%s%%neighbor(%s%%cell_capacity, 6, 4))\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%leaf_ids = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%level = 0\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%center = 0.0d0\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%dx = 0.0d0\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%volume = 0.0d0\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%face_area = 0.0d0\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%parent = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%children = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%is_leaf = .false.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%neighbor = -1\n" ind m);
    (* Per-field allocations sized to the current cell capacity. *)
    List.iter (fun f ->
      match f.field_type with
      | TFloat ->
        Buffer.add_string buf
          (Printf.sprintf "%s  allocate(%s%%%s(%s%%cell_capacity))\n"
             ind m f.field_name m)
        ;
        Buffer.add_string buf
          (Printf.sprintf "%s  %s%%%s = 0.0d0\n" ind m f.field_name)
      | TArray (TFloat, [FixedDim (IntLit 3)]) ->
        Buffer.add_string buf
          (Printf.sprintf "%s  allocate(%s%%%s(%s%%cell_capacity, 3))\n"
             ind m f.field_name m)
        ;
        Buffer.add_string buf
          (Printf.sprintf "%s  %s%%%s = 0.0d0\n" ind m f.field_name)
      | _ -> ()
    ) fields;
    Buffer.add_string buf (Printf.sprintf "%s  fs_dx__ = %s%%spacing\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  do fs_k__ = 1, %s%%nz\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    do fs_j__ = 1, %s%%ny\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      do fs_i__ = 1, %s%%nx\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        fs_c__ = ((fs_k__ - 1) * %s%%ny + (fs_j__ - 1)) * %s%%nx + fs_i__\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%leaf_ids(fs_c__) = fs_c__ - 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%is_leaf(fs_c__) = .true.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%center(fs_c__, 1) = %s%%dom_min(1) + (dble(fs_i__) - 0.5d0) * fs_dx__\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%center(fs_c__, 2) = %s%%dom_min(2) + (dble(fs_j__) - 0.5d0) * fs_dx__\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%center(fs_c__, 3) = %s%%dom_min(3) + (dble(fs_k__) - 0.5d0) * fs_dx__\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%dx(fs_c__) = fs_dx__\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%volume(fs_c__) = fs_dx__**3\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%face_area(fs_c__, :) = fs_dx__**2\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_i__ > 1) %s%%neighbor(fs_c__, 1, :) = fs_c__ - 2\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_i__ < %s%%nx) %s%%neighbor(fs_c__, 2, :) = fs_c__\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_j__ > 1) %s%%neighbor(fs_c__, 3, :) = fs_c__ - %s%%nx - 1\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_j__ < %s%%ny) %s%%neighbor(fs_c__, 4, :) = fs_c__ + %s%%nx - 1\n" ind m m m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_k__ > 1) %s%%neighbor(fs_c__, 5, :) = fs_c__ - %s%%nx * %s%%ny - 1\n" ind m m m);
    Buffer.add_string buf (Printf.sprintf "%s        if (fs_k__ < %s%%nz) %s%%neighbor(fs_c__, 6, :) = fs_c__ + %s%%nx * %s%%ny - 1\n" ind m m m m);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%send block\n" ind);
    (* Strip the trailing newline so the dispatch caller can add one itself. *)
    let s = Buffer.contents buf in
    if String.length s > 0 && s.[String.length s - 1] = '\n' then
      String.sub s 0 (String.length s - 1)
    else s
  | _ -> failwith "geom_cartesian_uniform expects: mesh, dim_min, dim_max, spacing"

let gen_geom_cartesian_resize_block ind m fields extra =
  let buf = Buffer.create 2048 in
  (* extra is the Fortran expression for the number of new cells the caller
     is about to append, so a batched split can grow capacity in one step. *)
  Buffer.add_string buf (Printf.sprintf "%s  if (%s%%num_cells + %s > %s%%cell_capacity) then\n" ind m extra m);
  Buffer.add_string buf (Printf.sprintf "%s    fs_newcap__ = max(%s%%num_cells + %s, max(1, 2 * %s%%cell_capacity))\n" ind m extra m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_i1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__ = -1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__(1:%s%%cell_capacity) = %s%%leaf_ids\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_i1__, %s%%leaf_ids)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_i1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__ = 0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__(1:%s%%cell_capacity) = %s%%level\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_i1__, %s%%level)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_i1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__ = -1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i1__(1:%s%%cell_capacity) = %s%%parent\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_i1__, %s%%parent)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_i2__(fs_newcap__, 8))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i2__ = -1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i2__(1:%s%%cell_capacity, :) = %s%%children\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_i2__, %s%%children)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_l1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_l1__ = .false.\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_l1__(1:%s%%cell_capacity) = %s%%is_leaf\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_l1__, %s%%is_leaf)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r2__(fs_newcap__, 3))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__ = 0.0d0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__(1:%s%%cell_capacity, :) = %s%%center\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r2__, %s%%center)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__ = 0.0d0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__(1:%s%%cell_capacity) = %s%%dx\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r1__, %s%%dx)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r1__(fs_newcap__))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__ = 0.0d0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__(1:%s%%cell_capacity) = %s%%volume\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r1__, %s%%volume)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r2__(fs_newcap__, 6))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__ = 0.0d0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__(1:%s%%cell_capacity, :) = %s%%face_area\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r2__, %s%%face_area)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_i3__(fs_newcap__, 6, 4))\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i3__ = -1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_i3__(1:%s%%cell_capacity, :, :) = %s%%neighbor\n" ind m m);
  Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_i3__, %s%%neighbor)\n" ind m);
  List.iter (fun f ->
    match f.field_type with
    | TFloat ->
      Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r1__(fs_newcap__))\n" ind);
      Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__ = 0.0d0\n" ind);
      Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r1__(1:%s%%cell_capacity) = %s%%%s\n" ind m m f.field_name);
      Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r1__, %s%%%s)\n" ind m f.field_name)
    | TArray (TFloat, [FixedDim (IntLit 3)]) ->
      Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_tmp_r2__(fs_newcap__, 3))\n" ind);
      Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__ = 0.0d0\n" ind);
      Buffer.add_string buf (Printf.sprintf "%s    fs_tmp_r2__(1:%s%%cell_capacity, :) = %s%%%s\n" ind m m f.field_name);
      Buffer.add_string buf (Printf.sprintf "%s    call move_alloc(fs_tmp_r2__, %s%%%s)\n" ind m f.field_name)
    | _ -> ()
  ) fields;
  Buffer.add_string buf (Printf.sprintf "%s    %s%%cell_capacity = fs_newcap__\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s  end if\n" ind);
  Buffer.contents buf

(* Emit a call to the fast locate-based neighbor rebuild
   (support.geom_cartesian: geom_cartesian_rebuild_neighbors). This replaces
   the old inline all-pairs O(num_leaves^2) overlap scan with an
   O(num_leaves * tree_depth) probe. Returns a single line with no trailing
   newline so the caller can append one. *)
let gen_neighbor_rebuild_call ind m =
  Printf.sprintf "%s  call geom_cartesian_rebuild_neighbors(%s)" ind m

(* Emit the body that turns fs_parent__ (a 1-based active-leaf cell id) into
   eight children: geometry, tree topology, and FieldSet inheritance. Assumes
   fs_old_cells__ already holds the pre-split cell count and that the
   surrounding block declares fs_half__, fs_q__, fs_child__, fs_sx__, fs_sy__,
   fs_sz__. Does not touch leaf_ids; the caller updates the leaf list. p is
   the indent prefix for the emitted statements. *)
let emit_refine_one_parent p m fields =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf (Printf.sprintf "%sfs_half__ = 0.5d0 * %s%%dx(fs_parent__)\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s%s%%is_leaf(fs_parent__) = .false.\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s%s%%children(fs_parent__, :) = -1\n" p m);
  Buffer.add_string buf (Printf.sprintf "%sdo fs_q__ = 1, 8\n" p);
  Buffer.add_string buf (Printf.sprintf "%s  fs_child__ = fs_old_cells__ + fs_q__\n" p);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%children(fs_parent__, fs_q__) = fs_child__ - 1\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%parent(fs_child__) = fs_parent__ - 1\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%level(fs_child__) = %s%%level(fs_parent__) + 1\n" p m m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%is_leaf(fs_child__) = .true.\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  fs_sx__ = merge(-0.25d0, 0.25d0, mod(fs_q__ - 1, 2) == 0)\n" p);
  Buffer.add_string buf (Printf.sprintf "%s  fs_sy__ = merge(-0.25d0, 0.25d0, mod((fs_q__ - 1) / 2, 2) == 0)\n" p);
  Buffer.add_string buf (Printf.sprintf "%s  fs_sz__ = merge(-0.25d0, 0.25d0, ((fs_q__ - 1) / 4) == 0)\n" p);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%dx(fs_child__) = fs_half__\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%center(fs_child__, 1) = %s%%center(fs_parent__, 1) + fs_sx__ * %s%%dx(fs_parent__)\n" p m m m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%center(fs_child__, 2) = %s%%center(fs_parent__, 2) + fs_sy__ * %s%%dx(fs_parent__)\n" p m m m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%center(fs_child__, 3) = %s%%center(fs_parent__, 3) + fs_sz__ * %s%%dx(fs_parent__)\n" p m m m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%volume(fs_child__) = fs_half__**3\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%face_area(fs_child__, :) = fs_half__**2\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%children(fs_child__, :) = -1\n" p m);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%neighbor(fs_child__, :, :) = -1\n" p m);
  List.iter (fun f ->
    match f.field_type with
    | TFloat ->
      Buffer.add_string buf (Printf.sprintf "%s  %s%%%s(fs_child__) = %s%%%s(fs_parent__)\n" p m f.field_name m f.field_name)
    | TArray (TFloat, [FixedDim (IntLit 3)]) ->
      Buffer.add_string buf (Printf.sprintf "%s  %s%%%s(fs_child__, :) = %s%%%s(fs_parent__, :)\n" p m f.field_name m f.field_name)
    | _ -> ()
  ) fields;
  Buffer.add_string buf (Printf.sprintf "%send do\n" p);
  Buffer.add_string buf (Printf.sprintf "%s%s%%num_cells = fs_old_cells__ + 8\n" p m);
  Buffer.contents buf

(* Emit the Fortran statements that refine fs_parent__ (a 1-based cell id
   already known to be an active leaf in scope) into eight children. Assumes
   the surrounding block declares the standard fs_* scratch variables used
   by gen_geom_cartesian_refine_cell_stmt and that the FieldSet field
   inheritance lines must apply. ind is the indent of the surrounding block
   body lines (not the outer block header). *)
let gen_geom_cartesian_refine_parent_body ind m fields =
  let buf = Buffer.create 4096 in
  (* Reuse the same resize cascade as refine_cell so per-pass growth stays
     amortized when balance refinements pile up. *)
  Buffer.add_string buf (gen_geom_cartesian_resize_block ind m fields "8");
  Buffer.add_string buf (Printf.sprintf "%s  fs_old_cells__ = %s%%num_cells\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s  fs_old_leaves__ = %s%%num_leaves\n" ind m);
  (* Split the parent into eight children (geometry, topology, fields). *)
  Buffer.add_string buf (emit_refine_one_parent (ind ^ "  ") m fields);
  Buffer.add_string buf (Printf.sprintf "%s  fs_leaf__ = 1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s  do while (fs_leaf__ <= fs_old_leaves__)\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    if (%s%%leaf_ids(fs_leaf__) == fs_parent__ - 1) then\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s      %s%%leaf_ids(fs_leaf__) = fs_old_cells__\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s      exit\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_leaf__ = fs_leaf__ + 1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s  do fs_q__ = 2, 8\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    %s%%leaf_ids(fs_old_leaves__ + fs_q__ - 1) = fs_old_cells__ + fs_q__ - 1\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s  %s%%num_leaves = fs_old_leaves__ + 7\n" ind m);
  Buffer.add_string buf (gen_neighbor_rebuild_call ind m);
  Buffer.add_string buf "\n";
  Buffer.contents buf

(* Emit the 2:1 balance cascade. The scan that picks the next coarser cell
   to refine lives in support.geom_cartesian as geom_cartesian_find_imbalance,
   which keeps this emitter focused on the parts that need the monomorphic
   mesh type (the refine itself). The cascade iterates until the FortScript
   helper reports no remaining violations. *)
let gen_geom_cartesian_balance_cascade_body ind m fields =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "%s  fs_balance_iter__ = 0\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s  fs_balance_target__ = geom_cartesian_find_imbalance(%s)\n" ind m);
  (* Safety bound: each refine adds 8 cells, so cell_capacity * 8 is a
     generous upper bound on cascade iterations. *)
  Buffer.add_string buf (Printf.sprintf "%s  do while (fs_balance_target__ >= 0 .and. fs_balance_iter__ < 8 * %s%%cell_capacity + 8)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s    fs_balance_iter__ = fs_balance_iter__ + 1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_parent__ = fs_balance_target__ + 1\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    if (%s%%is_leaf(fs_parent__)) then\n" ind m);
  Buffer.add_string buf (gen_geom_cartesian_refine_parent_body (ind ^ "    ") m fields);
  Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
  Buffer.add_string buf (Printf.sprintf "%s    fs_balance_target__ = geom_cartesian_find_imbalance(%s)\n" ind m);
  Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
  Buffer.contents buf

let gen_geom_cartesian_refine_cell_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; cell_e] ->
    let _mono, fields = resolve_cartesian_template mesh_e in
    let m = gen_expr mesh_e in
    let c = gen_index_expr cell_e in
    let buf = Buffer.create 4096 in
    Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_parent__, fs_child__, fs_q__, fs_leaf__, fs_old_cells__, fs_old_leaves__, fs_newcap__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_balance_iter__, fs_balance_target__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_half__, fs_sx__, fs_sy__, fs_sz__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer, allocatable :: fs_tmp_i1__(:), fs_tmp_i2__(:, :), fs_tmp_i3__(:, :, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8), allocatable :: fs_tmp_r1__(:), fs_tmp_r2__(:, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical, allocatable :: fs_tmp_l1__(:)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  fs_parent__ = %s\n" ind c);
    Buffer.add_string buf (Printf.sprintf "%s  if (fs_parent__ >= 1 .and. fs_parent__ <= %s%%num_cells .and. %s%%is_leaf(fs_parent__)) then\n" ind m m);
    Buffer.add_string buf (gen_geom_cartesian_resize_block ind m fields "8");
    Buffer.add_string buf (Printf.sprintf "%s  fs_old_cells__ = %s%%num_cells\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  fs_old_leaves__ = %s%%num_leaves\n" ind m);
    (* Split the parent into eight children (geometry, topology, fields). *)
    Buffer.add_string buf (emit_refine_one_parent (ind ^ "  ") m fields);
    Buffer.add_string buf (Printf.sprintf "%s  fs_leaf__ = 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  do while (fs_leaf__ <= fs_old_leaves__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    if (%s%%leaf_ids(fs_leaf__) == fs_parent__ - 1) then\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      %s%%leaf_ids(fs_leaf__) = fs_old_cells__\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      exit\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    fs_leaf__ = fs_leaf__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  do fs_q__ = 2, 8\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    %s%%leaf_ids(fs_old_leaves__ + fs_q__ - 1) = fs_old_cells__ + fs_q__ - 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  %s%%num_leaves = fs_old_leaves__ + 7\n" ind m);
    Buffer.add_string buf (gen_neighbor_rebuild_call ind m);
    Buffer.add_string buf "\n";
    (* Restore 2:1 balance after the user-requested refinement: any neighbor
       whose level is now more than one below this cell's level is itself
       refined. The cascade iterates until every leaf satisfies the rule. *)
    Buffer.add_string buf (gen_geom_cartesian_balance_cascade_body ind m fields);
    Buffer.add_string buf (Printf.sprintf "%s  end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%send block" ind);
    Buffer.contents buf
  | _ -> failwith "geom_cartesian_refine_cell() expects 2 arguments"

let gen_geom_cartesian_refine_to_sdf_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; sdf_e; tol_e; max_level_e] ->
    let _mono, fields = resolve_cartesian_template mesh_e in
    let m = gen_expr mesh_e in
    let sdf = gen_expr sdf_e in
    let tol = gen_expr tol_e in
    let max_level = gen_expr max_level_e in
    let buf = Buffer.create 8192 in
    Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  ! Refine leaves near the SDF zero surface.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_parent__, fs_child__, fs_q__, fs_leaf__, fs_old_cells__, fs_old_leaves__, fs_newcap__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_l__, fs_target__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_balance_iter__, fs_balance_target__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_nx_sdf__, fs_ny_sdf__, fs_nz_sdf__, fs_ix__, fs_iy__, fs_iz__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_half__, fs_sx__, fs_sy__, fs_sz__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_fx__, fs_fy__, fs_fz__, fs_wx__, fs_wy__, fs_wz__, fs_sdf_val__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_c000__, fs_c100__, fs_c010__, fs_c110__, fs_c001__, fs_c101__, fs_c011__, fs_c111__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical :: fs_changed__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer, allocatable :: fs_tmp_i1__(:), fs_tmp_i2__(:, :), fs_tmp_i3__(:, :, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8), allocatable :: fs_tmp_r1__(:), fs_tmp_r2__(:, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical, allocatable :: fs_tmp_l1__(:)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  fs_nx_sdf__ = size(%s, 3)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s  fs_ny_sdf__ = size(%s, 2)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s  fs_nz_sdf__ = size(%s, 1)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s  fs_changed__ = .true.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  do while (fs_changed__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    fs_changed__ = .false.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    fs_target__ = -1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    if (fs_nx_sdf__ >= 2 .and. fs_ny_sdf__ >= 2 .and. fs_nz_sdf__ >= 2) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      do fs_l__ = 1, %s%%num_leaves\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        fs_parent__ = %s%%leaf_ids(fs_l__) + 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        if (%s%%level(fs_parent__) < %s) then\n" ind m max_level);
    Buffer.add_string buf (Printf.sprintf "%s          ! Sample SDF with trilinear interpolation.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_fx__ = 1.0d0 + (%s%%center(fs_parent__, 1) - %s%%dom_min(1)) / (%s%%dom_max(1) - %s%%dom_min(1)) * dble(fs_nx_sdf__ - 1)\n" ind m m m m);
    Buffer.add_string buf (Printf.sprintf "%s          fs_fy__ = 1.0d0 + (%s%%center(fs_parent__, 2) - %s%%dom_min(2)) / (%s%%dom_max(2) - %s%%dom_min(2)) * dble(fs_ny_sdf__ - 1)\n" ind m m m m);
    Buffer.add_string buf (Printf.sprintf "%s          fs_fz__ = 1.0d0 + (%s%%center(fs_parent__, 3) - %s%%dom_min(3)) / (%s%%dom_max(3) - %s%%dom_min(3)) * dble(fs_nz_sdf__ - 1)\n" ind m m m m);
    Buffer.add_string buf (Printf.sprintf "%s          fs_ix__ = max(1, min(fs_nx_sdf__ - 1, int(fs_fx__)))\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_iy__ = max(1, min(fs_ny_sdf__ - 1, int(fs_fy__)))\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_iz__ = max(1, min(fs_nz_sdf__ - 1, int(fs_fz__)))\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_wx__ = fs_fx__ - dble(fs_ix__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_wy__ = fs_fy__ - dble(fs_iy__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_wz__ = fs_fz__ - dble(fs_iz__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c000__ = %s(fs_iz__, fs_iy__, fs_ix__)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c100__ = %s(fs_iz__, fs_iy__, fs_ix__ + 1)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c010__ = %s(fs_iz__, fs_iy__ + 1, fs_ix__)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c110__ = %s(fs_iz__, fs_iy__ + 1, fs_ix__ + 1)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c001__ = %s(fs_iz__ + 1, fs_iy__, fs_ix__)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c101__ = %s(fs_iz__ + 1, fs_iy__, fs_ix__ + 1)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c011__ = %s(fs_iz__ + 1, fs_iy__ + 1, fs_ix__)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_c111__ = %s(fs_iz__ + 1, fs_iy__ + 1, fs_ix__ + 1)\n" ind sdf);
    Buffer.add_string buf (Printf.sprintf "%s          fs_sdf_val__ = (1.0d0 - fs_wz__) * ((1.0d0 - fs_wy__) * ((1.0d0 - fs_wx__) * fs_c000__ + fs_wx__ * fs_c100__) + fs_wy__ * ((1.0d0 - fs_wx__) * fs_c010__ + fs_wx__ * fs_c110__)) + fs_wz__ * ((1.0d0 - fs_wy__) * ((1.0d0 - fs_wx__) * fs_c001__ + fs_wx__ * fs_c101__) + fs_wy__ * ((1.0d0 - fs_wx__) * fs_c011__ + fs_wx__ * fs_c111__))\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          if (abs(fs_sdf_val__) <= %s) then\n" ind tol);
    Buffer.add_string buf (Printf.sprintf "%s            fs_target__ = fs_parent__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s            exit\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    if (fs_target__ > 0) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_parent__ = fs_target__\n" ind);
    Buffer.add_string buf (gen_geom_cartesian_resize_block (ind ^ "  ") m fields "8");
    Buffer.add_string buf (Printf.sprintf "%s      fs_old_cells__ = %s%%num_cells\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      fs_old_leaves__ = %s%%num_leaves\n" ind m);
    (* Split the target into eight children (geometry, topology, fields). *)
    Buffer.add_string buf (emit_refine_one_parent (ind ^ "      ") m fields);
    Buffer.add_string buf (Printf.sprintf "%s      fs_leaf__ = 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      do while (fs_leaf__ <= fs_old_leaves__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        if (%s%%leaf_ids(fs_leaf__) == fs_parent__ - 1) then\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s          %s%%leaf_ids(fs_leaf__) = fs_old_cells__\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s          exit\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        fs_leaf__ = fs_leaf__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      do fs_q__ = 2, 8\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%leaf_ids(fs_old_leaves__ + fs_q__ - 1) = fs_old_cells__ + fs_q__ - 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      %s%%num_leaves = fs_old_leaves__ + 7\n" ind m);
    Buffer.add_string buf (gen_neighbor_rebuild_call (ind ^ "  ") m);
    Buffer.add_string buf (Printf.sprintf "\n%s      fs_changed__ = .true.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
    (* After the SDF refinement loop converges, enforce 2:1 balance over the
       entire mesh in one final cascade. *)
    Buffer.add_string buf (gen_geom_cartesian_balance_cascade_body ind m fields);
    Buffer.add_string buf (Printf.sprintf "%send block" ind);
    Buffer.contents buf
  | _ -> failwith "geom_cartesian_refine_to_sdf() expects 4 arguments"

(* Lower geom_cartesian_refine_band(mesh, sdf, tol, max_level), a batched
   snappyHexMesh-castellation-style refinement. sdf is a per-cell scalar
   field (cell-id indexed) already sampled at leaf centers. Each pass marks
   every leaf below max_level whose |sdf| <= tol, propagates 2:1 balance over
   the marked set, splits all marked cells in one batch, recompacts the leaf
   list once, and rebuilds the neighbor table once. The pass repeats until a
   pass marks nothing. This replaces the per-cell refine + per-cell neighbor
   rebuild pattern, dropping cost from O(R * N^2) to O(L * N * tree_depth). *)
let gen_geom_cartesian_refine_band_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; sdf_e; tol_e; max_level_e] ->
    let _mono, fields = resolve_cartesian_template mesh_e in
    let m = gen_expr mesh_e in
    let sdf = gen_expr sdf_e in
    let tol = gen_expr tol_e in
    let max_level = gen_expr max_level_e in
    let buf = Buffer.create 8192 in
    Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  ! Batched SDF-band refinement (snappyHexMesh castellation style).\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_parent__, fs_child__, fs_q__, fs_old_cells__, fs_newcap__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_l__, fs_c__, fs_f__, fs_s__, fs_nbr__, fs_top__, fs_nmark__, fs_i__, fs_write__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8) :: fs_half__, fs_sx__, fs_sy__, fs_sz__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical :: fs_changed__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical, allocatable :: fs_mark__(:)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer, allocatable :: fs_stack__(:), fs_list__(:)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer, allocatable :: fs_tmp_i1__(:), fs_tmp_i2__(:, :), fs_tmp_i3__(:, :, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  real(8), allocatable :: fs_tmp_r1__(:), fs_tmp_r2__(:, :)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical, allocatable :: fs_tmp_l1__(:)\n" ind);
    (* Outer convergence loop: each pass lifts band cells by one level. *)
    Buffer.add_string buf (Printf.sprintf "%s  fs_changed__ = .true.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  do while (fs_changed__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    fs_changed__ = .false.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_mark__(%s%%num_cells))\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    fs_mark__ = .false.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_stack__(%s%%num_cells))\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    fs_top__ = 0\n" ind);
    (* MARK: band leaves still below the target level. *)
    Buffer.add_string buf (Printf.sprintf "%s    do fs_l__ = 1, %s%%num_leaves\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      fs_c__ = %s%%leaf_ids(fs_l__) + 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      if (%s%%level(fs_c__) < %s) then\n" ind m max_level);
    Buffer.add_string buf (Printf.sprintf "%s        if (abs(%s(fs_c__)) <= %s) then\n" ind sdf tol);
    Buffer.add_string buf (Printf.sprintf "%s          fs_mark__(fs_c__) = .true.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_top__ = fs_top__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_stack__(fs_top__) = fs_c__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    (* BALANCE: 2:1 propagation over the marked set using current neighbors. *)
    Buffer.add_string buf (Printf.sprintf "%s    do while (fs_top__ > 0)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_c__ = fs_stack__(fs_top__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_top__ = fs_top__ - 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      do fs_f__ = 1, 6\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        do fs_s__ = 1, 4\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          fs_nbr__ = %s%%neighbor(fs_c__, fs_f__, fs_s__)\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s          if (fs_nbr__ >= 0) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s            if (%s%%is_leaf(fs_nbr__ + 1)) then\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s              if (%s%%level(fs_nbr__ + 1) < %s%%level(fs_c__)) then\n" ind m m);
    Buffer.add_string buf (Printf.sprintf "%s                if (.not. fs_mark__(fs_nbr__ + 1)) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s                  fs_mark__(fs_nbr__ + 1) = .true.\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s                  fs_top__ = fs_top__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s                  fs_stack__(fs_top__) = fs_nbr__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s                end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s              end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s            end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    (* COLLECT the marked leaves into a stable list before any split. *)
    Buffer.add_string buf (Printf.sprintf "%s    allocate(fs_list__(%s%%num_leaves))\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    fs_nmark__ = 0\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    do fs_l__ = 1, %s%%num_leaves\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      fs_c__ = %s%%leaf_ids(fs_l__) + 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      if (fs_mark__(fs_c__)) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        fs_nmark__ = fs_nmark__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        fs_list__(fs_nmark__) = fs_c__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    if (fs_nmark__ > 0) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_changed__ = .true.\n" ind);
    (* Grow capacity once for all 8 * nmark new children. *)
    Buffer.add_string buf (gen_geom_cartesian_resize_block (ind ^ "    ") m fields "(8 * fs_nmark__)");
    (* SPLIT every marked parent, appending children at the current tail. *)
    Buffer.add_string buf (Printf.sprintf "%s      do fs_i__ = 1, fs_nmark__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        fs_parent__ = fs_list__(fs_i__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        fs_old_cells__ = %s%%num_cells\n" ind m);
    Buffer.add_string buf (emit_refine_one_parent (ind ^ "        ") m fields);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    (* RECOMPACT the leaf id list once over the whole cell array. *)
    Buffer.add_string buf (Printf.sprintf "%s      %s%%leaf_ids = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      fs_write__ = 0\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      do fs_i__ = 1, %s%%num_cells\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        if (%s%%is_leaf(fs_i__)) then\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s          fs_write__ = fs_write__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s          %s%%leaf_ids(fs_write__) = fs_i__ - 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      %s%%num_leaves = fs_write__\n" ind m);
    (* Rebuild the neighbor table once for the whole batch. *)
    Buffer.add_string buf (gen_neighbor_rebuild_call (ind ^ "    ") m);
    Buffer.add_string buf "\n";
    Buffer.add_string buf (Printf.sprintf "%s    end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    deallocate(fs_mark__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    deallocate(fs_stack__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    deallocate(fs_list__)\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%send block" ind);
    Buffer.contents buf
  | _ -> failwith "geom_cartesian_refine_band() expects 4 arguments"

let gen_geom_cartesian_coarsen_cell_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; cell_e] ->
    let _mono, fields = resolve_cartesian_template mesh_e in
    let m = gen_expr mesh_e in
    let c = gen_index_expr cell_e in
    let buf = Buffer.create 4096 in
    Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fs_parent__, fs_child__, fs_q__, fs_write__, fs_i__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  logical :: fs_can__\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  fs_parent__ = %s\n" ind c);
    Buffer.add_string buf (Printf.sprintf "%s  fs_can__ = fs_parent__ >= 1 .and. fs_parent__ <= %s%%num_cells\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s  if (fs_can__) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    do fs_q__ = 1, 8\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_child__ = %s%%children(fs_parent__, fs_q__) + 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      if (fs_child__ < 1 .or. fs_child__ > %s%%num_cells) fs_can__ = .false.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      if (fs_can__) then\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        if (.not. %s%%is_leaf(fs_child__)) fs_can__ = .false.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s  if (fs_can__) then\n" ind);
    List.iter (fun f ->
      match f.field_type with
      | TFloat ->
        Buffer.add_string buf (Printf.sprintf "%s    %s%%%s(fs_parent__) = 0.0d0\n" ind m f.field_name);
        Buffer.add_string buf (Printf.sprintf "%s    do fs_q__ = 1, 8\n" ind);
        Buffer.add_string buf (Printf.sprintf "%s      fs_child__ = %s%%children(fs_parent__, fs_q__) + 1\n" ind m);
        Buffer.add_string buf (Printf.sprintf "%s      %s%%%s(fs_parent__) = %s%%%s(fs_parent__) + %s%%%s(fs_child__)\n" ind m f.field_name m f.field_name m f.field_name);
        Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
        Buffer.add_string buf (Printf.sprintf "%s    %s%%%s(fs_parent__) = %s%%%s(fs_parent__) / 8.0d0\n" ind m f.field_name m f.field_name)
      | TArray (TFloat, [FixedDim (IntLit 3)]) ->
        Buffer.add_string buf (Printf.sprintf "%s    %s%%%s(fs_parent__, :) = 0.0d0\n" ind m f.field_name);
        Buffer.add_string buf (Printf.sprintf "%s    do fs_q__ = 1, 8\n" ind);
        Buffer.add_string buf (Printf.sprintf "%s      fs_child__ = %s%%children(fs_parent__, fs_q__) + 1\n" ind m);
        Buffer.add_string buf (Printf.sprintf "%s      %s%%%s(fs_parent__, :) = %s%%%s(fs_parent__, :) + %s%%%s(fs_child__, :)\n" ind m f.field_name m f.field_name m f.field_name);
        Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
        Buffer.add_string buf (Printf.sprintf "%s    %s%%%s(fs_parent__, :) = %s%%%s(fs_parent__, :) / 8.0d0\n" ind m f.field_name m f.field_name)
      | _ -> ()
    ) fields;
    Buffer.add_string buf (Printf.sprintf "%s    do fs_q__ = 1, 8\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s      fs_child__ = %s%%children(fs_parent__, fs_q__) + 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      %s%%is_leaf(fs_child__) = .false.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    %s%%children(fs_parent__, :) = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    %s%%is_leaf(fs_parent__) = .true.\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    %s%%leaf_ids = -1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s    fs_write__ = 0\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    do fs_i__ = 1, %s%%num_cells\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      if (%s%%is_leaf(fs_i__)) then\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s        fs_write__ = fs_write__ + 1\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s        %s%%leaf_ids(fs_write__) = fs_i__ - 1\n" ind m);
    Buffer.add_string buf (Printf.sprintf "%s      end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    end do\n" ind);
    Buffer.add_string buf (Printf.sprintf "%s    %s%%num_leaves = fs_write__\n" ind m);
    Buffer.add_string buf (gen_neighbor_rebuild_call ind m);
    Buffer.add_string buf (Printf.sprintf "\n%s  end if\n" ind);
    Buffer.add_string buf (Printf.sprintf "%send block" ind);
    Buffer.contents buf
  | _ -> failwith "geom_cartesian_coarsen_cell() expects 2 arguments"

let gen_geom_cartesian_face_center_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [mesh_e; c_e; face_e; fc_e] ->
    let m = gen_expr mesh_e in
    let c = gen_index_expr c_e in
    let face = gen_expr face_e in
    let fc = gen_expr fc_e in
    String.concat "\n" [
      Printf.sprintf "%s%s(1) = %s%%center(%s, 1)" ind fc m c;
      Printf.sprintf "%s%s(2) = %s%%center(%s, 2)" ind fc m c;
      Printf.sprintf "%s%s(3) = %s%%center(%s, 3)" ind fc m c;
      Printf.sprintf "%sselect case (%s)" ind face;
      Printf.sprintf "%scase (0)" ind;
      Printf.sprintf "%s  %s(1) = %s(1) - 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%scase (1)" ind;
      Printf.sprintf "%s  %s(1) = %s(1) + 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%scase (2)" ind;
      Printf.sprintf "%s  %s(2) = %s(2) - 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%scase (3)" ind;
      Printf.sprintf "%s  %s(2) = %s(2) + 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%scase (4)" ind;
      Printf.sprintf "%s  %s(3) = %s(3) - 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%scase default" ind;
      Printf.sprintf "%s  %s(3) = %s(3) + 0.5d0 * %s%%dx(%s)" ind fc fc m c;
      Printf.sprintf "%send select" ind;
    ]
  | _ -> failwith "geom_cartesian_face_center() expects 4 arguments"

let gen_geom_cartesian_face_normal_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [face_e; n_e] ->
    let face = gen_expr face_e in
    let n = gen_expr n_e in
    String.concat "\n" [
      Printf.sprintf "%s%s = 0.0d0" ind n;
      Printf.sprintf "%sselect case (%s)" ind face;
      Printf.sprintf "%scase (0)" ind;
      Printf.sprintf "%s  %s(1) = -1.0d0" ind n;
      Printf.sprintf "%scase (1)" ind;
      Printf.sprintf "%s  %s(1) = 1.0d0" ind n;
      Printf.sprintf "%scase (2)" ind;
      Printf.sprintf "%s  %s(2) = -1.0d0" ind n;
      Printf.sprintf "%scase (3)" ind;
      Printf.sprintf "%s  %s(2) = 1.0d0" ind n;
      Printf.sprintf "%scase (4)" ind;
      Printf.sprintf "%s  %s(3) = -1.0d0" ind n;
      Printf.sprintf "%scase default" ind;
      Printf.sprintf "%s  %s(3) = 1.0d0" ind n;
      Printf.sprintf "%send select" ind;
    ]
  | _ -> failwith "geom_cartesian_face_normal() expects 2 arguments"

