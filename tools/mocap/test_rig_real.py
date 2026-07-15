# -*- coding: utf-8 -*-
"""多相机融合的「真管线」自检：真实 MediaPipe，两个已知夹角的机位。

test_rig.py 的合成测试只考融合的数学；这个考的是它建立在其上的**前提**——
MediaPipe 世界关键点的朝向是不是跟着相机走。素材是 tools/render_rig.gd 从 0° 和 65°
两个机位渲染的同一段动作：把两路画面各自过 MediaPipe 再喂进 Rig。

实测结论（本测试钉死的就是这些）：朝向**大体**跟着相机走，但 MediaPipe 对侧视的人
有系统性「转正」偏置——65° 机位的肩线只测出 ~55°，叠加侧视深度压扁，Kabsch 解出
~41°。所以标定的本质是「两台相机自洽的对齐」而非精确物理角度；断言按这个现实写：
角度量级正确（25°~73°，镜像/错人会落在 0° 或 180°）、旋转轴竖直、修剪残差 ≤10cm。

    先渲染素材（两条命令）：
      godot --path . --script res://tools/render_rig.gd --resolution 720x1280 -- --yaw 0
      godot --path . --script res://tools/render_rig.gd --resolution 720x1280 -- --yaw 65
    再跑：
      python tools/mocap/test_rig_real.py
"""

import math
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402  复用真实的 pack/to_godot 转换，别在测试里抄一份
import mediapipe as mp  # noqa: E402
from rig import CAL_FRAMES, CAL_RMS_OK, Rig  # noqa: E402

YAW_TRUE = 65.0
TICK = 1.0 / 30.0

fails = 0


def ok(cond, what):
    global fails
    print("  %s  %s" % ("PASS" if cond else "FAIL", what))
    if not cond:
        fails += 1


def frames_of(view_dir):
    files = sorted(view_dir.glob("*.png"))
    if not files:
        sys.exit("缺素材 %s：先跑 render_rig.gd（见文件头）" % view_dir)
    return [cv2.imread(str(f)) for f in files]


def main():
    user = Path.home() / "AppData/Roaming/Godot/app_userdata/VRM Motion Gen"
    imgs_a = frames_of(user / "rig_0")
    imgs_b = frames_of(user / "rig_65")

    print("[识别两路机位（真实 MediaPipe）]")
    lm_a, lm_b = capture.make_landmarker(), capture.make_landmarker()
    packs_a, packs_b = [], []
    for i, (ia, ib) in enumerate(zip(imgs_a, imgs_b)):
        ms = i * 33
        ra = lm_a.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                            data=cv2.cvtColor(ia, cv2.COLOR_BGR2RGB)), ms)
        rb = lm_b.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                            data=cv2.cvtColor(ib, cv2.COLOR_BGR2RGB)), ms)
        packs_a.append(capture.pack(ra))
        packs_b.append(capture.pack(rb))
    hit_a = sum(1 for p in packs_a if p["pose"])
    hit_b = sum(1 for p in packs_b if p["pose"])
    ok(hit_a >= 30, "正面机位认出 %d/%d 帧" % (hit_a, len(packs_a)))
    ok(hit_b >= 25, "65° 侧面机位认出 %d/%d 帧" % (hit_b, len(packs_b)))

    print("\n[标定：真实管线下解出机位夹角]")
    events = []
    rig = Rig(on_event=events.append)
    t = 0.0
    n = len(packs_a)
    # 先让正面机位独跑几帧站稳参考位——正面第 0 帧可能恰好没认出人，直接双路齐喂的话
    # 侧面机位会抢先当上参考相机（这也复刻了「先开一台、中途加入第二台」的真实顺序）
    warm = 0
    for i in range(n):
        if packs_a[i]["pose"]:
            t += TICK
            rig.push("A", packs_a[i], t)
            rig.fuse(t)
            warm += 1
            if warm >= 3:
                break
    ok(rig.cams["A"].is_ref, "正面机位先入场，成为参考相机")
    for k in range(max(CAL_FRAMES * 3, n * 3)):     # 序列循环喂，攒够标定帧数
        t += TICK
        i = k % n
        if packs_a[i]["pose"]:
            rig.push("A", packs_a[i], t)
        if packs_b[i]["pose"]:
            rig.push("B", packs_b[i], t)
        fused, status = rig.fuse(t)
    st_b = next((e for e in status if e["id"] == "B"), None)
    ok(st_b is not None and st_b["st"] == "on" and not st_b["ref"],
       "侧面机位标定完成并启用（%s）" % ([e for e in events if "标定" in e][-1:] or st_b))
    if st_b and st_b["st"] == "on":
        R = rig.cams["B"].R
        angle = math.degrees(math.acos(np.clip((np.trace(R) - 1.0) / 2.0, -1.0, 1.0)))
        w, v = np.linalg.eigh((R + R.T) / 2.0)      # 旋转轴 = 对称化后特征值 1 的方向
        axis = v[:, np.argmax(w)]
        # 机位真值 65°，但 MediaPipe 对侧视的人有系统性「转正」偏置（肩线实测 -54.6°/65°
        # 机位），叠加侧视深度压扁，解出 ~41°。这里断言的是「方向对、量级对、不是镜像/
        # 错人（那种会解出 0° 或 180°）」——标定的本质是两台相机的自洽对齐，见 rig.py 文档。
        ok(25.0 < angle < YAW_TRUE + 8.0,
           "解出的旋转角 %.1f°（机位真值 65°，MediaPipe 转正偏置会把它解小——量级正确即可）" % angle)
        ok(abs(abs(axis[1]) - 1.0) < 0.05,
           "旋转轴就是竖直轴（|axis.y| = %.3f）——机位只在水平面上转过" % abs(axis[1]))
        ok(st_b.get("rms", 1.0) <= CAL_RMS_OK,
           "修剪后标定残差 %.1f cm ≤ %.0f cm（镜像另有 det 判据守门）"
           % (st_b.get("rms", 1.0) * 100, CAL_RMS_OK * 100))

    print("\n[融合出口]")
    ok(fused is not None and len(fused["pose"]) == 33, "两机位融合正常出 33 点骨架")

    print("\n结果：%s" % ("全部通过" if fails == 0 else "%d 项失败" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
