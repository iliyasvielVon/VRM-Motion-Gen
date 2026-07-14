"""手机动补的自检：不用真手机也能验证整条链路。

假装自己是手机：用 HTTPS 拉那个网页，再用 WebSocket 把一帧真实画面（渲染出来的参考素材）
灌进去，然后在 UDP 那头蹲着，看关键点有没有原样吐出来。

    # 一个终端：
    python tools/mocap/capture.py --phone
    # 另一个终端：
    python tools/mocap/test_phone.py
"""

import asyncio
import json
import socket
import ssl
import sys
from pathlib import Path

import cv2

HERE = Path(__file__).resolve().parent
UDP_PORT = 9977
URL = "wss://127.0.0.1:8443/ws"
PAGE = "https://127.0.0.1:8443/"

fails = 0


def ok(cond, what):
    global fails
    if cond:
        print("  PASS  %s" % what)
    else:
        fails += 1
        print("  FAIL  %s" % what)


def find_test_frame():
    """拿一帧「里面确实有个人」的画面：优先用渲染出来的参考素材"""
    for p in [
        Path.home() / "AppData/Roaming/Godot/app_userdata/VRM Motion Gen/mocap_probe/010.png",
        HERE.parent.parent / "docs/img/studio.png",
    ]:
        if p.exists():
            img = cv2.imread(str(p))
            if img is not None:
                return img, p.name
    return None, None


async def main():
    import aiohttp

    img, name = find_test_frame()
    if img is None:
        sys.exit("找不到测试画面：先跑 tools/render_probe.gd 生成参考素材")
    print("[准备] 测试画面：%s  %dx%d" % (name, img.shape[1], img.shape[0]))
    jpeg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()

    # UDP 那头先蹲好（Godot 平时就蹲在这儿）
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", UDP_PORT))
    udp.settimeout(15.0)

    sslctx = ssl.create_default_context()
    sslctx.check_hostname = False
    sslctx.verify_mode = ssl.CERT_NONE     # 自签证书，跟手机上点「继续前往」是一个意思

    print("\n[网页]")
    async with aiohttp.ClientSession() as sess:
        try:
            async with sess.get(PAGE, ssl=sslctx) as r:
                html = await r.text()
        except Exception as e:
            sys.exit("连不上 %s（%s）\n先在另一个终端跑：python tools/mocap/capture.py --phone" % (PAGE, e))
        ok(r.status == 200, "HTTPS 页面返回 200")
        ok("getUserMedia" in html, "页面里有摄像头调用（getUserMedia）")
        ok("/ws" in html, "页面里有 WebSocket 地址")

        print("\n[灌一帧进去]")
        async with sess.ws_connect(URL, ssl=sslctx) as ws:
            await ws.send_bytes(jpeg)
            print("  已发送 %d 字节的 JPEG" % len(jpeg))

            try:
                data, _ = udp.recvfrom(65535)
            except socket.timeout:
                ok(False, "UDP 那头收到了关键点（超时，什么都没收到）")
                return
            frame = json.loads(data.decode("utf-8"))
            ok(True, "UDP 收到关键点包（%d 字节）" % len(data))
            ok(frame.get("pose") is not None and len(frame["pose"]) == 33,
               "包里有身体的 33 个关键点")
            ok(all(len(p) == 3 for p in frame["pose"]), "每个点都是 3D 的 [x,y,z]")
            hips = frame["pose"][23]
            ok(abs(hips[0]) < 1.0 and abs(hips[1]) < 1.0,
               "坐标在合理量级（左胯 = %s，单位米、原点在胯心）" % [round(v, 3) for v in hips])
            print("  手部：左 %s  右 %s ｜ 表情通道：%d 个" % (
                "有" if frame.get("lh") else "无",
                "有" if frame.get("rh") else "无",
                len(frame.get("bs") or {})))

    print("\n结果：%s" % ("全部通过" if fails == 0 else "%d 项失败" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    asyncio.run(main())
