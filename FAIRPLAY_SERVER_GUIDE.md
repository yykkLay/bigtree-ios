# FairPlay Streaming 实施指南

> 客户端部分**已经做好了**（在 `App/FairPlayPlayer.swift` 里）：
> 拦截 `skd://` 密钥请求 → 取证书 → 生成 SPC → 换 CKC → 交给 AVPlayer 解密播放。
>
> 这份文档说明**服务端需要做什么**，以及两边怎么对上。

---

## 一、先看清全貌：FairPlay 是「客户端 + 服务端 + 苹果授权」三件套

| 部分 | 谁来做 | 状态 |
| --- | --- | --- |
| **客户端**：AVContentKeySession、SPC 生成、CKC 应用、解密播放 | 已由本 App 完成 | ✅ |
| **苹果授权**：FPS 证书（证明你有权分发这些内容） | 你用 Apple Developer 账号申请 | ⬜ 需要你办 |
| **内容加密**：把视频切成 HLS 分片并用 SAMPLE-AES 加密 | 用打包工具（免费工具即可） | ⬜ 需要你做 |
| **密钥服务器**：收 SPC → 换 CKC → 返回 | 你搭（关键门槛见第五节） | ⬜ 需要你做 |

**核心概念**（看懂这几个词，后面就通了）：

- **SPC**（Server Playback Context）：客户端生成的"加密请求"，里面含本次播放的上下文
- **CKC**（Content Key Context）：服务端返回的"解密票据"，AVPlayer 拿到它才能解密
- **KSM**（Key Security Module）：苹果的安全模块，**只有它能用 FPS 私钥解 SPC、生成 CKC**
- **assetId**：内容标识，客户端从 `skd://<assetId>` 里取出来传给服务端

---

## 二、第一步：申请 FairPlay Streaming 证书

1. 需要 **Apple Developer Program**（个人/公司账号，$99/年）
2. 登录 <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles**
3. 找到 **FairPlay Streaming**（若看不到入口，需先在 <https://developer.apple.com/streaming/> 提交申请，苹果会审核你的内容分发资格）
4. 按流程生成证书，下载得到一个 `.cer` 文件
5. 把证书转成服务端能用的格式：

```bash
openssl x509 -inform DER -in fairplay.cer -out fairplay.pem
```

> **证书的作用**：它是解密 SPC 的钥匙对对的一半。客户端会从你的服务器下载这个证书来生成 SPC。

---

## 三、第二步：把视频加密成 FairPlay 格式

用 **Shaka Packager**（免费、跨平台、原生支持 FairPlay）：

```bash
packager \
  in=hls.m3u8,stream=audio,segment_template=audio_$Number$.aac \
  in=hls.m3u8,stream=video,segment_template=video_$Number$.ts \
  --enable_raw_key_encryption \
  --keys label=VIDEO:key_id=31323334353637383930313233343536:key=32333435363738393031323334353637:iv=11111111111111111111111111111111 \
  --protection_systems FairPlay \
  --hls_master_playlist_output master.m3u8
```

或者用苹果官方的 **HLS Tools**（`mediafilesegmenter`，需开发者账号下载）：

```bash
mediafilesegmenter -f out -k key.bin -skd skd://my-asset-id input.mp4
```

**加密后的 m3u8 里会出现这样的行**（这就是客户端要处理的信号）：

```
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://my-asset-id",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
```

> `skd://` 后面那段（例中的 `my-asset-id`）会被客户端取出来，作为 **assetId** 发给你的许可证服务器。

---

## 四、第三步：搭密钥服务器（两个接口）

### 接口 1：提供证书

```
GET https://your-server/fps/cert
→ 返回 fairplay.pem 的原始二进制内容（Content-Type: application/octet-stream）
```

### 接口 2：换取许可证（核心）

```
POST https://your-server/fps/license
请求头：
  Content-Type: application/octet-stream
  X-Asset-Id: <客户端从 skd:// 里取出的 assetId>
请求体：SPC（二进制）
响应体：CKC（二进制）
```

Node.js 骨架（示意，KSM 部分见下节）：

```js
app.post('/fps/license', express.raw({ type: '*/*', limit: '10mb' }), async (req, res) => {
  const spc = req.body;                       // 二进制 SPC
  const assetId = req.header('X-Asset-Id');   // 内容标识

  // 1) 校验用户是否有权看这个 assetId（接你自己的账号/订单系统）
  if (!(await userCanWatch(req, assetId))) {
    return res.status(403).send('forbidden');
  }

  // 2) 把 SPC 交给 KSM，换回 CKC
  const ckc = await ksm.exchange({ spc, assetId, keyId: lookupKeyId(assetId) });

  // 3) 原样返回 CKC（二进制）
  res.set('Content-Type', 'application/octet-stream').send(ckc);
});
```

---

## 五、关键门槛：KSM（这一节决定你的实施路线）

**苹果的 FPS 私钥在 KSM 里，SPC 只能由 KSM 解开。** 所以你有两条路：

| 路线 | 说明 | 适合谁 |
| --- | --- | --- |
| **A. 用第三方 DRM 服务商**（推荐） | PallyCon、EZDRM、Axinom、BuyDRM、Verimatrix、AWS MediaPackage 等。他们持有 KSM，提供现成的"SPC 进、CKC 出"API，你只需调用 | 绝大多数团队，**这也是最快的路** |
| **B. 自己拿苹果 KSM** | 苹果提供的 KSM 参考实现，通常要求较大的内容提供商并签协议，部署在受控环境（HSM/专用服务器） | 有专门 DRM 团队的大型内容方 |

> 换句话说：**第四节的 `ksm.exchange(...)` 那一行，最省事的做法是换成第三方服务商的 HTTP 调用。**
> 各家接口形状不同，但都逃不出"传 SPC + assetId，拿回 CKC"这个模式。

---

## 六、第四步：在 App 里填地址

打开 App → 右上角 **⋯** → **FairPlay 服务器**，填：

| 字段 | 填什么 | 例 |
| --- | --- | --- |
| 证书地址 | 上面「接口 1」的完整 URL | `https://your-server/fps/cert` |
| 许可证地址 | 上面「接口 2」的完整 URL | `https://your-server/fps/license` |
| 固定 assetId | 一般留空（客户端自动从 `skd://` 取）；若你的流不带 skd，可在此固定 | 留空 |
| Authorization 请求头 | 如果你的接口需要鉴权，填 `Bearer xxx` 或 `Cookie xxx` | 留空或按需 |

填完直接生效（存在本机，不会上传）。

---

## 七、怎么验证

1. 先拿 **未加密** 的 m3u8 试播放：App → ⋯ → **原生播放（FairPlay）** → 手动输入 m3u8 地址 → 应能正常播放（说明播放链路没问题）
2. 再拿 **FairPlay 加密** 的 m3u8 试：若证书/许可证配置正确，应能解密播放；屏幕下方会显示 `FairPlay 已就绪 · 正在播放`
3. 报错对照表：

| 屏幕提示 | 含义 | 排查方向 |
| --- | --- | --- |
| 尚未配置 FairPlay 证书地址与许可证地址 | 没填地址 | 第六节 |
| 无法从服务器获取 FairPlay 证书 | 证书接口不通或格式不对 | 证书应是 DER/PEM 原始二进制，不是 base64 文本 |
| 许可证服务器未返回密钥（CKC 为空） | 许可证接口返回空 | 看服务端日志：SPC 是否成功交给 KSM、assetId 是否匹配 |
| 生成 SPC 失败 | 证书本身不被 AVFoundation 接受 | 确认是 **FPS 证书**（不是普通 SSL 证书），且未过期 |
| 播放失败：… | 密钥换到了但内容对不上 | 加密时用的 key/keyId 与 KSM 返回的不是同一把 |

---

## 八、还有一个更省事的可能

如果你的内容**并不需要**强 DRM（只是希望 iPhone 能播），其实可以：

- **不加密**，直接提供明文 HLS（m3u8）→ 本 App 的原生播放器直接就能播，**什么都不用配**
- 或者用 **AES-128 普通 HLS 加密**（密钥就是一个 URL）→ 也是苹果原生支持，不需要 FPS 证书

**FairPlay 只在"必须防录屏/防抓取"时才需要。** 如果你的目标是"让 iPhone 用户能正常看"，先把服务端输出的 m3u8 换成明文或 AES-128，是最快见效的方案。

---

## 附：客户端代码位置

| 文件 | 作用 |
| --- | --- |
| `App/FairPlayPlayer.swift` | FPS 密钥加载器（SPC/CKC 全流程）+ 原生播放器 |
| `App/WebView.swift` | 捕获网页里的 m3u8 / skd:// 地址，转发给原生播放器 |
| `App/ContentView.swift` | 「原生播放（FairPlay）」与「FairPlay 服务器」两个入口 |
