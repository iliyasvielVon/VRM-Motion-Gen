class_name ArmIK
extends RefCounted
## 手臂 two-bone IK（肩-肘-腕，余弦定理解析解，无迭代）。
## 关键决策：直接 set_bone_pose_rotation 写骨骼姿态，与 MotionController 的
## 程序化动作走同一条管线——衣柜跟随骨架（读 get_bone_global_pose 吸附）和
## PoseBlend 过渡天然兼容；且解算结果可读，能写数值断言（SkeletonModifier3D
## 的输出只进渲染管线读不到，所以不做成 modifier）。
## 骨骼索引由调用方用拓扑解析提供（骨骼名不可信）。

var skeleton: Skeleton3D
var upper := -1          # 大臂
var lower := -1          # 小臂
var hand := -1           # 手（可缺，缺了按大臂长估算小臂长）
var _upper_parent := -1
var _len_upper := 0.25
var _len_lower := 0.22
var _child_dir_upper := Vector3.RIGHT   # 静止姿态下大臂指向肘的方向（大臂局部）
var _child_dir_lower := Vector3.RIGHT   # 小臂指向腕的方向（小臂局部）


func setup(skel: Skeleton3D, upper_idx: int, lower_idx: int, hand_idx: int) -> bool:
	skeleton = skel
	upper = upper_idx
	lower = lower_idx
	hand = hand_idx
	if skeleton == null or upper < 0 or lower < 0:
		return false
	_upper_parent = skeleton.get_bone_parent(upper)
	var lower_rest: Vector3 = skeleton.get_bone_rest(lower).origin
	_len_upper = lower_rest.length()
	_child_dir_upper = lower_rest.normalized()
	if hand >= 0:
		var hand_rest: Vector3 = skeleton.get_bone_rest(hand).origin
		_len_lower = hand_rest.length()
		_child_dir_lower = hand_rest.normalized()
	else:
		_len_lower = _len_upper * 0.82
		_child_dir_lower = _child_dir_upper
	return true


func valid() -> bool:
	return skeleton != null and upper >= 0 and lower >= 0


func reach() -> float:
	return _len_upper + _len_lower


## 解算并写入大臂/小臂旋转。target = 腕目标点，pole = 肘尖大致朝向，均为骨架空间。
## 返回解算后的腕位置（骨架空间，超出臂展时贴在最大伸展处）。
func solve(target: Vector3, pole: Vector3) -> Vector3:
	if not valid():
		return target
	# 肩关节位置：父链含本帧已写入的躯干姿态（get_bone_global_pose 反映 set 过的姿态）
	var parent_g := Transform3D.IDENTITY
	if _upper_parent >= 0:
		parent_g = skeleton.get_bone_global_pose(_upper_parent)
	var upper_rest_g := parent_g * skeleton.get_bone_rest(upper)
	var a := upper_rest_g.origin
	var to_t := target - a
	var d := clampf(to_t.length(), 0.02, _len_upper + _len_lower - 0.005)
	var dir := to_t.normalized()
	if dir.length_squared() < 0.5:
		return a
	# 肘弯平面：正向旋转把大臂往 pole 一侧抬，肘尖落在 pole 方向
	var bend_axis := dir.cross(pole)
	if bend_axis.length() < 0.001:
		bend_axis = dir.cross(Vector3.UP)
		if bend_axis.length() < 0.001:
			bend_axis = Vector3.FORWARD
	bend_axis = bend_axis.normalized()
	# 余弦定理：肩角（大臂偏离肩-目标连线的角度）
	var cos_shoulder := clampf(
		(_len_upper * _len_upper + d * d - _len_lower * _len_lower) / (2.0 * _len_upper * d), -1.0, 1.0)
	var upper_dir := dir.rotated(bend_axis, acos(cos_shoulder))
	# 写大臂：把静止姿态的"指肘方向"扭到 upper_dir（最短弧）
	var w0 := (upper_rest_g.basis * _child_dir_upper).normalized()
	var upper_g_basis := Basis(Quaternion(w0, upper_dir)) * upper_rest_g.basis
	skeleton.set_bone_pose_rotation(upper,
		(parent_g.basis.inverse() * upper_g_basis).get_rotation_quaternion().normalized())
	# 写小臂：肘位置定了，前臂指向目标
	var elbow := a + upper_dir * _len_upper
	var forearm_dir := (target - elbow).normalized()
	var upper_g := skeleton.get_bone_global_pose(upper)
	var lower_rest_g := upper_g * skeleton.get_bone_rest(lower)
	var w1 := (lower_rest_g.basis * _child_dir_lower).normalized()
	var lower_g_basis := Basis(Quaternion(w1, forearm_dir)) * lower_rest_g.basis
	skeleton.set_bone_pose_rotation(lower,
		(upper_g.basis.inverse() * lower_g_basis).get_rotation_quaternion().normalized())
	return elbow + forearm_dir * _len_lower
