(*  Title:      Abduct/Benchmark/mirabelle_drop_premise.ML
    Author:     Custom Mirabelle Action

Custom Mirabelle action: "drop_premise"

This action randomly selects a premise (hypothesis) from each proof goal,
logs it, shows what the goal would look like without it, and runs sledgehammer
on the ORIGINAL goal (with all premises).

This is useful for:
- Analyzing which premises exist in proof goals
- Understanding goal structure
- Testing if goals are provable (with all premises)
- Identifying potential unnecessary premises for manual investigation

Results are logged to mirabelle.log.
*)

structure Mirabelle_Drop_Premise: MIRABELLE_ACTION =
struct

(* Configuration parameters *)
val random_seedK = "random_seed" (*=INT: random seed for premise selection (0=use position-based)*)
val exhaustive_preplayK = "exhaustive_preplay" (*=BOOL: show exhaustive preplay data*)
val keep_probsK = "keep_probs" (*=BOOL: keep temporary problem files*)
val keep_proofsK = "keep_proofs" (*=BOOL: keep temporary proof files*)

(* Defaults *)
val random_seed_default = 42
val exhaustive_preplay_default = false
val keep_probs_default = false
val keep_proofs_default = false

(* Statistics tracking *)
datatype stats = Stats of {
  total_calls: int,
  successes: int,
  failures: int,
  timeouts: int,
  errors: int,
  no_premises: int,
  total_time_ms: int}

fun empty_stats () = Stats {
  total_calls = 0,
  successes = 0,
  failures = 0,
  timeouts = 0,
  errors = 0,
  no_premises = 0,
  total_time_ms = 0}

fun inc_total (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls + 1, successes = successes, failures = failures,
    timeouts = timeouts, errors = errors, no_premises = no_premises, total_time_ms = total_time_ms}

fun inc_success (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes + 1, failures = failures,
    timeouts = timeouts, errors = errors, no_premises = no_premises, total_time_ms = total_time_ms}

fun inc_failure (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes, failures = failures + 1,
    timeouts = timeouts, errors = errors, no_premises = no_premises, total_time_ms = total_time_ms}

fun inc_timeout (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes, failures = failures,
    timeouts = timeouts + 1, errors = errors, no_premises = no_premises, total_time_ms = total_time_ms}

fun inc_error (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes, failures = failures,
    timeouts = timeouts, errors = errors + 1, no_premises = no_premises, total_time_ms = total_time_ms}

fun inc_no_premises (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes, failures = failures,
    timeouts = timeouts, errors = errors, no_premises = no_premises + 1, total_time_ms = total_time_ms}

fun add_time ms (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  Stats {total_calls = total_calls, successes = successes, failures = failures,
    timeouts = timeouts, errors = errors, no_premises = no_premises, total_time_ms = total_time_ms + ms}

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

(* Run sledgehammer and report which premise was conceptually dropped *)
fun run_sledgehammer_modified params keep_setup pos state dropped_hyp_idx hyp_count =
  let
    fun set_file_name (SOME (dir, keep_probs, keep_proofs)) =
        let
          val line_str = the_default "0" (Option.map string_of_int (Position.line_of pos))
          val offset_str = the_default "0" (Option.map string_of_int (Position.offset_of pos))
          val filename = "drop_premise_" ^
            StringCvt.padLeft #"0" 5 line_str ^ "_" ^
            StringCvt.padLeft #"0" 6 offset_str
          fun mk_smt_file () = dir ^ "/" ^ filename ^ "__" ^ serial_string ()
        in
          Config.put Sledgehammer_Prover_ATP.atp_problem_prefix (filename ^ "__")
          #> (keep_probs ? Config.put Sledgehammer_Prover_ATP.atp_problem_dest_dir dir)
          #> (keep_proofs ? Config.put Sledgehammer_Prover_ATP.atp_proof_dest_dir dir)
          #> (keep_probs ? Config.put SMT_Config.problem_dest_file (mk_smt_file ()))
          #> (keep_proofs ? Config.put SMT_Config.proof_dest_file (mk_smt_file ()))
        end
      | set_file_name NONE = I

    val {context = ctxt, facts = chained, goal} = Proof.goal state
    val subgoal = 1

    (* Get subgoal structure *)
    val (_, hyp_ts, concl_t) = ATP_Util.strip_subgoal goal subgoal ctxt

    (* Run sledgehammer on the original state *)
    val state' = Proof.map_context (set_file_name keep_setup) state

    val ((_, (outcome, msg)), cpu_time) = Mirabelle.cpu_time (fn () =>
      Sledgehammer.run_sledgehammer params Sledgehammer_Prover.Normal NONE 1
        Sledgehammer_Fact.no_fact_override state') ()

    (* Build informative message showing what goal would be without dropped premise *)
    val reconstructed_goal_str =
      let
        val remaining_hyps = filter_by_index (fn i => i <> dropped_hyp_idx) hyp_ts
        val modified_term = Logic.list_implies (remaining_hyps, concl_t)
      in
        "\nGoal without this premise: " ^
        Protocol_Message.clean_output (Syntax.string_of_term ctxt modified_term)
      end
      handle TERM _ => ""
        | TYPE _ => ""

    val note = reconstructed_goal_str
  in
    (outcome, msg ^ note, cpu_time)
  end
  handle ERROR msg => (Sledgehammer.SH_Unknown, " error: " ^ msg, 0)
    | Timeout.TIMEOUT _ => (Sledgehammer.SH_Unknown, " timeout", 0)
    | THM (msg, _, _) => (Sledgehammer.SH_Unknown, " thm error: " ^ msg, 0)
    | TERM (msg, _) => (Sledgehammer.SH_Unknown, " term error: " ^ msg, 0)
    | TYPE (msg, _, _) => (Sledgehammer.SH_Unknown, " type error: " ^ msg, 0)

(* Format statistics for logging *)
fun format_stats (Stats {total_calls, successes, failures, timeouts, errors, no_premises, total_time_ms}) =
  let
    fun percentage a b = if b = 0 then "0.0" else
      Real.fmt (StringCvt.FIX (SOME 1)) (Real.fromInt (a * 100) / Real.fromInt b)
    fun avg_time t n = if n > 0 then
      Real.fmt (StringCvt.FIX (SOME 3)) (Real.fromInt t / 1000.0 / Real.fromInt n)
      else "0.000"
  in
    "\n=== Drop Premise Statistics ===" ^
    "\nTotal calls: " ^ string_of_int total_calls ^
    "\nSuccesses: " ^ string_of_int successes ^
      " (" ^ percentage successes total_calls ^ "%)" ^
    "\nFailures: " ^ string_of_int failures ^
      " (" ^ percentage failures total_calls ^ "%)" ^
    "\nTimeouts: " ^ string_of_int timeouts ^
      " (" ^ percentage timeouts total_calls ^ "%)" ^
    "\nErrors: " ^ string_of_int errors ^
      " (" ^ percentage errors total_calls ^ "%)" ^
    "\nGoals with no premises: " ^ string_of_int no_premises ^
    "\nTotal time: " ^ Real.fmt (StringCvt.FIX (SOME 3)) (Real.fromInt total_time_ms / 1000.0) ^ "s" ^
    "\nAverage time: " ^ avg_time total_time_ms total_calls ^ "s"
  end

(* Main action implementation *)
fun make_action ({arguments, timeout, output_dir, index, ...} : Mirabelle.action_context) =
  let
    (* Parse arguments *)
    val random_seed = Mirabelle.get_int_argument arguments (random_seedK, random_seed_default)
    val keep_probs = Mirabelle.get_bool_argument arguments (keep_probsK, keep_probs_default)
    val keep_proofs = Mirabelle.get_bool_argument arguments (keep_proofsK, keep_proofs_default)
    val exhaustive_preplay =
      Mirabelle.get_bool_argument arguments (exhaustive_preplayK, exhaustive_preplay_default)

    val params = Sledgehammer_Commands.default_params \<^theory> arguments

    (* Shared statistics *)
    val stats = Synchronized.var "drop_premise_stats" (empty_stats ())

    val init_msg =
      "Drop-premise action initialized\n" ^
      "Random seed: " ^ string_of_int random_seed ^ "\n" ^
      "Sledgehammer params: " ^ Sledgehammer_Prover.string_of_params params

    (* Process each proof command *)
    fun run ({theory_index, pos, pre, ...} : Mirabelle.command) =
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
            (* Generate seed from position for deterministic randomness *)
            val line = the_default 0 (Position.line_of pos)
            val offset = the_default 0 (Position.offset_of pos)
            val seed = random_seed + theory_index * 10000 + line * 100 + offset

            (* Select random premise *)
            val (dropped_premise, premise_idx) = the (select_random_premise seed premises)
            val premise_str = Protocol_Message.clean_output (Syntax.string_of_term ctxt dropped_premise)

            (* Setup file output if needed *)
            val keep_setup =
              if keep_probs orelse keep_proofs then
                let
                  val thy_long_name = Context.theory_long_name (Proof.theory_of pre)
                  val session_name = Long_Name.qualifier thy_long_name
                  val thy_name = Long_Name.base_name thy_long_name
                  val subdir = StringCvt.padLeft #"0" 4 (string_of_int theory_index) ^ "_" ^ thy_name
                  val dir = Path.append (Path.append output_dir (Path.basic session_name))
                    (Path.basic subdir)
                  val _ = Isabelle_System.make_directory dir
                in
                  SOME (Path.implode dir, keep_probs, keep_proofs)
                end
              else
                NONE

            (* Run sledgehammer with the premise removed *)
            val (outcome, msg, cpu_time) =
              run_sledgehammer_modified params keep_setup pos pre premise_idx (length premises)

            (* Determine if this was a timeout by checking the message *)
            val is_timeout = String.isSubstring "timeout" (String.map Char.toLower msg)

            (* Update statistics *)
            val _ = Synchronized.change stats
              (case outcome of
                Sledgehammer.SH_Some _ => inc_success #> inc_total #> add_time cpu_time
              | Sledgehammer.SH_None => inc_failure #> inc_total #> add_time cpu_time
              | Sledgehammer.SH_Unknown =>
                  (if is_timeout then inc_timeout else inc_error) #> inc_total #> add_time cpu_time)

            val outcome_str =
              case outcome of
                Sledgehammer.SH_Some _ => "SUCCESS"
              | Sledgehammer.SH_None => "FAILURE"
              | Sledgehammer.SH_Unknown => if is_timeout then "TIMEOUT" else "ERROR"
          in
            "DROPPED PREMISE [" ^ string_of_int (premise_idx + 1) ^ "/" ^
            string_of_int (length premises) ^ "]: " ^ premise_str ^ "\n" ^
            "RESULT: " ^ outcome_str ^ " (" ^ string_of_int cpu_time ^ "ms)\n" ^
            "SLEDGEHAMMER: " ^ Protocol_Message.clean_output msg
          end
      end

    fun finalize () =
      let val Stats {total_calls, ...} = Synchronized.value stats
      in if total_calls > 0 then format_stats (Synchronized.value stats) else "" end

  in
    (init_msg, {run = run, finalize = finalize})
  end

(* Register the action *)
val () = Mirabelle.register_action "drop_premise" make_action

end
