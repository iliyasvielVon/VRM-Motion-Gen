class_name AnimBaker
extends RefCounted
## 动作工房的数据层：整姿势关键帧 → 补间采样（slerp + 缓动）→ Animation 烘焙 → 工程存读。
##
## 关键帧 keys: { 帧号:int -> { 骨骼名:String -> Quaternion(骨骼局部姿态) } }
## （Flash/Animate 式整姿势快照：每个关键帧记全身，帧间自动补间。）
## 补间区间 spans: { 起始关键帧号:int -> Ease }——描述「这个关键帧到下一个关键帧
## 之间怎么走」。没登记的区间按 LINEAR 走（= 老工程的行为，读旧文件不用迁移）。
##
## 导出 .tres：rotation_3d 轨道 + "%GeneralSkeleton:骨骼名" 路径——与 Mixamo 重定向
## 剪辑同格式，MotionController.play_clip 直接可播、可交叉混合、可调速。

const FPS := 30.0
const CUSTOM_DIR := "res://animations/custom"

enum Ease { LINEAR, IN, OUT, IN_OUT, HOLD }

const EASE_NAMES := ["线性", "缓入", "缓出", "缓入缓出", "定格"]


## 缓动曲线：把 0~1 的线性进度重映射
static func ease_t(t: float, e: int) -> float:
	match e:
		Ease.IN:
			return t * t                      # 慢起快收
		Ease.OUT:
			return 1.0 - (1.0 - t) * (1.0 - t)   # 快起慢收
		Ease.IN_OUT:
			return t * t * (3.0 - 2.0 * t)    # smoothstep
		Ease.HOLD:
			return 0.0                        # 定格：停在前一个关键帧直到下一个关键帧
	return t


static func sorted_frames(keys: Dictionary) -> Array:
	var fs := keys.keys()
	fs.sort()
	return fs


## 补间采样的通用部分：找到 frame 落在哪两个关键帧之间，返回 [前帧, 后帧, 缓动后的 t]
## （没有关键帧返回空；越界或落在关键帧上时前后帧相同）
static func _span_at(keys: Dictionary, frame: float, spans: Dictionary) -> Array:
	var fs := sorted_frames(keys)
	if fs.is_empty():
		return []
	if frame <= float(fs[0]):
		return [fs[0], fs[0], 0.0]
	if frame >= float(fs.back()):
		return [fs.back(), fs.back(), 0.0]
	var prev: int = fs[0]
	var next: int = fs.back()
	for f in fs:
		if float(f) <= frame:
			prev = f
		if float(f) >= frame:
			next = f
			break
	if prev == next:
		return [prev, prev, 0.0]
	return [prev, next,
		ease_t((frame - float(prev)) / float(next - prev), int(spans.get(prev, Ease.LINEAR)))]


## 胯的平移的补间采样：{帧号 -> Vector3} 在 frame 处的线性插值
static func sample_root(roots: Dictionary, frame: float, spans := {}) -> Vector3:
	var s := _span_at(roots, frame, spans)
	if s.is_empty():
		return Vector3.ZERO
	var a: Vector3 = roots[s[0]]
	return a if s[0] == s[1] else a.lerp(roots[s[1]], s[2])


## 表情形变的补间采样：{帧号 -> {形变名: 0~1}} 在 frame 处的线性插值
static func sample_shapes(shapes: Dictionary, frame: float, spans := {}) -> Dictionary:
	var s := _span_at(shapes, frame, spans)
	if s.is_empty():
		return {}
	var a: Dictionary = shapes[s[0]]
	if s[0] == s[1]:
		return a
	var b: Dictionary = shapes[s[1]]
	var t: float = s[2]
	var out := {}
	for name in a:
		out[name] = lerpf(a[name], b.get(name, 0.0), t)
	for name in b:
		if not a.has(name):
			out[name] = lerpf(0.0, b[name], t)   # 前一帧没这个形变 = 从 0 淡入
	return out


## 补间采样：frame 处的整姿势（前后关键帧按区间缓动 slerp，越界夹到端点；无关键帧返回空）
static func sample(keys: Dictionary, frame: float, spans := {}) -> Dictionary:
	var fs := sorted_frames(keys)
	if fs.is_empty():
		return {}
	if frame <= float(fs[0]):
		return keys[fs[0]]
	if frame >= float(fs.back()):
		return keys[fs.back()]
	var prev: int = fs[0]
	var next: int = fs.back()
	for f in fs:
		if float(f) <= frame:
			prev = f
		if float(f) >= frame:
			next = f
			break
	if prev == next:
		return keys[prev]
	var t := ease_t((frame - float(prev)) / float(next - prev), int(spans.get(prev, Ease.LINEAR)))
	var a: Dictionary = keys[prev]
	var b: Dictionary = keys[next]
	var out := {}
	for bone in a:
		out[bone] = (a[bone] as Quaternion).slerp(b[bone], t) if b.has(bone) else a[bone]
	for bone in b:
		if not a.has(bone):
			out[bone] = b[bone]
	return out


## 需要写进 Animation 的帧：所有关键帧，加上非线性区间的每一个中间帧。
## （Godot 的 rotation_3d 轨道两个关键帧之间只会匀速 slerp，缓动/定格喂不进去，
##   所以缓动区间只能逐帧烘死；线性区间保持两个端点关键帧，轨道最干净。）
static func bake_frames(keys: Dictionary, spans: Dictionary) -> Array:
	var fs := sorted_frames(keys)
	var out := {}
	for f in fs:
		out[f] = true
	for i in range(fs.size() - 1):
		var a: int = fs[i]
		var b: int = fs[i + 1]
		if int(spans.get(a, Ease.LINEAR)) == Ease.LINEAR:
			continue
		for f in range(a + 1, b):
			out[f] = true
	var frames := out.keys()
	frames.sort()
	return frames


## 烘焙成 Animation：每根出现过的骨骼一条 rotation_3d 轨道，每个用到的表情形变一条
## blend_shape 轨道（shape_node = 挂着形变的网格，如 "%GeneralSkeleton/Face"）。
## roots = 胯的平移（全身 IK 拖胯挪重心时才有），会额外烘一条 position_3d 轨道；
## root_rest = 胯的静止局部位置——position 轨道写的是绝对位置，不是偏移量。
static func bake(keys: Dictionary, length_frames: int, looping: bool, spans := {},
		shapes := {}, shape_node := "", roots := {}, root_rest := Vector3.ZERO) -> Animation:
	var anim := Animation.new()
	anim.length = maxf(length_frames / FPS, 1.0 / FPS)
	anim.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE

	var bones := {}
	for f in keys:
		for b in keys[f]:
			bones[b] = true
	var frames := bake_frames(keys, spans)
	var poses := {}
	for f in frames:
		poses[f] = sample(keys, float(f), spans)
	for bone in bones:
		var tr := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(tr, "%GeneralSkeleton:" + str(bone))
		for f in frames:
			if (poses[f] as Dictionary).has(bone):
				anim.rotation_track_insert_key(tr, f / FPS, poses[f][bone])

	if not roots.is_empty():
		var tr := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(tr, "%GeneralSkeleton:Hips")
		for f in bake_frames(roots, spans):
			anim.position_track_insert_key(tr, f / FPS, root_rest + (roots[f] as Vector3))

	if shapes.is_empty() or shape_node.is_empty():
		return anim
	var names := {}
	for f in shapes:
		for n in shapes[f]:
			names[n] = true
	var sframes := bake_frames(shapes, spans)
	for n in names:
		var tr := anim.add_track(Animation.TYPE_BLEND_SHAPE)
		anim.track_set_path(tr, "%s:%s" % [shape_node, n])
		for f in sframes:
			# 某一帧没登记这个形变 = 那一帧它是 0（脸上没这个表情），不能跳过：
			# 跳过的话轨道会把前后两个非零关键帧直接连起来，表情永远消不掉
			anim.blend_shape_track_insert_key(tr, f / FPS,
				float((shapes[f] as Dictionary).get(n, 0.0)))
	return anim


## 导出 .tres 到 animations/custom/<名>.tres，返回路径（失败返回空串）
static func export_tres(anim_name: String, keys: Dictionary, length_frames: int,
		looping: bool, spans := {}, shapes := {}, shape_node := "", roots := {},
		root_rest := Vector3.ZERO) -> String:
	if keys.is_empty() or anim_name.strip_edges().is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(CUSTOM_DIR)
	var path := "%s/%s.tres" % [CUSTOM_DIR, anim_name.strip_edges()]
	if ResourceSaver.save(bake(keys, length_frames, looping, spans, shapes, shape_node,
			roots, root_rest), path) != OK:
		return ""
	return path


# ---------------------------------------------------------------- 抽稀

## 把逐帧关键帧（动补录出来的那种，时间轴全是金格子、没法手改）压成「只在姿势转折处
## 留关键帧、中间交给线性补间」。Douglas-Peucker：递归找「线性补间误差最大的那一帧」，
## 超过阈值就把它留下来当新的转折点，两边再各自递归。tol_deg = 允许的最大骨骼偏差（度）。
static func decimate(keys: Dictionary, tol_deg: float) -> Dictionary:
	var fs := sorted_frames(keys)
	if fs.size() <= 2:
		return keys.duplicate()
	var keep := {fs[0]: true, fs[fs.size() - 1]: true}
	_split(keys, fs, 0, fs.size() - 1, tol_deg, keep)
	var out := {}
	for f in fs:
		if keep.has(f):
			out[f] = keys[f]
	return out


static func _split(keys: Dictionary, fs: Array, i0: int, i1: int, tol: float,
		keep: Dictionary) -> void:
	if i1 - i0 < 2:
		return
	var a: Dictionary = keys[fs[i0]]
	var b: Dictionary = keys[fs[i1]]
	var worst := -1.0
	var worst_i := -1
	for i in range(i0 + 1, i1):
		var t := float(int(fs[i]) - int(fs[i0])) / float(int(fs[i1]) - int(fs[i0]))
		var err := 0.0
		for bone in keys[fs[i]]:
			if not a.has(bone) or not b.has(bone):
				continue
			var guess: Quaternion = (a[bone] as Quaternion).slerp(b[bone], t)
			err = maxf(err, _quat_deg(guess, keys[fs[i]][bone]))
		if err > worst:
			worst = err
			worst_i = i
	if worst > tol and worst_i > i0:
		keep[fs[worst_i]] = true
		_split(keys, fs, i0, worst_i, tol, keep)
		_split(keys, fs, worst_i, i1, tol, keep)


static func _quat_deg(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.dot(b)), 0.0, 1.0)))


## 表情通道的抽稀（同一套 Douglas-Peucker，误差换成通道值的线性插值偏差）。
## 表情必须和骨骼分开抽：眨眼的时候骨骼一动不动，按骨骼的转折点抽，
## 眨眼那三四帧会被整段抽掉——录了个眨眼，抽完稀眼睛就再也不眨了。
static func decimate_channels(chans: Dictionary, tol: float) -> Dictionary:
	var fs := sorted_frames(chans)
	if fs.size() <= 2:
		return chans.duplicate()
	var keep := {fs[0]: true, fs[fs.size() - 1]: true}
	_split_ch(chans, fs, 0, fs.size() - 1, tol, keep)
	var out := {}
	for f in fs:
		if keep.has(f):
			out[f] = chans[f]
	return out


static func _split_ch(chans: Dictionary, fs: Array, i0: int, i1: int, tol: float,
		keep: Dictionary) -> void:
	if i1 - i0 < 2:
		return
	var a: Dictionary = chans[fs[i0]]
	var b: Dictionary = chans[fs[i1]]
	var names := {}
	for i in range(i0, i1 + 1):
		for n in chans[fs[i]]:
			names[n] = true
	var worst := -1.0
	var worst_i := -1
	for i in range(i0 + 1, i1):
		var t := float(int(fs[i]) - int(fs[i0])) / float(int(fs[i1]) - int(fs[i0]))
		var err := 0.0
		for n in names:   # 某帧没登记这个通道 = 那一帧它是 0（和烘焙的语义一致）
			var guess := lerpf(float(a.get(n, 0.0)), float(b.get(n, 0.0)), t)
			err = maxf(err, absf(guess - float((chans[fs[i]] as Dictionary).get(n, 0.0))))
		if err > worst:
			worst = err
			worst_i = i
	if worst > tol and worst_i > i0:
		keep[fs[worst_i]] = true
		_split_ch(chans, fs, i0, worst_i, tol, keep)
		_split_ch(chans, fs, worst_i, i1, tol, keep)


# ---------------------------------------------------------------- 工程存读（JSON）

static func project_path(anim_name: String) -> String:
	return "%s/%s.pose.json" % [CUSTOM_DIR, anim_name.strip_edges()]


static func save_project(anim_name: String, keys: Dictionary, length_frames: int,
		looping: bool, spans := {}, shapes := {}, roots := {}) -> bool:
	DirAccess.make_dir_recursive_absolute(CUSTOM_DIR)
	var jkeys := {}
	for f in keys:
		var jpose := {}
		for bone in keys[f]:
			var q: Quaternion = keys[f][bone]
			jpose[bone] = [q.x, q.y, q.z, q.w]
		jkeys[str(f)] = jpose
	var jspans := {}
	for f in spans:
		jspans[str(f)] = int(spans[f])
	var jshapes := {}
	for f in shapes:
		jshapes[str(f)] = shapes[f]
	var jroots := {}
	for f in roots:
		var v: Vector3 = roots[f]
		jroots[str(f)] = [v.x, v.y, v.z]
	var file := FileAccess.open(project_path(anim_name), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"fps": FPS, "length": length_frames, "loop": looping,
		"keys": jkeys, "spans": jspans, "shapes": jshapes, "roots": jroots}, "  "))
	return true


## 读工程：{ok, keys, spans, shapes, roots, length, loop}
## （老工程没有 spans / shapes / roots 字段 → 全线性、无表情、胯不平移，行为跟以前一模一样）
static func load_project(anim_name: String) -> Dictionary:
	var path := project_path(anim_name)
	if not FileAccess.file_exists(path):
		return {"ok": false}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null or not (data is Dictionary):
		return {"ok": false}
	var keys := {}
	for fs in data.get("keys", {}):
		var pose := {}
		for bone in data["keys"][fs]:
			var arr: Array = data["keys"][fs][bone]
			pose[bone] = Quaternion(arr[0], arr[1], arr[2], arr[3])
		keys[int(fs)] = pose
	var spans := {}
	for fs in data.get("spans", {}):
		spans[int(fs)] = int(data["spans"][fs])
	var shapes := {}
	for fs in data.get("shapes", {}):
		var vals := {}
		for n in data["shapes"][fs]:
			vals[n] = float(data["shapes"][fs][n])
		shapes[int(fs)] = vals
	var roots := {}
	for fs in data.get("roots", {}):
		var v: Array = data["roots"][fs]
		roots[int(fs)] = Vector3(v[0], v[1], v[2])
	return {"ok": true, "keys": keys, "spans": spans, "shapes": shapes, "roots": roots,
		"length": int(data.get("length", 48)), "loop": bool(data.get("loop", true))}
