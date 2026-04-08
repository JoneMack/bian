# 日线轮动与买点提醒

## 现在已经能做什么

- App 里会自动拉取自选币最近约 75 天日线和 72 小时小时线。
- 推荐不再只看 24h 涨跌，而是会做 45 天轮动回测，自动选择当前更合适的权重方案。
- App 已接入 `iOS 本地通知`，当检测到高质量买点时会直接在 iPhone 上弹提醒。
- 提醒增加了 `6 小时冷却`，避免同一币种连续刷屏。
- `bin/hourly_replay_runner.dart` 会重放最近 45 天每小时状态，并输出 15 天提醒优化结果。
- `bin/daily_signal_runner.dart` 可以直接输出：
  - 今日 Top3
  - 买入时机
  - 回测结果
  - `build/reports/daily_signal_report.json`
  - 如果存在 `build/reports/hourly_replay_report.json`，会自动读取其中的优化提醒阈值

## 免费推送到 iPhone 的建议方案

推荐先用 `ntfy`：

- 免费
- HTTP 接口简单
- iPhone 有现成 App
- 不需要自己维护 APNs 服务

另外，App 内现在已经有本地通知能力：

- 你打开 App 时，只要命中买点阈值，就会直接弹 iPhone 本地提醒
- `ntfy` 适合做云端定时提醒
- 两者可以同时保留：本地通知负责 App 内实时触发，`ntfy` 负责离线/云端跑批

### 1. 手机端

- 在 iPhone 安装 `ntfy` App
- 自己订阅一个 topic，例如 `your-private-signal-topic`

### 2. 本地测试

在项目根目录执行：

```bash
flutter pub get
NTFY_TOPIC=your-private-signal-topic dart run bin/daily_signal_runner.dart
```

如果你有自建 ntfy 服务，可以再加：

```bash
NTFY_SERVER=https://your-ntfy-server.com
```

### 3. GitHub Actions 定时跑

仓库里已经放了：

`/.github/workflows/daily_signal.yml`

要生效，只需要把项目推到 GitHub，然后在仓库 Secrets 里加：

- `NTFY_TOPIC`
- `NTFY_SERVER`（可选，不填默认 `https://ntfy.sh`）

这个工作流默认每 2 小时跑一次，也支持手动触发。

## 安全建议

- 不要把账号密码直接写进代码或文档。
- GitHub 侧建议使用仓库 Secret 或 PAT。
- 如果后面要换成 Firebase/APNs，再补正式推送链路。

## 回放与优化

运行小时级回放：

```bash
HOME=/Users/luzw/Desktop/news/binance_analyzer/.home \
/Users/luzw/flutter/bin/cache/dart-sdk/bin/dart run bin/hourly_replay_runner.dart
```

产物：

- `build/reports/hourly_replay_report.json`

完整算法说明见：

- `docs/REPLAY_STRATEGY.md`
- `docs/CLOUD_SCHEDULER_DEPLOY.md`
