(********************************************************************)
(*                                                                  *)
(*  The LustreC compiler toolset   /  The LustreC Development Team  *)
(*  Copyright 2012 -    --   ONERA - CNRS - INPT                    *)
(*                                                                  *)
(*  LustreC is free software, distributed WITHOUT ANY WARRANTY      *)
(*  under the terms of the GNU Lesser General Public License        *)
(*  version 2.1.                                                    *)
(*                                                                  *)
(********************************************************************)

(* The compilation presented here was first defined in Garoche, Gurfinkel,
   Kahsai, HCSV'14.

   This is a modified version that handle reset
*)

open Format
open LustreSpec
open Corelang
open Machine_code

open Horn_backend_common
open Types

(********************************************************************************************)
(*                    Instruction Printing functions                                        *)
(********************************************************************************************)

let pp_horn_var m fmt id =
  (*if Types.is_array_type id.var_type
  then
    assert false (* no arrays in Horn output *)
  else*)
    fprintf fmt "%s" id.var_id

(* Used to print boolean constants *)
let pp_horn_tag fmt t =
  pp_print_string fmt (if t = tag_true then "true" else if t = tag_false then "false" else t)

(* Prints a constant value *)
let rec pp_horn_const fmt c =
  match c with
    | Const_int i    -> pp_print_int fmt i
    | Const_real (_,_,s)   -> pp_print_string fmt s
    | Const_tag t    -> pp_horn_tag fmt t
    | _              -> assert false

let rec get_type_cst c =
  match c with
  | Const_int(n) -> new_ty Tint
  | Const_real(x) -> new_ty Treal
  | Const_float(f) -> new_ty Treal
  | Const_array(l) -> new_ty (Tarray(Dimension.mkdim_int (Location.dummy_loc) (List.length l), get_type_cst (List.hd l)))
  | Const_tag(tag) -> new_ty Tbool
  | Const_string(str) ->  assert false(* used only for annotations *)
  | Const_struct(l) -> new_ty (Tstruct(List.map (fun (label, t) -> (label, get_type_cst t)) l))

let rec get_type v = 
  match v with
  | Cst c -> get_type_cst c             
  | Access(tab, index) -> begin
                           let rec remove_link ltype = match (dynamic_type ltype).tdesc with 
                             | Tlink t -> t
                             | _ -> ltype
                           in
                            match (dynamic_type (remove_link (get_type tab))).tdesc with
                            | Tarray(size, t) -> remove_link t
                            | Tvar -> Format.eprintf "Type of access is a variable... "; assert false
                            | Tunivar -> Format.eprintf "Type of access is a variable... "; assert false
                            | _ -> Format.eprintf "Type of access is not an array "; assert false
                          end
  | Power(v, n) -> assert false
  | LocalVar v -> v.var_type
  | StateVar v -> v.var_type
  | Fun(n, vl) -> begin match n with
                  | "+" 
                  | "-" 
                  | "*" -> get_type (List.hd vl)
                  | _ -> Format.eprintf "Function undealt with : %s" n ;assert false
                  end
  | Array(l) -> new_ty (Tarray(Dimension.mkdim_int (Location.dummy_loc) (List.length l), get_type (List.hd l)))
  | _ -> assert false


let rec default_val fmt t =
  match (dynamic_type t).tdesc with
  | Tint -> fprintf fmt "0"
  | Treal -> fprintf fmt "0"
  | Tbool -> fprintf fmt "true"
  | Tarray(dim, l) -> let valt = array_element_type t in
                      fprintf fmt "((as const (Array Int ";
                      begin try
                        pp_type fmt valt
                      with
                      | _ -> fprintf fmt "failed"; end;
                      fprintf fmt ")) ";
                      begin try
                        default_val fmt valt
                      with
                      | _ -> fprintf fmt "failed"; end;
                      fprintf fmt ")"
  | Tstruct(l) -> assert false
  | Ttuple(l) -> assert false
  |_ -> assert false


(* Prints a value expression [v], with internal function calls only.
   [pp_var] is a printer for variables (typically [pp_c_var_read]),
   but an offset suffix may be added for array variables
*)
let rec pp_horn_val ?(is_lhs=false) self pp_var fmt v =
  match v.value_desc with
    | Cst c         -> pp_horn_const fmt c
    | Array initlist       -> (*Format.fprintf err_formatter "init %a" (pp_horn_val ~is_lhs:is_lhs self pp_var) (List.hd initlist);*)
                              let rec print tab x =
                                match tab with
                                | [] -> default_val fmt (get_type v)(*fprintf fmt "YAY"*)
                                | h::t -> fprintf fmt "(store "; print t (x+1); fprintf fmt " %i " x; pp_horn_val ~is_lhs:is_lhs self pp_var fmt h; fprintf fmt ")" 
                              in
                              print initlist 0
    | Access(tab,index)      -> fprintf fmt "(select "; pp_horn_val ~is_lhs:is_lhs self pp_var fmt tab; fprintf fmt " "; pp_horn_val ~is_lhs:is_lhs self pp_var fmt index; fprintf fmt ")"
    | Power (v, n)  -> assert false
    | LocalVar v    -> pp_var fmt (rename_machine self v)
    | StateVar v    ->
      if Types.is_array_type v.var_type
      then begin assert false; eprintf "toto called\n";fprintf fmt "TOTO" end
      else pp_var fmt (rename_machine self ((if is_lhs then rename_next else rename_current) (* self *) v))
    | Fun (n, vl)   -> fprintf fmt "%a" (Basic_library.pp_horn n (pp_horn_val self pp_var)) vl

(* Prints a [value] indexed by the suffix list [loop_vars] *)
let rec pp_value_suffix self pp_value fmt value =
 match value.value_desc with
 | Fun (n, vl)  ->
   Basic_library.pp_horn n (pp_value_suffix self pp_value) fmt vl
 |  _            ->
   pp_horn_val self pp_value fmt value

(* type_directed assignment: array vs. statically sized type
   - [var_type]: type of variable to be assigned
   - [var_name]: name of variable to be assigned
   - [value]: assigned value
   - [pp_var]: printer for variables
*)
let pp_assign m pp_var fmt var_name value =
  let self = m.mname.node_id in
  fprintf fmt "(= %a %a)"
    (pp_horn_val ~is_lhs:true self pp_var) var_name
    (pp_value_suffix self pp_var) value


(* In case of no reset call, we define mid_mem = current_mem *)
let pp_no_reset machines m fmt i =
  let (n,_) = List.assoc i m.minstances in
  let target_machine = List.find (fun m  -> m.mname.node_id = (node_name n)) machines in

  let m_list =
    rename_machine_list
      (concat m.mname.node_id i)
      (rename_mid_list (full_memory_vars machines target_machine))
  in
  let c_list =
    rename_machine_list
      (concat m.mname.node_id i)
      (rename_current_list (full_memory_vars machines target_machine))
  in
  match c_list, m_list with
  | [chd], [mhd] ->
    fprintf fmt "(= %a %a)"
      (pp_horn_var m) mhd
      (pp_horn_var m) chd

  | _ -> (
    fprintf fmt "@[<v 0>(and @[<v 0>";
    List.iter2 (fun mhd chd ->
      fprintf fmt "(= %a %a)@ "
      (pp_horn_var m) mhd
      (pp_horn_var m) chd
    )
      m_list
      c_list      ;
    fprintf fmt ")@]@ @]"
  )

let pp_instance_reset machines m fmt i =
  let (n,_) = List.assoc i m.minstances in
  let target_machine = List.find (fun m  -> m.mname.node_id = (node_name n)) machines in

  fprintf fmt "(%a @[<v 0>%a)@]"
    pp_machine_reset_name (node_name n)
    (Utils.fprintf_list ~sep:"@ " (pp_horn_var m))
    (
      (rename_machine_list
	 (concat m.mname.node_id i)
	 (rename_current_list (full_memory_vars machines target_machine))
      )
      @
	(rename_machine_list
	   (concat m.mname.node_id i)
	   (rename_mid_list (full_memory_vars machines target_machine))
	)
    )

let pp_instance_call machines reset_instances m fmt i inputs outputs =
  let self = m.mname.node_id in
  try (* stateful node instance *)
    begin
      let (n,_) = List.assoc i m.minstances in
      let target_machine = List.find (fun m  -> m.mname.node_id = node_name n) machines in
      (* Checking whether this specific instances has been reset yet *)
      if not (List.mem i reset_instances) then
	(* If not, declare mem_m = mem_c *)
	pp_no_reset machines m fmt i;

      let mems = full_memory_vars machines target_machine in
      let rename_mems f = rename_machine_list (concat m.mname.node_id i) (f mems) in
      let mid_mems = rename_mems rename_mid_list in
      let next_mems = rename_mems rename_next_list in

      match node_name n, inputs, outputs, mid_mems, next_mems with
      | "_arrow", [i1; i2], [o], [mem_m], [mem_x] -> begin
	fprintf fmt "@[<v 5>(and ";
	fprintf fmt "(= %a (ite %a %a %a))"
	  (pp_horn_val ~is_lhs:true self (pp_horn_var m)) (mk_val (LocalVar o) o.var_type) (* output var *)
	  (pp_horn_var m) mem_m
	  (pp_horn_val self (pp_horn_var m)) i1
	  (pp_horn_val self (pp_horn_var m)) i2
	;
	fprintf fmt "@ ";
	fprintf fmt "(= %a false)" (pp_horn_var m) mem_x;
	fprintf fmt ")@]"
      end

      | node_name_n -> begin
	fprintf fmt "(%a @[<v 0>%a%t%a%t%a)@]"
	  pp_machine_step_name (node_name n)
	  (Utils.fprintf_list ~sep:"@ " (pp_horn_val self (pp_horn_var m))) inputs
	  (Utils.pp_final_char_if_non_empty "@ " inputs)
	  (Utils.fprintf_list ~sep:"@ " (pp_horn_val self (pp_horn_var m)))
	  (List.map (fun v -> mk_val (LocalVar v) v.var_type) outputs)
	  (Utils.pp_final_char_if_non_empty "@ " outputs)
	  (Utils.fprintf_list ~sep:"@ " (pp_horn_var m)) (mid_mems@next_mems)

      end
    end
  with Not_found -> ( (* stateless node instance *)
    let (n,_) = List.assoc i m.mcalls in
    fprintf fmt "(%s @[<v 0>%a%t%a)@]"
      (node_name n)
      (Utils.fprintf_list ~sep:"@ " (pp_horn_val self (pp_horn_var m)))
      inputs
      (Utils.pp_final_char_if_non_empty "@ " inputs)
      (Utils.fprintf_list ~sep:"@ " (pp_horn_val self (pp_horn_var m)))
      (List.map (fun v -> mk_val (LocalVar v) v.var_type) outputs)
  )


(* Print the instruction and update the set of reset instances *)
let rec pp_machine_instr machines reset_instances (m: machine_t) fmt instr : ident list =
  match instr with
  | MComment _ -> reset_instances
  | MNoReset i -> (* we assign middle_mem with mem_m. And declare i as reset *)
    pp_no_reset machines m fmt i;
    i::reset_instances
  | MReset i -> (* we assign middle_mem with reset: reset(mem_m) *)
    pp_instance_reset machines m fmt i;
    i::reset_instances
  | MLocalAssign (i,v) ->
    pp_assign
      m (pp_horn_var m) fmt
      (mk_val (LocalVar i) i.var_type) v;
    reset_instances
  | MStateAssign (i,v) ->
    pp_assign
      m (pp_horn_var m) fmt
      (mk_val (StateVar i) i.var_type) v;
    reset_instances
  | MStep ([i0], i, vl) when Basic_library.is_internal_fun i (List.map (fun v -> v.value_type) vl) ->
    assert false (* This should not happen anymore *)
  | MStep (il, i, vl) ->
    (* if reset instance, just print the call over mem_m , otherwise declare mem_m =
       mem_c and print the call to mem_m *)
    pp_instance_call machines reset_instances m fmt i vl il;
    reset_instances (* Since this instance call will only happen once, we
		       don't have to update reset_instances *)

  | MBranch (g,hl) -> (* (g = tag1 => expr1) and (g = tag2 => expr2) ...
			 should not be produced yet. Later, we will have to
			 compare the reset_instances of each branch and
			 introduced the mem_m = mem_c for branches to do not
			 address it while other did. Am I clear ? *)
    (* For each branch we obtain the logical encoding, and the information
       whether a sub node has been reset or not. If a node has been reset in one
       of the branch, then all others have to have the mem_m = mem_c
       statement. *)
    let self = m.mname.node_id in
    let pp_branch fmt (tag, instrs) =
      fprintf fmt
	"@[<v 3>(or (not (= %a %s))@ "
	(*"@[<v 3>(=> (= %a %s)@ "*)  (* Issues with some versions of Z3. It
					  seems that => within Horn predicate
					  may cause trouble. I have hard time
					  producing a MWE, so I'll just keep the
					  fix here as (not a) or b *)
	(pp_horn_val self (pp_horn_var m)) g
	tag;
      let rs = pp_machine_instrs machines reset_instances m fmt instrs in
      fprintf fmt "@])";
      () (* rs *)
    in
    pp_conj pp_branch fmt hl;
    reset_instances

and pp_machine_instrs machines reset_instances m fmt instrs =
  let ppi rs fmt i = pp_machine_instr machines rs m fmt i in
  match instrs with
  | [x] -> ppi reset_instances fmt x
  | _::_ ->
    fprintf fmt "(and @[<v 0>";
    let rs = List.fold_left (fun rs i ->
      let rs = ppi rs fmt i in
      fprintf fmt "@ ";
      rs
    )
      reset_instances instrs
    in
    fprintf fmt "@])";
    rs

  | [] -> fprintf fmt "true"; reset_instances

let pp_machine_reset machines fmt m =
  let locals = local_memory_vars machines m in
  fprintf fmt "@[<v 5>(and @ ";

  (* print "x_m = x_c" for each local memory *)
  (Utils.fprintf_list ~sep:"@ " (fun fmt v ->
    fprintf fmt "(= %a %a)"
      (pp_horn_var m) (rename_mid v)
      (pp_horn_var m) (rename_current v)
   )) fmt locals;
  fprintf fmt "@ ";

  (* print "child_reset ( associated vars _ {c,m} )" for each subnode.
     Special treatment for _arrow: _first = true
  *)
  (Utils.fprintf_list ~sep:"@ " (fun fmt (id, (n, _)) ->
    let name = node_name n in
    if name = "_arrow" then (
      fprintf fmt "(= %s._arrow._first_m true)"
	(concat m.mname.node_id id)
    ) else (
      let machine_n = get_machine machines name in
      fprintf fmt "(%s_reset @[<hov 0>%a@])"
	name
	(Utils.fprintf_list ~sep:"@ " (pp_horn_var m))
	(rename_machine_list (concat m.mname.node_id id) (reset_vars machines machine_n))
    )
   )) fmt m.minstances;

  fprintf fmt "@]@ )"



(**************************************************************)

let is_stateless m = m.minstances = [] && m.mmemory = []

(* Print the machine m:
   two functions: m_init and m_step
   - m_init is a predicate over m memories
   - m_step is a predicate over old_memories, inputs, new_memories, outputs
   We first declare all variables then the two /rules/.
*)
let print_machine machines fmt m =
  if m.mname.node_id = arrow_id then
    (* We don't print arrow function *)
    ()
  else
    begin
      fprintf fmt "; %s@." m.mname.node_id;

      (* Printing variables *)
      Utils.fprintf_list ~sep:"@." pp_decl_var fmt
	(
	  (inout_vars machines m)@
	    (rename_current_list (full_memory_vars machines m)) @
	    (rename_mid_list (full_memory_vars machines m)) @
	    (rename_next_list (full_memory_vars machines m)) @
	    (rename_machine_list m.mname.node_id m.mstep.step_locals)
	);
      pp_print_newline fmt ();

      if is_stateless m then
	begin
	  (* Declaring single predicate *)
	  fprintf fmt "(declare-rel %a (%a))@."
	    pp_machine_stateless_name m.mname.node_id
	    (Utils.fprintf_list ~sep:" " pp_type)
	    (List.map (fun v -> v.var_type) (inout_vars machines m));

	  (* Rule for single predicate *)
	  fprintf fmt "@[<v 2>(rule (=> @ ";
	  ignore (pp_machine_instrs machines ([] (* No reset info for stateless nodes *) )  m fmt m.mstep.step_instrs);
	  fprintf fmt "@ (%a %a)@]@.))@.@."
	    pp_machine_stateless_name m.mname.node_id
	    (Utils.fprintf_list ~sep:" " (pp_horn_var m)) (inout_vars machines m);
	end
      else
	begin
	  (* Declaring predicate *)
	  fprintf fmt "(declare-rel %a (%a))@."
	    pp_machine_reset_name m.mname.node_id
	    (Utils.fprintf_list ~sep:" " pp_type)
	    (List.map (fun v -> v.var_type) (reset_vars machines m));

	  fprintf fmt "(declare-rel %a (%a))@."
	    pp_machine_step_name m.mname.node_id
	    (Utils.fprintf_list ~sep:" " pp_type)
	    (List.map (fun v -> v.var_type) (step_vars machines m));

	  pp_print_newline fmt ();

	  (* Rule for reset *)
	  fprintf fmt "@[<v 2>(rule (=> @ %a@ (%a @[<v 0>%a)@]@]@.))@.@."
	    (pp_machine_reset machines) m
	    pp_machine_reset_name m.mname.node_id
	    (Utils.fprintf_list ~sep:"@ " (pp_horn_var m)) (reset_vars machines m);

          match m.mstep.step_asserts with
	  | [] ->
	    begin

	      (* Rule for step*)
	      fprintf fmt "@[<v 2>(rule (=> @ ";
	      ignore (pp_machine_instrs machines [] m fmt m.mstep.step_instrs);
	      fprintf fmt "@ (%a @[<v 0>%a)@]@]@.))@.@."
		pp_machine_step_name m.mname.node_id
		(Utils.fprintf_list ~sep:"@ " (pp_horn_var m)) (step_vars machines m);
	    end
	  | assertsl ->
	    begin
	      let pp_val = pp_horn_val ~is_lhs:true m.mname.node_id (pp_horn_var m) in
	      (* print_string pp_val; *)
	      fprintf fmt "; with Assertions @.";

	      (*Rule for step*)
	      fprintf fmt "@[<v 2>(rule (=> @ (and @ ";
	      ignore (pp_machine_instrs machines [] m fmt m.mstep.step_instrs);
	      fprintf fmt "@. %a)(%a @[<v 0>%a)@]@]@.))@.@." (pp_conj pp_val) assertsl
		pp_machine_step_name m.mname.node_id
		(Utils.fprintf_list ~sep:" " (pp_horn_var m)) (step_vars machines m);
	    end


	end
    end


let mk_flags arity =
 let b_range =
   let rec range i j =
     if i > arity then [] else i :: (range (i+1) j) in
   range 2 arity;
 in
 List.fold_left (fun acc x -> acc ^ " false") "true" b_range


  (*Get sfunction infos from command line*)
let get_sf_info() =
  let splitted = Str.split (Str.regexp "@") !Options.sfunction in
  Log.report ~level:1 (fun fmt -> fprintf fmt ".. sfunction name: %s@," !Options.sfunction);
  let sf_name, flags, arity = match splitted with
      [h;flg;par] -> h, flg, par
    | _ -> failwith "Wrong Sfunction info"

  in
  Log.report ~level:1 (fun fmt -> fprintf fmt "... sf_name: %s@, .. flags: %s@ .. arity: %s@," sf_name flags arity);
  sf_name, flags, arity


    (*a function to print the rules in case we have an s-function*)
  let print_sfunction machines fmt m =
      if m.mname.node_id = arrow_id then
        (* We don't print arrow function *)
        ()
      else
        begin
          Format.fprintf fmt "; SFUNCTION@.";
          Format.fprintf fmt "; %s@." m.mname.node_id;
          Format.fprintf fmt "; EndPoint Predicate %s." !Options.sfunction;

          (* Check if there is annotation for s-function *)
          if m.mannot != [] then(
              Format.fprintf fmt "; @[%a@]@]@\n" (Utils.fprintf_list ~sep:"@ " Printers.pp_s_function) m.mannot;
            );

       (* Printing variables *)
          Utils.fprintf_list ~sep:"@." pp_decl_var fmt
                             ((step_vars machines m)@
    	                        (rename_machine_list m.mname.node_id m.mstep.step_locals));
          Format.pp_print_newline fmt ();
          let sf_name, flags, arity = get_sf_info() in

       if is_stateless m then
         begin
           (* Declaring single predicate *)
           Format.fprintf fmt "(declare-rel %a (%a))@."
    	                  pp_machine_stateless_name m.mname.node_id
    	                  (Utils.fprintf_list ~sep:" " pp_type)
    	                  (List.map (fun v -> v.var_type) (reset_vars machines m));
           Format.pp_print_newline fmt ();
           (* Rule for single predicate *)
           let str_flags = sf_name ^ " " ^ mk_flags (int_of_string flags) in
           Format.fprintf fmt "@[<v 2>(rule (=> @ (%s %a) (%a %a)@]@.))@.@."
                          str_flags
                          (Utils.fprintf_list ~sep:" " (pp_horn_var m)) (reset_vars machines m)
	                  pp_machine_stateless_name m.mname.node_id
	                  (Utils.fprintf_list ~sep:" " (pp_horn_var m)) (reset_vars machines m);
         end
      else
         begin
           (* Declaring predicate *)
           Format.fprintf fmt "(declare-rel %a (%a))@."
    	                  pp_machine_reset_name m.mname.node_id
    	                  (Utils.fprintf_list ~sep:" " pp_type)
    	                  (List.map (fun v -> v.var_type) (inout_vars machines m));

           Format.fprintf fmt "(declare-rel %a (%a))@."
    	                  pp_machine_step_name m.mname.node_id
    	                  (Utils.fprintf_list ~sep:" " pp_type)
    	                  (List.map (fun v -> v.var_type) (step_vars machines m));

           Format.pp_print_newline fmt ();
          (* Adding assertions *)
           match m.mstep.step_asserts with
	  | [] ->
	    begin

	      (* Rule for step*)
	      fprintf fmt "@[<v 2>(rule (=> @ ";
	      ignore (pp_machine_instrs machines [] m fmt m.mstep.step_instrs);
	      fprintf fmt "@ (%a @[<v 0>%a)@]@]@.))@.@."
		pp_machine_step_name m.mname.node_id
		(Utils.fprintf_list ~sep:"@ " (pp_horn_var m)) (step_vars machines m);
	    end
	  | assertsl ->
	    begin
	      let pp_val = pp_horn_val ~is_lhs:true m.mname.node_id (pp_horn_var m) in
	      (* print_string pp_val; *)
	      fprintf fmt "; with Assertions @.";

	      (*Rule for step*)
	      fprintf fmt "@[<v 2>(rule (=> @ (and @ ";
	      ignore (pp_machine_instrs machines [] m fmt m.mstep.step_instrs);
	      fprintf fmt "@. %a)(%a @[<v 0>%a)@]@]@.))@.@." (pp_conj pp_val) assertsl
		pp_machine_step_name m.mname.node_id
		(Utils.fprintf_list ~sep:" " (pp_horn_var m)) (step_vars machines m);
	    end

         end

        end
(* Local Variables: *)
(* compile-command:"make -C ../../.." *)
(* End: *)
