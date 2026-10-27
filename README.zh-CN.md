# Agent Island · AI 编程助手灵动岛

把 **Claude Code、Codex、Kimi Code、ZCode、MiniMax Code** 的会话进度放到 Mac 刘海上：哪些在跑、哪个在等你回答、哪个刚做完，一眼看清；点一下直接回到那条对话。

[English](README.md)

## 功能

| 能力 | 说明 |
| - | - |
| 实时状态 | 每 2 秒读一次：进行中 / 等你回答 / 没动静（2 小时无更新）/ 已完成 / 出错 / 已停止 |
| 收起态 | 刘海左侧旋转光环 + 思考文案，右侧活跃会话小点 + 数量；有人等你时橙色呼吸光 |
| 弹出提醒 | 完成 / 等你回答（显示问题原文）/ 出错时弹卡片，带提示音，可静音 |
| 会话列表 | 鼠标移到刘海展开；每行标出来自哪个助手；点一行跳到对应助手里的那条对话，命令行助手切到对应终端窗口 |
| 菜单栏 | 全部会话、「数据来源」按助手开关、打开助手、静音、开机自启、新手引导、卸载 |
| 隐私 | 只在本机只读各助手的本地状态文件，不联网、不上传、不需要任何 API Key |

## 支持的助手

| 助手 | 读取位置（只读） | 等你回答 | 点击跳转 | 验证情况 |
| - | - | - | - | - |
| Kimi Code 桌面端 | ~/.kimi-code | 批准请求、提问 | 侧栏点中 | 真机端到端实测 |
| ZCode 桌面端 | ~/.zcode | AskUserQuestion、计划确认 | 侧栏点中 | 真机端到端实测 |
| MiniMax Code 桌面端 | ~/.minimax*/v2/sqlite | 问卷 | 侧栏点中 | 合成数据测试（沿用 v1 已验证逻辑） |
| Claude Code（CLI / IDE） | ~/.claude/projects | AskUserQuestion、ExitPlanMode（权限弹窗不落盘，显示为进行中） | 终端 / 编辑器窗口 | 合成数据测试 |
| Codex（CLI / IDE / 桌面） | ~/.codex/sessions | 批准请求（取决于版本是否落盘） | 终端 / 编辑器 / App | 合成数据测试 |

## 安装

从 [Releases](../../releases) 下载 DMG，把 Agent Island 拖进「应用程序」，双击后跟着引导走（环境检查 → 辅助功能授权 → 开机自启）。App 暂未公证，第一次打开需要在「系统设置 → 隐私与安全性」点「仍要打开」，详见 [首次打开说明](docs/FIRST_OPEN.md)。

要求：macOS 14 及以上，Apple 芯片和 Intel 都可以。

## 开发

    bash scripts/build.sh                    # 编译通用二进制 + 签名 + DMG + zip → build/
    node --test test/adapters.test.mjs       # 适配器测试（合成数据，不碰真实数据）

新增一个助手：在 Sources/ 下新建一个实现 AgentSource 的文件，把它的本地状态映射成统一的会话状态，然后加到 Agents.all 里，再补一条合成数据测试。详见英文 README 的 “Adding another agent”。

## 许可

MIT
