extends SceneTree
## 给多相机融合做「第二机位」素材：同一段确定性动作（和 render_probe 相同），
## 从指定偏航角的机位渲染。跑两次（0° 和 65°）就得到一对已知夹角的同步序列——
## test_rig_real.py 拿它验证「真实 MediaPipe 管线下，标定能把机位夹角解回来」。
## 合成测试（test_rig.py）只考数学；这个考的是 MediaPipe 世界关键点
## 「朝向跟着相机走」这一前提本身。
##
## godot --path . --script res://tools/render_rig.gd --resolution 720x1280 -- --yaw 65

const FRAMES := 40

var _skel: Skeleton3D
var _bones := {}
var _tips := {}
var _parents := {}
var _order: Array[String] = []
var _pending := -1
var _n := -4
var _yaw := 0.0
var _dir := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--yaw")
	if i >= 0 and i + 1 < args.size():
		_yaw = float(args[i + 1])
	_dir = "user://rig_%d" % int(_yaw)

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

	# 机位绕人（0, 0.85, 0）水平转 _yaw 度，距离和俯仰跟 render_probe 一致
	var a := deg_to_rad(_yaw)
	var cam := Camera3D.new()
	cam.fov = 40.0
	var pos := Vector3(2.9 * sin(a), 0.85, 2.9 * cos(a))
	# look_at 要求节点已在树里且下一帧才生效，_initialize 里不可靠——直接构造朝向
	cam.transform = Transform3D(
		Basis.looking_at((Vector3(0, 0.85, 0) - pos).normalized(), Vector3.UP), pos)
	world.add_child(cam)
	cam.make_current()
	DirAccess.make_dir_recursive_absolute(_dir)


## 和 render_probe 相同的确定性动作（正面平面内张合屈肘 + 抬腿），保证两个机位帧同步
func _targets(f: int) -> Dictionary:
	var t := float(f) / float(FRAMES) * TAU
	var open := deg_to_rad(20.0 + 60.0 * (0.5 + 0.5 * sin(t)))
	var bend := deg_to_rad(10.0 + 60.0 * (0.5 + 0.5 * sin(t * 2.0)))
	var lift := deg_to_rad(12.0 * (0.5 + 0.5 * sin(t)))
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
		root.get_texture().get_image().save_png("%s/%03d.png" % [_dir, _pending])
	if _pending + 1 >= FRAMES:
		print("RIGVIEW -> ", ProjectSettings.globalize_path(_dir), " yaw=", _yaw)
		quit()
		return true
	var frame := _pending + 1
	var rots := _solve(_targets(frame))
	for b in rots:
		_skel.set_bone_pose_rotation(_bones[b], rots[b])
	_pending = frame
	return false
