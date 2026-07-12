extends SkeletonModifier3D
## 动作切换缓冲：切换瞬间 capture() 快照全骨架姿态，本修改器每帧把快照姿态
## 盖回骨架，靠 SkeletonModifier3D 自带的 influence 在「新动作姿态 ↔ 快照姿态」
## 之间插值；influence 由 MotionController 从 1 衰减到 0，实现交叉淡出。
## 修改器跑在 AnimationPlayer / 脚本写姿态之后，对两种动作源都有效。

var _rot := {}   # 骨骼索引 -> 快照旋转
var _pos := {}   # 骨骼索引 -> 快照位置


func capture() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_rot.clear()
	_pos.clear()
	for i in sk.get_bone_count():
		_rot[i] = sk.get_bone_pose_rotation(i)
		_pos[i] = sk.get_bone_pose_position(i)
	influence = 1.0
	active = true


func fade(delta: float, blend_time: float) -> void:
	if not active:
		return
	influence = maxf(influence - delta / blend_time, 0.0)
	if influence <= 0.0:
		active = false


func _process_modification_with_delta(_delta: float) -> void:
	_process_modification()


func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	for i in _rot:
		sk.set_bone_pose_rotation(i, _rot[i])
		sk.set_bone_pose_position(i, _pos[i])
