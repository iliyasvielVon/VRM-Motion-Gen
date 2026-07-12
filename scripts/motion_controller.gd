class_name MotionController
extends Node
## 动作预览：无需任何动画素材的程序化动作（待机/摇摆/鞠躬/点头/挥手），
## 直接驱动 Skeleton3D 的骨骼姿态。骨骼名走 Godot 人形 Profile
## （godot-vrm 导入时已重定向）。对应 Unity 参考工程的 ProceduralMotion.cs。

const HumanoidBonesResolver = preload("res://scripts/humanoid_bones.gd")
const PoseBlend = preload("res://scripts/pose_blend.gd")

## 动作切换的交叉淡出时长（秒）
const BLEND_TIME := 0.35

enum Mode { NONE, IDLE, SWAY, BOW, NOD, WAVE }

const MOTIONS := [
	["待机", Mode.IDLE],
	["摇摆", Mode.SWAY],
	["鞠躬", Mode.BOW],
	["点头", Mode.NOD],
	["挥手", Mode.WAVE],
	["停止", Mode.NONE],
]

## Mixamo 等外部动画剪辑目录：FBX 需在导入设置里挂 BoneMap 重定向
## （见 animations/mixamo/Walking.fbx.import），轨道路径才是 %GeneralSkeleton:骨骼名
const CLIP_DIR := "res://animations/mixamo"

var skeleton: Skeleton3D
var mode: Mode = Mode.IDLE

var _clip_player: AnimationPlayer
var _blend: SkeletonModifier3D
var _follower_blends: Array = []   # 衣柜跟随骨架的过渡缓冲，与本体同步快照/衰减

var _t := 0.0
var _bones := {}          # 名字 -> 骨骼索引
var _rest_rot := {}       # 索引 -> 静止旋转
var _rest_pos := {}       # 索引 -> 静止位置

# ---- IK 驱动（圆舞棍等轨迹动作：外部每帧喂腕目标，右臂 two-bone 解算）
var _ik: ArmIK
var _ik_active := false
var _ik_target_world := Vector3.ZERO
var _ik_pole_world := Vector3(1, -0.5, 0)
var _ik_torso_yaw := 0.0             # 躯干拧转（弧度），随挥舞相位
var last_ik_wrist := Vector3.ZERO    # 解算后的腕位置（世界空间，拖尾/自检用）

const DRIVEN := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"RightShoulder", "RightUpperArm", "RightLowerArm",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm"]


func setup(skel: Skeleton3D) -> void:
	# 旧剪辑播放器挂在旧模型场景下，随模型销毁，直接丢引用
	if _clip_player != null and is_instance_valid(_clip_player):
		_clip_player.queue_free()
	_clip_player = null
	skeleton = skel
	_blend = null
	_follower_blends.clear()
	if skeleton != null:
		_blend = PoseBlend.new()
		_blend.active = false
		skeleton.add_child(_blend)
	_bones.clear()
	_rest_rot.clear()
	_rest_pos.clear()
	if skeleton == null:
		return
	# 拓扑解析优先（骨骼名在部分导入管线上不可信），find_bone 兜底
	var resolved: Dictionary = HumanoidBonesResolver.resolve(skeleton)
	for bname in DRIVEN:
		var idx: int = resolved.get(bname, skeleton.find_bone(bname))
		if idx >= 0:
			_bones[bname] = idx
			_rest_rot[idx] = skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()
			_rest_pos[idx] = skeleton.get_bone_rest(idx).origin
	var detail := ""
	for bname in _bones:
		detail += "%s=%d(名:%s) " % [bname, _bones[bname], skeleton.get_bone_name(_bones[bname])]
	print("动作系统骨骼映射 %d/%d（拓扑解析 %d 根）: %s" % [_bones.size(), DRIVEN.size(), resolved.size(), detail])
	# 右臂 IK：手骨 = 小臂下最"茂盛"的子骨骼（手指子树大），find_bone 兜底
	_ik = ArmIK.new()
	_ik_active = false
	var lower_idx: int = _bones.get("RightLowerArm", -1)
	_ik.setup(skeleton, _bones.get("RightUpperArm", -1), lower_idx, _find_hand(lower_idx))


## 小臂的子骨骼里挑子树节点最多的当手骨（手指撑大子树）；拓扑失败用名字兜底
func _find_hand(lower_idx: int) -> int:
	if lower_idx >= 0:
		var best := -1
		var best_n := -1
		for c in skeleton.get_bone_children(lower_idx):
			var n := _count_subtree(c)
			if n > best_n:
				best_n = n
				best = c
		if best >= 0:
			return best
	return skeleton.find_bone("RightHand")


func _count_subtree(bone: int) -> int:
	var n := 1
	for c in skeleton.get_bone_children(bone):
		n += _count_subtree(c)
	return n


## 注册衣柜跟随骨架（在 setup 之后调用），给每根骨架配同步的过渡缓冲
func set_followers(skels: Array) -> void:
	_follower_blends.clear()
	for sk in skels:
		var b: SkeletonModifier3D = PoseBlend.new()
		b.active = false
		sk.add_child(b)
		_follower_blends.append(b)


func _capture_all() -> void:
	if _blend != null:
		_blend.capture()
	for b in _follower_blends:
		if is_instance_valid(b):
			b.capture()


func set_mode(m: Mode) -> void:
	_capture_all()   # 先快照当前姿态，再动骨架，淡出交给 _process
	_stop_clip()
	_ik_active = false
	mode = m
	_t = 0.0
	_reset_pose()


# ---------------------------------------------------------------- IK 驱动

## 进入 IK 驱动（圆舞棍等轨迹动作）：快照当前姿态平滑过渡，停掉剪辑/程序化模式
func ik_begin() -> void:
	_capture_all()
	_stop_clip()
	mode = Mode.NONE
	_ik_active = true


## 每帧喂腕目标（世界空间）。pole = 肘尖大致朝向；torso_yaw = 躯干拧转弧度
func ik_update(target_world: Vector3, pole_world: Vector3, torso_yaw := 0.0) -> void:
	_ik_target_world = target_world
	_ik_pole_world = pole_world
	_ik_torso_yaw = torso_yaw


## 结束 IK 驱动：快照 IK 末姿态做淡出，交还给 set_mode / play_clip
func ik_end() -> void:
	if not _ik_active:
		return
	_capture_all()
	_ik_active = false
	_reset_pose()


func is_ik_active() -> bool:
	return _ik_active


## IK 姿态施加：每帧从静止姿态起算——左臂放松、躯干随挥舞拧转、右臂解算到目标
func _apply_ik() -> void:
	_reset_pose()
	_rot("LeftUpperArm", Vector3.RIGHT, deg_to_rad(-60.0))
	_rot("LeftLowerArm", Vector3.RIGHT, deg_to_rad(-8.0))
	_rot("Spine", Vector3.UP, _ik_torso_yaw * 0.5)
	_rot("Chest", Vector3.UP, _ik_torso_yaw * 0.5)
	_rot("Head", Vector3.UP, -_ik_torso_yaw * 0.4)
	if _ik == null or not _ik.valid():
		return
	var inv := skeleton.global_transform.affine_inverse()
	var wrist_local: Vector3 = _ik.solve(inv * _ik_target_world,
		(inv.basis * _ik_pole_world).normalized())
	last_ik_wrist = skeleton.global_transform * wrist_local


# ---------------------------------------------------------------- 动画剪辑

## 列出剪辑目录里的动画文件（导出包里文件名带 .remap 后缀，需剥掉）；
## 动作工房导出的自制动作（animations/custom/*.tres）也一并列出
static func list_clips() -> Array[String]:
	var out: Array[String] = []
	for dir_cfg in [[CLIP_DIR, ["fbx", "glb", "gltf"]], [AnimBaker.CUSTOM_DIR, ["tres", "res"]]]:
		var dir := DirAccess.open(dir_cfg[0])
		if dir == null:
			continue
		for f in dir.get_files():
			var fname := (f as String).trim_suffix(".remap")
			if fname.get_extension().to_lower() in (dir_cfg[1] as Array):
				out.append(str(dir_cfg[0]) + "/" + fname)
	out.sort()
	return out


## 播放一个动画剪辑。所有剪辑合入一个常驻 AnimationPlayer 的动画库：
## 剪辑→剪辑用原生 custom_blend 交叉混合（两个循环在过渡期都继续播）
## 并按归一化相位对齐步态；程序化→剪辑仍走 pose_blend 快照缓冲。
func play_clip(path: String) -> void:
	if skeleton == null:
		return
	if _ik_active:
		ik_end()   # 剪辑与 IK 互斥：都逐帧写姿态，同时跑会互相打架
	var anim_name := _ensure_clip_loaded(path)
	if anim_name.is_empty():
		return
	var ap := _clip_player
	if ap.is_playing() and ap.current_animation != anim_name:
		# 剪辑 → 剪辑：交叉混合 + 步态相位对齐（两个循环 t=0 相位一致时最有效）
		var phase := fmod(ap.current_animation_position / ap.current_animation_length, 1.0)
		var new_len := ap.get_animation(anim_name).length
		ap.play(anim_name, BLEND_TIME)
		ap.seek(phase * new_len, false)
	elif not ap.is_playing():
		# 程序化/静止 → 剪辑：快照当前姿态做淡出缓冲
		_capture_all()
		mode = Mode.NONE
		_t = 0.0
		_reset_pose()
		ap.play(anim_name)


## 确保剪辑已抽取进常驻 AnimationPlayer 的动画库，返回库内动画名（失败返回空）
func _ensure_clip_loaded(path: String) -> String:
	if _clip_player == null or not is_instance_valid(_clip_player):
		_clip_player = AnimationPlayer.new()
		_clip_player.add_animation_library("", AnimationLibrary.new())
		var host: Node = skeleton.owner if skeleton.owner != null else skeleton.get_parent()
		host.add_child(_clip_player)
	var lib := _clip_player.get_animation_library("")
	var anim_name := path.get_file().get_basename()
	if lib.has_animation(anim_name):
		return anim_name
	var res := load(path)
	var anim: Animation = null
	if res is Animation:
		anim = res   # 动作工房导出的 .tres 直接就是 Animation
	elif res is PackedScene:
		var scene := (res as PackedScene).instantiate()
		var src_ap := _find_anim_player(scene)
		if src_ap != null:
			for n in src_ap.get_animation_list():
				if n != "RESET":
					anim = src_ap.get_animation(n)
					break
		scene.queue_free()
	if anim == null:
		push_warning("动画文件里没有可播放的动画: " + path)
		return ""
	if not _is_retargeted(anim):
		push_warning("剪辑未做人形重定向（轨道对不上 VRM 骨架），先运行 tools/setup_mixamo.bat: " + path)
		return ""
	lib.add_animation(anim_name, anim)
	return anim_name


## 重定向过的剪辑轨道路径是 %GeneralSkeleton:骨骼名，原始 Mixamo 轨道对不上
static func _is_retargeted(anim: Animation) -> bool:
	for t in anim.get_track_count():
		if String(anim.track_get_path(t)).begins_with("%GeneralSkeleton"):
			return true
	return false


## 当前是否有剪辑在播（单次剪辑播完返回 false，用于攻击/跳跃收尾判断）
func is_clip_active() -> bool:
	return _clip_player != null and is_instance_valid(_clip_player) and _clip_player.is_playing()


## 调整当前剪辑的播放速度（走路/冲刺共用一个跑步剪辑时区分节奏）
func set_clip_speed(s: float) -> void:
	if _clip_player != null and is_instance_valid(_clip_player):
		_clip_player.speed_scale = s


func _stop_clip() -> void:
	if _clip_player != null and is_instance_valid(_clip_player) and _clip_player.is_playing():
		_clip_player.stop()
		# 剪辑驱动的骨骼远多于 DRIVEN（腿/手指），全骨架回到静止姿态
		if skeleton != null:
			skeleton.reset_bone_poses()


static func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found != null:
			return found
	return null


func _reset_pose() -> void:
	if skeleton == null:
		return
	for idx in _rest_rot.keys():
		skeleton.set_bone_pose_rotation(idx, _rest_rot[idx])
		skeleton.set_bone_pose_position(idx, _rest_pos[idx])


func _process(delta: float) -> void:
	if skeleton == null:
		return
	if _blend != null:
		_blend.fade(delta, BLEND_TIME)
	for b in _follower_blends:
		if is_instance_valid(b):
			b.fade(delta, BLEND_TIME)
	if _ik_active:
		_apply_ik()
		return
	if mode == Mode.NONE:
		return
	_t += delta
	match mode:
		Mode.IDLE:
			_idle()
		Mode.SWAY:
			_sway()
		Mode.BOW:
			_bow()
		Mode.NOD:
			_nod()
		Mode.WAVE:
			_wave()


## 呼吸：双臂自然下垂 + 胸口轻微起伏 + 头部微动
func _idle() -> void:
	var breath := sin(_t * TAU * 0.25)
	_relax_arms()
	_rot("Chest", Vector3.RIGHT, deg_to_rad(1.5) * breath)
	_rot("Head", Vector3.RIGHT, deg_to_rad(1.0) * sin(_t * TAU * 0.25 + 0.8))
	_bob("Hips", 0.005 * breath)


## 把 T-pose 双臂放下来（绕手臂骨骼局部 X 轴 = 摆臂，实测轴向）
func _relax_arms() -> void:
	_rot("RightUpperArm", Vector3.RIGHT, deg_to_rad(-60.0))
	_rot("LeftUpperArm", Vector3.RIGHT, deg_to_rad(-60.0))
	_rot("RightLowerArm", Vector3.RIGHT, deg_to_rad(-8.0))
	_rot("LeftLowerArm", Vector3.RIGHT, deg_to_rad(-8.0))


## 左右摇摆：胯和脊柱反向侧倾
func _sway() -> void:
	var s := sin(_t * TAU * 0.35)
	_relax_arms()
	_rot("Hips", Vector3.FORWARD, deg_to_rad(6.0) * s)
	_rot("Spine", Vector3.FORWARD, deg_to_rad(-3.0) * s)
	_rot("Head", Vector3.FORWARD, deg_to_rad(-2.0) * s)
	_bob("Hips", -0.01 * absf(s))


## 鞠躬：3 秒一个循环，弯下-保持-起身
func _bow() -> void:
	var phase := fmod(_t, 3.0) / 3.0
	var k := 0.0
	if phase < 0.3:
		k = smoothstep(0.0, 1.0, phase / 0.3)
	elif phase < 0.6:
		k = 1.0
	else:
		k = 1.0 - smoothstep(0.0, 1.0, (phase - 0.6) / 0.4)
	_relax_arms()
	_rot("Spine", Vector3.RIGHT, deg_to_rad(35.0) * k)
	_rot("Neck", Vector3.RIGHT, deg_to_rad(12.0) * k)


## 点头
func _nod() -> void:
	var k := (1.0 - cos(_t * TAU * 0.8)) * 0.5
	_relax_arms()
	_rot("Head", Vector3.RIGHT, deg_to_rad(22.0) * k)


## 挥手：右臂举起，前臂摆动
## （轴向经实测：VRoid 骨架上手臂骨骼绕父空间 X 轴 = 上下摆，Z 轴是自转）
func _wave() -> void:
	var raise := smoothstep(0.0, 1.0, minf(_t / 0.6, 1.0))
	_rot("LeftUpperArm", Vector3.RIGHT, deg_to_rad(-60.0))
	_rot("LeftLowerArm", Vector3.RIGHT, deg_to_rad(-8.0))
	_rot("RightUpperArm", Vector3.RIGHT, deg_to_rad(70.0) * raise - deg_to_rad(60.0) * (1.0 - raise))
	_rot("RightLowerArm", Vector3.RIGHT, deg_to_rad(15.0 * raise) + deg_to_rad(18.0) * sin(_t * TAU * 1.5) * raise)
	_rot("Head", Vector3.FORWARD, deg_to_rad(4.0) * sin(_t * TAU * 0.75))


## 绕父空间轴旋转（重定向后的骨架局部轴 ≈ 世界轴）
func _rot(bone_name: String, axis: Vector3, angle: float) -> void:
	if not _bones.has(bone_name):
		return
	var idx: int = _bones[bone_name]
	var offset := Quaternion(axis.normalized(), angle)
	skeleton.set_bone_pose_rotation(idx, offset * _rest_rot[idx])


func _bob(bone_name: String, dy: float) -> void:
	if not _bones.has(bone_name):
		return
	var idx: int = _bones[bone_name]
	skeleton.set_bone_pose_position(idx, _rest_pos[idx] + Vector3(0, dy, 0))
