theory TEST
  imports Main
begin

lemma test :
  assumes p_k : "P k" and j_a : "k = a" and j_k : "a = j" shows "P j"
proof - 
have t : "P a" using j_a p_k by auto 
with t p_k j_k show "P j" by auto
qed
