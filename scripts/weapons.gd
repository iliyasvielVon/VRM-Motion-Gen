class_name Weapons
extends RefCounted
## 荣耀武器库：参考原作六大职业系 + 散人的代表性武器类型，纯几何体构建。
## 约定：握把在原点，武器主轴朝 +Z（equip 时旋转对齐到手骨的手指方向）。

const LIST := [
	{"name": "千机伞", "cls": "散人", "icon": "伞", "dual": false, "anim": "polearm",
		"desc": "形态万千的自制银武。据说它的原主人拿过三届总冠军。"},
	{"name": "战矛", "cls": "法师系 · 战斗法师", "icon": "矛", "dual": false, "anim": "polearm",
		"desc": "「一枪穿云」。战斗法师的专属长兵。"},
	{"name": "巨剑", "cls": "剑士系 · 狂剑士", "icon": "剑", "dual": false, "anim": "greatsword",
		"desc": "沉重的两手巨剑，力量的化身。"},
	{"name": "太刀", "cls": "剑士系 · 剑客", "icon": "刀", "dual": false, "anim": "sword",
		"desc": "轻灵的长刀，讲究一击必杀的居合。"},
	{"name": "银光火枪", "cls": "枪手系 · 神枪手", "icon": "枪", "dual": false, "anim": "rifle",
		"desc": "百步穿杨的长火枪，枪手系的浪漫。"},
	{"name": "拳套", "cls": "格斗系 · 拳法家", "icon": "拳", "dual": true, "anim": "fist",
		"desc": "近身格斗的强化拳套，双手佩戴。"},
	{"name": "元素法杖", "cls": "法师系 · 元素法师", "icon": "杖", "dual": false, "anim": "staff",
		"desc": "顶端凝聚着元素结晶的法杖。"},
	{"name": "圣十字权杖", "cls": "圣职系 · 牧师", "icon": "十", "dual": false, "anim": "staff",
		"desc": "祝福与治愈的圣职象征。"},
	{"name": "影匕", "cls": "暗夜系 · 刺客", "icon": "匕", "dual": true, "anim": "sword",
		"desc": "淬毒的双匕，夜色中的獠牙。"},
]

## 兜底的通用移动剪辑（sets 里没配时）
const FALLBACK_MOVE := "res://animations/mixamo/Treadmill Running.fbx"


## 武器名 -> 动作集目录名（徒手/未知武器用 default）
static func anim_set(weapon_name: String) -> String:
	var def := find_def(weapon_name)
	return str(def.get("anim", "default")) if not def.is_empty() else "default"


## 解析动作剪辑路径：武器集 -> default 集 -> 走跑兜底通用剪辑；找不到返回空串
static func anim_clip(set_name: String, action: String) -> String:
	for candidate in ["res://animations/sets/%s/%s.fbx" % [set_name, action],
			"res://animations/sets/default/%s.fbx" % action]:
		if ResourceLoader.exists(candidate):
			return candidate
	if action in ["walk", "run"]:
		return FALLBACK_MOVE
	return ""


static func find_def(weapon_name: String) -> Dictionary:
	for def in LIST:
		if def["name"] == weapon_name:
			return def
	return {}


## 装备到骨架手部（双持武器两只手都挂），返回创建的挂点
static func equip(skel: Skeleton3D, weapon_name: String) -> void:
	unequip(skel)
	var def := find_def(weapon_name)
	if def.is_empty() or skel == null:
		return
	var sides: Array = ["RightHand", "LeftHand"] if def["dual"] else ["RightHand"]
	for side in sides:
		if skel.find_bone(side) < 0:
			continue
		var att := BoneAttachment3D.new()
		att.set_meta("glory_weapon", true)
		skel.add_child(att)
		att.bone_name = side
		var w := build(weapon_name)
		# +Z 转到手骨 +X（垂直穿过握拳的方向）：武器从拳中向前伸出，经典持械姿态。
		# 左手骨骼轴向天然镜像，同一旋转在两只手上都指向身前。
		w.rotation_degrees = Vector3(0, 90, 0)
		w.position = Vector3(0, 0.05, 0.0)
		att.add_child(w)


static func unequip(skel: Skeleton3D) -> void:
	if skel == null:
		return
	# 用 meta 标记查找（queue_free 帧末才释放，按名字找会因同帧重名失效）
	for child in skel.get_children():
		if child is BoneAttachment3D and child.has_meta("glory_weapon"):
			child.queue_free()


# ---------------------------------------------------------------- 构建

const MODEL_DIR := "res://models/weapons"
## 各武器的标准全长（米），自定义模型自动缩放到这个尺寸
const TARGET_LEN := {"千机伞": 1.15, "战矛": 1.9, "巨剑": 1.35, "太刀": 1.1,
	"银光火枪": 1.05, "拳套": 0.28, "元素法杖": 1.3, "圣十字权杖": 1.25, "影匕": 0.55}


static func build(weapon_name: String) -> Node3D:
	# 优先用玩家放进 models/weapons/ 的自定义模型（自动缩放/对轴/定握点）
	var custom := _load_custom(weapon_name)
	if custom != null:
		return custom
	var root := Node3D.new()
	root.name = "Weapon"
	match weapon_name:
		"千机伞":
			_umbrella(root)
		"战矛":
			_spear(root)
		"巨剑":
			_greatsword(root)
		"太刀":
			_katana(root)
		"银光火枪":
			_rifle(root)
		"拳套":
			_gauntlet(root)
		"元素法杖":
			_staff(root)
		"圣十字权杖":
			_cross(root)
		"影匕":
			_dagger(root)
	return root


## 加载自定义武器模型并自动适配：
## 最长轴 → +Z（武器主轴约定）、缩放到标准全长、握点定在全长 18% 处；
## 存在同名 .flip 空文件时翻转 180°（处理"刀尖朝反"）。
static func _load_custom(weapon_name: String) -> Node3D:
	var node: Node3D = null
	for ext in ["glb", "gltf", "fbx", "obj"]:
		var path := "%s/%s.%s" % [MODEL_DIR, weapon_name, ext]
		if not ResourceLoader.exists(path):
			continue
		var res = load(path)
		if res is PackedScene:
			node = (res as PackedScene).instantiate() as Node3D
		elif res is Mesh:
			node = MeshInstance3D.new()
			(node as MeshInstance3D).mesh = res
		if node != null:
			break
	if node == null:
		return null

	var aabb := _combined_aabb(node)
	if aabb.size.length() < 0.0001:
		return node   # 拿不到包围盒就原样返回
	# 最长轴转到 +Z
	var rot := Basis.IDENTITY
	if aabb.size.x >= aabb.size.y and aabb.size.x >= aabb.size.z:
		rot = Basis(Vector3.UP, -PI / 2.0)          # +X -> +Z
	elif aabb.size.y >= aabb.size.x and aabb.size.y >= aabb.size.z:
		rot = Basis(Vector3.RIGHT, PI / 2.0)        # +Y -> +Z
	if FileAccess.file_exists("%s/%s.flip" % [MODEL_DIR, weapon_name]):
		rot = Basis(Vector3.RIGHT, PI) * rot        # 翻转 180°
	# 缩放到标准全长
	var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var s := float(TARGET_LEN.get(weapon_name, 1.0)) / longest
	var fit := Node3D.new()
	fit.name = "Weapon"
	fit.add_child(node)
	node.transform = Transform3D(rot.scaled(Vector3.ONE * s), Vector3.ZERO)
	# 旋转缩放后重算包围盒，把握点（min_z + 18% 全长）挪到原点
	var fitted := _combined_aabb(fit)
	var grip := Vector3(
		fitted.position.x + fitted.size.x / 2.0,
		fitted.position.y + fitted.size.y / 2.0,
		fitted.position.z + fitted.size.z * 0.18)
	node.position = -grip
	return fit


## 合并节点树里所有网格的包围盒（相对 root 的局部空间）
static func _combined_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var found := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var xform: Transform3D = entry[1]
		if node is Node3D and node != root:
			xform = xform * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mesh_aabb: AABB = xform * (node as MeshInstance3D).mesh.get_aabb()
			result = mesh_aabb if not found else result.merge(mesh_aabb)
			found = true
		for child in node.get_children():
			stack.push_back([child, xform])
	return result


static func _mat(color: Color, metallic := 0.55, rough := 0.4, emission := Color.BLACK) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	if emission != Color.BLACK:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = 1.6
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	mi.mesh = mesh
	mi.position = pos
	parent.add_child(mi)


static func _cyl(parent: Node3D, top_r: float, bottom_r: float, height: float,
		pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = height
	mesh.material = mat
	mi.mesh = mesh
	mi.rotation_degrees.x = 90   # 圆柱轴向从 Y 转到 Z
	mi.position = pos
	parent.add_child(mi)


static func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = mat
	mi.mesh = mesh
	mi.position = pos
	parent.add_child(mi)


const SILVER := Color(0.85, 0.88, 0.92)
const STEEL := Color(0.62, 0.66, 0.72)
const WOOD := Color(0.36, 0.24, 0.14)
const GOLD := Color(0.85, 0.71, 0.42)


static func _umbrella(root: Node3D) -> void:
	var silver := _mat(SILVER, 0.8, 0.25)
	_cyl(root, 0.012, 0.012, 0.95, Vector3(0, 0, 0.35), silver)          # 伞杆
	_cyl(root, 0.02, 0.09, 0.46, Vector3(0, 0, 0.58), _mat(SILVER, 0.6, 0.35))  # 收拢伞面（细长锥）
	_cyl(root, 0.008, 0.008, 0.10, Vector3(0, 0, 0.87), silver)          # 伞尖
	_box(root, Vector3(0.03, 0.03, 0.10), Vector3(0, 0.04, -0.10), silver)  # 弯把


static func _spear(root: Node3D) -> void:
	_cyl(root, 0.015, 0.015, 1.55, Vector3(0, 0, 0.55), _mat(Color(0.5, 0.12, 0.10), 0.3, 0.6))
	_cyl(root, 0.0, 0.045, 0.28, Vector3(0, 0, 1.44), _mat(SILVER, 0.85, 0.2))   # 矛头
	_box(root, Vector3(0.10, 0.015, 0.06), Vector3(0, 0, 1.28), _mat(GOLD, 0.7, 0.3))  # 缨座
	_sphere(root, 0.025, Vector3(0, 0, -0.22), _mat(GOLD, 0.7, 0.3))


static func _greatsword(root: Node3D) -> void:
	var steel := _mat(STEEL, 0.8, 0.3)
	_box(root, Vector3(0.16, 0.02, 0.95), Vector3(0, 0, 0.62), steel)     # 宽刃
	_cyl(root, 0.0, 0.08, 0.16, Vector3(0, 0, 1.17), steel)               # 剑尖
	_box(root, Vector3(0.26, 0.035, 0.05), Vector3(0, 0, 0.12), _mat(GOLD, 0.7, 0.3))  # 护手
	_cyl(root, 0.022, 0.022, 0.26, Vector3(0, 0, -0.05), _mat(WOOD, 0.2, 0.7))


static func _katana(root: Node3D) -> void:
	var steel := _mat(SILVER, 0.85, 0.2)
	_box(root, Vector3(0.035, 0.012, 0.75), Vector3(0, 0.01, 0.52), steel)   # 刀身（微上弯）
	var tip := MeshInstance3D.new()
	var tmesh := BoxMesh.new()
	tmesh.size = Vector3(0.035, 0.012, 0.18)
	tmesh.material = steel
	tip.mesh = tmesh
	tip.position = Vector3(0, 0.028, 0.95)
	tip.rotation_degrees.x = -8
	root.add_child(tip)
	_cyl(root, 0.05, 0.05, 0.015, Vector3(0, 0, 0.13), _mat(GOLD, 0.7, 0.3))  # 圆镡
	_cyl(root, 0.018, 0.018, 0.24, Vector3(0, 0, -0.02), _mat(Color(0.15, 0.15, 0.2), 0.2, 0.7))


static func _rifle(root: Node3D) -> void:
	var silver := _mat(SILVER, 0.85, 0.25)
	_cyl(root, 0.02, 0.02, 0.72, Vector3(0, 0, 0.42), silver)             # 枪管
	_box(root, Vector3(0.04, 0.07, 0.30), Vector3(0, -0.02, 0.10), _mat(WOOD, 0.2, 0.6))  # 枪身
	_box(root, Vector3(0.035, 0.10, 0.16), Vector3(0, -0.06, -0.14), _mat(WOOD, 0.2, 0.6))  # 枪托
	_box(root, Vector3(0.012, 0.03, 0.02), Vector3(0, 0.045, 0.70), silver)  # 准星


static func _gauntlet(root: Node3D) -> void:
	var m := _mat(Color(0.75, 0.3, 0.15), 0.5, 0.45)
	_sphere(root, 0.075, Vector3(0, 0.01, 0.05), m)                       # 拳部
	_box(root, Vector3(0.11, 0.06, 0.10), Vector3(0, 0.01, -0.04), _mat(GOLD, 0.6, 0.35))  # 腕甲
	for zi in range(3):
		_box(root, Vector3(0.022, 0.02, 0.05), Vector3(-0.03 + zi * 0.03, 0.045, 0.08), _mat(SILVER, 0.8, 0.25))


static func _staff(root: Node3D) -> void:
	_cyl(root, 0.016, 0.016, 1.15, Vector3(0, 0, 0.38), _mat(WOOD, 0.2, 0.65))
	_sphere(root, 0.07, Vector3(0, 0, 1.02), _mat(Color(0.4, 0.7, 1.0), 0.2, 0.2, Color(0.3, 0.6, 1.0)))
	_cyl(root, 0.05, 0.03, 0.10, Vector3(0, 0, 0.93), _mat(GOLD, 0.7, 0.3))  # 托座


static func _cross(root: Node3D) -> void:
	var gold := _mat(GOLD, 0.75, 0.3)
	_cyl(root, 0.018, 0.018, 1.0, Vector3(0, 0, 0.32), _mat(SILVER, 0.7, 0.3))
	_box(root, Vector3(0.05, 0.03, 0.34), Vector3(0, 0, 0.94), gold)      # 竖臂
	_box(root, Vector3(0.22, 0.03, 0.05), Vector3(0, 0, 0.88), gold)      # 横臂
	_sphere(root, 0.03, Vector3(0, 0, 0.72), gold)


static func _dagger(root: Node3D) -> void:
	_box(root, Vector3(0.03, 0.01, 0.30), Vector3(0, 0, 0.24), _mat(Color(0.3, 0.32, 0.4), 0.8, 0.25))
	_cyl(root, 0.0, 0.02, 0.08, Vector3(0, 0, 0.42), _mat(Color(0.3, 0.32, 0.4), 0.8, 0.25))
	_box(root, Vector3(0.09, 0.02, 0.03), Vector3(0, 0, 0.08), _mat(Color(0.5, 0.2, 0.5), 0.5, 0.4))
	_cyl(root, 0.015, 0.015, 0.14, Vector3(0, 0, 0.0), _mat(Color(0.12, 0.12, 0.16), 0.2, 0.7))