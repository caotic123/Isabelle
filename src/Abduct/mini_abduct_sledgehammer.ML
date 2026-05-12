(*  Title:      Abduct/mini_abduct_sledgehammer.ML
    Author:     Caotic

    A minimal Sledgehammer pipeline for abduction experiments.

    This module provides two independent abduction pipelines:
    - CVC5: Uses SMT solver's native abduction via get-abduct
    - E: Extracts abduction candidates from E prover's output messages

    Both pipelines run independently without sharing intermediate results.
*)

signature MINI_ABDUCT_SLEDGEHAMMER =
sig
  type max_facts_config = {cvc5: int option, e: int option}

  type tactic_input = {
      max_facts: max_facts_config,
      max_facts_depth: max_facts_config,  (* max_facts to use when depth > 0 *)
      max_limit: max_facts_config,
      max_limit_depth: max_facts_config,  (* max_limit to use when depth > 0 *)
      depth: int,
      timeout: real,  (* Timeout in seconds for each solver *)
      debug: bool,  (* Enable debug tracing (default: false) *)
      exclude_terms: term list option, (* Terms to exclude from facts (e.g. dropped premises) *)
      use_grammar_assertions: bool, (* Use :grammar-assertions in get-abduct to limit to local facts (default: true) *)
      filter_global_quantifiers: bool (* Filter out global facts containing quantifiers (forall/exists) (default: false) *)
  }

  (* Abduct with provenance tracking:
     source can be: "cvc5", "e", "cvc5 -> e", "e -> cvc5" *)
  type abduct =
    {source: string,
     content: string,
     generated_at_ms: int,
     sequence_no: int}

   val abduct_sledgehammer_tac: Proof.state -> tactic_input -> int -> thm -> thm Seq.seq
   val abduct_sledgehammer_tac_depth : Proof.state -> tactic_input -> int -> thm -> thm Seq.seq
   val abduct_sledgehammer_tac_depth_ctxt : Proof.context -> tactic_input -> int -> thm -> thm Seq.seq
   val get_abducts : Proof.context -> tactic_input -> int -> thm -> abduct list

   (* SMT-LIB translation utilities *)
   val term_to_smtlib : Proof.context -> term -> string
   val terms_to_smtlib_problem : Proof.context -> term list -> term list -> term -> string

   (* Fact inspection utilities *)
   val get_solver_facts : Proof.context -> tactic_input -> string -> term list -> int -> thm
                          -> (string * thm) list

   (* Get the actual SMT-LIB problem that would be sent to CVC5 for abduction *)
   val get_cvc5_smtlib_problem : Proof.context -> tactic_input -> term list -> int -> thm -> string

   (* Default configuration for abduce method and command *)
   val default_config : tactic_input

   (* Abduce tactic with announcement message *)
   val abduce_tac : tactic_input -> Proof.context -> int -> thm -> thm Seq.seq
   val with_live_output_prefix : string -> (unit -> 'a) -> 'a
end

structure Mini_Abduct_Sledgehammer : MINI_ABDUCT_SLEDGEHAMMER =
struct

  type max_facts_config = {cvc5: int option, e: int option}

  type tactic_input = {
      max_facts: max_facts_config,
      max_facts_depth: max_facts_config,  (* max_facts to use when depth > 0 *)
      max_limit: max_facts_config,
      max_limit_depth: max_facts_config,  (* max_limit to use when depth > 0 *)
      depth: int,
      timeout: real,  (* Timeout in seconds for each solver *)
      debug: bool,  (* Enable debug tracing (default: false) *)
      exclude_terms: term list option, (* Terms to exclude from facts (e.g. dropped premises) *)
      use_grammar_assertions: bool, (* Use :grammar-assertions in get-abduct to limit to local facts (default: true) *)
      filter_global_quantifiers: bool (* Filter out global facts containing quantifiers (forall/exists) (default: false) *)
  }

  (* Abduct with provenance tracking *)
  type abduct =
    {source: string,
     content: string,
     generated_at_ms: int,
     sequence_no: int}

open Sledgehammer_Util
open Sledgehammer_Fact
open Sledgehammer_MaSh
open Sledgehammer_Prover
open Sledgehammer_Prover_Minimize

structure APG = ATP_Problem_Generate
structure SATP = Sledgehammer_ATP_Systems
structure SH_SMT = Sledgehammer_Prover_SMT
structure Abduct_Cfg = Abduct_CVC5_Abduct

val live_output_prefix_var = Thread_Data.var () : string Thread_Data.var


(* ========================================================================== *)
(* TYPE DEFINITIONS                                                           *)
(* ========================================================================== *)

(* A stage in the abduction pipeline *)
datatype stage =
  Stage of
    {label: string,
     prover_name: string,
     overrides: (string * string) list,
     finalize: bool}

(* Output from a single stage *)
type stage_output =
  {stage: stage,
   params: params,
   result: prover_result option,
   message: string option,
   abducts: abduct list}

type stage_publication =
  {branch_order: int,
   local_index: int,
   output: stage_output}

(* Solver state tracks facts and abducts between stages *)
type solver_state =
  {fact_override: fact_override,
   extra_facts: Sledgehammer_Fact.fact list,
   abduct_map: (string * thm) list,
   abduct_index: int}

(* Abduction naming context for recursive depth tracking *)
type abduction_context =
  {solver_name: string,        (* "cvc5" or "e" *)
   parent_index: int option,    (* parent hypothesis index, NONE for depth 0 *)
   current_depth: int,          (* current recursion depth level *)
   source_chain: string}        (* provenance: "cvc5", "e", "cvc5 -> e", "e -> cvc5" *)

(* Prepared stage: common data after initial setup, before solver execution *)
type prepared_stage =
  {stage: stage,
   stage_ctxt: Proof.context,
   params: params,
   solver: prover,
   slices: prover_slice list,
   facts: Sledgehammer_Fact.fact list,
   local_fact_count: int,  (* Number of local facts for grammar assertions *)
   problem: prover_problem}

(* Solver run result: prover result and textual messages *)
type solver_run =
  {result: prover_result option,
   messages: string list}

(* Shared timing and sequencing for one abduction pipeline run *)
type timing_context =
  {pipeline_timer: Timing.start,
   next_sequence_no: int Synchronized.var,
   live_output_prefix: string}

(* Parsed abduct content prior to provenance/sequence assignment *)
type parsed_abduct =
  {content: string,
   generated_at_ms: int option}

(* Parsed CVC5 abduct term with resolved elapsed time *)
type timed_term =
  {term: term,
   generated_at_ms: int}

(* CVC5-specific input: prepared stage plus abducts from SMT translation *)
type cvc5_input =
  {prepared: prepared_stage,
   updated_state: solver_state,
   abducts: parsed_abduct list}

(* E-specific input: prepared stage with original state *)
type e_input =
  {prepared: prepared_stage,
   original_state: solver_state}

(* ========================================================================== *)
(* GENERAL UTILITIES                                                          *)
(* ========================================================================== *)

(* Check if type contains no interesting arithmetic types *)
fun is_boring_builtin_typ (T : typ) : bool =
  not (Term.exists_subtype (member (op =) [HOLogic.natT, HOLogic.intT, HOLogic.realT]) T)

(* Check if term has boolean/prop type *)
fun is_boolean_term (t : term) : bool =
  case Term.fastype_of t of
    Type ("prop", _) => true
  | T => T = HOLogic.boolT

(* Check if term contains quantifiers (forall or exists).
   This filters facts that would become (assert (forall ...)) or (assert (exists ...)) in SMT-LIB. *)
fun contains_quantifier (t : term) : bool =
  let
    fun is_quant (Const (@{const_name All}, _)) = true
      | is_quant (Const (@{const_name Ex}, _)) = true
      | is_quant _ = false
  in
    Term.exists_subterm is_quant t
  end

(* Escape quotes for sendback commands *)
fun escape_quotes (s : string) : string =
  String.translate (fn #"\"" => "\\\"" | c => String.str c) s

val cvc5_elapsed_line_prefix = "__ABDUCT_ELAPSED_MS__"

fun elapsed_ms_of_timer (timer : Timing.start) : int =
  Int.fromLarge (Time.toMilliseconds (#elapsed (Timing.result timer)))

fun next_sequence_no (sequence_var : int Synchronized.var) : int =
  Synchronized.change_result sequence_var (fn sequence_no => (sequence_no, sequence_no + 1))

fun abduct_ord
    ({generated_at_ms = left_ms, sequence_no = left_seq, ...} : abduct,
     {generated_at_ms = right_ms, sequence_no = right_seq, ...} : abduct)
    : order =
  case int_ord (left_ms, right_ms) of
    EQUAL => int_ord (left_seq, right_seq)
  | ord => ord

fun sort_abducts_by_time (abducts : abduct list) : abduct list =
  sort abduct_ord abducts

fun current_live_output_prefix () =
  the_default "" (Thread_Data.get live_output_prefix_var)

fun with_live_output_prefix prefix f =
  Thread_Data.setmp live_output_prefix_var (SOME prefix) f ()

(* Normalize solver names for display (e.g. "cvc5_abduct_trace" -> "cvc5") *)
fun normalize_solver_name (name : string) : string =
  if String.isPrefix "cvc5" name then "cvc5"
  else if name = "e" then "e"
  else name

(* Format hypothesis name based on abduction context *)
fun format_hypothesis_name (abduct_ctx : abduction_context) (index : int) : string =
  case #parent_index abduct_ctx of
    NONE => #solver_name abduct_ctx ^ "_" ^ string_of_int index
  | SOME parent =>
      #solver_name abduct_ctx ^ "_from_" ^ string_of_int parent ^
      "_depth_" ^ string_of_int (#current_depth abduct_ctx) ^ "_" ^ string_of_int index


(* ========================================================================== *)
(* STAGE ACCESSORS                                                           *)
(* ========================================================================== *)

fun stage_label (Stage {label, ...}) : string = label
fun stage_prover (Stage {prover_name, ...}) : string = prover_name
fun stage_overrides (Stage {overrides, ...}) : (string * string) list = overrides
fun stage_finalize (Stage {finalize, ...}) : bool = finalize

fun make_stage (label : string) (prover_name : string)
               (overrides : (string * string) list) (finalize : bool) : stage =
  Stage {label = label, prover_name = prover_name, overrides = overrides, finalize = finalize}


(* ========================================================================== *)
(* SOLVER STATE MANAGEMENT                                                   *)
(* ========================================================================== *)

fun init_solver_state (fact_override : fact_override) : solver_state =
  {fact_override = fact_override, extra_facts = [], abduct_map = [], abduct_index = 1}


(* ========================================================================== *)
(* PROVER NAMES                                                              *)
(* ========================================================================== *)

val cvc5_abduct_name : string = #name Abduct_CVC5_Abduct.cvc5_abduct_trace


(* ========================================================================== *)
(* HARDCODED PIPELINE: CVC5 \<rightarrow> E                                              *)
(* ========================================================================== *)

val cvc5_stage : stage =
  make_stage "CVC5" cvc5_abduct_name
    [("abduce", "0"),
     ("smt_proofs", "false"),
     ("try0", "false"),
     ("minimize", "false"),
     ("preplay_timeout", "0")]
    false

val e_stage : stage =
  make_stage "E" ATP_Proof.eN
    [("abduce", "10"),
     ("falsify", "false"),
     ("smt_proofs", "false"),
     ("try0", "false"),
     ("minimize", "false"),
     ("preplay_timeout", "0")]
    true


(* ========================================================================== *)
(* FACT SELECTION AND PROBLEM CONSTRUCTION                                   *)
(* ========================================================================== *)

fun stage_params (ctxt : Proof.context) (config : tactic_input) (stage : stage) : params =
  let
    val thy = Proof_Context.theory_of ctxt
    val timeout_str = string_of_int (Real.ceil (#timeout config))
    val overrides = ("timeout", timeout_str) :: ("provers", stage_prover stage) :: stage_overrides stage
  in
    Sledgehammer_Commands.default_params thy overrides
  end

(* ---------- Fact Selection: Helper Functions ---------- *)

(* Conditional transformation: apply f if flag is true, otherwise identity *)
fun when_enabled (flag : bool) (f : 'a -> 'a) (x : 'a) : 'a =
  if flag then f x else x

(* Check if a term matches any in the excluded list *)
fun term_matches_excluded (excluded : term list) (t : term) : bool =
  exists (fn excl => Term.aconv (t, excl) orelse
                     Term.aconv (t, HOLogic.mk_Trueprop excl)) excluded

(* Predicate: fact contains excluded term *)
fun is_excluded_fact (excluded : term list) ((_, _), thm) : bool =
  term_matches_excluded excluded (Thm.prop_of thm)

(* Predicate: fact contains quantifiers *)
fun has_quantifier_fact ((_, _), thm) : bool =
  contains_quantifier (Thm.prop_of thm)

(* Extract hypothesis facts from subgoal *)
fun get_hypothesis_facts (ctxt : Proof.context) (goal : thm) (subgoal : int)
    : Sledgehammer_Fact.fact list * term list * term =
  let
    val (_, hyp_ts, concl_t) = ATP_Util.strip_subgoal goal subgoal ctxt
    val hyp_facts =
      map_index (fn (i, hyp_t) =>
        let
          val hyp_name = "local.hyp" ^ string_of_int (i + 1)
          val stature : Sledgehammer_Prover.stature = (APG.Assum, APG.General)
          val hyp_thm = Thm.assume (Thm.cterm_of ctxt hyp_t)
        in
          ((hyp_name, stature), hyp_thm)
        end) hyp_ts
  in
    (hyp_facts, hyp_ts, concl_t)
  end

(* Extract local named facts from proof context (local.IH, local.2.hyps, etc.) *)
fun get_local_named_facts (ctxt : Proof.context) : Sledgehammer_Fact.fact list =
  let
    val facts_table = Proof_Context.facts_of ctxt
    val all_names = Facts.fold_static (fn (name, _) => cons name) facts_table []
    val local_names = filter (String.isPrefix "local.") all_names

    fun try_get_fact name =
      (SOME (name, Proof_Context.get_fact ctxt (Facts.named name)))
      handle ERROR _ => NONE

    val retrieved = map_filter try_get_fact local_names
  in
    maps (fn (name, thms) =>
      map_index (fn (i, thm) =>
        let
          val fact_name = name ^ "(" ^ string_of_int (i + 1) ^ ")"
          val stature : Sledgehammer_Prover.stature = (APG.Assum, APG.General)
        in
          ((fact_name, stature), thm)
        end) thms
    ) retrieved
  end

(* Apply relevance filtering to facts (used at depth > 0).
   Facts parameter is last for pipeline composition. *)
fun filter_facts_by_relevance
    (ctxt : Proof.context)
    (params : params)
    (prover_name : string)
    (fact_override : fact_override)
    (concl_t : term)
    (current_depth : int)
    (facts : Sledgehammer_Fact.fact list)
    : Sledgehammer_Fact.fact list =
  if current_depth = 0 orelse null facts then facts
  else
    let
      val lazy_facts =
        map (fn ((name, stature), thm) => ((fn () => name, stature), thm)) facts
      val factss =
        relevant_facts ctxt params prover_name (length facts)
          fact_override [] concl_t lazy_facts
    in
      case factss of
        [] => facts
      | (_, filtered) :: _ => filtered
    end

(* Convert chained theorems to facts *)
fun chained_to_facts (chained : thm list) : Sledgehammer_Fact.fact list =
  map_index (fn (i, thm) =>
    let
      val chained_name = "local.chained" ^ string_of_int (i + 1)
      val stature : Sledgehammer_Prover.stature = (APG.Assum, APG.General)
    in
      ((chained_name, stature), thm)
    end) chained

(* Compute max_facts based on config, params, prover, and depth *)
fun compute_max_facts
    (config : tactic_input)
    (params : params)
    (prover_name : string)
    (current_depth : int)
    : int =
  let
    val max_facts_cfg = if current_depth > 0 then #max_facts_depth config else #max_facts config
    val from_cfg = if prover_name = "e" then #e max_facts_cfg else #cvc5 max_facts_cfg
  in
    case from_cfg of
      SOME n => n
    | NONE => (case #max_facts params of SOME n => n | NONE => 2048)
  end

(* Get outer/theory facts, excluding already-included theorems *)
fun get_outer_facts
    (ctxt : Proof.context)
    (params : params)
    (prover_name : string)
    (fact_override : fact_override)
    (concl_t : term)
    (already_included : thm list)
    (max_facts : int)
    : Sledgehammer_Fact.fact list =
  let
    val keywords = Thy_Header.get_keywords' ctxt
    val css_table = clasimpset_rule_table_of ctxt
    val inst_inducts = (#induction_rules params = SOME Instantiate)
    val raw_facts =
      nearly_all_facts ctxt inst_inducts fact_override keywords css_table [] [] concl_t

    fun is_already_included (((_, _), thm) : Sledgehammer_Fact.lazy_fact) =
      exists (fn incl => Thm.eq_thm_prop (thm, incl)) already_included

    val filtered_raw = filter_out is_already_included raw_facts
    val factss =
      relevant_facts ctxt params prover_name max_facts fact_override [] concl_t filtered_raw
  in
    case factss of [] => [] | (_, facts) :: _ => facts
  end

(* ---------- Fact Selection: Main Composition ---------- *)

fun select_facts
    (ctxt : Proof.context)
    (config : tactic_input)
    (params : params)
    (fact_override : fact_override)
    (chained : thm list)
    (goal : thm)
    (subgoal : int)
    (prover_name : string)
    (current_depth : int)
    : Sledgehammer_Fact.fact list * int =
  let
    val excluded = #exclude_terms config |> the_default []

    (* Get hypothesis facts and goal conclusion *)
    val (hyp_facts, _, concl_t) = get_hypothesis_facts ctxt goal subgoal

    (* Get and filter local named facts *)
    val local_named_facts =
      get_local_named_facts ctxt
      |> filter_out (is_excluded_fact excluded)
      |> filter_facts_by_relevance ctxt params prover_name fact_override concl_t current_depth

    (* Convert chained facts *)
    val chained_facts = chained_to_facts chained

    (* Combine local facts *)
    val local_all = hyp_facts @ local_named_facts @ chained_facts
    val local_fact_count = length local_all

    (* Get outer facts with filtering *)
    val max_facts = compute_max_facts config params prover_name current_depth
    val already_included = map snd local_all
    val outer_facts =
      get_outer_facts ctxt params prover_name fact_override concl_t already_included max_facts
      |> filter_out (is_excluded_fact excluded)
      |> when_enabled (#filter_global_quantifiers config) (filter_out has_quantifier_fact)
  in
    (local_all @ outer_facts, local_fact_count)
  end

fun make_problem
    (state : Proof.state)
    (goal : thm)
    (subgoal : int)
    (subgoal_count : int)
    (facts : Sledgehammer_Fact.fact list)
    : prover_problem =
  {comment = "",
   state = state,
   goal = goal,
   subgoal = subgoal,
   subgoal_count = subgoal_count,
   factss = [("", facts)],
   has_already_found_something = K false,
   found_something = K (),
   memoize_fun_call = fn f => f}


(* ========================================================================== *)
(* CVC5 ABDUCTION PIPELINE - SMT SERIALIZATION                               *)
(* ========================================================================== *)

(* These functions are needed by prepare_stage_input, so they come first *)

fun reorder_sterms (ts : (SMT_Util.role * SMT_Translate.sterm) list)
                   : (SMT_Util.role * SMT_Translate.sterm) list =
  let
    val (conjectures, others) =
      List.partition (fn (role, _) => role = SMT_Util.Conjecture) ts
  in
    if null conjectures then
      raise SMT_Failure.SMT (SMT_Failure.Other_Failure "no conjecture")
    else
      others @ conjectures
  end

fun app_tree (name : string) (trees : SMTLIB.tree list) : SMTLIB.tree =
  if null trees then SMTLIB.Sym name else SMTLIB.S (SMTLIB.Sym name :: trees)

fun tree_of_sterm (depth : int) (sterm : SMT_Translate.sterm) : SMTLIB.tree =
  case sterm of
    SMT_Translate.SVar (i, ts) =>
      app_tree ("?v" ^ string_of_int (depth - i - 1)) (map (tree_of_sterm depth) ts)
  | SMT_Translate.SConst (name, ts) =>
      app_tree name (map (tree_of_sterm depth) ts)
  | SMT_Translate.SQua (quantifier, ss, pats, body) =>
      let
        val depth' = depth + length ss
        fun quant_name SMT_Translate.SForall = "forall"
          | quant_name SMT_Translate.SExists = "exists"
        fun mk_binding (i, ty) =
          SMTLIB.S [SMTLIB.Sym ("?v" ^ string_of_int (depth + i)), SMTLIB.Sym ty]
        fun trees_of_pat (SMT_Translate.SPat ps) =
              [SMTLIB.Key "pattern", SMTLIB.S (map (tree_of_sterm depth') ps)]
          | trees_of_pat (SMT_Translate.SNoPat ps) =
              [SMTLIB.Key "no-pattern", SMTLIB.S (map (tree_of_sterm depth') ps)]
        fun include_pats [] term = term
          | include_pats pat_terms term =
              SMTLIB.S (SMTLIB.Sym "!" :: term :: maps trees_of_pat pat_terms)
        val vars = map_index mk_binding ss
        val body' = include_pats pats (tree_of_sterm depth' body)
      in
        SMTLIB.S [SMTLIB.Sym (quant_name quantifier), SMTLIB.S vars, body']
      end

fun named_tree (name : string) (tree : SMTLIB.tree) : SMTLIB.tree =
  SMTLIB.S [SMTLIB.Sym "!", tree, SMTLIB.Key "named", SMTLIB.Sym name]

fun string_of_fun ((f, (args, result)) : string * (string list * string)) : string =
  f ^ " (" ^ implode_space args ^ ") " ^ result

fun sctr_arg ((selector, typ) : string * string) : string =
  "(" ^ selector ^ " " ^ typ ^ ")"

fun sctr ((name, args) : string * (string * string) list) : string =
  enclose "(" ")" (implode_space (name :: map sctr_arg args))

fun sdatatype ((name, ctrs) : string * (string * (string * string) list) list) : string =
  enclose "(" ")" (implode_space (name :: map sctr ctrs))

fun sdtyp ((fp, dtyps) : BNF_Util.fp_kind * (string * (string * (string * string) list) list) list) : string =
  let
    val prefix = "(declare-" ^ BNF_FP_Util.co_prefix fp ^ "datatypes () ("
    val body = space_implode "\n  " (map sdatatype dtyps)
  in
    enclose prefix "))\n" body
  end

fun de_negate_goal tree =
  let
    fun strip (SMTLIB.S [SMTLIB.Sym "not", t]) = SOME t
      | strip (SMTLIB.S [SMTLIB.Sym "=", t, SMTLIB.Sym "false"]) = SOME t
      | strip (SMTLIB.S [SMTLIB.Sym "=", SMTLIB.Sym "false", t]) = SOME t
      | strip (SMTLIB.S (SMTLIB.Sym "let" :: bindings :: body :: rest)) =
          strip body |> Option.map (fn body' =>
            SMTLIB.S (SMTLIB.Sym "let" :: bindings :: body' :: rest))
      | strip (SMTLIB.S (SMTLIB.Sym "!" :: body :: attrs)) =
          strip body |> Option.map (fn body' =>
            SMTLIB.S (SMTLIB.Sym "!" :: body' :: attrs))
      | strip _ = NONE
  in
    (case strip tree of
      SOME t' => t'
    | NONE => tree)
  end

(* ---------- SMT-LIB Serialization: Helper Functions ---------- *)

(* Convert sterms to indexed (index, role, tree) triples *)
fun index_and_convert_to_trees (ts : (SMT_Util.role * SMT_Translate.sterm) list)
    : (int * SMT_Util.role * SMTLIB.tree) list =
  map_index (fn (i, (role, sterm)) => (i, role, tree_of_sterm 0 sterm)) ts

(* Count hypothesis entries in indexed list *)
fun count_hypotheses (indexed : (int * SMT_Util.role * 'a) list) : int =
  length (filter (fn (_, role, _) => role = SMT_Util.Hypothesis) indexed)

(* Create grammar assertion predicate based on local_fact_count *)
fun make_grammar_predicate (local_fact_count_opt : int option) (num_hypotheses : int)
    : int -> SMT_Util.role -> bool =
  fn i => fn role =>
    case local_fact_count_opt of
      NONE => false
    | SOME local_fact_count =>
        role = SMT_Util.Hypothesis orelse
        (role = SMT_Util.Axiom andalso i < num_hypotheses + local_fact_count)

(* Deduplicate assertions, tracking grammar names for local facts *)
fun deduplicate_assertions
    (is_grammar : int -> SMT_Util.role -> bool)
    (last_index : int)
    (indexed_ts : (int * SMT_Util.role * SMTLIB.tree) list)
    : string list * (int * SMT_Util.role * SMTLIB.tree) list =
  let
    fun go [] _ grammar_names = (rev grammar_names, [])
      | go ((entry as (i, role, tree)) :: rest) seen grammar_names =
          if i = last_index then
            let val (names, deduped) = go rest seen grammar_names
            in (names, entry :: deduped) end
          else
            let
              val tree_str = SMTLIB.str_of tree
              val name = SMTLIB_Interface.assert_name_of_role_and_index role i
            in
              if member (op =) seen tree_str then
                go rest seen grammar_names
              else
                let
                  val grammar_names' =
                    if is_grammar i role then name :: grammar_names else grammar_names
                  val (names, deduped) = go rest (tree_str :: seen) grammar_names'
                in (names, entry :: deduped) end
            end
  in
    go indexed_ts [] []
  end

(* Build grammar suffix string from names *)
fun build_grammar_suffix (local_fact_count_opt : int option) (grammar_names : string list) : string =
  case local_fact_count_opt of
    NONE => ""
  | SOME _ => " :grammar-assertions (" ^ String.concatWith " " grammar_names ^ ")"

(* Buffer addition helpers *)
fun add_comment comment buf = Buffer.add (enclose "; " "\n" comment) buf
fun add_option (k, v) buf = Buffer.add ("(set-option " ^ k ^ " " ^ v ^ ")\n") buf
fun add_sort sort buf = Buffer.add ("(declare-sort " ^ sort ^ " 0)\n") buf
fun add_fun_decl decl buf = Buffer.add ("(declare-fun " ^ decl ^ ")\n") buf

(* Build statement with grammar suffix for last (goal) entry *)
fun make_statement_adder (last_index : int) (grammar_suffix : string)
    : (int * SMT_Util.role * SMTLIB.tree) -> Buffer.T -> Buffer.T =
  fn (i, role, tree) => fn buf =>
    let
      val (command, tree', suffix) =
        if i = last_index then ("(get-abduct A ", de_negate_goal tree, grammar_suffix)
        else ("(assert ", tree, "")
      val name = SMTLIB_Interface.assert_name_of_role_and_index role i
      val stmt = command ^ SMTLIB.str_of (named_tree name tree') ^ suffix ^ ")\n"
    in
      Buffer.add stmt buf
    end

(* Serialize SMT-LIB components to buffer *)
fun serialize_to_buffer
    (comments : string list)
    (smt_options : (string * string) list)
    (logic : string)
    (sorts : string list)
    (dtyps : (BNF_Util.fp_kind * (string * (string * (string * string) list) list)) list)
    (funcs : (string * (string list * string)) list)
    (statements : (int * SMT_Util.role * SMTLIB.tree) list)
    (add_statement : (int * SMT_Util.role * SMTLIB.tree) -> Buffer.T -> Buffer.T)
    : string =
  Buffer.empty
  |> fold add_comment comments
  |> fold add_option smt_options
  |> Buffer.add logic
  |> fold add_sort (sort fast_string_ord sorts)
  |> fold (Buffer.add o sdtyp) (AList.coalesce (op =) dtyps)
  |> fold add_fun_decl (map string_of_fun (sort (fast_string_ord o apply2 fst) funcs))
  |> fold add_statement statements
  |> Buffer.content

(* ---------- SMT-LIB Serialization: Main Composition ---------- *)

fun make_serialize_abduct (local_fact_count_opt : int option) (debug : bool)
    (smt_options : (string * string) list)
    (comments : string list)
    {logic, sorts, dtyps, funcs}
    (ts : (SMT_Util.role * SMT_Translate.sterm) list) : string =
  let
    val indexed_ts = ts |> reorder_sterms |> index_and_convert_to_trees
    val last_index = length indexed_ts - 1
    val num_hypotheses = count_hypotheses indexed_ts

    val is_grammar = make_grammar_predicate local_fact_count_opt num_hypotheses
    val (grammar_names, deduped_ts) = deduplicate_assertions is_grammar last_index indexed_ts

    val _ = if debug then
      tracing ("make_serialize_abduct: deduplication removed " ^
        string_of_int (length indexed_ts - length deduped_ts - 1) ^ " duplicate assertions")
      else ()

    val grammar_suffix = build_grammar_suffix local_fact_count_opt grammar_names

    val _ = if debug then
      tracing ("make_serialize_abduct: local_fact_count_opt=" ^
        (case local_fact_count_opt of NONE => "NONE" | SOME n => "SOME " ^ string_of_int n) ^
        ", num_hypotheses=" ^ string_of_int num_hypotheses ^
        ", grammar_names=" ^ string_of_int (length grammar_names) ^
        ", grammar_suffix=" ^ quote grammar_suffix)
      else ()

    val add_statement = make_statement_adder last_index grammar_suffix
    val result = serialize_to_buffer comments smt_options logic sorts dtyps funcs deduped_ts add_statement

    val _ = if debug then
      tracing ("=== ABDUCT SERIALIZER OUTPUT ===\n" ^ result ^ "=== END ABDUCT SERIALIZER OUTPUT ===")
      else ()
  in
    result
  end

(* Default serialize without grammar assertions or debug *)
val serialize_abduct = make_serialize_abduct NONE false

fun abduct_translate_config_with_grammar
    (local_fact_count_opt : int option)
    (debug : bool)
    (order : SMT_Util.order)
    (ctxt : Proof.context) : SMT_Translate.config =
  let
    val base = SMTLIB_Interface.translate_config order ctxt
  in
    {order = #order base,
     logic = #logic base,
     fp_kinds = #fp_kinds base,
     serialize = make_serialize_abduct local_fact_count_opt debug}
  end

fun abduct_translate_config (order : SMT_Util.order) (ctxt : Proof.context) : SMT_Translate.config =
  abduct_translate_config_with_grammar NONE false order ctxt

fun ensure_abduct_serializer_with_grammar
    (local_fact_count_opt : int option)
    (debug : bool)
    (name : string)
    (ctxt : Proof.context) : Proof.context =
  if name <> cvc5_abduct_name then
    ctxt
  else
    let
      val solver = Abduct_CVC5_Abduct.cvc5_abduct_trace
      val class = (#class solver) ctxt
      fun add_config (cls, order) =
        Context.proof_map (SMT_Translate.add_config (cls, abduct_translate_config_with_grammar local_fact_count_opt debug order)) ctxt
    in
      if class = Abduct_Cfg.smtlib_abductC then
        add_config (Abduct_Cfg.smtlib_abductC, SMT_Util.First_Order)
      else if class = Abduct_Cfg.smtlib_cvc_abductC then
        add_config (Abduct_Cfg.smtlib_cvc_abductC, SMT_Util.First_Order)
      else if class = Abduct_Cfg.bvsmlib_abductC then
        add_config (Abduct_Cfg.bvsmlib_abductC, SMT_Util.First_Order)
      else if class = Abduct_Cfg.hosmtlib_abductC then
        add_config (Abduct_Cfg.hosmtlib_abductC, SMT_Util.Higher_Order)
      else if class = Abduct_Cfg.hosmtlib_cvc_abductC then
        add_config (Abduct_Cfg.hosmtlib_cvc_abductC, SMT_Util.Higher_Order)
      else
        (warning ("ensure_abduct_serializer_with_grammar: unrecognized class " ^
           SMT_Util.string_of_class class); ctxt)
    end

fun ensure_abduct_serializer (name : string) (ctxt : Proof.context) : Proof.context =
  ensure_abduct_serializer_with_grammar NONE false name ctxt


(* ========================================================================== *)
(* SHARED: STAGE PREPARATION AND SOLVER EXECUTION                            *)
(* ========================================================================== *)

fun prepare_stage_input
    (state : Proof.state)
    (goal : thm)
    (config : tactic_input)
    (chained : thm list)
    (subgoal : int)
    (stage : stage)
    (solver_state : solver_state)
    (current_depth : int)
    : prepared_stage =
  let
    val ctxt = Proof.context_of state
    val subgoal_count = Thm.nprems_of goal
    val prover_name = stage_prover stage

    (* First, select facts to get local_fact_count *)
    val base_ctxt = ctxt
    val base_params = stage_params base_ctxt config stage
    val (base_facts, local_fact_count) =
      select_facts base_ctxt config base_params (#fact_override solver_state) chained goal subgoal prover_name current_depth
    val facts : Sledgehammer_Fact.fact list = #extra_facts solver_state @ base_facts
    (* Now set up serializer with grammar info if enabled *)
    val local_fact_count_opt =
      if #use_grammar_assertions config then SOME local_fact_count
      else NONE
    val stage_ctxt = ensure_abduct_serializer_with_grammar local_fact_count_opt (#debug config) prover_name ctxt
    val params = stage_params stage_ctxt config stage
    val problem = make_problem state goal subgoal subgoal_count facts
    val solver = get_prover stage_ctxt Normal prover_name
    val raw_slices = get_slices stage_ctxt prover_name
    (* If abduce parameter is set, modify slices to enable abduction mode *)
    val slices : prover_slice list =
      case #abduce params of
        SOME _ =>
          (* Slice structure: ((slice_size, abduce, falsify, num_facts, fact_filter), ATP_Slice (...)) *)
          let
            fun enable_abduce_in_slice ((sz, _, fals, nf, ff), atp_slice) =
              ((sz, true, fals, nf, ff), atp_slice)
          in
            map enable_abduce_in_slice raw_slices
          end
      | NONE => raw_slices
  in
    {stage = stage,
     stage_ctxt = stage_ctxt,
     params = params,
     solver = solver,
     slices = slices,
     facts = facts,
     local_fact_count = local_fact_count,
     problem = problem}
  end

fun run_prover_slices
    (prover : prover)
    (slices : prover_slice list)
    (params : params)
    (problem : prover_problem)
    (prover_name : string)
    (debug : bool)
    : prover_result option * string list =
  let
    fun attempt (remaining : prover_slice list) (last : prover_result option) (messages : string list)
                (slice_num : int)
                : prover_result option * string list =
      case remaining of
        [] => (last, rev messages)
      | slice :: rest =>
          let
            val ((slice_size, abduce, falsify, num_facts, fact_filter), _) = slice
            val _ = if debug then
                      tracing (prover_name ^ " slice #" ^ string_of_int slice_num ^
                             ": size=" ^ string_of_int slice_size ^
                             ", abduce=" ^ Bool.toString abduce ^
                             ", facts=" ^ string_of_int num_facts)
                    else ()
          in
            case Exn.capture (fn () => prover params problem slice) () of
              Exn.Res res =>
                let
                  val msg_result = Exn.capture (fn () => #message res NONE) ()
                in
                  case msg_result of
                    Exn.Res msg =>
                      let
                        val messages' = msg :: messages
                        val last' = if #outcome res = NONE then SOME res else last
                      in
                        attempt rest last' messages' (slice_num + 1)
                      end
                  | Exn.Exn Size =>
                      (if debug then
                         tracing (prover_name ^ " slice #" ^ string_of_int slice_num ^
                                ": Size exception in message extraction")
                       else ();
                       attempt rest last messages (slice_num + 1))
                  | Exn.Exn exn => raise exn
                end
            | Exn.Exn (ERROR msg) =>
                (warning ("Abduction pipeline: " ^ prover_name ^ " slice #" ^ string_of_int slice_num ^
                         " failed: " ^ msg);
                 attempt rest last messages (slice_num + 1))
            | Exn.Exn Size =>
                (warning ("Abduction pipeline: " ^ prover_name ^ " slice #" ^ string_of_int slice_num ^
                         " raised Size exception during invocation");
                 attempt rest last messages (slice_num + 1))
            | Exn.Exn exn => raise exn
          end
  in
    attempt slices NONE [] 1
  end

fun run_solver (prepared : prepared_stage) (debug : bool) : solver_run =
  let
    val prover_name = stage_prover (#stage prepared)
    val (result, messages) =
      run_prover_slices (#solver prepared) (#slices prepared) (#params prepared)
        (#problem prepared) prover_name debug
  in
    {result = result, messages = messages}
  end


(* ========================================================================== *)
(* CVC5 ABDUCTION PIPELINE (continued)                                       *)
(* ========================================================================== *)

(* ---------- CVC5: Parse Solver Output ---------- *)

fun cvc5_solver_outcome (_ : string) (line : string) : SMT_Solver.outcome =
  if String.isPrefix "unsat" line then SMT_Solver.Unsat
  else if String.isPrefix "sat" line then SMT_Solver.Sat
  else if String.isPrefix "unknown" line then SMT_Solver.Unknown
  else if String.isPrefix "abduced" line then SMT_Solver.Abduced
  else if String.isPrefix "(error \"Maximum term size" line then SMT_Solver.Time_Out
  else if String.isPrefix "cvc5 interrupted by timeout" line then SMT_Solver.Time_Out
  else if String.isPrefix "timeout" line then SMT_Solver.Time_Out
  else if String.isPrefix "fail" line then SMT_Solver.Unknown
  else SMT_Solver.Unknown (* Don't raise exception for unrecognized outcomes *)

fun cvc5_is_blank_or_error_line (s : string) : bool =
  s = "" orelse
  String.isPrefix "(error " s orelse
  String.isPrefix (getenv "ISABELLE_TMP_PREFIX") s

fun parse_cvc5_abduct_outcome (solver_name : string) (ctxt : Proof.context)
                              (typs : typ Symtab.table) (terms : term Symtab.table)
                              (lines : string list)
                              : {outcome: SMT_Solver.outcome,
                                 lines: string list,
                                 parsed: {term: term, generated_at_ms: int option} option list} =
  let
    fun strip_elapsed_prefix (line : string) : {line: string, generated_at_ms: int option} =
      if String.isPrefix cvc5_elapsed_line_prefix line then
        let
          val rest = String.extract (line, size cvc5_elapsed_line_prefix, NONE)
        in
          (case space_explode "\t" rest of
            ms_str :: content_parts =>
              {line = String.concatWith "\t" content_parts,
               generated_at_ms = Int.fromString ms_str}
          | [] => {line = line, generated_at_ms = NONE})
        end
      else
        {line = line, generated_at_ms = NONE}

    val timed_lines =
      map strip_elapsed_prefix lines
      |> Library.drop_prefix (fn {line, ...} => cvc5_is_blank_or_error_line line)

    (* Check if a line looks like a define-fun abduct from CVC5.
       CVC5 outputs abducts as: (define-fun __internal_abduct () Bool ...) or (define-fun A () Bool ...) *)
    fun is_abduct_entry ({line, ...} : {line: string, generated_at_ms: int option}) =
      let
        val trimmed = String.implode (Library.drop_prefix (fn c => c = #" ") (String.explode line))
      in
        String.isPrefix "(define-fun __internal_abduct" trimmed orelse
        String.isPrefix "(define-fun A " trimmed
      end

    (* Try to parse each abduct line - ignore lines that don't parse *)
    val abduct_candidates = filter is_abduct_entry timed_lines
    val parsed_abducts =
      map (fn {line = abduct_line, generated_at_ms} =>
            Option.map (fn abduct_term =>
              {term = abduct_term, generated_at_ms = generated_at_ms})
              (Abduct_CVC5_Abduct.parse_abduct_term ctxt typs terms [abduct_line]))
          abduct_candidates

    (* Determine outcome from remaining lines *)
    val non_abduct_lines = filter_out is_abduct_entry timed_lines
    val result_line =
      case try List.last non_abduct_lines of
        SOME {line, ...} => line
      | NONE => if exists Option.isSome parsed_abducts then "abduced" else "unknown"

    val outcome0 = cvc5_solver_outcome solver_name result_line
    val outcome =
      case outcome0 of
        SMT_Solver.Unknown =>
          if exists Option.isSome parsed_abducts then SMT_Solver.Abduced else outcome0
      | _ => outcome0
  in
    {outcome = outcome, lines = map #line abduct_candidates, parsed = parsed_abducts}
  end

(* ---------- CVC5: Translate Abduction Problem (Pure) ---------- *)

fun translate_cvc5_abduct_problem (ctxt : Proof.context) (params : params)
                                  (problem : prover_problem)
                                  (facts : Sledgehammer_Fact.fact list)
                                  (local_fact_count_opt : int option)
                                  (debug : bool)
                                  : {raw_input: string,
                                     replay_data: SMT_Translate.replay_data,
                                     command: Bash.params,
                                     run_ctxt: Proof.context,
                                     solver_name: string} =
  let
    val name = cvc5_abduct_name
    val solver = Abduct_CVC5_Abduct.cvc5_abduct_trace
    val state = #state problem
    val goal = #goal problem
    val subgoal = #subgoal problem
    val timeout = #timeout params
    val {overlord, max_mono_iters, max_new_mono_instances, type_enc, ...} = params
    val ctxt0 = Proof.context_of state
    val ctxt_timeout = Config.put SMT_Config.timeout (Time.toReal timeout) ctxt0
    val ({context = focus_ctxt, prems, concl, ...}, _) =
      Subgoal.focus ctxt_timeout subgoal NONE goal
    (* For abduction, we use the goal directly without negation *)
    val cprop = Thm.rhs_of (SMT_Normalize.atomize_conv focus_ctxt concl)
    val conjecture = Thm.assume cprop
    val thms =
      (SMT_Util.Conjecture, conjecture) ::
      map (pair SMT_Util.Hypothesis) prems @
      map (pair SMT_Util.Axiom o snd) facts
    val normalized =
      let
        val normalized_entries = SMT_Normalize.normalize focus_ctxt thms
        val (conjectures, others) =
          List.partition (fn ((_, role), _) => role = SMT_Util.Conjecture) normalized_entries
        val _ =
          if null conjectures then
            raise SMT_Failure.SMT (SMT_Failure.Other_Failure "no conjecture")
          else ()
        val goal_prop = Thm.term_of cprop
        val (goal_conjs, other_conjs) =
          List.partition (fn (_, thm) => Term.aconv_untyped (goal_prop, Thm.prop_of thm)) conjectures
        val reordered_conjs =
          if null goal_conjs then conjectures
          else other_conjs @ goal_conjs
      in
        others @ reordered_conjs
      end
    val (higher_order, nat_as_int) =
      case type_enc of
        SOME s =>
          (SOME (String.isSubstring "native_higher" s),
           SOME (String.isSubstring "arith" s))
      | NONE => (NONE, NONE)
    fun repair_context ctxt' =
      ctxt'
      |> Context.proof_map (SMT_Config.select_solver name)
      |> (case higher_order of
           SOME higher => Config.put SMT_Config.higher_order higher
         | NONE => I)
      |> (case nat_as_int of
           SOME nat_int => Config.put SMT_Config.nat_as_int nat_int
         | NONE => I)
      |> (if overlord then
            let
              val (path, base) = overlord_file_location_of_prover name
              val file_base = path ^ "/" ^ base
            in
              Config.put SMT_Config.problem_dest_file file_base #>
              Config.put SMT_Config.proof_dest_file file_base
            end
          else I)
      |> Config.put SMT_Config.infer_triggers
           (Config.get focus_ctxt SH_SMT.smt_triggers)
      |> (if Config.get focus_ctxt SH_SMT.smt_builtins then I
          else SMT_Builtin.filter_builtins is_boring_builtin_typ
            #> Config.put SMT_Systems.z3_extensions false)
      |> repair_monomorph_context max_mono_iters SATP.default_max_mono_iters
           max_new_mono_instances SATP.default_max_new_mono_instances
    val ctxt' = repair_context focus_ctxt
    val ctxt'' = ensure_abduct_serializer_with_grammar local_fact_count_opt debug name ctxt'
    val cmd_options = (#options solver) ctxt''
    val solver_options = SMT_Config.solver_options_of ctxt''
    val options = cmd_options @ solver_options
    val comments = [implode_space options]
    val (raw_input, replay_data) =
      SMT_Translate.translate ctxt'' name (#smt_options solver) comments normalized
    val base_command = Bash.strings ((#command solver) () @ options)
    val timestamp_script =
      "import sys, time\n" ^
      "start = time.monotonic()\n" ^
      "for raw_line in sys.stdin:\n" ^
      "    elapsed = int((time.monotonic() - start) * 1000)\n" ^
      "    sys.stdout.write('" ^ cvc5_elapsed_line_prefix ^ "' + str(elapsed) + '\\t' + raw_line)\n" ^
      "    sys.stdout.flush()\n"
    val command =
      Bash.script ("set -o pipefail\n" ^
        base_command ^ " | python3 -u -c " ^ Bash.string timestamp_script)
  in
    {raw_input = raw_input,
     replay_data = replay_data,
     command = command,
     run_ctxt = ctxt'',
     solver_name = name}
  end

(* ---------- CVC5: Run Solver ---------- *)

(* Run cvc5 with Isabelle timeout wrapper as safety net.
   The timeout is set to tlimit + 5 seconds to allow CVC5's --tlimit to trigger first.
   If CVC5 hangs beyond that, Isabelle will kill it. *)
fun run_cvc5_abduct_solver
    (raw_input : string)
    (command : Bash.params)
    (ctxt : Proof.context)
    : string list =
  let
    (* Get timeout from context and add buffer for Isabelle-level timeout *)
    val isabelle_timeout =
      case SMT_Config.get_timeout ctxt of
        SOME t => Time.+ (Time.scale 15.0 t, Time.fromSeconds 5)  (* tlimit + 5s buffer *)
      | NONE => Time.fromSeconds 300  (* Default 5 minutes if no timeout set *)

    val run_command = Cache_IO.run command
    val result =
      Timeout.apply isabelle_timeout (fn () => run_command raw_input) ()
      handle Timeout.TIMEOUT _ =>
        Process_Result.make {rc = 124, out_lines = ["timeout"], err_lines = [], timing = Timing.zero}
    (* Always return output lines regardless of return code.
       We'll parse whatever abducts are there, even if CVC5 failed. *)
  in
    Process_Result.out_lines result
  end

(* ---------- CVC5: Collect Abduction Terms (Orchestration) ---------- *)

fun collect_cvc5_abduct_terms
    (ctxt : Proof.context)
    (params : params)
    (problem : prover_problem)
    (facts : Sledgehammer_Fact.fact list)
    (local_fact_count_opt : int option)
    (debug : bool)
    (stage_start_elapsed_ms : int)
    (timing_ctx : timing_context)
    : timed_term list =
  let
    val translated = translate_cvc5_abduct_problem ctxt params problem facts local_fact_count_opt debug
    val output_lines : string list =
      run_cvc5_abduct_solver (#raw_input translated) (#command translated) (#run_ctxt translated)

    val _ = if debug then
              tracing ("=== CVC5 SOLVER OUTPUT ===\n" ^ space_implode "\n" output_lines ^ "\n=== END CVC5 SOLVER OUTPUT ===")
            else ()

    val {context = replay_ctxt, typs, terms, ...} = #replay_data translated
    val abduct_report =
      parse_cvc5_abduct_outcome (#solver_name translated) replay_ctxt typs terms output_lines
    
    (* Sanitize terms to remove trailing underscores from variable names *)
    fun sanitize_term_names t =
      let
        fun clean_name n = 
           if String.isSuffix "__" n then 
             clean_name (String.substring (n, 0, size n - 2)) 
           else if String.isSuffix "_" n then
             clean_name (String.substring (n, 0, size n - 1))
           else n
      in
        t |> Term.map_aterms (fn Free (n, T) => Free (clean_name n, T)
                               | Var ((n, i), T) => Var ((clean_name n, i), T)
                               | x => x)
      end

    fun resolve_generated_at_ms (SOME elapsed_ms) = stage_start_elapsed_ms + elapsed_ms
      | resolve_generated_at_ms NONE = elapsed_ms_of_timer (#pipeline_timer timing_ctx)

    fun sanitize_timed_term {term = abduct_term, generated_at_ms} =
      {term = sanitize_term_names abduct_term,
       generated_at_ms = resolve_generated_at_ms generated_at_ms}
  in
    #parsed abduct_report |> map_filter I |> map sanitize_timed_term
  end
  handle SMT_Failure.SMT fail =>
    (warning ("CVC5 abduction: SMT failure (" ^
      SMT_Failure.string_of_failure fail ^ ")"); [])

(* ---------- CVC5: Convert Abduct Terms to Facts ---------- *)

fun make_abduct_facts
    (ctxt : Proof.context)
    (index : int)
    (terms : term list)
    : (Sledgehammer_Fact.fact list * int) =
  let
    fun build (remaining : term list) (idx : int) (acc : Sledgehammer_Fact.fact list)
              : (Sledgehammer_Fact.fact list * int) =
      case remaining of
        [] => (rev acc, idx)
      | t :: ts =>
          let
            val name = "abduct_" ^ string_of_int idx
            val stature : Sledgehammer_Prover.stature = (APG.Assum, APG.General)
            val prop : term =
              case Term.fastype_of t of
                Type ("prop", _) => t
              | _ => HOLogic.mk_Trueprop t
            val thm = Thm.assume (Thm.cterm_of ctxt prop)
          in
            build ts (idx + 1) (((name, stature), thm) :: acc)
          end
  in
    build terms index []
  end

(* ---------- CVC5: Prepare Input ---------- *)

fun cvc5_prepare_input
    (prepared : prepared_stage)
    (state : solver_state)
    (config : tactic_input)
    (timing_ctx : timing_context)
    : cvc5_input =
  let
    val stage_ctxt = #stage_ctxt prepared
    val params = #params prepared
    val problem = #problem prepared
    val facts = #facts prepared
    val local_fact_count = #local_fact_count prepared
    val local_fact_count_opt =
      if #use_grammar_assertions config then SOME local_fact_count else NONE
    val stage_start_elapsed_ms = elapsed_ms_of_timer (#pipeline_timer timing_ctx)
    val raw_abduct_terms : timed_term list =
      collect_cvc5_abduct_terms stage_ctxt params problem facts local_fact_count_opt
        (#debug config) stage_start_elapsed_ms timing_ctx
    val abduct_terms : timed_term list =
      filter (is_boolean_term o #term) raw_abduct_terms
    val abduct_term_values = map #term abduct_terms
    val (new_abduct_facts : Sledgehammer_Fact.fact list, abduct_index' : int) =
      if null abduct_term_values then ([], #abduct_index state)
      else make_abduct_facts stage_ctxt (#abduct_index state) abduct_term_values
    val abduct_strings : parsed_abduct list =
      map (fn {term = abduct_term, generated_at_ms} =>
        {content = Syntax.string_of_term stage_ctxt abduct_term,
         generated_at_ms = SOME generated_at_ms}) abduct_terms
    val new_abduct_entries : (string * thm) list =
      map (fn ((name, _), thm) => (name, thm)) new_abduct_facts
    val updated_state : solver_state =
      {fact_override = #fact_override state,
       extra_facts = new_abduct_facts @ #extra_facts state,
       abduct_map = new_abduct_entries @ #abduct_map state,
       abduct_index = abduct_index'}
  in
    {prepared = prepared, updated_state = updated_state, abducts = abduct_strings}
  end

(* ---------- CVC5: Parse Run (No-op for CVC5) ---------- *)

fun cvc5_parse_run (input : cvc5_input) (run : solver_run)
                   : {message: string option, abducts: parsed_abduct list} =
  let
    val message =
      case #result run of
        SOME res => SOME (#message res NONE)
      | NONE => NONE
  in
    {message = message, abducts = #abducts input}
  end

(* ---------- Shared: Stage Output Logic ---------- *)

(* Apply max_limit to abduct collections *)
fun apply_max_limit (max_limit_opt : int option) xs =
  case max_limit_opt of
    NONE => xs
  | SOME n => take (Int.min (n, length xs)) xs

(* Format depth prefix for output header *)
fun format_depth_prefix (abduct_ctx : abduction_context) : string =
  case #parent_index abduct_ctx of
    NONE => ""
  | SOME parent =>
      " (from " ^ #solver_name abduct_ctx ^ "_" ^ string_of_int parent ^
      " at depth " ^ string_of_int (#current_depth abduct_ctx) ^ ")"

(* Print abducts to output as they are emitted. *)
fun print_abducts (timing_ctx : timing_context) (abducts : abduct list) : unit =
  app (fn {source, content, generated_at_ms, sequence_no} =>
    writeln (#live_output_prefix timing_ctx ^
      "ABDUCT GENERATED " ^ string_of_int sequence_no ^
      " [elapsed=" ^ string_of_int generated_at_ms ^ "ms] " ^
      source ^ ": " ^ content)) abducts

fun publish_stage_output
    (timing_ctx : timing_context)
    ({stage, params, result, message, abducts} : stage_output)
    : stage_output =
  let
    val published_abducts =
      map (fn {source, content, generated_at_ms, ...} =>
        {source = source,
         content = content,
         generated_at_ms = generated_at_ms,
         sequence_no = next_sequence_no (#next_sequence_no timing_ctx)}) abducts
    val _ = print_abducts timing_ctx published_abducts
  in
    {stage = stage,
     params = params,
     result = result,
     message = message,
     abducts = published_abducts}
  end

(* Build stage output with common logic, parameterized by max_limit selector. *)
fun make_stage_output
    (prepared : prepared_stage)
    (abduct_ctx : abduction_context)
    (config : tactic_input)
    (run : solver_run)
    (message : string option)
    (all_abducts : parsed_abduct list)
    (get_max_limit : max_facts_config -> int option)
    (timing_ctx : timing_context)
    : stage_output =
  let
    val stage = #stage prepared
    val max_limit_cfg = if #current_depth abduct_ctx > 0 then #max_limit_depth config else #max_limit config
    val max_limit_opt = get_max_limit max_limit_cfg
    val stage_elapsed_ms = elapsed_ms_of_timer (#pipeline_timer timing_ctx)
    fun resolved_generated_at_ms (SOME elapsed_ms) = elapsed_ms
      | resolved_generated_at_ms NONE = stage_elapsed_ms
    val abduct_entries =
      all_abducts
      |> map_index (fn (original_index, {content, generated_at_ms}) =>
          {content = content,
           generated_at_ms = resolved_generated_at_ms generated_at_ms,
           original_index = original_index})
      |> sort (fn ({generated_at_ms = left_ms, original_index = left_index, ...},
                   {generated_at_ms = right_ms, original_index = right_index, ...}) =>
            case int_ord (left_ms, right_ms) of
              EQUAL => int_ord (left_index, right_index)
            | ord => ord)
      |> apply_max_limit max_limit_opt
    val source = #source_chain abduct_ctx
    val abducts =
      map (fn {content, generated_at_ms, ...} =>
        {source = source,
         content = content,
         generated_at_ms = generated_at_ms,
         sequence_no = 0}) abduct_entries
  in
    {stage = stage,
     params = #params prepared,
     result = #result run,
     message = message,
     abducts = abducts}
  end

(* ---------- CVC5: Create Stage Output ---------- *)

fun cvc5_stage_output (config : tactic_input) (abduct_ctx : abduction_context) (input : cvc5_input) (run : solver_run)
                      (parsed : {message: string option, abducts: parsed_abduct list})
                      (timing_ctx : timing_context)
                      : stage_output =
  make_stage_output (#prepared input) abduct_ctx config run (#message parsed) (#abducts parsed) #cvc5 timing_ctx


(* ========================================================================== *)
(* E PROVER ABDUCTION PIPELINE - HELPER FUNCTIONS                            *)
(* ========================================================================== *)

(* ---------- E: Extract Abducts from Messages ---------- *)

fun extract_e_abducts (ctxt : Proof.context) (message : string) : string list =
  if String.isPrefix "Candidate missing assumption" message then
    let
      val lines = String.tokens (fn c => c = #"\n") message
      val content_lines = case lines of [] => [] | _ :: rest => rest
      val trimmed = map (String.implode o Library.trim Char.isSpace o String.explode) content_lines
    in
      filter (fn s => s <> "") trimmed
    end
  else
    []

(* ---------- E: Prepare Input (Pass-through) ---------- *)

fun e_prepare_input (prepared : prepared_stage) (state : solver_state) : e_input =
  {prepared = prepared, original_state = state}

(* ---------- E: Parse Run Results ---------- *)

fun e_parse_run (input : e_input) (run : solver_run)
                : {message: string option, abducts: parsed_abduct list} =
  let
    val prepared = #prepared input
    val params = #params prepared
    val stage_ctxt = #stage_ctxt prepared
    val max_abducts : int =
      the_default Sledgehammer_Prover.default_abduce_max_candidates (#abduce params)
    val messages = #messages run
    val candidates : string list =
      messages
      |> maps (extract_e_abducts stage_ctxt)
      |> distinct (op =)
    val abducts : parsed_abduct list =
      if max_abducts <= 0 then []
      else take (Int.min (max_abducts, length candidates)) candidates
        |> map (fn content => {content = content, generated_at_ms = NONE})
    val message : string option =
      case #result run of
        SOME res =>
          if #outcome res = NONE then
            SOME "completed with abduct candidates"
          else
            SOME (#message res NONE)
      | NONE => NONE
  in
    {message = message, abducts = abducts}
  end

(* ---------- E: Create Stage Output ---------- *)

fun e_stage_output (config : tactic_input) (abduct_ctx : abduction_context) (input : e_input) (run : solver_run)
                   (parsed : {message: string option, abducts: parsed_abduct list})
                   (timing_ctx : timing_context)
                   : stage_output =
  make_stage_output (#prepared input) abduct_ctx config run (#message parsed) (#abducts parsed) #e timing_ctx


(* ========================================================================== *)
(* BREADTH-FIRST EXECUTION: LEVEL BY LEVEL                                   *)
(* ========================================================================== *)

(* Work item for processing at next depth level *)
type work_item =
  {parent_solver: string,       (* "cvc5" or "e" *)
   parent_index: int,            (* which abduct from parent *)
   abduct_str: string,           (* the abduct hypothesis *)
   depth: int,                   (* depth level for this work item *)
   ctxt: Proof.context,
   chained: thm list,
   goal_term: term}              (* the abduct as a term *)

(* Pure function: run a single solver stage and collect abducts *)
fun run_single_stage
    (config : tactic_input)
    (timing_ctx : timing_context)
    (abduct_ctx : abduction_context)
    (state : Proof.state)
    (goal : thm)
    (chained : thm list)
    (subgoal : int)
    (stage : stage)
    (solver_state : solver_state)
    : stage_output * solver_state =
  let
    val debug = #debug config
    val prepared = prepare_stage_input state goal config chained subgoal stage solver_state (#current_depth abduct_ctx)
    val prover_name = stage_prover stage
  in
    if prover_name = cvc5_abduct_name then
      let
        val input = cvc5_prepare_input prepared solver_state config timing_ctx
        val run = run_solver prepared debug
        val parsed = cvc5_parse_run input run
        val output = cvc5_stage_output config abduct_ctx input run parsed timing_ctx
        val updated_state = #updated_state input
      in
        (output, updated_state)
      end
    else (* E prover *)
      let
        val _ = if debug then tracing ("E prover stage starting at depth " ^ string_of_int (#current_depth abduct_ctx)) else ()
        val clean_state = init_solver_state (#fact_override solver_state)
        val prepared' = prepare_stage_input state goal config chained subgoal stage clean_state (#current_depth abduct_ctx)
        val _ = if debug then tracing ("E prover: prepared stage input, about to prepare E input") else ()
        val input = e_prepare_input prepared' clean_state
        val _ = if debug then
                  tracing ("E prover: prepared input, about to run solver with " ^
                          string_of_int (length (#slices prepared')) ^ " slices")
                else ()
        val run = run_solver prepared' debug
        val _ = if debug then tracing ("E prover: solver finished, parsing output") else ()
        val parsed = e_parse_run input run
        val _ = if debug then tracing ("E prover: output parsed, creating stage output") else ()
        val output = e_stage_output config abduct_ctx input run parsed timing_ctx
        val _ = if debug then tracing ("E prover stage completed") else ()
      in
        (output, solver_state)
      end
  end

fun publication_ord
    (((left_branch, left_index), _) : (int * int) * 'a,
     ((right_branch, right_index), _) : (int * int) * 'a) : order =
  (case int_ord (left_branch, right_branch) of
    EQUAL => int_ord (left_index, right_index)
  | ord => ord)

fun branch_result_ord ((left_branch, _) : int * 'a, (right_branch, _) : int * 'a) : order =
  int_ord (left_branch, right_branch)

fun run_stage_branches_eager
    (timing_ctx : timing_context)
    (name : string)
    (branches : (int * ((int -> stage_output -> unit) -> 'a)) list)
    : (int * 'a) list * stage_output list =
  let
    val publications =
      Synchronized.var (name ^ "_publications") ([] : stage_publication list)

    fun emit_output branch_order local_index output =
      Synchronized.change publications (fn events =>
        {branch_order = branch_order, local_index = local_index, output = output} :: events)

    fun drain_publications published =
      let
        val events =
          Synchronized.change_result publications (fn events => (rev events, []))
        val newly_published =
          map (fn {branch_order, local_index, output} =>
            ((branch_order, local_index), publish_stage_output timing_ctx output)) events
      in
        newly_published @ published
      end

    fun published_outputs published =
      published
      |> sort publication_ord
      |> map snd

    fun sorted_results results =
      sort branch_result_ord results

    fun run_sequential [] results published =
          (sorted_results results, published_outputs (drain_publications published))
      | run_sequential ((branch_order, run_branch) :: rest) results published =
          let
            val result = run_branch (emit_output branch_order)
            val published' = drain_publications published
          in
            run_sequential rest ((branch_order, result) :: results) published'
          end

    fun cancel_pending pending = app (Future.cancel o snd) pending

    fun ready_future pending =
      get_first (fn (branch_order, future) =>
        Option.map (fn result => (branch_order, future, result)) (Future.peek future)) pending

    fun remove_branch branch_order =
      filter_out (fn (branch_order', _) => branch_order = branch_order')

    fun run_parallel () =
      let
        val group = Future.new_group NONE
        val futures =
          Future.forks
            {name = name, group = SOME group, deps = [], pri = 0, interrupts = true}
            (map (fn (branch_order, run_branch) =>
              fn () => run_branch (emit_output branch_order)) branches)
        val pending0 = map fst branches ~~ futures

        fun collect pending results published =
          let
            val published' = drain_publications published
          in
            if null pending then
              (sorted_results results, published_outputs published')
            else
              (case ready_future pending of
                SOME (branch_order, _, result) =>
                  let
                    val pending' = remove_branch branch_order pending
                    val branch_result =
                      (case result of
                        Exn.Res value => value
                      | Exn.Exn exn => (cancel_pending pending'; Exn.reraise exn))
                  in
                    collect pending' ((branch_order, branch_result) :: results) published'
                  end
              | NONE =>
                  (OS.Process.sleep (seconds 0.02);
                   collect pending results published'))
          end
      in
        collect pending0 [] []
      end
  in
    if Future.relevant branches then run_parallel ()
    else run_sequential branches [] []
  end

(* Convert stage output abducts to work items for next level *)
fun stage_output_to_work_items
    (output : stage_output)
    (abduct_ctx : abduction_context)
    (stage_ctxt : Proof.context)
    (next_depth : int)
    : work_item list =
  let
    val abducts = #abducts output
    fun make_work_item (i : int, {content = abduct_str, ...} : abduct) : work_item option =
      (SOME {
        parent_solver = #solver_name abduct_ctx,
        parent_index = i,
        abduct_str = abduct_str,
        depth = next_depth,
        ctxt = stage_ctxt,
        chained = [],
        goal_term =
          let
            val clean_str = XML.content_of (YXML.parse_body abduct_str)
          in
            Syntax.read_prop stage_ctxt clean_str
          end
      })
      handle ERROR _ => NONE
           | TERM _ => NONE
           | THM _ => NONE
  in
    map_filter I (map_index (fn (i, ab) => make_work_item (i + 1, ab)) abducts)
  end

(* Process all work items at current depth level, return outputs and next level work items *)
fun process_depth_level
    (config : tactic_input)
    (timing_ctx : timing_context)
    (work_items : work_item list)
    (target_solver : stage)
    (fact_override : fact_override)
    (emit_output : int -> stage_output -> unit)
    : stage_output list * work_item list =
  let
    val debug = #debug config
    val _ = if null work_items then ()
            else if debug then
              tracing ("Processing " ^ string_of_int (length work_items) ^
                      " work items at depth " ^ string_of_int (#depth (hd work_items)))
            else ()

    fun process_work_item (local_index : int, item : work_item) : (stage_output * work_item list) option =
      (let
        val item_ctxt = #ctxt item
        val item_depth = #depth item
        val item_goal_term = #goal_term item
        val abduct_str = #abduct_str item
        val parent_solver = #parent_solver item
        val parent_idx = #parent_index item
        val _ = if debug then
                  tracing ("Processing work item: " ^ parent_solver ^ "_" ^ string_of_int parent_idx ^
                          " at depth " ^ string_of_int item_depth ^
                          " with abduct: " ^ String.substring (abduct_str, 0, Int.min (80, String.size abduct_str)) ^ "...")
                else ()
        (* Create a proper proof state for the abduct *)
        val state = Proof.theorem NONE (K I) [[(item_goal_term, [])]] item_ctxt
        val {goal, ...} = Proof.goal state
        (* Compute source chain: parent_solver -> target_solver (normalized for display) *)
        val target_name = stage_prover target_solver
        val source_chain = normalize_solver_name parent_solver ^ " -> " ^ normalize_solver_name target_name
        val abduct_ctx : abduction_context =
          {solver_name = target_name,
           parent_index = SOME (#parent_index item),
           current_depth = item_depth,
           source_chain = source_chain}
        val solver_state = init_solver_state fact_override
        val (output, _) =
          run_single_stage config timing_ctx abduct_ctx state goal (#chained item) 1 target_solver solver_state
        val _ = emit_output local_index output
        val prepared_ctxt = item_ctxt  (* Use same context for work items *)
        val next_work_items = stage_output_to_work_items output abduct_ctx prepared_ctxt (item_depth + 1)
      in
        SOME (output, next_work_items)
      end)
      handle ERROR msg =>
               (warning ("Work item " ^ #parent_solver item ^ "_" ^ string_of_int (#parent_index item) ^
                        " failed (ERROR): " ^ msg); NONE)
           | TERM (msg, _) =>
               (warning ("Work item " ^ #parent_solver item ^ "_" ^ string_of_int (#parent_index item) ^
                        " failed (TERM): " ^ msg); NONE)
           | THM (msg, _, _) =>
               (warning ("Work item " ^ #parent_solver item ^ "_" ^ string_of_int (#parent_index item) ^
                        " failed (THM): " ^ msg); NONE)
           | Size =>
               (warning ("Work item " ^ #parent_solver item ^ "_" ^ string_of_int (#parent_index item) ^
                        " failed (Size exception from prover)"); NONE)

    val results = map_filter I (map_index process_work_item work_items)
    val outputs = map #1 results
    val all_next_work = maps #2 results
  in
    (outputs, all_next_work)
  end

(* ========================================================================== *)
(* PIPELINE EXECUTION                                                        *)
(* ========================================================================== *)

fun run_pipeline_with_depth
    (state : Proof.state)
    (goal : thm)
    (config: tactic_input)
    (fact_override : fact_override)
    (chained : thm list)
    (subgoal : int)
    (cvc5_stg : stage)
    (e_stg : stage)
    : stage_output list * fact_override * (string * thm) list =
  let
    val ctxt = Proof.context_of state
    val initial_state = init_solver_state fact_override
    val timing_ctx : timing_context =
      {pipeline_timer = Timing.start (),
       next_sequence_no = Synchronized.var "abduct_sequence_no" 1,
       live_output_prefix = current_live_output_prefix ()}
    val max_depth = #depth config

    (* Run depth 0: CVC5 and E independently. *)
    val cvc5_ctx_0 : abduction_context =
      {solver_name = "cvc5", parent_index = NONE, current_depth = 0, source_chain = "cvc5"}
    val e_ctx_0 : abduction_context =
      {solver_name = "e", parent_index = NONE, current_depth = 0, source_chain = "e"}

    val (_, depth0_outputs) =
      run_stage_branches_eager timing_ctx "Mini_Abduct.depth0"
        [(0, fn emit_output =>
          let
            val (output, _) =
              run_single_stage config timing_ctx cvc5_ctx_0 state goal chained subgoal cvc5_stg initial_state
            val _ = emit_output 0 output
          in
            ()
          end),
         (1, fn emit_output =>
          let
            val (output, _) =
              run_single_stage config timing_ctx e_ctx_0 state goal chained subgoal e_stg initial_state
            val _ = emit_output 0 output
          in
            ()
          end)]

    val (cvc5_output_0, e_output_0) =
      (case depth0_outputs of
        [cvc5_output, e_output] => (cvc5_output, e_output)
      | _ => raise Fail "run_pipeline_with_depth: unexpected depth 0 branch count")

    (* Collect work items for depth 1 *)
    val cvc5_work_items_1 = stage_output_to_work_items cvc5_output_0 cvc5_ctx_0 ctxt 1
    val e_work_items_1 = stage_output_to_work_items e_output_0 e_ctx_0 ctxt 1

    (* Process recursion levels breadth-first *)
    fun process_levels (current_depth : int)
                       (cvc5_work : work_item list)
                       (e_work : work_item list)
                       (all_outputs : stage_output list)
                       : stage_output list =
      if current_depth > max_depth then
        all_outputs
      else if null cvc5_work andalso null e_work then
        all_outputs
      else
        let
          fun process_frontier (work, target_solver) emit_output =
            let
              val (_, next_work) =
                if null work then ([], [])
                else process_depth_level config timing_ctx work target_solver fact_override emit_output
            in
              next_work
            end

          (* Process both interchange frontiers in parallel, but keep each frontier sequential. *)
          val (frontier_results, frontier_outputs) =
            run_stage_branches_eager timing_ctx
              ("Mini_Abduct.depth" ^ string_of_int current_depth)
              [(0, process_frontier (e_work, cvc5_stg)),
               (1, process_frontier (cvc5_work, e_stg))]

          fun next_work_for branch_order =
            (case get_first (fn (branch_order', next_work) =>
                if branch_order = branch_order' then SOME next_work else NONE) frontier_results of
              SOME next_work => next_work
            | NONE => [])

          val cvc5_next_work = next_work_for 0
          val e_next_work = next_work_for 1

          val new_outputs = all_outputs @ frontier_outputs
        in
          process_levels (current_depth + 1) cvc5_next_work e_next_work new_outputs
        end

    val all_outputs = process_levels 1 cvc5_work_items_1 e_work_items_1 [cvc5_output_0, e_output_0]
  in
    (all_outputs, fact_override, [])
  end

(* Check if any stage output has abducts *)
fun has_any_abducts (outputs : stage_output list) : bool =
  exists (fn {abducts, ...} => not (null abducts)) outputs

(* Run pipeline and return goal if abducts were found *)
fun pipeline_tac
    (config : tactic_input)
    (state : Proof.state)
    (fact_override : fact_override)
    (chained : thm list)
    (cvc5_stg : stage)
    (e_stg : stage)
    (subgoal : int)
    (goal : thm)
    : thm Seq.seq =
  if subgoal < 1 orelse subgoal > Thm.nprems_of goal then
    Seq.empty
  else
    let
      val (outputs, _, _) =
        run_pipeline_with_depth state goal config fact_override chained subgoal cvc5_stg e_stg
    in
      if has_any_abducts outputs then Seq.single goal else Seq.empty
    end


(* ========================================================================== *)
(* PUBLIC API                                                                *)
(* ========================================================================== *)

fun abduct_sledgehammer_tac
    (state : Proof.state)
    (config : tactic_input)
    : int -> thm -> thm Seq.seq =
  pipeline_tac config state no_fact_override [] cvc5_stage e_stage

fun abduct_sledgehammer_tac_depth
    (state : Proof.state)
    (config : tactic_input)
    : int -> thm -> thm Seq.seq =
  pipeline_tac config state no_fact_override [] cvc5_stage e_stage

fun abduct_sledgehammer_tac_depth_ctxt
    (ctxt : Proof.context)
    (config : tactic_input)
    : int -> thm -> thm Seq.seq =
  fn subgoal => fn goal =>
    let
      val goal_term = Thm.prop_of goal
      val state = Proof.theorem NONE (K I) [[(goal_term, [])]] ctxt
    in
      pipeline_tac config state no_fact_override [] cvc5_stage e_stage subgoal goal
    end

fun get_abducts
    (context : Proof.context)
    (config : tactic_input)
    (subgoal : int)
    (goal : thm)
    : abduct list =
  let
    (* Create a proper proof state with the goal attached.
       Sledgehammer's internal code calls Proof.goal, so we need a real goal. *)
    val goal_term = Thm.prop_of goal
    val state = Proof.theorem NONE (K I) [[(goal_term, [])]] context
    val (outputs, _, _) =
      run_pipeline_with_depth state goal config no_fact_override [] subgoal cvc5_stage e_stage
  in
    sort_abducts_by_time (maps #abducts outputs)
  end


(* ========================================================================== *)
(* SMT-LIB TRANSLATION UTILITIES                                              *)
(* ========================================================================== *)

(* Convert a single Isabelle term to SMT-LIB s-expression format.
   This uses the existing SMT translation infrastructure directly on terms.
   Note: This is a best-effort translation - some terms may not translate cleanly. *)
fun term_to_smtlib (ctxt : Proof.context) (t : term) : string =
  let
    (* Ensure term is a proposition *)
    val prop_t =
      case Term.fastype_of t of
        Type ("prop", _) => t
      | T => if T = HOLogic.boolT then HOLogic.mk_Trueprop t else t

    (* Create a minimal theorem for translation *)
    val cterm = Thm.cterm_of ctxt prop_t
    val thm = Thm.assume cterm

    (* Configure context for SMT translation *)
    val ctxt' = ctxt
      |> Context.proof_map (SMT_Config.select_solver cvc5_abduct_name)

    (* Prepare for translation *)
    val normalized = SMT_Normalize.normalize ctxt' [(SMT_Util.Conjecture, thm)]

    (* Translate using SMT infrastructure - use empty options for normal assertions *)
    val (raw_smtlib, _) =
      SMT_Translate.translate ctxt' cvc5_abduct_name [] [] normalized
  in
    (* Return full SMT-LIB output to include all declarations *)
    raw_smtlib
  end
  handle ERROR _ => "(translation-error)"
       | THM _ => "(translation-error)"
       | TERM _ => "(translation-error)"
       | TYPE _ => "(translation-error)"

(* Check if a term contains schematic variables (Vars) or schematic type variables (TVars)
   that cannot be translated to SMT-LIB via Thm.assume *)
fun has_schematic_vars (t : term) : bool =
  Term.exists_subterm (fn Var _ => true | _ => false) t orelse
  Term.exists_type (Term.exists_subtype (fn TVar _ => true | _ => false)) t

(* Convert a list of hypothesis terms and a goal term to a full SMT-LIB problem.
   hypotheses: List of hypothesis terms (will be asserted)
   display_facts: Additional facts for display/printing purposes (will be asserted but noted as display-only)
   goal: The goal term (will be negated and asserted, or used with get-abduct)
   Note: Terms with schematic variables are filtered out as they cannot be assumed. *)
fun terms_to_smtlib_problem (ctxt : Proof.context) (hypotheses : term list) (display_facts : term list) (goal : term) : string =
  let
    (* Ensure all terms are propositions *)
    fun to_prop t =
      case Term.fastype_of t of
        Type ("prop", _) => t
      | T => if T = HOLogic.boolT then HOLogic.mk_Trueprop t else t

    (* Filter out hypotheses with schematic variables - they can't be assumed *)
    val valid_hypotheses = filter_out has_schematic_vars hypotheses
    val valid_display_facts = filter_out has_schematic_vars display_facts
    val prop_hyps = map to_prop valid_hypotheses
    val prop_display = map to_prop valid_display_facts
    val prop_goal = to_prop goal

    (* Create theorems from terms *)
    fun term_to_thm t = Thm.assume (Thm.cterm_of ctxt t)
    val hyp_thms = map (fn t => (SMT_Util.Hypothesis, term_to_thm t)) prop_hyps
    val display_thms = map (fn t => (SMT_Util.Hypothesis, term_to_thm t)) prop_display
    val goal_thm = (SMT_Util.Conjecture, term_to_thm prop_goal)

    (* All theorems: hypotheses first, then display facts, then goal *)
    val all_thms = hyp_thms @ display_thms @ [goal_thm]

    (* Configure context for SMT translation with abduction support *)
    val ctxt' = ctxt
      |> Context.proof_map (SMT_Config.select_solver cvc5_abduct_name)
      |> ensure_abduct_serializer cvc5_abduct_name

    (* Normalize and translate *)
    val normalized = SMT_Normalize.normalize ctxt' all_thms

    val solver = Abduct_CVC5_Abduct.cvc5_abduct_trace
    val (raw_smtlib, _) =
      SMT_Translate.translate ctxt' cvc5_abduct_name (#smt_options solver) [] normalized
  in
    raw_smtlib
  end
  handle ERROR msg => "; SMT-LIB translation error: " ^ msg
       | THM (msg, _, _) => "; SMT-LIB translation error (THM): " ^ msg
       | TERM (msg, _) => "; SMT-LIB translation error (TERM): " ^ msg
       | TYPE (msg, _, _) => "; SMT-LIB translation error (TYPE): " ^ msg


(* Get the actual SMT-LIB problem that would be sent to CVC5 for abduction.
   This replicates the exact translation done by translate_cvc5_abduct_problem
   to show what CVC5 actually receives, including all declarations and facts.
   exclude_terms: terms to exclude from facts (e.g. dropped premises) *)
fun get_cvc5_smtlib_problem
    (ctxt : Proof.context)
    (config : tactic_input)
    (exclude_terms : term list)
    (subgoal : int)
    (goal : thm)
    : string =
  let
    val thy = Proof_Context.theory_of ctxt
    val timeout = #timeout config
    val timeout_str = string_of_int (Real.ceil timeout)

    (* Build params matching the pipeline *)
    val overrides = [("timeout", timeout_str), ("provers", cvc5_abduct_name)]
    val params = Sledgehammer_Commands.default_params thy overrides

    (* Create fact_override *)
    val fact_override : fact_override = {add = [], del = [], only = false}

    (* Modify config to include exclude_terms *)
    val config' = {
      max_facts = #max_facts config,
      max_facts_depth = #max_facts_depth config,
      max_limit = #max_limit config,
      max_limit_depth = #max_limit_depth config,
      depth = #depth config,
      timeout = timeout,
      debug = #debug config,
      exclude_terms = SOME exclude_terms,
      use_grammar_assertions = #use_grammar_assertions config,
      filter_global_quantifiers = #filter_global_quantifiers config
    }

    (* Select facts using the same mechanism as the pipeline *)
    val (facts, local_fact_count) = select_facts ctxt config' params fact_override [] goal subgoal cvc5_abduct_name 0

    (* Setup context with timeout *)
    val ctxt_timeout = Config.put SMT_Config.timeout (Time.toReal (Time.fromReal timeout)) ctxt

    (* Focus on the subgoal *)
    val ({context = focus_ctxt, prems, concl, ...}, _) =
      Subgoal.focus ctxt_timeout subgoal NONE goal

    (* For abduction, we use the goal directly without negation *)
    val cprop = Thm.rhs_of (SMT_Normalize.atomize_conv focus_ctxt concl)
    val conjecture = Thm.assume cprop

    (* Build theorems list: conjecture + premises + facts *)
    val thms =
      (SMT_Util.Conjecture, conjecture) ::
      map (pair SMT_Util.Hypothesis) prems @
      map (pair SMT_Util.Axiom o snd) facts

    (* Normalize *)
    val normalized =
      let
        val normalized_entries = SMT_Normalize.normalize focus_ctxt thms
        val (conjectures, others) =
          List.partition (fn ((_, role), _) => role = SMT_Util.Conjecture) normalized_entries
        val _ =
          if null conjectures then
            raise SMT_Failure.SMT (SMT_Failure.Other_Failure "no conjecture")
          else ()
        val goal_prop = Thm.term_of cprop
        val (goal_conjs, other_conjs) =
          List.partition (fn (_, thm) => Term.aconv_untyped (goal_prop, Thm.prop_of thm)) conjectures
        val reordered_conjs =
          if null goal_conjs then conjectures
          else other_conjs @ goal_conjs
      in
        others @ reordered_conjs
      end

    (* Configure context for CVC5 abduction *)
    val name = cvc5_abduct_name
    val solver = Abduct_CVC5_Abduct.cvc5_abduct_trace
    val ctxt' = focus_ctxt
      |> Context.proof_map (SMT_Config.select_solver name)
      |> (if Config.get focus_ctxt SH_SMT.smt_builtins then I
          else SMT_Builtin.filter_builtins is_boring_builtin_typ
            #> Config.put SMT_Systems.z3_extensions false)

    (* Build grammar info if enabled *)
    val local_fact_count_opt =
      if #use_grammar_assertions config then SOME local_fact_count
      else NONE

    val ctxt'' = ensure_abduct_serializer_with_grammar local_fact_count_opt (#debug config) name ctxt'
    val cmd_options = (#options solver) ctxt''
    val solver_options = SMT_Config.solver_options_of ctxt''
    val options = cmd_options @ solver_options
    val comments = [implode_space options]

    (* Translate to SMT-LIB *)
    val (raw_input, _) =
      SMT_Translate.translate ctxt'' name (#smt_options solver) comments normalized
  in
    raw_input
  end
  handle ERROR msg => "; SMT-LIB translation error: " ^ msg
       | THM (msg, _, _) => "; SMT-LIB translation error (THM): " ^ msg
       | TERM (msg, _) => "; SMT-LIB translation error (TERM): " ^ msg
       | TYPE (msg, _, _) => "; SMT-LIB translation error (TYPE): " ^ msg
       | SMT_Failure.SMT fail => "; SMT failure: " ^ SMT_Failure.string_of_failure fail


(* ========================================================================== *)
(* FACT INSPECTION UTILITIES                                                  *)
(* ========================================================================== *)

(* Get the facts that a specific solver would use for a given goal.
   prover_name: "cvc5_abduct" or "e"
   exclude_terms: terms to exclude from facts (e.g. dropped premises)
   Returns list of (name, thm) pairs representing the facts *)
fun get_solver_facts
    (ctxt : Proof.context)
    (config : tactic_input)
    (prover_name : string)
    (exclude_terms : term list)
    (subgoal : int)
    (goal : thm)
    : (string * thm) list =
  let
    val thy = Proof_Context.theory_of ctxt
    val timeout_str = string_of_int (Real.ceil (#timeout config))

    (* Build minimal params for fact selection *)
    val overrides = [("timeout", timeout_str), ("provers", prover_name)]
    val params = Sledgehammer_Commands.default_params thy overrides

    (* Create fact_override with exclusions *)
    val fact_override : fact_override = {
      add = [],
      del = [],
      only = false
    }

    (* Modify config to include exclude_terms *)
    val config' = {
      max_facts = #max_facts config,
      max_facts_depth = #max_facts_depth config,
      max_limit = #max_limit config,
      max_limit_depth = #max_limit_depth config,
      depth = #depth config,
      timeout = #timeout config,
      debug = #debug config,
      exclude_terms = SOME exclude_terms,
      use_grammar_assertions = #use_grammar_assertions config,
      filter_global_quantifiers = #filter_global_quantifiers config
    }

    (* Select facts using existing infrastructure *)
    val (facts, _) = select_facts ctxt config' params fact_override [] goal subgoal prover_name 0

    (* Convert to (name, thm) pairs *)
    val result = map (fn ((name, _), thm) => (name, thm)) facts
  in
    result
  end
  handle ERROR _ => []
       | THM _ => []
       | TERM _ => []
       | TYPE _ => []


(* ========================================================================== *)
(* DEFAULT CONFIGURATION AND METHOD SETUP                                     *)
(* ========================================================================== *)

(* Default configuration for the abduce method and command *)
val default_config : tactic_input =
  {max_facts = {cvc5 = SOME 20, e = NONE},
   max_facts_depth = {cvc5 = SOME 6, e = NONE},
   max_limit = {cvc5 = SOME 10, e = SOME 4},
   max_limit_depth = {cvc5 = SOME 30, e = SOME 2},
   depth = 1,
   timeout = 20.0,
   debug = false,
   exclude_terms = NONE,
   use_grammar_assertions = true,
   filter_global_quantifiers = true}

(* Build config from optional arguments *)
fun make_config (depth_opt : int option) (timeout_opt : int option) (facts_opt : int option) : tactic_input =
  {max_facts = {cvc5 = SOME (the_default 20 facts_opt), e = NONE},
   max_facts_depth = {cvc5 = SOME 6, e = NONE},
   max_limit = {cvc5 = SOME 10, e = SOME 4},
   max_limit_depth = {cvc5 = SOME 30, e = SOME 2},
   depth = the_default 1 depth_opt,
   timeout = Real.fromInt (the_default 20 timeout_opt),
   debug = false,
   exclude_terms = NONE,
   use_grammar_assertions = true,
   filter_global_quantifiers = true}

(* Abduce tactic with announcement *)
fun abduce_tac (config : tactic_input) (ctxt : Proof.context) : int -> thm -> thm Seq.seq =
  fn subgoal => fn goal =>
    let
      val _ = writeln "Calling Abduce..."
      val goal_term = Thm.prop_of goal
      val state = Proof.theorem NONE (K I) [[(goal_term, [])]] ctxt
      val _ = Seq.pull (pipeline_tac config state no_fact_override [] cvc5_stage e_stage subgoal goal)
    in
      Seq.single goal
    end

(* Argument parsers with named modifiers (at Token.T list level) *)
val depth_mod : int parser = Args.$$$ "depth" -- Args.colon |-- Parse.nat
val timeout_mod : int parser = Args.$$$ "timeout" -- Args.colon |-- Parse.nat
val facts_mod : int parser = Args.$$$ "facts" -- Args.colon |-- Parse.nat

val args_parser_raw : ((int * int) * int) parser =
  Scan.optional depth_mod 1 -- Scan.optional timeout_mod 20 -- Scan.optional facts_mod 20

(* Combined parser lifted to context_parser *)
val args_parser : ((int * int) * int) context_parser =
  Scan.lift args_parser_raw

(* Method setup for 'abduce'.
   Usage: abduce, abduce depth: 2, abduce depth: 2 timeout: 30 facts: 100 *)
val abduce_method : (Proof.context -> Method.method) context_parser =
  args_parser >> (fn ((depth, timeout), facts) => fn ctxt =>
    let val config = make_config (SOME depth) (SOME timeout) (SOME facts)
    in METHOD (fn _ => HEADGOAL (abduce_tac config ctxt)) end)

fun setup_abduce_method thy =
  let
    val ctxt = Proof_Context.init_global thy
    val registered = can (Method.check_name ctxt) ("abduce", Position.none)
  in
    if registered then thy
    else
      Method.setup \<^binding>\<open>abduce\<close> abduce_method
        "Abductive reasoning using CVC5 and E prover (depth: N, timeout: N, facts: N)" thy
  end

val _ = Theory.setup setup_abduce_method

(* Diagnostic proof command for running abduction without changing the proof state.
   Usage: abduce, abduce depth: 2, abduce depth: 2 timeout: 30 facts: 100 *)
fun run_abduce_command (config : tactic_input) (state : Proof.state) : unit =
  if Proof.goal_finished state then
    writeln "No subgoal!"
  else
    let
      val {facts, goal, ...} = Proof.goal state
      val _ = writeln "Calling Abduce..."
      val _ = Seq.pull (pipeline_tac config state no_fact_override facts cvc5_stage e_stage 1 goal)
    in
      ()
    end

fun command_registered thy name =
  let
    val keywords = Thy_Header.get_keywords thy
  in
    Keyword.is_command keywords name andalso
      not (null (Token.explode0 keywords name |> maps (Outer_Syntax.command_reports thy)))
  end

fun setup_abduce_command () =
  let
    val thy = Context.theory_of (Context.the_generic_context ())
    val keywords = Thy_Header.get_keywords thy
    val name = "abduce"
  in
    if Keyword.is_command keywords name andalso not (command_registered thy name) then
      Outer_Syntax.command (name, \<^here>)
        "run abductive reasoning using CVC5 and E prover"
        (args_parser_raw >> (fn ((depth, timeout), facts) =>
          let val config = make_config (SOME depth) (SOME timeout) (SOME facts)
          in Toplevel.keep_proof (run_abduce_command config o Toplevel.proof_of) end))
    else
      ()
  end

val _ = setup_abduce_command ()

end
