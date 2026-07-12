extends SceneTree
## 端到端：驱动真实的 anim_studio 场景走一遍「导入动补 → 抽稀 → 导出」，
## 再把导出的 .tres 挂到 AnimationPlayer 上真播一遍，确认骨骼和表情都真的被驱动了。
## godot --path . --script res://tools/test_mocap_flow.gd --resolution 1600x900

const SRC := "自检正面.mocap.json"
const TEST_NAME := "自检动补临时"

var _fail := 0
var _studio: Node3D
var _n := 0
var _anim: Animation
var _mesh: MeshInstance3D
var _skel: Skeleton3D
var _ap: AnimationPlayer
var _bone := -1


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
	_n += 1
	if _n < 5:
		return false
	if _n == 5:
		_run()
		return false
	if _n == 8:                 # 等 AnimationPlayer 真的推进几帧
		_check_playback()
		print("\n结果：", "全部通过" if _fail == 0 else "%d 项失败" % _fail)
		_cleanup()
		quit(1 if _fail > 0 else 0)
		return true
	return false


func _run() -> void:
	var s := _studio

	print("[导入视频动补]")
	var idx := -1
	for i in s._mocap_opt.item_count:
		if s._mocap_opt.get_item_text(i) == SRC:
			idx = i
	_ok(idx >= 0, "动补文件下拉框里找得到 %s" % SRC)
	s._mocap_opt.selected = idx
	s._import_mocap()
	var imported: int = s._keys.size()
	_ok(imported >= 30, "导入了 %d 帧关键帧" % imported)
	_ok((s._keys[s._keys.keys()[0]] as Dictionary).size() == 52, "每帧都是全身 52 根骨的整姿势")

	# 导入的姿势必须真的不是静止姿态（不然等于什么都没干）
	var moved := 0
	var first: Dictionary = s._keys[s._keys.keys()[0]]
	for b in first:
		var rest: Quaternion = s._rest_rot[s._bones[b]]
		if rad_to_deg(2.0 * acos(clampf(absf((first[b] as Quaternion).dot(rest)), 0, 1))) > 5.0:
			moved += 1
	_ok(moved >= 6, "第一帧里有 %d 根骨偏离了静止姿态（动补真的摆了姿势）" % moved)

	print("\n[抽稀]")
	# 表情：这段素材是动漫脸，认出率低，手动塞一个保证表情通路被测到
	s._shapes[0] = {"Fcl_MTH_A": 0.0}
	s._shapes[10] = {"Fcl_MTH_A": 1.0}
	s._shapes[20] = {"Fcl_MTH_A": 0.0}
	s._decimate()
	_ok(s._keys.size() < imported, "抽稀把 %d 帧压到 %d 帧" % [imported, s._keys.size()])
	_ok(s._keys.size() >= 2, "抽稀后至少还剩首尾两帧")
	_ok(s._spans.is_empty(), "抽稀后区间全线性")

	print("\n[导出]")
	s._shapes = {0: {"Fcl_MTH_A": 0.0}, 10: {"Fcl_MTH_A": 1.0}, 20: {"Fcl_MTH_A": 0.0}}
	s._name_edit.text = TEST_NAME
	s._export_anim()
	var path := "res://animations/custom/%s.tres" % TEST_NAME
	_ok(ResourceLoader.exists(path), "导出了 %s" % path)
	_anim = load(path)
	var rot := 0
	var bs := 0
	for t in _anim.get_track_count():
		if _anim.track_get_type(t) == Animation.TYPE_ROTATION_3D:
			rot += 1
		elif _anim.track_get_type(t) == Animation.TYPE_BLEND_SHAPE:
			bs += 1
	_ok(rot == 52, "52 条骨骼旋转轨道（实得 %d）" % rot)
	_ok(bs == 1, "1 条表情形变轨道（实得 %d）" % bs)

	# 真播一遍：把导出的动画挂到一个干净的模型上
	print("\n[挂到 AnimationPlayer 上真播]")
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	_skel = AvatarContext.new(scene).skeleton
	_mesh = scene.find_child("Face", true, false) as MeshInstance3D
	_bone = _skel.find_bone("RightUpperArm")
	var lib := AnimationLibrary.new()
	lib.add_animation("t", _anim)
	_ap = AnimationPlayer.new()
	scene.add_child(_ap)
	_ap.add_animation_library("", lib)
	_ap.play("t")
	_ap.seek(10.0 / AnimBaker.FPS, true)   # 第 10 帧：嘴张到最大
	_ap.pause()                            # 不暂停的话下面几帧播放头就滑过去了，读到的是插值中间值


func _check_playback() -> void:
	var rest: Quaternion = _skel.get_bone_rest(_bone).basis.get_rotation_quaternion()
	var now := _skel.get_bone_pose_rotation(_bone)
	var moved := rad_to_deg(2.0 * acos(clampf(absf(now.dot(rest)), 0, 1)))
	_ok(moved > 5.0, "播放时 RightUpperArm 被驱动了（偏离静止姿态 %.1f°）" % moved)
	var mouth := float(_mesh.get("blend_shapes/Fcl_MTH_A"))
	_ok(mouth > 0.8, "播放到第 10 帧时嘴型 Fcl_MTH_A = %.2f（表情轨道生效）" % mouth)


func _cleanup() -> void:
	for f in ["res://animations/custom/%s.tres" % TEST_NAME,
			"res://animations/custom/%s.pose.json" % TEST_NAME]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
