# 免费云定时运行

现在项目已经有一个专门给云端部署的入口：

```bash
dart run bin/cloud_signal_scheduler.dart
```

你这次选的是：

- `常驻 Web 服务 + 内部定时器`

它同时也兼容：

- `一次性任务模式`

## 1. 常驻服务模式

适合：

- 有 Web Service / Container 的平台
- 容器可以持续运行

启动后会做这些事：

- 暴露 `health/latest/replay/run` 接口
- 暴露 `market-snapshot` 接口给 Flutter App 直接取推荐快照
- 按固定时间自动跑推荐
- 需要时自动刷新小时回放
- 命中信号后推送到 `飞书` 或 `ntfy`
- 自动做重复推送去重

### 默认行为

- 每 `120` 分钟跑一次
- 启动后立刻跑一次
- 回放结果超过 `12` 小时会自动重算
- 同样的推送内容在 `6` 小时内不重复发

### 推荐直接使用这组配置

项目里已经放了：

- `.env.web.example`
- `Procfile`

常驻 Web 服务模式建议保持：

```env
RUN_ONCE=false
ENABLE_INTERNAL_SCHEDULER=true
RUN_ON_STARTUP=true
PUSH_PROVIDER=auto
PUBLISH_PUSH=true
DEDUPE_PUSH=true
```

这里默认建议：

- 优先配 `FEISHU_WEBHOOK_URL`
- 不配飞书时，再退回 `NTFY_TOPIC`

### HTTP 接口

- `GET /health`
- `GET /latest`
- `GET /replay`
- `GET /market-snapshot`
- `GET /market-snapshot?symbols=FETUSDT,TONUSDT`
- `GET /market-snapshot?symbols=FETUSDT,TONUSDT&refresh=1`
- `GET /run?token=...`
- `POST /run`，Header:
  `Authorization: Bearer <RUNNER_TOKEN>`

### `market-snapshot` 是做什么的

这个接口会直接返回：

- 当前自选币列表
- 后台计算后的全量评分
- 今日 Top3 推荐
- 当前回测报告
- 入场提醒信号

这样 Flutter App 只负责展示和实时轻量价格刷新，不再在手机端做整套历史分析。

## 2. 一次性任务模式

适合：

- 平台本身提供 Cron Job
- 任务跑完就退出

只要加：

```bash
RUN_ONCE=true
```

进程会：

- 自动刷新回放
- 跑一次推荐
- 推送信号
- 写报告后退出

这对于很多“免费定时任务平台”会更稳。

## 3. Docker 部署

项目根目录已经带了：

- `Dockerfile`
- `.dockerignore`

本地测试：

```bash
docker build -t binance-analyzer-cloud .
docker run --rm -p 8080:8080 \
  -e PUSH_PROVIDER=feishu \
  -e FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/replace-me \
  -e RUNNER_TOKEN=your-secret-token \
  binance-analyzer-cloud
```

健康检查：

```bash
curl http://localhost:8080/health
```

手动触发：

```bash
curl "http://localhost:8080/run?token=your-secret-token"
```

## 4. 推荐环境变量

必须：

- 二选一：
- `FEISHU_WEBHOOK_URL`
- `NTFY_TOPIC`

建议：

- `PUSH_PROVIDER`
- `RUNNER_TOKEN`
- `NTFY_SERVER`
- `SIGNAL_INTERVAL_MINUTES`
- `REPLAY_REFRESH_HOURS`
- `MARKET_SNAPSHOT_TTL_SECONDS`
- `PUSH_DEDUPE_HOURS`

可选：

- `WATCHLIST`
- `PUBLISH_PUSH`
- `DEDUPE_PUSH`
- `RUN_ON_STARTUP`
- `ENABLE_INTERNAL_SCHEDULER`
- `REFRESH_REPLAY_BEFORE_RUN`
- `RUN_ONCE`

## 5. 关键环境变量说明

### 推送

- `PUSH_PROVIDER`
  - `auto / feishu / ntfy`
  - 默认推荐 `auto`
  - `auto` 会优先飞书，没有飞书再走 ntfy
- `FEISHU_WEBHOOK_URL`
  - 飞书自定义机器人 webhook 地址
- `NTFY_TOPIC`
  - 你的 ntfy topic
- `NTFY_SERVER`
  - 默认 `https://ntfy.sh`
- `PUBLISH_PUSH`
  - `true/false`
- `DEDUPE_PUSH`
  - `true/false`
- `PUSH_DEDUPE_HOURS`
  - 默认 `6`

### 调度

- `PORT`
  - 默认 `8080`
- `SIGNAL_INTERVAL_MINUTES`
  - 默认 `120`
- `MARKET_SNAPSHOT_TTL_SECONDS`
  - 默认 `90`
  - App 拉取 `/market-snapshot` 时的后台缓存秒数
- `RUN_ON_STARTUP`
  - 默认 `true`
- `ENABLE_INTERNAL_SCHEDULER`
  - 默认常驻模式下 `true`
- `RUN_ONCE`
  - 默认 `false`

### 回放

- `REFRESH_REPLAY_BEFORE_RUN`
  - 默认 `true`
- `REPLAY_REFRESH_HOURS`
  - 默认 `12`

### 自选币

- `WATCHLIST`
  - 逗号分隔，例如：
  - `WATCHLIST=FET,TON,STG,LINK`

### 安全

- `RUNNER_TOKEN`
  - 给 `/run` 接口加一层简单鉴权

## 6. 报告文件

运行后会生成：

- `build/reports/daily_signal_report.json`
- `build/reports/hourly_replay_report.json`
- `build/reports/cloud_scheduler_state.json`
- `build/reports/cloud_push_state.json`

## 7. 部署建议

如果平台支持“常驻容器”：

- 直接跑 `dart run bin/cloud_signal_scheduler.dart`
- 或识别 `Procfile` 时直接按 `web` 进程启动

如果平台只支持“定时任务”：

- 同样用这个入口
- 加上 `RUN_ONCE=true`

这样你之后不管部署到哪个免费云，入口都不用再改。

## 7.1 为什么这次优先接飞书

飞书 webhook 成本最低，原因很直接：

- 不需要 Apple 开发者远程推送链路
- 不需要 APNs 证书、设备 token、推送网关
- 只要一个机器人 webhook 就能从云端直接发
- 免费云部署时排障成本更低

苹果通知目前项目里保留的是本地通知；
如果你后面一定要做“云端直推 iPhone”，那会是单独一条 APNs 接入工作流。

## 8. Flutter App 如何接后台

App 端已经支持通过 `BACKEND_BASE_URL` 走远程后台模式。

只要启动 App 时带上：

```bash
flutter run \
  --dart-define=BACKEND_BASE_URL=https://你的服务域名
```

或者打包时带上：

```bash
flutter build ios --dart-define=BACKEND_BASE_URL=https://你的服务域名
flutter build apk --dart-define=BACKEND_BASE_URL=https://你的服务域名
```

接入后行为是：

- 首页 / 自选页优先请求后台 `/market-snapshot`
- 后台不可用时，自动回退到本地分析
- 实时价格 WebSocket 仍然由 App 自己连，页面刷新更顺滑

## 9. 你本地验证一套最小可用命令

先启动后台：

```bash
PORT=8080 \
RUN_ON_STARTUP=false \
PUBLISH_PUSH=false \
RUNNER_TOKEN=test-token \
dart run bin/cloud_signal_scheduler.dart
```

验证接口：

```bash
curl http://127.0.0.1:8080/health
curl "http://127.0.0.1:8080/market-snapshot?symbols=FETUSDT,TONUSDT"
curl "http://127.0.0.1:8080/run?token=test-token&sync=1"
```

然后启动 Flutter：

```bash
flutter run --dart-define=BACKEND_BASE_URL=http://127.0.0.1:8080
```

注意：

- 真机 iPhone 建议优先用 `https` 域名
- 如果是局域网直连，不要写 `127.0.0.1`，要写你电脑的局域网 IP

## 10. 飞书 webhook 怎么配

1. 在飞书群里添加一个自定义机器人
2. 拿到 webhook 地址
3. 部署时配置：

```env
PUSH_PROVIDER=feishu
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/你的地址
PUBLISH_PUSH=true
DEDUPE_PUSH=true
```

如果你想让系统自动选择：

```env
PUSH_PROVIDER=auto
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/你的地址
```

这样有飞书就发飞书，没有飞书才会尝试 ntfy。
