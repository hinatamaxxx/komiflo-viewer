<p align="center"><img src="docs/assets/icon.png" width="100" alt="KomifloViewerのアイコン"></p>

<h1 align="center">KomifloViewer</h1>
<p align="center">めくる、探す、また読み返す。<br>Komifloを、iPhoneでもっと読みやすく。</p>
<p align="center">iPhone / iPad · iOS 17以降 · 非公式アプリ · MIT</p>

KomifloViewerは、KomifloをiPhone・iPadで読むための非公式アプリです。横にめくる、縦に流す、見開きで読むなど、好みに合わせて読み方を選べます。検索やタグの掛け合わせ、履歴・ブックマーク・フォローもまとめて使えます。

利用にはKomifloのアカウントと、作品の閲覧権限が必要です。ログインは、アプリ内で開く公式サイトの画面からご自身で行います。Komifloの運営元とは関係ありません。

## インストール

App Storeでは配布していません。AltStore ClassicまたはLiveContainerを使います。アプリは無料です。Komifloの利用料金は別途必要です。

IPAを直接ダウンロードする場合は、[リリースページ](https://github.com/hinatamaxxx/komiflo-viewer/releases/latest)から入手できます。配布ソースと同じIPAです。

| AltStore Classicに追加 | LiveContainerに追加 |
| :---: | :---: |
| <a href="https://altdirect.app/?r=altstore&amp;url=https%3A%2F%2Fraw.githubusercontent.com%2Fhinatamaxxx%2Fkomiflo-viewer%2Fmain%2Fdistribution%2Fsource.json"><img src="docs/assets/add-source.svg" width="220" alt="AltStoreに追加"></a> | <a href="https://altdirect.app/?r=livecontainer&amp;url=https%3A%2F%2Fraw.githubusercontent.com%2Fhinatamaxxx%2Fkomiflo-viewer%2Fmain%2Fdistribution%2Fsource.json"><img src="docs/assets/add-source.svg" width="220" alt="LiveContainerに追加"></a> |

ボタンには[AltDirect](https://github.com/StikDebug/altdirect)の配布用バッジを使用しています。それぞれのアプリでソース登録を開きます。

### AltStore Classic

1. [AltStoreの公式案内](https://faq.altstore.io/altstore-classic/how-to-install-altstore)に従って、AltStore Classicを導入します。
2. 上の「AltStoreに追加」からソースを登録します。
3. ソース内のKomifloViewerを選び、インストールします。

### LiveContainer

1. LiveContainerを導入済みのiPhone・iPadで、上の「LiveContainerに追加」からソースを登録します。
2. ソース内のKomifloViewerを追加して起動します。

ボタンで開けない場合は、各アプリのソース追加画面へ次のURLを貼り付けます。GitHubのコード欄右上にあるコピーボタンを使えます。

```text
https://raw.githubusercontent.com/hinatamaxxx/komiflo-viewer/main/distribution/source.json
```

署名や更新の条件は、使用するインストールアプリの案内を確認してください。AltStore PAL向けの配布ではありません。

## アプリ画面

iPhone実機で撮影した画面です。一部の画像は白塗りしています。ホーム、漫画ビュアー、マガジン、さがす、ライブラリ、メニューの順に紹介します。

### ホーム

開いてすぐ、新着・話題の作品や雑誌の案内が並びます。下へ進むと、タグごとの作品の棚や作家のバナーも出てきます。棚の「もっと見る」で一覧へ移れるので、気になる流れからそのまま作品を選べます。上の切り替えを「ピックアップ」にすると、ホームのバナーを雑誌・特集・ストア・作家ごとにまとめて見られます。雑誌の配信カレンダーも、アプリの画面で月ごとに開けます。

| ホーム | ホーム → タグの棚・作家 | ホーム → 新着・話題の作品 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/home.png" width="240" alt="ホーム"> | <img src="docs/screenshots/home-tag-shelves.png" width="240" alt="ホームのタグの棚と作家バナー"> | <img src="docs/screenshots/home-new-trending.png" width="240" alt="新着・話題の作品の一覧"> |

#### ピックアップ・ランキング・作家ページ

スタッフのピックアップや新作ランキング、ロングヒット作品も一覧で開けます。ランキングは順位付きで、逆順にも並べ替えられます。作家名を押すと作家ページが開き、作品と商品を切り替えたり、フォローや共有をしたりできます。バナーから開く特集のページでも、いいねや共有ができ、ランキングの特集には順位が付きます。

| ピックアップ | 新作ランキング | ロングヒット作品 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/home-pickup.png" width="240" alt="スタッフいち推しピックアップ"> | <img src="docs/screenshots/home-ranking.png" width="240" alt="新作ランキング"> | <img src="docs/screenshots/home-long-hit.png" width="240" alt="ロングヒット作品"> |

| 作家ページ |
| :---: |
| <img src="docs/screenshots/artist.png" width="240" alt="作家ページ"> |

### 漫画ビュアー

ナビを隠して、漫画だけを表示できます。画面を押すとナビが出て、戻る・共有・縦読みへの切り替え・設定が上に、作品情報・ブックマーク・インデックス・いいね・自動再生が下に並びます。ナビ表示中は、設定に応じて左上に掲載誌のロゴも表示できます。

| 読んでいるところ | ナビを表示 | 縦読みに切り替え |
| :---: | :---: | :---: |
| <img src="docs/screenshots/reader.png" width="240" alt="漫画ビュアー"> | <img src="docs/screenshots/reader-nav.png" width="240" alt="漫画ビュアーのナビ表示"> | <img src="docs/screenshots/reader-scroll.png" width="240" alt="縦読みのナビ表示"> |

#### インデックス・進捗バー・自動再生

インデックスでは、同じ号のほかの作品と、この作品のページ一覧を見ながら移動できます。ナビを閉じていても、画面下の細い進捗バーで今どこを読んでいるか分かります。自動再生中は進み具合がバーで表示され、ナビから止められます。

| インデックス | ページの進捗バー |
| :---: | :---: |
| <img src="docs/screenshots/reader-index.png" width="240" alt="インデックス"> | <img src="docs/screenshots/reader-progress.png" width="240" alt="ナビなしの進捗バー"> |

| 自動再生中 | 自動再生中にナビを表示 |
| :---: | :---: |
| <img src="docs/screenshots/autoplay.png" width="240" alt="自動再生中"> | <img src="docs/screenshots/autoplay-nav.png" width="240" alt="自動再生をやめるボタン"> |

#### 読み終わり・前の作品

最後のページの先には次の作品の案内があり、そのままスワイプで続けて読めます。作家のフォロー、Xへのポスト、いいねもここでできます。「こちらもおすすめ」はボタンで入れ替えられます。1ページ目からさらに戻ると、前の作品へ移れます。

| 読み終わり → 次の作品 | 1ページ目 → 前の作品 |
| :---: | :---: |
| <img src="docs/screenshots/reader-end.png" width="240" alt="読み終わりと次の作品"> | <img src="docs/screenshots/reader-previous.png" width="240" alt="前の作品へ"> |

#### コミックビューア設定

ビュアーの設定は、ナビ右上の設定ボタンか、メニュー → アプリ設定 → コミックビューア設定から開けます。作品画質は高画質・低画質に加え、画像の読み込み時間で選ぶ自動も選べます。ページ送りの操作、見開きの条件、ナビの出し方、自動再生の速さなども細かく調整できます。

| 作品画質モード | 画面表示・進捗バー | ページ操作・見開き |
| :---: | :---: | :---: |
| <img src="docs/screenshots/viewer-settings-quality.png" width="240" alt="作品画質モードの選択"> | <img src="docs/screenshots/viewer-settings-display.png" width="240" alt="画面表示とページ進捗バーの設定"> | <img src="docs/screenshots/viewer-settings-paging.png" width="240" alt="ページ操作と見開きの設定"> |

| 見開き・メニュー操作 | メニュー操作・コメント投稿 | 自動再生 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/viewer-settings-spread.png" width="240" alt="見開きとメニュー操作の設定"> | <img src="docs/screenshots/viewer-settings-menu.png" width="240" alt="メニュー操作とコメント投稿ボタンの設定"> | <img src="docs/screenshots/viewer-settings-autoplay.png" width="240" alt="自動再生の設定"> |

| 自動再生の速さ・その他 |
| :---: |
| <img src="docs/screenshots/viewer-settings-other.png" width="240" alt="自動再生の速さとその他の設定"> |

### マガジン

雑誌をロゴ・表紙・新作の3通りで見比べられます。ロゴから雑誌を選ぶと、号ごとに並んだバックナンバーへ進めます。新しい号には「NEW」が付くので、更新された雑誌がすぐ分かります。バックナンバーは号数と配信日をそろえて並べます。

| マガジン → ロゴ | マガジン → 表紙 | マガジン → 新作 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/magazine-logos.png" width="240" alt="マガジンラックのロゴ一覧"> | <img src="docs/screenshots/magazine-covers.png" width="240" alt="マガジンラックの表紙一覧"> | <img src="docs/screenshots/magazine-latest.png" width="240" alt="マガジンラックの新作"> |

#### 雑誌のバックナンバー

| マガジン → 雑誌 → バックナンバー |
| :---: |
| <img src="docs/screenshots/magazine-back-issues.png" width="240" alt="雑誌のバックナンバー"> |

### さがす

検索欄は、タグ・作家・作品名をまとめて探せます。作家は五十音で、タグは人気順・関連・名前順で一覧できます。

| さがす → 検索結果 | さがす → 作家 | さがす → タグ（人気順） |
| :---: | :---: | :---: |
| <img src="docs/screenshots/search-results.png" width="240" alt="検索結果"> | <img src="docs/screenshots/search-artists.png" width="240" alt="作家の五十音一覧"> | <img src="docs/screenshots/search-tags.png" width="240" alt="タグの人気順一覧"> |

#### タグを掛け合わせる

タグのページで「タグを掛け合わせる」を押すと、別のタグを足して絞り込めます。選んでいる間は一覧が変わらず、「決定」で結果に切り替わります。結果の画面でも、足したタグを1つずつ外せます。

| タグのページ | タグを選ぶ | タグを足す | 掛け合わせた結果 |
| :---: | :---: | :---: | :---: |
| <img src="docs/screenshots/tag-page.png" width="180" alt="タグのページ"> | <img src="docs/screenshots/tag-picker.png" width="180" alt="タグを掛け合わせる画面"> | <img src="docs/screenshots/tag-picker-selected.png" width="180" alt="タグを2つ足した状態"> | <img src="docs/screenshots/tag-results.png" width="180" alt="タグを掛け合わせた結果"> |

### ライブラリ

自分の記録を1か所にまとめています。上部で閲覧履歴・ブックマーク・いいね・フォローを切り替えます。閲覧履歴は新しい順・古い順、ブックマークは既読・未読で絞り込めるので、「途中だった作品」や「まだ読んでいない作品」へすぐ戻れます。

| ライブラリ → 閲覧履歴 | ライブラリ → ブックマーク | ライブラリ → フォロー |
| :---: | :---: | :---: |
| <img src="docs/screenshots/history.png" width="240" alt="閲覧履歴"> | <img src="docs/screenshots/bookmarks.png" width="240" alt="ブックマーク"> | <img src="docs/screenshots/follows.png" width="240" alt="フォロー中のタグと作家"> |

### メニュー

お知らせ・作家ギャラリー・アプリ設定などを開けます。ストア・ミッション・アカウント設定は、アプリ内のブラウザで公式サイトの画面を開きます。

お知らせでは、フォロー中の作家・タグの新着作品が日付ごとに並びます。どのフォローで届いたかも表示され、作家・タグ別に絞り込めます。

| メニュー | メニュー → お知らせ | メニュー → 作家ギャラリー |
| :---: | :---: | :---: |
| <img src="docs/screenshots/menu.png" width="240" alt="メニュー"> | <img src="docs/screenshots/notifications.png" width="240" alt="お知らせ"> | <img src="docs/screenshots/artist-gallery.png" width="240" alt="作家ギャラリー"> |

#### お知らせの絞り込み

| お知らせ → 作家 | お知らせ → タグ |
| :---: | :---: |
| <img src="docs/screenshots/notifications-artists.png" width="240" alt="お知らせを作家で絞り込み"> | <img src="docs/screenshots/notifications-tags.png" width="240" alt="お知らせをタグで絞り込み"> |

#### アプリ設定

表紙の棚の並ぶ向き、雑誌ロゴの背景の透明度、検索バーの位置、タブバーの見た目、キーボードの出し方などを変えられます。キャッシュとして保存するのは表紙・バナーの画像だけで、漫画のページは保存しません。iPhoneで使えない項目（iPadのタブ位置）はグレーで表示されます。

| 表紙の棚・検索バー | タブバー・ビューア・キーボード | コメント投稿・画像のキャッシュ |
| :---: | :---: | :---: |
| <img src="docs/screenshots/settings-shelves.png" width="240" alt="アプリ設定：表紙の棚と検索バー"> | <img src="docs/screenshots/settings-tab-bar.png" width="240" alt="アプリ設定：タブバー・ビューア・キーボード"> | <img src="docs/screenshots/settings-cache.png" width="240" alt="アプリ設定：コメント投稿と画像のキャッシュ"> |

| キャッシュ・初期設定・ライセンス | タブバーのガラスをオフにした場合 |
| :---: | :---: |
| <img src="docs/screenshots/settings-license.png" width="240" alt="アプリ設定：初期設定に戻すとライセンス"> | <img src="docs/screenshots/settings-glass-off.png" width="240" alt="タブバーのガラスをオフにしたアプリ設定"> |

### 作品情報・コメント

作品情報では、作家・掲載誌・ページ数・いいね数・タグを確認でき、「読む」からすぐ開けます。作家名やタグを押せば、それぞれのページへ移れます。コメントは一覧で読め、投稿ボタンから書き込めます。投稿は公式サイトの画面をアプリ内で開いて行います。

コメントは、作品情報の「コメントを開く」からだけでなく、作品一覧の表紙（サムネイル）の下にあるピンクの吹き出しアイコンからも開けます。

| 作品情報 | コメント | コメントを投稿 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/details.png" width="240" alt="作品情報"> | <img src="docs/screenshots/comments.png" width="240" alt="コメント一覧"> | <img src="docs/screenshots/comment-post.png" width="240" alt="コメント投稿画面"> |

## データの扱い

漫画のページ画像を端末に保存・書き出しする機能や、オフラインで読む機能はありません。ページ画像は閲覧中のメモリだけで扱い、ビューアを閉じると破棄します。別のアプリへ一時的に切り替えた場合は、開いているビューアの画像をメモリに保持します。

ログイン状態、設定、閲覧履歴などの情報と、表紙・バナーのキャッシュは端末に保持します。閲覧権限・期限・利用者識別の透かしを維持し、いいね・フォロー・ブックマークはKomifloのアカウントに反映します。

## 対応環境・問い合わせ

iOS 17以降のiPhone・iPadに対応しています。iPadの実機での表示・操作は未確認です。公式サイトの変更により動かなくなる場合があります。不具合は、このリポジトリの[Issues](https://github.com/hinatamaxxx/komiflo-viewer/issues)へお知らせください。

## ライセンス

アプリ本体は[MITライセンス](LICENSE)です。移植元の第三者のコードには、その利用条件が適用されます。アプリのメニューにある「ライセンス」から全文を確認できます。Komifloの作品・ロゴ・商標は、このアプリのMITライセンスには含まれません。

開発補助にOpenAI Codex、今回の紹介文にClaude Opus 5.5（中）を使用しています。公開文はyomiyasuで校正しています。
