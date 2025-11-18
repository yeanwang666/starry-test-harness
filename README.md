# Starry Test Harness

基于 Rust 构建的原型仓库，用于为 Starry OS 构建分层自动化测试体系。目标是给研发、测试人员提供一个统一入口，可以在 PR、nightly、灰度阶段按层次执行不同类型的用例（ci/stress/daily），并输出可追踪的日志与报告。

## 仓库结构

```
.
├── Cargo.toml               # Rust harness 配置
├── Makefile                 # 顶层入口 (例如 make ci-test run)
├── scripts/
│   └── build_starry.sh      # 编译 StarryOS 内核并准备 rootfs 模板
├── src/
│   └── main.rs              # Harness 主逻辑 (解析 suite.toml, 调度测试)
├── tests/
│   ├── ci/
│   │   ├── suite.toml       # CI 套件: 用例清单
│   │   ├── run_starry_boot.sh # CI 用例: 启动验证脚本
│   │   ├── run_case.sh      # CI 用例: Rust 测试用例运行器
│   │   └── cases/           # CI 用例: 所有 Rust 测试源码 (一个 Crate)
│   ├── stress/
│   │   ├── suite.toml       # Stress 套件: 用例清单
│   │   ├── run_case.sh      # Stress 用例: 统一运行器脚本
│   │   └── cases/           # Stress 用例: 各测试源码 (每个都是独立 Crate)
│   └── daily/
│       ├── suite.toml       # Daily 套件: 用例清单
│       ├── run_case.sh      # Daily 用例: 统一运行器脚本
│       └── cases/           # Daily 用例: 各测试源码 (每个都是独立 Crate)
├── logs/                    # 本地运行日志
└── .github/workflows/ci-test.yml
```

## 运行流程 / 快速开始

当执行 `make <suite-name> run` (例如 `make stress-test run`) 时，框架会自动执行以下步骤：

1.  **Harness 启动**: `Makefile` 调用 Rust 编写的 `starry-test-harness` 程序。
2.  **环境与内核构建**: Harness 首先执行 `scripts/build_starry.sh`，该脚本负责：
    *   自动安装并切换到指定的 **Rust nightly** 工具链及所需组件 (`aarch64` 目标, `llvm-tools`)。
    *   克隆或更新 StarryOS 仓库代码。
    *   编译 StarryOS 内核 (`.bin` 文件)。
    *   下载 `rootfs` 模板镜像 (如果本地没有)。
3.  **用例迭代执行**: Harness 解析对应 `tests/<suite-name>/suite.toml` 文件，并依次执行其中定义的每个测试用例。
4.  **动态镜像生成与测试**:
    *   **CI 套件**: `run_case.sh` 会交叉编译 Rust 测试二进制，复制一个全新的临时磁盘镜像，使用 `debugfs` 注入测试二进制，然后启动 QEMU 在虚拟机内执行。Rust 测试框架的退出码直接决定 PASS/FAIL。
    *   **Stress/Daily 套件**: 类似流程，但测试程序必须在标准输出打印包含 `status: "pass"` 或 `status: "fail"` 的 JSON 对象，框架会捕获并解析该 JSON 来判断成功或失败。
5.  **结果汇总与日志**:
    *   所有用例执行完毕后，框架会生成汇总报告和详细日志，存放在 `logs/<suite-name>/<timestamp>/` 目录中。

这个流程确保了每次测试都在一个**干净、隔离**的环境中进行，避免了用例间的相互干扰。


### Stress 套件快速参考
-目前先把一些边迭代边开发的测试放到stress里，以便CI test稳定为主线测试服务，一般每个测试都是一个cargo工程，里面自己添加需要的文件等，自己写测试逻辑。可以参考目录下别人的文件，需要遵守下面添加stress测试用例的规则。
- 路径：`tests/stress/`
  - 运行器：`tests/stress/run_case.sh`。负责编译单个用例、复制 rootfs 模板、用 debugfs 写入 `/usr/tests/<case_id>`，启动 QEMU 并解析 JSON 输出。
  - 套件清单：`tests/stress/suite.toml`。
  - 用例目录：`tests/stress/cases/<case_id>/`，每个都是独立 Cargo 工程。
- 单独运行某个用例：
  - 推荐：`CASES=<suite.toml里的name> make stress-test run`（例如 `CASES=sqlite-fixture`）。
  - 直接脚本：`tests/stress/run_case.sh <case_id> [args...]`（默认无 CASES 过滤，确保 rootfs 模板存在）。
- 输出与日志：
  - suite 日志目录：`logs/stress/<timestamp>/`
  - 用例日志：`logs/stress/<timestamp>/cases/<case>.log`
  - 结果 JSON：`logs/stress/<timestamp>/artifacts/<case>/result.json`

## 如何添加测试用例

### 添加 Stress / Daily 测试用例

`stress` 与 `daily` 套件的用例是独立的 `Cargo` 工程，适合复杂的、自成一体的测试场景。

1.  **创建用例工程**:
    在 `tests/stress/cases/` 或 `tests/daily/cases/` 目录下，创建一个新的子目录作为你的 Cargo 工程。目录名 (`<case_id>`) 需要与包名保持一致。
    *   `tests/stress/cases/<case_id>/Cargo.toml`
    *   `tests/stress/cases/<case_id>/src/main.rs`

2.  **实现测试逻辑**:
    在 `main.rs` 中编写你的测试代码。程序结束时，**必须向标准输出打印一个 JSON 对象**，其中 `status` 字段是必需的。

    ```rust
    use serde::Serialize;
    
    #[derive(Serialize)]
    struct TestResult {
        status: &'static str,
        // ... 其他自定义字段
    }

    fn main() {
        // ... 你的测试逻辑 ...
        let result = TestResult { status: "pass", /* ... */ };
        println!("{}", serde_json::to_string(&result).unwrap());
    }
    ```

3.  **在 `suite.toml` 中注册**:
    打开 `tests/stress/suite.toml` (或 `daily` 的)，添加一个新的 `[[cases]]` 条目。

    ```toml
    [[cases]]
    name = "my-new-stress-test"
    description = "描述我的新压力测试"
    path = "tests/stress/run_case.sh"  # 固定指向统一的运行器
    args = ["<case_id>", "arg1", "arg2"] # 第一个参数必须是你的包名/目录名
    timeout_secs = 600
    ```
    *   `path`: 固定指向 `tests/<suite>/run_case.sh`。
    *   `args`: 数组的第一个元素必须是你的 `<case_id>` (Cargo 包名)，后续元素会作为命令行参数传递给你的程序。

### 添加 CI 测试用例

`ci` 套件的所有用例共享同一个 `Cargo` 工程 (`tests/ci/cases/`)，适合小型的、可以快速编译的单元测试或冒烟测试。

1.  **生成骨架 (推荐)**:
    执行 `templates/add_ci_case.sh` 脚本可以快速生成一个测试用例模板。

    ```bash
    # 用法: ./templates/add_ci_case.sh <case_name>
    ./templates/add_ci_case.sh my_ci_test
    ```
    该命令会在 `tests/ci/cases/tests/` 目录下创建一个 `my_ci_test.rs` 文件，并提示下一步需要做的修改。

2.  **实现测试逻辑**:
    打开新生成的 `my_ci_test.rs` 文件，使用 `#[test]` 函数编写断言。
    > **注意**: CI 用例完全依赖 Rust 原生测试框架，断言失败会自动标记为失败，无需手动打印 `PASS/FAIL`。

3.  **在 `suite.toml` 中注册**:
    根据上一步脚本的提示，打开 `tests/ci/suite.toml` 并添加对应的 `[[cases]]` 条目。

    ```toml
    [[cases]]
    name = "my-ci-test"
    path = "tests/ci/run_case.sh" # 固定指向 CI 的运行器
    args = ["my_ci_test"]               # args[0] 是你的测试文件名 (不含 .rs)
    ```

    harness 会自动把交叉编译好的测试二进制写入 StarryOS 镜像，并在虚拟机内执行该程序；Rust 测试框架返回的退出码会直接作为 PASS/FAIL。

## 超时配置

测试用例在虚拟机内的执行时间受 `suite.toml` 中的 `timeout_secs` 控制：

- **全局默认超时**：`default_timeout_secs`（CI 套件当前为 300 秒）。
- **单个用例超时**：在 `[[cases]]` 中设置 `timeout_secs = <秒数>` 可覆盖默认值。

示例：
```toml
[[cases]]
name = "long-running-test"
path = "tests/ci/run_case.sh"
args = ["my_test"]
timeout_secs = 1200  # 单独为这个用例设置 20 分钟超时
```

如果测试用例运行时间较长被提前终止，请根据实际需要调整对应的 `timeout_secs` 或 `default_timeout_secs`。

## 依赖与环境

本地运行需要以下工具：
- `rustup` 及 **nightly** 工具链。
- `qemu-system-aarch64`
- `debugfs` (通常包含在 `e2fsprogs` 包中)
- `python3`

## CI/CD

`.github/workflows/ci-test.yml` 已经配置好所有依赖的安装和缓存，并会自动执行 `make ci-test run`。

- `STARRYOS_REMOTE`: StarryOS 仓库地址（默认：https://github.com/kylin-x-kernel/StarryOS.git）。
- `STARRYOS_REF`: StarryOS 分支/标签。
- `STARRYOS_ROOT`: StarryOS 本地克隆路径。

这些环境变量可以在 workflow 文件中修改，以适配不同的测试目标。
