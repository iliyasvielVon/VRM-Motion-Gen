extends SceneTree
## 给动补重定向做「干净素材」：造一段**只在正面平面内**（Z≈0）的动作——双臂在身体两侧
## 张合、屈肘、抬腿。单目姿态估计最弱的就是深度（Z）方向，用没有深度歧义的动作，才能把
## 「我的重定向对不对」和「MediaPipe 准不准」分开。
##
## 逐帧存 PNG 到 user://mocap_probe/ + 真值骨骼旋转 truth.json。
## godot --path . --script res://tools/render_probe.gd --resolution 720x1280

const FRAMES := 40

var _skel: Skeleton3D
var _bones := {}
var _tips := {}
var _parents := {}
var _order: Array[String] = []
var _pending := -1
var _n := -4
var _truth := {}


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.42, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.2
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, 20, 0)
	world.add_child(light)

	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	world.add_child(scene)
	_skel = AvatarContext.new(scene).skeleton
	_bones = HumanoidBones.resolve_all(_skel)
	_parents = HumanoidBones.humanoid_parents(_skel, _bones)
	_tips = HumanoidBones.bone_tips(_skel, _bones, _parents)
	for b in HumanoidBones.humanoid_names():
		if _bones.has(b):
			_order.append(b)

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.position = Vector3(0, 0.85, 2.9)
	world.add_child(cam)
	cam.make_current()
	DirAccess.make_dir_recursive_absolute("user://mocap_probe")


## 第 f 帧每根骨头该指向哪（骨架空间，全部落在正面平面 Z=0 上）
func _targets(f: int) -> Dictionary:
	var t := float(f) / float(FRAMES) * TAU
	var open := deg_to_rad(20.0 + 60.0 * (0.5 + 0.5 * sin(t)))        # 双臂张开角（离体侧）
	var bend := deg_to_rad(10.0 + 60.0 * (0.5 + 0.5 * sin(t * 2.0)))  # 屈肘角
	var lift := deg_to_rad(12.0 * (0.5 + 0.5 * sin(t)))               # 抬腿
	# 人物的左手边 = +X。大臂从水平往上抬 open 度；小臂在大臂基础上再折 bend 度。
	var lu := Vector3(cos(open), sin(open), 0)
	var ll := Vector3(cos(open + bend), sin(open + bend), 0)
	return {
		"LeftUpperArm": lu,
		"LeftLowerArm": ll,
		"RightUpperArm": Vector3(-lu.x, lu.y, 0),
		"RightLowerArm": Vector3(-ll.x, ll.y, 0),
		"LeftUpperLeg": Vector3(sin(lift), -cos(lift), 0),
		"RightUpperLeg": Vector3(-sin(lift), -cos(lift), 0),
	}


## 正向运动学 + 最短弧瞄准：把每根骨头扭到目标方向，返回局部旋转（父在前子在后）
func _solve(targets: Dictionary) -> Dictionary:
	var out := {}
	var g := {}
	for bname in _order:
		var pname: String = _parents[bname]
		var parent_g: Basis = g.get(pname, Basis.IDENTITY) if pname != "" \
			else _skel.get_bone_global_rest(_skel.get_bone_parent(_bones[bname])).basis.orthonormalized()
		var gb: Basis = parent_g * _skel.get_bone_rest(_bones[bname]).basis.orthonormalized()
		if targets.has(bname):
			var cur := (gb * (_tips[bname] as Vector3)).normalized()
			gb = Basis(Quaternion(cur, (targets[bname] as Vector3).normalized())) * gb
		g[bname] = gb
		out[bname] = (parent_g.inverse() * gb).get_rotation_quaternion().normalized()
	return out


func _process(_d: float) -> bool:
	_n += 1
	if _n < 0:
		return false
	if _pending >= 0:
		root.get_texture().get_image().save_png("user://mocap_probe/%03d.png" % _pending)
	if _pending + 1 >= FRAMES:
		var f := FileAccess.open("res://animations/mocap/自检正面.truth.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(_truth))
		print("PROBE -> ", ProjectSettings.globalize_path("user://mocap_probe/"))
		quit()
		return true

	var frame := _pending + 1
	var rots := _solve(_targets(frame))
	var tf := {}
	for b in rots:
		var q: Quaternion = rots[b]
		_skel.set_bone_pose_rotation(_bones[b], q)
		tf[b] = [q.x, q.y, q.z, q.w]
	_truth[str(frame)] = tf
	_pending = frame
	return false
