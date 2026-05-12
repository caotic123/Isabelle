theory TEST_TACTIC
  imports Main
begin

ML_file \<open>../../Abduct/cvc5_abduct_setup.ML\<close>
ML_file \<open>../../Abduct/mini_abduct_sledgehammer.ML\<close>

declare [[smt_solver = cvc5_abduct_trace]]
declare [[cvc5_abduct_trace_options = "--tlimit-per 6000 --sygus-abort-size=10"]]


lemma test :
  assumes p_k : "P k" and j_a : "k = a" and j_k : "a = j" shows "P j"
proof -
show ?thesis
apply (tactic \<open>Mini_Abduct_Sledgehammer.abduct_sledgehammer_tac_depth
    @{context}
    {max_facts = {cvc5 = SOME 5, e = NONE},
     max_limit = {cvc5 = SOME 1, e = SOME 1},
     max_facts_depth = {cvc5 = NONE, e = NONE},
     max_limit_depth = {cvc5 = SOME 1, e = NONE},
     depth = 1,
     timeout = 100.0,
     debug = false}
    1\<close>)
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
show ?thesis
apply (tactic \<open>Mini_Abduct_Sledgehammer.abduct_sledgehammer_tac_depth
    @{context}
    {max_facts = {cvc5 = SOME 5, e = NONE},
     max_limit = {cvc5 = SOME 1, e = SOME 1},
     max_facts_depth = {cvc5 = NONE, e = NONE},
     max_limit_depth = {cvc5 = SOME 1, e = NONE},
     depth = 1,
     timeout = 100.0,
     debug = false}
    1\<close>)
have t : "P a" using j_a p_k by auto
with t p_k j_k show "P j" by auto
qed

end
