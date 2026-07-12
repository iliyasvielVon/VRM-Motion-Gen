class_name PoseSolver
extends RefCounted
## 人形骨架的正向运动学 / 瞄准求解器：给每根骨骼一个「目标」，算出全身的局部旋转。
## 动补重定向（mocap.gd）和全身 IK（body_ik.gd）都建在它上面——两边要解的东西不一样，
## 但「父在前子在后地推下去、把骨头最短弧扭到目标」这件事是同一件。
##
## 目标有三种写法：
##   Vector3                  —— 只给方向：把骨头（默认是「关节 → 骨头尖」那根轴）扭过去。
##   Array[主轴, 侧轴]         —— 给完整朝向：光有方向定不住绕自身轴的自转（手掌指向前，
##                               但可以翻掌），这种骨用两个向量定死。
##   refs[骨骼名] = Vector3    —— 换掉「骨头的参考轴」：全身 IK 的链会经过 UpperChest 这种
##                               骨头——它自己的骨头尖指向脖子，但链是往肩膀拐的，
##                               这时参考轴要换成「本骨骼 → 链上下一个关节」。
##
## 纯数学，不碰骨架（不 set_bone_pose_rotation），所以能脱离场景循环写断言。
##
## 前提：人形骨骼的父骨骼就是它在骨架里的直接父骨骼（avatar0 上成立，
## tools/test_studio.gd 里有断言）。中间隔着非人形骨的骨架要另说。

var skel: Skeleton3D
var bones := {}                  # 骨骼名 -> 索引
var tips := {}                   # 骨骼名 -> 骨头尖（本骨骼局部空间，指向子关节）
var parents := {}                # 骨骼名 -> 人形父骨名（根是空串）
var order: Array[String] = []    # 骨骼名，父在前子在后

var _rest_basis := {}            # 骨骼名 -> 静止姿态的全局朝向（骨架空间）
var _rest_org := {}              # 骨骼名 -> 静止姿态的全局位置（骨架空间）
var _rest_local := {}            # 骨骼名 -> 静止姿态的局部朝向（相对父骨骼）
var _rest_off := {}              # 骨骼名 -> 静止姿态的局部位置（相对父骨骼）
var _root_xform := {}            # 人形根骨（Hips）之上那些不动的骨骼的全局静止变换


func setup(skeleton_node: Skeleton3D) -> void:
	skel = skeleton_node
	bones = HumanoidBones.resolve_all(skel)
	parents = HumanoidBones.humanoid_parents(skel, bones)
	tips = HumanoidBones.bone_tips(skel, bones, parents)
	order.clear()
	for bname in HumanoidBones.humanoid_names():
		if not bones.has(bname):
			continue
		order.append(bname)
		var idx: int = bones[bname]
		var gr := skel.get_bone_global_rest(idx)
		_rest_basis[bname] = gr.basis.orthonormalized()
		_rest_org[bname] = gr.origin
		_rest_local[bname] = skel.get_bone_rest(idx).basis.orthonormalized()
		_rest_off[bname] = skel.get_bone_rest(idx).origin
		if parents[bname] == "":
			var p: int = skel.get_bone_parent(idx)
			_root_xform[bname] = skel.get_bone_global_rest(p) if p >= 0 else Transform3D.IDENTITY


func rest_basis(bname: String) -> Basis:
	return _rest_basis[bname]


func rest_org(bname: String) -> Vector3:
	return _rest_org[bname]


## 人形根骨之上那截不动骨骼的朝向：把骨架空间的平移换算成胯的父空间平移要用它
func root_basis(bname: String) -> Basis:
	return (_root_xform[bname] as Transform3D).basis.orthonormalized()


## 胯的静止局部位置（烘焙 position_3d 轨道时要写绝对值，不是偏移量）
func rest_local_origin(bname: String) -> Vector3:
	return _rest_off[bname]


## 本骨骼局部空间里，从本骨骼关节指向 to_bone 关节的向量（to_bone 得是本骨骼的后代）。
## 全身 IK 用它当参考轴——链未必顺着骨头尖走。
func local_offset_to(bname: String, to_bone: String) -> Vector3:
	return (_rest_basis[bname] as Basis).inverse() \
		* ((_rest_org[to_bone] as Vector3) - (_rest_org[bname] as Vector3))


# ---------------------------------------------------------------- 求解

## 目标 → 全身局部旋转。
##   targets[骨骼名] = Vector3 —— 方向：把骨头（参考轴，默认骨头尖）最短弧扭过去。
##   targets[骨骼名] = Basis   —— 绝对朝向：这根骨头的全局朝向 = 这个旋转 × 静止全局朝向。
##                               （怎么算出这个旋转是调用方的事：动补拿关键点量，
##                                 各家骨架的「手心朝哪」不一样，通用求解器不该知道。）
## hold = 没有目标的骨骼保持哪个局部旋转（不给就回静止姿态）。
## refs = 换掉某根骨骼的参考轴（默认用骨头尖）。
func solve(targets: Dictionary, hold := {}, refs := {}) -> Dictionary:
	var out := {}
	var g := {}                              # 骨骼名 -> 解算后的全局朝向（骨架空间）
	for bname in order:
		var parent_g := _parent_basis(bname, g)
		var t = targets.get(bname)
		var gb: Basis
		if t is Vector3 and (t as Vector3).length() > 0.001:
			gb = parent_g * (_rest_local[bname] as Basis)
			var ref: Vector3 = refs.get(bname, tips[bname])
			var cur := (gb * ref).normalized()
			gb = Basis(Quaternion(cur, (t as Vector3).normalized())) * gb
		elif t is Basis:
			gb = (t as Basis) * (_rest_basis[bname] as Basis)
		elif hold.has(bname):
			gb = parent_g * Basis(hold[bname] as Quaternion)
		else:
			gb = parent_g * (_rest_local[bname] as Basis)
		g[bname] = gb
		out[bname] = (parent_g.inverse() * gb).get_rotation_quaternion().normalized()
	return out


## 用主轴 + 侧轴搭一组正交基（主轴当 Y，侧轴正交化后当 X，Z = X×Y）。
## 「把静止姿态量出来的一对轴，旋到目标的一对轴」= frame(目标) × frame(静止)⁻¹，
## 正交基的逆就是转置。动补的定向骨、以后别的什么，都能拿它算绝对朝向。
static func align(main_rest: Vector3, side_rest: Vector3, main_target: Vector3,
		side_target: Vector3):
	var f0 = frame(main_rest, side_rest)
	var f1 = frame(main_target, side_target)
	if f0 == null or f1 == null:
		return null
	return (f1 as Basis) * (f0 as Basis).transposed()


static func frame(main_axis: Vector3, side_axis: Vector3):
	if main_axis.length() < 0.001 or side_axis.length() < 0.001:
		return null
	var y := main_axis.normalized()
	var x := side_axis - y * side_axis.dot(y)
	if x.length() < 0.0001:
		return null       # 两根轴共线，定不出朝向
	x = x.normalized()
	return Basis(x, y, x.cross(y))


## 一组局部旋转 → 每根骨骼在骨架空间的完整变换（含关节位置）。
## root_offset = 人形根骨（Hips）的额外平移，全身 IK 拽着身体挪重心时用。
func global_pose(local_rots := {}, root_offset := Vector3.ZERO) -> Dictionary:
	var g := {}
	for bname in order:
		var pname: String = parents[bname]
		var local := Basis(local_rots[bname] as Quaternion) if local_rots.has(bname) \
			else (_rest_local[bname] as Basis)
		var off: Vector3 = _rest_off[bname]
		var xf := Transform3D(local, off)
		if pname == "":
			g[bname] = (_root_xform[bname] as Transform3D) * Transform3D(local, off + root_offset)
		else:
			g[bname] = (g[pname] as Transform3D) * xf
	return g


## 一组局部旋转 → 每根骨头在骨架空间里指向哪（校验动补/IK 用：绕自身轴的自转是测不出来
## 的自由度，直接比四元数会把好结果冤枉成 100°+，要比骨头指向）
func global_dirs(local_rots: Dictionary) -> Dictionary:
	var out := {}
	var g := global_pose(local_rots)
	for bname in order:
		out[bname] = ((g[bname] as Transform3D).basis * (tips[bname] as Vector3)).normalized()
	return out


func _parent_basis(bname: String, g: Dictionary) -> Basis:
	var pname: String = parents[bname]
	if pname == "":
		return (_root_xform[bname] as Transform3D).basis.orthonormalized()
	return g.get(pname, Basis.IDENTITY)
