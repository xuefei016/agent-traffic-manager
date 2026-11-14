# 版本记录

## 1.7.0

- 新增 Grok 订阅额度：读取 Grok CLI 登录（`~/.grok/auth.json`），走 `cli-chat-proxy.grok.com/v1/billing?format=credits` 只读接口，不发起推理、不消耗额度。
- 菜单栏新增 Grok 剩余百分比，按账号自己的周期（当前为每周）显示，不随 Codex/Claude 的 5 小时/每周开关变化；菜单详情含重置时间、套餐（SuperGrok）与续费日期、按产品的用量归因。
- 凭证过期时自动调用 Grok CLI（`grok models`，无副作用）续期；续期仍失败才提示手动 `grok login`。
- **B.AI 从 Claude 的子选项拆成独立来源**：菜单栏并列 Codex · Claude · B.AI · DeepSeek · Grok，各自独立缓存、退避与显示开关；Claude 只代表官方订阅，不再承载「官方 / 第三方」切换。
- `status.json` 新增 `grok*` 与独立 `bai*` 字段，`--check-grok`、`--check-bai` 可独立核对。

## 1.6.5

- 整理独立 Agent 流量管家源码项目，派生自 Carolyn-ai/codex-battery，保留原 MIT 许可证。
- 文字菜单栏支持 Codex、Claude 官方订阅、第三方 B.AI Credits 与 DeepSeek 余额。
- Codex / Claude 官方共用 5 小时（默认）与每周周期选项。
- B.AI 百万以上使用 M 缩写；精确积分保留在菜单详情与状态文件。
- B.AI 密钥遮罩输入支持 ⌘V 和剪贴板按钮，存入 Keychain。
- DeepSeek 今日消费为余额差分估算，支持手动校准；充值、采样缺口等限制见 README。
- 启动不弹说明窗口；保留公开消息、倒计时、隔离演示和安装保护。
- 更新安装、隐私和开发文档，移除旧版自动发布流程，保留 macOS 源码 CI。

## 上游历史

此前 Codex 功能与发布历史见 [上游项目](https://github.com/Carolyn-ai/codex-battery)。
