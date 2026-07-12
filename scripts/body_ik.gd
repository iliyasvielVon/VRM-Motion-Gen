class_name BodyIK
extends RefCounted
## 全身 IK（Cascadeur 那种「拖一只手，全身跟着动」）。
##
## 拖任意一根骨头的骨头尖，从胯到这根骨头的**整条链**一起解：小臂、大臂、肩、上胸、
## 脊柱、胯依次让步，够不着了胯还会被拽着平移（重心跟过去），双脚锁在原地不打滑。
##
## 解法是 FABRIK（Forward And Backward Reaching Inverse Kinematics）：把骨链当成一串
## 定长线段，反复「从末端往回拉一遍、再从根往外推一遍」，几次就收敛。选它而不选雅可比
## 迭代是因为它不用求导、不会在奇异位形（手臂完全伸直）炸掉，而且每次迭代都保持骨长——
## 骨头绝不会被拉长，这在动画工具里是硬要求。
##
## **刚度**是让它像人而不像橡皮的关键：脊柱比手臂难拽动，胯更难。人去够远处的东西，
## 先伸手臂，够不着才弯腰，最后才挪重心——刚度就是在编码这个顺序。
##
## 纯数学，不碰骨架。输入输出都是「一组局部旋转 + 胯的平移」，直接就是编辑器的姿势格式。

const ITERS := 16
const TOL := 0.002          # 末端离目标这么近（米）就算够到了

## 躯干骨相对静止姿态最多能转多少度。没有限位的话，脚一锁死、目标一放远，FABRIK 会把
## 脊柱直接对折过去（头埋进胸口）——数学上没错，人体上荒谬。限位之后躯干只肯让到这么多，
## 剩下的够不着就是够不着，这正是真人的样子。
## 注意这是**逐段**限位，会累加：脊柱三节 + 胯加起来就是躯干总活动量，别按「总共能弯多少」
## 来填。填 30/25/20 试过，加起来能让上半身拧出 90°，够是够着了，人已经扭成麻花。
const TORSO_LIMIT := {
	"Hips": 14.0, "Spine": 20.0, "Chest": 16.0, "UpperChest": 12.0,
	"LeftShoulder": 22.0, "RightShoulder": 22.0,
}

var solver: PoseSolver


func setup(pose_solver: PoseSolver) -> void:
	solver = pose_solver


## 从人形根骨（Hips）到 bname 的整条链，父在前
func chain_of(bname: String) -> Array[String]:
	var out: Array[String] = []
	var b := bname
	while b != "" and solver.bones.has(b):
		out.push_front(b)
		b = solver.parents[b]
	return out


## 拖拽求解。pose = 当前全身局部旋转，root_off = 当前胯的平移（胯的父空间）。
## effector = 被拖的骨头，target = 它的骨头尖要去的地方（骨架空间）。
## 返回 {"bones": {骨骼名: Quaternion}, "root": Vector3}
##
## **分两级解**，这是让它像人而不像橡皮的关键：
##   一级：只解肢体（肩→手 / 胯→脚），躯干纹丝不动。手边够得着的调整就到此为止。
##   二级：一级够不着，才把脊柱和胯拉进链里一起解，人这才弯腰拧腰。
## 一开始我是想用「刚度」（每根骨头一个阻尼系数）来做这个的，结果躯干被彻底焊死——
## 因为每次迭代都把关节往**原始姿势**拉回去，偏移根本累积不起来。分级解既解决了这个，
## 又白送了一个好性质：手边的小调整绝对不会把整个身子带得东倒西歪。
func solve(pose: Dictionary, root_off: Vector3, effector: String, target: Vector3,
		pin_feet := true) -> Dictionary:
	if not solver.bones.has(effector):
		return {"bones": pose.duplicate(), "root": root_off}
	var g := solver.global_pose(pose, root_off)

	# 拖胯 = 整个人平移（重心自己挪），没有链可解。
	# 手/脚的链一律不动胯——不然拽一下手整个人像踩在冰上一样滑走。
	if solver.parents[effector] == "":
		var tip: Vector3 = (g[effector] as Transform3D) * (solver.tips[effector] as Vector3)
		var delta: Vector3 = solver.root_basis(effector).inverse() * (target - tip)
		return {"bones": pose.duplicate(), "root": root_off + delta}

	var full := chain_of(effector)
	var limb := _limb_chain(full)

	# 拖的就是肢体的根骨（大臂/大腿）：链上只有它自己，那就纯粹转它自己。
	# 不能走下面「够不着就升级」那条路——单根骨头的尖只能落在半径 = 骨长的球面上，
	# 目标基本永远「够不着」，一升级就变成拖个大臂都要全身跟着晃。
	if limb.size() == 1:
		return {"bones": _solve_chain(limb, g, pose, target), "root": root_off}

	if not limb.is_empty():
		var rots := _solve_chain(limb, g, pose, target)
		var reached := _tip_of(effector, solver.global_pose(rots, root_off))
		if reached.distance_to(target) < TOL:
			return {"bones": rots, "root": root_off}   # 手臂自己够到了，躯干不用动

	# 够不着 → 整条链（含脊柱和胯）一起解，躯干按限位收一收，再拿收完的躯干重解一次肢体，
	# 把末端尽量拉回目标（躯干让到极限之后，剩下的差距只能靠手臂自己伸）
	var rots_full := _solve_chain(full, g, pose, target)
	rots_full = _clamp_torso(rots_full)
	if not limb.is_empty():
		rots_full = _solve_chain(limb, solver.global_pose(rots_full, root_off), rots_full, target)
	if pin_feet:
		rots_full = _plant_feet(rots_full, root_off, g)
	return {"bones": rots_full, "root": root_off}


## 躯干骨的关节限位：超出 TORSO_LIMIT 的部分，沿着「静止姿态 → 解出来的姿态」这条弧
## 往回收到限位角上（slerp 的插值系数就是限位角占实际角的比例）
func _clamp_torso(rots: Dictionary) -> Dictionary:
	for bname in TORSO_LIMIT:
		if not rots.has(bname) or not solver.bones.has(bname):
			continue
		var q: Quaternion = rots[bname]
		var rest: Quaternion = solver.skel.get_bone_rest(
			solver.bones[bname]).basis.get_rotation_quaternion()
		var angle := 2.0 * acos(clampf(absf(q.dot(rest)), 0.0, 1.0))
		var limit := deg_to_rad(float(TORSO_LIMIT[bname]))
		if angle > limit and angle > 0.0001:
			rots[bname] = rest.slerp(q, limit / angle)
	return rots


## 链上属于「肢体」的那一段：大臂往下 / 大腿往下。
## 起点是大臂而不是肩：锁骨（Shoulder）算躯干骨，归关节限位管——它要是进了肢体链，
## 最后那次「拿限位后的躯干重解肢体」就会把它的限位覆盖掉，锁骨能甩出 80°。
func _limb_chain(full: Array[String]) -> Array[String]:
	for i in range(full.size()):
		var b: String = full[i]
		if b.ends_with("UpperArm") or b.ends_with("UpperLeg"):
			return full.slice(i)
	return []   # 拖的是躯干骨（胯/脊柱/胸/颈/头），没有肢体段


func _tip_of(bname: String, g: Dictionary) -> Vector3:
	return (g[bname] as Transform3D) * (solver.tips[bname] as Vector3)


## 解一条链：根关节钉死不动，末端（链尾骨头的骨头尖）拉到 target
func _solve_chain(chain: Array[String], g: Dictionary, hold: Dictionary,
		target: Vector3) -> Dictionary:
	var effector: String = chain[chain.size() - 1]
	var pts: Array[Vector3] = []
	for b in chain:
		pts.append((g[b] as Transform3D).origin)
	pts.append(_tip_of(effector, g))
	_fabrik(pts, _lengths(pts), target)
	return _rots_from_points(chain, pts, hold)


## 胯一转，两条腿就跟着飘，脚会插进地里或者浮起来。把双脚重新解回它们拖拽前的位置。
func _plant_feet(rots: Dictionary, root_off: Vector3, before: Dictionary) -> Dictionary:
	var g := solver.global_pose(rots, root_off)
	for side in ["Left", "Right"]:
		var chain: Array[String] = [side + "UpperLeg", side + "LowerLeg", side + "Foot"]
		var ok := true
		for b in chain:
			if not solver.bones.has(b):
				ok = false
		if not ok:
			continue
		var target := _tip_of(chain[2], before)   # 拖拽之前脚在哪，就还回哪
		rots = _solve_chain(chain, g, rots, target)
		g = solver.global_pose(rots, root_off)    # 解完一条腿，另一条腿的起点跟着更新
	return rots


## FABRIK 本体（pts 原地改）：把骨链当成一串定长线段，反复「从末端往回拉一遍、
## 再从根往外推一遍」。根关节钉死。每趟都重新还原骨长，所以骨头永远不会被拉长；
## 目标够不着时它会自然伸直，不会炸。
static func _fabrik(pts: Array[Vector3], seg: Array[float], target: Vector3) -> void:
	var last := pts.size() - 1
	var root := pts[0]
	for _it in ITERS:
		pts[last] = target                        # 往回拉：末端钉在目标上
		for i in range(last - 1, -1, -1):
			pts[i] = pts[i + 1] + (pts[i] - pts[i + 1]).normalized() * seg[i]
		pts[0] = root                             # 往外推：根部钉回原位
		for i in range(1, last + 1):
			pts[i] = pts[i - 1] + (pts[i] - pts[i - 1]).normalized() * seg[i - 1]
		if pts[last].distance_to(target) < TOL:
			return


static func _lengths(pts: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for i in range(pts.size() - 1):
		out.append(pts[i].distance_to(pts[i + 1]))
	return out


## 解出来的一串关节位置 → 全身局部旋转（链上每根骨头瞄准链上的下一个关节）
func _rots_from_points(chain: Array[String], pts: Array[Vector3], hold: Dictionary) -> Dictionary:
	var targets := {}
	var refs := {}
	for i in range(chain.size()):
		var b: String = chain[i]
		targets[b] = pts[i + 1] - pts[i]
		# 参考轴：链未必顺着骨头尖走（UpperChest 的骨头尖指着脖子，链却往肩膀拐）
		refs[b] = solver.tips[b] if i + 1 == chain.size() \
			else solver.local_offset_to(b, chain[i + 1])
	return solver.solve(targets, hold, refs)
