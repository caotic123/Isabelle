theory Abduct_Setup
  imports HOL.Mirabelle
  keywords "abduce" :: diag
begin

ML_file "cvc5_abduct_setup.ML"
ML_file "mini_abduct_sledgehammer.ML"
declare [[smt_solver = cvc5_abduct_trace]]
declare [[cvc5_abduct_trace_options = "--tlimit-per 6000 --sygus-abort-size=10"]]

end
