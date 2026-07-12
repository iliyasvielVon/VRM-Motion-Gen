extends SceneTree
## 全身 IK 自检。动画工具里 IK 的硬要求有三条，都在这儿钉死：
##   1. 够得到 —— 目标在臂展内，末端就该真的到位；
##   2. 骨头不许被拉长 —— FABRIK 每次迭代都还原骨长，解完的骨长必须和静止姿态一致；
##   3. 脚不许打滑 —— 拽手把胯带动了，脚得留在原地（不锁脚的话整个人像踩冰上一样滑走）。
## 另外验一下「刚度」的排序：脊柱要比手臂难拽动，不然拽一下手全身像面条一样甩。
##
## godot --headless --path . --script res://tools/test_bodyik.gd

var _fail := 0
var _solver: PoseSolver
var _ik: BodyIK


func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	_solver = PoseSolver.new()
	_solver.setup(AvatarContext.new(scene).skeleton)
	_ik = BodyIK.new()
	_ik.setup(_solver)

	var rest := {}                       # 静止姿态（空 = 全部用 rest）
	var g0 := _solver.global_pose(rest)
	var chain := _ik.chain_of("LeftHand")
	print("[链]")
	print("    拖 LeftHand → ", ", ".join(chain))
	_ok(chain[0] == "Hips" and chain[chain.size() - 1] == "LeftHand",
		"链从胯一路连到被拖的骨头（%d 根）" % chain.size())

	# 目标：手往身体正前方偏下拽一点，臂展够得到
	var wrist0: Vector3 = (g0["LeftHand"] as Transform3D) * (_solver.tips["LeftHand"] as Vector3)
	var target := wrist0 + Vector3(-0.25, -0.25, 0.35)
	var r := _ik.solve(rest, Vector3.ZERO, "LeftHand", target)
	var pose: Dictionary = r["bones"]
	var root_off: Vector3 = r["root"]
	var g1 := _solver.global_pose(pose, root_off)

	print("\n[1. 够得到]")
	var tip: Vector3 = (g1["LeftHand"] as Transform3D) * (_solver.tips["LeftHand"] as Vector3)
	_ok(tip.distance_to(target) < 0.02,
		"手拖到目标（还差 %.1f mm）" % (tip.distance_to(target) * 1000.0))

	print("\n[2. 骨头没被拉长]")
	var worst := 0.0
	var worst_b := ""
	for i in range(chain.size() - 1):
		var a: String = chain[i]
		var b: String = chain[i + 1]
		var d0: float = (g0[a] as Transform3D).origin.distance_to((g0[b] as Transform3D).origin)
		var d1: float = (g1[a] as Transform3D).origin.distance_to((g1[b] as Transform3D).origin)
		if absf(d1 - d0) > worst:
			worst = absf(d1 - d0)
			worst_b = "%s→%s" % [a, b]
	_ok(worst < 0.0005, "链上所有骨长和静止姿态一致（最大偏差 %s %.3f mm）"
		% [worst_b, worst * 1000.0])

	print("\n[3. 近处的目标：手臂自己够得到，躯干就不该跟着晃]")
	print("    Spine 转了 %.2f°，Hips 转了 %.2f°，胯平移 %.1f mm"
		% [_turn(pose, "Spine"), _turn(pose, "Hips"), root_off.length() * 1000.0])
	# 手臂自己能够到就完全不动躯干；这个目标在臂展边缘，躯干象征性地让了两三度，可以接受。
	# 关键是别一拽手就整个人东倒西歪。
	_ok(_turn(pose, "Spine") < 5.0 and root_off.length() < 0.005,
		"手边的小调整最多让躯干动几度，不会把整个身子带得东倒西歪")

	# 够远的目标（手臂伸直也够不到），躯干必须让步——刚度排序在这儿才看得出来
	var shoulder: Vector3 = (g0["LeftUpperArm"] as Transform3D).origin
	var far_target := shoulder + Vector3(0.10, -0.10, 0.72)   # 模型朝 +Z，这是往身前远处够
	var rf := _ik.solve(rest, Vector3.ZERO, "LeftHand", far_target)
	var pose_f: Dictionary = rf["bones"]
	var root_f: Vector3 = rf["root"]
	var gf := _solver.global_pose(pose_f, root_f)

	print("\n[4. 远处的目标：手臂够不着，躯干才让步（但让步有上限）]")
	# 别拿「某根骨的局部旋转角」当「谁出的力」的指标：躯干先转了，手臂就不用再转多少，
	# 大臂的局部角反而会变小 —— 这个读数会骗人。要看的是「躯干有没有让步」和
	# 「让步有没有超过关节限位」这两件事。
	var spine := _turn(pose_f, "Spine")
	print("    Spine 弯了 %.1f°，Hips 转了 %.1f°" % [spine, _turn(pose_f, "Hips")])
	_ok(spine > 1.0, "躯干让步了（脊柱弯了 %.1f°）" % spine)
	var over := ""
	for b in BodyIK.TORSO_LIMIT:
		if _turn(pose_f, b) > float(BodyIK.TORSO_LIMIT[b]) + 0.5:
			over += "%s(%.1f°>%s°) " % [b, _turn(pose_f, b), BodyIK.TORSO_LIMIT[b]]
	_ok(over.is_empty(), "躯干每一节都没超过关节限位（超了的话人会扭成麻花）%s" % over)
	var tip_f: Vector3 = (gf["LeftHand"] as Transform3D) * (_solver.tips["LeftHand"] as Vector3)
	print("    末端离目标还差 %.0f mm（躯干让到限位就不让了，剩下的够不着就是够不着）"
		% (tip_f.distance_to(far_target) * 1000.0))
	_ok(root_f.length() < 0.001, "拖手不会平移胯（要挪重心请直接拖胯——不然整个人像踩冰上一样滑）")

	print("\n[5. 脚没打滑（就在上面那个「弯腰挪重心」的姿势里）]")
	for side in ["Left", "Right"]:
		var foot: String = str(side) + "Foot"
		var f0: Vector3 = (g0[foot] as Transform3D) * (_solver.tips[foot] as Vector3)
		var f1: Vector3 = (gf[foot] as Transform3D) * (_solver.tips[foot] as Vector3)
		_ok(f0.distance_to(f1) < 0.005, "%s 留在原地（漂移 %.1f mm）"
			% [foot, f0.distance_to(f1) * 1000.0])

	print("\n[5. 拖胯 = 整个人平移]")
	var hips_tip: Vector3 = (g0["Hips"] as Transform3D) * (_solver.tips["Hips"] as Vector3)
	var r2 := _ik.solve(rest, Vector3.ZERO, "Hips", hips_tip + Vector3(0.1, -0.05, 0))
	_ok((r2["root"] as Vector3).length() > 0.05, "胯平移了 %.0f mm"
		% ((r2["root"] as Vector3).length() * 1000.0))
	_ok((r2["bones"] as Dictionary).is_empty() or _turn(r2["bones"], "LeftLowerArm") < 0.01,
		"拖胯不会顺手把手臂拧了（纯平移）")

	print("\n[6. 够不着的时候]")
	var far := wrist0 + Vector3(0, 0, 3.0)      # 三米开外，怎么伸都够不着
	var r3 := _ik.solve(rest, Vector3.ZERO, "LeftHand", far)
	var g3 := _solver.global_pose(r3["bones"], r3["root"])
	var worst_far := 0.0
	for i in range(chain.size() - 1):
		var d0: float = (g0[chain[i]] as Transform3D).origin.distance_to(
			(g0[chain[i + 1]] as Transform3D).origin)
		var d1: float = (g3[chain[i]] as Transform3D).origin.distance_to(
			(g3[chain[i + 1]] as Transform3D).origin)
		worst_far = maxf(worst_far, absf(d1 - d0))
	_ok(worst_far < 0.0005, "够不着也不会把骨头拉长（最大偏差 %.3f mm，只是伸直了）"
		% (worst_far * 1000.0))

	print("\n结果：", "全部通过" if _fail == 0 else "%d 项失败" % _fail)
	quit(1 if _fail > 0 else 0)


## 某根骨骼相对静止姿态转了多少度
func _turn(pose: Dictionary, bname: String) -> float:
	if not pose.has(bname):
		return 0.0
	var rest: Quaternion = _solver.skel.get_bone_rest(
		_solver.bones[bname]).basis.get_rotation_quaternion()
	return rad_to_deg(2.0 * acos(clampf(absf((pose[bname] as Quaternion).dot(rest)), 0.0, 1.0)))
