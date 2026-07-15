extends SceneTree
## 给多相机融合做「第二机位」素材：同一段确定性动作（和 render_probe 相同），
## 从指定偏航角的机位渲染。跑两次（0° 和 65°）就得到一对已知夹角的同步序列——
## test_rig_real.py 拿它验证「真实 MediaPipe 管线下，标定能把机位夹角解回来」。
## 合成测试（test_rig.py）只考数学；这个考的是 MediaPipe 世界关键点
## 「朝向跟着相机走」这一前提本身。
##
## godot --path . --script res://tools/render_rig.gd --resolution 720x1280 -- --yaw 65

const FRAMES := 120   # 4 秒：对时的互相关要够长的重叠才可信（短片段相关系数会趴地上）

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


## 确定性但**非周期**、且带**出平面**（前后向）分量的动作。三个都是刻意的：
##   非周期（不可通约频率）—— 视频对时靠互相关，周期动作的峰值到处是别名；
##   出平面 —— 近平面的点云镜像后能被旋转硬凑上（残差骗过标定门槛，实测发生过），
##            手臂前后摆开之后镜像残差才真正撑起来；
##   确定性 —— 两个机位靠帧号天然同步，不需要另行对齐。
func _targets(f: int) -> Dictionary:
	var t := float(f) / 30.0 * TAU * 0.55
	# 每个角度都叠两个不可通约频率：单频正弦的互相关满地都是周期别名格，
	# 对时会锁到错的峰上（+78 帧那次就是 28 帧周期的肘弯干的）
	var open := deg_to_rad(20.0 + 55.0 * (0.5 + 0.3 * sin(t * 1.13) + 0.2 * sin(t * 2.71 + 1.7)))
	var bend := deg_to_rad(10.0 + 60.0 * (0.5 + 0.3 * sin(t * 1.97 + 0.9) + 0.2 * sin(t * 3.31)))
	# ±22°：再大（试过 ±50°）侧机位视角下手臂持续被躯干挡住，MediaPipe 的"检出"
	# 全靠脑补，坐标是编的——对时和标定全崩。真人拍动补也一样：别把手藏到身后。
	var fwd := deg_to_rad(22.0) * sin(t * 0.71 + 0.3)
	var lift := deg_to_rad(14.0) * (0.5 + 0.3 * sin(t * 0.83 + 1.1) + 0.2 * sin(t * 2.23 + 0.4))
	var kick := 0.3 * sin(t * 0.57 + 2.0)                        # 腿也带点前后
	var lu := Vector3(cos(open) * cos(fwd), sin(open), cos(open) * sin(fwd))
	var lb := open + bend
	var ll := Vector3(cos(lb) * cos(fwd), sin(lb), cos(lb) * sin(fwd))
	return {
		"LeftUpperArm": lu,
		"LeftLowerArm": ll,
		"RightUpperArm": Vector3(-lu.x, lu.y, lu.z),
		"RightLowerArm": Vector3(-ll.x, ll.y, ll.z),
		"LeftUpperLeg": Vector3(sin(lift), -cos(lift), kick).normalized(),
		"RightUpperLeg": Vector3(-sin(lift), -cos(lift), -kick).normalized(),
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
