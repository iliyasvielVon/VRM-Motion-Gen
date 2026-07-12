extends SceneTree
## 启动动作工房主场景，截一张图存到 user://（人工看一眼布局用）。
## 加 --mocap 会顺手导入一段动补关键点再截图。
## godot --path . --script res://tools/shoot.gd --resolution 1600x900 [-- --mocap]

var _studio: Node3D
var _n := 0
var _mocap := false
var _shot := "studio"


func _initialize() -> void:
	_mocap = "--mocap" in OS.get_cmdline_user_args() or "--mocap" in OS.get_cmdline_args()
	if _mocap:
		_shot = "studio_mocap"
	_studio = (load("res://scenes/anim_studio.tscn") as PackedScene).instantiate()
	root.add_child(_studio)


func _process(_d: float) -> bool:
	_n += 1
	if _n == 10 and "--ik" in OS.get_cmdline_user_args():
		# 拖左手去够身前远处的一个点：手臂先伸直，够不着了躯干才弯腰拧腰，双脚锁地
		_shot = "studio_ik"
		_studio._select_bone("LeftHand")
		# 从「双臂自然下垂」起手，而不是 T-pose：躯干一让步，没被拖的那条手臂会保持它
		# 相对胸腔的姿态跟着转——起手是 T-pose 的话，右臂会跟着甩到天上去，看着像 bug
		var start := {}
		var skel: Skeleton3D = _studio.skeleton
		for b in ["LeftUpperArm", "RightUpperArm"]:
			start[b] = Quaternion(Vector3.RIGHT, deg_to_rad(-70)) \
				* skel.get_bone_rest(_studio._bones[b]).basis.get_rotation_quaternion()
		var shoulder: Vector3 = _studio._solver.global_pose(start)["LeftUpperArm"].origin
		var target: Vector3 = shoulder + Vector3(0.05, -0.35, 0.62)
		var r: Dictionary = _studio._bodyik.solve(start, Vector3.ZERO, "LeftHand", target, true)
		_studio._pose = r["bones"]
		_studio._root_off = r["root"]
		_studio._insert_key()
		var got: Vector3 = _studio._solver.global_pose(r["bones"], r["root"])["LeftHand"] \
			* _studio._solver.tips["LeftHand"]
		print("IK 肩 %v 目标 %v → 实到 %v（差 %.1f mm）"
			% [shoulder, target, got, got.distance_to(target) * 1000.0])
		return false
	if _n == 10 and _mocap:
		for i in _studio._mocap_opt.item_count:
			if _studio._mocap_opt.get_item_text(i) == "自检正面.mocap.json":
				_studio._mocap_opt.selected = i
		_studio._import_mocap()
		_studio._click_frame(10, false)
		_studio._select_bone("LeftUpperArm")
		return false
	if _n < 40:
		return false
	root.get_texture().get_image().save_png("user://%s.png" % _shot)
	print("SHOT -> ", ProjectSettings.globalize_path("user://%s.png" % _shot))
	quit()
	return true
