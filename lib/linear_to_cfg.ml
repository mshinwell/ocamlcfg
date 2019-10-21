(**************************************************************************)
(*                                                                        *)
(*                                 OCamlFDO                               *)
(*                                                                        *)
(*                     Greta Yorsh, Jane Street Europe                    *)
(*                                                                        *)
(*   Copyright 2019 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module C = Cfg
module L = Linear

type t = {
  cfg : Cfg.t;
  mutable layout : Label.t list;
  trap_depths : int Label.Tbl.t;
  (* Map labels to trap depths. Required for linearize. *)
  trap_labels : Label.t Label.Tbl.t;
  (* Maps trap handler block label [L] to the label of the block where the
     "Pushtrap L" reference it. Used for dead block elimination. This
     mapping is one to one, but the reverse is not, because a block might
     contain multiple Pushtrap, which is not a terminator. *)
  (* CR mshinwell: I'm not sure the statement about not being a 1:1
     map is true at present.  There might be more than one Pushtrap, but
     it would be for different handlers, no?  That said, in the future, I
     don't think this will necessarily hold (as noted elsewhere) so we
     shouldn't rely on this mapping being 1:1. *)
  mutable id_to_label : Label.t Numbers.Int.Map.t;
  (* Map id of instruction to label of the block that contains the
     instruction. Used for mapping perf data back to linear IR. *)
  mutable preserve_orig_labels : bool;
  (* Set for validation, unset for optimization. *)
  mutable new_labels : Label.Set.t;
  (* Labels added by cfg construction, except entry. Used for testing of the
     mapping back to Linear IR. *)
}

let _id_to_label t id = (* CR mshinwell: remove if unused *)
  match Numbers.Int.Map.find_opt id t.id_to_label with
  | None ->
    Misc.fatal_errorf "Cannot find label for ID %d in [id_to_label]:@ %a"
      id
      (Numbers.Int.Map.print Label.print) t.id_to_label
  | Some lbl ->
    if !Print.verbose then begin
      Printf.printf "Found label %d for id %d in map\n" lbl id
    end;
    Some lbl

(* CR-soon gyorsh: implement CFG traversal *)

(* CR-soon gyorsh: abstraction of cfg updates that transparently and
   efficiently keeps predecessors and successors in sync. For example,
   change successors relation should automatically updates the predecessors
   relation without recomputing them from scratch. *)

(* CR-soon gyorsh: Optimize terminators. Implement switch as jump table or
   as a sequence of branches depending on perf counters and layout. It
   should be implemented as a separate transformation on the cfg, that needs
   to be informated by the layout, but it should not be done while emitting
   linear. This way we can keep to_linear as simple as possible to ensure
   basic invariants are preserved, while other optimizations can be turned
   on and off. *)

let entry_id = 1
let last_linear_id = ref entry_id

let get_new_linear_id =
  fun () ->
    let id = !last_linear_id in
    last_linear_id := id + 1;
    id

let create_empty_instruction ?(trap_depth = 0) desc : _ C.instruction =
  { desc;
    arg = [| |];
    res = [| |];
    dbg = Debuginfo.none;
    live = Reg.Set.empty;
    trap_depth;
    id = get_new_linear_id ();
  }

let create_instruction desc ~trap_depth (i : Linear.instruction)
      : _ C.instruction =
  { desc;
    arg = i.arg;
    res = i.res;
    dbg = i.dbg;
    live = i.live;
    trap_depth;
    id = get_new_linear_id ();
  }

let create_empty_block t start =
  let block : C.basic_block =
    { start;
      body = [];
      terminator = create_empty_instruction (C.Branch []);
      predecessors = Label.Set.empty;
    }
  in
  if C.mem_block t.cfg start then begin
    Misc.fatal_errorf "A block with starting label %d is already registered"
      start
  end;
  t.layout <- start :: t.layout;
  block

let register_block t (block : C.basic_block) =
  if Label.Tbl.mem t.cfg.blocks block.start then begin
    Misc.fatal_errorf "A block with starting label %d is already registered"
      block.start
  end;
  (* Printf.printf "registering block %d\n" block.start *)
  (* Body is constructed in reverse, fix it now: *)
  block.body <- List.rev block.body;
  (* CR mshinwell: Document this assertion.  I think in fact this should be
     a [fatal_errorf] since it doesn't appear to be a local property of
     this function *)
  assert (not (block.terminator.id = 0 && List.length block.body = 0));
  Label.Tbl.add t.cfg.blocks block.start block

let register_predecessors_for_all_blocks t =
  Label.Tbl.iter (fun label block ->
      let targets = C.successor_labels t.cfg block in
      List.iter (fun target ->
          let target_block = Label.Tbl.find t.cfg.blocks target in
          target_block.predecessors <-
            Label.Set.add label target_block.predecessors)
        targets)
    t.cfg.blocks

let get_or_make_label t (insn : Linear.instruction)
      : Linear_utils.labelled_insn =
  match insn.desc with
  | Llabel label -> { label; insn; }
  | Lend -> Misc.fatal_error "Unexpected end of function instead of label"
  | _ ->
    let label = Cmm.new_label () in
    t.new_labels <- Label.Set.add label t.new_labels;
    let insn = Linear.instr_cons (Llabel label) [||] [||] insn in
    { label; insn; }

let mark_trap_label t ~lbl_handler ~lbl_pushtrap_block =
  if Label.Tbl.mem t.trap_labels lbl_handler then begin
    Misc.fatal_errorf "Trap handler label already exists: Lpushtrap %d \
        from block label %d\n"
      lbl_handler lbl_pushtrap_block
  end;
  Label.Tbl.add t.trap_labels lbl_handler lbl_pushtrap_block

let record_trap_depth_at_label t label ~trap_depth =
  match Label.Tbl.find t.trap_depths label with
  | exception Not_found -> Label.Tbl.add t.trap_depths label trap_depth
  | existing_trap_depth ->
    if trap_depth <> existing_trap_depth then begin
      Misc.fatal_errorf "Conflicting trap depths for label %d: \
          already have %d but the following instruction has depth %d"
        label existing_trap_depth trap_depth
    end

let block_is_registered t (block : C.basic_block) =
  Label.Tbl.mem t.cfg.blocks block.start

let add_terminator t (block : C.basic_block) (i : L.instruction)
      (desc : C.terminator) ~trap_depth =
  begin match desc with
  | Branch successors ->
    List.iter (fun (_, label) ->
        record_trap_depth_at_label t label ~trap_depth)
      successors
  | Switch arms ->
    Array.iter (fun label ->
        record_trap_depth_at_label t label ~trap_depth)
      arms
  | Return | Raise _ | Tailcall _ -> ()
  end;
  begin match desc with
  (* CR mshinwell: What exactly determines which ones of these must be
     followed by a label? *)
  | Branch _ -> ()
  | Switch _ | Return | Raise _ | Tailcall _ ->
    if not (Linear_utils.has_label i.next) then begin
      Misc.fatal_errorf "Linear instruction not followed by label:@ %a"
        Printlinear.instr { i with next = Linear.end_instr; }
    end
  end;
  block.terminator <- create_instruction desc ~trap_depth i;
  register_block t block

let rec create_blocks t (i : L.instruction) (block : C.basic_block)
      ~trap_depth =
  match i.desc with
  | Lend ->
    if not (block_is_registered t block) then begin
      Misc.fatal_errorf "End of function without terminator for block %d"
        block.start
    end
  | Llabel start ->
    if !Print.verbose then begin
      Printf.printf "Llabel start=%d, block.start=%d\n" start block.start
    end;
    (* Labels always cause a new block to be created.  If the block prior
       to the label falls through, an explicit successor edge is added. *)
    if not (block_is_registered t block) then begin
      let fallthrough : C.terminator = Branch [Always, start] in
      block.terminator <- create_empty_instruction fallthrough ~trap_depth;
      register_block t block
    end;
    (* CR-soon gyorsh: check for multiple consecutive labels *)
    record_trap_depth_at_label t start ~trap_depth;
    let new_block = create_empty_block t start in
    create_blocks t i.next new_block ~trap_depth
  | Lop (Itailcall_ind { label_after; }) ->
    let desc = C.Tailcall (Func (Indirect { label_after; })) in
    add_terminator t block i desc ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Lop (Itailcall_imm { func = func_symbol; label_after; }) ->
    let desc =
      if String.equal func_symbol (C.fun_name t.cfg) then
        C.Tailcall (Self { label_after; })
      else
        C.Tailcall (Func (Direct { func_symbol; label_after; }))
    in
    add_terminator t block i desc ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Lreturn ->
    if trap_depth <> 0 then begin
      Misc.fatal_errorf "Trap depth must be zero at Lreturn"
    end;
    add_terminator t block i Return ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Lraise kind ->
    add_terminator t block i (Raise kind) ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Lbranch lbl ->
    if !Print.verbose then begin
      Printf.printf "Lbranch %d\n" lbl
    end;
    add_terminator t block i (Branch [Always, lbl]) ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Lcondbranch (cond, lbl) ->
    (* CR-soon gyorsh: merge (Lbranch | Lcondbranch | Lcondbranch3)+ into
       a single terminator when the argments are the same. Enables
       reordering of branch instructions and save cmp instructions. The
       main problem is that it involves boolean combination of
       conditionals of type Mach.test that can arise from a sequence of
       branches. When all conditions in the combination are integer
       comparisons, we can simplify them into a single condition, but it
       doesn't work for Ieventest and Ioddtest (which come from the
       primitive "is integer"). The advantage is that it will enable us to
       reorder branch instructions to avoid generating jmp to fallthrough
       location in the new order. Also, for linear to cfg and back will be
       harder to generate exactly the same layout. Also, how do we map
       execution counts about branches onto this terminator? *)
    let fallthrough = get_or_make_label t i.next in
    add_terminator t block i (Branch [
        Test cond, lbl;
        Test (L.invert_test cond), fallthrough.label;
      ]) ~trap_depth;
    create_blocks t fallthrough.insn block ~trap_depth
  | Lcondbranch3 (lbl0, lbl1, lbl2) ->
    let fallthrough = get_or_make_label t i.next in
    let get_dest lbl = Option.value lbl ~default:fallthrough.label in
    let s0 = (C.Test (Iinttest_imm (Iunsigned Clt, 1)), get_dest lbl0) in
    let s1 = (C.Test (Iinttest_imm (Iunsigned Ceq, 1)), get_dest lbl1) in
    let s2 = (C.Test (Iinttest_imm (Iunsigned Cgt, 1)), get_dest lbl2) in
    add_terminator t block i (Branch [s0; s1; s2]) ~trap_depth;
    create_blocks t fallthrough.insn block ~trap_depth
  | Lswitch labels ->
    (* CR-soon gyorsh: get rid of switches entirely and re-generate them
       based on optimization and perf data? *)
    add_terminator t block i (Switch labels) ~trap_depth;
    create_blocks t i.next block ~trap_depth
  | Ladjust_trap_depth { delta_traps; } ->
    (* We do not emit any executable code for this insn; it only moves the
       virtual stack pointer in the emitter. We do not have a corresponding
       insn in [Cfg] because the required adjustment can change when blocks
       are reordered. Instead we regenerate the instructions when converting
       back to linear. We use [delta_traps] only to compute [trap_depth]s of
       other instructions. *)
    let trap_depth = trap_depth + delta_traps in
    if trap_depth < 0 then begin
      Misc.fatal_errorf "Ladjust_trap_depth %d moves the trap depth below \
          zero: %d"
        delta_traps trap_depth
    end;
    create_blocks t i.next block ~trap_depth
  | Lpushtrap { lbl_handler; } ->
    mark_trap_label t ~lbl_handler ~lbl_pushtrap_block:block.start;
    record_trap_depth_at_label t lbl_handler ~trap_depth;
    let desc = C.Pushtrap { lbl_handler; } in
    block.body <- (create_instruction desc ~trap_depth i) :: block.body;
    let trap_depth = trap_depth + 1 in
    create_blocks t i.next block ~trap_depth
  | Lpoptrap ->
    let desc = C.Poptrap in
    block.body <- (create_instruction desc ~trap_depth i) :: block.body;
    let trap_depth = trap_depth - 1 in
    if trap_depth < 0 then begin
      Misc.fatal_error "Lpoptrap moves the trap depth below zero"
    end;
    create_blocks t i.next block ~trap_depth
  | desc ->
    let desc : C.basic =
      match desc with
      | Lprologue -> Prologue
      | Lentertrap -> Entertrap
      | Lreloadretaddr -> Reloadretaddr
      | Lop op ->
        begin match op with
        | Icall_ind { label_after; } ->
          Call (F (Indirect { label_after; }))
        | Icall_imm { func; label_after; } ->
          Call (F (Direct { func_symbol = func; label_after; }))
        | Iextcall { func; alloc; label_after; } ->
          Call (P (External { func_symbol = func; alloc; label_after; }))
        | Iintop (Icheckbound { label_after_error; spacetime_index; }) ->
          Call (P (Checkbound {
            immediate = None;
            label_after_error;
            spacetime_index;
          }))
        | Iintop op -> Op (Intop op)
        | Iintop_imm (Icheckbound { label_after_error; spacetime_index; }, i) ->
          Call (P (Checkbound {
            immediate = Some i;
            label_after_error;
            spacetime_index;
          }))
        | Iintop_imm (op, i) -> Op (Intop_imm (op, i))
        | Ialloc { bytes; label_after_call_gc; spacetime_index; } ->
          Call (P (Alloc { bytes; label_after_call_gc; spacetime_index; }))
        | Istackoffset i -> Op (Stackoffset i)
        | Iload (c, a) -> Op (Load (c, a))
        | Istore (c, a, b) -> Op (Store (c, a, b))
        | Imove -> Op Move
        | Ispill -> Op Spill
        | Ireload -> Op Reload
        | Iconst_int n -> Op (Const_int n)
        | Iconst_float n -> Op (Const_float n)
        | Iconst_symbol n -> Op (Const_symbol n)
        | Inegf -> Op Negf
        | Iabsf -> Op Absf
        | Iaddf -> Op Addf
        | Isubf -> Op Subf
        | Imulf -> Op Mulf
        | Idivf -> Op Divf
        | Ifloatofint -> Op Floatofint
        | Iintoffloat -> Op Intoffloat
        | Ispecific op -> Op (Specific op)
        | Iname_for_debugger
            { ident; which_parameter; provenance; is_assignment; } ->
          Op (Name_for_debugger
            { ident; which_parameter; provenance; is_assignment; })
        | Itailcall_ind _ | Itailcall_imm _ -> assert false
        end
      | Lend | Lreturn | Llabel _ | Lbranch _
      | Lcondbranch (_, _) | Lcondbranch3 (_, _, _) | Lswitch _ | Lraise _
      | Ladjust_trap_depth _ | Lpoptrap | Lpushtrap _ -> assert false
    in
    block.body <- (create_instruction desc i ~trap_depth) :: block.body;
    create_blocks t i.next block ~trap_depth

let compute_id_to_label t =
  let fold_block id_to_label label =
    let block = Label.Tbl.find t.cfg.blocks label in
    let id_to_label =
      List.fold_left (fun id_to_label (i : _ C.instruction) ->
          Numbers.Int.Map.add i.id label id_to_label)
        id_to_label block.body
    in
    Numbers.Int.Map.add block.terminator.id label id_to_label
  in
  t.id_to_label <- List.fold_left fold_block Numbers.Int.Map.empty t.layout

let run (f : Linear.fundecl) ~preserve_orig_labels =
  let t =
    let cfg =
      Cfg.create ~fun_name:f.fun_name
        ~fun_tailrec_entry_point_label:f.fun_tailrec_entry_point_label
    in
    { cfg;
      trap_labels = Label.Tbl.create 7;
      trap_depths = Label.Tbl.create 31;
      new_labels = Label.Set.empty;
      id_to_label = Numbers.Int.Map.empty;
      layout = [];
      preserve_orig_labels;
    }
  in
  (* CR-soon gyorsh: label of the function entry must not conflict with
     existing labels. Relies on the invariant: Cmm.new_label() is int > 99.
     An alternative is to create a new type for label here, but it is less
     efficient because label is used as a key to Label.Tbl.
     mshinwell: I don't think a new type needs to cause any change in
     efficiency.  A custom hashtable can be made with the appropriate
     hashing and equality functions. *)
  (* CR mshinwell: Why is the magic number 99? *)
  let entry_block = create_empty_block t t.cfg.entry_label in
  last_linear_id := entry_id;
  create_blocks t f.fun_body entry_block ~trap_depth:0;
  (* Register predecessors now rather than during cfg construction, because
     of forward jumps: the blocks do not exist when the jump that reference
     them is processed. *)
  (* CR-soon gyorsh: combine with dead block elimination. *)
  register_predecessors_for_all_blocks t;
  compute_id_to_label t;
  (* Layout was constructed in reverse, fix it now: *)
  t.layout <- List.rev t.layout;
  Cfg_with_layout.create t.cfg ~layout:t.layout ~trap_depths:t.trap_depths
    ~trap_labels:t.trap_labels ~preserve_orig_labels:t.preserve_orig_labels
    ~new_labels:t.new_labels