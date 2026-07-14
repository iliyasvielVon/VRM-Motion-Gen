"""动作工房的动补采集端：MediaPipe HolisticLandmarker → 身体 + 双手 + 表情。

Godot 里没有 ML 推理（没有 ONNX / GDExtension），所以姿态估计放在这个 Python 边车里，
Godot 只负责把关键点重定向成骨骼旋转。两种用法共用同一套输出格式：

    # 离线：把视频跑成关键点文件，Godot 里「导入动补」读它
    python capture.py --video dance.mp4 --out 圆舞

    # 实时：电脑摄像头 → UDP 喷给 Godot，模型实时跟着动，Godot 里按「录制」落关键帧
    python capture.py --camera 0

    # 实时：拿手机当摄像头（手机浏览器打开一个网页即可，不用装 App）
    python capture.py --phone

    # 实时：手机装了 IP 摄像头类 App（DroidCam / IP Webcam / 任意 RTSP 源）
    python capture.py --url http://192.168.1.7:8080/video

    # 实时的同时也存一份文件
    python capture.py --camera 0 --out 试拍

输出坐标系已经转成 **Godot 空间**（Y 上、模型朝 +Z、单位米、原点在胯心）：
MediaPipe 的世界关键点是 X 右 / Y 下 / Z 越小越靠近镜头，所以 (x, -y, -z)。
这个映射的行列式是 +1，不会把左右手镜像反。

预览窗口按 Q 或 ESC 退出。
"""

import argparse
import json
import shutil
import socket
import sys
import time
import urllib.request
from pathlib import Path

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent.parent                      # tools/mocap → 项目根
MODEL = HERE / "models" / "holistic_landmarker.task"
OUT_DIR = PROJECT / "animations" / "mocap"

# 只送 Godot 那边真正会用到的表情通道（ARKit 52 里挑出来的），省带宽也省得对不上
BLENDSHAPES = [
    "eyeBlinkLeft", "eyeBlinkRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight", "jawOpen", "mouthPucker", "mouthFunnel",
    "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthStretchLeft", "mouthStretchRight", "mouthPressLeft", "mouthPressRight",
    "browInnerUp", "browDownLeft", "browDownRight", "browOuterUpLeft", "browOuterUpRight",
]

# 预览窗口画骨架用的连线（MediaPipe pose 的 33 点）
POSE_EDGES = [
    (11, 12), (11, 13), (13, 15), (12, 14), (14, 16),
    (11, 23), (12, 24), (23, 24),
    (23, 25), (25, 27), (27, 31), (24, 26), (26, 28), (28, 32),
]
HAND_EDGES = [
    (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8),
    (0, 9), (9, 10), (10, 11), (11, 12), (0, 13), (13, 14), (14, 15), (15, 16),
    (0, 17), (17, 18), (18, 19), (19, 20), (5, 9), (9, 13), (13, 17),
]


def to_godot(landmarks):
    """MediaPipe 世界关键点 → Godot 空间的 [x, y, z] 列表（四位小数够用，JSON 也小）"""
    if not landmarks:
        return None
    return [[round(p.x, 4), round(-p.y, 4), round(-p.z, 4)] for p in landmarks]


def pick_blendshapes(categories):
    if not categories:
        return None
    got = {c.category_name: c.score for c in categories}
    return {n: round(got[n], 4) for n in BLENDSHAPES if n in got and got[n] > 0.001}


MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/holistic_landmarker/"
    "holistic_landmarker/float16/latest/holistic_landmarker.task"
)


def ensure_model():
    """首次运行时自动下 MediaPipe 的模型权重（13MB）。

    权重是 Google 的（Apache-2.0），不跟着仓库走：一来没必要让每个 clone 都背 13MB，
    二来不替别人分发权重更省事。下一次就直接命中本地文件了。
    """
    if MODEL.exists():
        return
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    print("首次运行，下载 MediaPipe 模型（13MB）→ %s" % MODEL)
    tmp = MODEL.with_suffix(".part")
    try:
        with urllib.request.urlopen(MODEL_URL, timeout=60) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f)
        tmp.replace(MODEL)          # 下完再改名：中途断网不会留下一个半截的模型文件
    except Exception as e:
        tmp.unlink(missing_ok=True)
        sys.exit("下载失败（%s）。手动下：\n  curl -L -o %s \\\n    %s" % (e, MODEL, MODEL_URL))
    print("模型就绪")


def make_landmarker():
    ensure_model()
    opts = vision.HolisticLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=str(MODEL)),
        running_mode=vision.RunningMode.VIDEO,   # 摄像头也走 VIDEO 模式：同步、时序稳定、代码简单
        output_face_blendshapes=True,
        min_pose_detection_confidence=0.5,
        min_pose_landmarks_confidence=0.5,
        min_hand_landmarks_confidence=0.5,
    )
    return vision.HolisticLandmarker.create_from_options(opts)


def draw_preview(bgr, result):
    h, w = bgr.shape[:2]

    def px(lm):
        return int(lm.x * w), int(lm.y * h)

    if result.pose_landmarks:
        for a, b in POSE_EDGES:
            cv2.line(bgr, px(result.pose_landmarks[a]), px(result.pose_landmarks[b]),
                     (120, 220, 255), 2)
        for lm in result.pose_landmarks:
            cv2.circle(bgr, px(lm), 3, (60, 160, 255), -1)
    for hand in (result.left_hand_landmarks, result.right_hand_landmarks):
        if hand:
            for a, b in HAND_EDGES:
                cv2.line(bgr, px(hand[a]), px(hand[b]), (160, 255, 160), 1)
    return bgr


def run_phone(args, landmarker, sock, addr, frames):
    """手机模式：手机浏览器把 JPEG 帧经 WebSocket 传过来，这边解码 → 识别 → UDP 给 Godot"""
    import numpy as np

    import phone

    t0 = time.time()
    state = {"n": 0}

    def on_frame(jpeg: bytes):
        bgr = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        if bgr is None:
            return
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = landmarker.detect_for_video(image, int((time.time() - t0) * 1000))
        frame = pack(result)
        if args.out:
            frames.append(frame)
        sock.sendto(json.dumps(frame, separators=(",", ":")).encode("utf-8"), addr)
        state["n"] += 1
        if state["n"] % 30 == 0:
            hit = "认出人了" if frame["pose"] else "没认出人（全身入镜？光够亮吗？）"
            print("  已收 %d 帧 · %s" % (state["n"], hit))

    phone.serve(on_frame)


def pack(result) -> dict:
    return {
        "pose": to_godot(result.pose_world_landmarks),
        "lh": to_godot(result.left_hand_world_landmarks),
        "rh": to_godot(result.right_hand_world_landmarks),
        "bs": pick_blendshapes(result.face_blendshapes),
    }


def main():
    ap = argparse.ArgumentParser(description="动作工房动补采集")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--video", help="视频文件路径（离线跑）")
    src.add_argument("--camera", type=int, help="电脑摄像头编号（实时，一般是 0）")
    src.add_argument("--phone", action="store_true",
                     help="拿手机当摄像头：手机浏览器打开网页即可，不用装 App")
    src.add_argument("--url", help="网络摄像头流地址（DroidCam / IP Webcam / RTSP 都行）")
    ap.add_argument("--out", help="存成 animations/mocap/<名>.mocap.json")
    ap.add_argument("--udp", default="127.0.0.1:9977", help="实时模式喷给 Godot 的地址")
    ap.add_argument("--fps", type=float, default=30.0, help="摄像头模式的目标帧率")
    ap.add_argument("--no-preview", action="store_true", help="不开预览窗口")
    args = ap.parse_args()

    live = args.camera is not None or args.phone or args.url is not None

    sock = None
    addr = None
    if live:
        host, port = args.udp.split(":")
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        addr = (host, int(port))
        print("实时动补 → UDP %s:%s（Godot 里开「实时动补」接收）" % (host, port))

    landmarker = make_landmarker()
    frames = []

    if args.phone:
        try:
            run_phone(args, landmarker, sock, addr, frames)
        except KeyboardInterrupt:
            pass
        finish(args, frames, 30.0, "phone")
        return

    source = args.camera if args.camera is not None else (args.url or args.video)
    cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        sys.exit("打不开：%s" % source)

    fps = args.fps if live else (cap.get(cv2.CAP_PROP_FPS) or 30.0)
    total = 0 if live else int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    n = 0
    t0 = time.time()

    while True:
        ok, bgr = cap.read()
        if not ok:
            break
        if args.camera is not None:
            bgr = cv2.flip(bgr, 1)   # 电脑摄像头是镜子：抬右手，屏幕上的模型也抬右手
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        ts = int((time.time() - t0) * 1000) if live else int(n / fps * 1000)
        result = landmarker.detect_for_video(image, ts)

        frame = pack(result)
        if args.out:
            frames.append(frame)
        if sock:
            sock.sendto(json.dumps(frame, separators=(",", ":")).encode("utf-8"), addr)

        n += 1
        if not args.no_preview:
            draw_preview(bgr, result)
            tag = "REC %d" % len(frames) if args.out else ("LIVE" if live else "%d/%d" % (n, total))
            cv2.putText(bgr, tag, (12, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (80, 220, 255), 2)
            cv2.imshow("mocap (Q/ESC 退出)", bgr)
            if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                break
        elif not live and n % 30 == 0:
            print("  %d/%d 帧" % (n, total))

    cap.release()
    cv2.destroyAllWindows()
    finish(args, frames, fps, str(source))


def finish(args, frames, fps, source):
    if not args.out or not frames:
        return
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / ("%s.mocap.json" % args.out)
    hit = sum(1 for f in frames if f["pose"])
    path.write_text(json.dumps({
        "fps": round(fps, 3), "source": source, "frames": frames,
    }, ensure_ascii=False), encoding="utf-8")
    print("写出 %s（%d 帧，其中 %d 帧认出了人）" % (path, len(frames), hit))
    if hit < len(frames) * 0.5:
        print("  ⚠ 一半以上的帧没认出人：确认画面里是全身入镜、光照够亮")


if __name__ == "__main__":
    main()
