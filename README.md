# Starry Test Harness

Rust 原型仓库，用于为 Kylin-X / Starry OS 构建分层自动化测试体系。目标是给研发、测试人员提供一个统一入口，可以在 PR、nightly、灰度阶段按层次执行不同类型的用例（ci/stress/daily），并输出可追踪的日志与报告。

## 关键特性

- **Rust 驱动**：`starry-test-harness` CLI 负责解析测试清单、执行脚本/二进制用例、生成 JSON 报告。
- **Make 统一入口**：遵循"`make <suite> <action>`"约定，例如 `make ci-test run`、`make daily-test publish`。
- **分层目录**：`tests/<suite>/suite.toml` 描述用例；CI 套件内包含 `cases/` Rust 工程 + `test-utils/` 辅助库 + `run_*.sh` 脚本，便于研发/测试统一扩展。
- **日志可追踪**：所有执行输出落在 `logs/<suite>/`，失败时还会写入 `error.log` 方便 CI 收集。
- **StarryOS 集成**：`ci-test` 会自动从 GitHub 拉取 StarryOS、编译镜像并在 QEMU 中验证 BusyBox Shell。
- **AArch64 关注**：默认面向 AArch64，后续再考虑别的架构。
- **用例模板**：`templates/rust-ci-case` 可配合 cargo-generate 快速生成标准化测试工程。

## 仓库结构

```
.
├── Cargo.toml               # Rust harness 配置
├── Makefile                 # make ci-test run / daily-test publish 等
├── scripts/
│   ├── build_stub.sh        # stress/daily 仍使用的占位 build
│   └── ci_build_starry.sh   # 借鉴 StarryOS 构建流程
├── src/
│   └── main.rs              # harness 主逻辑（clap + toml + 日志）
├── tests/
│   ├── ci/
│   │   ├── suite.toml       # CI 用例清单
│   │   ├── run_starry_boot.sh / run_rust_case.sh
│   │   ├── cases/            # Rust bin 用例 (Cargo.toml, src/bin/*.rs)
│   │   └── test-utils/       # 共享 helper 库 (Cargo.toml, src/lib.rs)
│   ├── stress/
│   │   └── suite.toml + cases/
│   └── daily/
│       └── suite.toml + cases/
├── logs/                    # 运行日志（含 .gitkeep）
├── reports/daily/           # publish 结果
└── .github/workflows/ci-test.yml
```

## 使用方式

```bash
make ci-test run          # PR/CI 基础功能
make stress-test run      # nightly 压力测试
make daily-test run       # 长稳并发测试
make daily-test publish   # 将最近一次 daily 结果导出到 reports/daily
make build                # 仅编译 Rust harness
```

> `make <suite> run/publish` 的第二个单词只是帮助 make 命令解析；真正执行逻辑在第一个目标里完成。

每次执行会：

1. 调 `scripts/ci_build_starry.sh`（ci-test）或 `scripts/build_stub.sh`（其余 suite）准备镜像，支持切换到 StarryOS 真机流程。
2. 解析 `tests/<suite>/suite.toml`，依序跑 `[[cases]]` 中的脚本/二进制。
3. 将 case 输出写到 `logs/<suite>/cases/<timestamp>/<case>.log`。
4. 生成 `logs/<suite>/<suite>-<timestamp>.log` 与 `logs/<suite>/last_run.json`。
5. 失败则写 `logs/<suite>/error.log` 并让命令以非零退出，方便 CI 感知。

`make daily-test publish` 会把 `logs/daily/last_run.json` 复制到 `reports/daily/summary-<timestamp>.json`，便于灰度版本归档。

## StarryOS 集成参数

- `STARRYOS_REMOTE`：要拉取的 Git 仓库地址，默认 `https://github.com/yeanwang666/StarryOS.git`。
- `STARRYOS_REF`：构建所用的分支/标签/提交，默认 `main`。
- `STARRYOS_ROOT`：StarryOS 的本地缓存目录，默认 `<repo>/.cache/StarryOS`。
- `STARRYOS_DEPTH`：浅克隆深度，可选；默认 0 表示完整历史。
- `CI_TEST_SCRIPT`：QEMU 启动脚本路径，默认 `${STARRYOS_ROOT}/scripts/ci-test.py`。

只要按需覆盖这些变量，本地或 CI 中执行 `make ci-test run` 就能自动完成"拉代码 → 构建 → 制作 rootfs → QEMU 启动验证"的完整链路。
> 依赖：需要可用的 `aarch64-linux-musl-*` 交叉工具链、`debugfs`（e2fsprogs）以及 `qemu-system-aarch64`、`Python 3`，可参考 Starry Tutorial Book 推荐的预编译包,启动命令中会用到 -serial tcp: (line 4444) 与 -drive file=disk.img，所以无需额外 GUI。

## 添加/维护用例

1. **生成骨架**：执行 `templates/add_ci_case.sh <binary_name> [display_name]` 自动在 `tests/ci/cases/src/bin/` 生成基础模板。
2. **完善逻辑**：根据提示在生成的 `run()` 中补全测试代码，可复用 `test-utils` 中的工具函数；失败时返回 `Err("原因".into())` 以便日志追踪。
3. **登记运行条目**：在 `tests/ci/suite.toml` 中新增 `[[cases]]`，大多数 Rust 二进制可直接复用 `tests/ci/run_rust_case.sh`，通过 `args = ["<binary_name>", "<optional_dest>"]` 指定要运行的目标；若只需主机验证，可设置 `SKIP_DISK_IMAGE=1` 跳过写盘（示例：`SKIP_DISK_IMAGE=1 cargo run -- ci-test run`）。
4. **如需自定义脚本**：特殊流程（如额外预处理/后处理）可以依旧编写独立的 `run_*.sh`，并在 `path` 中指向该脚本。
5. **本地验证**：执行 `make <suite> run` 或直接运行脚本，检查 `logs/<suite>/` 下是否产生日志。

> 常用环境变量：`STARRYOS_DISK_IMAGE` 指向 rootfs（默认 `.cache/StarryOS/arceos/disk.img`）；`TARGET_TRIPLE` 控制 `cargo build --target`；`STARRYOS_TEST_PATH` 指定写入镜像内的路径；`SKIP_DISK_IMAGE=1` 仅运行主机版测试。

## CI 流程

- `.github/workflows/ci-test.yml` 参考 StarryOS 的 workflow：并发保护、Rust 缓存、Musl 工具链与 QEMU 安装均自动完成。
- 步骤仅需 checkout 本仓库；`scripts/ci_build_starry.sh` 会 clone StarryOS、同步子模块并执行 `make build` / `make img`。
- 若想固定特定分支或自建镜像，可在 workflow env 中覆盖 `STARRYOS_REMOTE` / `STARRYOS_REF` / `STARRYOS_ROOT`。

## 下一步正在看

1. **扩展其他层级**：将 stress/daily/manual 也切换到真实 StarryOS 构建 / 执行路径。
2. **引入超时/并发调度**：在 Rust harness 中监听 case 运行时间，必要时强制 kill。
3. **CI 集成**：在 PR pipeline 中运行 `make ci-test run`，nightly 调 `make stress-test run`，灰度阶段调 `make daily-test run && make daily-test publish`。
4. **用例扩展**：把 musl/调度/资源抢占等真实脚本或 Rust 二进制放入 `tests/<tier>/cases/`。

通过该原型，测试与研发可以在统一仓库内新增脚本/二进制用例，`make`/Rust harness 会自动发现并执行，为后续引入更复杂的 QEMU/expect 流程做好准备。
