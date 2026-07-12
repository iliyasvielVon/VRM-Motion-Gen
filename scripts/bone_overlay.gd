class_name BoneOverlay
extends MeshInstance3D
## 骨骼可视化 + 鼠标拾取：把人形骨骼画成穿透模型可见的八面体线框，选中的骨骼
## 额外画三个旋转环（红=父空间X 绿=Y 蓝=Z）。
##
## 关键决策：拾取全在屏幕空间做——把骨段/圆环投影成 2D 折线，算鼠标到折线的
## 像素距离取最近的。不用 Area3D + 物理射线，因为骨骼每帧都在动，同步 180 个
## 碰撞体的代价和坑都比投影几十条线段大；而且屏幕空间的「够不够近」正好就是
## 用户眼里的「点没点中」，手指那种细骨也点得着。
##
## 本节点挂在 Skeleton3D 下且不带 skin，顶点直接用骨架空间坐标
## （get_bone_global_pose 给的就是骨架空间）。

const PICK_PX := 14.0            # 拾取判定半径（像素）
const RING_SEGS := 48
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS := [Color(0.95, 0.32, 0.32), Color(0.42, 0.9, 0.42), Color(0.42, 0.62, 0.98)]

const COL_BONE := Color(0.55, 0.78, 0.95)      # 冷蓝：亮色模型上比金色显眼
const COL_HOVER := Color(1.0, 0.95, 0.75)
const COL_SEL := Color(1.0, 0.72, 0.16)
const FILL_ALPHA := {"bone": 0.22, "hover": 0.45, "sel": 0.62}

var skel: Skeleton3D
var camera: Camera3D
var bones := {}                  # 名字 -> 骨骼索引
var order: Array[String] = []    # 名字，父在前子在后
var tips := {}                   # 名字 -> 骨头尖（骨骼局部空间的向量，指向子关节）
var parents := {}                # 名字 -> 父骨骼名（人形集合内）

var selected := ""
var hovered := ""
var rings_visible := true

var _im: ImmediateMesh


func setup(skeleton_node: Skeleton3D, cam: Camera3D) -> void:
	skel = skeleton_node
	camera = cam
	bones = HumanoidBones.resolve_all(skel)
	parents = HumanoidBones.humanoid_parents(skel, bones)
	tips = HumanoidBones.bone_tips(skel, bones, parents)
	order.clear()
	for bname in HumanoidBones.humanoid_names():
		if bones.has(bname):
			order.append(bname)
	_im = ImmediateMesh.new()
	mesh = _im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true            # 骨骼藏在网格里也要看得见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 10
	material_override = mat
	sorting_offset = 100.0


## 选中骨骼的旋转环半径：细骨（手指）给小环，粗骨给大环，都控制在能抓得住的范围
func ring_radius(bname: String) -> float:
	return clampf(bone_len(bname) * 1.6, 0.05, 0.12)


func bone_len(bname: String) -> float:
	return (tips.get(bname, Vector3(0, 0.08, 0)) as Vector3).length()


## 骨骼在骨架空间的起点（关节位置）
func joint(bname: String) -> Vector3:
	return skel.get_bone_global_pose(bones[bname]).origin


## 骨骼在骨架空间的末端（子关节所在处）
func tip(bname: String) -> Vector3:
	return skel.get_bone_global_pose(bones[bname]) * (tips[bname] as Vector3)


## 骨头朝向（骨架空间的单位向量：从关节指向骨头尖）—— 拖拽瞄准要把它扭到光标上
func bone_dir(bname: String) -> Vector3:
	return (skel.get_bone_global_pose(bones[bname]).basis * (tips[bname] as Vector3)).normalized()


## 父空间三轴在骨架空间的朝向（旋转环的轴 / 滑条的轴，与骨骼姿态四元数同一套基）
func parent_basis(bname: String) -> Basis:
	var p: int = skel.get_bone_parent(bones[bname])
	if p < 0:
		return Basis.IDENTITY
	return skel.get_bone_global_pose(p).basis.orthonormalized()


# ---------------------------------------------------------------- 绘制

func redraw() -> void:
	if _im == null or skel == null:
		return
	_im.clear_surfaces()
	# 半透明实心骨头（穿透模型可见）打底，再描一遍不透明的边——只画线的话
	# 1px 细线在亮色模型上几乎看不见，点都没法点
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for bname in order:
		var shape := _octahedron(bname)
		if not shape.is_empty():
			_fill(shape, Color(_color_of(bname), _alpha_of(bname)))
	_im.surface_end()
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for bname in order:
		var shape := _octahedron(bname)
		if not shape.is_empty():
			_edges(shape, _color_of(bname))
	if rings_visible and selected != "" and bones.has(selected):
		_rings(selected)
	_im.surface_end()


func _color_of(bname: String) -> Color:
	if bname == selected:
		return COL_SEL
	return COL_HOVER if bname == hovered else COL_BONE


func _alpha_of(bname: String) -> float:
	if bname == selected:
		return FILL_ALPHA["sel"]
	return FILL_ALPHA["hover"] if bname == hovered else FILL_ALPHA["bone"]


## Blender 式八面体骨头的六个顶点：[关节, 四个环点…, 骨头尖]
func _octahedron(bname: String) -> Array[Vector3]:
	var o := joint(bname)
	var tip_p := tip(bname)
	var dir := tip_p - o
	var l := dir.length()
	if l < 0.0001:
		return []
	dir /= l
	# 骨头截面的两根横轴：随便取一根与骨向不平行的向量叉出来即可（只用于画外形）
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.01:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := dir.cross(side).normalized()
	var r := l * 0.14
	var out: Array[Vector3] = [o]
	for i in 4:
		var a := i * PI * 0.5
		out.append(o + dir * (l * 0.18) + side * (cos(a) * r) + up * (sin(a) * r))
	out.append(tip_p)
	return out


func _fill(v: Array[Vector3], col: Color) -> void:
	for i in 4:
		var a: Vector3 = v[1 + i]
		var b: Vector3 = v[1 + (i + 1) % 4]
		_tri(v[0], a, b, col)     # 关节那头的四个面
		_tri(v[5], b, a, col)     # 骨头尖那头的四个面


func _edges(v: Array[Vector3], col: Color) -> void:
	for i in 4:
		_line(v[0], v[1 + i], col)
		_line(v[1 + i], v[5], col)
		_line(v[1 + i], v[1 + (i + 1) % 4], col)


func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	for p in [a, b, c]:
		_im.surface_set_color(col)
		_im.surface_add_vertex(p)


func _rings(bname: String) -> void:
	var c := joint(bname)
	var pb := parent_basis(bname)
	var r := ring_radius(bname)
	for a in 3:
		var axis: Vector3 = (pb * AXES[a]).normalized()
		var u := axis.cross(Vector3.UP)
		if u.length() < 0.01:
			u = axis.cross(Vector3.RIGHT)
		u = u.normalized()
		var v := axis.cross(u).normalized()
		var prev := c + u * r
		for i in range(1, RING_SEGS + 1):
			var t := float(i) / RING_SEGS * TAU
			var p := c + (u * cos(t) + v * sin(t)) * r
			_line(prev, p, AXIS_COLORS[a])
			prev = p


func _line(a: Vector3, b: Vector3, col: Color) -> void:
	_im.surface_set_color(col)
	_im.surface_add_vertex(a)
	_im.surface_set_color(col)
	_im.surface_add_vertex(b)


# ---------------------------------------------------------------- 拾取（屏幕空间）

## 鼠标下最近的骨骼名（够不着返回空串）
func pick_bone(mouse: Vector2) -> String:
	if skel == null or camera == null:
		return ""
	var xform := skel.global_transform
	var best := ""
	var best_d := PICK_PX
	for bname in order:
		var a = _to_screen(xform * joint(bname))
		var b = _to_screen(xform * tip(bname))
		if a == null or b == null:
			continue
		var d := _dist_to_seg(mouse, a, b)
		if d < best_d:
			best_d = d
			best = bname
	return best


## 鼠标下的旋转环轴（0=X 1=Y 2=Z，够不着返回 -1）
func pick_ring(mouse: Vector2) -> int:
	if selected == "" or not bones.has(selected) or not rings_visible:
		return -1
	var xform := skel.global_transform
	var c := joint(selected)
	var pb := parent_basis(selected)
	var r := ring_radius(selected)
	var best := -1
	var best_d := PICK_PX
	for a in 3:
		var axis: Vector3 = (pb * AXES[a]).normalized()
		var u := axis.cross(Vector3.UP)
		if u.length() < 0.01:
			u = axis.cross(Vector3.RIGHT)
		u = u.normalized()
		var v := axis.cross(u).normalized()
		var prev = _to_screen(xform * (c + u * r))
		for i in range(1, RING_SEGS + 1):
			var t := float(i) / RING_SEGS * TAU
			var p = _to_screen(xform * (c + (u * cos(t) + v * sin(t)) * r))
			if prev != null and p != null:
				var d := _dist_to_seg(mouse, prev, p)
				if d < best_d:
					best_d = d
					best = a
			prev = p
	return best


## 世界点 → 屏幕点（在相机背后返回 null）
func _to_screen(world: Vector3):
	if camera.is_position_behind(world):
		return null
	return camera.unproject_position(world)


static func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
