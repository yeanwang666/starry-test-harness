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
│   │   ├── run_rust_case.sh # CI 用例: Rust 测试用例运行器
│   │   └── cases/           # CI 用例: 所有 Rust 测试源码 (一个 Crate)
│   ├── stress/
│   │   ├── suite.toml       # Stress 套件: 用例清单
│   │   ├── run_case.sh      # Stress 用例: 统一运行器脚本
│   │   └── cases/           # Stress 用例: 各测试源码 (每个都是独立 Crate)
│   └── daily/
│       └── suite.toml + cases/
├── logs/                    # 本地运行日志
└── .github/workflows/ci-test.yml
```

## 运行流程

当执行 `make <suite-name> run` (例如 `make stress-test run`) 时，框架会自动执行以下步骤：

1.  **Harness 启动**: `Makefile` 调用 Rust 编写的 `starry-test-harness` 程序。
2.  **环境与内核构建**: Harness 首先执行 `scripts/build_starry.sh`，该脚本负责：
    *   自动安装并切换到指定的 **Rust nightly** 工具链及所需组件 (`aarch64` 目标, `llvm-tools`)。
    *   克隆或更新 StarryOS 仓库代码。
    *   编译 StarryOS 内核 (`.bin` 文件)。
    *   下载 `rootfs` 模板镜像 (如果本地没有)。
3.  **用例迭代执行**: Harness 解析对应 `tests/<suite-name>/suite.toml` 文件，并依次执行其中定义的每个测试用例。
4.  **动态镜像生成与测试**: 对于每个用例，`run_case.sh` (或 `run_rust_case.sh`) 脚本会：
    *   编译当前用例的 Rust 代码，生成一个测试二进制文件。
    *   从 `rootfs` 模板**复制一个全新的、临时的磁盘镜像**。
    *   使用 `debugfs` 将测试二进制文件**注入**到这个临时镜像中。
    *   启动 QEMU，并加载这个包含测试程序的镜像来执行测试。
5.  **结果解析与报告**:
    *   用例在虚拟机中运行结束后，必须在标准输出打印一个包含 `status: "pass"` 或 `status: "fail"` 的 JSON 对象。
    *   框架会自动捕获并解析这个 JSON，判断用例是否成功，并记录详细日志。

这个流程确保了每次测试都在一个**干净、隔离**的环境中进行，避免了用例间的相互干扰。

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
    # 用法: ./templates/add_ci_case.sh <binary_name>
    ./templates/add_ci_case.sh my_ci_test
    ```
    该命令会在 `tests/ci/cases/src/bin/` 目录下创建一个 `my_ci_test.rs` 文件，并提示下一步需要做的修改。

2.  **实现测试逻辑**:
    打开新生成的 `my_ci_test.rs` 文件，在 `run()` 函数中编写你的测试代码。
    > **注意**: CI 用例的模板与 stress/daily 不同，它不要求输出 JSON。成功时返回 `Ok(())`，失败时返回 `Err("原因".into())` 即可。框架会自动处理日志和状态。

3.  **在 `suite.toml` 中注册**:
    根据上一步脚本的提示，打开 `tests/ci/suite.toml` 并添加对应的 `[[cases]]` 条目。

    ```toml
    [[cases]]
    name = "my-ci-test"
    path = "tests/ci/run_rust_case.sh" # 固定指向 CI 的运行器
    args = ["my_ci_test"]               # args[0] 是你的文件名 (不含 .rs)
    ```

## 依赖与环境

本地运行需要以下工具：
- `rustup` 及 **nightly** 工具链。
- `qemu-system-aarch64`
- `debugfs` (通常包含在 `e2fsprogs` 包中)
- `python3`

## CI/CD

`.github/workflows/ci-test.yml` 已经配置好所有依赖的安装和缓存，并会自动执行 `make ci-test run`。

- `STARRYOS_REMOTE`: StarryOS 仓库地址。
- `STARRYOS_REF`: StarryOS 分支/标签。
- `STARRYOS_ROOT`: StarryOS 本地克隆路径。

这些环境变量可以在 workflow 文件中修改，以适配不同的测试目标。