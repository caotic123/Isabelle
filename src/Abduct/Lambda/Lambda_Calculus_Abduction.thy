theory Lambda_Calculus_Abduction
  imports Mini_Abduct_Setup
begin

datatype lam =
  Var nat
| App lam lam
| Lam nat lam

fun vars :: \<open>lam \<Rightarrow> nat set\<close> where
  \<open>vars (Var x) = {x}\<close>
| \<open>vars (App t u) = vars t \<union> vars u\<close>
| \<open>vars (Lam x t) = insert x (vars t)\<close>

fun rename :: \<open>nat \<Rightarrow> nat \<Rightarrow> lam \<Rightarrow> lam\<close> where
  \<open>rename x y (Var z) = (if z = x then Var y else Var z)\<close>
| \<open>rename x y (App t u) = App (rename x y t) (rename x y u)\<close>
| \<open>rename x y (Lam z t) = Lam z (if z = x then t else rename x y t)\<close>

fun scoped :: \<open>nat set \<Rightarrow> lam \<Rightarrow> bool\<close> where
  \<open>scoped \<Gamma> (Var x) \<longleftrightarrow> x \<in> \<Gamma>\<close>
| \<open>scoped \<Gamma> (App t u) \<longleftrightarrow> scoped \<Gamma> t \<and> scoped \<Gamma> u\<close>
| \<open>scoped \<Gamma> (Lam x t) \<longleftrightarrow> scoped (insert x \<Gamma>) t\<close>

definition closed :: \<open>lam \<Rightarrow> bool\<close> where
  \<open>closed t \<longleftrightarrow> scoped {} t\<close>

inductive alpha_rel :: \<open>lam \<Rightarrow> lam \<Rightarrow> bool\<close> where
  alpha_Var: \<open>alpha_rel (Var x) (Var x)\<close>
| alpha_App:
    \<open>alpha_rel t t' \<Longrightarrow> alpha_rel u u' \<Longrightarrow>
     alpha_rel (App t u) (App t' u')\<close>
| alpha_Lam:
    \<open>alpha_rel t u \<Longrightarrow> alpha_rel (Lam x t) (Lam x u)\<close>
| alpha_rename:
    \<open>y \<notin> vars t \<Longrightarrow> alpha_rel (Lam x t) (Lam y (rename x y t))\<close>
| alpha_rename_back:
    \<open>y \<notin> vars t \<Longrightarrow> alpha_rel (Lam y (rename x y t)) (Lam x t)\<close>
| alpha_trans:
    \<open>alpha_rel t u \<Longrightarrow> alpha_rel u v \<Longrightarrow> alpha_rel t v\<close>

lemma scoped_mono:
  assumes \<open>scoped \<Gamma> t\<close> and \<open>\<Gamma> \<subseteq> \<Delta>\<close>
  shows \<open>scoped \<Delta> t\<close>
  sorry

lemma scoped_remove_fresh:
  assumes \<open>x \<notin> vars t\<close> and \<open>scoped (insert x \<Gamma>) t\<close>
  shows \<open>scoped \<Gamma> t\<close>
  sorry

lemma scoped_rename:
  assumes \<open>scoped (insert x \<Gamma>) t\<close>
  shows \<open>scoped (insert y \<Gamma>) (rename x y t)\<close>
  sorry

lemma scoped_rename_fresh_back:
  assumes \<open>y \<notin> vars t\<close> and \<open>scoped (insert y \<Gamma>) (rename x y t)\<close>
  shows \<open>scoped (insert x \<Gamma>) t\<close>
  sorry

lemma alpha_rel_scoped_right:
  assumes \<open>alpha_rel t u\<close>
  shows \<open>scoped \<Gamma> t \<Longrightarrow> scoped \<Gamma> u\<close>
  sorry

lemma alpha_rel_closed_right:
  \<open>alpha_rel t u \<Longrightarrow> closed t \<Longrightarrow> closed u\<close>
  using alpha_rel_scoped_right unfolding closed_def by blast

(* Can abduction discover the missing premise alpha_rel u t? *)
lemma alpha_rel_closed_left:
  \<open>alpha_rel t u \<Longrightarrow> closed u \<Longrightarrow> closed t\<close>
proof -
  assume rel: \<open>alpha_rel t u\<close> and closed_u: \<open>closed u\<close>
  show \<open>closed t\<close>
  (* abduct *)
    abduce
    sorry
qed

end
