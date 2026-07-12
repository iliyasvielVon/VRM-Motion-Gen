extends SceneTree
## 临时诊断：打印 avatar0.vrm 的骨架层级（骨骼名 + 静止位置）
## godot --headless --path . --script res://tools/dump_bones.gd

func _initialize() -> void:
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	var skel := _find_skel(scene)
	if skel == null:
		print("NO SKELETON")
		quit()
		return
	print("BONE_COUNT=", skel.get_bone_count())
	for i in skel.get_bone_count():
		var rest := skel.get_bone_rest(i)
		print("%d\t%d\t%s\t(%.3f, %.3f, %.3f)" % [i, skel.get_bone_parent(i), skel.get_bone_name(i),
			rest.origin.x, rest.origin.y, rest.origin.z])
	quit()

func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null
