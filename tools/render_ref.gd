extends SceneTree
## 渲染一段「已知姿势」的参考素材给动补管线做自检：
## 让 avatar 播放 animations/custom/<名>.pose.json 的姿势，逐帧存 PNG 到 user://mocap_ref/，
## 同时把每帧的真值骨骼旋转存成 truth.json —— 动补捕回来的姿势可以直接跟它比。
##
## godot --path . --script res://tools/render_ref.gd --resolution 720x1280

const CLIP := "圆舞_循环"
const FRAMES := 48

var _skel: Skeleton3D
var _bones := {}
var _rest := {}
var _keys := {}
var _spans := {}
var _n := -4          # 前几帧等渲染管线热身
var _truth := {}


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.6, 0.65)     # 浅灰背景，人像分割好认
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.4
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, 20, 0)
	light.light_energy = 1.4
	world.add_child(light)

	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	world.add_child(scene)
	_skel = AvatarContext.new(scene).skeleton
	_bones = HumanoidBones.resolve_all(_skel)
	for b in _bones:
		_rest[_bones[b]] = _skel.get_bone_rest(_bones[b]).basis.get_rotation_quaternion()

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.position = Vector3(0, 0.85, 2.9)              # 全身入镜，正面
	world.add_child(cam)
	cam.make_current()

	var data := AnimBaker.load_project(CLIP)
	if not data["ok"]:
		push_error("读不到工程 " + CLIP)
		quit(1)
		return
	_keys = data["keys"]
	_spans = data["spans"]
	DirAccess.make_dir_recursive_absolute("user://mocap_ref")


## 注意：_process 里不能 await（返回值会变成协程，被当成 truthy 直接结束主循环）。
## 所以流程是「本帧先把上一帧渲出来的画面存盘，再摆下一帧的姿势」，天然错开一帧。
var _pending := -1


func _process(_d: float) -> bool:
	_n += 1
	if _n < 0:
		return false
	if _pending >= 0:
		root.get_texture().get_image().save_png("user://mocap_ref/%03d.png" % _pending)
	if _pending + 1 >= FRAMES:
		var f := FileAccess.open("res://animations/mocap/自检参考.truth.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(_truth))
		print("REF -> ", ProjectSettings.globalize_path("user://mocap_ref/"), " (", FRAMES, " 帧)")
		quit()
		return true

	var frame := _pending + 1
	var pose := AnimBaker.sample(_keys, float(frame), _spans)
	var truth_frame := {}
	for b in _bones:
		var q: Quaternion = pose.get(b, _rest[_bones[b]])
		_skel.set_bone_pose_rotation(_bones[b], q)
		truth_frame[b] = [q.x, q.y, q.z, q.w]
	_truth[str(frame)] = truth_frame
	_pending = frame
	return false
