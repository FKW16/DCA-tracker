# DCA Tracker

DCA Tracker 是一款仅在 Mac 本地运行的美股定投记录与规划应用。它使用原生 SwiftUI、SwiftData 和 Swift Charts 开发，无需注册账号，也不依赖自建服务端。

当前版本属于**本地开发测试版**，适合个人试用和验证投资记录流程，不构成投资建议，也不会连接券商或自动下单。

## 主要功能

- DCA（定额定投）策略
- 唯一全局月度 DCA 计划，可编辑各标的启用状态与目标权重
- 在月度预算内优化非负整数股建议，显示预计花费、剩余现金及买后权重
- 买入、卖出和股息数据模型，以及移动平均成本收益计算内核
- Twelve Data 实时行情刷新（个股报价），失败时使用最后缓存或手工价格
- 净持仓市值结构（扇区图 + 图例）、券商账户持仓结构、按自然月汇总的月度投入
- 手动新增、编辑和删除买入、卖出及股息记录
- CSV 台账和完整 JSON 备份导出（当前不提供文件导入）
- API Key 保存在 macOS 钥匙串中

## 系统要求

- macOS 14 或更高版本
- Apple Silicon 或 Intel Mac
- 如需自动行情：一个 Twelve Data API Key

使用 DMG 安装不需要 Xcode。只有从源码构建时才需要完整版 Xcode（建议使用当前 App Store 最新稳定版）；VS Code 可以用于编辑源码，但不能替代 Xcode 提供的 macOS SDK 和工具链。

## 使用 DMG 安装

1. 双击 `DCA-Tracker-1.0.dmg`。
2. 将 `DCATracker` 拖到窗口中的“应用程序”文件夹。
3. 在 Finder 的“应用程序”中打开 `DCATracker`。

当前 DMG 是未公证的本地测试版本。如果 macOS 阻止首次启动，请在 Finder 中按住 Control 点击应用，选择“打开”，再确认一次；也可以前往“系统设置 → 隐私与安全性”允许打开。请只安装来自可信来源的副本。

## 从源码安装与运行

### 1. 安装 Xcode

从 Mac App Store 安装 Xcode。首次安装后，在“终端”执行：

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -version
```

最后一条命令能正常显示 Xcode 版本即表示环境就绪。

### 2. 打开工程

在 Finder 中双击 `DCATracker.xcodeproj`，或者在项目目录执行：

```bash
open DCATracker.xcodeproj
```

### 3. 运行应用

1. 在 Xcode 顶部选择 scheme `DCATracker`。
2. 运行目标选择 `My Mac`。
3. 点击运行按钮，或按 `Command + R`。
4. 首次构建完成后，应用会自动启动。

本地调试通常不需要 Apple Developer 付费账号。如果 Xcode 提示签名问题，可在 Target 的 **Signing & Capabilities** 中选择自己的 Personal Team，或仅使用下面的无签名命令行构建。

### 4. 命令行构建和测试（可选）

在项目根目录执行：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild \
  -project DCATracker.xcodeproj \
  -scheme DCATracker \
  -destination 'platform=macOS,arch=arm64' \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project DCATracker.xcodeproj \
  -scheme DCATracker \
  -destination 'platform=macOS,arch=arm64' \
  test CODE_SIGNING_ALLOWED=NO
```

Intel Mac 请将 `arch=arm64` 改为 `arch=x86_64`。当前测试集覆盖收益计算、DCA 策略、行情回退、SwiftData 模型和备份序列化。

## 首次使用

建议按下面顺序配置。

### 1. 新建券商账户

进入侧栏的**券商账户**，填写账户名称并创建账户。账户用于区分不同券商中的交易和持仓。

### 2. 添加投资标的

进入**投资标的**：

1. 输入股票或 ETF 代码，例如 `VTI`、`QQQ`。
2. 如暂未配置自动行情，可填写手工价格。
3. 点击添加。股票代码保存时会自动转换为大写。

### 3. 配置 Twelve Data 行情（可选）

1. 在 Twelve Data 官网注册并取得 API Key。
2. 打开应用的**设置**页面。
3. 在 Twelve Data 区域输入 API Key，点击**保存**。
4. 回到**投资标的**页面，点击**刷新全部关注标的**。

API Key 仅存放于 macOS 钥匙串，不会写入数据库、日志或 JSON 备份。免费套餐可能存在请求频率限制；刷新失败时，应用会继续使用最后一次成功价格，再回退到手工价格。每个价格旁会显示缓存更新时间。

### 4. 手动添加投资记录

1. 先确保已经添加至少一个券商账户和投资标的。
2. 进入**交易台账**，点击左上角**新增投资记录**。
3. 选择买入、卖出或股息，以及对应账户和标的。
4. 填写日期和金额字段：
   - 买入/卖出：数量、成交单价、手续费。
   - 股息：税前股息、预扣税、实际到账金额。
5. 可选填写备注，然后点击保存。应用以美元记账，不提供汇率输入或换算。

卖出数量不能超过该账户下对应标的的当前持仓。

### 5. 配置 DCA 计划（可选）

进入 **DCA 计划**：

1. 输入每月新增资金。
2. 启用计划中的标的并填写目标比例。金额和有效配置会自动保存，下次打开时自动恢复。
3. 点击**生成本期建议**。所有启用比例必须大于 0 且合计 100%，否则页面会显示错误。
4. 检查整数股、预计花费、剩余现金和买后权重。
5. 实际在券商成交后，点击**确认记为买入**。

“确认记为买入”会创建本地买入记录，但不会向券商发送订单。建议先核对实际成交价和数量，再到交易台账中编辑成券商的真实数据。

### 6. 管理交易

进入**交易台账**可以：

- 按买入、卖出或股息类型筛选
- 编辑日期、数量、价格、手续费、股息和备注
- 删除记录；删除前会再次确认
- 导出当前台账为 CSV

账户、标的和 DCA 计划都可编辑。交易修改后，持仓和收益会根据完整台账重新计算。

### 7. 查看总览

**总览**页面展示累计投入、当前市值和浮动差额，并提供：

- 持有仓位明细表（标的/股数/现价/平均成本/现值/比例/涨跌幅，支持拖动排序）
- 按市值降序的净持仓市值结构（扇区图 + 图例）
- 按自然月汇总的月度投入
- 按券商账户统计的净持仓市值饼图
- 一键刷新个股行情
- 持仓报告自动同步到项目目录 `holdings-report.md`，并支持手动导出 Markdown

所有美元金额统一显示为 `1,234.56 $`。缺价标的会被明确列出，不会伪造为零。

## 数据导出

### 完整 JSON 备份

在**交易台账**中点击**导出完整 JSON**，选择保存位置。完整备份包含：

- 券商账户
- 投资标的和非敏感行情缓存
- 标签
- 投资组合、资产权重和定投计划
- 计划执行记录
- 买入、卖出和股息记录
- 非敏感设置

备份**不包含 Twelve Data API Key**。备份文件含有个人投资数据，请勿上传到公开仓库或公开网盘。

### CSV 导出

CSV 适合使用 Numbers 或 Excel 查看交易台账。当前版本仅提供 CSV 和 JSON 导出，不提供 CSV/JSON 文件导入或恢复入口。

## 本地数据与隐私

- SwiftData 数据库和行情缓存保存在 macOS 管理的应用数据目录，不写入源码目录。
- Twelve Data API Key 保存在系统钥匙串。
- 应用没有账号、后端和云同步。
- 应用不会读取券商现金余额，也不会自动交易。
- 删除应用程序本体不一定会同时删除 Application Support 中的数据。

如需彻底清除测试数据，可先导出备份，再删除应用对应的 Application Support 数据和钥匙串中的 Twelve Data 项目。操作前务必确认路径，避免误删其他应用数据。

## 常见问题

### `xcodebuild` 提示当前目录是 Command Line Tools

执行：

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

或者仅对当前终端设置：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

### 行情刷新失败

请依次检查 API Key、网络连接、标的代码和 Twelve Data 套餐限额。HTTP 429 表示触发频率限制。失败时不会清除上次成功缓存，可继续使用缓存或手工价格。

### 策略提示权重不等于 100%

启用标的的目标权重必须为正且合计 100%。明显错误会在点击“生成本期建议”后显示，且不会生成建议。

## 当前版本限制

- 当前为个人本地测试版，尚未进行公证、签名分发或 Mac App Store 发布。
- 当前 UI 支持账户、标的、月度 DCA 计划、自定义权重、整数股建议、行情、手动交易录入和台账维护。
- Twelve Data 是首个行情源，行情可能延迟且受 API 套餐限制。
- 策略建议仅用于规划，最终交易数量和价格应以券商成交记录为准。
- 不支持自动下单、券商同步、云同步和 iPhone 版本。

## 技术栈

- Swift 6
- SwiftUI
- SwiftData
- Swift Charts
- XCTest
- Foundation `URLSession`
- macOS Keychain（Security）

## 免责声明

本项目仅用于个人投资记录和软件开发学习。应用生成的收益、年化收益、行情和定投建议可能受到数据延迟、录入错误及计算假设影响，不构成任何投资建议或收益承诺。
