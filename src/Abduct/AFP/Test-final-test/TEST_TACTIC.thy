theory TEST_TACTIC
  imports Main
  keywords "try_abduct" :: diag
begin

ML_file \<open>../../Abduct/cvc5_abduct_setup.ML\<close>
ML_file \<open>../../Abduct/mini_abduct_sledgehammer.ML\<close>

declare [[smt_solver = cvc5_abduct_trace]]
declare [[cvc5_abduct_trace_options = "--tlimit-per 6000 --sygus-abort-size=10"]]

(* Define the custom command 'try_abduct' *)
ML \<open>
  Outer_Syntax.command @{command_keyword try_abduct}
    "Run abduction tactic diagnostically (like sledgehammer)"
    (Scan.succeed (Toplevel.keep (fn state =>
      let
        (* 1. Safely grab the proof state from the Toplevel *)
        val proof_state = Toplevel.proof_of state
        val ctxt = Proof.context_of proof_state

        (* 2. Get the current goal theorem *)
        val {goal, ...} = Proof.goal proof_state

        (* 3. Configure the tactic *)
        val tac = Mini_Abduct_Sledgehammer.abduct_sledgehammer_tac_depth
            ctxt
            {max_facts = {cvc5 = SOME 5, e = NONE},
             max_limit = {cvc5 = SOME 1, e = SOME 1},
             max_facts_depth = {cvc5 = NONE, e = NONE},
             max_limit_depth = {cvc5 = SOME 1, e = NONE},
             depth = 1,
             timeout = 100.0,
             debug = false}
            1 (* Apply to subgoal 1 *)
      in
        (* 4. Run the tactic and print result *)
        writeln "Running abduction...";
        case Seq.pull (tac goal) of
          SOME (new_thm, _) =>
             writeln ("\n[Abduction Success]\n" ^
                      Syntax.string_of_term ctxt (Thm.prop_of new_thm))
        | NONE =>
             writeln "[Abduction Failed] No solution found."
      end
      handle Toplevel.UNDEF => writeln "Not in a proof state!"
           | ERROR msg => writeln ("Error: " ^ msg)
    )))
\<close>


lemma test :
  assumes p_k : "P k" and j_a : "k = a" and j_k : "a = j" shows "P j"
proof -
(*have t : "P a" using j_a p_k by auto *)
apply (tactic ‹Mini_Abduct_Sledgehammer.abduct_sledgehammer_tac_depth
    @{context}
    {max_facts = {cvc5 = SOME 5, e = NONE},  (* NONE = use Isabelle default *)
     max_limit = {cvc5 = SOME 1, e = SOME 1},
     max_facts_depth = {cvc5 = NONE, e = NONE},
     max_limit_depth = {cvc5 = SOME 1, e = NONE},
     depth = 1,
     timeout = 100.0,
     debug = false}
    1›)
try_abduct
have t : "P a" using j_a p_k by auto
with t p_k j_k show "P j" by auto
qed

end
