# Agent Island · AI 编程助手灵动岛

把 **Claude Code、Codex、Gemini CLI、DeepSeek Harness、Qwen Code、OpenCode、Kimi Code、ZCode、MiniMax Code** 的会话进度放到 Mac 刘海上：哪些在跑、哪个在等你回答、哪个刚做完，一眼看清；点一下直接回到那条对话。

[English](README.md) · [更新记录](CHANGELOG.md)

## 功能

| 能力 | 说明 |
| - | - |
| 实时状态 | 每 2 秒读一次：进行中 / 等你回答 / 没动静 / 已完成 / 出错 / 已停止 |
| 弹出提醒 | 完成 / 等你回答（显示问题原文）/ 出错时弹卡片，带提示音，可静音 |
| 会话列表 | 鼠标移到刘海展开；每行带助手自己的图标；点一行跳到对应助手里的那条对话，命令行助手切到对应终端窗口 |
| 菜单栏 | 全部会话、「数据来源」按助手开关、打开助手、下载缺失图标、接管 / 恢复刘海、静音、开机自启、新手引导、卸载 |
| 刘海归属 | 同一时间只跑一个实例；检测到别的刘海程序时默认让位，可一键接管，被停用的程序随时可恢复 |
| 隐私 | 只在本机只读各助手的本地状态文件；除你主动点「下载图标」外不联网 |

## 支持的助手

| 助手 | 读取位置（只读） | 等你回答 | 点击跳转 | 验证情况 |
| - | - | - | - | - |
| Kimi Code 桌面端 | ~/.kimi-code | 批准请求、提问 | 侧栏点中 | 真机端到端实测 |
| ZCode 桌面端 | ~/.zcode | 提问、计划确认 | 侧栏点中 | 真机端到端实测 |
| MiniMax Code 桌面端 | ~/.minimax*/v2/sqlite | 问卷 | 侧栏点中 | 合成数据测试 |
| Claude Code | ~/.claude/projects | 提问、计划确认（权限弹窗不落盘） | 终端 / 编辑器 | 合成数据测试 |
| Codex | ~/.codex/sessions | 批准请求 | 终端 / 编辑器 / App | 合成数据测试 |
| Gemini CLI | ~/.gemini/tmp/*/chats | 工具批准、ask_user | 终端 | 合成数据测试 |
| DeepSeek Harness（dsh） | ~/.dsh/sessions（支持 zstd 压缩日志） | 批准、ask_user_question | App / 终端 | 合成数据测试 |
| Qwen Code | ~/.qwen/projects/*/chats | ask_user_question | 终端 | 合成数据测试 |
| OpenCode | ~/.local/share/opencode/*.db | question 工具（旧版库） | App / 终端 | 合成数据测试 |

合成数据按各项目源码里的真实格式构造（见 test/adapters.test.mjs）。

## 刘海归属

刘海同一时间只能给一个程序。Agent Island 不管启动的是哪个副本、哪个版本，都只会有一个实例在跑；检测到其他刘海程序（旧版灵动岛、NotchNook、boring.notch 等）时默认让位，只留菜单栏图标（⏸）。在菜单里点「接管刘海」会退出对方，如果它有开机自启的 LaunchAgent，会把配置挪到 ~/Library/Application Support/AgentIsland/suspended 暂存（不删除）；点「恢复被停用的刘海程序」即可原样恢复。

## 图标

统一按这个顺序取：你自定义的图标 → 本机已安装的助手 App 图标 → 你主动从项目官方 GitHub 下载的图标 → 品牌色字母。仓库和 App 里都不打包任何第三方 logo，商标归各自所有者。

## 版本管理

VERSION 文件是唯一版本来源（语义化版本），构建号取提交数并写入提交哈希，「关于」、--version、--check 都会显示如 2.1.0 (build 3, a1b2c3d)，随时知道正在跑的是哪一份。每次发布打 vX.Y.Z 标签，变更写进 CHANGELOG.md。

## 安装

从 [Releases](../../releases) 下载 DMG，把 Agent Island 拖进「应用程序」，双击后跟着引导走。App 暂未公证，首次打开见 [首次打开说明](docs/FIRST_OPEN.md)。要求 macOS 14 及以上。

## 开发

    bash scripts/build.sh                    # 编译通用二进制 + 签名 + DMG + zip → build/
    node --test test/adapters.test.mjs       # 适配器测试（合成数据，不碰真实数据）

新增一个助手：在 Sources/ 下新建一个实现 AgentSource 的文件，把它的本地状态映射成统一的会话状态，加到 Agents.all，再补合成数据测试。

## 许可

MIT
