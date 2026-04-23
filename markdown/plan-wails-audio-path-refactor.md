# 実装計画: Wails 音声経路の整備

**作成日:** 2026-04-23  
**対象ブランチ:** `feature/renderer-js-to-ts-migration`  
**状態:** 未着手

---

## 背景・経緯

もともと Electron 前提で設計された音声経路を Wails へ移行した際、「その場しのぎ」で Go 側に実装が移された。結果として以下の問題が生じている。

1. JS 側に Electron 向けの loudness 正規化コードが残っており、Wails では**未適用**（TODO コメントのまま）
2. 出力先デバイス変更が即時反映されず、次の `Play()` 呼び出しまで音が変わらない
3. 設定保存が `electronAPI.send('save-settings')` と `musicApi.saveSettings()` の二経路に分散
4. Wails モードでも `audio-graph.ts` の `setSinkId` 試行が空振りし続けている

### 直前の修正（コミット `8cc6ac3`）で解消済みの問題

- Go `decoderLoop` の EOF 待機ループが `Stop()` シグナルを無視していた → `stopCh` キャプチャで修正
- Wails モードで `play()` が不要な IPC（`loadRendererSettings` / `get-loudness-value`）を2回実行していた → `if (!isWails)` ガードで修正
- `stop()` が Wails で `electronAPI.send('playback-stopped')` を呼んでいた → `if (!isWails)` ガードで修正

---

## 関連ファイル一覧

| ファイル | 役割 |
|---|---|
| `pkg/audio/player.go` | Go PortAudio プレイヤー本体。EQ・volume・デコーダ管理 |
| `server/app_audio.go` | Wails バインディング層。JS → Go の IPC エントリポイント |
| `src/renderer/js/features/player.ts` | JS プレイヤー制御。Wails/Electron の分岐を持つ |
| `src/renderer/js/features/playback-manager.ts` | 曲選択・キュー・loudness 待機ロジック |
| `src/renderer/js/features/audio-graph.ts` | Electron 用 Web Audio Graph。sinkId 管理もここ |
| `src/renderer/js/ui/ui-manager.ts` | デバイス一覧 UI。Wails/Electron 両対応で描画 |
| `src/renderer/js/core/bridge.ts` | `musicApi` ブリッジ。Wails/Electron を吸収する |
| `src/renderer/js/core/settings-helpers.ts` | 設定取得ヘルパー |

---

## Phase 1 — Wails で loudness 正規化を有効にする

### 現状の問題

`playback-manager.ts:131` で loudness 値を取得し gain を計算するが、この値は `player.ts:play()` には渡されず、Wails モードでは誰も使わない。  
`player.ts` の `play()` 内の `if (isWails) { // TODO }` ブロックが完全な空実装になっている。

### 設計方針

- `playback-manager.ts` が計算した `gainLinear`（`float64`）を `player.ts:play()` へ引数で渡す
- `player.ts:play(song, gainLinear = 1.0)` → `playLocal(song, gainLinear)` → `WailsApp.AudioPlay(path, gainLinear)` と伝播
- Go 側の `AudioPlay(filePath string, gainLinear float64)` でゲインを `Player` に設定してから再生開始

### Go 側の変更（`pkg/audio/player.go`）

`Player` 構造体に `baseGain atomic.Uint64`（`float64` ビット格納）を追加：

```go
// Player 構造体に追加
baseGain atomic.Uint64 // stored as float64 bits, default 1.0
```

初期化（`NewPlayer` 内）：

```go
p.baseGain.Store(math.Float64bits(1.0))
```

`processAudio()` の volume 適用部分を変更：

```go
// 変更前
outputSample *= volume

// 変更後
bg := math.Float64frombits(p.baseGain.Load())
outputSample *= volume * bg
```

`Play()` メソッドのシグネチャ変更：

```go
// 変更前
func (p *Player) Play(filePath string) error {

// 変更後
func (p *Player) Play(filePath string, gainLinear float64) error {
    // 先頭で baseGain を設定
    if gainLinear <= 0 || math.IsNaN(gainLinear) || math.IsInf(gainLinear, 0) {
        gainLinear = 1.0
    }
    p.baseGain.Store(math.Float64bits(gainLinear))
    // ...以降既存コードそのまま
```

### Go 側の変更（`server/app_audio.go`）

```go
// 変更前
func (a *App) AudioPlay(filePath string) error {
    if err := a.audioPlayer.Play(filePath); err != nil {

// 変更後
func (a *App) AudioPlay(filePath string, gainLinear float64) error {
    if err := a.audioPlayer.Play(filePath, gainLinear); err != nil {
```

### JS 側の変更（`player.ts`）

```ts
// 変更前
export async function play(song) {

// 変更後
export async function play(song, gainLinear = 1.0) {
```

`playLocal()` へ渡す：

```ts
// 変更前
await playLocal({ ...song, path: filePath });

// 変更後
await playLocal({ ...song, path: filePath }, gainLinear);
```

`playLocal()` 内：

```ts
// 変更前
async function playLocal(song) {
    if (isWails) {
        await WailsApp.AudioPlay(path);

// 変更後
async function playLocal(song, gainLinear = 1.0) {
    if (isWails) {
        await WailsApp.AudioPlay(path, gainLinear);
```

### JS 側の変更（`playback-manager.ts`）

`runPlaySongWork` 内、loudness 計算後に gain を `playSongInPlayer` へ渡す：

```ts
// 変更前（loudness 計算は既に存在、isWails 判定を追加する）
const started = await playSongInPlayer(songToPlayActual);

// 変更後
let gainLinear = 1.0;
if (isWails) {
    // Wails モード: 計算して Go へ渡す
    const settings = await musicApi.getSettings();
    const targetLoudness = typeof settings?.targetLoudness === 'number'
        ? settings.targetLoudness : -18.0;
    const savedLoudnessRaw = await electronAPI.invoke('get-loudness-value', songToPlayActual.path);
    const savedLoudness = parseLoudnessValue(savedLoudnessRaw);
    if (savedLoudness !== null) {
        const gainDb = targetLoudness - savedLoudness;
        gainLinear = Math.pow(10, gainDb / 20);
    }
}
const started = await playSongInPlayer(songToPlayActual, gainLinear);
```

`playSongInPlayer`（= `player.ts` の `play()`）のシグネチャも更新。

> **注意:** `isWails` は `player.ts` の内部変数で外部から参照できない。`playback-manager.ts` 側では `getWailsApp() !== null` で代替するか、`bridge.ts` に `isWailsMode()` ヘルパーを追加する。

### Wails バインディング再生成

`server/app_audio.go` のシグネチャ変更後、以下を実行して自動生成バインディングを更新すること：

```bash
wails generate module
# または
wails dev（起動時に自動再生成）
```

生成先: `src/renderer/wailsjs/go/server/App.js` および `App.d.ts`

---

## Phase 2 — 出力先デバイス変更の即時反映

### 現状の問題

`Player.SetDevice()` はデバイス情報を更新するだけで、PortAudio ストリームは次の `Play()` まで変わらない。ユーザーが設定画面でデバイスを変更しても音は変わらない。

### 設計方針

`SetDevice()` 呼び出し時、再生中なら現在の再生位置を保存してストリームを作り直し、同じ位置から再開する。  
デコーダは継続利用するため再度ファイルを開き直す必要はない（`Seek()` で位置を合わせる）。

### Go 側の変更（`pkg/audio/player.go`）

```go
func (p *Player) SetDevice(deviceID string) error {
    // 1. デバイス選択（既存コード）
    p.mu.Lock()
    // ... idx 解決 ...
    p.currentDevice = p.devices[idx]
    wasPlaying := p.playing.Load() && !p.paused.Load()
    currentPos := p.GetPosition()
    currentBaseGain := math.Float64frombits(p.baseGain.Load())
    p.mu.Unlock()

    fmt.Printf("[Audio] Device set to: %s\n", p.currentDevice.Name)

    // 2. 再生中でなければ終了
    if !wasPlaying {
        return nil
    }

    // 3. 現在のストリームを停止（デコーダは保持）
    p.mu.Lock()
    if p.stream != nil {
        p.stream.Stop()
        p.stream.Close()
        p.stream = nil
    }
    p.mu.Unlock()

    // 4. リングバッファをリセット
    p.ringAvailable.Store(0)
    p.ringReadPos.Store(0)
    p.ringWritePos.Store(0)

    // 5. 新デバイスでストリームを再オープン（既存の openStream ロジックを流用）
    if err := p.reopenStream(); err != nil {
        return fmt.Errorf("failed to reopen stream on new device: %w", err)
    }

    // 6. 再生位置を復元
    if err := p.Seek(currentPos); err != nil {
        fmt.Printf("[Audio] Warning: failed to seek after device change: %v\n", err)
    }

    fmt.Printf("[Audio] Device switched and playback resumed at %.2fs\n", currentPos)
    return nil
}
```

`reopenStream()` は `Play()` 内のストリーム生成コードを抽出してプライベートメソッドとして切り出す。`p.mu` を取らずに呼べるよう設計する（呼び出し元が管理）。

---

## Phase 3 — 設定保存経路の一本化

### 現状の問題

- `audio-graph.ts:266` → `electronAPI.send('save-settings', { audioOutputId: sinkId })` （Electron 直呼び）
- `player.ts:115` → `getWailsApp()?.SaveSettings?.({ audioOutputId: deviceId })` （Wails 直呼び）
- `playback-manager.ts` → `musicApi.saveSettings()` 経由（正しい形）

### 修正方針

`audio-graph.ts` と `player.ts` にある直接の `electronAPI.send` / `getWailsApp()?.SaveSettings` を `musicApi.saveSettings()` に統一する。

**`audio-graph.ts:266` の修正：**

```ts
// 変更前
electronAPI.send('save-settings', { audioOutputId: sinkId });

// 変更後（import が必要: import { musicApi } from '../core/bridge.js'）
musicApi.saveSettings({ audioOutputId: sinkId });
```

**`player.ts:115` の修正：**

```ts
// 変更前
await getWailsApp()?.AudioSetDevice?.(deviceId);
await getWailsApp()?.SaveSettings?.({ audioOutputId: deviceId });

// 変更後
await getWailsApp()?.AudioSetDevice?.(deviceId);
musicApi.saveSettings({ audioOutputId: deviceId });
```

---

## Phase 4 — Electron 残滓の撤去

Phase 1〜3 完了後に実施する。着手前に全フェーズのテストが通っていることを確認すること。

### 撤去対象

1. **`audio-graph.ts` の `setSinkId` ロジック全体を Wails モードでスキップ**  
   `initAudioGraph()` / `restoreSavedSinkId()` / `setAudioOutput()` の先頭に `if (isWails) return;` を追加。  
   `isWails` の参照には `getWailsApp() !== null` を使うか、`bridge.ts` に `export function isWailsMode()` を追加する。

2. **`initPlayer()` の `sinkId` 引数を Wails では無視**  
   `player.ts:initPlayer(playerElement, callbacks, sinkId = null)` で、`isWails` の場合は `sinkId` を `initAudioGraph` に渡さない（現状は `await initAudioGraph(localPlayer, sinkId)` が Electron 専用パスにしか入らないため影響は軽微だが、明示的にガードする）。

3. **`playback-manager.ts:200` の `electronAPI.send('playback-stopped')` を Wails でスキップ**  
   ```ts
   // 変更前
   electronAPI.send('playback-stopped');
   
   // 変更後
   if (!getWailsApp()) electronAPI.send('playback-stopped');
   ```

---

## 実装順序・コミット粒度

各 Phase を以下の順で、Phase 内でも Red → Green → Refactor サイクルを守ること。

```
Phase 1a: Go 側 Player.Play() に gainLinear 引数追加 + processAudio() で適用
Phase 1b: server/app_audio.go の AudioPlay シグネチャ変更 + バインディング再生成
Phase 1c: JS 側 player.ts play() / playLocal() への gainLinear 伝播
Phase 1d: playback-manager.ts で Wails 時の gainLinear 計算・渡し

Phase 2a: pkg/audio/player.go に reopenStream() プライベートメソッド抽出
Phase 2b: SetDevice() に即時ストリーム再オープンロジック追加

Phase 3:  audio-graph.ts / player.ts の保存経路を musicApi.saveSettings() に統一

Phase 4:  Electron 残滓の撤去（isWails ガード追加）
```

各 Phase 完了時にバージョンを更新する（`PhaseVer +1, SubVer = a`）。

---

## 検証チェックリスト

各 Phase 完了後に以下を手動確認する（`wails dev` 起動）：

- [ ] 曲を再生すると音が出る（FLAC / MP3 / FLAC+ID3v2 それぞれ）
- [ ] 曲を切り替えると音も切り替わる（UI と音声が同期している）
- [ ] loudness 正規化が適用される（音量の大きい曲と小さい曲を交互に再生して確認）
- [ ] 設定画面で出力先デバイスを変更すると即時に音が切り替わる
- [ ] 変更したデバイスが再起動後も維持される
- [ ] スキップ連打しても panic / close of closed channel が起きない

---

## 既知のリスクと注意事項

| リスク | 対策 |
|---|---|
| Phase 1 で `AudioPlay` シグネチャを変更するとバインディング再生成が必要 | `wails generate module` を必ず実行し `App.js` / `App.d.ts` の更新を確認 |
| Phase 2 の `reopenStream()` はストリーム破棄中に PortAudio コールバックが呼ばれる可能性がある | `stream.Stop()` が完了してから ring buffer をリセットすること。`p.mu.Lock()` でコールバックと排他する必要はないが順序に注意 |
| `decoderLifecycleMu` を持ったまま `p.mu` を取得しない（逆順ロック禁止） | `shutdownDecoderGoroutine()` 内のロック順序（`decoderLifecycleMu` → なし）を変えないこと |
| Wails バインディングの `gainLinear` は `float64` として渡る | JS の `Number` は float64 なので精度の問題は発生しない |
