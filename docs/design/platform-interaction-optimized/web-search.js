(() => {
  "use strict";

  // 官网搜索分页原型的数据层。
  // 接口真值来自 packages/api/lib/src/web_source.dart:
  //   searchResultPath = '/api/search/result'（免签 GET）
  //   catalog.dart:880-888 -> aid=8662&query={关键词}&page={n}（page 从 1 起）
  //   searchListFromJson  -> series_id / series_title / series_cover / series_intro / episode_cnt / tag_info.text
  //   searchHasMore       -> hasMore 优先；缺省用 totalPages > pageNum；越界页仍 200 但 searchList 为空
  // 仓库内没有该接口的原始留样，因此结果剧名复用 2026-10-30 实机匿名采样
  // （feed + 榜单卡），封面/简介仍是原型占位，series_id 为稳定派生 ID。

  const PAGE_SIZE = 4; // 上游决定每页条数；原型固定 4 条便于演示翻页
  const AID = 8662;
  const scenario = { value: "normal" };
  const Data = window.HGPrototypeData;
  if (!Data) throw new Error("请先加载 prototype-data.js");

  const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));

  function setScenario(next) {
    scenario.value = ["normal", "empty", "error"].includes(next) ? next : "normal";
    return scenario.value;
  }

  function stableSeriesId(title) {
    // 采样脱敏后不含 series_id；用稳定 hash 派生 16 位数字串，仅用于演示字段形态。
    let hash = 7;
    for (const char of String(title)) hash = (hash * 31 + char.charCodeAt(0)) >>> 0;
    return String(9000000000000000 + (hash % 1000000000000000));
  }

  function urlFor(query, page) {
    const params = new URLSearchParams({ aid: String(AID), query: query || "", page: String(page || 1) });
    return `https://www.hongguo.example/api/search/result?${params.toString()}`;
  }

  // 与 searchListFromJson 的字段取舍一致；保留 score 作为真值采样附带的额外字段。
  function normalizeItem(source) {
    const video = source.video_data || source;
    const seriesId = String(
      video.series_id || video.seriesId || video.item_key || video.key || stableSeriesId(video.title),
    );
    return {
      series_id: seriesId,
      series_title: String(video.series_title || video.series_name || video.name || video.title || "未命名"),
      series_cover: String(video.series_cover || video.cover || ""),
      series_intro: String(video.series_intro || video.description || ""),
      episode_cnt: Number(video.episode_cnt || video.episode_count || 0),
      episode_right_text: video.episode_right_text || "",
      tag_info: { text: String(video.tag_info?.text || video.tags || "") },
      category_list: video.category_list || "",
      score: video.score || "",
    };
  }

  // 与 searchHasMore 一致：hasMore 支持 true/1/'true'；缺省回退 totalPages > pageNum。
  function resolveHasMore(response) {
    if (response.hasMore !== undefined && response.hasMore !== null) {
      if (response.hasMore === true || response.hasMore === 1 || response.hasMore === "true") return true;
      return false;
    }
    return Number(response.totalPages || 0) > Number(response.pageNum || 0);
  }

  async function request({ query = "", page = 1 } = {}) {
    await new Promise((resolve) => setTimeout(resolve, 240));
    const pageNum = Math.max(1, Number(page) || 1);
    const keyword = query.trim();

    if (scenario.value === "error") {
      return {
        code: "-1",
        message: "服务暂时不可用，请稍后重试",
        searchList: [],
        hasMore: false,
        pageNum,
        totalPages: 0,
        totalCount: 0,
      };
    }
    if (scenario.value === "empty" || !keyword) {
      return {
        code: 0,
        message: "ok",
        searchList: [],
        hasMore: false,
        pageNum,
        totalPages: 0,
        totalCount: 0,
      };
    }

    // 剧名来自真值采样（feed + 榜单卡）；series_id / cover / intro 为形态占位。
    const matches = Data.allDramas().filter((drama) => drama.title.toLowerCase().includes(keyword.toLowerCase()));
    const totalCount = matches.length;
    const totalPages = Math.ceil(totalCount / PAGE_SIZE);
    const start = (pageNum - 1) * PAGE_SIZE;
    // 越界页仍返回 200 + 空列表，不画假结果。
    const pageItems = pageNum > totalPages ? [] : matches.slice(start, start + PAGE_SIZE);
    const hasMore = pageNum < totalPages;
    return {
      code: 0,
      message: "ok",
      searchList: pageItems.map((drama) => ({
        series_id: stableSeriesId(drama.title),
        series_name: drama.title,
        series_cover: drama.poster,
        series_intro: drama.summary,
        episode_cnt: drama.episodeCount,
        episode_right_text: `全${drama.episodeCount}集`,
        tags: drama.badge || "",
        category_list: Data.contentTypeName(drama.contentType),
        score: drama.score || "",
        video_data: null,
      })),
      hasMore,
      pageNum,
      totalPages,
      totalCount,
    };
  }

  function parse(response) {
    if (String(response.code ?? 0) !== "0" && Number(response.code ?? 0) !== 0) return [];
    return (response.searchList || []).map(normalizeItem);
  }

  window.HGWebSearch = {
    AID,
    PAGE_SIZE,
    urlFor,
    request,
    parse,
    resolveHasMore,
    setScenario,
    get scenario() { return scenario.value; },
    meta: {
      path: "/api/search/result",
      note: "免签 GET；剧名/集数/徽标/评分来自 2026-10-30 实机匿名采样。采样不含 series_id 与封面 URL，原型用稳定派生 ID 和 SVG 占位；每页条数由上游决定，原型固定 4 条。",
    },
  };
})();
