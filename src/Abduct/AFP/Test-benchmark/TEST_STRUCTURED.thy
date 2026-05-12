theory TEST_STRUCTURED
  imports Main
begin

ML_file \<open>../../Abduct/cvc5_abduct_setup.ML\<close>
ML_file \<open>../../Abduct/mini_abduct_sledgehammer.ML\<close>

declare [[smt_solver = cvc5_abduct_trace]]
declare [[cvc5_abduct_trace_options = "--tlimit-per 6000 --sygus-abort-size=10"]]


lemma test_structured:
  assumes "P x" "Q y"
  shows "P x \<and> Q y"
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
  have "P x" using assms(1) by simp
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
  have "Q y" using assms(2) by simp
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
  proof
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
    show "P x" using assms(1) by simp
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
    show "Q y" using assms(2) by simp
  qed
qed

lemma another_test:
  shows "True"
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
  show ?thesis by simp
qed

end
