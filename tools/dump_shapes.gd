extends SceneTree
## 打印 avatar0.vrm 的网格 + BlendShape 名（表情动补要驱动的就是这些）。

func _initialize() -> void:
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	_walk(scene, scene)
	quit()

func _walk(n: Node, owner_root: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Mesh = mi.mesh
		var cnt: int = m.get_blend_shape_count() if m != null else 0
		if cnt > 0:
			print("=== ", owner_root.get_path_to(mi), "  (", cnt, " 个 BlendShape)")
			for i in cnt:
				print("    ", m.get_blend_shape_name(i))
	for c in n.get_children():
		_walk(c, owner_root)
