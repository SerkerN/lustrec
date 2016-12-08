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

open Format
(********************************************************************************************)
(*                         Translation function                                             *)
(********************************************************************************************)
(* USELESS
let makefile_opt print basename dependencies makefile_fmt machines =
  (* If a main node is identified, generate a main target for it *)
  match !Options.main_node with
  | "" ->  ()
  | main_node -> (
    match Machine_code.get_machine_opt main_node machines with
    | None -> Format.eprintf "Unable to find a main node named %s@.@?" main_node; ()
    | Some _ -> print basename !Options.main_node dependencies makefile_fmt
  )
*)

let gen_files funs basename prog machines dependencies =
  let destname = !Options.dest_dir ^ "/" ^ basename in
  let source_main_file = destname ^ "_main.c" in (* Could be changed *)
  let makefile_file = destname ^ ".makefile" in (* Could be changed *)
  
  let print_header, print_lib_c, print_main_c, print_makefile = funs in

  (* Generating H file *)
  let alloc_header_file = destname ^ "_alloc.h" in (* Could be changed *)
  let header_out = open_out alloc_header_file in
  let header_fmt = formatter_of_out_channel header_out in
  print_header header_fmt basename prog machines dependencies;
  close_out header_out;
  
  (* Generating Lib C file *)
  let source_lib_file = destname ^ ".c" in (* Could be changed *)
  let source_lib_out = open_out source_lib_file in
  let source_lib_fmt = formatter_of_out_channel source_lib_out in
  print_lib_c source_lib_fmt basename prog machines dependencies;
  close_out source_lib_out;

  match !Options.main_node with
  | "" ->  () (* No main node: we do not generate main nor makefile *)
  | main_node -> (
    match Machine_code.get_machine_opt main_node machines with
    | None -> begin
      Global.main_node := main_node;
      Format.eprintf "Code generation error: %a@." Corelang.pp_error LustreSpec.Main_not_found;
      raise (Corelang.Error (Location.dummy_loc, LustreSpec.Main_not_found))
    end
    | Some m -> begin
      let source_main_out = open_out source_main_file in
      let source_main_fmt = formatter_of_out_channel source_main_out in
      let makefile_out = open_out makefile_file in
      let makefile_fmt = formatter_of_out_channel makefile_out in

      (* Generating Main C file *)
      print_main_c source_main_fmt m basename prog machines dependencies;
      
      (* Generating Makefile *)
      print_makefile basename main_node dependencies makefile_fmt;

     close_out source_main_out;
     close_out makefile_out

    end
  )

let translate_to_c basename prog machines dependencies =
  match !Options.spec with
  | "no" -> begin
    let module HeaderMod = C_backend_header.EmptyMod in
    let module SourceMod = C_backend_src.EmptyMod in
    let module SourceMainMod = C_backend_main.EmptyMod in
    let module MakefileMod = C_backend_makefile.EmptyMod in

    let module Header = C_backend_header.Main (HeaderMod) in
    let module Source = C_backend_src.Main (SourceMod) in
    let module SourceMain = C_backend_main.Main (SourceMainMod) in
    let module Makefile = C_backend_makefile.Main (MakefileMod) in

    let funs = 
      Header.print_alloc_header, 
      Source.print_lib_c, 
      SourceMain.print_main_c, 
      Makefile.print_makefile 
    in
    gen_files funs basename prog machines dependencies 

  end
  | "acsl" -> begin

    let module HeaderMod = C_backend_header.EmptyMod in
    let module SourceMod = C_backend_src.EmptyMod in
    let module SourceMainMod = C_backend_main.EmptyMod in
    let module MakefileMod = C_backend_spec.MakefileMod in

    let module Header = C_backend_header.Main (HeaderMod) in
    let module Source = C_backend_src.Main (SourceMod) in
    let module SourceMain = C_backend_main.Main (SourceMainMod) in
    let module Makefile = C_backend_makefile.Main (MakefileMod) in

    let funs = 
      Header.print_alloc_header, 
      Source.print_lib_c,
      SourceMain.print_main_c,
      Makefile.print_makefile 
    in
    gen_files funs basename prog machines dependencies 

  end
  | "c" -> begin
    assert false (* not implemented yet *)
  end
  | _ -> assert false
(* Local Variables: *)
(* compile-command:"make -C ../../.." *)
(* End: *)
