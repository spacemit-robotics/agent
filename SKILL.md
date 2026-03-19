---
name: spacemit-robot
description: "进迭时空机器人 SDK：安装、编译、方案选择、模块能力调用。当用户提到 SpacemiT、进迭时空、机器人SDK、编译、构建方案、下载SDK、语音识别、大模型、电机、雷达 等机器人相关能力时使用。"
metadata:
  openclaw:
    emoji: "🤖"
    os: ["linux"]
    requires:
      bins: ["repo"]
---

# SpacemiT Robot SDK

进迭时空机器人 SDK，包含 AI 模型（语音识别/合成/大模型/视觉）、外设驱动（电机/雷达/IMU/NFC）、语音交互应用等完整机器人能力栈。

通过 repo 多仓工具管理，编译产物统一输出到 `%SDK_ROOT%/output/staging/`。

## 工作流程（必须严格遵守）

**重要规则：**
- 不要凭自身知识直接执行 SDK 命令，必须从 MODULE.md 获取精确的命令和参数
- 不要跳过 preflight 检查，即使你认为环境已就绪
- 不要从 README 或其他文档中提取运行命令，MODULE.md 是唯一的操作依据

每次收到用户请求时，必须按以下步骤执行：

1. 执行 `%SDK_ROOT%/agent/scripts/discover.sh --json` 了解所有可用模块和编译状态
2. 根据用户需求定位到具体模块
3. 执行 `%SDK_ROOT%/agent/scripts/preflight.sh <模块名>` 检查前置条件
4. 如果结果为 NOT_READY，按输出的 `[ACTION]` 逐条执行（构建/下载模型/检查硬件等）
5. 读取该模块目录下的 `MODULE.md` 获取详细操作指南（路径见 discover 输出的 path 字段，前缀为 `%SDK_ROOT%/`）
6. 严格按 MODULE.md 中的命令和参数执行，不要自行修改或替换

## 运行编译产物

编译产物在 `%SDK_ROOT%/output/staging/bin/` 下，运行时需要设置库路径：

```bash
export LD_LIBRARY_PATH=%SDK_ROOT%/output/staging/lib:${LD_LIBRARY_PATH:-}
%SDK_ROOT%/output/staging/bin/<可执行文件> <参数>
```

## 安装 SDK

```bash
sudo apt install repo cmake jq python3

mkdir spacemit_robot && cd spacemit_robot

# GitHub
repo init -u https://github.com/spacemit-robotics/manifest.git -b main -m default.xml
repo sync -j4
repo start robot-dev --all

# Gitee（国内更快）
repo init -u https://gitee.com/spacemit-robotics/manifest.git -b main -m default.xml
repo sync -j4
repo start robot-dev --all

# 注册 AI skill
bash agent/install.sh
```

## 构建

无交互方式（推荐 AI 使用）：
```bash
BUILD_TARGET_FILE=%SDK_ROOT%/target/<方案名>.json %SDK_ROOT%/build/build.sh all
```

单模块构建：
```bash
BUILD_TARGET_FILE=%SDK_ROOT%/target/<方案名>.json %SDK_ROOT%/build/build.sh package <模块路径>
```

查看可用构建方案：
```bash
%SDK_ROOT%/agent/scripts/discover.sh --targets
```

## 查看模块能力

```bash
%SDK_ROOT%/agent/scripts/discover.sh --json   # JSON 格式（推荐，便于解析）
%SDK_ROOT%/agent/scripts/discover.sh           # 简表（便于阅读）
```

## 检查模块前置条件

```bash
%SDK_ROOT%/agent/scripts/preflight.sh <模块名>
```

输出 `[RESULT] READY` 表示可以直接使用，`[RESULT] NOT_READY` 时按 `[ACTION]` 提示操作。
