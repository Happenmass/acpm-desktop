# Windows 托盘与运行控制台（预留目录）

本目录预留用于后续 **Windows x64** 桌面原生 UI 外壳（推荐 WinUI 3 或轻量原生系统托盘应用）。

## 对接方式

- 与 `apps/macos-console` 完全一样，Windows UI 壳本身**不包含任何调度与模型管理逻辑**，启动时拉起/连接共用内核 `acpmd.exe`。
- 通过 `%LOCALAPPDATA%\acpm-desktop\runtime.json` 发现并消费相同的控制面接口：
  - `GET /v1/system/status`
  - `GET /v1/system/events`（SSE 实时状态流）
  - `GET /v1/models`、`POST /v1/models/{id}/load|unload|download`
  - `GET /v1/system/failures`（最近 20 条脱敏失败记录）
