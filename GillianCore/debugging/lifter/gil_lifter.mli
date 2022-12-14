(** A basic "GIL-to-GIL" lifter implementation. *)

module Make
    (PC : ParserAndCompiler.S)
    (V : Verifier.S with type annot = PC.Annot.t)
    (SMemory : SMemory.S) :
  Lifter.S
    with type memory = SMemory.t
     and type tl_ast = PC.tl_ast
     and type memory_error = SMemory.err_t
     and type cmd_report = V.SAInterpreter.Logging.ConfigReport.t
     and type annot = PC.Annot.t
