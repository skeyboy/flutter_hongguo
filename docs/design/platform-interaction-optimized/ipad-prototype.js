(() => {
  "use strict";
  const { clamp, hydrateIcons, PlaybackClock } = HGProto;
  const Data = window.HGPrototypeData;
  const stage = document.querySelector("#padStage");
  const player = document.querySelector("#padPlayer");
  const state = {
    screen: "discover", mode: "landscape",
    genre: "short_play", cursor: "0", total: 0, request: 0,
    categoryContentType: "short_play", categoryCursor: "0", categoryRequest: 0,
    track: Data.RANK_TRACKS[0].id, boardType: Data.RANK_TRACKS[0].boards[0].type,
    rankRequest: 0,
    detail: null, detailId: "", detailRequest: 0, detailEpisodes: [], detailCursor: null,
    currentEpisode: 1, episodeList: [], episodeCursor: null,
    playing: true, fit: "contain", clock: null,
  };

  const $ = (selector) => document.querySelector(selector);
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  const toast = (message) => {
    const bar = $("#padSnackbar");
    bar.textContent = message; bar.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { bar.hidden = true; }, 2200);
  };
  const setSource = (message) => { $("#padSource").textContent = message; };

  // ===== 导航 =====
  function showScreen(name) {
    state.screen = name;
    document.querySelectorAll("[data-pad-screen]").forEach((button) => {
      if (button.classList.contains("pad-rail-item")) {
        if (button.dataset.padScreen === name) button.setAttribute("aria-current", "page");
        else button.removeAttribute("aria-current");
      }
    });
    document.querySelectorAll(".pad-screen").forEach((section) => { section.hidden = section.dataset.padScreen !== name; });
    player.hidden = true;
    if (name === "discover") loadDiscover();
    if (name === "categories") loadCategories();
    if (name === "rank") loadRank();
    if (name === "mine") loadMine();
  }

  // ===== 发现：真值 feed =====
  async function loadDiscover(append = false) {
    const request = ++state.request;
    $("#padFeedCount").textContent = "正在读取真值目录…";
    document.querySelectorAll("#padGenreChips .pad-chip").forEach((chip) => {
      chip.setAttribute("aria-pressed", String(chip.dataset.genre === state.genre));
    });
    try {
      const page = await Data.browse({ contentType: state.genre, cursor: state.cursor, sort: Data.SORT_DEFAULT });
      if (request !== state.request) return;
      state.total = page.total;
      const hero = page.items[0];
      if (hero && !append) {
        $("#padHero").innerHTML = `<div class="pad-hero-copy">
          <h1>${escapeHtml(hero.title)}</h1>
          <p>评分 ${escapeHtml(hero.score || "—")} · 全 ${hero.episodeCount} 集 · ${escapeHtml(hero.badge || "真值采样")}<br/>${escapeHtml(hero.summary)}</p>
          <button type="button" class="button primary" data-pad-detail="${escapeHtml(hero.id)}">开始观看</button>
        </div>`;
      }
      if (append) $("#padGrid").insertAdjacentHTML("beforeend", page.items.map(padCard).join(""));
      else $("#padGrid").innerHTML = page.items.map(padCard).join("");
      state.cursor = page.nextCursor || "0";
      $("#padFeedCount").textContent = `真值采样 ${page.total} 部 · ${page.cached ? "已缓存" : "本次请求"}${page.note ? " · " + page.note : ""}`;
      $("#padLoadMore").hidden = !page.nextCursor;
      setSource(`目录采样 ${Data.SAMPLE_AT.slice(0, 10)} · ${page.total} 部`);
    } catch (error) {
      $("#padFeedCount").textContent = `加载失败：${error.message}`;
    }
  }
  function padCard(item) {
    const heat = item.badge ? `<span class="pad-card-badge">${escapeHtml(item.badge)}</span>` : "";
    return `<button type="button" class="pad-card" data-pad-detail="${escapeHtml(item.id)}">
      <span class="pad-card-art">${heat}<img src="${escapeHtml(item.poster)}" alt="" loading="lazy" /><span class="pad-card-eps">全${item.episodeCount}集</span></span>
      <span class="pad-card-copy"><strong>${escapeHtml(item.title)}</strong><small>评分 ${escapeHtml(item.score || "—")}</small></span>
    </button>`;
  }

  // ===== 榜单：真值赛道 × 真值榜名 =====
  async function loadRank() {
    const request = ++state.rankRequest;
    const track = Data.RANK_TRACKS.find((t) => t.id === state.track) || Data.RANK_TRACKS[0];
    $("#padRankTracks").innerHTML = Data.RANK_TRACKS.map((t) =>
      `<button type="button" class="pad-chip" data-track-id="${escapeHtml(t.id)}" aria-pressed="${t.id === state.track}">${escapeHtml(t.name)}</button>`).join("");
    $("#padRankBoards").innerHTML = track.boards.map((b) =>
      `<button type="button" class="pad-chip" data-board-type="${escapeHtml(b.type)}" aria-pressed="${b.type === state.boardType}">${escapeHtml(b.name)}</button>`).join("");
    $("#padRankNotice").textContent = `${track.name} · 上游现读 ${track.boards.length} 块榜`;
    $("#padRankList").innerHTML = '<div class="pad-section-head"><p>正在读取榜单…</p></div>';
    try {
      const page = await Data.rank(state.boardType, state.track);
      if (request !== state.rankRequest) return;
      $("#padRankList").innerHTML = page.items.length ? page.items.map((item) => {
        const badge = item.badge ? `<span class="pad-rank-badge">${escapeHtml(item.badge)}</span>` : "";
        return `<button type="button" class="pad-rank-row" data-pad-detail="${escapeHtml(item.id)}" data-top="${item.position <= 3}">
          <span class="pad-rank-pos">${item.position}</span>
          <span class="pad-rank-thumb" style="background:${escapeHtml(item.dominateColor)}"><img src="${escapeHtml(item.poster)}" alt="" loading="lazy" /></span>
          <span class="pad-rank-copy"><strong>${escapeHtml(item.title)}</strong>${badge}<small>${escapeHtml(item.subtitle || "")}</small></span>
          <span class="pad-rank-metrics">${item.heat ? `<em>${escapeHtml(item.heat)}</em>` : ""}${item.collect ? `<span>${escapeHtml(item.collect)}</span>` : ""}${item.score ? `<span>评分 ${escapeHtml(item.score)}</span>` : ""}</span>
        </button>`;
      }).join("") : `<div class="pad-section-head"><p>${escapeHtml(page.notice)}</p></div>`;
      $("#padRankNotice").textContent = `${page.notice}${page.updatedAt ? " · 更新于 " + page.updatedAt.slice(11, 16) + " UTC" : ""}`;
      setSource(`榜单采样 ${Data.SAMPLE_AT.slice(0, 10)} · ${page.count} 条`);
    } catch (error) {
      $("#padRankList").innerHTML = `<div class="pad-section-head"><p>榜单加载失败：${escapeHtml(error.message)}</p></div>`;
    }
  }

  // ===== 分类：与 PC 一致的内容类型筛选 =====
  async function loadCategories(append = false) {
    const request = ++state.categoryRequest;
    try {
      const page = await Data.browse({ contentType: state.categoryContentType, cursor: state.categoryCursor, sort: Data.SORT_DEFAULT });
      if (request !== state.categoryRequest) return;
      if (append) $("#padCategoryGrid").insertAdjacentHTML("beforeend", page.items.map(padCard).join(""));
      else $("#padCategoryGrid").innerHTML = page.items.map(padCard).join("");
      state.categoryCursor = page.nextCursor || "0";
      $("#padCategorySummary").textContent = `真值采样 ${page.total} 部 · ${page.cached ? "已缓存" : "本次请求"}`;
      $("#padCategoryLoadMore").hidden = !page.nextCursor;
    } catch (error) { $("#padCategorySummary").textContent = `加载失败：${error.message}`; }
  }

  // ===== 详情：PC 式顺序（选集在相关推荐之上） =====
  async function openDetail(id) {
    const request = ++state.detailRequest;
    showScreen("detail");
    state.detailId = String(id || "");
    try {
      const detail = await Data.detail(state.detailId);
      if (request !== state.detailRequest) return;
      state.detail = detail;
      state.detailEpisodes = detail.episodes || [];
      state.detailCursor = detail.nextEpisodeCursor || null;
      state.currentEpisode = Math.min(3, Math.max(1, detail.episodeCount));
      $("#padDetailArt").innerHTML = `<img src="${escapeHtml(detail.poster)}" alt="" />`;
      $("#padDetailTags").innerHTML = [detail.theme?.name, `${detail.episodeCount} 集`, Data.statusName(detail.creationStatus), Data.contentTypeName(detail.contentType)]
        .filter(Boolean).map((tag) => `<span class="pad-chip">${escapeHtml(tag)}</span>`).join("");
      $("#padDetailTitle").textContent = detail.title;
      $("#padDetailSummary").textContent = detail.summary;
      $("#padDetailMeta").textContent = `${detail.sourceLabel || "真值采样"} · 模拟字段：${(detail.simulatedFields || []).join("、")}`;
      $("#padDetailTracks").innerHTML = (detail.tracks || []).map((track) =>
        `<button type="button" class="pad-chip" data-detail-track="${escapeHtml(track.id)}" aria-pressed="false" ${track.playable ? "" : "disabled"}>${escapeHtml(track.label)} · ${escapeHtml(track.quality || "自动")}</button>`).join("");
      renderDetailEpisodes();
      $("#padDetailRelated").innerHTML = (detail.related || []).map(padCard).join("");
      setSource(`详情采样 ${Data.SAMPLE_AT.slice(0, 10)} · 选集在相关推荐之上`);
    } catch (error) { toast(error.message); }
  }

  function renderDetailEpisodes() {
    $("#padDetailEpisodes").innerHTML = state.detailEpisodes.map((ep) =>
      `<button type="button" class="pad-episode ${ep.number === state.currentEpisode ? "current" : ""} ${ep.beyondFree ? "locked" : ""}" data-detail-episode="${ep.number}">${ep.number}</button>`).join("");
    const total = state.detail?.episodeCount || 0;
    $("#padDetailEpisodeSummary").textContent = `已加载 ${state.detailEpisodes.length} / ${total} 集 · 当前第 ${state.currentEpisode} 集 · 限免 ${state.detailEpisodes[0]?.accessibleCount || 6}`;
    $("#padDetailLoadMore").hidden = !state.detailCursor;
  }

  async function loadMoreDetailEpisodes() {
    if (!state.detailCursor || !state.detailId) return;
    try {
      const page = await Data.episodes(state.detailId, Number(state.detailCursor));
      state.detailEpisodes = [...state.detailEpisodes, ...page.items];
      state.detailCursor = page.nextCursor;
      renderDetailEpisodes();
    } catch (error) { toast(error.message); }
  }

  // ===== 我的：与 Mobile / PC / TV 共用组件与交互 =====
  const padMine = HGProto.PersonalCenter({
    mount: $("#padMine"),
    Data,
    onOpenDetail: (id) => openDetail(id),
    onContinue: (id, episode) => openDetail(id).then(() => {
      state.currentEpisode = episode;
      renderDetailEpisodes();
      toast(`已从第 ${episode} 集继续`);
    }),
    onSettings: () => toast("设置页沿用 PC 交互，本版未新增入口"),
    toast,
    emptyState: (title, message) => `<div class="pad-section-head"><strong>${escapeHtml(title)}</strong><p>${escapeHtml(message)}</p></div>`,
  });
  async function loadMine() { await padMine.render(); }

  // ===== 三段式播放 =====
  async function openPlayer(id) {
    try {
      const detail = await Data.detail(id);
      state.detail = detail;
      state.currentEpisode = 1;
      state.episodeList = detail.episodes;
      $("#padPlayerTitle").textContent = `${detail.title} · 三段式播放`;
      $("#padVideoTitle").textContent = detail.title;
      $("#padVideoMeta").textContent = `评分 ${detail.score || "—"} · ${detail.sourceLabel || "真值采样"}`;
      $("#padInfoSummary").textContent = detail.summary;
      $("#padVideoPoster").innerHTML = `<img src="${escapeHtml(detail.poster)}" alt="" />`;
      $("#padEpisodeGrid").innerHTML = detail.episodes.map((ep) => `<button type="button" class="pad-episode ${ep.number === state.currentEpisode ? "current" : ""} ${ep.beyondFree ? "locked" : ""}" data-episode="${ep.number}">${ep.number}</button>`).join("");
      $("#padEpisodeSummary").textContent = `共 ${detail.episodeCount} 集 · 限免 ${detail.episodes[0]?.accessibleCount || 6}`;
      $("#padDanmaku").innerHTML = ["高能预警", "这反转太爽了", "追剧中", "画面质感不错", "终于更新了"]
        .map((text, i) => `<div class="pad-danmaku-item">${text}<small>观众${i + 1} · 示例弹幕</small></div>`).join("");
      player.hidden = false;
      hydrateIcons(player);
      if (state.clock) state.clock.dispose();
      state.clock = PlaybackClock({
        duration: 748, initial: 0,
        onUpdate: (position, duration) => {
          $("#padCurrentTime").textContent = HGProto.formatTime(position);
          $("#padProgress").querySelector("i").style.width = `${(position / duration) * 100}%`;
          $("#padProgress").setAttribute("aria-valuenow", String(Math.round(position)));
        },
      });
      state.clock.setPlaying(state.playing);
    } catch (error) { toast(error.message); }
  }

  function togglePlay() {
    state.playing = !state.playing;
    state.clock?.setPlaying(state.playing);
    const iconName = state.playing ? "pause" : "play";
    $("#padPlayBtn").innerHTML = HGProto.icon(iconName);
    $("#padCenterPlay").innerHTML = HGProto.icon(iconName);
    hydrateIcons($("#padPlayBtn")); hydrateIcons($("#padCenterPlay"));
  }

  // ===== 事件绑定 =====
  document.querySelectorAll("[data-pad-mode]").forEach((button) => button.addEventListener("click", () => {
    state.mode = button.dataset.padMode;
    stage.dataset.mode = state.mode;
    document.querySelectorAll("[data-pad-mode]").forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
    toast(`已切换到${state.mode === "landscape" ? "横屏两栏" : state.mode === "portrait" ? "竖屏单列" : "分屏窄窗"}`);
  }));
  document.querySelectorAll(".pad-rail-item, .pad-topbar [data-pad-screen]").forEach((button) => {
    button.addEventListener("click", () => showScreen(button.dataset.padScreen));
  });
  $("#scenarioSelect").addEventListener("change", (event) => {
    Data.setScenario(event.target.value);
    if (state.screen === "rank") loadRank(); else loadDiscover();
  });
  $("#padGenreChips").addEventListener("click", (event) => {
    const chip = event.target.closest("[data-genre]");
    if (!chip) return;
    state.genre = chip.dataset.genre; state.cursor = "0"; loadDiscover();
  });
  $("#padRankTracks").addEventListener("click", (event) => {
    const chip = event.target.closest("[data-track-id]");
    if (!chip) return;
    state.track = chip.dataset.trackId;
    const track = Data.RANK_TRACKS.find((t) => t.id === state.track);
    state.boardType = track?.boards[0]?.type || "recommend";
    loadRank();
  });
  $("#padRankBoards").addEventListener("click", (event) => {
    const chip = event.target.closest("[data-board-type]");
    if (!chip) return;
    state.boardType = chip.dataset.boardType; loadRank();
  });
  document.addEventListener("click", (event) => {
    const detailButton = event.target.closest("[data-pad-detail]");
    if (detailButton) { openDetail(detailButton.dataset.padDetail); return; }
    if (event.target.closest("[data-pad-back]")) { player.hidden = true; state.clock?.dispose(); state.clock = null; return; }
    if (event.target.closest("[data-source-switch]")) {
      HGProto.SourceSwitch({
        tracks: state.detail?.tracks || [], currentId: "main",
        onChoose: (id, result) => toast(result.hit ? "已切换播放线路" : "解析超时，已回退可用线路"),
      });
    }
    const toastButton = event.target.closest("[data-toast]");
    if (toastButton) { toast(toastButton.dataset.toast); return; }
  });
  $("#padPlayBtn").addEventListener("click", togglePlay);
  $("#padCenterPlay").addEventListener("click", togglePlay);
  $("#padEpisodeGrid").addEventListener("click", (event) => {
    const button = event.target.closest("[data-episode]");
    if (!button) return;
    const number = Number(button.dataset.episode);
    if (button.classList.contains("locked")) { toast("该集限免外，请换源或前往观看页"); return; }
    state.currentEpisode = number;
    $("#padEpisodeGrid").querySelectorAll(".pad-episode").forEach((b) => b.classList.toggle("current", Number(b.dataset.episode) === number));
    $("#padVideoTitle").textContent = `${state.detail.title} · 第 ${number} 集`;
    toast(`已切到第 ${number} 集`);
  });
  $("#padProgress").addEventListener("click", (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const ratio = clamp((event.clientX - rect.left) / rect.width, 0, 1);
    state.clock?.seekTo(ratio * 748);
  });
  $("#padRate").addEventListener("click", (event) => {
    const rates = [1, 1.25, 1.5, 2];
    const next = rates[(rates.indexOf(state.clock?.rate || 1) + 1) % rates.length];
    state.clock?.setRate(next);
    event.currentTarget.textContent = `${next.toFixed(2).replace(/0$/, "")}×`;
    toast(`倍速 ${next}×`);
  });
  $("#padFit").addEventListener("click", (event) => {
    state.fit = state.fit === "contain" ? "fill" : "contain";
    $("#padVideoStage").dataset.fit = state.fit;
    event.currentTarget.textContent = state.fit === "contain" ? "适应" : "铺满";
    toast(state.fit === "contain" ? "适应：保留完整画面（黑边）" : "铺满：裁切填满画面");
  });
  $("#padFollow").addEventListener("click", () => toast("已加入追剧列表（favorites）"));
  $("#padReserve").addEventListener("click", () => toast("已预约更新提醒"));
  $("#padSendDanmaku").addEventListener("click", () => {
    const input = $("#padDanmakuInput");
    const text = input.value.trim();
    if (!text) return;
    $("#padDanmaku").insertAdjacentHTML("beforeend", `<div class="pad-danmaku-item">${escapeHtml(text)}<small>我 · 刚刚</small></div>`);
    $("#padDanmaku").scrollTop = $("#padDanmaku").scrollHeight;
    input.value = "";
  });

  // ===== 分类 / 详情交互 =====
  $("#padCategoryTypes").innerHTML = Data.CONTENT_TYPES.map((type) =>
    `<button type="button" class="pad-chip" data-category-type="${escapeHtml(type.id)}" aria-pressed="${type.id === state.categoryContentType}">${escapeHtml(type.name)}</button>`).join("");
  $("#padCategoryTypes").addEventListener("click", (event) => {
    const chip = event.target.closest("[data-category-type]");
    if (!chip) return;
    state.categoryContentType = chip.dataset.categoryType;
    state.categoryCursor = "0";
    $("#padCategoryTypes").querySelectorAll(".pad-chip").forEach((item) =>
      item.setAttribute("aria-pressed", String(item === chip)));
    loadCategories();
  });
  $("#padCategoryLoadMore").addEventListener("click", () => loadCategories(true));
  $("#padLoadMore").addEventListener("click", () => loadDiscover(true));
  $("#padDetailPlay").addEventListener("click", () => openPlayer(state.detailId));
  $("#padDetailFollow").addEventListener("click", () => toast("已加入追剧列表（favorites）"));
  $("#padDetailLoadMore").addEventListener("click", () => loadMoreDetailEpisodes());
  $("#padDetailEpisodes").addEventListener("click", (event) => {
    const button = event.target.closest("[data-detail-episode]");
    if (!button) return;
    const number = Number(button.dataset.detailEpisode);
    if (button.classList.contains("locked")) { toast("该集限免外，请换源后继续观看"); return; }
    state.currentEpisode = number;
    renderDetailEpisodes();
    toast(`已选第 ${number} 集`);
  });
  $("#padDetailTracks").addEventListener("click", (event) => {
    const chip = event.target.closest("[data-detail-track]");
    if (!chip) return;
    $("#padDetailTracks").querySelectorAll(".pad-chip").forEach((item) =>
      item.setAttribute("aria-pressed", String(item === chip)));
    toast(`已切换线路：${chip.textContent.trim()}`);
  });

  // ===== 初始化 =====
  $("#padGenreChips").innerHTML = [{ id: "short_play", name: "真人剧" }, { id: "comic_series", name: "漫剧" }, { id: "ai_series", name: "AI 剧" }]
    .map((g) => `<button type="button" class="pad-chip" data-genre="${g.id}" aria-pressed="${g.id === state.genre}">${g.name}</button>`).join("");
  hydrateIcons(document);
  const initialScreen = new URLSearchParams(location.search).get("screen");
  showScreen(["rank", "categories", "detail", "mine"].includes(initialScreen) ? initialScreen : "discover");
})();
