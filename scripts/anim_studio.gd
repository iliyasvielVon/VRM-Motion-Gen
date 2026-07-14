extends Node3D
## 动作工房：模型在左、骨骼树在右、时间轴在下的 VRM 动作编辑器。
## 运行方式：编辑器里打开 scenes/anim_studio.tscn 按 F6，或
##   godot --path . scenes/anim_studio.tscn
##
## 摆姿势（三种，随便混用）：
##   1. 在 3D 里直接点骨头选中，按住左键拖 —— **整体 IK**（默认）：从胯到这根骨头的整条链
##      一起解，手臂先动、够不着才弯腰拧腰，双脚锁地不打滑（见 body_ik.gd）。
##      关掉就是单骨 FK：只把被拖的那一根扭向光标。
##   2. 选中骨头后关节处出现红/绿/蓝三个旋转环，拖环 = 绕该轴精确旋转（按住 Ctrl 吸附 5°）；
##   3. 右侧骨骼树选骨头 + XYZ 滑条输数值。
##   拖 Hips = 整个人平移（挪重心）——会额外烘一条 position_3d 轨道。
##
## 关键帧-补间（Flash/Animate 式）：
##   时间轴点帧格移动播放头；F6 / 「插入关键帧」把当前整身姿势记成关键帧（金色格）。
##   点起始帧、按住 Shift 点结束帧选中一段，选好缓动曲线按「创建补间」——
##   两端没关键帧会自动补上，区间按 线性/缓入/缓出/缓入缓出/定格 走。
##
## 存读 .pose.json 工程可反复改；「导出动画」烘焙 .tres（Animation 资源，轨道路径
## `%GeneralSkeleton:骨骼名`），母项目 MotionController.play_clip 即插即用。

const AVATAR := "res://avatars/avatar0.vrm"

const MAX_FRAMES := 240   # 8 秒 @30fps
const PANEL_X := 1288.0   # 右侧骨骼面板左边缘 —— 3D 拾取区就是它左边那块
const STAGE_TOP := 96.0   # 3D 拾取区上边缘（顶栏两行之下）
const TL_Y := 744.0       # 底部时间轴面板上边缘
const SNAP_DEG := 5.0     # 按住 Ctrl 时旋转环的吸附角

const MOCAP_DIR := "res://animations/mocap"
const MOCAP_PORT := 9977         # tools/mocap/capture.py --camera 往这个口喷关键点
const LIVE_SMOOTH := 0.6         # 实时动补的平滑（抖动全靠它压，但太大会拖泥带水）
const IMPORT_SMOOTH := 0.35      # 离线导入可以少平滑一点，细节留多些
## 抽稀阈值（度）。定 8 而不是更小：动补数据本身就有 5~10° 的逐帧噪声，
## 阈值压到噪声地板以下的话每一帧都会被判为「转折点」，一帧也删不掉。
const DECIMATE_DEG := 8.0

enum Drag { NONE, AIM, RING }

var skeleton: Skeleton3D
var _cam: OrbitCamera
var _overlay: BoneOverlay
var _solver: PoseSolver
var _bodyik: BodyIK
var _mocap: Mocap
var _shape_mesh: MeshInstance3D  # 挂着表情形变的网格（VRoid 里叫 Face）
var _shape_node := ""            # 它在动画轨道里的路径，如 "%GeneralSkeleton/Face"

var _bones := {}                 # 骨骼名 -> 索引（全身人形 52 根）
var _rest_rot := {}              # 索引 -> 静止旋转

# ---- 工程数据
var _keys := {}                  # 帧号 -> {骨骼名: Quaternion}
var _shapes := {}                # 帧号 -> {表情形变名: 0~1}
var _roots := {}                 # 帧号 -> Vector3（胯的平移；只有拖胯挪重心时才有）
var _spans := {}                 # 补间区间起始帧号 -> AnimBaker.Ease
var _len := 48
var _loop := true
var _playhead := 0.0
var _playing := false

# ---- 动补
var _udp: PacketPeerUDP
var _live := false               # 实时动补：在收 UDP 关键点
var _recording := false
var _rec_t := 0.0
var _rec_last := -1
var _last_solved := {}           # 上一帧解算结果（平滑用）

# ---- 编辑状态
var _pose := {}                  # 当前工作姿势（骨骼名 -> 局部四元数）
var _shape_pose := {}            # 当前工作表情（形变名 -> 0~1）
var _sel_bone := "RightUpperArm"
var _sel_a := -1                 # 时间轴区间选择（帧号，-1 = 无）
var _sel_b := -1
var _drag := Drag.NONE
var _drag_axis := -1
var _drag_q0 := Quaternion.IDENTITY
var _ring_last := 0.0
var _ring_accum := 0.0
var _ring_sign := 1.0
var _dirty := false              # 本次拖拽改过姿势 → 松手落关键帧
var _full_ik := true             # 拖骨头时整条链一起解（关掉 = 只转被拖的那一根）
var _pin_feet := true
var _root_off := Vector3.ZERO    # 当前胯的平移
var _weapon_on := false

# ---- UI 引用
var _name_edit: LineEdit
var _hint: Label
var _frame_lbl: Label
var _sel_lbl: Label
var _play_btn: Button
var _ik_btn: Button
var _feet_cb: CheckBox
var _loop_cb: CheckBox
var _len_edit: LineEdit
var _ease_opt: OptionButton
var _mocap_opt: OptionButton
var _live_btn: Button
var _rec_btn: Button
var _tree: Tree
var _tree_items := {}            # 骨骼名 -> TreeItem
var _tree_syncing := false       # 3D 选骨 → 回写树选中，别让 item_selected 再弹回来
var _sliders := {}
var _slider_vals := {}
var _timeline: Timeline
var _tl_menu: PopupMenu
var _tl_menu_frame := -1
var _last_drawn_frame := -1


func _ready() -> void:
	_build_stage()
	_build_model()
	_build_ui()
	_goto_frame(0)
	_select_bone(_sel_bone)
	_show_hint("点 3D 里的骨头选中 · 拖骨头 = 转向光标 · 拖旋转环 = 绕轴转（Ctrl 吸附 5°）")


# ---------------------------------------------------------------- 舞台 / 模型

func _build_stage() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.028, 0.028)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.45, 0.42)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 35, 0)
	light.light_energy = 1.1
	light.shadow_enabled = true
	add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 2.2
	disc.bottom_radius = 2.2
	disc.height = 0.06
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.22, 0.09, 0.09)
	disc.material = fmat
	floor_mesh.mesh = disc
	floor_mesh.position.y = -0.03
	add_child(floor_mesh)
	_cam = OrbitCamera.new()
	_cam.fov = 45.0
	_cam.distance = 2.8
	_cam.focus = Vector3(0, 1.0, 0)
	_cam.yaw = 0.0                # 看模型正面（avatar0 朝 +Z，相机站 +Z 侧）
	_cam.lateral = _lateral_shift()
	add_child(_cam)


## 右侧被骨骼面板占掉一块，把相机横挪一点让模型落在剩下那块的中间（= 画面偏左）
func _lateral_shift() -> float:
	var vp := get_viewport().get_visible_rect().size
	var free_center := PANEL_X * 0.5
	var m_per_px := 2.0 * _cam.distance * tan(deg_to_rad(_cam.fov) * 0.5) / vp.y
	return (vp.x * 0.5 - free_center) * m_per_px


func _build_model() -> void:
	if not ResourceLoader.exists(AVATAR):
		push_error("动作工房：找不到 " + AVATAR)
		return
	var scene: Node3D = (load(AVATAR) as PackedScene).instantiate()
	add_child(scene)
	skeleton = AvatarContext.new(scene).skeleton
	if skeleton == null:
		push_error("动作工房：VRM 里没找到 Skeleton3D")
		return
	_bones = HumanoidBones.resolve_all(skeleton)
	for bname in _bones:
		_rest_rot[_bones[bname]] = skeleton.get_bone_rest(_bones[bname]).basis.get_rotation_quaternion()
	print("动作工房骨骼：%d/%d 根人形骨（骨架共 %d 根）"
		% [_bones.size(), HumanoidBones.humanoid_names().size(), skeleton.get_bone_count()])
	_overlay = BoneOverlay.new()
	skeleton.add_child(_overlay)   # 挂在骨架下、不带 skin → 顶点直接用骨架空间坐标
	_overlay.setup(skeleton, _cam)
	_solver = PoseSolver.new()
	_solver.setup(skeleton)
	_bodyik = BodyIK.new()
	_bodyik.setup(_solver)
	_mocap = Mocap.new()
	_mocap.setup(skeleton, _solver)   # 动补和全身 IK 共用同一个求解器
	_find_shape_mesh(scene)


## 找挂着表情形变的网格（VRoid 是 Face，别的模型可能叫别的，所以按「有没有形变」找）
func _find_shape_mesh(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# 只看 ArrayMesh：骨骼线框那个 overlay 也是 MeshInstance3D，但它是 ImmediateMesh，
		# 压根没有 get_blend_shape_count 这个方法
		if mi.mesh is ArrayMesh and mi.mesh.get_blend_shape_count() > 0 and _shape_mesh == null:
			_shape_mesh = mi
			_shape_node = "%%GeneralSkeleton/%s" % mi.name
			print("动作工房表情：%s（%d 个形变），轨道路径 %s"
				% [mi.name, mi.mesh.get_blend_shape_count(), _shape_node])
	for c in node.get_children():
		_find_shape_mesh(c)


# ---------------------------------------------------------------- 每帧

func _process(delta: float) -> void:
	if skeleton == null:
		return
	if _live:
		_poll_mocap()
		if _recording:
			_record(delta)
	if _playing and not _keys.is_empty():
		_playhead += delta * AnimBaker.FPS
		if _playhead >= float(_len):
			if _loop:
				_playhead = fmod(_playhead, float(_len))
			else:
				_playhead = float(_len) - 0.01
				_set_playing(false)
		_apply_pose(AnimBaker.sample(_keys, _playhead, _spans),
			AnimBaker.sample_root(_roots, _playhead, _spans))
		_apply_shapes(AnimBaker.sample_shapes(_shapes, _playhead, _spans))
	else:
		_apply_pose(_pose, _root_off)
		_apply_shapes(_shape_pose)
	if int(_playhead) != _last_drawn_frame:
		_redraw_timeline()
		if _playing:
			_timeline.follow_playhead()
	if _drag == Drag.NONE and not _playing:
		var m := get_viewport().get_mouse_position()
		_overlay.hovered = _overlay.pick_bone(m) if _in_stage(m) else ""
	_overlay.rings_visible = not _playing
	_overlay.redraw()


func _exit_tree() -> void:
	_stop_live()   # 别把 UDP 端口占着不放


## 鼠标是否落在 3D 舞台区（右侧面板 / 底部时间轴 / 顶栏之外）
func _in_stage(m: Vector2) -> bool:
	return m.x < PANEL_X and m.y > STAGE_TOP and m.y < TL_Y


## 把姿势写到骨架（缺的骨骼回静止姿态）。root_off = 胯的平移。
func _apply_pose(pose: Dictionary, root_off := Vector3.ZERO) -> void:
	for bname in _bones:
		var idx: int = _bones[bname]
		skeleton.set_bone_pose_rotation(idx, pose.get(bname, _rest_rot[idx]))
	if _bones.has("Hips"):
		skeleton.set_bone_pose_position(_bones["Hips"],
			_solver.rest_local_origin("Hips") + root_off)


## 把表情写到网格。没登记的形变一律归零——不归零的话上一帧的表情会永远糊在脸上
func _apply_shapes(shapes: Dictionary) -> void:
	if _shape_mesh == null:
		return
	var mesh: Mesh = _shape_mesh.mesh
	for i in mesh.get_blend_shape_count():
		var n: String = mesh.get_blend_shape_name(i)
		_shape_mesh.set("blend_shapes/%s" % n, float(shapes.get(n, 0.0)))


## 当前工作姿势的全身快照（关键帧存整姿势，Flash 式）
func _snapshot() -> Dictionary:
	var out := {}
	for bname in _bones:
		out[bname] = _pose.get(bname, _rest_rot[_bones[bname]])
	return out


## 第 frame 帧的整姿势（补全所有骨骼；没有任何关键帧时就是当前姿势）
func _pose_at(frame: float) -> Dictionary:
	if _keys.is_empty():
		return _snapshot()
	var s := AnimBaker.sample(_keys, frame, _spans)
	var out := {}
	for bname in _bones:
		out[bname] = s.get(bname, _rest_rot[_bones[bname]])
	return out


# ---------------------------------------------------------------- 3D 里操作骨骼

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_SPACE:
				_set_playing(not _playing)
			KEY_F6:
				_insert_key()
				_show_hint("已在第 %d 帧插入关键帧" % (int(round(_playhead)) + 1))
		return
	if skeleton == null or _playing or _live:
		return   # 实时动补开着的时候姿势每帧被关键点覆盖，手拖也留不住

	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if _in_stage(mb.position):
				_begin_drag(mb.position)
		else:
			if _dirty:
				_insert_key()       # 拖完自动落关键帧
			_drag = Drag.NONE
			_dirty = false
		return

	if event is InputEventMouseMotion and _drag != Drag.NONE:
		var m := (event as InputEventMouseMotion).position
		match _drag:
			Drag.AIM:
				_aim_bone(m)
			Drag.RING:
				_spin_ring(m, Input.is_key_pressed(KEY_CTRL))
		_dirty = true
		_refresh_sliders()


func _begin_drag(m: Vector2) -> void:
	var axis := _overlay.pick_ring(m)
	if axis >= 0:
		_drag = Drag.RING
		_drag_axis = axis
		_drag_q0 = _pose.get(_sel_bone, _rest_rot[_bones[_sel_bone]]) as Quaternion
		_ring_last = _screen_angle(m)
		_ring_accum = 0.0
		# 轴指向镜头背面时，屏幕上的顺时针 = 绕轴正向（右手定则），指向镜头则相反
		var axis_w: Vector3 = (skeleton.global_transform.basis
			* (_overlay.parent_basis(_sel_bone) * BoneOverlay.AXES[axis])).normalized()
		var view_dir := (_bone_origin_world(_sel_bone) - _cam.global_position).normalized()
		_ring_sign = 1.0 if axis_w.dot(view_dir) > 0.0 else -1.0
		return
	var hit := _overlay.pick_bone(m)
	if hit != "":
		_select_bone(hit)
		_drag = Drag.AIM
		_aim_bone(m)


func _bone_origin_world(bname: String) -> Vector3:
	return skeleton.global_transform * _overlay.joint(bname)


func _screen_angle(m: Vector2) -> float:
	return (m - _cam.unproject_position(_bone_origin_world(_sel_bone))).angle()


## 拖骨头。目标点取在「过骨头尖、面向相机」的平面上——骨头只在屏幕平面内动，
## 转视角（右键拖）就能从别的方向补另一个自由度。
##   整体 IK（默认）：从胯到这根骨头的整条链一起解，手臂先动、够不着才弯腰（见 body_ik.gd）。
##   单骨 FK：只把被拖的这一根扭向光标，别的骨头一动不动。
func _aim_bone(m: Vector2) -> void:
	var target = _drag_target(m)
	if target == null:
		return
	if _full_ik:
		var r := _bodyik.solve(_pose, _root_off, _sel_bone, target, _pin_feet)
		_pose = r["bones"]
		_root_off = r["root"]
	else:
		_fk_aim(target)


## 光标在「过骨头尖、面向相机」的平面上的落点（骨架空间）；打不中返回 null
func _drag_target(m: Vector2):
	var xform := skeleton.global_transform
	var tip_world: Vector3 = xform * _overlay.tip(_sel_bone)
	var plane := Plane(-_cam.global_transform.basis.z, tip_world)
	var hit = plane.intersects_ray(_cam.project_ray_origin(m), _cam.project_ray_normal(m))
	return null if hit == null else xform.affine_inverse() * (hit as Vector3)


## 单骨 FK：骨架空间里把「当前骨向」最短弧扭到「关节→目标」，再换算回父空间的局部姿态
func _fk_aim(target: Vector3) -> void:
	var idx: int = _bones[_sel_bone]
	var g := skeleton.get_bone_global_pose(idx)
	var to_target := target - g.origin
	if to_target.length() < 0.001:
		return
	var world_delta := Quaternion(_overlay.bone_dir(_sel_bone), to_target.normalized())
	var new_basis := Basis(world_delta) * g.basis.orthonormalized()
	var parent_b := Basis.IDENTITY
	var p := skeleton.get_bone_parent(idx)
	if p >= 0:
		parent_b = skeleton.get_bone_global_pose(p).basis.orthonormalized()
	_pose[_sel_bone] = (parent_b.inverse() * new_basis).get_rotation_quaternion().normalized()


## 旋转环：绕父空间的某根轴转，角度 = 光标绕关节转过的屏幕角（可累计多圈）
func _spin_ring(m: Vector2, snap: bool) -> void:
	var a := _screen_angle(m)
	_ring_accum += wrapf(a - _ring_last, -PI, PI) * _ring_sign
	_ring_last = a
	var ang := _ring_accum
	if snap:
		ang = snappedf(ang, deg_to_rad(SNAP_DEG))
	_pose[_sel_bone] = Quaternion(BoneOverlay.AXES[_drag_axis], ang) * _drag_q0


# ---------------------------------------------------------------- 骨骼选择 / 滑条

func _select_bone(bname: String) -> void:
	if not _bones.has(bname):
		return
	_sel_bone = bname
	_overlay.selected = bname
	if _tree_items.has(bname) and not _tree_syncing:
		var item: TreeItem = _tree_items[bname]
		_tree_syncing = true
		item.uncollapse_tree()
		_tree.set_selected(item, 0)
		_tree.scroll_to_item(item)
		_tree_syncing = false
	if _sel_lbl != null:
		_sel_lbl.text = bname
	_refresh_sliders()


func _on_tree_selected() -> void:
	if _tree_syncing:
		return
	var item := _tree.get_selected()
	if item != null:
		_select_bone(str(item.get_metadata(0)))


## 滑条显示 = 当前姿势相对静止姿态的父空间偏转（欧拉角，度）
func _refresh_sliders() -> void:
	if not _bones.has(_sel_bone) or _sliders.is_empty():
		return
	var rest: Quaternion = _rest_rot[_bones[_sel_bone]]
	var offset: Quaternion = (_pose.get(_sel_bone, rest) as Quaternion) * rest.inverse()
	var e := offset.get_euler()
	var vals := {"x": rad_to_deg(e.x), "y": rad_to_deg(e.y), "z": rad_to_deg(e.z)}
	for axis in _sliders:
		(_sliders[axis] as HSlider).set_value_no_signal(vals[axis])
		(_slider_vals[axis] as Label).text = "%d°" % roundi(vals[axis])


func _on_slider_changed(_v: float) -> void:
	if _playing or not _bones.has(_sel_bone):
		return
	var e := Vector3(deg_to_rad(_sliders["x"].value), deg_to_rad(_sliders["y"].value),
		deg_to_rad(_sliders["z"].value))
	_pose[_sel_bone] = Quaternion.from_euler(e) * (_rest_rot[_bones[_sel_bone]] as Quaternion)
	for axis in _slider_vals:
		(_slider_vals[axis] as Label).text = "%d°" % roundi(_sliders[axis].value)
	_insert_key()   # 调姿势自动落关键帧（Animate 属性关键帧直觉）


func _reset_bone() -> void:
	_pose.erase(_sel_bone)
	_refresh_sliders()
	_insert_key()
	_show_hint("已把 %s 复位到静止姿态" % _sel_bone)


func _reset_all() -> void:
	_pose.clear()
	_shape_pose.clear()
	_root_off = Vector3.ZERO
	_refresh_sliders()
	_insert_key()
	_show_hint("已把全身复位到静止姿态")


# ---------------------------------------------------------------- 动补

## 实时动补：收 capture.py 从摄像头喷过来的关键点（UDP），解算成姿势直接摆到模型上
func _toggle_live() -> void:
	if _live:
		_stop_live()
		_show_hint("实时动补已关闭")
		return
	_udp = PacketPeerUDP.new()
	if _udp.bind(MOCAP_PORT, "127.0.0.1") != OK:
		_show_hint("占不到 UDP %d 端口——是不是已经开着一个动作工房？" % MOCAP_PORT)
		_udp = null
		return
	_live = true
	_set_playing(false)
	_live_btn.text = "实时动补：开"
	_show_hint("在等 UDP %d 的关键点：另开终端跑 capture.py --camera 0（电脑摄像头）或 --phone（手机）"
		% MOCAP_PORT)


func _stop_live() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	_live = false
	_recording = false
	_last_solved = {}
	if _live_btn != null:
		_live_btn.text = "实时动补：关"
		_rec_btn.text = "● 录制"


func _poll_mocap() -> void:
	var got := false
	while _udp.get_available_packet_count() > 0:
		var raw := _udp.get_packet().get_string_from_utf8()
		var frame = JSON.parse_string(raw)
		if not (frame is Dictionary):
			continue
		var r := _mocap.solve(frame, _last_solved)   # 手/脸丢帧时保持上一帧，别弹回静止
		if r.is_empty():
			continue
		_last_solved = Mocap.smooth(_last_solved, r, LIVE_SMOOTH)
		got = true
	if got:
		_pose = (_last_solved["bones"] as Dictionary).duplicate()
		_shape_pose = (_last_solved["shapes"] as Dictionary).duplicate()
		_refresh_sliders()


## 录制：实时姿势按真实时间落成逐帧关键帧，录到总帧数为止
func _record(delta: float) -> void:
	_rec_t += delta
	var f := int(_rec_t * AnimBaker.FPS)
	if f >= _len:
		_toggle_record()
		_show_hint("录满 %d 帧了。想留得住细节就直接导出；想手改先按「抽稀」" % _len)
		return
	if f == _rec_last or _last_solved.is_empty():
		return
	_rec_last = f
	_keys[f] = _snapshot()
	if not _shape_pose.is_empty():
		_shapes[f] = _shape_pose.duplicate()
	_playhead = float(f)
	_redraw_timeline()


func _toggle_record() -> void:
	if not _live:
		_show_hint("先开「实时动补」")
		return
	_recording = not _recording
	_rec_btn.text = "■ 停止录制" if _recording else "● 录制"
	if _recording:
		_keys.clear()
		_shapes.clear()
		_roots.clear()
		_spans.clear()
		_rec_t = 0.0
		_rec_last = -1
		_show_hint("录制中……对着摄像头做动作，录满 %d 帧自动停" % _len)


## 离线导入：capture.py 跑视频吐出来的关键点文件 → 逐帧关键帧
func _import_mocap() -> void:
	var file := _mocap_opt.get_item_text(_mocap_opt.selected) if _mocap_opt.item_count > 0 else ""
	if file.is_empty():
		_show_hint("animations/mocap/ 里没有关键点文件——先跑 capture.py --video xxx.mp4 --out 名字")
		return
	var data = JSON.parse_string(
		FileAccess.get_file_as_string("%s/%s" % [MOCAP_DIR, file]))
	if not (data is Dictionary) or not data.has("frames"):
		_show_hint("读不懂 %s" % file)
		return
	_stop_live()
	var src_frames: Array = data["frames"]
	var src_fps := float(data.get("fps", 30.0))
	# 源视频不一定是 30fps，按时间重采样到时间轴的 30fps
	var n := mini(int(src_frames.size() * AnimBaker.FPS / src_fps), MAX_FRAMES)
	_keys.clear()
	_shapes.clear()
	_roots.clear()
	_spans.clear()
	var prev := {}
	var miss := 0
	for i in range(n):
		var src := mini(int(i * src_fps / AnimBaker.FPS), src_frames.size() - 1)
		var r := _mocap.solve(src_frames[src], prev)   # 手/脸丢帧时保持上一帧，别弹回静止
		if r.is_empty():
			miss += 1
			continue                     # 这一帧没认出人，跳过（补间会把这个洞连起来）
		r = Mocap.smooth(prev, r, IMPORT_SMOOTH)
		prev = r
		_keys[i] = (r["bones"] as Dictionary).duplicate()
		if not (r["shapes"] as Dictionary).is_empty():
			_shapes[i] = (r["shapes"] as Dictionary).duplicate()
	if _keys.is_empty():
		_show_hint("%s 里一帧人都没认出来" % file)
		return
	_len = maxi(n, 2)
	_len_edit.text = str(_len)
	_sel_a = -1
	_sel_b = -1
	_goto_frame(0)
	_show_hint("已导入 %s：%d 帧关键帧%s。想手改先按「抽稀」"
		% [file, _keys.size(), "（%d 帧没认出人，已跳过）" % miss if miss > 0 else ""])


## 抽稀：逐帧关键帧 → 只在转折处留关键帧，中间交给补间（动补录完必备，不然改不动）
func _decimate() -> void:
	var before := _keys.size()
	if before < 3:
		_show_hint("关键帧太少，不用抽稀")
		return
	_keys = AnimBaker.decimate(_keys, DECIMATE_DEG)
	var kept := {}
	var kept_roots := {}
	for f in _keys:
		if _shapes.has(f):
			kept[f] = _shapes[f]
		if _roots.has(f):
			kept_roots[f] = _roots[f]
	_shapes = kept
	_roots = kept_roots
	_spans.clear()                       # 抽稀后全线性补间
	_goto_frame(_playhead)
	_show_hint("抽稀：%d → %d 个关键帧（骨骼偏差控制在 %.0f° 以内），现在可以手改了"
		% [before, _keys.size(), DECIMATE_DEG])


# ---------------------------------------------------------------- 关键帧 / 补间

func _insert_key() -> void:
	var f := int(round(_playhead))
	_keys[f] = _snapshot()
	if not _shape_pose.is_empty():
		_shapes[f] = _shape_pose.duplicate()
	# 胯没挪过就别开这条轨道——一旦有了 roots，导出就会多一条 position_3d 轨道，
	# 那会盖掉母项目里角色自己的位移
	if _root_off != Vector3.ZERO or not _roots.is_empty():
		_roots[f] = _root_off
	_redraw_timeline()


func _delete_key() -> void:
	var f := int(round(_playhead))
	_keys.erase(f)
	_shapes.erase(f)
	_roots.erase(f)
	_spans.erase(f)
	_goto_frame(_playhead)


func _goto_frame(f: float) -> void:
	_playhead = clampf(f, 0.0, float(_len - 1))
	_pose = _pose_at(_playhead)
	_root_off = AnimBaker.sample_root(_roots, _playhead, _spans)
	_shape_pose = AnimBaker.sample_shapes(_shapes, _playhead, _spans).duplicate()
	_refresh_sliders()
	_redraw_timeline()


func _set_playing(on: bool) -> void:
	_playing = on and not _keys.is_empty()
	_play_btn.text = "⏸ 暂停" if _playing else "▶ 播放"
	if not _playing:
		_goto_frame(_playhead)


## 程序化地「点一帧」——等价于在时间轴上点击（Shift 点击 = extend）。
## 时间轴控件自己会发信号，这个函数是给自检脚本和工具脚本用的入口。
func _click_frame(f: int, extend: bool) -> void:
	if extend and _sel_a >= 0:
		_sel_b = f
	else:
		_sel_a = f
		_sel_b = f
	_set_playing(false)
	_goto_frame(float(f))


## 「创建补间」：选区两端没关键帧就按当前采样姿势补上，区间内每一段挂上缓动曲线
func _make_tween() -> void:
	var a := mini(_sel_a, _sel_b)
	var b := maxi(_sel_a, _sel_b)
	if a < 0 or a == b:
		_show_hint("先选一段：点起始帧，按住 Shift 点结束帧")
		return
	for f in [a, b]:
		if not _keys.has(f):
			_keys[f] = _pose_at(float(f))
	var e := _ease_opt.selected
	var n := 0
	for f in AnimBaker.sorted_frames(_keys):
		if f >= a and f < b:
			_spans[f] = e
			n += 1
	_goto_frame(_playhead)
	_show_hint("第 %d–%d 帧已建立「%s」补间（%d 段）" % [a + 1, b + 1, AnimBaker.EASE_NAMES[e], n])


# ---------------------------------------------------------------- 存读 / 导出

func _save_project() -> void:
	var n := _name_edit.text.strip_edges()
	if n.is_empty() or _keys.is_empty():
		_show_hint("先起个动作名并至少插一个关键帧")
		return
	var existed := FileAccess.file_exists(AnimBaker.project_path(n))
	if not AnimBaker.save_project(n, _keys, _len, _loop, _spans, _shapes, _roots):
		_show_hint("保存失败")
		return
	_show_hint("%s工程「%s」（%d 个关键帧）"
		% ["⚠ 已覆盖" if existed else "已保存", n, _keys.size()])


func _load_project() -> void:
	var n := _name_edit.text.strip_edges()
	var data := AnimBaker.load_project(n)
	if not data["ok"]:
		_show_hint("找不到工程「%s」" % n)
		return
	_stop_live()
	_keys = data["keys"]
	_spans = data["spans"]
	_shapes = data["shapes"]
	_roots = data["roots"]
	_len = data["length"]
	_loop = data["loop"]
	_loop_cb.set_pressed_no_signal(_loop)
	_len_edit.text = str(_len)
	_sel_a = -1
	_sel_b = -1
	_goto_frame(0)
	_show_hint("已读取工程「%s」（%d 个关键帧%s）"
		% [n, _keys.size(), "，含表情" if not _shapes.is_empty() else ""])


func _export_anim() -> void:
	var n := _name_edit.text.strip_edges()
	var path := AnimBaker.export_tres(n, _keys, _len, _loop, _spans, _shapes, _shape_node,
		_roots, _solver.rest_local_origin("Hips"))
	if path.is_empty():
		_show_hint("导出失败：需要动作名和至少一个关键帧")
		return
	AnimBaker.save_project(n, _keys, _len, _loop, _spans, _shapes, _roots)   # 顺手存工程
	_show_hint("已导出 %s（%d 帧轨道关键帧%s）" % [path,
		AnimBaker.bake_frames(_keys, _spans).size(),
		"，含表情轨道" if not _shapes.is_empty() else ""])


func _show_hint(text: String) -> void:
	_hint.text = text


# ---------------------------------------------------------------- UI 搭建

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = ClientTheme.make_theme()
	layer.add_child(ui)
	ClientTheme.plaque("动 作 工 房", Vector2(24, 14), Vector2(200, 40), ui)
	_build_topbar(ui)
	_build_mocap_bar(ui)
	_build_bone_panel(ui)
	_build_timeline(ui)


## 动补那一行（顶栏第二行，只占 3D 区上方那条，不碰右侧骨骼面板）
func _build_mocap_bar(ui: Control) -> void:
	var lbl := Label.new()
	lbl.text = "动补"
	lbl.position = Vector2(26, 62)
	lbl.add_theme_color_override("font_color", ClientTheme.ACCENT)
	ui.add_child(lbl)

	_mocap_opt = OptionButton.new()
	_mocap_opt.position = Vector2(70, 58)
	_mocap_opt.size = Vector2(200, 30)
	ClientTheme.style_button(_mocap_opt, 13)
	ui.add_child(_mocap_opt)
	_refresh_mocap_list()

	var imp := Button.new()
	imp.text = "导入视频动补"
	imp.position = Vector2(280, 58)
	imp.size = Vector2(120, 30)
	ClientTheme.style_button(imp, 13, true)
	imp.pressed.connect(_import_mocap)
	ui.add_child(imp)

	_live_btn = Button.new()
	_live_btn.text = "实时动补：关"
	_live_btn.position = Vector2(414, 58)
	_live_btn.size = Vector2(116, 30)
	ClientTheme.style_button(_live_btn, 13)
	_live_btn.pressed.connect(_toggle_live)
	ui.add_child(_live_btn)

	_rec_btn = Button.new()
	_rec_btn.text = "● 录制"
	_rec_btn.position = Vector2(538, 58)
	_rec_btn.size = Vector2(88, 30)
	ClientTheme.style_button(_rec_btn, 13)
	_rec_btn.pressed.connect(_toggle_record)
	ui.add_child(_rec_btn)

	var dec := Button.new()
	dec.text = "抽稀关键帧"
	dec.position = Vector2(640, 58)
	dec.size = Vector2(104, 30)
	ClientTheme.style_button(dec, 13)
	dec.pressed.connect(_decimate)
	ui.add_child(dec)

	var tip := Label.new()
	tip.text = "python tools/mocap/capture.py  ──  视频：--video x.mp4 --out 名字 ｜ 电脑摄像头：--camera 0 ｜ 手机：--phone"
	tip.position = Vector2(758, 63)
	tip.add_theme_font_size_override("font_size", 12)
	tip.add_theme_color_override("font_color", ClientTheme.TEXT_DIM)
	ui.add_child(tip)


func _refresh_mocap_list() -> void:
	_mocap_opt.clear()
	var dir := DirAccess.open(MOCAP_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		var fname := (f as String).trim_suffix(".remap")
		if fname.ends_with(".mocap.json"):
			_mocap_opt.add_item(fname)


func _build_topbar(ui: Control) -> void:
	_name_edit = LineEdit.new()
	_name_edit.position = Vector2(250, 18)
	_name_edit.size = Vector2(200, 34)
	_name_edit.text = "新动作"
	_name_edit.placeholder_text = "动作名"
	ClientTheme.style_line_edit(_name_edit)
	ui.add_child(_name_edit)
	var cfgs := [["保存工程", 462.0, _save_project], ["读取工程", 568.0, _load_project],
		["导出动画", 674.0, _export_anim]]
	for cfg in cfgs:
		var btn := Button.new()
		btn.text = cfg[0]
		btn.position = Vector2(cfg[1], 18)
		btn.size = Vector2(96, 34)
		ClientTheme.style_button(btn, 14, cfg[0] == "导出动画")
		btn.pressed.connect(cfg[2])
		ui.add_child(btn)
	var wp := Button.new()
	wp.text = "武器：无"
	wp.position = Vector2(780, 18)
	wp.size = Vector2(106, 34)
	ClientTheme.style_button(wp, 14)
	wp.pressed.connect(func():
		_weapon_on = not _weapon_on
		wp.text = "武器：战矛" if _weapon_on else "武器：无"
		if _weapon_on:
			Weapons.equip(skeleton, "战矛")
		else:
			Weapons.unequip(skeleton))
	ui.add_child(wp)
	_hint = Label.new()
	_hint.position = Vector2(900, 24)
	_hint.size = Vector2(680, 24)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", ClientTheme.TEXT_DIM)
	ui.add_child(_hint)


func _build_bone_panel(ui: Control) -> void:
	var panel := Panel.new()
	panel.position = Vector2(PANEL_X, 66)
	panel.size = Vector2(296, 664)
	panel.add_theme_stylebox_override("panel",
		ClientTheme.tech_style(Color(0.10, 0.025, 0.025, 0.85)))
	ui.add_child(panel)
	var title := Label.new()
	title.text = "骨骼树"
	title.position = Vector2(12, 8)
	title.add_theme_color_override("font_color", ClientTheme.ACCENT)
	panel.add_child(title)

	_tree = Tree.new()
	_tree.position = Vector2(10, 36)
	_tree.size = Vector2(276, 396)
	_tree.hide_root = true
	_tree.allow_reselect = true
	ClientTheme.style_tree(_tree)
	_tree.item_selected.connect(_on_tree_selected)
	panel.add_child(_tree)
	_build_bone_tree()

	_sel_lbl = Label.new()
	_sel_lbl.position = Vector2(12, 440)
	_sel_lbl.add_theme_color_override("font_color", ClientTheme.ACCENT)
	panel.add_child(_sel_lbl)

	var axis_y := 470.0
	for axis in ["x", "y", "z"]:
		var al := Label.new()
		al.text = axis.to_upper()
		al.position = Vector2(12, axis_y + 2)
		al.add_theme_color_override("font_color", BoneOverlay.AXIS_COLORS[["x", "y", "z"].find(axis)])
		panel.add_child(al)
		var sl := HSlider.new()
		sl.min_value = -180
		sl.max_value = 180
		sl.step = 1
		sl.position = Vector2(36, axis_y)
		sl.size = Vector2(190, 24)
		sl.value_changed.connect(_on_slider_changed)
		panel.add_child(sl)
		_sliders[axis] = sl
		var vl := Label.new()
		vl.text = "0°"
		vl.position = Vector2(234, axis_y + 2)
		vl.add_theme_color_override("font_color", ClientTheme.TECH_TEXT)
		panel.add_child(vl)
		_slider_vals[axis] = vl
		axis_y += 34

	var rb := Button.new()
	rb.text = "复位本骨骼"
	rb.position = Vector2(10, 578)
	rb.size = Vector2(134, 32)
	ClientTheme.style_button(rb, 13)
	rb.pressed.connect(_reset_bone)
	panel.add_child(rb)
	var ra := Button.new()
	ra.text = "复位全身"
	ra.position = Vector2(152, 578)
	ra.size = Vector2(134, 32)
	ClientTheme.style_button(ra, 13)
	ra.pressed.connect(_reset_all)
	panel.add_child(ra)

	_ik_btn = Button.new()
	_ik_btn.text = "拖拽：整体 IK"
	_ik_btn.position = Vector2(10, 618)
	_ik_btn.size = Vector2(180, 34)
	ClientTheme.style_button(_ik_btn, 14, true)
	_ik_btn.pressed.connect(func():
		_full_ik = not _full_ik
		_ik_btn.text = "拖拽：整体 IK" if _full_ik else "拖拽：单骨 FK"
		ClientTheme.style_button(_ik_btn, 14, _full_ik)
		_show_hint("拖一根骨头，从胯到它的整条链一起解（手臂先动，够不着才弯腰）" if _full_ik
			else "只转被拖的那一根骨头，别的一动不动"))
	panel.add_child(_ik_btn)
	_feet_cb = CheckBox.new()
	_feet_cb.text = "锁脚"
	_feet_cb.position = Vector2(200, 620)
	_feet_cb.set_pressed_no_signal(true)
	_feet_cb.add_theme_color_override("font_color", ClientTheme.TECH_TEXT)
	_feet_cb.toggled.connect(func(on): _pin_feet = on)
	panel.add_child(_feet_cb)


## 骨骼树：按人形父子关系建（手指默认折叠，不然一屏塞不下）
func _build_bone_tree() -> void:
	var parents := HumanoidBones.humanoid_parents(skeleton, _bones)
	var root := _tree.create_item()
	_tree_items.clear()
	for bname in HumanoidBones.humanoid_names():   # 父在前子在后
		if not _bones.has(bname):
			continue
		var parent_item: TreeItem = _tree_items.get(parents.get(bname, ""), root)
		var item := _tree.create_item(parent_item)
		item.set_text(0, bname)
		item.set_metadata(0, bname)
		_tree_items[bname] = item
	for side in ["Left", "Right"]:
		if _tree_items.has(side + "Hand"):
			(_tree_items[side + "Hand"] as TreeItem).collapsed = true


func _build_timeline(ui: Control) -> void:
	var bar := Panel.new()
	bar.position = Vector2(16, TL_Y)
	bar.size = Vector2(1568, 140)
	bar.add_theme_stylebox_override("panel",
		ClientTheme.tech_style(Color(0.10, 0.025, 0.025, 0.85)))
	ui.add_child(bar)

	_play_btn = Button.new()
	_play_btn.text = "▶ 播放"
	_play_btn.position = Vector2(12, 10)
	_play_btn.size = Vector2(92, 34)
	ClientTheme.style_button(_play_btn, 14, true)
	_play_btn.pressed.connect(func(): _set_playing(not _playing))
	bar.add_child(_play_btn)
	var head_btn := Button.new()
	head_btn.text = "⏮ 回首帧"
	head_btn.position = Vector2(112, 10)
	head_btn.size = Vector2(92, 34)
	ClientTheme.style_button(head_btn, 14)
	head_btn.pressed.connect(func():
		_set_playing(false)
		_goto_frame(0))
	bar.add_child(head_btn)
	var key_btn := Button.new()
	key_btn.text = "◆ 插关键帧 (F6)"
	key_btn.position = Vector2(212, 10)
	key_btn.size = Vector2(142, 34)
	ClientTheme.style_button(key_btn, 14)
	key_btn.pressed.connect(_insert_key)
	bar.add_child(key_btn)
	var del_btn := Button.new()
	del_btn.text = "✕ 删关键帧"
	del_btn.position = Vector2(362, 10)
	del_btn.size = Vector2(106, 34)
	ClientTheme.style_button(del_btn, 14)
	del_btn.pressed.connect(_delete_key)
	bar.add_child(del_btn)

	_ease_opt = OptionButton.new()
	for n in AnimBaker.EASE_NAMES:
		_ease_opt.add_item(n)
	_ease_opt.selected = AnimBaker.Ease.IN_OUT
	_ease_opt.position = Vector2(490, 10)
	_ease_opt.size = Vector2(110, 34)
	ClientTheme.style_button(_ease_opt, 14)
	bar.add_child(_ease_opt)
	var tw_btn := Button.new()
	tw_btn.text = "⇥ 创建补间"
	tw_btn.position = Vector2(608, 10)
	tw_btn.size = Vector2(112, 34)
	ClientTheme.style_button(tw_btn, 14, true)
	tw_btn.pressed.connect(_make_tween)
	bar.add_child(tw_btn)

	_loop_cb = CheckBox.new()
	_loop_cb.text = "循环"
	_loop_cb.position = Vector2(740, 12)
	_loop_cb.set_pressed_no_signal(true)
	_loop_cb.add_theme_color_override("font_color", ClientTheme.TECH_TEXT)
	_loop_cb.toggled.connect(func(on): _loop = on)
	bar.add_child(_loop_cb)
	var len_lbl := Label.new()
	len_lbl.text = "总帧数"
	len_lbl.position = Vector2(826, 16)
	len_lbl.add_theme_color_override("font_color", ClientTheme.TECH_TEXT)
	bar.add_child(len_lbl)
	_len_edit = LineEdit.new()
	_len_edit.text = str(_len)
	_len_edit.position = Vector2(882, 12)
	_len_edit.size = Vector2(58, 30)
	ClientTheme.style_line_edit(_len_edit)
	_len_edit.text_submitted.connect(func(t):
		_len = clampi(int(t), 2, MAX_FRAMES)
		_len_edit.text = str(_len)
		_goto_frame(minf(_playhead, _len - 1)))
	bar.add_child(_len_edit)
	_frame_lbl = Label.new()
	_frame_lbl.position = Vector2(960, 16)
	_frame_lbl.add_theme_color_override("font_color", ClientTheme.ACCENT)
	bar.add_child(_frame_lbl)

	_timeline = Timeline.new()
	_timeline.position = Vector2(12, 54)
	_timeline.size = Vector2(1544, 62)
	_timeline.length = _len
	_timeline.keys = _keys
	_timeline.spans = _spans
	_timeline.scrubbed.connect(_on_scrub)
	_timeline.key_moved.connect(_move_key)
	_timeline.selection_changed.connect(_on_tl_selection)
	_timeline.menu_requested.connect(_on_tl_menu)
	bar.add_child(_timeline)

	# 右键菜单（Animate 里那套「插入关键帧 / 创建补间…」）
	_tl_menu = PopupMenu.new()
	for item in ["◆ 插入关键帧", "✕ 删除关键帧", "", "⇥ 用当前缓动创建补间", "清除补间（改回线性）"]:
		if item.is_empty():
			_tl_menu.add_separator()
		else:
			_tl_menu.add_item(item)
	_tl_menu.id_pressed.connect(_on_tl_menu_pick)
	_timeline.add_child(_tl_menu)
	_redraw_timeline()


# ---------------------------------------------------------------- 时间轴回调

## 拖播放头擦帧：只移播放头，不落关键帧
func _on_scrub(f: float) -> void:
	_set_playing(false)
	_goto_frame(f)


func _on_tl_selection(a: int, b: int) -> void:
	_sel_a = a
	_sel_b = b
	_redraw_timeline()


## 拖动关键帧搬家：姿势、补间区间、表情、胯位移都要跟着一起搬，落点上有旧关键帧就覆盖
func _move_key(from_frame: int, to_frame: int) -> void:
	if not _keys.has(from_frame) or from_frame == to_frame:
		return
	for d in [_keys, _shapes, _roots, _spans]:
		if (d as Dictionary).has(from_frame):
			(d as Dictionary)[to_frame] = (d as Dictionary)[from_frame]
			(d as Dictionary).erase(from_frame)
	_goto_frame(float(to_frame))
	_show_hint("关键帧 %d → %d" % [from_frame + 1, to_frame + 1])


func _on_tl_menu(frame: int, screen_pos: Vector2) -> void:
	_tl_menu_frame = frame
	_tl_menu.position = Vector2i(screen_pos)
	_tl_menu.reset_size()
	_tl_menu.popup()


func _on_tl_menu_pick(id: int) -> void:
	var f := _tl_menu_frame
	match id:
		0:
			_goto_frame(float(f))
			_insert_key()
			_show_hint("已在第 %d 帧插入关键帧" % (f + 1))
		1:
			_goto_frame(float(f))
			_delete_key()
			_show_hint("已删除第 %d 帧的关键帧" % (f + 1))
		3:
			_make_tween()
		4:
			for k in AnimBaker.sorted_frames(_keys):
				if _sel_a >= 0 and k >= mini(_sel_a, _sel_b) and k < maxi(_sel_a, _sel_b):
					_spans.erase(k)
			_redraw_timeline()
			_show_hint("选区内的补间已改回线性")


## 刷新时间轴（数据变了就调它；控件自己负责画）
func _redraw_timeline() -> void:
	if _timeline == null:
		return
	_last_drawn_frame = int(_playhead)
	_timeline.length = _len
	_timeline.keys = _keys
	_timeline.spans = _spans
	_timeline.playhead = _playhead
	_timeline.sel_a = _sel_a
	_timeline.sel_b = _sel_b
	_timeline.refresh()
	if _frame_lbl != null:
		var lo := mini(_sel_a, _sel_b) if _sel_a >= 0 else -1
		var hi := maxi(_sel_a, _sel_b) if _sel_a >= 0 else -2
		var sel_txt := "｜选区 %d–%d" % [lo + 1, hi + 1] if lo >= 0 and hi > lo else ""
		_frame_lbl.text = "帧 %d / %d ｜ 关键帧 %d 个%s" % [_last_drawn_frame + 1, _len,
			_keys.size(), sel_txt]
