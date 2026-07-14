extends SceneTree
## 动补自检。这里量的是**三件不同的事**，混在一起看会得出完全错误的结论：
##
##   1. 重定向保真度（考我的代码）：方向骨的最终朝向，必须精确等于关键点给的方向。
##      这一项要求 < 1°——它只依赖 mocap.gd 的数学，跟 MediaPipe 准不准无关。
##   2. 关键点的图像平面精度（考 MediaPipe 的 X/Y）：把方向投到正面平面（Z 归零）再比。
##   3. 关键点的深度精度（考 MediaPipe 的 Z）：完整 3D 方向比。单目估计的软肋就在这，
##      误差比 (2) 大好几倍是**正常的**，不是 bug。
##
## 素材两套：正面平面动作（render_probe.gd，双臂体侧张合屈肘 + 抬腿，全程 Z≈0）用来断言；
## 圆舞（render_ref.gd，手臂绕身往身后甩）踩在单目最弱处，只报告不断言。
##
## 比的是**骨头指向**不是四元数：骨头绕自身轴的自转是动补根本测不出来的自由度，
## 拿四元数算误差会把好结果冤枉成 100°+。
##
## godot --headless --path . --script res://tools/test_mocap.gd

## 有「方向目标」的骨（不含胯/上胸/头/手掌这些用完整朝向定的）
const AIMED := ["RightUpperArm", "RightLowerArm", "LeftUpperArm", "LeftLowerArm",
	"LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg"]
const REPORT := ["RightUpperArm", "RightLowerArm", "LeftUpperArm", "LeftLowerArm",
	"LeftUpperLeg", "RightUpperLeg", "Spine", "Chest", "Head"]

var _fail := 0
var _mocap: Mocap


func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	_mocap = Mocap.new()
	_mocap.setup(AvatarContext.new(scene).skeleton)

	var probe := _load("res://animations/mocap/自检正面.mocap.json", "res://animations/mocap/自检正面.truth.json")

	print("[1. 重定向保真度 —— 考 mocap.gd 的数学]")
	_ok(probe["frames"] >= 30, "40 帧里解算出 %d 帧" % probe["frames"])
	_ok(probe["bones"] == 52, "每帧给出全部 52 根骨的旋转")
	_ok(probe["fidelity"] < 1.0,
		"方向骨的最终朝向 = 关键点给的方向（最大偏差 %.4f°）" % probe["fidelity"])

	print("\n[2. 关键点的图像平面精度 —— 考 MediaPipe 的 X/Y（正面素材，Z 归零）]")
	var plane := _report(probe, true)
	_ok(plane["arms"] < 15.0, "四肢在图像平面内的平均偏差 < 15°（实为 %.1f°）" % plane["arms"])

	print("\n[3. 关键点的深度精度 —— 考 MediaPipe 的 Z（同一批帧，完整 3D）]")
	var full := _report(probe, false)
	print("    → 同样的动作、同样的代码，加上深度这一维，四肢偏差从 %.1f° 涨到 %.1f°。"
		% [plane["arms"], full["arms"]])
	print("      这就是单目动补的软肋：轮廓抓得准，前后深度是糊的。")
	_ok(full["arms"] < 35.0, "完整 3D 偏差仍在可用范围（< 35°，实为 %.1f°）" % full["arms"])

	print("\n[4. 圆舞素材：手臂绕身往身后甩，全靠深度分辨——只报告不断言]")
	var hard := _load("res://animations/mocap/自检参考.mocap.json", "res://animations/mocap/自检参考.truth.json")
	var hard_full := _report(hard, false)
	print("    → 四肢偏差 %.1f°。同一套代码在正面动作上只有 %.1f°——"
		% [hard_full["arms"], full["arms"]])
	print("      差距全在深度，说明「拍动补时尽量正对镜头、别让肢体前后穿插」是真的有用。")

	print("\n[5. 可见度门控：被遮挡的腿保持上一帧，不乱飘]")
	# 同色裤腿/出画时 MediaPipe 照样硬给一个瞎猜的坐标，只是 visibility 很低。
	# 门控要保证：这种帧腿部不接垃圾数据，而是保持上一帧的姿态。
	var raw_frames: Array = JSON.parse_string(FileAccess.get_file_as_string(
		"res://animations/mocap/自检正面.mocap.json"))["frames"]
	var base := {}
	for fr in raw_frames:
		if fr.get("pose") != null:
			base = fr
			break
	var r1 := _mocap.solve(base)
	var blocked := {"pose": []}
	for i in range(33):
		var pt: Array = (base["pose"] as Array)[i]
		if i >= 25:   # 膝/踝/脚跟/脚尖全标成「看不见」+ 塞进垃圾坐标
			(blocked["pose"] as Array).append([9.9, -9.9, 9.9, 0.05])
		else:
			(blocked["pose"] as Array).append([pt[0], pt[1], pt[2], 1.0])
	var r2 := _mocap.solve(blocked, r1)
	var held := true
	for b in ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
			"RightUpperLeg", "RightLowerLeg", "RightFoot"]:
		if not (r2["bones"][b] as Quaternion).is_equal_approx(r1["bones"][b]):
			held = false
	_ok(held, "腿部关键点标记不可见后，六根腿骨全部保持上一帧（不接垃圾坐标）")
	var r3 := _mocap.solve(blocked)   # 没有上一帧可保持 → 回静止姿态，也不能接垃圾
	var rest_q: Quaternion = _mocap.solver.skel.get_bone_rest(
		_mocap.solver.bones["LeftUpperLeg"]).basis.get_rotation_quaternion()
	_ok((r3["bones"]["LeftUpperLeg"] as Quaternion).is_equal_approx(rest_q),
		"没有上一帧时回静止姿态（也不接垃圾坐标）")

	print("\n[6. 眨眼：MediaPipe 的分数峰值只有 ~0.5，要拉伸校准才闭得上眼]")
	var fb := {"pose": base["pose"], "bs": {"eyeBlinkLeft": 0.5, "eyeBlinkRight": 0.14}}
	var rb := _mocap.solve(fb)
	_ok(float((rb["shapes"] as Dictionary).get("Fcl_EYE_Close_L", 0.0)) > 0.95,
		"闭眼峰值分数 0.5 → 左眼全闭（实为 %.2f）"
		% float((rb["shapes"] as Dictionary).get("Fcl_EYE_Close_L", 0.0)))
	_ok(float((rb["shapes"] as Dictionary).get("Fcl_EYE_Close_R", 1.0)) < 0.1,
		"睁眼基线抖动 0.14 → 右眼几乎不动（不会常年半眯眼）")
	var sm2 := Mocap.smooth(
		{"bones": {}, "shapes": {"Fcl_EYE_Close_L": 0.0}},
		{"bones": {}, "shapes": {"Fcl_EYE_Close_L": 1.0}}, 0.75, 0.2)
	_ok(float(sm2["shapes"]["Fcl_EYE_Close_L"]) >= 0.79,
		"表情走单独的小平滑：一帧就到 %.2f（按骨骼那档 0.75 平滑，眨眼会被磨没）"
		% float(sm2["shapes"]["Fcl_EYE_Close_L"]))

	print("\n[7. 平滑]")
	var f: Array = probe["solved"]
	var sm := Mocap.smooth(f[0], f[1], 0.75)
	var raw := _angle(f[0]["bones"]["RightUpperArm"], f[1]["bones"]["RightUpperArm"])
	var got := _angle(f[0]["bones"]["RightUpperArm"], sm["bones"]["RightUpperArm"])
	_ok(got <= raw + 0.001, "一阶低通把帧间跳变从 %.2f° 压到 %.2f°" % [raw, got])

	print("\n结果：", "全部通过" if _fail == 0 else "%d 项失败" % _fail)
	quit(1 if _fail > 0 else 0)


## 解算一套素材，顺便量重定向保真度（骨头最终朝向 vs 关键点给的方向）
func _load(mocap_path: String, truth_path: String) -> Dictionary:
	var truth: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(truth_path))
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(mocap_path))
	var solved := []
	var truth_dirs := []
	var got_dirs := []
	var fidelity := 0.0
	var bone_count := 0
	for i in range((data["frames"] as Array).size()):
		var frame: Dictionary = data["frames"][i]
		var r := _mocap.solve(frame)
		if r.is_empty() or not truth.has(str(i)):
			continue
		bone_count = (r["bones"] as Dictionary).size()
		var dg := _mocap.global_dirs(r["bones"])
		var t := _mocap.targets(frame)
		for b in AIMED:
			fidelity = maxf(fidelity, rad_to_deg(
				(dg[b] as Vector3).angle_to((t[b] as Vector3).normalized())))
		var truth_rots := {}
		for b in truth[str(i)]:
			var a: Array = truth[str(i)][b]
			truth_rots[b] = Quaternion(a[0], a[1], a[2], a[3])
		solved.append(r)
		got_dirs.append(dg)
		truth_dirs.append(_mocap.global_dirs(truth_rots))
	return {"frames": solved.size(), "bones": bone_count, "fidelity": fidelity,
		"solved": solved, "truth_dirs": truth_dirs, "got_dirs": got_dirs}


## 逐骨报告指向偏差；flatten = 把方向压到正面平面（Z 归零）再比，用来隔离深度误差
func _report(data: Dictionary, flatten: bool) -> Dictionary:
	var arm_sum := 0.0
	var arm_n := 0
	for b in REPORT:
		var mean := 0.0
		var n := 0
		for i in range((data["truth_dirs"] as Array).size()):
			var a: Vector3 = data["truth_dirs"][i][b]
			var c: Vector3 = data["got_dirs"][i][b]
			if flatten:
				a = Vector3(a.x, a.y, 0.0)
				c = Vector3(c.x, c.y, 0.0)
				if a.length() < 0.05 or c.length() < 0.05:
					continue   # 骨头几乎正对镜头，压平之后方向没意义
			mean += rad_to_deg(a.angle_to(c))
			n += 1
		mean /= maxi(n, 1)
		print("    %-14s 平均 %5.1f°" % [b, mean])
		if b in AIMED and b.ends_with("Arm"):
			arm_sum += mean
			arm_n += 1
	return {"arms": arm_sum / maxi(arm_n, 1)}


static func _angle(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.dot(b)), 0.0, 1.0)))
