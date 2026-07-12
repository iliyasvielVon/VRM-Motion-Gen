extends SceneTree
## 打印 avatar0.vrm 的授权 meta —— 决定这个模型能不能跟着仓库公开分发。

func _initialize() -> void:
	var scene: Node3D = (load("res://avatars/avatar0.vrm") as PackedScene).instantiate()
	root.add_child(scene)
	var meta = scene.get("vrm_meta")
	if meta == null:
		print("没有 vrm_meta")
		quit()
		return
	for p in meta.get_property_list():
		var n: String = p["name"]
		if n in ["script", "Resource", "resource_local_to_scene", "resource_path",
				"resource_name", "resource_scene_unique_id", "RefCounted", "Object"]:
			continue
		var v = meta.get(n)
		if v is Texture2D or v == null:
			continue
		print("%-28s = %s" % [n, v])
	quit()
