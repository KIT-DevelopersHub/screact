# PR #24後の手座標・ジェスチャー精度改善レビュー

## 1. このレビューの前提

本レビューは、PR #24「複数人操作（2人・最大2手）のPC側2トラック処理」をmainへ統合した後、その続きとして精度改善を実装するための判断資料である。

確認した基準は次のとおり。

- PR #24 final head: fa6e4cd054712d47fc50888a96924264630839d6
- PR #24 merge commit: 2c867932383652d57c5f8512ac97c340478933f3
- PR #24 merge target: main（PR #21、PR #22統合済み）
- Android: PR #21で最大2手検出、trackId付与、hands[]送信まで実装済み
- Desktop: PR #24でhands[]受信、trackId別状態、2骨格・2カーソル・トラック別描画まで実装

PR #24は2026-08-16にレビュー修正と検証を完了してmainへ統合した。この文書は現行仕様の正本ではなく、PR #24後に行う精度改善のレビュー・実装方針である。

`fix/desktop-screen-boundary`では、本レビューのPhase 1（Desktop画面境界、安全解除、骨格表示、OS主トラック安定化）を実装する。Phase 2以降のジェスチャー状態、Android・通信の未クリップ拡張、AndroidのtrackId安定化は後続PRとし、このブランチの実装済み状態には含めない。

## 2. 結論

PR #24統合時点では、次の2種類のクリッピングが残る。

1. AndroidがMediaPipeの全21点を送信直前にカメラ範囲0.0〜1.0へ丸める。
2. Desktopがホモグラフィ変換後の座標を画面範囲0.0〜1.0へ丸める。

PR #24統合時点のDesktop側では、画面外の人差し指が画面端の操作へ変換される。この処理がtrackIdごとのInteractionEngineで独立して実行されるため、最大2手のそれぞれで画面端への誤描画・誤クリックが起こり得る。

さらにPR #24のMultiHandEngine.mapToScreen()は、骨格表示用の全21点も0.0〜1.0へ丸める。操作だけでなく、画面外の骨格が画面端へ集まって表示される可能性がある。

精度改善は次の順序で行う。

1. Desktopの各trackIdで、未クリップ座標と画面内外判定を分離する。
2. 画面外では操作イベントを開始せず、進行中操作をクリックなしで安全解除する。
3. PR #24のOS主トラックを安定させ、画面外になっただけで別の手へ操作権を移さない。
4. 曖昧なジェスチャーから新規操作を開始しない状態機械へ整理する。
5. Androidから未クリップ骨格を互換的に追加送信する。
6. Androidの新規trackIdを複数フレーム確認してから操作対象にする。
7. 最後に実機ログを基にconfidence、z、trackId対応を調整する。

単純に閾値を厳しくする方法は採用しない。誤発火を減らす代わりに認識漏れや途中解除が増えるためである。まず座標情報を失わないことと、曖昧な入力から副作用を開始しないことで改善する。

---

## 3. PR #24が解決すること・残ること

### 3.1 PR #24で解決済みとして扱うこと

以下は精度改善側で再実装しない。

- hands[]を0〜2手として受信する。
- trackId、点数、有限値、順序、session、frameIdを検証する。
- session単位でホモグラフィを共有する。
- trackIdごとにInteractionEngineを持つ。
- 平滑化、ジェスチャー、押下、描画状態を手ごとに分離する。
- 消えたtrackIdだけを即時解除する。
- WebSocket切断時に全trackIdを解除する。
- 2骨格、2カーソル、トラック別ストロークを別色表示する。
- 旧hand単一形式を互換トラックとして処理する。

精度改善はPR #24のMultiHandEngineとInputFrameを基礎として拡張する。

### 3.2 PR #24後も残る問題

#### 操作座標のクリッピング

各トラックのInteractionEngineは、ホモグラフィ変換直後に座標を0.0〜1.0へ丸める。

~~~dart
final s = _homography?.map(cam) ?? cam;
return Vec2(s.x.clamp(0.0, 1.0), s.y.clamp(0.0, 1.0));
~~~

変換結果が (-0.06, 0.45) でも、後段には (0.0, 0.45) として渡る。元の点が画面外だった情報が失われるため、左端のポインター、描画、クリック、ドラッグとして処理される。

#### 骨格表示のクリッピング

PR #24のMultiHandEngine.mapToScreen()も全21点を丸める。

~~~dart
final s = _calib.homography?.map(camera) ?? camera;
return Vec2(s.x.clamp(0.0, 1.0), s.y.clamp(0.0, 1.0));
~~~

その結果、画面外の関節が端へ並び、骨格線も端へ集まる。これは操作判定とは別の表示上の問題である。

#### OS主トラックの不安定化

PR #24は、イベントを生成したトラックのうち最小trackIdをOS入力へ渡す。

~~~text
byTrackのキー
→ 最小trackId
→ OS入力
~~~

精度改善で画面外トラックのイベントを抑止すると、より小さいtrackIdが存在していてもbyTrackから消え、別の手が自動的にOS主トラックになる可能性がある。画面外へ出ただけで別人へOS操作権が移るのは誤操作につながる。

#### Android送信時の骨格クリッピング

Androidは各点へ次を適用してから送る。

~~~kotlin
it.x.coerceIn(0f, 1f)
it.y.coerceIn(0f, 1f)
~~~

カメラ画像端では複数の関節が同じ端座標へ潰れ、PC側の距離比率が変形する。画面領域がカメラ画像内へ十分収まっていれば影響しないが、カメラ端とPC画面端が近い設置ではジェスチャー誤判定の原因になる。

---

## 4. 改善後の責任分担

### Android

- CameraX画像の回転・cropRectを補正する。
- MediaPipeで最大2手・各21点を検出する。
- trackIdを安定して付与する。
- 操作用として安定したtrackIdだけを送る。
- 有限値、点数、手数を検証する。
- 互換座標と、必要に応じて未クリップ座標を送る。
- ジェスチャーやOS操作は決定しない。

### Desktop

- InputFrameで最大2手を検証する。
- session単位でホモグラフィを共有する。
- trackIdごとに未クリップ画面座標、境界状態、ジェスチャー状態を管理する。
- 平滑化、クリック、ドラッグ、描画、スクロールを決定する。
- 画面外、手喪失、trackId消失、切断で安全解除する。
- OS主トラックを明示的かつ安定して管理する。

Android側でクリックや描画を確定して送る案は採用しない。PR #24で確立した「Androidは骨格とtrackId、Desktopは操作状態」という境界を維持する。

---

## 5. Desktop修正案

### 5.1 InteractionEngineをtrackId共通の正しい境界実装にする

PR #24はtrackIdごとにInteractionEngineを生成する。画面境界ロジックはMultiHandEngineへ重複実装せず、単一手と複数手の両方で使うInteractionEngineへ置く。

各インスタンスに次の状態を持たせる。

- 最後の未クリップsurface座標
- 最後の有効な画面内座標
- 現在画面内か
- 画面外から再入場した後の再開待ち状態
- 押下、描画、スクロールの既存状態
- 画面座標フィルター

処理順を次に変更する。

~~~text
HandFrame
→ 未クリップ骨格でGestureRecognizer
→ 人差し指をホモグラフィ変換
→ rawSurfacePointを保持
→ 人差し指が画面内か判定
→ 画面内の場合だけ画面座標Filterへ入力
→ trackIdごとのInteractionEvent
~~~

### 5.2 未クリップ座標と画面内座標を分離する

ホモグラフィ変換メソッドは範囲外を保持する。

~~~text
rawSurfacePoint = homography.map(cameraPoint)
inside = 0.0 <= x <= 1.0 and 0.0 <= y <= 1.0
~~~

画面境界そのものは有効とする。xまたはyが正確に0.0、1.0の場合も操作可能である。これにより四辺・四隅まで描画できる。

画面外点を先に丸めてからinside判定してはいけない。

### 5.3 操作可否は人差し指先端で決める

ジェスチャー判定には21点を使うが、操作対象が画面内かどうかは人差し指先端の未クリップsurface座標で決める。

- 人差し指が画面内: ジェスチャーに応じて操作できる。
- 人差し指が画面外: 他の関節や描画中点が画面内でも操作しない。
- 人差し指以外が画面外: ジェスチャー判定は継続する。

これにより、手の大部分が画面外でも人差し指が画面内なら画面端へ書ける。一方、人差し指が画面外なら画面端へ誤操作しない。

### 5.4 描画中点が画面外の場合

描画位置は人差し指と中指の中点だが、画面端では中指だけが外へ出て中点も外になることがある。

次の規則とする。

1. 操作可否は人差し指で判定する。
2. 描画中点も画面内なら中点を使う。
3. 人差し指は画面内だが中点が画面外なら、人差し指座標を筆点として使う。
4. 中点を無条件に画面端へクリップしない。

これにより画面端で描画を継続でき、画面外中点を端へ引きずる線も防げる。

### 5.5 画面外へ出た時のイベント

画面外では次の副作用を新規生成しない。

- pointerMove
- drawDown / drawMove
- pressDown / pressMove
- scroll

操作中に外へ出た場合は次のとおり。

| trackIdの現在状態 | 画面外へ出た時 |
|---|---|
| ポインターのみ | OSポインターを動かさず、該当カーソルだけ非表示 |
| 描画中 | 最後の画面内座標でdrawUp。端へ点を追加しない |
| 押下・ドラッグ中 | 最後の画面内座標でpressUp。clickを生成しない |
| スクロール中 | 該当トラックのスクロールアンカーを破棄 |

短時間・小移動のpressUpからclickを生成する既存経路を使わず、画面外専用の「clickなし解除」を用意する。

### 5.6 手喪失のreleaseと画面外を区別する

PR #24のOverlayModelではreleaseがtrackIdの表示状態を削除する。画面外でも骨格検出自体は続くため、手喪失と同じreleaseを使うと骨格まで消える。

画面外遷移用に、例えばpointerExitのような副作用なしイベントを追加する。

- pointerExit: カーソルと押下表示を消すが、骨格は残す。
- drawUp / pressUp: 最後の有効点で個別に送る。
- release: trackId消失または切断時だけ使い、骨格を含むトラック表示を削除する。

pointerExitはOS入力へ送らない。DesktopBridgeのオーバーレイ専用イベントとして扱う。

### 5.7 再入場時の安全な再開

画面外へ出た時に該当trackIdの画面座標Filterとスクロールアンカーをリセットする。画面外座標はFilterへ入力しない。

再入場では次を守る。

- ポインター: 連続した画面内フレームを確認してから表示する。
- 描画: 新しいストロークとして開始し、画面外区間を結ばない。
- クリック・ドラッグ: 一度ピンチを解除してニュートラルへ戻るまで再開しない。
- スクロール: 新しいアンカーから開始し、再入場1フレーム目に差分を出さない。

外へ出た時の抑止は即時とする。画面外に猶予領域を設けて操作を許可しない。

### 5.8 骨格表示は未クリップ座標を使う

PR #24の骨格表示では、全21点をmapToScreen()で端へ丸めている。これを未クリップsurface座標へ変更する。

推奨動作は次のとおり。

- 関節を端へ丸めない。
- 画面外の関節は画面外座標のまま保持する。
- Canvasを画面矩形でclipし、画面内に見える骨・関節部分だけ描画する。
- 画面境界をまたぐ骨は、自然に画面端で切れる。

操作イベントのscreen座標は引き続き0.0〜1.0内だけに限定する。骨格表示座標と操作イベント座標の契約を分ける。

### 5.9 OS主トラックをイベント発生有無から切り離す

PR #24のprimaryTrackIdOf(byTrack)は、イベントを生成したトラックだけから主トラックを選ぶ。画面外抑止を入れた後は操作権が意図せず別トラックへ移る。

主トラックはactiveTrackIdsから安定して選び、イベントの有無では変更しない。

推奨規則:

1. session内で最初に安定したtrackIdをOS主トラックにする。
2. 主トラックが画面外でも所有権は保持し、OS入力だけ停止する。
3. 主トラックが消失したらpressUp/releaseを先に完了する。
4. 別トラックへ移す場合は、そのトラックが画面内かつニュートラルで安定してから移す。
5. 同一フレームで旧主トラックの解除と新主トラックのpressDownを発生させない。

全トラックのオーバーレイ描画は継続する。OSが単一カーソルである現在の制約と、2人同時の画面上描画を混同しない。

### 5.10 曖昧なジェスチャーから開始しない

現在はスクロール、描画、クリックの優先順位で分岐する。複数条件が同時成立した場合、優先順位だけで操作を始めると誤描画や誤クリックになる。

各trackIdで次を行う。

- pinchingとfingersTogetherが同時成立した場合、新規操作を開始しない。
- 描画開始には、人差し指・中指の接近に加えて両指の伸展を要求する。
- スクロール開始には、人差し指・中指の伸展と、描画・ピンチの不成立を要求する。
- 新規開始は複数フレームで確認する。
- 既存操作中の短い曖昧期間は状態を維持する。
- 曖昧状態が上限を超えた場合はclickなしで安全解除する。

「曖昧なら新しい副作用を起こさない」を共通規則とする。

### 5.11 zを使う場合は評価後に限定する

2D上で指が重なるだけでも接触に見えるため、MediaPipeのz差を補助条件に使える可能性がある。ただしzは角度・遮蔽でノイズが大きい。

次を座標ログで比較してから判断する。

- 現在の2D距離比率
- z差が大きい時だけ接触開始を拒否
- 手スケールで正規化した3D距離

zを最初から必須条件にしない。意図したクリック・描画の認識漏れが増えない場合だけ採用する。

---

## 6. Android修正案

### 6.1 未クリップ骨格を加算的に送る

PR #24のInputFrameはhands[].landmarksへ0.0〜1.0を要求する。既存フィールドの意味は変えない。

各手へ任意のunclippedLandmarksを追加する。

~~~json
{
  "trackId": 12,
  "landmarks": [[0.0, 0.42, -0.01]],
  "unclippedLandmarks": [[-0.03, 0.42, -0.01]]
}
~~~

- landmarks: 現行どおりクリップし、旧PC・PR #24との互換を維持。
- unclippedLandmarks: MediaPipeの有限な元座標を保持。
- PR #24後の新PC: 存在すればジェスチャーと画面変換へ使用。
- 旧PCとPR #24未改修版: 未知フィールドを無視。
- legacy hand: 現行どおりclipped landmarksを維持。

InputFrameのHandTrackへ互換座標と未クリップ座標を分けて保持し、toHandFrame()は未クリップ座標を優先する。

未クリップ値にも防御的な許容上限を設ける。値は実機ログから決め、非有限値、点数不正、極端な外挿値が1点でもあればフレーム全体を破棄する。片方の手だけを採用しないというPR #24の原則を維持する。

### 6.2 trackIdごとに候補期間を設ける

AndroidのTrackingStateMachineは現在、1手以上検出できたかという全体状態である。2手環境では、既に1手がTRACKINGなら、新しく現れた2手目が候補確認なしで送られ得る。

操作送信の安定判定はtrackIdごとに持つ。

- 新規trackId: 連続検出が成立するまでUI・診断だけに使う。
- 安定trackId: hands[]へ含める。
- 消失trackId: 古い座標を再送せず、そのフレームからhands[]から外す。
- 300ms以内に同IDで再検出: 再開条件を実機評価し、少なくとも単一ノイズフレームで操作を始めない。
- legacy hand: 安定trackId群のprimaryから生成する。

これにより、一瞬だけ現れた誤検出がPR #24の新しいInteractionEngineを生成し、操作を開始することを防げる。

### 6.3 confidenceは一律に上げない

MediaPipeのdetection、presence、tracking confidenceは現在すべて0.5である。一律に上げると誤検出だけでなく喪失が増え、trackId消失による途中解除が増える。

調整順は次のとおり。

1. 現行値でtrackId別の検出開始、喪失、復帰を記録する。
2. 画面外ガードとtrackId候補期間を先に導入する。
3. 3種類を個別に変更する。
4. 誤操作開始率、初回検出時間、途中解除回数を比較する。
5. デモ端末・設置距離・照明で既定値を決める。

### 6.4 HandTrackAssignerを必要に応じて改善する

現行は手のひら5点中心の距離で対応し、既定最大距離0.25、保持300msである。2手交差や遮蔽ではID交換が起き得る。

改善候補:

- 直前速度から予測した中心との距離を使う。
- handednessを絶対条件にせず、安定時だけ弱いコストへ加える。
- 手のひらサイズ変化をコストへ加える。
- 時間差に応じて許容距離を変える。
- 対応が曖昧なら無理に既存IDへ割り当てず、新IDとして安全解除させる。

Androidで全ランドマークを強く平滑化しない。PR #24後はPCがtrackIdごとにOne-Euro Filterを持つため、Android側はID対応用の中心予測だけに留める。

---

## 7. 推奨するtrackId別状態機械

各InteractionEngineで、ジェスチャー状態と画面境界状態を組み合わせる。

~~~text
Outside
  └─ 画面内が連続成立 → InsideNeutral

InsideNeutral
  ├─ 安定した二本指接触 + 両指伸展 → DrawCandidate
  ├─ 安定した親指ピンチ           → PressCandidate
  ├─ 安定した二本指伸展           → ScrollCandidate
  └─ 画面外                       → Outside

Candidate
  ├─ 条件が連続成立 → Active
  └─ 曖昧／画面外／手喪失 → 副作用なしでNeutralまたはOutside

Active
  ├─ 正常解除 → 終了イベント
  ├─ 画面外 → 最後の有効点でclickなし解除
  ├─ trackId消失／切断 → release
  └─ 短い曖昧期間 → 状態維持、上限超過で安全解除
~~~

開始側を慎重にし、操作中は短い認識ノイズへ耐える非対称設計とする。ただし画面外・trackId消失・切断・session不一致は安全性を優先する。

---

## 8. PR #24後の実装順序

### Gate 0: PR #24統合確認

1. PR #24をmainへ統合する。
2. headまたは統合コミットを記録する。
3. PR #24のDesktop 137テストとflutter analyzeを再実行する。
4. 2手fixtureで2骨格・個別解除・全解除を確認する。
5. 精度改善ブランチを最新mainから作る。

PR #24のブランチと精度改善ブランチで同じengineファイルを並列編集しない。

### Phase 1: Desktop画面境界（デモクリティカル）

1. InteractionEngineへ未クリップsurface座標とinside判定を追加。
2. trackIdごとに画面外副作用を抑止。
3. drawUp、clickなしpressUp、pointerExitを実装。
4. 再入場時のFilter・アンカー・再開待ちを実装。
5. MultiHandEngineの骨格変換からクリップを除去。
6. OS主トラックをイベント発生有無から切り離す。
7. 単一手・2手・互換handの境界テストを追加。

このPhaseは通信仕様とAndroidを変えない。

### Phase 2: Desktopジェスチャー状態

1. 描画開始へ両指伸展条件を追加。
2. 同時成立を曖昧状態として扱う。
3. trackId別の開始確認と解除ヒステリシスを整理。
4. 主トラック切替時のニュートラル再開を追加。
5. 保存済み骨格fixtureで認識成功率と誤発火率を比較。

gesture_recognizer.dartとinteraction_engine.dartは同じ担当が直列で変更する。

### Phase 3: Android・通信の未クリップ拡張

1. android-protocol-v1.mdへunclippedLandmarksを追加。
2. Android送信とInputFrame受信を同じ変更単位で実装。
3. 旧Android、旧PC、PR #24形式との互換テストを追加。
4. 通信量、queueSize、capture-to-send時間を実測。

### Phase 4: AndroidのtrackId安定化

1. trackIdごとの候補期間を追加。
2. 2手交差・一時遮蔽fixtureでID交換を測定。
3. 必要な場合だけHandTrackAssignerを改善。
4. 最後にconfidenceとz補助条件を評価。

---

## 9. 必須テスト

### 9.1 InteractionEngine単体

- 変換結果x<0、x>1、y<0、y>1で副作用イベントが出ない。
- x==0、x==1、y==0、y==1では操作できる。
- 人差し指が画面内なら、他の骨格が画面外でもジェスチャー判定できる。
- 人差し指が画面外なら、描画中点が画面内でも描画しない。
- 人差し指が画面内・描画中点が画面外なら人差し指座標で描画する。
- 描画中に外へ出ると最後の有効点でdrawUpし、端へ点を追加しない。
- 押下中に外へ出るとpressUpは出るがclickは出ない。
- スクロール中に外へ出るとアンカーを破棄する。
- 再入場1フレーム目に座標ジャンプやスクロール差分が出ない。
- pointerExitとreleaseの意味が混同されない。

### 9.2 MultiHandEngine・InputServer

- 片方だけ画面外でも、もう片方のオーバーレイ操作は継続する。
- 画面外トラックだけのカーソル・描画・押下が停止する。
- 画面外になっただけではOS主トラックが別トラックへ移らない。
- 主トラック消失時は解除完了後にだけ次の主トラックへ移る。
- 同一フレームで旧主トラックのpressUpと新主トラックのpressDownが出ない。
- 0手、片手消失、全切断のPR #24既存テストが維持される。
- 互換handでも同じ画面境界規則が適用される。

### 9.3 骨格表示

- 画面外関節が0または1へ集まらない。
- 画面境界をまたぐ骨格線が自然にclipされる。
- 片手が画面外でも、もう片手の色・骨格・カーソルが変わらない。
- pointerExitでカーソルは消えるが、検出中の骨格は残る。

### 9.4 Android・通信

- landmarksは0.0〜1.0を維持する。
- unclippedLandmarksは有限な範囲外座標を保持する。
- raw欠落時はlandmarksへ安全にフォールバックする。
- rawの点数不正・非有限値・極端値でフレーム全体を拒否する。
- 新規trackIdは候補期間中にhands[]へ出ない。
- 安定後に同じtrackIdで送信を開始する。
- legacy handは安定trackId群から生成される。
- 旧PCが追加フィールドを無視して動作する。

### 9.5 実機E2E

- 2本の人差し指を別々の画面端へ置き、各トラックが端まで描画できる。
- 片方の人差し指だけ画面外へ出し、その手だけ操作が止まる。
- 画面外の手から端の線・クリック・スクロールが発生しない。
- もう片方の手の描画・骨格表示は継続する。
- 主トラックが画面外へ出ても、別人へOS操作権が突然移らない。
- 描画しながら外へ出て戻っても、端の直線や復帰位置へのジャンプがない。
- PC画面端とAndroidカメラ画像端を別々に試験する。
- 正面・斜め・デモ照明で同じ確認を行う。

---

## 10. 精度評価指標

カメラ映像は保存せず、trackId付き骨格座標と判定状態だけで比較する。

| 指標 | 完了判断 |
|---|---|
| 画面外で生成された副作用イベント数 | 0 |
| 意図しない操作開始回数 | 現行より減少 |
| 意図した操作の開始成功率 | 現行より悪化しない |
| 操作開始までの時間 | デモ操作で許容可能 |
| 1分あたりの途中解除回数 | 現行より増えない |
| 境界再入場時の最大座標ジャンプ | 目視できる飛びがない |
| OS主トラックの意図しない交代回数 | 0 |
| 2手交差時のtrackId交換回数 | 現行以下 |
| Android queueSize | 上限到達なし |
| capture-to-send時間 | 現行より有意に悪化しない |

評価データにはニュートラル、クリック、描画、ドラッグ、スクロール、境界横断、手喪失、片手だけの画面外、2手交差を含める。

---

## 11. PR #24後の主な変更ファイル

### Desktop

- desktop/lib/core/interaction_engine.dart
- desktop/lib/core/gesture_recognizer.dart
- desktop/lib/core/multi_hand_engine.dart
- desktop/lib/protocol/input_frame.dart
- desktop/lib/protocol/messages.dart
- desktop/lib/net/input_server.dart
- desktop/lib/core/pointer_state.dart
- desktop/lib/platform/desktop_bridge.dart
- desktop/lib/ui/home_page.dart
- desktop/lib/ui/overlay_canvas.dart
- desktop/test/gesture_test.dart
- desktop/test/multi_hand_test.dart
- desktop/test/multi_hand_server_test.dart
- desktop/test/multi_hand_overlay_test.dart
- 新規の画面境界専用純Dartテスト

Phase 1では必要なファイルだけを変更する。特にhome_page.dartは骨格変換の呼び出し変更に限定し、UIデザイン・文言を変更しない。pointer_state.dartとoverlay_canvas.dartもpointerExitと未クリップ骨格表示に必要な最小差分に留める。

### Android

- android/app/src/main/java/com/nxtend/team35/yubiboard/network/YubiBoardWebSocketClient.kt
- android/app/src/main/java/com/nxtend/team35/yubiboard/vision/HandLandmarkerProcessor.kt
- android/app/src/main/java/com/nxtend/team35/yubiboard/vision/HandTrackAssigner.kt
- android/app/src/main/java/com/nxtend/team35/yubiboard/protocol/Messages.kt
- 対応するunit test・契約テスト

### 正本文書

- docs/android/android-protocol-v1.md
- docs/desktop/desktop-app-requirements.md
- 責任境界を変える場合のみdocs/system/system-requirements.md

---

## 12. 競合回避ルール

- PR #24をマージする前に精度改善コードを書かない。
- 精度改善はPR #24統合後の最新mainから分岐する。
- PR #24のtrackId別状態と解除処理を置き換えず、拡張する。
- gesture_recognizer.dart、interaction_engine.dart、multi_hand_engine.dartは同一担当が直列で変更する。
- Androidの未クリップ送信とDesktopのInputFrame対応は同じPRまたは連続した統合順で扱う。
- UI文言PRとはhome_page.dartの骨格配線周辺だけを分離し、デザインを変更しない。
- PRごとにPhaseを分け、画面境界修正へconfidence調整やtrackIdアルゴリズム変更を混ぜない。

推奨PR分割:

1. fix(desktop): trackId別の画面境界・安全解除・主トラック安定化
2. fix(desktop): ジェスチャー開始条件と曖昧状態の改善
3. feat(protocol): 未クリップ骨格の互換的追加
4. fix(android): trackId候補期間と割り当て安定化

---

## 13. 完了条件

1. 画面外の人差し指からポインター、描画、クリック、ドラッグ、スクロールが発生しない。
2. 画面の四辺・四隅では、内側の人差し指で正常に操作できる。
3. 手の大部分が画面外でも、人差し指が画面内ならジェスチャーを判定できる。
4. 画面外へ出た操作は端でクリックせず、最後の有効点で安全解除される。
5. 再入場時に線、ポインター、スクロール量が飛ばない。
6. 片方だけ画面外でも、もう片方の描画と骨格表示が継続する。
7. 画面外を理由にOS主トラックが別人へ自動交代しない。
8. 画面外の骨格が画面端へ集まって表示されない。
9. Androidカメラ端の骨格を、旧クライアント互換を維持して未クリップで渡せる。
10. 曖昧な単一フレームから新規操作が始まらない。
11. 意図したジェスチャーの成功率が現行より悪化しない。
12. PR #24の2手、個別解除、全解除、互換handの回帰テストがすべて成功する。
13. 通信遅延、CPU負荷、バッテリー消費がデモ運用上許容範囲にある。
14. Android・Desktopの契約テスト、純粋ロジックテスト、実機境界テストが成功する。

実装時は通信変更をdocs/android/android-protocol-v1.md、画面外動作と主トラック規則をdocs/desktop/desktop-app-requirements.mdへ先に反映してからコードを変更する。

---

## 14. PR #26 実機デバッグ結果

2026-08-16に`fix/desktop-screen-boundary`のcommit `0f01140`を次の環境で確認した。

- PC: Windows 10.0.26200.9168、Desktop Windows debug build
- Android: Xiaomi 25118PC98G、Android 16（API 36）、1080×2392、debug APK
- 接続: PCとAndroidを同一LANへ接続し、UDP自動発見後にTCP 8765のWebSocketを確立
- 確認者: ユーザーによる実機操作と目視、CodexによるADB・TCP状態確認

### 14.1 実行結果

| 確認項目 | 結果 | 証跡・補足 |
| --- | --- | --- |
| Android debug APK | 成功 | `assembleDebug`成功、実機への上書きインストール成功 |
| Desktop Windows debug build | 成功 | `flutter build windows --debug`成功 |
| 自動発見・初回認証 | 成功 | Androidの「画面認識開始」後、AndroidからPCのTCP 8765へ接続確立 |
| 配置確認・4マーカー位置合わせ | 成功 | PCの「位置合わせ開始」後、Androidが追跡状態へ遷移 |
| 単一手の画面境界 | PR #26の範囲では問題なし | 四辺を横断する操作をユーザーが目視し、画面端判定は良好でブロッカーなしと判断 |
| 手喪失・再入場 | PR #26の範囲では問題なし | 境界横断と手の出し入れを含む目視確認で、継続を妨げる問題なし |
| 2手認識・描画判定 | 後続課題 | 2手の認識成立と描画モードへの遷移が難しく、Phase 2のジェスチャー状態とAndroid側認識を分けて評価する |
| 2手描画の滑らかさ | 後続課題 | 確認環境ではカクつきを体感。Androidの`gfxinfo`だけではPC描画・通信・検出のどこが原因か判別できないため、区間別計測が必要 |
| Windowsネイティブカーソル入力 | 未実装 | 現行mainの既知制約。オーバーレイ確認とOS入力確認を分け、別PRで実装する |
| Android instrumentation test | 未実行 | debug APKは導入成功したが、test APKは端末側の`INSTALL_FAILED_USER_RESTRICTED`で導入できなかった |

Android側の案内はPCで「配置OK」を押す表現だが、現行Desktopの実ボタンは「位置合わせ開始」である。位置合わせ自体は完走したためPR #26のブロッカーとはしないが、接続UI文言の同期課題として別に扱う。

### 14.2 PR #26の判定

PR #26が変更する画面境界、安全解除、骨格非クリップ、OS主トラック安定化のうち、実機で確認可能な画面境界経路にブロッカーは見つからなかった。自動テスト148件と`flutter analyze`の成功も合わせ、Phase 1としてはレビュー・マージ判断へ進められる。

次の課題はPR #26へ混ぜず、責任範囲ごとに分ける。

1. Desktopのジェスチャー開始条件と曖昧状態の改善
2. Androidの2手認識・trackId安定性と、Desktopまでのフレームレート／遅延計測
3. 2手描画時のカクつきの区間別計測とボトルネック修正
4. Windowsネイティブのポインター、クリック、ドラッグ、スクロール入力
5. Androidの「配置OK」とDesktopの「位置合わせ開始」の文言同期

### 14.3 追加検証と負荷軽減の必要性

実機操作後に、Desktopの保存ログ、AndroidのLogcatリングバッファ、`dumpsys cpuinfo`、`dumpsys meminfo`、`dumpsys gfxinfo`、`dumpsys media.camera`を照合した。Desktopの接続ログでは、WebSocket確立、`hand_frame`受信開始、2回の位置合わせ成功を確認し、現在のセッションに切断、不正フレーム破棄、失効フレーム破棄は記録されていない。一方、Androidの連続Logcat保存は0バイトで終了しており、`hand_result`と`hand_frame_sent`の構造化診断も本番モードで無効だったため、2手の検出欠損回数、trackId交換、推論fps、送信置換数、描画状態遷移は確定できなかった。

負荷については、位置合わせ後を含む5分間にAndroidアプリが平均193% CPU、カメラプロバイダーが平均152% CPUを使用した。AndroidアプリのPSSは最大約309MB、RSSは最大約476MB、Native Heapは一時約145MBだった。503秒間に22回のGCを確認し、各回で主に10〜21MBのLarge Objectを解放していた。カメラは1280×720、AEの対象範囲は15〜30fpsで、直近の5秒区間では約30fpsを維持しながらフレーム間隔が最大177msまで開いていた。温度状態は0でスロットリングは発生せず、Android UIのJank率も0.01%だったため、熱制限やCompose UIより、カメラ画像変換、最大2手のMediaPipe推論、Bitmapの生成・回収、結果送信までの処理負荷を優先して調べる必要がある。

実装上、Androidは1280×720のRGBAフレームを毎回Bitmapへ変換して最大2手の非同期推論へ投入し、送信側は最大20fpsで最新結果だけを採用する。1フレームでも片方の手が`hands`から消えると、DesktopはそのtrackIdの描画・押下状態を即時解除して破棄する。300ms以内にAndroidが同じtrackIdを再利用しても、Desktopのジェスチャー状態は再作成されるため、検出欠損が描画の途切れとモード再判定へ直結し得る。また、Desktopのオーバーレイは更新のたびに保持中の全ストロークからPathを再構築するため、短いストロークが増える状況ではPC描画負荷も別途計測が必要である。これらは今回のログから確認した実装経路であり、実機での発生回数と各区間の寄与率は未確定である。

次の性能・精度PRでは、同じ設置、照明、ジェスチャーで単一手と2手を各60秒以上比較し、次を同一時刻軸で記録する。

1. Androidの`frames_submitted`、`hand.results`、`hand.missing`、`handCount`、`trackIds`、推論時間、推論fps
2. Android送信の`hand_replaced`、queue bytes、capture-to-send時間、実送信fps
3. Desktopの受信frameId、受信間隔、単一スロット置換数、trackId消失・復帰、`drawDown`／`drawUp`／scroll遷移
4. AndroidのCPU、Native Heap、GC、温度と、Desktopの描画中CPU、フレーム時間、ストローク数・点数
5. 1280×720、960×540、640×480での2手認識成功率、途中解除回数、滑らかさ、画面境界精度

負荷軽減は2手デモの信頼性確保に必要であり、計測結果を基に次の順で扱う。

1. Androidの解析解像度と認識精度の比較を先に行い、デモで成立する最小解像度を選ぶ。
2. 推論投入周期と最大20fpsの送信周期を整合させ、処理中フレームの重複投入と不要なBitmap生成を減らす。
3. Bitmap・MPImageの所有権と解放を確認し、再利用または変換回数削減が可能な箇所を改善する。
4. 単一フレームの検出欠損で描画状態を破棄する現行経路を計測し、trackId別の短い猶予と安全解除を両立させる。
5. Desktop描画がボトルネックの場合だけ、骨格更新と操作更新の再描画統合、Pathの増分化・キャッシュ、保持履歴の上限を検討する。

PR #26は画面境界Phase 1としてマージ判断を妨げない。ただし、2手描画を安定したデモ経路として扱う前に、上記の再検証とAndroid側の負荷軽減を完了する。Desktop側の負荷軽減は描画中の計測結果に基づいて実施する。
