(() => {
  "use strict";

  // ===== 真值数据源 =====
  // 全部剧名 / 集数 / 评分 / 热度 / 收藏 / 徽标 / 主色 / 赛道榜名 / 筛选项 ID
  // 来自 docs/evidence/ranking-fields/ 2026-10-30 实机匿名采样（CatalogClient 现读），
  // 由 docs/design/prototypes/discover-filters-ranking.html 的 const API 原样导出。
  const API = window.HGRealData;
  if (!API) throw new Error("请先加载 prototype-real-data.js（真值数据模块）");

  const SAMPLE_AT = API.sampledAt;                 // 2026-10-30T02:04:01Z
  const PANEL_RUNS = API.panelRuns;
  const PAGE_SIZE = 12;                            // 真值 feed 每类型 12 条
  const EPISODE_PAGE_SIZE = 60;
  const state = { scenario: "normal" };

  // ===== 筛选项：全部来自上游现读词表（show_name / selector_item_id 原样） =====
  const THEME_DIMS = API.dims;
  const themeOf = (genre) => THEME_DIMS[genre]?.category_dim_theme?.items || [];
  const defaultThemes = themeOf("short_play");

  // 原型 chip 行只展示真值词表前 15 项，完整词表在筛选抽屉里（避免移动端横向太长）
  const THEMES = defaultThemes.slice(0, 15).map(([name, id]) => ({ id, name }));
  const THEMES_ALL = defaultThemes.map(([name, id]) => ({ id, name }));

  const STATUSES = (API.dims.comic_series?.creation_status?.items || [["已完结", "creation_status_0"], ["连载中", "creation_status_1"]])
    .map(([name, id]) => ({ id, name }));

  const CONTENT_TYPES = (API.dims.short_play?.genre?.items || []).map(([name, id]) => ({
    id, name, shortName: name,
  }));

  // 排序只有三档（真值 select_items.sort）
  const SORTS = (API.dims.short_play?.sort?.items || []).map(([name, id]) => ({ id, name }));
  const SORT_DEFAULT = "online_time";

  // ===== 赛道 × 榜单：真值 cell_selector（5 赛道 / 25–27 块，禁止写死条数） =====
  // 本轮只有 3 块榜落了卡面真值（recommend/hot/new）；其余榜名是真值、卡面按榜名语义
  // 映射到最接近的三档样本，并在 notice 里明示，避免画假卡却不说明。
  const boardSampleType = (boardName, boardId) => {
    const metaType = Object.keys(API.rankMeta).find((type) => API.rankMeta[type][0] === boardId);
    if (metaType) return metaType;
    if (/新剧|追更|预约/.test(boardName)) return "new";
    if (/热播|收藏|必看|热搜/.test(boardName)) return "hot";
    return "recommend";
  };
  const RANK_TRACKS = API.rankTracks.map(([name, id, boards]) => ({
    id, name, boardType: id,
    boards: boards.map(([boardName, boardId]) => ({
      id: boardId, name: boardName, type: boardSampleType(boardName, boardId),
      sampled: Boolean(API.rankMeta[boardSampleType(boardName, boardId)]?.[0] === boardId),
    })),
  }));

  // ===== 真值 feed → Drama 对象 =====
  // 真值行格式：[title, episodeCount, _, score, _, _, badge, dominateColor, playCnt]
  function hash(value) {
    return String(value).split("").reduce((total, char) => (total * 31 + char.charCodeAt(0)) >>> 0, 7);
  }

  function posterFor(title, seed, contentType) {
    const palettes = {
      short_play: [["#f05b67", "#6b1935"], ["#3f79f6", "#152752"], ["#d59843", "#56331c"], ["#7d5cf2", "#2e1a56"]],
      comic_series: [["#12b8a6", "#103f47"], ["#f18a34", "#5a2817"], ["#6578ff", "#20265e"], ["#db4c91", "#591d42"]],
      ai_series: [["#6576ff", "#26265c"], ["#0db4a4", "#123c3e"], ["#d16e42", "#542a1e"], ["#955fe8", "#3c1c5a"]],
    };
    const palette = palettes[contentType][seed % 4];
    const safeTitle = title.replace(/[&<>"']/g, "");
    const label = CONTENT_TYPES.find((type) => type.id === contentType)?.shortName || "剧场";
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="480" height="680" viewBox="0 0 480 680"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="${palette[0]}"/><stop offset="1" stop-color="${palette[1]}"/></linearGradient><radialGradient id="h"><stop stop-color="#fff" stop-opacity=".32"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs><rect width="480" height="680" fill="url(#g)"/><circle cx="360" cy="120" r="210" fill="url(#h)"/><path d="M0 530C120 430 200 610 480 430V680H0Z" fill="#000" opacity=".18"/><text x="38" y="74" fill="#fff" opacity=".76" font-family="system-ui,sans-serif" font-size="24">${label}</text><text x="38" y="540" fill="#fff" font-family="system-ui,sans-serif" font-size="42" font-weight="700">${safeTitle.slice(0, 10)}</text><text x="38" y="594" fill="#fff" opacity=".72" font-family="system-ui,sans-serif" font-size="22">红果剧场 · 真值采样</text></svg>`;
    return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
  }

  // 真值 drama：剧名/集数/评分/徽标/主色均为采样值；本采样不含简介/封面，标记为模拟。
  function dramaFromReal(row, genre, index) {
    const [title, episodeCount, , score, , , badge, dominateColor, playCnt] = row;
    const id = `rg_${hash(`${genre}:${title}`).toString(36)}`;
    return {
      id, title, contentType: genre, episodeCount,
      score: score || "", badge: badge || null, dominateColor: dominateColor || "#282828",
      playCnt: Number(playCnt) || 0,
      theme: { id: "", name: "剧情" }, // 真值 feed 行未带题材，抽屉筛选按题材词表提供
      tagNames: [],
      creationStatus: "",
      summary: `${title} · 采样评分 ${score || "—"}。真值采样只含剧名、集数、评分与主色，简介为原型占位。`,
      poster: posterFor(title, index, genre),
      isNew: badge === "新剧",
      favoriteCount: 0, // 真值 feed 无收藏数，不编造
      provenance: "real-sample",
      simulatedFields: ["intro", "poster", "theme"],
    };
  }

  const feedCatalog = Object.entries(API.feed).flatMap(([genre, rows]) =>
    rows.map((row, index) => dramaFromReal(row, genre, index)));

  // 榜单条目（真值 rankBoards）：同一剧名去重映射到 feed drama；未收录者新建 drama。
  const catalog = [...feedCatalog];
  const byTitle = new Map(catalog.map((d) => [d.title, d]));
  const RANK_BOARD_ROWS = {}; // type -> 真值行数组
  for (const [type, rows] of Object.entries(API.rankBoards)) {
    RANK_BOARD_ROWS[type] = rows;
    rows.forEach((row, index) => {
      const [title, episodeCount, , score, , , badge, dominateColor] = row;
      if (!byTitle.has(title)) {
        const genre = type === "new" ? "short_play" : "short_play";
        const drama = dramaFromReal(row, genre, index + 100);
        catalog.push(drama);
        byTitle.set(title, drama);
      }
    });
  }
  const dramasById = new Map(catalog.map((drama) => [drama.id, drama]));

  class DataError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "DataError";
      this.code = code;
    }
  }

  const wait = (milliseconds = 320) => new Promise((resolve) => setTimeout(resolve, milliseconds));

  // ===== 目录 / 发现（真值 feed） =====
  async function browse(options = {}) {
    await wait();
    if (state.scenario === "error") throw new DataError("NETWORK", "网络开小差了，请检查连接后重试");
    const {
      contentType = "short_play", themeId = "", statusId = "", sort = SORT_DEFAULT,
      query = "", cursor = "0", pageSize = PAGE_SIZE,
    } = options;
    if (state.scenario === "empty") return { items: [], nextCursor: null, total: 0, source: SAMPLE_AT, cached: false };
    let items = feedCatalog.filter((drama) => drama.contentType === contentType);
    // 题材筛选：真值 feed 无题材字段，按词表 id 无法确定归属 → 不伪造筛选结果，原样返回并标注
    const keyword = query.trim().toLowerCase();
    if (keyword) items = items.filter((drama) => `${drama.title} ${drama.tagNames.join(" ")}`.toLowerCase().includes(keyword));
    if (sort === "hot_score") items = items.slice().sort((a, b) => b.playCnt - a.playCnt);
    if (sort === "hot_collect") items = items.slice().sort((a, b) => b.score.localeCompare(a.score));
    const start = Math.max(0, Number(cursor) || 0);
    const page = items.slice(start, start + pageSize);
    return {
      items: page,
      nextCursor: start + page.length < items.length ? String(start + page.length) : null,
      total: items.length,
      source: SAMPLE_AT,
      cached: true,
      note: themeId ? "本次真值采样未带题材字段，题材筛选为词表演示" : "",
    };
  }

  // ===== 搜索独立接口 =====
  // 真实有两套：App GET /reading/bookapi/search/tab/v（passback/search_id + offset），
  // 官网 GET /api/search/result（page/hasMore）。原型用 passback 语义，与 browse 的 offset 区分。
  async function search(options = {}) {
    await wait(260);
    if (state.scenario === "error") throw new DataError("SEARCH", "搜索失败，请稍后重试");
    const { query = "", cursor = "0", pageSize = 10 } = options;
    const keyword = query.trim().toLowerCase();
    if (!keyword) return { items: [], nextCursor: null, total: 0, passback: "", searchId: "", source: "search/tab/v" };
    const items = catalog.filter((d) => d.title.toLowerCase().includes(keyword));
    const start = Math.max(0, Number(cursor) || 0);
    const page = items.slice(start, start + pageSize);
    return {
      items: page,
      nextCursor: start + page.length < items.length ? String(start + page.length) : null,
      total: items.length,
      passback: start + page.length < items.length ? `pb_${start + page.length}` : "",
      searchId: `sid_${hash(keyword).toString(36)}`,
      source: "search/tab/v",
    };
  }

  // ===== 详情 / 选集 =====
  async function detail(id, options = {}) {
    await wait(options.delay || 400);
    if (state.scenario === "error") throw new DataError("DETAIL", "详情加载失败，请返回后重试");
    const drama = dramasById.get(String(id));
    if (!drama) throw new DataError("NOT_FOUND", "这部剧暂时找不到了");
    const related = catalog.filter((item) => item.id !== id && item.contentType === drama.contentType).slice(0, 6);
    return {
      ...drama,
      sourceLabel: "真值采样 · 2026-10-30",
      sampledAt: SAMPLE_AT,
      related,
      episodes: makeEpisodes(id, 1),
      nextEpisodeCursor: drama.episodeCount > EPISODE_PAGE_SIZE ? String(EPISODE_PAGE_SIZE + 1) : null,
      tracks: [
        { id: "main", label: "高清线路 1", status: "ready", playable: true, quality: "1080P", format: "mp4", candidates: 2, fromWeb: false },
        { id: "web", label: "网页直链", status: "idle", playable: true, quality: "自动", format: "mp4", candidates: 1, fromWeb: true },
        { id: "backup", label: "备用线路", status: "idle", playable: true, quality: "720P", format: "mp4", candidates: 3, fromWeb: false },
      ],
    };
  }

  const FREE_EPISODES = 6;
  function makeEpisodes(id, start, count = EPISODE_PAGE_SIZE) {
    const drama = dramasById.get(String(id));
    if (!drama) return [];
    const end = Math.min(drama.episodeCount, start + count - 1);
    return Array.from({ length: Math.max(0, end - start + 1) }, (_, index) => {
      const number = start + index;
      const locked = number > FREE_EPISODES;
      return {
        vid: `${id}_${number}`, index: number, number,
        title: `第 ${number} 集`, accessibleCount: FREE_EPISODES, locked,
        get beyondFree() { return this.index > this.accessibleCount; },
        preview: number > drama.episodeCount - 2,
      };
    });
  }

  async function episodes(id, start = 1, count = EPISODE_PAGE_SIZE) {
    await wait(180);
    if (state.scenario === "error") throw new DataError("EPISODES", "选集加载失败，请重试");
    const items = makeEpisodes(id, start, count);
    const next = start + items.length;
    return { items, nextCursor: next <= (dramasById.get(String(id))?.episodeCount || 0) ? String(next) : null };
  }

  // ===== 榜单（真值 rankBoards + 真值 rankMeta） =====
  // 真值行：[title, episodeCount, subtitle, score, heat, collect, badge, dominateColor, playCnt]
  async function rank(type = "recommend", trackId = "comic_series_rank") {
    await wait(320);
    if (state.scenario === "error") throw new DataError("RANK", "榜单加载失败，请稍后重试");
    const track = RANK_TRACKS.find((item) => item.id === trackId) || RANK_TRACKS[0];
    const meta = API.rankMeta[type] || ["", "", []];
    const updatedAt = meta[1] ? new Date(Number(meta[1]) * 1000).toISOString() : null; // 推荐榜为空 → null
    if (state.scenario === "empty" || state.scenario === "live") {
      return {
        items: [], count: 0, type, track, cached: false, sampledAt: SAMPLE_AT, updatedAt,
        notice: state.scenario === "live" ? "本次上游返回空榜，不展示浏览推荐（避免把榜降级成普通列表）" : "当前赛道暂无榜单内容",
      };
    }
    const rows = RANK_BOARD_ROWS[type] || RANK_BOARD_ROWS.recommend;
    const boardDef = track.boards.find((b) => b.type === type);
    const sampleNote = boardDef && !boardDef.sampled
      ? `「${boardDef.name}」本次未落卡面样本，按榜名语义复用 ${type === "recommend" ? "推荐" : type === "hot" ? "热播" : "新剧"}榜真值`
      : "";
    const entries = rows.map((row, index) => {
      const [title, episodeCount, subtitle, score, heat, collect, badge, dominateColor] = row;
      const drama = byTitle.get(title) || catalog[0];
      return {
        ...drama,
        title, episodeCount,
        position: index + 1,          // 位次只能来自数组下标
        heat: heat || "",             // rec_text_item.RecommendText（真值）
        collect: collect || "",       // secondary_info_list[].content（真值）
        score: score || "",           // score（真值）
        badge: badge || null,         // tag_info.text（真值）
        subtitle: subtitle || "",     // sub_title（真值）
        dominateColor: dominateColor || "#282828", // color_dominate（真值）
        trend: null,                  // rec_arrow_type 全 0 → 语义未证实，不画假箭头
      };
    });
    return {
      items: entries,
      count: entries.length,
      type, track, cached: true,
      sampledAt: SAMPLE_AT, updatedAt,
      notice: `${sampleNote ? sampleNote + " · " : "真值采样 · "}${meta[1] ? `更新于 ${new Date(Number(meta[1]) * 1000).toISOString().slice(11, 16)} UTC` : "该榜上游未给更新时刻"}`,
      boardId: meta[0], unrecognizedCards: 0,
    };
  }

  // ===== 「我的」：真结构 + 真字段名（来自 personal_library.dart / WatchRecord） =====
  // 数据为演示值；字段名与存储键严格对齐本地 PreferencesBackend：
  // favorites=[], history=WatchRecord[], 进度键 `<dramaId>:<vid>`
  const account = {
    displayName: "红果观众",
    favorites: feedCatalog.slice(0, 3).map((d) => ({ dramaId: d.id, title: d.title, poster: d.poster })),
    history: [
      { drama: feedCatalog[0].id, vid: `${feedCatalog[0].id}_12`, episode: 12, positionMs: 243000, durationMs: 612000, updated: "2026-10-30T02:05:11Z", quality: "best", local: false, finished: false },
      { drama: feedCatalog[1].id, vid: `${feedCatalog[1].id}_3`, episode: 3, positionMs: 98000, durationMs: 540000, updated: "2026-10-29T13:20:00Z", quality: "best", local: true, finished: false },
    ],
    downloads: [
      { dramaId: feedCatalog[2].id, title: feedCatalog[2].title, vid: `${feedCatalog[2].id}_1`, episode: 1, quality: "1080P", sizeBytes: 186_000_000, progress: 1, status: "done" },
      { dramaId: feedCatalog[3].id, title: feedCatalog[3].title, vid: `${feedCatalog[3].id}_2`, episode: 2, quality: "720P", sizeBytes: 94_000_000, progress: 0.46, status: "running" },
    ],
    reservations: [{ dramaId: feedCatalog[4].id, title: feedCatalog[4].title, updated: "2026-10-30T01:40:00Z" }],
  };

  async function personal() {
    await wait(140);
    return {
      ...account,
      stats: {
        favorites: account.favorites.length,
        history: account.history.length,
        downloads: account.downloads.filter((d) => d.status === "done").length,
        reservations: account.reservations.length,
      },
      keys: ["favorites", "history", "<dramaId>:<vid>"],
      source: "PreferencesBackend.read()（纯本地，无服务端接口）",
    };
  }

  const allDramas = () => catalog.map((d) => ({ ...d }));
  const dramaById = (id) => {
    const d = dramasById.get(String(id));
    return d ? { ...d } : null;
  };

  const statusName = (id) => STATUSES.find((s) => s.id === id)?.name || "已完结";
  const contentTypeName = (id) => CONTENT_TYPES.find((t) => t.id === id)?.name || "真人剧";

  // ===== 二级主从筛选：一级内容类型决定二级词表 =====
  // 真值 dims 按 genre 分域：真人剧 29 题材 / 漫剧 8 题材（另有画风）/ AI剧 8 题材。
  // 只做词表演示：真值 feed 行不含题材字段，不做伪造过滤。
  const dimItems = (genre, key) => (THEME_DIMS[genre]?.[key]?.items || [])
    .map(([name, id]) => ({ id, name }));
  function dimsFor(contentType = "short_play") {
    const genre = THEME_DIMS[contentType] ? contentType : "short_play";
    return {
      themes: dimItems(genre, "category_dim_theme"),
      roles: dimItems(genre, "category_dim_role"),
      epochs: dimItems(genre, "category_dim_epoch"),
      artStyles: dimItems(genre, "category_dim_art_style"),
      statuses: dimItems(genre, "creation_status"),
      genders: dimItems(genre, "gender"),
      onlineTimes: dimItems(genre, "online_time"),
    };
  }
  const themeIdsFor = (contentType) => new Set(dimsFor(contentType).themes.map((item) => item.id));

  function setScenario(scenario) {
    state.scenario = ["normal", "empty", "error", "live"].includes(scenario) ? scenario : "normal";
    return state.scenario;
  }

  window.HGPrototypeData = {
    SAMPLE_AT, PANEL_RUNS, PAGE_SIZE, EPISODE_PAGE_SIZE,
    THEMES, THEMES_ALL, STATUSES, CONTENT_TYPES, SORTS, SORT_DEFAULT, RANK_TRACKS,
    browse, search, detail, episodes, rank, personal, allDramas, dramaById,
    statusName, contentTypeName, dimsFor, themeIdsFor, setScenario, DataError,
    meta: {
      apiShape: "Drama / CatalogPage / DramaDetail / Episode / RankEntry / RankPage / WatchRecord",
      provenance: "剧名/集数/评分/热度/收藏/徽标/主色/赛道榜名/筛选项 ID 均来自 2026-10-30 实机匿名采样；简介、海报、题材归属为原型占位。",
      sampleAt: SAMPLE_AT,
    },
  };
})();
