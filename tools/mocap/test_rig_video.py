# -*- coding: utf-8 -*-
"""离线多机位（--rig-video）的自检：真实 MediaPipe + 已知的开录错位。

素材：render_rig.gd 渲染的 0°/65° 两机位帧序列（先跑 test_rig_real.py 文件头那两条
渲染命令），拼成两段 30fps 视频，侧面那段开头垫 13 帧模拟晚按录制。

断言分三层，各测各的（混在一起会像之前那样误诊）：
  1. **手动对时路径（--sync-offsets，兜底也是最稳）**：给定正确错位后，
     标定 → 融合 → 写文件全链路必须成立，镜像机位必须被 det 判据拒收；
  2. **自动对时的算法本身**：用合成的相关信号验证 NCC 实现正确（找回已知 lag）——
     和「MediaPipe 侧视质量够不够」分开测；
  3. **自动对时在最坏样本上的诚实行为**：动漫渲染 + 65° 侧视下侧机姿态估计和
     真实动作不相关（被遮挡的半边是编的），自动对时找不准是已知限制——
     只断言它「有报告、有相关系数、不崩」，不断言它对。

    python tools/mocap/test_rig_video.py
"""

import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402
import rig_video  # noqa: E402
from rig import CAL_RMS_OK  # noqa: E402

OFFSET = 13         # 侧面机位晚按录制的帧数（30fps 下 0.43 秒）

fails = 0


def ok(cond, what):
    global fails
    print("  %s  %s" % ("PASS" if cond else "FAIL", what))
    if not cond:
        fails += 1


def build_video(out_path, frames, prepend=0, mirror=False):
    h, w = frames[0].shape[:2]
    vw = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"), 30, (w, h))
    for f in [frames[0]] * prepend + frames:
        vw.write(cv2.flip(f, 1) if mirror else f)
    vw.release()
    return out_path


def main():
    user = Path.home() / "AppData/Roaming/Godot/app_userdata/VRM Motion Gen"
    fa = [cv2.imread(str(p)) for p in sorted((user / "rig_0").glob("*.png"))]
    fb = [cv2.imread(str(p)) for p in sorted((user / "rig_65").glob("*.png"))]
    if not fa or not fb:
        sys.exit("缺素材：先跑 render_rig.gd 渲染 0°/65° 两个机位（见 test_rig_real.py 文件头）")

    print("[拼装测试视频：侧面机位故意晚按 %d 帧录制]" % OFFSET)
    va = build_video(user / "rig_video_a.mp4", fa)
    vb = build_video(user / "rig_video_b.mp4", fb, prepend=OFFSET)
    vm = build_video(user / "rig_video_m.mp4", fb, prepend=OFFSET, mirror=True)

    print("\n[1. 手动对时（--sync-offsets 打板）：标定→融合→写文件 全链路]")
    report = rig_video.run([va, vb], "_rigvideo自检", capture.make_landmarker,
                           capture.pack, capture.OUT_DIR,
                           sync_offsets=[0.0, OFFSET / 30.0])
    other = next(c for c in report["offsets"] if report["offsets"][c]["shift"] != 0)
    ok(report["offsets"][other].get("manual", False), "错位按打板值直接采用（不猜）")
    cal = report["calib"].get(other, {})
    ok(not cal.get("mirrored", True), "标定确认两机位是纯旋转关系（det=+1）")
    ok(cal.get("rms", 1.0) <= CAL_RMS_OK,
       "整段重叠区间标定：%d 帧对应点，残差 %.1f cm ≤ %.0f cm"
       % (cal.get("pairs", 0), cal.get("rms", 1.0) * 100, CAL_RMS_OK * 100))
    ok(report["frames"] >= 100, "融合输出 %d 帧" % report["frames"])
    ok(report["multi_ratio"] >= 0.6,
       "多机位覆盖率 %.0f%%（其余帧由单机位顶上）" % (report["multi_ratio"] * 100))
    out_file = capture.OUT_DIR / "_rigvideo自检.mocap.json"
    ok(out_file.exists(), "关键点文件已写出，可回编辑器「导入视频动补」")

    print("\n[2. 镜像判据：管点云级反射，不管镜像视频（后者经 MediaPipe 已变合法骨架）]")
    # 重要发现，测试钉死以防遗忘：把**视频**镜像后喂 MediaPipe，它会把画面里的人
    # 当正常人解读，输出手性合法的骨架（动作左右调换而已）——几何上没有反射，
    # det 判据管不到，动作又偏对称时标定照样通过。det 判据真正防的是**点云级**
    # 反射：上游对关键点坐标做了 x 取反（手机路径历史上就干过），那种一抓一个准。
    from rig import calibrate_pairs
    rng0 = np.random.default_rng(11)
    pts = [rng0.normal(size=(20, 3)) for _ in range(50)]
    good = [(p, p @ rig_video.np.eye(3)) for p in pts]
    bad = [(p * np.array([-1.0, 1.0, 1.0]), p) for p in pts]
    _, _, m_good = calibrate_pairs(good)
    _, _, m_bad = calibrate_pairs(bad)
    ok(not m_good and m_bad, "点云级反射被 det 判据识破，正常点云不误伤")

    report2 = rig_video.run([va, vm], "_rigvideo自检2", capture.make_landmarker,
                            capture.pack, capture.OUT_DIR,
                            sync_offsets=[0.0, OFFSET / 30.0])
    ok(report2["frames"] >= 100,
       "镜像视频不崩管线（%d 帧）——它的骨架是合法的，只是动作左右反了：文档已写明"
       "「别给融合喂镜像视频，动作不对称时会被残差拦，偏对称时会稀释左右细节」"
       % report2["frames"])

    print("\n[3. 自动对时：算法本身（合成相关信号）]")
    rng = np.random.default_rng(3)
    base = np.cumsum(rng.normal(size=300))                    # 随机游走 = 宽带信号
    sig_a = np.full((300, 4), np.nan)
    sig_b = np.full((313, 4), np.nan)
    for c in range(4):
        sig_a[:, c] = base * (c + 1) + rng.normal(size=300) * 0.3
        sig_b[13:, c] = sig_a[:, c] + rng.normal(size=300) * 0.3   # 晚 13 帧 + 各自噪声
        sig_b[:13, c] = sig_b[13, c]
    lag, corr = rig_video._align(sig_a, sig_b, 60)
    ok(lag == 13 and corr > 0.9,
       "NCC 从带噪声的相关信号里找回错位 %d 帧（相关 %.2f）——算法本身没问题" % (lag, corr))

    print("\n[4. 自动对时在最坏样本上的诚实行为（动漫+65°侧视，已知不可靠）]")
    report3 = rig_video.run([va, vb], "_rigvideo自检3", capture.make_landmarker,
                            capture.pack, capture.OUT_DIR)
    other3 = next(iter(report3["offsets"]), None)
    ok(other3 is not None and "corr" in report3["offsets"][other3],
       "自动对时给出了结果和相关系数（%.2f）供人工核对，全程不崩"
       % report3["offsets"][other3]["corr"])

    for f in [va, vb, vm, out_file,
              capture.OUT_DIR / "_rigvideo自检2.mocap.json",
              capture.OUT_DIR / "_rigvideo自检3.mocap.json"]:
        Path(f).unlink(missing_ok=True)
    print("\n结果：%s" % ("全部通过" if fails == 0 else "%d 项失败" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
