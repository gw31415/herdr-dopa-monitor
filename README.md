# dopa macOS Sleep Guard for herdr

Herdrのエージェントが作業している間だけ、Macが自動でスリープしないようにする
[Dopa](https://github.com/gw31415/dopa)連携プラグインです。

作業中のエージェントが1つでもあればDopaのセッションを開始し、すべてのエージェントが
待機状態になると自動で終了します。一度設定すれば、普段は操作する必要がありません。

## 🌟 主な機能

- **作業中だけスリープを防止**: `working` 状態のエージェントを検出して自動で開始・終了
- **すべてのHerdrセッションを監視**: 別のワークスペースで作業中のエージェントも見逃しません
- **Dopaのセッションを安全に分離**: このプラグインが開始したセッションだけを終了します
- **イベント駆動で軽量**: 常駐監視ループや追加デーモン、ビルド作業はありません
- **ディスプレイと蓋の設定に対応**: 画面消灯の防止や、蓋を閉じたときの自動停止を選べます
- **無効化・削除時も自動停止**: プラグインを止める前に手動で後片付けする必要はありません

## ✅ 動作環境

| 必要なもの | 内容 |
| --- | --- |
| Dopa | システムにインストールされ、`dopa-daemon` が起動していること |
| Dopa互換性 | Dopa 0.3.2で確認済み。公開control socket API v1を使用 |
| Herdr | 0.9.0以降 |
| OS | Apple Silicon搭載Mac。推奨のHomebrew CaskはmacOS 26以降 |

実行時に使うのはmacOS標準のコマンドだけです。追加の言語ランタイムやパッケージは
必要ありません。

## 📦 インストール

### 1. Dopaをインストールする

Homebrewを使う場合:

```sh
brew install --cask gw31415/tap/dopa
```

Dopaを一度開き、案内に従ってスリープ管理サービスを設定します。ターミナルから
設定する場合は、次のコマンドを実行します。

```sh
sudo dopa-daemon install
dopa-daemon status
```

`dopa-daemon status` でサービスの状態が表示されれば準備完了です。macOSに
起動を止められた場合は、[Dopaのインストール案内](https://github.com/gw31415/dopa#-インストール)
に従って初回起動を許可してください。

### 2. Herdrプラグインをインストールする

```sh
herdr plugin install gw31415/herdr-dopa-monitor
```

これで設定は完了です。次にエージェントの状態が変化したときから、自動で監視が始まります。

### 開発中のチェックアウトを使う場合

```sh
git clone https://github.com/gw31415/herdr-dopa-monitor.git
cd herdr-dopa-monitor
herdr plugin link .
```

## 🚀 使い方

通常は自動で動作します。

```text
エージェントが作業開始   → Dopaセッションを開始
全エージェントが待機     → Dopaセッションを終了
```

状態確認や設定変更には、リポジトリ内のコマンドを使用できます。

```sh
# 現在の状態を表示
sh guard/status.sh

# JSONで表示
sh guard/status.sh --json

# 2秒ごとに更新
sh guard/status.sh --watch

# 画面の自動消灯も防ぐ
sh guard/set.sh keep_display_on true

# MacBookの蓋を閉じたら停止する
sh guard/set.sh stop_on_lid_close true

# このプラグインが保持しているDopaセッションをいったん終了
sh guard/stop.sh
```

設定はコマンド実行時に保存されます。セッションの保持中なら、必要に応じて再起動して
新しい設定をすぐに反映します。待機中なら、次にセッションを開始するときに使われます。

`guard/stop.sh` は一時的にセッションを終了するコマンドです。エージェントが
`working` のまま次のイベントが届くと再開します。継続して止めたい場合は、
次の「一時停止と再開」の手順でプラグインを無効にしてください。

## ⏸ 一時停止と再開

一時停止:

```sh
herdr plugin disable herdr-dopa-monitor
```

再開:

```sh
herdr plugin enable herdr-dopa-monitor
```

無効化すると、プラグインが保持中のDopaセッションも自動で終了します。再び有効にした時点で
エージェントがすでに作業中の場合は、次の状態変化か `sh guard/once.sh` の実行後に
セッションを開始します。

## ⚙️ 設定

| 設定 | 初期値 | 内容 |
| --- | --- | --- |
| `keep_display_on` | `false` | `true` にすると、作業中は画面の自動消灯も防ぎます |
| `stop_on_lid_close` | `false` | `true` にすると、MacBookの蓋を閉じた時点でセッションを終了します |
| `dopa_sock` | `/var/run/dopa/control.sock` | Dopaのcontrol socket。通常は変更不要です |

`stop_on_lid_close=true` の場合、セッション開始前と保持中に蓋の状態を確認します。
蓋の状態を安全に確認できない場合も、スリープ防止を残さないよう停止側に倒します。
蓋を再び開いた後は、次のHerdrイベントで必要に応じて再開します。

## 🔒 安全性について

- プラグインはDopaの公開control socket API v1を使用します。
- 接続時にAPIバージョンを確認し、互換性がない場合はセッションを有効扱いにしません。
- Dopaとの接続が閉じると、その接続が所有するセッションもDopa側で解放されます。
- 手動で開始したDopaや、ほかのアプリが開始したセッションには触れません。
- Herdrへ接続できない場合は「作業中」と推測せず、セッションを終了する側に倒します。
- プラグインの無効化、リンク解除、アンインストールも保持中に検出して自動停止します。

> [!WARNING]
> `stop_on_lid_close` が `false` の間は、蓋を閉じてもMacが動作を続けます。
> MacBookをバッグへ入れる前に、Herdrの作業とDopaセッションが終了していることを
> 確認してください。このプラグインには、バッテリー残量の低下による独自の自動停止機能は
> ありません。

## 🧭 仕組み

Herdrのpane・agent状態が変わるたびに、プラグインが1回だけ状態を確認します。
すべてのHerdrセッションをまとめて調べ、`working` のエージェントが1つ以上あれば
1つのDopaセッションを保持します。

```text
off ── workingを検出 ──▶ on
on  ── 全員が待機   ──▶ off
```

Dopaセッションは、バックグラウンドの `nc` がcontrol socketへの接続を保持することで
所有します。API v1のhelloが成功した後だけ取得結果を受け入れ、接続を閉じることで
セッションを解放します。

状態更新処理はロックで直列化されるため、複数のイベントが同時に届いても
セッションを重複して開始しません。保持中のセッションがDopaの再起動などで消えた場合は、
次のHerdrイベントで自動復旧します。

## 🗂 保存場所

設定と実行状態は、Herdrのプラグイン用ディレクトリに保存されます。

```text
~/.config/herdr/plugins/config/herdr-dopa-monitor/config
~/.local/state/herdr/plugins/herdr-dopa-monitor/state
~/.local/state/herdr/plugins/herdr-dopa-monitor/holder/
```

`XDG_CONFIG_HOME` と `XDG_STATE_HOME` にも対応しています。テスト時は
`HERDR_DOPA_CONFIG_DIR` と `HERDR_DOPA_STATE_DIR` で保存先を変更できます。

## 🧰 トラブルシューティング

### 「dopa socket MISSING」と表示される

Dopaのサービスが動いているか確認します。

```sh
dopa-daemon status
```

停止している場合:

```sh
sudo dopa-daemon start
```

### エージェントが作業中なのに開始されない

まず詳細状態を確認します。

```sh
sh guard/status.sh
dopa-daemon status
```

プラグインが無効なら `herdr plugin enable herdr-dopa-monitor` で再開します。
APIの互換性エラーや取得失敗はHerdrのプラグインコマンドログに記録されます。
問題を直した後は、次のHerdrイベントを待つか `sh guard/once.sh` で再試行できます。

### セッションを手動で終了したい

```sh
sh guard/stop.sh
```

この操作も、このプラグインが所有するセッションだけを対象にします。
継続して停止する場合は `herdr plugin disable herdr-dopa-monitor` を使用してください。

## 🗑 アンインストール

```sh
herdr plugin uninstall herdr-dopa-monitor
```

保持中のセッションは自動で終了するため、事前に `guard/stop.sh` を実行する必要は
ありません。Dopa本体はほかの用途でも利用できるため、そのまま残ります。

## 🧪 開発者向け

シェルの構文とraw API v1の契約テストを実行します。

```sh
sh -n guard/*.sh
python3 tests/test_dopa_api.py
```

契約テストは一時的なUnix socketを作り、次の動作を実環境へ影響させず確認します。

- API v1のhello
- 非互換APIとerror応答の拒否
- セッションの取得と明示的な解放
- holder終了時の接続切断

実際のDopaデーモンと組み合わせた確認手順は
[`docs/manual-test.md`](docs/manual-test.md)を参照してください。CIもmacOS上で同じ
構文検査と契約テストを実行します。
