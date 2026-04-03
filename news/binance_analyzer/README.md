# 币安自选币分析推荐 - Flutter App

一个基于币安公开API的自选币涨幅分析与每日买入推荐工具。

---

## 功能特点

- **实时行情**：自动获取币安24小时行情数据，每30秒自动刷新
- **智能评分**：三维度综合评分（动量 + 价格位置 + 成交量）
- **今日推荐**：自动筛选当日最具买入价值的币种
- **分级标签**：强烈推荐 / 推荐买入 / 可以考虑 / 暂不推荐
- **筛选排序**：按推荐等级筛选，按评分/涨幅/成交量排序
- **24h区间**：可视化展示价格在当日区间中的位置
- **Binance风格**：深色主题，黄黑配色

---

## 评分算法说明

| 维度 | 权重 | 说明 |
|------|------|------|
| 动量分 | 45% | 24h涨幅在+1%~+8%得分最高；大跌或暴涨均降分 |
| 位置分 | 30% | 价格在24h区间中越低得分越高（有上涨空间） |
| 成交量 | 25% | 对数归一化，高成交量信号更可靠 |

**加分项**：正动量 + 价格仍在区间低位（趋势初期），额外+12%

**推荐等级**：
- 🟢🟢 强烈推荐：综合分 ≥ 72
- 🟢 推荐买入：综合分 58~72
- 🟡 可以考虑：综合分 42~58
- 🔴 暂不推荐：综合分 < 42

---

## 自选币列表

当前内置33个自选币（与用户币安自选一致）：

```
MYX, TON, SSV, GALA, NEIRO, BOME, APT, ARK, CHR, AVAX,
LTC, XRP, NFP, FET, OG, PHB, HIGH, LUNA, FTT, STX,
MAGIC, STG, API3, MANA, MASK, MDT, OP, LINK, HFT, LQTY,
ICX, LDO, ID
```

如需修改，编辑 `lib/services/binance_service.dart` 中的 `watchlistRaw` 列表。

---

## 快速开始

### 前置条件
- Flutter SDK 3.10+（推荐 3.19+）：https://flutter.dev/docs/get-started/install
- Dart 3.0+（Flutter自带）
- Android Studio 或 VS Code（安装Flutter插件）

### 安装步骤

```bash
# 1. 进入项目目录
cd binance_analyzer

# 2. 安装依赖
flutter pub get

# 3. 连接设备（手机开启USB调试，或启动模拟器）
flutter devices

# 4. 运行应用
flutter run

# 5. 构建发布版（可选）
flutter build apk --release   # Android
flutter build ipa             # iOS（需Mac）
```

### 运行在不同平台
```bash
flutter run -d android   # Android设备/模拟器
flutter run -d ios       # iPhone/模拟器（需Mac）
flutter run -d macos     # macOS桌面
flutter run -d windows   # Windows桌面
flutter run -d chrome    # 浏览器（注意CORS限制）
```

> ⚠️ **浏览器运行注意**：在Chrome运行时可能遇到CORS跨域问题（币安API不支持浏览器直接调用）。建议在手机或桌面端运行。

---

## 项目结构

```
lib/
├── main.dart                  # 应用入口
├── theme/
│   └── app_theme.dart         # 暗色主题（Binance风格）
├── models/
│   └── coin_data.dart         # 行情数据模型
├── services/
│   └── binance_service.dart   # 币安API接口
├── utils/
│   └── coin_analyzer.dart     # 评分算法
├── screens/
│   └── home_screen.dart       # 主界面
└── widgets/
    ├── coin_card.dart          # 单币种卡片
    └── top_picks_section.dart  # 今日推荐区
```

---

## 免责声明

> 本工具仅供学习参考，**不构成任何投资建议**。加密货币市场风险极高，请自行决策并做好风险管理。
