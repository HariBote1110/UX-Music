## 2026-07-14 — Desktop App: 公式再生/ストリーミング曲の同期歌詞（字幕→LRC）対応（サブエージェント実装）

### 実施内容
- YouTube を公式再生（embed）/ストリーミング（stream）で追加した曲について、UX Music の歌詞パネルに時刻同期歌詞を表示できるようにした（f646137〜f110e1a、TDD）。従来これらのモードは字幕→LRC 変換をスキップしており歌詞パネルが空だった。
- 事前に字幕取得経路を実測で確定（使い捨て cmd/spike-captions、検証後削除）。結論：**timedtext 本文が安定取得できるのは kkdai(ANDROID) の CaptionTrack.BaseURL 直接 GET のみ**。WEB ウォッチページ抽出の baseURL は proof-of-origin token（pot）要求のため status 200 でも本文 0 バイト、innertube WEB /player も captions 抽出不可。よって「取れる動画は取り、取れない動画は歌詞なしで壊れない」方針。
- internal/youtube に `FetchTranscriptLRC(url, preference)` を追加（DL せず字幕のみ取得して LRC/lang/vssId を返す）。server/app_youtube.go の addYouTubeStreamingLink（embed/stream 共通）で追加時に LRC を取得・保存。取得失敗でも登録は継続。
- **副産物の既存バグ修正**：downloadTranscriptAsLRC の言語ルートが kkdai GetTranscript を使っており eghAYpSDtRw 等で HTTP 400 で字幕を取り逃していた。新設 loadTranscriptForTrack で「トラック BaseURL 直接 GET（新鮮な署名付き URL）優先→失敗時のみ GetTranscript」に変更し、ダウンロード経路も堅牢化。
- 保存ファイル名を youtubeLyricsFileName(title, path)=<title>.lrc に集約。embed/stream 曲は path が動画 URL のため、フロントの get-lyrics は title 候補で探索する。保存も title 基準で一致（loadLyricsForSong・ローカル/DL 曲の読込は不変）。
- 実データ検証：eghAYpSDtRw で 55 セグメントの同期 LRC を取得、6LtrI3MOfQg は ANDROID 応答に字幕が載らず取得不可を確認。go test / vitest 177 件 / typecheck / wails build / E2E すべて通過。renderer 版を 1.0.0-Beta-43a へ更新（機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- WEB baseURL は pot 未保有では本文 0 バイトのため fallback として無意味と実測で判断し、実装しなかった（複雑さだけ増える）。
- 保存名・探索キーをともに title 基準に揃えることで、フロント無改修で歌詞パネル同期に載せた。

### 残課題・次のステップ
- ANDROID 応答に字幕が載らない動画（例 6LtrI3MOfQg）は headless では取得不可。実環境（実 WKWebView）での取得可否は今後の調査対象。
- srv3 の色・配置情報は現状破棄（parseTranscriptXMLBody が span テキスト結合のみ）。将来の「色分け表示」「フルスクリーン配置」対応時に別途拡張（非破壊）。[[project_youtube]]

## 2026-07-13 — Desktop App: embed 再生開始時の爆音を根治（ソースミュート→タップ確立後 unmute）

### 実施内容
- 公式再生（embed）で再生開始の一瞬だけ極端な爆音が鳴る安全問題を修正（サブエージェント実装、TDD）。
- 確定原因は「タップ確立前の生音」：埋め込みホストページが autoplay かつ非ミュートで再生を始めるため、AudioStartWebViewTap がタップを張って CATapMutedWhenTapped でヘルパー出力を消すまでの数百 ms、WebKit の音がシステム音量のまま鳴っていた。この生音は Go の processAudio（音量スライダーは最終段でクリップ後に乗算）を通らないため、定常出力の天井を超えて突出＝爆音。Go 側フェードだけでは直らないためソースミュートで根治。
- 主対策：埋め込みを mute=1 で開始（onReady でも mute）→ onPlaying で AudioStartWebViewTap が解決してから embedUnmute を送る。この時点でタップのミュートがヘルパー出力を消しているため生音漏れゼロ。reattach 時も unmute を送り直す。タップ開始失敗時はフォールバックで unmute し無音化を防ぐ。
- 副対策（保険・埋め込み限定）：ライブ再生開始から約120ms 出力を 0→1 に線形フェードイン（RT セーフ）。ファイル再生は完全非対象で回帰なし（TestLiveStartFadeRampsOutputFromSilence で固定）。
- go test / vitest 177 件 / typecheck / wails build / E2E すべて通過。renderer 版を 1.0.0-Beta-42d へ更新（不具合修正のため SubVer +1）。

### 選定理由・判断の根拠
- 爆音が Go 出力経路を通らない（生音）とアーキテクチャ上断定できたため、Go 側フェードは保険に留め、ソースミュート＋タップ確立後 unmute を主対策とした。
- 代償として開始時に約0.1–0.3秒の無音が入るが、聴覚保護を優先。

### 残課題・次のステップ
- ユーザー操作起点の再生で player.unMute() が音を復帰させることが前提（標準 API で問題ないはず、失敗時もフォールバックで unmute）。実機聴感の最終確認が残る。
- （別件・おいおい）YouTube UI の enableYouTube ゲートを外し公式再生を既定で使える形にする。DL/非公式ストリーミングのモード選択のみ隠す。

## 2026-07-13 — Desktop App: embed 音声タップの他アプリ巻き込みを修正（自アプリ WebKit ヘルパー PID 限定）

### 実施内容
- 公式再生（embed）で音量スライダーが効かない問題の真因を実測で特定・修正。真因は「タップ対象を bundle ID（com.apple.WebKit.GPU）で指定していたため、全アプリ共有の WebKit 音声（Safari 等）を捕捉・ミュート・再出力し、自アプリの埋め込み音声はほぼ捕捉できていなかった」こと。ユーザー実機で確定（UX Music の音量が Safari の YouTube/ニコニコに連動、Apple Music は無影響、自アプリ embed の OutputRMS≈0.00003）。
- 診断プローブ uxDebug.embedVolumeProbe() で Go 出力段・フロント伝達は正常（RMS が音量に比例）と確認済みだったため、タップ対象選定のみを修正。
- タップ対象を「自プロセスが帰属する WebKit ヘルパー PID」に限定：libproc（proc_listpids / proc_pidinfo / proc_pidpath）＋ responsibility_get_pid_responsible_for_pid で、WebKit パスかつ自 PID の子孫／responsible が自 PID 系のプロセスだけを選ぶ。純粋ロジック webKitHelperPIDsForSelf を TDD 実装。AudioStartWebViewTap は起動毎に PID を再列挙し、0 件時はエラー。
- 実機ログで自アプリの 3 ヘルパーのみ対象化・Safari/Orion 等 38 個の他 WebKit を除外を確認。E2E の音量チェックが PASS（RMS 0.00003→0.1746、ratio 0.29）。
- go test / vitest 176 件 / typecheck / wails build / E2E すべて通過。renderer 版を 1.0.0-Beta-42c へ更新（不具合修正のため SubVer +1）。

### 選定理由・判断の根拠
- WKWebView ヘルパーは launchd 直下の XPC プロセスで親子チェーンだけでは自アプリに辿れないため、responsibility_get_pid_responsible_for_pid を帰属シグナルに使う。
- スパイク段階で警告されていた「bundle ID タップは他アプリを巻き込む」リスクが実害として顕在化したため、PID 限定へ全面移行し bundle ID 経路は廃止。

### 残課題・次のステップ
- 本番（Finder/Dock 起動）での実機未検証。この場合アプリ自身が responsible ルートになる設計だが未確認。ユーザーの通常起動での動作確認が望ましい。
- TCC「システム音声録音」許可が未付与だとタップ失敗の可能性（別課題）。

## 2026-07-13 — Desktop App: embed 再生で音量スライダーが効かない問題の修正（クリップ順序バグ）

### 実施内容
- 公式再生（embed）で音量スライダーが効かないというユーザー報告を修正（サブエージェント実装、TDD）。
- 根本原因は `pkg/audio/player.go` の `processAudio` の計算順序：`sample × volume × baseGain` を掛けてからクリップしていたため、ラウドネス正規化で baseGain > 1 になる embed 曲では出力がクリップ天井に張り付き、スライダー上半分を動かしても出力が変わらなかった。音量値の伝達経路（フロント→AudioSetVolume→SetVolume→processAudio）は正常であることを単体テストで証明した上で特定。
- 修正はクリップを baseGain 適用直後へ移動し、volume はクリップ後に乗算。baseGain ≤ 1 の既存ローカル再生ではクリップが no-op のため出力はビット単位で不変。
- 診断用に出力 RMS プローブ `Player.OutputRMS()`（RT セーフ）と `AudioDebugOutputRMS` バインディングを追加。E2E に音量比例チェックを追加（自動再生ミュート環境では設計どおり SKIP、比例性は Go 単体テストで担保）。
- go test / vitest 176 件 / typecheck / wails build / E2E すべて通過。renderer 版を `1.0.0-Beta-42b` へ更新（不具合修正のため SubVer +1）。

### 選定理由・判断の根拠
- ローカル曲で無症状だった理由（gain ≤ 1 でクリップ不発）と、EQ・正規化が「効いているように聞こえた」理由（音色・クリップ量は変わる）が症状と整合し、原因として確定できた。
- volume をクリップ後に掛けることで、ユーザー音量が「最終段の減衰」として常に線形に効く設計になった。

## 2026-07-13 — Desktop App: 公式再生のラウドネス正規化とリサイズ追従修正（サブエージェント実装）

### 実施内容
- 【ラウドネス正規化】innertube /player（ANDROID クライアント、kkdai と同一設定）から `audioConfig.loudnessDb` / `perceptualLoudnessDb` を取得する `internal/youtube/loudness.go` を追加（a52b959〜19e0bb0、TDD）。実測で `perceptualLoudnessDb = -14 + loudnessDb` が全検証動画で厳密に成立し、ffmpeg ebur128 の統合ラウドネス実測（-7.3 LUFS）とも一致 → perceptualLoudnessDb をコンテンツ実効 LUFS として採用。ゲインは純関数 `resolveEmbedPlaybackGain`（target − 実効 LUFS、上限 64 倍で Go 側 maxNormGain と一致）。適用は `AudioStartWebViewTap` 解決後に `AudioSetNormalisationGain`（playLiveSource が開始時に baseGain をリセットするため順序が重要）。取得不能時はゲイン 1.0。
- 【リサイズ追従】埋め込みプレイヤーがサイドバーリサイズに追従しない原因は、`#youtube-embed-wrapper` に寸法指定がなく内側 iframe の height:100% が解決できないこと。wrapper に width/height 100% を付与し display:block 化（046155b）。実機ドラッグで双方向追従と再生継続を確認。ローカル動画プレビュー・サムネイルは無影響。
- E2E をタップ開始＋ゲイン適用まで拡張し PASS（ログ例: loudness=-23.67 → gain=1.9209、target -18 に対し +5.67dB で計算どおり）。typecheck / vitest 176 件 / go test / wails build 全通過。
- renderer 版を `1.0.0-Beta-41a` から `1.0.0-Beta-42a` へ更新（機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- WEB クライアントの innertube は UNPLAYABLE を返すため ANDROID クライアントを採用。
- loudnessDb の解釈は推測でなく実測（複数動画の相互関係＋ebur128 突き合わせ）で確定させた。
- 埋め込みプレイヤー自身の減衰有無は未確定（自動再生ミュート問題で計測が汚染されたため）。ソース音源のラウドネスとして扱う設計とし、コードコメントに明記。

### 残課題・次のステップ
- **要対応**: WKWebView の自動再生ポリシーにより、E2E の自動再生では埋め込みが「ミュート＋音量0」で開始しタップに無音しか流れないことを実測で発見（onReady の unMute() は効かず）。ユーザー操作起点の本番再生で音が出るかは実機聴感の確認が必要。出ない場合はユーザージェスチャー文脈での unMute かホストページ側の対策を実装する。
- ラウドネス正規化の聴感上の効き具合は、上記問題の確認後に評価するのが確実。

## 2026-07-13 — Desktop App: 公式再生エラー153の根治（ループバックホスト方式）と E2E 再生テスト整備（サブエージェント実装）

### 実施内容
- 実機で発生した YouTube 埋め込みプレイヤーのエラー 153 を修正（addb0c5〜0bddad7）。E2E ログでの実測により原因を確定：Wails 本番ビルドはページ origin が独自スキーム `wails://wails` になり、IFrame API がそれを origin/forigin として YouTube に送り、かつ HTTP Referer が空のため「Referer 欠落/不正」として再生拒否されていた。
- 修正方式は**ループバックホスト**：Go 側（server/embed_host.go）が 127.0.0.1 の空きポート（ループバック限定・lazy 起動）で `/embed?v=<11桁ID>` に公式プレイヤー入りページを配信し、Now Playing の iframe はそこを指す。ページ origin が `http://127.0.0.1:<port>` になるため YouTube が受理する。renderer とは postMessage で制御・状態を中継（純粋プロトコルは youtube-embed-bridge.ts、TDD）。公開 API 不変のため player.ts は無変更。
- 動画 ID は正規表現で検証しインジェクション不可。CSP frame-src に `http://127.0.0.1:*` を追加。
- **E2E 再生テストを整備**：`scripts/e2e-youtube-embed.sh` が wails build → 本番バイナリを環境変数付きで起動 → 起動直後に embed 再生を自動開始 → 構造化ログ（EmbedDebugLog）を監視し、PLAYING 到達で PASS / error で FAIL / 60 秒でタイムアウトを自動判定。修正後の本番バイナリで **PASS（起動から PLAYING まで約1秒）** を確認。
- renderer 版を `1.0.0-Beta-40b` から `1.0.0-Beta-41a` へ更新（重大な不具合修正のため PhaseVer +1）。

### 選定理由・判断の根拠
- origin パラメーター調整・iframe 直接生成・assetserver ミドルウェアの各案は、いずれも「親ページが独自スキームである限り Referer が空のまま」という根本原因を解消できず却下。ループバックホストのみが本番（wails:// origin）で機能する。
- E2E の完全ヘッドレス化は原理的に不可（YouTube 再生は実 WKWebView・実ネットワーク・実音声出力を要する）。ウィンドウ表示と数秒の実音を伴う半自動とし、合否判定のみ完全自動化した。

### 残課題・次のステップ
- 二重 iframe のため、Now Playing 再描画時の reattach（DOM 移動）で iframe が再読込され再生が頭から再開する可能性。実機で頻度を確認。
- E2E は mount 直呼びのためプロセスタップ〜聴感（EQ が効く・二重再生なし）は実機確認が必要。
- ループバックポートは起動ごとに変動。配信内容は公開動画の埋め込みページのみで秘匿情報なし。

## 2026-07-13 — Desktop App: YouTube「公式再生（embed）」モードの実装完了（フェーズ2b、サブエージェント実装）

### 実施内容
- 公式埋め込みプレイヤー（IFrame Player API、controls=1・映像可視）で再生し、音声だけをプロセスタップ経由で Go ネイティブパイプライン（EQ・音量・ビジュアライザー）から出力する再生モード「公式再生」を追加（92e0ef2〜f985000）。
- 設定の YouTube 再生モードに「公式再生（推奨）」を追加。embed モードのリンク追加は stream と同じ非ダウンロード登録（type:"youtube"）。
- 再生経路判定 `resolveYouTubePlaybackRoute` と動画 ID 抽出 `extractYouTubeVideoId`（watch / youtu.be / shorts / embed / live 対応）を純関数として TDD で実装（vitest 7 件）。
- 埋め込みプレイヤー管理 `youtube-embed-player.ts`：IFrame API シングルトンロード、mountToken による競合破棄防止、再描画時の reattach（iframe 破棄による音途切れ・二重再生防止）。
- player.ts 統合：PLAYING イベントで一度だけ `AudioStartWebViewTap()`、停止/曲切替で `destroyEmbedPlayer()`→`AudioStopWebViewTap()`。ポーズ/再開はタップを張ったまま pauseVideo/playVideo。時間・シーク・再生状態は embed 中は YouTube プレイヤー側から取得（Go はライブ再生で 0 を返すため）。ENDED は既存の曲終了導線（songFinished→次曲遷移）へ接続。
- 検証：typecheck / vitest 163 件 / go build / go test / wails build（24 秒）すべて通過。
- renderer 版を `1.0.0-Beta-39a` から `1.0.0-Beta-40a` へ更新（機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- 埋め込みは controls 表示・映像可視のまま使う。規約グレーの解消（還元の成立）が目的のため、旧 Electron 時代の controls=0・不可視 iframe のような使い方はしない。
- 埋め込み側はミュートしない：mutedWhenTapped が WebKit ヘルパーの出力を消すため、埋め込みを muted にするとタップに音が来なくなる。
- ポーズ/再開でタップを解除しない：ヘルパーが無音になるだけで害がなく、再開レイテンシを最小化できる。

### 残課題・次のステップ
- 実機聴感確認（ユーザー実施）：映像表示・ネイティブ経路からの音・EQ/ビジュアライザー・二重再生なし・シーク/ポーズ/曲送り・通常曲復帰。
- タップ確立までの数百 ms に一瞬生音が出る可能性（PLAYING→タップ確立の間）。実機で気になるようなら対策検討。
- 広告再生中の duration がシークバーに出る挙動は未検証。
- bundle ID タップは他アプリの WKWebView 音声（Safari 等）も捕捉し得る。将来は自アプリのヘルパー PID 限定を検討。
- ラウドネス正規化の適用（YouTube player response の audioConfig.loudnessDb を自前 parse してゲイン設定）は未実装の次候補。

## 2026-07-13 — Desktop App: プロセスタップ音声基盤の実装完了（フェーズ2a、サブエージェント実装）

### 実施内容
- WebKit ヘルパープロセスの音声を捕捉して既存 Go パイプラインで再生する基盤を TDD で実装（453bf13〜f31d68b）：
  - `pkg/audio/tapring.go`: ロックフリー SPSC リングバッファ（RT スレッド側は満杯時破棄、破棄/受信数を計上）。
  - `pkg/audio/player_live.go` + `player.go`: ライブタップ再生モード。デコーダーに optional interface `float32Decoder`（`ReadFloat32`）を追加し、float32 のまま再生リングへ直結。EQ・ゲイン・FFT ビジュアライザーが有効。ライブ中は position/duration=0・Seek no-op、無音時は無音注入。
  - `pkg/audio/processtap_darwin.{go,m,h}`: `ProcessTapCapture`（bundle ID / PID 指定、macOS 26 の bundleIDs + processRestoreEnabled 優先、旧 OS 向けプロセス列挙フォールバック）。
  - `server/app_audio.go`: `AudioStartWebViewTap` / `AudioStopWebViewTap` バインディング追加、wailsjs 再生成。
- **ユーザーの聴感報告（150Hz 級の低音）が実バグの発見につながった**：`kAudioTapPropertyFormat` は 48kHz を報告するが、IOProc の実供給レートは集約デバイスのクロック＝実出力デバイスレート（この環境では 192kHz）。48kHz 解釈だと 440Hz が 110Hz（2 オクターブ下）で再生される。`kAudioDevicePropertyNominalSampleRate` を照会する修正（d089400）で解消。
- 実機検証コマンド `cmd/spike-tapplayer` は聴感に依存しない自動合否判定（ゼロクロス周波数・RMS 理論値一致・FFT ビン・Stop 後の通常再生復帰）で全フェーズ合格。
- 副産物として decoderLoop の stop/done チャネル競合（EOF しないソースで Stop 不能になるレース）を発見・修正。

### 選定理由・判断の根拠
- s16le 変換ではなく float32 直結経路を採用：タップは float32 で届き再生リングも float32 のため、変換は量子化の往復損失のみで利点がない。出力ストリームはソースレートで開くためリサンプルも不要。
- リングバッファは mutex ではなくロックフリー（atomic）：IOProc が Core Audio のリアルタイムスレッドから呼ばれるため。

### 残課題・次のステップ（フェーズ2b: フロントエンド統合）
- 公式埋め込みプレイヤー（IFrame Player API）を Now Playing に表示し、再生開始後に `AudioStartWebViewTap()` を呼ぶ接続。
- ライブ中の position/duration は 0 のため、シークバーは YouTube プレイヤー側の時間で描画する必要がある。
- bundle ID タップはシステム全体の com.apple.WebKit.GPU を対象にするため、Safari 等の音声も捕捉し得る。将来は自アプリのヘルパー PID 限定を検討。
- 既定出力デバイス変更時は集約デバイスの作り直し（Stop→Start）が必要。

## 2026-07-13 — Desktop App: 「公式埋め込み＋プロセスタップ」方式の技術スパイク成功（YouTube 還元問題の解法）

### 実施内容
- YouTube 再生の方針転換を決定：非公式ストリーミング（同日実装）はクリエイター還元がゼロのままという課題が残るため、「公式埋め込みプレイヤーで再生（再生数・広告 → 還元あり）しつつ、その音声を Core Audio プロセスタップで捕捉して既存 Go パイプライン（EQ・ラウドネス・ビジュアライザー）に流す」構成を検証した。
- サブエージェントによる技術スパイクを実施（`cmd/spike-processtap/`、コミット 8963dab）。結果、**全ステップ成功・構想は実現可能**：
  - `AudioHardwareCreateProcessTap` + `CATapDescription`（CATapMutedWhenTapped）でのタップ作成、集約デバイス経由のサンプル受信すべて noErr。
  - 捕捉精度は定量的に正確（440Hz/振幅0.30 の正弦波で RMS=0.21211、理論値と一致）。
  - フォーマットは 48kHz / 2ch / float32（出力デバイスレートでミックスダウン済み）。
  - 子プロセス（afplay）をタップ → 自プロセスの PortAudio から再出力する構成が安定動作。レイテンシ上限 ≈107ms、チューニングで 20〜50ms まで詰められる見込み。
  - TCC 許可ダイアログは不要だった（自プロセスと子プロセスは responsible process 配下のため）。

### 選定理由・判断の根拠
- ユーザーの要件は「法律遵守」と「クリエイター還元」の2点（YouTube 規約自体は優先しない）。還元は公式プレイヤー経由の再生でしか成立せず、一方 EQ・正規化は出力前の信号加工の問題なので、両者は直交しており「公式再生＋後段タップ処理」で両立できる。
- 音声はどこにも保存せずリアルタイム加工のみのため、複製に関する法的問題を発生させない。
- ラウドネス正規化は事前ファイル解析の代わりに、YouTube player response の `audioConfig.loudnessDb` を自前 parse して利用する方針（kkdai/youtube は未対応フィールド）。

### 残課題・次のステップ（スパイクで判明した設計上の注意）
- **自己帰還が最大の落とし穴**：自プロセスをタップすると EQ 後の再出力も捕捉されループする（実証済み）。本実装では WKWebView の音声を出す WebKit ヘルパープロセス（com.apple.WebKit.GPU 等）だけをタップする。
- macOS 26 なら `CATapDescription.bundleIDs` + `processRestoreEnabled` でヘルパー再起動に自動追従できる。26 未満対応には PID 変化の再タップ処理が必要。
- タップは 48kHz float32。Player パイプラインに float32 のライブ入力経路を追加するのが素直（44.1kHz へのリサンプルはしない）。
- IOProc は Core Audio のリアルタイムスレッドから入るため、本実装はロックフリーリングバッファ推奨。
- 署名済み .app 配布時に NSAudioCaptureUsageDescription が必要になるかは .app バンドルで要再確認。
- 「mutedWhenTapped で物理スピーカーが無音になるか」は CLI から計測不能のため、実機での聴感確認が必要。

## 2026-07-13 — Desktop App: YouTube ストリーミング再生の実装（ダウンロード不要の再生モード復活）

### 実施内容
- 以前 Electron 版で挫折し、Wails 版では「ダウンロードモードのみ対応」とエラーで拒否していた YouTube ストリーミング再生を実装した。
- 【技術スパイク】実装前に検証を実施し、成立を確認：`kkdai/youtube` で解決した googlevideo の直接 URL（音声専用 itag 251 / opus）を ffmpeg が直接デコードでき、`-ss` によるシークも Range リクエストで機能し、スロットリングも発生しない（30 秒分の音声を 0.2 秒で取得）。
- 【pkg/audio】`Player.Play` に `isRemoteSource`（http/https 判定）を追加。リモート URL は `os.Open` と拡張子分岐を通さず、URL を直接読める ffmpeg デコーダーへ委ねる。デコーダー決定後の共通処理を `startDecodedPlayback` に抽出。既存のシーク（`ffmpeg -ss`）・ポーズ復帰はそのまま機能する。
- 【internal/youtube】`chooseStreamFormat` を追加し、`GetYouTubeStreamURL` を音声専用フォーマット最高ビットレート優先（無ければ音声付きへフォールバック）に変更。URL は `Format.URL` 直参照をやめ `GetStreamURLContext` 経由にし、署名暗号化（signatureCipher）動画にも対応。
- 【server】`youtubePlaybackMode: "stream"` を受け入れ、`buildStreamingSong`（type=youtube、path=元動画 URL、保存なし）でライブラリ登録する `addYouTubeStreamingLink` を追加。再生用に `ResolveYouTubeStreamURL` バインディングを新設（googlevideo URL は数時間で失効するため再生の都度解決）。
- 【フロントエンド】`player.ts` の `play()` に `type === 'youtube'` 分岐を追加し、`ResolveYouTubeStreamURL` → `AudioPlay` で Go ネイティブパイプライン再生（EQ・ラウドネス・ビジュアライザーが有効）。`now-playing.ts` の YouTube 埋め込み iframe（autoplay 付き）はネイティブ再生と二重になるため廃止し、サムネイル表示に変更。
- TDD: Red f59865a → Green 7c5d950（Go 側）→ 0070c84（フロントエンド）。wailsjs バインディング再生成込み。
- renderer 版を `1.0.0-Beta-38a` から `1.0.0-Beta-39a` へ更新（機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- 再生方式は「webview の `<audio>` 直再生」や「Go 側 HTTP プロキシ経由」ではなく、既存 ffmpeg デコーダーへの URL 直接渡しを選んだ。追加依存ゼロ・追加プロセスゼロで、既存のネイティブ再生パイプライン（EQ／ラウドネス／FFT ビジュアライザー／シーク復帰処理）がそのまま使えるため。
- 過去に「無理」とされた要因は、当時の構成（Electron の埋め込み iframe 依存＝controls 隠蔽などの規約違反すれすれの実装）にあった。現在の Wails 構成は ffmpeg デコーダーが再生の中核であり、ffmpeg は HTTPS 入力とバイトレンジシークをネイティブサポートするため、構図が変わっていた。
- ストリーム URL はライブラリに保存せず再生の都度解決する。googlevideo URL は数時間で失効し IP にも紐づくため、保存しても再利用できない。
- フォーマットは音声専用（opus/m4a）優先とした。プログレッシブ形式（itag 18）は映像バイトも取得してしまい帯域の無駄になるため。
- 埋め込み iframe の廃止は二重再生の解消が直接の理由だが、controls=0 での埋め込みは YouTube の埋め込み規約的にもグレーであり、「グレーな実装をなんとかしたい」という当初の目的にも沿う。

### 残課題・次のステップ
- 映像付きストリーミング（音と映像の同期表示）は未対応。現状は音声＋サムネイル表示。対応するなら映像ストリームの分離取得と同期が必要。
- YouTube 側の仕様変更で `kkdai/youtube` の URL 解決が壊れる可能性は残る（ダウンロードモードと共通のリスク）。失敗時はエラー通知され、ダウンロードモードへの切替で回避可能。
- ストリーミング曲は UX Sync／MTP 転送などファイル前提の機能の対象外。必要なら type=youtube を除外するガードの総点検を行う。

## 2026-07-05 — Desktop App: コンピレーション参加アーティストのアルバム表示バグ修正と、履歴ベースの共通戻るボタン導入

### 実施内容
- 【バグ修正】アーティスト詳細で、コンピレーションアルバム参加アーティストのアルバムが表示されない不具合を修正。原因は `renderArtistDetailView` が「アルバムの代表アーティスト名 === アーティスト名」の文字列一致で絞り込んでいたこと。コンピレーションは代表アーティストが `Various Artists` になるため一致しなかった。`src/renderer/js/core/library-model.ts` に、所属曲の `albumKey` から参加アルバムを辿る純関数 `getArtistAlbums` を追加し、アーティスト詳細はこれを使うよう変更（TDD: Red 1266a09 → Green 7ad0ccd）。
- 【機能追加】`src/renderer/js/core/navigation.ts` にビュー履歴（`viewHistory` / `canGoBack` / `goBack`）を導入。詳細ビュー（album / artist / playlist）への遷移時に遷移元を積み、一覧ビューへの通常遷移で履歴をクリア。オーバーレイ系ビュー（quiz 等）は履歴に関与しない（TDD: Red 4eacab5 → Green f244252）。
- 【UI変更】前回の「← アーティストに戻る」テキストボタン（fromArtist 方式）を廃止し、共通コンポーネント `src/renderer/js/ui/detail-back-button.ts`（`prependDetailBackButton`）による丸い「‹」アイコンボタンに置換。全詳細ビュー（アルバム／アーティスト／プレイリスト）の左上に表示し、クリックで履歴上の一つ前のビューへ戻る。
- renderer 版を `1.0.0-Beta-37a` から `1.0.0-Beta-38a` へ更新（バグ修正＋機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- アーティスト→アルバムの紐付けは、代表アーティスト名の一致ではなく所属曲の `albumKey` から辿る方式にした。タグの揺れ（albumartist 有無・Various Artists 化）に依存せず、`groupLibraryByAlbum` が曲へ付与する `albumKey` を単一の紐付け根拠にできるため。
- 戻るボタンは「遷移元アーティスト名を持ち回る」fromArtist 方式を捨て、汎用のビュー履歴スタックに置き換えた。詳細ビューが増えても遷移元の種類ごとの分岐が不要で、アーティスト詳細→アーティスト一覧など任意の遷移元へ戻れるため。
- 履歴は一覧ビューへの通常遷移（サイドナビ）でクリアし、無限に積まれることを防いだ。オーバーレイ系（quiz / lrc-editor 等）は独自の終了導線を持つため履歴対象外とした。
- ボタンの描画判定は `canGoBack()` のみで行い、詳細ビュー3種の描画関数から共通関数を1行呼ぶだけの構成にして重複を避けた。

### 検証
- `npx vitest run`（src/renderer）: 20ファイル / 156テスト全通過。
- `npx tsc --noEmit` / `npx eslint`（変更ファイル）: エラーなし。
- 実アプリ（Wails）での目視確認は未実施（環境上の制約）。

### 残課題・次のステップ
- `showPlaylist` は都度 API から詳細を取得するが、goBack ではスナップショット（履歴に積んだ data）を再描画する。戻った直後にプレイリスト内容が古い可能性が理論上あるが、実用上は許容と判断。必要なら goBack 時の再取得を検討。

## 2026-07-05 — Desktop App: アルバム詳細に「アーティストに戻る」ボタンを追加

### 実施内容
- Desktop App（`src/renderer`）で、アーティスト一覧→アーティスト詳細→アルバム詳細と遷移した際に、アルバム一覧（中央セクション）に戻る手段がなく、アーティスト詳細へ戻れない不具合を解消した。
- `src/renderer/js/core/navigation.ts` の `showAlbum` に任意引数 `{ fromArtist }` を追加し、`showView` 経由で `state.currentDetailView.fromArtist` に遷移元アーティスト名を記録するようにした。
- `src/renderer/js/ui/detail-renderer.ts` の `renderArtistDetailView` 内のアルバムグリッドクリック時に `showAlbum(albumKey, { fromArtist: artist.name })` を渡すよう変更。
- `renderAlbumDetailView` で `state.currentDetailView.fromArtist` が設定されている場合のみ、詳細ヘッダー左上に `.header-button.album-detail-back-btn`（「← アーティストに戻る」）を描画し、クリックで `showArtist(fromArtist)` を呼び出すようにした。
- 既存の `.header-button`（quiz の戻るボタン等で使用）スタイルを再利用し、`views.css` に `.album-detail-back-btn { margin-bottom: 16px; }` のみ追加。
- TDD: まず `src/renderer/js/core/navigation.test.ts` に「`showAlbum` が `fromArtist` オプション付きで呼ばれたとき `currentDetailView.fromArtist` に記録される／オプションなしでは記録されない」テストを追加し Red を確認、コミット後に実装して Green にした。
- renderer 版を `1.0.0-Beta-36d` から `1.0.0-Beta-37a` へ更新（新機能追加のため PhaseVer +1）。

### 選定理由・判断の根拠
- 状態管理は既存の `state.currentDetailView`（`DetailViewState`、任意キー許容の型）を拡張する形にし、新しいグローバル状態や別ストアを作らず既存の遷移フローに最小差分で乗せた。
- `renderAlbumDetailView` の統合テスト（DOM操作込み）は本プロジェクトが jsdom を導入しておらず、既存のDOMテストも手動モック中心のため、DOM生成込みの検証は割に合わないと判断。ロジックの核となる `showAlbum`／`currentDetailView` の状態遷移のみを vitest で検証する方針にした。
- ボタンのスタイルは新規CSSクラスを増やさず、quiz-back-btn 等で既に使われている `.header-button` を流用し、UIの一貫性を優先した。

### 検証
- `npx vitest run`（src/renderer）: 20ファイル / 152テスト全通過。
- `npx tsc --noEmit`: エラーなし。
- `npx eslint`（変更ファイルのみ）: エラーなし（既存パターンと同様の `any` 警告のみ）。
- Wails + Go バックエンドを要する実アプリでの目視確認は本セッションでは未実施（環境上の制約）。

### 残課題・次のステップ
- 実機（Wails dev サーバー起動）での目視確認は未実施のため、次回起動時に確認するとよい。

## 2026-07-05 — ドメイン境界・無意味テスト・UI不整合の一斉是正

### 実施内容
- 探索エージェント3体（ドメイン境界／テスト品質／UI）でコードベースを監査し、検出結果を裏取りのうえ Sonnet 5 サブエージェント2体（Go 担当・renderer 担当）で並行修正した。
- Go: `pkg/audio` の `internal/config` 依存を `SetFFmpegPaths` 注入方式に切断し、pkg→internal の層逆転を解消（1e7e6c1, 2ddb959）。
- Go: 散在していたパス正規化（`filepath.Clean` / NFC / NFD）を新設 `internal/pathutil`（`CanonicalisePath` / `CandidateForms` / `SamePath` 等）に統一（3ed7fcf, 24c29dd）。`app_media.go` の `filepath.Clean` はパストラバーサル防御目的のため意図的に据え置き。
- Go: `internal/playlist` と `internal/lyricssync` の `store.Instance` 直接参照を `SettingsProvider` interface 注入に変更し、ドメイン層→永続化層の直結を解消（50b5b28, fe12bea）。
- Go: 未参照だった `internal/discord` を削除（f3d2469, 7584c56。並行作業により2コミットに分裂、実害なし）。`internal/special` を責務が読める `internal/moodspecial` に改名（6b70ca4）。
- renderer: `renderer.ts` に重複していたシャッフル設定反映を `applyShuffleSetting` に共通化（300c647, cfebf87）。
- renderer: DOM 文字列 contains だけの凍結テスト（ux-sync-settings-dom / default-artwork / equalizer-colour-events の呼び出し順比較 / mock_ui_test.mjs）を挙動検証テストに置換または削除（5c1cdc0, 4146035, 472ed7c）。
- renderer: `stopQuiz` が `isResultShowing` / `startTime` / タイマーIDを未リセットのまま残し、離脱後の遅延 Space 入力で回答ボタンが二重生成される実バグを Red→Green で修正（fe473b8, f597751）。notification のタイマー競合疑いは再現不能で、既存実装は健全と判断し回帰テストのみ追加（1f77867）。
- 不具合修正＋リファクタのため renderer 版を `1.0.0-Beta-36c` から `1.0.0-Beta-36d` へ更新した。

### 選定理由・判断の根拠
- `store.Instance` の全面 DI 化（server/ 含む80箇所超）は影響が大きすぎるため、層違反として実害のあるドメイン層（playlist / lyricssync）への注入導入に絞った。server/ 側の直接参照は今後の課題。
- `internal/discord` は完全実装済みだったが、参照が TODO コメント1行のみで死蔵状態だったため、git 履歴から復元可能なことを根拠に削除を選択（実装完了より YAGNI を優先）。
- 監査で挙がった「UX Sync 保存ボタン未接続」「fullscreen の var() 入れ子不正」は裏取りで誤検出と判明し、対応対象から除外した。

### 検証
- `go build ./...` / `go test -count=1 ./...` 全16パッケージ ok。
- `npx vitest run` 19ファイル / 150テスト全通過。

### 残課題・次のステップ
- server/ パッケージ（約14,000行）のサブパッケージ分割と `store.Instance` の残存直接参照の DI 化。
- MusicCenter テーマで右サイドバー（歌詞・キュー・イコライザ）が `display:none !important` により到達不能になる仕様の要否判断。
- `pkg/normalize` に正確性テストがない（ベンチマークのみ）。

## 2026-07-04 — UX Sync保存UIとAIムード検索表示の不自然さを修正

### 実施内容
- 既存の未コミット差分を `fix: フルスクリーン背景色同期とシャッフル演出を調整` として整理した。
- UX Sync Phase 5.16 / 5.17 のドキュメントに対して、保存タブから消えていた `syncCachePolicy` の選択UIを復帰した。
- 保存タブの保存処理が `syncMinFreeSpaceGB` / `syncCachePolicy` / `syncPreferredFormat` を同時に正規化して保存するようにした。
- 同期タブのラベルを `転送時の音質` に変更し、push転送用の設定であることが分かる文言にした。
- AIムード検索結果の表示名を `/` と `\` の両方で分割する `moodSearchDisplayName()` に集約し、Windowsパスでもファイル名だけを表示するようにした。
- `markdown/wails-migration-gaps.md` では解消済みと書かれていた曲リスト右クリックの「プレイリストに追加」が、実コードでは `console.log` のみだったため、Wails の `AddSongsToPlaylist` へ曲メタデータを渡す実処理に差し替えた。
- 不具合修正として renderer 版を `1.0.0-Beta-36b` から `1.0.0-Beta-36c` へ更新した。

### 検証
- Red: `npm test -- --run js/features/ai-embed-settings.test.ts js/features/ux-sync-settings-dom.test.ts` で意図した3件の失敗を確認。
- Red: `npm test -- --run js/ui/list-renderer.test.ts` で曲リストのプレイリスト追加が未実装であることを確認。
- Green: `npm test -- --run js/ui/list-renderer.test.ts js/features/ux-sync-settings.test.ts js/features/ai-embed-settings.test.ts js/features/ux-sync-settings-dom.test.ts` PASS。
- `npm run typecheck` PASS。
- `npm test -- --run` PASS（17 files / 131 tests）。

## 2026-06-29 — フルスクリーン背景色が前曲のジャケット色になる不具合を修正

### 実施内容
- 症状：曲変更後にフルスクリーンモードへ入る、またはフルスクリーン中に曲が変わると、背景グラデーションが現在曲ではなく一つ前の曲から抽出された色になる。
- 原因：フルスクリーン側の `notifyFullscreenSongChange()` は曲情報更新直後に `syncColours()` を呼んでいたが、ジャケット画像の読み込みと `setEqualizerColorFromArtwork()` による色抽出は非同期で完了する。そのため、フルスクリーンが CSS 変数 `--eq-color-1` / `--eq-color-2` を読む時点では前曲の値が残っていた。
- 修正：`setEqualizerColorFromArtwork()` が CSS 変数更新後に `equalizer-colours-change` イベントを発火し、フルスクリーンビューが開いている場合はそのイベントで背景色を再同期するようにした。
- TDD：色更新完了イベントが CSS 変数更新後に発火するテストを追加し、Red→Green を確認。

### 検証
- `npm test -- --run js/ui/equalizer-colour-events.test.ts` PASS。
- `npm run typecheck` PASS。
- `npm test -- --run` PASS（14 files / 125 tests）。

### 補足
- 既存の未コミット差分（シャッフルボタンのずらしアニメーション、package-lock 等）は巻き戻さず保持した。

## 2026-06-28 — YouTube 字幕（カラオケ風 en 字幕）の二重登録を修正

### 実施内容
- 症状：`youtube.com/watch?v=eghAYpSDtRw` の en 字幕で全行が二重登録される。
- 原因調査：yt-dlp で srv3 形式の字幕を取得して確認したところ、当該動画は
  カラオケ風に装飾された手動字幕で、各行が **同一開始時刻・同一テキストの
  `<p>` 2 要素**（縁取り用 `et="4"` と塗り用 `et="3"` の 2 レイヤー）として
  出力されていた。実データでは 110 個の `<p>` が実質 55 行に対応。
  既存の `parseTranscriptXMLBody` は両レイヤーをそのままセグメント化していた。
- 修正1：`appendTranscriptSegment` に直前セグメントとの (開始時刻, テキスト)
  一致判定を追加し、隣接する重複レイヤーを 1 行へ統合（110→55 行）。
- 修正2：副次的に判明したゼロ幅文字（U+200B 等）の混入を `sanitiseTranscriptText`
  で除去。`strings.Fields` は ZWSP を空白扱いしないため明示除去が必要だった。
- TDD：各修正の前に失敗するテストを追加（Red→Green）。実ファイルでも
  55 行・ゼロ幅文字なしを確認。版を `Beta-36a`→`Beta-36b` に更新。

### 選定理由・判断の根拠
- 重複判定は「直前セグメントとの一致」に限定。当該フォーマットでは重複は常に
  隣接ペアであり、全体走査やハッシュ集合より単純で、別時刻の正当な繰り返し
  歌詞を誤って削らない。
- ゼロ幅除去は `strings.NewReplacer` でソース内にリテラル BOM を埋め込めない
  ため Go コンパイル要件に従い対応（実装は通常の文字リテラルで完結）。

### 残課題・次のステップ
- 自動生成字幕（asr）でも同種の重複が出ないか、別動画でも追って確認したい。

## 2026-06-28 — 長時間一時停止後に再生再開できない不具合を修正

### 実施内容
- 症状：曲を再生 → 一時停止 → 数時間放置すると再開できなくなる（Wails/Go
  バックエンドの `pkg/audio` Player）。
- 既存の対策（`eb5ce5d`）は長時間ポーズ後に `reopenStream()` で出力ストリームのみ
  張り直していたが、**デコーダーは使い回し**だった。m4a/aac/ogg は FFmpeg
  サブプロセスでデコードしており、数時間のポーズ／システムスリープで
  サブプロセスやパイプが死ぬとストリームだけ復活しても無音で固まる。
- `Player.Resume()` を再設計：
  - 短時間ポーズはこれまで通りキャッシュ済みストリームを `Start()` で復帰。
  - **長時間ポーズ、またはストリーム復帰に失敗した場合**は、保存しておいた
    再生位置でトラックを丸ごと再構築（`restartCurrentTrack` → `Play()` + `Seek()`）。
    ファイル・デコーダー・出力ストリームを作り直すため、固まった状態に依存しない。
- `Player` に `currentPath`（`Play` で記録）と、テスト用シーム `restartTrack` を追加。
- テスト追加（`player_resume_test.go`）：長時間ポーズで再構築されること・位置が
  保持されること・復帰失敗時も再構築にフォールバックすること・トラック未ロード時は
  エラーになること。`go test ./pkg/audio/` PASS、`go build ./...` 通過。
- バージョンを `35b` → `36a` に更新（重大な不具合の修正）。

### 選定理由・判断の根拠
- ユーザー要望「根本的に治せない場合は再生中の曲をそのまま再生し直す挙動で良い」に
  沿い、ストリーム／デバイスハンドルの延命という壊れやすい経路ではなく、
  トラック全体の再構築という確実な復旧手段を採用した。FFmpeg デコーダー死亡・
  スリープ後のデバイスハンドル陳腐化の両方をまとめて解消できる。
- 既存の長時間ポーズ用テスト（`reopenStream` 前提）は「効かないと分かっている方式」を
  検証していたため、新方式（再構築）を検証するテストへ置き換えた。
- `reopenStream` 自体は `SetDevice` でなお使用しているため残置。

## 2026-06-25 — UX Sync 自動同期トーストの乱発を抑止

### 実施内容
- 自動同期ループ（60 秒間隔、`server/app_sync_auto.go`）が、ペア端末が 1 台でも
  あれば毎周期 `ux-sync-auto-result` を emit していたため、フロントで毎分トーストが
  出続けていた問題を修正。
- **フロント** `formatSyncAutoResultNotification`：新規データ（取得 / 再生回数送信 /
  ジャケット）が動いたときだけメッセージを返すよう変更。既存曲のスキップのみ・
  単なる接続確認では空文字を返し無音化。
- **バックエンド**：`syncAutoResultIsNotable()` を新設し、新規データ・一時停止・
  失敗があるときだけ emit するようループの条件を変更（無駄な IPC も削減）。
- vitest 53 件・Go テスト追加（`TestSyncAutoResultIsNotable`）とも PASS。
- バージョンを `35a` → `35b` に更新。

### 選定理由・判断の根拠
- 定常状態では `skippedTracks`（既存曲）が毎周期非ゼロになり「既存 N 曲」トーストが、
  あるいは parts 空で「接続できたため同期を確認しました」が必ず出ていた。これが
  「無限に下に出てくる」の正体。ユーザーに知らせる価値があるのは新規データ・停止・
  失敗のみと判断し、表示・emit 両方で同じ基準に絞った。
- 表示判定（TS）と emit 判定（Go）の二重化は懸念だが、フロントは表示の最終ゲート、
  バックエンドは IPC 抑制が目的で役割が異なるため、両方に最小ロジックを置いた。

## 2026-06-25 — 同期歌詞の間奏表示と和訳プロンプトのコピー文字化けを修正

### 実施内容
- **間奏マーカー `[間奏]` の表示を空白化**。`lyrics-translation.ts` に間奏判定の
  単一情報源 `isInterludeText()`（空行＋ `[間奏]` / `[interlude]` / `(interlude)`
  マーカーを認識）を新設し、`isBlankPrimaryLine()` をこれに委譲。
  - 再生画面 (`lyrics-manager.ts`) と全画面 (`fullscreen-view.ts`) の描画で
    間奏行は本文を出さず半角スペース（行高のみ維持）に置換。既存ファイルの
    `[間奏]` も対象。
  - LRC エディタ (`lrc-editor.ts`) の保存時、間奏行は `[mm:ss.xx]` のみの空行で
    書き出すよう変更。エディタ UI 上の `[間奏]` 表示と「間奏挿入」操作は維持。
  - 和訳プロンプトでも `[間奏]` を `[INTERLUDE: …]` プレースホルダ扱いに統一。
- **和訳用プロンプトのコピー文字化けを修正**。`navigator.clipboard.writeText`
  （UTF-8 安全）を優先し、Wails `ClipboardSetText` はフォールバックに降格。
- バージョンを `1.0.0-Beta-34c` → `35a` に更新。

### 選定理由・判断の根拠
- 間奏はコード全体で「空行」として扱われる設計（`isBlankPrimaryLine` が和訳の
  欠落・サイドカー生成を制御）だったが、エディタだけが `[間奏]` を実テキストとして
  書き込んでおり不整合だった。判定を 1 箇所に集約し、保存も空行へ寄せることで
  設計に一致させた。既存ファイル救済のため表示側でも `[間奏]` を空白化。
- 文字化けは Wails の IPC ブリッジが非 ASCII を破損するため。すでに `cd-ripper.ts`
  が Web 標準 API で正常動作していたので、それに揃えた。

### 残課題・次のステップ
- TDD: 純粋関数は vitest で Red→Green を確認（全 121 件 PASS、tsc クリーン）。
  描画・クリップボードは DOM 依存のため手動確認推奨。

## 2026-06-19 — Phase 3 (Gemma 4 E2B): エンドツーエンドのムード特集生成が動作

### 実施内容
- LLM 推論スタックを **MLX-LM から llama.cpp (llama-server)** に切替。理由は
  `mlx-community/gemma-4-e2b-it-4bit` が mlx-vlm 0.6.3 の Gemma 4 実装と weights
  が一致せず "140 parameters not in model" でロード失敗したため。MLX は将来の
  LoRA 学習用に温存 (pyproject `[gemma-special]` 残置)。
- Gemma 4 E2B QAT GGUF (`google/gemma-4-E2B-it-qat-q4_0-gguf`, 3.1GB) を
  `~/.cache/ux-music/models/` に DL し、llama-server で **44.7 tok/s の日本語生成** を確認。
- `internal/llamasrv/` 新設: HTTP クライアント (`/completion` + Gemma chat
  テンプレート) + 子プロセス管理 (Start 90s timeout / SIGTERM→SIGKILL escalation)。
  ユニットテスト 11/11 PASS。
- `internal/special/` 新設: 候補曲を**インデックス参照** ([1] [2] ...) で
  Gemma に渡し、JSON 出力を強制。範囲外/重複は drop。
  ユニットテスト 5/5 PASS。
- Wails App: `GenerateMoodSpecial(mood, topK)` を新設。CLAP 候補抽出 →
  library JSON から title/artist/album を join → llama-server 遅延起動 → 特集 JSON 生成。
- `main.go` に `OnShutdown` を配線し、アプリ終了時に llama-server を確実に停止。
- 設定 UI に「Gemma 4 E2B で特集化」ボタン追加。検索 → 結果リスト → 特集ボタン
  → 生成結果 (タイトル/紹介文/曲順/コメント) のフローが完成。

### 選定理由・判断の根拠
- **llama.cpp 採用の根拠**: Ollama より高速かつ単一バイナリで配布性が良く、
  既に Gemma 4 を安定サポート。MLX のバグ修正待ちは Phase 3 完了をブロック
  するため切替を即決した。
- **`/completion` + 手動 Gemma テンプレート**: llama-server 9700 の
  `/v1/chat/completions` は `--jinja` の有無に関わらず Gemma 4 で空 content を
  返す不具合 (300 tokens 生成されているのに content 長 0)。`/completion` は
  英日双方で正常動作するため、Go 側もこちらで固定。
- **インデックス参照プロンプト**: Gemma に long path を出力させるとハルシ
  ネーション (typo, 存在しないファイル) のリスクが高い。`[1] タイトル / アーティスト`
  形式にして番号で参照させ、Go 側で番号→TrackID マップ。範囲外はサイレントに
  drop することで誤参照に対して堅牢。
- **遅延起動 vs 常駐**: 初回起動は 10〜20s 待ちだが、特集生成は数秒〜10秒で
  完了する短い操作。常駐させると 1.8GB を恒常占有するため、必要な時だけ
  起動する設計を採用。

### 残課題・次のステップ
- 実際にライブラリで CLAP 解析 → 検索 → 特集生成のフルパス E2E 動作確認
  (実曲データで Gemma の品質を 50 件評価セットで定量化)。
- Phase 2 (VocaDB / Wikipedia メタデータ補完) — 同人圏のアーティスト情報を
  プロンプトに混ぜないと「未知アーティスト」で Gemma がフリーズ気味になる可能性。
- Phase 4 (評価結果次第): 文体が単調なら蒸留 SFT、選曲がブレるなら CLAP 側
  ロジック改善 (LLM 責任ではない)。
- 配布時: llama.cpp バイナリの `build/bin/` 同梱と GGUF DL UI 化。

---

## 2026-06-19 — Phase 1 完了: CLAP 埋め込み基盤 + 検索 API

### 実施内容
- Python サイドカー (`python/audio_embed/`) を新設。ダミーモード骨組み → 実 CLAP (laion-clap `music_audioset_epoch_15_esc_90.14.pt`, HTSAT-tiny + fusion) を遅延ロードして 512次元 float32 を返す実装まで完了。
- `python/audio_embed/embedder.py` にテキスト埋め込みパスを追加（同一モデルの text encoder）。Request に `text`/`texts` を受け、`textEmbeddings` を返却。
- Go 側 `internal/audioembed/` を新設し、以下を実装。
  - `store.go`: JSON index + 連結 float32 バイナリの 2 ファイル構成で永続化。再解析は末尾 append + index 貼り替え（旧行は dead space）。
  - `sidecar.go`: Python サイドカー呼び出し (stdin/stdout JSON、stderr 進捗パース)、venv 自動解決。
  - `analyser.go`: バッチ + 増分。`Needs(version)` で skip 判定、進捗コールバック。
  - `search.go`: コサイン類似度ランキング、テキストクエリの埋め込み→ストア線形検索。
- Wails 公開 API (`server/app_audio_embed.go`) を追加。
  - `AnalyseLibraryAudioEmbeddings()` — ライブラリ全曲を解析（Wails event `audio-embed-progress` で進捗通知）。
  - `SearchTracksByMood(query, topK)` — テキストで類似曲ランキング。
  - `GetAudioEmbedStatus()` — 保存件数と version 取得。
- TDD でユニットテスト 21 件 (audioembed パッケージ単独) + 既存全 Go テスト PASS、Python ダミー/実 CLAP 両方の smoke PASS。

### 選定理由・判断の根拠
- **SQLite ではなくファイル 2 個構成**: 本プロジェクトに SQLite は未導入で、依存追加を Phase 1 のスコープに入れたくなかった。10 万曲でも約 200MB、線形検索ミリ秒級で当面十分。将来 sqlite-vec/FAISS に差し替える際もインターフェース変更は最小。
- **CLAP テキスト埋め込みを同一サイドカーに同居**: 別プロセス立てるとモデルロードが二重化する（5s×2）。Request に text フィールドを追加するだけでよいので 1 プロセスに集約。
- **AnalyseSongs に SidecarRunner abstraction**: production は RunSidecar クロージャ、テストは stub。サイドカー実行を含まない高速な単体テストが可能になった。
- **version 文字列での差分検出**: モデル/前処理の改善ごとに `CurrentAudioEmbedVersion` をバンプすれば全曲が自動的に再解析対象になる。タイムスタンプベースより堅牢。
- **同期実行 (await) + Wails event 進捗**: Phase 1 では非同期キャンセル機構を入れず、フロントから await で十分。Phase 2 以降の必要性次第で再考。

### 残課題・次のステップ
- Phase 1 残り: Wails 経由で実際にライブラリを解析して動作確認（実曲を CLAP に通すフルパス E2E）。
- Phase 2: VocaDB / Wikipedia メタデータ補完（事実性 RAG の前提）。
- Phase 3: Gemma E2B プロトタイプ着手前に、評価セット 50 件を作成。
- ストア圧縮: 再解析で生まれる dead row の compaction を別タスク化。

---

## 2026-06-19 — AI 特集機能 計画策定とブランチ作成

### 実施内容
- AI による「アーティスト特集」「ムード特集」機能（Apple Music/Spotify 風）のオンデバイス実装計画を策定し、`markdown/ai-feature-special-plan.md` に保存した。
- 既存 `lyrics-sync-test` 上の Wear/Mobile リファクタを 1 コミットにまとめてクローズし、新ブランチ `ai-feature-special` を作成した。
- Phase 1 (CLAP 埋め込み基盤) のサブタスクを TaskCreate で 8 件登録した。

### 選定理由・判断の根拠
- **モデル**: Gemma 系 E2B (MatFormer) を採用。日本語会話品質が実用域で、Mac mini M4 32GB および将来の iPhone Air にも展開可能。SLM 自作は GPU コスト的に非現実的なため却下。
- **役割分担**: 「音楽的判断は CLAP 埋め込み + メタデータ、LLM は言語化のみ」。LLM に選曲をさせないことでハルシネーション (存在しない曲名等) を構造的に回避する。
- **音声埋め込み**: LAION-CLAP を採用。テキスト⇔音声を同一空間に埋めるため「夜ドライブ系」のようなテキストクエリで類似検索が可能になり、Phase 1 単体でも体験価値が出る。
- **学習戦略**: いきなり蒸留/RL に踏み込まず、まず素の Gemma E2B + RAG + プロンプト設計で評価。文体問題が残った場合のみ Mac mini M4 上で MLX-LM LoRA SFT。RL は最後まで封印 (報酬設計の難しさと小規模 RL の不安定性を考慮)。
- **データソース**: VocaDB/UtaiteDB/TouhouDB API + Wikipedia。ユーザーが同人/VocaDB 圏を聴くため、メジャー側だけのカバレッジでは不十分。
- **Python サイドカー方式**: 既存 `python/lyrics_sync` と同パターン。Wails の Go 本体を汚さず、venv 自動検出機構も流用できる。

### 残課題・次のステップ
- Phase 1 Step 1: CLAP モデル選定 (laion_clap の `music_audioset_epoch_15_esc_90.14.pt` 等) と Mac での動作確認。
- TDD で `python/audio_embed/` の骨組みをダミーモード対応で先に作る。
- `track_audio_embeddings` テーブルのマイグレーションテストを書く。

---

## 2026-06-15 — 不足テスト調査

### 実施内容
- `markdown/` と `UX-Music-Mobile/markdown/` の仕様を読み、現在の差分が Mobile の Wear API mDNS 自動発見へ寄っていることを確認した。
- 未コミット差分とテスト一覧を照合し、`WearDiscoveryService` / `SettingsScreen` / `WearAPIClient` の新規・変更仕様に対するテストの穴を洗い出した。
- 既存の大きな未テスト領域として、renderer 画面層、SwiftUI 画面統合、`internal/analyzer` / `internal/config` / `internal/discord` / `pkg/mtp` などを確認した。

### 検証
- `npm test -- --run`: 13 files / 115 tests passed。
- `go test ./...`: passed。
- `go test ./... -cover`: 初回に `TestRunSidecarDummySwift` が Swift sidecar の empty stdout で一度失敗したが、同テスト単体再実行と通常 `go test ./...` は通過。
- XcodeBuildMCP `test_sim`: 71 passed, 0 failed, 1 skipped（実機 mDNS 診断のみフラグ未指定で skip）。

### 不足テスト候補
- Mobile mDNS: `schemaVersion` の明示アサート、`WearHost` role 許容、空 host / port 0 の拒否、`txtDictionary` / `hostStrings(from:)` の境界テスト。
- Mobile Settings: 接続テストが手動 host 失敗後に discovery の次候補へフォールバックし、成功 host を保存する統合テスト。
- Mobile UI: `HomeRootView` の TabView 化、mini player accessory、Settings discovery 表示の回帰テスト。
- 既存広範囲: renderer の `cd-ripper` / `lrc-editor` / `player` / `audio-graph` / UI renderer 系、Go の未テスト package、Swift lyrics-sync の CLI / runtime 周辺。

---

## 2026-06-13 — Mobile Wear API 接続候補のフォールバック

### 実施内容
- 実機で mDNS 発見後に `Connection failed` になる症状に対し、Mac mini が複数の IPv4 interface を広告している場合に到達不能な候補だけを保存してしまう可能性を切り分けた。
- UX-Music-Mobile の `WearDiscoveryPeer` が `NetService.addresses` 由来の複数 IPv4 と Bonjour host名を重複排除した `connectionHosts` として保持するようにした。
- Settings の `Test` は手動入力 host を先頭にしつつ、選択済み discovery peer の候補を順に `/wear/ping` へ試し、成功した host / port を `ServerConfig` と入力欄へ保存するようにした。

### 検証
- Red: `WearDiscoveryPeerTests.testFromTXTKeepsAllIPv4ConnectionCandidatesBeforeBonjourHostname` は `connectionHosts` 未実装で失敗。
- Green: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testFromTXTKeepsAllIPv4ConnectionCandidatesBeforeBonjourHostname -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testConnectionCandidatesKeepManualHostFirstAndDeduplicateDiscoveredHosts test`: succeeded.
- XcodeBuildMCP `test_sim`（Wear discovery / LAN session 限定）: 11 passed, 0 failed, 1 skipped.
- XcodeBuildMCP `test_sim`（全体）: 71 passed, 0 failed, 1 skipped.
- 実機 build: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'platform=iOS,id=00008150-001A55A63C07801C' build`: succeeded.

## 2026-06-13 — Mobile mDNS listener 維持と探索表示 timeout の分離

### 実施内容
- UX-Music-Mobile の Settings mDNS scan timeout が `NetServiceBrowser` 自体を止めていたため、遅れて届く Bonjour 発見・解決を取りこぼし得る状態になっていた。
- timeout 後は `isBrowsing` の探索中表示だけを閉じ、`isDiscoveryActive` と underlying listener は Settings 表示中維持するように変更した。
- `Search again` は listener を stop/start せず、既存 listener のまま探索中表示の scan window を再開するようにした。

### 検証
- Red: `WearDiscoveryPeerTests.testDiscoveryKeepsListenerActiveAfterScanTimeout` は `isDiscoveryActive` 未実装で失敗。
- Green: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryHidesSearchingIndicatorAfterScanTimeout -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryKeepsListenerActiveAfterScanTimeout test`: succeeded.
- `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryHidesSearchingIndicatorAfterScanTimeout -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryKeepsListenerActiveAfterScanTimeout -only-testing:UX-Music-MobileTests/WearAPIClientTests/testWearLANConfigurationBypassesSystemProxyAndCellularFallback test`: succeeded.
- 実機 build: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'platform=iOS,id=00008150-001A55A63C07801C' build`: succeeded.

## 2026-06-13 — Mobile Settings のネットワーク待ち対策

### 実施内容
- UX-Music-Mobile の Settings 表示時に始まる mDNS 探索へ scan indicator timeout を追加し、探索中表示が残り続けないようにした。
- Wear API の通常 LAN HTTP セッションを request timeout 10秒 / resource timeout 45秒へ短縮し、到達不能な Desktop への通信が長時間 UI 体験を塞がないようにした。
- 音源ダウンロード専用セッションは request timeout 30秒 / resource timeout 300秒を明示し、大容量転送の猶予は維持した。

### 検証
- Red: `WearDiscoveryPeerTests.testDiscoveryStopsBrowsingAfterScanTimeout` は `start(scanTimeout:)` 未実装で失敗。
- Green: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryStopsBrowsingAfterScanTimeout test`: succeeded.
- Red: `WearAPIClientTests.testWearLANConfigurationBypassesSystemProxyAndCellularFallback` は timeout 期待値追加後に失敗。
- Green: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearAPIClientTests/testWearLANConfigurationBypassesSystemProxyAndCellularFallback -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testDiscoveryStopsBrowsingAfterScanTimeout test`: succeeded.
- 実機 build: `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'platform=iOS,id=00008150-001A55A63C07801C' build`: succeeded.
- 実機 mDNS XCTest の再実行は `YkiPhoneAir` への Launch/CoreDevice worker materialize 待ちで 280秒後に手動中断した。テスト本体の timeout には入っておらず、アプリ側ではなく Xcode / CoreDevice 側の停止として記録する。

## 2026-06-13 — Mobile Wear API mDNS自動発見

### 実施内容
- Wear API (`/wear/*`) を UX Sync Protocol の lightweight mobile / wearable profile として扱う方針を `markdown/ux-music-sync-protocol.md` に追記した。
- UX-Music-Mobile に `_uxmusic-sync._tcp.local.` を探索する `WearDiscoveryService` と、TXT / role / host / port を正規化する `WearDiscoveryPeer` を追加した。
- Settings 画面に発見済み Desktop の一覧と再検索ボタンを追加し、選択した peer を既存の `ServerConfig` に保存できるようにした。
- iOS の Bonjour 探索許可として `NSBonjourServices` に `_uxmusic-sync._tcp` を追加した。
- Mobile 側の `markdown/Task.md` / `markdown/Implementation_Plan.md` / `progress.md` を Wear API mDNS 自動発見の内容へ更新した。
- 実機で `.local` host 保存後に Remote Library が `Unreachable` になる可能性を避けるため、`NetService.addresses` から得た数値IPv4を Bonjour host名より優先して `ServerConfig` へ保存するようにした。
- 実機で `192.168.x.x:8765` が `mask.icloud.com` 経由の proxy fallback へ流れて 502 になる現象を避けるため、Wear API の LAN 通信用 `URLSession` を ephemeral / proxy無効 / cellular fallback無効 / cache無効の専用設定へ変更した。
- ビルド済み app bundle に local network usage description と Bonjour service が入ることをテストで固定した。
- 明示フラグ付きの実機診断 XCTest を追加し、同一LAN上の `_uxmusic-sync._tcp.local.` peer を `WearDiscoveryService` 経由で発見できるか確認できるようにした。
- 診断過程で、直接の `NetServiceBrowser` probe は iPhone 実機から `YukinoMac-mini` を発見できた一方、`WearDiscoveryService` 経由では timeout していたため、発見後の `NetService.resolve` を browser callback 内で開始するよう修正した。

### 検証
- `WearDiscoveryPeerTests`
- XcodeBuildMCP `test_sim`: 64 tests passed, 0 failed, 0 skipped.
- `swiftc -typecheck UX-Music-Mobile/UX-Music-Mobile/Services/WearDiscoveryService.swift UX-Music-Mobile/UX-Music-Mobile/Models/ServerConfig.swift UX-Music-Mobile/UX-Music-Mobile/Core/AppConstants.swift`
- `swiftc -typecheck UX-Music-Mobile/UX-Music-Mobile/Services/WearAPIClient.swift UX-Music-Mobile/UX-Music-Mobile/Models/Song.swift UX-Music-Mobile/UX-Music-Mobile/Models/Album.swift UX-Music-Mobile/UX-Music-Mobile/Core/AppConstants.swift`
- `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'generic/platform=iOS Simulator' -only-testing:UX-Music-MobileTests/WearAPIClientTests/testWearLANConfigurationBypassesSystemProxyAndCellularFallback build-for-testing`: succeeded.
- `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' test`: succeeded.
- `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'id=573CA9F8-DBEB-4E26-A632-5C429B642B6E' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests test`: succeeded.
- `xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination 'platform=iOS,id=00008150-001A55A63C07801C' 'OTHER_SWIFT_FLAGS=$(inherited) -DUX_MUSIC_REAL_DEVICE_DISCOVERY_TEST' -only-testing:UX-Music-MobileTests/WearDiscoveryPeerTests/testRealDeviceDiscoversUXSyncMDNSPeer test`: succeeded on `YkiPhoneAir`。修正前は 10秒 timeout で失敗していたが、`WearDiscoveryService` 経由で `_uxmusic-sync._tcp.local.` peer を発見できることを確認した。

## 2026-06-13 — Mobile App UI改変のロールバック

### 実施内容
- `UX-Music-Mobile` 配下だけを、Walkman Cross UI 導入前の Mobile App 変更履歴上一つ前である `d7ccc43` 相当へ復元した。
- `HomeRootView.swift` を従来のタブ型ルートへ戻し、十字スワイプUI用に追加された `CrossPlayerNavigation.swift` と `CrossPlayerNavigationTests.swift` を削除した。
- Mobile App 用に追加されていた Walkman Cross UI の Task / Implementation Plan / Walk Through / progress 文書も、UI導入前の状態へ戻した。
- ルート側に既に存在していた `.gitignore`、`go.mod`、`go.sum`、Wails 生成物などの未コミット差分には触れていない。

### 検証
- XcodeBuildMCP: `UX-Music-Mobile` scheme を iPhone 17 Simulator で `test_sim` 実行。
- 結果: 60 tests passed, 0 failed, 0 skipped。

## 2026-06-10 — UX Sync mini逆輸入汚染の再発防止と掃除

### 実施内容
- Mac mini 実機で `library.json` が 5715 曲まで増え、内訳が原本 `/Users/yuki/doc/uxmusic` 812 曲 + `SyncLibrary` 由来 4903 曲になっていることを確認した。
- 原因は mini が Air / 過去 peer を `LibraryHost` とみなし、自分の原本曲と同じ matchKey の曲を `SyncLibrary` へ逆輸入していたこと。
- 再発防止として、`PullSyncLibraryAssets` が remote snapshot の曲を処理する前に、ローカル原本（`syncSourceDeviceId` を持たない曲）の `syncSongMatchKey` と一致する remote 曲を skip するようにした。
- mini の UX-Music / 残存 ffmpeg を停止したうえで、`library.json` から `SyncLibrary` 由来の 4903 件を削除し、同期コピー側に付いた再生回数 14 エントリを対応する原本 path へ合算した。
- `~/Library/Application Support/ux-music/SyncLibrary`（約 41GB）を削除し、空き容量を約 69GiB まで回復した。
- 掃除前に JSON 一式を `~/uxmusic-databackup-before-clean-20260610-104303/` へ保存した。
- 不具合修正扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-31c`、`markdown/requirement.md` を `0.1.9-Beta-34c` に更新した。

### 検証
- `go test ./server -run 'TestPullSyncLibraryAssetsSkipsRemoteTrackWhenLocalMatchExists|TestPullSyncLibraryAssetsDownloadsRemoteTrackIntoManagedLibrary|TestPullSyncLibraryAssetsRequestsPreferredMP3320WhenPeerSupportsIt' -count=1`
- `go test ./server -count=1`
- `npm test --prefix src/renderer -- --run`
- `npm run typecheck --prefix src/renderer`

## 2026-06-10 — UX Sync 手動ペアリング導線

### 実施内容
- mDNS が使えない環境向けに、UX Sync 専用設定画面の `端末` タブへ IP / ホスト名と任意ポートの手動入力欄を追加した。
- `manualSyncPeerBaseUrl` を追加し、裸の IP / host、`host:port`、完全 URL、空入力や制御文字混入を正規化できるようにした。
- 手動入力から合成 peer を作り、既存の `startSyncPairing` → 6桁コード表示 → `confirmSyncPairing` のペアリングフローに合流させた。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-31a`、`markdown/requirement.md` を `0.1.9-Beta-34a` に更新した。

### 検証
- `npm test --prefix src/renderer -- --run js/features/ux-sync-settings.test.ts`
- `go test ./... -count=1`
- `npm test --prefix src/renderer`
- `npm run typecheck --prefix src/renderer`

## 2026-06-10 — mDNS TXT 255バイト制限の緊急修正

### 実施内容
- mDNS TXT の `capabilities=` が full capability set で 255 バイトを超え、zeroconf の広告送信を失敗させる問題を修正した。
- `BuildMDNSText` から `capabilities` 行を外し、TXT は `deviceId` / `displayName` / `protocolVersion` / `schemaVersion` / `roles` の軽量ヒントだけにした。
- capability は従来どおり reachableBaseUrl probe 後の `/sync/identity` から取得する方針を `markdown/ux-music-sync-protocol.md` に明記した。
- 不具合修正扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-30b`、`markdown/requirement.md` を `0.1.9-Beta-33b` に更新した。

### 検証
- `go test ./internal/uxsync ./server -run 'TestBuildMDNSText|TestSyncMDNSAdvertiseInfo_usesHostIdentity' -count=1`
- `go test ./... -count=1`
- `npm test --prefix src/renderer`
- `npm run typecheck --prefix src/renderer`

## 2026-06-10 — UX Sync ポータブル MP3 キャッシュ

### 実施内容
- `/sync/assets/{trackId}/file?encoding=mp3_320` を追加し、元が非 MP3 の曲は `syncOpenMP3Stream` で MP3 320kbps としてストリーミング配信するようにした。
- 元が MP3 の曲は再変換せず原本配信し、変換失敗時は原本へフォールバックせずエラーにするようにした。
- `syncPreferredFormat` 設定を追加し、`mp3_320` かつ peer が `library.transcode.mp3-320.v1` を広告する場合だけ pull / tap DL / prefetch / selective 自動同期の取得 URL に `encoding=mp3_320` を付けるようにした。
- pull 取込曲へ `syncTransferEncoding: "mp3_320"` と `audioBitrateKbps: 320` を保存し、保存名も `.mp3` にするようにした。
- UX Sync 設定の `保存` タブに優先フォーマット選択（原本 / MP3 320kbps）を追加した。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-30a`、`markdown/requirement.md` を `0.1.9-Beta-33a` に更新した。

### 検証
- `go test ./server -run 'TestSyncAssetFileServesMP3320EncodingWhenRequested|TestSyncAssetFileKeepsOriginalMP3WhenMP3320Requested|TestSyncAssetFileServesOriginalFileByTrackID|TestSyncAssetFileFailsMP3320EncodingWithoutOriginalFallback|TestPullSyncLibraryAssetsRequestsPreferredMP3320WhenPeerSupportsIt|TestPullSyncLibraryAssetsFallsBackToOriginalWhenPeerLacksMP3320Capability|TestPullSyncLibraryAssetsKeepsOriginalWhenPreferredFormatIsOriginal|TestSyncSongMatchKeyIgnoresTransferredFormat' -count=1`
- `npm test --prefix src/renderer -- --run js/features/ux-sync-settings.test.ts`
- `go test ./... -count=1`
- `npm test --prefix src/renderer`
- `npm run typecheck --prefix src/renderer`

## 2026-06-09 — safe-media Windows絶対パス復元の修正

### 実施内容
- `/safe-media/` のデコード処理が Windows ドライブレター付き絶対パスを `/C:/...` のように変換し、Windows で `filepath.IsAbs` が失敗して Forbidden になり得る問題を修正した。
- `decodeSafeMediaPath` で Windows ドライブレター、既存の先頭スラッシュ、相対パスを分けて候補パスを作るようにした。
- 不具合修正扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-29c`、`markdown/requirement.md` を `0.1.9-Beta-32c` に更新した。

### 検証
- `go test . -run 'TestDecodeSafeMediaPathKeepsWindowsDriveAbsolute|TestDecodeSafeMediaPathKeepsPosixAbsolutePath|TestAssetHandlerServesRegisteredSafeMediaWithReservedCharacters' -count=1`
- `go test ./... -count=1`

## 2026-06-09 — UX Sync 再生回数収束の実機検証（Crescent / Windows）

### 実施内容
- ヘッドレス検証用に `cmd/synctest`（renderer 資産を embed しない最小 main）と `--sync-serve` CLI を追加した。
- Crescent（Windows10, Go/mingw/git あり, データ使い捨て可）に git bundle 経由でブランチを転送し、`go build ./cmd/synctest` でネイティブビルドした。
- mingw ランタイム DLL を PATH に通し、`Win32_Process.Create` で SSH セッションから切り離して `--sync-serve` を常駐起動した（OpenSSH はセッション終了で子プロセスを道連れに kill するため）。
- 実 Windows バイナリ＋実ストアに対し `127.0.0.1:8765/sync/library/events` へ再生イベントを POST して検証した。
  - Test1 メタデータ一致（未pull曲・trackId はローカルに無い）→ ローカル曲へ反映 count=1。
  - Test2 同一 eventID 再送 → 冪等（count 据え置き）。
  - Test3 別 eventID・同曲 → count 2。
  - Test4 非一致 matchKey → playcounts に幽霊エントリ無し。ただし sync-play-events ログには3件全部保持。

### 判断
- Mac → Crescent:8765 の inbound は Windows Firewall で遮断（SSH:22 は可）。従来テストは Crescent がクライアント=outbound だったため顕在化しなかった。受信ロジック検証に LAN ホップは不要なため Crescent ローカルから検証した。
- Phase 1.5 のライブ emit は GUI 無しのヘッドレスでは観測不可（a.ctx nil で skip）。stub 単体テストで担保済み。

### 後片付け
- Crescent の `SyncLibrary`（約30GB の旧テスト音源）と転送バンドルを削除。空き 124.5GB。
- 再テスト用に `C:\Users\HariBote\uxtest`（クローン＋synctest.exe＋serve.bat）は残置。

## 2026-06-09 — Gemini Code Assist レビュー指摘の実害修正

### 実施内容
- `randomBytes` で `crypto/rand.Read` 失敗時に時刻文字列へフォールバックしていた処理を廃止し、乱数源が利用できない場合は panic するようにした。
- `DiscoverMDNS` で entries channel close 時に nil を受け続けないよう、`ok` を確認して close 後は select 対象から外すようにした。
- `/safe-artwork/` handler が unescaped path から prefix を外すようにし、空白入り artwork 名を安全に解決できるようにした。
- `formatInt64` の自作変換を `strconv.FormatInt` に置き換え、`math.MinInt64` でも正しく扱えるようにした。
- 不具合修正扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-29b`、`markdown/requirement.md` を `0.1.9-Beta-32b` に更新した。

### 検証
- `go test . -run 'TestAssetHandlerServesSafeArtworkWithEscapedSpace|TestAssetHandlerRejectsSafeArtworkTraversal|TestAssetHandlerServesRegisteredSafeMediaWithReservedCharacters' -count=1`
- `go test ./internal/uxsync -run 'TestFormatInt64HandlesMinInt64|TestPruneAcknowledgedOutbox' -count=1`
- `go test ./server -run 'TestSyncLibraryEvents|TestSyncIdentity|TestStartSyncPairing' -count=1`

## 2026-06-09 — UX Sync スマートキャッシュと容量ポリシー

### 実施内容
- `syncCachePolicy` を追加し、既定の `mirror` では現行どおり全曲 pull、`selective` では最近再生 remote 曲とキュー先読みだけを取得するようにした。
- `recentRemoteSyncTrackRefs` と `PrefetchSyncTracks` を追加し、playcounts history と remote catalog から取得対象を決定できるようにした。
- selective かつ空き容量閾値未満の場合、最終アクセスが最も古い同期取得音源をファイルと `library.json` から削除する LRU 処理を追加した。
- renderer に cache policy の正規化と保存タブ向け選択肢、キュー先読み refs 生成と `PrefetchSyncTracks` bridge 呼び出しを追加した。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-29a`、`markdown/requirement.md` を `0.1.9-Beta-32a` に更新した。

### 検証
- `go test ./server -run 'TestAutoSyncPairedDevicesSelective|TestAutoSyncPairedDevicesMirrorPolicy|TestRecentRemoteSyncTrackRefs|TestPrefetchSyncTracks|TestSelectiveCachePrunes|TestMirrorCachePolicyDoesNotPrune|TestDownloadSyncTrack' -count=1`
- `npm test --prefix src/renderer -- --run js/features/ux-sync-settings.test.ts js/features/playback-manager.test.ts`
- `npm run typecheck --prefix src/renderer`

## 2026-06-09 — UX Sync シームレスDL再生

### 実施内容
- `DownloadSyncTrack(sourceDeviceId, sourceTrackId)` を追加し、`sync-remote-catalog` の track metadata と既知 peer/token から対象曲だけを取得して `SyncLibrary` へ import できるようにした。
- renderer の remote 曲再生フローを、`DownloadSyncTrack` 呼び出し、統一ライブラリ再取得、local 曲として再生へ遷移する流れに変更した。
- DL 失敗時はエラー通知を出し、再生に入らないようにした。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-28a`、`markdown/requirement.md` を `0.1.9-Beta-31a` に更新した。

### 検証
- `go test ./server -run 'TestDownloadSyncTrack' -count=1`
- `npm test --prefix src/renderer -- --run js/features/playback-manager.test.ts`

## 2026-06-09 — UX Sync 統一ライブラリビュー

### 実施内容
- `sync-remote-catalog` ストアを追加し、LibraryHost peer の `/sync/library/snapshot` metadata をキャッシュできるようにした。
- `GetUnifiedLibrary()` を追加し、local 曲には `syncAvailability="local"`、未取得 remote 曲には `syncAvailability="remote"` と取得元 peer 情報を付けて返すようにした。
- local/remote および複数 peer 間の重複は `syncSongMatchKey` で dedup し、local 曲を優先するようにした。
- `LoadLibrary()` が統一ライブラリビューを emit するようにした。
- renderer で remote 曲に `DL可能` バッジを表示し、プレースホルダ artwork を使い、再生アクション対象外として扱うようにした。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-27a`、`markdown/requirement.md` を `0.1.9-Beta-30a` に更新した。

### 検証
- `go test ./server -run 'TestGetUnifiedLibrary|TestRefreshSyncRemoteCatalog' -count=1`
- `npm test --prefix src/renderer -- --run js/ui/sync-availability.test.ts`

## 2026-06-09 — UX Sync イベント受信後の再生回数ライブ通知

### 実施内容
- `/sync/library/events` 受信後、再生回数イベントを `playcounts` に再計算・適用できたタイミングで、最新 `playcounts` を `play-counts-updated` として Wails frontend へ emit するようにした。
- `registerSyncRoutes` が `App` を保持し、同期イベントハンドラから `App.ctx` と差し替え可能な `playCountsEmitter` を参照できるようにした。
- 既存の ctx なし直呼びテスト/CLI 用経路は nil-safe のまま維持した。
- 小修正扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-26b`、`markdown/requirement.md` を `0.1.9-Beta-29b` に更新した。

### 検証
- `go test ./server -run 'TestSyncLibraryEventsEmitsUpdatedPlayCountsAfterApplyingEvents|TestSyncLibraryEventsRejectsInvalidMethod|TestSyncLibraryEventsPushStoresChildPlayEventsAndReturnsAcks' -count=1`

## 2026-06-09 — UX Sync 再生回数収束の実装

### 実施内容
- `syncSongMatchKey` を追加し、曲同一性を `artist|album|title|durationSec` の正規化メタデータから SHA-1 hex で判定するようにした。
- `uxsync.PlayEvent` に `matchKey` を追加し、ローカル再生イベント記録時に設定するようにした。
- 受信した再生イベントは `matchKey -> path` を優先し、旧イベントは `trackID -> path` でフォールバックするようにした。
- 一致するローカル曲がないイベントは `sync-play-events` に保持しつつ、`playcounts` には幽霊エントリを作らないようにした。
- `playcounts-base` を導入し、一度きりの移行で既存 count から既存ログ件数を差し引いた base を保存したうえで、`playcounts = base + logCount` として再計算するようにした。
- 新機能扱いとして `src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-26a`、`markdown/requirement.md` を `0.1.9-Beta-29a` に更新した。

### 検証
- `go test ./server -run 'TestSyncSongMatchKey|TestIncrementPlayCountRecordsLocalSyncPlayEvent|TestSyncLibraryEventsAppliesIncomingPlayCountsByMetadataWithoutPulledTrack|TestSyncLibraryEventsSkipsUnmatchedPlayCountsWithoutGhostEntry|TestIncrementPlayCountMigratesExistingCountsToBaseBeforeProjection|TestSyncPlayCountsConvergeAcrossBidirectionalMetadataMatchedEvents|TestSyncLibraryEventsFallsBackToTrackIDForLegacyEventsWithoutMatchKey|TestSyncLibraryEventsAppliesIncomingPlayCountsIdempotently' -count=1`

## 2026-06-09 — UX Sync 再生回数同期ズレの診断と実装計画策定（codex へ委譲）

### 実施内容
- 既存 UX Sync 実装を読み、再生回数同期が概念からズレている根本原因を特定した。
  - #1 曲のクロスマシン同一性が存在しない: 曲 id が `uuid.NewString()` でマシンごとに別。受信側 `applyIncomingSyncPlayEventsToPlayCounts` は trackID→path 索引でしか突合できず、sync で pull した曲のみ一致。両機が同曲を別々に保有すると同期されず、幽霊 playcounts エントリも蓄積する。
  - #2 再生回数の真実の源が二重化: `playcounts`（直接 ++）と `syncPlayEvents` ログが再突合されず恒久ドリフトする。
- バックグラウンド自動同期ループ（`startSyncAutoLoop`、起動10秒後＋60秒毎）は既存で概念どおり動作していることを確認した。
- 実装計画 `markdown/sync-playcount-convergence-plan.md` を作成・コミットし、agmsg で codex に実装を委譲した。

### 選定理由・判断の根拠
- 曲同一性キーは「メタデータキー優先」を採用（ユーザー確認済み）。content hash より実装が軽く副作用が小さい。全曲ハッシュ計算の負荷を避けられる。
- スコープは #1+#2 をまとめて実施（ユーザー確認済み）。#1 だけでは表示用 count の二重ソース問題が残るため。
- 再生回数は `base + logCount` の射影とし、移行で `base = max(0, currentCount - existingLogCount)` とすることで既存値を失わず二重計上も防ぐ。

### 残課題・次のステップ
- codex の実装完了待ち。doc 末尾のテスト8項目を Red から先に進める方針。

## 2026-06-09 — UX Sync Phase 5.5 プロトコルスキーマとバージョンネゴシエーション

### 実施内容
- UX Sync protocol 定数として `ux-music-sync` / `0.2` / `2026-06-09` / capability 一覧を追加した
- `/sync/identity` が `protocolVersion`、`minCompatibleProtocolVersion`、`schemaVersion`、`capabilities`、`negotiation` を返すようにした
- `fetchSyncIdentity` が自分の protocol/schema/capabilities をヘッダで申告し、非互換 major の peer を同期操作前に拒否するようにした
- `/sync/schema` を追加し、endpoint / message / capability / 拡張規則を含む機械可読スキーマを返すようにした
- mDNS TXT に `schemaVersion` と `capabilities` を追加した
- `markdown/ux-music-sync-protocol.md` を追加し、未知フィールド・未知 capability・`extensions` の扱いを含む将来互換方針を明文化した
- Windows ビルドで macOS 向け MTP 実装と Windows stub が衝突しないよう、MTP 実装に build tag を追加し Windows stub を整理した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` をプロトコルスキーマ仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-21b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-18b` に更新

### 検証
- `go test ./server -run 'TestSyncIdentityIncludesSchema|TestFetchSyncIdentitySendsProtocol|TestFetchSyncIdentityRejectsIncompatibleProtocolMajor|TestSyncSchemaEndpoint|TestSyncMDNSAdvertiseInfo' -count=1`
- `go test ./internal/uxsync -count=1`

### 判断
- 多少のバージョン差は unknown field / capability を無視して進め、major 不一致は同期操作前に止める方針を実装した。
- 今後 token と `sourceDeviceId` の対応検証を強める場合は、新しい capability と schema version で段階導入する。

## 2026-06-09 — UX Sync Phase 5.4 音源push転送

### 実施内容
- `/sync/library/import` を追加し、同期トークン認証済みの multipart アップロードを `SyncLibrary` へ取り込めるようにした
- 受信側はアップロードされたメタデータから `syncSourceDeviceId` / `syncSourceTrackId` を保存し、同じ同期元・同じ曲の重複転送を skip するようにした
- `PushSyncLibraryAssets(baseURL, limit)` を追加し、保存済み同期トークンでローカルライブラリの音源をペア済み端末へ転送できるようにした
- UX Sync 専用設定画面の `同期` タブに `1曲転送` / `全曲転送` を追加し、転送結果を転送数・既存数・失敗数と受信側保存先として表示するようにした
- renderer と Wails binding に `PushSyncLibraryAssets` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源push転送の仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-20a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-17a` に更新

### 検証
- `go test ./server -run 'TestSyncLibraryImport|TestPushSyncLibraryAssets' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- Mac mini 側から Windows 側へ能動的に音源を送り込めるため、発見・ペアリング後の同期操作が pull / push の両方向に揃った。

## 2026-06-09 — UX Sync Phase 5.3.1 ペア済み端末復元と同期操作修正

### 実施内容
- `ListSyncDevices()` を追加し、保存済み `syncAuthTokens` と `syncKnownPeers` から同期トークンを返さずペア済み端末一覧を取得できるようにした
- UX Sync 専用設定画面で mDNS discovery 結果とペア済み端末一覧をマージし、画面を閉じた後もペアリング済み状態と同期元候補を復元するようにした
- ペアリング確定後に端末一覧と同期元セレクトを更新し、到達URLを持つペア済み端末では `1曲取得` / `全曲取得` を押せるようにした
- ペア済み peer は `ペアリング済み` と表示し、再ペアリング用の接続ボタンを `接続済み` として無効化するようにした
- renderer と Wails binding に `ListSyncDevices` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` をペア済み端末復元の仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-19b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-16b` に更新

### 検証
- `go test ./server -run 'TestListSyncDevices' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- ペアリング情報が一時的なUI状態だけに閉じていた問題を解消し、たまに接続される端末でも保存済みペア情報から同期操作へ戻れる状態になった。

## 2026-06-08 — UX Sync Phase 5.3 音源pull GUI

### 実施内容
- UX Sync 専用設定画面の `同期` タブを有効化した
- 発見済み / 既知 peer の到達URLを同期元セレクトへ反映するようにした
- `1曲取得` ボタンから `PullSyncLibraryAssets(baseURL, 1)`、`全曲取得` ボタンから `PullSyncLibraryAssets(baseURL, 0)` を呼ぶようにした
- 音源pull結果を `downloaded` / `skipped` / `failed` と保存先パスとして表示するようにした
- `PullSyncLibraryAssets` binding が無い環境、または同期元未選択時は取得ボタンを無効化するようにした
- renderer に `normaliseSyncPullResult`、`syncPullActionState`、`formatSyncPullResultSummary` のテストを追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源pull GUI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-19a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-16a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- SSH CLI で通した親から子への音源pullを、UX Sync 専用設定画面から操作できる第一段階に到達した。
- destructive な検証用初期化は誤操作リスクが高いため、GUI には出さず CLI 専用に残した。

## 2026-06-08 — UX Sync Phase 5.2 音源pullとSSH検証CLI

### 実施内容
- Windows 側を検証専用ノードとして扱うため、GUI / WebView2 を起動しない `--sync-reset-test-data`、`--sync-pull-one`、`--sync-pull` の CLI 入口を追加した
- `/sync/library/snapshot` を追加し、同期トークン認証済み端末へアートワーク blob を除いた曲一覧を返すようにした
- `/sync/assets/{trackId}/file` を追加し、同期トークン認証済み端末へ登録済み曲IDの原本ファイルを返すようにした
- `PullSyncLibraryAssets(baseURL, limit)` を追加し、保存済み `syncAuthTokens` を使って親から曲一覧と音源を取得し、子側 `SyncLibrary` 配下へ保存して `library.json` へ取り込むようにした
- 取り込んだ曲には `syncSourceDeviceId` / `syncSourceTrackId` / `syncImportedAt` を付与し、同じ親・同じ曲の再取り込みを避けるようにした
- `ResetSyncTestData` は `syncDeviceId` / `syncAuthTokens` / `syncKnownPeers` を温存し、検証用ライブラリ・再生回数・解析・同期イベント・アートワーク・キャッシュ・プレイリストを初期化し、`libraryPath` を `SyncLibrary` へ向け直す
- Wails binding と renderer bridge に `PullSyncLibraryAssets(baseURL, limit)` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源pull MVP の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-18a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-15a` に更新

### 検証
- `go test ./server -run 'TestSyncLibrarySnapshot|TestSyncAssetFile|TestPullSyncLibraryAssets|TestResetSyncTestData' -count=1`
- Mac 側 `go test ./...`
- Mac 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Mac 側 `npm run typecheck`
- Mac 側 `wails build -clean -nopackage`
- Mac 側で新ビルドを `open /Users/yuki/GitHub/UX-Music/build/bin/UX-Music` から起動し、`/sync/identity` が `YukinoMac-mini` を返すことを確認
- Mac 側 `/sync/library/snapshot` が Windows 側保存済み同期トークンで `200` を返し、812曲のスナップショットを返すことを確認
- Windows 側 `go test ./server -run TestSyncLibrarySnapshot^|TestSyncAssetFile^|TestPullSyncLibraryAssets^|TestResetSyncTestData -count=1`
- Windows 側 `npm run typecheck`
- Windows 側 `wails build -clean -nopackage`
- Windows 側 `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe --sync-reset-test-data`
- Windows 側 `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe --sync-pull-one http://192.168.0.226:8765`
- Windows 側 `SyncLibrary` に Mac mini 由来の FLAC 2曲が保存され、`library.json` の `syncSourceDeviceId` / `syncSourceTrackId` とファイルサイズを確認

### 判断
- 圧縮アセット生成は未実装だが、親 Mac mini の既存原本を子 Windows の管理ライブラリへ pull する縦串は、ローカルテストと `mainpc` への実通信検証の両方で通った。
- `--sync-pull-one` は既存取り込み済み曲を skip し、次の未取得曲を1曲 download する挙動として動作した。

## 2026-06-08 — UX Sync Phase 5.1 Windows側発見fallback

### 実施内容
- Mac 側から Windows peer は見えるが、Windows 側の mDNS discovery が空になって Mac mini を見つけられない非対称状態を調査
- `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答することを確認し、HTTP 到達性ではなく discovery の問題だと切り分けた
- mDNS 広告に使う表示名から `.local` suffix を除去し、`YukinoMac-mini.local` ではなく `YukinoMac-mini` として広告するようにした
- inbound pairing confirm 成功時に、相手 `deviceId`、表示名、実通信元 IP から既知 peer を `settings.syncKnownPeers` へ保存するようにした
- `DiscoverSyncDevices(timeoutMs)` と `/sync/discover` が mDNS 結果と既知 peer をマージするようにした
- mainpc 側のビルド環境に `gcc` / `pkg-config` / portaudio header と `.pc` を用意し、Windows バイナリを再ビルドできる状態にした
- 既に古いバイナリでペアリング済みだった Windows 設定へ、Mac mini の `syncKnownPeers` を一度だけ補完した

### 検証
- Mac 側 `dns-sd -B _uxmusic-sync._tcp local` で `YukinoMac-mini` が複数 interface に広告されることを確認
- `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答することを確認
- Windows 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Windows 側 `npm run typecheck`
- Windows 側 `go test ./server -run "TestSyncPairingConfirmStoresKnownPeer|TestMergeSyncKnownPeers|TestSyncMDNSAdvertiseInfo|TestNormaliseSyncDisplayName" -count=1`
- Windows 側 `wails build -clean -nopackage`
- Windows 側 `settings.json` に `syncKnownPeers` として `YukinoMac-mini` / `http://192.168.0.226:8765` が保存されたことを確認
- Mac 側 `go test ./...`
- Mac 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Mac 側 `npm run typecheck`

### 判断
- Windows の mDNS browse 自体は SSH 上の Go smoke で空のままだが、ペアリング済み端末は既知 peer fallback で発見一覧へ補完できる構造になった。
- SSH 経由で Windows GUI を起動すると WebView2 が `Invalid window handle` で落ちるため、更新済み `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe` は Windows のデスクトップ側から起動して確認する。

## 2026-06-08 — UX Sync Phase 5 専用設定画面

### 実施内容
- 通常設定モーダルに混在していた UX Sync の探索・ペアリング UI を、UX Sync 専用設定画面へ切り出した
- 通常設定には `UX Sync設定を開く` の入口だけを表示するようにした
- Wails sync binding が無い renderer 単体環境では UX Sync 入口を非表示にする状態判定を追加
- UX Sync 専用設定画面の `端末` タブに探索ボタン、探索状態、peer 一覧、6桁コード確認ペアリング導線を集約した
- 後続の同期状態・保存ポリシー設定を載せるため、`同期` と `保存` のタブ枠を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync 専用設定画面の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-17a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-14a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- UX Sync は通常設定の一項目ではなく、専用画面で端末・同期・保存を管理していく形へ移行した。

## 2026-06-08 — UX Sync Phase 4 ペアリングUI

### 実施内容
- Wails 向けに `StartSyncPairing(baseURL)` と `ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID)` を追加
- `StartSyncPairing` はリモート `/sync/identity` で端末情報を取得し、ローカル `deviceId` を使って `/sync/pairing/start` を呼ぶ
- `ConfirmSyncPairing` はリモート `/sync/pairing/confirm` が返したトークンを、リモート `deviceId` 宛の同期トークンとしてローカル設定へ保存する
- ペアリング開始時の `remoteDeviceId` と確定時に再取得した `deviceId` が異なる場合は、トークンを保存せず失敗させる
- 設定画面の UX Sync peer カードに「接続」ボタンを追加し、6桁コード表示、確定、キャンセル、ペアリング済み表示まで進めるようにした
- `reachableBaseUrl` を優先し、未取得時は `host` / `hosts` と `port` からペアリング用 URL を構成する renderer ロジックを追加
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync ペアリング UI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-16a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-13a` に更新

### 検証
- `go test ./server -run 'TestStartSyncPairing|TestConfirmSyncPairing|TestSyncPairing' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- UI 上で検出済み peer からペアリング開始・確定まで進める状態になった。
- ペア済み端末一覧と解除 UI、双方独立表示型の数値確認は後続フェーズに残す。

## 2026-06-08 — UX Sync Phase 3.1 macOS mDNS fallback

### 実施内容
- 半自動テストで `dns-sd` では `mainPC` が見える一方、Go の `grandcat/zeroconf` discovery が `mainPC` を取りこぼすことを確認
- macOS では `zeroconf` discovery と OS 標準の `dns-sd -B/-L` の結果をマージするようにした
- `dns-sd` 出力を `MDNSPeer` へ正規化し、既存の `ResolveReachablePeers` で `reachableBaseUrl` を選べるようにした
- `markdown/Task.md` と `markdown/requirement.md` を macOS mDNS fallback の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-15b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-12b` に更新

### 検証
- `dns-sd -B _uxmusic-sync._tcp local` で `mainPC` を確認
- `dns-sd -L mainPC _uxmusic-sync._tcp local` で `mainPC.local.:8765` と TXT レコードを確認
- 半自動 Go smoke で `DiscoverMDNS` → `ResolveReachablePeers` が Mac 自身と `mainPC` / `reachableBaseUrl=http://mainPC.local:8765` を返すことを確認
- `go test ./internal/uxsync`
- `go test ./...`

### 判断
- UI 側が `DiscoverSyncDevices(timeoutMs)` を呼べば、今回の fallback を通って Windows 側 `mainPC` を検出できる状態になった。

## 2026-06-08 — UX Sync Phase 3 自動発見UI

### 実施内容
- renderer に `ux-sync-settings` の peer 正規化・接続候補表示ロジックを追加
- 設定画面に UX Sync セクションと「同期端末を探す」ボタンを追加
- Wails の `DiscoverSyncDevices(timeoutMs)` から得た `reachableBaseUrl`、役割、複数 NIC の候補 `hosts` を一覧表示するようにした
- Wails binding が無い renderer 単体開発環境では UX Sync セクションを非表示にし、通常の設定画面を壊さないようにした
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync 自動発見 UI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-15a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-12a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm test -- --run`
- `npm run typecheck`
- `go test ./...`
- `git diff --check`

### 判断
- UI 側の自動発見一覧表示は実装済み。発見 peer から6桁コード確認ペアリングへ進む導線と、ペア済み端末管理 UI は後続フェーズに残す。

## 2026-06-08 — UX Sync Phase 2 mDNS 自動発見基盤

### 実施内容
- `internal/uxsync` に mDNS サービス定義、TXT レコード生成、発見 peer 正規化、複数アドレス保持を追加
- `github.com/grandcat/zeroconf` を導入し、`_uxmusic-sync._tcp.local.` の広告と探索を実装
- LAN HTTP サーバー起動時に UX Sync mDNS 広告を開始し、停止時に shutdown するようにした
- Wails 向けに `DiscoverSyncDevices(timeoutMs)` を追加
- `/sync/identity` に `deviceId` / `displayName` / `roles` を含めるよう更新
- 複数NIC環境で同じ `deviceId` が複数アドレスを返す場合、`hosts` に全候補を保持するようにした
- `hosts` 候補へ `/sync/identity` を順番に probe し、到達可能な `reachableBaseUrl` を自動選択するようにした
- 末端側が IP 手入力や OS の `dns-sd` 操作をしなくても、アプリ側の mDNS 探索と自動 probe で接続候補を得られる方針にした
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を mDNS 実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-14b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-11b` に更新

### 検証
- `go test ./internal/uxsync`
- `go test ./internal/uxsync ./server`
- 検証用サーバーを `0.0.0.0:9876` で起動し、macOS `dns-sd -B _uxmusic-sync._tcp local` で `UX Music mDNS Test` の広告を確認
- Go の `uxsync.DiscoverMDNS` で広告を発見し、`hosts` に `192.168.1.182`、`192.168.0.226`、`192.168.1.48`、Tailscale / IPv6 候補が含まれることを確認
- Go の `ResolveReachablePeers` で `reachableBaseUrl` が自動設定されることを確認
- SSH 接続した `mainpc` から `http://192.168.0.226:9876/sync/identity` が応答することを確認
- `mainpc` には `dns-sd` が無かったため、Windows 側での mDNS browse は未実施

### 判断
- mDNS 自動発見と到達可能URLの自動選択基盤は実装済み。UI 上の一覧表示と、発見 peer からペアリングへ進む導線は後続フェーズに残す。
- 複数NIC環境では代表 `host` が `mainpc` から到達不能なアドレスになる可能性があるため、後続のペアリングUIでは `reachableBaseUrl` を優先して使う。

## 2026-06-08 — UX Sync Phase 1 ペアリングと再生イベントプッシュ基盤

### 実施内容
- `internal/uxsync` を追加し、`PlayEvent` の重複排除、同時再生の別イベント採用、再生回数集計、アウトボックス ACK pruning、6桁ペアリングコード生成を実装
- `/sync/identity`、`/sync/pairing/start`、`/sync/pairing/confirm`、`/sync/library/events` を既存 LAN HTTP サーバーへ追加
- Wear 認証と Sync 認証を `lanAuthMiddleware` で分離し、Sync は `X-UX-Music-Sync-Token` / Bearer / `syncToken` を受け付けるようにした
- `sync-play-events` をイベントログとして保存し、同じ `eventId` の再送で再生回数が二重加算されない構造にした
- `Store.Save` がユーザーデータディレクトリを自動作成するようにし、一時サーバーや初回起動時の保存失敗を防いだ
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-13a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-10a` に更新

### 検証
- `go test ./internal/uxsync`
- `go test ./server -run 'TestSyncPairing|TestSyncAuth|TestLanAuth|TestSyncLibraryEvents' -count=1`
- `go test ./internal/store ./server ./internal/uxsync`
- `go test ./...`
- `mainpc` へ SSH 接続し、`192.168.0.226:9876` の検証用サーバーに対してペアリング開始、6桁コード confirm、認証付き `/sync/library/events` push、同一イベント再送を実行
- 実通信検証では `firstAccepted=1`、`secondAccepted=1`、`ackSequence=1` を確認し、保存された `sync-play-events` は `evt_mainpc_0001` 1件のみであることを確認

### 判断
- `mainpc` から `192.168.1.182` へは到達できなかったが、同じネットワーク上の `192.168.0.226` では到達できた。既存 `GetWearServerAddress()` は最初に見つかった非 loopback IPv4 を返すため、複数NIC環境では表示アドレス選択の改善が後続課題。
- mDNS / Bonjour、自動発見、UI、圧縮アセット、WebSocket 再生移行は後続フェーズに残す。

## 2026-06-08 — UX Music Sync 実装計画を文書化

### 実施内容
- `markdown/ux-music-sync-plan.md` を追加し、同一 LAN 上の UX Music 端末同期の実装計画を整理
- 6桁コード確認つきペアリング、`Library Host` / `Portable Client` の役割、HTTP / WebSocket の使い分け、再生イベント同期、圧縮音源キャッシュ、再生移行を計画に落とし込んだ
- `Portable Client` の再生カウントを親へプッシュするアウトボックス、たまに接続される端末向けの再送・取り込み確認、同時再生時のカウント重複排除方針を追記
- `markdown/roadmap.md`、`markdown/features.md`、`markdown/requirement.md` に UX Sync 計画への参照を追加

### 判断
- 今回は設計ドキュメント作成のみのため、実装コードとテストは追加していない
- 実装着手時はフェーズごとに `markdown/Task.md` へ完了条件を追加し、テスト先行で進める

## 2026-06-08 — TXT専用歌詞同期の音源候補選択と実ライブラリ検証

### 実施内容
- Python fallback に `UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES=full|vocals|both` を追加
- `full` ではDemucsを通さず元音源を直接 faster-whisper へ渡すようにした
- `both` では元音源候補とボーカル候補をそれぞれTXT行へ整列し、参照LRCを使わない品質スコアで候補選択するようにした
- 結果JSONへ `audioSource` / `alignmentQualityScore` / `candidateScores` を追加

### 検証
- `python/.venv/bin/python -m pytest python/tests -m 'not heavy' -q` → `30 passed, 1 deselected`
- `/Users/yuki/doc/uxmusic` 5曲ベンチ（LRC時刻は答え合わせのみ、入力は時刻なしTXT相当、`base` / `full`）:
  - アムネシア: `MAE(after_tol)=0.734s`
  - PROMINENCE: `81.670s`
  - Lone Wolf: `58.186s`
  - main heroine: `93.846s`
  - Twilight: `28.689s`
- PROMINENCE / `vocals` / `base`: `auto=23.731s`, `ja=69.775s`, `auto-ja=28.219s`
- `/opt/homebrew/bin/speech align` は実行可能だったが、アムネシアのボーカル抽出音声+簡易行復元では `MAE(after_tol)=3.395s`

### 判断
- アムネシアはfull音源ASRで0.8秒級に到達した
- PROMINENCE / Synthion系は反復ブロックとASR欠落が大きく、現行の曲全体一括ASR→後段整列では0.8秒級に届かない
- 次の本命は、セクション分割・複数候補DP・歌詞反復ブロックの構造推定

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12c` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9c` に更新

## 2026-06-08 — Python fallback Stage3の未来ドリフト修復と0.8秒級同期検証

### 実施内容
- `stage3_align` に、後半の繰り返しフレーズへ大きく吸われた行を、飛ばされたASRセグメントへ時系列順で戻す未来ドリフト修復を追加
- 繰り返しブロック末尾の延長補正を、未来ドリフト修復と単調化の後にも再適用するよう調整
- `UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS`（既定 `75.0`）と `UX_MUSIC_SYNC_FORWARD_DRIFT_MAX_ROWS`（既定 `32`）を追加
- `speech` CLI / Qwen3 Forced Aligner は導入済みのまま、今回の実装はバックエンドAPI不要のローカルPython fallback側を改善

### 検証
- `cd python && .venv/bin/python -m pytest tests/ -m 'not heavy' -v`
- `IGNORE/` 実測:
  - アムネシア / `base`: 既存ベースライン `MAE(after_tol)=0.952s`、今回の揺れ込み再測では `17.536s`
  - アムネシア / `medium`: 後段補正のみの理論再計算で `MAE(after_tol)=0.737s`、実パイプライン再推論では `2.564s`
  - PROMINENCE / `base`: `123s`級の全体ドリフトから `20.562s` まで改善したが、採用精度には未達
  - Lone_Wolf / `base`: `109s`級の全体ドリフトから `24.243s` まで改善したが、採用精度には未達

### 判断
- アムネシアでは同一ASR結果への後段補正で0.8秒級に届く条件を確認したが、Demucs / faster-whisper の再推論揺れで実パイプラインの確定値は安定しなかった
- PROMINENCE / Lone_Wolf は破綻を大幅に縮めたものの、0.8秒級には届かない
- これ以上は曲全体一括整列ではなく、チャンク化・複数候補保持・VAD/ASRアンカーによるセクション単位アラインメントが必要と判断し、今回の試行はここで切り上げ

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12b` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9b` に更新

## 2026-06-08 — macOSローカル強制アラインメント経路を追加

### 実施内容
- Swift sidecar に `Qwen3 Forced Aligner` / `speech align` 互換 CLI を優先する経路を追加
- `speech align` の単語タイムスタンプ出力を解析し、元のTXT歌詞行へ戻すマッパを実装
- `UX_MUSIC_LYRICS_SYNC_ALIGNER=auto|qwen3|off`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_MODEL` を追加
- `auto` ではローカルalignerが利用可能な場合に優先し、失敗時は既存WhisperKit経路へフォールバック
- Swift純粋ロジックのテストを追加

### 検証
- `swift test --package-path swift/lyrics-sync`
- `go test ./internal/lyricssync`
- `go test ./...`
- `npm run typecheck`（`src/renderer`）
- `npm test`（`src/renderer`）

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12a` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9a` に更新

## 2026-05-28 — レビュー指摘順のセキュリティ・再生修正

### 実施内容
- Wear API に認証トークンを導入し、LAN 上の未認証アクセスを拒否
- `/safe-media/` をライブラリ登録済み曲だけに制限し、`/safe-artwork/` と data URL アートワーク読み込みを安全な解決関数へ統一
- プレイリスト名の traversal を拒否
- ノーマライズ表示のHTMLエスケープを追加
- `profile=fast` で Swift sidecar の軽量モデル選択を尊重
- Wails build で `lyrics-sync-swift` を `.app/Contents/Resources/bin` に同梱
- Wails 再生位置でスキップ統計を記録
- AudioGraph 切替時に EQ 設定を再適用
- `/safe-media/` URL の予約文字を segment ごとにエンコード

### 検証
- `go test ./...`
- `npm test -- --run`
- `npm run typecheck`
- `swift build -c release --package-path swift/lyrics-sync`

---

## 2026-05-27 — リファクタリング G2 / R3 / R5+G6 の判定

### 実施内容
- **G2 完了**: `GetSituationPlaylists` (86 行) を 30 行に短縮
  - `pickRecentlyAdded` / `pickMostPlayed` / `pickRandomPick` を `situation_playlists.go` に切り出し
  - TDD で 8 ケースのテスト (`situation_playlists_test.go`)
  - go test ./... 全パス
- **R3 / R5 / G6 スキップ**: 実コードを精査した結果、Explore エージェントの誤検出だった
  - R3 (querySelector キャッシュ): 対象は呼び出し頻度が低い、または getElementById で O(1)
  - R5 (mtp-browser.ts コメントアウト): 実際にはコメントアウトされたコードブロックなし
  - G6 (wearPairingURLFromParts インライン化): 2 箇所利用＋専用テスト有り。インライン化は逆効果

### 選定理由・判断の根拠
- G2 は本物の責務分離: 3 つの異なるセクション (最近追加・よく聴く・ランダム) を 1 関数に詰め込んでいたため、用途別の純関数化で単体テストが書け、本体側の見通しが圧倒的に改善
- 偽陽性の 3 つは「Don't add features, refactor, or introduce abstractions beyond what the task requires」(CLAUDE.md) の原則に従って積極的にスキップ。「やらないこと」も判断
- スキャン結果は実コードでの再検証必須という教訓

### 残課題・次のステップ
- 今回着手したスキャン候補は全て決着。新規スキャンを行うかは別途判断

---

## 2026-05-27 — fix: ノーマライズ適用が反応しないバグの修正

### 実施内容
- 症状: 解析後、エラー行を外して「ノーマライズを適用」をクリックしてもボタンは押せるが何も起きない
- 原因: 過去コミット e121036 で導入した「id 不一致時に path で照合」フォールバックと、ペイロード narrow 化が、TS 移行 (92d7544) でリグレッション
- 純関数 `findNormalizeFileForResult` / `toJobFilePayload` を `normalize-lookup.ts` に新設 (8 ケースの vitest)
- `normalize-view.ts` の handler と apply 送信箇所を置換

### 選定理由・判断の根拠
- Wails の JSON ブリッジで id 型がゆらぎ `Map.get(id)` が undefined を返すと、handler 冒頭の `if (!file) return` で結果が黙って捨てられていた
- backend (`app_normalize.go`) は既に `path` をイベントに乗せているので、renderer 側で活用するだけで復旧
- 同じ理由で送信時も renderer の余分なフィールド (currentLufs, selected 等) を載せず `{id, path, gain}` に絞り、ブリッジ越しの型強制リスクを下げた

### 残課題・次のステップ
- G2 (GetSituationPlaylists 分割), R3 (querySelector キャッシュ), R5+G6 (デッドコード) に着手

---

## 2026-05-27 — リファクタリング R2: runAutoSync の責務分離

### 実施内容
- スキャン結果のうち R1 (`setupLrcEditorListeners`) はエージェントの計測誤り（実際は 60 行・13 リスナー）と判明し、スキップ
- R2 (`runAutoSync` 117 行) から純関数 2 つを抽出
  - `validateAutoSyncPrereqs`: 4 種の事前検証
  - `applyAlignedTimestamps`: 整列タイムスタンプの正規化＋代入
- 新モジュール `src/renderer/js/features/lrc-auto-sync.ts` に切り出し
- TDD: 11 ケースの vitest を Red → Green → 本体置換、tsc も通過
- 本体は 117 → 103 行 (-14 行) かつ、検証ロジックがテスト可能に

### 選定理由・判断の根拠
- lrc-editor.ts はグローバル変数 28 個と DOM 直操作の塊で全体を一気にテスト化するのは非現実的
- 「DOM/グローバルに触らない純ロジック」だけを切り出してテスト網を張る方針が現実解
- R1 は本来「26 個並列」と報告されていたが実コードを精査して虚偽と判明、 CLAUDE.md「premature abstraction を避ける」方針に従い不要と判断

### 残課題・次のステップ
- 後続候補: G2 (GetSituationPlaylists 96 行の分割), R3 (querySelector キャッシュ), R5 (デッドコード削除)
- lrc-editor.ts には他にも純粋ロジック (payload 構築, result パース) が残るので将来的に同パターンで切り出し可能

---

## 2026-05-27 — リファクタリング G1: store ヘルパー導入

### 実施内容
- 全コードベースをスキャンし、デッドコード/複雑関数/重複/パフォーマンスの観点で候補をリストアップ
- 最重要候補 G1（`store.Instance.Load` の冗長パターン）に着手
- TDD で `store.LoadSlice` / `store.LoadMap` を新設
  - Red: `internal/store/store_test.go` を追加 (6 ケース)
  - Green: `internal/store/store.go` にヘルパー 2 関数を実装
  - Refactor: server/ 14 ファイル, internal/ 2 ファイルの呼び出し側を一括置換 (-126 行)
- `go test ./...` 全パス

### 選定理由・判断の根拠
- 31 箇所で「Load → nil チェック → `interface{}` キャスト」が機械的に繰り返されていた
- スライス型 (library, analysed-queue) とマップ型 (settings, playcounts, loudness) に分かれて型付け可能
- 型付きヘルパーで呼び出し側は 1 行化し、誤って nil をデリファレンスするバグも構造的に防げる
- 代替案: ジェネリクスを使った `Load[T]` も検討したが、JSON Unmarshal 後の型は限定的で、2 関数で十分簡潔と判断

### 残課題・次のステップ
- R1: `lrc-editor.ts` の `setupLrcEditorListeners` (134 行・26 連続 addEventListener) を分割
- R2: `lrc-editor.ts` の `runAutoSync` (118 行・ネスト 4 階層) の責務分離
- 後続候補: G2 (GetSituationPlaylists 分割), G3, R3 (querySelector キャッシュ), R5 (デッドコード削除)
