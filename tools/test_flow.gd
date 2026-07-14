extends SceneTree
## 端到端自检：驱动真实的 anim_studio 场景走一遍「拖骨头 → 插关键帧 → 选区间 →
## 创建缓动补间 → 导出 .tres」，再把导出的动画读回来验证轨道内容。
## godot --path . --script res://tools/test_flow.gd --resolution 1600x900

const TEST_NAME := "自检临时动作"

var _fail := 0
var _studio: Node3D
var _frame := 0


func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	_studio = (load("res://scenes/anim_studio.tscn") as PackedScene).instantiate()
	root.add_child(_studio)


func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 5:
		return false     # 等骨架姿态缓存和 UI 都就绪
	_run()
	print("\n结果：", "全部通过" if _fail == 0 else "%d 项失败" % _fail)
	_cleanup()
	quit(1 if _fail > 0 else 0)
	return true


func _run() -> void:
	var s := _studio
	var skel: Skeleton3D = s.skeleton
	var overlay = s._overlay

	print("[拾取]")
	# 右大臂在骨架空间的中点投到屏幕上，应该能被 pick_bone 点中
	var cam: Camera3D = s._cam
	var screen := cam.unproject_position(
		skel.global_transform * ((overlay.joint("RightUpperArm") + overlay.tip("RightUpperArm")) * 0.5))
	_ok(overlay.pick_bone(screen) == "RightUpperArm", "点右大臂中点 → 拾取到 RightUpperArm")
	_ok(overlay.pick_bone(Vector2(50, 700)) == "", "点空地 → 拾取不到骨头")

	print("\n[拖骨头（FK 瞄准）]")
	s._select_bone("RightUpperArm")
	_ok(s._sel_bone == "RightUpperArm" and overlay.selected == "RightUpperArm", "选中同步到 3D 与骨骼树")
	# 往屏幕上某个点拖：拖完骨头朝向应该指向那个点所在的视线
	var drag_to := screen + Vector2(-60, -120)
	s._aim_bone(drag_to)
	_ok(s._pose.has("RightUpperArm"), "拖拽写出了工作姿势")
	s._apply_pose(s._pose)   # 真实运行时这一步在 _process 里，姿势晚一帧才落到骨架上
	# 拖完的骨头尖投回屏幕，应该落在光标附近（同一个面向相机的平面内）
	var tip_screen := cam.unproject_position(skel.global_transform * overlay.tip("RightUpperArm"))
	var joint_screen := cam.unproject_position(skel.global_transform * overlay.joint("RightUpperArm"))
	var want_dir := (drag_to - joint_screen).normalized()
	var got_dir := (tip_screen - joint_screen).normalized()
	_ok(got_dir.dot(want_dir) > 0.999,
		"骨头尖在屏幕上朝向光标（夹角 %.2f°）" % rad_to_deg(acos(clampf(got_dir.dot(want_dir), -1, 1))))

	print("\n[关键帧 / 补间]")
	s._click_frame(0, false)
	s._select_bone("RightUpperArm")
	s._aim_bone(screen + Vector2(-40, -100))
	s._insert_key()
	s._click_frame(20, false)
	s._select_bone("LeftUpperArm")
	var lscreen := cam.unproject_position(skel.global_transform
		* ((overlay.joint("LeftUpperArm") + overlay.tip("LeftUpperArm")) * 0.5))
	s._aim_bone(lscreen + Vector2(60, -110))
	s._insert_key()
	_ok(s._keys.size() == 2 and s._keys.has(0) and s._keys.has(20), "第 0 / 20 帧各落了一个关键帧")
	_ok((s._keys[0] as Dictionary).size() == 52, "关键帧存的是全身 52 根骨的整姿势")

	# 选中 0–20 这一段，建立「缓入缓出」补间
	s._click_frame(0, false)
	s._click_frame(20, true)
	_ok(s._sel_a == 0 and s._sel_b == 20, "Shift 点击拉出了 0–20 选区")
	s._ease_opt.selected = AnimBaker.Ease.IN_OUT
	s._make_tween()
	_ok(s._spans.get(0) == AnimBaker.Ease.IN_OUT, "0–20 区间挂上了缓入缓出")

	# 中间帧的姿势必须按缓动走，而不是线性
	var a: Quaternion = s._keys[0]["RightUpperArm"]
	var b: Quaternion = s._keys[20]["RightUpperArm"]
	var mid_pose: Quaternion = AnimBaker.sample(s._keys, 5.0, s._spans)["RightUpperArm"]
	_ok(mid_pose.is_equal_approx(a.slerp(b, AnimBaker.ease_t(0.25, AnimBaker.Ease.IN_OUT))),
		"第 5 帧采样 = 缓动后的 slerp（不是线性）")

	print("\n[导出]")
	s._name_edit.text = TEST_NAME
	s._export_anim()
	var path := "res://animations/custom/%s.tres" % TEST_NAME
	_ok(ResourceLoader.exists(path), "导出了 %s" % path)
	var anim: Animation = load(path)
	_ok(anim != null and anim.get_track_count() == 52, "动画有 52 条骨骼轨道（实得 %d）"
		% (anim.get_track_count() if anim else -1))
	if anim != null:
		var p := String(anim.track_get_path(0))
		_ok(p.begins_with("%GeneralSkeleton:"), "轨道路径是 %%GeneralSkeleton:骨骼名（实为 %s）" % p)
		_ok(anim.track_get_type(0) == Animation.TYPE_ROTATION_3D, "轨道类型是 rotation_3d")
		# 缓动区间要逐帧烘死：0–20 共 21 个关键帧
		_ok(anim.track_get_key_count(0) == 21,
			"缓动区间逐帧烘焙 → 每条轨道 21 个关键帧（实得 %d）" % anim.track_get_key_count(0))
		_ok(is_equal_approx(anim.length, 48.0 / AnimBaker.FPS), "动画时长 = 48 帧 / 30fps")
		_ok(anim.loop_mode == Animation.LOOP_LINEAR, "循环模式 = LOOP_LINEAR")

	print("\n[工程存读]")
	var data := AnimBaker.load_project(TEST_NAME)
	_ok(data["ok"] and (data["keys"] as Dictionary).size() == 2, "工程 .pose.json 存下了 2 个关键帧")
	_ok((data["spans"] as Dictionary).get(0) == AnimBaker.Ease.IN_OUT, "工程存下了补间区间的缓动曲线")

	# 旧工程（12 根骨、没有 spans 字段）必须照读不误，补间行为退回全线性。
	# 用一份专门冻起来的副本（_自检旧工程），不用示例动作「圆舞_循环」本身——示例是用户会
	# 打开来改的，拿它当测试基准的话，用户存一次盘测试就红了（真发生过，示例还被覆盖了）
	print("\n[旧工程兼容]")
	var old := AnimBaker.load_project("_自检旧工程")
	_ok(old["ok"], "读得动旧格式工程（12 根骨、无 spans/shapes 字段）")
	_ok((old["spans"] as Dictionary).is_empty(), "旧工程没有 spans 字段 → 默认全线性")
	s._name_edit.text = "_自检旧工程"
	s._load_project()
	_ok(s._keys.size() > 0 and s._spans.is_empty(), "旧工程读进编辑器（%d 个关键帧）" % s._keys.size())
	var old_anim := AnimBaker.bake(s._keys, s._len, s._loop, s._spans)
	_ok(old_anim.get_track_count() == 12,
		"旧工程只烘出它自己那 12 条轨道（实得 %d）" % old_anim.get_track_count())


func _cleanup() -> void:
	for f in ["res://animations/custom/%s.tres" % TEST_NAME,
			"res://animations/custom/%s.pose.json" % TEST_NAME]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
