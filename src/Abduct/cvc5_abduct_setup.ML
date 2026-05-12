(*  Custom cvc5 configuration for abduct examples *)

structure Abduct_CVC5_Abduct =
struct

val abduct_tag = "abduct_goal"
val mepoN = "mepo"
val meshN = "mesh"

fun extend_class cs = cs @ [abduct_tag]

fun smtlib_base_config order ctxt = SMTLIB_Interface.translate_config order ctxt

fun cvc_base_config order ctxt = {
  order = order,
  logic = K (K "(set-logic ALL_SUPPORTED)\n"),
  fp_kinds = [BNF_Util.Least_FP, BNF_Util.Greatest_FP],
  serialize = #serialize (SMTLIB_Interface.translate_config order ctxt)}

val smtlib_abductC = extend_class SMTLIB_Interface.smtlibC
val hosmtlib_abductC = extend_class SMTLIB_Interface.hosmtlibC
val bvsmlib_abductC = extend_class SMTLIB_Interface.bvsmlibC
val smtlib_cvc_abductC = extend_class CVC_Interface.smtlib_cvcC
val hosmtlib_cvc_abductC = extend_class CVC_Interface.hosmtlib_cvcC

val _ = Theory.setup (Context.theory_map
  (SMT_Translate.add_config (smtlib_abductC, smtlib_base_config SMT_Util.First_Order) #>
   SMT_Translate.add_config (hosmtlib_abductC, smtlib_base_config SMT_Util.Higher_Order) #>
   SMT_Translate.add_config (bvsmlib_abductC, smtlib_base_config SMT_Util.First_Order) #>
   SMT_Translate.add_config (smtlib_cvc_abductC, cvc_base_config SMT_Util.First_Order) #>
   SMT_Translate.add_config (hosmtlib_cvc_abductC, cvc_base_config SMT_Util.Higher_Order)))

fun getenv_nonempty name =
  (case getenv name of
    "" => NONE
  | value => SOME value)

fun bundled_cvc5_path () = getenv "ISABELLE_HOME" ^ "/contrib/cvc5/bin/cvc5"

fun cvc5_candidates () =
  [("CVC5", getenv_nonempty "CVC5"),
   ("CVC5_HOME/bin/cvc5", Option.map (fn home => home ^ "/bin/cvc5") (getenv_nonempty "CVC5_HOME")),
   ("ISABELLE_HOME/contrib/cvc5/bin/cvc5", SOME (bundled_cvc5_path ())),
   ("PATH", SOME "cvc5")]
  |> map_filter (fn (source, SOME candidate) => SOME (source, candidate) | (_, NONE) => NONE)

fun resolve_executable candidate =
  if String.isSubstring "/" candidate then
    if File.is_file (Path.explode candidate) then SOME candidate else NONE
  else
    let
      val (output, rc) = Isabelle_System.bash_output ("command -v " ^ Bash.string candidate)
      val resolved =
        output
        |> String.tokens (fn c => c = #"\n" orelse c = #"\r")
        |> List.filter (fn line => line <> "")
    in
      if rc = 0 andalso not (null resolved) then SOME (hd resolved) else NONE
    end

fun cvc5_resolution_info () =
  map (fn (source, candidate) =>
    {source = source, candidate = candidate, resolved = resolve_executable candidate}) (cvc5_candidates ())

fun cvc5_resolved () =
  get_first (fn {source, candidate, resolved} =>
    Option.map (fn path => {source = source, candidate = candidate, path = path}) resolved)
    (cvc5_resolution_info ())

fun cvc5_available () = Option.isSome (cvc5_resolved ())

fun cvc5_path () =
  (case cvc5_resolved () of
    SOME {path, ...} => path
  | NONE => bundled_cvc5_path ())

fun cvc5_resolution_report () =
  let
    fun line_for {source, candidate, resolved} =
      "  " ^ source ^ ": " ^ candidate ^
      (case resolved of
        SOME path => " [found at " ^ path ^ "]"
      | NONE => " [missing]")
  in
    String.concatWith "\n" (map line_for (cvc5_resolution_info ()))
  end

fun cvc5_status_message () =
  case cvc5_resolved () of
    SOME {source, path, ...} =>
      "CVC5 available: true\n" ^
      "CVC5 path: " ^ path ^ "\n" ^
      "CVC5 source: " ^ source
  | NONE =>
      "CVC5 available: false\n" ^
      "CVC5 resolution attempts:\n" ^ cvc5_resolution_report ()

fun make_avail _ () = cvc5_available ()
fun make_command _ () = [cvc5_path ()]

fun infer_term ctxt t =
  let
    val needs_inferT = equal Term.dummyT orf Term.is_TVar
    val needs_infer = Term.exists_type (Term.exists_subtype needs_inferT)
  in
    if needs_infer t then singleton (Type_Infer_Context.infer_types_finished ctxt) t else t
  end

fun parse_abduct_term ctxt typs funs lines =
  let
    val candidate_lines =
      lines
      |> filter (fn s =>
          let
            val is_success =
              String.isPrefix "(success" s orelse String.isPrefix "success" s
          in
            s <> "" andalso not is_success
          end)
    fun try_parse _ [] = NONE
      | try_parse rev_acc (line :: rest) =
          let
            val rev_acc' = line :: rev_acc
            val acc = rev rev_acc'
          in
            (case Exn.capture SMTLIB.parse acc of
              Exn.Res tree => SOME tree
            | Exn.Exn _ => try_parse rev_acc' rest)
          end

    (* Sanitize names to avoid "Bad name" errors from internal/skolem names *)
    fun trim_name_suffix is_suffix s =
      if size s > 1 andalso is_suffix s then
        trim_name_suffix is_suffix (String.substring (s, 0, size s - 1))
      else s

    fun trim_trailing_underscores s =
      trim_name_suffix (fn name => String.isSuffix "_" name) s

    fun trim_safe_suffixes s =
      trim_name_suffix
        (fn name => String.isSuffix "_" name orelse String.isSuffix "$" name) s

    fun sanitize_name s = trim_trailing_underscores s

    fun aliases_of_name name =
      [name, trim_trailing_underscores name, trim_safe_suffixes name,
       trim_trailing_underscores (trim_safe_suffixes name)]
      |> distinct (op =)

    fun add_alias alias value table =
      if is_some (Symtab.lookup table alias) then table
      else Symtab.update (alias, value) table

    fun add_aliases name value table =
      fold (fn alias => add_alias alias value) (aliases_of_name name) table

    fun add_table_aliases table =
      Symtab.fold (fn (name, value) => add_aliases name value) table table

    fun sanitize_tree (SMTLIB.Sym s) = SMTLIB.Sym (sanitize_name s)
      | sanitize_tree (SMTLIB.Key s) = SMTLIB.Key (sanitize_name s)
      | sanitize_tree (SMTLIB.S trees) = SMTLIB.S (map sanitize_tree trees)
      | sanitize_tree t = t

    val term_tree =
      (case try_parse [] candidate_lines of
        NONE => NONE
      | SOME (SMTLIB.S [SMTLIB.Sym "define-fun", _, _, _, body]) => SOME (sanitize_tree body)
      | SOME _  => NONE)
  in
    (case term_tree of
      NONE => NONE
    | SOME tree =>
        let
          val cx0 =
            SMTLIB_Proof.empty_context ctxt
              (add_table_aliases typs)
              (add_table_aliases funs)
        in
          (case Exn.capture (SMTLIB_Proof.term_of tree) cx0 of
            Exn.Res (t_raw, _) =>
              let
                val t = infer_term ctxt t_raw
              in SOME t end
          | Exn.Exn _ => NONE)
        end)
  end

fun outcome_of solver_name line =
  if String.isPrefix "unsat" line then SMT_Solver.Unsat
  else if String.isPrefix "sat" line then SMT_Solver.Sat
  else if String.isPrefix "unknown" line then SMT_Solver.Unknown
  else if String.isPrefix "(error \"Maximum term size" line then SMT_Solver.Time_Out
  else if String.isPrefix "cvc5 interrupted by timeout" line then SMT_Solver.Time_Out
  else if String.isPrefix "timeout" line then SMT_Solver.Time_Out
  else
    raise SMT_Failure.SMT
      (SMT_Failure.Other_Failure
         ("Solver " ^ quote solver_name ^ " failed -- enable tracing using the " ^
          quote (Config.name_of SMT_Config.trace) ^ " option for details"))

fun is_blank_or_error_line "" = true
  | is_blank_or_error_line s =
      String.isPrefix "(error " s orelse
      String.isPrefix (getenv "ISABELLE_TMP_PREFIX") s

fun trace_outcome solver_name ctxt typs funs lines =
  let
    val lines = Library.drop_prefix is_blank_or_error_line lines
    val r = List.last lines
    val abducts = List.take (lines, List.length lines - 1)
    val parsed_abducts =
      map (fn abduct => parse_abduct_term ctxt typs funs [abduct]) abducts
    val result0 = outcome_of solver_name r
    val result =
      (case result0 of
        SMT_Solver.Unknown =>
          if exists Option.isSome parsed_abducts then SMT_Solver.Abduced else result0
      | _ => result0)
  in (result, abducts) end

fun parse_abduct_proof _
    ({context = ctxt, typs, terms, ...} : SMT_Translate.replay_data)
    _ _ _ lines =
  let
    val abduct_terms =
      map_filter (fn line => parse_abduct_term ctxt typs terms [line]) lines
    val failure_msg =
      if null abduct_terms then "Abduction failed"
      else "Abduced premises available"
  in
    {outcome = SOME (SMT_Failure.Other_Failure failure_msg),
     fact_ids = NONE,
     atp_proof = K [],
     abducts = abduct_terms}
  end

fun cvc5_options ctxt =
  ["--no-stats",
   "--sat-random-seed=" ^ string_of_int (Config.get ctxt SMT_Config.random_seed),
   "--lang=smt2",
   "--sygus-abort-size=10"] @
  (case SMT_Config.get_timeout ctxt of
    NONE => []
  | SOME t =>
      let
        val tlimit_per_ms = Time.toMilliseconds t
        val tlimit_ms = tlimit_per_ms * 15
      in
        ["--tlimit-per", string_of_int tlimit_per_ms,
         "--tlimit", string_of_int tlimit_ms]
      end) @
  (space_explode " " (getenv "CVC5_ABDUCT_OPTIONS"))

fun select_class ctxt =
  if Config.get ctxt SMT_Systems.cvc_extensions then
    if Config.get ctxt SMT_Config.higher_order then
      hosmtlib_cvc_abductC
    else
      smtlib_cvc_abductC
  else if Config.get ctxt SMT_Config.higher_order then
    hosmtlib_abductC
  else if Config.get ctxt SMT_Config.native_bv then
    bvsmlib_abductC
  else
    smtlib_abductC

val cvc5_abduct_trace : SMT_Solver.solver_config = {
  name = "cvc5_abduct_trace",
  class = select_class,
  avail = make_avail "CVC5",
  command = make_command "CVC5",
  options = cvc5_options,
  smt_options = [(":produce-abducts", "true"), (":sygus-stream", "true")],
  good_slices =
    [((2, true, false, 20, meshN), [])],
  outcome = trace_outcome,
  parse_proof = SOME parse_abduct_proof,
  replay = NONE
}

fun setup_cvc5_abduct_trace thy =
  let
    val ctxt = Proof_Context.init_global thy
    val registered =
      member (op =) (SMT_Config.all_solvers_of ctxt) (#name cvc5_abduct_trace)
  in
    if registered then thy
    else SMT_Solver.add_solver cvc5_abduct_trace thy
  end

val _ = Theory.setup setup_cvc5_abduct_trace

end
