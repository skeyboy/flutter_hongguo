(() => {
  "use strict";

  const SAMPLE_AT = "2026-11-26T02:14:52.635219Z";
  const RANK_AT = "2026-10-30";
  const PAGE_SIZE = 18;
  const EPISODE_PAGE_SIZE = 60;
  const state = { scenario: "normal" };

  const THEMES = [
    ["cate_5007", "古装"], ["cate_5000", "爱情"], ["cate_5004", "悬疑"],
    ["cate_5001", "家庭"], ["cate_5022", "都市"], ["cate_5025", "科幻"],
    ["cate_5030", "剧情"], ["cate_5031", "逆袭"], ["cate_5008", "玄幻"],
    ["cate_5010", "成长"], ["cate_5021", "年代"], ["cate_5024", "喜剧"],
    ["cate_5023", "青春"], ["cate_9165", "动作"], ["cate_5006", "治愈"],
  ].map(([id, name]) => ({ id, name }));

  const STATUSES = [
    { id: "creation_status_0", name: "已完结" },
    { id: "creation_status_1", name: "连载中" },
  ];

  const CONTENT_TYPES = [
    { id: "short_play", name: "真人短剧", shortName: "短剧" },
    { id: "comic_series", name: "漫剧", shortName: "漫剧" },
    { id: "ai_series", name: "AI 剧", shortName: "AI 剧" },
  ];

  const SORTS = [
    { id: "hot", name: "热门" },
    { id: "new", name: "最新" },
    { id: "favorite", name: "收藏" },
  ];

  const rawRows = [
    ["7711705007799684121", "都很漂亮", "short_play", 9, ["家庭", "家庭伦理", "矛盾和解", "大女主", "现代", "亲子关系"]],
    ["7711000203901291545", "迷途方知岁月真", "short_play", 35, ["悬疑", "悬疑情感", "矛盾和解", "打脸反派", "总裁", "现代"]],
    ["7710560827824147481", "春色初婚", "short_play", 63, ["爱情", "都市爱情", "闪婚", "先婚后爱", "总裁", "现代"]],
    ["7702430712992893976", "念念栀上又相逢", "short_play", 68, ["爱情", "都市爱情", "揭露阴谋", "先婚后爱", "逆风翻盘", "圆满结局", "总裁", "大女主", "忠诚男主", "现代"]],
    ["7711318462810835992", "归乡涅槃：撕开拆迁的谎言", "short_play", 41, ["逆袭", "逆袭翻身", "揭露阴谋", "大男主", "乡村", "现代"]],
    ["7710528099686829081", "穿书民国：我的心声无人敢惹", "short_play", 80, ["家庭", "家庭伦理", "奇幻脑洞", "读心术", "日久生情", "穿书", "真假千金", "民国"]],
    ["7709869681766583320", "退婚嫡女，竟是绝世神医", "short_play", 70, ["玄幻", "逆袭翻身", "空间", "日久生情", "打脸反派", "大女主", "架空", "古代"]],
    ["7711199411925175321", "全网等我爆发，而我等着开饭", "short_play", 60, ["家庭", "家庭伦理", "大男主", "极品亲戚", "乡村", "现代"]],
    ["7711718669679610942", "我的诊断书，是他们所有人的判决书", "short_play", 81, ["剧情", "犯罪", "揭露阴谋", "日久生情", "大女主", "市井英雄", "乡村", "现代"]],
    ["7710201596377844761", "苏秘书，前夫请签收", "short_play", 35, ["都市", "重生逆袭", "隐藏大佬", "揭露阴谋", "虐渣", "大女主", "豪门千金", "现代"]],
    ["7710184330739338264", "女婿的底线", "short_play", 60, ["家庭", "家庭伦理", "揭露阴谋", "极品亲戚", "现代", "家长里短"]],
    ["7712029706324823065", "姜小姐高调离婚了", "short_play", 61, ["成长", "女性成长", "隐藏大佬", "大女主", "现代", "情感觉醒"]],
    ["7708272475045383230", "冰山先生的掌心光", "short_play", 60, ["爱情", "都市爱情", "闪婚", "先婚后爱", "逼婚", "总裁", "年龄差", "灰姑娘", "现代"]],
    ["7711254808669211673", "春山不眠", "short_play", 70, ["爱情", "都市爱情", "日久生情", "打脸反派", "总裁", "年龄差", "豪门", "现代"]],
    ["7711701400756948030", "夫人，您的马甲藏不住啦", "short_play", 62, ["爱情", "都市爱情", "先婚后爱", "重生", "逆风翻盘", "马甲文", "刺客杀手", "总裁", "现代"]],
    ["7708641756555791385", "我扶你七年你睡我隔壁", "short_play", 57, ["成长", "女性成长", "虐渣", "大女主", "现代", "情感觉醒"]],
    ["7704504409945803801", "姐姐求我带孩子，姐夫要我交伙食费", "short_play", 84, ["成长", "女性成长", "打脸反派", "大女主", "总裁", "现代"]],
    ["7710503618658454553", "温夜潮湿", "short_play", 78, ["爱情", "都市爱情", "日久生情", "逆风翻盘", "总裁", "乖乖女", "现代"]],
    ["7710577961384037438", "全科医生：什么都会亿点点", "comic_series", 102, ["都市", "医疗", "重生", "系统", "升级流", "热血", "大男主", "现代", "无敌神医"]],
    ["7711009447434275865", "皇叔别跑", "comic_series", 14, ["爱情", "奇幻爱情", "逆袭翻身", "穿书", "自我救赎", "轻松搞笑", "大女主", "豪门千金", "古代"]],
    ["7710249398382365758", "家族修仙：我的抽卡很欧皇", "comic_series", 171, ["玄幻", "玄幻仙侠", "穿书", "系统", "召唤抽卡", "擂台比武", "大女主", "豪门千金", "架空", "世家", "修仙问道"]],
    ["7711015946512501822", "听懂兽语后全家慌了", "comic_series", 148, ["悬疑", "御兽", "揭露阴谋", "大女主", "豪门千金", "世子", "古代", "世家", "古装探案", "励志自强"]],
    ["7710843286671330329", "两万块的命", "comic_series", 55, ["成长", "自我救赎", "催泪", "矛盾和解", "市井英雄", "现代", "海洋"]],
    ["7711069487725825086", "我家那只戏精小狗", "comic_series", 73, ["爱情", "仙侠爱情", "轻喜剧", "治愈", "萌系", "隐藏大佬", "萌宠", "戏精", "架空"]],
    ["7711171618160004158", "烟火下的婚约", "ai_series", 45, ["家庭", "婚姻经营", "家庭伦理", "虐渣", "后悔流", "极品亲戚", "豪门千金", "现代", "家长里短"]],
    ["7711171910532353086", "算盘起家", "ai_series", 52, ["年代", "年代创业", "经营奋斗", "逆袭翻身", "美食", "女强", "直爽女主", "极品亲戚", "乡村"]],
    ["7702784787957697560", "养女一来春满家", "ai_series", 42, ["年代", "年代创业", "家庭温情", "治愈", "矛盾和解", "圆满结局", "女强", "直爽女主", "男强", "乡村"]],
    ["7710907271315721278", "三年沉默后真相藏不住了", "ai_series", 47, ["家庭", "隐藏大佬", "财产争夺", "揭露阴谋", "女强", "商界女王", "男强", "现代", "商界", "亲情", "赘婿逆袭"]],
    ["7701670713396038681", "帝阙同谋第2季", "ai_series", 30, ["古装", "朝堂权谋", "隐藏大佬", "权臣篡位", "扮猪吃虎", "揭露阴谋", "大女主", "刺客杀手", "古代"]],
    ["7710559634414636094", "和离后王爷对我念念不忘第二季", "ai_series", 123, ["爱情", "古风爱情", "异能", "甜虐交织", "女强", "古代", "架空"]],
  ];

  const rankRows = {
    recommend: [
      ["7677801492920667198", "糯糯下山，师兄们都慌了", 63, ["萌宝", "异界"]],
      ["7621200213801176126", "万妖图录传第一季", 81, ["玄幻", "穿越", "系统", "逆袭", "异界"]],
      ["7675673932682251326", "搞笑疯人院：满级病友竟是大佬", 82, ["恋爱", "穿越", "搞笑", "都市", "豪门"]],
      ["7677436611537144894", "末日漂流：从小木筏开始无限升级", 104, ["末世", "系统", "升级流"]],
      ["7675400266065136665", "全球死考：刚下刑场你让我去考试第一季", 154, ["脑洞", "穿越", "求生", "无限流", "异界"]],
      ["7669722678260943897", "春潮夜渡", 80, ["恋爱", "古代"]],
      ["7676021826752891966", "一村人养一个神第一季", 80, ["脑洞", "穿越", "系统", "求生", "异界"]],
      ["7637569673411709976", "谁说没灵根不能修仙的？之无灵证道", 78, ["玄幻", "逆袭", "修真", "异界"]],
    ],
    hot: [
      ["7698294694886788121", "和离后我带女儿横扫魔域", 1000, ["玄幻", "系统", "异界"]],
      ["7700968020511837208", "学法律的玄学大师，很常见吗第二季", 236, ["脑洞", "逆袭", "都市"]],
      ["7701199948087299096", "遇棠方知涉：被偏执大佬黏上了3", 99, ["恋爱", "系统", "都市", "豪门"]],
      ["7701303541440187416", "烛九阴第八季", 149, ["玄幻", "逆袭", "古代"]],
      ["7701639065673681944", "我海洛薇兹，在韩国贵族学院假扮千金第二季", 250, ["脑洞", "系统", "都市", "豪门"]],
      ["7697453551529774105", "边军破刀：一路砍到裂土封王", 539, ["剧情", "穿越", "逆袭", "架空"]],
      ["7700436139546512408", "后妈只想苟，老公非要凑第二季", 200, ["恋爱", "穿越", "都市", "豪门"]],
      ["7699494516272663577", "反派拿捏！第三季", 399, ["恋爱", "都市", "豪门"]],
    ],
    new: [
      ["7700968020511837208", "学法律的玄学大师，很常见吗第二季", 236, ["脑洞", "逆袭", "都市"]],
      ["7701199948087299096", "遇棠方知涉：被偏执大佬黏上了3", 99, ["恋爱", "系统", "都市", "豪门"]],
      ["7701303541440187416", "烛九阴第八季", 149, ["玄幻", "逆袭", "古代"]],
      ["7701639065673681944", "我海洛薇兹，在韩国贵族学院假扮千金第二季", 250, ["脑洞", "系统", "都市", "豪门"]],
      ["7700909263228521497", "谁说纨绔不能当状元！第六季", 154, ["剧情", "穿越", "古代"]],
      ["7701297357853314073", "乡下来的掌上明珠第四季", 158, ["萌宝", "萌系", "都市", "豪门"]],
      ["7700975749448092697", "父皇别慌，福星多多来啦第八季", 176, ["萌宝", "古代"]],
      ["7700193386157837336", "我与四大尸王成了兄弟之末世躺赢指南第二季", 186, ["末世", "穿越", "异能", "都市"]],
    ],
  };

  const themeAlias = {
    古代: "古装", 古风爱情: "古装", 古装: "古装", 仙侠爱情: "玄幻",
    玄幻: "玄幻", 奇幻: "科幻", 奇幻脑洞: "科幻", 悬疑: "悬疑", 犯罪: "悬疑",
    家庭: "家庭", 爱情: "爱情", 都市: "都市", 年代: "年代", 成长: "成长",
    剧情: "剧情", 逆袭: "逆袭", 喜剧: "喜剧", 治愈: "治愈", 青春: "青春",
    科幻: "科幻", 动作: "动作", 武侠: "古装", 纪实: "剧情",
  };

  function hash(value) {
    return String(value).split("").reduce((total, char) => (total * 31 + char.charCodeAt(0)) >>> 0, 7);
  }

  function themeFor(tags) {
    const name = tags.map((tag) => themeAlias[tag]).find(Boolean) || "剧情";
    return THEMES.find((theme) => theme.name === name) || THEMES[6];
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
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="480" height="680" viewBox="0 0 480 680"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="${palette[0]}"/><stop offset="1" stop-color="${palette[1]}"/></linearGradient><radialGradient id="h"><stop stop-color="#fff" stop-opacity=".32"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs><rect width="480" height="680" fill="url(#g)"/><circle cx="360" cy="120" r="210" fill="url(#h)"/><path d="M0 530C120 430 200 610 480 430V680H0Z" fill="#000" opacity=".18"/><text x="38" y="74" fill="#fff" opacity=".76" font-family="system-ui,sans-serif" font-size="24">${label}</text><text x="38" y="540" fill="#fff" font-family="system-ui,sans-serif" font-size="42" font-weight="700">${safeTitle.slice(0, 10)}</text><text x="38" y="594" fill="#fff" opacity=".72" font-family="system-ui,sans-serif" font-size="22">红果剧场 · 交互原型</text></svg>`;
    return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
  }

  function baseDrama(row, index, provenance = "api") {
    const [id, title, contentType, episodeCount, tagNames] = row;
    return {
      id,
      title,
      contentType,
      episodeCount,
      tagNames,
      theme: themeFor(tagNames),
      creationStatus: index % 3 === 0 ? "creation_status_0" : "creation_status_1",
      summary: `${title}：${tagNames.slice(0, 4).join("、")}。一次意外的相遇，让原本平行的人生重新交织；在一次次选择与反转中，他们逐渐靠近真相，也找回彼此。`,
      poster: posterFor(title, index, contentType),
      accent: index % 4,
      isNew: index < 8,
      favoriteCount: 1200 + (hash(id) % 98000),
      provenance,
      simulatedFields: ["creationStatus", "summary", "poster", "favoriteCount"],
    };
  }

  const feedCatalog = rawRows.map((row, index) => baseDrama(row, index));
  const catalog = [...feedCatalog];
  Object.values(rankRows).flat().forEach((row, index) => {
    if (!catalog.some((drama) => drama.id === row[0])) {
      catalog.push(baseDrama([row[0], row[1], "short_play", row[2], row[3]], index + 30, "historical-api"));
    }
  });
  const dramasById = new Map(catalog.map((drama) => [drama.id, drama]));

  class DataError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "DataError";
      this.code = code;
    }
  }

  const wait = (milliseconds = 360) => new Promise((resolve) => setTimeout(resolve, milliseconds));

  async function browse(options = {}) {
    await wait();
    if (state.scenario === "error") throw new DataError("NETWORK", "网络开小差了，请检查连接后重试");
    const {
      contentType = "short_play", themeId = "", statusId = "", sort = "hot",
      query = "", cursor = "0", pageSize = PAGE_SIZE,
    } = options;
    if (state.scenario === "empty") return { items: [], nextCursor: null, total: 0, source: SAMPLE_AT, cached: false };
    let items = feedCatalog.filter((drama) => drama.contentType === contentType);
    if (themeId) items = items.filter((drama) => drama.theme.id === themeId);
    if (statusId) items = items.filter((drama) => drama.creationStatus === statusId);
    const keyword = query.trim().toLowerCase();
    if (keyword) items = items.filter((drama) => `${drama.title} ${drama.tagNames.join(" ")}`.toLowerCase().includes(keyword));
    if (sort === "new") items = items.slice().sort((a, b) => Number(b.isNew) - Number(a.isNew) || b.id.localeCompare(a.id));
    if (sort === "favorite") items = items.slice().sort((a, b) => b.favoriteCount - a.favoriteCount);
    const start = Math.max(0, Number(cursor) || 0);
    const page = items.slice(start, start + pageSize);
    return {
      items: page,
      nextCursor: start + page.length < items.length ? String(start + page.length) : null,
      total: items.length,
      source: SAMPLE_AT,
      cached: false,
    };
  }

  const search = (options = {}) => browse(options);

  async function detail(id, options = {}) {
    await wait(options.delay || 420);
    if (state.scenario === "error") throw new DataError("DETAIL", "详情加载失败，请返回后重试");
    const drama = dramasById.get(String(id));
    if (!drama) throw new DataError("NOT_FOUND", "这部剧暂时找不到了");
    const related = catalog.filter((item) => item.id !== id && item.contentType === drama.contentType && item.theme.id === drama.theme.id).slice(0, 6);
    return {
      ...drama,
      sourceLabel: drama.provenance === "historical-api" ? "历史匿名榜单样例" : "匿名目录样例",
      sampledAt: drama.provenance === "historical-api" ? RANK_AT : SAMPLE_AT,
      related,
      episodes: makeEpisodes(id, 1),
      nextEpisodeCursor: drama.episodeCount > EPISODE_PAGE_SIZE ? String(EPISODE_PAGE_SIZE + 1) : null,
      tracks: [
        { id: "main", label: "高清线路 1", status: "ready", playable: true },
        { id: "backup", label: "备用线路", status: "idle", playable: true },
      ],
    };
  }

  function makeEpisodes(id, start, count = EPISODE_PAGE_SIZE) {
    const drama = dramasById.get(String(id));
    if (!drama) return [];
    const end = Math.min(drama.episodeCount, start + count - 1);
    return Array.from({ length: Math.max(0, end - start + 1) }, (_, index) => ({
      number: start + index,
      title: `第 ${start + index} 集`,
      vip: false,
      preview: start + index > drama.episodeCount - 2,
    }));
  }

  async function episodes(id, start = 1, count = EPISODE_PAGE_SIZE) {
    await wait(180);
    if (state.scenario === "error") throw new DataError("EPISODES", "选集加载失败，请重试");
    const items = makeEpisodes(id, start, count);
    const next = start + items.length;
    return { items, nextCursor: next <= (dramasById.get(String(id))?.episodeCount || 0) ? String(next) : null };
  }

  async function rank(type = "recommend") {
    await wait(320);
    if (state.scenario === "error") throw new DataError("RANK", "榜单加载失败，请稍后重试");
    if (state.scenario === "empty" || state.scenario === "live") {
      return {
        items: [], count: 0, type, cached: false, sampledAt: SAMPLE_AT,
        notice: state.scenario === "live" ? "上游于 2026-11-26 返回空榜，以下为浏览推荐" : "当前筛选下暂无榜单内容",
      };
    }
    const rows = rankRows[type] || rankRows.recommend;
    return {
      items: rows.map((row, index) => ({ ...dramasById.get(row[0]), position: index + 1 })),
      count: rows.length,
      type,
      cached: true,
      sampledAt: RANK_AT,
      notice: "榜单缓存 · 2026-10-30 匿名留样；实时接口本次返回空榜",
    };
  }

  function statusName(id) {
    return STATUSES.find((status) => status.id === id)?.name || "连载中";
  }

  function contentTypeName(id) {
    return CONTENT_TYPES.find((type) => type.id === id)?.name || "真人短剧";
  }

  function setScenario(scenario) {
    state.scenario = ["normal", "empty", "error", "live"].includes(scenario) ? scenario : "normal";
    return state.scenario;
  }

  window.HGPrototypeData = {
    SAMPLE_AT, RANK_AT, PAGE_SIZE, EPISODE_PAGE_SIZE, THEMES, STATUSES, CONTENT_TYPES, SORTS,
    browse, search, detail, episodes, rank, statusName, contentTypeName, setScenario, DataError,
    meta: {
      apiShape: "Drama / CatalogPage / DramaDetail / Episode / RankEntry / RankPage",
      provenance: "目录与筛选来自 2026-11-26 匿名采样；榜单来自 2026-10-30 匿名留样。简介、状态、海报、收藏数与播放线路为原型模拟，不代表线上真实值。",
    },
  };
})();
