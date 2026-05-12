theory TEST_STRUCTURED
  imports Main
begin

lemma test_structured:
  assumes "P x" "Q y"
  shows "P x \<and> Q y"
proof -
  have "P x" using assms(1) by simp
  have "Q y" using assms(2) by simp
  show ?thesis proof
    show "P x" using assms(1) by simp
    show "Q y" using assms(2) by simp
  qed
qed

lemma another_test:
  shows "True"
proof -
  show ?thesis by simp
qed

end
