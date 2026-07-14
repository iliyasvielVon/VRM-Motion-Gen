"""手机摄像头动补：手机浏览器直接当摄像头，不用装任何 App。

    python tools/mocap/capture.py --phone

跑起来会打印一个 https://<本机局域网IP>:8443 的地址，手机（跟电脑同一个 Wi-Fi）用浏览器打开，
点「开始」授权摄像头，画面就会以 JPEG 帧的形式经 WebSocket 传回电脑；MediaPipe 在电脑上跑，
关键点照旧用 UDP 喷给 Godot。手机只负责当一个摄像头，不做任何计算，所以老手机也不卡。

**为什么必须是 HTTPS**：浏览器的 getUserMedia（摄像头权限）只在「安全上下文」里可用——
localhost 或者 HTTPS。手机访问的是 http://192.168.x.x，不算安全上下文，摄像头会被直接拒掉，
连弹窗都不会有。所以这里现场签一张自签证书。代价是手机上会跳一次「连接不是私密连接」的警告，
点「高级 → 继续前往」即可（证书是你自己电脑上刚生成的，只在局域网里用）。

证书存在 tools/mocap/.cert/ 下，第一次生成，之后复用；已加进 .gitignore（私钥不进仓库）。
"""

import asyncio
import datetime
import ipaddress
import socket
import ssl
from pathlib import Path

CERT_DIR = Path(__file__).resolve().parent / ".cert"
CERT = CERT_DIR / "cert.pem"
KEY = CERT_DIR / "key.pem"

PAGE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>动作工房 · 手机动补</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#160505; color:#e8d9b8; font-family:system-ui,-apple-system,sans-serif;
         display:flex; flex-direction:column; align-items:center; gap:14px; padding:18px 12px; }
  h1 { font-size:17px; margin:0; color:#d8b46a; letter-spacing:2px; }
  video { width:100%; max-width:460px; border-radius:10px; border:1px solid #6b5330; background:#000;
          transform:scaleX(-1); }
  button { font-size:17px; padding:13px 32px; border-radius:8px; border:1px solid #d8b46a;
           background:#3a0d0d; color:#e8d9b8; }
  button:disabled { opacity:.45; }
  #stat { font-size:13px; color:#b9a888; min-height:20px; text-align:center; line-height:1.6; }
  #fps { color:#d8b46a; }
</style>
<h1>动 作 工 房 · 手机动补</h1>
<video id="v" playsinline muted autoplay></video>
<div>
  <button id="go">开始</button>
  <button id="flip">前/后摄</button>
</div>
<div id="stat">点「开始」授权摄像头。手机只负责拍，识别在电脑上跑。</div>
<canvas id="c" hidden></canvas>
<script>
const v=document.getElementById('v'), c=document.getElementById('c'), ctx=c.getContext('2d');
const stat=document.getElementById('stat'), go=document.getElementById('go'), flip=document.getElementById('flip');
let ws=null, stream=null, facing='user', sending=false, sent=0, t0=0;
const W=480, FPS=15;

flip.onclick=()=>{ facing = facing==='user' ? 'environment' : 'user';
  v.style.transform = facing==='user' ? 'scaleX(-1)' : 'none';
  if (stream) start(); };

go.onclick=()=>{ if (sending) stop(); else start(); };

async function start(){
  try{
    if (stream) stream.getTracks().forEach(t=>t.stop());
    stream = await navigator.mediaDevices.getUserMedia({
      video:{ facingMode:facing, width:{ideal:640}, height:{ideal:480} }, audio:false });
  }catch(e){ stat.textContent='拿不到摄像头：'+e.message+'\\n（页面必须是 https，且要允许摄像头权限）'; return; }
  v.srcObject=stream;
  await v.play();
  c.width=W; c.height=Math.round(W*v.videoHeight/v.videoWidth);
  if (!ws || ws.readyState!==1){
    ws = new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');
    ws.binaryType='arraybuffer';
    ws.onclose=()=>{ stat.textContent='连接断了。电脑上的 capture.py 还开着吗？'; stop(); };
  }
  sending=true; sent=0; t0=performance.now(); go.textContent='停止';
  pump();
}

function stop(){ sending=false; go.textContent='开始';
  if (stream) stream.getTracks().forEach(t=>t.stop());
  stream=null; stat.textContent='已停止。'; }

function pump(){
  if (!sending) return;
  // 发送的画面永远是真实朝向（不镜像）：多相机融合要做刚体对齐，镜像过的骨架
  // 是「反射」不是「旋转」，和别的相机永远拼不上（Kabsch 残差爆表会拒收）。
  // 单相机模式的镜子手感由电脑那头统一翻转，预览里的镜像只是 CSS。
  ctx.drawImage(v,0,0,c.width,c.height);
  c.toBlob(b=>{
    if (b && ws && ws.readyState===1 && ws.bufferedAmount < 200000){
      b.arrayBuffer().then(a=>ws.send(a));
      sent++;
      const el=(performance.now()-t0)/1000;
      stat.innerHTML='传输中 · <span id="fps">'+(sent/el).toFixed(1)+' fps</span> · 已发 '+sent+' 帧<br>把手机架稳，全身入镜，正对镜头';
    }
    setTimeout(pump, 1000/FPS);
  }, 'image/jpeg', 0.6);
}
</script>
"""


def lan_ip() -> str:
    """本机在局域网里的 IP（连一下外网地址让系统自己选出口网卡，不会真的发包）"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("223.5.5.5", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def ensure_cert(ip: str) -> ssl.SSLContext:
    """自签一张只给局域网用的证书（首次生成，之后复用）"""
    if not (CERT.exists() and KEY.exists()):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID

        CERT_DIR.mkdir(parents=True, exist_ok=True)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "vrm-motion-gen-mocap")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=3650))
            # IP 也写进 SAN：手机是按 IP 访问的，只写 CN 的话某些浏览器会直接拒绝
            .add_extension(x509.SubjectAlternativeName([
                x509.IPAddress(ipaddress.ip_address(ip)),
                x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
            ]), critical=False)
            .sign(key, hashes.SHA256())
        )
        KEY.write_bytes(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption()))
        CERT.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        print("已生成自签证书 → %s" % CERT_DIR)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    return ctx


def serve(on_frame, port: int = 8443, on_close=None, handle_signals: bool = True) -> None:
    """开 HTTPS 服务。可以有任意多台手机同时连（多相机融合的「中途加入」就是从这儿进来的）。

    on_frame(conn_id, jpeg_bytes)：每收到一帧调一次，conn_id 形如 "phone1"/"phone2"。
    on_close(conn_id)：手机断开时调一次（融合那头拿它做「下线即移除」）。"""
    from aiohttp import WSMsgType, web

    ip = lan_ip()
    counter = {"n": 0}

    async def index(_req):
        return web.Response(text=PAGE, content_type="text/html")

    async def ws_handler(req):
        counter["n"] += 1
        cid = "phone%d" % counter["n"]
        ws = web.WebSocketResponse(max_msg_size=8 << 20)
        await ws.prepare(req)
        print("手机 %s 连上了：%s" % (cid, req.remote))
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                on_frame(cid, msg.data)
            elif msg.type == WSMsgType.ERROR:
                break
        print("手机 %s 断开了" % cid)
        if on_close is not None:
            on_close(cid)
        return ws

    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)

    url = "https://%s:%d" % (ip, port)
    print("\n" + "=" * 58)
    print("  手机用浏览器打开：  %s" % url)
    print("  （手机要和电脑在同一个 Wi-Fi 下）")
    print()
    print("  会跳一次「连接不是私密连接」的警告 —— 这是自签证书，")
    print("  点「高级 → 继续前往」即可。然后点页面上的「开始」。")
    print("=" * 58 + "\n")

    web.run_app(app, host="0.0.0.0", port=port, ssl_context=ensure_cert(ip),
                print=None, access_log=None, handle_signals=handle_signals)


def serve_threaded(on_frame, on_close=None, port: int = 8443) -> None:
    """后台线程里跑手机服务（多相机融合模式用：主线程要留给融合循环和预览窗口）"""
    import threading

    threading.Thread(target=serve, args=(on_frame, port, on_close, False), daemon=True).start()
