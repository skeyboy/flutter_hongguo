import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../../catalog/library_cache.dart';
import '../../search/search_suggestions.dart';
import '../../widgets/sort_menu.dart';
import '../library_page.dart';

/// The two catalog pages, as a top-level constant so the state's fields can be
/// held in [LibraryPageStateBase] while `_LibraryPageState` still keeps its own
/// `static const panes = kDiscoverPanes;` for the methods that have not moved.
/// A `static` is not inherited, and a private name is not visible across two
/// libraries, which is why the value has to live here rather than in the class.
const kDiscoverPanes = [0, 1];

/// 类型 in the order both pages' tabs router pages through it, as a top-level
/// constant for the same reason as [kDiscoverPanes]: the private
/// `static const _genreOrder` inside `_LibraryPageState` can only be read by
/// that library, so a field moved out of it could not name the slot list.
const kGenreOrder = ['short_play', 'comic_series', 'ai_series'];

/// Everything the library page's state owns, held one level above
/// `_LibraryPageState` so the behaviour can leave in stages
/// (`mixin X on LibraryPageStateBase`) without the fields moving again.
///
/// `abstract` because `State.build` is abstract and is not moved here: the
/// concrete class stays `_LibraryPageState` in `features/library_page.dart`,
/// which now reads `class _LibraryPageState extends LibraryPageStateBase`.
abstract class LibraryPageStateBase extends State<LibraryPage> {
  /// The first level of each page, in the order that page's own tabs router
  /// pages through it.
  /// 一级 is the same dimension on both pages -- 类型 -- and the value is shared,
  /// so the three pages each pane pages through sideways are the same three
  /// pages. A slot is a route, so the list is fixed for the life of the router.
  late final slotSets = <int, List<String>>{
    for (final pane in kDiscoverPanes) pane: kGenreOrder,
  };

  /// One list per feed record: a swipe lays several of them out at once (the
  /// page next to this one, the theme next to this theme) and a
  /// `ScrollController` attaches to exactly one live scrollable. Keyed by the
  /// record's own key so that a feed evicted from [feeds] loses its controller
  /// with it -- the cap on retained lists is the cap on retained controllers.
  final feedScroll = <String, ScrollController>{};

  /// One second-level pager per first-level page of each pane: a swipe lays two
  /// first-level pages out at once, and a `PageController` attaches to exactly
  /// one live `PageView`.
  final levelScroll = <int, Map<String, PageController>>{
    for (final pane in kDiscoverPanes) pane: {},
  };

  final paneSearch = <int, TextEditingController>{
    for (final p in kDiscoverPanes) p: TextEditingController(),
  };
  final paneFocus = <int, FocusNode>{
    for (final p in kDiscoverPanes) p: FocusNode(),
  };
  final paneField = <int, GlobalKey>{
    for (final p in kDiscoverPanes) p: GlobalKey(),
  };
  final paneTapGroup = <int, Object>{
    for (final p in kDiscoverPanes) p: Object(),
  };
  final paneQuery = <int, String>{for (final p in kDiscoverPanes) p: ''};

  final suggester = SearchSuggester();
  OverlayEntry? suggestionsEntry;
  List<String> historyRows = const [];
  List<Suggestion> suggestionRows = const [];
  int? suggestionsPane;
  bool suggestionsLoading = false;
  int suggestionsRevision = 0;
  String? suggestionsGenre;
  Rect? suggestionAnchor;

  /// L2′ 的抽屉：和搜索联想同一个做法（一条 `OverlayEntry`，锚在触发它的那枚 chip
  /// 下面），所以换目的地、`Esc`、再开一次都走同一个 `_closeFilterPanel`。
  OverlayEntry? filterPanelEntry;

  /// 触控族的同一层是一条路由（底部弹层），不是浮层，所以页面握着的不是 entry
  /// 而是它的 `setState`：抽屉里的每一次选中都改了页面，而页面重画不会重画路由。
  /// 值为 null 就是「没开着」——判开合的地方两族一起问。
  StateSetter? filterSheetSetState;

  /// 桌面的 L3。页面握着它的句柄只为 `O` 一枚键：开合由控件自己管。
  final GlobalKey<SortMenuState> sortMenuKey = GlobalKey<SortMenuState>();

  /// 桌面的 L2′ chip：抽屉锚在它下沿，所以页面要能问出它的位置。
  final GlobalKey filterChipKey = GlobalKey();

  /// 页面自己握着这枚 chip 的焦点节点，只为 `Esc` 那一条规格：关掉抽屉要把焦点还给
  /// 触发它的那枚控件，而不是还给页面顶部。
  final FocusNode filterChipFocus = FocusNode(
    debugLabel: 'discover-filter-chip',
  );

  /// 排序那一枚同理——两枚都是「层借走的焦点，关的时候归还」。
  final FocusNode sortChipFocus = FocusNode(debugLabel: 'discover-sort-chip');

  /// 桌面卡面的 hover 预览。开合的计时在页面而不在 `HoverPeek`：鼠标从卡移进预览
  /// 卡本体要把那 300ms 的收起取消掉，而「进了预览」这件事只有页面握着的那张浮卡
  /// 知道。同一时刻最多一张，所以换卡先看新的、旧的立刻撤。
  OverlayEntry? peekEntry;
  Timer? peekHide;

  /// 一级，跨两页共享：在分类挑了「漫剧」再甩回发现，发现仍然在漫剧上。
  String genre = 'short_play';

  /// 「看哪一路流」现在是 L3 那一枚的事（`catalogSortKeys` 的三档），不再是发现
  /// 自己的一对 频道 chip。旧的 推荐/最新 两枚已经退场：「推荐」不对应任何一个上游
  /// sort，而触控族这一轮把排序也收到了行尾。所以这里不再存 `view`；取数读 [paneSort]
  /// 与设置里的全局 sort。见 `widgets/sort_menu.dart` 的 `SortSheet`。

  /// 二级，跨两页共享：题材是类型的孩子，两页都按同一个含义用它收窄列表。
  String? theme;

  /// L2′ 的其余维度（设定/背景/受众/时间，漫剧再加画风/状态）：和 题材 同层，
  /// 所以它也是跨两页共享的一份值，换类型一起归零——不设第二套重置规则。它只改
  /// 请求，不换页：见 `_reQuery`。
  final dims = <String, List<String>>{};

  /// 排序，一页一份（规格：排序属于该 pane 的状态）。`null` 是「跟着设置里那一档」；
  /// 桌面把这一维做成右上角下拉，触控族本轮仍用上面的 推荐/最新 两枚 chip。
  final paneSort = <int, String?>{};

  /// 排序挂出去之前的档位。排序失败时档位要回滚到这里，不能让用户以为排到了。
  final paneSortRollback = <int, String?>{};
  StreamSubscription<AppSettings>? sortEvents;
  late String lastSort;
  late CatalogRepository lastCatalog;

  bool settingsChanged = false;

  /// One debounce per list: a choice pending on the page that is not on screen
  /// -- or on the theme next to it inside this one -- must not be cancelled by
  /// whatever the visible list does with its own.
  final feedFilterTimer = <String, Timer?>{};
  late final LibraryCache feedCache;

  /// Which page is on screen. It mirrors the nested tab router, so a swipe and
  /// a tap on the navigation bar end up in the same place.
  int destination = 0;

  /// 我的 is a destination, not a page in the swipe: flinging past 分类 into
  /// your personal library by accident costs more than it gives.
  bool mineOpen = false;

  /// 榜单 is a destination too, for the same reason: it is a different kind of
  /// answer (a ranked list of one 赛道 × 榜, not a feed of 类型 × 题材), so it is
  /// not a mode one of the two catalog pages can be put into. It is layered over
  /// the swipe like 我的, because the pages under it keep their rows and scroll
  /// positions -- and because its own state belongs to a controller that outlives
  /// a round trip back to 发现.
  bool rankOpen = false;

  /// A `看它所在的榜 ›` still owed to the viewer: the 赛道 it named. The tree of
  /// boards only arrives with the first answer, so the wish has to outlive the
  /// request that discovers it.
  String? rankDrillTrack;

  /// The one gesture the phone has and the desktop does not: shown until the
  /// viewer has actually moved between the two pages.
  bool swipeHintSeen = false;

  /// Whether the collapsible part of a page's top -- the search field, the
  /// offline-check button and the swipe hint -- is currently folded away. Both
  /// filter rows stay under it, so a scroll never takes a way out of the current
  /// mode or type with it. One per page, because each page answers for its own
  /// list: a pane scrolled deep stays folded when the viewer swipes back to it,
  /// instead of pushing the band over the rows they were reading.
  final bandCollapsed = <int, bool>{for (final p in kDiscoverPanes) p: false};

  /// How far past the end of the page itself the finger has travelled, in the
  /// direction it is going. One level spends this once: the switch resets it, so
  /// a long pull cannot run the viewer through both pages at once.
  double edgePull = 0;

  /// The same, held per page, for what the chip rows of that band hand over: a
  /// row that has run out of width is asked in the narrowest question first, so
  /// the pull is spent on that page's own first level before the shell hears of
  /// it at all.
  final bandEdgePull = <int, double>{};

  /// One controller per sideways row of a band, and the same one handed to that
  /// row's `Scrollbar`. A `Scrollbar` with no controller falls back to the
  /// `PrimaryScrollController`, which no horizontal row ever attaches to, so the
  /// framework asserts the moment anything moves one of these rows from outside a
  /// drag -- and moving one from outside is exactly what revealing the chip the
  /// level now names has to do.
  final rowScroll = <String, ScrollController>{};

  /// One handle per sideways row's own content, so the row can be asked where
  /// its chips ended up after the frame that laid them out.
  final rowContent = <String, GlobalKey>{};

  /// What each pinned row last stood for -- the content it holds and, of that
  /// content, the chip its level names -- and whether showing it is still owed.
  /// A chip can be the answer without ever having been dragged into view: a
  /// swipe that turned the type, a search that narrowed the row to one chip, a
  /// row parked
  /// at the far end of the type that was just left.
  ///
  /// Recorded per row rather than per content, because a strip that comes back
  /// to a type it showed a minute ago is a different question from the same
  /// frame of that strip: in between, the row was parked by the chips of another
  /// type. And an ask stays owed while the row cannot be measured -- a strip
  /// still waiting for its 题材 is a spinner with no chip to aim at -- so the
  /// frame that fills it is asked again.
  final bandShown = <String, String>{};
  final bandOwed = <String>{};

  /// The same pull again, counted per page for the lists inside it rather than
  /// for the chip rows of its band: the second level runs out first, and only a
  /// drag that survives that question is asked of the first level.
  final levelEdgePull = <int, double>{};

  /// How wide the shell laid itself out as, read by the routed pages: one
  /// measure decides phone or desktop for the whole screen, navigation and
  /// content together.
  bool compact = true;

  /// Captured from the tabs builder, which is the only place that has it.
  TabsRouter? tabs;

  /// The same, once per page, for that page's own first level: a chip tap and a
  /// swipe inside one page both go through the router of that page, and it is
  /// only reachable from inside its own builder.
  final innerTabs = <int, TabsRouter>{};

  /// A rebuild of `LibraryPage` stops at the nested `Router`, which only
  /// re-renders its routed subtree when its own delegate notifies -- so every
  /// `setState` bumps this as well, and the routed shell and panes watch it.
  final viewRev = ValueNotifier<int>(0);
}
