extends SceneTree
## 自检：补间缓动 / 烘焙帧集 / 骨骼拓扑与骨头尖 / FK 瞄准公式。
## godot --headless --path . --script res://tools/test_studio.gd
##
## 注意：骨架检查必须在 _process 里跑——Skeleton3D 的全局姿态缓存要等场景循环
## 转起来才刷新，在 _initialize() 里 set_bone_pose_rotation 之后 get_bone_global_pose
## 读回来的还是旧值（踩过这个坑，别把测试挪回 _initialize）。

var _fail := 0
var _skel: Skeleton3D
var _bones := {}
var _frame := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	_test_ease()
	_test_bake_frames()
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	_skel = _find_skel(scene)
	_bones = HumanoidBones.resolve_all(_skel)


func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false     # 等骨架姿态缓存转起来
	_test_topology()
	_test_aim()
	print("\n结果：", "全部通过" if _fail == 0 else "%d 项失败" % _fail)
	quit(1 if _fail > 0 else 0)
	return true


func _test_ease() -> void:
	print("[缓动采样]")
	var a := Quaternion.IDENTITY
	var b := Quaternion(Vector3.UP, deg_to_rad(90))
	var keys := {0: {"Bone": a}, 10: {"Bone": b}}

	_ok((AnimBaker.sample(keys, 2.5)["Bone"] as Quaternion).is_equal_approx(a.slerp(b, 0.25)),
		"线性补间 t=0.25")
	# 缓入缓出 smoothstep(0.25) = 0.25²·(3-2·0.25) = 0.15625
	_ok((AnimBaker.sample(keys, 2.5, {0: AnimBaker.Ease.IN_OUT})["Bone"] as Quaternion)
		.is_equal_approx(a.slerp(b, 0.15625)), "缓入缓出 t=0.25 → 0.15625")
	# 缓入 t² = 0.0625；缓出 1-(1-t)² = 0.4375
	_ok((AnimBaker.sample(keys, 2.5, {0: AnimBaker.Ease.IN})["Bone"] as Quaternion)
		.is_equal_approx(a.slerp(b, 0.0625)), "缓入 t=0.25 → 0.0625")
	_ok((AnimBaker.sample(keys, 2.5, {0: AnimBaker.Ease.OUT})["Bone"] as Quaternion)
		.is_equal_approx(a.slerp(b, 0.4375)), "缓出 t=0.25 → 0.4375")
	# 定格：整段停在前一个关键帧，到下一个关键帧才跳
	_ok((AnimBaker.sample(keys, 9.9, {0: AnimBaker.Ease.HOLD})["Bone"] as Quaternion)
		.is_equal_approx(a), "定格 t=0.99 仍是起始姿势")
	_ok((AnimBaker.sample(keys, 10.0, {0: AnimBaker.Ease.HOLD})["Bone"] as Quaternion)
		.is_equal_approx(b), "定格 到达结束帧才切换")


func _test_bake_frames() -> void:
	print("\n[烘焙帧集]")
	var keys := {0: {}, 10: {}, 20: {}}
	_ok(AnimBaker.bake_frames(keys, {}) == [0, 10, 20], "全线性 → 只烘关键帧")
	# 0→10 缓动要逐帧烘死（Godot 轨道只会匀速 slerp），10→20 线性只留端点
	var f := AnimBaker.bake_frames(keys, {0: AnimBaker.Ease.IN_OUT})
	_ok(f.size() == 12 and f[0] == 0 and f[1] == 1 and f[10] == 10 and f[11] == 20,
		"缓动区间逐帧、线性区间只留端点")


func _test_topology() -> void:
	print("\n[骨架拓扑]")
	_ok(_bones.size() == 52, "解析到 52 根人形骨（实得 %d，骨架共 %d）"
		% [_bones.size(), _skel.get_bone_count()])
	var parents := HumanoidBones.humanoid_parents(_skel, _bones)
	_ok(parents["RightLowerArm"] == "RightUpperArm", "RightLowerArm 的人形父骨是 RightUpperArm")
	_ok(parents["LeftUpperLeg"] == "Hips", "LeftUpperLeg 的人形父骨是 Hips（跨过裙摆摇物骨）")
	_ok(parents["Hips"] == "", "Hips 是人形根")

	# 骨头尖必须精确落在子骨骼的关节上（画骨头和拖拽瞄准都靠它）
	var tips := HumanoidBones.bone_tips(_skel, _bones, parents)
	for c in [["RightUpperArm", "RightLowerArm"], ["LeftLowerLeg", "LeftFoot"],
			["Spine", "Chest"], ["Hips", "Spine"], ["RightIndexProximal", "RightIndexIntermediate"]]:
		var tip: Vector3 = _skel.get_bone_global_rest(_bones[c[0]]) * (tips[c[0]] as Vector3)
		var child_joint: Vector3 = _skel.get_bone_global_rest(_bones[c[1]]).origin
		_ok(tip.distance_to(child_joint) < 0.001,
			"%s 的骨头尖落在 %s 的关节上（差 %.4f m）" % [c[0], c[1], tip.distance_to(child_joint)])


## FK 瞄准：把骨头扭向目标点后，骨头的实际朝向必须真的对上目标
func _test_aim() -> void:
	print("\n[FK 瞄准]")
	var parents := HumanoidBones.humanoid_parents(_skel, _bones)
	var tips := HumanoidBones.bone_tips(_skel, _bones, parents)
	for bname in ["RightUpperArm", "LeftLowerLeg", "Head", "RightIndexProximal"]:
		var idx: int = _bones[bname]
		var g := _skel.get_bone_global_pose(idx)
		var target := g.origin + Vector3(-0.3, 0.5, 0.4)
		var want := (target - g.origin).normalized()
		var dir := (g.basis * (tips[bname] as Vector3)).normalized()
		var nb := Basis(Quaternion(dir, want)) * g.basis.orthonormalized()
		var pb := Basis.IDENTITY
		var p := _skel.get_bone_parent(idx)
		if p >= 0:
			pb = _skel.get_bone_global_pose(p).basis.orthonormalized()
		_skel.set_bone_pose_rotation(idx, (pb.inverse() * nb).get_rotation_quaternion().normalized())
		var g2 := _skel.get_bone_global_pose(idx)
		var got := (g2.basis * (tips[bname] as Vector3)).normalized()
		var err := rad_to_deg(acos(clampf(got.dot(want), -1.0, 1.0)))
		_ok(err < 0.05, "%s 扭向目标后朝向误差 %.4f°" % [bname, err])


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null
