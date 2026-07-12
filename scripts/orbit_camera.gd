class_name OrbitCamera
extends Camera3D
## 环绕相机：右键拖拽旋转、滚轮缩放、中键拖拽平移、Q/E 升降。
## （左键留给普通攻击 / UI 操作）

var focus := Vector3(0, 1.0, 0)
var distance := 2.6
var yaw := 0.0          # 弧度，0 = 正面
var pitch := deg_to_rad(-5.0)
var auto_rotate := false
## 相机横向平移（米，正值把画面里的模型推到左边给右侧面板让位）。
## 只挪相机自身位置、不动 focus——环绕依旧绕着模型转，而且相机变换是真的，
## unproject_position / project_ray_normal 的骨骼拾取跟着一起对。
var lateral := 0.0

var _dragging := false
var _panning := false

const MIN_DIST := 0.6
const MAX_DIST := 8.0
const MIN_PITCH := deg_to_rad(-80.0)
const MAX_PITCH := deg_to_rad(80.0)
const MIN_FOCUS_Y := -0.5      # 允许压到台面以下（平台会自动透明化）
const MAX_FOCUS_Y := 2.4
const LIFT_SPEED := 1.2        # Q/E 升降速度 米/秒


func _ready() -> void:
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_dragging = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					distance = clampf(distance * 0.9, MIN_DIST, MAX_DIST)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					distance = clampf(distance * 1.1, MIN_DIST, MAX_DIST)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			yaw -= mm.relative.x * 0.008
			pitch = clampf(pitch - mm.relative.y * 0.008, MIN_PITCH, MAX_PITCH)
		elif _panning:
			var right := global_transform.basis.x
			var up := global_transform.basis.y
			focus += (-right * mm.relative.x + up * mm.relative.y) * distance * 0.0015
			focus.y = clampf(focus.y, MIN_FOCUS_Y, MAX_FOCUS_Y)


func _process(delta: float) -> void:
	if auto_rotate and not _dragging:
		yaw += delta * 0.4
	var lift := 0.0
	if Input.is_physical_key_pressed(KEY_E):
		lift += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		lift -= 1.0
	if lift != 0.0:
		focus.y = clampf(focus.y + lift * LIFT_SPEED * delta, MIN_FOCUS_Y, MAX_FOCUS_Y)
	_update_transform()


func _update_transform() -> void:
	var rot := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var offset := rot * Vector3(lateral, 0, distance)
	global_transform = Transform3D(rot, focus + offset)
