# dopa macOS Sleep Guard for Herdr

Herdr のエージェントが作業している間だけ、Mac の自動スリープを防ぐ
[Dopa](https://github.com/gw31415/dopa) 連携プラグインです。

作業中のエージェントが 1 つでもあれば Dopa セッションを開始し、すべての
エージェントが待機状態になると自動で終了します。実行部分は Swift 製の単一
バイナリです。通常のインストールでは arm64 のビルド済みバイナリを取得するため、
Swift toolchain は必要ありません。

## 主な機能

- `working` のエージェントがいる間だけスリープを防止
- すべての Herdr セッションをまとめて監視
- このプラグインが取得した Dopa セッションだけを解放
- イベント駆動。常駐ポーリングデーモンはなし
- 画面消灯の防止と、蓋を閉じたときの自動停止に対応
- plugin disable / unlink / uninstall を検出して接続を自動解放
- Foundation、Darwin、IOKit によるネイティブ実装（実行時の `sh` / `nc` / `ioreg` は不要）

## 動作環境

| 必要なもの | 内容 |
| --- | --- |
| OS | macOS 13 以降、Apple Silicon（arm64） |
| Dopa | 0.3.3 以降。`dopa-daemon` が起動していること |
| Herdr | 0.9.0 以降 |

## インストール

まず Dopa をセットアップします。

```sh
brew install --cask gw31415/tap/dopa
sudo dopa-daemon install
dopa-daemon status
```

次にプラグインをインストールします。

```sh
herdr plugin install gw31415/herdr-dopa-monitor
```

Herdr は `herdr-plugin.toml` の `[[build]]` を実行し、同じバージョンの GitHub
Release から arm64 バイナリと SHA-256 checksum を取得します。download が
できずローカルに Swift がある場合だけ、source build へフォールバックします。
checksum 不一致や不正な archive は受け入れません。

## 使い方

通常は自動で動作します。

```text
エージェントが作業開始  → Dopa セッションを開始
全エージェントが待機    → Dopa セッションを終了
```

Herdr の action から状態確認と一時停止ができます。

```sh
herdr plugin action invoke status --plugin herdr-dopa-monitor
herdr plugin action invoke stop --plugin herdr-dopa-monitor
```

開発 checkout ではバイナリを直接呼び出せます。

```sh
./bin/herdr-dopa-monitor status
./bin/herdr-dopa-monitor status --json
./bin/herdr-dopa-monitor set keep_display_on true
./bin/herdr-dopa-monitor set stop_on_lid_close true
./bin/herdr-dopa-monitor stop
```

`stop` は一時的に owned session を終了します。エージェントが `working` のまま
次のイベントが届くと再開します。継続して止める場合は plugin を無効にします。

```sh
herdr plugin disable herdr-dopa-monitor
herdr plugin enable herdr-dopa-monitor
```

保持中の内部プロセスは Herdr の plugin registry の親ディレクトリをファイルシステム
イベントで監視しているため、disable、unlink、uninstall のいずれでも Dopa 接続を
閉じます。一定間隔での再読は行いません。

## 設定

| 設定 | 初期値 | 内容 |
| --- | --- | --- |
| `keep_display_on` | `false` | 作業中は画面の自動消灯も防ぐ |
| `stop_on_lid_close` | `false` | MacBook の蓋が閉じたら owned session を終了 |
| `dopa_sock` | `/var/run/dopa/control.sock` | Dopa control socket |

保存先は Herdr の plugin 用ディレクトリです。

```text
~/.config/herdr/plugins/config/herdr-dopa-monitor/config.json
~/.local/state/herdr/plugins/herdr-dopa-monitor/state.json
~/.local/state/herdr/plugins/herdr-dopa-monitor/holder/
```

`XDG_CONFIG_HOME` / `XDG_STATE_HOME` に対応しています。テストでは
`HERDR_DOPA_CONFIG_DIR` / `HERDR_DOPA_STATE_DIR` で上書きできます。

0.1.x の `config` / `state`（`KEY='value'` 形式）は初回実行時に読み取られ、次の
保存から JSON になります。旧 `nc` holder が残っている場合は、PID だけでなく旧版が
作成した専用 executable path も照合してから終了します。

## 仕組みと安全性

Herdr の pane / agent 状態イベントごとに Swift バイナリが一回だけ状態を整合させます。
全 Herdr session socket の `agent.list` を集約し、状態更新は `flock` で直列化します。

```text
off ── working を検出 ──▶ on
on  ── 全員が待機 ─────▶ off
```

`on` の間だけ、同じバイナリの非公開 `hold` サブコマンドがバックグラウンドで動きます。
これは追加デーモンではなく、Dopa の control socket 接続を所有する小さなプロセスです。
接続終了時に Dopa 側がその接続の session を解放するため、手動で開始した Dopa や
ほかのアプリの session には触れません。

Dopa 接続では公開 API v1 の hello を検証し、Dopa 0.3.3 未満、互換性のない API、
error response を拒否します。Herdr に接続できない場合は作業中と推測せず、停止側へ
倒します。`stop_on_lid_close=true` では `IOPMrootDomain` の IOKit interest
notification を受け、通知時だけ蓋状態を読み直します。Dopa の切断は socket read
source で受けます。いずれにもポーリングタイマーはなく、蓋状態を取得できない場合は
fail closed で停止します。

> [!WARNING]
> `stop_on_lid_close=false` の間は蓋を閉じても Mac が動作を続けます。MacBook を
> バッグへ入れる前に、Herdr の作業と Dopa session が終了していることを確認してください。

## 開発

`plugin link` は Herdr の `[[build]]` を実行しないため、先にローカルバイナリを作ります。

```sh
scripts/build.sh
herdr plugin link .
```

テスト:

```sh
swift test
scripts/build.sh
python3 tests/test_dopa_api.py
```

タグ `v<herdr-plugin.toml の version>` を push すると release workflow が macOS 13
deployment target の arm64 バイナリをビルドし、ad-hoc 署名した archive と checksum を
GitHub Release へ公開します。

リリース前に同梱物をローカルで作るだけなら `scripts/build.sh`、release asset の
install 動作を試す場合は `scripts/install-prebuilt.sh` を使います。生成される `bin/` は
Git 管理せず、Herdr の managed checkout 内で install 時に作成されます。

## アンインストール

```sh
herdr plugin uninstall herdr-dopa-monitor
```

保持中の接続は plugin registry から entry が消えたことを検出して自動で閉じます。
