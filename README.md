# Starry Test Harness

Rust 原型仓库，用于为 Kylin-X / Starry OS 构建分层自动化测试体系。目标是给研发、测试同学提供一个统一入口，可以在 PR、nightly、灰度阶段按层次执行不同类型的用例（ci/stress/daily），并输出可追踪的日志与报告。

## 关键特性

- **Rust 驱动**：`starry-test-harness` CLI 负责解析测试清单、执行脚本/二进制用例、生成 JSON 报告。
- **Make 统一入口**：遵循“`make <suite> <action>`”约定，例如 `make ci-test run`、`make daily-test publish`。
- **分层目录**：`tests/ci|stress|daily` 保存 manifest（`suite.toml`）和脚本，开发/测试可直接追加用例。
- **日志可追踪**：所有执行输出落在 `logs/<suite>/`，失败时还会写入 `error.log` 方便 CI 收集。
- **StarryOS 集成**：`ci-test` 会自动从 GitHub 拉取 StarryOS、编译镜像并在 QEMU 中验证 BusyBox Shell。
- **AArch64 关注**：默认面向 AArch64，后续再考虑别的架构。

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
├── templates/
│   └── case_template.sh     # 新脚本用例模板
├── tests/
│   ├── ci/
│   │   ├── suite.toml       # 清单：run.sh/a.sh/b.sh/sqlite.sh
│   │   └── cases/
│   ├── stress/
│   │   ├── suite.toml
│   │   └── cases/
│   └── daily/
│       ├── suite.toml
│       └── cases/
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

只要按需覆盖这些变量，本地或 CI 中执行 `make ci-test run` 就能自动完成“拉代码 → 构建 → 制作 rootfs → QEMU 启动验证”的完整链路。

## 添加/维护用例

1. **复制模板**：`cp templates/case_template.sh tests/<tier>/cases/<name>.sh && chmod +x`。
2. **实现逻辑**：脚本里可调用二进制、python、expect 或 `cargo run`，关键是保持可在 AArch64 QEMU/实机上执行。
3. **登记 manifest**：在 `tests/<tier>/suite.toml` 中追加 `[[cases]]`，字段说明：
   - `name` / `description`：展示信息。
   - `path`：相对仓库根路径。
   - `args`：传给脚本/二进制的参数数组。
   - `timeout_secs`（可选）：期望超时预算（当前仅记录，后续可接入强制超时）。
   - `allow_failure`：true 则算 soft fail，不阻塞主流程。
4. **验证**：`make <tier> run`，检查 `logs/<tier>/` 下日志与 JSON。

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
