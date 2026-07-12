class_name AvatarContext
extends RefCounted
## 加载完成的 VRM 的"上下文"：骨架、所有网格、皮肤材质。
## 对应 Unity 参考工程的 AvatarContext.cs。

var root: Node3D
var skeleton: Skeleton3D
var mesh_instances: Array[MeshInstance3D] = []
var skin_materials: Array[Material] = []


func _init(avatar_root: Node3D) -> void:
	root = avatar_root
	_collect(root)


func _collect(node: Node) -> void:
	if node is Skeleton3D and skeleton == null:
		skeleton = node
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mesh_instances.append(mi)
		for s in range(mi.get_surface_override_material_count()):
			var mat := mi.get_active_material(s)
			if mat != null and _is_skin_material(mat) and not skin_materials.has(mat):
				skin_materials.append(mat)
	for child in node.get_children():
		_collect(child)


## VRoid 皮肤材质命名如 N00_000_00_Body_00_SKIN / N00_000_00_Face_00_SKIN
static func _is_skin_material(mat: Material) -> bool:
	var n := mat.resource_name.to_lower()
	return n.contains("skin")


## 取某个表面的当前材质名（优先 override，再 active）
static func material_name(mi: MeshInstance3D, surface: int) -> String:
	var mat := mi.get_active_material(surface)
	return mat.resource_name if mat != null else ""
