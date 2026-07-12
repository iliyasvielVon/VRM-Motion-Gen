class_name Mocap
extends RefCounted
## 动补重定向：MediaPipe 关键点 → VRM 人形骨骼旋转 + VRoid 表情形变。
##
## 输入是 tools/mocap/capture.py 吐出来的一帧（已经转成 Godot 空间：Y 上、模型朝 +Z、
## 单位米、原点在胯心）。输出是 { "bones": {骨骼名: 局部四元数}, "shapes": {形变名: 0~1} }，
## 直接就是编辑器关键帧的格式。
##
## 重定向的做法：**不看关键点的绝对位置，只看方向**——这样捕来的人多高多胖都无所谓，
## 只要姿势对。两类骨骼：
##   · 方向骨（大臂/小臂/大腿/小腿/脚/手指…）：只知道「骨头该指哪」，用最短弧把骨头
##     从「父骨骼转过之后它本该在的朝向」扭到目标方向——和鼠标拖骨头是同一个公式。
##   · 定向骨（胯/上胸/头/手掌）：光有方向定不住绕自身轴的自转（胯朝上，但人可以左右
##     转身；手掌指向前，但可以翻掌）。这些骨用两个向量（主轴 + 侧轴）定出完整朝向，
##     参考轴直接从骨架静止姿态里量（左胯→右胯、左眼→右眼、食指根→小指根…），
##     所以不用手写任何「这个模型的手心朝哪」的魔法常数。
##
## 全程纯数学，不碰骨架（不 set_bone_pose_rotation），所以能脱离场景循环写断言。

# ---- MediaPipe pose 的 33 个关键点里我们用到的
const NOSE := 0
const EAR_L := 7
const EAR_R := 8
const SHOULDER_L := 11
const SHOULDER_R := 12
const ELBOW_L := 13
const ELBOW_R := 14
const WRIST_L := 15
const WRIST_R := 16
const HIP_L := 23
const HIP_R := 24
const KNEE_L := 25
const KNEE_R := 26
const ANKLE_L := 27
const ANKLE_R := 28
const FOOT_L := 31
const FOOT_R := 32

# ---- MediaPipe 手部的 21 个关键点：手腕 + 五指各四节
const HAND_WRIST := 0
const HAND_INDEX_MCP := 5
const HAND_MIDDLE_MCP := 9
const HAND_LITTLE_MCP := 17

## 手指骨 -> 它在手部关键点里的 (起点, 终点)
const FINGER_CHAIN := {
	"ThumbMetacarpal": [1, 2], "ThumbProximal": [2, 3], "ThumbDistal": [3, 4],
	"IndexProximal": [5, 6], "IndexIntermediate": [6, 7], "IndexDistal": [7, 8],
	"MiddleProximal": [9, 10], "MiddleIntermediate": [10, 11], "MiddleDistal": [11, 12],
	"RingProximal": [13, 14], "RingIntermediate": [14, 15], "RingDistal": [15, 16],
	"LittleProximal": [17, 18], "LittleIntermediate": [18, 19], "LittleDistal": [19, 20],
}

## VRoid 表情形变 <- MediaPipe(ARKit) blendshape 的加权和。
## 只驱动具体通道（EYE_/MTH_/BRW_），不碰 Fcl_ALL_*——那些是复合形变，
## 叠上来会和具体通道打架（嘴角被拉两次）。
const SHAPE_MAP := {
	"Fcl_EYE_Close_L": {"eyeBlinkLeft": 1.0},
	"Fcl_EYE_Close_R": {"eyeBlinkRight": 1.0},
	"Fcl_EYE_Surprised": {"eyeWideLeft": 0.5, "eyeWideRight": 0.5},
	"Fcl_MTH_A": {"jawOpen": 1.0},
	"Fcl_MTH_I": {"mouthStretchLeft": 0.5, "mouthStretchRight": 0.5},
	"Fcl_MTH_U": {"mouthPucker": 1.0},
	"Fcl_MTH_E": {"mouthPressLeft": 0.5, "mouthPressRight": 0.5},
	"Fcl_MTH_O": {"mouthFunnel": 1.0},
	"Fcl_MTH_Joy": {"mouthSmileLeft": 0.5, "mouthSmileRight": 0.5},
	"Fcl_MTH_Sorrow": {"mouthFrownLeft": 0.5, "mouthFrownRight": 0.5},
	"Fcl_BRW_Surprised": {"browInnerUp": 1.0},
	"Fcl_BRW_Angry": {"browDownLeft": 0.5, "browDownRight": 0.5},
	"Fcl_BRW_Fun": {"browOuterUpLeft": 0.5, "browOuterUpRight": 0.5},
}

var solver: PoseSolver     # 正向运动学 / 瞄准求解器（和全身 IK 共用同一套）
var skel: Skeleton3D
var _eye_l := -1
var _eye_r := -1


func setup(skeleton_node: Skeleton3D, pose_solver: PoseSolver = null) -> void:
	skel = skeleton_node
	solver = pose_solver
	if solver == null:
		solver = PoseSolver.new()
		solver.setup(skel)
	_eye_l = skel.find_bone("LeftEye")
	_eye_r = skel.find_bone("RightEye")


# ---------------------------------------------------------------- 重定向

## 一帧关键点 → {bones: {名:Quaternion}, shapes: {名:float}}；没认出人时返回空字典。
##
## prev = 上一帧的解算结果。这一帧**没测到**的部位（手常常丢、脸更常丢）会保持上一帧的
## 姿态，而不是弹回静止姿态——不这么做的话，手一丢帧十根手指就「啪」地摊回 T-pose，
## 实时预览里手指一直抽搐，而且这个每帧几十度的抖动会把抽稀彻底废掉（误差永远超阈值，
## 一帧都删不掉）。
func solve(frame: Dictionary, prev := {}) -> Dictionary:
	var t := targets(frame)
	if t.is_empty():
		return {}
	# 定向骨的目标是一对轴，先在这里算成「绝对朝向」再交给求解器——「这个模型的手心朝哪」
	# 是动补自己的知识（从骨架静止姿态量出来的），通用求解器不该知道
	var solver_targets := {}
	for bname in t:
		var v = t[bname]
		if v is Array:
			var refs := _rest_refs(bname)
			if refs.is_empty():
				continue
			var r = PoseSolver.align(refs[0], refs[1], v[0], v[1])
			if r != null:
				solver_targets[bname] = r
		else:
			solver_targets[bname] = v
	var bs = frame.get("bs")
	return {
		"bones": solver.solve(solver_targets, prev.get("bones", {})),
		"shapes": _shapes(bs) if bs != null else (prev.get("shapes", {}) as Dictionary).duplicate(),
	}


## 一帧关键点 → 每根骨骼的目标：Vector3 = 只给方向；Array[主轴, 侧轴] = 给完整朝向。
## （拆出来是为了能单独断言「重定向有没有把骨头精确扭到关键点指的方向」——那是本文件的
##   职责；关键点本身准不准是 MediaPipe 的事，两件事得分开量。）
func targets(frame: Dictionary) -> Dictionary:
	var pose = frame.get("pose")
	if pose == null or (pose as Array).size() < 33:
		return {}
	var p := _points(pose)

	var hip_mid := (p[HIP_L] + p[HIP_R]) * 0.5
	var sho_mid := (p[SHOULDER_L] + p[SHOULDER_R]) * 0.5
	var ear_mid := (p[EAR_L] + p[EAR_R]) * 0.5
	var spine_dir := sho_mid - hip_mid

	var out := {
		"Hips": [spine_dir, p[HIP_L] - p[HIP_R]],
		"Spine": spine_dir,
		"Chest": spine_dir,
		"UpperChest": [spine_dir, p[SHOULDER_L] - p[SHOULDER_R]],
		"Neck": ear_mid - sho_mid,
		"Head": [(p[NOSE] - ear_mid).cross(p[EAR_L] - p[EAR_R]), p[EAR_L] - p[EAR_R]],
		"LeftUpperArm": p[ELBOW_L] - p[SHOULDER_L],
		"LeftLowerArm": p[WRIST_L] - p[ELBOW_L],
		"RightUpperArm": p[ELBOW_R] - p[SHOULDER_R],
		"RightLowerArm": p[WRIST_R] - p[ELBOW_R],
		"LeftUpperLeg": p[KNEE_L] - p[HIP_L],
		"LeftLowerLeg": p[ANKLE_L] - p[KNEE_L],
		"LeftFoot": p[FOOT_L] - p[ANKLE_L],
		"RightUpperLeg": p[KNEE_R] - p[HIP_R],
		"RightLowerLeg": p[ANKLE_R] - p[KNEE_R],
		"RightFoot": p[FOOT_R] - p[ANKLE_R],
	}
	_add_hand(out, "Left", frame.get("lh"))
	_add_hand(out, "Right", frame.get("rh"))
	return out


## 定向骨在静止姿态下的 (主轴, 侧轴)——全部从骨架自己量，不写死任何模型相关常数
func _rest_refs(bname: String) -> Array:
	match bname:
		"Hips":
			return _refs(_up("Hips", "Spine"), _side("LeftUpperLeg", "RightUpperLeg"))
		"UpperChest":
			return _refs(_up("UpperChest", "Neck"), _side("LeftShoulder", "RightShoulder"))
		"Head":
			if _eye_l < 0 or _eye_r < 0:
				return []
			var eye_side: Vector3 = skel.get_bone_global_rest(_eye_l).origin \
				- skel.get_bone_global_rest(_eye_r).origin
			return _refs(solver.rest_basis("Head") * (solver.tips["Head"] as Vector3), eye_side)
		"LeftHand", "RightHand":
			var side := bname.trim_suffix("Hand")
			return _refs(_up(bname, side + "MiddleProximal"),
				_side(side + "IndexProximal", side + "LittleProximal"))
	return []


func _refs(a: Vector3, b: Vector3) -> Array:
	return [] if a.length() < 0.0001 or b.length() < 0.0001 else [a, b]


func _up(from_bone: String, to_bone: String) -> Vector3:
	if not solver.bones.has(from_bone) or not solver.bones.has(to_bone):
		return Vector3.ZERO
	return solver.rest_org(to_bone) - solver.rest_org(from_bone)


## 左边那根减右边那根 = 指向「人物自己的左手边」（MediaPipe 的左右也是人物视角，对得上）
func _side(left_bone: String, right_bone: String) -> Vector3:
	if not solver.bones.has(left_bone) or not solver.bones.has(right_bone):
		return Vector3.ZERO
	return solver.rest_org(left_bone) - solver.rest_org(right_bone)


func _add_hand(targets: Dictionary, side: String, hand) -> void:
	if hand == null or (hand as Array).size() < 21:
		return
	var h := _points(hand)
	targets[side + "Hand"] = [h[HAND_MIDDLE_MCP] - h[HAND_WRIST],
		h[HAND_INDEX_MCP] - h[HAND_LITTLE_MCP]]
	for seg in FINGER_CHAIN:
		var pair: Array = FINGER_CHAIN[seg]
		targets[side + seg] = h[pair[1]] - h[pair[0]]


static func _points(raw: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for v in raw:
		out.append(Vector3(v[0], v[1], v[2]))
	return out


## ARKit blendshape → VRoid Fcl_* 形变值
func _shapes(bs) -> Dictionary:
	var out := {}
	if bs == null:
		return out
	for vroid in SHAPE_MAP:
		var v := 0.0
		for arkit in SHAPE_MAP[vroid]:
			v += float(bs.get(arkit, 0.0)) * float(SHAPE_MAP[vroid][arkit])
		if v > 0.01:
			out[vroid] = clampf(v, 0.0, 1.0)
	return out


## 校验动补用的：方向骨绕自身轴的自转是动补测不出来的自由度，直接比四元数会把这个
## 自由度的差异也算进误差里，看着像大 bug 其实只是自转不同——比「骨头指向」才准。
func global_dirs(local_rots: Dictionary) -> Dictionary:
	return solver.global_dirs(local_rots)


# ---------------------------------------------------------------- 平滑

## 一阶低通：新值往旧值那边拉 amount（0 = 不平滑，0.8 = 很粘）。抖动全靠它压。
static func smooth(prev: Dictionary, cur: Dictionary, amount: float) -> Dictionary:
	if prev.is_empty() or amount <= 0.0:
		return cur
	var out := {"bones": {}, "shapes": {}}
	var pb: Dictionary = prev.get("bones", {})
	for b in cur["bones"]:
		var q: Quaternion = cur["bones"][b]
		out["bones"][b] = (pb[b] as Quaternion).slerp(q, 1.0 - amount) if pb.has(b) else q
	var ps: Dictionary = prev.get("shapes", {})
	for s in cur["shapes"]:
		var v: float = cur["shapes"][s]
		out["shapes"][s] = lerpf(ps[s], v, 1.0 - amount) if ps.has(s) else v
	return out
