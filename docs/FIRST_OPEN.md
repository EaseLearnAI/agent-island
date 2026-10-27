# 首次打开 / First open

## 中文

1. 打开 DMG，把「Agent Island」拖进右边的「应用程序」文件夹。
2. 在「应用程序」里双击 Agent Island。
3. 如果提示“无法验证开发者”或“Apple 无法检查其是否包含恶意软件”：点「完成」（不要移到废纸篓）→ 打开「系统设置 → 隐私与安全性」，滚到最下面，点「仍要打开」→ 再双击一次 App，点「打开」。
   会用终端的话也可以：xattr -dr com.apple.quarantine /Applications/AgentIsland.app
4. 跟着新手引导走：环境检查（检测到哪些助手）→ 辅助功能授权 → 开机自启。

辅助功能权限只用来在助手侧栏里点中你选的那条对话、或把对应的终端窗口提到最前；不读取输入，也不看屏幕内容。

## English

1. Open the DMG and drag **Agent Island** into Applications.
2. Double-click it in Applications.
3. If macOS says the developer cannot be verified: click Done, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then open the app again.
   Or in Terminal: xattr -dr com.apple.quarantine /Applications/AgentIsland.app
4. Follow the onboarding: environment check → Accessibility permission → launch at login.

Accessibility is only used to click the session row in the agent's sidebar or raise the terminal window running a CLI agent.
