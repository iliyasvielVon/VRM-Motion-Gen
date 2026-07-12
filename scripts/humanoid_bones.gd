class_name HumanoidBones
extends RefCounted
## 按骨架拓扑解析人形骨骼索引，不依赖骨骼名。
## （godot-vrm 在部分 Godot 版本上重定向改名会错位——名字不可信，
##   但层级和静止姿态是自洽的，所以用结构特征找骨骼：
##   Hips = 挂着两条腿和一条脊柱的分叉点；沿脊柱上行到肩部分叉，
##   横向展开的长链是手臂（T-pose 时手在 |x|>0.3m），居中向上的是脖子。）
##
## resolve_all() 是编辑器用的全身版：VRM 人形标准名优先（avatar0 上 180 根骨里
## 52 根是人形骨，其余是裙摆/头发/胸部的 SpringBone 摇物骨——摇物骨不进编辑器，
## 交给物理），名字对不上时核心 12 根回退到上面的拓扑解析。


## 一根手指的三节（拇指的第一节叫 Metacarpal，其余叫 Proximal）
const FINGERS := ["Thumb", "Index", "Middle", "Ring", "Little"]

## 头骨没有人形子骨骼（眼球不进编辑器），给个像样的显示长度，别的骨骼算得出来
const TIP_OVERRIDE := {"Head": Vector3(0, 0.13, 0)}


## 编辑器可摆的人形骨骼名，父在前子在后（骨骼树按这个顺序直接建得起来）
static func humanoid_names() -> Array[String]:
	var out: Array[String] = ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"]
	for side in ["Left", "Right"]:
		out.append_array([side + "Shoulder", side + "UpperArm", side + "LowerArm", side + "Hand"])
		for finger in FINGERS:
			var segs := ["Metacarpal", "Proximal", "Distal"] if finger == "Thumb" \
				else ["Proximal", "Intermediate", "Distal"]
			for seg in segs:
				out.append(side + finger + seg)
	for side in ["Left", "Right"]:
		out.append_array([side + "UpperLeg", side + "LowerLeg", side + "Foot", side + "Toes"])
	return out


## 全身人形骨骼 名字 -> 骨骼索引（骨架上没有的骨骼不出现在结果里）
static func resolve_all(skel: Skeleton3D) -> Dictionary:
	if skel == null:
		return {}
	var topo := resolve(skel)   # 核心 12 根的拓扑兜底
	var out := {}
	for bname in humanoid_names():
		var idx := skel.find_bone(bname)
		if idx < 0:
			idx = topo.get(bname, -1)
		if idx >= 0:
			out[bname] = idx
	return out


## 每根骨骼在人形骨骼集合里的父骨骼名（沿骨架父链上行找最近的人形骨；根返回空串）
static func humanoid_parents(skel: Skeleton3D, bones: Dictionary) -> Dictionary:
	var idx2name := {}
	for bname in bones:
		idx2name[bones[bname]] = bname
	var out := {}
	for bname in bones:
		var p: int = skel.get_bone_parent(bones[bname])
		while p >= 0 and not idx2name.has(p):
			p = skel.get_bone_parent(p)
		out[bname] = idx2name.get(p, "")
	return out


## 每根骨骼的「骨头尖」：本骨骼局部空间里指向子骨骼关节的向量。
## 直接取子骨骼的 rest 偏移（rest.origin 就是相对父骨骼的），不去假设「局部 +Y 就是
## 骨头方向」——那个假设在小腿→脚上差 2.5cm（脚往前挪了一截），骨头会画歪、
## 拖拽瞄准也会偏。骨骼有多个人形子骨骼时（Hips 挂着脊柱和两条腿）只认 +Y 那侧
## 最长的（脊柱），末端骨骼（指尖/脚趾/头）没有子骨骼，按父骨骼长度打折沿 +Y 伸出去。
static func bone_tips(skel: Skeleton3D, bones: Dictionary, parents: Dictionary) -> Dictionary:
	var children := {}
	for bname in bones:
		children[bname] = []
	for bname in bones:
		var p: String = parents[bname]
		if p != "":
			(children[p] as Array).append(bname)
	var out := {}
	for bname in humanoid_names():   # 父在前子在后：算末端骨骼时父骨骼长度已经有了
		if not bones.has(bname):
			continue
		var best := Vector3.ZERO
		for c in children[bname]:
			if skel.get_bone_parent(bones[c]) != bones[bname]:
				continue   # 中间隔着非人形骨，这个子骨骼的 rest 不是相对本骨骼的
			var off: Vector3 = skel.get_bone_rest(bones[c]).origin
			if off.y > 0.005 and off.length() > best.length():
				best = off
		if best == Vector3.ZERO:
			var plen: float = (out.get(parents.get(bname, ""), Vector3(0, 0.05, 0)) as Vector3).length()
			best = Vector3(0, maxf(0.6 * plen, 0.02), 0)
		out[bname] = TIP_OVERRIDE.get(bname, best)
	return out


## 返回 {"Hips": int, "Spine", "Chest", "UpperChest", "Neck", "Head",
##  "LeftShoulder", "LeftUpperArm", "LeftLowerArm",
##  "RightShoulder", "RightUpperArm", "RightLowerArm"}，解析失败的键不出现。
static func resolve(skel: Skeleton3D) -> Dictionary:
	var result := {}
	var n := skel.get_bone_count()
	if n == 0:
		return result

	# 每根骨骼在骨架空间的静止位置（广度优先，从根往下，不假设索引顺序）
	var global_rest: Array[Transform3D] = []
	global_rest.resize(n)
	var frontier := skel.get_parentless_bones()
	for b in frontier:
		global_rest[b] = skel.get_bone_rest(b)
	var qi := 0
	var queue := PackedInt32Array(frontier)
	while qi < queue.size():
		var b := queue[qi]
		qi += 1
		for c in skel.get_bone_children(b):
			global_rest[c] = global_rest[b] * skel.get_bone_rest(c)
			queue.append(c)

	# 子树统计：最大 |x|、最大 y、节点数
	var kids := []
	kids.resize(n)
	for i in range(n):
		kids[i] = skel.get_bone_children(i)

	# ---- 找 Hips：有 >=2 个"往下"的子树（腿）和 >=1 个"往上"的子树（脊柱）
	var hips := -1
	for i in range(n):
		if (kids[i] as PackedInt32Array).size() < 3:
			continue
		var down := 0
		var up := 0
		for c in kids[i]:
			var dy: float = global_rest[c].origin.y - global_rest[i].origin.y
			if dy < -0.02 and _subtree_depth(skel, c) >= 2:
				down += 1
			elif dy > 0.02:
				up += 1
		if down >= 2 and up >= 1:
			hips = i
			break
	if hips < 0:
		return result
	result["Hips"] = hips

	# ---- 沿脊柱上行，直到出现手臂分叉（两个横向展开的长子树）
	var spine_start := -1
	for c in kids[hips]:
		if global_rest[c].origin.y > global_rest[hips].origin.y + 0.02:
			spine_start = c
			break
	if spine_start < 0:
		return result

	var chain: Array[int] = []
	var cur := spine_start
	var split := -1
	while cur >= 0 and chain.size() < 10:
		chain.append(cur)
		var arm_children: Array[int] = []
		var up_child := -1
		var up_child_reach := 0.0
		for c in kids[cur]:
			var reach := _subtree_max_abs_x(skel, global_rest, c)
			var depth := _subtree_depth(skel, c)
			# 手臂候选：子树横向伸展 + 链够深 + 骨骼本身偏离中线（排除脖子——头发子树也可能很宽）
			if reach > 0.25 and depth >= 3 and absf(global_rest[c].origin.x) > 0.01:
				arm_children.append(c)
			# 无论是否像手臂，都记录"最高子树"备选：
			# 单独一个包含整条手臂的躯干子骨骼（如 Spine→Chest）不是分叉，要继续上行
			var top := _subtree_max_y(skel, global_rest, c)
			if up_child < 0 or top > up_child_reach:
				up_child = c
				up_child_reach = top
		if arm_children.size() >= 2:
			# 分叉点的"向上"子骨骼要排除手臂本身，重新在非手臂子骨骼里挑最高的
			up_child = -1
			up_child_reach = 0.0
			for c in kids[cur]:
				if arm_children.has(c):
					continue
				var top2 := _subtree_max_y(skel, global_rest, c)
				if up_child < 0 or top2 > up_child_reach:
					up_child = c
					up_child_reach = top2
		if arm_children.size() >= 2:
			split = cur
			# ---- 手臂：按静止位 x 分左右
			for a in arm_children:
				var side := "Left" if global_rest[a].origin.x > 0.0 else "Right"
				var shoulder := a
				var upper := _widest_child(skel, global_rest, kids, shoulder)
				var lower := _widest_child(skel, global_rest, kids, upper) if upper >= 0 else -1
				result[side + "Shoulder"] = shoulder
				if upper >= 0:
					result[side + "UpperArm"] = upper
				if lower >= 0:
					result[side + "LowerArm"] = lower
			# ---- 脖子和头：居中、最高的子树
			if up_child >= 0:
				result["Neck"] = up_child
				var head := _widest_child(skel, global_rest, kids, up_child)
				result["Head"] = head if head >= 0 else up_child
			break
		cur = up_child

	if split >= 0:
		result["UpperChest"] = split
		result["Spine"] = chain[0]
		result["Chest"] = chain[chain.size() - 2] if chain.size() >= 2 else split
	return result


static func _subtree_depth(skel: Skeleton3D, bone: int) -> int:
	var depth := 0
	var frontier := PackedInt32Array([bone])
	while frontier.size() > 0 and depth < 32:
		var next := PackedInt32Array()
		for b in frontier:
			next.append_array(skel.get_bone_children(b))
		frontier = next
		if frontier.size() > 0:
			depth += 1
	return depth


static func _subtree_max_abs_x(skel: Skeleton3D, global_rest: Array[Transform3D], bone: int) -> float:
	var m := absf(global_rest[bone].origin.x)
	for c in skel.get_bone_children(bone):
		m = maxf(m, _subtree_max_abs_x(skel, global_rest, c))
	return m


static func _subtree_max_y(skel: Skeleton3D, global_rest: Array[Transform3D], bone: int) -> float:
	var m := global_rest[bone].origin.y
	for c in skel.get_bone_children(bone):
		m = maxf(m, _subtree_max_y(skel, global_rest, c))
	return m


## 子骨骼里"伸得最远"（子树 |x| 最大）的那个——用来沿手臂链前进
static func _widest_child(skel: Skeleton3D, global_rest: Array[Transform3D], kids: Array, bone: int) -> int:
	var best := -1
	var best_reach := -1.0
	for c in kids[bone]:
		var reach := _subtree_max_abs_x(skel, global_rest, c) + _subtree_max_y(skel, global_rest, c)
		if reach > best_reach:
			best_reach = reach
			best = c
	return best
