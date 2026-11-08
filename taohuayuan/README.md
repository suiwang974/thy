# 桃花源 App（从零重写版）

> 不套 SkyStream。2026-11-08 用户原话：网页版 3D 片库能用，APK 为什么写不出来——
> 要求 APK 就要像网页版那样工作。于是把旧壳扔了，按网页版的行为从头写。

## 路线：(a) 全新 Flutter 原生 + 复用 JS 插件的搜索逻辑

没选 (b) WebView 套网页版，原因：

- 静态网页版（`ts-spaces/3d-video-library-public/index.html`）只有**目录搜索**，
  没有多源活搜索（里面一个 fetch 都没有）；套壳解决不了“搜足没结果”。
- WebView 里 `<video>` 发不出 niacg 要的 Referer，33 段 niacg 片照样 403；
  还要依赖 CDN 的 hls.js，全屏、倍速都得再桥接。
- 9 个 JS 插件一共才 1333 行，每个就是一次 HTTP + 正则解析，搬成 Dart 是机械活。
- 原生 Dart 没有 CORS 限制；ExoPlayer（video_player）原生支持 HLS，
  还能在请求头里带 Referer——niacg 的 xunge 链在原生层就能播通，
  这是浏览器/WebView 做不到的。

## 结构

```
lib/
  main.dart               入口：底部五栏 推荐 / 短视频 / 搜索 / 追番 / 我的
  models/video_item.dart  视频条目（直链 / Referer / 封面 / 作者 / 批次）
  data/
    catalog.dart          在线片库目录加载 + 目录内搜索（62 条）
    search_map.dart       中文词 -> 英文词映射（足->foot，长词优先）
    sources.dart          9 个源（Eporner JSON API + 7 个 HTML 解析源 + 片库）
  services/
    search_service.dart   多源并行搜索，结果随到随回；片库瞬间先出
    stream_resolver.dart  视频页 -> 直链（r34 m3u8 / niacg mp4+Referer / lianzu11 mp4）
    store.dart            喜欢 / 关注作者 / 观看记录 / 源开关（本机存）
  ui/
    home_screen.dart      推荐：猜你喜欢（写明理由）+ 关注作者置顶 + 按批次列出
    shorts_screen.dart    短视频：竖滑，滑到就真播视频，点一下横屏放大
    search_screen.dart    搜索：中文映射后默认查全部已启用源，按源分组
    following_screen.dart 追番：关注的作者 + 我喜欢的
    profile_screen.dart   我的：源开关 + 观看记录
    author_screen.dart    作者页：点作者名只看他的片
    player_screen.dart    播放页：直链在线播 + 倍速 + 上一段/下一段 + 在源站看
    widgets.dart          视频卡片（无封面显示文字卡，绝不丢条目）
assets/
  catalog.json            62 条在线目录（57 条有直链，03 批 5 条待补链）
  thumbs/                 62 张真实封面
test/
  search_map_test.dart    映射测试
  sources_test.dart       目录 + 各源解析测试
  live_verify_test.dart   联网验证（Eporner / r34 / 直链可达；Niacg 只记录）
```

## Android 配置

- 包名 `dev.akash.skystream`，名字桃花源，图标是桃花设计（`icon-src/` 的 webp 转的 mipmap）
- compileSdk 37 / targetSdk 37 / minSdk 21（上游教训：不要改回 36）
- INTERNET 权限在 Manifest 里（模板默认没有，已补）

## 验证（2026-11-08，本地）

- `flutter analyze`：No issues found
- `flutter test`：15/15 通过（含 4 项联网验证）
  - Eporner API 搜 foot 有结果；Rule34Video 搜 foot 有结果；
    r34 HLS 直链 HEAD 200；xunge mp4 带 Referer HEAD 200/206
  - Niacg 搜索页 VM 下 HTTP 403 / 断连（已知 VM 网络问题，手机真机要另验；
    代码里该源失败只显示“该源暂不可用”，不炸整页）

## 没验过的（诚实写清）

- **本地打不出 APK**：VM 沙盒拦 JVM 回环 TCP，`flutter build apk` 在 Gradle
  那步 Broken pipe 失败——和旧壳当年同一毛病。打包走 GitHub Actions CI。
- **真机没验过**：启动、首页、搜 foot 点播、短视频真播、niacg 在手机网络下
  通不通，都要真机（或 CI 的 KVM 模拟器集成测试）验。
- SPEC 有两处措辞要跟着新路线改（等用户/主 agent 定）：
  验收 3 “已安装里 9 个源都在”——新 App 源是内置的，在“我的”里开关，
  没有“已安装”这个概念；首页五栏第三栏是“搜索”（时间表以后再说）。

## 打包（CI，走 GitHub Actions，推代码等主 agent 指示）

仓库 suiwang974/thy。推之前本地先跑：`flutter analyze && flutter test`。
