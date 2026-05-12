(*  Title:      Abduct/mirabelle_abduct.ML
    Author:     Custom Mirabelle Action

Custom Mirabelle action: "abduct"

This action runs the CVC5/E abduction pipeline on proof goals where a premise
has been dropped. It logs the abduction results, including:
- Which premise was dropped
- The abduct hypotheses suggested by the solvers
- Timing information

This is the benchmark action that tests the Mini_Abduct_Sledgehammer tactic.
*)

structure Mirabelle_Abduct: MIRABELLE_ACTION =
struct

(* Configuration parameters *)
val random_seedK = "random_seed" (*=INT: random seed for premise selection*)
val timeoutK = "timeout" (*=REAL: timeout in seconds*)
val depthK = "depth" (*=INT: recursion depth for abduction*)
val debugK = "debug" (*=BOOL: enable debug output*)
val max_facts_cvc5K = "max_facts_cvc5" (*=INT: max facts for cvc5*)
val max_facts_eK = "max_facts_e" (*=INT: max facts for e*)
val max_limit_cvc5K = "max_limit_cvc5" (*=INT: max abducts from cvc5*)
val max_limit_eK = "max_limit_e" (*=INT: max abducts from e*)
val test_premisesK = "test_premises" (*=BOOL: test if abducts imply dropped premise*)
val test_timeoutK = "test_timeout" (*=REAL: timeout for premise testing*)
val test_provableK = "test_provable" (*=BOOL: test if abducts are provable with Sledgehammer*)
val job_idK = "job_id" (*=INT: this worker's job ID (0-indexed)*)
val total_jobsK = "total_jobs" (*=INT: total number of parallel workers*)
val max_goals_per_theoryK = "max_goals_per_theory" (*=INT: max benchmark proof commands per theory; 0 = unbounded*)
val use_grammar_assertionsK = "use_grammar_assertions" (*=BOOL: use grammar assertions in CVC5*)
val grammar_assertions_modeK = "grammar_assertions_mode" (*=STRING: enabled, disabled, or both *)
val filter_global_quantifiersK = "filter_global_quantifiers" (*=BOOL: filter out global facts with quantifiers*)

(* Defaults *)
val random_seed_default = 42
val timeout_default = 60.0
val depth_default = 1
val debug_default = false
val max_facts_cvc5_default = SOME 20
val max_facts_e_default = NONE
val max_limit_cvc5_default = SOME 20
val max_limit_e_default = SOME 5
val test_premises_default = false
val test_timeout_default = 10.0
val test_provable_default = false
val job_id_default = 0
val total_jobs_default = 1
val max_goals_per_theory_default = 0
val use_grammar_assertions_default = true
val filter_global_quantifiers_default = true

datatype grammar_assertions_mode =
    Grammar_Assertions_Enabled
  | Grammar_Assertions_Disabled
  | Grammar_Assertions_Both

type action_config = {
  max_facts: Mini_Abduct_Sledgehammer.max_facts_config,
  max_limit: Mini_Abduct_Sledgehammer.max_facts_config,
  depth: int,
  timeout: real,
  debug: bool,
  test_premises: bool,
  test_timeout: real,
  test_provable: bool,
  use_grammar_assertions: bool,
  filter_global_quantifiers: bool
}

fun parse_grammar_assertions_mode (raw : string) : grammar_assertions_mode =
  case raw of
    "enabled" => Grammar_Assertions_Enabled
  | "disabled" => Grammar_Assertions_Disabled
  | "both" => Grammar_Assertions_Both
  | "true" => Grammar_Assertions_Enabled
  | "false" => Grammar_Assertions_Disabled
  | _ =>
      error ("Invalid " ^ grammar_assertions_modeK ^ " value: " ^ raw ^
        " (expected enabled, disabled, both, true, or false)")

fun string_of_grammar_assertions_mode mode =
  case mode of
    Grammar_Assertions_Enabled => "enabled"
  | Grammar_Assertions_Disabled => "disabled"
  | Grammar_Assertions_Both => "both"

fun mode_label_of_use_grammar_assertions use_grammar_assertions =
  if use_grammar_assertions then "enabled" else "disabled"

fun config_with_grammar_assertions (config : action_config) (use_grammar_assertions : bool) : action_config =
  {
    max_facts = #max_facts config,
    max_limit = #max_limit config,
    depth = #depth config,
    timeout = #timeout config,
    debug = #debug config,
    test_premises = #test_premises config,
    test_timeout = #test_timeout config,
    test_provable = #test_provable config,
    use_grammar_assertions = use_grammar_assertions,
    filter_global_quantifiers = #filter_global_quantifiers config
  }

fun grammar_assertions_runs (mode : grammar_assertions_mode) (config : action_config)
    : (string * action_config) list =
  case mode of
    Grammar_Assertions_Enabled =>
      [(mode_label_of_use_grammar_assertions true, config_with_grammar_assertions config true)]
  | Grammar_Assertions_Disabled =>
      [(mode_label_of_use_grammar_assertions false, config_with_grammar_assertions config false)]
  | Grammar_Assertions_Both =>
      [(mode_label_of_use_grammar_assertions true, config_with_grammar_assertions config true),
       (mode_label_of_use_grammar_assertions false, config_with_grammar_assertions config false)]

(* Statistics tracking *)
datatype stats = Stats of {
  total_calls: int,
  with_abducts: int,
  no_abducts: int,
  errors: int,
  no_premises: int,
  total_time_ms: int,
  total_abducts: int,
  (* Premise testing stats *)
  abducts_tested: int,
  abducts_proved: int,
  abducts_not_proved: int,
  (* Provability testing stats *)
  provable_tested: int,
  provable_proved: int,
  provable_not_proved: int}

fun empty_stats () = Stats {
  total_calls = 0,
  with_abducts = 0,
  no_abducts = 0,
  errors = 0,
  no_premises = 0,
  total_time_ms = 0,
  total_abducts = 0,
  abducts_tested = 0,
  abducts_proved = 0,
  abducts_not_proved = 0,
  provable_tested = 0,
  provable_proved = 0,
  provable_not_proved = 0}

fun inc_total (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls + 1, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun inc_with_abducts n (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts + 1, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts + n,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun inc_no_abducts (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts + 1,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun inc_error (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors + 1, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun inc_no_premises (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises + 1, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun add_time ms (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms + ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun add_premise_test_results proved not_proved (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested + proved + not_proved, abducts_proved = abducts_proved + proved, abducts_not_proved = abducts_not_proved + not_proved,
    provable_tested = provable_tested, provable_proved = provable_proved, provable_not_proved = provable_not_proved}

fun add_provable_test_results proved not_proved (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  Stats {total_calls = total_calls, with_abducts = with_abducts, no_abducts = no_abducts,
    errors = errors, no_premises = no_premises, total_time_ms = total_time_ms, total_abducts = total_abducts,
    abducts_tested = abducts_tested, abducts_proved = abducts_proved, abducts_not_proved = abducts_not_proved,
    provable_tested = provable_tested + proved + not_proved, provable_proved = provable_proved + proved, provable_not_proved = provable_not_proved + not_proved}

(* Extract hypotheses from context assumptions *)
fun get_hypotheses ctxt _ =
  (let
    val premise_assms = (Assumption.all_assms_of ctxt handle Match => [])
    val premises = List.map Thm.term_of premise_assms
  in
    premises
  end)
  handle TERM _ => []
    | THM _ => []

(* Helper: filter list by index *)
fun filter_by_index f xs =
  let
    fun go _ [] = []
      | go i (x :: xs) = if f i then x :: go (i + 1) xs else go (i + 1) xs
  in
    go 0 xs
  end

(* Select random hypothesis using PRNG *)
fun select_random_premise seed premises =
  if null premises then NONE
  else
    let
      val n = length premises
      val prng_state = MLCG.initialize seed
      val (rand_val, _) = MLCG.next prng_state
      val index = Int.abs rand_val mod n
    in
      SOME (nth premises index, index)
    end

fun accept_theory_goal max_goals_per_theory theory_goal_counts theory_index =
  if max_goals_per_theory <= 0 then true
  else
    Synchronized.change_result theory_goal_counts (fn counts =>
      let
        val count = the_default 0 (AList.lookup (op =) counts theory_index)
      in
        if count >= max_goals_per_theory then
          (false, counts)
        else
          (true, AList.update (op =) (theory_index, count + 1) counts)
      end)

fun theory_goal_cap_reached max_goals_per_theory theory_goal_counts theory_index =
  max_goals_per_theory > 0 andalso
    let
      val counts = Synchronized.value theory_goal_counts
      val count = the_default 0 (AList.lookup (op =) counts theory_index)
    in
      count >= max_goals_per_theory
    end

(* Run abduction tactic and return results with optional error message.
   Preserves any partial results even if an exception occurs. *)
fun run_abduction ctxt (config : action_config) dropped_premise goal =
  let
    val tactic_input : Mini_Abduct_Sledgehammer.tactic_input = {
      max_facts = #max_facts config,
      max_facts_depth = #max_facts config,
      max_limit = #max_limit config,
      max_limit_depth = #max_limit config,
      depth = #depth config,
      timeout = #timeout config,
      debug = #debug config,
      exclude_terms = SOME [dropped_premise],
      use_grammar_assertions = #use_grammar_assertions config,
      filter_global_quantifiers = #filter_global_quantifiers config
    }

    (* Use refs to preserve partial results on exception *)
    val abducts_ref : Mini_Abduct_Sledgehammer.abduct list Unsynchronized.ref = Unsynchronized.ref []
    val error_ref : string option Unsynchronized.ref = Unsynchronized.ref NONE

    val (_, cpu_time) = Mirabelle.cpu_time (fn () =>
      let
        val results = Mini_Abduct_Sledgehammer.get_abducts ctxt tactic_input 1 goal
        val _ = abducts_ref := results
      in () end
      handle ERROR msg => error_ref := SOME ("ERROR: " ^ msg)
           | Timeout.TIMEOUT _ => error_ref := SOME "TIMEOUT: Abduction timed out"
           | Fail msg => error_ref := SOME ("FAIL: " ^ msg)
           | THM (msg, _, _) => error_ref := SOME ("THM: " ^ msg)
           | TERM (msg, _) => error_ref := SOME ("TERM: " ^ msg)
           | TYPE (msg, _, _) => error_ref := SOME ("TYPE: " ^ msg)) ()
  in
    (!abducts_ref, cpu_time, !error_ref)
  end

(* Format statistics for logging *)
fun format_stats (Stats {total_calls, with_abducts, no_abducts, errors, no_premises, total_time_ms, total_abducts, abducts_tested, abducts_proved, abducts_not_proved, provable_tested, provable_proved, provable_not_proved}) =
  let
    fun percentage a b = if b = 0 then "0.0" else
      Real.fmt (StringCvt.FIX (SOME 1)) (Real.fromInt (a * 100) / Real.fromInt b)
    fun avg_time t n = if n > 0 then
      Real.fmt (StringCvt.FIX (SOME 3)) (Real.fromInt t / 1000.0 / Real.fromInt n)
      else "0.000"
    fun avg_abducts a n = if n > 0 then
      Real.fmt (StringCvt.FIX (SOME 2)) (Real.fromInt a / Real.fromInt n)
      else "0.00"
  in
    "\n=== Abduction Benchmark Statistics ===" ^
    "\nTotal calls: " ^ string_of_int total_calls ^
    "\nWith abducts: " ^ string_of_int with_abducts ^
      " (" ^ percentage with_abducts total_calls ^ "%)" ^
    "\nNo abducts: " ^ string_of_int no_abducts ^
      " (" ^ percentage no_abducts total_calls ^ "%)" ^
    "\nErrors: " ^ string_of_int errors ^
      " (" ^ percentage errors total_calls ^ "%)" ^
    "\nGoals with no premises: " ^ string_of_int no_premises ^
    "\nTotal abducts found: " ^ string_of_int total_abducts ^
    "\nAverage abducts per goal: " ^ avg_abducts total_abducts with_abducts ^
    "\nTotal time: " ^ Real.fmt (StringCvt.FIX (SOME 3)) (Real.fromInt total_time_ms / 1000.0) ^ "s" ^
    "\nAverage time: " ^ avg_time total_time_ms total_calls ^ "s" ^
    (if abducts_tested > 0 then
      "\n--- Premise Testing ---" ^
      "\nAbducts tested: " ^ string_of_int abducts_tested ^
      "\nAbducts proved (valid): " ^ string_of_int abducts_proved ^
        " (" ^ percentage abducts_proved abducts_tested ^ "%)" ^
      "\nAbducts not proved (may be weak): " ^ string_of_int abducts_not_proved ^
        " (" ^ percentage abducts_not_proved abducts_tested ^ "%)"
    else "") ^
    (if provable_tested > 0 then
      "\n--- Provability Testing (Sledgehammer with full context) ---" ^
      "\nAbducts tested: " ^ string_of_int provable_tested ^
      "\nAbducts provable: " ^ string_of_int provable_proved ^
        " (" ^ percentage provable_proved provable_tested ^ "%)" ^
      "\nAbducts not provable: " ^ string_of_int provable_not_proved ^
        " (" ^ percentage provable_not_proved provable_tested ^ "%)"
    else "")
  end

(* Main action implementation *)
fun make_action ({arguments, timeout, output_dir, index, ...} : Mirabelle.action_context) =
  let
    (* Parse arguments *)
    val random_seed = Mirabelle.get_int_argument arguments (random_seedK, random_seed_default)
    val action_timeout =
      case AList.lookup (op =) arguments timeoutK of
        SOME s => (case Real.fromString s of SOME r => r | NONE => timeout_default)
      | NONE => timeout_default
    val depth = Mirabelle.get_int_argument arguments (depthK, depth_default)
    val debug = Mirabelle.get_bool_argument arguments (debugK, debug_default)

    val max_facts_cvc5 =
      case AList.lookup (op =) arguments max_facts_cvc5K of
        SOME s => Int.fromString s
      | NONE => max_facts_cvc5_default
    val max_facts_e =
      case AList.lookup (op =) arguments max_facts_eK of
        SOME s => Int.fromString s
      | NONE => max_facts_e_default
    val max_limit_cvc5 =
      case AList.lookup (op =) arguments max_limit_cvc5K of
        SOME s => Int.fromString s
      | NONE => max_limit_cvc5_default
    val max_limit_e =
      case AList.lookup (op =) arguments max_limit_eK of
        SOME s => Int.fromString s
      | NONE => max_limit_e_default
    val test_premises = Mirabelle.get_bool_argument arguments (test_premisesK, test_premises_default)
    val test_timeout =
      case AList.lookup (op =) arguments test_timeoutK of
        SOME s => (case Real.fromString s of SOME r => r | NONE => test_timeout_default)
      | NONE => test_timeout_default
    val test_provable = Mirabelle.get_bool_argument arguments (test_provableK, test_provable_default)
    val job_id = Mirabelle.get_int_argument arguments (job_idK, job_id_default)
    val total_jobs = Mirabelle.get_int_argument arguments (total_jobsK, total_jobs_default)
    val max_goals_per_theory =
      Mirabelle.get_int_argument arguments (max_goals_per_theoryK, max_goals_per_theory_default)
    val _ =
      if max_goals_per_theory >= 0 then ()
      else error (max_goals_per_theoryK ^ " must be non-negative")
    val use_grammar_assertions = Mirabelle.get_bool_argument arguments (use_grammar_assertionsK, use_grammar_assertions_default)
    val grammar_assertions_mode =
      case AList.lookup (op =) arguments grammar_assertions_modeK of
        SOME s => parse_grammar_assertions_mode s
      | NONE =>
          parse_grammar_assertions_mode
            (if use_grammar_assertions then "enabled" else "disabled")
    val filter_global_quantifiers = Mirabelle.get_bool_argument arguments (filter_global_quantifiersK, filter_global_quantifiers_default)
    val cvc5_available = Abduct_CVC5_Abduct.cvc5_available ()
    val cvc5_status_message = Abduct_CVC5_Abduct.cvc5_status_message ()
    val _ =
      if cvc5_available then ()
      else error ("CVC5 is not available for abduction.\n" ^ cvc5_status_message)

    val config : action_config = {
      max_facts = {cvc5 = max_facts_cvc5, e = max_facts_e} : Mini_Abduct_Sledgehammer.max_facts_config,
      max_limit = {cvc5 = max_limit_cvc5, e = max_limit_e} : Mini_Abduct_Sledgehammer.max_facts_config,
      depth = depth,
      timeout = action_timeout,
      debug = debug,
      test_premises = test_premises,
      test_timeout = test_timeout,
      test_provable = test_provable,
      use_grammar_assertions = use_grammar_assertions,
      filter_global_quantifiers = filter_global_quantifiers
    }

    (* Shared statistics *)
    val stats = Synchronized.var "abduct_stats" (empty_stats ())
    (* Goal counter for job distribution *)
    val goal_counter = Synchronized.var "goal_counter" 0
    val theory_goal_counts = Synchronized.var "theory_goal_counts" ([] : (int * int) list)

    val init_msg =
      "Abduction benchmark action initialized\n" ^
      "Random seed: " ^ string_of_int random_seed ^ "\n" ^
      "Timeout: " ^ Real.toString action_timeout ^ "s\n" ^
      "Depth: " ^ string_of_int depth ^ "\n" ^
      "Debug: " ^ Bool.toString debug ^ "\n" ^
      "Test premises: " ^ Bool.toString test_premises ^
      (if test_premises then " (timeout: " ^ Real.toString test_timeout ^ "s)" else "") ^ "\n" ^
      "Test provable: " ^ Bool.toString test_provable ^
      (if test_provable then " (timeout: " ^ Real.toString test_timeout ^ "s)" else "") ^ "\n" ^
      "Max goals per theory: " ^
        (if max_goals_per_theory <= 0 then "unbounded" else string_of_int max_goals_per_theory) ^ "\n" ^
      "Grammar assertions mode: " ^ string_of_grammar_assertions_mode grammar_assertions_mode ^ "\n" ^
      "Filter global quantifiers: " ^ Bool.toString filter_global_quantifiers ^ "\n" ^
      cvc5_status_message ^ "\n" ^
      "Job: " ^ string_of_int job_id ^ "/" ^ string_of_int total_jobs ^
      (if total_jobs > 1 then " (processing goals where index mod " ^ string_of_int total_jobs ^ " = " ^ string_of_int job_id ^ ")" else "")

    (* Process each proof command *)
    fun run ({theory_index, pos, pre, ...} : Mirabelle.command) =
      let
        val cap_already_reached =
          theory_goal_cap_reached max_goals_per_theory theory_goal_counts theory_index
      in
        if cap_already_reached then ""
        else
      let
        val {context = ctxt, facts = _, goal} = Proof.goal pre
        val premises = get_hypotheses ctxt goal
      in
        if null premises then
          let
            val _ = Synchronized.change stats inc_no_premises
          in
            "No premises available to drop"
          end
        else
      let
        val accepted_by_theory_cap =
          accept_theory_goal max_goals_per_theory theory_goal_counts theory_index
      in
        if not accepted_by_theory_cap then
          ""
        else
      let
        (* Get current accepted proof problem index and increment counter atomically *)
        val goal_index = Synchronized.change_result goal_counter (fn n => (n, n + 1))
      in
        (* Skip this accepted proof problem if it doesn't belong to this worker *)
        if total_jobs > 1 andalso goal_index mod total_jobs <> job_id then
          ""  (* Empty string = skip, no output *)
        else
          let
            (* Generate seed from position for deterministic randomness *)
            val line = the_default 0 (Position.line_of pos)
            val offset = the_default 0 (Position.offset_of pos)
            val seed = random_seed + theory_index * 10000 + line * 100 + offset

            (* Select random premise to drop *)
            val (dropped_premise, premise_idx) = the (select_random_premise seed premises)
            val premise_str = Protocol_Message.clean_output (Syntax.string_of_term ctxt dropped_premise)

            (* Convert dropped premise to SMT-LIB format *)
            val dropped_premise_smtlib =
              (Mini_Abduct_Sledgehammer.term_to_smtlib ctxt dropped_premise)
              handle ERROR _ => "; SMT-LIB translation failed"
                   | THM _ => "; SMT-LIB translation failed"
                   | TERM _ => "; SMT-LIB translation failed"
                   | TYPE _ => "; SMT-LIB translation failed"

            (* Show what goal would look like without the premise *)
            val (_, hyp_ts, concl_t) = ATP_Util.strip_subgoal goal 1 ctxt
            val remaining_hyps = filter_by_index (fn i => i <> premise_idx) hyp_ts
            val modified_goal_str =
              Protocol_Message.clean_output (Syntax.string_of_term ctxt (Logic.list_implies (remaining_hyps, concl_t)))
              handle TERM _ => "<error formatting goal>"
                   | TYPE _ => "<error formatting goal>"

            fun render_mode_output ((mode_label, mode_config) : string * action_config) =
              let
                (* Run abduction with the dropped premise excluded *)
                val live_prefix = "[grammar_assertions=" ^ mode_label ^ "] "
                val (abducts, cpu_time, error_msg) =
                  Mini_Abduct_Sledgehammer.with_live_output_prefix live_prefix
                    (fn () => run_abduction ctxt mode_config dropped_premise goal)

                (* Update statistics *)
                val _ = Synchronized.change stats (fn s =>
                  s |> inc_total
                    |> add_time cpu_time
                    |> (if null abducts then inc_no_abducts else inc_with_abducts (length abducts)))

                fun format_abduct_prefix idx source generated_at_ms =
                  "  " ^ string_of_int (idx + 1) ^ ". " ^ source ^
                  " [elapsed=" ^ string_of_int generated_at_ms ^ "ms]: "

                (* Format abducts in Isabelle format with source provenance *)
                val abducts_str =
                  if null abducts then "  (none)"
                  else String.concatWith "\n" (map_index (fn (i, {source, content, generated_at_ms, ...}) =>
                    format_abduct_prefix i source generated_at_ms ^ content) abducts)

                (* Parse abduct strings to terms and convert to SMT-LIB format *)
                fun abduct_to_smtlib (idx, {source, content = abduct_str, generated_at_ms, ...}) =
                  let
                    val clean_str = XML.content_of (YXML.parse_body abduct_str)
                    val term_opt =
                      (SOME (Syntax.read_prop ctxt clean_str))
                      handle ERROR _ => NONE
                           | TERM _ => NONE
                           | TYPE _ => NONE
                    fun translate_term t =
                      (Mini_Abduct_Sledgehammer.term_to_smtlib ctxt t)
                      handle ERROR _ => "; translation failed"
                           | THM _ => "; translation failed"
                           | TERM _ => "; translation failed"
                           | TYPE _ => "; translation failed"
                    val smtlib_str =
                      case term_opt of
                        SOME t => translate_term t
                      | NONE => "; parse failed"
                  in
                    format_abduct_prefix idx source generated_at_ms ^ smtlib_str
                  end

                val abducts_smtlib_str =
                  if null abducts then "  (none)"
                  else String.concatWith "\n" (map_index (fn (i, ab) => abduct_to_smtlib (i, ab)) abducts)

                (* Get facts for CVC5 and E to show what each solver sees *)
                val tactic_config : Mini_Abduct_Sledgehammer.tactic_input = {
                  max_facts = #max_facts mode_config,
                  max_facts_depth = #max_facts mode_config,
                  max_limit = #max_limit mode_config,
                  max_limit_depth = #max_limit mode_config,
                  depth = #depth mode_config,
                  timeout = #timeout mode_config,
                  debug = #debug mode_config,
                  exclude_terms = SOME [dropped_premise],
                  use_grammar_assertions = #use_grammar_assertions mode_config,
                  filter_global_quantifiers = #filter_global_quantifiers mode_config
                }

                val cvc5_prover_name = "cvc5_abduct"
                val e_prover_name = "e"

                val cvc5_facts = Mini_Abduct_Sledgehammer.get_solver_facts
                  ctxt tactic_config cvc5_prover_name [dropped_premise] 1 goal
                val e_facts = Mini_Abduct_Sledgehammer.get_solver_facts
                  ctxt tactic_config e_prover_name [dropped_premise] 1 goal

                fun thm_prop_eq (thm1, thm2) = Thm.eq_thm_prop (thm1, thm2)
                fun is_in_cvc5 (_, e_thm) =
                  exists (fn (_, cvc5_thm) => thm_prop_eq (e_thm, cvc5_thm)) cvc5_facts
                val e_additional_facts = filter_out is_in_cvc5 e_facts

                fun has_schematic_vars t =
                  Term.exists_subterm (fn Var _ => true | _ => false) t orelse
                  Term.exists_type (Term.exists_subtype (fn TVar _ => true | _ => false)) t
                val e_ground_facts = filter_out (fn (_, thm) => has_schematic_vars (Thm.prop_of thm)) e_additional_facts
                val e_schematic_count = length e_additional_facts - length e_ground_facts
                val e_facts_terms = map (fn (_, thm) => Thm.prop_of thm) e_ground_facts

                val smtlib_problem =
                  (Mini_Abduct_Sledgehammer.get_cvc5_smtlib_problem ctxt tactic_config [dropped_premise] 1 goal)
                  handle ERROR msg => "; SMT-LIB translation failed: " ^ msg
                       | THM _ => "; SMT-LIB translation failed (THM)"
                       | TERM _ => "; SMT-LIB translation failed (TERM)"
                       | TYPE _ => "; SMT-LIB translation failed (TYPE)"

                val smtlib_clean = Protocol_Message.clean_output smtlib_problem

                val e_facts_smtlib_display =
                  if null e_facts_terms then "(no ground E additional facts)"
                  else
                    (let
                      val e_smtlib = Mini_Abduct_Sledgehammer.terms_to_smtlib_problem ctxt e_facts_terms [] concl_t
                      val lines = String.tokens (fn c => c = #"\n") e_smtlib
                      val relevant_lines = filter (fn s =>
                        String.isPrefix "(declare-sort" s orelse
                        String.isPrefix "(declare-fun" s orelse
                        String.isPrefix "(assert" s) lines
                    in
                      String.concatWith "\n" relevant_lines
                    end
                    handle ERROR _ => "(E facts translation failed)"
                         | THM _ => "(E facts translation failed)"
                         | TERM _ => "(E facts translation failed)"
                         | TYPE _ => "(E facts translation failed)")

                val premise_test_results =
                  if not (#test_premises mode_config) orelse null abducts then
                    ("", 0, 0, 0, 0)
                  else
                    let
                      fun test_abduct {source, content = abduct_str, ...} =
                        let
                          val clean_str = XML.content_of (YXML.parse_body abduct_str)
                        in
                          (case (Syntax.read_prop ctxt clean_str) of
                            abduct_term =>
                              let
                                val result = Premise_Testing.test_bidirectional ctxt remaining_hyps abduct_term dropped_premise (#test_timeout mode_config)
                              in
                                (source, clean_str, result)
                              end)
                          handle ERROR msg => (source, clean_str,
                            Premise_Testing.BidirResult {
                              premise_implies_abduct = Premise_Testing.Error ("Parse error: " ^ msg),
                              abduct_implies_premise = Premise_Testing.Error ("Parse error: " ^ msg)})
                               | TERM (msg, _) => (source, clean_str,
                            Premise_Testing.BidirResult {
                              premise_implies_abduct = Premise_Testing.Error ("Term error: " ^ msg),
                              abduct_implies_premise = Premise_Testing.Error ("Term error: " ^ msg)})
                               | TYPE (msg, _, _) => (source, clean_str,
                            Premise_Testing.BidirResult {
                              premise_implies_abduct = Premise_Testing.Error ("Type error: " ^ msg),
                              abduct_implies_premise = Premise_Testing.Error ("Type error: " ^ msg)})
                        end

                      val results = map test_abduct abducts

                      fun is_proved (Premise_Testing.Proved _) = true
                        | is_proved _ = false

                      fun get_counts (Premise_Testing.BidirResult {premise_implies_abduct, abduct_implies_premise}) =
                        (is_proved premise_implies_abduct, is_proved abduct_implies_premise)

                      val counts = map (fn (_, _, r) => get_counts r) results
                      val p_implies_a_count = length (filter fst counts)
                      val a_implies_p_count = length (filter snd counts)
                      val equivalent_count = length (filter (fn (a, b) => a andalso b) counts)
                      val incomparable_count = length (filter (fn (a, b) => not a andalso not b) counts)

                      val _ = Synchronized.change stats (add_premise_test_results a_implies_p_count (length results - a_implies_p_count))

                      val results_str =
                        String.concatWith "\n" (map_index (fn (i, (src, abduct_str, result)) =>
                          "  " ^ string_of_int (i + 1) ^ ". " ^ src ^ ": " ^
                          "P=" ^ premise_str ^ " | A=" ^ abduct_str ^ " | " ^
                          Premise_Testing.string_of_bidir_result result) results)
                    in
                      (results_str, p_implies_a_count, a_implies_p_count, equivalent_count, incomparable_count)
                    end

                val (premise_test_str, p_implies_a, a_implies_p, equivalent, incomparable) = premise_test_results

                val provable_test_results =
                  if not (#test_provable mode_config) orelse null abducts then
                    ("", 0, 0)
                  else
                    let
                      fun test_provable_abduct {source, content = abduct_str, ...} =
                        let
                          val clean_str = XML.content_of (YXML.parse_body abduct_str)
                        in
                          (case (Syntax.read_prop ctxt clean_str) of
                            abduct_term =>
                              let
                                val result = Premise_Testing.test_provable_with_context ctxt premises abduct_term (#test_timeout mode_config)
                              in
                                (source, clean_str, result)
                              end)
                          handle ERROR msg => (source, clean_str, Premise_Testing.Error ("Parse error: " ^ msg))
                               | TERM (msg, _) => (source, clean_str, Premise_Testing.Error ("Term error: " ^ msg))
                               | TYPE (msg, _, _) => (source, clean_str, Premise_Testing.Error ("Type error: " ^ msg))
                        end

                      val results = map test_provable_abduct abducts

                      fun is_proved (Premise_Testing.Proved _) = true
                        | is_proved _ = false

                      val proved_count = length (filter (fn (_, _, r) => is_proved r) results)
                      val not_proved_count = length results - proved_count

                      val _ = Synchronized.change stats (add_provable_test_results proved_count not_proved_count)

                      val results_str =
                        String.concatWith "\n" (map_index (fn (i, (src, abduct_str, result)) =>
                          "  " ^ string_of_int (i + 1) ^ ". " ^ src ^ ": " ^
                          abduct_str ^ " | " ^
                          Premise_Testing.string_of_result result) results)
                    in
                      (results_str, proved_count, not_proved_count)
                    end

                val (provable_test_str, provable_count, not_provable_count) = provable_test_results
              in
                "GRAMMAR ASSERTIONS MODE: " ^ mode_label ^ "\n" ^
                "DROPPED PREMISE [" ^ string_of_int (premise_idx + 1) ^ "/" ^
                string_of_int (length premises) ^ "]: " ^ premise_str ^ "\n" ^
                "DROPPED PREMISE (SMT-LIB): " ^ dropped_premise_smtlib ^ "\n" ^
                "GOAL WITHOUT PREMISE: " ^ modified_goal_str ^ "\n" ^
                "ABDUCTION TIME: " ^ string_of_int cpu_time ^ "ms\n" ^
                (case error_msg of SOME msg => "ABDUCTION ERROR: " ^ msg ^ "\n" | NONE => "") ^
                "ABDUCTS FOUND (" ^ string_of_int (length abducts) ^ "):\n" ^ abducts_str ^ "\n" ^
                "ABDUCTS (SMT-LIB):\n" ^ abducts_smtlib_str ^ "\n" ^
                (if #test_premises mode_config andalso not (null abducts) then
                  "PREMISE vs ABDUCT RELATIONSHIP TEST:\n" ^
                  "  Legend: P = Dropped Premise, A = Abduct\n" ^
                  "  Summary: " ^ string_of_int equivalent ^ " equivalent (P<=>A), " ^
                    string_of_int (p_implies_a - equivalent) ^ " weaker (P=>A only), " ^
                    string_of_int (a_implies_p - equivalent) ^ " stronger (A=>P only), " ^
                    string_of_int incomparable ^ " incomparable\n" ^
                  premise_test_str ^ "\n"
                else "") ^
                (if #test_provable mode_config andalso not (null abducts) then
                  "ABDUCT PROVABILITY TEST (Sledgehammer with full context):\n" ^
                  "  Summary: " ^ string_of_int provable_count ^ " provable, " ^
                    string_of_int not_provable_count ^ " not provable\n" ^
                  provable_test_str ^ "\n"
                else "") ^
                "FACTS: " ^ string_of_int (length cvc5_facts) ^ " CVC5, " ^
                  string_of_int (length e_ground_facts) ^ " E ground (" ^
                  string_of_int e_schematic_count ^ " schematic filtered)\n" ^
                "E ADDITIONAL FACTS (display only, not sent to CVC5):\n" ^ e_facts_smtlib_display ^ "\n" ^
                "ACTUAL CVC5 SMT-LIB PROBLEM:\n" ^ smtlib_clean
              end
              handle ERROR msg =>
                let
                  val _ = Synchronized.change stats inc_error
                in
                  "GRAMMAR ASSERTIONS MODE: " ^ mode_label ^ "\nERROR: " ^ msg
                end
                | Fail msg =>
                let
                  val _ = Synchronized.change stats inc_error
                in
                  "GRAMMAR ASSERTIONS MODE: " ^ mode_label ^ "\nFAIL: " ^ msg
                end

            val mode_outputs =
              let
                val runs = grammar_assertions_runs grammar_assertions_mode config
              in
                if length runs > 1 andalso Multithreading.max_threads () > 1 then
                  Par_List.map render_mode_output runs
                else
                  map render_mode_output runs
              end
          in
            String.concatWith "\n\n" mode_outputs
          end
      end
      end
      end
      end

    fun finalize () =
      let
        val Stats {total_calls, ...} = Synchronized.value stats
      in
        if total_calls > 0 then format_stats (Synchronized.value stats) else ""
      end

  in
    (init_msg, {run = run, finalize = finalize})
  end

(* Register the action *)
val () = Mirabelle.register_action "abduct" make_action

end
